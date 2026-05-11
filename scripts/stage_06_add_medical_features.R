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
source("R/stage_06_medical_features.R")

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

split_csv <- function(x) {
  if (is.null(x) || identical(x, TRUE) || !nzchar(x)) {
    return(NULL)
  }
  strsplit(gsub("\\s+", "", x), ",", fixed = TRUE)[[1L]]
}

args <- parse_cli(commandArgs(trailingOnly = TRUE))
cfg <- load_config(args$config %||% "config/config_template.yaml")

output_path <- args[["out-file"]] %||% stage06_default_output_path(cfg)
qc_path <- args[["qc-file"]] %||% stage06_default_qc_path(cfg)
for (path in c(output_path, qc_path)) {
  if (!grepl("^/", path)) {
    stop(
      "Stage 06 output paths must be absolute because this stage writes restricted row-level derived data: ",
      path,
      call. = FALSE
    )
  }
}

result <- add_medical_features(
  cfg = cfg,
  input_path = args[["input-file"]],
  outpatient_paths = split_csv(args[["outpatient-files"]]),
  inpatient_paths = split_csv(args[["inpatient-files"]]),
  years = parse_years(args$years),
  output_path = output_path,
  qc_path = qc_path,
  diagnosis_concepts = split_csv(args[["diagnosis-concepts"]]),
  db_path = args$db %||% ":memory:",
  threads = as.integer(args$threads %||% Sys.getenv("SLURM_CPUS_PER_TASK", "8")),
  memory_limit = args$memory %||% "64GB",
  temp_directory = args[["temp-dir"]] %||% cfg$paths$tmp_root,
  overwrite = !isTRUE(args[["no-overwrite"]])
)

cat("Stage 06 medical feature build complete\n")
cat("Input:", result$input_path, "\n")
cat("Outpatient files:", length(result$outpatient_paths), "\n")
cat("Inpatient files:", length(result$inpatient_paths), "\n")
cat("Diagnosis concepts:", paste(result$diagnosis_concepts, collapse = ","), "\n")
cat("Output:", result$output_path, "\n")
cat("QC:", result$qc_path, "\n")
cat("No row-level data were printed. Outputs are restricted derived data and must remain inside an approved workspace.\n")
