#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-docker-nginx:verify}"
# The development daemon has no default bridge. Override for other builders.
BUILD_NETWORK="${BUILD_NETWORK:-host}"
TEST_CASES="${TEST_CASES:-contract,enabled,nonroot}"

build_options=()
if [ "${BUILD_NETWORK}" = host ]; then
    build_options+=(--allow network.host)
fi

echo "Building ${IMAGE} from ${REPOSITORY_ROOT}/Dockerfile..."
docker buildx build --load --pull \
    --network "${BUILD_NETWORK}" \
    "${build_options[@]}" \
    -t "${IMAGE}" -f "${REPOSITORY_ROOT}/Dockerfile" "${REPOSITORY_ROOT}"

echo "Running image verification for: ${TEST_CASES}..."
IMAGE="${IMAGE}" \
TEST_CASES="${TEST_CASES}" \
    "${REPOSITORY_ROOT}/scripts/verify-integration.sh"
