#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-docker-nginx:verify}"
DOCKERFILE="${DOCKERFILE:-${REPOSITORY_ROOT}/Dockerfile}"
BUILD_CONTEXT="${BUILD_CONTEXT:-${REPOSITORY_ROOT}}"
# The development daemon has no default bridge. Override for other builders.
BUILD_NETWORK="${BUILD_NETWORK:-host}"
PLATFORM="${PLATFORM:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"
TEST_CASES="${TEST_CASES:-contract}"

if [ "${SKIP_BUILD}" != "1" ]; then
    echo "Building ${IMAGE} from ${DOCKERFILE}..."
    if [ -n "${PLATFORM}" ]; then
        build_allow=()
        if [ "${BUILD_NETWORK}" = host ]; then
            build_allow=(--allow network.host)
        fi
        docker buildx build \
            --load \
            --platform "${PLATFORM}" \
            --network "${BUILD_NETWORK}" \
            "${build_allow[@]}" \
            --pull \
            -t "${IMAGE}" \
            -f "${DOCKERFILE}" \
            "${BUILD_CONTEXT}"
    else
        docker build --network "${BUILD_NETWORK}" \
            -t "${IMAGE}" -f "${DOCKERFILE}" "${BUILD_CONTEXT}"
    fi
else
    echo "Using prebuilt image ${IMAGE}."
fi

echo "Running image verification for: ${TEST_CASES}..."
IMAGE="${IMAGE}" \
TEST_CASES="${TEST_CASES}" \
    "${REPOSITORY_ROOT}/scripts/verify-integration.sh"
