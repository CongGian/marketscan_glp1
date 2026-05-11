# Stage 01: extract diabetes-drug pharmacy fills with DuckDB.
#
# This stage scans the MarketScan pharmacy (D) module, keeps only claims whose
# NDC appears in configured public diabetes-drug concept files, and writes a
# reduced derived Parquet file for downstream switch classification.

.stage01_required_functions <- function() {
  required <- c(
    "validate_config",
    "resolve_module_files",
    "resolve_code_list_path",
    "duckdb_connect",
    "duckdb_disconnect",
    "sql_file_list",
    "sql_quote_identifier",
    "normalize_sql_date_expr",
    "normalize_sql_ndc11_expr",
    "create_parquet_view",
    "copy_query_to_parquet",
    "normalize_ndc11"
  )
  missing <- required[!vapply(required, exists, logical(1), mode = "function")]
  if (length(missing) > 0L) {
    stop(
      "Stage 01 dependencies are not loaded: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

stage01_default_drug_classes <- function(cfg) {
  validate_config(cfg)
  configured <- cfg$outcomes_and_mediators$monthly_drug_classes
  if (is.null(configured) || length(configured) == 0L) {
    configured <- c("glp1", "glp1_like", "dpp4", "metformin", "insulin", "sglt2")
  }
  unique(as.character(configured))
}

.stage01_select_existing_drug_classes <- function(cfg, drug_classes, must_exist = TRUE) {
  available <- names(cfg$code_lists$drug_ndc)
  selected <- intersect(drug_classes, available)
  missing <- setdiff(drug_classes, available)
  if (length(missing) > 0L && isTRUE(must_exist)) {
    stop(
      "Requested drug class(es) are not configured under code_lists.drug_ndc: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  selected
}

.stage01_read_one_ndc_list <- function(path, drug_class) {
  if (!file.exists(path)) {
    stop("NDC code-list file does not exist: ", path, call. = FALSE)
  }
  x <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
  ndc_col <- intersect(c("NDC11", "ndc11", "ndc", "NDC", "NDCNUM"), names(x))
  if (length(ndc_col) == 0L) {
    stop("NDC code-list file lacks an NDC column: ", path, call. = FALSE)
  }
  ndc <- normalize_ndc11(x[[ndc_col[[1L]]]])
  out <- data.frame(
    ndc11 = ndc,
    drug_class = as.character(drug_class),
    code_list_name = basename(path),
    stringsAsFactors = FALSE
  )
  out <- out[!is.na(out$ndc11) & nzchar(out$ndc11), , drop = FALSE]
  unique(out)
}

load_stage01_ndc_map <- function(cfg, drug_classes = NULL, must_exist = TRUE) {
  .stage01_required_functions()
  validate_config(cfg)

  if (is.null(drug_classes) || length(drug_classes) == 0L) {
    drug_classes <- stage01_default_drug_classes(cfg)
  }
  drug_classes <- .stage01_select_existing_drug_classes(cfg, unique(as.character(drug_classes)), must_exist)
  if (length(drug_classes) == 0L) {
    stop("No configured drug classes were selected for Stage 01.", call. = FALSE)
  }

  pieces <- lapply(drug_classes, function(drug_class) {
    path <- resolve_code_list_path(
      cfg,
      group = "drug_ndc",
      name = drug_class,
      must_exist = must_exist
    )
    .stage01_read_one_ndc_list(path, drug_class)
  })

  out <- unique(do.call(rbind, pieces))
  out <- out[order(out$drug_class, out$ndc11), , drop = FALSE]
  rownames(out) <- NULL
  out
}

.stage01_describe_parquet <- function(con, paths) {
  sql <- sprintf(
    "DESCRIBE SELECT * FROM read_parquet(%s, union_by_name=true);",
    sql_file_list(paths)
  )
  desc <- DBI::dbGetQuery(con, sql)
  names(desc) <- tolower(names(desc))
  desc
}

.stage01_column_names <- function(con, paths) {
  desc <- .stage01_describe_parquet(con, paths)
  if (!"column_name" %in% names(desc)) {
    stop("Unable to inspect parquet schema for pharmacy files.", call. = FALSE)
  }
  desc$column_name
}

.stage01_optional_numeric_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("TRY_CAST(%s AS DOUBLE) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(NULL AS DOUBLE) AS %s", sql_quote_identifier(alias))
  }
}

.stage01_optional_character_expr <- function(columns, source_col, alias) {
  if (!is.null(source_col) && source_col %in% columns) {
    sprintf("CAST(%s AS VARCHAR) AS %s", sql_quote_identifier(source_col), sql_quote_identifier(alias))
  } else {
    sprintf("CAST(NULL AS VARCHAR) AS %s", sql_quote_identifier(alias))
  }
}

.stage01_build_extract_query <- function(cfg, columns, years, source_view = "raw_pharmacy_d") {
  vars <- cfg$variables$D
  required <- unname(c(vars$enrollee_id, vars$fill_date, vars$ndc, vars$days_supply))
  missing <- setdiff(required, columns)
  if (length(missing) > 0L) {
    stop(
      "Pharmacy D parquet is missing required column(s): ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  years_sql <- paste(sort(unique(as.integer(years))), collapse = ", ")

  enrollee_expr <- sprintf(
    "CAST(%s AS VARCHAR) AS enrollee_id",
    sql_quote_identifier(vars$enrollee_id)
  )
  fill_date_expr <- sprintf(
    "%s AS fill_date",
    normalize_sql_date_expr(sql_quote_identifier(vars$fill_date))
  )
  ndc_expr <- sprintf(
    "%s AS ndc11",
    normalize_sql_ndc11_expr(sql_quote_identifier(vars$ndc))
  )
  days_supply_expr <- sprintf(
    "TRY_CAST(%s AS INTEGER) AS days_supply",
    sql_quote_identifier(vars$days_supply)
  )
  year_raw_expr <- if (!is.null(vars$year) && vars$year %in% columns) {
    sprintf("TRY_CAST(%s AS INTEGER) AS source_year", sql_quote_identifier(vars$year))
  } else {
    "CAST(NULL AS INTEGER) AS source_year"
  }

  select_exprs <- c(
    enrollee_expr,
    fill_date_expr,
    ndc_expr,
    days_supply_expr,
    year_raw_expr,
    .stage01_optional_numeric_expr(columns, vars$quantity, "quantity"),
    .stage01_optional_numeric_expr(columns, vars$metric_quantity, "metric_quantity"),
    .stage01_optional_numeric_expr(columns, vars$allowed_amount, "allowed_amount"),
    .stage01_optional_numeric_expr(columns, vars$plan_paid, "plan_paid"),
    .stage01_optional_numeric_expr(columns, vars$copay, "copay"),
    .stage01_optional_numeric_expr(columns, vars$coinsurance, "coinsurance"),
    .stage01_optional_numeric_expr(columns, vars$deductible, "deductible"),
    .stage01_optional_character_expr(columns, vars$generic_id, "generic_id"),
    .stage01_optional_character_expr(columns, vars$therapeutic_class, "therapeutic_class"),
    .stage01_optional_character_expr(columns, vars$therapeutic_group, "therapeutic_group"),
    .stage01_optional_character_expr(columns, vars$refill, "refill"),
    .stage01_optional_character_expr(columns, vars$plan_type, "plan_type"),
    .stage01_optional_character_expr(columns, vars$health_plan, "health_plan"),
    .stage01_optional_character_expr(columns, vars$age, "age"),
    .stage01_optional_character_expr(columns, vars$sex, "sex"),
    .stage01_optional_character_expr(columns, vars$region, "region")
  )

  sprintf(
    paste(
      "WITH standardized_base AS (",
      "  SELECT %s",
      "  FROM %s",
      "), standardized AS (",
      "  SELECT",
      "    enrollee_id,",
      "    fill_date,",
      "    ndc11,",
      "    days_supply,",
      "    COALESCE(source_year, CAST(EXTRACT(year FROM fill_date) AS INTEGER)) AS claim_year,",
      "    quantity, metric_quantity, allowed_amount, plan_paid, copay, coinsurance, deductible,",
      "    generic_id, therapeutic_class, therapeutic_group, refill, plan_type, health_plan, age, sex, region",
      "  FROM standardized_base",
      "), matched AS (",
      "  SELECT",
      "    s.enrollee_id,",
      "    s.fill_date,",
      "    s.claim_year,",
      "    s.ndc11,",
      "    c.drug_class,",
      "    c.code_list_name,",
      "    s.days_supply,",
      "    s.quantity,",
      "    s.metric_quantity,",
      "    s.allowed_amount,",
      "    s.plan_paid,",
      "    s.copay,",
      "    s.coinsurance,",
      "    s.deductible,",
      "    COALESCE(s.copay, 0) + COALESCE(s.coinsurance, 0) + COALESCE(s.deductible, 0) AS patient_oop,",
      "    s.generic_id, s.therapeutic_class, s.therapeutic_group, s.refill,",
      "    s.plan_type, s.health_plan, s.age, s.sex, s.region",
      "  FROM standardized s",
      "  INNER JOIN drug_code_list c",
      "    ON s.ndc11 = c.ndc11",
      "  WHERE s.enrollee_id IS NOT NULL",
      "    AND s.enrollee_id <> ''",
      "    AND s.fill_date IS NOT NULL",
      "    AND s.ndc11 IS NOT NULL",
      "    AND length(s.ndc11) = 11",
      "    AND s.days_supply IS NOT NULL",
      "    AND s.days_supply > 0",
      "    AND s.days_supply <= 365",
      "    AND s.claim_year IN (%s)",
      ")",
      "SELECT *",
      "FROM matched",
      "ORDER BY claim_year, enrollee_id, fill_date, drug_class, ndc11",
      sep = "\n"
    ),
    paste(select_exprs, collapse = ",\n    "),
    sql_quote_identifier(source_view),
    years_sql
  )
}

stage01_year_label <- function(years) {
  years <- sort(unique(as.integer(years)))
  if (length(years) == 1L) {
    as.character(years)
  } else {
    paste0(min(years), "_", max(years))
  }
}

default_stage01_output_path <- function(cfg, years) {
  file.path(
    path.expand(cfg$paths$derived_root %||% "derived"),
    "drug_fills",
    sprintf("diabetes_drug_fills_%s.parquet", stage01_year_label(years))
  )
}

extract_diabetes_drug_fills <- function(cfg,
                                        years = NULL,
                                        drug_classes = NULL,
                                        output_path = NULL,
                                        db_path = ":memory:",
                                        threads = 4L,
                                        memory_limit = "32GB",
                                        overwrite = TRUE) {
  .stage01_required_functions()
  validate_config(cfg)
  if (is.null(years) || length(years) == 0L) {
    years <- cfg$study_period$data_years
  }
  years <- sort(unique(as.integer(years)))
  if (any(is.na(years))) {
    stop("years must be numeric/integer values.", call. = FALSE)
  }
  if (is.null(output_path)) {
    output_path <- default_stage01_output_path(cfg, years)
  }

  module_files <- resolve_module_files(cfg, modules = "D", years = years, must_exist = TRUE)
  ndc_map <- load_stage01_ndc_map(cfg, drug_classes = drug_classes, must_exist = TRUE)

  con <- NULL
  on.exit(duckdb_disconnect(con), add = TRUE)
  con <- duckdb_connect(db_path = db_path, threads = threads, memory_limit = memory_limit)

  DBI::dbWriteTable(con, "drug_code_list_input", ndc_map, overwrite = TRUE)
  DBI::dbExecute(
    con,
    "CREATE OR REPLACE TEMP VIEW drug_code_list AS SELECT DISTINCT ndc11, drug_class, code_list_name FROM drug_code_list_input"
  )

  create_parquet_view(con, "raw_pharmacy_d", module_files$path, union_by_name = TRUE)
  columns <- .stage01_column_names(con, module_files$path)
  query <- .stage01_build_extract_query(cfg, columns, years = years, source_view = "raw_pharmacy_d")
  copy_query_to_parquet(con, query, output_path = output_path, overwrite = overwrite)

  invisible(list(
    output_path = normalizePath(output_path, mustWork = FALSE),
    years = years,
    drug_classes = sort(unique(ndc_map$drug_class)),
    input_files = module_files$path
  ))
}
