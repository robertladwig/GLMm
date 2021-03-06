function sim_data = calcLaGLMmetrics(simfile,conf)
% function sim_data = calcGLMmetrics(simfile,conf)
%
% Inputs:
%       such and area and depth
%		simfile    : filename of GLM output
%       LA_metrics : list of thermodynamics metrics
%       paths      : paths for various input and output directories
%
% Outputs
%
% Uses:
%      readGLMnetcdf.m
%      LakeAnalyzer scripts
%
% Written by L. Bruce 14th April 2014
% Takes GLM simulated output and calculates various thermodynamic metrics
% listed in LA_metrics using LakeAnalyzer scripts
% Adds values to text files

%Get glm.nml info
glm_nml = getGLMnml([conf.paths.working_dir,'nml/glm2_init.nml']);

%MCMC configuration information
varname = conf.config.varname;

bthD = flipud(glm_nml.H(end) - glm_nml.H)';
bthA = flipud(glm_nml.A)';

%-------------------------------------------------------------------------%
%Some constant parameters for calculating stratification metrics
%-------------------------------------------------------------------------%

drhDz = 0.1;   %min slope for metalimnion (drho/dz per m)
Tdiff = 0.5;    %mixed temp differential (oC)
Smin = 0.1;      %minimum Salinity
mix_depth_pc = 0.85;  %Percent maximum depth for mixis (if thermoD > mix_depth_pc*max_depth)


%Create structure of GLM variable
sim_data = readGLMnetcdf(simfile,varname);

%Remove spin up time from calculations
spinup_indx = find(sim_data.time >= sim_data.startTime+conf.config.spin_up,1,'first');
sim_data.time = sim_data.time(spinup_indx:end);
sim_data.z = sim_data.z(spinup_indx:end,:);
sim_data.temp = sim_data.temp(spinup_indx:end,:);
sim_data.NS = sim_data.NS(spinup_indx:end);

%Convert simulated z (height from bottom) to depths (mid point for each
%layer)
sim_data.depth = 0.0*sim_data.z - 999;
for time_i = 1:length(sim_data.time)
    max_depth = sim_data.z(time_i,sim_data.NS(time_i));
    sim_data.depth(time_i,1) = max_depth - (sim_data.z(time_i,1))/2;
    for depth_i = 2:sim_data.NS(time_i)
        sim_data.depth(time_i,depth_i) = max_depth - ...
                        (sim_data.z(time_i,depth_i) + sim_data.z(time_i,depth_i-1))/2;
    end
end

%Size of array
numDates = length(sim_data.time);
numDepths = length(sim_data.depth);
%Max depth for simulated and observed data
max_depth = max(max(sim_data.depth));

%-------------------------------------------------------------------------%
%Wind data ---------------------------------------------------------------%
%-------------------------------------------------------------------------%

%Read in GLM meteorological information
metData = importdata([conf.paths.working_dir,conf.paths.sim_dir,glm_nml.metfile],',',1);
metData.time = datenum(metData.textdata(2:end,1));

%Extract wind speed
met_varNames = metData.textdata(1,2:end);
met_varNames = regexprep(met_varNames,' ','');
met_varNames = regexprep(met_varNames,'\t','');
wind_indx = find(strcmp(met_varNames,'WindSpeed')==1);
WindSpeed = metData.data(:,wind_indx);

%Apply wind factor
WindSpeed = glm_nml.wind_factor * WindSpeed;

%Find wind speed for each of the simulated output time stamps
for time_i = 1:numDates
    [~,wind_idx] = min(abs(metData.time - sim_data.time(time_i)));
    wind_speed(time_i) = WindSpeed(wind_idx);
end

%--------------THERMODYNAMIC METRICS-------------------------------------%

%First intitialise indexes
sim_data.mixed = zeros(length(sim_data.time),1);
sim_data.thermoD = ones(length(sim_data.time),1)*max_depth;
sim_data.meta_top = sim_data.thermoD;
sim_data.meta_bot = sim_data.meta_top;

for time_i = 1:numDates
    %time_i
    %datestr(sim_data.time(time_i))
    sim_NS = sim_data.NS(time_i);
    %---------------------------------------------------------------------%
    %Get measures of temperature, salinity, density to calculate
    %stratification metrics
    
    %Simulated data
    salSim = zeros(1,sim_NS);
    sim_wtrT = sim_data.temp(time_i,1:sim_NS);
    sim_data.rho(time_i,1:length(sim_wtrT)) = waterDensity(sim_wtrT,salSim);
    % test shallowest depth with deepest depth (exclude NaNs)
    sim_wtrT = sim_wtrT(~isnan(sim_wtrT));
    % remove NaNs, need at least 3 values
    sim_rhoT = sim_data.rho(time_i,1:sim_NS); 
    sim_depT = sim_data.depth(time_i,1:sim_NS);
    sim_depT(isnan(sim_rhoT)) = [];
    sim_rhoT(isnan(sim_rhoT)) = [];
    sim_wtrT(isnan(sim_rhoT)) = [];
    %Flip simulated arrays so that they go from surface to bottom
    sim_depT = fliplr(sim_depT);
    sim_wtrT = fliplr(sim_wtrT);
    sim_rhoT = fliplr(sim_rhoT);
    %Get layer heights
    sim_hgtT = sim_depT(2:end) - sim_depT(1:end-1);
    sim_hgtT = [sim_depT(1) sim_hgtT];
    
    %Thermocline depth----------------------------------------------------%
    
    %Simulated data
    if abs(sim_wtrT(1)-sim_wtrT(end)) > Tdiff % not mixed... % GIVES mixed if NaN!!!!
         if length(sim_depT)>2
             if sim_wtrT(1)>sim_wtrT(end)
                %Tdepth
                [sim_data.thermoD(time_i),~,drho_dz] = FindThermoDepth(sim_rhoT,sim_depT,Smin);
                sim_data.meta_top(time_i) = FindMetaTop(drho_dz,sim_data.thermoD(time_i),sim_depT,drhDz);
                sim_data.meta_bot(time_i) = FindMetaBot(drho_dz,sim_data.thermoD(time_i),sim_depT,drhDz);
             end
         end % or else, keep as NaN
   else
         %thermoD, meta_top and meta_bot stay as max_depth
         sim_data.mixed(time_i) = 1;
    end
    
    %During mixis set all thermoD to maximum depth
    sim_data.thermoD(sim_data.thermoD < 0.01*max_depth) = max_depth;
    sim_data.thermoD(sim_data.thermoD > 0.9*max_depth) = max_depth;
    
    %Depth average temperature (all depths)--------------------------%
    %Include all layers from surface to bottom layer
    
    sim_data.all(time_i) = layerTemp(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD);

    %Epilimnion temperature (depth average)--------------------------%
    %Include all layers from surface to meta_top layer
    
    if sim_data.mixed(time_i) == 1 %lake mixed
        sim_data.epi(time_i) = layerTemp(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD);
        sim_data.epiRho(time_i) = layerDensity(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD,salSim);
    else
        sim_data.epi(time_i) = layerTemp(0,sim_data.meta_top(time_i),sim_wtrT,sim_depT,bthA,bthD);
        sim_data.epiRho(time_i) = layerDensity(0,sim_data.meta_top(time_i),sim_wtrT,sim_depT,bthA,bthD,salSim);
    end


    %Hypolimnion temperature (depth average)--------------------------%
    %Include all layers from meta_bot layer to bottom layer
    
    if sim_data.mixed(time_i) == 1 %lake mixed
        sim_data.hyp(time_i) = layerTemp(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD);
        sim_data.hypRho(time_i) = layerDensity(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD,salSim);
    elseif (sim_wtrT(1) < sim_wtrT(end)) %Inverse stratification, consider mixed
        sim_data.hyp(time_i) = layerTemp(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD);
        sim_data.hypRho(time_i) = layerDensity(0,max(sim_depT),sim_wtrT,sim_depT,bthA,bthD,salSim);
    else
        sim_data.hyp(time_i) = layerTemp(sim_data.meta_bot(time_i),max(sim_depT),sim_wtrT,sim_depT,bthA,bthD);
        sim_data.hypRho(time_i) = layerDensity(sim_data.meta_bot(time_i),max(sim_depT),sim_wtrT,sim_depT,bthA,bthD,salSim);
    end
    
    %uStar -------------------------------------------------------------%
    %    fprintf('Calculating uStar');
    
    %Simulated Data
    sim_data.uStar(time_i) = NaN;
    if length(sim_wtrT) > 2
        sim_data.uStar(time_i) = uStar(wind_speed(time_i),10.0,sim_data.epiRho(time_i));
    end % else keep as NaN

    
    %Schmidt Stability ---------------------------------------------------------%
    %    fprintf('Calculating Schmidt Stability');
    
    %Simulated Data
    sim_data.St(time_i) = NaN;
    if length(sim_wtrT) > 2
        sim_data.St(time_i) = schmidtStability(sim_wtrT,sim_depT,bthA,bthD,salSim);
    end % else keep as NaN
    
    %Lake Number ---------------------------------------------------------%
    %    fprintf('Calculating LakeNumber');
    
    %Initialise as NaN
    sim_data.LN(time_i) = NaN;
    if length(sim_wtrT) > 2
        sim_data.LN(time_i) = lakeNumber(bthA,bthD, ...
            sim_data.uStar(time_i),sim_data.St(time_i),sim_data.meta_top(time_i), ...
            sim_data.meta_bot(time_i),sim_data.hypRho(time_i));
    end % else keep as NaN

    
end

%Avoid errors when lake mixed and Schmidt number is close to zero
sim_data.St(sim_data.St<=0.01) = 0.01;

sim_data.thermoD = sim_data.thermoD';

%Calculate mixing
sim_data.mixed(sim_data.thermoD > mix_depth_pc * max_depth) = 1;

% ------------------------------------------------------------------------ %


%-------------------------------------------------------------------------%
%Finally save results ----------------------------------------------------%
%-------------------------------------------------------------------------%

%Time series variables calculated to plot parameter uncertainty at
%completion of MCMC optimisation run


%Save to results file
% ---------------------------- SAVE TO FILE --------------------------- %

%Open files.

for ii = 1:length(conf.dataset.Data_Subsets)
    fid.(conf.dataset.Data_Subsets{ii}) = fopen([conf.paths.working_dir,'Results/GLM_',conf.dataset.Data_Subsets{ii},'_TimeSeries.csv'],'a');
end

% Write time stamp as headers
format_line = '%f';
for ii = 1:length(sim_data.time)-1
    format_line = [format_line,', %f '];
end
format_line = [format_line,'\n'];

%Write time series for thermodynamic metrics
for ii = 1:length(conf.dataset.Data_Subsets)
    fprintf(fid.(conf.dataset.Data_Subsets{ii}),format_line,sim_data.(conf.dataset.Data_Subsets{ii}));
    fclose(fid.(conf.dataset.Data_Subsets{ii})); % Close the file.
end



% ------------------------------------------------------------------------ %

