#' Data ingest
#'
#' Ingests data for site scale simulations with rsofun (or any other Dynamic Vegetation Model).
#'
#' @param siteinfo A data frame containing site meta info. Required columns are: \code{"sitename", "date_start", "date_end", "lon", "lat", "elv"}.
#' @param source A character used as identifiyer for the type of data source
#' (e.g., \code{"fluxnet"}). See vignette for a full description of available options.
#' @param getvars A named list of characters specifying the variable names in
#' the source dataset corresponding to standard names \code{"temp"} for temperature,
#' \code{"prec"} for precipitation, \code{"patm"} for atmospheric pressure,
#' \code{"vpd"} for vapour pressure deficit, \code{"netrad"} for net radiation,
#' \code{"swin"} for shortwave incoming radiation.
#' @param dir A character specifying the directory where data is located.
#' @param settings A list of additional settings used for reading original files.
#' @param timescale A character or vector of characters, specifying the time scale of data used from
#' the respective source (if multiple time scales are available, otherwise is disregarded).
#' @param parallel A logical specifying whether ingest is run as parallel jobs for each site. This option is
#' only available for \code{source = "modis"} and requires argument \code{ncores} to be set.
#' @param ncores An integer specifying the number of cores for parallel runs of ingest per site. Required only
#' if \code{parallel = TRUE}
#' @param verbose if \code{TRUE}, additional messages are printed.
#'
#' @return A named list of data frames (tibbles) containing input data for each site is returned.
#' @import purrr dplyr
#' @export
#'
#' @examples inputdata <- prepare_input_sofun( settings_input = settings_input, settings_sims = settings_sims, overwrite_climate = FALSE, verbose = TRUE )
#'
ingest <- function(
	siteinfo,
	source,
	getvars,
	dir,
	settings  = NULL,
	timescale = "d",
	parallel  = FALSE,
	ncores    = NULL,
	verbose   = FALSE
  ){

  if (!(source %in% c("hwsd", "etopo1", "wwf", "soilgrids", "wise", "gsde", "worldclim"))){

    ## complement dates information
    if (!("year_start" %in% names(siteinfo))){
      if ("date_start" %in% names(siteinfo)){
        siteinfo <- siteinfo %>%
          mutate(year_start = lubridate::year(date_start))
      } else {
        rlang::abort("ingest(): Columns 'year_start' and 'date_start' missing in object provided by argument 'siteinfo'")
      }
    }
    if (!("year_end" %in% names(siteinfo))){
      if ("date_end" %in% names(siteinfo)){
        siteinfo <- siteinfo %>%
          mutate(year_end = lubridate::year(date_end))
      } else {
        rlang::abort("ingest(): Columns 'year_end' and 'date_end' missing in object provided by argument 'siteinfo'")
      }
    }

    if (!("date_start" %in% names(siteinfo))){
      if ("year_start" %in% names(siteinfo)){
        siteinfo <- siteinfo %>%
          mutate(date_start = lubridate::ymd(paste0(as.character(year_start), "-01-01")))
      } else {
        rlang::abort("ingest(): Columns 'year_start' and 'date_start' missing in object provided by argument 'siteinfo'")
      }
    }
    if (!("date_end" %in% names(siteinfo))){
      if ("year_end" %in% names(siteinfo)){
        siteinfo <- siteinfo %>%
          mutate(date_end = lubridate::ymd(paste0(as.character(year_end), "-12-31")))
      } else {
        rlang::abort("ingest(): Columns 'year_end' and 'date_end' missing in object provided by argument 'siteinfo'")
      }
    }

  }

	if (source == "fluxnet"){
	  #-----------------------------------------------------------
	  # Get data from sources given by site
	  #-----------------------------------------------------------
		ddf <- purrr::map(
		  as.list(seq(nrow(siteinfo))),
		  ~ingest_bysite( siteinfo$sitename[.],
											source                     = source,
											getvars                    = getvars,
											dir                        = dir,
											settings                   = settings,
											timescale                  = timescale,
											year_start                 = lubridate::year(siteinfo$date_start[.]),
											year_end                   = lubridate::year(siteinfo$date_end[.]),
											verbose                    = verbose
		  )
		) %>%
		bind_rows()


	} else if (source == "cru" || source == "watch_wfdei" || source == "ndep"){
	  #-----------------------------------------------------------
	  # Get data from global fields
	  #-----------------------------------------------------------
		# if (settings$correct_bias == "worldclim"){
		#   if (source == "watch_wfdei"){
		#     rlang::inform("Beware: WorldClim data is for years 1970-2000. Therefore WATCH_WFDEI data is ingested for 1979-(at least) 2000.")
		#     siteinfo <- siteinfo %>%
		#     	mutate(year_start = 1979, 
		#     				 year_end = ifelse(year_end > 2000, year_end, 2000))
		#   }
		# }

		## this returns a flat data frame with data from all sites
    ddf <- ingest_globalfields(siteinfo,
                               source = source,
                               dir = dir,
                               getvars = getvars,
                               timescale = timescale,
                               verbose = FALSE
    )

    ## bias-correct atmospheric pressure - per default
    if ("patm" %in% getvars){

      df_patm_base <- siteinfo %>%
      	dplyr::select(sitename, elv) %>%
      	mutate(patm_base = calc_patm(elv))

      df_patm_mean <- ddf %>% 
      	group_by(sitename) %>%
        summarise(patm_mean = mean(patm, na.rm = TRUE)) %>%
        left_join(df_patm_base, by = "sitename") %>%
        mutate(scale = patm_base / patm_mean) %>%
        right_join(ddf, by = "sitename") %>%
        mutate(patm = patm * scale) %>% 
        dplyr::select(-patm_base, -elv, -patm_mean, -scale)

    }
    
    if (!identical(NULL, settings$correct_bias)){
      
      if (settings$correct_bias == "worldclim"){
        #-----------------------------------------------------------
        # Bias correction using WorldClim data
        #-----------------------------------------------------------
        getvars_wc <- c()
        if ("temp" %in% getvars){getvars_wc <- c(getvars_wc, "tavg")}
        if ("prec" %in% getvars){getvars_wc <- c(getvars_wc, "prec")}
        if ("ppfd" %in% getvars){getvars_wc <- c(getvars_wc, "srad")}
        if ("wind" %in% getvars){getvars_wc <- c(getvars_wc, "wind")}
        if ("vpd" %in% getvars){getvars_wc <- c(getvars_wc, "vapr")}
        
        df_fine <- ingest_globalfields(siteinfo,
                                       source = "worldclim",
                                       dir = settings$dir_bias,
                                       getvars = NULL,
                                       timescale = NULL,
                                       verbose = FALSE,
                                       layer = getvars_wc
        )
        
        ## Bias correction for temperature: substract difference
        if ("tavg" %in% getvars_wc){
          df_bias <- df_fine %>% 
            pivot_longer(cols = starts_with("tavg_"), names_to = "month", values_to = "tavg", names_prefix = "tavg_") %>% 
            mutate(month = as.integer(month)) %>% 
            rename(temp_fine = tavg) %>% 
            right_join(ddf %>% 
                         mutate(month = lubridate::month(date)) %>% 
                         group_by(sitename, month) %>% 
                         summarise(temp = mean(temp, na.rm = TRUE)),
                       by = c("sitename", "month")) %>% 
            mutate(bias = temp - temp_fine) %>% 
            dplyr::select(-temp, -temp_fine)
          
          ## correct bias by month
          ddf <- ddf %>% 
            mutate(month = lubridate::month(date)) %>% 
            left_join(df_bias %>% dplyr::select(sitename, month, bias), by = c("sitename", "month")) %>% 
            mutate(temp = temp - bias) %>% 
            dplyr::select(-bias, -month)
        }
        
        ## Bias correction for precipitation: scale by ratio (snow and rain equally)
        if ("prec" %in% getvars_wc){
          df_bias <- df_fine %>% 
            pivot_longer(cols = starts_with("prec_"), names_to = "month", values_to = "prec", names_prefix = "prec_") %>% 
            mutate(month = as.integer(month)) %>% 
            rename(prec_fine = prec) %>% 
            mutate(prec_fine = prec_fine / days_in_month(month)) %>%   # mm/month -> mm/d
            mutate(prec_fine = prec_fine / (60 * 60 * 24)) %>%         # mm/d -> mm/sec
            right_join(ddf %>% 
                         mutate(month = lubridate::month(date)) %>% 
                         group_by(sitename, month) %>% 
                         summarise(prec = mean(prec, na.rm = TRUE)),
                       by = c("sitename", "month")) %>% 
            mutate(scale = prec_fine / prec) %>% 
            dplyr::select(-prec, -prec_fine)
          
          ## correct bias by month
          ddf <- ddf %>% 
            mutate(month = lubridate::month(date)) %>% 
            left_join(df_bias %>% dplyr::select(sitename, month, scale), by = c("sitename", "month")) %>% 
            mutate(prec = prec * scale, rain = rain * scale, snow = snow * scale) %>% 
            dplyr::select(-scale, -month)
        }
        
        ## Bias correction for shortwave radiation: scale by ratio
        if ("srad" %in% getvars_wc){
          kfFEC <- 2.04
          df_bias <- df_fine %>% 
            pivot_longer(cols = starts_with("srad_"), names_to = "month", values_to = "srad", names_prefix = "srad_") %>% 
            mutate(month = as.integer(month)) %>% 
            rename(srad_fine = srad) %>% 
            mutate(ppfd_fine = 1e3 * srad_fine * kfFEC * 1.0e-6 / (60 * 60 * 24) ) %>%   # kJ m-2 day-1 -> mol m−2 s−1 PAR
            right_join(ddf %>% 
                         mutate(month = lubridate::month(date)) %>% 
                         group_by(sitename, month) %>% 
                         summarise(ppfd = mean(ppfd, na.rm = TRUE)),
                       by = c("sitename", "month")) %>% 
            mutate(scale = ppfd_fine / ppfd) %>% 
            dplyr::select(-srad_fine, -ppfd_fine, -ppfd)
          
          ## correct bias by month
          ddf <- ddf %>% 
            mutate(month = lubridate::month(date)) %>% 
            left_join(df_bias %>% dplyr::select(sitename, month, scale), by = c("sitename", "month")) %>% 
            mutate(ppfd = ppfd * scale) %>% 
            dplyr::select(-scale, -month)
        }
        
        ## Bias correction for atmospheric pressure: scale by ratio
        if ("wind" %in% getvars_wc){
          df_bias <- df_fine %>% 
            pivot_longer(cols = starts_with("wind_"), names_to = "month", values_to = "wind", names_prefix = "wind_") %>% 
            mutate(month = as.integer(month)) %>% 
            rename(wind_fine = wind) %>% 
            right_join(ddf %>% 
                         mutate(month = lubridate::month(date)) %>% 
                         group_by(sitename, month) %>% 
                         summarise(wind = mean(wind, na.rm = TRUE)),
                       by = c("sitename", "month")) %>% 
            mutate(scale = wind_fine / wind) %>% 
            dplyr::select(-wind_fine, -wind)
          
          ## correct bias by month
          ddf <- ddf %>% 
            mutate(month = lubridate::month(date)) %>% 
            left_join(df_bias %>% dplyr::select(sitename, month, scale), by = c("sitename", "month")) %>% 
            mutate(wind = wind * scale) %>% 
            dplyr::select(-scale, -month)
        }
        
        ## Bias correction for relative humidity (actually vapour pressure): scale
        if ("vapr" %in% getvars_wc){
          
          ## calculate vapour pressure from specific humidity - needed for bias correction with worldclim data
          ddf <- ddf %>% 
            rowwise() %>% 
            dplyr::mutate(vapr = calc_vp(qair = qair, tc = temp, patm = patm)) %>% 
            ungroup()
          
          df_bias <- df_fine %>% 
            pivot_longer(cols = starts_with("vapr_"), names_to = "month", values_to = "vapr", names_prefix = "vapr_") %>% 
            mutate(month = as.integer(month)) %>% 
            rename(vapr_fine = vapr) %>% 
            mutate(vapr_fine = vapr_fine * 1e3) %>%   # kPa -> Pa
            right_join(ddf %>% 
                         mutate(month = lubridate::month(date)) %>% 
                         group_by(sitename, month) %>% 
                         summarise(vapr = mean(vapr, na.rm = TRUE)),
                       by = c("sitename", "month")) %>% 
            mutate(scale = vapr_fine / vapr) %>% 
            dplyr::select(-vapr_fine, -vapr)
          
          ## correct bias by month
          ddf <- ddf %>% 
            mutate(month = lubridate::month(date)) %>% 
            left_join(df_bias %>% dplyr::select(sitename, month, scale), by = c("sitename", "month")) %>% 
            mutate(vapr = vapr * scale) %>% 
            dplyr::select(-scale, -month)
        }      
        
        
        ## Calculate vapour pressure deficit from specific humidity
        if ("vpd" %in% getvars){
          ddf <- ddf %>%
            rowwise() %>%
            dplyr::mutate(vpd = calc_vpd(eact = vapr, tc = temp, patm = patm)) %>% 
            ungroup()
        }
        
      }
      
    }

	} else if (source == "gee"){
	  #-----------------------------------------------------------
	  # Get data from the remote server
	  #-----------------------------------------------------------
	  ## Define years covered based on site meta info:
	  ## take all years used for at least one site.
	  year_start <- siteinfo %>%
	    pull(year_start) %>%
	    min()

	  year_end <- siteinfo %>%
	    pull(year_end) %>%
	    max()

	  ddf <- purrr::map(
	    as.list(seq(nrow(siteinfo))),
	    ~ingest_gee_bysite(
	      slice(siteinfo, .),
	      start_date           = paste0(as.character(year_start), "-01-01"),
	      end_date             = paste0(as.character(year_end), "-12-31"),
	      overwrite_raw        = settings$overwrite_raw,
	      overwrite_interpol   = settings$overwrite_interpol,
	      band_var             = settings$band_var,
	      band_qc              = settings$band_qc,
	      prod                 = settings$prod,
	      prod_suffix          = settings$prod_suffix,
	      varnam               = settings$varnam,
	      productnam           = settings$productnam,
	      scale_factor         = settings$scale_factor,
	      period               = settings$period,
	      python_path          = settings$python_path,
	      gee_path             = settings$gee_path,
	      data_path            = settings$data_path,
	      method_interpol      = settings$method_interpol,
	      keep                 = settings$keep
	    )
	  )

	} else if (source == "modis"){
	  #-----------------------------------------------------------
	  # Get data from the remote server
	  #-----------------------------------------------------------
		if (parallel){

			if (is.null(ncores)) rlang::abort(paste("Aborting. Please provide number of cores for parallel jobs."))

	    cl <- multidplyr::new_cluster(ncores) %>%
	      multidplyr::cluster_assign(settings = settings) %>%
	      multidplyr::cluster_library(c("dplyr", "purrr", "rlang", "ingestr", "readr", "lubridate", "MODISTools", "tidyr"))

		  ## distribute to cores, making sure all data from a specific site is sent to the same core
		  ddf <- tibble(ilon = seq(nrow(siteinfo))) %>%
		    multidplyr::partition(cl) %>%
		    dplyr::mutate(data = purrr::map( ilon,
		                                    ~ingest_modis_bysite(
		                                    	slice(siteinfo, .),
				      														settings))) %>%
		    collect() %>%
		    tidyr::unnest(data)

		} else {

		  ddf <- purrr::map(
		    as.list(seq(nrow(siteinfo))),
		    ~ingest_modis_bysite(
		      slice(siteinfo, .),
		      settings
		      )
		  	)

		}


	} else if (source == "co2_mlo"){
	  #-----------------------------------------------------------
	  # Get CO2 data year, independent of site
	  #-----------------------------------------------------------
	  df_co2 <- climate::meteo_noaa_co2() %>%
	    dplyr::select(yy, co2_avg) %>%
	    dplyr::rename(year = yy) %>%
	    group_by(year) %>%
	    summarise(co2_avg = mean(co2_avg, na.rm = TRUE))

	  ddf <- purrr::map(
	    as.list(seq(nrow(siteinfo))),
	    ~expand_co2_bysite(
	      df_co2,
	      sitename = siteinfo$sitename[.],
	      year_start = lubridate::year(siteinfo$date_start[.]),
	      year_end   = lubridate::year(siteinfo$date_end[.])
	      )
	    )


	} else if (source == "fapar_unity"){
	  #-----------------------------------------------------------
	  # Assume fapar = 1 for all dates
	  #-----------------------------------------------------------
	  ddf <- purrr::map(
	    as.list(seq(nrow(siteinfo))),
	    ~expand_bysite(
	      sitename = siteinfo$sitename[.],
	      year_start = lubridate::year(siteinfo$date_start[.]),
	      year_end   = lubridate::year(siteinfo$date_end[.])
	      ) %>%
	      mutate(fapar = 1.0)
	  )

	} else if (source == "etopo1"){
	  #-----------------------------------------------------------
	  # Get ETOPO1 elevation data. year_start and year_end not required
	  #-----------------------------------------------------------
	  ddf <- ingest_globalfields(siteinfo,
	                             source = source,
	                             dir = dir,
	                             getvars = NULL,
	                             timescale = NULL,
	                             verbose = FALSE
	  )

	} else if (source == "hwsd"){
	  #-----------------------------------------------------------
	  # Get HWSD soil data. year_start and year_end not required
	  #-----------------------------------------------------------
	  con <- rhwsd::get_hwsd_con()
	  ddf <- rhwsd::get_hwsd_siteset(x = dplyr::select(siteinfo, sitename, lon, lat), con = con, hwsd.bil = settings$fil ) %>%
	    dplyr::ungroup() %>%
	    dplyr::select(sitename, data) %>%
	    tidyr::unnest(data)

	} else if (source == "wwf"){
	  #-----------------------------------------------------------
	  # Get WWF ecoregion data. year_start and year_end not required
	  #-----------------------------------------------------------
	  ddf <- ingest_globalfields(siteinfo,
	                             source = source,
	                             dir = dir,
	                             getvars = NULL,
	                             timescale = NULL,
	                             verbose = FALSE,
	                             layer = settings$layer
	  )

	} else if (source == "soilgrids"){
	  #-----------------------------------------------------------
	  # Get SoilGrids soil data. year_start and year_end not required
	  # Code from https://git.wur.nl/isric/soilgrids/soilgrids.notebooks/-/blob/master/markdown/xy_info_from_R.md
	  #-----------------------------------------------------------
	  ddf <- purrr::map_dfr(
	    as.list(seq(nrow(siteinfo))),
	    ~ingest_soilgrids_bysite(
	      siteinfo$sitename[.], 
	      siteinfo$lon[.], 
	      siteinfo$lat[.],
	      settings
	      )
	    ) %>% 
	    unnest(data)

	} else if (source == "wise"){
	  #-----------------------------------------------------------
	  # Get WISE30secs soil data. year_start and year_end not required
	  #-----------------------------------------------------------
	  ddf <- purrr::map_dfc(as.list(settings$varnam), ~ingest_wise_byvar(., siteinfo, layer = settings$layer, dir = dir))

	  if (length(settings$varnam) > 1){
	    ddf <- ddf %>%
	      rename(lon = lon...1, lat = lat...2) %>%
	      dplyr::select(-starts_with("lon..."), -starts_with("lat...")) %>%
	      right_join(dplyr::select(siteinfo, sitename, lon, lat), by = c("lon", "lat")) %>%
	      dplyr::select(-lon, -lat)

	  } else {
	    ddf <- ddf %>%
	      right_join(dplyr::select(siteinfo, sitename, lon, lat), by = c("lon", "lat")) %>%
	      dplyr::select(-lon, -lat)

	  }

	} else if (source == "gsde"){
	  #-----------------------------------------------------------
	  # Get GSDE soil data from tif files (2 files, for bottom and top layers)
	  #-----------------------------------------------------------
	  aggregate_layers <- function(df, varnam, layer){
	    
	    df_layers <- tibble(layer = 1:8, bottom = c(4.5, 9.1, 16.6, 28.9, 49.3, 82.9, 138.3, 229.6)) %>% 
	      mutate(top = lag(bottom)) %>% 
	      mutate(top = ifelse(is.na(top), 0, top)) %>% 
	      rowwise() %>% 
	      mutate(depth = bottom - top) %>% 
	      dplyr::select(-top, -bottom)
	    
	    z_tot_use <- df_layers %>%
	      ungroup() %>% 
	      dplyr::filter(layer %in% settings$layer) %>%
	      summarise(depth_tot_cm = sum(depth)) %>%
	      pull(depth_tot_cm)
	    
	    ## weighted sum, weighting by layer depth
	    df %>%
	      left_join(df_layers, by = "layer") %>%
	      rename(var = !!varnam) %>% 
	      dplyr::filter(layer %in% settings$layer) %>%
	      mutate(var_wgt = var * depth / z_tot_use) %>%
	      group_by(sitename) %>%
	      summarise(var := sum(var_wgt)) %>% 
	      rename(!!varnam := var)
	  }
	  
	  ddf <- purrr::map(
	    as.list(settings$varnam),
	    ~ingest_globalfields(siteinfo,
	                         source = source,
	                         getvars = NULL,
	                         dir = dir,
	                         timescale = NULL,
	                         verbose = FALSE,
	                         layer = .
	    )) %>% 
	    map2(as.list(settings$varnam), ~aggregate_layers(.x, .y, settings$layer)) %>% 
	    purrr::reduce(left_join, by = "sitename")
	  
	 }  else if (source == "worldclim"){
	   #-----------------------------------------------------------
	   # Get WorldClim data from global raster file
	   #-----------------------------------------------------------
	   ddf <- ingest_globalfields(siteinfo,
	                              source = source,
	                              dir = dir,
	                              getvars = NULL,
	                              timescale = NULL,
	                              verbose = FALSE,
	                              layer = settings$varnam
	   )
	   
	 } else {

	  rlang::warn(paste("you selected source =", source))
	  rlang::abort("ingest(): Argument 'source' could not be identified. Use one of 'fluxnet', 'cru', 'watch_wfdei', 'co2_mlo', 'etopo1', or 'gee'.")

	}

  ddf <- ddf %>%
    bind_rows() %>%
    group_by(sitename) %>%
    nest()

  return(ddf)

}

## give each site and day within year the same co2 value
expand_co2_bysite <- function(df, sitename, year_start, year_end){

  ddf <- init_dates_dataframe( year_start, year_end ) %>%
    dplyr::mutate(year = lubridate::year(date)) %>%
    dplyr::left_join(
      df,
      by = "year"
    ) %>%
    dplyr::mutate(sitename = sitename) %>%
    dplyr::select(sitename, date, co2 = co2_avg)

  return(ddf)
}

expand_bysite <- function(sitename, year_start, year_end){

  ddf <- init_dates_dataframe( year_start, year_end ) %>%
    dplyr::mutate(sitename = sitename)

  return(ddf)

}

