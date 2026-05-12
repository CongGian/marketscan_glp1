library(testthat)

skip_if_not_installed("DBI")
skip_if_not_installed("duckdb")
skip_if_not_installed("arrow")

repo_path <- function(...) {
  path <- file.path(...)
  if (file.exists(path)) {
    return(path)
  }
  file.path("..", path)
}

source(repo_path("R", "config.R"))
source(repo_path("R", "duckdb_io.R"))
source(repo_path("R", "drug_episodes.R"))
source(repo_path("R", "synthetic_data.R"))
source(repo_path("R", "stage_01_drug_fills.R"))

test_that("Stage 01 extracts matched diabetes-drug fills from synthetic parquet", {
  tmp <- tempfile("stage01_synth_")
  dir.create(tmp, recursive = TRUE)
  synthetic <- write_synthetic_dataset(tmp, format = "parquet")

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$raw_root <- synthetic$data_dir
  cfg$paths$code_list_root <- file.path(tmp, "code_lists")
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$study_period$data_years <- 2021L

  output_path <- file.path(tmp, "derived", "drug_fills", "diabetes_drug_fills_2021.parquet")
  result <- extract_diabetes_drug_fills(
    cfg = cfg,
    years = 2021L,
    drug_classes = c("dpp4", "glp1", "glp1_like", "metformin"),
    output_path = output_path,
    threads = 1L,
    memory_limit = "1GB"
  )

  expect_true(file.exists(result$output_path))
  fills <- as.data.frame(arrow::read_parquet(result$output_path))

  expect_true(all(c(
    "enrollee_id", "fill_date", "claim_year", "ndc11", "drug_class",
    "days_supply", "allowed_amount", "plan_paid", "patient_oop"
  ) %in% names(fills)))
  expect_setequal(unique(fills$drug_class), c("dpp4", "glp1", "glp1_like"))
  expect_true(all(fills$claim_year == 2021L))
  expect_true(all(nchar(fills$ndc11) == 11L))
  expect_true(all(fills$days_supply > 0L))

  raw_glp1_rows <- sum(
    synthetic$tables$D$YEAR == 2021L &
      synthetic$tables$D$NDCNUM %in% unname(synthetic_ndc_codes()$glp1)
  )
  glp1_like_rows <- sum(fills$drug_class == "glp1_like")
  expect_equal(glp1_like_rows, raw_glp1_rows)

  example <- fills[fills$enrollee_id == "P007" & fills$drug_class == "glp1", , drop = FALSE]
  example <- example[order(example$fill_date), , drop = FALSE]
  expect_equal(example$patient_oop[[1L]], 465)
})
