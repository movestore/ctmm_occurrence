# Estimate Occurrence Distribution (Kriging)

MoveApps

Github repository: https://github.com/ctmm-initiative/ctmmMoveApp_occurrence

## Description
This function calculates an occurrence distribution from telemetry data and a continuous-time movement model using Kriging. This means that it optimally infers the complete movement path from a limited sample of locations.

## Documentation
After fitting a continuous-time movement model, this app allows to reconstruct the path where the animal possibly went.

For details and background of the method please see the [publication](https://esajournals.onlinelibrary.wiley.com/doi/full/10.1890/15-1607.1) and the methods description in the [documentation of the occurance function](https://ctmm-initiative.github.io/ctmm/reference/occurrence.html) of the ctmm package. The occurrence distribution attempts to calculate the track of the animal, while the range distribution (i.e., the result of the aKDE app) calculates the long-term space use.

**ATTENTION**: The preceding App *`Fit a Continuous-Time Movement Model (ctmm)`* can have a long run time (hours). Consider pinning this app for further workflow runs. Subsequent apps like *`Autocorrelated Kernel Density Estimate (aKDE)`* and *`Estimate Occurrence Distribution (Kriging)`* with interactive user interface (once the app has run a button "OPEN APP UI" appears) can only be accessed for 8 hours (afterwards the "OPEN APP UI" is not visible anymore). To get again access to it, the workflow has to be run again. BUT before doing this, pin the workflow to the *`Fit a Continuous-Time Movement Model (ctmm)`* (menu at the top right corner of the App - *"Pin to this App"*) to avoid the long run time again. An app can only be pinned once it has run and produced results.

### Input data
The app requires a `ctmm model with data` as input. 


### Output data
`ctmm UD with Data and Model` including the occurrance distribution.

### Artefacts

`occurrence.gpkg`: A geopackage with the calculated occurrence distributions at the selected isopleths. 

`occurrence_uds.zip`: A zipped archive of individual occurrence distributions (saved as tifs). 

### Settings

`Isopleth level`: Coverage level of the utilization distribution area. 

`Opacity`: The opacity (or non-transparency) of the estimated home range on the map. 

`Remove all animals from map`: This button will remove all home-ranges from the map. They can be added individually again. 

`Store settings`: click to store the current settings of the app for future workflow runs

### Most common errors
Calculating of occurrence distribution can potentially take a long time if a lot of data points are available for an animal. 

### Null or error handling
Please file an issue [here](https://github.com/ctmm-initiative/ctmmMoveApp_occurrence/issues) if you repeatedly encounter a specific error.
