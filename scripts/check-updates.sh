#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${REPOSITORY_ROOT}/Dockerfile"
INTEGRATION_TEST="${REPOSITORY_ROOT}/scripts/verify-integration.sh"
PATCH_FILE="${REPOSITORY_ROOT}/patches/crowdsec-lua-1.0.14.patch"
MODE="${1:---check}"

case "${MODE}" in
    --check | --update) ;;
    *)
        echo "Usage: $0 [--check|--update]" >&2
        exit 2
        ;;
esac

for command in curl jq patch sed sha256sum tar; do
    command -v "${command}" >/dev/null || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

CURL_ARGS=(--fail --silent --show-error --location)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_ARGS+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

dockerfile_arg() {
    local name="$1"
    sed -nE "s/^ARG ${name}=//p" "${DOCKERFILE}"
}

latest_github_version() {
    local repository="$1"
    curl "${CURL_ARGS[@]}" \
        "https://api.github.com/repos/${repository}/releases/latest" \
        | jq -er '.tag_name | sub("^v"; "")'
}

download() {
    local url="$1"
    local destination="$2"
    curl "${CURL_ARGS[@]}" "${url}" --output "${destination}"
}

checksum() {
    sha256sum "$1" | awk '{print $1}'
}

verify_crowdsec_patch() {
    local archive="$1"
    local extract_root="${TEMP_DIR}/crowdsec-source"
    local source_dir

    rm -rf "${extract_root}"
    mkdir -p "${extract_root}"
    tar -xzf "${archive}" -C "${extract_root}"
    source_dir="$(find "${extract_root}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "${source_dir}" ]] || {
        echo "Unable to locate extracted CrowdSec source." >&2
        exit 1
    }
    patch --dry-run --batch --forward --fuzz=0 -p1 \
        -d "${source_dir}/lua-mod/lib" < "${PATCH_FILE}" >/dev/null
}

replace_dockerfile_arg() {
    local name="$1"
    local value="$2"
    sed -i -E "s|^(ARG ${name}=).*|\\1${value}|" "${DOCKERFILE}"
}

current_geoip_version="$(dockerfile_arg GEOIPUPDATE_VERSION)"
current_geoip_amd64_sha="$(dockerfile_arg GEOIPUPDATE_AMD64_SHA256)"
current_geoip_arm64_sha="$(dockerfile_arg GEOIPUPDATE_ARM64_SHA256)"
current_crowdsec_version="$(dockerfile_arg CROWDSEC_BOUNCER_VERSION)"
current_crowdsec_sha="$(dockerfile_arg CROWDSEC_BOUNCER_SHA256)"

latest_geoip_version="$(latest_github_version maxmind/geoipupdate)"
latest_crowdsec_version="$(latest_github_version crowdsecurity/cs-nginx-bouncer)"

if [[ "${MODE}" == --update ]]; then
    target_geoip_version="${latest_geoip_version}"
    target_crowdsec_version="${latest_crowdsec_version}"
else
    target_geoip_version="${current_geoip_version}"
    target_crowdsec_version="${current_crowdsec_version}"
fi

geoip_amd64_archive="${TEMP_DIR}/geoipupdate-amd64.tar.gz"
geoip_arm64_archive="${TEMP_DIR}/geoipupdate-arm64.tar.gz"
crowdsec_archive="${TEMP_DIR}/crowdsec-nginx-bouncer.tgz"

download \
    "https://github.com/maxmind/geoipupdate/releases/download/v${target_geoip_version}/geoipupdate_${target_geoip_version}_linux_amd64.tar.gz" \
    "${geoip_amd64_archive}"
download \
    "https://github.com/maxmind/geoipupdate/releases/download/v${target_geoip_version}/geoipupdate_${target_geoip_version}_linux_arm64.tar.gz" \
    "${geoip_arm64_archive}"
download \
    "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${target_crowdsec_version}/crowdsec-nginx-bouncer.tgz" \
    "${crowdsec_archive}"

geoip_amd64_sha="$(checksum "${geoip_amd64_archive}")"
geoip_arm64_sha="$(checksum "${geoip_arm64_archive}")"
crowdsec_sha="$(checksum "${crowdsec_archive}")"
verify_crowdsec_patch "${crowdsec_archive}"

if [[ "${MODE}" == --check ]]; then
    [[ "${geoip_amd64_sha}" == "${current_geoip_amd64_sha}" ]] || {
        echo "GeoIPUpdate amd64 checksum mismatch." >&2
        exit 1
    }
    [[ "${geoip_arm64_sha}" == "${current_geoip_arm64_sha}" ]] || {
        echo "GeoIPUpdate arm64 checksum mismatch." >&2
        exit 1
    }
    [[ "${crowdsec_sha}" == "${current_crowdsec_sha}" ]] || {
        echo "CrowdSec bouncer checksum mismatch." >&2
        exit 1
    }

    echo "Pinned release checksums and the CrowdSec patch are valid."
    echo "GeoIPUpdate: ${current_geoip_version} (latest: ${latest_geoip_version})"
    echo "CrowdSec bouncer: ${current_crowdsec_version} (latest: ${latest_crowdsec_version})"
    exit 0
fi

replace_dockerfile_arg GEOIPUPDATE_VERSION "${target_geoip_version}"
replace_dockerfile_arg GEOIPUPDATE_AMD64_SHA256 "${geoip_amd64_sha}"
replace_dockerfile_arg GEOIPUPDATE_ARM64_SHA256 "${geoip_arm64_sha}"
replace_dockerfile_arg CROWDSEC_BOUNCER_VERSION "${target_crowdsec_version}"
replace_dockerfile_arg CROWDSEC_BOUNCER_SHA256 "${crowdsec_sha}"
sed -i -E \
    "s|crowdsec-nginx-bouncer/v[0-9]+\\.[0-9]+\\.[0-9]+|crowdsec-nginx-bouncer/v${target_crowdsec_version}|g" \
    "${INTEGRATION_TEST}"

echo "Updated GeoIPUpdate to ${target_geoip_version}."
echo "Updated CrowdSec bouncer to ${target_crowdsec_version}."
echo "Review the diff and run scripts/verify-image.sh and scripts/verify-integration.sh."
