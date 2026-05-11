# Aggregate GLP-1-like user denominators for the manuscript waterfall.
#
# This helper reads restricted Stage 01/02/03/07 derived files and writes one
# aggregate CSV. It must be analyst-run inside the approved workspace.

.stage08_glp1_required_functions <- function() {
  required <- c(
    "validate_config",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_file_list",
    "sql_quote_string"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "GLP-1 waterfall dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage08_glp1_default_drug_fill_paths <- function(cfg, years = NULL) {
  validate_config(cfg)
  years <- years %||% cfg$study_period$data_years
  years <- sort(unique(as.integer(years)))
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "drug_fills",
    sprintf("diabetes_drug_fills_%s.parquet", years)
  )
}

stage08_glp1_default_stage02_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "switch_candidates",
    "dpp4_to_glp1_switch_candidates.parquet"
  )
}

stage08_glp1_default_stage03_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "enrollment",
    "dpp4_to_glp1_switch_candidates_enrollment.parquet"
  )
}

stage08_glp1_default_final_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    cfg$outputs$person_month_table %||% "person_month_dpp4_to_glp1_switchers.parquet"
  )
}

stage08_glp1_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "figures",
    "data",
    "glp1_user_waterfall_by_period.csv"
  )
}

.stage08_glp1_check_files <- function(paths, label) {
  missing <- paths[!file.exists(paths)]
  if (length(missing) > 0L) {
    stop(label, " file(s) do not exist:\n", paste(missing, collapse = "\n"), call. = FALSE)
  }
  invisible(paths)
}

.stage08_glp1_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage08_glp1_copy_csv <- function(con, query, output_path, overwrite = TRUE) {
  if (file.exists(output_path)) {
    if (!isTRUE(overwrite)) {
      stop("Output already exists: ", output_path, call. = FALSE)
    }
    unlink(output_path)
  }
  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  DBI::dbExecute(
    con,
    sprintf(
      "COPY (%s) TO %s (HEADER, DELIMITER ',');",
      query,
      sql_quote_string(output_path)
    )
  )
  invisible(output_path)
}

.stage08_glp1_query <- function(drug_fill_paths, stage02_path, stage03_path, final_path,
                                period_start, period_end) {
  sprintf(
    paste(
      "WITH glp1_fills AS (",
      "  SELECT",
      "    CAST(EXTRACT(year FROM fill_date) AS INTEGER) AS period_year,",
      "    CAST(enrollee_id AS VARCHAR) AS enrollee_id",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE drug_class = 'glp1_like'",
      "    AND fill_date IS NOT NULL",
      "    AND CAST(EXTRACT(year FROM fill_date) AS INTEGER) BETWEEN %d AND %d",
      "), glp1_by_year AS (",
      "  SELECT",
      "    period_year,",
      "    COUNT(DISTINCT enrollee_id)::BIGINT AS glp1_like_users,",
      "    COUNT(*)::BIGINT AS glp1_like_fills",
      "  FROM glp1_fills",
      "  GROUP BY period_year",
      "), candidate_by_year AS (",
      "  SELECT",
      "    CAST(index_year AS INTEGER) AS period_year,",
      "    COUNT(*)::BIGINT AS switch_candidate_episodes,",
      "    SUM(CASE WHEN switch_class = 'clean_replacement' THEN 1 ELSE 0 END)::BIGINT AS clean_replacement_candidates",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE CAST(index_year AS INTEGER) BETWEEN %d AND %d",
      "  GROUP BY CAST(index_year AS INTEGER)",
      "), enrolled_by_year AS (",
      "  SELECT",
      "    CAST(index_year AS INTEGER) AS period_year,",
      "    SUM(CASE WHEN primary_clean_replacement_enrolled THEN 1 ELSE 0 END)::BIGINT AS enrolled_clean_replacements",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE CAST(index_year AS INTEGER) BETWEEN %d AND %d",
      "  GROUP BY CAST(index_year AS INTEGER)",
      "), final_by_year AS (",
      "  SELECT",
      "    CAST(index_year AS INTEGER) AS period_year,",
      "    COUNT(DISTINCT episode_id)::BIGINT AS final_episodes,",
      "    COUNT(*)::BIGINT AS final_person_month_rows",
      "  FROM read_parquet(%s, union_by_name=true)",
      "  WHERE CAST(index_year AS INTEGER) BETWEEN %d AND %d",
      "  GROUP BY CAST(index_year AS INTEGER)",
      "), years AS (",
      "  SELECT range::INTEGER AS period_year FROM range(%d, %d)",
      "), by_year AS (",
      "  SELECT",
      "    CAST(y.period_year AS VARCHAR) AS period,",
      "    COALESCE(g.glp1_like_users, 0)::BIGINT AS glp1_like_users,",
      "    COALESCE(g.glp1_like_fills, 0)::BIGINT AS glp1_like_fills,",
      "    COALESCE(c.switch_candidate_episodes, 0)::BIGINT AS switch_candidate_episodes,",
      "    COALESCE(c.clean_replacement_candidates, 0)::BIGINT AS clean_replacement_candidates,",
      "    COALESCE(e.enrolled_clean_replacements, 0)::BIGINT AS enrolled_clean_replacements,",
      "    COALESCE(f.final_episodes, 0)::BIGINT AS final_episodes,",
      "    COALESCE(f.final_person_month_rows, 0)::BIGINT AS final_person_month_rows",
      "  FROM years y",
      "  LEFT JOIN glp1_by_year g ON y.period_year = g.period_year",
      "  LEFT JOIN candidate_by_year c ON y.period_year = c.period_year",
      "  LEFT JOIN enrolled_by_year e ON y.period_year = e.period_year",
      "  LEFT JOIN final_by_year f ON y.period_year = f.period_year",
      "), overall AS (",
      "  SELECT",
      "    'total' AS period,",
      "    SUM(glp1_like_users)::BIGINT AS glp1_like_users,",
      "    (SELECT COUNT(*)::BIGINT FROM glp1_fills) AS glp1_like_fills,",
      "    SUM(switch_candidate_episodes)::BIGINT AS switch_candidate_episodes,",
      "    SUM(clean_replacement_candidates)::BIGINT AS clean_replacement_candidates,",
      "    SUM(enrolled_clean_replacements)::BIGINT AS enrolled_clean_replacements,",
      "    SUM(final_episodes)::BIGINT AS final_episodes,",
      "    SUM(final_person_month_rows)::BIGINT AS final_person_month_rows",
      "  FROM by_year",
      "), combined AS (",
      "  SELECT * FROM by_year",
      "  UNION ALL",
      "  SELECT * FROM overall",
      ")",
      "SELECT",
      "  period,",
      "  glp1_like_users,",
      "  glp1_like_fills,",
      "  switch_candidate_episodes AS index_candidate_episodes,",
      "  clean_replacement_candidates,",
      "  enrolled_clean_replacements,",
      "  final_episodes,",
      "  final_person_month_rows,",
      "  CASE WHEN glp1_like_users = 0 THEN NULL ELSE 100.0 * switch_candidate_episodes / glp1_like_users END AS index_candidates_per_100_glp1_users,",
      "  CASE WHEN switch_candidate_episodes = 0 THEN NULL ELSE 100.0 * clean_replacement_candidates / switch_candidate_episodes END AS clean_replacement_pct_of_candidates,",
      "  CASE WHEN clean_replacement_candidates = 0 THEN NULL ELSE 100.0 * enrolled_clean_replacements / clean_replacement_candidates END AS enrolled_pct_of_clean_replacements,",
      "  CASE WHEN enrolled_clean_replacements = 0 THEN NULL ELSE 100.0 * final_episodes / enrolled_clean_replacements END AS final_pct_of_enrolled_clean",
      "FROM combined",
      "ORDER BY CASE WHEN period = 'total' THEN 9999 ELSE CAST(period AS INTEGER) END",
      sep = "\n"
    ),
    sql_file_list(drug_fill_paths),
    period_start,
    period_end,
    sql_quote_string(stage02_path),
    period_start,
    period_end,
    sql_quote_string(stage03_path),
    period_start,
    period_end,
    sql_quote_string(final_path),
    period_start,
    period_end,
    period_start,
    period_end + 1L
  )
}

build_stage08_glp1_waterfall <- function(cfg,
                                         drug_fill_paths = NULL,
                                         stage02_path = NULL,
                                         stage03_path = NULL,
                                         final_path = NULL,
                                         output_path = NULL,
                                         db_path = ":memory:",
                                         threads = 4L,
                                         memory_limit = "32GB",
                                         temp_directory = NULL,
                                         overwrite = TRUE) {
  .stage08_glp1_required_functions()
  validate_config(cfg)

  period_start <- as.integer(format(as.Date(cfg$study_period$index_start), "%Y"))
  period_end <- as.integer(format(as.Date(cfg$study_period$index_end), "%Y"))
  if (is.na(period_start) || is.na(period_end)) {
    stop("study_period.index_start and index_end must parse as dates.", call. = FALSE)
  }

  drug_fill_paths <- drug_fill_paths %||% stage08_glp1_default_drug_fill_paths(cfg)
  stage02_path <- stage02_path %||% stage08_glp1_default_stage02_path(cfg)
  stage03_path <- stage03_path %||% stage08_glp1_default_stage03_path(cfg)
  final_path <- final_path %||% stage08_glp1_default_final_path(cfg)
  output_path <- output_path %||% stage08_glp1_default_output_path(cfg)

  drug_fill_paths <- normalizePath(drug_fill_paths, mustWork = FALSE)
  stage02_path <- normalizePath(stage02_path, mustWork = FALSE)
  stage03_path <- normalizePath(stage03_path, mustWork = FALSE)
  final_path <- normalizePath(final_path, mustWork = FALSE)

  .stage08_glp1_check_files(drug_fill_paths, "Stage 01 drug-fill")
  .stage08_glp1_check_files(stage02_path, "Stage 02 switch-candidate")
  .stage08_glp1_check_files(stage03_path, "Stage 03 enrollment")
  .stage08_glp1_check_files(final_path, "Stage 07 final person-month")

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage08_glp1_set_temp_directory(con, cfg, temp_directory = temp_directory)

  query <- .stage08_glp1_query(
    drug_fill_paths = drug_fill_paths,
    stage02_path = stage02_path,
    stage03_path = stage03_path,
    final_path = final_path,
    period_start = period_start,
    period_end = period_end
  )
  .stage08_glp1_copy_csv(con, query, output_path, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    drug_fill_paths = drug_fill_paths,
    stage02_path = stage02_path,
    stage03_path = stage03_path,
    final_path = final_path,
    period_start = period_start,
    period_end = period_end
  ))
}
