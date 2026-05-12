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
source(repo_path("R", "stage_03_enrollment.R"))

make_stage03_candidates <- function() {
  data.frame(
    enrollee_id = c("P001", "P004", "P005"),
    episode_number = 1L,
    index_date = as.Date(c("2021-07-01", "2021-07-01", "2021-07-01")),
    index_year = 2021L,
    index_ndc11 = "22222222222",
    index_drug_class = "glp1_like",
    index_days_supply = 28L,
    prior_glp1_fill_date = as.Date(NA),
    days_since_prior_glp1 = NA_integer_,
    glp1_washout_pass = TRUE,
    dpp4_preindex_fill_count = 4L,
    last_dpp4_fill_preindex = as.Date("2021-06-01"),
    last_dpp4_coverage_end_preindex = as.Date("2021-06-30"),
    dpp4_gap_days_before_index = 0L,
    qualifying_dpp4_preindex = TRUE,
    dpp4_postindex_fill_count_0_120 = 0L,
    first_dpp4_fill_after_grace = as.Date(NA),
    dpp4_postindex_fill_after_grace = FALSE,
    dpp4_overlap_days_after_index = 0L,
    dpp4_continues_after_transition = FALSE,
    switch_back = FALSE,
    glp1_episode_end = as.Date("2021-09-28"),
    switch_class = "clean_replacement",
    classification = "clean_replacement",
    primary_clean_replacement = TRUE,
    stringsAsFactors = FALSE
  )
}

test_that("Stage 03 flags continuous enrollment on synthetic candidates", {
  tmp <- tempfile("stage03_synth_")
  dir.create(tmp, recursive = TRUE)
  synthetic <- write_synthetic_dataset(tmp, format = "parquet")

  candidate_path <- file.path(tmp, "derived", "switch_candidates", "candidates.parquet")
  dir.create(dirname(candidate_path), recursive = TRUE)
  arrow::write_parquet(make_stage03_candidates(), candidate_path)

  cfg <- load_config(repo_path("config", "config_template.yaml"))
  cfg$paths$raw_root <- synthetic$data_dir
  cfg$paths$derived_root <- file.path(tmp, "derived")
  cfg$paths$output_root <- file.path(tmp, "outputs", "dpp4_to_glp1")
  cfg$paths$tmp_root <- file.path(tmp, "tmp")
  cfg$study_period$data_years <- 2021L

  output_path <- file.path(tmp, "derived", "enrollment", "candidate_enrollment.parquet")
  qc_path <- file.path(tmp, "outputs", "dpp4_to_glp1", "qc", "stage03_counts.csv")

  result <- extract_candidate_enrollment(
    cfg = cfg,
    candidate_path = candidate_path,
    years = 2021L,
    output_path = output_path,
    qc_path = qc_path,
    threads = 1L,
    memory_limit = "1GB",
    temp_directory = file.path(tmp, "tmp")
  )

  expect_true(file.exists(result$output_path))
  expect_true(file.exists(result$qc_path))

  enrollment <- as.data.frame(arrow::read_parquet(result$output_path))
  expect_equal(nrow(enrollment), 3L)
  expect_true(all(c(
    "required_enrollment_start", "required_enrollment_end",
    "continuous_enrollment", "primary_clean_replacement_enrolled",
    "age_at_index", "sex", "region"
  ) %in% names(enrollment)))

  by_id <- setNames(enrollment$continuous_enrollment, enrollment$enrollee_id)
  expect_true(isTRUE(by_id[["P001"]]))
  expect_false(isTRUE(by_id[["P004"]]))
  expect_false(isTRUE(by_id[["P005"]]))

  p001 <- enrollment[enrollment$enrollee_id == "P001", , drop = FALSE]
  expect_equal(p001$required_enrollment_start[[1L]], as.Date("2020-07-01"))
  expect_equal(p001$required_enrollment_end[[1L]], as.Date("2022-07-31"))
  expect_true(isTRUE(p001$primary_clean_replacement_enrolled[[1L]]))
})
