#!/bin/bash

#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message { cat <<HELP
Usage: $SCRIPT_NAME -a FILE -t DIR -o DIR -- [minimap-args]

Extract genomes from AGC assemblies and map sequences to them.
This script can be safely run in parallel multiple times.

Available options:
    -a, --agc     FILE  Input AGC file.
    -t, --targets DIR   Directory with target sequences.
                        Files should be named <contig>.fa[.gz].
    -o, --output  DIR   Output directory.
    -h, --help          Print this message and exit.

Provide minimap2 arguments after --
    Default arguments are "-cx asm20 -t 3 -N 10 -p 0.5"
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
    ARGS="$(getopt -o a:t:o:h --long agc:,targets:,output:,help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -a | --agc )
                agc_file="$2"; shift 2 ;;
            -t | --targets )
                targets="$2";  shift 2 ;;
            -o | --output )
                output="$2";   shift 2 ;;

            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    [[ ! -z "${agc_file-}" ]] || panic "Missing required parameter -a/--agc"
    [[ ! -z "${targets-}" ]]  || panic "Missing required parameter -t/--targets"
    [[ ! -z "${output-}" ]]   || panic "Missing required parameter -o/--output"

    if [[ ${#@} -ne 0 ]]; then
        minimap2_args=( "$@" )
    else
        minimap2_args=( -cx asm20 -t 3 -N 10 -p 0.5 )
    fi
    msg "Using minimap2 arguments ${minimap2_args[*]}"
}

function process_genome {
    local genome="$1"

    local prefix="${output}/${genome}"
    local ok_file="${prefix}.ok"
    local lock_file="${prefix}.lock"

    if [[ -f "$ok_file" ]]; then
        return
    fi
    if ! ( set -C; 2>/dev/null > "$lock_file" ); then
        return
    fi
    trap 'rm -f "${lock_file}"; exit 1' INT TERM ERR

    # ===== START ======

    msg "Processing $genome"
    for curr_targets in "${target_fnames[@]}"; do
        # Pattern removes suffix .fa[sta][.gz]
        local contig
        contig="$(sed 's/\.fa\(sta\)\?\(\.gz\)\?$//' <<<"$curr_targets")"
        msg "... Processing $contig @ $genome"
        local contig_prefix="${prefix}::${contig}"
        agc getctg "$agc_file" "${contig}@${genome}" | gzip > "${contig_prefix}.fa.gz"
        minimap2 "${minimap2_args[@]}" "${contig_prefix}.fa.gz" "${targets}/${curr_targets}" \
            2> "${contig_prefix}.log"
        rm "${contig_prefix}.log" "${contig_prefix}.fa.gz"
    done | gzip > "${prefix}.paf.gz"

    # ===== END ======

    touch "${ok_file}"
    rm -f "${lock_file}"
    trap - INT TERM ERR
}

setup_colors
parse_params "$@"

shopt -s nullglob
target_fnames=( "${targets}/"*.fa{,sta}{,.gz} )
[[ ${#target_fnames[@]} -ne 0 ]] || panic "No targets found at ${targets}/*.fa[.gz]"

mkdir -p "$output"
agc listset "$agc_file" | while read genome; do
    process_genome "$genome"
done
