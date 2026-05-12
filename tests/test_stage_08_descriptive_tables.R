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
source(repo_path("R", "stage_08_descriptive_tables.R"))

make_stage08_input <- function() {
  out <- data.frame(
    enrollee_id = rep(c("P001", "P002", "P003"), each = 3L),
    episode_number = 1L,
    episode_id = rep(c("P001_ep001", "P002_ep001", "P003_ep001"), each = 3L),
    index_date = rep(as.Date(c("2021-07-01", "2021-09-01", "2022-02-01")), each = 3L),
    index_year = rep(c(2021L, 2021L, 2022L), each = 3L),
    event_month = rep(-1L:1L, 3L),
    age_at_index = rep(c(50L, 60L, 70L), each = 3L),
    monthly_rx_fill_count = c(1L, 1L, 0L, 1L, 1L, 0L, 0L, 0L, 1L),
    monthly_medical_claim_count = c(1L, 0L, 1L, 0L, 1L, 0L, 0L, 0L, 2L),
    monthly_outpatient_claim_count = c(1L, 0L, 1L, 0L, 1L, 0L, 0L, 0L, 1L),
    monthly_inpatient_admissions = c(0L, 0L, 1L, 0L, 0L, 0L, 0L, 0L, 1L),
    monthly_ed_visits = c(0L, 0L, 1L, 0L, 0L, 0L, 0L, 0L, 1L),
    monthly_allowed_amount_rx = c(10, 20, 0, 15, 15, 0, 0, 0, 25),
    monthly_plan_paid_rx = c(8, 16, 0, 12, 12, 0, 0, 0, 20),
    monthly_patient_oop_rx = c(2, 4, 0, 3, 3, 0, 0, 0, 5),
    monthly_allowed_amount_glp1_like = c(0, 15, 0, 0, 12, 0, 0, 0, 20),
    monthly_plan_paid_glp1_like = c(0, 12, 0, 0, 10, 0, 0, 0, 16),
    monthly_patient_oop_glp1_like = c(0, 3, 0, 0, 2, 0, 0, 0, 4),
    monthly_allowed_amount_medical = c(100, 80, 200, 0, 30, 0, 0, 0, 150),
    monthly_plan_paid_medical = c(90, 72, 180, 0, 27, 0, 0, 0, 135),
    monthly_patient_oop_medical = c(10, 8, 20, 0, 3, 0, 0, 0, 15),
    baseline_medical_claim_count = rep(c(3L, 1L, 2L), each = 3L),
    baseline_outpatient_claim_count = rep(c(3L, 1L, 1L), each = 3L),
    baseline_inpatient_admissions = rep(c(0L, 0L, 1L), each = 3L),
    baseline_ed_visits = rep(c(0L, 0L, 1L), each = 3L),
    baseline_allowed_amount_medical = rep(c(350, 50, 225), each = 3L),
    baseline_plan_paid_medical = rep(c(315, 45, 200), each = 3L),
    baseline_patient_oop_medical = rep(c(35, 5, 25), each = 3L),
    drug_any_dpp4 = c(TRUE, TRUE, FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE),
    drug_any_glp1_like = c(FALSE, TRUE, TRUE, FALSE, TRUE, FALSE, FALSE, TRUE, TRUE),
    drug_any_metformin = c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, TRUE, TRUE, TRUE),
    baseline_condition_diabetes_any = TRUE,
    baseline_condition_obesity = rep(c(TRUE, FALSE, TRUE), each = 3L),
    baseline_condition_chronic_kidney_disease = rep(c(FALSE, TRUE, TRUE), each = 3L),
    stringsAsFactors = FALSE
  )
  out$monthly_allowed_amount_total <- out$monthly_allowed_amount_rx + out$monthly_allowed_amount_medical
  out$monthly_plan_paid_total <- out$monthly_plan_paid_rx + out$monthly_plan_paid_medical
  out$monthly_patient_oop_total <- out$monthly_patient_oop_rx + out$monthly_patient_oop_medical
  out$any_claim_month <- out$monthly_rx_fill_count > 0L | out$monthly_medical_claim_count > 0L
  out
}

test_that("Stage 08 writes aggregate descriptive CSVs on synthetic data", {
  tmp <- tempfile("stage08_synth_")
  dir.create(tmp, recursive = TRUE)

  input_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "person_month_dpp4_to_glp1_switchers.parquet")
  dir.create(dirname(input_path), recursive = TRUE)
  arrow::write_parquet(make_stage08_input(), input_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")

  result <- build_stage08_descriptive_tables(
    cfg = cfg,
    input_path = input_path,
    output_dir = file.path(tmp, "outputs", "dpp4_to_glp1", "figures", "data"),
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp"),
    cell_suppression_threshold = 0L
  )

  expected_files <- c(
    "event_time_medication_rates.csv",
    "treatment_state_event_time.csv",
    "event_time_utilization_rates.csv",
    "event_time_spending_summary.csv",
    "event_time_spending_distribution.csv",
    "event_time_spending_decomposition.csv",
    "baseline_condition_prevalence.csv",
    "baseline_comorbidity_category_prevalence.csv",
    "multimorbidity_burden.csv",
    "baseline_spending_utilization_summary.csv",
    "sample_structure.csv",
    "cohort_waterfall.csv"
  )
  expect_named(result$output_paths, tools::file_path_sans_ext(expected_files))
  expect_true(all(file.exists(file.path(result$output_dir, expected_files))))

  medications <- utils::read.csv(result$output_paths[["event_time_medication_rates"]], stringsAsFactors = FALSE)
  expect_true(any(
    medications$event_month == -1L &
      medications$drug_class == "dpp4" &
      medications$n_person_months == 3L &
      medications$exposed_count == 2L
  ))
  expect_true(any(
    medications$event_month == 0L &
      medications$drug_class == "glp1_like" &
      medications$exposed_count == 3L &
      medications$exposed_pct == 100
  ))

  states <- utils::read.csv(result$output_paths[["treatment_state_event_time"]], stringsAsFactors = FALSE)
  expect_true(any(
    states$event_month == 0L &
      states$treatment_state == "both" &
      states$n == 2L
  ))
  expect_true(any(
    states$event_month == 0L &
      states$treatment_state == "glp1_like_only" &
      states$n == 1L
  ))

  utilization <- utils::read.csv(result$output_paths[["event_time_utilization_rates"]], stringsAsFactors = FALSE)
  expect_true(any(
    utilization$event_month == 0L &
      utilization$metric == "monthly_rx_fill_count_gt0" &
      utilization$numerator == 2L &
      utilization$denominator == 3L
  ))

  spending <- utils::read.csv(result$output_paths[["event_time_spending_summary"]], stringsAsFactors = FALSE)
  oop_index <- spending[spending$event_month == 0L & spending$variable == "monthly_patient_oop_total", , drop = FALSE]
  expect_equal(oop_index$n, 3L)
  expect_equal(oop_index$mean, 6)
  expect_equal(oop_index$median, 6)
  expect_true("p99" %in% names(spending))

  distribution <- utils::read.csv(result$output_paths[["event_time_spending_distribution"]], stringsAsFactors = FALSE)
  total_index <- distribution[
    distribution$event_month == 0L &
      distribution$variable == "monthly_allowed_amount_total" &
      distribution$population == "all_person_months",
    ,
    drop = FALSE
  ]
  expect_equal(total_index$n, 3L)
  expect_equal(total_index$n_positive, 2L)
  expect_true("p99" %in% names(distribution))

  decomposition <- utils::read.csv(result$output_paths[["event_time_spending_decomposition"]], stringsAsFactors = FALSE)
  glp1_index <- decomposition[
    decomposition$event_month == 0L &
      decomposition$amount_type == "allowed_amount" &
      decomposition$component == "glp1_like_rx",
    ,
    drop = FALSE
  ]
  expect_equal(glp1_index$n, 3L)
  expect_equal(glp1_index$mean, 9)

  conditions <- utils::read.csv(result$output_paths[["baseline_condition_prevalence"]], stringsAsFactors = FALSE)
  expect_true(any(
    conditions$condition == "diabetes_any" &
      conditions$n_episodes == 3L &
      conditions$pct_episodes == 100
  ))
  expect_true(any(
    conditions$condition == "obesity" &
      conditions$n_episodes == 2L
  ))
  comorbidity <- utils::read.csv(result$output_paths[["baseline_comorbidity_category_prevalence"]], stringsAsFactors = FALSE)
  expect_true(any(
    comorbidity$category_set == "study_defined" &
      comorbidity$category == "obesity" &
      comorbidity$n_episodes == 2L
  ))

  burden <- utils::read.csv(result$output_paths[["multimorbidity_burden"]], stringsAsFactors = FALSE)
  expect_true(any(burden$condition_count == 2L & burden$n_episodes == 2L))
  expect_true(any(burden$condition_count == 3L & burden$n_episodes == 1L))

  baseline <- utils::read.csv(result$output_paths[["baseline_spending_utilization_summary"]], stringsAsFactors = FALSE)
  age <- baseline[baseline$variable == "age_at_index", , drop = FALSE]
  expect_equal(age$n, 3L)
  expect_equal(age$mean, 60)
  expect_equal(age$median, 60)

  structure <- utils::read.csv(result$output_paths[["sample_structure"]], stringsAsFactors = FALSE)
  expect_true(any(structure$metric == "episodes" & structure$n == 3L))
  expect_true(any(structure$metric == "person_month_rows" & structure$n == 9L))
  expect_true(any(structure$metric == "event_month" & structure$metric_value == "0" & structure$n == 3L))
  expect_true(any(structure$metric == "duplicate_episode_month_rows" & structure$n == 0L))

  waterfall <- utils::read.csv(result$output_paths[["cohort_waterfall"]], stringsAsFactors = FALSE)
  expect_true(any(waterfall$step == "stage07_final_episodes" & waterfall$n == 3L))
  expect_true(any(waterfall$step == "stage07_final_person_month_rows" & waterfall$n == 9L))
})
