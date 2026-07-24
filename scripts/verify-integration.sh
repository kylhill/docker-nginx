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

wait_stopped() {
    local container="$1"
    local attempts="${2:-30}"

    for ((i = 0; i < attempts; i++)); do
        if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" = "false" ]; then
            return 0
        fi
        sleep 1
    done

    fail "${container} did not stop after initialization failed"
}

wait_healthy() {
    local container="$1"
    local attempts="${2:-30}"

    for ((i = 0; i < attempts; i++)); do
        if [ "$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || true)" = healthy ]; then
            return 0
        fi
        sleep 1
    done

    fail "${container} did not become healthy"
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
        --entrypoint bash \
        "${IMAGE}" \
        -c 'mkdir -p /config/nginx/site-confs
            while IFS= read -r -d "" source; do
                destination="/config/${source#/defaults/}"
                mkdir -p "$(dirname "${destination}")"
                ln -s "${source}" "${destination}"
            done < <(find /defaults/nginx -type f -print0)'
}

install_fixtures() {
    local volume="$1"
    docker run --rm \
        -v "${volume}:/config" \
        -v "${TEST_ROOT}/fixtures:/fixtures:ro" \
        --entrypoint sh \
        "${IMAGE}" \
        -c 'mkdir -p /config/nginx/site-confs
            cp /fixtures/integration.subdomain.conf /config/nginx/site-confs/
            : > /config/nginx/site-confs/ignored.conf
            rm -f /config/nginx/http.d/geoip2.conf
            cp /fixtures/geoip2.conf /config/nginx/http.d/
            cp /config/nginx/nginx.conf /config/nginx/nginx.conf.override
            rm /config/nginx/nginx.conf
            mv /config/nginx/nginx.conf.override /config/nginx/nginx.conf
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
    include /config/nginx/snippets/hsts.conf;
    include /config/nginx/snippets/security-headers.conf;

    location / {
        default_type text/plain;
        add_header X-Integration-Location true always;
        content_by_lua_block {
            ngx.say("secure-ok")
        }
    }

    location = /proxy-tls-policy {
        include /config/nginx/snippets/proxy-ssl-verify.conf;
        return 204;
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

TARGET="${PREFIX}-target"
CONTAINERS+=("${TARGET}")
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
    -v "${TEST_ROOT}/geoip-success:/usr/local/bin/geoipupdate:ro" \
    "${IMAGE}" >/dev/null

wait_running "${TARGET}"
wait_healthy "${TARGET}"
wait_for_log "${LAPI}" 'user_agent="crowdsec-nginx-bouncer/v1.1.6"'
wait_for_log "${TARGET}" 'site configs are ignored because their names do not end in .subdomain.conf'
wait_for_log "${TARGET}" 'GeoIPUpdate completed successfully.'

docker exec "${TARGET}" sh -c '
    test ! -e /config/nginx/nginx.conf.sample
    test ! -L /config/nginx/nginx.conf
    test -L /config/nginx/snippets/server-base.conf
    test "$(readlink /config/nginx/snippets/server-base.conf)" = /defaults/nginx/snippets/server-base.conf
    test ! -L /config/nginx/http.d/geoip2.conf
    test ! -e /config/nginx/snippets/resolver.conf.sample
    test ! -e /config/nginx/snippets/static-assets.conf.sample
    test ! -e /config/nginx/templates
    test -f /defaults/runtime/nginx/crowdsec.conf
    test ! -e /config/nginx/snippets/resolver.conf
    grep -q "^resolver " /run/nginx/resolver.conf
    grep -Fq "Generated from the container" /run/nginx/resolver.conf
    test -f /run/nginx/http.d/crowdsec.conf
    test ! -e /config/nginx/http.d/crowdsec.conf
    test "$((0$(stat -c %a /config/nginx/nginx.conf) & 0020))" -ne 0
'

QUIC_HOST_KEY_SHA256="$(docker exec "${TARGET}" sha256sum \
    /config/keys/quic_host.key | awk '{print $1}')"
TLS_CERT_SHA256="$(docker exec "${TARGET}" sha256sum \
    /config/keys/cert.crt | awk '{print $1}')"
docker exec "${TARGET}" sh -c '
    test "$(stat -c %a /config/keys/quic_host.key)" = 600
    test "$(wc -c < /config/keys/quic_host.key)" = 32
    test "$(stat -c %a /config/keys/cert.crt)" = 600
    test "$(stat -c %a /config/keys/cert.key)" = 600
    openssl x509 -in /config/keys/cert.crt -noout -checkend 1
'

echo "Checking runtime secret paths and LinuxServer secret-file conventions..."
docker exec "${TARGET}" sh -c '
    test "$(stat -c %a /run/GeoIP.conf)" = 600
    test "$(stat -c %a /run/crowdsec/crowdsec-nginx-bouncer.conf)" = 600
    grep -q "^AccountID file-account$" /run/GeoIP.conf
    grep -q "^LicenseKey file-license$" /run/GeoIP.conf
    grep -q "^EditionIDs GeoLite2-Country$" /run/GeoIP.conf
    grep -q "^API_KEY=test-api-key$" /run/crowdsec/crowdsec-nginx-bouncer.conf
    test -f /run/nginx/http.d/crowdsec.conf
    test ! -e /etc/GeoIP.conf
    test -f /config/geoip/GeoLite2-Country.mmdb
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
RESPONSE_HEADERS="$(docker exec "${TARGET}" curl -sk --http2 -D - -o /dev/null \
    https://127.0.0.1:8443/)"
grep -Fiq 'X-Content-Type-Options: nosniff' <<< "${RESPONSE_HEADERS}" ||
    fail "X-Content-Type-Options response header missing"
grep -Fiq 'Referrer-Policy: strict-origin-when-cross-origin' <<< "${RESPONSE_HEADERS}" ||
    fail "Referrer-Policy response header missing"
grep -Fiq 'Strict-Transport-Security: max-age=63072000' <<< "${RESPONSE_HEADERS}" ||
    fail "HSTS response header missing"
grep -Fiq 'X-Integration-Location: true' <<< "${RESPONSE_HEADERS}" ||
    fail "location response header missing"

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
    'cp /config/nginx/snippets/hsts.conf /config/nginx/snippets/hsts.conf.override
     rm /config/nginx/snippets/hsts.conf
     mv /config/nginx/snippets/hsts.conf.override /config/nginx/snippets/hsts.conf
     printf "\\n# integration-persistence-marker\\n" >> /config/nginx/snippets/hsts.conf
     cat > /config/nginx/snippets/resolver-override.conf <<EOF
## User-managed resolver override
resolver 127.0.0.1 ipv6=off valid=30s;
resolver_timeout 1s;
EOF'

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
wait_healthy "${PERSISTED_TARGET}"
docker exec "${PERSISTED_TARGET}" grep -Fq \
    '# integration-persistence-marker' /config/nginx/snippets/hsts.conf ||
    fail "persisted configuration was overwritten"
docker exec "${PERSISTED_TARGET}" test ! -L /config/nginx/snippets/hsts.conf ||
    fail "user override was replaced by a default symlink"
docker exec "${PERSISTED_TARGET}" sh -c \
    '[ "$(readlink /config/nginx/snippets/server-base.conf)" = /defaults/nginx/snippets/server-base.conf ]' ||
    fail "immutable default symlink was not retained"
docker exec "${PERSISTED_TARGET}" cmp -s \
    /config/nginx/snippets/resolver-override.conf /run/nginx/resolver.conf ||
    fail "persistent resolver override was not installed into the runtime config"
[ "$(docker exec "${PERSISTED_TARGET}" sha256sum \
    /config/keys/quic_host.key | awk '{print $1}')" = "${QUIC_HOST_KEY_SHA256}" ] ||
    fail "QUIC host key changed after container replacement"
[ "$(docker exec "${PERSISTED_TARGET}" sha256sum \
    /config/keys/cert.crt | awk '{print $1}')" = "${TLS_CERT_SHA256}" ] ||
    fail "generated TLS certificate changed after container replacement"
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
            sh -c 'mkdir -p /config/geoip && : > /config/geoip/GeoLite2-Country.mmdb'
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

    if [ "${scenario}" = cached ]; then
        wait_running "${container}"
        wait_healthy "${container}"
        wait_for_log "${container}" "${expected_log}"
        docker stop -t 10 "${container}" >/dev/null
    else
        wait_stopped "${container}"
        wait_for_log "${container}" "${expected_log}"
        [ "$(docker inspect -f '{{.State.ExitCode}}' "${container}")" -ne 0 ] ||
            fail "${container} exited successfully without its initial GeoIP database"
    fi
}

echo "Checking GeoIPUpdate failure paths..."
test_geo_failure missing \
    'ERROR: Unable to bootstrap the configured GeoIP database.'
test_geo_failure cached \
    'WARNING: GeoIPUpdate failed; retaining the existing database.'

test_init_failure() {
    local scenario="$1"
    local expected_log="$2"
    shift 2
    local volume="${PREFIX}-init-failure-${scenario}"
    local container="${PREFIX}-init-failure-${scenario}"

    new_volume "${volume}"
    CONTAINERS+=("${container}")
    docker run -d \
        --name "${container}" \
        --read-only \
        --tmpfs /run:exec \
        --tmpfs /tmp \
        -v "${volume}:/config" \
        -v "${TEST_ROOT}/secrets:/run/secrets:ro" \
        "$@" \
        "${IMAGE}" >/dev/null
    wait_stopped "${container}"
    wait_for_log "${container}" "${expected_log}"
    [ "$(docker inspect -f '{{.State.ExitCode}}' "${container}")" -ne 0 ] ||
        fail "${container} exited successfully after invalid startup configuration"
}

echo "Checking unsupported legacy secret-file variables..."
test_init_failure legacy-geoip-file \
    'GEOIPUPDATE_ACCOUNT_ID and GEOIPUPDATE_LICENSE_KEY must both be set' \
    -e GEOIPUPDATE_ACCOUNT_ID=test-account \
    -e GEOIPUPDATE_LICENSE_KEY_FILE=/run/secrets/maxmind_license
test_init_failure legacy-crowdsec-file \
    'CROWDSEC_NGINX_API_KEY and CROWDSEC_LAPI_URL must both be set' \
    -e CROWDSEC_NGINX_API_KEY_FILE=/run/secrets/crowdsec_api_key \
    -e CROWDSEC_LAPI_URL=http://crowdsec.invalid:8080

echo "Checking partial feature configuration..."
test_init_failure partial-geoip-account \
    'GEOIPUPDATE_ACCOUNT_ID and GEOIPUPDATE_LICENSE_KEY must both be set' \
    -e GEOIPUPDATE_ACCOUNT_ID=test-account
test_init_failure partial-geoip-license \
    'GEOIPUPDATE_ACCOUNT_ID and GEOIPUPDATE_LICENSE_KEY must both be set' \
    -e GEOIPUPDATE_LICENSE_KEY=test-license
test_init_failure partial-crowdsec-key \
    'CROWDSEC_NGINX_API_KEY and CROWDSEC_LAPI_URL must both be set' \
    -e CROWDSEC_NGINX_API_KEY=test-key
test_init_failure partial-crowdsec-url \
    'CROWDSEC_NGINX_API_KEY and CROWDSEC_LAPI_URL must both be set' \
    -e CROWDSEC_LAPI_URL=http://crowdsec.invalid:8080

echo "Checking obsolete CrowdSec include handling..."
CROWDSEC_COLLISION_VOLUME="${PREFIX}-crowdsec-collision"
CROWDSEC_COLLISION_TARGET="${PREFIX}-crowdsec-collision"
new_volume "${CROWDSEC_COLLISION_VOLUME}"
bootstrap_config "${CROWDSEC_COLLISION_VOLUME}"
docker run --rm -v "${CROWDSEC_COLLISION_VOLUME}:/config" "${HELPER_IMAGE}" \
    sh -c 'printf "%s\n" "# user-managed-crowdsec-marker" > /config/nginx/http.d/crowdsec.conf'
CONTAINERS+=("${CROWDSEC_COLLISION_TARGET}")
docker run -d \
    --name "${CROWDSEC_COLLISION_TARGET}" \
    --read-only \
    --tmpfs /run:exec \
    --tmpfs /tmp \
    -e CROWDSEC_NGINX_API_KEY=test-key \
    -e CROWDSEC_LAPI_URL=http://crowdsec.invalid:8080 \
    -v "${CROWDSEC_COLLISION_VOLUME}:/config" \
    "${IMAGE}" >/dev/null
wait_stopped "${CROWDSEC_COLLISION_TARGET}"
wait_for_log "${CROWDSEC_COLLISION_TARGET}" \
    'Remove the obsolete /config/nginx/http.d/crowdsec.conf before enabling CrowdSec'
[ "$(docker inspect -f '{{.State.ExitCode}}' "${CROWDSEC_COLLISION_TARGET}")" -ne 0 ] ||
    fail "${CROWDSEC_COLLISION_TARGET} exited successfully after a CrowdSec include collision"
docker run --rm -v "${CROWDSEC_COLLISION_VOLUME}:/config" "${HELPER_IMAGE}" \
    grep -Fq '# user-managed-crowdsec-marker' /config/nginx/http.d/crowdsec.conf ||
    fail "user-managed CrowdSec include was removed"

echo "Checking TLS key-generation failure handling..."
KEYGEN_FAILURE_VOLUME="${PREFIX}-keygen-failure"
KEYGEN_FAILURE_TARGET="${PREFIX}-keygen-failure"
new_volume "${KEYGEN_FAILURE_VOLUME}"
docker run --rm -v "${KEYGEN_FAILURE_VOLUME}:/config" "${HELPER_IMAGE}" \
    sh -c 'mkdir -p /config/keys/cert.crt'
CONTAINERS+=("${KEYGEN_FAILURE_TARGET}")
docker run -d \
    --name "${KEYGEN_FAILURE_TARGET}" \
    --read-only \
    --tmpfs /run:exec \
    --tmpfs /tmp \
    -v "${KEYGEN_FAILURE_VOLUME}:/config" \
    "${IMAGE}" >/dev/null
wait_stopped "${KEYGEN_FAILURE_TARGET}"
wait_for_log "${KEYGEN_FAILURE_TARGET}" \
    'ERROR: Unable to remove incomplete TLS certificate files.'
[ "$(docker inspect -f '{{.State.ExitCode}}' "${KEYGEN_FAILURE_TARGET}")" -ne 0 ] ||
    fail "${KEYGEN_FAILURE_TARGET} exited successfully after TLS key generation failed"

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
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges=true \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --tmpfs /run:exec,uid=1000,gid=1000 \
    --tmpfs /tmp:uid=1000,gid=1000 \
    -e TZ=Etc/UTC \
    -e UMASK=002 \
    -e GEOIPUPDATE_ACCOUNT_ID=file-account \
    -e GEOIPUPDATE_LICENSE_KEY=file-license \
    -v "${NONROOT_VOLUME}:/config" \
    -v "${TEST_ROOT}/geoip-success:/usr/local/bin/geoipupdate:ro" \
    "${IMAGE}" >/dev/null
wait_running "${NONROOT_TARGET}"
wait_healthy "${NONROOT_TARGET}"
wait_for_log "${NONROOT_TARGET}" 'nginx: configuration file /etc/nginx/nginx.conf test is successful'
wait_for_log "${NONROOT_TARGET}" 'GeoIPUpdate completed successfully.'
[ "$(docker inspect -f '{{.Config.User}}' "${NONROOT_TARGET}")" = 1000:1000 ] ||
    fail "non-root user was not applied"
[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${NONROOT_TARGET}")" = true ] ||
    fail "read-only root filesystem was not applied"
docker inspect -f '{{json .HostConfig.CapDrop}}' "${NONROOT_TARGET}" | grep -Fqi 'ALL' ||
    fail "capability drop was not applied"
docker inspect -f '{{json .HostConfig.SecurityOpt}}' "${NONROOT_TARGET}" | grep -Fqi 'no-new-privileges' ||
    fail "no-new-privileges was not applied"
docker exec "${NONROOT_TARGET}" nginx -t -e stderr
docker exec "${NONROOT_TARGET}" test -f /config/geoip/GeoLite2-Country.mmdb
docker stop -t 10 "${NONROOT_TARGET}" >/dev/null

echo "Integration verification passed."
