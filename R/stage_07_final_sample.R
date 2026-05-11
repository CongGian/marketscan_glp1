# Stage 07: final person-month assembly and aggregate descriptives.
#
# This stage reads the completed Stage 06 person-month file, adds combined
# pharmacy/medical total fields, writes the final restricted analytic parquet,
# and creates aggregate QC/descriptive CSVs. Real-data execution must be
# analyst-run inside the approved workspace.

.stage07_required_functions <- function() {
  required <- c(
    "validate_config",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_quote_string",
    "sql_quote_identifier",
    "copy_query_to_parquet"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 07 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage07_default_input_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_with_pharmacy_medical.parquet"
  )
}

stage07_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    cfg$outputs$person_month_table %||% "person_month_dpp4_to_glp1_switchers.parquet"
  )
}

stage07_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage07_final_sample_counts.csv"
  )
}

stage07_default_baseline_descriptive_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "descriptives",
    "stage07_baseline_characteristics.csv"
  )
}

stage07_default_person_month_descriptive_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "descriptives",
    "stage07_person_month_descriptives.csv"
  )
}

.stage07_check_file <- function(path, label) {
  if (is.null(path) || !nzchar(path)) {
    stop(label, " path is required.", call. = FALSE)
  }
  if (!file.exists(path)) {
    stop(label, " file does not exist: ", path, call. = FALSE)
  }
  invisible(path)
}

.stage07_describe_parquet <- function(con, path) {
  desc <- DBI::dbGetQuery(
    con,
    sprintf(
      "DESCRIBE SELECT * FROM read_parquet(%s, union_by_name=true);",
      sql_quote_string(path)
    )
  )
  names(desc) <- tolower(names(desc))
  desc
}

.stage07_column_names <- function(con, path) {
  desc <- .stage07_describe_parquet(con, path)
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for Stage 07 input.", call. = FALSE)
  }
  desc$column_name
}

.stage07_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage07_sanitize_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x[x == "" | is.na(x)] <- "missing"
  starts_with_digit <- grepl("^[0-9]", x)
  x[starts_with_digit] <- paste0("x", x[starts_with_digit])
  x
}

.stage07_numeric_expr <- function(columns, column_name) {
  if (column_name %in% columns) {
    sprintf("COALESCE(TRY_CAST(%s AS DOUBLE), 0)", sql_quote_identifier(column_name))
  } else {
    "0"
  }
}

.stage07_integer_expr <- function(columns, column_name) {
  if (column_name %in% columns) {
    sprintf("COALESCE(TRY_CAST(%s AS BIGINT), 0)", sql_quote_identifier(column_name))
  } else {
    "0"
  }
}

.stage07_bool_expr <- function(columns, column_name) {
  if (column_name %in% columns) {
    sprintf("COALESCE(TRY_CAST(%s AS BOOLEAN), FALSE)", sql_quote_identifier(column_name))
  } else {
    "FALSE"
  }
}

.stage07_suppress_select <- function(count_col = "row_count", threshold = 11L) {
  threshold <- as.integer(threshold %||% 11L)
  if (is.na(threshold) || threshold < 2L) {
    return(sprintf("%s, FALSE AS suppressed", count_col))
  }
  sprintf(
    "CASE WHEN %1$s > 0 AND %1$s < %2$d THEN NULL ELSE %1$s END AS %1$s, (%1$s > 0 AND %1$s < %2$d) AS suppressed",
    count_col,
    threshold
  )
}

.stage07_build_final_query <- function(input_path, columns) {
  monthly_rx_claims <- .stage07_integer_expr(columns, "monthly_rx_fill_count")
  monthly_med_claims <- .stage07_integer_expr(columns, "monthly_medical_claim_count")
  monthly_rx_allowed <- .stage07_numeric_expr(columns, "monthly_allowed_amount_rx")
  monthly_med_allowed <- .stage07_numeric_expr(columns, "monthly_allowed_amount_medical")
  monthly_rx_plan <- .stage07_numeric_expr(columns, "monthly_plan_paid_rx")
  monthly_med_plan <- .stage07_numeric_expr(columns, "monthly_plan_paid_medical")
  monthly_rx_oop <- .stage07_numeric_expr(columns, "monthly_patient_oop_rx")
  monthly_med_oop <- .stage07_numeric_expr(columns, "monthly_patient_oop_medical")

  sprintf(
    paste(
      "SELECT",
      "  *,",
      "  (%s + %s)::BIGINT AS monthly_claim_count_total,",
      "  (%s + %s)::DOUBLE AS monthly_allowed_amount_total,",
      "  (%s + %s)::DOUBLE AS monthly_plan_paid_total,",
      "  (%s + %s)::DOUBLE AS monthly_patient_oop_total,",
      "  ((%s + %s) > 0) AS any_claim_month,",
      "  ((%s + %s + %s + %s) > 0) AS any_spending_month",
      "FROM read_parquet(%s, union_by_name=true)",
      sep = "\n"
    ),
    monthly_rx_claims,
    monthly_med_claims,
    monthly_rx_allowed,
    monthly_med_allowed,
    monthly_rx_plan,
    monthly_med_plan,
    monthly_rx_oop,
    monthly_med_oop,
    monthly_rx_claims,
    monthly_med_claims,
    monthly_rx_allowed,
    monthly_med_allowed,
    monthly_rx_oop,
    monthly_med_oop,
    sql_quote_string(input_path)
  )
}

.stage07_prefixed_columns <- function(columns, prefix) {
  columns[startsWith(columns, prefix)]
}

.stage07_qc_query <- function(columns, cell_suppression_threshold = 11L) {
  baseline_conditions <- .stage07_prefixed_columns(columns, "baseline_condition_")
  monthly_conditions <- .stage07_prefixed_columns(columns, "monthly_condition_")
  drug_any <- .stage07_prefixed_columns(columns, "drug_any_")

  condition_rows <- c(
    vapply(baseline_conditions, function(column_name) {
      suffix <- sub("^baseline_condition_", "", column_name)
      sprintf(
        "SELECT 'episodes_with_baseline_condition' AS metric, %s AS metric_value, COUNT(DISTINCT CASE WHEN %s THEN episode_id ELSE NULL END)::BIGINT AS row_count FROM stage07_final_person_month",
        sql_quote_string(suffix),
        sql_quote_identifier(column_name)
      )
    }, character(1L)),
    vapply(monthly_conditions, function(column_name) {
      suffix <- sub("^monthly_condition_", "", column_name)
      sprintf(
        "SELECT 'person_months_with_monthly_condition' AS metric, %s AS metric_value, SUM(CASE WHEN %s THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage07_final_person_month",
        sql_quote_string(suffix),
        sql_quote_identifier(column_name)
      )
    }, character(1L)),
    vapply(drug_any, function(column_name) {
      suffix <- sub("^drug_any_", "", column_name)
      sprintf(
        "SELECT 'person_months_with_drug_any' AS metric, %s AS metric_value, SUM(CASE WHEN %s THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage07_final_person_month",
        sql_quote_string(suffix),
        sql_quote_identifier(column_name)
      )
    }, character(1L))
  )

  pieces <- c(
    "SELECT 'episodes' AS metric, 'all' AS metric_value, COUNT(DISTINCT episode_id)::BIGINT AS row_count FROM stage07_final_person_month",
    "SELECT 'person_month_rows' AS metric, 'all' AS metric_value, COUNT(*)::BIGINT AS row_count FROM stage07_final_person_month",
    "SELECT 'event_month' AS metric, CAST(event_month AS VARCHAR) AS metric_value, COUNT(*)::BIGINT AS row_count FROM stage07_final_person_month GROUP BY event_month",
    "SELECT 'index_year' AS metric, CAST(index_year AS VARCHAR) AS metric_value, COUNT(DISTINCT episode_id)::BIGINT AS row_count FROM stage07_final_person_month GROUP BY index_year",
    "SELECT 'duplicate_episode_month_rows' AS metric, 'all' AS metric_value, COALESCE(SUM(n - 1), 0)::BIGINT AS row_count FROM (SELECT episode_id, event_month, COUNT(*) AS n FROM stage07_final_person_month GROUP BY episode_id, event_month HAVING COUNT(*) > 1)",
    "SELECT 'person_months_with_any_claim' AS metric, 'all' AS metric_value, SUM(CASE WHEN any_claim_month THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage07_final_person_month",
    "SELECT 'person_months_with_any_spending' AS metric, 'all' AS metric_value, SUM(CASE WHEN any_spending_month THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage07_final_person_month",
    condition_rows
  )

  paste(
    "WITH raw AS (",
    paste(pieces, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT metric, metric_value,",
    paste0("  ", .stage07_suppress_select("row_count", cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY metric, metric_value",
    sep = "\n"
  )
}

.stage07_numeric_rows <- function(columns, variables, source = "episode_level") {
  variables <- intersect(variables, columns)
  vapply(variables, function(variable) {
    id <- sql_quote_identifier(variable)
    sprintf(
      "SELECT %1$s AS variable, 'mean' AS level, COUNT(%2$s)::BIGINT AS n, 100.0 AS pct, AVG(TRY_CAST(%2$s AS DOUBLE))::DOUBLE AS mean_value, STDDEV_SAMP(TRY_CAST(%2$s AS DOUBLE))::DOUBLE AS sd_value FROM %3$s",
      sql_quote_string(variable),
      id,
      source
    )
  }, character(1L))
}

.stage07_categorical_rows <- function(columns, variables, source = "episode_level") {
  variables <- intersect(variables, columns)
  vapply(variables, function(variable) {
    id <- sql_quote_identifier(variable)
    sprintf(
      paste(
        "SELECT %1$s AS variable, COALESCE(CAST(%2$s AS VARCHAR), 'missing') AS level,",
        "COUNT(*)::BIGINT AS n,",
        "100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS pct,",
        "CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value",
        "FROM %3$s",
        "GROUP BY COALESCE(CAST(%2$s AS VARCHAR), 'missing')",
        sep = "\n"
      ),
      sql_quote_string(variable),
      id,
      source
    )
  }, character(1L))
}

.stage07_boolean_rows <- function(columns, variables, label, source = "episode_level") {
  variables <- intersect(variables, columns)
  vapply(variables, function(variable) {
    suffix <- sub(paste0("^", label, "_"), "", variable)
    id <- sql_quote_identifier(variable)
    sprintf(
      paste(
        "SELECT %1$s AS variable, %2$s AS level,",
        "SUM(CASE WHEN %3$s THEN 1 ELSE 0 END)::BIGINT AS n,",
        "100.0 * SUM(CASE WHEN %3$s THEN 1 ELSE 0 END) / COUNT(*) AS pct,",
        "CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value",
        "FROM %4$s",
        sep = "\n"
      ),
      sql_quote_string(label),
      sql_quote_string(suffix),
      id,
      source
    )
  }, character(1L))
}

.stage07_baseline_descriptive_query <- function(columns, cell_suppression_threshold = 11L) {
  baseline_conditions <- .stage07_prefixed_columns(columns, "baseline_condition_")
  numeric_vars <- c(
    "age_at_index",
    "baseline_medical_claim_count",
    "baseline_outpatient_claim_count",
    "baseline_inpatient_admissions",
    "baseline_ed_visits",
    "baseline_allowed_amount_medical",
    "baseline_plan_paid_medical",
    "baseline_patient_oop_medical"
  )

  rows <- c(
    "SELECT 'sample' AS variable, 'episodes' AS level, COUNT(DISTINCT episode_id)::BIGINT AS n, 100.0 AS pct, CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value FROM episode_level",
    "SELECT 'age_band' AS variable, CASE WHEN age_at_index IS NULL THEN 'missing' WHEN age_at_index < 35 THEN '<35' WHEN age_at_index < 45 THEN '35-44' WHEN age_at_index < 55 THEN '45-54' WHEN age_at_index < 65 THEN '55-64' ELSE '65+' END AS level, COUNT(*)::BIGINT AS n, 100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS pct, CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value FROM episode_level GROUP BY CASE WHEN age_at_index IS NULL THEN 'missing' WHEN age_at_index < 35 THEN '<35' WHEN age_at_index < 45 THEN '35-44' WHEN age_at_index < 55 THEN '45-54' WHEN age_at_index < 65 THEN '55-64' ELSE '65+' END",
    .stage07_numeric_rows(columns, numeric_vars),
    .stage07_categorical_rows(columns, c("index_year", "sex", "region", "plan_type")),
    .stage07_boolean_rows(columns, baseline_conditions, "baseline_condition")
  )

  paste(
    "WITH episode_level AS (",
    "  SELECT *",
    "  FROM stage07_final_person_month",
    "  WHERE event_month = 0",
    "), raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT variable, level,",
    paste0("  ", .stage07_suppress_select("n", cell_suppression_threshold), ","),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE pct END AS pct_of_episodes,",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE mean_value END AS mean_value,",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE sd_value END AS sd_value",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    "FROM raw",
    "ORDER BY variable, level",
    sep = "\n"
  )
}

.stage07_person_month_descriptive_query <- function(columns, cell_suppression_threshold = 11L) {
  monthly_conditions <- .stage07_prefixed_columns(columns, "monthly_condition_")
  drug_any <- .stage07_prefixed_columns(columns, "drug_any_")
  bool_vars <- intersect(c("any_claim_month", "any_spending_month"), columns)
  numeric_vars <- c(
    "monthly_claim_count_total",
    "monthly_rx_fill_count",
    "monthly_medical_claim_count",
    "monthly_outpatient_claim_count",
    "monthly_inpatient_admissions",
    "monthly_ed_visits",
    "monthly_allowed_amount_total",
    "monthly_plan_paid_total",
    "monthly_patient_oop_total",
    "monthly_allowed_amount_rx",
    "monthly_plan_paid_rx",
    "monthly_patient_oop_rx",
    "monthly_allowed_amount_medical",
    "monthly_plan_paid_medical",
    "monthly_patient_oop_medical"
  )

  numeric_rows <- vapply(intersect(numeric_vars, columns), function(variable) {
    id <- sql_quote_identifier(variable)
    sprintf(
      paste(
        "SELECT %1$s AS variable, 'mean' AS level, event_window,",
        "COUNT(%2$s)::BIGINT AS n, 100.0 AS pct,",
        "AVG(TRY_CAST(%2$s AS DOUBLE))::DOUBLE AS mean_value,",
        "STDDEV_SAMP(TRY_CAST(%2$s AS DOUBLE))::DOUBLE AS sd_value",
        "FROM windowed",
        "GROUP BY event_window",
        sep = "\n"
      ),
      sql_quote_string(variable),
      id
    )
  }, character(1L))

  bool_rows <- vapply(c(bool_vars, drug_any, monthly_conditions), function(variable) {
    label <- if (startsWith(variable, "monthly_condition_")) {
      "monthly_condition"
    } else if (startsWith(variable, "drug_any_")) {
      "drug_any"
    } else {
      "monthly_indicator"
    }
    suffix <- sub("^monthly_condition_", "", sub("^drug_any_", "", variable))
    id <- sql_quote_identifier(variable)
    sprintf(
      paste(
        "SELECT %1$s AS variable, %2$s AS level, event_window,",
        "SUM(CASE WHEN %3$s THEN 1 ELSE 0 END)::BIGINT AS n,",
        "100.0 * SUM(CASE WHEN %3$s THEN 1 ELSE 0 END) / COUNT(*) AS pct,",
        "CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value",
        "FROM windowed",
        "GROUP BY event_window",
        sep = "\n"
      ),
      sql_quote_string(label),
      sql_quote_string(suffix),
      id
    )
  }, character(1L))

  rows <- c(numeric_rows, bool_rows)
  if (length(rows) == 0L) {
    rows <- "SELECT 'sample' AS variable, 'person_months' AS level, event_window, COUNT(*)::BIGINT AS n, 100.0 AS pct, CAST(NULL AS DOUBLE) AS mean_value, CAST(NULL AS DOUBLE) AS sd_value FROM windowed GROUP BY event_window"
  }

  paste(
    "WITH windowed AS (",
    "  SELECT 'all' AS event_window, * FROM stage07_final_person_month",
    "  UNION ALL",
    "  SELECT 'baseline' AS event_window, * FROM stage07_final_person_month WHERE event_month < 0",
    "  UNION ALL",
    "  SELECT 'index' AS event_window, * FROM stage07_final_person_month WHERE event_month = 0",
    "  UNION ALL",
    "  SELECT 'followup' AS event_window, * FROM stage07_final_person_month WHERE event_month > 0",
    "), raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT variable, level, event_window,",
    paste0("  ", .stage07_suppress_select("n", cell_suppression_threshold), ","),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE pct END AS pct_of_person_months,",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE mean_value END AS mean_value,",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    sprintf(
      "  CASE WHEN %1$d >= 2 AND n > 0 AND n < %1$d THEN NULL ELSE sd_value END AS sd_value",
      as.integer(cell_suppression_threshold %||% 11L)
    ),
    "FROM raw",
    "ORDER BY variable, level, event_window",
    sep = "\n"
  )
}

.stage07_copy_csv <- function(con, query, path, overwrite = TRUE) {
  if (is.null(path) || !nzchar(path)) {
    return(invisible(NULL))
  }
  if (file.exists(path)) {
    if (!isTRUE(overwrite)) {
      stop("CSV output already exists: ", path, call. = FALSE)
    }
    unlink(path)
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(
    con,
    sprintf(
      "COPY (%s) TO %s (HEADER, DELIMITER ',');",
      query,
      sql_quote_string(path)
    )
  )
  invisible(path)
}

finalize_person_month_sample <- function(cfg,
                                         input_path = NULL,
                                         output_path = NULL,
                                         qc_path = NULL,
                                         baseline_descriptive_path = NULL,
                                         person_month_descriptive_path = NULL,
                                         db_path = ":memory:",
                                         threads = 4L,
                                         memory_limit = "32GB",
                                         temp_directory = NULL,
                                         cell_suppression_threshold = 11L,
                                         overwrite = TRUE) {
  .stage07_required_functions()
  validate_config(cfg)

  input_path <- normalizePath(input_path %||% stage07_default_input_path(cfg), mustWork = FALSE)
  .stage07_check_file(input_path, "Stage 06 person-month medical")
  output_path <- output_path %||% stage07_default_output_path(cfg)
  qc_path <- qc_path %||% stage07_default_qc_path(cfg)
  baseline_descriptive_path <- baseline_descriptive_path %||% stage07_default_baseline_descriptive_path(cfg)
  person_month_descriptive_path <- person_month_descriptive_path %||% stage07_default_person_month_descriptive_path(cfg)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage07_set_temp_directory(con, cfg, temp_directory = temp_directory)

  input_columns <- .stage07_column_names(con, input_path)
  final_query <- .stage07_build_final_query(input_path, input_columns)
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage07_final_person_month AS %s", final_query))
  final_columns <- DBI::dbGetQuery(con, "DESCRIBE stage07_final_person_month")$column_name

  copy_query_to_parquet(
    con,
    "SELECT * FROM stage07_final_person_month ORDER BY index_year, enrollee_id, episode_number, event_month",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage07_copy_csv(
    con,
    .stage07_qc_query(final_columns, cell_suppression_threshold = cell_suppression_threshold),
    qc_path,
    overwrite = overwrite
  )
  .stage07_copy_csv(
    con,
    .stage07_baseline_descriptive_query(final_columns, cell_suppression_threshold = cell_suppression_threshold),
    baseline_descriptive_path,
    overwrite = overwrite
  )
  .stage07_copy_csv(
    con,
    .stage07_person_month_descriptive_query(final_columns, cell_suppression_threshold = cell_suppression_threshold),
    person_month_descriptive_path,
    overwrite = overwrite
  )

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    baseline_descriptive_path = normalizePath(baseline_descriptive_path, mustWork = FALSE),
    person_month_descriptive_path = normalizePath(person_month_descriptive_path, mustWork = FALSE),
    input_path = input_path,
    cell_suppression_threshold = as.integer(cell_suppression_threshold)
  ))
}
