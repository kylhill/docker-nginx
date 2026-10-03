#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPOSITORY_ROOT}/tests/fixtures"
BASIC_CONFIG_ROOT="${REPOSITORY_ROOT}/examples/basic/config"
IMAGE="${IMAGE:-docker-nginx:verify}"
PREFIX="${PREFIX:-docker-nginx-integration-$$}"
TEST_CASES="${TEST_CASES:-contract,enabled,nonroot}"
CHECK_LUA_MODULES="${CHECK_LUA_MODULES:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
TEST_UID="${TEST_UID:-12345}"
TEST_GID="${TEST_GID:-23456}"
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-\\[(emerg|alert|crit|error)\\]|^ERROR:|^FATAL:}"
TEST_ROOT="$(mktemp -d)"

declare -a CONTAINERS=()
declare -a VOLUMES=()
declare -a DIAGNOSTIC_CONTAINERS=()
declare -a SELECTED_CASES=()
NETWORK="${PREFIX}-network"
NETWORK_CREATED=false
PHASE="environment setup"

cleanup() {
    local status=$? container volume cleanup_failed=0
    trap - ERR
    for container in "${CONTAINERS[@]}"; do
        if docker inspect "${container}" >/dev/null 2>&1; then
            docker rm -f "${container}" >/dev/null || cleanup_failed=1
        fi
    done
    for volume in "${VOLUMES[@]}"; do
        docker volume rm "${volume}" >/dev/null || cleanup_failed=1
    done
    if [ "${NETWORK_CREATED}" = true ]; then
        docker network rm "${NETWORK}" >/dev/null || cleanup_failed=1
    fi
    rm -rf "${TEST_ROOT}" || cleanup_failed=1
    if ((cleanup_failed)); then
        echo "Cleanup failed; inspect resources with prefix ${PREFIX}." >&2
        ((status != 0)) || status=1
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() {
    local container
    trap - ERR
    echo "Integration verification failed during ${PHASE}: $*" >&2
    for container in "${DIAGNOSTIC_CONTAINERS[@]}"; do
        if docker inspect "${container}" >/dev/null 2>&1; then
            echo "State for ${container}:" >&2
            docker inspect -f \
                'running={{.State.Running}} status={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${container}" >&2 || true
            docker inspect -f '{{if .State.Health}}{{json .State.Health.Log}}{{end}}' \
                "${container}" >&2 || true
            echo "Last 200 log lines for ${container}:" >&2
            docker logs --tail 200 "${container}" >&2 || true
        fi
    done
    exit 1
}

# Never print the failing command: future arguments may contain credentials.
trap 'fail "command failed at line ${LINENO} (status $?)"' ERR

wait_healthy() {
    local container="$1" deadline=$((SECONDS + WAIT_TIMEOUT)) state
    while ((SECONDS < deadline)); do
        state="$(docker inspect -f '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container}")"
        [[ "${state}" == true* ]] || fail "${container} stopped before becoming healthy"
        [[ "${state}" == 'true healthy' ]] && return 0
        sleep 1
    done
    fail "${container} did not become healthy within ${WAIT_TIMEOUT}s"
}

wait_failed_start() {
    local container="$1" deadline=$((SECONDS + WAIT_TIMEOUT)) state
    while ((SECONDS < deadline)); do
        state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' "${container}")"
        if [[ "${state}" == false* ]]; then
            [[ "${state}" != 'false 0' ]] || fail "${container} unexpectedly exited successfully"
            return 0
        fi
        sleep 1
    done
    fail "${container} did not reject configuration within ${WAIT_TIMEOUT}s"
}

request() {
    local container="$1"
    shift
    docker exec "${container}" curl --connect-timeout "${CURL_TIMEOUT}" \
        --max-time "${CURL_TIMEOUT}" "$@"
}

validate_config() {
    # Reuse the running image's command rather than duplicating CMD arguments.
    # nginx rewrites /proc/1/cmdline into a process title, so use Docker's launch metadata.
    local argument
    local -a command=()
    docker inspect -f '{{printf "%s%c" .Path 0}}{{range .Args}}{{printf "%s%c" . 0}}{{end}}' \
        "$1" > "${TEST_ROOT}/nginx-command"
    while IFS= read -r -d '' argument; do
        command+=("${argument}")
    done < "${TEST_ROOT}/nginx-command"
    docker exec "$1" "${command[@]}" -t
}

assert_clean_logs() {
    local logs
    logs="$(docker logs "$1" 2>&1)"
    if grep -Ei "${LOG_ERROR_REGEX}" <<< "${logs}" >/dev/null; then
        fail "$1 logs matched error regex: ${LOG_ERROR_REGEX}"
    fi
}

case_selected() {
    local candidate="$1"
    local selected
    for selected in "${SELECTED_CASES[@]}"; do
        [[ "${selected}" == "${candidate}" ]] && return 0
    done
    return 1
}

parse_test_cases() {
    local selected
    IFS=',' read -r -a SELECTED_CASES <<< "${TEST_CASES}"
    ((${#SELECTED_CASES[@]} > 0)) || fail "no test cases selected"
    for selected in "${SELECTED_CASES[@]}"; do
        case "${selected}" in
            contract | enabled | nonroot) ;;
            *) fail "unknown test case '${selected}'; expected contract, enabled, or nonroot" ;;
        esac
    done
}

prepare_config() {
    local destination="$1"
    mkdir -p "${destination}"
    cp -a "${BASIC_CONFIG_ROOT}/." "${destination}/"
}

prepare_fixture_volume() {
    local source_dir="$1"
    local volume="$2"
    local staging="${volume}-staging"

    docker volume create "${volume}" >/dev/null ||
        fail "could not create fixture volume ${volume}"
    VOLUMES+=("${volume}")
    CONTAINERS+=("${staging}")
    docker create --name "${staging}" --network none \
        -v "${volume}:/fixture" "${IMAGE}" >/dev/null ||
        fail "could not create fixture staging container ${staging}"
    # Copy through the Docker API; fixture paths need not exist on the daemon host.
    docker cp "${source_dir}/." "${staging}:/fixture" ||
        fail "could not copy fixtures into ${volume}"
    docker rm "${staging}" >/dev/null ||
        fail "could not remove fixture staging container ${staging}"
}

test_contract() {
    local missing="${PREFIX}-missing-config"
    local invalid="${PREFIX}-invalid-config"
    local invalid_dir="${TEST_ROOT}/invalid-config"
    local invalid_volume="${PREFIX}-invalid-config"
    local target="${PREFIX}-contract"
    local config_dir="${TEST_ROOT}/contract-config"
    local config_volume="${PREFIX}-contract-config"
    local logs

    PHASE="required configuration contract"
    echo "Checking startup fails without externally managed configuration..."
    CONTAINERS+=("${missing}")
    DIAGNOSTIC_CONTAINERS=("${missing}")
    docker run -d --name "${missing}" --network none "${IMAGE}" >/dev/null
    wait_failed_start "${missing}"
    logs="$(docker logs "${missing}" 2>&1)"
    grep -F '/config/nginx/nginx.conf' <<< "${logs}" >/dev/null ||
        fail "missing-config error did not name /config/nginx/nginx.conf"

    PHASE="invalid configuration rejection"
    mkdir -p "${invalid_dir}/nginx"
    printf 'this_is_intentionally_invalid;\n' > "${invalid_dir}/nginx/nginx.conf"
    prepare_fixture_volume "${invalid_dir}" "${invalid_volume}"
    CONTAINERS+=("${invalid}")
    DIAGNOSTIC_CONTAINERS=("${invalid}")
    docker run -d --name "${invalid}" --network none \
        -v "${invalid_volume}:/config:ro" "${IMAGE}" >/dev/null
    wait_failed_start "${invalid}"
    logs="$(docker logs "${invalid}" 2>&1)"
    grep -F 'this_is_intentionally_invalid' <<< "${logs}" >/dev/null ||
        fail "startup did not report the invalid configuration directive"

    PHASE="external configuration and image contract"
    [ "$(docker image inspect -f '{{.Config.StopSignal}}' "${IMAGE}")" = SIGQUIT ] ||
        fail "image stop signal is not SIGQUIT"
    prepare_config "${config_dir}"
    if [ "${CHECK_LUA_MODULES}" = 1 ]; then
        cp "${FIXTURE_ROOT}/lua-paths.conf" "${config_dir}/nginx/http.d/"
        cp "${FIXTURE_ROOT}/lua-load.conf" "${config_dir}/nginx/http.d/"
    fi
    prepare_fixture_volume "${config_dir}" "${config_volume}"
    CONTAINERS+=("${target}")
    DIAGNOSTIC_CONTAINERS=("${target}")
    docker run -d \
        --name "${target}" \
        --network none \
        --read-only \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        -v "${config_volume}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"
    docker exec "${target}" sh -c 'test "$(cat /proc/1/comm)" = nginx' ||
        fail "nginx is not PID 1"
    validate_config "${target}"
    assert_clean_logs "${target}"
    docker stop -t 10 "${target}" >/dev/null
    [ "$(docker inspect -f '{{.State.ExitCode}}' "${target}")" = 0 ] ||
        fail "nginx did not stop cleanly through SIGQUIT"
}

render_feature_fixture() {
    local source="$1" destination="$2"
    sed -e "s/@HTTP_PORT@/${FEATURE_HTTP_PORT}/g" \
        -e "s/@TLS_PORT@/${FEATURE_TLS_PORT}/g" \
        -e "s/@LAPI_PORT@/${FEATURE_LAPI_PORT}/g" \
        -e "s/@API_KEY@/${FEATURE_API_KEY}/g" \
        -e "s/@TLS_BODY@/${FEATURE_TLS_BODY}/g" \
        -e "s/@HSTS@/${FEATURE_HSTS}/g" \
        "${source}" > "${destination}"
}

prepare_enabled_environment() {
    local config_dir="$1"
    local banned_ip lapi="$2"

    prepare_config "${config_dir}"
    # Replace example sites regardless of their filenames.
    rm -f "${config_dir}/nginx/site-confs/"*.conf
    render_feature_fixture "${FIXTURE_ROOT}/integration.conf.template" \
        "${config_dir}/nginx/site-confs/integration.conf"
    cp "${FIXTURE_ROOT}/geoip2.conf" "${config_dir}/nginx/http.d/"
    cp "${FIXTURE_ROOT}/lua-paths.conf" "${config_dir}/nginx/http.d/"
    cp "${FIXTURE_ROOT}/crowdsec.conf" "${config_dir}/nginx/http.d/crowdsec-bouncer.conf"
    mkdir -p "${config_dir}/crowdsec" "${config_dir}/keys" \
        "${config_dir}/nginx/snippets"
    render_feature_fixture "${FIXTURE_ROOT}/hsts.conf.template" \
        "${config_dir}/nginx/snippets/hsts.conf"

    command -v openssl >/dev/null || fail "openssl is required for the TLS fixture"
    openssl req -new -x509 -days 1 -nodes \
        -out "${config_dir}/keys/cert.crt" \
        -keyout "${config_dir}/keys/cert.key" \
        -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost >/dev/null 2>&1

    banned_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${PREFIX}-banned")"
    mkdir -p "${TEST_ROOT}/lapi-config"
    render_feature_fixture "${FIXTURE_ROOT}/crowdsec-lapi.conf.template" \
        "${TEST_ROOT}/lapi-config/nginx.conf"
    sed -i "s/@BANNED_IP@/${banned_ip}/g" "${TEST_ROOT}/lapi-config/nginx.conf"
    render_feature_fixture "${FIXTURE_ROOT}/crowdsec-nginx-bouncer.conf.template" \
        "${config_dir}/crowdsec/crowdsec-nginx-bouncer.conf"
    sed -i "s/@LAPI@/${lapi}/g" "${config_dir}/crowdsec/crowdsec-nginx-bouncer.conf"
    chmod 0400 "${config_dir}/crowdsec/crowdsec-nginx-bouncer.conf"
}

test_enabled_features() {
    local banned="${PREFIX}-banned"
    local lapi="${PREFIX}-lapi"
    local target="${PREFIX}-target"
    local config_dir="${TEST_ROOT}/enabled-config"
    local config_volume="${PREFIX}-enabled-config"
    local lapi_volume="${PREFIX}-lapi-config"
    local banned_status response_headers response_body http_version lapi_status lapi_logs
    local deadline
    # shellcheck source=../tests/fixtures/features.env
    source "${FIXTURE_ROOT}/features.env"

    PHASE="feature-enabled environment"
    echo "Preparing CrowdSec, TLS, and HTTP/2 integration environment..."
    docker network create "${NETWORK}" >/dev/null
    NETWORK_CREATED=true

    CONTAINERS+=("${banned}")
    docker run -d --name "${banned}" --network "${NETWORK}" --no-healthcheck \
        --entrypoint sleep "${IMAGE}" 86400 >/dev/null

    prepare_enabled_environment "${config_dir}" "${lapi}"
    prepare_fixture_volume "${config_dir}" "${config_volume}"
    prepare_fixture_volume "${TEST_ROOT}/lapi-config" "${lapi_volume}"

    CONTAINERS+=("${lapi}")
    DIAGNOSTIC_CONTAINERS=("${lapi}")
    docker run -d \
        --name "${lapi}" \
        --network "${NETWORK}" \
        --no-healthcheck \
        -v "${lapi_volume}:/config:ro" \
        --entrypoint nginx \
        "${IMAGE}" \
        -c /config/nginx.conf -e stderr -g 'daemon off;' >/dev/null

    lapi_status=
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        lapi_status="$(request "${banned}" -sS -o /dev/null -w '%{http_code}' \
            "http://${lapi}:${FEATURE_LAPI_PORT}/v1/usage-metrics" || true)"
        [ "${lapi_status}" = 200 ] && break
        sleep 1
    done
    [ "${lapi_status}" = 200 ] || fail "mock CrowdSec API did not become ready"

    CONTAINERS+=("${target}")
    DIAGNOSTIC_CONTAINERS=("${target}" "${lapi}")
    docker run -d \
        --name "${target}" \
        --hostname target \
        --network "${NETWORK}" \
        --read-only \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        -v "${config_volume}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"

    PHASE="CrowdSec decision enforcement"
    banned_status=
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        banned_status="$(request "${banned}" -sS -o /dev/null -w '%{http_code}' \
            "http://${target}:${FEATURE_HTTP_PORT}/" || true)"
        [ "${banned_status}" = 403 ] && break
        sleep 1
    done
    [ "${banned_status}" = 403 ] || fail "CrowdSec did not ban the test client"
    lapi_logs="$(docker logs "${lapi}" 2>&1)"
    grep -F "api_key=${FEATURE_API_KEY}" <<< "${lapi_logs}" >/dev/null ||
        fail "CrowdSec did not authenticate to the mock API"

    PHASE="TLS and HTTP/2"
    http_version="$(request "${target}" -sk --http2 \
        -D /tmp/test-response-headers -o /tmp/test-response-body \
        -w '%{http_version}' https://127.0.0.1:${FEATURE_TLS_PORT}/)"
    response_headers="$(docker exec "${target}" cat /tmp/test-response-headers)"
    response_body="$(docker exec "${target}" cat /tmp/test-response-body)"
    grep -Fi "Strict-Transport-Security: ${FEATURE_HSTS}" <<< "${response_headers}" >/dev/null ||
        fail "HSTS response header missing"
    [ "${response_body}" = "${FEATURE_TLS_BODY}" ] || fail "unexpected TLS response body: ${response_body}"
    [ "${http_version}" = 2 ] || fail "expected HTTP/2, got HTTP/${http_version}"
}

test_nonroot() {
    local target="${PREFIX}-nonroot"
    local config_dir="${TEST_ROOT}/nonroot-config"
    local config_volume="${PREFIX}-nonroot-config"
    local old_workers worker deadline reload_seen=false

    PHASE="arbitrary-UID read-only operation"
    echo "Checking arbitrary-UID operation with read-only configuration..."
    prepare_config "${config_dir}"
    cp "${FIXTURE_ROOT}/reload.conf" "${config_dir}/nginx/site-confs/"
    chmod -R a+rX "${config_dir}"
    prepare_fixture_volume "${config_dir}" "${config_volume}"

    CONTAINERS+=("${target}")
    DIAGNOSTIC_CONTAINERS=("${target}")
    docker run -d \
        --name "${target}" \
        --network none \
        --user "${TEST_UID}:${TEST_GID}" \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges=true \
        --tmpfs "/run:rw,noexec,nosuid,nodev,uid=${TEST_UID},gid=${TEST_GID}" \
        --tmpfs "/tmp:rw,noexec,nosuid,nodev,uid=${TEST_UID},gid=${TEST_GID}" \
        -v "${config_volume}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"
    [ "$(docker exec "${target}" id -u)" = "${TEST_UID}" ] ||
        fail "container did not run as the requested UID"
    [ "$(docker exec "${target}" id -g)" = "${TEST_GID}" ] ||
        fail "container did not run as the requested GID"
    validate_config "${target}"
    # Capture every old child: a request to any original worker cannot prove reload.
    old_workers=" $(docker exec "${target}" cat /proc/1/task/1/children) "
    request "${target}" -fsS --unix-socket /run/nginx-reload-test.sock \
        http://localhost/ >/dev/null
    docker kill --signal HUP "${target}" >/dev/null
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        worker="$(request "${target}" -fsS --unix-socket /run/nginx-reload-test.sock \
            http://localhost/ || true)"
        if [[ "${worker}" =~ ^[0-9]+$ && "${old_workers}" != *" ${worker} "* ]]; then
            reload_seen=true
            break
        fi
        sleep 1
    done
    [ "${reload_seen}" = true ] ||
        fail "a replacement nginx worker did not serve a response after SIGHUP"
    assert_clean_logs "${target}"
    docker stop -t 10 "${target}" >/dev/null
    [ "$(docker inspect -f '{{.State.ExitCode}}' "${target}")" = 0 ] ||
        fail "nginx did not stop cleanly under the arbitrary UID"
}

for value in "${WAIT_TIMEOUT}" "${CURL_TIMEOUT}" "${TEST_UID}" "${TEST_GID}"; do
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fail "timeouts and test UID/GID must be positive integers"
done
parse_test_cases
if case_selected contract; then test_contract; fi
if case_selected enabled; then test_enabled_features; fi
if case_selected nonroot; then test_nonroot; fi

echo "Integration verification passed for: ${TEST_CASES}."
