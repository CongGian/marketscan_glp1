# Stage 02: identify DPP-4 to GLP-1 switch candidate episodes.
#
# This stage reads the reduced Stage 01 diabetes-drug fill parquet files and
# writes one selected candidate switch episode per enrollee. It should run only
# inside the approved restricted workspace when pointed at real MarketScan
# derived files.

.stage02_required_functions <- function() {
  required <- c(
    "validate_config",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_file_list",
    "sql_quote_string",
    "copy_query_to_parquet"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 02 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage02_default_input_paths <- function(cfg, years = NULL) {
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

stage02_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "switch_candidates",
    "dpp4_to_glp1_switch_candidates.parquet"
  )
}

stage02_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage02_switch_candidate_counts.csv"
  )
}

stage02_glp1_index_class <- function(cfg, override = NULL) {
  validate_config(cfg)
  if (!is.null(override) && nzchar(override)) {
    return(as.character(override))
  }
  include_tirzepatide <- isTRUE(cfg$exposure_definition$include_tirzepatide_in_primary_glp1_like)
  if (include_tirzepatide) "glp1_like" else "glp1"
}

.stage02_check_files <- function(paths) {
  if (length(paths) == 0L) {
    stop("No Stage 02 input files were supplied.", call. = FALSE)
  }
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0L) {
    stop(
      "Stage 02 input file(s) do not exist:\n",
      paste(missing, collapse = "\n"),
      call. = FALSE
    )
  }
  invisible(paths)
}

.stage02_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage02_interval_days <- function(cfg, name, default) {
  value <- cfg$exposure_definition[[name]] %||% default
  value <- as.integer(value)
  if (length(value) != 1L || is.na(value) || value < 0L) {
    stop("exposure_definition.", name, " must be a non-negative integer.", call. = FALSE)
  }
  value
}

.stage02_build_candidate_query <- function(cfg, input_paths, glp1_index_class = NULL) {
  validate_config(cfg)
  glp1_index_class <- stage02_glp1_index_class(cfg, glp1_index_class)

  index_start <- as.Date(cfg$study_period$index_start)
  index_end <- as.Date(cfg$study_period$index_end)
  if (is.na(index_start) || is.na(index_end)) {
    stop("study_period index dates must parse as YYYY-MM-DD.", call. = FALSE)
  }

  glp1_washout_days <- .stage02_interval_days(cfg, "glp1_washout_days", 365L)
  dpp4_lookback_days <- .stage02_interval_days(cfg, "dpp4_preindex_lookback_days", 180L)
  dpp4_preindex_grace_days <- .stage02_interval_days(cfg, "dpp4_preindex_grace_days", 60L)
  replacement_assessment_days <- .stage02_interval_days(cfg, "replacement_assessment_days", 120L)
  postindex_grace_days <- .stage02_interval_days(cfg, "dpp4_postindex_grace_days", 30L)
  transition_overlap_allowed_days <- .stage02_interval_days(cfg, "allow_transition_overlap_days", 30L)

  sprintf(
    paste(
      "WITH fills_raw AS (",
      "  SELECT DISTINCT",
      "    CAST(enrollee_id AS VARCHAR) AS enrollee_id,",
      "    CAST(fill_date AS DATE) AS fill_date,",
      "    CAST(claim_year AS INTEGER) AS claim_year,",
      "    CAST(ndc11 AS VARCHAR) AS ndc11,",
      "    CAST(drug_class AS VARCHAR) AS drug_class,",
      "    CAST(days_supply AS INTEGER) AS days_supply",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE drug_class IN ('dpp4', %s)",
      "    AND enrollee_id IS NOT NULL",
      "    AND fill_date IS NOT NULL",
      "    AND ndc11 IS NOT NULL",
      "    AND days_supply IS NOT NULL",
      "    AND days_supply > 0",
      "    AND days_supply <= 365",
      "), fills AS (",
      "  SELECT",
      "    enrollee_id, fill_date, claim_year, ndc11,",
      "    CASE WHEN drug_class = 'dpp4' THEN 'dpp4' ELSE 'glp1_index' END AS exposure_class,",
      "    days_supply,",
      "    fill_date + CAST(days_supply - 1 AS INTEGER) AS fill_end",
      "  FROM fills_raw",
      "), glp1_fills AS (",
      "  SELECT * FROM fills WHERE exposure_class = 'glp1_index'",
      "), dpp4_fills AS (",
      "  SELECT * FROM fills WHERE exposure_class = 'dpp4'",
      "), glp1_candidates_base AS (",
      "  SELECT",
      "    g.*,",
      "    max(g.fill_date) OVER (",
      "      PARTITION BY g.enrollee_id",
      "      ORDER BY g.fill_date, g.ndc11",
      "      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING",
      "    ) AS prior_glp1_fill_date",
      "  FROM glp1_fills g",
      "), candidates AS (",
      "  SELECT",
      "    row_number() OVER (ORDER BY enrollee_id, fill_date, ndc11) AS candidate_id,",
      "    enrollee_id,",
      "    fill_date AS index_date,",
      "    CAST(EXTRACT(year FROM fill_date) AS INTEGER) AS index_year,",
      "    ndc11 AS index_ndc11,",
      "    days_supply AS index_days_supply,",
      "    fill_end AS index_fill_end,",
      "    prior_glp1_fill_date,",
      "    CASE",
      "      WHEN prior_glp1_fill_date IS NULL THEN NULL",
      "      ELSE date_diff('day', prior_glp1_fill_date, fill_date)",
      "    END AS days_since_prior_glp1,",
      "    CASE",
      "      WHEN prior_glp1_fill_date IS NULL THEN TRUE",
      "      WHEN date_diff('day', prior_glp1_fill_date, fill_date) > %d THEN TRUE",
      "      ELSE FALSE",
      "    END AS glp1_washout_pass",
      "  FROM glp1_candidates_base",
      "  WHERE fill_date BETWEEN DATE %s AND DATE %s",
      "), dpp4_pre_fills AS (",
      "  SELECT",
      "    c.candidate_id,",
      "    count(d.enrollee_id) AS dpp4_preindex_fill_count,",
      "    max(d.fill_date) AS last_dpp4_fill_preindex",
      "  FROM candidates c",
      "  LEFT JOIN dpp4_fills d",
      "    ON d.enrollee_id = c.enrollee_id",
      "   AND d.fill_date >= c.index_date - INTERVAL %d DAY",
      "   AND d.fill_date < c.index_date",
      "  GROUP BY c.candidate_id",
      "), dpp4_pre_coverage AS (",
      "  SELECT",
      "    c.candidate_id,",
      "    max(d.fill_end) AS last_dpp4_coverage_end_preindex",
      "  FROM candidates c",
      "  LEFT JOIN dpp4_fills d",
      "    ON d.enrollee_id = c.enrollee_id",
      "   AND d.fill_date < c.index_date",
      "   AND d.fill_end >= c.index_date - INTERVAL %d DAY",
      "  GROUP BY c.candidate_id",
      "), dpp4_post AS (",
      "  SELECT",
      "    c.candidate_id,",
      "    count(d.enrollee_id) AS dpp4_postindex_fill_count_0_120,",
      "    min(CASE",
      "      WHEN d.fill_date > c.index_date + INTERVAL %d DAY THEN d.fill_date",
      "      ELSE NULL",
      "    END) AS first_dpp4_fill_after_grace",
      "  FROM candidates c",
      "  LEFT JOIN dpp4_fills d",
      "    ON d.enrollee_id = c.enrollee_id",
      "   AND d.fill_date >= c.index_date",
      "   AND d.fill_date <= c.index_date + INTERVAL %d DAY",
      "  GROUP BY c.candidate_id",
      "), dpp4_transition AS (",
      "  SELECT",
      "    c.candidate_id,",
      "    max(d.fill_end) AS dpp4_transition_max_end",
      "  FROM candidates c",
      "  LEFT JOIN dpp4_fills d",
      "    ON d.enrollee_id = c.enrollee_id",
      "   AND d.fill_date <= c.index_date + INTERVAL %d DAY",
      "   AND d.fill_end >= c.index_date",
      "  GROUP BY c.candidate_id",
      "), glp1_post_coverage AS (",
      "  SELECT",
      "    c.candidate_id,",
      "    max(g.fill_end) AS glp1_episode_end",
      "  FROM candidates c",
      "  LEFT JOIN glp1_fills g",
      "    ON g.enrollee_id = c.enrollee_id",
      "   AND g.fill_date >= c.index_date",
      "   AND g.fill_date <= c.index_date + INTERVAL %d DAY",
      "  GROUP BY c.candidate_id",
      "), features AS (",
      "  SELECT",
      "    c.*,",
      "    COALESCE(pre.dpp4_preindex_fill_count, 0) AS dpp4_preindex_fill_count,",
      "    pre.last_dpp4_fill_preindex,",
      "    cov.last_dpp4_coverage_end_preindex,",
      "    CASE",
      "      WHEN cov.last_dpp4_coverage_end_preindex IS NULL THEN NULL",
      "      ELSE greatest(0, date_diff('day', cov.last_dpp4_coverage_end_preindex, c.index_date) - 1)",
      "    END AS dpp4_gap_days_before_index,",
      "    (",
      "      COALESCE(pre.dpp4_preindex_fill_count, 0) > 0",
      "      AND cov.last_dpp4_coverage_end_preindex >= c.index_date - INTERVAL %d DAY",
      "    ) AS qualifying_dpp4_preindex,",
      "    COALESCE(post.dpp4_postindex_fill_count_0_120, 0) AS dpp4_postindex_fill_count_0_120,",
      "    post.first_dpp4_fill_after_grace,",
      "    post.first_dpp4_fill_after_grace IS NOT NULL AS dpp4_postindex_fill_after_grace,",
      "    CASE",
      "      WHEN trans.dpp4_transition_max_end IS NULL THEN 0",
      "      ELSE greatest(0, date_diff('day', c.index_date, trans.dpp4_transition_max_end) + 1)",
      "    END AS dpp4_overlap_days_after_index,",
      "    COALESCE(glp1cov.glp1_episode_end, c.index_fill_end) AS glp1_episode_end",
      "  FROM candidates c",
      "  LEFT JOIN dpp4_pre_fills pre ON c.candidate_id = pre.candidate_id",
      "  LEFT JOIN dpp4_pre_coverage cov ON c.candidate_id = cov.candidate_id",
      "  LEFT JOIN dpp4_post post ON c.candidate_id = post.candidate_id",
      "  LEFT JOIN dpp4_transition trans ON c.candidate_id = trans.candidate_id",
      "  LEFT JOIN glp1_post_coverage glp1cov ON c.candidate_id = glp1cov.candidate_id",
      "), switchback AS (",
      "  SELECT",
      "    f.candidate_id,",
      "    count(d.enrollee_id) > 0 AS switch_back",
      "  FROM features f",
      "  LEFT JOIN dpp4_fills d",
      "    ON d.enrollee_id = f.enrollee_id",
      "   AND d.fill_date > f.glp1_episode_end + INTERVAL %d DAY",
      "   AND d.fill_date <= f.index_date + INTERVAL %d DAY",
      "  GROUP BY f.candidate_id",
      "), classified AS (",
      "  SELECT",
      "    f.*,",
      "    (",
      "      f.dpp4_overlap_days_after_index > %d",
      "      OR f.dpp4_postindex_fill_after_grace",
      "    ) AS dpp4_continues_after_transition,",
      "    COALESCE(sb.switch_back, FALSE) AS switch_back,",
      "    CASE",
      "      WHEN NOT f.glp1_washout_pass THEN 'prior_glp1_washout_failure'",
      "      WHEN NOT f.qualifying_dpp4_preindex THEN 'ambiguous_switch'",
      "      WHEN (f.dpp4_overlap_days_after_index > %d OR f.dpp4_postindex_fill_after_grace) THEN 'addon_or_overlap'",
      "      ELSE 'clean_replacement'",
      "    END AS switch_class",
      "  FROM features f",
      "  LEFT JOIN switchback sb ON f.candidate_id = sb.candidate_id",
      "), ranked AS (",
      "  SELECT",
      "    *,",
      "    row_number() OVER (",
      "      PARTITION BY enrollee_id",
      "      ORDER BY CASE WHEN qualifying_dpp4_preindex THEN 0 ELSE 1 END, index_date, index_ndc11",
      "    ) AS candidate_rank",
      "  FROM classified",
      ")",
      "SELECT",
      "  enrollee_id,",
      "  1 AS episode_number,",
      "  index_date,",
      "  index_year,",
      "  index_ndc11,",
      "  %s AS index_drug_class,",
      "  index_days_supply,",
      "  prior_glp1_fill_date,",
      "  days_since_prior_glp1,",
      "  glp1_washout_pass,",
      "  dpp4_preindex_fill_count,",
      "  last_dpp4_fill_preindex,",
      "  last_dpp4_coverage_end_preindex,",
      "  dpp4_gap_days_before_index,",
      "  qualifying_dpp4_preindex,",
      "  dpp4_postindex_fill_count_0_120,",
      "  first_dpp4_fill_after_grace,",
      "  dpp4_postindex_fill_after_grace,",
      "  dpp4_overlap_days_after_index,",
      "  dpp4_continues_after_transition,",
      "  switch_back,",
      "  glp1_episode_end,",
      "  switch_class,",
      "  switch_class AS classification,",
      "  switch_class = 'clean_replacement' AS primary_clean_replacement",
      "FROM ranked",
      "WHERE candidate_rank = 1",
      "ORDER BY index_year, enrollee_id",
      sep = "\n"
    ),
    sql_file_list(input_paths),
    sql_quote_string(glp1_index_class),
    glp1_washout_days,
    sql_quote_string(as.character(index_start)),
    sql_quote_string(as.character(index_end)),
    dpp4_lookback_days,
    dpp4_lookback_days,
    postindex_grace_days,
    replacement_assessment_days,
    postindex_grace_days,
    replacement_assessment_days,
    dpp4_preindex_grace_days,
    postindex_grace_days,
    replacement_assessment_days,
    transition_overlap_allowed_days,
    transition_overlap_allowed_days,
    sql_quote_string(glp1_index_class)
  )
}

.stage02_copy_qc <- function(con, qc_path, overwrite = TRUE) {
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
        "  SELECT switch_class, count(*) AS candidate_count",
        "  FROM stage02_switch_candidates",
        "  GROUP BY switch_class",
        "  ORDER BY switch_class",
        ") TO '%s' (HEADER, DELIMITER ',');",
        sep = "\n"
      ),
      escaped
    )
  )
  invisible(qc_path)
}

extract_switch_candidates <- function(cfg,
                                      input_paths = NULL,
                                      years = NULL,
                                      output_path = NULL,
                                      qc_path = NULL,
                                      glp1_index_class = NULL,
                                      db_path = ":memory:",
                                      threads = 8L,
                                      memory_limit = "64GB",
                                      temp_directory = NULL,
                                      overwrite = TRUE) {
  .stage02_required_functions()
  validate_config(cfg)

  if (is.null(input_paths) || length(input_paths) == 0L) {
    input_paths <- stage02_default_input_paths(cfg, years = years)
  }
  input_paths <- normalizePath(input_paths, mustWork = FALSE)
  .stage02_check_files(input_paths)

  if (is.null(output_path)) {
    output_path <- stage02_default_output_path(cfg)
  }
  if (is.null(qc_path)) {
    qc_path <- stage02_default_qc_path(cfg)
  }

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage02_set_temp_directory(con, cfg, temp_directory = temp_directory)

  query <- .stage02_build_candidate_query(
    cfg = cfg,
    input_paths = input_paths,
    glp1_index_class = glp1_index_class
  )
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage02_switch_candidates AS %s", query))
  copy_query_to_parquet(
    con,
    "SELECT * FROM stage02_switch_candidates",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage02_copy_qc(con, qc_path = qc_path, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    input_paths = input_paths,
    glp1_index_class = stage02_glp1_index_class(cfg, glp1_index_class)
  ))
}
