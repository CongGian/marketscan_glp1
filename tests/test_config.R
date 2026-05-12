library(testthat)

config_r_path <- file.path("R", "config.R")
if (!file.exists(config_r_path)) {
  config_r_path <- file.path("..", "R", "config.R")
}
source(config_r_path)

template_path <- file.path("config", "config_template.yaml")
if (!file.exists(template_path)) {
  template_path <- file.path("..", "config", "config_template.yaml")
}

repo_root <- normalizePath(dirname(dirname(template_path)), mustWork = TRUE)

test_that("template loads and validates", {
  cfg <- load_config(template_path)

  expect_true(validate_config(cfg))
  expect_true(is.list(cfg))
  expect_equal(cfg$paths$raw_root, "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET")
  expect_equal(cfg$paths$code_list_root, "/PATH/TO/REPO/code_lists")
  expect_equal(cfg$study_period$data_years, 2017:2023)
  expect_equal(cfg$study_period$index_start, "2018-01-01")
  expect_equal(cfg$study_period$index_end, "2022-12-31")
})

test_that("required modules and variable mappings are present", {
  cfg <- load_config(template_path)

  expect_setequal(names(cfg$modules), c("A", "D", "F", "I", "O", "S", "T"))
  expect_equal(cfg$modules$A$pattern, "mscan_{year}_a.parquet")
  expect_equal(cfg$modules$D$pattern, "mscan_{year}_d.parquet")
  expect_equal(cfg$modules$F$pattern, "mscan_{year}_f.parquet")
  expect_equal(cfg$modules$I$pattern, "mscan_{year}_i.parquet")
  expect_equal(cfg$modules$O$pattern, "mscan_{year}_o.parquet")
  expect_equal(cfg$modules$S$pattern, "mscan_{year}_s.parquet")
  expect_equal(cfg$modules$T$pattern, "mscan_{year}_t.parquet")

  expect_equal(cfg$variables$common$enrollee_id, "ENROLID")
  expect_equal(cfg$variables$D$ndc, "NDCNUM")
  expect_equal(cfg$variables$D$fill_date, "SVCDATE")
  expect_equal(cfg$variables$D$days_supply, "DAYSUPP")
  expect_equal(cfg$variables$T$enrollment_start, "DTSTART")
  expect_equal(cfg$variables$T$enrollment_end, "DTEND")
  expect_true(all(c("DX1", "DX2", "DX3", "DX4") %in% cfg$variables$O$dx_fields))
  expect_true(all(c("PAY", "NETPAY", "COPAY", "COINS", "DEDUCT") %in% cfg$outcomes_and_mediators$spending_fields))
})

test_that("module file pattern expansion is deterministic and metadata-only", {
  cfg <- load_config(template_path)

  expect_equal(
    resolve_module_file(cfg, "D", 2021),
    "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2021_d.parquet"
  )
  expect_equal(
    resolve_module_file(cfg, "pharmacy_D", 2021),
    "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2021_d.parquet"
  )
  expect_equal(
    resolve_module_file(cfg, "T", 2023),
    "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2023_t.parquet"
  )

  paths <- resolve_module_files(cfg, modules = c("D", "T"), years = 2021:2022)
  expect_s3_class(paths, "data.frame")
  expect_equal(nrow(paths), 4L)
  expect_equal(paths$module, c("D", "D", "T", "T"))
  expect_equal(paths$year, c(2021L, 2022L, 2021L, 2022L))
  expect_equal(
    paths$path,
    c(
      "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2021_d.parquet",
      "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2022_d.parquet",
      "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2021_t.parquet",
      "/PATH/TO/RESTRICTED_MARKETSCAN_PARQUET/mscan_2022_t.parquet"
    )
  )
})

test_that("code-list paths resolve from configured root", {
  cfg <- load_config(template_path)
  cfg$paths$code_list_root <- file.path(repo_root, "code_lists")

  expect_equal(
    resolve_code_list_path(cfg, "drug_ndc", "glp1"),
    file.path(repo_root, "code_lists", "drug_ndc", "glp1_ndc.csv")
  )
  expect_equal(
    resolve_code_list_path(cfg, "dpp4"),
    file.path(repo_root, "code_lists", "drug_ndc", "dpp4_ndc.csv")
  )
  expect_equal(
    resolve_code_list_path(cfg, "diagnosis_groups", "type2_diabetes"),
    file.path(repo_root, "code_lists", "diagnosis_groups", "type2_diabetes_icd10cm.csv")
  )

  drug_paths <- resolve_code_list_paths(cfg, group = "drug_ndc", must_exist = TRUE)
  expect_true(all(file.exists(drug_paths)))
  expect_true("drug_ndc.glp1_like" %in% names(drug_paths))
  expect_true("drug_ndc.dpp4" %in% names(drug_paths))
})

test_that("invalid configs fail fast", {
  cfg <- load_config(template_path)

  cfg_missing_module <- cfg
  cfg_missing_module$modules$D <- NULL
  expect_error(validate_config(cfg_missing_module), "modules.D is required", fixed = TRUE)

  cfg_bad_year_pattern <- cfg
  cfg_bad_year_pattern$modules$D$pattern <- "mscan_d.parquet"
  expect_error(validate_config(cfg_bad_year_pattern), "must contain {year}", fixed = TRUE)
})
