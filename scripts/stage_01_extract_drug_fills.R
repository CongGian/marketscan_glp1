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
source("R/drug_episodes.R")
source("R/stage_01_drug_fills.R")

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
    } else {
      if (i == length(args) || startsWith(args[[i + 1L]], "--")) {
        out[[arg]] <- TRUE
        i <- i + 1L
      } else {
        out[[arg]] <- args[[i + 1L]]
        i <- i + 2L
      }
    }
  }
  out
}

parse_years <- function(x) {
  if (is.null(x) || identical(x, TRUE) || !nzchar(x)) {
    return(NULL)
  }
  x <- gsub("\\s+", "", x)
  if (grepl("^\\d{4}:\\d{4}$", x)) {
    parts <- as.integer(strsplit(x, ":", fixed = TRUE)[[1L]])
    return(seq(parts[[1L]], parts[[2L]]))
  }
  as.integer(strsplit(x, ",", fixed = TRUE)[[1L]])
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))

config_path <- args$config %||% "config/config_template.yaml"
cfg <- load_config(config_path)

years <- parse_years(args$years)
classes <- if (is.null(args$classes) || identical(args$classes, TRUE)) {
  NULL
} else {
  strsplit(gsub("\\s+", "", args$classes), ",", fixed = TRUE)[[1L]]
}
threads <- as.integer(args$threads %||% Sys.getenv("SLURM_CPUS_PER_TASK", "4"))
memory_limit <- args$memory %||% "32GB"
db_path <- args$db %||% ":memory:"

output_path <- args[["out-file"]]
if (is.null(output_path) && !is.null(args[["out-dir"]])) {
  years_for_name <- years %||% cfg$study_period$data_years
  output_path <- file.path(
    args[["out-dir"]],
    sprintf("diabetes_drug_fills_%s.parquet", stage01_year_label(years_for_name))
  )
}
if (is.null(output_path)) {
  years_for_name <- years %||% cfg$study_period$data_years
  output_path <- default_stage01_output_path(cfg, years_for_name)
}
if (!grepl("^/", output_path)) {
  stop(
    "Stage 01 output path must be absolute because it writes restricted row-level derived data: ",
    output_path,
    call. = FALSE
  )
}

result <- extract_diabetes_drug_fills(
  cfg = cfg,
  years = years,
  drug_classes = classes,
  output_path = output_path,
  db_path = db_path,
  threads = threads,
  memory_limit = memory_limit,
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("Stage 01 diabetes-drug fill extraction complete\n")
cat("Years:", paste(result$years, collapse = ","), "\n")
cat("Drug classes:", paste(result$drug_classes, collapse = ","), "\n")
cat("Output:", result$output_path, "\n")
cat("No row-level data were printed. The output parquet is derived restricted data and must remain inside an approved workspace.\n")
