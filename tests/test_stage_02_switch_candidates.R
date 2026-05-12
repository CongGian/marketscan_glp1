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
source(repo_path("R", "synthetic_data.R"))
source(repo_path("R", "stage_02_switch_candidates.R"))

make_stage02_synthetic_fills <- function() {
  tables <- make_synthetic_marketscan_tables()
  ndc <- synthetic_ndc_codes()
  drug_map <- data.frame(
    ndc11 = c(unname(ndc$dpp4), unname(ndc$glp1)),
    drug_class = c(rep("dpp4", length(ndc$dpp4)), rep("glp1_like", length(ndc$glp1))),
    stringsAsFactors = FALSE
  )

  fills <- merge(
    data.frame(
      enrollee_id = tables$D$ENROLID,
      fill_date = tables$D$SVCDATE,
      claim_year = tables$D$YEAR,
      ndc11 = tables$D$NDCNUM,
      days_supply = tables$D$DAYSUPP,
      stringsAsFactors = FALSE
    ),
    drug_map,
    by = "ndc11",
    all.x = FALSE,
    sort = FALSE
  )
  fills[order(fills$enrollee_id, fills$fill_date, fills$drug_class), ]
}

test_that("Stage 02 classifies synthetic DPP-4 to GLP-1 switch candidates", {
  tmp <- tempfile("stage02_synth_")
  dir.create(tmp, recursive = TRUE)

  input_path <- file.path(tmp, "derived", "drug_fills", "diabetes_drug_fills_2020_2021.parquet")
  dir.create(dirname(input_path), recursive = TRUE)
  arrow::write_parquet(make_stage02_synthetic_fills(), input_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")
  cfg$study_period$data_years <- c(2020L, 2021L)
  cfg$study_period$index_start <- "2021-01-01"
  cfg$study_period$index_end <- "2021-12-31"

  output_path <- file.path(tmp, "derived", "switch_candidates", "candidates.parquet")
  qc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage02_counts.csv")

  result <- extract_switch_candidates(
    cfg = cfg,
    input_paths = input_path,
    output_path = output_path,
    qc_path = qc_path,
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp")
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))

  candidates <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_true(all(c(
    "enrollee_id", "index_date", "switch_class", "glp1_washout_pass",
    "qualifying_dpp4_preindex", "primary_clean_replacement"
  ) %in% names(candidates)))
  expect_equal(nrow(candidates), 8L)

  by_id <- setNames(candidates$switch_class, candidates$enrollee_id)
  expect_equal(by_id[["P001"]], "clean_replacement")
  expect_equal(by_id[["P002"]], "addon_or_overlap")
  expect_equal(by_id[["P003"]], "prior_glp1_washout_failure")
  expect_true(isTRUE(candidates$qualifying_dpp4_preindex[candidates$enrollee_id == "P001"]))
  expect_false(isTRUE(candidates$glp1_washout_pass[candidates$enrollee_id == "P003"]))
})
