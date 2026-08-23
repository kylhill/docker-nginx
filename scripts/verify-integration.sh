#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPOSITORY_ROOT}/tests/fixtures"
BASIC_CONFIG_ROOT="${REPOSITORY_ROOT}/examples/basic/config"
IMAGE="${IMAGE:-docker-nginx:verify}"
PREFIX="${PREFIX:-docker-nginx-integration-$$}"
TEST_CASES="${TEST_CASES:-contract,enabled,nonroot}"
CHECK_LUA_MODULES="${CHECK_LUA_MODULES:-0}"
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-\\[(emerg|alert|crit|error)\\]|^ERROR:|^FATAL:}"
TEST_ROOT="$(mktemp -d)"

declare -a CONTAINERS=()
declare -a DIAGNOSTIC_CONTAINERS=()
declare -a SELECTED_CASES=()
NETWORK="${PREFIX}-network"
NETWORK_CREATED=false
PHASE="environment setup"

cleanup() {
    local container
    for container in "${CONTAINERS[@]}"; do
        docker rm -f "${container}" >/dev/null 2>&1 || true
    done
    if [ "${NETWORK_CREATED}" = true ]; then
        docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    fi
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
    local container
    echo "Integration verification failed during ${PHASE}: $*" >&2
    for container in "${DIAGNOSTIC_CONTAINERS[@]}"; do
        if docker inspect "${container}" >/dev/null 2>&1; then
            echo "State for ${container}:" >&2
            docker inspect -f \
                'running={{.State.Running}} status={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "${container}" >&2 || true
            echo "Last 200 log lines for ${container}:" >&2
            docker logs --tail 200 "${container}" >&2 || true
        fi
    done
    exit 1
}

wait_healthy() {
    local container="$1"
    local attempts="${2:-30}"
    local running

    for ((i = 0; i < attempts; i++)); do
        running="$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)"
        [ "${running}" = true ] || fail "${container} stopped before becoming healthy"
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || true)" = healthy ]; then
            return 0
        fi
        sleep 1
    done

    fail "${container} did not become healthy"
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

check_lua_modules() {
    local container="$1"

    docker exec "${container}" sh -lc 'cat > /tmp/crowdsec-lua-load-test.conf <<'"'"'EOF'"'"'
include /etc/nginx/modules/*.conf;
pid /tmp/crowdsec-lua-load-test.pid;
error_log stderr;
events {}
http {
    lua_package_path "/usr/local/lua/crowdsec/?.lua;/usr/share/lua/common/?.lua;/usr/share/lua/common/?/init.lua;;";
    lua_package_cpath "/usr/local/lib/lua/5.1/?.so;;";
    lua_shared_dict crowdsec_cache 1m;
    init_by_lua_block {
        require "cjson"
        require "resty.http"
        require "resty.openssl.x509.chain"
        require "crowdsec"
    }
}
EOF
nginx -c /tmp/crowdsec-lua-load-test.conf -e stderr
nginx -c /tmp/crowdsec-lua-load-test.conf -e stderr -s quit'
}

test_contract() {
    local missing="${PREFIX}-missing-config"
    local target="${PREFIX}-contract"
    local config_dir="${TEST_ROOT}/contract-config"
    local exit_code

    PHASE="required configuration contract"
    echo "Checking startup fails without externally managed configuration..."
    CONTAINERS+=("${missing}")
    DIAGNOSTIC_CONTAINERS=("${missing}")
    docker run -d --name "${missing}" --network none "${IMAGE}" >/dev/null
    exit_code="$(docker wait "${missing}")"
    [ "${exit_code}" != 0 ] || fail "container unexpectedly started without /config"
    docker logs "${missing}" 2>&1 | grep -Fq '/config/nginx/nginx.conf' ||
        fail "missing-config error did not name /config/nginx/nginx.conf"

    prepare_config "${config_dir}"
    CONTAINERS+=("${target}")
    DIAGNOSTIC_CONTAINERS=("${target}")
    docker run -d \
        --name "${target}" \
        --network none \
        --read-only \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        -v "${config_dir}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"
    docker exec "${target}" sh -c 'test "$(cat /proc/1/comm)" = nginx' ||
        fail "nginx is not PID 1"
    docker exec "${target}" nginx \
        -c /config/nginx/nginx.conf \
        -e stderr \
        -g 'pid /run/nginx.pid;' \
        -t || fail "external configuration validation failed"
    if [ "${CHECK_LUA_MODULES}" = 1 ]; then
        check_lua_modules "${target}" || fail "CrowdSec Lua modules could not be loaded"
        if docker logs "${target}" 2>&1 | grep -Eiq "${LOG_ERROR_REGEX}"; then
            fail "container logs matched error regex: ${LOG_ERROR_REGEX}"
        fi
    fi
    docker stop -t 10 "${target}" >/dev/null
    [ "$(docker inspect -f '{{.State.ExitCode}}' "${target}")" = 0 ] ||
        fail "nginx did not stop cleanly through SIGQUIT"
}

prepare_enabled_environment() {
    local config_dir="$1"
    local banned_ip lapi="$2"

    prepare_config "${config_dir}"
    rm "${config_dir}/nginx/site-confs/example.conf"
    cp "${FIXTURE_ROOT}/integration.conf" "${config_dir}/nginx/site-confs/"
    cp "${FIXTURE_ROOT}/geoip2.conf" "${config_dir}/nginx/http.d/"
    cp "${FIXTURE_ROOT}/crowdsec.conf" "${config_dir}/nginx/http.d/crowdsec-bouncer.conf"
    mkdir -p "${config_dir}/crowdsec" "${config_dir}/keys" \
        "${config_dir}/nginx/snippets"
    cp "${FIXTURE_ROOT}/hsts.conf" "${config_dir}/nginx/snippets/"

    command -v openssl >/dev/null || fail "openssl is required for the TLS fixture"
    openssl req -new -x509 -days 1 -nodes \
        -out "${config_dir}/keys/cert.crt" \
        -keyout "${config_dir}/keys/cert.key" \
        -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost >/dev/null 2>&1

    banned_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${PREFIX}-banned")"
    sed "s/@BANNED_IP@/${banned_ip}/g" \
        "${FIXTURE_ROOT}/crowdsec-lapi.conf.template" > "${TEST_ROOT}/crowdsec-lapi.conf"
    sed "s/@LAPI@/${lapi}/g" \
        "${FIXTURE_ROOT}/crowdsec-nginx-bouncer.conf.template" \
        > "${config_dir}/crowdsec/crowdsec-nginx-bouncer.conf"
    chmod 0400 "${config_dir}/crowdsec/crowdsec-nginx-bouncer.conf"
}

test_enabled_features() {
    local banned="${PREFIX}-banned"
    local lapi="${PREFIX}-lapi"
    local target="${PREFIX}-target"
    local config_dir="${TEST_ROOT}/enabled-config"
    local banned_status response_headers response_body http_version lapi_status lapi_logs

    PHASE="feature-enabled environment"
    echo "Preparing CrowdSec, TLS, and HTTP/2 integration environment..."
    docker network create "${NETWORK}" >/dev/null
    NETWORK_CREATED=true

    CONTAINERS+=("${banned}")
    docker run -d --name "${banned}" --network "${NETWORK}" \
        --entrypoint sleep "${IMAGE}" 86400 >/dev/null

    prepare_enabled_environment "${config_dir}" "${lapi}"

    CONTAINERS+=("${lapi}")
    DIAGNOSTIC_CONTAINERS=("${lapi}")
    docker run -d \
        --name "${lapi}" \
        --network "${NETWORK}" \
        -v "${TEST_ROOT}/crowdsec-lapi.conf:/tmp/nginx.conf:ro" \
        --entrypoint nginx \
        "${IMAGE}" \
        -c /tmp/nginx.conf -e stderr -g 'daemon off;' >/dev/null

    lapi_status=
    for ((i = 0; i < 30; i++)); do
        lapi_status="$(docker exec "${banned}" curl -sS -o /dev/null -w '%{http_code}' \
            "http://${lapi}:8080/v1/usage-metrics" || true)"
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
        -v "${config_dir}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"

    PHASE="CrowdSec decision enforcement"
    banned_status=
    for ((i = 0; i < 30; i++)); do
        banned_status="$(docker exec "${banned}" curl -sS -o /dev/null -w '%{http_code}' \
            "http://${target}:8080/" || true)"
        [ "${banned_status}" = 403 ] && break
        sleep 1
    done
    [ "${banned_status}" = 403 ] || fail "CrowdSec did not ban the test client"
    lapi_logs="$(docker logs "${lapi}" 2>&1)"
    grep -Fq 'api_key=test-api-key' <<< "${lapi_logs}" ||
        fail "CrowdSec did not authenticate to the mock API"

    PHASE="TLS and HTTP/2"
    response_headers="$(docker exec "${target}" curl -sk --http2 -D - -o /dev/null \
        https://127.0.0.1:8443/)"
    grep -Fiq 'Strict-Transport-Security: max-age=63072000' <<< "${response_headers}" ||
        fail "HSTS response header missing"
    response_body="$(docker exec "${target}" curl -sk --http2 https://127.0.0.1:8443/)"
    [ "${response_body}" = secure-ok ] || fail "unexpected TLS response body: ${response_body}"
    http_version="$(docker exec "${target}" curl -sk --http2 -o /dev/null \
        -w '%{http_version}' https://127.0.0.1:8443/)"
    [ "${http_version}" = 2 ] || fail "expected HTTP/2, got HTTP/${http_version}"
}

test_nonroot() {
    local target="${PREFIX}-nonroot"
    local config_dir="${TEST_ROOT}/nonroot-config"

    PHASE="arbitrary-UID read-only operation"
    echo "Checking arbitrary-UID operation with read-only configuration..."
    prepare_config "${config_dir}"
    chmod -R a+rX "${config_dir}"

    CONTAINERS+=("${target}")
    DIAGNOSTIC_CONTAINERS=("${target}")
    docker run -d \
        --name "${target}" \
        --network none \
        --user 1000:1000 \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges=true \
        --tmpfs /run:rw,noexec,nosuid,nodev,uid=1000,gid=1000 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=1000,gid=1000 \
        -v "${config_dir}:/config:ro" \
        "${IMAGE}" >/dev/null
    wait_healthy "${target}"
    [ "$(docker exec "${target}" id -u)" = 1000 ] ||
        fail "container did not run as the requested UID"
    docker exec "${target}" nginx \
        -c /config/nginx/nginx.conf \
        -e stderr \
        -g 'pid /run/nginx.pid;' \
        -t || fail "nginx validation failed under the arbitrary UID"
}

parse_test_cases
case_selected contract && test_contract
case_selected enabled && test_enabled_features
case_selected nonroot && test_nonroot

echo "Integration verification passed for: ${TEST_CASES}."
