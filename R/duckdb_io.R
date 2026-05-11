# DuckDB I/O helpers for production MarketScan stages.
#
# These helpers operate on metadata/configured paths. They do not inspect or
# export row-level MarketScan records by themselves.

require_namespace <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Required R package is not installed: ", pkg, call. = FALSE)
  }
}

duckdb_connect <- function(db_path = ":memory:", threads = 8, memory_limit = "32GB") {
  require_namespace("DBI")
  require_namespace("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
  DBI::dbExecute(con, sprintf("SET threads=%s;", as.integer(threads)))
  DBI::dbExecute(con, sprintf("SET memory_limit='%s';", memory_limit))
  con
}

duckdb_disconnect <- function(con) {
  if (!is.null(con)) {
    DBI::dbDisconnect(con, shutdown = TRUE)
  }
}

sql_quote_string <- function(x) {
  paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
}

sql_quote_identifier <- function(x) {
  paste0('"', gsub('"', '""', x, fixed = TRUE), '"')
}

sql_file_list <- function(paths) {
  if (length(paths) == 0) {
    stop("No file paths supplied.", call. = FALSE)
  }
  paste0("[", paste(sql_quote_string(paths), collapse = ","), "]")
}

create_parquet_view <- function(con, view_name, paths, columns = NULL, union_by_name = TRUE) {
  require_namespace("DBI")
  cols_sql <- if (is.null(columns) || length(columns) == 0) {
    "*"
  } else {
    paste(sql_quote_identifier(columns), collapse = ", ")
  }
  union_sql <- if (isTRUE(union_by_name)) ", union_by_name=true" else ""
  sql <- sprintf(
    'CREATE OR REPLACE VIEW %s AS SELECT %s FROM read_parquet(%s%s);',
    sql_quote_identifier(view_name),
    cols_sql,
    sql_file_list(paths),
    union_sql
  )
  DBI::dbExecute(con, sql)
  invisible(view_name)
}

copy_query_to_parquet <- function(con, query, output_path, overwrite = TRUE) {
  require_namespace("DBI")
  if (file.exists(output_path)) {
    if (!isTRUE(overwrite)) {
      stop("Output already exists: ", output_path, call. = FALSE)
    }
    unlink(output_path)
  }
  dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
  escaped <- gsub("'", "''", output_path, fixed = TRUE)
  DBI::dbExecute(
    con,
    sprintf("COPY (%s) TO '%s' (FORMAT PARQUET);", query, escaped)
  )
  invisible(output_path)
}

normalize_sql_date_expr <- function(column_name) {
  sprintf(
    "CASE WHEN typeof(%1$s) IN ('INTEGER','BIGINT','UBIGINT') THEN (DATE '1960-01-01' + CAST(%1$s AS INTEGER)) ELSE CAST(%1$s AS DATE) END",
    column_name
  )
}

normalize_sql_ndc11_expr <- function(column_name) {
  sprintf(
    "lpad(regexp_replace(regexp_replace(CAST(%s AS VARCHAR), '\\\\.0+$', ''), '[^0-9]', '', 'g'), 11, '0')",
    column_name
  )
}
