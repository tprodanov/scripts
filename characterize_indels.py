#!/usr/bin/env python3

import pysam
import sys


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('vcf', help='Pangenome VCF file.')
    parser.add_argument('-v', '--variants', nargs='+', required=True,
        help='Center variants of interest.')
    parser.add_argument('-p', '--padding', type=int, default=100,
        help='Padding around center variants [%(default)s].')
    parser.add_argument('-o', '--output', default=sys.stdout,
        help='Output file.')
    args = parser.parse_args()

    out = args.output
    out.write('var\thap\tref_len\talt_len\tcenter_var\n')
    vcf = pysam.VariantFile(args.vcf)
    for center_var in args.variants:
        chrom, pos = center_var.split(':')
        pos = int(pos)
        for var in vcf.fetch(chrom, pos - 1 - args.padding, pos + args.padding):
            ref_len = len(var.ref)
            if all(ref_len == len(allele) for allele in var.alleles):
                continue
            for sample, data in var.samples.items():
                gt = data['GT']
                for i, allele_ix in enumerate(gt, 1):
                    hap = sample if len(gt) == 1 else f'{sample}.{i}'
                    alt_len = len(var.alleles[allele_ix]) if allele_ix is not None else 'NA'
                    out.write(f'{var.chrom}:{var.pos}\t{hap}\t{ref_len}\t{alt_len}\t{center_var}\n')


if __name__ == '__main__':
    main()
