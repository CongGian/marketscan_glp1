suppressPackageStartupMessages(library(testthat))

enrollment_path <- if (file.exists(file.path("R", "enrollment.R"))) {
  file.path("R", "enrollment.R")
} else {
  file.path("..", "R", "enrollment.R")
}
source(enrollment_path)

test_that("continuous enrollment flags full baseline and follow-up windows", {
  enrollment <- data.frame(
    ENROLID = c("P001", "P002"),
    DTSTART = as.Date(c("2020-07-01", "2021-01-01")),
    DTEND = as.Date(c("2022-07-31", "2022-07-31")),
    RX = c("1", "1"),
    stringsAsFactors = FALSE
  )
  std <- standardize_enrollment(enrollment)
  index <- data.frame(
    enrollee_id = c("P001", "P002"),
    index_date = as.Date(c("2021-07-01", "2021-07-01")),
    stringsAsFactors = FALSE
  )

  checked <- check_continuous_enrollment(index, std)
  expect_equal(checked$continuous_enrollment, c(TRUE, FALSE))
  expect_equal(checked$required_enrollment_start[1], as.Date("2020-07-01"))
  expect_equal(checked$required_enrollment_end[1], as.Date("2022-07-31"))
})

test_that("adjacent monthly enrollment spans are merged", {
  enrollment <- data.frame(
    ENROLID = c("P001", "P001", "P001"),
    DTSTART = as.Date(c("2021-01-01", "2021-02-01", "2021-04-01")),
    DTEND = as.Date(c("2021-01-31", "2021-02-28", "2021-04-30")),
    RX = c("1", "1", "1"),
    stringsAsFactors = FALSE
  )
  std <- standardize_enrollment(enrollment)
  spells <- merge_enrollment_spans(std)

  expect_equal(nrow(spells), 2L)
  expect_equal(spells$spell_start[1], as.Date("2021-01-01"))
  expect_equal(spells$spell_end[1], as.Date("2021-02-28"))
})

test_that("inactive pharmacy benefit rows can be excluded", {
  enrollment <- data.frame(
    ENROLID = "P001",
    DTSTART = as.Date("2020-07-01"),
    DTEND = as.Date("2022-07-31"),
    RX = "0",
    stringsAsFactors = FALSE
  )
  std <- standardize_enrollment(enrollment)
  spells <- merge_enrollment_spans(std, require_rx = TRUE)
  expect_equal(nrow(spells), 0L)
})
