#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-docker-nginx:verify}"
DOCKERFILE="${DOCKERFILE:-${REPOSITORY_ROOT}/Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-${REPOSITORY_ROOT}}"
PLATFORM="${PLATFORM:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

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

echo "Running the core image contract checks..."
IMAGE="${IMAGE}" \
TEST_CASES=contract \
CHECK_LUA_MODULES=1 \
    "${REPOSITORY_ROOT}/scripts/verify-integration.sh"
