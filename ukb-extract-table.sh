#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME -i FILE -f FILE -d FILE -o STR

Based on the field IDs, extract CSV.

Available options:
    -i, --ids      FILE  Local text file with field IDs.
                         Only first column is taken, comments are ignored.
    -f, --fields   FILE  Local text file with expanded field names
                         of format "pNNN[_iN][_aN]".
    -d, --dataset  FILE  Dataset path on the DnaNexus.
    -o, --output   STR   Prefix of the output file on the DnaNexus.
        --instance STR   Job instance [${instance}].
        --priority STR   Job priority [${priority}]
        --dry-run        Do not execute DnaNexus command.
    -h, --help           Print this help and exit.
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
    dry_run=no
    instance=mem2_ssd1_v2_x4
    priority=high

    ARGS="$(getopt -o i:f:d:o:h \
        --long ids:,fields:,dataset:,output:,instance:,priority:,dry-run,help \
        --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -i | --ids)
                ids="$2";     shift 2
                ;;
            -f | --fields)
                fields="$2";  shift 2
                ;;
            -d | --dataset)
                dataset="$2"; shift 2
                ;;
            -o | --output)
                output="$2";  shift 2
                ;;
            --instance)
                instance="$2"; shift 2
                ;;
            --priority)
                priority="$2"; shift 2
                ;;
            --dry-run)
                dry_run=yes; shift
                ;;
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    [[ $# -eq 0 ]] || panic "Too many arguments ($*)"
    [[ ! -z "${ids-}" ]] || panic "Missing required parameter: ids"
    [[ ! -z "${fields-}" ]] || panic "Missing required parameter: fields"
    [[ ! -z "${dataset-}" ]] || panic "Missing required parameter: dataset"
    [[ ! -z "${output-}" ]] || panic "Missing required parameter: output"
}

function get_fields {
    local pattern
    pattern="$(awk '
        BEGIN { printf("^p(") }
        $0!~/^#/ {
            if (n++) { printf("|") }
            printf($1)
        }
        END { printf(")(_|$)") }
    ' "$ids" | sort -V)"
    sel_fields=( $(grep -P "$pattern" "$fields") )
    [[ ${#sel_fields[@]} -ne 0 ]] || panic "No fields were selected"
    msg "Identified ${#sel_fields[@]} fields"
}

setup_colors
parse_params "$@"
get_fields

command=(
    dx run table-exporter
    "-idataset_or_cohort_or_dashboard=${dataset}"
    "--destination=$(dirname "$output")"
    "-ioutput=$(basename "$output")"
    "--instance-type=${instance}"
    "--priority=${priority}"
    "-ientity=participant"
    "-ifield_names=eid"
    "${sel_fields[@]/#/-ifield_names=}"
    )
msg "Execute command:"
echo "${command[*]}" | fold -s | \
    sed 's/$/\\/; 2,$s/^/    /; $s/.$/\n/' >&2

if [[ "$dry_run" = no ]]; then
    msg "========"
    printf "y\ny" | "${command[@]}"
fi
