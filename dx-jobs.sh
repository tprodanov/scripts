#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME [DIR]

Save IDs and key information about all DnaNexus jobs.

Available options:
        DIR             Working directory.
    --skip-ids          Do not request new job ids.
    --skip-descr        Do not request new job descriptions.
    -@, --threads  INT  Number of fetching threads [8].
    -h, --help          Print this help and exit.
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
    threads=8
    skip_ids=no
    skip_descr=no

    ARGS="$(getopt -o @:h --long skip-ids,skip-descr,threads:,help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            --skip-ids)
                skip_ids=yes; shift
                ;;
            --skip-descr)
                skip_descr=yes; shift
                ;;
            -@ | --threads)
                threads="$2"; shift 2;
                ;;
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    [[ $# -le 2 ]] || panic "Too many positional arguments ($*)"
    [[ $# -eq 1 ]] && wdir="$1" || wdir=.
}

function atomic_touch {
    local fname
    fname="$1"
    ( set -C; 2>/dev/null > "$fname" )
}

function request_ids {
    local output last_timepoint COUNT
    output="$1"
    last_timepoint="$2"
    COUNT=20000
    dx find jobs --json -n "$COUNT" --created-after="$last_timepoint" | \
        jq -r '.[] | [.id, .created] | @csv' | \
        tr -d '"' > "$output"
}

function save_ids {
    shopt -s nullglob
    local subdir filenames
    subdir="${wdir}/ids"
    mkdir -p "$subdir"
    filenames=( "${subdir}/"*.csv )

    local last_timepoint output
    if [[ "${#filenames[@]}" -eq 0 ]]; then
        last_timepoint=0
        output="${subdir}/0.csv"
    else
        IFS=$'\n' last="$(sort -V <<<"${filenames[*]}" | tail -n1)"
        unset IFS

        last_timepoint="$(awk -F, '{ s = $2 > s ? $2 : s } END { print s }' "$last")"
        local last_ix
        last_ix="$(basename "$last" .csv)"
        output="${subdir}/$((last_ix + 1)).csv"
    fi

    local retries=3
    while ! request_ids "$output" "$last_timepoint"; do
        ((--retries)) || panic "Could not fetch jobs 3 times"
        sleep 10
    done
}

function get_description {
    local decsr_dir descr_fname job_id state
    # Need to get global variables since the function will be called from gnu-parallel.
    descr_dir="$1"
    job_id="$2"
    descr_fname="${descr_dir}/${job_id}.json"
    [[ -f "${descr_fname}.gz" ]] && return
    dx describe --json "$job_id" > "$descr_fname"
    state="$(jq -r .state "$descr_fname")"
    if [[ "$state" = running || "$state" = runnable ]]; then
        rm "$descr_fname"
    else
        gzip "$descr_fname"
    fi
}
export -f get_description

function parse_description {
    local filename
    filename="$1"
    zcat "$filename" | \
        sed 's/\(\\\\\)\?\\n \+/ /g; s/\\n/; /g' | \
        jq -r '[.id, .priority, .instanceType, .try, .totalPrice, .created, .stoppedRunning, .state, .failureReason, .input.cmd] | @csv'
}
export -f parse_description

setup_colors
parse_params "$@"
mkdir -p "$wdir"

lock_fname="${wdir}/.lock"
descr_dir="${wdir}/descr"
atomic_touch "$lock_fname" || panic "Lock ${lock_fname} already exists"
trap 'rm -f "$lock_fname" "${descr_dir}"/*.tmp' INT TERM ERR EXIT
mkdir -p "$descr_dir"

if [[ "$skip_ids" = no ]]; then
    msg "Loading job IDs"
    save_ids
fi

if [[ "$skip_descr" = no ]]; then
    msg "Saving job descriptions"
    cut -f1 -d, "${wdir}/ids/"*.csv | sort -u | \
        parallel -P "$threads" --progress get_description "$descr_dir" {}
fi

msg "Parsing job descriptions"
(
    echo 'id,priority,instance,try,price,time_start,time_end,state,failure_reason,cmd';
    ls "${descr_dir}/"*.json.gz | \
        parallel -P "$threads" --progress parse_description
) | gzip > "${wdir}/summary.csv.gz"
