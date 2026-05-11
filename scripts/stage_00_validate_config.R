#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
config_path <- if (length(args) >= 1) args[[1]] else "config/config_template.yaml"

source("R/config.R")

cfg <- load_config(config_path)
invisible(validate_config(cfg))

cat("Config validated:", config_path, "\n")
cat("Project:", cfg$project$name, "\n")
cat("Years:", paste(cfg$study_period$data_years, collapse = ", "), "\n")
