# Stage 08: aggregate descriptive tables for figure/report data.
#
# This stage reads the restricted final Stage 07 person-month parquet and writes
# aggregate CSV tables only. It does not export row-level records.

.stage08_required_functions <- function() {
  required <- c(
    "validate_config",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_quote_string",
    "sql_quote_identifier"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 08 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage08_default_input_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    cfg$outputs$person_month_table %||% "person_month_dpp4_to_glp1_switchers.parquet"
  )
}

stage08_default_output_dir <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "figures",
    "data"
  )
}

.stage08_check_file <- function(path, label) {
  if (is.null(path) || !nzchar(path)) {
    stop(label, " path is required.", call. = FALSE)
  }
  if (!file.exists(path)) {
    stop(label, " file does not exist: ", path, call. = FALSE)
  }
  invisible(path)
}

.stage08_describe_parquet <- function(con, path) {
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

.stage08_column_names <- function(desc) {
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for Stage 08 input.", call. = FALSE)
  }
  desc$column_name
}

.stage08_require_columns <- function(columns, required, label) {
  missing <- setdiff(required, columns)
  if (length(missing) > 0L) {
    stop(
      label,
      " is missing required column(s): ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

.stage08_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage08_table_files <- function() {
  c(
    event_time_medication_rates = "event_time_medication_rates.csv",
    treatment_state_event_time = "treatment_state_event_time.csv",
    event_time_utilization_rates = "event_time_utilization_rates.csv",
    event_time_spending_summary = "event_time_spending_summary.csv",
    event_time_spending_distribution = "event_time_spending_distribution.csv",
    event_time_spending_decomposition = "event_time_spending_decomposition.csv",
    baseline_condition_prevalence = "baseline_condition_prevalence.csv",
    baseline_comorbidity_category_prevalence = "baseline_comorbidity_category_prevalence.csv",
    multimorbidity_burden = "multimorbidity_burden.csv",
    baseline_spending_utilization_summary = "baseline_spending_utilization_summary.csv",
    sample_structure = "sample_structure.csv",
    cohort_waterfall = "cohort_waterfall.csv"
  )
}

.stage08_output_paths <- function(output_dir) {
  files <- .stage08_table_files()
  stats::setNames(file.path(output_dir, unname(files)), names(files))
}

.stage08_prefixed_columns <- function(columns, prefix) {
  columns[startsWith(columns, prefix)]
}

.stage08_bool_expr <- function(columns, column_name) {
  if (column_name %in% columns) {
    sprintf("COALESCE(TRY_CAST(%s AS BOOLEAN), FALSE)", sql_quote_identifier(column_name))
  } else {
    "FALSE"
  }
}

.stage08_numeric_value_expr <- function(column_name) {
  sprintf("TRY_CAST(%s AS DOUBLE)", sql_quote_identifier(column_name))
}

.stage08_threshold <- function(cell_suppression_threshold = 11L) {
  threshold <- as.integer(cell_suppression_threshold %||% 11L)
  if (is.na(threshold) || threshold < 2L) {
    return(0L)
  }
  threshold
}

.stage08_suppression_condition <- function(count_col, threshold = 11L) {
  threshold <- .stage08_threshold(threshold)
  if (threshold == 0L) {
    return("FALSE")
  }
  sprintf("(%1$s > 0 AND %1$s < %2$d)", count_col, threshold)
}

.stage08_suppressed_count <- function(count_col, output_col = count_col, threshold = 11L) {
  condition <- .stage08_suppression_condition(count_col, threshold)
  sprintf("CASE WHEN %s THEN NULL ELSE %s END AS %s", condition, count_col, output_col)
}

.stage08_suppressed_value <- function(value_expr, output_col, count_col, threshold = 11L) {
  condition <- .stage08_suppression_condition(count_col, threshold)
  sprintf("CASE WHEN %s THEN NULL ELSE %s END AS %s", condition, value_expr, output_col)
}

.stage08_suppressed_flag <- function(count_col, threshold = 11L) {
  sprintf("%s AS suppressed", .stage08_suppression_condition(count_col, threshold))
}

.stage08_empty_query <- function(columns) {
  paste(
    "SELECT",
    paste(sprintf("  %s AS %s", unname(columns), names(columns)), collapse = ",\n"),
    "WHERE FALSE",
    sep = "\n"
  )
}

.stage08_event_time_medication_rates_query <- function(columns, cell_suppression_threshold = 11L) {
  drug_any <- .stage08_prefixed_columns(columns, "drug_any_")
  if (length(drug_any) == 0L) {
    return(.stage08_empty_query(c(
      event_month = "CAST(NULL AS INTEGER)",
      drug_class = "CAST(NULL AS VARCHAR)",
      n_person_months = "CAST(NULL AS BIGINT)",
      exposed_count = "CAST(NULL AS BIGINT)",
      exposed_pct = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  rows <- vapply(drug_any, function(column_name) {
    drug_class <- sub("^drug_any_", "", column_name)
    sprintf(
      paste(
        "SELECT event_month, %s AS drug_class,",
        "COUNT(*)::BIGINT AS n_person_months,",
        "SUM(CASE WHEN %s THEN 1 ELSE 0 END)::BIGINT AS exposed_count",
        "FROM stage08_person_month",
        "GROUP BY event_month",
        sep = "\n"
      ),
      sql_quote_string(drug_class),
      .stage08_bool_expr(columns, column_name)
    )
  }, character(1L))

  paste(
    "WITH raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT",
    "  event_month,",
    "  drug_class,",
    "  n_person_months,",
    paste0("  ", .stage08_suppressed_count("exposed_count", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN n_person_months = 0 THEN NULL ELSE 100.0 * exposed_count / n_person_months END",
        "exposed_pct",
        "exposed_count",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("exposed_count", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY event_month, drug_class",
    sep = "\n"
  )
}

.stage08_treatment_state_event_time_query <- function(columns, cell_suppression_threshold = 11L) {
  dpp4 <- .stage08_bool_expr(columns, "drug_any_dpp4")
  glp1_like <- .stage08_bool_expr(columns, "drug_any_glp1_like")

  paste(
    "WITH classified AS (",
    "  SELECT",
    "    event_month,",
    sprintf(
      "    CASE WHEN %1$s AND %2$s THEN 'both' WHEN %1$s THEN 'dpp4_only' WHEN %2$s THEN 'glp1_like_only' ELSE 'neither' END AS treatment_state",
      dpp4,
      glp1_like
    ),
    "  FROM stage08_person_month",
    "), event_months AS (",
    "  SELECT DISTINCT event_month FROM stage08_person_month",
    "), states AS (",
    "  SELECT * FROM (VALUES ('dpp4_only'), ('glp1_like_only'), ('both'), ('neither')) AS s(treatment_state)",
    "), counts AS (",
    "  SELECT event_month, treatment_state, COUNT(*)::BIGINT AS n",
    "  FROM classified",
    "  GROUP BY event_month, treatment_state",
    "), raw AS (",
    "  SELECT",
    "    e.event_month,",
    "    s.treatment_state,",
    "    COALESCE(c.n, 0)::BIGINT AS n,",
    "    SUM(COALESCE(c.n, 0)) OVER (PARTITION BY e.event_month)::BIGINT AS denominator",
    "  FROM event_months e",
    "  CROSS JOIN states s",
    "  LEFT JOIN counts c",
    "    ON e.event_month = c.event_month",
    "   AND s.treatment_state = c.treatment_state",
    ")",
    "SELECT",
    "  event_month,",
    "  treatment_state,",
    paste0("  ", .stage08_suppressed_count("n", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN denominator = 0 THEN NULL ELSE 100.0 * n / denominator END",
        "pct",
        "n",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("n", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY event_month, treatment_state",
    sep = "\n"
  )
}

.stage08_event_time_utilization_rates_query <- function(columns, cell_suppression_threshold = 11L) {
  metrics <- list()
  if ("any_claim_month" %in% columns) {
    metrics[["any_claim_month"]] <- .stage08_bool_expr(columns, "any_claim_month")
  }
  positive_metrics <- c(
    monthly_rx_fill_count = "monthly_rx_fill_count_gt0",
    monthly_medical_claim_count = "monthly_medical_claim_count_gt0",
    monthly_outpatient_claim_count = "monthly_outpatient_claim_count_gt0",
    monthly_inpatient_admissions = "monthly_inpatient_admissions_gt0",
    monthly_ed_visits = "monthly_ed_visits_gt0"
  )
  for (column_name in names(positive_metrics)) {
    if (column_name %in% columns) {
      metrics[[positive_metrics[[column_name]]]] <- sprintf(
        "COALESCE(TRY_CAST(%s AS DOUBLE), 0) > 0",
        sql_quote_identifier(column_name)
      )
    }
  }

  if (length(metrics) == 0L) {
    return(.stage08_empty_query(c(
      event_month = "CAST(NULL AS INTEGER)",
      metric = "CAST(NULL AS VARCHAR)",
      numerator = "CAST(NULL AS BIGINT)",
      denominator = "CAST(NULL AS BIGINT)",
      rate_pct = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  rows <- vapply(names(metrics), function(metric) {
    sprintf(
      paste(
        "SELECT event_month, %s AS metric,",
        "SUM(CASE WHEN %s THEN 1 ELSE 0 END)::BIGINT AS numerator,",
        "COUNT(*)::BIGINT AS denominator",
        "FROM stage08_person_month",
        "GROUP BY event_month",
        sep = "\n"
      ),
      sql_quote_string(metric),
      metrics[[metric]]
    )
  }, character(1L))

  paste(
    "WITH raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT",
    "  event_month,",
    "  metric,",
    paste0("  ", .stage08_suppressed_count("numerator", threshold = cell_suppression_threshold), ","),
    "  denominator,",
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN denominator = 0 THEN NULL ELSE 100.0 * numerator / denominator END",
        "rate_pct",
        "numerator",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("numerator", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY event_month, metric",
    sep = "\n"
  )
}

.stage08_spending_variables <- function(columns) {
  core <- c(
      "monthly_patient_oop_total",
      "monthly_patient_oop_rx",
      "monthly_patient_oop_medical",
      "monthly_allowed_amount_total",
      "monthly_allowed_amount_rx",
      "monthly_allowed_amount_medical",
      "monthly_plan_paid_total",
      "monthly_plan_paid_rx",
      "monthly_plan_paid_medical"
  )
  glp1_classes <- c("glp1_like", "glp1", "tirzepatide")
  glp1_specific <- as.vector(outer(
    c("monthly_patient_oop_", "monthly_allowed_amount_", "monthly_plan_paid_"),
    glp1_classes,
    paste0
  ))
  intersect(unique(c(core, glp1_specific)), columns)
}

.stage08_summary_select <- function(source, group_cols, order_cols, cell_suppression_threshold = 11L) {
  group_sql <- paste(group_cols, collapse = ", ")
  order_sql <- paste(order_cols, collapse = ", ")
  select_group <- paste(paste0("  ", group_cols, ","), collapse = "\n")

  paste(
    "WITH raw AS (",
    sprintf(
      paste(
        "  SELECT",
        "    %s,",
        "    COUNT(value)::BIGINT AS n,",
        "    AVG(value)::DOUBLE AS mean,",
        "    STDDEV_SAMP(value)::DOUBLE AS sd,",
        "    quantile_cont(value, 0.25)::DOUBLE AS p25,",
        "    quantile_cont(value, 0.50)::DOUBLE AS median,",
        "    quantile_cont(value, 0.75)::DOUBLE AS p75,",
        "    quantile_cont(value, 0.90)::DOUBLE AS p90,",
        "    quantile_cont(value, 0.95)::DOUBLE AS p95,",
        "    quantile_cont(value, 0.99)::DOUBLE AS p99",
        "  FROM (%s) summary_source",
        "  GROUP BY %s",
        sep = "\n"
      ),
      group_sql,
      source,
      group_sql
    ),
    ")",
    "SELECT",
    select_group,
    paste0("  ", .stage08_suppressed_count("n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("mean", "mean", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("sd", "sd", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p25", "p25", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("median", "median", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p75", "p75", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p90", "p90", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p95", "p95", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p99", "p99", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_flag("n", threshold = cell_suppression_threshold)),
    "FROM raw",
    sprintf("ORDER BY %s", order_sql),
    sep = "\n"
  )
}

.stage08_event_time_spending_summary_query <- function(columns, cell_suppression_threshold = 11L) {
  variables <- .stage08_spending_variables(columns)
  if (length(variables) == 0L) {
    return(.stage08_empty_query(c(
      event_month = "CAST(NULL AS INTEGER)",
      variable = "CAST(NULL AS VARCHAR)",
      n = "CAST(NULL AS BIGINT)",
      mean = "CAST(NULL AS DOUBLE)",
      sd = "CAST(NULL AS DOUBLE)",
      p25 = "CAST(NULL AS DOUBLE)",
      median = "CAST(NULL AS DOUBLE)",
      p75 = "CAST(NULL AS DOUBLE)",
      p90 = "CAST(NULL AS DOUBLE)",
      p95 = "CAST(NULL AS DOUBLE)",
      p99 = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  rows <- vapply(variables, function(variable) {
    sprintf(
      "SELECT event_month, %s AS variable, %s AS value FROM stage08_person_month",
      sql_quote_string(variable),
      .stage08_numeric_value_expr(variable)
    )
  }, character(1L))

  .stage08_summary_select(
    source = paste(rows, collapse = "\nUNION ALL\n"),
    group_cols = c("event_month", "variable"),
    order_cols = c("event_month", "variable"),
    cell_suppression_threshold = cell_suppression_threshold
  )
}

.stage08_event_time_spending_distribution_query <- function(columns, cell_suppression_threshold = 11L) {
  variables <- .stage08_spending_variables(columns)
  if (length(variables) == 0L) {
    return(.stage08_empty_query(c(
      event_month = "CAST(NULL AS INTEGER)",
      variable = "CAST(NULL AS VARCHAR)",
      population = "CAST(NULL AS VARCHAR)",
      n = "CAST(NULL AS BIGINT)",
      n_positive = "CAST(NULL AS BIGINT)",
      positive_pct = "CAST(NULL AS DOUBLE)",
      mean = "CAST(NULL AS DOUBLE)",
      sd = "CAST(NULL AS DOUBLE)",
      p25 = "CAST(NULL AS DOUBLE)",
      median = "CAST(NULL AS DOUBLE)",
      p75 = "CAST(NULL AS DOUBLE)",
      p90 = "CAST(NULL AS DOUBLE)",
      p95 = "CAST(NULL AS DOUBLE)",
      p99 = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  value_rows <- vapply(variables, function(variable) {
    sprintf(
      "SELECT event_month, %s AS variable, %s AS value FROM stage08_person_month",
      sql_quote_string(variable),
      .stage08_numeric_value_expr(variable)
    )
  }, character(1L))

  paste(
    "WITH values_long AS (",
    paste(value_rows, collapse = "\nUNION ALL\n"),
    "), raw AS (",
    "  SELECT",
    "    event_month,",
    "    variable,",
    "    'all_person_months' AS population,",
    "    COUNT(value)::BIGINT AS n,",
    "    SUM(CASE WHEN value > 0 THEN 1 ELSE 0 END)::BIGINT AS n_positive,",
    "    AVG(value)::DOUBLE AS mean,",
    "    STDDEV_SAMP(value)::DOUBLE AS sd,",
    "    quantile_cont(value, 0.25)::DOUBLE AS p25,",
    "    quantile_cont(value, 0.50)::DOUBLE AS median,",
    "    quantile_cont(value, 0.75)::DOUBLE AS p75,",
    "    quantile_cont(value, 0.90)::DOUBLE AS p90,",
    "    quantile_cont(value, 0.95)::DOUBLE AS p95,",
    "    quantile_cont(value, 0.99)::DOUBLE AS p99",
    "  FROM values_long",
    "  GROUP BY event_month, variable",
    "  UNION ALL",
    "  SELECT",
    "    event_month,",
    "    variable,",
    "    'positive_person_months' AS population,",
    "    COUNT(value)::BIGINT AS n,",
    "    COUNT(value)::BIGINT AS n_positive,",
    "    AVG(value)::DOUBLE AS mean,",
    "    STDDEV_SAMP(value)::DOUBLE AS sd,",
    "    quantile_cont(value, 0.25)::DOUBLE AS p25,",
    "    quantile_cont(value, 0.50)::DOUBLE AS median,",
    "    quantile_cont(value, 0.75)::DOUBLE AS p75,",
    "    quantile_cont(value, 0.90)::DOUBLE AS p90,",
    "    quantile_cont(value, 0.95)::DOUBLE AS p95,",
    "    quantile_cont(value, 0.99)::DOUBLE AS p99",
    "  FROM values_long",
    "  WHERE value > 0",
    "  GROUP BY event_month, variable",
    ")",
    "SELECT",
    "  event_month,",
    "  variable,",
    "  population,",
    paste0("  ", .stage08_suppressed_count("n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_count("n_positive", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN n = 0 THEN NULL ELSE 100.0 * n_positive / n END",
        "positive_pct",
        "n_positive",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_value("mean", "mean", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("sd", "sd", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p25", "p25", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("median", "median", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p75", "p75", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p90", "p90", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p95", "p95", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p99", "p99", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_flag("n", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY event_month, variable, population",
    sep = "\n"
  )
}

.stage08_glp1_like_component_expr <- function(columns, amount_prefix) {
  preferred <- paste0("monthly_", amount_prefix, "_glp1_like")
  if (preferred %in% columns) {
    return(.stage08_numeric_value_expr(preferred))
  }
  fallback <- intersect(
    paste0("monthly_", amount_prefix, "_", c("glp1", "tirzepatide")),
    columns
  )
  if (length(fallback) == 0L) {
    return("0")
  }
  paste(vapply(fallback, .stage08_numeric_value_expr, character(1L)), collapse = " + ")
}

.stage08_event_time_spending_decomposition_query <- function(columns, cell_suppression_threshold = 11L) {
  amount_types <- c("allowed_amount", "plan_paid", "patient_oop")
  rows <- character()
  for (amount_type in amount_types) {
    medical_col <- paste0("monthly_", amount_type, "_medical")
    rx_col <- paste0("monthly_", amount_type, "_rx")
    if (!medical_col %in% columns && !rx_col %in% columns) {
      next
    }
    medical_expr <- if (medical_col %in% columns) .stage08_numeric_value_expr(medical_col) else "0"
    rx_expr <- if (rx_col %in% columns) .stage08_numeric_value_expr(rx_col) else "0"
    glp1_expr <- .stage08_glp1_like_component_expr(columns, amount_type)
    component_exprs <- c(
      medical = medical_expr,
      glp1_like_rx = glp1_expr,
      non_glp1_like_rx = sprintf("GREATEST(0, (%s) - (%s))", rx_expr, glp1_expr)
    )
    rows <- c(rows, vapply(names(component_exprs), function(component) {
      sprintf(
        "SELECT event_month, %s AS amount_type, %s AS component, (%s)::DOUBLE AS value FROM stage08_person_month",
        sql_quote_string(amount_type),
        sql_quote_string(component),
        component_exprs[[component]]
      )
    }, character(1L)))
  }

  if (length(rows) == 0L) {
    return(.stage08_empty_query(c(
      event_month = "CAST(NULL AS INTEGER)",
      amount_type = "CAST(NULL AS VARCHAR)",
      component = "CAST(NULL AS VARCHAR)",
      n = "CAST(NULL AS BIGINT)",
      n_positive = "CAST(NULL AS BIGINT)",
      positive_pct = "CAST(NULL AS DOUBLE)",
      mean = "CAST(NULL AS DOUBLE)",
      median = "CAST(NULL AS DOUBLE)",
      p75 = "CAST(NULL AS DOUBLE)",
      p90 = "CAST(NULL AS DOUBLE)",
      p95 = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  paste(
    "WITH values_long AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    "), raw AS (",
    "  SELECT",
    "    event_month,",
    "    amount_type,",
    "    component,",
    "    COUNT(value)::BIGINT AS n,",
    "    SUM(CASE WHEN value > 0 THEN 1 ELSE 0 END)::BIGINT AS n_positive,",
    "    AVG(value)::DOUBLE AS mean,",
    "    quantile_cont(value, 0.50)::DOUBLE AS median,",
    "    quantile_cont(value, 0.75)::DOUBLE AS p75,",
    "    quantile_cont(value, 0.90)::DOUBLE AS p90,",
    "    quantile_cont(value, 0.95)::DOUBLE AS p95",
    "  FROM values_long",
    "  GROUP BY event_month, amount_type, component",
    ")",
    "SELECT",
    "  event_month,",
    "  amount_type,",
    "  component,",
    paste0("  ", .stage08_suppressed_count("n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_count("n_positive", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN n = 0 THEN NULL ELSE 100.0 * n_positive / n END",
        "positive_pct",
        "n_positive",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_value("mean", "mean", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("median", "median", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p75", "p75", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p90", "p90", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_value("p95", "p95", "n", threshold = cell_suppression_threshold), ","),
    paste0("  ", .stage08_suppressed_flag("n", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY event_month, amount_type, component",
    sep = "\n"
  )
}

.stage08_baseline_condition_prevalence_query <- function(columns, cell_suppression_threshold = 11L) {
  baseline_conditions <- .stage08_prefixed_columns(columns, "baseline_condition_")
  if (length(baseline_conditions) == 0L) {
    return(.stage08_empty_query(c(
      condition = "CAST(NULL AS VARCHAR)",
      n_episodes = "CAST(NULL AS BIGINT)",
      pct_episodes = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  rows <- vapply(baseline_conditions, function(column_name) {
    condition <- sub("^baseline_condition_", "", column_name)
    sprintf(
      paste(
        "SELECT %s AS condition,",
        "COUNT(DISTINCT CASE WHEN %s THEN episode_id ELSE NULL END)::BIGINT AS n_episodes,",
        "COUNT(DISTINCT episode_id)::BIGINT AS denominator",
        "FROM stage08_person_month",
        "WHERE event_month = 0",
        sep = "\n"
      ),
      sql_quote_string(condition),
      .stage08_bool_expr(columns, column_name)
    )
  }, character(1L))

  paste(
    "WITH raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT",
    "  condition,",
    paste0("  ", .stage08_suppressed_count("n_episodes", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN denominator = 0 THEN NULL ELSE 100.0 * n_episodes / denominator END",
        "pct_episodes",
        "n_episodes",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("n_episodes", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY condition",
    sep = "\n"
  )
}

.stage08_comorbidity_category_set <- function(condition) {
  condition <- as.character(condition)
  ifelse(
    startsWith(condition, "elixhauser_"),
    "elixhauser",
    ifelse(startsWith(condition, "charlson_"), "charlson", "study_defined")
  )
}

.stage08_baseline_comorbidity_category_prevalence_query <- function(columns, cell_suppression_threshold = 11L) {
  baseline_conditions <- .stage08_prefixed_columns(columns, "baseline_condition_")
  if (length(baseline_conditions) == 0L) {
    return(.stage08_empty_query(c(
      category_set = "CAST(NULL AS VARCHAR)",
      category = "CAST(NULL AS VARCHAR)",
      n_episodes = "CAST(NULL AS BIGINT)",
      pct_episodes = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  rows <- vapply(baseline_conditions, function(column_name) {
    condition <- sub("^baseline_condition_", "", column_name)
    sprintf(
      paste(
        "SELECT %s AS category_set, %s AS category,",
        "COUNT(DISTINCT CASE WHEN %s THEN episode_id ELSE NULL END)::BIGINT AS n_episodes,",
        "COUNT(DISTINCT episode_id)::BIGINT AS denominator",
        "FROM stage08_person_month",
        "WHERE event_month = 0",
        sep = "\n"
      ),
      sql_quote_string(.stage08_comorbidity_category_set(condition)),
      sql_quote_string(condition),
      .stage08_bool_expr(columns, column_name)
    )
  }, character(1L))

  paste(
    "WITH raw AS (",
    paste(rows, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT",
    "  category_set,",
    "  category,",
    paste0("  ", .stage08_suppressed_count("n_episodes", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN denominator = 0 THEN NULL ELSE 100.0 * n_episodes / denominator END",
        "pct_episodes",
        "n_episodes",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("n_episodes", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY category_set, category",
    sep = "\n"
  )
}

.stage08_multimorbidity_burden_query <- function(columns, cell_suppression_threshold = 11L) {
  baseline_conditions <- .stage08_prefixed_columns(columns, "baseline_condition_")
  if (length(baseline_conditions) > 0L) {
    flag_aliases <- sprintf("condition_%03d", seq_along(baseline_conditions))
    flag_selects <- vapply(seq_along(baseline_conditions), function(i) {
      sprintf(
        "MAX(CASE WHEN %s THEN 1 ELSE 0 END)::INTEGER AS %s",
        .stage08_bool_expr(columns, baseline_conditions[[i]]),
        sql_quote_identifier(flag_aliases[[i]])
      )
    }, character(1L))
    condition_count <- paste(sql_quote_identifier(flag_aliases), collapse = " + ")
  } else {
    flag_selects <- "0::INTEGER AS condition_count"
    condition_count <- "condition_count"
  }

  paste(
    "WITH episode_flags AS (",
    "  SELECT",
    "    episode_id,",
    paste0("    ", paste(flag_selects, collapse = ",\n    ")),
    "  FROM stage08_person_month",
    "  WHERE event_month = 0",
    "  GROUP BY episode_id",
    "), episode_level AS (",
    "  SELECT",
    sprintf("    (%s)::INTEGER AS condition_count", condition_count),
    "  FROM episode_flags",
    "), raw AS (",
    "  SELECT",
    "    condition_count,",
    "    COUNT(*)::BIGINT AS n_episodes,",
    "    SUM(COUNT(*)) OVER ()::BIGINT AS denominator",
    "  FROM episode_level",
    "  GROUP BY condition_count",
    ")",
    "SELECT",
    "  condition_count,",
    paste0("  ", .stage08_suppressed_count("n_episodes", threshold = cell_suppression_threshold), ","),
    paste0(
      "  ",
      .stage08_suppressed_value(
        "CASE WHEN denominator = 0 THEN NULL ELSE 100.0 * n_episodes / denominator END",
        "pct_episodes",
        "n_episodes",
        threshold = cell_suppression_threshold
      ),
      ","
    ),
    paste0("  ", .stage08_suppressed_flag("n_episodes", threshold = cell_suppression_threshold)),
    "FROM raw",
    "ORDER BY condition_count",
    sep = "\n"
  )
}

.stage08_baseline_summary_variables <- function(columns) {
  baseline_variables <- columns[
    startsWith(columns, "baseline_") &
      !startsWith(columns, "baseline_condition_") &
      grepl("(claim|fill|admission|visit|amount|paid|oop|pay|cost|spend|netpay|days|count|util)", columns)
  ]
  unique(c(intersect("age_at_index", columns), baseline_variables))
}

.stage08_baseline_spending_utilization_summary_query <- function(columns, cell_suppression_threshold = 11L) {
  variables <- .stage08_baseline_summary_variables(columns)
  if (length(variables) == 0L) {
    return(.stage08_empty_query(c(
      variable = "CAST(NULL AS VARCHAR)",
      n = "CAST(NULL AS BIGINT)",
      mean = "CAST(NULL AS DOUBLE)",
      sd = "CAST(NULL AS DOUBLE)",
      p25 = "CAST(NULL AS DOUBLE)",
      median = "CAST(NULL AS DOUBLE)",
      p75 = "CAST(NULL AS DOUBLE)",
      p90 = "CAST(NULL AS DOUBLE)",
      p95 = "CAST(NULL AS DOUBLE)",
      p99 = "CAST(NULL AS DOUBLE)",
      suppressed = "CAST(NULL AS BOOLEAN)"
    )))
  }

  episode_selects <- vapply(variables, function(variable) {
    sprintf("MAX(%s)::DOUBLE AS %s", .stage08_numeric_value_expr(variable), sql_quote_identifier(variable))
  }, character(1L))
  rows <- vapply(variables, function(variable) {
    sprintf(
      "SELECT %s AS variable, %s AS value FROM episode_level",
      sql_quote_string(variable),
      sql_quote_identifier(variable)
    )
  }, character(1L))

  source <- paste(
    "WITH episode_level AS (",
    "  SELECT",
    "    episode_id,",
    paste0("    ", paste(episode_selects, collapse = ",\n    ")),
    "  FROM stage08_person_month",
    "  WHERE event_month = 0",
    "  GROUP BY episode_id",
    ")",
    paste(rows, collapse = "\nUNION ALL\n"),
    sep = "\n"
  )

  .stage08_summary_select(
    source = source,
    group_cols = "variable",
    order_cols = "variable",
    cell_suppression_threshold = cell_suppression_threshold
  )
}

.stage08_sample_structure_query <- function(columns, cell_suppression_threshold = 11L) {
  index_year_rows <- if ("index_year" %in% columns) {
    paste(
      "SELECT 'index_year' AS metric, CAST(index_year AS VARCHAR) AS metric_value,",
      "COUNT(DISTINCT episode_id)::BIGINT AS n,",
      "100.0 * COUNT(DISTINCT episode_id) / NULLIF((SELECT COUNT(DISTINCT episode_id) FROM stage08_person_month), 0) AS pct_or_value,",
      "TRUE AS suppressible",
      "FROM stage08_person_month",
      "GROUP BY index_year"
    )
  } else {
    NULL
  }

  pieces <- c(
    "SELECT 'episodes' AS metric, 'all' AS metric_value, COUNT(DISTINCT episode_id)::BIGINT AS n, COUNT(DISTINCT episode_id)::DOUBLE AS pct_or_value, FALSE AS suppressible FROM stage08_person_month",
    "SELECT 'person_month_rows' AS metric, 'all' AS metric_value, COUNT(*)::BIGINT AS n, COUNT(*)::DOUBLE AS pct_or_value, FALSE AS suppressible FROM stage08_person_month",
    "SELECT 'event_month' AS metric, CAST(event_month AS VARCHAR) AS metric_value, COUNT(*)::BIGINT AS n, 100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM stage08_person_month), 0) AS pct_or_value, FALSE AS suppressible FROM stage08_person_month GROUP BY event_month",
    index_year_rows,
    paste(
      "SELECT 'duplicate_episode_month_rows' AS metric, 'all' AS metric_value,",
      "COALESCE(SUM(n - 1), 0)::BIGINT AS n,",
      "COALESCE(SUM(n - 1), 0)::DOUBLE AS pct_or_value,",
      "TRUE AS suppressible",
      "FROM (",
      "  SELECT episode_id, event_month, COUNT(*) AS n",
      "  FROM stage08_person_month",
      "  GROUP BY episode_id, event_month",
      "  HAVING COUNT(*) > 1",
      ") duplicates"
    )
  )
  pieces <- pieces[!vapply(pieces, is.null, logical(1L))]

  suppress_condition <- .stage08_suppression_condition("n", cell_suppression_threshold)
  suppress_when <- sprintf("(suppressible AND %s)", suppress_condition)

  paste(
    "WITH raw AS (",
    paste(pieces, collapse = "\nUNION ALL\n"),
    ")",
    "SELECT",
    "  metric,",
    "  metric_value,",
    sprintf("  CASE WHEN %s THEN NULL ELSE n END AS n,", suppress_when),
    sprintf("  CASE WHEN %s THEN NULL ELSE pct_or_value END AS pct_or_value,", suppress_when),
    sprintf("  %s AS suppressed", suppress_when),
    "FROM raw",
    "ORDER BY metric, metric_value",
    sep = "\n"
  )
}

.stage08_copy_csv <- function(con, query, path, overwrite = TRUE) {
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

.stage08_normalize_qc_paths <- function(qc_paths = list()) {
  if (is.null(qc_paths) || length(qc_paths) == 0L) {
    return(list())
  }
  if (!is.list(qc_paths) || is.null(names(qc_paths)) || any(!nzchar(names(qc_paths)))) {
    stop("qc_paths must be a named list of prior stage aggregate QC CSV paths.", call. = FALSE)
  }
  qc_paths[!vapply(qc_paths, is.null, logical(1L))]
}

.stage08_read_qc <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) {
    return(NULL)
  }
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

.stage08_qc_count <- function(df, metric, metric_value = NULL, count_col = "row_count") {
  if (is.null(df) || !all(c("metric", count_col) %in% names(df))) {
    return(NA_real_)
  }
  rows <- df[df$metric == metric, , drop = FALSE]
  if (!is.null(metric_value) && "metric_value" %in% names(rows)) {
    rows <- rows[as.character(rows$metric_value) == as.character(metric_value), , drop = FALSE]
  }
  if (nrow(rows) == 0L) {
    return(NA_real_)
  }
  suppressWarnings(as.numeric(rows[[count_col]][[1L]]))
}

.stage08_write_cohort_waterfall <- function(qc_paths, output_path, final_counts, overwrite = TRUE) {
  if (file.exists(output_path)) {
    if (!isTRUE(overwrite)) {
      stop("CSV output already exists: ", output_path, call. = FALSE)
    }
    unlink(output_path)
  }
  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)

  qc_paths <- .stage08_normalize_qc_paths(qc_paths)
  qcs <- lapply(qc_paths, .stage08_read_qc)
  names(qcs) <- names(qc_paths)
  get_qc <- function(name) qcs[[name]] %||% NULL

  stage02 <- get_qc("stage02")
  stage03 <- get_qc("stage03")
  stage04 <- get_qc("stage04")
  stage07 <- get_qc("stage07")

  stage02_total <- if (!is.null(stage02) && "candidate_count" %in% names(stage02)) {
    sum(suppressWarnings(as.numeric(stage02$candidate_count)), na.rm = TRUE)
  } else {
    NA_real_
  }
  stage02_clean <- if (!is.null(stage02) && all(c("switch_class", "candidate_count") %in% names(stage02))) {
    sum(suppressWarnings(as.numeric(stage02$candidate_count[stage02$switch_class == "clean_replacement"])), na.rm = TRUE)
  } else {
    NA_real_
  }
  stage03_enrolled_clean <- if (!is.null(stage03) && all(c("switch_class", "continuous_enrollment", "candidate_count") %in% names(stage03))) {
    rows <- stage03$switch_class == "clean_replacement" &
      tolower(as.character(stage03$continuous_enrollment)) == "true"
    sum(suppressWarnings(as.numeric(stage03$candidate_count[rows])), na.rm = TRUE)
  } else {
    NA_real_
  }
  stage04_episodes <- .stage08_qc_count(stage04, "episodes", "all")
  stage04_person_months <- .stage08_qc_count(stage04, "person_month_rows", "all")
  stage07_episodes <- .stage08_qc_count(stage07, "episodes", "all")
  stage07_person_months <- .stage08_qc_count(stage07, "person_month_rows", "all")

  if (is.na(stage07_episodes)) {
    stage07_episodes <- final_counts$episodes
  }
  if (is.na(stage07_person_months)) {
    stage07_person_months <- final_counts$person_month_rows
  }

  values <- c(
    stage02_all_switch_candidates = stage02_total,
    stage02_clean_replacement_candidates = stage02_clean,
    stage03_enrolled_clean_replacements = stage03_enrolled_clean,
    stage04_person_month_spine_episodes = stage04_episodes,
    stage04_person_month_rows = stage04_person_months,
    stage07_final_episodes = stage07_episodes,
    stage07_final_person_month_rows = stage07_person_months
  )
  denominators <- c(NA_real_, values[-length(values)])
  retention <- ifelse(is.na(denominators) | denominators == 0, NA_real_, 100.0 * values / denominators)

  out <- data.frame(
    step_order = seq_along(values),
    step = names(values),
    n = as.numeric(values),
    retention_from_prior_pct = as.numeric(retention),
    stringsAsFactors = FALSE
  )
  utils::write.csv(out, output_path, row.names = FALSE, na = "")
  invisible(output_path)
}

build_stage08_descriptive_tables <- function(cfg,
                                             input_path = NULL,
                                             output_dir = NULL,
                                             qc_paths = list(),
                                             db_path = ":memory:",
                                             threads = 4L,
                                             memory_limit = "32GB",
                                             temp_directory = NULL,
                                             cell_suppression_threshold = 11L,
                                             overwrite = TRUE) {
  .stage08_required_functions()
  validate_config(cfg)

  input_path <- normalizePath(input_path %||% stage08_default_input_path(cfg), mustWork = FALSE)
  .stage08_check_file(input_path, "Stage 07 final person-month")
  output_dir <- normalizePath(output_dir %||% stage08_default_output_dir(cfg), mustWork = FALSE)
  output_paths <- .stage08_output_paths(output_dir)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage08_set_temp_directory(con, cfg, temp_directory = temp_directory)

  desc <- .stage08_describe_parquet(con, input_path)
  columns <- .stage08_column_names(desc)
  .stage08_require_columns(columns, c("episode_id", "event_month"), "Stage 07 final person-month")
  DBI::dbExecute(
    con,
    sprintf(
      "CREATE OR REPLACE VIEW stage08_person_month AS SELECT * FROM read_parquet(%s, union_by_name=true)",
      sql_quote_string(input_path)
    )
  )

  queries <- list(
    event_time_medication_rates = .stage08_event_time_medication_rates_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    treatment_state_event_time = .stage08_treatment_state_event_time_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    event_time_utilization_rates = .stage08_event_time_utilization_rates_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    event_time_spending_summary = .stage08_event_time_spending_summary_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    event_time_spending_distribution = .stage08_event_time_spending_distribution_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    event_time_spending_decomposition = .stage08_event_time_spending_decomposition_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    baseline_condition_prevalence = .stage08_baseline_condition_prevalence_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    baseline_comorbidity_category_prevalence = .stage08_baseline_comorbidity_category_prevalence_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    multimorbidity_burden = .stage08_multimorbidity_burden_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    baseline_spending_utilization_summary = .stage08_baseline_spending_utilization_summary_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    ),
    sample_structure = .stage08_sample_structure_query(
      columns,
      cell_suppression_threshold = cell_suppression_threshold
    )
  )

  for (name in names(queries)) {
    .stage08_copy_csv(
      con,
      queries[[name]],
      output_paths[[name]],
      overwrite = overwrite
    )
  }

  final_counts <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT",
      "  COUNT(DISTINCT episode_id)::DOUBLE AS episodes,",
      "  COUNT(*)::DOUBLE AS person_month_rows",
      "FROM stage08_person_month"
    )
  )
  .stage08_write_cohort_waterfall(
    qc_paths = qc_paths,
    output_path = output_paths[["cohort_waterfall"]],
    final_counts = final_counts,
    overwrite = overwrite
  )

  invisible(list(
    input_path = input_path,
    output_dir = normalizePath(output_dir, mustWork = FALSE),
    output_paths = stats::setNames(
      vapply(output_paths, normalizePath, character(1L), mustWork = FALSE),
      names(output_paths)
    ),
    cell_suppression_threshold = as.integer(cell_suppression_threshold)
  ))
}
