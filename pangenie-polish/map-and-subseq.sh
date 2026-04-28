#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"

function help_message {
  cat <<HELP
Usage: $SCRIPT_NAME (-a FILE | -g DIR) -t FILE -o DIR [-d INT] [args] [-- minimap-args]

Maps target sequences to assembly genomes and extracts corresponding subregions.

Available options:
    -a, --agc      FILE  Input AGC file.
    -g, --genomes  DIR   Directory with various genome assemblies (.fa[.gz]).
                         Mutually exclusive with -a/--agc.
    -n, --names    FILE  Optional: replace genome names (first column) with another name (second column).
                         In case of -g/--genomes, first column should match file basename without extension.
    -t, --targets  FILE  FASTA file with target sequences. Name lines should not contain spaces.
    -o, --output   DIR   Output directory.
    -d, --distance INT   Merge PAF entries if distance is smaller than INT [${distance}].
    -f, --min-frac NUM   Minimum match fraction compared to target length [${min_frac}].
    -h, --help           Print this help and exit.

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
    min_frac=0.7
    distance=5000
    names_file=

    ARGS="$(getopt -o a:g:n:t:o:d:f:h --long agc:,genomes:,names:,targets:,output:,distance:,min-frac:,help \
        --name "$SCRIPT_NAME" -- "$@")"
    eval set -- "$ARGS"
    while :; do
        case "$1" in
            -a | --agc )
                agc_file="$2"; shift 2 ;;
            -g | --genomes )
                genomes_dir="$2"; shift 2 ;;
            -t | --targets )
                targets_file="$2"; shift 2 ;;
            -n | --names )
                names_file="$2"; shift 2 ;;
            -o | --output )
                output="$2"; shift 2 ;;
            -d | --distance )
                distance="$2"; shift 2 ;;
            -f | --min-frac )
                min_frac="$2"; shift 2 ;;
            -h | --help)
                help_message; exit 0;
                ;;
            -- ) shift; break ;;
            * )  panic "Unexpected argument $1" ;;
        esac
    done

    if [[ ${#@} -ne 0 ]]; then
        minimap2_args=( "$@" )
    else
        minimap2_args=( -cx asm20 -t 3 -N 10 -p 0.5 )
    fi

    [[ ! -z "${targets_file-}" ]] || panic "Missing required parameter -t/--targets"
    [[ ! -z "${output-}" ]]   || panic "Missing required parameter -o/--output"

    [[ -z "${agc_file-}" ]] && have_agc=n || have_agc=y
    [[ -z "${genomes_dir-}" ]] && have_genomes=n || have_genomes=y
    [[ $have_agc != $have_genomes ]] || panic "Require either -a or -g, but not both"
}

function load_names {
    [[ ! -z "$names_file" ]] || return 0
    while read name upd_name; do
        names["$name"]="$upd_name"
    done < "$names_file"
}

function process_genome {
    local arg="$1"
    local genome_name
    [[ $have_agc = y ]] && genome_name="$arg" || genome_name="$(basename "${arg%.fa*}")"

    local short_name
    # :- if unset or empty, use $genome_name
    short_name="${names["$genome_name"]:-"$genome_name"}"

    local prefix="${output}/${short_name}"
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
    msg "Processing $short_name"
    mkdir -p "$prefix"

    local genome_fasta
    if [[ $have_agc = y ]]; then
        msg "    Extracting genome sequence"
        genome_fasta="${prefix}.fa"
        agc getset "$agc_file" "$genome_name" > "${genome_fasta}"
        samtools faidx "${genome_fasta}"
    else
        genome_fasta="$arg"
    fi

    local paf_filename="${prefix}.paf.gz"
    if [[ ! -f "$paf_filename" ]]; then
        msg "    Mapping targets to assembly"
        minimap2 "${minimap2_args[@]}" "$genome_fasta" "$targets_file" 2> /dev/null | \
            gzip > "${paf_filename}.tmp" \
            && mv "${paf_filename}"{.tmp,}
    fi

    # Clear the BED file, if it exists.
    > "${prefix}.bed"
    msg "    Extracting subsequences"
    for target in "${target_names[@]}"; do
        # First, take PAF for given target and convert to BED file, then sort and merge.
        # As a fourth column in the BED file, output strand (+/-1) multiplied by region length.
        # This value is then summed up by bedtools merge and used to determine resulting strand of the mapping.
        local target_len
        target_len="$({
            zcat "${paf_filename}" | \
            awk -F$'\t' -v target="$target" 'BEGIN{OFS=FS}
                $1 == target {
                    print $6, $8, $9, ($5 == "+" ? 1 : -1) * ($4 - $3);
                    target_len=$2;
                }
                END { print target_len > "/dev/stderr"}' | \
            sort -k1,1V -k2,2n | \
            bedtools merge -d "$distance" -c 4 -o sum 2> /dev/null \
            > "${prefix}/${target}.bed";
            } 2>&1)"

        # Select largest region, output it into "chr:start-end@strand_arg" format,
        # where strand_arg is either -i (reverse complement) or empty string (forward),
        # which is then supplied to samtools faidx.
        local region_strand region strand_arg
        region_strand="$(awk -F$'\t' -v target_len="$target_len" -v min_frac="$min_frac" '
            BEGIN{ OFS = "@"; len = target_len * min_frac - 0.5 }
            {
                if ($3 - $2 > len) {
                    len = $3 - $2;
                    region = ($1 ":" ($2+1) "-" $3);
                    strand_arg = $4 >= 0 ? "" : "-i";
                }
            } END { print region, strand_arg }' "${prefix}/${target}.bed")"
        region="${region_strand%@*}"
        strand_arg="${region_strand#*@}"

        # If there is a region, extract it
        if [[ ! -z "$region" ]]; then
            samtools faidx "$genome_fasta" "$region" $strand_arg | \
                sed "1c>${short_name}" | gzip > "${prefix}/${target}.fa.gz"
            cut -f-3 "${prefix}/${target}.bed" | sed "s/$/\t${target}/" >> "${prefix}.bed"
        fi
    done

    [[ $have_agc = n ]] || rm "${genome_fasta}"{,.fai}

    sort -k1,1V -k2,2n "${prefix}.bed" | gzip "${prefix}.bed.gz"
    rm "${prefix}.bed" "${prefix}"/*.bed
    # ===== END ======

    touch "${ok_file}"
    rm -f "${lock_file}"
    trap - INT TERM ERR
}

setup_colors
parse_params "$@"
declare -A names
load_names

# zcat -f opens plain files as well. sed -n does not print by default.
readarray -t target_names < <(zcat -f "$targets_file" | sed -n 's/>//p' | sort -u)

mkdir -p "$output"
if [[ $have_agc = y ]]; then
    agc listset "$agc_file" | while read genome; do
        process_genome "$genome"
    done
else
    for filename in "${genomes_dir}"/*.fa{,sta}{,.gz}; do
        process_genome "$filename"
    done
fi
