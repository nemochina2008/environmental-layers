###################################################################################
###  R code to aquire and process MOD06_L2 cloud data from the MODIS platform


# Redirect all warnings to stderr()
#options(warn = -1)
#write("2) write() to stderr", stderr())
#write("2) write() to stdout", stdout())
#warning("2) warning()")


## import commandline arguments
library(getopt)
## get options
opta <- getopt(matrix(c(
                        'date', 'd', 1, 'character',
                        'tile', 't', 1, 'character',
                        'verbose','v',1,'logical',
                        'help', 'h', 0, 'logical'
                        ), ncol=4, byrow=TRUE))
if ( !is.null(opta$help) )
  {
       prg <- commandArgs()[1];
          cat(paste("Usage: ", prg,  " --date | -d <file> :: The date to process\n", sep=""));
          q(status=1);
     }


date=opta$date  #date="20030301"
tile=opta$tile #tile="h11v08"
verbose=opta$verbose  #print out extensive information for debugging?
outdir=paste("daily/",tile,"/",sep="")  #directory for separate daily files

## permanent storage on lou:
ldir=paste("lfe1.nas.nasa.gov:/u/awilso10/mod06/daily/",tile,sep="")

print(paste("Processing tile",tile," for date",date))

## load libraries
require(reshape)
require(geosphere)
require(raster)
library(rgdal)
require(spgrass6)
require(RSQLite)


## specify some working directories
setwd("/nobackupp1/awilso10/mod06")

## load ancillary data
load(file="allfiles.Rdata")

## load tile information
load(file="modlandTiles.Rdata")

## vars to process
vars=as.data.frame(matrix(c(
  "Cloud_Effective_Radius",              "CER",
  "Cloud_Effective_Radius_Uncertainty",  "CERU",
  "Cloud_Optical_Thickness",             "COT",
  "Cloud_Optical_Thickness_Uncertainty", "COTU",
  "Cloud_Water_Path",                    "CWP",
  "Cloud_Water_Path_Uncertainty",        "CWPU",
  "Cloud_Phase_Optical_Properties",      "CPOP",
  "Cloud_Multi_Layer_Flag",              "CMLF",
  "Cloud_Mask_1km",                      "CM1",
  "Quality_Assurance_1km",               "QA"),
  byrow=T,ncol=2,dimnames=list(1:10,c("variable","varid"))),stringsAsFactors=F)


############################################################################
############################################################################
### Define functions to process a particular date-tile

#### get swaths
#getswaths<-function(tile,db="/nobackupp4/pvotava/DB/export/swath_geo.sql.sqlite3.db"){
#  db=dbConnect(
#  }

swath2grid=function(file,vars,upleft,lowright){
  ## Function to generate hegtool parameter file for multi-band HDF-EOS file
  print(paste("Starting file",basename(file)))
  outfile=paste(tempdir(),"/",basename(file),sep="")
  ## First write the parameter file (careful, heg is very finicky!)
  hdr=paste("NUM_RUNS = ",length(vars$varid),"|MULTI_BAND_HDFEOS:",length(vars$varid),sep="")
  grp=paste("
BEGIN
INPUT_FILENAME=",file,"
OBJECT_NAME=mod06
FIELD_NAME=",vars$variable,"|
BAND_NUMBER = 1
OUTPUT_PIXEL_SIZE_X=1000
OUTPUT_PIXEL_SIZE_Y=1000
SPATIAL_SUBSET_UL_CORNER = ( ",upleft," )
SPATIAL_SUBSET_LR_CORNER = ( ",lowright," )
#RESAMPLING_TYPE =",ifelse(grepl("Flag|Mask|Quality",vars),"NN","CUBIC"),"
RESAMPLING_TYPE =NN
OUTPUT_PROJECTION_TYPE = SIN
OUTPUT_PROJECTION_PARAMETERS = ( 6371007.181 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 )
# projection parameters from http://landweb.nascom.nasa.gov/cgi-bin/QA_WWW/newPage.cgi?fileName=sn_gctp
ELLIPSOID_CODE = WGS84
OUTPUT_TYPE = HDFEOS
OUTPUT_FILENAME = ",outfile,"
END

",sep="")

  ## if any remnants from previous runs remain, delete them
  if(length(list.files(tempdir(),pattern=basename(file)))>0)
    file.remove(list.files(tempdir(),pattern=basename(file),full=T))
  ## write it to a file
  cat(c(hdr,grp)    , file=paste(tempdir(),"/",basename(file),"_MODparms.txt",sep=""))
  ## now run the swath2grid tool
  ## write the gridded file and save the log including the pid of the parent process
#  log=system(paste("( /nobackupp1/awilso10/software/heg/bin/swtif -p ",tempdir(),"/",basename(file),"_MODparms.txt -d ; echo $$)",sep=""),intern=T)
  log=system(paste("( /nobackupp1/awilso10/software/heg/bin/swtif -p ",tempdir(),"/",basename(file),"_MODparms.txt -d ; echo $$)",sep=""),intern=T,ignore.stderr=T)
  ## clean up temporary files in working directory
  file.remove(list.files(pattern=
              paste("filetable.temp_",
              as.numeric(log[length(log)]):(as.numeric(log[length(log)])+3),sep="",collapse="|")))  #Look for files with PID within 3 of parent process
  if(verbose) print(log)
  print(paste("Finished ", file))
}


##############################################################
### Import to GRASS for processing

## function to convert binary to decimal to assist in identifying correct values
## this is helpful when defining QA handling below, but isn't used in processing
## b2d=function(x) sum(x * 2^(rev(seq_along(x)) - 1)) #http://tolstoy.newcastle.edu.au/R/e2/help/07/02/10596.html
## for example:
## b2d(c(T,T))

  ## set Grass to overwrite
  Sys.setenv(GRASS_OVERWRITE=1)
  Sys.setenv(DEBUG=1)
  Sys.setenv(GRASS_GUI="txt")

### Function to extract various SDSs from a single gridded HDF file and use QA data to throw out 'bad' observations
loadcloud<-function(date,fs,ncfile){
  tf=paste(tempdir(),"/grass", Sys.getpid(),"/", sep="")
  if(!file.exists(tf))dir.create(tf)

  print(paste("Set up temporary grass session in",tf))

  ## set up temporary grass instance for this PID
  initGRASS(gisBase="/u/armichae/pr/grass-6.4.2/",gisDbase=tf,SG=td,override=T,location="mod06",mapset="PERMANENT",home=tf,pid=Sys.getpid())
  system(paste("g.proj -c proj4=\"",projection(td),"\"",sep=""),ignore.stdout=T,ignore.stderr=T)

  ## Define region by importing one MOD11A1 raster.
  print("Import one MOD11A1 raster to define grid")
  execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",gridfile,"\":MODIS_Grid_Daily_1km_LST:Night_view_angl",sep=""),
            output="modisgrid",flags=c("quiet","overwrite","o"))
  system("g.region rast=modisgrid save=roi --overwrite",ignore.stdout=T,ignore.stderr=T)

  ## Identify which files to process
  tfs=fs$file[fs$dateid==date]
  ## drop swaths that did not produce an output file (typically due to not overlapping the ROI)
  tfs=tfs[tfs%in%list.files(tempdir())]
  nfs=length(tfs)

  ## loop through scenes and process QA flags
  for(i in 1:nfs){
     file=paste(tempdir(),"/",tfs[i],sep="")
     ## Cloud Mask
     execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",file,"\":mod06:Cloud_Mask_1km_0",sep=""),
              output=paste("CM1_",i,sep=""),flags=c("overwrite","o")) ; print("")
    ## extract cloudy and 'confidently clear' pixels
    system(paste("r.mapcalc <<EOF
                CM_cloud_",i," =  ((CM1_",i," / 2^0) % 2) == 1  &&  ((CM1_",i," / 2^1) % 2^2) == 0 
                CM_clear_",i," =  ((CM1_",i," / 2^0) % 2) == 1  &&  ((CM1_",i," / 2^1) % 2^2) == 3 
EOF",sep=""))
    ## QA
     execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",file,"\":mod06:Quality_Assurance_1km_0",sep=""),
             output=paste("QA_",i,sep=""),flags=c("overwrite","o")) ; print("")
   ## QA_CER
   system(paste("r.mapcalc <<EOF
                 QA_COT_",i,"=   ((QA_",i," / 2^0) % 2^1 )==1
                 QA_COT2_",i,"=  ((QA_",i," / 2^1) % 2^2 )==3
                 QA_COT3_",i,"=  ((QA_",i," / 2^3) % 2^2 )==0
                 QA_CER_",i,"=   ((QA_",i," / 2^5) % 2^1 )==1
                 QA_CER2_",i,"=  ((QA_",i," / 2^6) % 2^2 )==3
EOF",sep="")) 
#                 QA_CWP_",i,"=   ((QA_",i," / 2^8) % 2^1 )==1
#                 QA_CWP2_",i,"=  ((QA_",i," / 2^9) % 2^2 )==3

   ## Optical Thickness
   execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",file,"\":mod06:Cloud_Optical_Thickness",sep=""),
            output=paste("COT_",i,sep=""),
            title="cloud_effective_radius",
            flags=c("overwrite","o")) ; print("")
   execGRASS("r.null",map=paste("COT_",i,sep=""),setnull="-9999")
   ## keep only positive COT values where quality is 'useful' and 'very good' & scale to real units
   system(paste("r.mapcalc \"COT_",i,"=if(QA_COT_",i,"&&QA_COT2_",i,"&&QA_COT3_",i,"&&COT_",i,">=0,COT_",i,"*0.009999999776482582,null())\"",sep=""))   
   ## set COT to 0 in clear-sky pixels
   system(paste("r.mapcalc \"COT2_",i,"=if(CM_clear_",i,"==0,COT_",i,",0)\"",sep=""))   
   
   ## Effective radius ##
   execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",file,"\":mod06:Cloud_Effective_Radius",sep=""),
            output=paste("CER_",i,sep=""),
            title="cloud_effective_radius",
            flags=c("overwrite","o")) ; print("")
   execGRASS("r.null",map=paste("CER_",i,sep=""),setnull="-9999")
   ## keep only positive CER values where quality is 'useful' and 'very good' & scale to real units
   system(paste("r.mapcalc \"CER_",i,"=if(QA_CER_",i,"&&QA_CER2_",i,"&&CER_",i,">=0,CER_",i,"*0.009999999776482582,null())\"",sep=""))   
   ## set CER to 0 in clear-sky pixels
   system(paste("r.mapcalc \"CER2_",i,"=if(CM_clear_",i,"==0,CER_",i,",0)\"",sep=""))   

   ## Cloud Water Path
#   execGRASS("r.in.gdal",input=paste("HDF4_EOS:EOS_GRID:\"",file,"\":mod06:Cloud_Water_Path",sep=""),
#            output=paste("CWP_",i,sep=""),title="cloud_water_path",
#            flags=c("overwrite","o")) ; print("")
#   execGRASS("r.null",map=paste("CWP_",i,sep=""),setnull="-9999")
   ## keep only positive CER values where quality is 'useful' and 'very good' & scale to real units
#   system(paste("r.mapcalc \"CWP_",i,"=if(QA_CWP_",i,"&&QA_CWP2_",i,"&&CWP_",i,">=0,CWP_",i,"*0.009999999776482582,null())\"",sep=""))   
   ## set CER to 0 in clear-sky pixels
#   system(paste("r.mapcalc \"CWP2_",i,"=if(CM_clear_",i,"==0,CWP_",i,",0)\"",sep=""))   
     
 } #end loop through sub daily files

#### Now generate daily averages (or maximum in case of cloud flag)
  
  system(paste("r.mapcalc <<EOF
         COT_denom=",paste("!isnull(COT2_",1:nfs,")",sep="",collapse="+"),"
         COT_numer=",paste("if(isnull(COT2_",1:nfs,"),0,COT2_",1:nfs,")",sep="",collapse="+"),"
         COT_daily=int((COT_numer/COT_denom)*100)
         CER_denom=",paste("!isnull(CER2_",1:nfs,")",sep="",collapse="+"),"
         CER_numer=",paste("if(isnull(CER2_",1:nfs,"),0,CER2_",1:nfs,")",sep="",collapse="+"),"
         CER_daily=int(100*(CER_numer/CER_denom))
         CLD_daily=int((max(",paste("if(isnull(CM_cloud_",1:nfs,"),0,CM_cloud_",1:nfs,")",sep="",collapse=","),"))*100) 
EOF",sep=""))


  ### Write the files to a netcdf file
  ## create image group to facilitate export as multiband netcdf
    execGRASS("i.group",group="mod06",input=c("CER_daily","COT_daily","CLD_daily")) ; print("")
   
  if(file.exists(ncfile)) file.remove(ncfile)  #if it exists already, delete it
  execGRASS("r.out.gdal",input="mod06",output=ncfile,type="Int16",nodata=-32768,flags=c("quiet"),
#      createopt=c("FORMAT=NC4","ZLEVEL=5","COMPRESS=DEFLATE","WRITE_GDAL_TAGS=YES","WRITE_LONLAT=NO"),format="netCDF")  #for compressed netcdf
      createopt=c("FORMAT=NC","WRITE_GDAL_TAGS=YES","WRITE_LONLAT=NO"),format="netCDF")

  ncopath="/nasa/sles11/nco/4.0.8/gcc/mpt/bin/"
  system(paste(ncopath,"ncecat -O -u time ",ncfile," ",ncfile,sep=""))
## create temporary nc file with time information to append to MOD06 data
  cat(paste("
    netcdf time {
      dimensions:
        time = 1 ;
      variables:
        int time(time) ;
      time:units = \"days since 2000-01-01 00:00:00\" ;
      time:calendar = \"gregorian\";
      time:long_name = \"time of observation\"; 
    data:
      time=",as.integer(fs$date[fs$dateid==date][1]-as.Date("2000-01-01")),";
    }"),file=paste(tempdir(),"/time.cdl",sep=""))
system(paste("ncgen -o ",tempdir(),"/time.nc ",tempdir(),"/time.cdl",sep=""))
system(paste(ncopath,"ncks -A ",tempdir(),"/time.nc ",ncfile,sep=""))
## add other attributes
  system(paste(ncopath,"ncrename -v Band1,CER -v Band2,COT -v Band3,CLD ",ncfile,sep=""))
  system(paste(ncopath,"ncatted -a scale_factor,CER,o,d,0.01 -a units,CER,o,c,\"micron\" -a missing_value,CER,o,d,-32768 -a long_name,CER,o,c,\"Cloud Particle Effective Radius\" ",ncfile,sep=""))
  system(paste(ncopath,"ncatted -a scale_factor,COT,o,d,0.01 -a units,COT,o,c,\"none\" -a missing_value,COT,o,d,-32768 -a long_name,COT,o,c,\"Cloud Optical Thickness\" ",ncfile,sep=""))
  system(paste(ncopath,"ncatted -a scale_factor,CLD,o,d,0.01 -a units,CLD,o,c,\"none\" -a missing_value,CLD,o,d,-32768 -a long_name,CLD,o,c,\"Cloud Mask\" ",ncfile,sep=""))
   
  
### delete the temporary files 
  unlink_.gislock()
  system("clean_temp")
  system(paste("rm -frR ",tf,sep=""))
}


###########################################
### Define a wrapper function that will call the two functions above (gridding and QA-handling) for a single tile-date

mod06<-function(date,tile){
  print(paste("Processing date ",date," for tile",tile))
  #####################################################
  ## Run the gridding procedure
  tile_bb=tb[tb$tile==tile,] ## identify tile of interest
  
#  if(venezuela) tile_bb$lat_max=11.0780999176  #increase northern boundary for KT

  lapply(fs$path[fs$dateid==date],swath2grid,vars=vars,upleft=paste(tile_bb$lat_max,tile_bb$lon_min),lowright=paste(tile_bb$lat_min,tile_bb$lon_max))

  ## confirm at least one file for this date is present
    outfiles=paste(tempdir(),"/",basename(fs$path[fs$dateid==date]),sep="")
    if(!any(file.exists(outfiles))) {
      print(paste("########################################   No gridded files for region exist for tile",tile," on date",date))
      q("no",status=0)
    }

  #####################################################
  ## Process the gridded files

  ## run themod06 processing for this date
  ncfile=paste(outdir,"/MOD06_",tile,"_",date,".nc",sep="")  #this is the 'final' daily output file
  loadcloud(date,fs=fs,ncfile=ncfile)

  ## Confirm that the file has the correct attributes, otherwise delete it
  ntime=as.numeric(system(paste("cdo -s ntime ",ncfile),intern=T))
  npar=as.numeric(system(paste("cdo -s npar ",ncfile),intern=T))
  if(!ntime==1&npar>0) {
    print(paste("File for tile ",tile," and date ",date," was not outputted correctly, deleting... "))
    file.remove(ncfile)
  }

  ## push file to lou and then delete it from pfe
#  system(paste("scp ",ncfile," ",ldir,sep="")  )
#  file.remove(ncfile)
 
  ## print out some info
  print(paste(" ###################################################################               Finished ",date,"
################################################################"))
}
 
## test it
##date=notdone[1]
mod06(date,tile)

## run it for all dates  - Use this if running on a workstation/server (otherwise use qsub)
#mclapply(notdone,mod06,tile,mc.cores=ncores) # use ncores/2 because system() commands can add second process for each spawned R
#foreach(i=notdone[1:3],.packages=(.packages())) %dopar% mod06(i,tile)
#foreach(i=1:20) %dopar% print(i)

## delete old files
#system("cleartemp")

q("no",status=0)
