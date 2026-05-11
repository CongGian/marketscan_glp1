# Pure-R helpers for assembling DPP-4 to GLP-1 person-month panels.
#
# These functions operate on standardized in-memory data frames. They do not
# read raw MarketScan files and intentionally avoid package dependencies.

.pm_required_cols <- function(data, cols, data_name = "data") {
  missing <- setdiff(cols, names(data))
  if (length(missing) > 0L) {
    stop(
      data_name, " is missing required column(s): ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

.pm_as_date <- function(x, col_name = "date") {
  if (inherits(x, "Date")) {
    return(x)
  }
  if (inherits(x, c("POSIXct", "POSIXlt"))) {
    return(as.Date(x))
  }
  if (is.character(x)) {
    out <- as.Date(x)
    if (any(is.na(out) & !is.na(x))) {
      stop(col_name, " contains character values that cannot be parsed as Date", call. = FALSE)
    }
    return(out)
  }
  stop(
    col_name,
    " must already be standardized as Date, POSIXt, or ISO date character",
    call. = FALSE
  )
}

.pm_month_start <- function(date) {
  date <- .pm_as_date(date)
  as.Date(sprintf("%s-%s-01", format(date, "%Y"), format(date, "%m")))
}

.pm_month_id <- function(date) {
  date <- .pm_as_date(date)
  as.integer(format(date, "%Y")) * 12L + as.integer(format(date, "%m")) - 1L
}

.pm_month_from_id <- function(month_id) {
  year <- month_id %/% 12L
  month <- month_id %% 12L + 1L
  as.Date(sprintf("%04d-%02d-01", year, month))
}

.pm_add_months <- function(date, n) {
  .pm_month_from_id(.pm_month_id(.pm_month_start(date)) + as.integer(n))
}

.pm_month_end <- function(date) {
  .pm_add_months(date, 1L) - 1L
}

.pm_sanitize_name <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x[x == "" | is.na(x)] <- "missing"
  starts_with_digit <- grepl("^[0-9]", x)
  x[starts_with_digit] <- paste0("x", x[starts_with_digit])
  x
}

.pm_find_col <- function(data, aliases) {
  matched <- aliases[aliases %in% names(data)]
  if (length(matched) == 0L) {
    return(NULL)
  }
  matched[[1L]]
}

.pm_numeric <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  out[is.na(out)] <- 0
  out
}

.pm_has_episode_col <- function(data) {
  "episode_id" %in% names(data)
}

.pm_key_cols <- function() {
  c("enrollee_id", "episode_id", "event_month")
}

.pm_episode_cols <- function() {
  c("enrollee_id", "episode_id")
}

.pm_assert_unique_keys <- function(data, key_cols = .pm_key_cols()) {
  .pm_required_cols(data, key_cols, "person-month table")
  dup <- duplicated(data[key_cols])
  if (any(dup)) {
    stop("person-month table has duplicate key rows", call. = FALSE)
  }
  invisible(TRUE)
}

.pm_bind_episode_features <- function(spine, features) {
  if (is.null(features) || nrow(features) == 0L) {
    return(spine)
  }
  join_cols <- .pm_episode_cols()
  .pm_required_cols(spine, join_cols, "spine")
  .pm_required_cols(features, join_cols, "features")

  out <- spine
  out$.pm_row_id <- seq_len(nrow(out))

  overlap <- setdiff(intersect(names(out), names(features)), c(join_cols, ".pm_row_id"))
  if (length(overlap) > 0L) {
    out[overlap] <- NULL
  }

  out <- merge(out, features, by = join_cols, all.x = TRUE, sort = FALSE)
  out <- out[order(out$.pm_row_id), , drop = FALSE]
  out$.pm_row_id <- NULL
  rownames(out) <- NULL
  out
}

.pm_subset_window <- function(data, enrollee_id, episode_id, start_date, end_date, date_col) {
  dates <- .pm_as_date(data[[date_col]], date_col)
  keep <- data$enrollee_id == enrollee_id & dates >= start_date & dates <= end_date
  if (.pm_has_episode_col(data)) {
    keep <- keep & data$episode_id == episode_id
  }
  keep
}

.pm_covered_days <- function(starts, ends, window_start, window_end) {
  if (length(starts) == 0L) {
    return(0L)
  }

  starts <- .pm_as_date(starts)
  ends <- .pm_as_date(ends)
  clipped_starts <- pmax(starts, window_start)
  clipped_ends <- pmin(ends, window_end)
  keep <- !is.na(clipped_starts) & !is.na(clipped_ends) & clipped_starts <= clipped_ends

  if (!any(keep)) {
    return(0L)
  }

  clipped_starts <- clipped_starts[keep]
  clipped_ends <- clipped_ends[keep]
  ord <- order(clipped_starts, clipped_ends)
  clipped_starts <- clipped_starts[ord]
  clipped_ends <- clipped_ends[ord]

  total <- 0L
  current_start <- clipped_starts[[1L]]
  current_end <- clipped_ends[[1L]]

  for (i in seq_along(clipped_starts)[-1L]) {
    next_start <- clipped_starts[[i]]
    next_end <- clipped_ends[[i]]
    if (next_start <= current_end + 1L) {
      if (next_end > current_end) {
        current_end <- next_end
      }
    } else {
      total <- total + as.integer(current_end - current_start + 1L)
      current_start <- next_start
      current_end <- next_end
    }
  }

  total <- total + as.integer(current_end - current_start + 1L)
  as.integer(min(total, as.integer(window_end - window_start + 1L)))
}

.pm_prepare_drug_fills <- function(drug_fills, date_col, class_col, days_supply_col) {
  if (is.null(drug_fills) || nrow(drug_fills) == 0L) {
    return(NULL)
  }
  .pm_required_cols(drug_fills, c("enrollee_id", date_col, class_col), "drug_fills")

  fills <- drug_fills
  fills$.pm_fill_date <- .pm_as_date(fills[[date_col]], date_col)
  if (!is.null(days_supply_col) && days_supply_col %in% names(fills)) {
    days_supply <- suppressWarnings(as.integer(fills[[days_supply_col]]))
  } else {
    days_supply <- rep(1L, nrow(fills))
  }
  days_supply[is.na(days_supply) | days_supply < 1L] <- 1L
  fills$.pm_fill_end <- fills$.pm_fill_date + days_supply - 1L
  fills$.pm_class <- .pm_sanitize_name(fills[[class_col]])
  fills
}

.pm_amount_columns <- function(data, amount_cols = NULL) {
  defaults <- list(
    pay = c("pay", "PAY", "allowed", "allowed_amount", "gross_pay"),
    netpay = c("netpay", "NETPAY", "plan_paid", "paid_amount"),
    copay = c("copay", "COPAY"),
    coinsurance = c("coinsurance", "coins", "COINS"),
    deductible = c("deductible", "deduct", "DEDUCT"),
    patient_pay = c("patient_pay", "oop", "OOP", "patpay", "PATPAY")
  )

  if (!is.null(amount_cols)) {
    for (nm in names(amount_cols)) {
      defaults[[nm]] <- amount_cols[[nm]]
    }
  }

  vapply(
    defaults,
    function(aliases) {
      col <- .pm_find_col(data, aliases)
      if (is.null(col)) {
        NA_character_
      } else {
        col
      }
    },
    character(1L),
    USE.NAMES = TRUE
  )
}

.pm_row_amounts <- function(data, amount_cols = NULL) {
  cols <- .pm_amount_columns(data, amount_cols)
  n <- nrow(data)

  value <- function(name) {
    col <- cols[[name]]
    if (is.na(col) || is.null(col) || identical(col, "")) {
      return(rep(0, n))
    }
    .pm_numeric(data[[col]])
  }

  has_components <- any(!is.na(cols[c("copay", "coinsurance", "deductible")]))
  patient_oop <- if (has_components) {
    value("copay") + value("coinsurance") + value("deductible")
  } else {
    value("patient_pay")
  }

  data.frame(
    patient_oop = patient_oop,
    pay = value("pay"),
    netpay = value("netpay"),
    stringsAsFactors = FALSE
  )
}

.pm_prepare_financials <- function(financials, date_col, class_col = NULL, amount_cols = NULL) {
  if (is.null(financials) || nrow(financials) == 0L) {
    return(NULL)
  }
  .pm_required_cols(financials, c("enrollee_id", date_col), "financials")

  out <- financials
  out$.pm_service_date <- .pm_as_date(out[[date_col]], date_col)
  amounts <- .pm_row_amounts(out, amount_cols)
  out$.pm_patient_oop <- amounts$patient_oop
  out$.pm_pay <- amounts$pay
  out$.pm_netpay <- amounts$netpay

  if (is.null(class_col)) {
    class_col <- .pm_find_col(out, c("class", "drug_class", "claim_class", "service_class", "source"))
  }
  if (!is.null(class_col) && class_col %in% names(out)) {
    out$.pm_class <- .pm_sanitize_name(out[[class_col]])
  } else {
    out$.pm_class <- NA_character_
  }

  out
}

.pm_prepare_claims <- function(medical_claims, date_col) {
  if (is.null(medical_claims) || nrow(medical_claims) == 0L) {
    return(NULL)
  }
  .pm_required_cols(medical_claims, c("enrollee_id", date_col), "medical_claims")
  claims <- medical_claims
  claims$.pm_service_date <- .pm_as_date(claims[[date_col]], date_col)
  claims
}

.pm_claim_matches_prefix <- function(claims, diagnosis_cols, prefixes) {
  if (is.null(diagnosis_cols) || length(diagnosis_cols) == 0L || length(prefixes) == 0L) {
    return(rep(FALSE, nrow(claims)))
  }
  diagnosis_cols <- diagnosis_cols[diagnosis_cols %in% names(claims)]
  if (length(diagnosis_cols) == 0L) {
    return(rep(FALSE, nrow(claims)))
  }

  prefixes <- toupper(gsub("\\.", "", as.character(prefixes)))
  matched <- rep(FALSE, nrow(claims))
  for (col in diagnosis_cols) {
    dx <- toupper(gsub("\\.", "", as.character(claims[[col]])))
    dx[is.na(dx)] <- ""
    for (prefix in prefixes) {
      matched <- matched | startsWith(dx, prefix)
    }
  }
  matched
}

.pm_condition_flag_map <- function(condition_flag_cols) {
  if (is.null(condition_flag_cols) || length(condition_flag_cols) == 0L) {
    return(character())
  }
  if (is.null(names(condition_flag_cols)) || any(names(condition_flag_cols) == "")) {
    stats::setNames(as.character(condition_flag_cols), .pm_sanitize_name(condition_flag_cols))
  } else {
    stats::setNames(as.character(condition_flag_cols), .pm_sanitize_name(names(condition_flag_cols)))
  }
}

.pm_prefix_condition_names <- function(diagnosis_prefixes) {
  prefix_names <- names(diagnosis_prefixes)
  if (is.null(prefix_names)) {
    prefix_names <- rep("", length(diagnosis_prefixes))
  }
  missing_names <- prefix_names == "" | is.na(prefix_names)
  prefix_names[missing_names] <- paste0("dx_prefix_", which(missing_names))
  .pm_sanitize_name(prefix_names)
}

event_month_sequence <- function(event_month_min = -12L, event_month_max = 12L) {
  if (length(event_month_min) != 1L || length(event_month_max) != 1L) {
    stop("event_month_min and event_month_max must be scalar integers", call. = FALSE)
  }
  if (is.na(event_month_min) || is.na(event_month_max)) {
    stop("event_month_min and event_month_max cannot be NA", call. = FALSE)
  }
  event_month_min <- as.integer(event_month_min)
  event_month_max <- as.integer(event_month_max)
  if (event_month_min > event_month_max) {
    stop("event_month_min cannot be greater than event_month_max", call. = FALSE)
  }
  seq.int(event_month_min, event_month_max)
}

build_event_month_spine <- function(
  index_table,
  event_month_min = -12L,
  event_month_max = 12L,
  index_date_col = "index_date"
) {
  .pm_required_cols(index_table, c("enrollee_id", index_date_col), "index_table")

  index <- index_table
  if (!"episode_id" %in% names(index)) {
    index$episode_id <- seq_len(nrow(index))
  }

  index[[index_date_col]] <- .pm_as_date(index[[index_date_col]], index_date_col)
  if (index_date_col != "index_date") {
    index$index_date <- index[[index_date_col]]
  }
  index$index_month_start <- .pm_month_start(index$index_date)
  index$index_year <- as.integer(format(index$index_month_start, "%Y"))
  index$index_month <- as.integer(format(index$index_month_start, "%m"))

  event_months <- event_month_sequence(event_month_min, event_month_max)
  row_idx <- rep(seq_len(nrow(index)), each = length(event_months))
  spine <- index[row_idx, , drop = FALSE]
  spine$event_month <- rep(event_months, times = nrow(index))

  event_month_id <- .pm_month_id(spine$index_month_start) + spine$event_month
  spine$month_start <- .pm_month_from_id(event_month_id)
  spine$month_end <- .pm_month_end(spine$month_start)
  spine$calendar_year <- as.integer(format(spine$month_start, "%Y"))
  spine$calendar_month <- as.integer(format(spine$month_start, "%m"))
  spine$year_month <- format(spine$month_start, "%Y-%m")

  preferred <- c(
    "enrollee_id", "episode_id", "event_month", "year_month",
    "calendar_year", "calendar_month", "month_start", "month_end",
    "index_date", "index_year", "index_month", "index_month_start"
  )
  spine <- spine[c(preferred[preferred %in% names(spine)], setdiff(names(spine), preferred))]
  rownames(spine) <- NULL

  .pm_assert_unique_keys(spine)
  spine
}

add_monthly_drug_states <- function(
  spine,
  drug_fills = NULL,
  date_col = "fill_date",
  class_col = "drug_class",
  days_supply_col = "days_supply",
  prefix = "drug"
) {
  .pm_required_cols(spine, c(.pm_key_cols(), "month_start", "month_end"), "spine")
  fills <- .pm_prepare_drug_fills(drug_fills, date_col, class_col, days_supply_col)
  if (is.null(fills)) {
    return(spine)
  }

  classes <- sort(unique(fills$.pm_class))
  out <- spine
  for (class in classes) {
    out[[paste0(prefix, "_any_", class)]] <- 0L
    out[[paste0(prefix, "_days_", class)]] <- 0L
    out[[paste0(prefix, "_fills_", class)]] <- 0L
  }

  for (i in seq_len(nrow(out))) {
    keep <- fills$enrollee_id == out$enrollee_id[[i]] &
      fills$.pm_fill_date <= out$month_end[[i]] &
      fills$.pm_fill_end >= out$month_start[[i]]
    if (.pm_has_episode_col(fills)) {
      keep <- keep & fills$episode_id == out$episode_id[[i]]
    }
    if (!any(keep)) {
      next
    }

    rows <- fills[keep, , drop = FALSE]
    for (class in unique(rows$.pm_class)) {
      class_rows <- rows[rows$.pm_class == class, , drop = FALSE]
      covered_days <- .pm_covered_days(
        class_rows$.pm_fill_date,
        class_rows$.pm_fill_end,
        out$month_start[[i]],
        out$month_end[[i]]
      )
      fill_starts <- class_rows$.pm_fill_date >= out$month_start[[i]] &
        class_rows$.pm_fill_date <= out$month_end[[i]]

      out[[paste0(prefix, "_any_", class)]][[i]] <- as.integer(covered_days > 0L)
      out[[paste0(prefix, "_days_", class)]][[i]] <- covered_days
      out[[paste0(prefix, "_fills_", class)]][[i]] <- sum(fill_starts, na.rm = TRUE)
    }
  }

  .pm_assert_unique_keys(out)
  out
}

add_monthly_financials <- function(
  spine,
  financials = NULL,
  date_col = "service_date",
  class_col = NULL,
  amount_cols = NULL,
  prefix = "monthly"
) {
  .pm_required_cols(spine, c(.pm_key_cols(), "month_start", "month_end"), "spine")
  prepared <- .pm_prepare_financials(financials, date_col, class_col, amount_cols)

  out <- spine
  totals <- c("patient_oop", "pay", "netpay")
  for (total in totals) {
    out[[paste0(prefix, "_", total)]] <- 0
  }

  if (is.null(prepared)) {
    return(out)
  }

  classes <- sort(unique(prepared$.pm_class[!is.na(prepared$.pm_class)]))
  for (class in classes) {
    for (total in totals) {
      out[[paste0(prefix, "_", total, "_", class)]] <- 0
    }
  }

  for (i in seq_len(nrow(out))) {
    keep <- prepared$enrollee_id == out$enrollee_id[[i]] &
      prepared$.pm_service_date >= out$month_start[[i]] &
      prepared$.pm_service_date <= out$month_end[[i]]
    if (.pm_has_episode_col(prepared)) {
      keep <- keep & prepared$episode_id == out$episode_id[[i]]
    }
    if (!any(keep)) {
      next
    }

    rows <- prepared[keep, , drop = FALSE]
    out[[paste0(prefix, "_patient_oop")]][[i]] <- sum(rows$.pm_patient_oop, na.rm = TRUE)
    out[[paste0(prefix, "_pay")]][[i]] <- sum(rows$.pm_pay, na.rm = TRUE)
    out[[paste0(prefix, "_netpay")]][[i]] <- sum(rows$.pm_netpay, na.rm = TRUE)

    if (length(classes) > 0L) {
      for (class in unique(rows$.pm_class[!is.na(rows$.pm_class)])) {
        class_rows <- rows[rows$.pm_class == class, , drop = FALSE]
        out[[paste0(prefix, "_patient_oop_", class)]][[i]] <-
          sum(class_rows$.pm_patient_oop, na.rm = TRUE)
        out[[paste0(prefix, "_pay_", class)]][[i]] <-
          sum(class_rows$.pm_pay, na.rm = TRUE)
        out[[paste0(prefix, "_netpay_", class)]][[i]] <-
          sum(class_rows$.pm_netpay, na.rm = TRUE)
      }
    }
  }

  .pm_assert_unique_keys(out)
  out
}

add_monthly_medical_outcomes <- function(
  spine,
  medical_claims = NULL,
  date_col = "service_date",
  setting_col = NULL,
  condition_flag_cols = NULL,
  diagnosis_cols = NULL,
  diagnosis_prefixes = NULL
) {
  .pm_required_cols(spine, c(.pm_key_cols(), "month_start", "month_end"), "spine")
  claims <- .pm_prepare_claims(medical_claims, date_col)

  out <- spine
  base_cols <- c(
    "monthly_medical_claims",
    "monthly_inpatient_admissions",
    "monthly_ed_visits",
    "monthly_outpatient_visits",
    "monthly_office_visits"
  )
  for (col in base_cols) {
    out[[col]] <- 0L
  }

  if (is.null(claims)) {
    return(out)
  }

  if (is.null(setting_col)) {
    setting_col <- .pm_find_col(claims, c("setting", "claim_type", "service_setting", "place_of_service"))
  }

  flag_map <- .pm_condition_flag_map(condition_flag_cols)
  for (condition in names(flag_map)) {
    out[[paste0("monthly_condition_", condition)]] <- 0L
  }

  if (!is.null(diagnosis_prefixes) && length(diagnosis_prefixes) > 0L) {
    if (is.null(diagnosis_cols)) {
      diagnosis_cols <- grep("^(dx|diagnosis)", names(claims), ignore.case = TRUE, value = TRUE)
    }
    for (condition in .pm_prefix_condition_names(diagnosis_prefixes)) {
      out[[paste0("monthly_condition_", condition)]] <- 0L
    }
  }

  dynamic_setting_cols <- character()
  if (!is.null(setting_col) && setting_col %in% names(claims)) {
    dynamic_setting_cols <- paste0("monthly_", sort(unique(.pm_sanitize_name(claims[[setting_col]]))), "_claims")
    for (col in dynamic_setting_cols) {
      out[[col]] <- 0L
    }
  }

  for (i in seq_len(nrow(out))) {
    keep <- claims$enrollee_id == out$enrollee_id[[i]] &
      claims$.pm_service_date >= out$month_start[[i]] &
      claims$.pm_service_date <= out$month_end[[i]]
    if (.pm_has_episode_col(claims)) {
      keep <- keep & claims$episode_id == out$episode_id[[i]]
    }
    if (!any(keep)) {
      next
    }

    rows <- claims[keep, , drop = FALSE]
    out$monthly_medical_claims[[i]] <- nrow(rows)

    if (!is.null(setting_col) && setting_col %in% names(rows)) {
      settings <- .pm_sanitize_name(rows[[setting_col]])
      out$monthly_inpatient_admissions[[i]] <- sum(grepl("inpatient|admission|acute_ip", settings))
      out$monthly_ed_visits[[i]] <- sum(grepl("(^|_)ed($|_)|emergency|er", settings))
      out$monthly_outpatient_visits[[i]] <- sum(grepl("outpatient|ambulatory", settings))
      out$monthly_office_visits[[i]] <- sum(grepl("office", settings))

      for (setting in unique(settings)) {
        col <- paste0("monthly_", setting, "_claims")
        out[[col]][[i]] <- sum(settings == setting)
      }
    }

    standard_flags <- list(
      inpatient_admissions = c("inpatient_admission", "is_inpatient", "inpatient"),
      ed_visits = c("ed_visit", "is_ed", "emergency_visit"),
      outpatient_visits = c("outpatient_visit", "is_outpatient"),
      office_visits = c("office_visit", "is_office")
    )
    for (nm in names(standard_flags)) {
      col <- .pm_find_col(rows, standard_flags[[nm]])
      if (!is.null(col)) {
        out[[paste0("monthly_", nm)]][[i]] <- sum(.pm_numeric(rows[[col]]) > 0, na.rm = TRUE)
      }
    }

    for (condition in names(flag_map)) {
      col <- flag_map[[condition]]
      if (col %in% names(rows)) {
        out[[paste0("monthly_condition_", condition)]][[i]] <-
          as.integer(any(.pm_numeric(rows[[col]]) > 0, na.rm = TRUE))
      }
    }

    if (!is.null(diagnosis_prefixes) && length(diagnosis_prefixes) > 0L) {
      condition_names <- .pm_prefix_condition_names(diagnosis_prefixes)
      for (j in seq_along(diagnosis_prefixes)) {
        matched <- .pm_claim_matches_prefix(rows, diagnosis_cols, diagnosis_prefixes[[j]])
        out[[paste0("monthly_condition_", condition_names[[j]])]][[i]] <-
          as.integer(any(matched))
      }
    }
  }

  .pm_assert_unique_keys(out)
  out
}

add_baseline_covariates <- function(
  spine,
  enrollment = NULL,
  drug_fills = NULL,
  financials = NULL,
  medical_claims = NULL,
  lookback_months = 12L,
  enrollment_vars = c("age", "sex", "region", "plan_type", "rx_benefit", "medical_benefit"),
  enrollment_date_col = NULL,
  enroll_start_col = "enroll_start",
  enroll_end_col = "enroll_end",
  drug_date_col = "fill_date",
  drug_class_col = "drug_class",
  drug_days_supply_col = "days_supply",
  financial_date_col = "service_date",
  financial_class_col = NULL,
  medical_date_col = "service_date",
  medical_setting_col = NULL,
  condition_flag_cols = NULL,
  diagnosis_cols = NULL,
  diagnosis_prefixes = NULL,
  amount_cols = NULL
) {
  .pm_required_cols(spine, c("enrollee_id", "episode_id", "index_month_start"), "spine")

  episodes <- spine[!duplicated(spine[.pm_episode_cols()]), c(
    "enrollee_id", "episode_id", "index_date", "index_month_start"
  ), drop = FALSE]
  episodes$baseline_start <- .pm_add_months(episodes$index_month_start, -as.integer(lookback_months))
  episodes$baseline_end <- episodes$index_month_start - 1L

  features <- episodes[c("enrollee_id", "episode_id")]
  features$baseline_start <- episodes$baseline_start
  features$baseline_end <- episodes$baseline_end
  features$baseline_medical_claims <- 0L
  features$baseline_inpatient_admissions <- 0L
  features$baseline_ed_visits <- 0L
  features$baseline_outpatient_visits <- 0L
  features$baseline_office_visits <- 0L
  features$baseline_patient_oop <- 0
  features$baseline_pay <- 0
  features$baseline_netpay <- 0

  fills <- .pm_prepare_drug_fills(drug_fills, drug_date_col, drug_class_col, drug_days_supply_col)
  if (!is.null(fills)) {
    for (class in sort(unique(fills$.pm_class))) {
      features[[paste0("baseline_any_", class)]] <- 0L
      features[[paste0("baseline_days_", class)]] <- 0L
      features[[paste0("baseline_fills_", class)]] <- 0L
    }
  }

  prepared_financials <- .pm_prepare_financials(financials, financial_date_col, financial_class_col, amount_cols)
  if (!is.null(prepared_financials)) {
    for (class in sort(unique(prepared_financials$.pm_class[!is.na(prepared_financials$.pm_class)]))) {
      features[[paste0("baseline_patient_oop_", class)]] <- 0
      features[[paste0("baseline_pay_", class)]] <- 0
      features[[paste0("baseline_netpay_", class)]] <- 0
    }
  }

  claims <- .pm_prepare_claims(medical_claims, medical_date_col)
  if (!is.null(claims) && is.null(medical_setting_col)) {
    medical_setting_col <- .pm_find_col(claims, c("setting", "claim_type", "service_setting", "place_of_service"))
  }

  flag_map <- .pm_condition_flag_map(condition_flag_cols)
  for (condition in names(flag_map)) {
    features[[paste0("baseline_condition_", condition)]] <- 0L
  }
  if (!is.null(diagnosis_prefixes) && length(diagnosis_prefixes) > 0L) {
    if (!is.null(claims) && is.null(diagnosis_cols)) {
      diagnosis_cols <- grep("^(dx|diagnosis)", names(claims), ignore.case = TRUE, value = TRUE)
    }
    for (condition in .pm_prefix_condition_names(diagnosis_prefixes)) {
      features[[paste0("baseline_condition_", condition)]] <- 0L
    }
  }

  for (i in seq_len(nrow(episodes))) {
    enrollee_id <- episodes$enrollee_id[[i]]
    episode_id <- episodes$episode_id[[i]]
    start_date <- episodes$baseline_start[[i]]
    end_date <- episodes$baseline_end[[i]]

    if (!is.null(enrollment) && nrow(enrollment) > 0L) {
      .pm_required_cols(enrollment, "enrollee_id", "enrollment")
      enrollment_rows <- enrollment[enrollment$enrollee_id == enrollee_id, , drop = FALSE]
      if (.pm_has_episode_col(enrollment_rows)) {
        enrollment_rows <- enrollment_rows[enrollment_rows$episode_id == episode_id, , drop = FALSE]
      }
      if (nrow(enrollment_rows) > 0L) {
        selected <- seq_len(nrow(enrollment_rows))
        if (!is.null(enrollment_date_col) && enrollment_date_col %in% names(enrollment_rows)) {
          dates <- .pm_as_date(enrollment_rows[[enrollment_date_col]], enrollment_date_col)
          valid <- which(dates <= end_date)
          if (length(valid) > 0L) {
            selected <- valid[which.max(dates[valid])]
          }
        } else if (all(c(enroll_start_col, enroll_end_col) %in% names(enrollment_rows))) {
          starts <- .pm_as_date(enrollment_rows[[enroll_start_col]], enroll_start_col)
          ends <- .pm_as_date(enrollment_rows[[enroll_end_col]], enroll_end_col)
          valid <- which(starts <= end_date & ends >= start_date)
          if (length(valid) > 0L) {
            selected <- valid[which.max(starts[valid])]
          }
        } else {
          selected <- 1L
        }
        selected_row <- enrollment_rows[selected[[1L]], , drop = FALSE]
        for (var in enrollment_vars[enrollment_vars %in% names(selected_row)]) {
          feature_col <- paste0("baseline_", .pm_sanitize_name(var))
          if (!feature_col %in% names(features)) {
            features[[feature_col]] <- rep(NA, nrow(features))
          }
          features[[feature_col]][[i]] <- selected_row[[var]][[1L]]
        }
      }
    }

    if (!is.null(fills)) {
      keep <- fills$enrollee_id == enrollee_id &
        fills$.pm_fill_date <= end_date &
        fills$.pm_fill_end >= start_date
      if (.pm_has_episode_col(fills)) {
        keep <- keep & fills$episode_id == episode_id
      }
      if (any(keep)) {
        rows <- fills[keep, , drop = FALSE]
        for (class in unique(rows$.pm_class)) {
          class_rows <- rows[rows$.pm_class == class, , drop = FALSE]
          features[[paste0("baseline_any_", class)]][[i]] <- 1L
          features[[paste0("baseline_days_", class)]][[i]] <- .pm_covered_days(
            class_rows$.pm_fill_date,
            class_rows$.pm_fill_end,
            start_date,
            end_date
          )
          fill_starts <- class_rows$.pm_fill_date >= start_date & class_rows$.pm_fill_date <= end_date
          features[[paste0("baseline_fills_", class)]][[i]] <- sum(fill_starts, na.rm = TRUE)
        }
      }
    }

    if (!is.null(prepared_financials)) {
      keep <- prepared_financials$enrollee_id == enrollee_id &
        prepared_financials$.pm_service_date >= start_date &
        prepared_financials$.pm_service_date <= end_date
      if (.pm_has_episode_col(prepared_financials)) {
        keep <- keep & prepared_financials$episode_id == episode_id
      }
      if (any(keep)) {
        rows <- prepared_financials[keep, , drop = FALSE]
        features$baseline_patient_oop[[i]] <- sum(rows$.pm_patient_oop, na.rm = TRUE)
        features$baseline_pay[[i]] <- sum(rows$.pm_pay, na.rm = TRUE)
        features$baseline_netpay[[i]] <- sum(rows$.pm_netpay, na.rm = TRUE)
        for (class in unique(rows$.pm_class[!is.na(rows$.pm_class)])) {
          class_rows <- rows[rows$.pm_class == class, , drop = FALSE]
          features[[paste0("baseline_patient_oop_", class)]][[i]] <-
            sum(class_rows$.pm_patient_oop, na.rm = TRUE)
          features[[paste0("baseline_pay_", class)]][[i]] <-
            sum(class_rows$.pm_pay, na.rm = TRUE)
          features[[paste0("baseline_netpay_", class)]][[i]] <-
            sum(class_rows$.pm_netpay, na.rm = TRUE)
        }
      }
    }

    if (!is.null(claims)) {
      keep <- claims$enrollee_id == enrollee_id &
        claims$.pm_service_date >= start_date &
        claims$.pm_service_date <= end_date
      if (.pm_has_episode_col(claims)) {
        keep <- keep & claims$episode_id == episode_id
      }
      if (any(keep)) {
        rows <- claims[keep, , drop = FALSE]
        features$baseline_medical_claims[[i]] <- nrow(rows)

        if (!is.null(medical_setting_col) && medical_setting_col %in% names(rows)) {
          settings <- .pm_sanitize_name(rows[[medical_setting_col]])
          features$baseline_inpatient_admissions[[i]] <- sum(grepl("inpatient|admission|acute_ip", settings))
          features$baseline_ed_visits[[i]] <- sum(grepl("(^|_)ed($|_)|emergency|er", settings))
          features$baseline_outpatient_visits[[i]] <- sum(grepl("outpatient|ambulatory", settings))
          features$baseline_office_visits[[i]] <- sum(grepl("office", settings))
        }

        standard_flags <- list(
          inpatient_admissions = c("inpatient_admission", "is_inpatient", "inpatient"),
          ed_visits = c("ed_visit", "is_ed", "emergency_visit"),
          outpatient_visits = c("outpatient_visit", "is_outpatient"),
          office_visits = c("office_visit", "is_office")
        )
        for (nm in names(standard_flags)) {
          col <- .pm_find_col(rows, standard_flags[[nm]])
          if (!is.null(col)) {
            features[[paste0("baseline_", nm)]][[i]] <- sum(.pm_numeric(rows[[col]]) > 0, na.rm = TRUE)
          }
        }

        for (condition in names(flag_map)) {
          col <- flag_map[[condition]]
          if (col %in% names(rows)) {
            features[[paste0("baseline_condition_", condition)]][[i]] <-
              as.integer(any(.pm_numeric(rows[[col]]) > 0, na.rm = TRUE))
          }
        }

        if (!is.null(diagnosis_prefixes) && length(diagnosis_prefixes) > 0L) {
          condition_names <- .pm_prefix_condition_names(diagnosis_prefixes)
          for (j in seq_along(diagnosis_prefixes)) {
            matched <- .pm_claim_matches_prefix(rows, diagnosis_cols, diagnosis_prefixes[[j]])
            features[[paste0("baseline_condition_", condition_names[[j]])]][[i]] <-
              as.integer(any(matched))
          }
        }
      }
    }
  }

  .pm_bind_episode_features(spine, features)
}

assemble_person_month_table <- function(
  index_table,
  drug_fills = NULL,
  enrollment = NULL,
  financials = NULL,
  medical_claims = NULL,
  event_month_min = -12L,
  event_month_max = 12L,
  index_date_col = "index_date",
  drug_date_col = "fill_date",
  drug_class_col = "drug_class",
  drug_days_supply_col = "days_supply",
  financial_date_col = "service_date",
  financial_class_col = NULL,
  medical_date_col = "service_date",
  medical_setting_col = NULL,
  condition_flag_cols = NULL,
  diagnosis_cols = NULL,
  diagnosis_prefixes = NULL,
  amount_cols = NULL
) {
  out <- build_event_month_spine(
    index_table = index_table,
    event_month_min = event_month_min,
    event_month_max = event_month_max,
    index_date_col = index_date_col
  )

  out <- add_monthly_drug_states(
    spine = out,
    drug_fills = drug_fills,
    date_col = drug_date_col,
    class_col = drug_class_col,
    days_supply_col = drug_days_supply_col
  )

  out <- add_monthly_financials(
    spine = out,
    financials = financials,
    date_col = financial_date_col,
    class_col = financial_class_col,
    amount_cols = amount_cols
  )

  out <- add_monthly_medical_outcomes(
    spine = out,
    medical_claims = medical_claims,
    date_col = medical_date_col,
    setting_col = medical_setting_col,
    condition_flag_cols = condition_flag_cols,
    diagnosis_cols = diagnosis_cols,
    diagnosis_prefixes = diagnosis_prefixes
  )

  out <- add_baseline_covariates(
    spine = out,
    enrollment = enrollment,
    drug_fills = drug_fills,
    financials = financials,
    medical_claims = medical_claims,
    enrollment_date_col = NULL,
    drug_date_col = drug_date_col,
    drug_class_col = drug_class_col,
    drug_days_supply_col = drug_days_supply_col,
    financial_date_col = financial_date_col,
    financial_class_col = financial_class_col,
    medical_date_col = medical_date_col,
    medical_setting_col = medical_setting_col,
    condition_flag_cols = condition_flag_cols,
    diagnosis_cols = diagnosis_cols,
    diagnosis_prefixes = diagnosis_prefixes,
    amount_cols = amount_cols
  )

  out <- out[order(out$enrollee_id, out$episode_id, out$event_month), , drop = FALSE]
  rownames(out) <- NULL
  .pm_assert_unique_keys(out)
  out
}
