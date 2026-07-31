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

for command in curl docker git grep jq patch sed sha256sum sort tar; do
    command -v "${command}" >/dev/null || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done

if [[ "${MODE}" == --update && "${UPDATE_PREFLIGHT_DONE:-0}" != 1 ]]; then
    echo "Preflighting every update source before editing files..." >&2
    UPDATE_PREFLIGHT_DONE=1 SKIP_APK_CHECK=1 \
        "${BASH_SOURCE[0]}" --check --format text >/dev/null
fi

TEMP_DIR="$(mktemp -d)"
RECORDS_FILE="${TEMP_DIR}/records.tsv"
touch "${RECORDS_FILE}"
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
)
GITHUB_CURL_ARGS=("${CURL_ARGS[@]}")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GITHUB_CURL_ARGS+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

latest_github_version() {
    local repository="$1"
    local latest
    latest="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs \
        "https://github.com/${repository}.git" \
        | awk '{ sub("refs/tags/", "", $2); print $2 }' \
        | sed -nE '/^v?[0-9]+(\.[0-9]+){1,3}$/p' \
        | awk '{ normalized = $0; sub(/^v/, "", normalized); print normalized "\t" $0 }' \
        | sort -t $'\t' -k1,1V \
        | tail -n1 | cut -f2)"
    [[ -n "${latest}" ]] || {
        echo "Unable to find a stable release tag for ${repository}." >&2
        exit 1
    }
    printf '%s\n' "${latest}"
}

resolve_tag_sha() {
    local repository="$1"
    local tag="$2"
    local refs sha

    refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags \
        "https://github.com/${repository}.git" \
        "refs/tags/${tag}" "refs/tags/${tag}^{}")"
    sha="$(awk -v peeled="refs/tags/${tag}^{}" -v direct="refs/tags/${tag}" '
        $2 == direct { fallback = $1 }
        $2 == peeled { print $1; found = 1 }
        END { if (!found) print fallback }
    ' <<< "${refs}")"
    [[ "${sha}" =~ ^[a-f0-9]{40}$ ]] || {
        echo "Unable to resolve ${repository}@${tag} to a commit." >&2
        exit 1
    }
    printf '%s\n' "${sha}"
}

image_digest() {
    local image_ref="$1"
    [[ "${image_ref}" != *$'\n'* && "${image_ref}" == *:* ]] || {
        echo "Invalid image reference generated for update check: ${image_ref}" >&2
        exit 1
    }
    if ! docker buildx imagetools inspect "${image_ref}" \
        | sed -n 's/^Digest:[[:space:]]*//p' | head -n1
    then
        echo "Unable to inspect image pin: ${image_ref}" >&2
        return 1
    fi
}

record() {
    local kind="$1" name="$2" current="$3" latest="$4"
    local status=current
    [[ "${current}" == "${latest}" ]] || status=update
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${kind}" "${name}" "${current}" "${latest}" "${status}" \
        >> "${RECORDS_FILE}"
}

replace_all() {
    local pattern="$1" replacement="$2"
    shift 2
    sed -i -E "s|${pattern}|${replacement}|g" "$@"
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

latest_binfmt_tag() {
    curl "${CURL_ARGS[@]}" \
        'https://hub.docker.com/v2/repositories/tonistiigi/binfmt/tags?page_size=100' \
        | jq -r '.results[].name' \
        | sed -nE '/^qemu-v[0-9]+\.[0-9]+\.[0-9]+$/p' \
        | sort -V | tail -n1
}

latest_dockerfile_major_tag() {
    curl "${CURL_ARGS[@]}" \
        'https://hub.docker.com/v2/repositories/docker/dockerfile/tags?page_size=100' \
        | jq -r '.results[].name' \
        | sed -nE '/^[0-9]+$/p' \
        | sort -V | tail -n1
}

update_action_pins() {
    local line repository current_sha current_tag latest_tag latest_sha
    while IFS= read -r line; do
        repository="$(sed -E 's|.*uses:[[:space:]]*([^@[:space:]]+)@.*|\1|' <<<"${line}")"
        current_sha="$(sed -E 's|.*@([a-f0-9]{40}).*|\1|' <<<"${line}")"
        current_tag="$(sed -nE 's|.*#[[:space:]]*([^[:space:]]+).*|\1|p' <<<"${line}")"
        [[ -n "${current_tag}" ]] || {
            echo "Action pin has no version comment: ${line}" >&2
            exit 1
        }
        latest_tag="$(latest_github_version "${repository}")"
        latest_sha="$(resolve_tag_sha "${repository}" "${latest_tag}")"
        record action "${repository}" "${current_tag}@${current_sha}" "${latest_tag}@${latest_sha}"
        if [[ "${MODE}" == --update && "${current_sha}" != "${latest_sha}" ]]; then
            replace_all \
                "(${repository}@)[a-f0-9]{40}([[:space:]]*#[[:space:]]*)[^[:space:]]+" \
                "\\1${latest_sha}\\2${latest_tag}" \
                "${WORKFLOW_DIR}"/*.yml
        fi
    done < <(grep -rhE 'uses:[[:space:]]+[^./][^@[:space:]]+@[a-f0-9]{40}' \
        "${WORKFLOW_DIR}" | sort -u)
}

update_release_version() {
    local name="$1" repository="$2" variable="$3"
    local current latest normalized
    current="$(dockerfile_arg "${variable}")"
    latest="$(latest_github_version "${repository}")"
    normalized="${latest#v}"
    record release "${name}" "${current}" "${normalized}"
    if [[ "${MODE}" == --update && "${current}" != "${normalized}" ]]; then
        replace_all "^(ARG ${variable}=).*" "\\1${normalized}" "${DOCKERFILE}"
    fi
    printf '%s\n' "${normalized}"
}

update_buildx() {
    local current latest
    current="$(sed -nE 's/^[[:space:]]*BUILDX_VERSION:[[:space:]]*//p' \
        "${WORKFLOW_DIR}"/*.yml | sort -u)"
    [[ "$(wc -l <<<"${current}")" -eq 1 ]] || {
        echo "BUILDX_VERSION pins are inconsistent." >&2
        exit 1
    }
    latest="$(latest_github_version docker/buildx)"
    record release docker/buildx "${current}" "${latest}"
    if [[ "${MODE}" == --update && "${current}" != "${latest}" ]]; then
        replace_all "(BUILDX_VERSION:[[:space:]]*).*" "\\1${latest}" \
            "${WORKFLOW_DIR}"/*.yml
    fi
}

update_image_pin() {
    local name="$1" source_repository="$2" tag_template="$3"
    local current_ref current_tag current_digest release_tag latest_tag latest_digest latest_ref
    current_ref="$(grep -rhEo \
        "${name}:[^[:space:]]+@sha256:[a-f0-9]{64}" \
        "${WORKFLOW_DIR}" | sort -u)"
    [[ -n "${current_ref}" && "$(wc -l <<<"${current_ref}")" -eq 1 ]] || {
        echo "Missing or inconsistent image pin for ${name}." >&2
        exit 1
    }
    current_tag="${current_ref#"${name}":}"
    current_tag="${current_tag%@sha256:*}"
    current_digest="sha256:${current_ref##*@sha256:}"
    case "${tag_template}" in
        release)
            release_tag="$(latest_github_version "${source_repository}")"
            latest_tag="${release_tag}"
            ;;
        release-no-v)
            release_tag="$(latest_github_version "${source_repository}")"
            latest_tag="${release_tag#v}"
            ;;
        qemu-docker-tag) latest_tag="$(latest_binfmt_tag)" ;;
        release-debian)
            release_tag="$(latest_github_version "${source_repository}")"
            latest_tag="${release_tag}-debian"
            ;;
        *) echo "Unknown image tag template: ${tag_template}" >&2; exit 1 ;;
    esac
    latest_digest="$(image_digest "${name}:${latest_tag}")"
    latest_ref="${name}:${latest_tag}@${latest_digest}"
    record image "${name}" "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update && "${current_ref}" != "${latest_ref}" ]]; then
        replace_all "${current_ref}" "${latest_ref}" "${WORKFLOW_DIR}"/*.yml
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
    latest_digest="$(image_digest "ghcr.io/linuxserver/baseimage-alpine:${latest_tag}")"
    latest_ref="ghcr.io/linuxserver/baseimage-alpine:${latest_tag}@${latest_digest}"
    record image ghcr.io/linuxserver/baseimage-alpine \
        "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update && "${current_ref}" != "${latest_ref}" ]]; then
        replace_all "^(ARG BASE_IMAGE=).*" "\\1${latest_ref}" "${DOCKERFILE}"
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
    latest_tag="$(latest_dockerfile_major_tag)"
    latest_digest="$(image_digest "docker/dockerfile:${latest_tag}")"
    record image docker/dockerfile \
        "${current_tag}@${current_digest}" "${latest_tag}@${latest_digest}"
    if [[ "${MODE}" == --update ]] &&
        [[ "${current_tag}@${current_digest}" != "${latest_tag}@${latest_digest}" ]]; then
        replace_all '^# syntax=docker/dockerfile:[0-9]+@sha256:[a-f0-9]{64}$' \
            "# syntax=docker/dockerfile:${latest_tag}@${latest_digest}" "${DOCKERFILE}"
    fi
}

download() {
    curl "${GITHUB_CURL_ARGS[@]}" "$1" --output "$2"
}

checksum() {
    sha256sum "$1" | awk '{print $1}'
}

update_release_checksums() {
    local geoip_version="$1" crowdsec_version="$2"
    local geo_amd_archive geo_arm_archive crowdsec_archive
    local geo_amd_sha geo_arm_sha crowdsec_sha source_dir extract_root
    geo_amd_archive="${TEMP_DIR}/geoipupdate-amd64.tar.gz"
    geo_arm_archive="${TEMP_DIR}/geoipupdate-arm64.tar.gz"
    crowdsec_archive="${TEMP_DIR}/crowdsec-nginx-bouncer.tgz"

    download "https://github.com/maxmind/geoipupdate/releases/download/v${geoip_version}/geoipupdate_${geoip_version}_linux_amd64.tar.gz" "${geo_amd_archive}"
    download "https://github.com/maxmind/geoipupdate/releases/download/v${geoip_version}/geoipupdate_${geoip_version}_linux_arm64.tar.gz" "${geo_arm_archive}"
    download "https://github.com/crowdsecurity/cs-nginx-bouncer/releases/download/v${crowdsec_version}/crowdsec-nginx-bouncer.tgz" "${crowdsec_archive}"

    geo_amd_sha="$(checksum "${geo_amd_archive}")"
    geo_arm_sha="$(checksum "${geo_arm_archive}")"
    crowdsec_sha="$(checksum "${crowdsec_archive}")"
    record checksum GEOIPUPDATE_AMD64_SHA256 \
        "$(dockerfile_arg GEOIPUPDATE_AMD64_SHA256)" "${geo_amd_sha}"
    record checksum GEOIPUPDATE_ARM64_SHA256 \
        "$(dockerfile_arg GEOIPUPDATE_ARM64_SHA256)" "${geo_arm_sha}"
    record checksum CROWDSEC_BOUNCER_SHA256 \
        "$(dockerfile_arg CROWDSEC_BOUNCER_SHA256)" "${crowdsec_sha}"

    extract_root="${TEMP_DIR}/crowdsec-source"
    mkdir -p "${extract_root}"
    tar -xzf "${crowdsec_archive}" -C "${extract_root}"
    source_dir="$(find "${extract_root}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "${source_dir}" ]] || { echo "Unable to locate CrowdSec source." >&2; exit 1; }
    patch --dry-run --batch --forward --fuzz=0 -p1 \
        -d "${source_dir}/lua-mod/lib" < "${PATCH_FILE}" >/dev/null

    if [[ "${MODE}" == --update ]]; then
        replace_all '^(ARG GEOIPUPDATE_AMD64_SHA256=).*' "\\1${geo_amd_sha}" "${DOCKERFILE}"
        replace_all '^(ARG GEOIPUPDATE_ARM64_SHA256=).*' "\\1${geo_arm_sha}" "${DOCKERFILE}"
        replace_all '^(ARG CROWDSEC_BOUNCER_SHA256=).*' "\\1${crowdsec_sha}" "${DOCKERFILE}"
    fi
}

audit_inventory() {
    local known_images='^(moby/buildkit|tonistiigi/binfmt|koalaman/shellcheck|ghcr.io/hadolint/hadolint|renovate/renovate):'
    local ref dockerfile_args expected_dockerfile_args
    while IFS= read -r ref; do
        [[ "${ref}" =~ ${known_images} ]] || {
            echo "Unmanaged workflow image pin: ${ref}" >&2
            exit 1
        }
    done < <(grep -rhEo '[[:alnum:]./_-]+:[^[:space:]]+@sha256:[a-f0-9]{64}' \
        "${WORKFLOW_DIR}" | sort -u)

    while IFS= read -r ref; do
        [[ "${ref}" =~ @[a-f0-9]{40}$ ]] || {
            echo "External GitHub Action is not pinned to a commit SHA: ${ref}" >&2
            exit 1
        }
    done < <(grep -rhEo 'uses:[[:space:]]+[^./][^[:space:]]+' \
        "${WORKFLOW_DIR}" | sed -E 's/^uses:[[:space:]]+//' | sort -u)

    dockerfile_args="$(sed -nE 's/^ARG ([A-Z0-9_]+)=.*/\1/p' \
        "${DOCKERFILE}" | sort)"
    expected_dockerfile_args="$(printf '%s\n' \
        APK_REFRESH_DATE \
        BASE_IMAGE \
        CROWDSEC_BOUNCER_SHA256 \
        CROWDSEC_BOUNCER_VERSION \
        GEOIPUPDATE_AMD64_SHA256 \
        GEOIPUPDATE_ARM64_SHA256 \
        GEOIPUPDATE_VERSION | sort)"
    [[ "${dockerfile_args}" == "${expected_dockerfile_args}" ]] || {
        echo "Dockerfile dependency ARG inventory changed; update check-updates.sh." >&2
        diff -u <(printf '%s\n' "${expected_dockerfile_args}") \
            <(printf '%s\n' "${dockerfile_args}") >&2 || true
        exit 1
    }
}

compare_apk_and_refresh() {
    [[ "${MODE}" == --update && "${SKIP_APK_CHECK}" != 1 ]] || return 0
    local apk_report="${TEMP_DIR}/apk-report.md"
    PUBLISHED_IMAGE="${PUBLISHED_IMAGE}" \
        "${REPOSITORY_ROOT}/scripts/compare-apk-packages.sh" > "${apk_report}"
    if grep -q '<!-- apk-updates-available:true -->' "${apk_report}"; then
        record apk floating-packages changed refresh-required
        replace_all '^(ARG APK_REFRESH_DATE=).*' "\\1$(date -u +%F)" "${DOCKERFILE}"
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

audit_inventory
update_action_pins
update_buildx
update_dockerfile_frontend
update_base_image
update_image_pin moby/buildkit moby/buildkit release
update_image_pin tonistiigi/binfmt tonistiigi/binfmt qemu-docker-tag
update_image_pin koalaman/shellcheck koalaman/shellcheck release
update_image_pin ghcr.io/hadolint/hadolint hadolint/hadolint release-debian
update_image_pin renovate/renovate renovatebot/renovate release-no-v
geoip_version="$(update_release_version GeoIPUpdate maxmind/geoipupdate GEOIPUPDATE_VERSION)"
crowdsec_version="$(update_release_version CrowdSec crowdsecurity/cs-nginx-bouncer CROWDSEC_BOUNCER_VERSION)"
update_release_checksums "${geoip_version}" "${crowdsec_version}"
compare_apk_and_refresh
emit_report
