#!/usr/bin/env bash
set -Eeuo pipefail

# sort(1) and comm(1) must use bytewise ordering. In UTF-8 locales, sort's
# last-resort byte comparison can order collation-equivalent package names
# differently from comm, causing valid inventories to be rejected as unsorted.
export LC_ALL=C

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISHED_IMAGE="${PUBLISHED_IMAGE:-ghcr.io/kylhill/docker-nginx:latest}"
ARCHES="${ARCHES:-${APK_COMPARE_ARCHES:-}}"
TEMP_DIR="$(mktemp -d)"

cleanup() {
    docker image rm \
        docker-nginx:apk-candidate-amd64 \
        docker-nginx:apk-candidate-arm64 \
        docker-nginx:apk-published-amd64 \
        docker-nginx:apk-published-arm64 \
        >/dev/null 2>&1 || true
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

for command in docker sort comm; do
    command -v "${command}" >/dev/null || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done

if [[ -z "${ARCHES}" ]]; then
    NATIVE_ARCH="$(docker version --format '{{.Server.Arch}}')"
    case "${NATIVE_ARCH}" in
        amd64 | arm64) ;;
        x86_64) NATIVE_ARCH=amd64 ;;
        aarch64) NATIVE_ARCH=arm64 ;;
        *) echo "Unsupported Docker host architecture: ${NATIVE_ARCH}" >&2; exit 2 ;;
    esac
    ARCHES="${NATIVE_ARCH}"
fi
read -r -a ARCH_LIST <<< "${ARCHES}"
BUILDX_DETAILS="$(docker buildx inspect --bootstrap)"
for arch in "${ARCH_LIST[@]}"; do
    if ! grep -Eq "Platforms:.*linux/${arch}([,[:space:]]|$)" \
        <<< "${BUILDX_DETAILS}"; then
        echo "Buildx cannot execute linux/${arch}." >&2
        echo "Configure binfmt/QEMU or compare only the native architecture." >&2
        exit 1
    fi
done

updates=false
report="${TEMP_DIR}/report.md"
{
    echo "## Floating Alpine packages"
    echo
    echo "Fresh no-cache builds are compared with \`${PUBLISHED_IMAGE}\`."
} > "${report}"

for arch in "${ARCH_LIST[@]}"; do
    [[ "${arch}" == amd64 || "${arch}" == arm64 ]] || {
        echo "Unsupported architecture: ${arch}" >&2
        exit 2
    }
    platform="linux/${arch}"
    candidate="docker-nginx:apk-candidate-${arch}"
    published="docker-nginx:apk-published-${arch}"
    candidate_packages="${TEMP_DIR}/candidate-${arch}.txt"
    published_packages="${TEMP_DIR}/published-${arch}.txt"
    added="${TEMP_DIR}/added-${arch}.txt"
    removed="${TEMP_DIR}/removed-${arch}.txt"
    build_log="${TEMP_DIR}/build-${arch}.log"
    build_args=(
        --platform "${platform}"
        --pull
        --no-cache
        --target runtime-packages
        --load
        --tag "${candidate}"
        "${REPOSITORY_ROOT}"
    )

    if ! docker buildx build "${build_args[@]}" > "${build_log}" 2>&1; then
        if ! grep -Fq 'network bridge not found' "${build_log}"; then
            cat "${build_log}" >&2
            exit 1
        fi

        echo "Docker's default bridge is unavailable; retrying with host networking." >&2
        docker buildx build \
            --allow network.host \
            --network host \
            "${build_args[@]}" >/dev/null
    fi

    {
        echo
        echo "### \`${platform}\`"
        echo
    } >> "${report}"

    if ! docker pull --platform "${platform}" "${PUBLISHED_IMAGE}" >/dev/null; then
        updates=true
        echo "The published comparison image is unavailable." >> "${report}"
        continue
    fi

    docker tag "${PUBLISHED_IMAGE}" "${published}"
    docker run --rm --network none --platform "${platform}" --entrypoint apk \
        "${candidate}" --repositories-file /dev/null info -v \
        | sort > "${candidate_packages}"
    docker run --rm --network none --platform "${platform}" --entrypoint apk \
        "${published}" --repositories-file /dev/null info -v \
        | sort > "${published_packages}"

    comm -13 "${published_packages}" "${candidate_packages}" > "${added}"
    comm -23 "${published_packages}" "${candidate_packages}" > "${removed}"

    if [[ ! -s "${added}" && ! -s "${removed}" ]]; then
        echo "No package changes." >> "${report}"
        continue
    fi

    updates=true
    if [[ -s "${removed}" ]]; then
        {
            echo "Current-only package versions:"
            echo '```text'
            sed -n '1,100p' "${removed}"
            echo '```'
        } >> "${report}"
    fi
    if [[ -s "${added}" ]]; then
        {
            echo "Candidate package versions:"
            echo '```text'
            sed -n '1,100p' "${added}"
            echo '```'
        } >> "${report}"
    fi
done

echo "<!-- apk-updates-available:${updates} -->"
cat "${report}"
