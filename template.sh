#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME [TODO] INSERT USAGE

[TODO] INSERT DESCRIPTION

Available options:
    -h, --help          Print this help and exit.
HELP
}

function cleanup {
    trap - INT TERM ERR EXIT
    # [TODO] CLEANUP CODE
}
trap cleanup INT TERM ERR EXIT

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
    # [TODO] DEFAULT PARAMETERS

    ARGS="$(getopt -o h --long help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            # [TODO] PARSE VALUES
            -h | --help)
                help_message; exit 0;
                ;;
            --)
                shift; break ;;
            *)
                break ;;
        esac
    done

    args=( "$@" )
    # [[ -z "${param-}" ]] && die "Missing required parameter: param"
    # [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"
    # [[ ${#args[@]} -ne 0 ]] && die "Too many arguments (${args[@]})"
}

setup_colors
parse_params "$@"
