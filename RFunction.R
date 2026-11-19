library(moveapps)
library(ctmm)
library(sf)

rFunction <- function(data, isopleth_levels) {
  lvls <- parse_levels(isopleth_levels)

  models <- data[[1]]

  # Ensure all telemetry columns are valid and unique. See
  # https://github.com/movestore/move2TOtelemetry/issues/7
  # (Only the copy passed to occurrence() is changed; the output keeps the
  # input data as it was.)
  telemetry <- purrr::map(
    data[[2]],
    function(x) {
      names(x) <- make.names(names(x), unique = TRUE)
      x
    }
  )

  logger.info(
    paste0(
      "Estimating occurrence distributions for ", length(telemetry),
      " animal(s) at isopleth level(s) ", paste(lvls, collapse = ", ")
    )
  )

  occu <- occurrence(telemetry, models)

  # Occurrence contour polygon artifact for all animal/level combinations
  contours <- purrr::list_rbind(
    purrr::imap(occu, function(ud, id) animal_contours(ud, id, lvls))
  )

  sf::st_write(
    contours,
    appArtifactPath("occurrence.gpkg"),
    append = FALSE,
    quiet = TRUE
  )

  write_pdf(appArtifactPath("occurrence_plots.pdf"), telemetry, occu, lvls)

  # One UD raster artifact per animal
  targetDirUDs <- tempfile("uds")
  dir.create(targetDirUDs)

  purrr::walk(
    names(occu),
    function(id) {
      writeRaster(
        occu[[id]],
        file.path(targetDirUDs, paste0(id, ".tif")),
        overwrite = TRUE
      )
    }
  )

  zip::zip(
    zipfile = appArtifactPath("occurrence_uds.zip"),
    files = list.files(targetDirUDs, full.names = TRUE, pattern = "tif$"),
    mode = "cherry-pick"
  )

  list(model = models, uds = occu, data = data[[2]])
}


# Convert isopleth level setting (comma delimited string) into a sorted
# vector of unique numbers. Stops with a message if any value is not a number
# strictly between 0 and 1.
parse_levels <- function(isopleth_levels) {
  if (is.null(isopleth_levels) || all(trimws(isopleth_levels) == "")) {
    stop("No isopleth level given. Enter one or more levels between 0 and 1, ",
         "separated by commas (e.g. \"0.5, 0.95\").", call. = FALSE)
  }

  parts <- trimws(unlist(strsplit(as.character(isopleth_levels), ",")))
  levels <- suppressWarnings(as.numeric(parts))

  bad <- parts[is.na(levels) | levels <= 0 | levels >= 1]

  if (length(bad) > 0) {
    stop("Invalid isopleth level(s): ", paste0("\"", bad, "\"", collapse = ", "),
         ". Each level must be a number between 0 and 1, separated by commas ",
         "(e.g. \"0.5, 0.95\"). For a 95% contour, enter 0.95, not 95.",
         call. = FALSE)
  }

  sort(unique(levels))
}

# Generate contour polygons for the occurrence distribution at the given
# isopleth level. This ensures that internal holes within the distribution
# contours are correctly left unfilled. At the time of writing, there is a bug
# in ctmm (1.3.x) that does not mark these holes correctly, meaning that the
# entire region within the external contour is filled.
ud_contours <- function(ud, level.UD) {
  spdf <- ctmm::SpatialPolygonsDataFrame.UD(ud, level.UD = level.UD)

  # Use even-odd rule to identify holes. Contour rings are nested by definition,
  # so the symmetric difference of all rings keeps the area inside an odd
  # number of rings and drops the areas inside an even number (holes).
  geometries <- lapply(spdf@polygons, function(contour) {
    rings <- lapply(contour@Polygons, function(ring) sf::st_polygon(list(ring@coords)))
    geom <- Reduce(sf::st_sym_difference, rings)

    # Rings that touch can leave zero-width line fragments in the result.
    # Keep only the polygon parts.
    if (inherits(geom, "GEOMETRYCOLLECTION")) {
      geom <- sf::st_union(sf::st_collection_extract(sf::st_sfc(geom), "POLYGON"))[[1]]
    }

    sf::st_cast(geom, "MULTIPOLYGON")
  })

  # Rebuild output to mirror `ctmm::SpatialPolygonsDataFrame.UD()` structure.
  # Contour names are the ctmm polygon `ID` values.
  sf::st_sf(
    name = vapply(spdf@polygons, function(contour) contour@ID, character(1)),
    geometry = sf::st_sfc(geometries, crs = sf::st_crs(spdf@proj4string))
  )
}

# Get contours of one animal's UD at each isopleth level, one row per level.
animal_contours <- function(ud, id, levels) {
  lvl_contours <- purrr::map(
    levels,
    function(lvl) {
      contours <- ud_contours(ud, level.UD = lvl)

      contours$id <- id
      contours$level <- lvl
      contours[, c("id", "level", "name")]
    }
  )

  purrr::list_rbind(lvl_contours)
}

# Colors for the contours at each isopleth level, from the smallest to the
# largest level. Part of the viridis palette, from teal (inner contours) to
# dark purple (outer contour). The largest level always gets dark purple, so a
# single contour is drawn in the most visible colour. Stops at teal because
# lighter viridis palette colors are hard to make out on white background.
contour_colors <- function(n) {
  grDevices::hcl.colors(100, "viridis")[rev(round(seq(5, 55, length.out = n)))]
}

# Colour for each animal, used in the PDF overview pages
animal_colors <- function(n) {
  grDevices::hcl.colors(n, palette = "Dark 3")
}

# Legend of animal colours for the side panel of an overview page
animal_legend <- function(ids, cols) {
  par(mar = c(0, 0, 4.1, 0))
  plot.new()
  legend("topleft", legend = ids, col = cols, pch = 19, bty = "n",
         ncol = ceiling(length(ids) / 25),
         cex = if (length(ids) > 25) 0.7 else 1)
}

# Legend of contour colours for the side panel of an animal's page
level_legend <- function(levels) {
  par(mar = c(0, 0, 4.1, 0))
  plot.new()
  legend("topleft", legend = paste0(levels * 100, "% contour"),
         col = contour_colors(length(levels)), lwd = 3, bty = "n",
         title = "Occurrence distribution", title.font = 2, title.adj = 0)
}

# PDF summary artifact. One page per isopleth level with all animals together,
# then one page per animal with all levels overlaid onto its occurrence
# density gradient.
write_pdf <- function(file, telemetry, occu, levels) {
  animal_cols <- animal_colors(length(occu))
  plot_mar <- c(5.1, 4.1, 4.1, 2.1)

  pdf(file, width = 11, height = 7.5)
  on.exit(dev.off())
  layout(matrix(1:2, nrow = 1), widths = c(3, 1))

  for (level in levels) {
    par(mar = plot_mar)
    plot(telemetry, UD = occu, level.UD = level, col = animal_cols,
         col.UD = animal_cols, col.level = animal_cols, col.grid = NA)
    title(paste0("All animals: ", level * 100, "% occurrence distribution"))
    animal_legend(names(occu), animal_cols)
  }

  for (id in names(occu)) {
    par(mar = plot_mar)
    # The locations are drawn in a second call. ctmm sizes the location error
    # circles from level.UD, and with several levels it mixes their values up
    # across the locations (with R warnings). A second call with the default
    # single level draws the circles as in any standard ctmm plot.
    plot(telemetry[[id]], UD = occu[[id]], level.UD = levels, col = NA, error = FALSE,
         col.UD = "grey45", col.level = contour_colors(length(levels)), lwd.level = 2)
    plot(telemetry[[id]], col = "black", add = TRUE)
    title(id)
    level_legend(levels)
  }
}
