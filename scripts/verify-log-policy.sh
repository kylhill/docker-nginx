#!/usr/bin/env bash

# Sourced by the verification scripts before any build or fixture creation.
ALLOW_EMULATED_AIO_ENOSYS="${ALLOW_EMULATED_AIO_ENOSYS-0}"
case "${ALLOW_EMULATED_AIO_ENOSYS}" in
    0 | 1) ;;
    *)
        echo "ALLOW_EMULATED_AIO_ENOSYS must be 0 or 1." >&2
        return 1
        ;;
esac

LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-\\[(emerg|alert|crit|error)\\]|^ERROR:|^FATAL:}"
EMULATED_AIO_ENOSYS_ELIGIBLE=0

configure_log_policy() {
    local image_arch daemon_arch
    EMULATED_AIO_ENOSYS_ELIGIBLE=0
    [ "${ALLOW_EMULATED_AIO_ENOSYS}" = 1 ] || return 0

    image_arch="$(docker image inspect --format '{{.Architecture}}' "${IMAGE}")" || {
        echo "Could not inspect image architecture; refusing log exception." >&2
        return 1
    }
    daemon_arch="$(docker info --format '{{.Architecture}}')" || {
        echo "Could not read Docker daemon architecture; refusing log exception." >&2
        return 1
    }
    case "${daemon_arch}" in
        x86_64) daemon_arch=amd64 ;;
        aarch64) daemon_arch=arm64 ;;
    esac
    case "${image_arch}:${daemon_arch}" in
        amd64:arm64 | arm64:amd64)
            EMULATED_AIO_ENOSYS_ELIGIBLE=1
            echo "WARNING: allowing only timestamped nginx [emerg] io_setup() ENOSYS (38) lines for image ${image_arch} on Docker daemon ${daemon_arch}; emulated AIO coverage is reduced. Original output is retained." >&2
            ;;
        amd64:amd64 | arm64:arm64)
            echo "Native image/daemon architecture ${image_arch}; log checks remain strict." >&2
            ;;
        *)
            echo "Unknown image/daemon architecture '${image_arch}'/'${daemon_arch}'; log checks remain strict (no exception)." >&2
            ;;
    esac
}

check_nginx_output() {
    local output="$1"
    local checked status
    printf '%s\n' "${output}"
    checked="${output}"
    if [ "${EMULATED_AIO_ENOSYS_ELIGIBLE}" = 1 ]; then
        checked="$(sed -E '/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[emerg\] [0-9]+#[0-9]+: io_setup\(\) failed \(38: Function not implemented\)$/d' <<< "${output}")" ||
            return 1
    fi
    # A here-string avoids grep -q closing a Docker log pipe early under pipefail.
    if grep -Eiq "${LOG_ERROR_REGEX}" <<< "${checked}"; then
        echo "nginx output matched error regex: ${LOG_ERROR_REGEX}" >&2
        return 1
    else
        status=$?
        [ "${status}" = 1 ] || return "${status}"
    fi
}

check_container_logs() {
    local output status
    output="$(docker logs "$1" 2>&1)" || {
        status=$?
        printf '%s\n' "${output}" >&2
        echo "Could not read container logs for $1." >&2
        return "${status}"
    }
    check_nginx_output "${output}"
}
