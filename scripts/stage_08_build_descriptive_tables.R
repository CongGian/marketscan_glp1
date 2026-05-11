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
source("R/stage_08_descriptive_tables.R")

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
    stop(label, " must be an absolute path: ", path, call. = FALSE)
  }
  invisible(path)
}

qc_arg <- function(args, name) {
  value <- args[[paste0("qc-", name)]]
  if (is.null(value) || identical(value, TRUE) || !nzchar(value)) {
    return(NULL)
  }
  value
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))
cfg <- load_config(args$config %||% "config/config_template.yaml")

output_dir <- args[["output-dir"]] %||% stage08_default_output_dir(cfg)
require_absolute(output_dir, "Stage 08 output directory")

qc_paths <- list(
  stage02 = qc_arg(args, "stage02"),
  stage03 = qc_arg(args, "stage03"),
  stage04 = qc_arg(args, "stage04"),
  stage05 = qc_arg(args, "stage05"),
  stage06 = qc_arg(args, "stage06"),
  stage07 = qc_arg(args, "stage07")
)

result <- build_stage08_descriptive_tables(
  cfg = cfg,
  input_path = args[["input-file"]],
  output_dir = output_dir,
  qc_paths = qc_paths,
  db_path = args$db %||% ":memory:",
  threads = as.integer(args$threads %||% Sys.getenv("SLURM_CPUS_PER_TASK", "4")),
  memory_limit = args$memory %||% "32GB",
  temp_directory = args[["temp-dir"]] %||% cfg$paths$tmp_root,
  cell_suppression_threshold = as.integer(args[["cell-suppression-threshold"]] %||% "11"),
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("Stage 08 aggregate descriptive tables complete\n")
cat("Input:", result$input_path, "\n")
cat("Output directory:", result$output_dir, "\n")
cat("Cell suppression threshold:", result$cell_suppression_threshold, "\n")
cat("Aggregate CSV files:", length(result$output_paths), "\n")
for (path in result$output_paths) {
  cat("CSV:", path, "\n")
}
cat("No row-level data were printed. Outputs are aggregate summaries for approved analyst review.\n")
