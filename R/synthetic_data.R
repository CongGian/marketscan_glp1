# Synthetic MarketScan-like tables for DPP-4 to GLP-1 pipeline tests.
#
# These fixtures are intentionally small and contain only artificial IDs,
# dates, codes, and dollar amounts. They do not read or depend on MarketScan.

synthetic_ndc_codes <- function() {
  list(
    dpp4 = c(
      sitagliptin = "11111111111",
      linagliptin = "11111111112"
    ),
    glp1 = c(
      semaglutide = "22222222222",
      liraglutide = "22222222223"
    ),
    metformin = c(
      metformin = "33333333333"
    )
  )
}

month_floor <- function(x) {
  as.Date(format(as.Date(x), "%Y-%m-01"))
}

month_end <- function(x) {
  x <- month_floor(x)
  as.Date(
    vapply(
      x,
      function(one_month) seq(one_month, by = "month", length.out = 2)[2] - 1,
      as.Date("1970-01-01")
    ),
    origin = "1970-01-01"
  )
}

seq_month_starts <- function(start_date, end_date) {
  seq(month_floor(start_date), month_floor(end_date), by = "month")
}

make_synthetic_case_key <- function() {
  data.frame(
    ENROLID = sprintf("P%03d", 1:8),
    SCENARIO = c(
      "clean_replacement",
      "addon_overlap",
      "prior_glp1_washout_failure",
      "incomplete_baseline_enrollment",
      "incomplete_followup_enrollment",
      "switch_back",
      "oop_shock",
      "baseline_comorbidity_diagnosis"
    ),
    INDEX_DATE = as.Date(rep("2021-07-01", 8)),
    ENROLL_START = as.Date(c(
      "2020-07-01", "2020-07-01", "2020-07-01", "2021-01-01",
      "2020-07-01", "2020-07-01", "2020-07-01", "2020-07-01"
    )),
    ENROLL_END = as.Date(c(
      "2022-07-31", "2022-07-31", "2022-07-31", "2022-07-31",
      "2021-12-31", "2022-07-31", "2022-07-31", "2022-07-31"
    )),
    EXPECTED_COHORT_STATUS = c(
      "eligible_clean_replacement",
      "ineligible_addon_overlap",
      "ineligible_prior_glp1",
      "ineligible_incomplete_baseline",
      "ineligible_incomplete_followup",
      "eligible_switch_back_sensitivity",
      "eligible_oop_shock",
      "eligible_baseline_comorbidity"
    ),
    stringsAsFactors = FALSE
  )
}

make_synthetic_enrollment_detail <- function(case_key) {
  rows <- lapply(seq_len(nrow(case_key)), function(i) {
    months <- seq_month_starts(case_key$ENROLL_START[i], case_key$ENROLL_END[i])
    enrolid <- case_key$ENROLID[i]
    age <- 45 + i
    data.frame(
      ENROLID = enrolid,
      DTSTART = months,
      DTEND = pmin(month_end(months), case_key$ENROLL_END[i]),
      RX = "1",
      AGE = age + as.integer(format(months, "%Y")) - 2021L,
      SEX = if (i %% 2 == 0) "2" else "1",
      REGION = c("1", "2", "3", "4")[(i - 1L) %% 4L + 1L],
      HLTHPLAN = "1",
      PLANTYP = c("1", "2")[(i - 1L) %% 2L + 1L],
      YEAR = as.integer(format(months, "%Y")),
      stringsAsFactors = FALSE
    )
  })

  do.call(rbind, rows)
}

make_synthetic_annual_enrollment <- function(enrollment_detail) {
  enrollment_detail$ENRMON_UNIT <- 1L
  enrollment_detail$RXMON_UNIT <- as.integer(enrollment_detail$RX == "1")

  enrollment_months <- aggregate(
    cbind(ENRMON_UNIT, RXMON_UNIT) ~ ENROLID + YEAR,
    data = enrollment_detail,
    FUN = sum
  )
  names(enrollment_months)[names(enrollment_months) == "ENRMON_UNIT"] <- "ENRMON"
  names(enrollment_months)[names(enrollment_months) == "RXMON_UNIT"] <- "RXMON"

  first_row <- enrollment_detail[
    !duplicated(paste(enrollment_detail$ENROLID, enrollment_detail$YEAR)),
    c("ENROLID", "YEAR", "AGE", "SEX", "REGION", "HLTHPLAN", "PLANTYP")
  ]

  annual <- merge(enrollment_months, first_row, by = c("ENROLID", "YEAR"), sort = TRUE)
  annual$MEDCOV <- "1"
  annual$RX <- ifelse(annual$RXMON > 0L, "1", "0")
  annual[order(annual$ENROLID, annual$YEAR), ]
}

make_synthetic_pharmacy <- function() {
  ndc <- synthetic_ndc_codes()

  fill <- function(enrolid, svdate, ndcnum, daysupp = 30L, qty = 30,
                   pay = 100, netpay = 80, copay = 10, coins = 0,
                   deduct = 0) {
    data.frame(
      ENROLID = enrolid,
      SVCDATE = as.Date(svdate),
      NDCNUM = ndcnum,
      DAYSUPP = as.integer(daysupp),
      QTY = qty,
      PAY = pay,
      NETPAY = netpay,
      COPAY = copay,
      COINS = coins,
      DEDUCT = deduct,
      stringsAsFactors = FALSE
    )
  }

  dpp4_dates <- c("2021-03-01", "2021-04-01", "2021-05-01", "2021-06-01")
  base_dpp4 <- function(enrolid) {
    do.call(rbind, lapply(
      dpp4_dates,
      function(x) fill(enrolid, x, ndc$dpp4[["sitagliptin"]], pay = 95, netpay = 78, copay = 7)
    ))
  }
  glp1_fill <- function(enrolid, svdate, copay = 25, coins = 5, deduct = 0) {
    fill(
      enrolid, svdate, ndc$glp1[["semaglutide"]],
      daysupp = 28L, qty = 1, pay = 950, netpay = 850,
      copay = copay, coins = coins, deduct = deduct
    )
  }

  pharmacy <- rbind(
    base_dpp4("P001"),
    glp1_fill("P001", "2021-07-01"),
    glp1_fill("P001", "2021-08-01"),
    glp1_fill("P001", "2021-09-01"),

    base_dpp4("P002"),
    glp1_fill("P002", "2021-07-01"),
    glp1_fill("P002", "2021-08-01"),
    fill("P002", "2021-07-20", ndc$dpp4[["linagliptin"]], pay = 110, netpay = 90, copay = 8),
    fill("P002", "2021-08-20", ndc$dpp4[["linagliptin"]], pay = 110, netpay = 90, copay = 8),

    glp1_fill("P003", "2020-11-01"),
    base_dpp4("P003"),
    glp1_fill("P003", "2021-07-01"),

    fill("P004", "2021-05-01", ndc$dpp4[["sitagliptin"]], pay = 95, netpay = 78, copay = 7),
    fill("P004", "2021-06-01", ndc$dpp4[["sitagliptin"]], pay = 95, netpay = 78, copay = 7),
    glp1_fill("P004", "2021-07-01"),

    base_dpp4("P005"),
    glp1_fill("P005", "2021-07-01"),
    glp1_fill("P005", "2021-08-01"),

    base_dpp4("P006"),
    glp1_fill("P006", "2021-07-01"),
    glp1_fill("P006", "2021-08-01"),
    fill("P006", "2021-11-01", ndc$dpp4[["sitagliptin"]], pay = 95, netpay = 78, copay = 7),
    fill("P006", "2021-12-01", ndc$dpp4[["sitagliptin"]], pay = 95, netpay = 78, copay = 7),

    base_dpp4("P007"),
    glp1_fill("P007", "2021-07-01", copay = 175, coins = 40, deduct = 250),
    glp1_fill("P007", "2021-08-01", copay = 160, coins = 30, deduct = 125),

    base_dpp4("P008"),
    glp1_fill("P008", "2021-07-01"),
    glp1_fill("P008", "2021-08-01")
  )

  pharmacy$YEAR <- as.integer(format(pharmacy$SVCDATE, "%Y"))
  pharmacy[order(pharmacy$ENROLID, pharmacy$SVCDATE, pharmacy$NDCNUM), ]
}

make_synthetic_outpatient <- function() {
  outpatient <- data.frame(
    ENROLID = c("P001", "P007", "P008", "P008"),
    MSCLMID = c("P001_O001", "P007_O001", "P008_O001", "P008_O002"),
    FACHDID = c(NA_character_, NA_character_, NA_character_, NA_character_),
    SVCDATE = as.Date(c("2021-02-15", "2021-04-12", "2021-01-15", "2021-03-01")),
    TSVCDAT = as.Date(c("2021-02-15", "2021-04-12", "2021-01-15", "2021-03-01")),
    DX1 = c("E119", "E119", "E669", "N183"),
    DX2 = c(NA_character_, NA_character_, "E119", "E669"),
    DX3 = c(NA_character_, NA_character_, NA_character_, NA_character_),
    DX4 = c(NA_character_, NA_character_, NA_character_, NA_character_),
    PROC1 = c("99213", "99214", "99213", "99213"),
    PROCGRP = c("01", "01", "01", "01"),
    STDPLAC = c("11", "11", "11", "11"),
    PAY = c(125, 150, 135, 135),
    NETPAY = c(100, 120, 110, 110),
    COPAY = c(20, 25, 15, 15),
    COINS = c(0, 0, 0, 0),
    DEDUCT = c(0, 0, 0, 0),
    stringsAsFactors = FALSE
  )
  outpatient$YEAR <- as.integer(format(outpatient$SVCDATE, "%Y"))
  outpatient
}

make_synthetic_inpatient <- function() {
  inpatient <- data.frame(
    ENROLID = "P008",
    CASEID = "P008_CASE001",
    ADMDATE = as.Date("2021-02-10"),
    DISDATE = as.Date("2021-02-12"),
    DX1 = "N183",
    DX2 = "E119",
    DX3 = NA_character_,
    DX4 = NA_character_,
    PROC1 = "0JH60DZ",
    PROC2 = NA_character_,
    DXVER = "0",
    STDPLAC = "21",
    TOTPAY = 12500,
    TOTNET = 11000,
    YEAR = 2021L,
    stringsAsFactors = FALSE
  )

  inpatient
}

make_synthetic_inpatient_services <- function() {
  data.frame(
    ENROLID = c("P008", "P008"),
    CASEID = c("P008_CASE001", "P008_CASE001"),
    MSCLMID = c("P008_S001", "P008_S002"),
    FACHDID = c("P008_F001", "P008_F001"),
    SVCDATE = as.Date(c("2021-02-10", "2021-02-11")),
    TSVCDAT = as.Date(c("2021-02-10", "2021-02-11")),
    DX1 = c("N183", "N183"),
    DX2 = c("E119", "E119"),
    DX3 = c(NA_character_, NA_character_),
    DX4 = c(NA_character_, NA_character_),
    PROC1 = c("99223", "99232"),
    STDPLAC = c("21", "21"),
    PAY = c(2500, 1800),
    NETPAY = c(2200, 1600),
    COPAY = c(50, 0),
    COINS = c(100, 80),
    DEDUCT = c(500, 0),
    YEAR = c(2021L, 2021L),
    stringsAsFactors = FALSE
  )
}

make_synthetic_facility_header <- function() {
  data.frame(
    ENROLID = "P008",
    CASEID = "P008_CASE001",
    MSCLMID = "P008_FH001",
    FACHDID = "P008_F001",
    SVCDATE = as.Date("2021-02-10"),
    TSVCDAT = as.Date("2021-02-12"),
    BILLTYP = "111",
    DX1 = "N183",
    DX2 = "E119",
    DX3 = NA_character_,
    DX4 = NA_character_,
    PROC1 = "0JH60DZ",
    PROC2 = NA_character_,
    STDPLAC = "21",
    NETPAY = 11000,
    COPAY = 50,
    COINS = 180,
    DEDUCT = 500,
    YEAR = 2021L,
    stringsAsFactors = FALSE
  )
}

make_synthetic_marketscan_tables <- function() {
  case_key <- make_synthetic_case_key()
  enrollment_detail <- make_synthetic_enrollment_detail(case_key)

  list(
    A = make_synthetic_annual_enrollment(enrollment_detail),
    D = make_synthetic_pharmacy(),
    F = make_synthetic_facility_header(),
    I = make_synthetic_inpatient(),
    O = make_synthetic_outpatient(),
    S = make_synthetic_inpatient_services(),
    T = enrollment_detail,
    case_key = case_key
  )
}

make_synthetic_code_lists <- function() {
  ndc <- synthetic_ndc_codes()

  list(
    drug_ndc = list(
      dpp4_ndc = data.frame(
        NDC11 = unname(ndc$dpp4),
        drug_class = "dpp4",
        ingredient = names(ndc$dpp4),
        synthetic = TRUE,
        stringsAsFactors = FALSE
      ),
      glp1_ndc = data.frame(
        NDC11 = unname(ndc$glp1),
        drug_class = "glp1",
        ingredient = names(ndc$glp1),
        synthetic = TRUE,
        stringsAsFactors = FALSE
      ),
      glp1_like_ndc = data.frame(
        NDC11 = unname(ndc$glp1),
        drug_class = "glp1_like",
        ingredient = names(ndc$glp1),
        synthetic = TRUE,
        stringsAsFactors = FALSE
      ),
      metformin_ndc = data.frame(
        NDC11 = unname(ndc$metformin),
        drug_class = "metformin",
        ingredient = names(ndc$metformin),
        synthetic = TRUE,
        stringsAsFactors = FALSE
      )
    ),
    diagnosis_groups = list(
      diabetes_any_icd10cm = data.frame(
        code = c("E119"),
        concept = "diabetes_any",
        match_type = "exact",
        synthetic = TRUE,
        stringsAsFactors = FALSE
      ),
      obesity_icd10cm = data.frame(
        code = c("E669"),
        concept = "obesity",
        match_type = "exact",
        synthetic = TRUE,
        stringsAsFactors = FALSE
      ),
      chronic_kidney_disease_icd10cm = data.frame(
        code = c("N183"),
        concept = "chronic_kidney_disease",
        match_type = "exact",
        synthetic = TRUE,
        stringsAsFactors = FALSE
      )
    )
  )
}

write_one_table <- function(x, path_base, format = c("auto", "parquet", "csv")) {
  format <- match.arg(format)
  use_arrow <- format == "parquet" ||
    (format == "auto" && requireNamespace("arrow", quietly = TRUE))

  if (use_arrow && !requireNamespace("arrow", quietly = TRUE)) {
    stop("format = 'parquet' requires the arrow package.", call. = FALSE)
  }

  if (use_arrow) {
    path <- paste0(path_base, ".parquet")
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(x, path)
    return(path)
  }

  path <- paste0(path_base, ".csv")
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(x, path, row.names = FALSE, na = "")
  path
}

write_code_list <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(x, path, row.names = FALSE, na = "")
  path
}

write_synthetic_dataset <- function(out_dir, format = c("auto", "parquet", "csv")) {
  format <- match.arg(format)
  out_dir <- normalizePath(out_dir, mustWork = FALSE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  tables <- make_synthetic_marketscan_tables()
  table_dir <- if (format == "csv" ||
    (format == "auto" && !requireNamespace("arrow", quietly = TRUE))) {
    file.path(out_dir, "csv")
  } else {
    file.path(out_dir, "parquet")
  }

  table_files <- list(
    A = write_one_table(tables$A, file.path(table_dir, "mscan_2021_a"), format),
    D = write_one_table(tables$D, file.path(table_dir, "mscan_2021_d"), format),
    F = write_one_table(tables$F, file.path(table_dir, "mscan_2021_f"), format),
    I = write_one_table(tables$I, file.path(table_dir, "mscan_2021_i"), format),
    O = write_one_table(tables$O, file.path(table_dir, "mscan_2021_o"), format),
    S = write_one_table(tables$S, file.path(table_dir, "mscan_2021_s"), format),
    T = write_one_table(tables$T, file.path(table_dir, "mscan_2021_t"), format)
  )

  case_key_file <- write_code_list(
    tables$case_key,
    file.path(out_dir, "synthetic_case_key.csv")
  )

  code_lists <- make_synthetic_code_lists()
  code_list_files <- list()
  for (group_name in names(code_lists)) {
    for (list_name in names(code_lists[[group_name]])) {
      code_list_files[[paste(group_name, list_name, sep = "/")]] <- write_code_list(
        code_lists[[group_name]][[list_name]],
        file.path(out_dir, "code_lists", group_name, paste0(list_name, ".csv"))
      )
    }
  }

  manifest <- data.frame(
    artifact = c(
      paste0("table_", names(table_files)),
      "synthetic_case_key",
      paste0("code_list_", names(code_list_files))
    ),
    path = c(unlist(table_files, use.names = FALSE), case_key_file, unlist(code_list_files, use.names = FALSE)),
    synthetic_only = TRUE,
    stringsAsFactors = FALSE
  )
  manifest_file <- write_code_list(manifest, file.path(out_dir, "synthetic_manifest.csv"))

  invisible(list(
    out_dir = out_dir,
    data_dir = table_dir,
    format = ifelse(grepl("\\.parquet$", table_files$D), "parquet", "csv"),
    table_files = table_files,
    case_key_file = case_key_file,
    code_list_files = code_list_files,
    manifest_file = manifest_file,
    tables = tables
  ))
}
