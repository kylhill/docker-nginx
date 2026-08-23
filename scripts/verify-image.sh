#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-docker-nginx:verify}"
CONTAINER="${CONTAINER:-docker-nginx-verify-$$}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
PLATFORM="${PLATFORM:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-\\[(emerg|alert|crit|error)\\]|^ERROR:|^FATAL:}"
KEEP_CONTAINER="${KEEP_CONTAINER:-0}"

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$(mktemp -d)"
NETWORK="${CONTAINER}-network"
LOG_FILE="$(mktemp)"

cleanup() {
    if [ "${KEEP_CONTAINER}" != "1" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    fi
    rm -rf "${CONFIG_DIR}"
    rm -f "${LOG_FILE}"
}
trap cleanup EXIT

cp -a "${REPOSITORY_ROOT}/tests/fixtures/config/." "${CONFIG_DIR}/"

if [ "${SKIP_BUILD}" != "1" ]; then
    echo "Building ${IMAGE} from ${DOCKERFILE}..."
    if [ -n "${PLATFORM}" ]; then
        docker buildx build \
            --load \
            --platform "${PLATFORM}" \
            --pull \
            -t "${IMAGE}" \
            -f "${DOCKERFILE}" \
            "${BUILD_CONTEXT}"
    else
        docker build -t "${IMAGE}" -f "${DOCKERFILE}" "${BUILD_CONTEXT}"
    fi
else
    echo "Using prebuilt image ${IMAGE}."
fi

docker network create "${NETWORK}" >/dev/null

echo "Starting ${CONTAINER} with externally managed configuration..."
RUN_ARGS=()
if [ -n "${PLATFORM}" ]; then
    RUN_ARGS+=(--platform "${PLATFORM}")
fi

docker run -d \
    --name "${CONTAINER}" \
    --network "${NETWORK}" \
    --read-only \
    --tmpfs /run:exec \
    --tmpfs /tmp \
    -v "${CONFIG_DIR}:/config:ro" \
    "${RUN_ARGS[@]}" \
    "${IMAGE}" >/dev/null

echo "Waiting for the image health check..."
for ((i = 0; i < 30; i++)); do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" != "true" ]; then
        echo "Container exited before becoming healthy." >&2
        docker logs "${CONTAINER}" >&2 || true
        exit 1
    fi
    HEALTH_STATUS="$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || true)"
    if [ "${HEALTH_STATUS}" = healthy ]; then
        break
    fi
    sleep 1
done
[ "${HEALTH_STATUS:-}" = healthy ] || {
    echo "Container did not become healthy; status: ${HEALTH_STATUS:-missing}" >&2
    docker inspect -f '{{json .State.Health}}' "${CONTAINER}" >&2 || true
    exit 1
}

echo "Validating the external nginx configuration..."
docker exec "${CONTAINER}" nginx \
    -c /config/nginx/nginx.conf \
    -e stderr \
    -g 'pid /run/nginx.pid;' \
    -t

echo "Checking nginx is the container init process..."
docker exec "${CONTAINER}" sh -c \
    'test "$(cat /proc/1/comm)" = nginx'

echo "Checking CrowdSec Lua modules can be loaded..."
docker exec "${CONTAINER}" sh -lc 'cat > /tmp/crowdsec-lua-load-test.conf <<'"'"'EOF'"'"'
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

docker logs "${CONTAINER}" >"${LOG_FILE}" 2>&1 || true
if grep -Eiq "${LOG_ERROR_REGEX}" "${LOG_FILE}"; then
    echo "Container logs matched error regex: ${LOG_ERROR_REGEX}" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi

echo "Checking graceful PID 1 shutdown..."
docker stop -t 10 "${CONTAINER}" >/dev/null
[ "$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")" = 0 ] || {
    echo "Container did not stop cleanly." >&2
    exit 1
}

echo "Smoke verification passed."
