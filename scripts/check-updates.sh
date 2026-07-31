#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${REPOSITORY_ROOT}/Dockerfile"
WORKFLOW_DIR="${REPOSITORY_ROOT}/.github/workflows"
PATCH_FILE="${REPOSITORY_ROOT}/patches/crowdsec-lua.patch"
MODE=--check
FORMAT=text
SKIP_APK_CHECK="${SKIP_APK_CHECK:-0}"
PUBLISHED_IMAGE="${PUBLISHED_IMAGE:-ghcr.io/kylhill/docker-nginx:latest}"

while (($#)); do
    case "$1" in
        --check | --update) MODE="$1" ;;
        --format)
            shift
            FORMAT="${1:-}"
            ;;
        *)
            echo "Usage: $0 [--check|--update] [--format text|json|markdown]" >&2
            exit 2
            ;;
    esac
    shift
done

case "${FORMAT}" in
    text | json | markdown) ;;
    *) echo "Unsupported format: ${FORMAT}" >&2; exit 2 ;;
esac

for command in curl docker grep jq patch sed sha256sum sort tar; do
    command -v "${command}" >/dev/null || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done
"${REPOSITORY_ROOT}/scripts/verify-pins.sh"

TEMP_DIR="$(mktemp -d)"
RECORDS_FILE="${TEMP_DIR}/records.tsv"
touch "${RECORDS_FILE}"
declare -a REPLACEMENT_FILES=()
declare -a REPLACEMENT_SEARCHES=()
declare -a REPLACEMENT_VALUES=()
mapfile -d '' WORKFLOW_FILES < <(
    find "${WORKFLOW_DIR}" -type f \
        \( -name '*.yml' -o -name '*.yaml' \) -print0 | sort -z
)
((${#WORKFLOW_FILES[@]} > 0)) || {
    echo "No GitHub Actions workflows found." >&2
    exit 1
}
cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

CURL_ARGS=(
    --fail
    --silent
    --show-error
    --location
    --retry 5
    --retry-all-errors
    --retry-delay 2
    --retry-max-time 60
    --connect-timeout 15
)
GITHUB_CURL_ARGS=("${CURL_ARGS[@]}")
GITHUB_CURL_ARGS+=(
    --header "Accept: application/vnd.github+json"
    --header "X-GitHub-Api-Version: 2026-03-10"
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GITHUB_CURL_ARGS+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

latest_github_tag_version() {
    local repository="$1"
    local body count page=1
    local tags_file="${TEMP_DIR}/github-tags-${repository//\//_}"
    : > "${tags_file}"

    while :; do
        body="$(curl "${GITHUB_CURL_ARGS[@]}" \
            "https://api.github.com/repos/${repository}/tags?per_page=100&page=${page}")"
        count="$(jq 'length' <<< "${body}")"
        jq -r '.[].name' <<< "${body}" >> "${tags_file}"
        ((count == 100)) || break
        ((page++))
    done

    sed -nE '/^v?[0-9]+(\.[0-9]+){1,3}$/p' "${tags_file}" \
        | awk '{ normalized = $0; sub(/^v/, "", normalized); print normalized "\t" $0 }' \
        | sort -t $'\t' -k1,1V \
        | tail -n1 | cut -f2
}

latest_github_version() {
    local repository="$1"
    local strategy="$2"
    local body latest='' cache_file

    case "${strategy}" in
        release)
            if body="$(curl "${GITHUB_CURL_ARGS[@]}" \
                "https://api.github.com/repos/${repository}/releases/latest")"; then
                latest="$(jq -er '
                    .tag_name
                    | select(test("^v?[0-9]+(\\.[0-9]+){1,3}$"))
                ' <<< "${body}")" || true
                if [[ -n "${latest}" ]]; then
                    cache_file="${TEMP_DIR}/release-${repository//\//_}-${latest}.json"
                    printf '%s\n' "${body}" > "${cache_file}"
                fi
            fi
            ;;
        tags) latest="$(latest_github_tag_version "${repository}")" ;;
        *) echo "Unknown GitHub version source strategy: ${strategy}" >&2; exit 2 ;;
    esac
    [[ -n "${latest}" ]] || {
        echo "Unable to find a stable ${strategy} version for ${repository}." >&2
        exit 1
    }
    printf '%s\n' "${latest}"
}

resolve_tag_sha() {
    local repository="$1"
    local tag="$2"
    local sha

    sha="$(curl "${GITHUB_CURL_ARGS[@]}" \
        "https://api.github.com/repos/${repository}/commits/${tag}" \
        | jq -er '.sha')"
    [[ "${sha}" =~ ^[a-f0-9]{40}$ ]] || {
        echo "Unable to resolve ${repository}@${tag} to a commit." >&2
        exit 1
    }
    printf '%s\n' "${sha}"
}

assert_not_downgrade() {
    local name="$1" current="${2#v}" latest="${3#v}" oldest
    [[ "${current}" == "${latest}" ]] && return 0
    oldest="$(printf '%s\n%s\n' "${current}" "${latest}" | sort -V | head -n1)"
    [[ "${oldest}" != "${latest}" ]] || {
        echo "Refusing to downgrade ${name} from ${current} to ${latest}." >&2
        exit 1
    }
}

image_digest() {
    local image_ref="$1" digest
    [[ "${image_ref}" != *$'\n'* && "${image_ref}" == *:* ]] || {
        echo "Invalid image reference generated for update check: ${image_ref}" >&2
        exit 1
    }
    if ! digest="$(docker buildx imagetools inspect "${image_ref}" \
        --format '{{json .Manifest}}' | jq -er '.digest')"; then
        echo "Unable to inspect image pin: ${image_ref}" >&2
        return 1
    fi
    [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || {
        echo "Registry returned an invalid digest for ${image_ref}: ${digest}" >&2
        return 1
    }
    printf '%s\n' "${digest}"
}

record() {
    local kind="$1" name="$2" current="$3" latest="$4"
    local status=current
    [[ "${current}" == "${latest}" ]] || status=update
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${kind}" "${name}" "${current}" "${latest}" "${status}" \
        >> "${RECORDS_FILE}"
}

queue_replacement() {
    local search="$1" replacement="$2" file found=false
    shift 2
    [[ "${search}" != *$'\n'* && "${replacement}" != *$'\n'* ]] || {
        echo "Refusing to replace a multiline value." >&2
        exit 1
    }
    for file in "$@"; do
        if grep -Fq -- "${search}" "${file}"; then
            found=true
            REPLACEMENT_FILES+=("${file}")
            REPLACEMENT_SEARCHES+=("${search}")
            REPLACEMENT_VALUES+=("${replacement}")
        fi
    done
    [[ "${found}" == true ]] || {
        echo "Unable to find the exact value to replace: ${search}" >&2
        exit 1
    }
}

apply_replacements() {
    [[ "${MODE}" == --update ]] || return 0
    local index file search replacement escaped_search escaped_replacement
    for index in "${!REPLACEMENT_FILES[@]}"; do
        file="${REPLACEMENT_FILES[index]}"
        search="${REPLACEMENT_SEARCHES[index]}"
        replacement="${REPLACEMENT_VALUES[index]}"
        grep -Fq -- "${search}" "${file}" || {
            echo "Planned value disappeared before apply: ${search}" >&2
            exit 1
        }
        escaped_search="$(printf '%s' "${search}" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
        escaped_replacement="$(printf '%s' "${replacement}" | sed 's/[&|\\]/\\&/g')"
        sed -i -E "s|${escaped_search}|${escaped_replacement}|g" "${file}"
    done
}

dockerfile_arg() {
    sed -nE "s/^ARG $1=//p" "${DOCKERFILE}"
}

latest_linuxserver_tag() {
    local token body count last_tag
    local -a query
    local tags_file="${TEMP_DIR}/linuxserver-tags"
    : > "${tags_file}"
    token="$(curl "${CURL_ARGS[@]}" \
        'https://ghcr.io/token?scope=repository:linuxserver/baseimage-alpine:pull' \
        | jq -er '.token')"

    last_tag=
    while :; do
        query=(--data-urlencode 'n=1000')
        [[ -z "${last_tag}" ]] || query+=(--data-urlencode "last=${last_tag}")
        body="$(curl "${CURL_ARGS[@]}" --get \
            --header "Authorization: Bearer ${token}" \
            "${query[@]}" \
            'https://ghcr.io/v2/linuxserver/baseimage-alpine/tags/list')"
        jq -r '.tags[]' <<< "${body}" >> "${tags_file}"
        count="$(jq '.tags | length' <<< "${body}")"
        ((count == 1000)) || break
        last_tag="$(jq -er '.tags[-1]' <<< "${body}")"
    done

    sed -nE '/^[0-9]+\.[0-9]+$/p' "${tags_file}" \
        | sort -V | tail -n1
}

update_action_pins() {
    local line repository current_sha current_tag latest_tag latest_sha
    local suffix comment_prefix updated_line
    while IFS= read -r line; do
        repository="$(sed -E 's|.*uses:[[:space:]]*([^@[:space:]]+)@.*|\1|' <<<"${line}")"
        current_sha="$(sed -E 's|.*@([a-f0-9]{40}).*|\1|' <<<"${line}")"
        current_tag="$(sed -nE 's|.*#[[:space:]]*([^[:space:]]+).*|\1|p' <<<"${line}")"
        [[ -n "${current_tag}" ]] || {
            echo "Action pin has no version comment: ${line}" >&2
            exit 1
        }
        latest_tag="$(latest_github_version "${repository}" release)"
        assert_not_downgrade "${repository}" "${current_tag}" "${latest_tag}"
        latest_sha="$(resolve_tag_sha "${repository}" "${latest_tag}")"
        record action "${repository}" "${current_tag}@${current_sha}" "${latest_tag}@${latest_sha}"
        if [[ "${MODE}" == --update ]] &&
            [[ "${current_tag}@${current_sha}" != "${latest_tag}@${latest_sha}" ]]; then
            suffix="${line#*"${repository}@${current_sha}"}"
            [[ "${suffix}" == *"${current_tag}" ]] || {
                echo "Unable to preserve Action pin formatting: ${line}" >&2
                exit 1
            }
            comment_prefix="${suffix%"${current_tag}"}"
            updated_line="${line%%"${repository}@${current_sha}"*}"
            updated_line+="${repository}@${latest_sha}${comment_prefix}${latest_tag}"
            queue_replacement "${line}" "${updated_line}" "${WORKFLOW_FILES[@]}"
        fi
    done < <(grep -hE 'uses:[[:space:]]+[^./][^@[:space:]]+@[a-f0-9]{40}' \
        "${WORKFLOW_FILES[@]}" | sort -u)
}

update_release_version() {
    local name="$1" repository="$2" variable="$3" strategy="$4"
    local current latest normalized
    current="$(dockerfile_arg "${variable}")"
    latest="$(latest_github_version "${repository}" "${strategy}")"
    normalized="${latest#v}"
    assert_not_downgrade "${name}" "${current}" "${normalized}"
    record release "${name}" "${current}" "${normalized}"
    if [[ "${MODE}" == --update && "${current}" != "${normalized}" ]]; then
        queue_replacement "ARG ${variable}=${current}" \
            "ARG ${variable}=${normalized}" "${DOCKERFILE}"
    fi
    printf '%s\n' "${normalized}"
}

update_buildx() {
    local current latest
    current="$(sed -nE 's/^[[:space:]]*BUILDX_VERSION:[[:space:]]*//p' \
        "${WORKFLOW_FILES[@]}" | sort -u)"
    [[ "$(wc -l <<<"${current}")" -eq 1 ]] || {
        echo "BUILDX_VERSION pins are inconsistent." >&2
        exit 1
    }
    latest="$(latest_github_version docker/buildx release)"
    assert_not_downgrade docker/buildx "${current}" "${latest}"
    record release docker/buildx "${current}" "${latest}"
    if [[ "${MODE}" == --update && "${current}" != "${latest}" ]]; then
        queue_replacement "BUILDX_VERSION: ${current}" \
            "BUILDX_VERSION: ${latest}" "${WORKFLOW_FILES[@]}"
    fi
}

update_image_pin() {
    local name="$1" source_repository="$2" tag_template="$3"
    local current_ref current_tag current_digest release_tag latest_tag latest_digest latest_ref
    current_ref="$(grep -hEo \
        "${name}:[^[:space:]]+@sha256:[a-f0-9]{64}" \
        "${WORKFLOW_FILES[@]}" | sort -u)"
    [[ -n "${current_ref}" && "$(wc -l <<<"${current_ref}")" -eq 1 ]] || {
        echo "Missing or inconsistent image pin for ${name}." >&2
        exit 1
    }
    current_tag="${current_ref#"${name}":}"
    current_tag="${current_tag%@sha256:*}"
    current_digest="sha256:${current_ref##*@sha256:}"
    case "${tag_template}" in
        release)
            release_tag="$(latest_github_version "${source_repository}" release)"
            latest_tag="${release_tag}"
            assert_not_downgrade "${name}" "${current_tag}" "${latest_tag}"
            ;;
        release-no-v)
            release_tag="$(latest_github_version "${source_repository}" release)"
            latest_tag="${release_tag#v}"
            assert_not_downgrade "${name}" "${current_tag}" "${latest_tag}"
            ;;
        release-debian)
            release_tag="$(latest_github_version "${source_repository}" release)"
            latest_tag="${release_tag}-debian"
            assert_not_downgrade "${name}" \
                "${current_tag%-debian}" "${release_tag}"
            ;;
        *) echo "Unknown image tag template: ${tag_template}" >&2; exit 1 ;;
    esac
    latest_digest="$(image_digest "${name}:${latest_tag}")"
    latest_ref="${name}:${latest_tag}@${latest_digest}"
    record image "${name}" "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update && "${current_ref}" != "${latest_ref}" ]]; then
        queue_replacement "${current_ref}" "${latest_ref}" "${WORKFLOW_FILES[@]}"
    fi
}

update_base_image() {
    local current_ref current_tag current_digest latest_tag latest_digest latest_ref
    current_ref="$(dockerfile_arg BASE_IMAGE)"
    [[ "${current_ref}" == ghcr.io/linuxserver/baseimage-alpine:*@sha256:* ]] || {
        echo "BASE_IMAGE is not pinned by tag and digest." >&2
        exit 1
    }
    current_tag="${current_ref#ghcr.io/linuxserver/baseimage-alpine:}"
    current_tag="${current_tag%@sha256:*}"
    current_digest="sha256:${current_ref##*@sha256:}"
    latest_tag="$(latest_linuxserver_tag)"
    LATEST_BASE_IMAGE_TAG="${latest_tag}"
    assert_not_downgrade ghcr.io/linuxserver/baseimage-alpine \
        "${current_tag}" "${latest_tag}"
    latest_digest="$(image_digest "ghcr.io/linuxserver/baseimage-alpine:${latest_tag}")"
    latest_ref="ghcr.io/linuxserver/baseimage-alpine:${latest_tag}@${latest_digest}"
    record image ghcr.io/linuxserver/baseimage-alpine \
        "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update && "${current_ref}" != "${latest_ref}" ]]; then
        queue_replacement "ARG BASE_IMAGE=${current_ref}" \
            "ARG BASE_IMAGE=${latest_ref}" "${DOCKERFILE}"
    fi
}

latest_alpine_package_version() {
    local branch="$1" repository="$2" package="$3"
    local arch archive version
    local versions_file="${TEMP_DIR}/alpine-${package}-versions"
    : > "${versions_file}"

    for arch in x86_64 aarch64; do
        archive="${TEMP_DIR}/alpine-${branch}-${repository}-${arch}.tar.gz"
        curl "${CURL_ARGS[@]}" --output "${archive}" \
            "https://dl-cdn.alpinelinux.org/alpine/v${branch}/${repository}/${arch}/APKINDEX.tar.gz"
        version="$(tar -xOzf "${archive}" APKINDEX | awk -v package="${package}" '
            BEGIN { RS = ""; FS = "\n" }
            {
                name = version = ""
                for (field = 1; field <= NF; field++) {
                    if ($field == "P:" package) name = package
                    if ($field ~ /^V:/) version = substr($field, 3)
                }
                if (name == package && version != "") {
                    print version
                    exit
                }
            }
        ')"
        [[ -n "${version}" ]] || {
            echo "Unable to find ${package} for Alpine ${branch}/${repository}/${arch}." >&2
            exit 1
        }
        printf '%s\n' "${version}" >> "${versions_file}"
    done

    version="$(sort -u "${versions_file}")"
    [[ "$(wc -l <<< "${version}")" -eq 1 ]] || {
        echo "Alpine package versions differ by architecture for ${package}:" >&2
        cat "${versions_file}" >&2
        exit 1
    }
    printf '%s\n' "${version}"
}

update_alpine_package_version() {
    local package="$1" variable="$2" repository="$3"
    local current latest
    current="$(dockerfile_arg "${variable}")"
    latest="$(latest_alpine_package_version \
        "${LATEST_BASE_IMAGE_TAG}" "${repository}" "${package}")"
    assert_not_downgrade "${package}" "${current}" "${latest}"
    record apk "${package}" "${current}" "${latest}"
    if [[ "${MODE}" == --update && "${current}" != "${latest}" ]]; then
        queue_replacement "ARG ${variable}=${current}" \
            "ARG ${variable}=${latest}" "${DOCKERFILE}"
    fi
}

update_dockerfile_frontend() {
    local line current_tag current_digest latest_tag latest_digest
    line="$(head -n1 "${DOCKERFILE}")"
    [[ "${line}" =~ ^#[[:space:]]syntax=docker/dockerfile:([0-9]+)@sha256:([a-f0-9]{64})$ ]] || {
        echo "Dockerfile syntax frontend is not pinned." >&2
        exit 1
    }
    current_tag="${BASH_REMATCH[1]}"
    current_digest="sha256:${BASH_REMATCH[2]}"
    latest_tag="${current_tag}"
    latest_digest="$(image_digest "docker/dockerfile:${latest_tag}")"
    record image docker/dockerfile \
        "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update ]] &&
        [[ "${current_tag}@${current_digest}" != "${latest_tag}@${latest_digest}" ]]; then
        queue_replacement "${line}" \
            "# syntax=docker/dockerfile:${latest_tag}@${latest_digest}" "${DOCKERFILE}"
    fi
}

download() {
    curl "${GITHUB_CURL_ARGS[@]}" "$1" --output "$2"
}

checksum() {
    sha256sum "$1" | awk '{print $1}'
}

github_release_asset_checksum() {
    local repository="$1" tag="$2" asset_name="$3"
    local cache_file digest
    cache_file="${TEMP_DIR}/release-${repository//\//_}-${tag}.json"
    if [[ ! -s "${cache_file}" ]]; then
        curl "${GITHUB_CURL_ARGS[@]}" \
            "https://api.github.com/repos/${repository}/releases/tags/${tag}" \
            --output "${cache_file}" || return 1
    fi
    digest="$(jq -er --arg name "${asset_name}" '
        .assets[]
        | select(.name == $name)
        | .digest
        | select(type == "string")
    ' "${cache_file}")" || return 1
    [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "${digest#sha256:}"
}

release_asset_checksum() {
    local repository="$1" tag="$2" asset_name="$3" url="$4" archive="$5"
    local digest
    if digest="$(github_release_asset_checksum \
        "${repository}" "${tag}" "${asset_name}")"; then
        printf '%s\n' "${digest}"
        return 0
    fi
    echo "Release digest unavailable for ${repository}/${asset_name}; downloading asset." >&2
    download "${url}" "${archive}"
    checksum "${archive}"
}

update_release_checksums() {
    local geoip_version="$1" crowdsec_version="$2"
    local geo_amd_archive geo_arm_archive crowdsec_archive
    local geo_amd_asset geo_arm_asset crowdsec_asset
    local geo_amd_url geo_arm_url crowdsec_url
    local geo_amd_sha geo_arm_sha crowdsec_sha source_dir extract_root
    local current_geo_amd_sha current_geo_arm_sha
    local current_crowdsec_version current_crowdsec_sha
    geo_amd_archive="${TEMP_DIR}/geoipupdate-amd64.tar.gz"
    geo_arm_archive="${TEMP_DIR}/geoipupdate-arm64.tar.gz"
    crowdsec_archive="${TEMP_DIR}/crowdsec-nginx-bouncer.tgz"

    geo_amd_asset="geoipupdate_${geoip_version}_linux_amd64.tar.gz"
    geo_arm_asset="geoipupdate_${geoip_version}_linux_arm64.tar.gz"
    crowdsec_asset=crowdsec-nginx-bouncer.tgz
    geo_amd_url="https://github.com/maxmind/geoipupdate/releases/download/v${geoip_version}/${geo_amd_asset}"
    geo_arm_url="https://github.com/maxmind/geoipupdate/releases/download/v${geoip_version}/${geo_arm_asset}"
    crowdsec_url="https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${crowdsec_version}/${crowdsec_asset}"

    geo_amd_sha="$(release_asset_checksum maxmind/geoipupdate \
        "v${geoip_version}" "${geo_amd_asset}" "${geo_amd_url}" "${geo_amd_archive}")"
    geo_arm_sha="$(release_asset_checksum maxmind/geoipupdate \
        "v${geoip_version}" "${geo_arm_asset}" "${geo_arm_url}" "${geo_arm_archive}")"
    crowdsec_sha="$(release_asset_checksum crowdsecurity/cs-nginx-bouncer \
        "v${crowdsec_version}" "${crowdsec_asset}" "${crowdsec_url}" "${crowdsec_archive}")"
    current_geo_amd_sha="$(dockerfile_arg GEOIPUPDATE_AMD64_SHA256)"
    current_geo_arm_sha="$(dockerfile_arg GEOIPUPDATE_ARM64_SHA256)"
    current_crowdsec_version="$(dockerfile_arg CROWDSEC_BOUNCER_VERSION)"
    current_crowdsec_sha="$(dockerfile_arg CROWDSEC_BOUNCER_SHA256)"
    record checksum GEOIPUPDATE_AMD64_SHA256 "${current_geo_amd_sha}" "${geo_amd_sha}"
    record checksum GEOIPUPDATE_ARM64_SHA256 "${current_geo_arm_sha}" "${geo_arm_sha}"
    record checksum CROWDSEC_BOUNCER_SHA256 "${current_crowdsec_sha}" "${crowdsec_sha}"

    if [[ "${current_crowdsec_version}" != "${crowdsec_version}" ]] ||
        [[ "${current_crowdsec_sha}" != "${crowdsec_sha}" ]]; then
        [[ -s "${crowdsec_archive}" ]] || download "${crowdsec_url}" "${crowdsec_archive}"
        extract_root="${TEMP_DIR}/crowdsec-source"
        mkdir -p "${extract_root}"
        tar -xzf "${crowdsec_archive}" -C "${extract_root}"
        source_dir="$(find "${extract_root}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
        [[ -n "${source_dir}" ]] || {
            echo "Unable to locate CrowdSec source." >&2
            exit 1
        }
        patch --dry-run --batch --forward --fuzz=0 -p1 \
            -d "${source_dir}/lua-mod/lib" < "${PATCH_FILE}" >/dev/null
    fi

    if [[ "${MODE}" == --update ]]; then
        if [[ "${current_geo_amd_sha}" != "${geo_amd_sha}" ]]; then
            queue_replacement "ARG GEOIPUPDATE_AMD64_SHA256=${current_geo_amd_sha}" \
                "ARG GEOIPUPDATE_AMD64_SHA256=${geo_amd_sha}" "${DOCKERFILE}"
        fi
        if [[ "${current_geo_arm_sha}" != "${geo_arm_sha}" ]]; then
            queue_replacement "ARG GEOIPUPDATE_ARM64_SHA256=${current_geo_arm_sha}" \
                "ARG GEOIPUPDATE_ARM64_SHA256=${geo_arm_sha}" "${DOCKERFILE}"
        fi
        if [[ "${current_crowdsec_sha}" != "${crowdsec_sha}" ]]; then
            queue_replacement "ARG CROWDSEC_BOUNCER_SHA256=${current_crowdsec_sha}" \
                "ARG CROWDSEC_BOUNCER_SHA256=${crowdsec_sha}" "${DOCKERFILE}"
        fi
    fi
}

compare_apk_and_refresh() {
    [[ "${MODE}" == --update && "${SKIP_APK_CHECK}" != 1 ]] || return 0
    local apk_report="${TEMP_DIR}/apk-report.md" current_refresh
    PUBLISHED_IMAGE="${PUBLISHED_IMAGE}" \
        "${REPOSITORY_ROOT}/scripts/compare-apk-packages.sh" > "${apk_report}"
    if grep -q '<!-- apk-updates-available:true -->' "${apk_report}"; then
        record apk floating-packages changed refresh-required
        current_refresh="$(dockerfile_arg APK_REFRESH_DATE)"
        queue_replacement "ARG APK_REFRESH_DATE=${current_refresh}" \
            "ARG APK_REFRESH_DATE=$(date -u +%F)" "${DOCKERFILE}"
    else
        record apk floating-packages current current
    fi
}

emit_report() {
    local updates
    updates="$(awk -F '\t' '$5 == "update" { count++ } END { print count + 0 }' "${RECORDS_FILE}")"
    case "${FORMAT}" in
        text)
            printf '%-10s %-48s %-82s %s\n' TYPE DEPENDENCY CURRENT LATEST
            awk -F '\t' '{ printf "%-10s %-48s %-82s %s\n", $1, $2, $3, $4 }' "${RECORDS_FILE}"
            echo "Updates available: ${updates}"
            ;;
        markdown)
            echo "<!-- updates-available:$([[ "${updates}" -gt 0 ]] && echo true || echo false) -->"
            echo "## Source-controlled dependencies"
            echo
            echo "| Type | Dependency | Current | Latest | Status |"
            echo "|---|---|---|---|---|"
            awk -F '\t' '{ printf "| `%s` | `%s` | `%s` | `%s` | %s |\n", $1, $2, $3, $4, $5 }' "${RECORDS_FILE}"
            echo
            echo "Run \`scripts/check-updates.sh --update\` locally to apply all available updates."
            ;;
        json)
            jq -Rn --argjson count "${updates}" '
                [inputs | split("\t") | {
                    type: .[0], dependency: .[1], current: .[2],
                    latest: .[3], status: .[4]
                }] | {updates_available: ($count > 0), update_count: $count, dependencies: .}
            ' < "${RECORDS_FILE}"
            ;;
    esac
}

update_action_pins
update_buildx
update_dockerfile_frontend
update_base_image
update_alpine_package_version \
    lua-resty-string LUA_RESTY_STRING_VERSION community
update_image_pin moby/buildkit moby/buildkit release
update_image_pin koalaman/shellcheck koalaman/shellcheck release
update_image_pin ghcr.io/hadolint/hadolint hadolint/hadolint release-debian
update_image_pin rhysd/actionlint rhysd/actionlint release-no-v
geoip_version="$(update_release_version \
    GeoIPUpdate maxmind/geoipupdate GEOIPUPDATE_VERSION release)"
crowdsec_version="$(update_release_version \
    CrowdSec crowdsecurity/cs-nginx-bouncer CROWDSEC_BOUNCER_VERSION tags)"
update_release_checksums "${geoip_version}" "${crowdsec_version}"
compare_apk_and_refresh
apply_replacements
emit_report
