suppressPackageStartupMessages(library(testthat))

synthetic_data_path <- if (file.exists(file.path("R", "synthetic_data.R"))) {
  file.path("R", "synthetic_data.R")
} else {
  file.path("..", "R", "synthetic_data.R")
}
source(synthetic_data_path)

read_synthetic_table <- function(path) {
  if (grepl("\\.parquet$", path)) {
    skip_if_not_installed("arrow")
    return(as.data.frame(arrow::read_parquet(path)))
  }

  utils::read.csv(path, stringsAsFactors = FALSE)
}

test_that("synthetic dataset writes all expected tables and code lists", {
  out_dir <- tempfile("synthetic_marketscan_")
  result <- write_synthetic_dataset(out_dir)

  expect_setequal(names(result$table_files), c("A", "D", "F", "I", "O", "S", "T"))
  expect_true(all(file.exists(unlist(result$table_files))))
  expect_true(file.exists(result$case_key_file))
  expect_true(file.exists(result$manifest_file))

  required_code_lists <- c(
    "drug_ndc/dpp4_ndc",
    "drug_ndc/glp1_ndc",
    "drug_ndc/glp1_like_ndc",
    "diagnosis_groups/obesity_icd10cm",
    "diagnosis_groups/chronic_kidney_disease_icd10cm"
  )
  expect_true(all(required_code_lists %in% names(result$code_list_files)))
  expect_true(all(file.exists(unlist(result$code_list_files[required_code_lists]))))
})

test_that("synthetic D table has required MarketScan-like pharmacy columns", {
  out_dir <- tempfile("synthetic_marketscan_")
  result <- write_synthetic_dataset(out_dir)
  d <- read_synthetic_table(result$table_files$D)

  expect_true(all(c(
    "ENROLID", "SVCDATE", "NDCNUM", "DAYSUPP", "QTY",
    "PAY", "NETPAY", "COPAY", "COINS", "DEDUCT"
  ) %in% names(d)))
  expect_true(all(grepl("^P[0-9]{3}$", d$ENROLID)))
  expect_true(all(grepl("^[0-9]{11}$", as.character(d$NDCNUM))))
})

test_that("pharmacy NDCs are present in generated synthetic code lists", {
  out_dir <- tempfile("synthetic_marketscan_")
  result <- write_synthetic_dataset(out_dir)
  d <- read_synthetic_table(result$table_files$D)

  dpp4 <- utils::read.csv(result$code_list_files[["drug_ndc/dpp4_ndc"]], stringsAsFactors = FALSE)
  glp1 <- utils::read.csv(result$code_list_files[["drug_ndc/glp1_ndc"]], stringsAsFactors = FALSE)
  listed_ndcs <- unique(c(as.character(dpp4$NDC11), as.character(glp1$NDC11)))

  expect_true(all(unique(as.character(d$NDCNUM)) %in% listed_ndcs))
})

test_that("synthetic cases cover the cohort edge cases", {
  out_dir <- tempfile("synthetic_marketscan_")
  result <- write_synthetic_dataset(out_dir)
  case_key <- utils::read.csv(result$case_key_file, stringsAsFactors = FALSE)

  expect_true(all(grepl("^P[0-9]{3}$", case_key$ENROLID)))
  expect_setequal(case_key$SCENARIO, c(
    "clean_replacement",
    "addon_overlap",
    "prior_glp1_washout_failure",
    "incomplete_baseline_enrollment",
    "incomplete_followup_enrollment",
    "switch_back",
    "oop_shock",
    "baseline_comorbidity_diagnosis"
  ))
})

test_that("every table uses synthetic enrollee IDs only", {
  out_dir <- tempfile("synthetic_marketscan_")
  result <- write_synthetic_dataset(out_dir)

  for (module in names(result$table_files)) {
    tbl <- read_synthetic_table(result$table_files[[module]])
    expect_true("ENROLID" %in% names(tbl), info = module)
    expect_true(all(grepl("^P[0-9]{3}$", tbl$ENROLID)), info = module)
  }
})
