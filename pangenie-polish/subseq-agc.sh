#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME -a FILE -t FILE -p DIR -o DIR [-d INT]

Extract subsequences from AGC genomes.

Available options:
    -a, --agc      FILE  Input AGC file.
    -t, --targets  FILE  File with target names (first PAF column).
    -p, --pafs     DIR   Directory with PAF.gz alignments.
    -o, --output   DIR   Output directory.
    -d, --distance INT   Merge PAF entries if distance is smaller than INT [${distance}].
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
    distance=5000

    ARGS="$(getopt -o a:p:o:d:h --long agc:,pafs:,output:,distance:,help --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -a | --agc )
                agc_file="$2"; shift 2 ;;
            -t | --targets )
                targets_file="$2";  shift 2 ;;
            -p | --pafs )
                paf_dir="$2";  shift 2 ;;
            -o | --output )
                output="$2";   shift 2 ;;
            -d | --distance )
                distance="$2"; shift 2 ;;
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    [[ $# -eq 0 ]] || panic "Too many arguments ($*)"
    [[ ! -z "${agc_file-}" ]] || panic "Missing required parameter -a/--agc"
    [[ ! -z "${targets_file-}" ]] || panic "Missing required parameter -t/--targets"
    [[ ! -z "${paf_dir-}" ]]  || panic "Missing required parameter -p/--pafs"
    [[ ! -z "${output-}" ]]   || panic "Missing required parameter -o/--output"
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

    local genome_paf="${paf_dir}/${genome}.paf.gz"
    if [[ ! -f "$genome_paf" ]]; then
        err "Alignment file ${genome_paf} does not exist"
        return 1
    fi
    msg "Processing $genome (${genome_paf})"
    agc getset "$agc_file" "$genome" > "${prefix}.fa"
    samtools faidx "${prefix}.fa"

    for target in "${targets[@]}"; do
        # First, take PAF for given target and convert to BED file, then sort and merge.
        # Then, sort it and merge;

        zcat "${genome_paf}" | \
            awk -F$'\t' -v target="$target" \
                'BEGIN{OFS=FS} $1 == target { print $6,$8,$9,target }' | \
            sort -k1,1V -k2,2n | \
            bedtools merge -d "$distance" -c 4 -o distinct \
            > "${prefix}::${target}.bed"

        # Select largest region and convert it into "chr:start-end" format.
        local region
        region="$(awk -F$'\t' 'BEGIN{OFS=FS} {
                if ($3 - $2 > len) {
                    len = $3 - $2;
                    region = ($1 ":" ($2+1) "-" $3);
                }
            } END { print region }' "${prefix}::${target}.bed")"

        # If there is a region, extract it
        if [[ ! -z "$region" ]]; then
            samtools faidx "${prefix}.fa" "$region" | gzip > "${prefix}::${target}.fa.gz"
        fi
    done
    rm "${prefix}.fa"

    cat "${prefix}::"*.bed | sort -k1,1V -2,2n > "${prefix}.bed"
    rm "${prefix}::"*.bed

    # ===== END ======

    touch "${ok_file}"
    rm -f "${lock_file}"
    trap - INT TERM ERR
}

setup_colors
parse_params "$@"

readarray -t targets < "$targets_file"
[[ ${#targets[@]} -ne 0 ]] || panic "No targets found at ${targets_file}"

mkdir -p "$output"
agc listset "$agc_file" | while read genome; do
    process_genome "$genome"
done
