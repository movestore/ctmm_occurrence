library(shiny)
library(ctmm)
library(sf)
library(dplyr)
library(purrr)
library(leaflet)
library(zip)
library(shinycssloaders)
library(leafem)

# Default isopleth level. Used for the slider and whenever the slider has no
# value, e.g. when the App runs in a workflow without its UI being opened.
default_level <- 0.95

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

shinyModuleUserInterface <- function(id, label) {
  ns <- NS(id) ## all IDs of UI functions need to be wrapped in ns()
  tagList(
    titlePanel("Occurrence distribution"),
    fluidRow(
      column(6,
             sliderInput(
               ns("isopleth_levels"),
               "Isopleth level:",
               min = 0.01, max = .99, value = default_level
             ),
      ), 
      column(6, 
             sliderInput(ns("opacity"), "Opacity", min = 0, max = 1, value = 0.5),
             div(
               style = "display: flex; flex-wrap: wrap; gap: 6px;",
               actionButton(ns("add_all"), label = "Add all animals to map", class = "btn-sm"),
               actionButton(ns("clear"), label = "Remove all animals from map", class = "btn-sm")
             )
      )
    ),
    hr(),
    shinycssloaders::withSpinner(leafletOutput(ns("map"), height = "800"))
  )
}

shinyModule <- function(input, output, session, data){ ## The parameter "data" is reserved for the data object passed on from the previous app
  ns <- session$ns ## all IDs of UI functions need to be wrapped in ns()
  
  # Ensure all telemetry columns are valid and unique. See
  # https://github.com/movestore/move2TOtelemetry/issues/7
  telemetry <- map(
    data[[2]],
    function(x) {
      names(x) <- make.names(names(x), unique = TRUE)
      x
    }
  )

  occu <- occurrence(telemetry, data[[1]])
  bbx <- map(occu, ~ st_as_sf(ctmm::SpatialPolygonsDataFrame.UD(.x, level.UD = 0.97)) |> 
               st_transform(4326)) |> 
    map(st_bbox)
  bbx <- do.call(rbind, bbx)
  
  # Selected isopleth level, or the default if the UI has not been opened
  level <- reactive(input$isopleth_levels %||% default_level)

  # Occurrence contours at the chosen isopleth level: a list with one sf
  # object per animal, in the same order and with the same names as occu
  occu.iso <- reactive({
    map(occu, ~ ud_contours(.x, level.UD = level()))
  })

  # Artefact: occurrence contours as a geopackage. Written independently of
  # the map so that it is produced even if the UI is never opened.
  observe({
    occu.iso() |>
      bind_rows() |>
      sf::st_write(appArtifactPath("occurrence.gpkg"), append = FALSE)
  })

  # The same contours in longitude/latitude for the map
  occu.leaflet <- reactive({
    map(occu.iso(), ~ st_transform(.x, 4326))
  })
  
  output$map <- renderLeaflet({
    leaflet() |> 
      addTiles(group = "OSM") |> 
      addProviderTiles(providers$Esri.WorldImagery,
                       options = providerTileOptions(noWrap = TRUE), group = "World Imagery") |>
      fitBounds(min(bbx[, 1]), min(bbx[, 2]), max(bbx[, 3]), max(bbx[, 4])) |>
      addHomeButton(
        ext = c(min(bbx[, 1]), min(bbx[, 2]), max(bbx[, 3]), max(bbx[, 4])),
        group = "Full extent", position = "bottomleft")
    
  })
  
  cols <- rainbow(length(occu))
  
  observe({
    # Wait for the opacity slider, which only has a value once the UI is open
    req(input$opacity)
    m <- leafletProxy("map") |> 
      clearShapes() |> 
      clearControls()
    for (i in 1:length(occu.leaflet())) {
      m <- m |> addPolygons(data = occu.leaflet()[[i]],
                            group = names(occu.leaflet())[i],
                            label = ~name,
                            color = cols[i],
                            fillColor = cols[i],
                            fillOpacity = input$opacity)
    }
    
    
    m |> 
      addLayersControl(
        baseGroups = c("OSM", "World Imagery"),
        overlayGroups = names(occu.leaflet()),
        options = layersControlOptions(collapsed = TRUE)
      ) |> 
      addLegend(
        position = "bottomright",
        colors = cols,
        labels  = names(occu))  
    
  })
  # The two buttons are left out of saved settings. Otherwise restoring them
  # would count as a click and hide or show the animals when the App opens.
  setBookmarkExclude(c("add_all", "clear"))
  observeEvent(input$add_all, {
    leafletProxy("map") |>
      showGroup(names(occu.leaflet()))
  })
  observeEvent(input$clear, {
    leafletProxy("map") |> 
      hideGroup(names(occu.leaflet()))
  })
  
  
  # Artefact: tifs
  targetDirUDs <- tempfile("uds")
  dir.create(targetDirUDs)
  
  r <- lapply(names(occu), function(x) 
    writeRaster(occu[[x]], file.path(targetDirUDs, paste0(x, ".tif")), overwrite = TRUE))
  
  zip::zip(
    zipfile = appArtifactPath("occurrence_uds.zip"),
    files = list.files(targetDirUDs, full.names = TRUE, pattern = "tif$"),
    mode = "cherry-pick"
  )
  
  return(reactive({
    list(model = data[[1]], uds = occu, data = data[[2]])
  }))
}
