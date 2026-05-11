#!/usr/bin/env Rscript

raw_args <- commandArgs(trailingOnly = FALSE)
file_arg <- raw_args[grepl("^--file=", raw_args)]
repo_root <- if (length(file_arg) > 0L) {
  normalizePath(file.path(dirname(sub("^--file=", "", file_arg[[1L]])), ".."), mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}
setwd(repo_root)

source("R/config.R")
source("R/duckdb_io.R")
source("R/stage_07_final_sample.R")

parse_cli <- function(args) {
  out <- list()
  i <- 1L
  while (i <= length(args)) {
    arg <- args[[i]]
    if (!startsWith(arg, "--")) {
      stop("Unexpected positional argument: ", arg, call. = FALSE)
    }
    arg <- sub("^--", "", arg)
    if (grepl("=", arg, fixed = TRUE)) {
      parts <- strsplit(arg, "=", fixed = TRUE)[[1L]]
      out[[parts[[1L]]]] <- paste(parts[-1L], collapse = "=")
      i <- i + 1L
    } else if (i == length(args) || startsWith(args[[i + 1L]], "--")) {
      out[[arg]] <- TRUE
      i <- i + 1L
    } else {
      out[[arg]] <- args[[i + 1L]]
      i <- i + 2L
    }
  }
  out
}

require_absolute <- function(path, label) {
  if (!grepl("^/", path)) {
    stop(
      label,
      " must be absolute because Stage 07 writes restricted derived outputs: ",
      path,
      call. = FALSE
    )
  }
  invisible(path)
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))
cfg <- load_config(args$config %||% "config/config_template.yaml")

output_path <- args[["out-file"]] %||% stage07_default_output_path(cfg)
qc_path <- args[["qc-file"]] %||% stage07_default_qc_path(cfg)
baseline_path <- args[["baseline-descriptives"]] %||% stage07_default_baseline_descriptive_path(cfg)
person_month_path <- args[["person-month-descriptives"]] %||% stage07_default_person_month_descriptive_path(cfg)

require_absolute(output_path, "Stage 07 final parquet output")
require_absolute(qc_path, "Stage 07 QC output")
require_absolute(baseline_path, "Stage 07 baseline descriptive output")
require_absolute(person_month_path, "Stage 07 person-month descriptive output")

result <- finalize_person_month_sample(
  cfg = cfg,
  input_path = args[["input-file"]],
  output_path = output_path,
  qc_path = qc_path,
  baseline_descriptive_path = baseline_path,
  person_month_descriptive_path = person_month_path,
  db_path = args$db %||% ":memory:",
  threads = as.integer(args$threads %||% Sys.getenv("SLURM_CPUS_PER_TASK", "4")),
  memory_limit = args$memory %||% "32GB",
  temp_directory = args[["temp-dir"]] %||% cfg$paths$tmp_root,
  cell_suppression_threshold = as.integer(args[["cell-suppression-threshold"]] %||% "11"),
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("Stage 07 final sample assembly complete\n")
cat("Input:", result$input_path, "\n")
cat("Final person-month output:", result$output_path, "\n")
cat("QC:", result$qc_path, "\n")
cat("Baseline descriptives:", result$baseline_descriptive_path, "\n")
cat("Person-month descriptives:", result$person_month_descriptive_path, "\n")
cat("Cell suppression threshold:", result$cell_suppression_threshold, "\n")
cat("No row-level data were printed. Outputs are restricted derived data and must remain inside an approved workspace.\n")
