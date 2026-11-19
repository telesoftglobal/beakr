#!/bin/bash
# Source from console tools. Only colour interactive stderr; exported logs stay plain.
beakr_log() {
    local category="$1"
    shift
    local colour="" reset="" marker="[${category}]"
    if [[ "${category}" == "FAIL" ]]; then marker="🔴 [FAIL]"; fi
    if [[ -t 2 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != "dumb" ]]; then
        case "${category}" in
            FAIL) colour=$'\033[31m' ;;
            RETRY) colour=$'\033[33m' ;;
            PASS|RECOVERED) colour=$'\033[32m' ;;
        esac
        reset=$'\033[0m'
    fi
    printf '%s%s %s%s\n' "${colour}" "${marker}" "$*" "${reset}" >&2
}

beakr_script_failure() {
    local status="$1" line="$2"
    # Never print BASH_COMMAND: fixture commands contain private keys/passwords.
    beakr_log FAIL "${0##*/} stopped at line ${line} (exit ${status})."
    return "${status}"
}
