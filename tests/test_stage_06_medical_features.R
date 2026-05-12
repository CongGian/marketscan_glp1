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
source(repo_path("R", "stage_06_medical_features.R"))

make_stage06_person_month <- function() {
  months <- seq(as.Date("2021-01-01"), as.Date("2021-07-01"), by = "month")
  month_end <- function(x) seq(x, by = "month", length.out = 2L)[[2L]] - 1L
  data.frame(
    enrollee_id = rep(c("P001", "P008"), each = length(months)),
    episode_number = 1L,
    episode_id = rep(c("P001_ep001", "P008_ep001"), each = length(months)),
    index_date = as.Date("2021-07-01"),
    index_year = 2021L,
    event_month = rep(-6L:0L, 2L),
    month_start = rep(months, 2L),
    month_end = rep(as.Date(vapply(months, month_end, as.Date("1970-01-01")), origin = "1970-01-01"), 2L),
    required_enrollment_start = as.Date("2020-07-01"),
    stringsAsFactors = FALSE
  )
}

test_that("Stage 06 adds medical utilization and diagnosis features on synthetic data", {
  tmp <- tempfile("stage06_synth_")
  dir.create(tmp, recursive = TRUE)
  synthetic <- write_synthetic_dataset(tmp, format = "parquet")

  input_path <- file.path(tmp, "derived", "person_month", "with_pharmacy.parquet")
  dir.create(dirname(input_path), recursive = TRUE)
  arrow::write_parquet(make_stage06_person_month(), input_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$raw_root <- synthetic$data_dir
  cfg$paths$code_list_root <- file.path(tmp, "code_lists")
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")
  cfg$study_period$data_years <- 2021L
  cfg$outcomes_and_mediators$baseline_conditions <- c("diabetes_any", "obesity", "chronic_kidney_disease")

  output_path <- file.path(tmp, "derived", "person_month", "with_medical.parquet")
  qc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage06_counts.csv")

  result <- add_medical_features(
    cfg = cfg,
    input_path = input_path,
    years = 2021L,
    output_path = output_path,
    qc_path = qc_path,
    diagnosis_concepts = c("diabetes_any", "obesity", "chronic_kidney_disease"),
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp")
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))

  out <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_equal(nrow(out), 14L)
  expect_true(all(c(
    "monthly_medical_claim_count", "monthly_outpatient_claim_count",
    "monthly_inpatient_admissions", "baseline_condition_diabetes_any",
    "baseline_condition_obesity", "baseline_condition_chronic_kidney_disease"
  ) %in% names(out)))

  p001 <- out[out$enrollee_id == "P001" & out$event_month == -5L, , drop = FALSE]
  expect_equal(p001$monthly_outpatient_claim_count[[1L]], 1L)
  expect_true(isTRUE(p001$monthly_condition_diabetes_any[[1L]]))
  expect_true(isTRUE(p001$baseline_condition_diabetes_any[[1L]]))

  p008 <- out[out$enrollee_id == "P008" & out$event_month == -5L, , drop = FALSE]
  expect_true(isTRUE(p008$baseline_condition_obesity[[1L]]))
  expect_true(isTRUE(p008$baseline_condition_chronic_kidney_disease[[1L]]))
  expect_true(any(out$monthly_inpatient_admissions[out$enrollee_id == "P008"] > 0L))
})
