#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="${REPOSITORY_ROOT}/tests/fixtures"
IMAGE="${IMAGE:-docker-nginx:verify}"
PREFIX="${PREFIX:-docker-nginx-integration-$$}"
TEST_CASES="${TEST_CASES:-enabled,persistence,nonroot}"
TEST_ROOT="$(mktemp -d)"

declare -a CONTAINERS=()
declare -a VOLUMES=()
declare -a DIAGNOSTIC_CONTAINERS=()
declare -a SELECTED_CASES=()
NETWORK="${PREFIX}-network"
PHASE="environment setup"
TARGET=
LAPI=
BANNED_CLIENT=
CONFIG_VOLUME=
QUIC_HOST_KEY_SHA256=
TLS_CERT_SHA256=

cleanup() {
    local container volume
    for container in "${CONTAINERS[@]}"; do
        docker rm -f "${container}" >/dev/null 2>&1 || true
    done
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    for volume in "${VOLUMES[@]}"; do
        docker volume rm "${volume}" >/dev/null 2>&1 || true
    done
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

new_volume() {
    local volume="$1"
    docker volume create "${volume}" >/dev/null
    VOLUMES+=("${volume}")
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
            enabled | persistence | nonroot) ;;
            *) fail "unknown test case '${selected}'; expected enabled, persistence, or nonroot" ;;
        esac
    done
}

install_fixtures() {
    local volume="$1"
    docker run --rm --network none \
        -v "${volume}:/config" \
        -v "${FIXTURE_ROOT}:/fixtures:ro" \
        --entrypoint sh \
        "${IMAGE}" \
        -c 'mkdir -p /config/nginx/http.d /config/nginx/site-confs
            cp /defaults/nginx/nginx.conf /config/nginx/nginx.conf
            cp /fixtures/integration.conf /config/nginx/site-confs/
            cp /fixtures/geoip2.conf /config/nginx/http.d/'
}

prepare_feature_environment() {
    local lapi_status banned_ip

    echo "Preparing feature-enabled integration environment..."
    mkdir -p "${TEST_ROOT}/secrets"
    cp "${FIXTURE_ROOT}/geoipupdate-stub" "${TEST_ROOT}/geoipupdate-stub"
    chmod +x "${TEST_ROOT}/geoipupdate-stub"
    printf '%s' 'test-api-key' > "${TEST_ROOT}/secrets/crowdsec_api_key"
    printf '%s' 'file-account' > "${TEST_ROOT}/secrets/maxmind_account"
    printf '%s' 'file-license' > "${TEST_ROOT}/secrets/maxmind_license"

    docker network create "${NETWORK}" >/dev/null

    BANNED_CLIENT="${PREFIX}-banned"
    CONTAINERS+=("${BANNED_CLIENT}")
    docker run -d --name "${BANNED_CLIENT}" --network "${NETWORK}" \
        --entrypoint sleep "${IMAGE}" 86400 >/dev/null
    banned_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${BANNED_CLIENT}")"
    sed "s/@BANNED_IP@/${banned_ip}/g" \
        "${FIXTURE_ROOT}/crowdsec-lapi.conf.template" > "${TEST_ROOT}/crowdsec-lapi.conf"

    LAPI="${PREFIX}-lapi"
    CONTAINERS+=("${LAPI}")
    DIAGNOSTIC_CONTAINERS=("${LAPI}")
    docker run -d \
        --name "${LAPI}" \
        --network "${NETWORK}" \
        -v "${TEST_ROOT}/crowdsec-lapi.conf:/tmp/nginx.conf:ro" \
        --entrypoint /usr/sbin/nginx \
        "${IMAGE}" \
        -c /tmp/nginx.conf -g 'daemon off;' >/dev/null

    PHASE="mock CrowdSec readiness"
    lapi_status=
    for ((i = 0; i < 30; i++)); do
        lapi_status="$(docker exec "${BANNED_CLIENT}" curl -sS -o /dev/null -w '%{http_code}' \
            "http://${LAPI}:8080/v1/usage-metrics" || true)"
        [ "${lapi_status}" = 200 ] && break
        sleep 1
    done
    [ "${lapi_status}" = 200 ] || fail "mock CrowdSec API did not become ready"

    CONFIG_VOLUME="${PREFIX}-config"
    new_volume "${CONFIG_VOLUME}"
    install_fixtures "${CONFIG_VOLUME}"

    TARGET="${PREFIX}-target"
    CONTAINERS+=("${TARGET}")
    DIAGNOSTIC_CONTAINERS=("${TARGET}" "${LAPI}")
    docker run -d \
        --name "${TARGET}" \
        --hostname target \
        --network "${NETWORK}" \
        --read-only \
        --tmpfs /run:exec \
        --tmpfs /tmp \
        -e FILE__CROWDSEC_NGINX_API_KEY=/run/secrets/crowdsec_api_key \
        -e CROWDSEC_LAPI_URL="http://${LAPI}:8080" \
        -e FILE__GEOIPUPDATE_ACCOUNT_ID=/run/secrets/maxmind_account \
        -e FILE__GEOIPUPDATE_LICENSE_KEY=/run/secrets/maxmind_license \
        -e GEOIPUPDATE_EDITION_IDS=GeoLite2-Country \
        -v "${CONFIG_VOLUME}:/config" \
        -v "${TEST_ROOT}/secrets:/run/secrets:ro" \
        -v "${TEST_ROOT}/geoipupdate-stub:/usr/local/bin/geoipupdate:ro" \
        "${IMAGE}" >/dev/null

    PHASE="feature-enabled startup"
    wait_healthy "${TARGET}"
    QUIC_HOST_KEY_SHA256="$(docker exec "${TARGET}" sha256sum \
        /config/keys/quic_host.key | awk '{print $1}')"
    TLS_CERT_SHA256="$(docker exec "${TARGET}" sha256sum \
        /config/keys/cert.crt | awk '{print $1}')"
}

test_enabled_features() {
    local banned_status response_headers response_body http_version

    PHASE="enabled feature contracts"
    echo "Checking immutable defaults, generated runtime files, and secret handling..."
    docker exec "${TARGET}" sh -c '
        test ! -L /config/nginx/nginx.conf
        test -L /config/nginx/snippets/server-base.conf
        test "$(readlink /config/nginx/snippets/server-base.conf)" = /defaults/nginx/snippets/server-base.conf
        test ! -L /config/nginx/http.d/geoip2.conf
        grep -q "^resolver " /run/nginx/resolver.conf
        grep -Fq "Generated from the container" /run/nginx/resolver.conf
        test -f /run/nginx/http.d/crowdsec.conf
        test ! -e /config/nginx/http.d/crowdsec.conf
        test "$(stat -c %a /run/GeoIP.conf)" = 600
        test "$(stat -c %a /run/crowdsec/crowdsec-nginx-bouncer.conf)" = 600
        grep -q "^AccountID file-account$" /run/GeoIP.conf
        grep -q "^LicenseKey file-license$" /run/GeoIP.conf
        grep -q "^API_KEY=test-api-key$" /run/crowdsec/crowdsec-nginx-bouncer.conf
        test -f /config/geoip/GeoLite2-Country.mmdb
        ! grep -R -q "test-api-key" /config
        test "$(stat -c %a /config/keys/quic_host.key)" = 600
        test "$(wc -c < /config/keys/quic_host.key)" = 32
        test "$(stat -c %a /config/keys/cert.crt)" = 600
        test "$(stat -c %a /config/keys/cert.key)" = 600
        openssl x509 -in /config/keys/cert.crt -noout -checkend 1
    ' || fail "enabled runtime configuration contract was not satisfied"

    PHASE="CrowdSec decision enforcement"
    echo "Checking one enabled CrowdSec decision..."
    banned_status=
    for ((i = 0; i < 30; i++)); do
        banned_status="$(docker exec "${BANNED_CLIENT}" curl -sS -o /dev/null -w '%{http_code}' \
            "http://${TARGET}:8080/" || true)"
        [ "${banned_status}" = 403 ] && break
        sleep 1
    done
    [ "${banned_status}" = 403 ] || fail "CrowdSec did not ban the test client"
    docker logs "${LAPI}" 2>&1 | grep -Fq 'api_key=test-api-key' ||
        fail "CrowdSec did not authenticate to the mock API"

    PHASE="TLS and HTTP/2"
    echo "Checking TLS, HTTP/2, and HSTS..."
    response_headers="$(docker exec "${TARGET}" curl -sk --http2 -D - -o /dev/null \
        https://127.0.0.1:8443/)"
    grep -Fiq 'Strict-Transport-Security: max-age=63072000' <<< "${response_headers}" ||
        fail "HSTS response header missing"
    response_body="$(docker exec "${TARGET}" curl -sk --http2 https://127.0.0.1:8443/)"
    [ "${response_body}" = secure-ok ] || fail "unexpected TLS response body: ${response_body}"
    http_version="$(docker exec "${TARGET}" curl -sk --http2 -o /dev/null \
        -w '%{http_version}' https://127.0.0.1:8443/)"
    [ "${http_version}" = 2 ] || fail "expected HTTP/2, got HTTP/${http_version}"
}

test_persistence() {
    local persisted_target="${PREFIX}-persisted"

    PHASE="configuration persistence"
    echo "Checking persisted /config..."
    docker exec "${TARGET}" sh -c \
        'cp /config/nginx/snippets/hsts.conf /config/nginx/snippets/hsts.conf.override
         rm /config/nginx/snippets/hsts.conf
         mv /config/nginx/snippets/hsts.conf.override /config/nginx/snippets/hsts.conf
         printf "\n# integration-persistence-marker\n" >> /config/nginx/snippets/hsts.conf
         cat > /config/nginx/snippets/resolver-override.conf <<EOF
## User-managed resolver override
resolver 127.0.0.1 ipv6=off valid=30s;
resolver_timeout 1s;
EOF'
    docker stop -t 10 "${TARGET}" >/dev/null
    [ "$(docker inspect -f '{{.State.ExitCode}}' "${TARGET}")" = 0 ] ||
        fail "feature target did not stop cleanly"
    docker rm "${TARGET}" >/dev/null

    CONTAINERS+=("${persisted_target}")
    DIAGNOSTIC_CONTAINERS=("${persisted_target}")
    docker run -d \
        --name "${persisted_target}" \
        --network "${NETWORK}" \
        --read-only \
        --tmpfs /run:exec \
        --tmpfs /tmp \
        -v "${CONFIG_VOLUME}:/config" \
        "${IMAGE}" >/dev/null
    wait_healthy "${persisted_target}"
    docker exec "${persisted_target}" grep -Fq \
        '# integration-persistence-marker' /config/nginx/snippets/hsts.conf ||
        fail "persisted configuration was overwritten"
    docker exec "${persisted_target}" test ! -L /config/nginx/snippets/hsts.conf ||
        fail "user override was replaced by a default symlink"
    docker exec "${persisted_target}" cmp -s \
        /config/nginx/snippets/resolver-override.conf /run/nginx/resolver.conf ||
        fail "persistent resolver override was not installed"
    [ "$(docker exec "${persisted_target}" sha256sum \
        /config/keys/quic_host.key | awk '{print $1}')" = "${QUIC_HOST_KEY_SHA256}" ] ||
        fail "QUIC host key changed after container replacement"
    [ "$(docker exec "${persisted_target}" sha256sum \
        /config/keys/cert.crt | awk '{print $1}')" = "${TLS_CERT_SHA256}" ] ||
        fail "TLS certificate changed after container replacement"
    docker stop -t 10 "${persisted_target}" >/dev/null
}

test_nonroot() {
    local nonroot_volume="${PREFIX}-nonroot"
    local nonroot_target="${PREFIX}-nonroot"

    PHASE="arbitrary-UID startup"
    echo "Checking arbitrary-UID, read-only operation..."
    new_volume "${nonroot_volume}"
    # Docker reapplies the image directory's ownership when a named volume is
    # still empty, so retain a marker while preparing the pre-writable volume.
    docker run --rm --network none \
        -v "${nonroot_volume}:/config" \
        --entrypoint sh \
        "${IMAGE}" \
        -c 'touch /config/.integration-volume
            chown -R 1000:1000 /config'

    CONTAINERS+=("${nonroot_target}")
    DIAGNOSTIC_CONTAINERS=("${nonroot_target}")
    docker run -d \
        --name "${nonroot_target}" \
        --network none \
        --user 1000:1000 \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges=true \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --tmpfs /run:exec,uid=1000,gid=1000 \
        --tmpfs /tmp:uid=1000,gid=1000 \
        -v "${nonroot_volume}:/config" \
        "${IMAGE}" >/dev/null
    wait_healthy "${nonroot_target}"
    [ "$(docker exec "${nonroot_target}" id -u)" = 1000 ] ||
        fail "container did not run as the requested UID"
    docker exec "${nonroot_target}" nginx -t -e stderr ||
        fail "nginx validation failed under the arbitrary UID"
    docker stop -t 10 "${nonroot_target}" >/dev/null
}

parse_test_cases
if case_selected enabled || case_selected persistence; then
    prepare_feature_environment
fi
case_selected enabled && test_enabled_features
case_selected persistence && test_persistence
case_selected nonroot && test_nonroot

echo "Integration verification passed for: ${TEST_CASES}."
