# Stage 06: add medical utilization, spending, and diagnosis features.
#
# This stage enriches the Stage 05 person-month file with outpatient/inpatient
# utilization, medical spending/OOP, monthly diagnosis flags, and baseline
# comorbidity flags. Real-data execution scans MarketScan O and I files for the
# already-defined switcher sample only and must be analyst-run.

.stage06_required_functions <- function() {
  required <- c(
    "validate_config",
    "resolve_module_files",
    "resolve_code_list_path",
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
      "Stage 06 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage06_default_input_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_with_pharmacy.parquet"
  )
}

stage06_default_output_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "person_month",
    "person_month_with_pharmacy_medical.parquet"
  )
}

stage06_default_qc_path <- function(cfg) {
  file.path(
    path.expand(cfg$paths$output_root %||% "outputs/dpp4_to_glp1"),
    "qc",
    "stage06_medical_feature_counts.csv"
  )
}

.stage06_check_files <- function(paths, label) {
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

.stage06_describe_parquet <- function(con, paths) {
  sql <- sprintf(
    "DESCRIBE SELECT * FROM read_parquet(%s, union_by_name=true);",
    sql_file_list(paths)
  )
  desc <- DBI::dbGetQuery(con, sql)
  names(desc) <- tolower(names(desc))
  desc
}

.stage06_column_names <- function(con, paths) {
  desc <- .stage06_describe_parquet(con, paths)
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for Stage 06 input files.", call. = FALSE)
  }
  desc$column_name
}

.stage06_set_temp_directory <- function(con, cfg, temp_directory = NULL) {
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

.stage06_sanitize_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x[x == "" | is.na(x)] <- "missing"
  starts_with_digit <- grepl("^[0-9]", x)
  x[starts_with_digit] <- paste0("x", x[starts_with_digit])
  x
}

.stage06_clean_code <- function(x) {
  x <- toupper(gsub("[^A-Za-z0-9]", "", as.character(x)))
  x[x == "" | is.na(x)] <- NA_character_
  x
}

stage06_diagnosis_concepts <- function(cfg, concepts = NULL) {
  validate_config(cfg)
  if (!is.null(concepts) && length(concepts) > 0L) {
    return(unique(as.character(concepts)))
  }
  groups <- names(cfg$code_lists$diagnosis_groups %||% list())
  groups <- setdiff(groups, "all_clinical_conditions")
  baseline <- cfg$outcomes_and_mediators$baseline_conditions %||% character()
  unique(c(as.character(baseline), groups))
}

load_stage06_diagnosis_map <- function(cfg, concepts = NULL, must_exist = TRUE) {
  .stage06_required_functions()
  validate_config(cfg)
  concepts <- stage06_diagnosis_concepts(cfg, concepts = concepts)

  all_conditions_path <- NULL
  if (!is.null(cfg$code_lists$diagnosis_groups$all_clinical_conditions)) {
    all_conditions_path <- resolve_code_list_path(
      cfg,
      group = "diagnosis_groups",
      name = "all_clinical_conditions",
      must_exist = FALSE
    )
  }

  if (!is.null(all_conditions_path) && file.exists(all_conditions_path)) {
    paths <- all_conditions_path
  } else {
    paths <- vapply(
      concepts,
      function(concept) {
        resolve_code_list_path(
          cfg,
          group = "diagnosis_groups",
          name = concept,
          must_exist = must_exist
        )
      },
      character(1L)
    )
  }

  pieces <- lapply(unique(paths), function(path) {
    x <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
    concept_col <- intersect(c("concept_id", "concept", "condition"), names(x))
    code_col <- intersect(c("code", "code_prefix", "diagnosis_code", "icd10cm"), names(x))
    if (length(concept_col) == 0L || length(code_col) == 0L) {
      stop(
        "Diagnosis code-list file must contain a concept column and a code column: ",
        path,
        call. = FALSE
      )
    }
    concept_col <- concept_col[[1L]]
    code_col <- code_col[[1L]]
    if (!"match_type" %in% names(x)) {
      x$match_type <- if (identical(code_col, "code_prefix")) "prefix" else "prefix"
    }
    data.frame(
      concept_id = .stage06_sanitize_name(x[[concept_col]]),
      code = .stage06_clean_code(x[[code_col]]),
      match_type = tolower(trimws(x$match_type)),
      stringsAsFactors = FALSE
    )
  })

  out <- unique(do.call(rbind, pieces))
  concepts_clean <- .stage06_sanitize_name(concepts)
  out <- out[out$concept_id %in% concepts_clean & !is.na(out$code), , drop = FALSE]
  out$match_type[!out$match_type %in% c("exact", "prefix")] <- "prefix"
  out <- out[order(out$concept_id, out$code), , drop = FALSE]
  rownames(out) <- NULL
  out
}

.stage06_optional_numeric_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("TRY_CAST(%s AS DOUBLE) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(NULL AS DOUBLE) AS %s", sql_quote_identifier(alias))
  }
}

.stage06_dx_exprs <- function(columns, dx_fields, max_dx = 16L) {
  dx_fields <- as.character(dx_fields %||% character())
  exprs <- character(max_dx)
  for (i in seq_len(max_dx)) {
    source_col <- if (i <= length(dx_fields)) dx_fields[[i]] else NA_character_
    alias <- sprintf("dx_%02d", i)
    if (!is.na(source_col) && source_col %in% columns) {
      exprs[[i]] <- sprintf("CAST(%s AS VARCHAR) AS %s", sql_quote_identifier(source_col), alias)
    } else {
      exprs[[i]] <- sprintf("CAST(NULL AS VARCHAR) AS %s", alias)
    }
  }
  exprs
}

.stage06_outpatient_sql <- function(cfg, paths, columns, max_dx = 16L) {
  vars <- cfg$variables$O
  required <- unname(c(vars$enrollee_id, vars$service_start))
  missing <- setdiff(required, columns)
  if (length(missing) > 0L) {
    stop("Outpatient O parquet is missing required column(s): ", paste(missing, collapse = ", "), call. = FALSE)
  }
  place_expr <- if (!is.null(vars$place_of_service) && vars$place_of_service %in% columns) {
    sprintf("CAST(%s AS VARCHAR)", sql_quote_identifier(vars$place_of_service))
  } else {
    "CAST(NULL AS VARCHAR)"
  }
  allowed <- .stage06_optional_numeric_expr(columns, vars$allowed_amount, "allowed_amount")
  plan <- .stage06_optional_numeric_expr(columns, vars$plan_paid, "plan_paid")
  copay <- .stage06_optional_numeric_expr(columns, vars$copay, "copay")
  coins <- .stage06_optional_numeric_expr(columns, vars$coinsurance, "coinsurance")
  ded <- .stage06_optional_numeric_expr(columns, vars$deductible, "deductible")
  dx <- .stage06_dx_exprs(columns, vars$dx_fields, max_dx = max_dx)

  sprintf(
    paste(
      "SELECT",
      "  concat('O:', CAST(row_number() OVER () AS VARCHAR)) AS claim_id,",
      "  CAST(%s AS VARCHAR) AS enrollee_id,",
      "  CAST('outpatient' AS VARCHAR) AS claim_source,",
      "  %s AS service_date,",
      "  CASE WHEN %s = '23' THEN 'ed' ELSE 'outpatient' END AS care_setting,",
      "  %s, %s, %s, %s, %s,",
      "  %s",
      "FROM read_parquet(%s, union_by_name=true)",
      sep = "\n"
    ),
    sql_quote_identifier(vars$enrollee_id),
    normalize_sql_date_expr(sql_quote_identifier(vars$service_start)),
    place_expr,
    allowed,
    plan,
    copay,
    coins,
    ded,
    paste(dx, collapse = ",\n  "),
    sql_file_list(paths)
  )
}

.stage06_inpatient_sql <- function(cfg, paths, columns, max_dx = 16L) {
  vars <- cfg$variables$I
  required <- unname(c(vars$enrollee_id, vars$admission_date))
  missing <- setdiff(required, columns)
  if (length(missing) > 0L) {
    stop("Inpatient I parquet is missing required column(s): ", paste(missing, collapse = ", "), call. = FALSE)
  }
  allowed <- .stage06_optional_numeric_expr(columns, vars$allowed_amount, "allowed_amount")
  plan <- .stage06_optional_numeric_expr(columns, vars$plan_paid, "plan_paid")
  copay <- .stage06_optional_numeric_expr(columns, vars$copay, "copay")
  coins <- .stage06_optional_numeric_expr(columns, vars$coinsurance, "coinsurance")
  ded <- .stage06_optional_numeric_expr(columns, vars$deductible, "deductible")
  dx <- .stage06_dx_exprs(columns, vars$dx_fields, max_dx = max_dx)

  sprintf(
    paste(
      "SELECT",
      "  concat('I:', CAST(row_number() OVER () AS VARCHAR)) AS claim_id,",
      "  CAST(%s AS VARCHAR) AS enrollee_id,",
      "  CAST('inpatient' AS VARCHAR) AS claim_source,",
      "  %s AS service_date,",
      "  CAST('inpatient' AS VARCHAR) AS care_setting,",
      "  %s, %s, %s, %s, %s,",
      "  %s",
      "FROM read_parquet(%s, union_by_name=true)",
      sep = "\n"
    ),
    sql_quote_identifier(vars$enrollee_id),
    normalize_sql_date_expr(sql_quote_identifier(vars$admission_date)),
    allowed,
    plan,
    copay,
    coins,
    ded,
    paste(dx, collapse = ",\n  "),
    sql_file_list(paths)
  )
}

.stage06_dx_long_sql <- function(max_dx = 16L) {
  pieces <- vapply(seq_len(max_dx), function(i) {
    dx_col <- sprintf("dx_%02d", i)
    sprintf(
      "SELECT claim_id, regexp_replace(upper(CAST(%s AS VARCHAR)), '[^A-Z0-9]', '', 'g') AS dx_code FROM unified_claims WHERE %s IS NOT NULL",
      dx_col,
      dx_col
    )
  }, character(1L))
  paste(pieces, collapse = "\nUNION ALL\n")
}

.stage06_condition_exprs <- function(concepts, prefix) {
  vapply(concepts, function(concept) {
    col <- paste0(prefix, "_condition_", .stage06_sanitize_name(concept))
    sprintf(
      "COALESCE(%s.%s, FALSE) AS %s",
      if (identical(prefix, "monthly")) "mc" else "bc",
      col,
      col
    )
  }, character(1L))
}

.stage06_condition_aggregate_exprs <- function(concepts, prefix) {
  vapply(concepts, function(concept) {
    col <- paste0(prefix, "_condition_", .stage06_sanitize_name(concept))
    sprintf(
      "MAX(CASE WHEN m.concept_id = %s THEN 1 ELSE 0 END) > 0 AS %s",
      sql_quote_string(.stage06_sanitize_name(concept)),
      col
    )
  }, character(1L))
}

.stage06_build_query <- function(cfg, input_path, outpatient_paths, inpatient_paths,
                                 outpatient_columns, inpatient_columns, concepts) {
  max_dx <- 16L
  concepts <- .stage06_sanitize_name(concepts)
  outpatient_sql <- .stage06_outpatient_sql(cfg, outpatient_paths, outpatient_columns, max_dx = max_dx)
  inpatient_sql <- .stage06_inpatient_sql(cfg, inpatient_paths, inpatient_columns, max_dx = max_dx)
  monthly_condition_aggs <- .stage06_condition_aggregate_exprs(concepts, "monthly")
  baseline_condition_aggs <- .stage06_condition_aggregate_exprs(concepts, "baseline")
  monthly_condition_selects <- .stage06_condition_exprs(concepts, "monthly")
  baseline_condition_selects <- .stage06_condition_exprs(concepts, "baseline")

  sprintf(
    paste(
      "WITH person_month AS (",
      "  SELECT * FROM read_parquet(%s, union_by_name=true)",
      "), sample_ids AS (",
      "  SELECT DISTINCT CAST(enrollee_id AS VARCHAR) AS enrollee_id FROM person_month",
      "), raw_claims AS (",
      "  %s",
      "  UNION ALL",
      "  %s",
      "), unified_claims AS (",
      "  SELECT",
      "    r.*,",
      "    COALESCE(r.copay, 0) + COALESCE(r.coinsurance, 0) + COALESCE(r.deductible, 0) AS patient_oop",
      "  FROM raw_claims r",
      "  INNER JOIN sample_ids ids ON r.enrollee_id = ids.enrollee_id",
      "  WHERE r.enrollee_id IS NOT NULL",
      "    AND r.enrollee_id <> ''",
      "    AND r.service_date IS NOT NULL",
      "), dx_long AS (",
      "  %s",
      "), matched_concepts AS (",
      "  SELECT DISTINCT d.claim_id, c.concept_id",
      "  FROM dx_long d",
      "  INNER JOIN diagnosis_code_list c",
      "    ON (c.match_type = 'exact' AND d.dx_code = c.code)",
      "    OR (c.match_type = 'prefix' AND d.dx_code LIKE c.code || '%%')",
      "  WHERE d.dx_code IS NOT NULL AND d.dx_code <> ''",
      "), medical_month AS (",
      "  SELECT",
      "    pm.enrollee_id, pm.episode_id, pm.event_month,",
      "    COUNT(DISTINCT c.claim_id)::INTEGER AS monthly_medical_claim_count,",
      "    COUNT(DISTINCT CASE WHEN c.claim_source = 'outpatient' THEN c.claim_id ELSE NULL END)::INTEGER AS monthly_outpatient_claim_count,",
      "    COUNT(DISTINCT CASE WHEN c.claim_source = 'inpatient' THEN c.claim_id ELSE NULL END)::INTEGER AS monthly_inpatient_admissions,",
      "    COUNT(DISTINCT CASE WHEN c.care_setting = 'ed' THEN c.claim_id ELSE NULL END)::INTEGER AS monthly_ed_visits,",
      "    COALESCE(SUM(c.allowed_amount), 0)::DOUBLE AS monthly_allowed_amount_medical,",
      "    COALESCE(SUM(c.plan_paid), 0)::DOUBLE AS monthly_plan_paid_medical,",
      "    COALESCE(SUM(c.patient_oop), 0)::DOUBLE AS monthly_patient_oop_medical",
      "  FROM person_month pm",
      "  LEFT JOIN unified_claims c",
      "    ON c.enrollee_id = pm.enrollee_id",
      "   AND c.service_date BETWEEN pm.month_start AND pm.month_end",
      "  GROUP BY pm.enrollee_id, pm.episode_id, pm.event_month",
      "), baseline_medical AS (",
      "  SELECT",
      "    pm.enrollee_id, pm.episode_id,",
      "    COUNT(DISTINCT c.claim_id)::INTEGER AS baseline_medical_claim_count,",
      "    COUNT(DISTINCT CASE WHEN c.claim_source = 'outpatient' THEN c.claim_id ELSE NULL END)::INTEGER AS baseline_outpatient_claim_count,",
      "    COUNT(DISTINCT CASE WHEN c.claim_source = 'inpatient' THEN c.claim_id ELSE NULL END)::INTEGER AS baseline_inpatient_admissions,",
      "    COUNT(DISTINCT CASE WHEN c.care_setting = 'ed' THEN c.claim_id ELSE NULL END)::INTEGER AS baseline_ed_visits,",
      "    COALESCE(SUM(c.allowed_amount), 0)::DOUBLE AS baseline_allowed_amount_medical,",
      "    COALESCE(SUM(c.plan_paid), 0)::DOUBLE AS baseline_plan_paid_medical,",
      "    COALESCE(SUM(c.patient_oop), 0)::DOUBLE AS baseline_patient_oop_medical",
      "  FROM (SELECT DISTINCT enrollee_id, episode_id, index_date, required_enrollment_start FROM person_month) pm",
      "  LEFT JOIN unified_claims c",
      "    ON c.enrollee_id = pm.enrollee_id",
      "   AND c.service_date >= pm.required_enrollment_start",
      "   AND c.service_date < pm.index_date",
      "  GROUP BY pm.enrollee_id, pm.episode_id",
      "), monthly_conditions AS (",
      "  SELECT",
      "    pm.enrollee_id, pm.episode_id, pm.event_month,",
      "    %s",
      "  FROM person_month pm",
      "  LEFT JOIN unified_claims c",
      "    ON c.enrollee_id = pm.enrollee_id",
      "   AND c.service_date BETWEEN pm.month_start AND pm.month_end",
      "  LEFT JOIN matched_concepts m ON c.claim_id = m.claim_id",
      "  GROUP BY pm.enrollee_id, pm.episode_id, pm.event_month",
      "), baseline_conditions AS (",
      "  SELECT",
      "    pm.enrollee_id, pm.episode_id,",
      "    %s",
      "  FROM (SELECT DISTINCT enrollee_id, episode_id, index_date, required_enrollment_start FROM person_month) pm",
      "  LEFT JOIN unified_claims c",
      "    ON c.enrollee_id = pm.enrollee_id",
      "   AND c.service_date >= pm.required_enrollment_start",
      "   AND c.service_date < pm.index_date",
      "  LEFT JOIN matched_concepts m ON c.claim_id = m.claim_id",
      "  GROUP BY pm.enrollee_id, pm.episode_id",
      ")",
      "SELECT",
      "  pm.*,",
      "  COALESCE(mm.monthly_medical_claim_count, 0) AS monthly_medical_claim_count,",
      "  COALESCE(mm.monthly_outpatient_claim_count, 0) AS monthly_outpatient_claim_count,",
      "  COALESCE(mm.monthly_inpatient_admissions, 0) AS monthly_inpatient_admissions,",
      "  COALESCE(mm.monthly_ed_visits, 0) AS monthly_ed_visits,",
      "  COALESCE(mm.monthly_allowed_amount_medical, 0) AS monthly_allowed_amount_medical,",
      "  COALESCE(mm.monthly_plan_paid_medical, 0) AS monthly_plan_paid_medical,",
      "  COALESCE(mm.monthly_patient_oop_medical, 0) AS monthly_patient_oop_medical,",
      "  COALESCE(bm.baseline_medical_claim_count, 0) AS baseline_medical_claim_count,",
      "  COALESCE(bm.baseline_outpatient_claim_count, 0) AS baseline_outpatient_claim_count,",
      "  COALESCE(bm.baseline_inpatient_admissions, 0) AS baseline_inpatient_admissions,",
      "  COALESCE(bm.baseline_ed_visits, 0) AS baseline_ed_visits,",
      "  COALESCE(bm.baseline_allowed_amount_medical, 0) AS baseline_allowed_amount_medical,",
      "  COALESCE(bm.baseline_plan_paid_medical, 0) AS baseline_plan_paid_medical,",
      "  COALESCE(bm.baseline_patient_oop_medical, 0) AS baseline_patient_oop_medical,",
      "  %s,",
      "  %s",
      "FROM person_month pm",
      "LEFT JOIN medical_month mm",
      "  ON pm.enrollee_id = mm.enrollee_id AND pm.episode_id = mm.episode_id AND pm.event_month = mm.event_month",
      "LEFT JOIN baseline_medical bm",
      "  ON pm.enrollee_id = bm.enrollee_id AND pm.episode_id = bm.episode_id",
      "LEFT JOIN monthly_conditions mc",
      "  ON pm.enrollee_id = mc.enrollee_id AND pm.episode_id = mc.episode_id AND pm.event_month = mc.event_month",
      "LEFT JOIN baseline_conditions bc",
      "  ON pm.enrollee_id = bc.enrollee_id AND pm.episode_id = bc.episode_id",
      "ORDER BY pm.index_year, pm.enrollee_id, pm.episode_number, pm.event_month",
      sep = "\n"
    ),
    sql_quote_string(input_path),
    outpatient_sql,
    inpatient_sql,
    .stage06_dx_long_sql(max_dx = max_dx),
    paste(monthly_condition_aggs, collapse = ",\n    "),
    paste(baseline_condition_aggs, collapse = ",\n    "),
    paste(monthly_condition_selects, collapse = ",\n  "),
    paste(baseline_condition_selects, collapse = ",\n  ")
  )
}

.stage06_qc_query <- function(concepts) {
  concept_rows <- vapply(concepts, function(concept) {
    suffix <- .stage06_sanitize_name(concept)
    sprintf(
      "SELECT 'episodes_with_baseline_condition' AS metric, %s AS metric_value, COUNT(DISTINCT CASE WHEN baseline_condition_%s THEN episode_id ELSE NULL END)::BIGINT AS row_count FROM stage06_person_month_medical",
      sql_quote_string(suffix),
      suffix
    )
  }, character(1L))

  paste(
    "SELECT metric, metric_value, row_count",
    "FROM (",
    "  SELECT 'episodes' AS metric, 'all' AS metric_value, COUNT(DISTINCT episode_id)::BIGINT AS row_count FROM stage06_person_month_medical",
    "  UNION ALL",
    "  SELECT 'person_month_rows' AS metric, 'all' AS metric_value, COUNT(*)::BIGINT AS row_count FROM stage06_person_month_medical",
    "  UNION ALL",
    "  SELECT 'person_months_with_medical_claim' AS metric, 'all' AS metric_value, SUM(CASE WHEN monthly_medical_claim_count > 0 THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage06_person_month_medical",
    "  UNION ALL",
    "  SELECT 'person_months_with_inpatient_admission' AS metric, 'all' AS metric_value, SUM(CASE WHEN monthly_inpatient_admissions > 0 THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage06_person_month_medical",
    "  UNION ALL",
    "  SELECT 'person_months_with_ed_visit' AS metric, 'all' AS metric_value, SUM(CASE WHEN monthly_ed_visits > 0 THEN 1 ELSE 0 END)::BIGINT AS row_count FROM stage06_person_month_medical",
    if (length(concept_rows) > 0L) paste("  UNION ALL", paste(concept_rows, collapse = "\n  UNION ALL\n")) else "",
    ")",
    "ORDER BY metric, metric_value",
    sep = "\n"
  )
}

.stage06_copy_qc <- function(con, qc_path, concepts, overwrite = TRUE) {
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
      .stage06_qc_query(concepts),
      sql_quote_string(qc_path)
    )
  )
  invisible(qc_path)
}

add_medical_features <- function(cfg,
                                 input_path = NULL,
                                 outpatient_paths = NULL,
                                 inpatient_paths = NULL,
                                 years = NULL,
                                 output_path = NULL,
                                 qc_path = NULL,
                                 diagnosis_concepts = NULL,
                                 db_path = ":memory:",
                                 threads = 8L,
                                 memory_limit = "64GB",
                                 temp_directory = NULL,
                                 overwrite = TRUE) {
  .stage06_required_functions()
  validate_config(cfg)

  input_path <- input_path %||% stage06_default_input_path(cfg)
  input_path <- normalizePath(input_path, mustWork = FALSE)
  .stage06_check_files(input_path, "Stage 05 person-month pharmacy")

  if (is.null(years) || length(years) == 0L) {
    years <- cfg$study_period$data_years
  }
  years <- sort(unique(as.integer(years)))
  if (is.null(outpatient_paths) || length(outpatient_paths) == 0L) {
    outpatient_paths <- resolve_module_files(cfg, modules = "O", years = years, must_exist = TRUE)$path
  }
  if (is.null(inpatient_paths) || length(inpatient_paths) == 0L) {
    inpatient_paths <- resolve_module_files(cfg, modules = "I", years = years, must_exist = TRUE)$path
  }
  outpatient_paths <- normalizePath(outpatient_paths, mustWork = FALSE)
  inpatient_paths <- normalizePath(inpatient_paths, mustWork = FALSE)
  .stage06_check_files(outpatient_paths, "Outpatient O")
  .stage06_check_files(inpatient_paths, "Inpatient I")

  output_path <- output_path %||% stage06_default_output_path(cfg)
  qc_path <- qc_path %||% stage06_default_qc_path(cfg)
  diagnosis_map <- load_stage06_diagnosis_map(cfg, concepts = diagnosis_concepts, must_exist = TRUE)
  concepts <- sort(unique(diagnosis_map$concept_id))

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)
  .stage06_set_temp_directory(con, cfg, temp_directory = temp_directory)

  DBI::dbWriteTable(con, "diagnosis_code_list", diagnosis_map, overwrite = TRUE)
  outpatient_columns <- .stage06_column_names(con, outpatient_paths)
  inpatient_columns <- .stage06_column_names(con, inpatient_paths)
  query <- .stage06_build_query(
    cfg = cfg,
    input_path = input_path,
    outpatient_paths = outpatient_paths,
    inpatient_paths = inpatient_paths,
    outpatient_columns = outpatient_columns,
    inpatient_columns = inpatient_columns,
    concepts = concepts
  )
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TABLE stage06_person_month_medical AS %s", query))
  copy_query_to_parquet(
    con,
    "SELECT * FROM stage06_person_month_medical",
    output_path = output_path,
    overwrite = overwrite
  )
  .stage06_copy_qc(con, qc_path = qc_path, concepts = concepts, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    qc_path = normalizePath(qc_path, mustWork = FALSE),
    input_path = input_path,
    outpatient_paths = outpatient_paths,
    inpatient_paths = inpatient_paths,
    diagnosis_concepts = concepts
  ))
}
