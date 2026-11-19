test_data <- test_data("input2_datamodel.rds")

# Write artefacts to a temporary folder instead of the working directory
artifacts_dir <- file.path(tempdir(), "artifacts")
dir.create(artifacts_dir, showWarnings = FALSE)
Sys.setenv(APP_ARTIFACTS_DIR = paste0(artifacts_dir, "/"))

test_that("isopleth levels are parsed, sorted and deduplicated", {
  expect_equal(parse_levels("0.5, 0.95"), c(0.5, 0.95))
  expect_equal(parse_levels(" 0.95 ,0.5,0.5"), c(0.5, 0.95))
  expect_equal(parse_levels("0.9"), 0.9)
  expect_equal(parse_levels(0.9), 0.9)
})

test_that("invalid isopleth levels stop the App", {
  expect_error(parse_levels(""), "No isopleth level")
  expect_error(parse_levels(NULL), "No isopleth level")
  expect_error(parse_levels("95"), "\"95\"")
  expect_error(parse_levels("0.5, abc"), "\"abc\"")
  expect_error(parse_levels("0"), "\"0\"")
  expect_error(parse_levels("1"), "\"1\"")
  expect_error(parse_levels("0.5,,0.9"), "Invalid isopleth level")
})

test_that("happy path", {
  actual <- rFunction(data = test_data, isopleth_levels = "0.5, 0.95")

  # Output: the input models and data, plus one UD per animal
  expect_named(actual, c("model", "uds", "data"))
  expect_identical(actual$model, test_data[[1]])
  expect_identical(actual$data, test_data[[2]])
  expect_named(actual$uds, c("Cilla", "Mvubu"))
  expect_true(all(vapply(actual$uds, inherits, logical(1), "UD")))

  # Contours: 2 animals x 2 levels, estimates only
  contours <- sf::st_read(file.path(artifacts_dir, "occurrence.gpkg"), quiet = TRUE)
  expect_named(contours, c("id", "level", "name", "geom"))
  expect_equal(nrow(contours), 4)
  expect_setequal(contours$level, c(0.5, 0.95))
  expect_true(all(contours$name == paste0(contours$id, " ", contours$level * 100, "% est")))

  expect_gt(file.size(file.path(artifacts_dir, "occurrence_plots.pdf")), 0)

  # Rasters: one per animal
  expect_setequal(
    zip::zip_list(file.path(artifacts_dir, "occurrence_uds.zip"))$filename,
    c("Cilla.tif", "Mvubu.tif")
  )
})

test_that("duplicate telemetry column names do not stop the App", {
  # occurrence() fails on duplicate column names, which some input data has.
  # See https://github.com/movestore/move2TOtelemetry/issues/7
  dup_data <- test_data
  n <- ncol(dup_data[[2]]$Cilla)
  dup_data[[2]]$Cilla$a <- 1
  dup_data[[2]]$Cilla$b <- 2
  names(dup_data[[2]]$Cilla)[c(n + 1, n + 2)] <- "dup"

  actual <- rFunction(data = dup_data, isopleth_levels = "0.95")

  expect_named(actual$uds, c("Cilla", "Mvubu"))
  # The output keeps the input data unchanged
  expect_identical(actual$data, dup_data[[2]])
})
