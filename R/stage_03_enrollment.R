# Stage 03: extract candidate enrollment and continuous-enrollment flags.
#
# This stage joins Stage 02 switch candidates to the MarketScan enrollment
# detail (T) module, restricted to candidate ENROLIDs, and writes one row per
# candidate with required baseline/follow-up enrollment flags.

.stage03_required_functions <- function() {
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
      "Stage 03 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage03_default_candidate_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "switch_candidates",
    "dpp4_to_glp1_switch_candidates.parquet"
  )
}

stage03_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "enrollment",
    "dpp4_to_glp1_switch_candidates_enrollment.parquet"
  )
}

stage03_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage03_enrollment_counts.csv"
  )
}

.stage03_check_files <- function(paths, label) {
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

.stage03_describe_parquet <- function(con, paths) {
  sql <- sprintf(
    "DESCRIBE SELECT * FROM read_parquet(%s, union_by_name=true);",
    sql_file_list(paths)
  )
  desc <- DBI::dbGetQuery(con, sql)
  names(desc) <- tolower(names(desc))
  desc
}

.stage03_column_names <- function(con, paths) {
  desc <- .stage03_describe_parquet(con, paths)
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for Stage 03 input files.", call. = FALSE)
  }
  desc$column_name
}

.stage03_optional_char_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("CAST(%s AS VARCHAR) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(NULL AS VARCHAR) AS %s", sql_quote_identifier(alias))
  }
}

.stage03_optional_int_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("TRY_CAST(%s AS INTEGER) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(NULL AS INTEGER) AS %s", sql_quote_identifier(alias))
  }
}

.stage03_active_expr <- function(columns, source_col, alias, default = TRUE) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf(
      "UPPER(CAST(%s AS VARCHAR)) IN ('1', 'Y', 'YES', 'T', 'TRUE') AS %s",
      sql_quote_identifier(source_col),
      sql_quote_identifier(alias)
    )
  } else {
    sprintf("%s AS %s", if (isTRUE(default)) "TRUE" else "FALSE", sql_quote_identifier(alias))
  }
}

.stage03_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage03_build_enrollment_query <- function(cfg, candidate_path, enrollment_paths, enrollment_columns) {
  validate_config(cfg)
  vars <- cfg$variables$T
  required <- unname(c(vars$enrollee_id, vars$enrollment_start, vars$enrollment_end))
  missing <- setdiff(required, enrollment_columns)
  if (length(missing) > 0L) {
    stop(
      "Enrollment T parquet is missing required column(s): ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  baseline_months <- as.integer(cfg$study_period$baseline_months %||% 12L)
  followup_months <- as.integer(cfg$study_period$followup_months %||% 12L)
  if (any(is.na(c(baseline_months, followup_months))) || baseline_months < 0L || followup_months < 0L) {
    stop("study_period baseline_months and followup_months must be non-negative integers.", call. = FALSE)
  }
  require_rx <- isTRUE(cfg$sample_restrictions$require_continuous_rx_enrollment)
  require_medical <- isTRUE(cfg$sample_restrictions$require_continuous_medical_enrollment)
  rx_filter <- if (require_rx) "rx_active" else "TRUE"
  medical_filter <- if (require_medical) "medical_active" else "TRUE"

  select_exprs <- c(
    sprintf("CAST(%s AS VARCHAR) AS enrollee_id", sql_quote_identifier(vars$enrollee_id)),
    sprintf("%s AS enroll_start", normalize_sql_date_expr(sql_quote_identifier(vars$enrollment_start))),
    sprintf("%s AS enroll_end", normalize_sql_date_expr(sql_quote_identifier(vars$enrollment_end))),
    .stage03_active_expr(enrollment_columns, vars$rx_benefit, "rx_active", default = TRUE),
    .stage03_active_expr(enrollment_columns, vars$medical_coverage, "medical_active", default = TRUE),
    .stage03_optional_int_expr(enrollment_columns, vars$member_days, "member_days"),
    .stage03_optional_int_expr(enrollment_columns, vars$year, "enrollment_year"),
    .stage03_optional_int_expr(enrollment_columns, vars$age, "age_at_index_candidate"),
    .stage03_optional_int_expr(enrollment_columns, vars$date_of_birth_year, "date_of_birth_year"),
    .stage03_optional_char_expr(enrollment_columns, vars$sex, "sex_at_index_candidate"),
    .stage03_optional_char_expr(enrollment_columns, vars$region, "region_at_index_candidate"),
    .stage03_optional_char_expr(enrollment_columns, vars$health_plan, "health_plan_at_index_candidate"),
    .stage03_optional_char_expr(enrollment_columns, vars$plan_type, "plan_type_at_index_candidate")
  )

  sprintf(
    paste(
      "WITH candidates AS (",
      "  SELECT",
      "    row_number() OVER (ORDER BY enrollee_id, index_date, episode_number) AS candidate_row_id,",
      "    *",
      "  FROM read_parquet(%s, union_by_name=true)",
      "), candidate_ids AS (",
      "  SELECT DISTINCT CAST(enrollee_id AS VARCHAR) AS enrollee_id",
      "  FROM candidates",
      "), enrollment_raw AS (",
      "  SELECT %s",
      "  FROM read_parquet(%s, union_by_name=true)",
      "), enrollment AS (",
      "  SELECT e.*",
      "  FROM enrollment_raw e",
      "  INNER JOIN candidate_ids ids ON e.enrollee_id = ids.enrollee_id",
      "  WHERE e.enrollee_id IS NOT NULL",
      "    AND e.enrollee_id <> ''",
      "    AND e.enroll_start IS NOT NULL",
      "    AND e.enroll_end IS NOT NULL",
      "    AND e.enroll_start <= e.enroll_end",
      "), candidate_windows AS (",
      "  SELECT",
      "    c.*,",
      "    CAST(date_trunc('month', c.index_date) AS DATE) AS index_month_start,",
      "    CAST(CAST(date_trunc('month', c.index_date) AS DATE) - INTERVAL %d MONTH AS DATE) AS required_enrollment_start,",
      "    CAST(CAST(date_trunc('month', c.index_date) AS DATE) + INTERVAL %d MONTH - INTERVAL 1 DAY AS DATE) AS required_enrollment_end",
      "  FROM candidates c",
      "), active_enrollment AS (",
      "  SELECT *",
      "  FROM enrollment",
      "  WHERE %s AND %s",
      "), ordered_spans AS (",
      "  SELECT",
      "    *,",
      "    max(enroll_end) OVER (",
      "      PARTITION BY enrollee_id",
      "      ORDER BY enroll_start, enroll_end",
      "      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING",
      "    ) AS prior_max_end",
      "  FROM active_enrollment",
      "), spell_flags AS (",
      "  SELECT",
      "    *,",
      "    CASE",
      "      WHEN prior_max_end IS NULL THEN 1",
      "      WHEN enroll_start > prior_max_end + INTERVAL 1 DAY THEN 1",
      "      ELSE 0",
      "    END AS new_spell",
      "  FROM ordered_spans",
      "), spell_groups AS (",
      "  SELECT",
      "    *,",
      "    sum(new_spell) OVER (",
      "      PARTITION BY enrollee_id",
      "      ORDER BY enroll_start, enroll_end",
      "      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW",
      "    ) AS spell_group",
      "  FROM spell_flags",
      "), merged_spells AS (",
      "  SELECT",
      "    enrollee_id,",
      "    spell_group,",
      "    min(enroll_start) AS enrollment_spell_start,",
      "    max(enroll_end) AS enrollment_spell_end",
      "  FROM spell_groups",
      "  GROUP BY enrollee_id, spell_group",
      "), matched_spells AS (",
      "  SELECT",
      "    cw.candidate_row_id,",
      "    min(ms.enrollment_spell_start) AS enrollment_spell_start,",
      "    max(ms.enrollment_spell_end) AS enrollment_spell_end,",
      "    count(ms.enrollee_id) > 0 AS continuous_enrollment",
      "  FROM candidate_windows cw",
      "  LEFT JOIN merged_spells ms",
      "    ON ms.enrollee_id = cw.enrollee_id",
      "   AND ms.enrollment_spell_start <= cw.required_enrollment_start",
      "   AND ms.enrollment_spell_end >= cw.required_enrollment_end",
      "  GROUP BY cw.candidate_row_id",
      "), demographics_ranked AS (",
      "  SELECT",
      "    cw.candidate_row_id,",
      "    e.age_at_index_candidate AS age_at_index,",
      "    e.date_of_birth_year,",
      "    e.sex_at_index_candidate AS sex,",
      "    e.region_at_index_candidate AS region,",
      "    e.health_plan_at_index_candidate AS health_plan,",
      "    e.plan_type_at_index_candidate AS plan_type,",
      "    e.rx_active AS rx_active_at_index,",
      "    e.medical_active AS medical_active_at_index,",
      "    row_number() OVER (",
      "      PARTITION BY cw.candidate_row_id",
      "      ORDER BY e.enroll_start DESC, e.enroll_end DESC",
      "    ) AS demo_rank",
      "  FROM candidate_windows cw",
      "  LEFT JOIN enrollment e",
      "    ON e.enrollee_id = cw.enrollee_id",
      "   AND e.enroll_start <= cw.index_date",
      "   AND e.enroll_end >= cw.index_date",
      "), demographics AS (",
      "  SELECT * EXCLUDE (demo_rank)",
      "  FROM demographics_ranked",
      "  WHERE demo_rank = 1",
      ")",
      "SELECT",
      "  cw.enrollee_id,",
      "  cw.episode_number,",
      "  cw.index_date,",
      "  cw.index_year,",
      "  cw.index_ndc11,",
      "  cw.index_drug_class,",
      "  cw.index_days_supply,",
      "  cw.prior_glp1_fill_date,",
      "  cw.days_since_prior_glp1,",
      "  cw.glp1_washout_pass,",
      "  cw.dpp4_preindex_fill_count,",
      "  cw.last_dpp4_fill_preindex,",
      "  cw.last_dpp4_coverage_end_preindex,",
      "  cw.dpp4_gap_days_before_index,",
      "  cw.qualifying_dpp4_preindex,",
      "  cw.dpp4_postindex_fill_count_0_120,",
      "  cw.first_dpp4_fill_after_grace,",
      "  cw.dpp4_postindex_fill_after_grace,",
      "  cw.dpp4_overlap_days_after_index,",
      "  cw.dpp4_continues_after_transition,",
      "  cw.switch_back,",
      "  cw.glp1_episode_end,",
      "  cw.switch_class,",
      "  cw.classification,",
      "  cw.primary_clean_replacement,",
      "  cw.required_enrollment_start,",
      "  cw.required_enrollment_end,",
      "  COALESCE(ms.continuous_enrollment, FALSE) AS continuous_enrollment,",
      "  ms.enrollment_spell_start,",
      "  ms.enrollment_spell_end,",
      "  d.age_at_index,",
      "  d.date_of_birth_year,",
      "  d.sex,",
      "  d.region,",
      "  d.health_plan,",
      "  d.plan_type,",
      "  COALESCE(d.rx_active_at_index, FALSE) AS rx_active_at_index,",
      "  COALESCE(d.medical_active_at_index, FALSE) AS medical_active_at_index,",
      "  (",
      "    cw.primary_clean_replacement",
      "    AND COALESCE(ms.continuous_enrollment, FALSE)",
      "  ) AS primary_clean_replacement_enrolled",
      "FROM candidate_windows cw",
      "LEFT JOIN matched_spells ms ON cw.candidate_row_id = ms.candidate_row_id",
      "LEFT JOIN demographics d ON cw.candidate_row_id = d.candidate_row_id",
      "ORDER BY cw.index_year, cw.enrollee_id",
      sep = "\n"
    ),
    sql_file_list(candidate_path),
    paste(select_exprs, collapse = ",\n    "),
    sql_file_list(enrollment_paths),
    baseline_months,
    followup_months + 1L,
    rx_filter,
    medical_filter
  )
}

.stage03_copy_qc <- function(con, qc_path, overwrite = TRUE) {
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
  escaped <- gsub("'", "''", qc_path, fixed = TRUE)
  DBI::dbExecute(
    con,
    sprintf(
      paste(
        "COPY (",
        "  SELECT",
        "    switch_class,",
        "    continuous_enrollment,",
        "    primary_clean_replacement_enrolled,",
        "    count(*) AS candidate_count",
        "  FROM stage03_candidate_enrollment",
        "  GROUP BY switch_class, continuous_enrollment, primary_clean_replacement_enrolled",
        "  ORDER BY switch_class, continuous_enrollment, primary_clean_replacement_enrolled",
        ") TO '%s' (HEADER, DELIMITER ',');",
        sep = "\n"
      ),
      escaped
    )
  )
  invisible(qc_path)
}

extract_candidate_enrollment <- function(cfg,
                                         candidate_path = NULL,
                                         enrollment_paths = NULL,
                                         years = NULL,
                                         output_path = NULL,
                                         qc_path = NULL,
                                         db_path = ":memory:",
                                         threads = 8L,
                                         memory_limit = "64GB",
                                         temp_directory = NULL,
                                         overwrite = TRUE) {
  .stage03_required_functions()
  validate_config(cfg)

  candidate_path <- candidate_path %||% stage03_default_candidate_path(cfg)
  candidate_path <- normalizePath(candidate_path, mustWork = FALSE)
  .stage03_check_files(candidate_path, "Stage 02 candidate")

  if (is.null(years) || length(years) == 0L) {
    years <- cfg$study_period$data_years
  }
  years <- sort(unique(as.integer(years)))
  if (is.null(enrollment_paths) || length(enrollment_paths) == 0L) {
    enrollment_paths <- resolve_module_files(cfg, modules = "T", years = years, must_exist = TRUE)$path
  }
  enrollment_paths <- normalizePath(enrollment_paths, mustWork = FALSE)
  .stage03_check_files(enrollment_paths, "Enrollment T")

  output_path <- output_path %||% stage03_default_output_path(cfg)
  qc_path <- qc_path %||% stage03_default_qc_path(cfg)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage03_set_temp_directory(con, cfg, temp_directory = temp_directory)

  enrollment_columns <- .stage03_column_names(con, enrollment_paths)
  query <- .stage03_build_enrollment_query(
    cfg = cfg,
    candidate_path = candidate_path,
    enrollment_paths = enrollment_paths,
    enrollment_columns = enrollment_columns
  )

  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage03_candidate_enrollment AS %s", query))
  copy_query_to_parquet(
    con,
    "SELECT * FROM stage03_candidate_enrollment",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage03_copy_qc(con, qc_path = qc_path, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    candidate_path = candidate_path,
    enrollment_paths = enrollment_paths
  ))
}
