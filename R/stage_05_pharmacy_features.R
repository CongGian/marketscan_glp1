# Stage 05: add monthly pharmacy treatment and Rx spending features.
#
# This stage enriches the Stage 04 person-month spine with diabetes-drug fill
# counts, coverage days, drug-state indicators, and pharmacy spending/OOP
# variables. Drug-state indicators and diabetes-drug spending use Stage 01
# reduced drug-fill intermediates. Optional all-pharmacy spending uses raw D
# module files and remains restricted row-level derived data.

.stage05_required_functions <- function() {
  required <- c(
    "validate_config",
    "resolve_module_files",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_file_list",
    "sql_quote_string",
    "sql_quote_identifier",
    "normalize_sql_date_expr",
    "copy_query_to_parquet"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 05 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage05_default_spine_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_spine_clean_replacement.parquet"
  )
}

stage05_default_drug_fill_paths <- function(cfg, years = NULL) {
  validate_config(cfg)
  if (is.null(years) || length(years) == 0L) {
    years <- cfg$study_period$data_years
  }
  years <- sort(unique(as.integer(years)))
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "drug_fills",
    sprintf("diabetes_drug_fills_%s.parquet", years)
  )
}

stage05_default_full_pharmacy_paths <- function(cfg, years = NULL) {
  validate_config(cfg)
  if (is.null(years) || length(years) == 0L) {
    years <- cfg$study_period$data_years
  }
  years <- sort(unique(as.integer(years)))
  resolve_module_files(cfg, modules = "D", years = years, must_exist = TRUE)$path
}

stage05_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_with_pharmacy.parquet"
  )
}

stage05_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage05_pharmacy_feature_counts.csv"
  )
}

.stage05_check_files <- function(paths, label) {
  if (length(paths) == 0L) {
    stop("No ", label, " file paths were supplied.", call. = FALSE)
  }
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0L) {
    stop(
      label,
      " file(s) do not exist:\n",
      paste(missing, collapse = "\n"),
      call. = FALSE
    )
  }
  invisible(paths)
}

.stage05_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
  temp_directory <- temp_directory %||% cfg$paths$tmp_root
  if (!is.null(temp_directory) && nzchar(temp_directory)) {
    dir.create(temp_directory, recursive = TRUE, showWarnings = FALSE)
    DBI::dbExecute(
      con,
      sprintf("SET temp_directory=%s;", sql_quote_string(normalizePath(temp_directory, mustWork = FALSE)))
    )
  }
  invisible(TRUE)
}

.stage05_describe_parquet_columns <- function(con, paths) {
  desc <- DBI::dbGetQuery(
    con,
    sprintf(
      "DESCRIBE SELECT * FROM read_parquet(%s, union_by_name=true);",
      sql_file_list(paths)
    )
  )
  names(desc) <- tolower(names(desc))
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for raw pharmacy files.", call. = FALSE)
  }
  desc$column_name
}

.stage05_sanitize_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x[x == "" | is.na(x)] <- "missing"
  starts_with_digit <- grepl("^[0-9]", x)
  x[starts_with_digit] <- paste0("x", x[starts_with_digit])
  x
}

stage05_drug_classes <- function(cfg, override = NULL) {
  validate_config(cfg)
  classes <- if (!is.null(override) && length(override) > 0L) {
    override
  } else {
    cfg$outcomes_and_mediators$monthly_drug_classes
  }
  if (is.null(classes) || length(classes) == 0L) {
    classes <- c("glp1_like", "dpp4", "metformin", "insulin", "sglt2")
  }
  unique(as.character(classes))
}

.stage05_class_expressions <- function(classes) {
  pieces <- character()
  for (drug_class in classes) {
    suffix <- .stage05_sanitize_name(drug_class)
    cls <- sql_quote_string(drug_class)
    pieces <- c(
      pieces,
      sprintf(
        "COALESCE(SUM(CASE WHEN f.drug_class = %s AND f.fill_date BETWEEN s.month_start AND s.month_end THEN 1 ELSE 0 END), 0)::INTEGER AS drug_fills_%s",
        cls,
        suffix
      ),
      sprintf(
        "COALESCE(SUM(CASE WHEN f.drug_class = %s THEN greatest(0, date_diff('day', greatest(f.fill_date, s.month_start), least(f.fill_end, s.month_end)) + 1) ELSE 0 END), 0)::INTEGER AS drug_coverage_days_%s",
        cls,
        suffix
      ),
      sprintf(
        "(COALESCE(SUM(CASE WHEN f.drug_class = %s THEN greatest(0, date_diff('day', greatest(f.fill_date, s.month_start), least(f.fill_end, s.month_end)) + 1) ELSE 0 END), 0) > 0) AS drug_any_%s",
        cls,
        suffix
      ),
      sprintf(
        "COALESCE(SUM(CASE WHEN f.drug_class = %s AND f.fill_date BETWEEN s.month_start AND s.month_end THEN COALESCE(f.patient_oop, 0) ELSE 0 END), 0)::DOUBLE AS monthly_patient_oop_%s",
        cls,
        suffix
      ),
      sprintf(
        "COALESCE(SUM(CASE WHEN f.drug_class = %s AND f.fill_date BETWEEN s.month_start AND s.month_end THEN COALESCE(f.allowed_amount, 0) ELSE 0 END), 0)::DOUBLE AS monthly_allowed_amount_%s",
        cls,
        suffix
      ),
      sprintf(
        "COALESCE(SUM(CASE WHEN f.drug_class = %s AND f.fill_date BETWEEN s.month_start AND s.month_end THEN COALESCE(f.plan_paid, 0) ELSE 0 END), 0)::DOUBLE AS monthly_plan_paid_%s",
        cls,
        suffix
      )
    )
  }
  pieces
}

.stage05_select_columns <- function(classes) {
  cols <- character()
  for (drug_class in classes) {
    suffix <- .stage05_sanitize_name(drug_class)
    cols <- c(
      cols,
      sprintf("COALESCE(cm.drug_fills_%1$s, 0) AS drug_fills_%1$s", suffix),
      sprintf("COALESCE(cm.drug_coverage_days_%1$s, 0) AS drug_coverage_days_%1$s", suffix),
      sprintf("COALESCE(cm.drug_any_%1$s, FALSE) AS drug_any_%1$s", suffix),
      sprintf("COALESCE(cm.monthly_patient_oop_%1$s, 0) AS monthly_patient_oop_%1$s", suffix),
      sprintf("COALESCE(cm.monthly_allowed_amount_%1$s, 0) AS monthly_allowed_amount_%1$s", suffix),
      sprintf("COALESCE(cm.monthly_plan_paid_%1$s, 0) AS monthly_plan_paid_%1$s", suffix)
    )
  }
  cols
}

.stage05_optional_numeric_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("COALESCE(TRY_CAST(%s AS DOUBLE), 0) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(0 AS DOUBLE) AS %s", sql_quote_identifier(alias))
  }
}

.stage05_all_rx_ctes <- function(cfg, full_pharmacy_paths = NULL, full_pharmacy_columns = NULL) {
  if (is.null(full_pharmacy_paths) || length(full_pharmacy_paths) == 0L) {
    return(paste(
      "all_rx_fills AS (",
      "  SELECT",
      "    concat('reduced_rx:', CAST(row_number() OVER () AS VARCHAR)) AS rx_claim_id,",
      "    enrollee_id, fill_date, allowed_amount, plan_paid, patient_oop",
      "  FROM unique_rx_fills",
      "),",
      sep = "\n"
    ))
  }

  vars <- cfg$variables$D
  required <- unname(c(vars$enrollee_id, vars$fill_date))
  missing <- setdiff(required, full_pharmacy_columns)
  if (length(missing) > 0L) {
    stop("Raw pharmacy D parquet is missing required column(s): ", paste(missing, collapse = ", "), call. = FALSE)
  }

  allowed <- .stage05_optional_numeric_expr(full_pharmacy_columns, vars$allowed_amount, "allowed_amount")
  plan <- .stage05_optional_numeric_expr(full_pharmacy_columns, vars$plan_paid, "plan_paid")
  copay <- .stage05_optional_numeric_expr(full_pharmacy_columns, vars$copay, "copay")
  coins <- .stage05_optional_numeric_expr(full_pharmacy_columns, vars$coinsurance, "coinsurance")
  ded <- .stage05_optional_numeric_expr(full_pharmacy_columns, vars$deductible, "deductible")

  sprintf(
    paste(
      "all_rx_raw AS (",
      "  SELECT",
      "    concat('D:', CAST(row_number() OVER () AS VARCHAR)) AS rx_claim_id,",
      "    CAST(%s AS VARCHAR) AS enrollee_id,",
      "    %s AS fill_date,",
      "    %s, %s, %s, %s, %s",
      "  FROM read_parquet(%s, union_by_name=true)",
      "), all_rx_fills AS (",
      "  SELECT",
      "    r.rx_claim_id,",
      "    r.enrollee_id,",
      "    r.fill_date,",
      "    r.allowed_amount,",
      "    r.plan_paid,",
      "    COALESCE(r.copay, 0) + COALESCE(r.coinsurance, 0) + COALESCE(r.deductible, 0) AS patient_oop",
      "  FROM all_rx_raw r",
      "  INNER JOIN spine_ids ids ON r.enrollee_id = ids.enrollee_id",
      "  WHERE r.enrollee_id IS NOT NULL",
      "    AND r.enrollee_id <> ''",
      "    AND r.fill_date IS NOT NULL",
      "),",
      sep = "\n"
    ),
    sql_quote_identifier(vars$enrollee_id),
    normalize_sql_date_expr(sql_quote_identifier(vars$fill_date)),
    allowed,
    plan,
    copay,
    coins,
    ded,
    sql_file_list(full_pharmacy_paths)
  )
}

.stage05_build_query <- function(cfg, spine_path, drug_fill_paths, drug_classes = NULL,
                                 full_pharmacy_paths = NULL, full_pharmacy_columns = NULL) {
  validate_config(cfg)
  classes <- stage05_drug_classes(cfg, drug_classes)
  all_rx_ctes <- .stage05_all_rx_ctes(
    cfg = cfg,
    full_pharmacy_paths = full_pharmacy_paths,
    full_pharmacy_columns = full_pharmacy_columns
  )

  sprintf(
    paste(
      "WITH spine AS (",
      "  SELECT * FROM read_parquet(%s, union_by_name=true)",
      "), spine_ids AS (",
      "  SELECT DISTINCT CAST(enrollee_id AS VARCHAR) AS enrollee_id FROM spine",
      "), drug_fills_raw AS (",
      "  SELECT",
      "    CAST(enrollee_id AS VARCHAR) AS enrollee_id,",
      "    CAST(fill_date AS DATE) AS fill_date,",
      "    CAST(ndc11 AS VARCHAR) AS ndc11,",
      "    CAST(drug_class AS VARCHAR) AS drug_class,",
      "    CAST(days_supply AS INTEGER) AS days_supply,",
      "    COALESCE(CAST(allowed_amount AS DOUBLE), 0) AS allowed_amount,",
      "    COALESCE(CAST(plan_paid AS DOUBLE), 0) AS plan_paid,",
      "    COALESCE(CAST(patient_oop AS DOUBLE), 0) AS patient_oop",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE enrollee_id IS NOT NULL",
      "    AND fill_date IS NOT NULL",
      "    AND ndc11 IS NOT NULL",
      "    AND drug_class IS NOT NULL",
      "    AND days_supply IS NOT NULL",
      "    AND days_supply > 0",
      "    AND days_supply <= 365",
      "), drug_fills AS (",
      "  SELECT f.*, f.fill_date + CAST(f.days_supply - 1 AS INTEGER) AS fill_end",
      "  FROM drug_fills_raw f",
      "  INNER JOIN spine_ids ids ON f.enrollee_id = ids.enrollee_id",
      "), unique_rx_fills AS (",
      "  SELECT DISTINCT",
      "    enrollee_id, fill_date, ndc11, days_supply,",
      "    allowed_amount, plan_paid, patient_oop",
      "  FROM drug_fills",
      "),",
      "    %s",
      "all_rx_month AS (",
      "  SELECT",
      "    s.enrollee_id, s.episode_id, s.event_month,",
      "    COALESCE(COUNT(a.rx_claim_id), 0)::INTEGER AS monthly_all_rx_fill_count,",
      "    COALESCE(SUM(a.patient_oop), 0)::DOUBLE AS monthly_patient_oop_all_rx,",
      "    COALESCE(SUM(a.allowed_amount), 0)::DOUBLE AS monthly_allowed_amount_all_rx,",
      "    COALESCE(SUM(a.plan_paid), 0)::DOUBLE AS monthly_plan_paid_all_rx",
      "  FROM spine s",
      "  LEFT JOIN all_rx_fills a",
      "    ON a.enrollee_id = s.enrollee_id",
      "   AND a.fill_date BETWEEN s.month_start AND s.month_end",
      "  GROUP BY s.enrollee_id, s.episode_id, s.event_month",
      "), baseline_all_rx AS (",
      "  SELECT",
      "    s.enrollee_id, s.episode_id,",
      "    COALESCE(COUNT(a.rx_claim_id), 0)::INTEGER AS baseline_all_rx_fill_count,",
      "    COALESCE(SUM(a.patient_oop), 0)::DOUBLE AS baseline_patient_oop_all_rx,",
      "    COALESCE(SUM(a.allowed_amount), 0)::DOUBLE AS baseline_allowed_amount_all_rx,",
      "    COALESCE(SUM(a.plan_paid), 0)::DOUBLE AS baseline_plan_paid_all_rx",
      "  FROM (SELECT DISTINCT enrollee_id, episode_id, required_enrollment_start, index_date FROM spine) s",
      "  LEFT JOIN all_rx_fills a",
      "    ON a.enrollee_id = s.enrollee_id",
      "   AND a.fill_date >= s.required_enrollment_start",
      "   AND a.fill_date < s.index_date",
      "  GROUP BY s.enrollee_id, s.episode_id",
      "), class_month AS (",
      "  SELECT",
      "    s.enrollee_id, s.episode_id, s.event_month,",
      "    %s",
      "  FROM spine s",
      "  LEFT JOIN drug_fills f",
      "    ON f.enrollee_id = s.enrollee_id",
      "   AND f.fill_date <= s.month_end",
      "   AND f.fill_end >= s.month_start",
      "  GROUP BY s.enrollee_id, s.episode_id, s.event_month",
      "), rx_month AS (",
      "  SELECT",
      "    s.enrollee_id, s.episode_id, s.event_month,",
      "    COALESCE(COUNT(u.ndc11), 0)::INTEGER AS monthly_rx_fill_count,",
      "    COALESCE(SUM(u.patient_oop), 0)::DOUBLE AS monthly_patient_oop_rx,",
      "    COALESCE(SUM(u.allowed_amount), 0)::DOUBLE AS monthly_allowed_amount_rx,",
      "    COALESCE(SUM(u.plan_paid), 0)::DOUBLE AS monthly_plan_paid_rx",
      "  FROM spine s",
      "  LEFT JOIN unique_rx_fills u",
      "    ON u.enrollee_id = s.enrollee_id",
      "   AND u.fill_date BETWEEN s.month_start AND s.month_end",
      "  GROUP BY s.enrollee_id, s.episode_id, s.event_month",
      ")",
      "SELECT",
      "  s.*,",
      "  COALESCE(rm.monthly_rx_fill_count, 0) AS monthly_rx_fill_count,",
      "  COALESCE(rm.monthly_patient_oop_rx, 0) AS monthly_patient_oop_rx,",
      "  COALESCE(rm.monthly_allowed_amount_rx, 0) AS monthly_allowed_amount_rx,",
      "  COALESCE(rm.monthly_plan_paid_rx, 0) AS monthly_plan_paid_rx,",
      "  COALESCE(rm.monthly_rx_fill_count, 0) AS monthly_diabetes_rx_fill_count,",
      "  COALESCE(rm.monthly_patient_oop_rx, 0) AS monthly_patient_oop_diabetes_rx,",
      "  COALESCE(rm.monthly_allowed_amount_rx, 0) AS monthly_allowed_amount_diabetes_rx,",
      "  COALESCE(rm.monthly_plan_paid_rx, 0) AS monthly_plan_paid_diabetes_rx,",
      "  COALESCE(arm.monthly_all_rx_fill_count, 0) AS monthly_all_rx_fill_count,",
      "  COALESCE(arm.monthly_patient_oop_all_rx, 0) AS monthly_patient_oop_all_rx,",
      "  COALESCE(arm.monthly_allowed_amount_all_rx, 0) AS monthly_allowed_amount_all_rx,",
      "  COALESCE(arm.monthly_plan_paid_all_rx, 0) AS monthly_plan_paid_all_rx,",
      "  COALESCE(bar.baseline_all_rx_fill_count, 0) AS baseline_all_rx_fill_count,",
      "  COALESCE(bar.baseline_patient_oop_all_rx, 0) AS baseline_patient_oop_all_rx,",
      "  COALESCE(bar.baseline_allowed_amount_all_rx, 0) AS baseline_allowed_amount_all_rx,",
      "  COALESCE(bar.baseline_plan_paid_all_rx, 0) AS baseline_plan_paid_all_rx,",
      "  %s",
      "FROM spine s",
      "LEFT JOIN class_month cm",
      "  ON s.enrollee_id = cm.enrollee_id",
      " AND s.episode_id = cm.episode_id",
      " AND s.event_month = cm.event_month",
      "LEFT JOIN rx_month rm",
      "  ON s.enrollee_id = rm.enrollee_id",
      " AND s.episode_id = rm.episode_id",
      " AND s.event_month = rm.event_month",
      "LEFT JOIN all_rx_month arm",
      "  ON s.enrollee_id = arm.enrollee_id",
      " AND s.episode_id = arm.episode_id",
      " AND s.event_month = arm.event_month",
      "LEFT JOIN baseline_all_rx bar",
      "  ON s.enrollee_id = bar.enrollee_id",
      " AND s.episode_id = bar.episode_id",
      "ORDER BY s.index_year, s.enrollee_id, s.episode_number, s.event_month",
      sep = "\n"
    ),
    sql_quote_string(spine_path),
    sql_file_list(drug_fill_paths),
    all_rx_ctes,
    paste(.stage05_class_expressions(classes), collapse = ",\n    "),
    paste(.stage05_select_columns(classes), collapse = ",\n  ")
  )
}

.stage05_qc_query <- function(classes) {
  class_rows <- vapply(classes, function(drug_class) {
    suffix <- .stage05_sanitize_name(drug_class)
    sprintf(
      "SELECT 'person_months_with_drug_any' AS metric, %s AS metric_value, SUM(CASE WHEN drug_any_%s THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage05_person_month_pharmacy",
      sql_quote_string(drug_class),
      suffix
    )
  }, character(1L))

  paste(
    "SELECT metric, metric_value, row_count",
    "FROM (",
    "  SELECT 'episodes' AS metric, 'all' AS metric_value, count(DISTINCT episode_id)::BIGINT AS row_count FROM stage05_person_month_pharmacy",
    "  UNION ALL",
    "  SELECT 'person_month_rows' AS metric, 'all' AS metric_value, count(*)::BIGINT AS row_count FROM stage05_person_month_pharmacy",
    "  UNION ALL",
    "  SELECT 'event_month' AS metric, CAST(event_month AS VARCHAR) AS metric_value, count(*)::BIGINT AS row_count FROM stage05_person_month_pharmacy GROUP BY event_month",
    "  UNION ALL",
    "  SELECT 'person_months_with_any_rx_fill' AS metric, 'all' AS metric_value, SUM(CASE WHEN monthly_rx_fill_count > 0 THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage05_person_month_pharmacy",
    "  UNION ALL",
    "  SELECT 'person_months_with_any_all_rx_fill' AS metric, 'all' AS metric_value, SUM(CASE WHEN monthly_all_rx_fill_count > 0 THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage05_person_month_pharmacy",
    if (length(class_rows) > 0L) paste("  UNION ALL", paste(class_rows, collapse = "\n  UNION ALL\n")) else "",
    ")",
    "ORDER BY metric, metric_value",
    sep = "\n"
  )
}

.stage05_copy_qc <- function(con, qc_path, classes, overwrite = TRUE) {
  if (is.null(qc_path) || !nzchar(qc_path)) {
    return(invisible(NULL))
  }
  if (file.exists(qc_path)) {
    if (!isTRUE(overwrite)) {
      stop("QC output already exists: ", qc_path, call. = FALSE)
    }
    unlink(qc_path)
  }
  dir.create(dirname(qc_path), recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(
    con,
    sprintf(
      "COPY (%s) TO %s (HEADER, DELIMITER ',');",
      .stage05_qc_query(classes),
      sql_quote_string(qc_path)
    )
  )
  invisible(qc_path)
}

add_pharmacy_features <- function(cfg,
                                  spine_path = NULL,
                                  drug_fill_paths = NULL,
                                  full_pharmacy_paths = NULL,
                                  years = NULL,
                                  output_path = NULL,
                                  qc_path = NULL,
                                  drug_classes = NULL,
                                  db_path = ":memory:",
                                  threads = 8L,
                                  memory_limit = "64GB",
                                  temp_directory = NULL,
                                  overwrite = TRUE) {
  .stage05_required_functions()
  validate_config(cfg)

  spine_path <- spine_path %||% stage05_default_spine_path(cfg)
  spine_path <- normalizePath(spine_path, mustWork = FALSE)
  .stage05_check_files(spine_path, "Stage 04 person-month spine")

  if (is.null(drug_fill_paths) || length(drug_fill_paths) == 0L) {
    drug_fill_paths <- stage05_default_drug_fill_paths(cfg, years = years)
  }
  drug_fill_paths <- normalizePath(drug_fill_paths, mustWork = FALSE)
  .stage05_check_files(drug_fill_paths, "Stage 01 drug-fill")
  if (is.null(full_pharmacy_paths) || length(full_pharmacy_paths) == 0L) {
    full_pharmacy_paths <- stage05_default_full_pharmacy_paths(cfg, years = years)
  }
  full_pharmacy_paths <- normalizePath(full_pharmacy_paths, mustWork = FALSE)
  .stage05_check_files(full_pharmacy_paths, "Raw pharmacy D")

  output_path <- output_path %||% stage05_default_output_path(cfg)
  qc_path <- qc_path %||% stage05_default_qc_path(cfg)
  classes <- stage05_drug_classes(cfg, drug_classes)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  temp_directory <- temp_directory %||% cfg$paths$tmp_root
  if (!is.null(temp_directory) && nzchar(temp_directory)) {
    dir.create(temp_directory, recursive = TRUE, showWarnings = FALSE)
    DBI::dbExecute(
      con,
      sprintf("SET temp_directory=%s;", sql_quote_string(normalizePath(temp_directory, mustWork = FALSE)))
    )
  }

  full_pharmacy_columns <- .stage05_describe_parquet_columns(con, full_pharmacy_paths)
  query <- .stage05_build_query(
    cfg = cfg,
    spine_path = spine_path,
    drug_fill_paths = drug_fill_paths,
    drug_classes = classes,
    full_pharmacy_paths = full_pharmacy_paths,
    full_pharmacy_columns = full_pharmacy_columns
  )
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage05_person_month_pharmacy AS %s", query))
  copy_query_to_parquet(
    con,
    "SELECT * FROM stage05_person_month_pharmacy",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage05_copy_qc(con, qc_path = qc_path, classes = classes, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    spine_path = spine_path,
    drug_fill_paths = drug_fill_paths,
    full_pharmacy_paths = full_pharmacy_paths,
    drug_classes = classes
  ))
}
