#!/usr/bin/env Rscript

suppressMessages(library(dplyr))
suppressMessages(library(tidyr))
suppressMessages(library(tibble))
suppressMessages(library(stringi))

# ===== Functions =====

failed <- function(obj) { inherits(obj, 'try-error') }

summarize_model <- function(name, model, summary, model0 = NULL, summary0 = NULL) {
    if (is.null(summary)) { return(data.frame(model = name)) }

    if (!is.null(summary0)) {
        a <- anova(model0, model)$`Pr(>Chi)`[2]
        lrt <- if (inherits(model, 'mdyplFit')) {
            brglm2::plrtest(model0, model)$`Pr(>Chi)`[2]
        } else {
            pchisq(
                2 * (summary$ll - summary0$ll), summary$df[1] - summary0$df[1],
                lower.tail = F)
        }
        aic_prob <- if (summary0$aic < summary$aic) { 1 } else {
            exp((summary$aic - summary0$aic) / 2)
        }
    } else { a <- NA; lrt <- NA; aic_prob <- NA }

    data.frame(
        model = name,
        deviance = summary$deviance,
        ll = summary$ll,
        df = summary$df[1],
        lrt = lrt,
        aic = summary$aic,
        aic_prob = aic_prob,
        anova = a
    )
}

process_pair <- function(pair) {
    split <- stringr::str_split_1(pair, '-')
    locus <- split[1]
    phenotype <- split[2]
    cat(sprintf('%s\n', pair))

    locus_annot <- local({
        locus_annot <- final_annot[final_annot$locus == locus,]
        vntr_vars <- select(locus_annot, starts_with('vntr')) |> apply(2, var)
        hgroup_vars <- select(locus_annot, starts_with('hgroup')) |> apply(2, var)
        locus_annot[, c(
            'sample',
            names(vntr_vars)[vntr_vars > 0] |> head(-1),
            names(hgroup_vars)[hgroup_vars > 0] |> head(-1)
        )]
    })
    curr_icd10_codes <- filter(icd10_codes, code == phenotype)
    curr_data <- inner_join(metadata, locus_annot, join_by(sample)) |>
        mutate(case = sample %in% curr_icd10_codes$sample)
    data_null <- select(curr_data, c(case, age, pca1, pca2, pca3, sex_female))
    data_full <- select(curr_data, c(case, age, pca1, pca2, pca3, sex_female),
        starts_with('hgroup'), starts_with('vntr'))

    models <- list()
    cat(sprintf('%s: Running GLM\n', pair))
    models$glm_full <- try(glm(case ~ ., data_full, family = 'binomial'))
    models$glm_null <- try(glm(case ~ ., data_null, family = 'binomial'))

    cat(sprintf('%s: Running BRGLM\n', pair))
    brglm2::brglmControl(maxit = 1000, epsilon = 1e-8)
    models$brglm_full <- try(glm(case ~ ., data_full, family = 'binomial', method = brglm2::brglm_fit))
    models$brglm_null <- try(glm(case ~ ., data_null, family = 'binomial', method = brglm2::brglm_fit))

    cat(sprintf('%s: Running MDYPL\n', pair))
    alpha <- local({
        n_obs <- nrow(data_full)
        n_fea <- ncol(data_full) - 1
        n_obs / (n_obs + n_fea)
    })
    models$mdypl_full <- try(glm(case ~ ., data_full,
        family = 'binomial', method = brglm2::mdypl_fit, alpha = alpha))
    models$mdypl_null <- try(glm(case ~ ., data_null,
        family = 'binomial', method = brglm2::mdypl_fit, alpha = alpha))

    summaries <- lapply(models, function(model) if (failed(model)) { NULL } else {
        s <- summary(model)
        s$ll <- as.numeric(logLik(model))
        s
    })
    names(summaries) |>
        lapply(function(name) {
            s <- summaries[[name]]
            if (is.null(s)) {
                data.frame(model = name)
            } else {
                coef(s) |> as.data.frame() |>
                    rownames_to_column('coefficient') |>
                    mutate(model = name)
            }
        }) %>%
        do.call(bind_rows, .) |>
        write.table(sprintf('res/%s.coef.csv', pair),
            sep = '\t', quote = F, row.names = F)

    bind_rows(
        summarize_model('glm_null', models$glm_null, summaries$glm_null),
        summarize_model('glm_full', models$glm_full, summaries$glm_full,
            models$glm_null, summaries$glm_null),

        summarize_model('brglm_null', models$brglm_null, summaries$brglm_null),
        summarize_model('brglm_full', models$brglm_full, summaries$brglm_full,
            models$brglm_null, summaries$brglm_null),

        summarize_model('mdypl_null', models$mdypl_null, summaries$mdypl_null),
        summarize_model('mdypl_full', models$mdypl_full, summaries$mdypl_full,
            models$mdypl_null, summaries$mdypl_null)
    ) |> write.table(sprintf('res/%s.summary.csv', pair),
        sep = '\t', quote = F, row.names = F)
    write.table(data.frame(), sprintf('res/%s.ok', pair), col.names = F)
}

# ===== Processing =====

load('~/data.RData')

filename <- commandArgs()[length(commandArgs())]
cat(sprintf('Reading pairs from %s\n', filename))
pairs <- readLines(filename)

for (pair in pairs) {
    process_pair(pair)
}
