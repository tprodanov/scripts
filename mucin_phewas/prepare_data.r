library(dplyr)
library(tidyr)
library(tibble)
library(stringi)

# Need files:
# - data.csv.gz
# - annot.csv.gz
# - withdrawed.txt (not required)
# - haplotype_haplogroup_manifest2.csv
# - phenotypes.csv

# ===== Load data =====
SKIP_GENES <- c('MUC4', 'MUC12', 'MUC16', 'MUC19')

data <- read.csv('data.csv.gz', sep = ',') |>
    rename(sample = eid)
annot <- read.csv('annot.csv.gz', sep = '\t', comment = '#') |>
    filter(!(locus %in% SKIP_GENES))
samples <- unique(annot$sample)
if (file.exists('withdrawed.txt')) {
    samples <- setdiff(samples, readLines('withdrawed.txt') |> as.integer())
}

# ===== Converting annotation =====

annot2 <- filter(annot, sample %in% samples) |>
    filter(hap1 != '<UNKNOWN>' & hap2 != '<UNKNOWN>') |>
    pivot_longer(c('hap1', 'hap2'), values_to = 'hap') |>
    select(-name) |>
    separate(hap, into = c('vntr', 'haplogroup'), sep = ',', convert = T)
samples2 <- unique(annot2$sample)

# Do this because join takes too much memory
vntr_clusters <- read.csv('haplotype_haplogroup_manifest2.csv', sep = '\t') |>
    with(setNames(vntr_cluster, sprintf('%s-%s', mucin, vntr_length)))
annot3 <- mutate(annot2,
    vntr_cluster = as.vector(vntr_clusters[sprintf('%s-%s', locus, vntr)]),
    haplogroup = haplogroup,
)
stopifnot(all(!is.na(annot3$vntr_cluster)))

# Convert haplogroups and VNTRs to one-hot encoding.
# Need this to avoid installing new libraries.
# Need ix to make all rows unique.
annot4 <- annot3 |>
    mutate(ix = 1:n()) |>
    pivot_wider(
        names_from = haplogroup, values_from = haplogroup,
        names_prefix = 'hgroup', names_sep = '', names_sort = T,
        values_fill = 0, values_fn = ~ 1,
    ) |>
    pivot_wider(
        names_from = vntr_cluster, values_from = vntr_cluster,
        names_prefix = 'vntr', names_sep = '', names_sort = T,
        values_fill = 0, values_fn = ~ 1,
    ) |>
    select(-ix) |>
    group_by(sample, locus) |>
    summarize(
        # min_vntr = min(vntr), max_vntr = max(vntr),
        across(matches('vntr[0-9]+') | starts_with('hgroup'), ~ sum(.x)),
        .groups = 'keep') |>
    ungroup()

# ===== Metadata =====

metadata <- filter(data, sample %in% samples2) |>
    with(data.frame(
        sample = sample,
        sex = p31,
        age = p21022,
        pca1 = p22009_a1,
        pca2 = p22009_a2,
        pca3 = p22009_a3
    )) |> arrange(sample)
metadata <- metadata[rowSums(is.na(metadata)) == 0,]
stopifnot(setdiff(unique(metadata$sex), c('Male', 'Female')) |> length() == 0)
metadata <- mutate(metadata, sex_female = as.integer(sex == 'Female'), sex = NULL)

final_samples <- metadata$sample
final_annot <- filter(annot4, sample %in% final_samples) |>
    arrange(sample)

# ===== ICD10 codes and phenotypes =====

icd10 <- filter(data, sample %in% final_samples) |>
    select(sample, p41270)
icd10$code <- icd10$p41270 |>
    stri_extract_all_regex('[A-Z][0-9.]+') |>
    sapply(paste0, collapse = ',')
icd10_long <- select(icd10, sample, code) |>
    separate_longer_delim(code, delim = ',') |>
    mutate(
        code3 = stri_sub(code, from = 1, to = 5),
        code2 = stri_sub(code3, from = 1, to = 3),
    )
icd10_lvl3 <- select(icd10_long, sample, code3, code2) |> unique()
icd10_lvl2 <- select(icd10_long, sample, code2) |> unique()

phenotypes <- read.csv('~/phenotypes.csv', sep = '\t')
phenotypes_exp <- phenotypes |>
    separate(icd10,
        into = c('from', 'to'), sep = '-', fill = 'right', remove = F) |>
    mutate(
        to = ifelse(is.na(to), from, to),
        letter = from |> stri_sub(1, 1),
        from_num = from |> stri_sub(2) |> as.integer(),
        to_num = to |> stri_sub(2) |> as.integer(),
        from = NULL, to = NULL,
    ) |>
    group_by(icd10) |>
    reframe(
        code2 = sprintf('%s%02d', rep(letter, to_num - from_num + 1),
            from_num:to_num)
    )
sel_code2 <- phenotypes_exp$code2

subset_lvl2 <- filter(icd10_lvl2, code2 %in% sel_code2) |>
    count(code2, name = 'total2')
subset_lvl3 <- filter(icd10_lvl3, code2 %in% sel_code2) |>
    count(code3, code2, name = 'total3') |>
    left_join(subset_lvl2, join_by(code2))

# ===== Phenotypes =====

MIN_COUNT <- 500
final_phenotypes <- bind_rows(subset_lvl2, subset_lvl3) |>
    filter(
        ( is.na(total3) & total2 >= MIN_COUNT) |
        (!is.na(total3) & total3 >= MIN_COUNT & total2 - total3 >= MIN_COUNT)) |>
    mutate(code = ifelse(is.na(code3), code2, code3)) |>
    with(code) |> unique() |> sort()
# 302 phenotypes

icd10_codes <- pivot_longer(icd10_lvl3, c(code3, code2), values_to = 'code') |>
    select(-name) |>
    filter(code %in% final_phenotypes) |>
    unique()

# ===== Save data =====

rm(
    data, annot, annot2, annot3, annot4,
    icd10, icd10_long, icd10_lvl2, icd10_lvl3,
    phenotypes, phenotypes_exp, subset_lvl2, subset_lvl3,
    MIN_COUNT, SKIP_GENES, samples, samples2, sel_code2,
    vntr_clusters
)

save.image(file = '~/data.RData')

expand.grid(locus = unique(final_annot$locus), phenotype = unique(icd10_codes$code)) |>
    arrange(locus, phenotype) |>
    with(sprintf('%s-%s', locus, phenotype)) |>
    writeLines('combinations.txt')
