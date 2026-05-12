library(testthat)

skip_if_not_installed("ggplot2")

repo_path <- function(...) {
  path <- file.path(...)
  if (file.exists(path)) {
    return(path)
  }
  file.path("..", path)
}

source(repo_path("R", "stage_08_descriptive_plots.R"))

write_stage08_csv <- function(dir, stem, data) {
  utils::write.csv(data, file.path(dir, paste0(stem, ".csv")), row.names = FALSE)
}

test_that("Stage 08 writes aggregate-only descriptive figures from synthetic CSVs", {
  tmp <- tempfile("stage08_plots_")
  data_dir <- file.path(tmp, "figures", "data")
  figure_dir <- file.path(tmp, "figures")
  dir.create(data_dir, recursive = TRUE)

  event_month <- -1L:1L

  write_stage08_csv(
    data_dir,
    "event_time_medication_rates",
    data.frame(
      event_month = rep(event_month, 3L),
      drug_class = rep(c("dpp4", "glp1_like", "metformin"), each = 3L),
      n_person_months = 100L,
      exposed_count = c(80, 45, 20, 10, 55, 85, 60, 58, 57),
      exposed_pct = c(80, 45, 20, 10, 55, 85, 60, 58, 57),
      suppressed = FALSE,
      stringsAsFactors = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "treatment_state_event_time",
    data.frame(
      event_month = rep(event_month, 2L),
      treatment_state = rep(c("dpp4_only", "glp1_like"), each = 3L),
      n = c(70, 40, 15, 30, 60, 85),
      pct = c(70, 40, 15, 30, 60, 85),
      suppressed = FALSE,
      stringsAsFactors = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "baseline_condition_prevalence",
    data.frame(
      condition = c("type2_diabetes", "obesity", "chronic_kidney_disease"),
      n_episodes = c(100, 42, 18),
      pct_episodes = c(100, 42, 18),
      suppressed = FALSE,
      stringsAsFactors = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "event_time_utilization_rates",
    data.frame(
      event_month = rep(event_month, 5L),
      metric = rep(
        c(
          "any_claim_month",
          "monthly_rx_fill_count_gt0",
          "monthly_outpatient_claim_count_gt0",
          "monthly_inpatient_admissions_gt0",
          "monthly_ed_visits_gt0"
        ),
        each = 3L
      ),
      numerator = c(65, 72, 70, 90, 93, 92, 50, 58, 54, 4, 5, 3, 8, 7, 9),
      denominator = 100L,
      rate_pct = c(65, 72, 70, 90, 93, 92, 50, 58, 54, 4, 5, 3, 8, 7, 9),
      suppressed = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "event_time_spending_summary",
    data.frame(
      event_month = rep(event_month, 3L),
      variable = rep(
        c("monthly_patient_oop_total", "monthly_patient_oop_rx", "monthly_patient_oop_medical"),
        each = 3L
      ),
      n = 100L,
      mean = c(30, 32, 34, 18, 19, 20, 12, 13, 14),
      sd = 1,
      p25 = 1,
      median = c(22, 24, 26, 12, 13, 14, 10, 11, 12),
      p75 = 3,
      p90 = 4,
      p95 = 5,
      suppressed = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "event_time_spending_distribution",
    data.frame(
      event_month = rep(event_month, 1L),
      variable = "monthly_allowed_amount_total",
      population = "all_person_months",
      n = 100L,
      n_positive = 90L,
      positive_pct = 90,
      mean = c(200, 260, 240),
      sd = 100,
      p25 = c(40, 50, 45),
      median = c(90, 120, 110),
      p75 = c(200, 280, 260),
      p90 = c(500, 620, 580),
      p95 = c(800, 950, 900),
      p99 = c(2000, 2500, 2300),
      suppressed = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "event_time_spending_decomposition",
    data.frame(
      event_month = rep(event_month, 9L),
      amount_type = rep(rep(c("allowed_amount", "plan_paid", "patient_oop"), each = 3L), each = 3L),
      component = rep(c("medical", "non_glp1_like_rx", "glp1_like_rx"), 9L),
      n = 100L,
      n_positive = 80L,
      positive_pct = 80,
      mean = c(
        100, 60, 10, 120, 55, 80, 110, 50, 95,
        90, 50, 8, 108, 45, 70, 99, 42, 85,
        10, 8, 2, 12, 10, 9, 11, 8, 10
      ),
      median = 0,
      p75 = 1,
      p90 = 2,
      p95 = 3,
      suppressed = FALSE
    )
  )

  write_stage08_csv(
    data_dir,
    "multimorbidity_burden",
    data.frame(
      condition_count = 0:3,
      n_episodes = c(15, 35, 30, 20),
      pct_episodes = c(15, 35, 30, 20),
      suppressed = FALSE
    )
  )

  result <- make_stage08_figures(
    data_dir = data_dir,
    figure_dir = figure_dir,
    formats = "png",
    width = 5,
    height = 3,
    dpi = 72
  )

  expected <- file.path(
    figure_dir,
    paste0(
      c(
        "event_time_medication_rates",
        "treatment_state_event_time",
        "baseline_condition_prevalence",
        "event_time_utilization_rates",
        "event_time_oop_spending",
        "event_time_allowed_spending_distribution",
        "event_time_allowed_spending_decomposition",
        "event_time_glp1_rx_payer_decomposition",
        "multimorbidity_burden"
      ),
      ".png"
    )
  )

  expect_equal(sort(basename(result$path)), sort(basename(expected)))
  expect_true(all(file.exists(expected)))
})

test_that("Stage 08 rejects obvious row-level identifiers in plotting inputs", {
  tmp <- tempfile("stage08_plots_ids_")
  data_dir <- file.path(tmp, "figures", "data")
  figure_dir <- file.path(tmp, "figures")
  dir.create(data_dir, recursive = TRUE)

  write_stage08_csv(
    data_dir,
    "baseline_condition_prevalence",
    data.frame(
      enrollee_id = "P001",
      condition = "obesity",
      pct_episodes = 50,
      stringsAsFactors = FALSE
    )
  )

  expect_error(
    make_stage08_figures(data_dir = data_dir, figure_dir = figure_dir, formats = "png"),
    "aggregate CSVs only"
  )
})
