library(moveapps)
library(ctmm)
library(sf)
library(leaflet)

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

  # Time since `start`, for the log, e.g. "3.4 secs" or "2.1 mins"
  start <- Sys.time()
  elapsed <- function() format(round(Sys.time() - start, 1))

  logger.info(
    paste0(
      "Estimating occurrence distributions for ", length(telemetry),
      " animal(s) at isopleth level(s) ", paste(lvls, collapse = ", "),
      ". This can take a while for many animals or long tracks."
    )
  )

  occu <- occurrence(telemetry, models)
  logger.info(paste0("Occurrence distributions estimated after ", elapsed()))

  # Occurrence contour polygon artifact for all animal/level combinations
  logger.info("Computing occurrence contours")
  contours <- purrr::list_rbind(
    purrr::imap(occu, function(ud, id) animal_contours(ud, id, lvls))
  )
  logger.info(paste0("Occurrence contours computed after ", elapsed()))

  logger.info("Writing occurrence contours (occurrence.gpkg)")
  sf::st_write(
    contours,
    appArtifactPath("occurrence.gpkg"),
    append = FALSE,
    quiet = TRUE
  )

  logger.info("Writing plots (occurrence_plots.pdf)")
  write_pdf(appArtifactPath("occurrence_plots.pdf"), telemetry, occu, lvls)

  logger.info("Writing interactive map (occurrence_map.html)")
  write_map(appArtifactPath("occurrence_map.html"), contours, names(occu), lvls)

  # One UD raster artifact per animal
  logger.info("Writing UD rasters (occurrence_uds.zip)")
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
  logger.info(paste0("All artefacts written after ", elapsed()))

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

# Colour for each animal, used in the PDF overview pages and on the map
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
    plot(telemetry, UD = occu, level.UD = level,
         col = grDevices::adjustcolor(animal_cols, alpha.f = 0.4),
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

# Interactive map as standalone HTML file. Shows all animals at all requested
# isopleth levels. Animals can be toggled on and off.
write_map <- function(file, contours, ids, levels) {
  cols <- stats::setNames(animal_colors(length(ids)), ids)
  contours <- sf::st_transform(contours, 4326)

  # Round the coordinates to 5 decimals (about 1 m), which is plenty for the
  # map and roughly halves the size of the HTML file. Points that become
  # identical to the previous point are dropped.
  round_ring <- function(ring) {
    ring <- round(ring, digits = 5)
    ring[c(TRUE, rowSums(abs(diff(ring))) > 0), , drop = FALSE]
  }

  sf::st_geometry(contours) <- sf::st_sfc(
    lapply(
      sf::st_geometry(contours),
      function(geom) {
        sf::st_multipolygon(
          lapply(geom, function(polygon) lapply(polygon, round_ring))
        )
      }
    ),
    crs = 4326
  )

  # Hover labels for each animal's region
  contours$label <- paste0(contours$id, ", ", contours$level * 100, "% occurrence")

  # Starting map view
  bbox <- unname(sf::st_bbox(contours[contours$level == max(levels), ]))

  m <- leaflet(options = leafletOptions(zoomSnap = 0.25, zoomDelta = 0.5)) |>
    addProviderTiles(providers$Esri.WorldTopoMap, group = "World Topo Map") |>
    addProviderTiles(providers$Esri.WorldImagery, group = "World Imagery") |>
    fitBounds(bbox[1], bbox[2], bbox[3], bbox[4])

  # One layer group per animal, so animals can be toggled on/off. The largest
  # level is drawn first so that smaller contours sit on top of it.
  for (level in sort(levels, decreasing = TRUE)) {
    for (id in ids) {
      m <- m |>
        addPolygons(
          data = contours[contours$id == id & contours$level == level, ],
          group = id,
          label = ~label,
          color = cols[[id]],
          weight = 2,
          opacity = 1,
          fillColor = cols[[id]],
          fillOpacity = 0.2
        )
    }
  }

  m <- m |>
    addControl(
      html = paste0(
        "<b>Occurrence distribution</b><br>Shaded regions show the ",
        paste0(levels * 100, "%", collapse = ", "), " contour",
        if (length(levels) > 1) "s", "<br>Hover over a region for details"
      ),
      position = "topright"
    ) |>
    addLayersControl(
      baseGroups = c("World Topo Map", "World Imagery"),
      overlayGroups = ids,
      options = layersControlOptions(collapsed = FALSE)
    ) |>
    addLegend(
      position = "bottomright",
      colors = unname(cols),
      labels = ids,
      opacity = 1
    ) |>
    addEasyButton(easyButton(
      icon = "<span>Zoom to extent</span>",
      title = "Zoom to all occurrence distributions",
      onClick = JS(
        sprintf(
          "function(btn, map) { map.fitBounds([[%f, %f], [%f, %f]]); }",
          bbox[2], bbox[1], bbox[4], bbox[3]
        )
      )
    )) |>
    # Larger text in the panels than leaflet's default (12px for the layer
    # menu, 14px for the title and legend boxes), for readability. Leaflet's
    # buttons are fixed squares, so the text button is widened to fit its label.
    htmlwidgets::prependContent(htmltools::tags$style(
      ".leaflet-control-layers, .leaflet-control.info { font-size: 16px; line-height: 1.4; }",
      ".easy-button-button { width: auto !important; padding: 0 8px; font-size: 14px; }"
    ))

  # saveWidget() can leave a folder of JavaScript libraries next to the file,
  # even though they are embedded in it. Save to a temporary folder so that
  # only the HTML file ends up with the artefacts.
  tmp_file <- file.path(tempfile("map"), "occurrence_map.html")
  dir.create(dirname(tmp_file))
  htmlwidgets::saveWidget(m, tmp_file, selfcontained = TRUE, title = "Occurrence distributions")
  file.copy(tmp_file, file, overwrite = TRUE)
  unlink(dirname(tmp_file), recursive = TRUE)
}
