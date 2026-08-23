#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${REPOSITORY_ROOT}/Dockerfile"
WORKFLOW_DIR="${REPOSITORY_ROOT}/.github/workflows"
KNOWN_IMAGES='^(moby/buildkit|koalaman/shellcheck|ghcr.io/hadolint/hadolint|rhysd/actionlint):'

mapfile -d '' workflow_files < <(
    find "${WORKFLOW_DIR}" -type f \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z
)
((${#workflow_files[@]} > 0)) || {
    echo "No GitHub Actions workflows found." >&2
    exit 1
}

while IFS= read -r ref; do
    [[ "${ref}" =~ ${KNOWN_IMAGES} ]] || {
        echo "Unmanaged workflow image pin: ${ref}" >&2
        exit 1
    }
done < <(grep -hEo '[[:alnum:]./_-]+:[^[:space:]]+@sha256:[a-f0-9]{64}' \
    "${workflow_files[@]}" | sort -u)

while IFS= read -r ref; do
    [[ "${ref}" =~ @[a-f0-9]{40}$ ]] || {
        echo "External GitHub Action is not pinned to a commit SHA: ${ref}" >&2
        exit 1
    }
done < <(grep -hEo 'uses:[[:space:]]+[^./][^[:space:]]+' \
    "${workflow_files[@]}" | sed -E 's/^uses:[[:space:]]+//' | sort -u)

dockerfile_args="$(sed -nE 's/^ARG ([A-Z0-9_]+)=.*/\1/p' "${DOCKERFILE}" | sort)"
expected_dockerfile_args="$(printf '%s\n' \
    APK_REFRESH_DATE \
    BASE_IMAGE \
    CROWDSEC_BOUNCER_SHA256 \
    CROWDSEC_BOUNCER_VERSION \
    LUA_RESTY_STRING_VERSION | sort)"
[[ "${dockerfile_args}" == "${expected_dockerfile_args}" ]] || {
    echo "Dockerfile dependency ARG inventory changed; update check-updates.sh." >&2
    diff -u <(printf '%s\n' "${expected_dockerfile_args}") \
        <(printf '%s\n' "${dockerfile_args}") >&2 || true
    exit 1
}
