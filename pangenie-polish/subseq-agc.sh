#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME (-a FILE | -g DIR) -t FILE -p DIR -o DIR [-d INT]

Extract subsequences from assembly genomes.

Available options:
    -a, --agc      FILE  Input AGC file.
    -g, --genomes  DIR   Directory with various genome assemblies (.fa[.gz]).
                         Mutually exclusive with -a/--agc.
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

    ARGS="$(getopt -o a:g:t:p:o:d:h --long agc:,genomes:targets:,pafs:,output:,distance:,help \
        --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -a | --agc )
                agc_file="$2"; shift 2 ;;
            -g | --genomes )
                genomes_dir="$2";  shift 2 ;;
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
    [[ ! -z "${targets_file-}" ]] || panic "Missing required parameter -t/--targets"
    [[ ! -z "${paf_dir-}" ]]  || panic "Missing required parameter -p/--pafs"
    [[ ! -z "${output-}" ]]   || panic "Missing required parameter -o/--output"

    [[ -z "${agc_file-}" ]] && have_agc=n || have_agc=y
    [[ -z "${genomes_dir-}" ]] && have_genomes=n || have_genomes=y
    [[ $have_agc != $have_genomes ]] || panic "Require either -a or -g, but not both"
}

function process_genome {
    local arg="$1"
    local genome_name
    [[ $have_agc = y ]] && genome_name="$arg" || genome_name="$(basename "${arg%.fa*}")"

    local prefix="${output}/${genome_name}"
    local ok_file="${prefix}.ok"
    local lock_file="${prefix}.lock"
    if [[ -f "$ok_file" ]]; then
        return
    fi
    if ! ( set -C; 2>/dev/null > "$lock_file" ); then
        return
    fi
    trap 'rm -f "${lock_file}"; exit 1' INT TERM ERR

    msg "Processing $genome_name"

    local genome_fasta
    [[ $have_agc = y ]] && genome_fasta="${prefix}.fa" || genome_fasta="$arg"

    local genome_paf="${paf_dir}/${genome_name}.paf.gz"
    if [[ ! -f "$genome_paf" ]]; then
        err "Alignment file ${genome_paf} does not exist"
        return 1
    fi

    if [[ $have_agc = y ]]; then
        agc getset "$agc_file" "$genome_name" > "${genome_fasta}"
        samtools faidx "${genome_fasta}"
    fi

    for target in "${targets[@]}"; do
        # First, take PAF for given target and convert to BED file, then sort and merge.
        # Then, sort it and merge;

        zcat "${genome_paf}" | \
            awk -F$'\t' -v target="$target" \
                'BEGIN{OFS=FS} $1 == target { print $6,$8,$9,target }' | \
            sort -k1,1V -k2,2n | \
            bedtools merge -d "$distance" -c 4 -o distinct \
            > "${prefix}__${target}.bed"

        # Select largest region and convert it into "chr:start-end" format.
        local region
        region="$(awk -F$'\t' 'BEGIN{OFS=FS} {
                if ($3 - $2 > len) {
                    len = $3 - $2;
                    region = ($1 ":" ($2+1) "-" $3);
                }
            } END { print region }' "${prefix}__${target}.bed")"

        # If there is a region, extract it
        if [[ ! -z "$region" ]]; then
            samtools faidx "${prefix}.fa" "$region" | gzip > "${prefix}__${target}.fa.gz"
        fi
    done

    [[ $have_agc = n ]] || rm "${genome_fasta}"{,.fai}

    cat "${prefix}__"*.bed | sort -k1,1V -k2,2n | gzip > "${prefix}.bed.gz"
    rm "${prefix}__"*.bed

    # ===== END ======

    touch "${ok_file}"
    rm -f "${lock_file}"
    trap - INT TERM ERR
}

setup_colors
parse_params "$@"

readarray -t targets < "$targets_file"
[[ ${#targets[@]} -ne 0 ]] || panic "No targets found at ${targets_file}"
(! grep -q __ "$targets_file") || panic "Target names should not contain __"

mkdir -p "$output"
if [[ $have_agc = y ]]; then
    agc listset "$agc_file" | while read genome; do
        process_genome "$genome"
    done
else
    shopt -s nullglob
    for genome in "${genomes_dir}"/*.fa{,sta}{,.gz}; do
        process_genome "$genome"
    done
fi
