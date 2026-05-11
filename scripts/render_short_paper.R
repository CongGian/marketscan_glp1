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

usage <- function() {
  cat(
    "Usage:\n",
    "  Rscript scripts/render_short_paper.R --format docx\n",
    "\n",
    "Options:\n",
    "  --config PATH          Config YAML. Default: config/config_template.yaml\n",
    "  --data-dir PATH        Stage 08 aggregate CSV directory.\n",
    "  --figure-dir PATH      Stage 08 figure directory.\n",
    "  --output-dir PATH      Manuscript output directory.\n",
    "  --format LIST          Comma-separated: docx,pdf,html,md. Default: docx\n",
    "  --manuscript PATH      Rmd source. Default: manuscripts/dpp4_glp1_short_paper.Rmd\n",
    sep = ""
  )
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))
if (isTRUE(args$help)) {
  usage()
  quit(status = 0)
}

if (!requireNamespace("rmarkdown", quietly = TRUE)) {
  stop("The R package 'rmarkdown' is required to render DOCX/PDF/HTML outputs.", call. = FALSE)
}

cfg <- load_config(args$config %||% "config/config_template.yaml")
default_output_root <- path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1")
data_dir <- args[["data-dir"]] %||% file.path(default_output_root, "figures", "data")
figure_dir <- args[["figure-dir"]] %||% file.path(default_output_root, "figures")
output_dir <- args[["output-dir"]] %||% file.path(default_output_root, "manuscript")
manuscript <- args$manuscript %||% file.path("manuscripts", "dpp4_glp1_short_paper.Rmd")
formats <- unlist(strsplit(args$format %||% "docx", ",", fixed = TRUE), use.names = FALSE)
formats <- tolower(trimws(formats[nzchar(formats)]))

if (!file.exists(manuscript)) {
  stop("Manuscript source does not exist: ", manuscript, call. = FALSE)
}
if (!dir.exists(data_dir)) {
  stop("Stage 08 aggregate data directory does not exist: ", data_dir, call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

format_map <- list(
  docx = "word_document",
  pdf = "pdf_document",
  html = "html_document",
  md = "md_document"
)
unsupported <- setdiff(formats, names(format_map))
if (length(unsupported) > 0L) {
  stop("Unsupported manuscript format(s): ", paste(unsupported, collapse = ", "), call. = FALSE)
}

if (!rmarkdown::pandoc_available() && any(formats %in% c("docx", "pdf", "html", "md"))) {
  stop(
    "Pandoc is required for rmarkdown rendering but was not found by rmarkdown. ",
    "On Quartz, try `module load pandoc/3.1.10` and rerun this command. ",
    "Alternatively, render from an environment where rmarkdown::pandoc_available() is TRUE.",
    call. = FALSE
  )
}

cat("Rendering short paper from aggregate Stage 08 outputs\n")
cat("Data directory:", data_dir, "\n")
cat("Figure directory:", figure_dir, "\n")
cat("Output directory:", output_dir, "\n")

for (format in formats) {
  output_format <- format_map[[format]]
  output_file <- paste0("dpp4_glp1_short_paper.", format)
  cat("Rendering:", output_file, "\n")
  rmarkdown::render(
    input = manuscript,
    output_format = output_format,
    output_file = output_file,
    output_dir = output_dir,
    params = list(
      data_dir = normalizePath(data_dir, mustWork = TRUE),
      figure_dir = normalizePath(figure_dir, mustWork = FALSE),
      small_cell_threshold = 11L
    ),
    envir = new.env(parent = globalenv()),
    quiet = FALSE
  )
}

cat("Done. Manuscript outputs written under:", normalizePath(output_dir, mustWork = FALSE), "\n")
cat("No row-level data were read or printed; the manuscript uses aggregate CSVs only.\n")
