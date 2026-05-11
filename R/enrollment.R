# Enrollment helpers for DPP-4 to GLP-1 cohort construction.
#
# These functions operate on standardized or MarketScan-like enrollment rows in
# memory. They do not read raw MarketScan files.

.enr_required_cols <- function(data, cols, data_name = "data") {
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

.enr_as_date <- function(x, origin = "1960-01-01") {
  if (inherits(x, "Date")) {
    return(x)
  }
  if (inherits(x, "POSIXt")) {
    return(as.Date(x))
  }
  if (is.numeric(x)) {
    out <- rep(as.Date(NA), length(x))
    keep <- !is.na(x)
    out[keep] <- as.Date(as.integer(x[keep]), origin = origin)
    return(out)
  }
  y <- trimws(as.character(x))
  y[y == "" | toupper(y) %in% c("NA", "NAN", "NULL")] <- NA_character_
  out <- rep(as.Date(NA), length(y))
  ymd <- !is.na(y) & grepl("^\\d{8}$", y)
  out[ymd] <- as.Date(y[ymd], format = "%Y%m%d")
  iso <- !is.na(y) & is.na(out) & grepl("^\\d{4}-\\d{2}-\\d{2}$", y)
  out[iso] <- as.Date(y[iso])
  numeric <- !is.na(y) & is.na(out) & grepl("^\\d+$", y)
  out[numeric] <- as.Date(as.integer(y[numeric]), origin = origin)
  remaining <- !is.na(y) & is.na(out)
  out[remaining] <- suppressWarnings(as.Date(y[remaining]))
  out
}

.enr_month_start <- function(date) {
  date <- .enr_as_date(date)
  as.Date(sprintf("%s-%s-01", format(date, "%Y"), format(date, "%m")))
}

.enr_month_id <- function(date) {
  date <- .enr_as_date(date)
  as.integer(format(date, "%Y")) * 12L + as.integer(format(date, "%m")) - 1L
}

.enr_month_from_id <- function(month_id) {
  year <- month_id %/% 12L
  month <- month_id %% 12L + 1L
  as.Date(sprintf("%04d-%02d-01", year, month))
}

.enr_add_months <- function(date, n) {
  .enr_month_from_id(.enr_month_id(.enr_month_start(date)) + as.integer(n))
}

.enr_month_end <- function(date) {
  .enr_add_months(date, 1L) - 1L
}

.enr_active <- function(x, active_values = c("1", 1L, TRUE)) {
  as.character(x) %in% as.character(active_values)
}

standardize_enrollment <- function(enrollment,
                                   enrollee_id_col = "ENROLID",
                                   start_col = "DTSTART",
                                   end_col = "DTEND",
                                   rx_col = "RX",
                                   medical_col = NULL,
                                   active_values = c("1", 1L, TRUE),
                                   date_origin = "1960-01-01") {
  required <- c(enrollee_id_col, start_col, end_col)
  if (!is.null(rx_col)) {
    required <- c(required, rx_col)
  }
  if (!is.null(medical_col)) {
    required <- c(required, medical_col)
  }
  .enr_required_cols(enrollment, required, "enrollment")

  out <- data.frame(
    enrollee_id = as.character(enrollment[[enrollee_id_col]]),
    enroll_start = .enr_as_date(enrollment[[start_col]], origin = date_origin),
    enroll_end = .enr_as_date(enrollment[[end_col]], origin = date_origin),
    rx_active = if (is.null(rx_col)) TRUE else .enr_active(enrollment[[rx_col]], active_values),
    medical_active = if (is.null(medical_col)) TRUE else .enr_active(enrollment[[medical_col]], active_values),
    stringsAsFactors = FALSE
  )

  keep <- !is.na(out$enrollee_id) &
    out$enrollee_id != "" &
    !is.na(out$enroll_start) &
    !is.na(out$enroll_end) &
    out$enroll_start <= out$enroll_end
  out <- out[keep, , drop = FALSE]
  out <- out[order(out$enrollee_id, out$enroll_start, out$enroll_end), , drop = FALSE]
  rownames(out) <- NULL
  out
}

merge_enrollment_spans <- function(enrollment,
                                   require_rx = TRUE,
                                   require_medical = TRUE,
                                   max_gap_days = 1L) {
  if (nrow(enrollment) == 0L) {
    return(data.frame(
      enrollee_id = character(),
      spell_start = as.Date(character()),
      spell_end = as.Date(character()),
      stringsAsFactors = FALSE
    ))
  }

  .enr_required_cols(
    enrollment,
    c("enrollee_id", "enroll_start", "enroll_end", "rx_active", "medical_active"),
    "enrollment"
  )

  keep <- rep(TRUE, nrow(enrollment))
  if (isTRUE(require_rx)) {
    keep <- keep & enrollment$rx_active
  }
  if (isTRUE(require_medical)) {
    keep <- keep & enrollment$medical_active
  }

  enrollment <- enrollment[keep, , drop = FALSE]
  if (nrow(enrollment) == 0L) {
    return(data.frame(
      enrollee_id = character(),
      spell_start = as.Date(character()),
      spell_end = as.Date(character()),
      stringsAsFactors = FALSE
    ))
  }

  pieces <- lapply(split(enrollment, enrollment$enrollee_id), function(g) {
    g <- g[order(g$enroll_start, g$enroll_end), , drop = FALSE]
    rows <- list()
    spell_start <- g$enroll_start[1L]
    spell_end <- g$enroll_end[1L]
    for (i in seq_len(nrow(g))[-1L]) {
      if (g$enroll_start[i] <= spell_end + as.integer(max_gap_days)) {
        if (g$enroll_end[i] > spell_end) {
          spell_end <- g$enroll_end[i]
        }
      } else {
        rows[[length(rows) + 1L]] <- data.frame(
          enrollee_id = g$enrollee_id[1L],
          spell_start = spell_start,
          spell_end = spell_end,
          stringsAsFactors = FALSE
        )
        spell_start <- g$enroll_start[i]
        spell_end <- g$enroll_end[i]
      }
    }
    rows[[length(rows) + 1L]] <- data.frame(
      enrollee_id = g$enrollee_id[1L],
      spell_start = spell_start,
      spell_end = spell_end,
      stringsAsFactors = FALSE
    )
    do.call(rbind, rows)
  })

  out <- do.call(rbind, pieces)
  out <- out[order(out$enrollee_id, out$spell_start, out$spell_end), , drop = FALSE]
  rownames(out) <- NULL
  out
}

check_continuous_enrollment <- function(index_table,
                                        enrollment,
                                        baseline_months = 12L,
                                        followup_months = 12L,
                                        require_rx = TRUE,
                                        require_medical = TRUE,
                                        max_gap_days = 1L) {
  .enr_required_cols(index_table, c("enrollee_id", "index_date"), "index_table")
  .enr_required_cols(enrollment, c("enrollee_id", "enroll_start", "enroll_end", "rx_active", "medical_active"), "enrollment")

  spells <- merge_enrollment_spans(
    enrollment,
    require_rx = require_rx,
    require_medical = require_medical,
    max_gap_days = max_gap_days
  )

  rows <- vector("list", nrow(index_table))
  for (i in seq_len(nrow(index_table))) {
    idx <- index_table[i, , drop = FALSE]
    index_month <- .enr_month_start(idx$index_date)
    required_start <- .enr_add_months(index_month, -as.integer(baseline_months))
    required_end <- .enr_month_end(.enr_add_months(index_month, as.integer(followup_months)))
    id_spells <- spells[spells$enrollee_id == idx$enrollee_id, , drop = FALSE]
    matched <- id_spells[
      id_spells$spell_start <= required_start &
        id_spells$spell_end >= required_end,
      ,
      drop = FALSE
    ]

    rows[[i]] <- data.frame(
      enrollee_id = idx$enrollee_id,
      required_enrollment_start = required_start,
      required_enrollment_end = required_end,
      continuous_enrollment = nrow(matched) > 0L,
      enrollment_spell_start = if (nrow(matched) > 0L) matched$spell_start[1L] else as.Date(NA),
      enrollment_spell_end = if (nrow(matched) > 0L) matched$spell_end[1L] else as.Date(NA),
      stringsAsFactors = FALSE
    )
  }

  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}
