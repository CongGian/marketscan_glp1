#!/usr/bin/env Rscript

parse_args <- function(args) {
  opts <- list(
    out_dir = file.path("outputs", "synthetic_marketscan"),
    format = "auto"
  )

  i <- 1L
  while (i <= length(args)) {
    arg <- args[[i]]
    if (arg %in% c("--out-dir", "-o")) {
      i <- i + 1L
      if (i > length(args)) stop("--out-dir requires a value", call. = FALSE)
      opts$out_dir <- args[[i]]
    } else if (arg %in% c("--format", "-f")) {
      i <- i + 1L
      if (i > length(args)) stop("--format requires one of: auto, parquet, csv", call. = FALSE)
      opts$format <- args[[i]]
    } else if (arg %in% c("--help", "-h")) {
      cat(
        "Usage: Rscript scripts/make_synthetic_data.R [--out-dir DIR] [--format auto|parquet|csv]\n",
        "\n",
        "Creates synthetic MarketScan-like D/T/I/S/O/F/A tables and synthetic code lists.\n",
        "No MarketScan data are read.\n",
        sep = ""
      )
      quit(status = 0)
    } else {
      stop("Unknown argument: ", arg, call. = FALSE)
    }
    i <- i + 1L
  }

  opts
}

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
if (is.na(script_path) || !nzchar(script_path)) {
  repo_root <- getwd()
} else {
  repo_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
}

source(file.path(repo_root, "R", "synthetic_data.R"))

opts <- parse_args(commandArgs(trailingOnly = TRUE))
result <- write_synthetic_dataset(opts$out_dir, format = opts$format)

cat("Synthetic dataset written\n")
cat("Output directory: ", result$out_dir, "\n", sep = "")
cat("Table format: ", result$format, "\n", sep = "")
cat("Data directory: ", result$data_dir, "\n", sep = "")
cat("Manifest: ", result$manifest_file, "\n", sep = "")
