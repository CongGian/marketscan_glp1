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
source(repo_path("R", "stage_07_final_sample.R"))

make_stage07_input <- function() {
  months <- as.Date(c("2021-06-01", "2021-07-01", "2021-08-01"))
  month_end <- function(x) seq(x, by = "month", length.out = 2L)[[2L]] - 1L
  data.frame(
    enrollee_id = rep(c("P001", "P002"), each = 3L),
    episode_number = 1L,
    episode_id = rep(c("P001_ep001", "P002_ep001"), each = 3L),
    index_date = as.Date("2021-07-01"),
    index_year = 2021L,
    event_month = rep(-1L:1L, 2L),
    month_start = rep(months, 2L),
    month_end = rep(as.Date(vapply(months, month_end, as.Date("1970-01-01")), origin = "1970-01-01"), 2L),
    age_at_index = rep(c(52L, 61L), each = 3L),
    sex = rep(c("1", "2"), each = 3L),
    region = rep(c("2", "3"), each = 3L),
    plan_type = rep(c("6", "8"), each = 3L),
    monthly_rx_fill_count = c(1L, 1L, 0L, 0L, 1L, 1L),
    monthly_medical_claim_count = c(1L, 0L, 2L, 0L, 1L, 0L),
    monthly_outpatient_claim_count = c(1L, 0L, 1L, 0L, 1L, 0L),
    monthly_inpatient_admissions = c(0L, 0L, 1L, 0L, 0L, 0L),
    monthly_ed_visits = c(0L, 0L, 1L, 0L, 0L, 0L),
    monthly_allowed_amount_rx = c(10, 20, 0, 0, 15, 25),
    monthly_plan_paid_rx = c(8, 16, 0, 0, 12, 20),
    monthly_patient_oop_rx = c(2, 4, 0, 0, 3, 5),
    monthly_allowed_amount_medical = c(100, 0, 250, 0, 50, 0),
    monthly_plan_paid_medical = c(90, 0, 225, 0, 45, 0),
    monthly_patient_oop_medical = c(10, 0, 25, 0, 5, 0),
    baseline_medical_claim_count = rep(c(3L, 1L), each = 3L),
    baseline_outpatient_claim_count = rep(c(3L, 1L), each = 3L),
    baseline_inpatient_admissions = rep(c(0L, 0L), each = 3L),
    baseline_ed_visits = rep(c(0L, 0L), each = 3L),
    baseline_allowed_amount_medical = rep(c(350, 50), each = 3L),
    baseline_plan_paid_medical = rep(c(315, 45), each = 3L),
    baseline_patient_oop_medical = rep(c(35, 5), each = 3L),
    drug_any_dpp4 = c(TRUE, FALSE, FALSE, TRUE, FALSE, FALSE),
    drug_any_glp1_like = c(FALSE, TRUE, TRUE, FALSE, TRUE, TRUE),
    baseline_condition_diabetes_any = TRUE,
    baseline_condition_obesity = rep(c(TRUE, FALSE), each = 3L),
    monthly_condition_hyperglycemia = c(TRUE, FALSE, FALSE, FALSE, TRUE, FALSE),
    stringsAsFactors = FALSE
  )
}

test_that("Stage 07 writes final sample and aggregate descriptives on synthetic data", {
  tmp <- tempfile("stage07_synth_")
  dir.create(tmp, recursive = TRUE)

  input_path <- file.path(tmp, "derived", "person_month", "with_pharmacy_medical.parquet")
  dir.create(dirname(input_path), recursive = TRUE)
  arrow::write_parquet(make_stage07_input(), input_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")

  result <- finalize_person_month_sample(
    cfg = cfg,
    input_path = input_path,
    output_path = file.path(tmp, "outputs", "dpp4_to_glp1", "final.parquet"),
    qc_path = file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage07_counts.csv"),
    baseline_descriptive_path = file.path(tmp, "outputs", "dpp4_to_glp1", "descriptives", "baseline.csv"),
    person_month_descriptive_path = file.path(tmp, "outputs", "dpp4_to_glp1", "descriptives", "person_month.csv"),
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp"),
    cell_suppression_threshold = 0L
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))
  expect_true(file.exists(result$baseline_descriptive_path))
  expect_true(file.exists(result$person_month_descriptive_path))

  out <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_equal(nrow(out), 6L)
  expect_true(all(c(
    "monthly_claim_count_total",
    "monthly_allowed_amount_total",
    "monthly_plan_paid_total",
    "monthly_patient_oop_total",
    "any_claim_month",
    "any_spending_month"
  ) %in% names(out)))
  expect_equal(out$monthly_patient_oop_total[out$enrollee_id == "P001" & out$event_month == -1L], 12)

  qc <- utils::read.csv(result$qc_path, stringsAsFactors = FALSE)
  expect_true(any(qc$metric == "episodes" & qc$row_count == 2L))
  expect_true(any(qc$metric == "duplicate_episode_month_rows" & qc$row_count == 0L))

  baseline <- utils::read.csv(result$baseline_descriptive_path, stringsAsFactors = FALSE)
  expect_true(any(baseline$variable == "baseline_condition" & baseline$level == "diabetes_any"))

  person_month <- utils::read.csv(result$person_month_descriptive_path, stringsAsFactors = FALSE)
  expect_true(any(person_month$variable == "monthly_patient_oop_total" & person_month$event_window == "all"))
  expect_true(any(person_month$variable == "drug_any" & person_month$level == "glp1_like"))
})
