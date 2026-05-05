#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(glue)
  library(readr)
})

# =========================
# PATHS 
# =========================
data_dir <- "/N/project/mscan_trial/data/parquet_raw/2022"
work_dir <- "/N/project/mscan_trial/trial_users/tgian"

in_dir  <- file.path(work_dir, "inputs")
out_dir <- file.path(work_dir, "outputs")
db_dir  <- file.path(work_dir, "duckdb")

dir.create(in_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(db_dir,  showWarnings = FALSE, recursive = TRUE)

ndc_path <- file.path(in_dir, "glp1_ndc11.csv")
db_path  <- file.path(db_dir, "marketscan_2022.duckdb")

# =========================
# Parameters
# =========================
washout_days    <- 180
min_follow_days <- 180

# =========================
# Helpers
# =========================
stop2 <- function(...) stop(paste0(...), call. = FALSE)

normalize_ndc11 <- function(x) {
  x <- gsub("[^0-9]", "", x)
  sprintf("%011s", x)  # left-pad with zeros to 11 digits
}
# =========================
# Locate shards (lowercase module letters: _d_ and _t_; no prefix assumption)
# =========================
d_glob <- file.path(data_dir, "*_d_*.snappy.parquet")
t_glob <- file.path(data_dir, "*_t_*.snappy.parquet")

d_files <- Sys.glob(d_glob)
t_files <- Sys.glob(t_glob)

if (length(d_files) == 0) stop2("No D shards found with: ", d_glob)
if (length(t_files) == 0) stop2("No T shards found with: ", t_glob)

cat("Found D shards:", length(d_files), "\n")
cat("Found T shards:", length(t_files), "\n")
cat("Example D file:", basename(d_files[1]), "\n")
cat("Example T file:", basename(t_files[1]), "\n")


# =========================
# Require NDC file ()	
# =========================
if (!file.exists(ndc_path)) {
  stop2(
    "Missing required file: ", ndc_path, "\n\n",
    "Create it as CSV with one column named NDC11.\n",
    "Example:\n",
    "NDC11\n00002143380\n00169406013\n"
  )
}

ndc_tbl <- read_csv(ndc_path, show_col_types = FALSE)
if (!("NDC11" %in% names(ndc_tbl))) {
  stop2("NDC file must have a column named exactly NDC11. Found: ",
        paste(names(ndc_tbl), collapse = ", "))
}
ndc_tbl$NDC11 <- normalize_ndc11(ndc_tbl$NDC11)
ndc_tbl <- unique(ndc_tbl["NDC11"])
if (nrow(ndc_tbl) == 0) stop2("NDC list is empty after normalization.")

# =========================
# Connect DuckDB ()
# =========================
con <- dbConnect(duckdb::duckdb(), dbdir = db_path, read_only = FALSE)
dbExecute(con, "SET threads=8;")
dbExecute(con, "SET memory_limit='16GB';")

# Build explicit file lists (more robust than relying on DuckDB globbing)
d_list_sql <- paste0("['", paste(gsub("'", "''", d_files), collapse="','"), "']")
t_list_sql <- paste0("['", paste(gsub("'", "''", t_files), collapse="','"), "']")

dbExecute(con, glue("CREATE OR REPLACE VIEW d_raw AS SELECT * FROM read_parquet({d_list_sql});"))
dbExecute(con, glue("CREATE OR REPLACE VIEW t_raw AS SELECT * FROM read_parquet({t_list_sql});"))


# =========================
# Schema check (hard stop if required columns missing)
# =========================
d_desc <- dbGetQuery(con, "DESCRIBE d_raw;")
t_desc <- dbGetQuery(con, "DESCRIBE t_raw;")

write.csv(d_desc, file.path(out_dir, "schema_d.csv"), row.names = FALSE)
write.csv(t_desc, file.path(out_dir, "schema_t.csv"), row.names = FALSE)

d_cols <- toupper(d_desc$column_name)
t_cols <- toupper(t_desc$column_name)

req_D <- c("ENROLID","SVCDATE","NDCNUM","DAYSUPP")
req_T <- c("ENROLID","DTSTART","DTEND","RX")

miss_D <- setdiff(req_D, d_cols)
miss_T <- setdiff(req_T, t_cols)

if (length(miss_D) > 0) stop2("D missing: ", paste(miss_D, collapse = ", "),
                             " (see outputs/schema_d.csv)")
if (length(miss_T) > 0) stop2("T missing: ", paste(miss_T, collapse = ", "),
                             " (see outputs/schema_t.csv)")

# =========================
# Load NDC list into DuckDB
# =========================
dbWriteTable(con, "glp1_ndc", ndc_tbl, temporary = TRUE, overwrite = TRUE)

# =========================
# Standardize key fields (dates + NDC)
# =========================
# NOTE: we keep everything as DATE and use integer day arithmetic (no INTERVALs)
dbExecute(con, "
CREATE OR REPLACE TEMP VIEW d_std AS
SELECT
  ENROLID,
  CASE
    WHEN typeof(SVCDATE) IN ('INTEGER','BIGINT','UBIGINT') THEN (DATE '1960-01-01' + CAST(SVCDATE AS INTEGER))
    ELSE CAST(SVCDATE AS DATE)
  END AS FILL_DATE,
  lpad(regexp_replace(CAST(NDCNUM AS VARCHAR), '[^0-9]', ''), 11, '0') AS NDC11,
  CAST(DAYSUPP AS INTEGER) AS DAYSUPP
FROM d_raw
WHERE ENROLID IS NOT NULL AND SVCDATE IS NOT NULL AND NDCNUM IS NOT NULL AND DAYSUPP IS NOT NULL
")

dbExecute(con, "
CREATE OR REPLACE TEMP VIEW t_std AS
SELECT
  ENROLID,
  CASE
    WHEN typeof(DTSTART) IN ('INTEGER','BIGINT','UBIGINT') THEN (DATE '1960-01-01' + CAST(DTSTART AS INTEGER))
    ELSE CAST(DTSTART AS DATE)
  END AS ENR_START,
  CASE
    WHEN typeof(DTEND) IN ('INTEGER','BIGINT','UBIGINT') THEN (DATE '1960-01-01' + CAST(DTEND AS INTEGER))
    ELSE CAST(DTEND AS DATE)
  END AS ENR_END,
  CAST(RX AS VARCHAR) AS RX
FROM t_raw
WHERE ENROLID IS NOT NULL AND DTSTART IS NOT NULL AND DTEND IS NOT NULL
")

# =========================
# Build RX=1 enrollment spells (merge overlapping/contiguous segments)
# =========================
dbExecute(con, "
CREATE OR REPLACE TEMP VIEW t_rx AS
SELECT ENROLID, ENR_START, ENR_END
FROM t_std
WHERE RX = '1'
")

dbExecute(con, "
CREATE OR REPLACE TEMP VIEW t_rx_marked AS
SELECT
  ENROLID, ENR_START, ENR_END,
  CASE
    WHEN lag(ENR_END) OVER (PARTITION BY ENROLID ORDER BY ENR_START, ENR_END) IS NULL THEN 1
    WHEN ENR_START > (lag(ENR_END) OVER (PARTITION BY ENROLID ORDER BY ENR_START, ENR_END) + 1) THEN 1
    ELSE 0
  END AS new_spell
FROM t_rx
")

dbExecute(con, "
CREATE OR REPLACE TEMP VIEW t_rx_spells AS
WITH x AS (
  SELECT *,
         SUM(new_spell) OVER (
           PARTITION BY ENROLID ORDER BY ENR_START, ENR_END
           ROWS UNBOUNDED PRECEDING
         ) AS spell_id
  FROM t_rx_marked
)
SELECT
  ENROLID,
  MIN(ENR_START) AS spell_start,
  MAX(ENR_END)   AS spell_end
FROM x
GROUP BY ENROLID, spell_id
")

# =========================
# Pull GLP-1 Rx fills only
# =========================
dbExecute(con, "
CREATE OR REPLACE TEMP TABLE glp1_rx AS
SELECT d.ENROLID, d.FILL_DATE, d.NDC11, d.DAYSUPP
FROM d_std d
INNER JOIN glp1_ndc n ON d.NDC11 = n.NDC11
WHERE d.DAYSUPP > 0 AND d.DAYSUPP <= 365
")

# =========================
# Define index date + pool (continuous RX spell around index)
# =========================
dbExecute(con, "
CREATE OR REPLACE TEMP TABLE glp1_index AS
SELECT
  ENROLID,
  MIN(FILL_DATE) AS index_date,
  COUNT(*)       AS n_glp1_fills
FROM glp1_rx
GROUP BY ENROLID
")

dbExecute(con, glue("
CREATE OR REPLACE TEMP TABLE glp1_pool AS
SELECT g.*
FROM glp1_index g
WHERE EXISTS (
  SELECT 1
  FROM t_rx_spells s
  WHERE s.ENROLID = g.ENROLID
    AND s.spell_start <= (g.index_date - {washout_days})
    AND s.spell_end   >= (g.index_date + {min_follow_days})
)
"))

# Restrict GLP1 Rx to pool (for Script 2)
dbExecute(con, "
CREATE OR REPLACE TEMP TABLE glp1_rx_pool AS
SELECT r.*
FROM glp1_rx r
JOIN glp1_pool p ON p.ENROLID = r.ENROLID
")

# =========================
# Export outputs (small files)
# =========================
dbExecute(con, glue("
COPY (SELECT * FROM glp1_pool)
TO '{file.path(out_dir, "glp1_pool.parquet")}'
(FORMAT PARQUET)
"))

dbExecute(con, glue("
COPY (SELECT * FROM glp1_rx_pool)
TO '{file.path(out_dir, "glp1_rx_pool.parquet")}'
(FORMAT PARQUET)
"))

# Summary
pool_n <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM glp1_pool;")$n
rx_n   <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM glp1_rx_pool;")$n

cat("DONE Script 1\n",
    "GLP1 pool size: ", pool_n, "\n",
    "GLP1 rx rows (pool): ", rx_n, "\n",
    "Outputs written to: ", out_dir, "\n", sep = "")

dbDisconnect(con, shutdown = TRUE)

