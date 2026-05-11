# Stage 04: build the enrolled clean-replacement person-month spine.
#
# This stage reads Stage 03 enrollment-filtered switch candidates and writes one
# row per enrolled clean-replacement episode per event month. It also writes
# aggregate QC/descriptive CSV files for analyst review.

.stage04_required_functions <- function() {
  required <- c(
    "validate_config",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_quote_string",
    "copy_query_to_parquet"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 04 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage04_default_input_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "enrollment",
    "dpp4_to_glp1_switch_candidates_enrollment.parquet"
  )
}

stage04_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_spine_clean_replacement.parquet"
  )
}

stage04_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage04_person_month_spine_counts.csv"
  )
}

stage04_default_descriptive_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "descriptives",
    "stage04_enrolled_clean_replacement_description.csv"
  )
}

.stage04_check_file <- function(path, label) {
  if (is.null(path) || !nzchar(path)) {
    stop(label, " path is required.", call. = FALSE)
  }
  if (!file.exists(path)) {
    stop(label, " file does not exist: ", path, call. = FALSE)
  }
  invisible(path)
}

.stage04_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage04_scalar_int <- function(value, default, name) {
  if (is.null(value)) {
    value <- default
  }
  value <- as.integer(value)
  if (length(value) != 1L || is.na(value)) {
    stop(name, " must be a scalar integer.", call. = FALSE)
  }
  value
}

.stage04_min_age_sql <- function(cfg) {
  min_age <- cfg$sample_restrictions$min_age
  if (is.null(min_age)) {
    return("TRUE")
  }
  sprintf("age_at_index IS NOT NULL AND age_at_index >= %d", as.integer(min_age))
}

.stage04_max_age_sql <- function(cfg) {
  max_age <- cfg$sample_restrictions$max_age
  if (is.null(max_age)) {
    return("TRUE")
  }
  sprintf("age_at_index IS NOT NULL AND age_at_index <= %d", as.integer(max_age))
}

.stage04_build_spine_query <- function(cfg, input_path) {
  validate_config(cfg)
  event_month_min <- .stage04_scalar_int(cfg$study_period$event_month_min, -12L, "study_period.event_month_min")
  event_month_max <- .stage04_scalar_int(cfg$study_period$event_month_max, 12L, "study_period.event_month_max")
  if (event_month_min > event_month_max) {
    stop("study_period.event_month_min cannot exceed event_month_max.", call. = FALSE)
  }

  sprintf(
    paste(
      "WITH enrolled AS (",
      "  SELECT *",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE primary_clean_replacement_enrolled = TRUE",
      "    AND %s",
      "    AND %s",
      "), event_months AS (",
      "  SELECT range AS event_month",
      "  FROM range(%d, %d)",
      "), spine AS (",
      "  SELECT",
      "    e.enrollee_id,",
      "    e.episode_number,",
      "    concat(CAST(e.enrollee_id AS VARCHAR), '_ep', lpad(CAST(e.episode_number AS VARCHAR), 3, '0')) AS episode_id,",
      "    e.index_date,",
      "    e.index_year,",
      "    e.index_ndc11,",
      "    e.index_drug_class,",
      "    e.switch_class,",
      "    e.classification,",
      "    e.age_at_index,",
      "    e.sex,",
      "    e.region,",
      "    e.health_plan,",
      "    e.plan_type,",
      "    e.required_enrollment_start,",
      "    e.required_enrollment_end,",
      "    e.enrollment_spell_start,",
      "    e.enrollment_spell_end,",
      "    m.event_month,",
      "    CAST(date_trunc('month', e.index_date) + m.event_month * INTERVAL 1 MONTH AS DATE) AS month_start,",
      "    CAST(date_trunc('month', e.index_date) + (m.event_month + 1) * INTERVAL 1 MONTH - INTERVAL 1 DAY AS DATE) AS month_end",
      "  FROM enrolled e",
      "  CROSS JOIN event_months m",
      ")",
      "SELECT",
      "  *,",
      "  CAST(EXTRACT(year FROM month_start) AS INTEGER) AS calendar_year,",
      "  CAST(EXTRACT(month FROM month_start) AS INTEGER) AS calendar_month,",
      "  strftime(month_start, '%%Y-%%m') AS year_month,",
      "  event_month < 0 AS baseline_month,",
      "  event_month = 0 AS index_month,",
      "  event_month > 0 AS followup_month",
      "FROM spine",
      "ORDER BY index_year, enrollee_id, episode_number, event_month",
      sep = "\n"
    ),
    sql_quote_string(input_path),
    .stage04_min_age_sql(cfg),
    .stage04_max_age_sql(cfg),
    event_month_min,
    event_month_max + 1L
  )
}

.stage04_copy_csv <- function(con, query, path, overwrite = TRUE) {
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

.stage04_qc_query <- function() {
  paste(
    "SELECT metric, metric_value, row_count",
    "FROM (",
    "  SELECT 'episodes' AS metric, 'all' AS metric_value, count(DISTINCT episode_id) AS row_count FROM stage04_person_month_spine",
    "  UNION ALL",
    "  SELECT 'person_month_rows' AS metric, 'all' AS metric_value, count(*) AS row_count FROM stage04_person_month_spine",
    "  UNION ALL",
    "  SELECT 'event_month' AS metric, CAST(event_month AS VARCHAR) AS metric_value, count(*) AS row_count FROM stage04_person_month_spine GROUP BY event_month",
    "  UNION ALL",
    "  SELECT 'index_year' AS metric, CAST(index_year AS VARCHAR) AS metric_value, count(DISTINCT episode_id) AS row_count FROM stage04_person_month_spine GROUP BY index_year",
    ")",
    "ORDER BY metric, metric_value",
    sep = "\n"
  )
}

.stage04_descriptive_query <- function() {
  paste(
    "WITH episode_level AS (",
    "  SELECT DISTINCT",
    "    episode_id, index_year, age_at_index, sex, region, health_plan, plan_type",
    "  FROM stage04_person_month_spine",
    "), age_bands AS (",
    "  SELECT",
    "    episode_id,",
    "    CASE",
    "      WHEN age_at_index IS NULL THEN 'missing'",
    "      WHEN age_at_index < 35 THEN '<35'",
    "      WHEN age_at_index BETWEEN 35 AND 44 THEN '35-44'",
    "      WHEN age_at_index BETWEEN 45 AND 54 THEN '45-54'",
    "      WHEN age_at_index BETWEEN 55 AND 64 THEN '55-64'",
    "      ELSE '65+'",
    "    END AS age_band",
    "  FROM episode_level",
    "), summaries AS (",
    "  SELECT 'sample' AS variable, 'episodes' AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM episode_level",
    "  UNION ALL",
    "  SELECT 'age_at_index' AS variable, 'mean' AS level, count(age_at_index) AS n, avg(age_at_index)::DOUBLE AS mean_value FROM episode_level",
    "  UNION ALL",
    "  SELECT 'age_band' AS variable, age_band AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM age_bands GROUP BY age_band",
    "  UNION ALL",
    "  SELECT 'sex' AS variable, coalesce(CAST(sex AS VARCHAR), 'missing') AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM episode_level GROUP BY sex",
    "  UNION ALL",
    "  SELECT 'region' AS variable, coalesce(CAST(region AS VARCHAR), 'missing') AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM episode_level GROUP BY region",
    "  UNION ALL",
    "  SELECT 'plan_type' AS variable, coalesce(CAST(plan_type AS VARCHAR), 'missing') AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM episode_level GROUP BY plan_type",
    "  UNION ALL",
    "  SELECT 'index_year' AS variable, CAST(index_year AS VARCHAR) AS level, count(*) AS n, NULL::DOUBLE AS mean_value FROM episode_level GROUP BY index_year",
    ")",
    "SELECT",
    "  variable,",
    "  level,",
    "  n,",
    "  round(100.0 * n / max(CASE WHEN variable = 'sample' AND level = 'episodes' THEN n ELSE NULL END) OVER (), 2) AS pct_of_episodes,",
    "  mean_value",
    "FROM summaries",
    "ORDER BY variable, level",
    sep = "\n"
  )
}

build_person_month_spine <- function(cfg,
                                     input_path = NULL,
                                     output_path = NULL,
                                     qc_path = NULL,
                                     descriptive_path = NULL,
                                     db_path = ":memory:",
                                     threads = 4L,
                                     memory_limit = "32GB",
                                     temp_directory = NULL,
                                     overwrite = TRUE) {
  .stage04_required_functions()
  validate_config(cfg)

  input_path <- input_path %||% stage04_default_input_path(cfg)
  input_path <- normalizePath(input_path, mustWork = FALSE)
  .stage04_check_file(input_path, "Stage 03 enrollment")

  output_path <- output_path %||% stage04_default_output_path(cfg)
  qc_path <- qc_path %||% stage04_default_qc_path(cfg)
  descriptive_path <- descriptive_path %||% stage04_default_descriptive_path(cfg)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage04_set_temp_directory(con, cfg, temp_directory = temp_directory)

  query <- .stage04_build_spine_query(cfg, input_path = input_path)
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage04_person_month_spine AS %s", query))
  copy_query_to_parquet(
    con,
    "SELECT * FROM stage04_person_month_spine",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage04_copy_csv(con, .stage04_qc_query(), qc_path, overwrite = overwrite)
  .stage04_copy_csv(con, .stage04_descriptive_query(), descriptive_path, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    descriptive_path = normalizePath(descriptive_path, mustWork = FALSE),
    input_path = input_path
  ))
}
