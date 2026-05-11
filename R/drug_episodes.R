# Pure-R helpers for DPP-4 to GLP-1 switch classification.
#
# These functions operate on already standardized, in-memory pharmacy data with
# columns: enrollee_id, fill_date, ndc11, days_supply, drug_class.

normalize_ndc11 <- function(x, invalid_to_na = TRUE) {
  if (is.factor(x)) {
    x <- as.character(x)
  }

  if (is.numeric(x)) {
    y <- rep(NA_character_, length(x))
    keep <- !is.na(x)
    y[keep] <- format(x[keep], scientific = FALSE, trim = TRUE)
  } else {
    y <- as.character(x)
  }

  y <- trimws(y)
  y[y == "" | toupper(y) %in% c("NA", "NAN", "NULL")] <- NA_character_
  y <- sub("\\.0+$", "", y)

  hyphen_ndc11 <- rep(NA_character_, length(y))
  hyphenated <- which(!is.na(y) & grepl("-", y, fixed = TRUE))
  for (i in hyphenated) {
    parts <- strsplit(y[i], "-", fixed = TRUE)[[1L]]
    if (length(parts) == 3L && all(grepl("^\\d+$", parts))) {
      lens <- nchar(parts)
      if (identical(lens, c(4L, 4L, 2L))) {
        hyphen_ndc11[i] <- paste0("0", parts[1L], parts[2L], parts[3L])
      } else if (identical(lens, c(5L, 3L, 2L))) {
        hyphen_ndc11[i] <- paste0(parts[1L], "0", parts[2L], parts[3L])
      } else if (identical(lens, c(5L, 4L, 1L))) {
        hyphen_ndc11[i] <- paste0(parts[1L], parts[2L], "0", parts[3L])
      }
    }
  }

  digits <- ifelse(!is.na(hyphen_ndc11), hyphen_ndc11, gsub("[^0-9]", "", y))
  digits[is.na(y) | digits == ""] <- NA_character_

  valid <- !is.na(digits) & nchar(digits) <= 11L
  out <- rep(NA_character_, length(digits))
  out[valid] <- paste0(
    strrep("0", 11L - nchar(digits[valid])),
    digits[valid]
  )

  if (!invalid_to_na) {
    out[!valid] <- digits[!valid]
  }

  out
}

parse_claim_date <- function(x, origin = "1960-01-01") {
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

  slash <- !is.na(y) & is.na(out) & grepl("^\\d{1,2}/\\d{1,2}/\\d{4}$", y)
  out[slash] <- as.Date(y[slash], format = "%m/%d/%Y")

  sas_days <- !is.na(y) & is.na(out) & grepl("^\\d+$", y)
  out[sas_days] <- as.Date(as.integer(y[sas_days]), origin = origin)

  remaining <- !is.na(y) & is.na(out)
  if (any(remaining)) {
    parsed <- suppressWarnings(as.Date(y[remaining]))
    out[remaining] <- parsed
  }

  out
}

canonical_drug_class <- function(x) {
  y <- tolower(trimws(as.character(x)))
  y[y == "" | toupper(y) %in% c("NA", "NAN", "NULL")] <- NA_character_
  compact <- gsub("[^a-z0-9]", "", y)

  out <- y
  dpp4 <- !is.na(compact) & grepl(
    "dpp4|sitagliptin|saxagliptin|linagliptin|alogliptin",
    compact
  )
  glp1 <- !is.na(compact) & grepl(
    "glp1|semaglutide|liraglutide|dulaglutide|exenatide|lixisenatide|tirzepatide|albiglutide",
    compact
  )

  out[dpp4] <- "dpp4"
  out[glp1] <- "glp1"
  out
}

standardize_rx_claims <- function(rx_claims,
                                  enrollee_id_col = "enrollee_id",
                                  fill_date_col = "fill_date",
                                  ndc11_col = "ndc11",
                                  days_supply_col = "days_supply",
                                  drug_class_col = "drug_class",
                                  date_origin = "1960-01-01",
                                  drop_invalid = TRUE) {
  required <- c(
    enrollee_id_col,
    fill_date_col,
    ndc11_col,
    days_supply_col,
    drug_class_col
  )
  missing_cols <- setdiff(required, names(rx_claims))
  if (length(missing_cols) > 0L) {
    stop(
      "rx_claims is missing required columns: ",
      paste(missing_cols, collapse = ", "),
      call. = FALSE
    )
  }

  out <- data.frame(
    enrollee_id = as.character(rx_claims[[enrollee_id_col]]),
    fill_date = parse_claim_date(rx_claims[[fill_date_col]], origin = date_origin),
    ndc11 = normalize_ndc11(rx_claims[[ndc11_col]]),
    days_supply = suppressWarnings(as.integer(as.numeric(rx_claims[[days_supply_col]]))),
    drug_class = canonical_drug_class(rx_claims[[drug_class_col]]),
    stringsAsFactors = FALSE
  )

  if (drop_invalid) {
    valid <- !is.na(out$enrollee_id) &
      out$enrollee_id != "" &
      !is.na(out$fill_date) &
      !is.na(out$ndc11) &
      !is.na(out$days_supply) &
      out$days_supply > 0L &
      !is.na(out$drug_class) &
      out$drug_class != ""
    out <- out[valid, , drop = FALSE]
  }

  if (nrow(out) > 0L) {
    out <- out[order(out$enrollee_id, out$drug_class, out$fill_date, out$ndc11), ]
  }
  rownames(out) <- NULL
  out
}

empty_episode_frame <- function() {
  data.frame(
    enrollee_id = character(),
    drug_class = character(),
    episode_id = integer(),
    episode_start = as.Date(character()),
    episode_end = as.Date(character()),
    first_fill_date = as.Date(character()),
    last_fill_date = as.Date(character()),
    n_fills = integer(),
    total_days_supply = integer(),
    stringsAsFactors = FALSE
  )
}

construct_drug_episodes <- function(rx_claims,
                                    episode_gap_days = 0L,
                                    date_origin = "1960-01-01") {
  episode_gap_days <- as.integer(episode_gap_days)
  if (is.na(episode_gap_days) || episode_gap_days < 0L) {
    stop("episode_gap_days must be a non-negative integer.", call. = FALSE)
  }

  rx <- standardize_rx_claims(rx_claims, date_origin = date_origin)
  if (nrow(rx) == 0L) {
    return(empty_episode_frame())
  }

  groups <- split(rx, list(rx$enrollee_id, rx$drug_class), drop = TRUE)
  pieces <- lapply(groups, function(g) {
    g <- g[order(g$fill_date, g$ndc11), , drop = FALSE]
    enrollee_id <- g$enrollee_id[1L]
    drug_class <- g$drug_class[1L]

    rows <- list()
    episode_id <- 1L
    episode_start <- g$fill_date[1L]
    first_fill_date <- g$fill_date[1L]
    last_fill_date <- g$fill_date[1L]
    coverage_end <- g$fill_date[1L] + g$days_supply[1L] - 1L
    n_fills <- 1L
    total_days_supply <- g$days_supply[1L]

    flush_episode <- function() {
      data.frame(
        enrollee_id = enrollee_id,
        drug_class = drug_class,
        episode_id = episode_id,
        episode_start = episode_start,
        episode_end = coverage_end,
        first_fill_date = first_fill_date,
        last_fill_date = last_fill_date,
        n_fills = n_fills,
        total_days_supply = total_days_supply,
        stringsAsFactors = FALSE
      )
    }

    if (nrow(g) > 1L) {
      for (i in 2L:nrow(g)) {
        fill_date <- g$fill_date[i]
        days_supply <- g$days_supply[i]
        gap_days <- as.integer(fill_date - coverage_end - 1L)

        if (gap_days <= episode_gap_days) {
          if (fill_date <= coverage_end + 1L) {
            coverage_end <- coverage_end + days_supply
          } else {
            coverage_end <- fill_date + days_supply - 1L
          }
          last_fill_date <- fill_date
          n_fills <- n_fills + 1L
          total_days_supply <- total_days_supply + days_supply
        } else {
          rows[[length(rows) + 1L]] <- flush_episode()
          episode_id <- episode_id + 1L
          episode_start <- fill_date
          first_fill_date <- fill_date
          last_fill_date <- fill_date
          coverage_end <- fill_date + days_supply - 1L
          n_fills <- 1L
          total_days_supply <- days_supply
        }
      }
    }

    rows[[length(rows) + 1L]] <- flush_episode()
    do.call(rbind, rows)
  })

  out <- do.call(rbind, pieces)
  out <- out[order(out$enrollee_id, out$drug_class, out$episode_start), ]
  rownames(out) <- NULL
  out
}

empty_index_frame <- function() {
  data.frame(
    enrollee_id = character(),
    index_date = as.Date(character()),
    index_ndc11 = character(),
    index_days_supply = integer(),
    prior_glp1_fill_date = as.Date(character()),
    days_since_prior_glp1 = integer(),
    glp1_washout_pass = logical(),
    stringsAsFactors = FALSE
  )
}

identify_glp1_index <- function(rx_claims,
                                glp1_washout_days = 365L,
                                index_start = NULL,
                                index_end = NULL,
                                require_washout = FALSE,
                                date_origin = "1960-01-01") {
  glp1_washout_days <- as.integer(glp1_washout_days)
  if (is.na(glp1_washout_days) || glp1_washout_days < 0L) {
    stop("glp1_washout_days must be a non-negative integer.", call. = FALSE)
  }

  rx <- standardize_rx_claims(rx_claims, date_origin = date_origin)
  glp1_rx <- rx[rx$drug_class == "glp1", , drop = FALSE]
  if (nrow(glp1_rx) == 0L) {
    return(empty_index_frame())
  }

  if (!is.null(index_start)) {
    index_start <- parse_claim_date(index_start, origin = date_origin)
    glp1_rx <- glp1_rx[glp1_rx$fill_date >= index_start, , drop = FALSE]
  }
  if (!is.null(index_end)) {
    index_end <- parse_claim_date(index_end, origin = date_origin)
    glp1_rx <- glp1_rx[glp1_rx$fill_date <= index_end, , drop = FALSE]
  }
  if (nrow(glp1_rx) == 0L) {
    return(empty_index_frame())
  }

  all_glp1 <- rx[rx$drug_class == "glp1", , drop = FALSE]
  ids <- sort(unique(glp1_rx$enrollee_id))
  rows <- vector("list", length(ids))

  for (i in seq_along(ids)) {
    id <- ids[i]
    candidates <- glp1_rx[glp1_rx$enrollee_id == id, , drop = FALSE]
    candidates <- candidates[order(candidates$fill_date, candidates$ndc11), , drop = FALSE]
    all_dates <- sort(all_glp1$fill_date[all_glp1$enrollee_id == id])

    chosen <- NULL
    chosen_prior <- as.Date(NA)
    chosen_days_since_prior <- NA_integer_
    chosen_pass <- NA

    for (j in seq_len(nrow(candidates))) {
      candidate_date <- candidates$fill_date[j]
      prior_dates <- all_dates[all_dates < candidate_date]
      prior_date <- if (length(prior_dates) > 0L) max(prior_dates) else as.Date(NA)
      days_since_prior <- if (is.na(prior_date)) {
        NA_integer_
      } else {
        as.integer(candidate_date - prior_date)
      }
      washout_pass <- is.na(days_since_prior) || days_since_prior > glp1_washout_days

      if (!require_washout || washout_pass) {
        chosen <- candidates[j, , drop = FALSE]
        chosen_prior <- prior_date
        chosen_days_since_prior <- days_since_prior
        chosen_pass <- washout_pass
        break
      }
    }

    if (!is.null(chosen)) {
      rows[[i]] <- data.frame(
        enrollee_id = id,
        index_date = chosen$fill_date,
        index_ndc11 = chosen$ndc11,
        index_days_supply = chosen$days_supply,
        prior_glp1_fill_date = chosen_prior,
        days_since_prior_glp1 = chosen_days_since_prior,
        glp1_washout_pass = chosen_pass,
        stringsAsFactors = FALSE
      )
    }
  }

  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0L) {
    return(empty_index_frame())
  }

  out <- do.call(rbind, rows)
  out <- out[order(out$enrollee_id, out$index_date), ]
  rownames(out) <- NULL
  out
}

enumerate_glp1_candidates <- function(rx_claims,
                                      glp1_washout_days = 365L,
                                      index_start = NULL,
                                      index_end = NULL,
                                      date_origin = "1960-01-01") {
  rx <- standardize_rx_claims(rx_claims, date_origin = date_origin)
  glp1_rx <- rx[rx$drug_class == "glp1", , drop = FALSE]
  if (nrow(glp1_rx) == 0L) {
    return(empty_index_frame())
  }

  if (!is.null(index_start)) {
    index_start <- parse_claim_date(index_start, origin = date_origin)
    glp1_rx <- glp1_rx[glp1_rx$fill_date >= index_start, , drop = FALSE]
  }
  if (!is.null(index_end)) {
    index_end <- parse_claim_date(index_end, origin = date_origin)
    glp1_rx <- glp1_rx[glp1_rx$fill_date <= index_end, , drop = FALSE]
  }
  if (nrow(glp1_rx) == 0L) {
    return(empty_index_frame())
  }

  all_glp1 <- rx[rx$drug_class == "glp1", , drop = FALSE]
  glp1_rx <- glp1_rx[order(glp1_rx$enrollee_id, glp1_rx$fill_date, glp1_rx$ndc11), ]
  rows <- vector("list", nrow(glp1_rx))

  for (i in seq_len(nrow(glp1_rx))) {
    candidate <- glp1_rx[i, , drop = FALSE]
    all_dates <- sort(all_glp1$fill_date[all_glp1$enrollee_id == candidate$enrollee_id])
    prior_dates <- all_dates[all_dates < candidate$fill_date]
    prior_date <- if (length(prior_dates) > 0L) max(prior_dates) else as.Date(NA)
    days_since_prior <- if (is.na(prior_date)) {
      NA_integer_
    } else {
      as.integer(candidate$fill_date - prior_date)
    }
    washout_pass <- is.na(days_since_prior) || days_since_prior > glp1_washout_days

    rows[[i]] <- data.frame(
      enrollee_id = candidate$enrollee_id,
      index_date = candidate$fill_date,
      index_ndc11 = candidate$ndc11,
      index_days_supply = candidate$days_supply,
      prior_glp1_fill_date = prior_date,
      days_since_prior_glp1 = days_since_prior,
      glp1_washout_pass = washout_pass,
      stringsAsFactors = FALSE
    )
  }

  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

empty_switch_frame <- function() {
  data.frame(
    enrollee_id = character(),
    index_date = as.Date(character()),
    index_ndc11 = character(),
    switch_class = character(),
    classification = character(),
    glp1_washout_pass = logical(),
    prior_glp1_fill_date = as.Date(character()),
    qualifying_dpp4_preindex = logical(),
    last_dpp4_fill_preindex = as.Date(character()),
    last_dpp4_coverage_end_preindex = as.Date(character()),
    dpp4_gap_days_before_index = integer(),
    dpp4_overlap_days_after_index = integer(),
    dpp4_postindex_fill_after_grace = logical(),
    dpp4_continues_after_transition = logical(),
    switch_back = logical(),
    glp1_episode_end = as.Date(character()),
    stringsAsFactors = FALSE
  )
}

max_date_or_na <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0L) {
    as.Date(NA)
  } else {
    max(x)
  }
}

classify_dpp4_to_glp1_switches <- function(rx_claims,
                                           glp1_washout_days = 365L,
                                           dpp4_preindex_lookback_days = 180L,
                                           preindex_grace_days = 60L,
                                           replacement_assessment_days = 120L,
                                           postindex_grace_days = 30L,
                                           transition_overlap_allowed_days = 30L,
                                           episode_gap_days = 0L,
                                           index_start = NULL,
                                           index_end = NULL,
                                           date_origin = "1960-01-01") {
  rx <- standardize_rx_claims(rx_claims, date_origin = date_origin)
  if (nrow(rx) == 0L) {
    return(empty_switch_frame())
  }

  candidates <- enumerate_glp1_candidates(
    rx,
    glp1_washout_days = glp1_washout_days,
    index_start = index_start,
    index_end = index_end,
    date_origin = date_origin
  )
  if (nrow(candidates) == 0L) {
    return(empty_switch_frame())
  }

  episodes <- construct_drug_episodes(
    rx,
    episode_gap_days = episode_gap_days,
    date_origin = date_origin
  )

  ids <- sort(unique(candidates$enrollee_id))
  indices <- vector("list", length(ids))
  for (i in seq_along(ids)) {
    id <- ids[i]
    id_candidates <- candidates[candidates$enrollee_id == id, , drop = FALSE]
    id_candidates <- id_candidates[order(id_candidates$index_date, id_candidates$index_ndc11), ]
    id_rx <- rx[rx$enrollee_id == id, , drop = FALSE]
    id_episodes <- episodes[episodes$enrollee_id == id, , drop = FALSE]
    dpp4_rx <- id_rx[id_rx$drug_class == "dpp4", , drop = FALSE]
    dpp4_episodes <- id_episodes[id_episodes$drug_class == "dpp4", , drop = FALSE]

    chosen <- id_candidates[1L, , drop = FALSE]
    for (j in seq_len(nrow(id_candidates))) {
      candidate_date <- id_candidates$index_date[j]
      lookback_start <- candidate_date - as.integer(dpp4_preindex_lookback_days)
      pre_window_rx <- dpp4_rx[
        dpp4_rx$fill_date >= lookback_start & dpp4_rx$fill_date < candidate_date,
        ,
        drop = FALSE
      ]
      pre_window_episodes <- dpp4_episodes[
        dpp4_episodes$episode_start < candidate_date &
          dpp4_episodes$episode_end >= lookback_start,
        ,
        drop = FALSE
      ]
      last_dpp4_coverage_end <- max_date_or_na(pre_window_episodes$episode_end)
      qualifying_preindex <- nrow(pre_window_rx) > 0L &&
        !is.na(last_dpp4_coverage_end) &&
        last_dpp4_coverage_end >= candidate_date - as.integer(preindex_grace_days)

      if (qualifying_preindex) {
        chosen <- id_candidates[j, , drop = FALSE]
        break
      }
    }
    indices[[i]] <- chosen
  }
  indices <- do.call(rbind, indices)

  rows <- vector("list", nrow(indices))
  for (i in seq_len(nrow(indices))) {
    idx <- indices[i, , drop = FALSE]
    id <- idx$enrollee_id
    index_date <- idx$index_date

    id_rx <- rx[rx$enrollee_id == id, , drop = FALSE]
    id_episodes <- episodes[episodes$enrollee_id == id, , drop = FALSE]
    dpp4_rx <- id_rx[id_rx$drug_class == "dpp4", , drop = FALSE]
    dpp4_episodes <- id_episodes[id_episodes$drug_class == "dpp4", , drop = FALSE]
    glp1_episodes <- id_episodes[id_episodes$drug_class == "glp1", , drop = FALSE]

    glp1_index_episode <- glp1_episodes[
      glp1_episodes$episode_start <= index_date &
        glp1_episodes$episode_end >= index_date,
      ,
      drop = FALSE
    ]
    glp1_episode_end <- if (nrow(glp1_index_episode) > 0L) {
      glp1_index_episode$episode_end[1L]
    } else {
      index_date + idx$index_days_supply - 1L
    }

    lookback_start <- index_date - as.integer(dpp4_preindex_lookback_days)
    pre_window_rx <- dpp4_rx[
      dpp4_rx$fill_date >= lookback_start & dpp4_rx$fill_date < index_date,
      ,
      drop = FALSE
    ]
    pre_window_episodes <- dpp4_episodes[
      dpp4_episodes$episode_start < index_date &
        dpp4_episodes$episode_end >= lookback_start,
      ,
      drop = FALSE
    ]

    last_dpp4_fill <- max_date_or_na(pre_window_rx$fill_date)
    last_dpp4_coverage_end <- max_date_or_na(pre_window_episodes$episode_end)
    qualifying_preindex <- nrow(pre_window_rx) > 0L &&
      !is.na(last_dpp4_coverage_end) &&
      last_dpp4_coverage_end >= index_date - as.integer(preindex_grace_days)
    dpp4_gap_days_before_index <- if (is.na(last_dpp4_coverage_end)) {
      NA_integer_
    } else {
      max(0L, as.integer(index_date - last_dpp4_coverage_end - 1L))
    }

    assessment_end <- index_date + as.integer(replacement_assessment_days)
    post_grace_end <- index_date + as.integer(postindex_grace_days)

    post_dpp4_rx <- dpp4_rx[
      dpp4_rx$fill_date >= index_date & dpp4_rx$fill_date <= assessment_end,
      ,
      drop = FALSE
    ]
    dpp4_after_grace <- dpp4_rx[
      dpp4_rx$fill_date > post_grace_end & dpp4_rx$fill_date <= assessment_end,
      ,
      drop = FALSE
    ]
    transition_episodes <- dpp4_episodes[
      dpp4_episodes$episode_start <= post_grace_end &
        dpp4_episodes$episode_end >= index_date,
      ,
      drop = FALSE
    ]
    max_transition_end <- max_date_or_na(transition_episodes$episode_end)
    dpp4_overlap_days <- if (is.na(max_transition_end)) {
      0L
    } else {
      max(0L, as.integer(max_transition_end - index_date + 1L))
    }

    postindex_fill_after_grace <- nrow(dpp4_after_grace) > 0L
    transition_overlap_excess <- dpp4_overlap_days >
      as.integer(transition_overlap_allowed_days)
    dpp4_continues_after_transition <- transition_overlap_excess ||
      postindex_fill_after_grace
    switch_back <- any(
      post_dpp4_rx$fill_date > glp1_episode_end + as.integer(postindex_grace_days)
    )

    switch_class <- if (!idx$glp1_washout_pass) {
      "prior_glp1_washout_failure"
    } else if (!qualifying_preindex) {
      "ambiguous_switch"
    } else if (dpp4_continues_after_transition) {
      "addon_or_overlap"
    } else {
      "clean_replacement"
    }

    rows[[i]] <- data.frame(
      enrollee_id = id,
      index_date = index_date,
      index_ndc11 = idx$index_ndc11,
      switch_class = switch_class,
      classification = switch_class,
      glp1_washout_pass = idx$glp1_washout_pass,
      prior_glp1_fill_date = idx$prior_glp1_fill_date,
      qualifying_dpp4_preindex = qualifying_preindex,
      last_dpp4_fill_preindex = last_dpp4_fill,
      last_dpp4_coverage_end_preindex = last_dpp4_coverage_end,
      dpp4_gap_days_before_index = dpp4_gap_days_before_index,
      dpp4_overlap_days_after_index = dpp4_overlap_days,
      dpp4_postindex_fill_after_grace = postindex_fill_after_grace,
      dpp4_continues_after_transition = dpp4_continues_after_transition,
      switch_back = switch_back,
      glp1_episode_end = glp1_episode_end,
      stringsAsFactors = FALSE
    )
  }

  out <- do.call(rbind, rows)
  out <- out[order(out$enrollee_id, out$index_date), ]
  rownames(out) <- NULL
  out
}
