person_month_path <- if (file.exists(file.path("R", "person_month.R"))) {
  file.path("R", "person_month.R")
} else {
  file.path("..", "R", "person_month.R")
}
source(person_month_path)

expect_true <- function(value, message) {
  if (!isTRUE(value)) {
    stop(message, call. = FALSE)
  }
}

expect_equal <- function(observed, expected, message) {
  if (!identical(observed, expected)) {
    stop(
      sprintf(
        "%s\nObserved: %s\nExpected: %s",
        message,
        paste(observed, collapse = ", "),
        paste(expected, collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

index <- data.frame(
  enrollee_id = "e1",
  episode_id = "ep1",
  index_date = as.Date("2021-06-15"),
  switch_category = "clean_replacement",
  stringsAsFactors = FALSE
)

drug_fills <- data.frame(
  enrollee_id = c("e1", "e1", "e1"),
  episode_id = c("ep1", "ep1", "ep1"),
  fill_date = as.Date(c("2021-05-20", "2021-06-15", "2021-07-10")),
  days_supply = c(30L, 30L, 30L),
  drug_class = c("dpp4", "glp1_like", "glp1_like"),
  stringsAsFactors = FALSE
)

financials <- data.frame(
  enrollee_id = c("e1", "e1", "e1", "e1"),
  episode_id = c("ep1", "ep1", "ep1", "ep1"),
  service_date = as.Date(c("2021-05-15", "2021-06-05", "2021-06-20", "2021-07-01")),
  class = c("rx", "rx", "medical", "rx"),
  pay = c(40, 100, 50, 20),
  netpay = c(30, 80, 40, 10),
  copay = c(4, 10, 5, 3),
  coinsurance = c(1, 2, 1, 0),
  deductible = c(0, 5, 0, 2),
  stringsAsFactors = FALSE
)

medical_claims <- data.frame(
  enrollee_id = c("e1", "e1"),
  episode_id = c("ep1", "ep1"),
  service_date = as.Date(c("2021-04-03", "2021-06-25")),
  setting = c("office", "ed"),
  dx1 = c("E119", "K850"),
  obesity_flag = c(0L, 1L),
  stringsAsFactors = FALSE
)

person_month <- assemble_person_month_table(
  index_table = index,
  drug_fills = drug_fills,
  financials = financials,
  medical_claims = medical_claims,
  diagnosis_prefixes = list(diabetes = "E11", pancreatitis = "K85")
)

expect_equal(nrow(person_month), 25L, "one episode should produce 25 event-month rows")
expect_equal(
  person_month$event_month,
  -12L:12L,
  "event-month sequence should run from -12 through +12"
)

event_dates <- person_month[c("event_month", "year_month", "calendar_year", "calendar_month")]
expect_equal(
  event_dates$year_month[event_dates$event_month == -12L],
  "2020-06",
  "event month -12 should be the month 12 months before index month"
)
expect_equal(
  event_dates$year_month[event_dates$event_month == 0L],
  "2021-06",
  "event month 0 should be the index calendar month"
)
expect_equal(
  event_dates$year_month[event_dates$event_month == 12L],
  "2022-06",
  "event month +12 should be the month 12 months after index month"
)
expect_equal(
  event_dates$calendar_year[event_dates$event_month == 0L],
  2021L,
  "calendar_year should match event-month date"
)
expect_equal(
  event_dates$calendar_month[event_dates$event_month == 0L],
  6L,
  "calendar_month should match event-month date"
)

index_month <- person_month[person_month$event_month == 0L, , drop = FALSE]
expect_equal(
  index_month$monthly_patient_oop,
  23,
  "monthly patient OOP should aggregate copay + coinsurance + deductible"
)
expect_equal(index_month$monthly_pay, 150, "monthly PAY should aggregate within event month")
expect_equal(index_month$monthly_netpay, 120, "monthly NETPAY should aggregate within event month")
expect_equal(index_month$monthly_patient_oop_rx, 17, "monthly OOP should aggregate by class")
expect_equal(index_month$monthly_patient_oop_medical, 6, "monthly OOP should aggregate medical class")
expect_equal(index_month$drug_any_glp1_like, 1L, "GLP-1-like coverage should be active in index month")
expect_equal(index_month$drug_fills_glp1_like, 1L, "GLP-1-like fill count should use fills starting in month")
expect_equal(index_month$monthly_ed_visits, 1L, "monthly ED visits should be counted from setting")
expect_equal(index_month$monthly_condition_pancreatitis, 1L, "monthly diagnosis prefixes should be matched")

baseline_row <- person_month[person_month$event_month == -1L, , drop = FALSE]
expect_equal(baseline_row$baseline_patient_oop, 5, "baseline OOP should use event months -12 through -1")
expect_equal(baseline_row$baseline_pay, 40, "baseline PAY should use event months -12 through -1")
expect_equal(baseline_row$baseline_any_dpp4, 1L, "baseline drug state should flag DPP-4 exposure")
expect_equal(baseline_row$baseline_medical_claims, 1L, "baseline medical claims should be counted")
expect_equal(baseline_row$baseline_condition_diabetes, 1L, "baseline diagnosis prefixes should be matched")

keys <- paste(person_month$enrollee_id, person_month$episode_id, person_month$event_month, sep = "\r")
expect_true(!anyDuplicated(keys), "person-month output should be unique by enrollee_id + episode_id + event_month")

cat("test_person_month.R passed\n")
