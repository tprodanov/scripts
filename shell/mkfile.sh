#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

readonly DEF_SUFFIX=".txt"
readonly DEF_MAX_COUNT=16384

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME -s STR -n INT [DIR|PREFIX]

Atomically create file in the output directory or with given prefix.
Output file will have form DIR/N.SUFFIX or PREFIX.N.SUFFIX.
If no directory is given, current directory is used.

Available options:
    -s, --suffix    STR  File suffix [${DEF_SUFFIX}].
    -n, --max-count INT  Maximum number of numeric indixes [${DEF_MAX_COUNT}].
    -h, --help           Print this help and exit.

Positional arguments:
        DIR/STR     Create file in this directory or with this prefix.
HELP
}

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
    suffix="$DEF_SUFFIX"
    max_count="$DEF_MAX_COUNT"

    ARGS="$(getopt -o s:n:h --long suffix:,max-count:,help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -s | --suffix)
                suffix="$2";    shift 2 ;;
            -n | --max-count)
                max_count="$2"; shift 2 ;;
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    [[ $# -le 1 ]] || panic "Too many positional arguments ($*)"
    # Use current directory by default
    prefix="${1-.}"
}

function create_file {
    if [[ -d "$prefix" ]]; then
        prefix="${prefix}/"
    else
        prefix="${prefix}."
    fi

    local i=1
    while [[ "$i" -le "$max_count" ]]; do
        name="${prefix}${i}${suffix}"
        if ( set -C; 2>/dev/null > "$name" ); then
            echo "$name"
            exit 0
        fi
        i=$((i + 1))
    done
    panic "Could not create files (${prefix}1${suffix} .. ${prefix}${max_count}${suffix})"
}

setup_colors
parse_params "$@"
create_file
