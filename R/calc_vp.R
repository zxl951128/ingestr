#' Calculate vapor pressure from relative humidity
#'
#' xxx
#'
#' @param qair Air specific humidity (g g-1)
#' @param tc temperature, deg C
#' @param tmin (optional) min daily air temp, deg C 
#' @param tmax (optional) max daily air temp, deg C
#' @param patm Atmospehric pressure (Pa)
#' @param elv Elevation above sea level (m) (Used only if \code{patm} is missing 
#' for calculating it based on standard sea level pressure)
#'
#' @return vapor pressure (Pa)
#' @export
#' 
calc_vp <- function(qair=NA, tc=NA, tmin=NA, tmax=NA, patm=NA, elv=NA){
  ##-----------------------------------------------------------------------
  ## Ref:      Eq. 5.1, Abtew and Meleese (2013), Ch. 5 Vapor Pressure 
  ##           Calculation Methods, in Evaporation and Evapotranspiration: 
  ##           Measurements and Estimations, Springer, London.
  ##             vpd = 0.611*exp[ (17.27 tc)/(tc + 237.3) ] - ea
  ##             where:
  ##                 tc = average daily air temperature, deg C
  ##                 eact  = actual vapor pressure, Pa
  ##-----------------------------------------------------------------------

  ## calculate atmopheric pressure (Pa) assuming standard conditions at sea level (elv=0)
  if (is.na(elv) && is.na(patm)){
    
    rlang::warn("calc_vp(): Either patm or elv must be provided if eact is not given.")
    vp <- NA
    
  } else {

    patm <- ifelse(is.na(patm),
                   calc_patm(elv),
                   patm)
    
    ## Calculate VPD as mean of VPD based on Tmin and VPD based on Tmax if they are availble.
    ## Otherwise, use just tc for calculating VPD.
    vp <- ifelse(!is.na(tmin) && !is.na(tmax),
                  mean(
                    calc_vp_inst(qair=qair, tc=tmin, patm=patm), 
                    calc_vp_inst(qair=qair, tc=tmax, patm=patm)
                  ),
                  calc_vp_inst(qair=qair, tc=tc, patm=patm)
    )
  }
  return( vp )
  
}

calc_vp_inst <- function(qair=NA, tc=NA, patm=NA, elv=NA){
  ##-----------------------------------------------------------------------
  ## Ref:      Eq. 5.1, Abtew and Meleese (2013), Ch. 5 Vapor Pressure 
  ##           Calculation Methods, in Evaporation and Evapotranspiration: 
  ##           Measurements and Estimations, Springer, London.
  ##             vpd = 0.611*exp[ (17.27 tc)/(tc + 237.3) ] - ea
  ##             where:
  ##                 tc = average daily air temperature, deg C
  ##                 ea  = actual vapor pressure, Pa
  ##-----------------------------------------------------------------------
  kTo = 288.15   # base temperature, K (Prentice, unpublished)
  kR  = 8.3143   # universal gas constant, J/mol/K (Allen, 1973)
  kMv = 18.02    # molecular weight of water vapor, g/mol (Tsilingiris, 2008)
  kMa = 28.963   # molecular weight of dry air, g/mol (Tsilingiris, 2008)
  
  ## calculate the mass mixing ratio of water vapor to dry air (dimensionless)
  wair <- qair / (1 - qair)
  
  ## calculate water vapor pressure 
  rv <- kR / kMv
  rd <- kR / kMa
  eact = patm * wair * rv / (rd + wair * rv)  
  
  return( eact )
}