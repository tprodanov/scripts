#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

function help_message {
  cat <<HELP
Usage: $(basename "${BASH_SOURCE[0]:-$0}") !!!!!

!!!!! INSERT DESCRIPTION !!!!!!

Available options:

-h, --help      Print this help and exit.
HELP
}

function cleanup {
    trap - SIGINT SIGTERM ERR EXIT
    # ===== CLEANUP =====
}

function setup_colors {
    readonly RED="\e[31m"
    readonly ENDCOLOR="\e[0m"
}

function msg {
    echo -e "$@" >&2
}

function die {
    msg "${RED}[ERROR]${ENDCOLOR} $@"
    exit 1
}

function parse_params {
    # ===== DEFAULT PARAMETER VALUES =====

    ARGS="$(getopt -o abg:d: --long alpha,beta,gamma:,delta: -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            # ===== PARSE VALUES =====
            -h | --help)
                help_message; exit 0;
                ;;
            --)
                shift; break ;;
            *)
                break ;;
        esac
        shift
    done

    args=("$@")
    # [[ -z "${param-}" ]] && die "Missing required parameter: param"
    # [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"
    # [[ ${#args[@]} -ne 0 ]] && die "Too many arguments (${args[@]})"
}

setup_colors
parse_params "$@"
