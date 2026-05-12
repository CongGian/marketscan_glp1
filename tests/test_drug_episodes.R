drug_episodes_path <- if (file.exists(file.path("R", "drug_episodes.R"))) {
  file.path("R", "drug_episodes.R")
} else {
  file.path("..", "R", "drug_episodes.R")
}
source(drug_episodes_path)

assert_true <- function(x, message) {
  if (!isTRUE(x)) {
    stop(message, call. = FALSE)
  }
}

assert_equal <- function(x, y, message) {
  if (!identical(x, y)) {
    stop(
      sprintf("%s\nExpected: %s\nObserved: %s", message, y, x),
      call. = FALSE
    )
  }
}

rx_row <- function(enrollee_id, fill_date, days_supply, drug_class, ndc11 = "12345678901") {
  data.frame(
    enrollee_id = enrollee_id,
    fill_date = as.Date(fill_date),
    ndc11 = ndc11,
    days_supply = days_supply,
    drug_class = drug_class,
    stringsAsFactors = FALSE
  )
}

clean_rx <- rbind(
  rx_row("clean", "2020-11-15", 30, "dpp4", "00000000001"),
  rx_row("clean", "2020-12-15", 30, "dpp4", "00000000001"),
  rx_row("clean", "2021-01-01", 30, "glp1", "00000000002")
)
clean_result <- classify_dpp4_to_glp1_switches(clean_rx)
assert_equal(
  clean_result$switch_class[1],
  "clean_replacement",
  "DPP-4 supply ending within the transition window should be a clean replacement."
)
assert_true(
  clean_result$qualifying_dpp4_preindex[1],
  "Clean replacement should have qualifying pre-index DPP-4 evidence."
)

addon_rx <- rbind(
  rx_row("addon", "2020-12-15", 30, "dpp4", "00000000001"),
  rx_row("addon", "2021-01-01", 30, "glp1", "00000000002"),
  rx_row("addon", "2021-02-15", 30, "dpp4", "00000000001")
)
addon_result <- classify_dpp4_to_glp1_switches(addon_rx)
assert_equal(
  addon_result$switch_class[1],
  "addon_or_overlap",
  "DPP-4 refill after the post-index grace window should be add-on/overlap."
)
assert_true(
  addon_result$dpp4_postindex_fill_after_grace[1],
  "Add-on case should flag a DPP-4 fill after the post-index grace window."
)

switchback_rx <- rbind(
  rx_row("switchback", "2020-12-15", 30, "dpp4", "00000000001"),
  rx_row("switchback", "2021-01-01", 30, "glp1", "00000000002"),
  rx_row("switchback", "2021-03-05", 30, "dpp4", "00000000001")
)
switchback_result <- classify_dpp4_to_glp1_switches(switchback_rx)
assert_true(
  switchback_result$switch_back[1],
  "DPP-4 restart after GLP-1 coverage plus grace should flag switch_back."
)

ambiguous_rx <- rx_row("ambiguous", "2021-01-01", 30, "glp1", "00000000002")
ambiguous_result <- classify_dpp4_to_glp1_switches(ambiguous_rx)
assert_equal(
  ambiguous_result$switch_class[1],
  "ambiguous_switch",
  "GLP-1 index without qualifying pre-index DPP-4 should be ambiguous."
)

washout_rx <- rbind(
  rx_row("washout", "2020-08-01", 30, "glp1", "00000000002"),
  rx_row("washout", "2020-12-15", 30, "dpp4", "00000000001"),
  rx_row("washout", "2021-01-01", 30, "glp1", "00000000002")
)
washout_result <- classify_dpp4_to_glp1_switches(washout_rx)
assert_equal(
  washout_result$switch_class[1],
  "prior_glp1_washout_failure",
  "Prior GLP-1 use inside 365 days should fail washout."
)
assert_true(
  !washout_result$glp1_washout_pass[1],
  "Washout failure should carry a FALSE washout flag."
)

stockpile_rx <- rbind(
  rx_row("stockpile", "2021-01-01", 30, "dpp4", "00000000001"),
  rx_row("stockpile", "2021-01-20", 30, "dpp4", "00000000001")
)
stockpile_episodes <- construct_drug_episodes(stockpile_rx)
assert_equal(
  nrow(stockpile_episodes),
  1L,
  "Overlapping DPP-4 fills should be merged into one episode."
)
assert_equal(
  as.character(stockpile_episodes$episode_end[1]),
  "2021-03-01",
  "Overlapping refill should carry unused supply forward."
)

standardized <- standardize_rx_claims(data.frame(
  enrollee_id = "ndc",
  fill_date = "20210101",
  ndc11 = "12345-6789-01",
  days_supply = "30",
  drug_class = "DPP-4",
  stringsAsFactors = FALSE
))
assert_equal(
  standardized$ndc11[1],
  "12345678901",
  "normalize_ndc11 should strip separators and retain NDC11."
)
assert_equal(
  standardized$drug_class[1],
  "dpp4",
  "standardize_rx_claims should canonicalize DPP-4 class labels."
)

assert_true(
  identical(
    normalize_ndc11(c("1234-5678-90", "12345-678-90", "12345-6789-0")),
    c("01234567890", "12345067890", "12345678900")
  ),
  "normalize_ndc11 should pad hyphenated 10-digit NDCs by segment."
)

message("drug episode tests passed")
