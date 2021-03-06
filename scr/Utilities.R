library(lubridate)
library(tidyr)
library(dplyr)
library(ggplot2)
library(gridExtra)
library(pracma)
library(splines)
library(stats)
library(meta)
  
############################################################################
load.data.xz1 = function() {
  
  ### read data 
  setwd("/Users/mac/Documents/GitHub/covid_wildfire")
  in.path = "data/moddat_xz1_rerun.csv"
  df = read.csv(in.path)
  
  print(paste(dim(df)[1], "records in the dataset"))
   
  df$date_str = ymd(df$date_str)
  df$date = ymd(df$date)
  
  ## make variables categorical
  df$dayofweek = as.factor(df$dayofweek)
  df$FIPS = as.factor(as.character(df$FIPS))

  df = arrange(df, date)

  ## create state 
  df$state = round(as.numeric(as.character(df$FIPS))/1000, 0)
  df$state[df$state == 6] = "CA"
  df$state[df$state == 53] = "WA"
  df$state[df$state == 41] = "OR"
  df$state = as.factor(df$state)

  ## merge with hazard data 0=nosmoke, 5=(0,10)light, 16=(11-20)medium, 27=(21,32)heavy
  hms = read.csv("data/HMS_county_2020.csv")
  hms = tidyr::gather(data=hms, key="date", value="hazardmap", -"County", -"GEOID")
  hms$date = mdy("01-01-2020") + (as.numeric(substr(hms$date, 2, 5)) - 1)
  hms$hazardmap[is.na(hms$hazardmap)] = 0
  hms$GEOID = as.factor(as.character(hms$GEOID))
  df = merge(df, hms, by.x=c("date", "FIPS"), by.y=c("date", "GEOID"), all.x=T)

  ## create the pm2.5 baseline and hazardline according to hazardmap 
  df$pmbase = NA
  df$pmhazard = NA
  for (ifips in unique(df$FIPS)) {
    irow = which(df$FIPS == ifips)
    pm.splitted = split.pm(df$pm25[irow], df$hazardmap[irow])
    df$pmbase[irow] = pm.splitted[[1]]
    df$pmhazard[irow] = pm.splitted[[2]]
  }
  
  ### fire day should shift with lag, no need to do it here  
  return(df)
}


############################################################################
# split the pm25 into pmbase and pmhazard according to the hazard map data 
split.pm = function(pm25, hazardmap) {
  ihazard = which(hazardmap >= 27 & !is.na(pm25))
  inothazard = which(hazardmap < 27 & !is.na(pm25))
  ina = which(is.na(pm25))

  pmbase = rep(NA,length(pm25))
  pmhazard = rep(NA,length(pm25))
  
  # if no hazard pm25 value, keep all as pmbase 
  if (length(ihazard) == 0) {
    return(list(pm25, pmhazard))
  }
  # if no non-hazard pm25 value, keep all as pmhazard 
  if (length(inothazard) == 0) {
    return(list(pmbase, pm25))
  }  

  # force split 
  pmbase[inothazard] = pm25[inothazard]
  pmhazard[ihazard] = pm25[ihazard]
  base.mean = mean(pmbase, na.rm=T)
  
  # remove base in hazard day 
  pmbase[ihazard] = base.mean
  pmhazard[ihazard] = pmhazard[ihazard] - pmbase[ihazard]
  pmhazard[inothazard] = 0
  
  # treat aloft record 
  ialoft = which(pmhazard < 0)
  if (any(ialoft)) {
    pmbase[ialoft] = pmbase[ialoft] + pmhazard[ialoft]
    pmhazard[ialoft] = 0 
  }
  
  return(list(pmbase, pmhazard))
}
  


############################################################################
add.lag = function(dff, value="pm25", group="FIPS", lags=1) {
  ### return all lagged 'value' as listed in 'lags', after grouping value by 'group'
  ### assumes df is ordered in time!!! 
  ### dplyr version 0.8.5
  ### output name pm25, pm25.l1, pm25.l2
  lag.names = c()
  
  for (i in lags) {
    new.var = ifelse(i == 0, value, paste0(value, ".l", i))
    lag.names = c(lag.names, new.var)
    dff = dff %>% 
      dplyr::group_by(.dots = group) %>% 
      dplyr::mutate(!!new.var := dplyr::lag(!!as.name(value), n = i, default = NA))
    dff = data.frame(dff)
  }
  return(list(dff[lag.names], lag.names))

}

############################################################################
#### define smoke as two consecutive days with PM2.5 higher than the pre-defined threshold ####
add.smoke = function(dff, value="pm25", group="FIPS", lag=1, pm.threshold=20) {
  if (length(lag) > 1) stop("add.smoke only works for 1 lag")
  
  unique.groups = unique(as.list(dff[group])[[1]])
  ndays = dim(dff)[1] / length(unique.groups)
  
  ### transform matrix
  tx1 = diag(x = 1, nrow=ndays, ncol=ndays, names = TRUE)
  for (i in 1:(ndays-1)) tx1[i, i+1] = 1
  
  tx2 = diag(x = 1, nrow=ndays, ncol=ndays, names = TRUE)
  for (i in 2:ndays) tx2[i, i-1] = 1
  
  ### get smoke day 
  dff["fireday"] = NA
  for (ig in unique.groups) {
    values = (dff[dff[group] == ig, ][value] >= pm.threshold) * 1
    values[is.na(values)] = 0
    w1 = t(t(values) %*% tx1 >= 2) * 1
    w2 = t(t(values) %*% tx2 >= 2) * 1
    dff["fireday"][dff[group] == ig] = (w1|w2) * 1
  }
  
  ### get lagged smoke day
  new.var = ifelse(lag == 0, "fireday", paste0("fireday", ".l", lag))
  dff = dff %>%
    dplyr::group_by(.dots = group) %>%
    dplyr::mutate(!!new.var := dplyr::lag(fireday, n = lag, default = NA))
  dff = data.frame(dff)

  return(list(dff[new.var], new.var))
}

############################################################################
add.hazard = function(dff, value="hazardmap", group="FIPS", lag=1, hazard.threshold=27) {
  if (length(lag) > 1) stop("add.hazard only works for 1 lag")
  i = lag
  new.var = ifelse(i == 0, value, paste0(value, ".l", i))
  dff = dff %>% 
    dplyr::group_by(.dots = group) %>% 
    dplyr::mutate(!!new.var := dplyr::lag(!!as.name(value), n = i, default = NA))
  dff = data.frame(dff)
  # dff[new.var] = as.factor(as.character((dff[new.var] >= hazard.threshold) * 1))           TODO 
  return(list(dff[new.var], new.var))
}
  