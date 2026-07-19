#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-docker-nginx:verify}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.24}"
HTTP3_CLIENT_IMAGE="${HTTP3_CLIENT_IMAGE:-ubuntu:24.04}"
PREFIX="${PREFIX:-docker-nginx-integration-$$}"
TEST_ROOT="$(mktemp -d)"

declare -a CONTAINERS=()
declare -a VOLUMES=()
NETWORK="${PREFIX}-network"

cleanup() {
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
    echo "Integration verification failed: $*" >&2
    for container in "${CONTAINERS[@]}"; do
        if docker inspect "${container}" >/dev/null 2>&1; then
            echo "Logs for ${container}:" >&2
            docker logs "${container}" >&2 || true
        fi
    done
    exit 1
}

wait_running() {
    local container="$1"
    local attempts="${2:-30}"

    for ((i = 0; i < attempts; i++)); do
        if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" = "true" ]; then
            return 0
        fi
        sleep 1
    done

    fail "${container} did not become ready"
}

wait_for_log() {
    local container="$1"
    local pattern="$2"
    local attempts="${3:-30}"
    local logs

    for ((i = 0; i < attempts; i++)); do
        logs="$(docker logs "${container}" 2>&1 || true)"
        if grep -Fq "${pattern}" <<< "${logs}"; then
            return 0
        fi
        sleep 1
    done

    fail "${container} did not log expected text: ${pattern}"
}

new_volume() {
    local volume="$1"
    docker volume create "${volume}" >/dev/null
    VOLUMES+=("${volume}")
}

bootstrap_config() {
    local volume="$1"
    docker run --rm \
        -v "${volume}:/config" \
        --entrypoint sh \
        "${IMAGE}" \
        -c 'cp -r /defaults/nginx /config/
            rm -f /config/nginx/snippets/resolver.conf'
}

install_fixtures() {
    local volume="$1"
    docker run --rm \
        -v "${volume}:/config" \
        -v "${TEST_ROOT}/fixtures:/fixtures:ro" \
        --entrypoint sh \
        "${HELPER_IMAGE}" \
        -c 'mkdir -p /config/nginx/site-confs
            cp /fixtures/integration.subdomain.conf /config/nginx/site-confs/
            : > /config/nginx/site-confs/ignored.conf
            cp /fixtures/geoip2.conf /config/nginx/http.d/
            : > /config/nginx/obsolete.conf.sample
            sed -i "s|error_log stderr warn;|error_log stderr debug;|" /config/nginx/nginx.conf'
}

echo "Preparing isolated integration environment..."
mkdir -p "${TEST_ROOT}/fixtures" "${TEST_ROOT}/secrets"

cat > "${TEST_ROOT}/geoip-success" <<'EOF'
#!/bin/sh
set -eu

config=
database_dir=
while getopts "f:d:" option; do
    case "${option}" in
        f) config="${OPTARG}" ;;
        d) database_dir="${OPTARG}" ;;
    esac
done

grep -q '^AccountID file-account$' "${config}"
grep -q '^LicenseKey file-license$' "${config}"
grep -q '^EditionIDs GeoLite2-Country$' "${config}"
mkdir -p "${database_dir}"
: > "${database_dir}/GeoLite2-Country.mmdb"
EOF

cat > "${TEST_ROOT}/geoip-failure" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${TEST_ROOT}/geoip-success" "${TEST_ROOT}/geoip-failure"

printf '%s' 'test-api-key' > "${TEST_ROOT}/secrets/crowdsec_api_key"
printf '%s' 'file-account' > "${TEST_ROOT}/secrets/maxmind_account"
printf '%s' 'file-license' > "${TEST_ROOT}/secrets/maxmind_license"

docker network create "${NETWORK}" >/dev/null

BANNED_CLIENT="${PREFIX}-banned"
TRUSTED_CLIENT="${PREFIX}-trusted"
CONTAINERS+=("${BANNED_CLIENT}" "${TRUSTED_CLIENT}")
docker run -d --name "${BANNED_CLIENT}" --network "${NETWORK}" \
    --entrypoint sleep "${IMAGE}" 86400 >/dev/null
docker run -d --name "${TRUSTED_CLIENT}" --network "${NETWORK}" \
    --entrypoint sleep "${IMAGE}" 86400 >/dev/null

BANNED_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${BANNED_CLIENT}")"
TRUSTED_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "${TRUSTED_CLIENT}")"

cat > "${TEST_ROOT}/fixtures/geoip2.conf" <<EOF
map \$remote_addr \$addr_allowed {
    default no;
    "${TRUSTED_IP}" yes;
}

map \$remote_addr \$access_allowed {
    default yes;
}
EOF

cat > "${TEST_ROOT}/fixtures/integration.subdomain.conf" <<'EOF'
server {
    listen 8080;
    listen unix:/run/crowdsec-integration.sock;
    server_name integration.test;

    location = /slow {
        content_by_lua_block {
            ngx.sleep(2)
            ngx.say("slow-ok")
        }
    }

    location / {
        default_type text/plain;
        content_by_lua_block {
            ngx.say("ok")
        }
    }
}

server {
    listen 8443 ssl;
    listen 8443 quic reuseport;
    server_name integration.test;

    ssl_certificate /config/keys/cert.crt;
    ssl_certificate_key /config/keys/cert.key;

    location / {
        default_type text/plain;
        content_by_lua_block {
            ngx.say("secure-ok")
        }
    }
}
EOF

cat > "${TEST_ROOT}/crowdsec-lapi.conf" <<EOF
pid /tmp/crowdsec-lapi.pid;
error_log stderr notice;
events {}
http {
    log_format integration '\$request_method \$request_uri api_key=\$http_x_api_key user_agent="\$http_user_agent"';
    access_log /dev/stdout integration;

    server {
        listen 8080;

        location /v1/decisions/stream {
            default_type application/json;
            return 200 '{"new":[{"duration":"1h","origin":"crowdsec","scope":"Ip","type":"ban","value":"${BANNED_IP}"},{"duration":"1h","origin":"crowdsec","scope":"Ip","type":"ban","value":"${TRUSTED_IP}"}],"deleted":[]}';
        }

        location /v1/usage-metrics {
            default_type application/json;
            return 200 '{}';
        }
    }
}
EOF

LAPI="${PREFIX}-lapi"
CONTAINERS+=("${LAPI}")
docker run -d \
    --name "${LAPI}" \
    --network "${NETWORK}" \
    -v "${TEST_ROOT}/crowdsec-lapi.conf:/tmp/nginx.conf:ro" \
    --entrypoint /usr/sbin/nginx \
    "${IMAGE}" \
    -c /tmp/nginx.conf -g 'daemon off;' >/dev/null
wait_running "${LAPI}"

CONFIG_VOLUME="${PREFIX}-config"
new_volume "${CONFIG_VOLUME}"
bootstrap_config "${CONFIG_VOLUME}"
install_fixtures "${CONFIG_VOLUME}"

docker run --rm \
    -v "${CONFIG_VOLUME}:/config" \
    --entrypoint sh \
    "${HELPER_IMAGE}" \
    -c 'apk add --no-cache openssl >/dev/null
        mkdir -p /config/keys
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -subj "/CN=integration.test" \
            -keyout /config/keys/cert.key \
            -out /config/keys/cert.crt >/dev/null 2>&1'

TARGET="${PREFIX}-target"
CONTAINERS+=("${TARGET}")
docker run -d \
    --name "${TARGET}" \
    --hostname target \
    --network "${NETWORK}" \
    --read-only \
    --tmpfs /run:exec \
    --tmpfs /tmp \
    -e CROWDSEC_NGINX_API_KEY=decoy-api-key \
    -e FILE__CROWDSEC_NGINX_API_KEY=/run/secrets/crowdsec_api_key \
    -e CROWDSEC_LAPI_URL="http://${LAPI}:8080" \
    -e GEOIPUPDATE_ACCOUNT_ID=decoy-account \
    -e GEOIPUPDATE_ACCOUNT_ID_FILE=/run/secrets/maxmind_account \
    -e GEOIPUPDATE_LICENSE_KEY=decoy-license \
    -e FILE__GEOIPUPDATE_LICENSE_KEY=/run/secrets/maxmind_license \
    -e GEOIPUPDATE_EDITION_IDS=GeoLite2-Country \
    -v "${CONFIG_VOLUME}:/config" \
    -v "${TEST_ROOT}/secrets:/run/secrets:ro" \
    -v "${TEST_ROOT}/geoip-success:/usr/local/bin/geoipupdate:ro" \
    "${IMAGE}" >/dev/null

wait_running "${TARGET}"
wait_for_log "${LAPI}" 'user_agent="crowdsec-nginx-bouncer/v1.1.6"'
wait_for_log "${TARGET}" 'site configs are ignored because their names do not end in .subdomain.conf'

docker exec "${TARGET}" sh -c '
    test -f /config/nginx/nginx.conf.sample
    test -f /config/nginx/snippets/resolver.conf.sample
    test ! -e /config/nginx/obsolete.conf.sample
    cmp -s /defaults/nginx/nginx.conf /config/nginx/nginx.conf.sample
    cmp -s /defaults/nginx/snippets/resolver.conf /config/nginx/snippets/resolver.conf.sample
    grep -q "^resolver " /config/nginx/snippets/resolver.conf
    grep -Fq "Generated from the container" /config/nginx/snippets/resolver.conf
    test "$((0$(stat -c %a /config/nginx/nginx.conf) & 0020))" -ne 0
    test "$((0$(stat -c %a /config/nginx/nginx.conf.sample) & 0020))" -ne 0
'

QUIC_HOST_KEY_SHA256="$(docker exec "${TARGET}" sha256sum \
    /config/keys/quic_host.key | awk '{print $1}')"
docker exec "${TARGET}" sh -c '
    test "$(stat -c %a /config/keys/quic_host.key)" = 600
    test "$(wc -c < /config/keys/quic_host.key)" = 32
'

echo "Checking runtime secret paths and LinuxServer secret-file conventions..."
docker exec "${TARGET}" sh -c '
    test "$(stat -c %a /run/GeoIP.conf)" = 600
    test "$(stat -c %a /run/crowdsec/crowdsec-nginx-bouncer.conf)" = 600
    grep -q "^AccountID file-account$" /run/GeoIP.conf
    grep -q "^LicenseKey file-license$" /run/GeoIP.conf
    grep -q "^EditionIDs GeoLite2-Country$" /run/GeoIP.conf
    grep -q "^API_KEY=test-api-key$" /run/crowdsec/crowdsec-nginx-bouncer.conf
    test ! -e /etc/GeoIP.conf
    test ! -e /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf
    ! grep -R -q "test-api-key" /config
'

echo "Checking enabled CrowdSec decisions and bypasses..."
BANNED_STATUS=
for ((i = 0; i < 30; i++)); do
    BANNED_STATUS="$(docker exec "${BANNED_CLIENT}" curl -sS -o /dev/null -w '%{http_code}' \
        "http://${TARGET}:8080/asset.css" || true)"
    if [ "${BANNED_STATUS}" = 403 ]; then
        break
    fi
    sleep 1
done
[ "${BANNED_STATUS}" = 403 ] || fail "CrowdSec did not ban the untrusted client"

TRUSTED_STATUS="$(docker exec "${TRUSTED_CLIENT}" curl -sS -o /dev/null -w '%{http_code}' \
    "http://${TARGET}:8080/")"
[ "${TRUSTED_STATUS}" = 200 ] || fail "trusted-network bypass returned ${TRUSTED_STATUS}"

UNIX_BODY="$(docker exec "${TARGET}" curl -sS \
    --unix-socket /run/crowdsec-integration.sock http://localhost/)"
[ "${UNIX_BODY}" = ok ] || fail "Unix-socket bypass did not return the test response"
wait_for_log "${TARGET}" '[Crowdsec] Trusted network client, skipping...'
wait_for_log "${TARGET}" '[Crowdsec] Unix socket request, skipping...'

echo "Checking TLS, HTTP/2, and an HTTP/3 request over UDP..."
HTTP_VERSION="$(docker exec "${TARGET}" curl -sk --http2 -o /dev/null \
    -w '%{http_version}' https://127.0.0.1:8443/)"
[ "${HTTP_VERSION}" = 2 ] || fail "expected HTTP/2, got HTTP/${HTTP_VERSION}"

if ! docker run --rm --network "${NETWORK}" "${HTTP3_CLIENT_IMAGE}" sh -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ngtcp2-client >/dev/null
    gtlsclient --exit-on-all-streams-close \
        "$1" 8443 "https://$1:8443/"
' sh "${TARGET}" >"${TEST_ROOT}/http3.log" 2>&1; then
    cat "${TEST_ROOT}/http3.log" >&2
    fail "HTTP/3 request failed"
fi
grep -Fq 'secure-ok' "${TEST_ROOT}/http3.log" || {
    cat "${TEST_ROOT}/http3.log" >&2
    fail "HTTP/3 response body was not received"
}

echo "Checking graceful shutdown and persisted /config..."
docker exec "${TARGET}" sh -c \
    'printf "\\n# integration-persistence-marker\\n" >> /config/nginx/snippets/resolver.conf'
docker exec "${TARGET}" sed -i \
    '1s|2026/07/20|2020/01/01|' /config/nginx/snippets/resolver.conf

docker exec "${TRUSTED_CLIENT}" curl -sS "http://${TARGET}:8080/slow" \
    >"${TEST_ROOT}/slow-response" &
SLOW_CURL_PID=$!
sleep 1
docker stop -t 10 "${TARGET}" >/dev/null
wait "${SLOW_CURL_PID}" || fail "in-flight request failed during graceful shutdown"
grep -Fxq slow-ok "${TEST_ROOT}/slow-response" || fail "in-flight response was truncated"
[ "$(docker inspect -f '{{.State.ExitCode}}' "${TARGET}")" = 0 ] ||
    fail "container did not exit cleanly"

docker rm "${TARGET}" >/dev/null

PERSISTED_TARGET="${PREFIX}-persisted"
CONTAINERS+=("${PERSISTED_TARGET}")
docker run -d \
    --name "${PERSISTED_TARGET}" \
    --read-only \
    --tmpfs /run:exec \
    --tmpfs /tmp \
    -v "${CONFIG_VOLUME}:/config" \
    "${IMAGE}" >/dev/null
wait_running "${PERSISTED_TARGET}"
wait_for_log "${PERSISTED_TARGET}" 'different version dates than the shipped samples'
docker exec "${PERSISTED_TARGET}" grep -Fq \
    '# integration-persistence-marker' /config/nginx/snippets/resolver.conf ||
    fail "persisted configuration was overwritten"
docker exec "${PERSISTED_TARGET}" grep -Fq \
    '## Version 2026/07/20' /config/nginx/snippets/resolver.conf.sample ||
    fail "shipped sample was not refreshed"
[ "$(docker exec "${PERSISTED_TARGET}" sha256sum \
    /config/keys/quic_host.key | awk '{print $1}')" = "${QUIC_HOST_KEY_SHA256}" ] ||
    fail "QUIC host key changed after container replacement"
docker stop -t 10 "${PERSISTED_TARGET}" >/dev/null

test_geo_failure() {
    local scenario="$1"
    local expected_log="$2"
    local volume="${PREFIX}-geoip-${scenario}"
    local container="${PREFIX}-geoip-${scenario}"

    new_volume "${volume}"
    bootstrap_config "${volume}"
    if [ "${scenario}" = cached ]; then
        docker run --rm -v "${volume}:/config" "${HELPER_IMAGE}" \
            sh -c 'mkdir -p /config/geoip && : > /config/geoip/cached.mmdb'
    fi

    CONTAINERS+=("${container}")
    docker run -d \
        --name "${container}" \
        --read-only \
        --tmpfs /run:exec \
        --tmpfs /tmp \
        -e GEOIPUPDATE_ACCOUNT_ID=test-account \
        -e GEOIPUPDATE_LICENSE_KEY=test-license \
        -v "${volume}:/config" \
        -v "${TEST_ROOT}/geoip-failure:/usr/local/bin/geoipupdate:ro" \
        "${IMAGE}" >/dev/null
    wait_running "${container}"
    wait_for_log "${container}" "${expected_log}"
    docker stop -t 10 "${container}" >/dev/null
}

echo "Checking GeoIPUpdate failure paths..."
test_geo_failure missing \
    'geoipupdate failed and no existing database was found'
test_geo_failure cached \
    'geoipupdate failed, but an existing database was found'

echo "Checking LinuxServer non-root operation..."
NONROOT_VOLUME="${PREFIX}-nonroot"
NONROOT_TARGET="${PREFIX}-nonroot"
new_volume "${NONROOT_VOLUME}"
bootstrap_config "${NONROOT_VOLUME}"
docker run --rm -v "${NONROOT_VOLUME}:/config" "${HELPER_IMAGE}" \
    sh -c 'chown -R 1000:1000 /config'

CONTAINERS+=("${NONROOT_TARGET}")
docker run -d \
    --name "${NONROOT_TARGET}" \
    --user 1000:1000 \
    --tmpfs /run:exec,uid=1000,gid=1000 \
    --tmpfs /tmp:uid=1000,gid=1000 \
    -e TZ=Etc/UTC \
    -e UMASK=002 \
    -v "${NONROOT_VOLUME}:/config" \
    "${IMAGE}" >/dev/null
wait_running "${NONROOT_TARGET}"
wait_for_log "${NONROOT_TARGET}" 'nginx: configuration file /etc/nginx/nginx.conf test is successful'
docker exec "${NONROOT_TARGET}" nginx -t -e stderr
docker stop -t 10 "${NONROOT_TARGET}" >/dev/null

echo "Integration verification passed."
