#!/usr/bin/env Rscript

# End-to-end synthetic run for the DPP-4 to GLP-1 person-month pipeline.
# This script uses only artificial data from R/synthetic_data.R.

args <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(args) >= 1L) args[[1L]] else "outputs/synthetic_pipeline"

source("R/synthetic_data.R")
source("R/drug_episodes.R")
source("R/enrollment.R")
source("R/person_month.R")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tables <- make_synthetic_marketscan_tables()
ndc <- synthetic_ndc_codes()

drug_map <- data.frame(
  ndc11 = unname(c(ndc$dpp4, ndc$glp1, ndc$metformin)),
  drug_class = c(
    rep("dpp4", length(ndc$dpp4)),
    rep("glp1", length(ndc$glp1)),
    rep("metformin", length(ndc$metformin))
  ),
  stringsAsFactors = FALSE
)

rx <- data.frame(
  enrollee_id = tables$D$ENROLID,
  fill_date = tables$D$SVCDATE,
  ndc11 = tables$D$NDCNUM,
  days_supply = tables$D$DAYSUPP,
  stringsAsFactors = FALSE
)
rx <- merge(rx, drug_map, by = "ndc11", all.x = TRUE, sort = FALSE)
rx <- standardize_rx_claims(rx)

switches <- classify_dpp4_to_glp1_switches(
  rx,
  index_start = "2018-01-01",
  index_end = "2022-12-31"
)
switches$episode_id <- paste0(switches$enrollee_id, "_ep001")
switches$switch_category <- switches$switch_class

enrollment <- standardize_enrollment(tables$T)
enrollment_flags <- check_continuous_enrollment(
  switches[c("enrollee_id", "index_date")],
  enrollment,
  baseline_months = 12L,
  followup_months = 12L,
  require_rx = TRUE,
  require_medical = TRUE
)
switches <- merge(switches, enrollment_flags, by = "enrollee_id", all.x = TRUE, sort = FALSE)

episode_lookup <- switches[c("enrollee_id", "episode_id")]

drug_fills <- merge(
  rx,
  episode_lookup,
  by = "enrollee_id",
  all.x = FALSE,
  sort = FALSE
)
drug_fills$drug_class <- ifelse(drug_fills$drug_class == "glp1", "glp1_like", drug_fills$drug_class)

rx_financials <- merge(
  data.frame(
    enrollee_id = tables$D$ENROLID,
    service_date = tables$D$SVCDATE,
    class = "rx",
    pay = tables$D$PAY,
    netpay = tables$D$NETPAY,
    copay = tables$D$COPAY,
    coinsurance = tables$D$COINS,
    deductible = tables$D$DEDUCT,
    stringsAsFactors = FALSE
  ),
  episode_lookup,
  by = "enrollee_id",
  all.x = FALSE,
  sort = FALSE
)

outpatient_financials <- merge(
  data.frame(
    enrollee_id = tables$O$ENROLID,
    service_date = tables$O$SVCDATE,
    class = "medical",
    pay = tables$O$PAY,
    netpay = tables$O$NETPAY,
    copay = tables$O$COPAY,
    coinsurance = tables$O$COINS,
    deductible = tables$O$DEDUCT,
    stringsAsFactors = FALSE
  ),
  episode_lookup,
  by = "enrollee_id",
  all.x = FALSE,
  sort = FALSE
)

financials <- rbind(rx_financials, outpatient_financials)

medical_claims <- merge(
  data.frame(
    enrollee_id = tables$O$ENROLID,
    service_date = tables$O$SVCDATE,
    setting = ifelse(tables$O$STDPLAC == "23", "ed", "office"),
    dx1 = tables$O$DX1,
    dx2 = tables$O$DX2,
    dx3 = tables$O$DX3,
    dx4 = tables$O$DX4,
    stringsAsFactors = FALSE
  ),
  episode_lookup,
  by = "enrollee_id",
  all.x = FALSE,
  sort = FALSE
)

person_month <- assemble_person_month_table(
  index_table = switches[c("enrollee_id", "episode_id", "index_date", "switch_category")],
  drug_fills = drug_fills,
  financials = financials,
  medical_claims = medical_claims,
  diagnosis_prefixes = list(
    type2_diabetes = "E11",
    obesity = "E66",
    chronic_kidney_disease = "N18"
  )
)

person_month <- merge(
  person_month,
  switches[c("enrollee_id", "episode_id", "continuous_enrollment")],
  by = c("enrollee_id", "episode_id"),
  all.x = TRUE,
  sort = FALSE
)

utils::write.csv(switches, file.path(out_dir, "synthetic_switches.csv"), row.names = FALSE)
utils::write.csv(person_month, file.path(out_dir, "synthetic_person_month.csv"), row.names = FALSE)

primary <- person_month[
  person_month$switch_category == "clean_replacement" &
    !is.na(person_month$continuous_enrollment) &
    person_month$continuous_enrollment,
  ,
  drop = FALSE
]
utils::write.csv(primary, file.path(out_dir, "synthetic_person_month_primary_clean.csv"), row.names = FALSE)

cat("Synthetic pipeline complete\n")
cat("Switch episodes:", nrow(switches), "\n")
cat("Person-month rows:", nrow(person_month), "\n")
cat("Primary clean-replacement rows after continuous enrollment:", nrow(primary), "\n")
cat("Output directory:", out_dir, "\n")
