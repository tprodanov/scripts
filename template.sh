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
    echo -e "$*" >&2
}

function err {
    msg "${RED}[ERROR]${ENDCOLOR} $*"
}

function panic {
    err "$1"
    exit "${2-1}" # Return 1 by default.
}

function parse_params {
    # [TODO] DEFAULT PARAMETERS

    # [TODO] Add options to getopt
    ARGS="$(getopt -o h --long help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            # [TODO] PARSE VALUES
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    # [[ $# -eq 1 ]] || panic "Missing script arguments"
    # [[ $# -eq 0 ]] || panic "Too many arguments ($*)"
    args=( "$@" )
    # [[ ! -z "${param-}" ]] || panic "Missing required parameter: param"
}

setup_colors
parse_params "$@"
