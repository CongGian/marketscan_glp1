# Configuration helpers for the metadata-driven MarketScan pipeline.
# These functions read YAML and expand paths only; they never read MarketScan data.

required_modules <- c("A", "D", "F", "I", "O", "S", "T")

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

is_scalar_character <- function(x) {
  is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)
}

append_error <- function(errors, message) {
  c(errors, message)
}

load_config <- function(path = "config/config_template.yaml") {
  if (!requireNamespace("yaml", quietly = TRUE)) {
    stop("Package 'yaml' is required to load configuration files.", call. = FALSE)
  }
  if (!file.exists(path)) {
    stop(sprintf("Config file does not exist: %s", path), call. = FALSE)
  }

  cfg <- yaml::read_yaml(path, eval.expr = FALSE)
  attr(cfg, "config_path") <- normalizePath(path, mustWork = FALSE)
  validate_config(cfg)
  cfg
}

validate_config <- function(cfg) {
  errors <- character()

  if (!is.list(cfg)) {
    stop("Config must be a YAML mapping/list.", call. = FALSE)
  }

  required_top <- c("project", "paths", "study_period", "modules", "variables", "code_lists")
  for (key in required_top) {
    if (is.null(cfg[[key]])) {
      errors <- append_error(errors, sprintf("Missing required top-level key: %s", key))
    }
  }

  if (!is.null(cfg$paths)) {
    for (key in c("raw_root", "code_list_root")) {
      if (!is_scalar_character(cfg$paths[[key]])) {
        errors <- append_error(errors, sprintf("paths.%s must be a non-empty string.", key))
      }
    }
  }

  if (!is.null(cfg$study_period)) {
    years <- cfg$study_period$data_years
    if (!(is.numeric(years) || is.integer(years)) || length(years) == 0L) {
      errors <- append_error(errors, "study_period.data_years must be a non-empty numeric vector.")
    }

    index_start <- suppressWarnings(as.Date(cfg$study_period$index_start))
    index_end <- suppressWarnings(as.Date(cfg$study_period$index_end))
    if (is.na(index_start)) {
      errors <- append_error(errors, "study_period.index_start must parse as YYYY-MM-DD.")
    }
    if (is.na(index_end)) {
      errors <- append_error(errors, "study_period.index_end must parse as YYYY-MM-DD.")
    }
    if (!is.na(index_start) && !is.na(index_end) && index_start > index_end) {
      errors <- append_error(errors, "study_period.index_start must be on or before index_end.")
    }
  }

  if (!is.null(cfg$modules)) {
    for (module in required_modules) {
      entry <- cfg$modules[[module]]
      if (is.null(entry)) {
        errors <- append_error(errors, sprintf("modules.%s is required.", module))
      } else if (!is_scalar_character(entry$pattern)) {
        errors <- append_error(errors, sprintf("modules.%s.pattern must be a non-empty string.", module))
      } else if (!grepl("{year}", entry$pattern, fixed = TRUE)) {
        errors <- append_error(errors, sprintf("modules.%s.pattern must contain {year}.", module))
      }
    }
  }

  if (!is.null(cfg$variables)) {
    common <- cfg$variables$common %||% list()
    if (!identical(common$enrollee_id, "ENROLID")) {
      errors <- append_error(errors, "variables.common.enrollee_id must map to ENROLID.")
    }

    module_required_vars <- list(
      A = c("enrollee_id", "year", "member_days", "age", "sex", "region", "health_plan", "rx_benefit"),
      D = c("enrollee_id", "fill_date", "ndc", "days_supply", "allowed_amount", "plan_paid",
            "copay", "coinsurance", "deductible"),
      F = c("enrollee_id", "facility_header_id", "service_start", "service_end", "dx_fields",
            "proc_fields", "place_of_service", "plan_paid", "copay", "coinsurance", "deductible"),
      I = c("enrollee_id", "case_id", "admission_date", "discharge_date", "dx_fields", "proc_fields",
            "allowed_amount", "plan_paid", "copay", "coinsurance", "deductible"),
      O = c("enrollee_id", "service_start", "service_end", "dx_fields", "proc_fields",
            "place_of_service", "revenue_code", "allowed_amount", "plan_paid",
            "copay", "coinsurance", "deductible"),
      S = c("enrollee_id", "case_id", "facility_header_id", "service_start", "service_end",
            "dx_fields", "proc_fields", "place_of_service", "revenue_code",
            "allowed_amount", "plan_paid", "copay", "coinsurance", "deductible"),
      T = c("enrollee_id", "enrollment_start", "enrollment_end", "member_days",
            "medical_coverage", "plan_type", "rx_benefit", "age", "sex", "region")
    )

    for (module in names(module_required_vars)) {
      module_vars <- cfg$variables[[module]]
      if (is.null(module_vars)) {
        errors <- append_error(errors, sprintf("variables.%s is required.", module))
        next
      }
      missing_vars <- setdiff(module_required_vars[[module]], names(module_vars))
      if (length(missing_vars) > 0L) {
        errors <- append_error(
          errors,
          sprintf("variables.%s is missing: %s", module, paste(missing_vars, collapse = ", "))
        )
      }
    }
  }

  if (!is.null(cfg$code_lists)) {
    drug_ndc <- cfg$code_lists$drug_ndc %||% list()
    diagnosis_groups <- cfg$code_lists$diagnosis_groups %||% list()
    for (key in c("glp1", "glp1_like", "dpp4", "metformin", "insulin", "sglt2")) {
      if (!is_scalar_character(drug_ndc[[key]])) {
        errors <- append_error(errors, sprintf("code_lists.drug_ndc.%s must be a non-empty string.", key))
      }
    }
    for (key in c("type2_diabetes", "obesity", "chronic_kidney_disease")) {
      if (!is_scalar_character(diagnosis_groups[[key]])) {
        errors <- append_error(errors, sprintf("code_lists.diagnosis_groups.%s must be a non-empty string.", key))
      }
    }
  }

  if (length(errors) > 0L) {
    stop(paste(c("Invalid configuration:", paste0(" - ", errors)), collapse = "\n"), call. = FALSE)
  }

  TRUE
}

canonical_module <- function(cfg, module) {
  if (!is_scalar_character(module)) {
    stop("module must be a non-empty string.", call. = FALSE)
  }

  module_upper <- toupper(module)
  if (!is.null(cfg$modules[[module_upper]])) {
    return(module_upper)
  }

  aliases <- cfg$module_aliases %||% list()
  alias_names <- names(aliases)
  alias_idx <- which(toupper(alias_names) == module_upper)
  alias_match <- NULL
  if (length(alias_idx) > 0L) {
    alias_match <- aliases[[alias_names[[alias_idx[[1L]]]]]]
  }
  if (is_scalar_character(alias_match) && !is.null(cfg$modules[[alias_match]])) {
    return(alias_match)
  }

  stop(sprintf("Unknown module: %s", module), call. = FALSE)
}

expand_year_pattern <- function(pattern, year) {
  if (!is_scalar_character(pattern)) {
    stop("pattern must be a non-empty string.", call. = FALSE)
  }
  if (length(year) != 1L || is.na(year)) {
    stop("year must be a single non-missing value.", call. = FALSE)
  }
  gsub("{year}", as.character(year), pattern, fixed = TRUE)
}

resolve_module_file <- function(cfg, module, year, raw_root = NULL, must_exist = FALSE) {
  validate_config(cfg)
  module <- canonical_module(cfg, module)
  raw_root <- raw_root %||% cfg$paths$raw_root
  if (!is_scalar_character(raw_root)) {
    stop("raw_root must be a non-empty string.", call. = FALSE)
  }

  relative_path <- expand_year_pattern(cfg$modules[[module]]$pattern, year)
  path <- file.path(path.expand(raw_root), relative_path)
  if (isTRUE(must_exist) && !file.exists(path)) {
    stop(sprintf("Resolved module file does not exist: %s", path), call. = FALSE)
  }
  path
}

resolve_module_files <- function(cfg, modules = names(cfg$modules), years = cfg$study_period$data_years,
                                 raw_root = NULL, must_exist = FALSE) {
  validate_config(cfg)
  rows <- list()
  idx <- 0L
  for (module in modules) {
    canonical <- canonical_module(cfg, module)
    for (year in years) {
      idx <- idx + 1L
      rows[[idx]] <- data.frame(
        module = canonical,
        year = as.integer(year),
        path = resolve_module_file(cfg, canonical, year, raw_root = raw_root, must_exist = must_exist),
        stringsAsFactors = FALSE
      )
    }
  }
  do.call(rbind, rows)
}

resolve_code_list_path <- function(cfg, group, name = NULL, code_list_root = NULL, must_exist = FALSE) {
  validate_config(cfg)
  code_list_root <- code_list_root %||% cfg$paths$code_list_root
  if (!is_scalar_character(code_list_root)) {
    stop("code_list_root must be a non-empty string.", call. = FALSE)
  }

  if (is.null(name)) {
    relative_path <- find_code_list_by_name(cfg$code_lists, group)
    label <- group
  } else {
    if (is.null(cfg$code_lists[[group]])) {
      stop(sprintf("Unknown code-list group: %s", group), call. = FALSE)
    }
    relative_path <- cfg$code_lists[[group]][[name]]
    label <- paste(group, name, sep = ".")
  }

  if (!is_scalar_character(relative_path)) {
    stop(sprintf("Unknown code list: %s", label), call. = FALSE)
  }

  path <- file.path(path.expand(code_list_root), relative_path)
  if (isTRUE(must_exist) && !file.exists(path)) {
    stop(sprintf("Resolved code-list file does not exist: %s", path), call. = FALSE)
  }
  path
}

find_code_list_by_name <- function(code_lists, name) {
  if (!is_scalar_character(name)) {
    stop("code-list name must be a non-empty string.", call. = FALSE)
  }
  for (group in names(code_lists)) {
    entry <- code_lists[[group]]
    if (is.list(entry) && is_scalar_character(entry[[name]])) {
      return(entry[[name]])
    }
  }
  NULL
}

resolve_code_list_paths <- function(cfg, group = NULL, code_list_root = NULL, must_exist = FALSE) {
  validate_config(cfg)
  groups <- if (is.null(group)) names(cfg$code_lists) else group
  paths <- character()

  for (group_name in groups) {
    entries <- cfg$code_lists[[group_name]]
    if (is.null(entries) || !is.list(entries)) {
      stop(sprintf("Unknown code-list group: %s", group_name), call. = FALSE)
    }
    for (entry_name in names(entries)) {
      key <- paste(group_name, entry_name, sep = ".")
      paths[[key]] <- resolve_code_list_path(
        cfg,
        group = group_name,
        name = entry_name,
        code_list_root = code_list_root,
        must_exist = must_exist
      )
    }
  }

  paths
}
