# Aggregate-only plotting helpers for Stage 08.
# These functions read only known aggregate CSV outputs from a figures/data directory.

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

stage08_required_ggplot2 <- function() {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop(
      "Package 'ggplot2' is required to make Stage 08 figures. ",
      "Install or load ggplot2 in the R environment before running this script.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

stage08_compact_name <- function(x) {
  gsub("[^a-z0-9]", "", tolower(as.character(x)))
}

stage08_find_column <- function(df, candidates) {
  cols <- names(df)
  idx <- match(stage08_compact_name(candidates), stage08_compact_name(cols))
  idx <- idx[!is.na(idx)]
  if (length(idx) == 0L) {
    return(NULL)
  }
  cols[[idx[[1L]]]]
}

stage08_numeric <- function(x) {
  suppressWarnings(as.numeric(as.character(x)))
}

stage08_title_case <- function(x) {
  x <- gsub("_+", " ", as.character(x))
  x <- gsub("\\s+", " ", trimws(x))
  ifelse(nzchar(x), tools::toTitleCase(x), x)
}

stage08_is_percent_scale <- function(x) {
  x <- x[!is.na(x)]
  length(x) > 0L && max(abs(x)) <= 1.1
}

stage08_percent_values <- function(x) {
  if (stage08_is_percent_scale(x)) {
    return(x * 100)
  }
  x
}

stage08_assert_aggregate_only <- function(df, path) {
  disallowed <- c(
    "enrollee_id", "enrolid", "patient_id", "person_id", "member_id",
    "episode_id", "episode_number", "claim_id", "msclmid", "fachdid",
    "case_id", "ndc", "ndcnum", "fill_date", "service_start",
    "service_end", "admission_date", "discharge_date"
  )
  bad <- intersect(stage08_compact_name(names(df)), stage08_compact_name(disallowed))
  if (length(bad) > 0L) {
    stop(
      "Stage 08 plotting inputs must be aggregate CSVs only; found row-level columns in ",
      path,
      ": ",
      paste(names(df)[stage08_compact_name(names(df)) %in% bad], collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

stage08_read_csv <- function(data_dir, stem) {
  path <- file.path(data_dir, paste0(stem, ".csv"))
  if (!file.exists(path)) {
    return(NULL)
  }
  df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  stage08_assert_aggregate_only(df, path)
  df
}

stage08_event_month_column <- function(df, source_name) {
  col <- stage08_find_column(df, c("event_month", "event_time", "relative_month", "month"))
  if (is.null(col)) {
    stop(source_name, " must include an event_month column.", call. = FALSE)
  }
  col
}

stage08_map_known_metric <- function(values, definitions) {
  out <- rep(NA_character_, length(values))
  compact_values <- stage08_compact_name(values)
  for (key in names(definitions)) {
    aliases <- unique(stage08_compact_name(c(key, definitions[[key]])))
    hit <- vapply(
      compact_values,
      function(value) any(value %in% aliases | vapply(aliases, grepl, logical(1L), x = value, fixed = TRUE)),
      logical(1L)
    )
    out[is.na(out) & hit] <- key
  }
  out
}

stage08_measure_column <- function(df, key, aliases, exclude = character(), allow_count = FALSE) {
  cols <- setdiff(names(df), exclude)
  if (length(cols) == 0L) {
    return(NULL)
  }

  key_aliases <- unique(stage08_compact_name(c(key, aliases)))
  matched <- cols[vapply(
    stage08_compact_name(cols),
    function(value) any(value %in% key_aliases | vapply(key_aliases, grepl, logical(1L), x = value, fixed = TRUE)),
    logical(1L)
  )]
  if (length(matched) == 0L) {
    return(NULL)
  }

  score <- vapply(matched, function(col) {
    name <- stage08_compact_name(col)
    if (grepl("pct|percent", name)) return(1)
    if (grepl("rate|share|proportion|prop", name)) return(2)
    if (grepl("mean", name)) return(3)
    if (name %in% key_aliases) return(4)
    if (allow_count && grepl("count|episodes|months|n$", name)) return(5)
    20
  }, numeric(1L))
  matched[[order(score)[[1L]]]]
}

stage08_rate_long <- function(df, source_name, definitions, labels, label_candidates) {
  event_col <- stage08_event_month_column(df, source_name)
  metric_col <- stage08_find_column(df, label_candidates)
  value_col <- stage08_find_column(
    df,
    c("exposed_pct", "rate_pct", "pct_episodes", "pct_of_episodes", "pct_of_person_months",
      "rate", "pct", "percent", "share", "proportion", "prop", "mean", "value")
  )

  if (!is.null(metric_col) && !is.null(value_col)) {
    metric <- stage08_map_known_metric(df[[metric_col]], definitions)
    out <- data.frame(
      event_month = stage08_numeric(df[[event_col]]),
      metric = metric,
      value = stage08_numeric(df[[value_col]]),
      stringsAsFactors = FALSE
    )
  } else {
    rows <- list()
    idx <- 0L
    for (key in names(definitions)) {
      col <- stage08_measure_column(df, key, definitions[[key]], exclude = event_col)
      if (is.null(col)) {
        next
      }
      idx <- idx + 1L
      rows[[idx]] <- data.frame(
        event_month = stage08_numeric(df[[event_col]]),
        metric = key,
        value = stage08_numeric(df[[col]]),
        stringsAsFactors = FALSE
      )
    }
    if (length(rows) == 0L) {
      return(NULL)
    }
    out <- do.call(rbind, rows)
  }

  out <- out[!is.na(out$event_month) & !is.na(out$metric) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out$value <- stage08_percent_values(out$value)
  out$metric <- factor(out$metric, levels = names(labels), labels = unname(labels))
  out[!is.na(out$metric), , drop = FALSE]
}

stage08_stacked_event_time <- function(df, source_name) {
  event_col <- stage08_event_month_column(df, source_name)
  state_col <- stage08_find_column(df, c("treatment_state", "state", "treatment", "level", "metric", "variable"))
  value_col <- stage08_find_column(
    df,
    c("pct_episodes", "pct_of_episodes", "pct", "percent", "share", "proportion", "rate_pct",
      "rate", "n_episodes", "episode_count", "count", "n", "value")
  )

  if (!is.null(state_col) && !is.null(value_col)) {
    out <- data.frame(
      event_month = stage08_numeric(df[[event_col]]),
      state = stage08_title_case(df[[state_col]]),
      value = stage08_numeric(df[[value_col]]),
      stringsAsFactors = FALSE
    )
    percent_like <- grepl("pct|percent|share|proportion|rate", stage08_compact_name(value_col))
  } else {
    value_cols <- setdiff(names(df), event_col)
    value_cols <- value_cols[vapply(df[value_cols], function(x) any(!is.na(stage08_numeric(x))), logical(1L))]
    value_cols <- value_cols[!stage08_compact_name(value_cols) %in% c(
      "nepisodes", "episodecount", "count", "n", "personmonths", "npersonmonths"
    )]
    if (length(value_cols) == 0L) {
      return(NULL)
    }
    rows <- lapply(value_cols, function(col) {
      data.frame(
        event_month = stage08_numeric(df[[event_col]]),
        state = stage08_title_case(col),
        value = stage08_numeric(df[[col]]),
        stringsAsFactors = FALSE
      )
    })
    out <- do.call(rbind, rows)
    percent_like <- any(grepl("pct|percent|share|proportion|rate", stage08_compact_name(value_cols)))
  }

  out <- out[!is.na(out$event_month) & nzchar(out$state) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  if (percent_like || stage08_is_percent_scale(out$value)) {
    out$value <- stage08_percent_values(out$value)
    attr(out, "y_label") <- "Episodes (%)"
  } else {
    attr(out, "y_label") <- "Episodes"
  }
  out
}

stage08_condition_prevalence <- function(df) {
  condition_col <- stage08_find_column(
    df,
    c("condition", "baseline_condition", "condition_name", "condition_group", "level", "metric", "variable")
  )
  value_col <- stage08_find_column(
    df,
    c("pct_episodes", "pct_of_episodes", "prevalence_pct", "pct", "percent", "prevalence",
      "rate_pct", "rate", "share", "proportion", "value")
  )
  if (is.null(condition_col) || is.null(value_col)) {
    return(NULL)
  }
  out <- data.frame(
    condition = stage08_title_case(df[[condition_col]]),
    value = stage08_numeric(df[[value_col]]),
    stringsAsFactors = FALSE
  )
  out <- out[nzchar(out$condition) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out$value <- stage08_percent_values(out$value)
  out <- out[order(out$value, decreasing = FALSE), , drop = FALSE]
  out$condition <- factor(out$condition, levels = out$condition)
  out
}

stage08_oop_spending <- function(df) {
  event_col <- stage08_event_month_column(df, "event_time_spending_summary.csv")
  metric_col <- stage08_find_column(df, c("variable", "metric", "measure"))
  stat_col <- stage08_find_column(df, c("statistic", "summary", "stat"))
  value_col <- stage08_find_column(df, c("value", "estimate", "amount"))

  if (!is.null(metric_col) && !is.null(stat_col) && !is.null(value_col)) {
    tmp <- df[grepl("oop|out_of_pocket|outofpocket", stage08_compact_name(df[[metric_col]])), , drop = FALSE]
    stats <- stage08_compact_name(tmp[[stat_col]])
    preferred <- if (any(grepl("median", stats))) "median" else "mean"
    tmp <- tmp[grepl(preferred, stats), , drop = FALSE]
    out <- data.frame(
      event_month = stage08_numeric(tmp[[event_col]]),
      measure = stage08_oop_label(tmp[[metric_col]]),
      statistic = preferred,
      value = stage08_numeric(tmp[[value_col]]),
      stringsAsFactors = FALSE
    )
  } else if (!is.null(metric_col)) {
    stat_value_col <- stage08_find_column(df, c("median", "mean"))
    if (is.null(stat_value_col)) {
      return(stage08_oop_spending_wide(df, event_col))
    }
    tmp <- df[grepl("oop|out_of_pocket|outofpocket", stage08_compact_name(df[[metric_col]])), , drop = FALSE]
    out <- data.frame(
      event_month = stage08_numeric(tmp[[event_col]]),
      measure = stage08_oop_label(tmp[[metric_col]]),
      statistic = tolower(stat_value_col),
      value = stage08_numeric(tmp[[stat_value_col]]),
      stringsAsFactors = FALSE
    )
  } else {
    out <- stage08_oop_spending_wide(df, event_col)
  }

  out <- out[!is.na(out$event_month) & nzchar(out$measure) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out
}

stage08_oop_spending_wide <- function(df, event_col) {
  cols <- setdiff(names(df), event_col)
  compact <- stage08_compact_name(cols)
  oop_cols <- cols[grepl("oop|outofpocket|patient", compact) & grepl("median|mean", compact)]
  if (length(oop_cols) == 0L) {
    return(NULL)
  }
  selected_stat <- if (any(grepl("median", stage08_compact_name(oop_cols)))) "median" else "mean"
  oop_cols <- oop_cols[grepl(selected_stat, stage08_compact_name(oop_cols))]

  rows <- lapply(oop_cols, function(col) {
    data.frame(
      event_month = stage08_numeric(df[[event_col]]),
      measure = stage08_oop_label(col),
      statistic = selected_stat,
      value = stage08_numeric(df[[col]]),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

stage08_oop_label <- function(x) {
  compact <- stage08_compact_name(x)
  out <- character(length(compact))
  out[grepl("total", compact)] <- "Total OOP"
  out[grepl("rx|pharmacy", compact)] <- "Rx OOP"
  out[grepl("medical", compact)] <- "Medical OOP"
  missing <- !nzchar(out)
  out[missing] <- stage08_title_case(gsub("median|mean|monthly|patient|oop|out_of_pocket", "", x[missing], ignore.case = TRUE))
  out
}

stage08_spending_distribution_percentiles <- function(df, variable = "monthly_allowed_amount_total",
                                                      population = "all_person_months") {
  event_col <- stage08_event_month_column(df, "event_time_spending_distribution.csv")
  variable_col <- stage08_find_column(df, c("variable", "measure", "metric"))
  population_col <- stage08_find_column(df, c("population", "subpopulation", "sample"))
  if (is.null(variable_col)) {
    return(NULL)
  }
  tmp <- df[df[[variable_col]] == variable, , drop = FALSE]
  if (!is.null(population_col)) {
    tmp <- tmp[tmp[[population_col]] == population, , drop = FALSE]
  }
  percentile_cols <- intersect(c("median", "p75", "p90", "p95", "p99"), names(tmp))
  if (nrow(tmp) == 0L || length(percentile_cols) == 0L) {
    return(NULL)
  }
  labels <- c(median = "P50", p75 = "P75", p90 = "P90", p95 = "P95", p99 = "P99")
  rows <- lapply(percentile_cols, function(col) {
    data.frame(
      event_month = stage08_numeric(tmp[[event_col]]),
      percentile = labels[[col]],
      value = stage08_numeric(tmp[[col]]),
      stringsAsFactors = FALSE
    )
  })
  out <- do.call(rbind, rows)
  out <- out[!is.na(out$event_month) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out$percentile <- factor(out$percentile, levels = unname(labels[percentile_cols]))
  out
}

stage08_component_label <- function(x) {
  labels <- c(
    medical = "Medical",
    glp1_like_rx = "GLP-1-like Rx",
    non_glp1_like_rx = "Other Rx"
  )
  out <- labels[as.character(x)]
  out[is.na(out)] <- stage08_title_case(x[is.na(out)])
  unname(out)
}

stage08_spending_decomposition <- function(df, amount_type = "allowed_amount") {
  event_col <- stage08_event_month_column(df, "event_time_spending_decomposition.csv")
  amount_col <- stage08_find_column(df, c("amount_type", "amount", "cost_type", "spending_type"))
  component_col <- stage08_find_column(df, c("component", "category", "source"))
  value_col <- stage08_find_column(df, c("mean", "mean_value", "value", "estimate"))
  if (is.null(amount_col) || is.null(component_col) || is.null(value_col)) {
    return(NULL)
  }
  tmp <- df[df[[amount_col]] == amount_type, , drop = FALSE]
  out <- data.frame(
    event_month = stage08_numeric(tmp[[event_col]]),
    component = stage08_component_label(tmp[[component_col]]),
    value = stage08_numeric(tmp[[value_col]]),
    stringsAsFactors = FALSE
  )
  out <- out[!is.na(out$event_month) & nzchar(out$component) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out$component <- factor(out$component, levels = c("Medical", "Other Rx", "GLP-1-like Rx"))
  out
}

stage08_glp1_payer_decomposition <- function(df) {
  event_col <- stage08_event_month_column(df, "event_time_spending_decomposition.csv")
  amount_col <- stage08_find_column(df, c("amount_type", "amount", "cost_type", "spending_type"))
  component_col <- stage08_find_column(df, c("component", "category", "source"))
  value_col <- stage08_find_column(df, c("mean", "mean_value", "value", "estimate"))
  if (is.null(amount_col) || is.null(component_col) || is.null(value_col)) {
    return(NULL)
  }
  tmp <- df[df[[component_col]] == "glp1_like_rx" & df[[amount_col]] %in% c("plan_paid", "patient_oop"), , drop = FALSE]
  labels <- c(plan_paid = "Plan paid", patient_oop = "Patient OOP")
  out <- data.frame(
    event_month = stage08_numeric(tmp[[event_col]]),
    payer = unname(labels[tmp[[amount_col]]]),
    value = stage08_numeric(tmp[[value_col]]),
    stringsAsFactors = FALSE
  )
  out <- out[!is.na(out$event_month) & nzchar(out$payer) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  out$payer <- factor(out$payer, levels = c("Plan paid", "Patient OOP"))
  out
}

stage08_multimorbidity_burden <- function(df) {
  burden_col <- stage08_find_column(
    df,
    c("condition_count", "multimorbidity_count", "multimorbidity_burden", "burden", "category", "level")
  )
  value_col <- stage08_find_column(
    df,
    c("pct_episodes", "pct_of_episodes", "pct", "percent", "share", "proportion",
      "n_episodes", "episode_count", "count", "n", "value")
  )
  if (is.null(burden_col) || is.null(value_col)) {
    return(NULL)
  }
  out <- data.frame(
    burden = as.character(df[[burden_col]]),
    value = stage08_numeric(df[[value_col]]),
    stringsAsFactors = FALSE
  )
  out <- out[nzchar(out$burden) & !is.na(out$value), , drop = FALSE]
  if (nrow(out) == 0L) {
    return(NULL)
  }
  percent_like <- grepl("pct|percent|share|proportion", stage08_compact_name(value_col))
  if (percent_like || stage08_is_percent_scale(out$value)) {
    out$value <- stage08_percent_values(out$value)
    attr(out, "y_label") <- "Episodes (%)"
  } else {
    attr(out, "y_label") <- "Episodes"
  }
  numeric_burden <- stage08_numeric(out$burden)
  if (all(!is.na(numeric_burden))) {
    out <- out[order(numeric_burden), , drop = FALSE]
  } else {
    out <- out[order(out$value, decreasing = TRUE), , drop = FALSE]
  }
  out$burden <- factor(out$burden, levels = out$burden)
  out
}

stage08_theme <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "bottom",
      plot.title.position = "plot"
    )
}

stage08_line_plot <- function(data, title, y_label, color_label) {
  ggplot2::ggplot(data, ggplot2::aes(x = .data$event_month, y = .data$value, color = .data$metric)) +
    ggplot2::geom_line(linewidth = 0.8, na.rm = TRUE) +
    ggplot2::geom_point(size = 1.8, na.rm = TRUE) +
    ggplot2::labs(x = "Event month", y = y_label, color = color_label, title = title) +
    stage08_theme()
}

stage08_save_plot <- function(plot, figure_dir, stem, formats, width, height, dpi, overwrite) {
  dir.create(figure_dir, recursive = TRUE, showWarnings = FALSE)
  paths <- character()
  for (format in formats) {
    path <- file.path(figure_dir, paste0(stem, ".", format))
    if (file.exists(path) && !isTRUE(overwrite)) {
      paths <- c(paths, path)
      next
    }
    ggplot2::ggsave(
      filename = path,
      plot = plot,
      width = width,
      height = height,
      dpi = dpi,
      units = "in",
      limitsize = FALSE
    )
    paths <- c(paths, path)
  }
  paths
}

stage08_normalize_formats <- function(formats) {
  formats <- unlist(strsplit(as.character(formats), ",", fixed = TRUE), use.names = FALSE)
  formats <- tolower(trimws(formats))
  formats <- formats[nzchar(formats)]
  if (length(formats) == 0L) {
    stop("At least one output format is required.", call. = FALSE)
  }
  unsupported <- setdiff(formats, c("png", "pdf"))
  if (length(unsupported) > 0L) {
    stop("Unsupported Stage 08 figure format(s): ", paste(unsupported, collapse = ", "), call. = FALSE)
  }
  unique(formats)
}

make_stage08_figures <- function(data_dir, figure_dir = NULL, formats = c("png"),
                                 width = 9, height = 5, dpi = 300, overwrite = TRUE) {
  stage08_required_ggplot2()

  if (missing(data_dir) || is.null(data_dir) || !nzchar(data_dir)) {
    stop("data_dir is required and must point to a Stage 08 aggregate CSV directory.", call. = FALSE)
  }
  if (!dir.exists(data_dir)) {
    stop("Stage 08 aggregate CSV directory does not exist: ", data_dir, call. = FALSE)
  }

  figure_dir <- figure_dir %||% dirname(normalizePath(data_dir, mustWork = FALSE))
  formats <- stage08_normalize_formats(formats)
  width <- as.numeric(width)
  height <- as.numeric(height)
  dpi <- as.numeric(dpi)
  if (is.na(width) || width <= 0 || is.na(height) || height <= 0 || is.na(dpi) || dpi <= 0) {
    stop("width, height, and dpi must be positive numeric values.", call. = FALSE)
  }

  outputs <- data.frame(figure = character(), format = character(), path = character(), stringsAsFactors = FALSE)
  add_outputs <- function(stem, plot) {
    paths <- stage08_save_plot(plot, figure_dir, stem, formats, width, height, dpi, overwrite)
    data.frame(
      figure = stem,
      format = tools::file_ext(paths),
      path = paths,
      stringsAsFactors = FALSE
    )
  }

  medication_defs <- list(
    dpp4 = c("dpp4", "dpp_4", "drug_any_dpp4"),
    glp1_like = c("glp1_like", "glp1", "glp_1", "drug_any_glp1_like"),
    metformin = c("metformin", "drug_any_metformin"),
    insulin = c("insulin", "drug_any_insulin"),
    sglt2 = c("sglt2", "sglt_2", "drug_any_sglt2"),
    sulfonylurea = c("sulfonylurea", "sulphonylurea", "drug_any_sulfonylurea")
  )
  medication_labels <- c(
    dpp4 = "DPP-4",
    glp1_like = "GLP-1-like",
    metformin = "Metformin",
    insulin = "Insulin",
    sglt2 = "SGLT2",
    sulfonylurea = "Sulfonylurea"
  )

  medication <- stage08_read_csv(data_dir, "event_time_medication_rates")
  if (!is.null(medication)) {
    data <- stage08_rate_long(
      medication,
      "event_time_medication_rates.csv",
      medication_defs,
      medication_labels,
      c("drug_class", "medication", "drug", "level", "metric", "variable")
    )
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- stage08_line_plot(
        data,
        "Medication Use Around Switch",
        "Episodes (%)",
        "Medication"
      )
      outputs <- rbind(outputs, add_outputs("event_time_medication_rates", plot))
    }
  }

  treatment <- stage08_read_csv(data_dir, "treatment_state_event_time")
  if (!is.null(treatment)) {
    data <- stage08_stacked_event_time(treatment, "treatment_state_event_time.csv")
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = factor(.data$event_month), y = .data$value, fill = .data$state)) +
        ggplot2::geom_col(width = 0.85) +
        ggplot2::labs(
          x = "Event month",
          y = attr(data, "y_label") %||% "Episodes",
          fill = "Treatment state",
          title = "Treatment State Around Switch"
        ) +
        stage08_theme()
      outputs <- rbind(outputs, add_outputs("treatment_state_event_time", plot))
    }
  }

  conditions <- stage08_read_csv(data_dir, "baseline_condition_prevalence")
  if (!is.null(conditions)) {
    data <- stage08_condition_prevalence(conditions)
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$condition, y = .data$value)) +
        ggplot2::geom_col(fill = "#4C78A8", width = 0.75) +
        ggplot2::coord_flip() +
        ggplot2::labs(x = NULL, y = "Episodes (%)", title = "Baseline Condition Prevalence") +
        stage08_theme() +
        ggplot2::theme(legend.position = "none")
      outputs <- rbind(outputs, add_outputs("baseline_condition_prevalence", plot))
    }
  }

  utilization_defs <- list(
    any_medical_claim = c("any_medical_claim", "medical_claim", "any_claim", "any_claim_month"),
    rx_fill = c("rx_fill", "any_rx_fill", "pharmacy_fill", "monthly_rx_fill"),
    outpatient = c("outpatient", "outpatient_claim", "any_outpatient"),
    inpatient = c("inpatient", "inpatient_admission", "admission", "any_inpatient"),
    ed = c("ed", "ed_visit", "emergency_department", "emergency_room")
  )
  utilization_labels <- c(
    any_medical_claim = "Any medical claim",
    rx_fill = "Rx fill",
    outpatient = "Outpatient",
    inpatient = "Inpatient",
    ed = "ED"
  )

  utilization <- stage08_read_csv(data_dir, "event_time_utilization_rates")
  if (!is.null(utilization)) {
    data <- stage08_rate_long(
      utilization,
      "event_time_utilization_rates.csv",
      utilization_defs,
      utilization_labels,
      c("utilization_type", "service_type", "metric", "measure", "level", "variable")
    )
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- stage08_line_plot(
        data,
        "Utilization Around Switch",
        "Episodes (%)",
        "Utilization"
      )
      outputs <- rbind(outputs, add_outputs("event_time_utilization_rates", plot))
    }
  }

  spending <- stage08_read_csv(data_dir, "event_time_spending_summary")
  if (!is.null(spending)) {
    data <- stage08_oop_spending(spending)
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$event_month, y = .data$value, color = .data$measure)) +
        ggplot2::geom_line(linewidth = 0.8, na.rm = TRUE) +
        ggplot2::geom_point(size = 1.8, na.rm = TRUE) +
        ggplot2::labs(
          x = "Event month",
          y = "Patient OOP",
          color = "Measure",
          title = paste0(stage08_title_case(unique(data$statistic)[[1L]]), " Patient OOP Around Switch")
        ) +
        stage08_theme()
      outputs <- rbind(outputs, add_outputs("event_time_oop_spending", plot))
    }
  }

  spending_distribution <- stage08_read_csv(data_dir, "event_time_spending_distribution")
  if (!is.null(spending_distribution)) {
    data <- stage08_spending_distribution_percentiles(
      spending_distribution,
      variable = "monthly_allowed_amount_total",
      population = "all_person_months"
    )
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$event_month, y = .data$value, color = .data$percentile)) +
        ggplot2::geom_line(linewidth = 0.8, na.rm = TRUE) +
        ggplot2::geom_point(size = 1.8, na.rm = TRUE) +
        ggplot2::labs(
          x = "Event month",
          y = "Monthly allowed amount",
          color = "Percentile",
          title = "Distribution of Total Monthly Allowed Amount"
        ) +
        stage08_theme()
      outputs <- rbind(outputs, add_outputs("event_time_allowed_spending_distribution", plot))
    }
  }

  spending_decomposition <- stage08_read_csv(data_dir, "event_time_spending_decomposition")
  if (!is.null(spending_decomposition)) {
    data <- stage08_spending_decomposition(spending_decomposition, amount_type = "allowed_amount")
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$event_month, y = .data$value, fill = .data$component)) +
        ggplot2::geom_col(width = 0.85, na.rm = TRUE) +
        ggplot2::labs(
          x = "Event month",
          y = "Mean monthly allowed amount",
          fill = "Component",
          title = "Mean Allowed Spending Decomposition"
        ) +
        stage08_theme()
      outputs <- rbind(outputs, add_outputs("event_time_allowed_spending_decomposition", plot))
    }

    data <- stage08_glp1_payer_decomposition(spending_decomposition)
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$event_month, y = .data$value, fill = .data$payer)) +
        ggplot2::geom_col(width = 0.85, na.rm = TRUE) +
        ggplot2::labs(
          x = "Event month",
          y = "Mean GLP-1-like Rx amount",
          fill = "Payer component",
          title = "GLP-1-like Rx Spending by Payer Component"
        ) +
        stage08_theme()
      outputs <- rbind(outputs, add_outputs("event_time_glp1_rx_payer_decomposition", plot))
    }
  }

  burden <- stage08_read_csv(data_dir, "multimorbidity_burden")
  if (!is.null(burden)) {
    data <- stage08_multimorbidity_burden(burden)
    if (!is.null(data) && nrow(data) > 0L) {
      plot <- ggplot2::ggplot(data, ggplot2::aes(x = .data$burden, y = .data$value)) +
        ggplot2::geom_col(fill = "#59A14F", width = 0.75) +
        ggplot2::labs(
          x = "Baseline condition count",
          y = attr(data, "y_label") %||% "Episodes",
          title = "Multimorbidity Burden"
        ) +
        stage08_theme() +
        ggplot2::theme(legend.position = "none")
      outputs <- rbind(outputs, add_outputs("multimorbidity_burden", plot))
    }
  }

  rownames(outputs) <- NULL
  outputs
}
