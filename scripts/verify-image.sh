#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${IMAGE:-docker-nginx:verify}"
CONTAINER="${CONTAINER:-docker-nginx-verify-$$}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"
PLATFORM="${PLATFORM:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"
RUN_SECONDS="${RUN_SECONDS:-8}"
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-\\b(emerg|alert|crit|fatal|error|failed)\\b}"
KEEP_CONTAINER="${KEEP_CONTAINER:-0}"

CONFIG_VOLUME="${CONFIG_VOLUME:-${CONTAINER}-config}"
LOG_FILE="$(mktemp)"

cleanup() {
    if [ "${KEEP_CONTAINER}" != "1" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        docker volume rm "${CONFIG_VOLUME}" >/dev/null 2>&1 || true
    fi
    rm -f "${LOG_FILE}"
}
trap cleanup EXIT

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

docker volume create "${CONFIG_VOLUME}" >/dev/null

echo "Starting ${CONTAINER} with temporary /config..."
RUN_ARGS=()
if [ -n "${PLATFORM}" ]; then
    RUN_ARGS+=(--platform "${PLATFORM}")
fi

docker run -d \
    --name "${CONTAINER}" \
    -v "${CONFIG_VOLUME}:/config" \
    "${RUN_ARGS[@]}" \
    "${IMAGE}" >/dev/null

for ((i = 0; i < RUN_SECONDS; i++)); do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || true)" != "true" ]; then
        echo "Container exited before smoke window completed." >&2
        docker logs "${CONTAINER}" >&2 || true
        exit 1
    fi
    sleep 1
done

echo "Validating nginx config inside running container..."
docker exec "${CONTAINER}" nginx -t -e stderr

echo "Waiting for the image health check..."
for ((i = 0; i < 30; i++)); do
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

echo "Checking CrowdSec Lua modules can be loaded during nginx startup..."
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
        require "crowdsec"
    }
}
EOF
nginx -c /tmp/crowdsec-lua-load-test.conf
nginx -c /tmp/crowdsec-lua-load-test.conf -s quit'

docker logs "${CONTAINER}" >"${LOG_FILE}" 2>&1 || true
if grep -Eiq "${LOG_ERROR_REGEX}" "${LOG_FILE}"; then
    echo "Container logs matched error regex: ${LOG_ERROR_REGEX}" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi

echo "Smoke verification passed: container stayed running for ${RUN_SECONDS}s and logs had no error matches."
