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
source(repo_path("R", "stage_04_person_month_spine.R"))

make_stage04_input <- function() {
  data.frame(
    enrollee_id = c("P001", "P002", "P003"),
    episode_number = 1L,
    index_date = as.Date(c("2021-07-01", "2021-08-15", "2021-09-01")),
    index_year = 2021L,
    index_ndc11 = "22222222222",
    index_drug_class = "glp1_like",
    switch_class = "clean_replacement",
    classification = "clean_replacement",
    primary_clean_replacement = TRUE,
    required_enrollment_start = as.Date(c("2020-07-01", "2020-08-01", "2020-09-01")),
    required_enrollment_end = as.Date(c("2022-07-31", "2022-08-31", "2022-09-30")),
    continuous_enrollment = c(TRUE, TRUE, FALSE),
    enrollment_spell_start = as.Date(c("2020-07-01", "2020-08-01", "2020-09-01")),
    enrollment_spell_end = as.Date(c("2022-07-31", "2022-08-31", "2021-12-31")),
    age_at_index = c(52L, 67L, 44L),
    sex = c("1", "2", "1"),
    region = c("1", "2", "3"),
    health_plan = c("1", "1", "2"),
    plan_type = c("1", "2", "1"),
    rx_active_at_index = TRUE,
    medical_active_at_index = TRUE,
    primary_clean_replacement_enrolled = c(TRUE, TRUE, FALSE),
    stringsAsFactors = FALSE
  )
}

test_that("Stage 04 builds event-month spine for eligible enrolled clean replacements", {
  tmp <- tempfile("stage04_synth_")
  dir.create(tmp, recursive = TRUE)

  input_path <- file.path(tmp, "derived", "enrollment", "candidate_enrollment.parquet")
  dir.create(dirname(input_path), recursive = TRUE)
  arrow::write_parquet(make_stage04_input(), input_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")
  cfg$study_period$event_month_min <- -2L
  cfg$study_period$event_month_max <- 2L
  cfg$sample_restrictions$min_age <- 18L
  cfg$sample_restrictions$max_age <- 64L

  output_path <- file.path(tmp, "derived", "person_month", "spine.parquet")
  qc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage04_counts.csv")
  desc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "descriptives", "stage04_desc.csv")

  result <- build_person_month_spine(
    cfg = cfg,
    input_path = input_path,
    output_path = output_path,
    qc_path = qc_path,
    descriptive_path = desc_path,
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp")
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))
  expect_true(file.exists(result$descriptive_path))

  spine <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_equal(nrow(spine), 5L)
  expect_equal(unique(spine$enrollee_id), "P001")
  expect_equal(spine$event_month, -2L:2L)
  expect_equal(spine$year_month[spine$event_month == 0L], "2021-07")
  expect_equal(spine$year_month[spine$event_month == -2L], "2021-05")
  expect_true(all(c("baseline_month", "index_month", "followup_month") %in% names(spine)))

  desc <- utils::read.csv(result$descriptive_path, stringsAsFactors = FALSE)
  sample_row <- desc[desc$variable == "sample" & desc$level == "episodes", , drop = FALSE]
  expect_equal(sample_row$n, 1L)
})
