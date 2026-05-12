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
source(repo_path("R", "stage_05_pharmacy_features.R"))

make_stage05_spine <- function() {
  data.frame(
    enrollee_id = "P001",
    episode_number = 1L,
    episode_id = "P001_ep001",
    index_date = as.Date("2021-07-01"),
    index_year = 2021L,
    event_month = -1L:1L,
    month_start = as.Date(c("2021-06-01", "2021-07-01", "2021-08-01")),
    month_end = as.Date(c("2021-06-30", "2021-07-31", "2021-08-31")),
    calendar_year = 2021L,
    calendar_month = 6L:8L,
    year_month = c("2021-06", "2021-07", "2021-08"),
    required_enrollment_start = as.Date("2020-07-01"),
    stringsAsFactors = FALSE
  )
}

make_stage05_drug_fills <- function() {
  data.frame(
    enrollee_id = c("P001", "P001", "P001", "P001"),
    fill_date = as.Date(c("2021-06-15", "2021-07-01", "2021-07-01", "2021-08-01")),
    claim_year = 2021L,
    ndc11 = c("11111111111", "22222222222", "22222222222", "22222222222"),
    drug_class = c("dpp4", "glp1", "glp1_like", "glp1_like"),
    code_list_name = c("dpp4_ndc.csv", "glp1_ndc.csv", "glp1_like_ndc.csv", "glp1_like_ndc.csv"),
    days_supply = c(30L, 28L, 28L, 28L),
    allowed_amount = c(100, 900, 900, 950),
    plan_paid = c(80, 830, 830, 875),
    copay = c(10, 20, 20, 25),
    coinsurance = c(0, 5, 5, 5),
    deductible = c(0, 0, 0, 10),
    patient_oop = c(10, 25, 25, 40),
    stringsAsFactors = FALSE
  )
}

make_stage05_raw_pharmacy <- function() {
  data.frame(
    ENROLID = c("P001", "P001", "P001"),
    SVCDATE = as.Date(c("2021-06-15", "2021-07-01", "2021-08-01")),
    PAY = c(100, 900, 950),
    NETPAY = c(80, 830, 875),
    COPAY = c(10, 20, 25),
    COINS = c(0, 5, 5),
    DEDUCT = c(0, 0, 10),
    stringsAsFactors = FALSE
  )
}

test_that("Stage 05 adds monthly pharmacy features without changing spine rows", {
  tmp <- tempfile("stage05_synth_")
  dir.create(tmp, recursive = TRUE)

  spine_path <- file.path(tmp, "derived", "person_month", "spine.parquet")
  drug_path <- file.path(tmp, "derived", "drug_fills", "diabetes_drug_fills_2021.parquet")
  raw_pharmacy_path <- file.path(tmp, "raw", "mscan_2021_d.parquet")
  dir.create(dirname(spine_path), recursive = TRUE)
  dir.create(dirname(drug_path), recursive = TRUE)
  dir.create(dirname(raw_pharmacy_path), recursive = TRUE)
  arrow::write_parquet(make_stage05_spine(), spine_path)
  arrow::write_parquet(make_stage05_drug_fills(), drug_path)
  arrow::write_parquet(make_stage05_raw_pharmacy(), raw_pharmacy_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")
  cfg$study_period$data_years <- 2021L
  cfg$outcomes_and_mediators$monthly_drug_classes <- c("dpp4", "glp1", "glp1_like")

  output_path <- file.path(tmp, "derived", "person_month", "with_pharmacy.parquet")
  qc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage05_counts.csv")

  result <- add_pharmacy_features(
    cfg = cfg,
    spine_path = spine_path,
    drug_fill_paths = drug_path,
    full_pharmacy_paths = raw_pharmacy_path,
    output_path = output_path,
    qc_path = qc_path,
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp")
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))

  out <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_equal(nrow(out), 3L)
  expect_true(all(c(
    "drug_any_dpp4", "drug_any_glp1_like", "drug_coverage_days_glp1_like",
    "monthly_rx_fill_count", "monthly_patient_oop_rx", "monthly_patient_oop_glp1_like"
  ) %in% names(out)))

  index_month <- out[out$event_month == 0L, , drop = FALSE]
  expect_true(isTRUE(index_month$drug_any_glp1_like[[1L]]))
  expect_equal(index_month$drug_fills_glp1_like[[1L]], 1L)
  expect_equal(index_month$drug_coverage_days_glp1_like[[1L]], 28L)
  expect_equal(index_month$monthly_rx_fill_count[[1L]], 1L)
  expect_equal(index_month$monthly_patient_oop_rx[[1L]], 25)
  expect_equal(index_month$monthly_patient_oop_glp1_like[[1L]], 25)

  baseline_month <- out[out$event_month == -1L, , drop = FALSE]
  expect_true(isTRUE(baseline_month$drug_any_dpp4[[1L]]))
  expect_equal(baseline_month$drug_coverage_days_dpp4[[1L]], 16L)
})
