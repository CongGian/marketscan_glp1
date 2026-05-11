#!/usr/bin/env Rscript

if (!requireNamespace("testthat", quietly = TRUE)) {
  stop("The R package 'testthat' is required to run tests.", call. = FALSE)
}

setwd(normalizePath(file.path(getwd()), mustWork = TRUE))

test_files <- list.files("tests", pattern = "^test.*\\.R$", full.names = TRUE)
if (length(test_files) == 0) {
  message("No tests found under tests/.")
  quit(status = 0)
}

results <- testthat::test_dir("tests", reporter = "summary")
invisible(results)
