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
source("R/stage_08_glp1_waterfall.R")

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

split_csv <- function(x) {
  if (is.null(x) || identical(x, TRUE) || !nzchar(x)) {
    return(NULL)
  }
  strsplit(x, ",", fixed = TRUE)[[1L]]
}

require_absolute <- function(path, label) {
  if (!grepl("^/", path)) {
    stop(label, " must be absolute: ", path, call. = FALSE)
  }
  invisible(path)
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))
cfg <- load_config(args$config %||% "config/config_template.yaml")
output_path <- args[["out-file"]] %||% stage08_glp1_default_output_path(cfg)
require_absolute(output_path, "GLP-1 waterfall output")

result <- build_stage08_glp1_waterfall(
  cfg = cfg,
  drug_fill_paths = split_csv(args[["drug-fill-files"]]),
  stage02_path = args[["stage02-file"]],
  stage03_path = args[["stage03-file"]],
  final_path = args[["final-file"]],
  output_path = output_path,
  db_path = args$db %||% ":memory:",
  threads = as.integer(args$threads %||% Sys.getenv("SLURM_CPUS_PER_TASK", "4")),
  memory_limit = args$memory %||% "32GB",
  temp_directory = args[["temp-dir"]] %||% cfg$paths$tmp_root,
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("GLP-1 user waterfall aggregate complete\n")
cat("Index period:", result$period_start, "to", result$period_end, "\n")
cat("Drug-fill files:", length(result$drug_fill_paths), "\n")
cat("Stage 02:", result$stage02_path, "\n")
cat("Stage 03:", result$stage03_path, "\n")
cat("Final person-month:", result$final_path, "\n")
cat("Output:", result$output_path, "\n")
cat("No row-level data were printed. Output is aggregate only.\n")
