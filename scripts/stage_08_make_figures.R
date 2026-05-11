#!/usr/bin/env Rscript

raw_args <- commandArgs(trailingOnly = FALSE)
file_arg <- raw_args[grepl("^--file=", raw_args)]
repo_root <- if (length(file_arg) > 0L) {
  normalizePath(file.path(dirname(sub("^--file=", "", file_arg[[1L]])), ".."), mustWork = TRUE)
} else {
  normalizePath(getwd(), mustWork = TRUE)
}
setwd(repo_root)

source("R/stage_08_descriptive_plots.R")

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

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))

data_dir <- args[["data-dir"]]
figure_dir <- args[["figure-dir"]]

if (is.null(data_dir) || is.null(figure_dir)) {
  source("R/config.R")
  cfg <- load_config(args$config %||% "config/config_template.yaml")
  data_dir <- data_dir %||% file.path(cfg$paths$output_root, "figures", "data")
  figure_dir <- figure_dir %||% file.path(cfg$paths$output_root, "figures")
}

result <- make_stage08_figures(
  data_dir = data_dir,
  figure_dir = figure_dir,
  formats = args$formats %||% "png",
  width = as.numeric(args$width %||% "9"),
  height = as.numeric(args$height %||% "5"),
  dpi = as.numeric(args$dpi %||% "300"),
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("Stage 08 aggregate figures complete\n")
cat("Aggregate data directory:", data_dir, "\n")
cat("Figure directory:", figure_dir, "\n")
if (nrow(result) == 0L) {
  cat("No figures were written because no recognized aggregate CSVs were present.\n")
} else {
  for (path in result$path) {
    cat("Figure:", path, "\n")
  }
}
cat("No row-level data were read or printed.\n")
