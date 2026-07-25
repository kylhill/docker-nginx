#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-}"

if [ -z "${IMAGE}" ]; then
    echo "Usage: $0 IMAGE" >&2
    exit 2
fi

for command in docker jq sha256sum; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done

INSPECT="$(docker image inspect "${IMAGE}")"

ROOTFS_ID="$(jq -cS '
    .[0] | {
        architecture: .Architecture,
        os: .Os,
        variant: .Variant,
        rootfs: .RootFS
    }
' <<< "${INSPECT}" | sha256sum | awk '{print $1}')"

CONFIG_ID="$(jq -cS '
    .[0] | {
        architecture: .Architecture,
        os: .Os,
        variant: .Variant,
        config: (.Config | del(.Labels))
    }
' <<< "${INSPECT}" | sha256sum | awk '{print $1}')"

CONTENT_ID="$(printf 'rootfs=%s\nconfig=%s\n' "${ROOTFS_ID}" "${CONFIG_ID}" |
    sha256sum | awk '{print $1}')"

printf 'rootfs_sha256=%s\n' "${ROOTFS_ID}"
printf 'config_sha256=%s\n' "${CONFIG_ID}"
printf 'content_sha256=%s\n' "${CONTENT_ID}"
