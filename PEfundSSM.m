function [FundOutput,otherOutput,Legacy] = PEfundSSM(yFund,otherInput)
% This program obtains fund-specific SSM parameter estimates and weekly NAV 
% and return series for a Private Equity fund as in "Nowcasting Net Asset Values: 
% The Case of Private Equity"  by G.Brown, E.Ghysels, O.Gredil published on SSRN
% https://papers.ssrn.com/sol3/papers.cfm?abstract_id=3507873
% The program requires MATLAB 2015a or higher with Econometrics Toolbox.
%
% KEY INPUT
% yFund -- Ty-by-2, observations at weekly frequency, NaNs if unobserved or zero, of :
%          (1) log of cash distributions,
%          (2) log of reported NAVs,
%
% otherInput.rmt  -- Tm-by-1 weekly market log returns, Tm>=Ty 
%                     * periods must align with those in yFund vector
%                     * cannot have missing values
%
% otherInput.rct  -- Tm-by-1 weekly log returns on comparable asset, Tm>=Ty
%                     * periods must align with those in yFund vector
%                     * can have missing values    
%                       
% otherInput.CFandVhat  -- Th-by-1 vector of complete cash flows and starting NAV estimates
%                    at weekly frequency, all values must be >=0, Th<=Tm 
%                    (1) Capital Calls
%                    (2) Distributions
%                    (3) NAV estimates
%                     * if initial Value-to-Return mapping function not provided,  
%                      it will be computed from these series
%
% KEY OUTPUT (all collect in 'FundOutput' structure) 
%
% ParameterEstimates -- 2-by-10 table with profiled MLE estimates of the
%                       SSM paraters and Numeric estimates of SE for each    
%                       * alfa, beta, delta, lambda, F, sigma_d, sigma_n
%                       * F_c, psi, beta_i 
%
% NowcastErrs_at1QafterParEst -- 4-by-3 table with perfromance statistics 
%     for selected nowcasting methods that are feasible when true asset values not observed     
%     The columns are: (1) InSample RMSE;  (2) Hybrid RMSE (3) OOS error for NAVs measured 
%     one quarter after parameter estimation period; S Sections 2 and 3 for
%     descption. The periods are indicated in 'Horizons' table
%      
% WeeklyReturnNowcastProperties -- 3-by-4 table with summary statistics for weekly fund
%    returns obainted via three nowcasting methods, as indicated by the row name:
%       (1) Naive, (2)--(3) SSM 
%    The columns are -- OLS (1) incercept, (2) slopes, and (3) MSEs from regressing of 
%      nowcasted returns on market returns; (4) -- AR(1) coefficient for nowcasted returns. 
% 
% Vt   -- Th-by-1 vector of SSM-based NAV estimates at weekly frequency  
% rt   -- Th-by-1 vector of SSM-based weekly fund return estimates
% Bias -- Th-by-1 vector of SSM-based esitmates of the appraisal bias at weekly frequency
%
%
% ADDITIONAL OUTPUT if true values are provided as otherInput.Params0.TrueVs
%
% NAVnowcastVtrueT0toT4 -- 6-by-4 table with performance statistics for 
%           nowcasted NAVs during 5 quarters after the parameter estimation period
%         The columns are:
%           (1) difference from the true values at the end of parameter estimation period
%           (2) RMSE during all weeks of 4 quarters if NAVs reported during T1-through-T4
%               were observed for nowcast production (i.e. HS for Hindsight) 
%           (3) RMSE during all weeks of 4 quarters if reported NAVs were NOT observed 
%              at the end of the respective quarter (i.e. RT Real-time during T0 to T4) 
%           (4) RMSE for the last week of 4 quarters if reported NAVs were not observed 
%              at the end of the respective quarter (i.e. RT Real-time at T1, T2, T3, T4)
%            * week numbers for the quarter-ends are in FundOutput.RT_nowcastQuarters table
%      
% Copyright 2022: Gregory Brown, Eric Ghysels, Oleg Gredil
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Step 1 prepare and rearrange inputs
if isfield(otherInput,'rmt')==0
    error('no market return series are provide, estimation impossible')
else
    rmt=otherInput.rmt(:,1);
    if max(isnan(rmt))>0
        error('market return series have missing values, estimation impossible')
    end
end

if isfield(otherInput,'CFandVhat')==0
    error('no complete cash flow schedule and starting nowcasts given, estimation impossible')
else
    CFandVhat=otherInput.CFandVhat;
    fCall=abs(CFandVhat(1,1))-abs(CFandVhat(1,2)); %period 0 net Contribion
    if max(isnan(CFandVhat(:)))>0 || fCall<=0
        error('cash flow schedule has missing values or initial Contribution Amount, estimation impossible')
    end
end

if isfield(otherInput,'rct')==0
   disp('Comp.asset not provided')
   CompAsset=0;
   rct=rmt;
else
   %assume the comp asset returns are not orthogonalized unless stated otherwize
   if size(otherInput.rct(:,1),2)>1
      disp('This code works with a single comp.asset only, the one in 1st col. is considered') 
   end
   rct=otherInput.rct(:,1);
   CompAsset=1;
   try
       if otherInput.rcIsOrthogonal2market==1
           CompAsset=2;
       end
   catch
   end
   try
       if otherInput.RcAdjReg==1
           CompAsset=3;
       end
   catch
   end   
end

%assume maximal T can be no longer than the fund naive nowcast series

TT=min([length(rmt),length(rct),length(CFandVhat)-1]);
if isfield(otherInput,'TT')==1
    TT=min(TT,otherInput.TT);
end
% TT=TT-1;
if length(rmt)>TT
   rmt_lead = rmt(2:TT+1,:); 
else
   rmt_lead = rmt(2:TT,:);
   TT       = TT-1;
end
rmt       = rmt(1:TT);
rct       = rct(1:TT);
CFandVhat = CFandVhat(1:TT+1,:);
if length(yFund)<TT
    yFund = [yFund; nan(TT-length(yFund),2)]; 
end
yFund     = yFund(1:TT,:);

%check if idvol is povided plug-in for time-varying volatility matrix
if isfield(otherInput,'sqrt_ht')==0 || length(otherInput.sqrt_ht)<TT || max(isnan(otherInput.sqrt_ht))==1
    disp('no proper time-varying volatility series provided, fund id ret assumed to be homoskedastic')
      sigt  = ones(TT,1);
    sig_vec = sigt;
else
    sigt = otherInput.sqrt_ht(1:TT);
    if length(otherInput.sqrt_ht)>TT
        sig_vec = [sigt(2:TT); otherInput.sqrt_ht(TT+1)];
    else
        sig_vec = [sigt(2:TT); sigt(TT)];
    end
end

%verify the time alignment of data and adjust if possible
%observation vector and the mapping must not have t0 values
   fDsTime = find(~isnan(yFund(:,1)),3,'first');
   fDsSize = exp(yFund(fDsTime,1));
   netCF   = abs(CFandVhat(2:end,2)) - abs(CFandVhat(2:end,1));
    % disp('--- DEBUG alignment check ---');
    % fprintf('size(yFund) = %d x %d\n', size(yFund,1), size(yFund,2));
    % fprintf('size(CFandVhat) = %d x %d\n', size(CFandVhat,1), size(CFandVhat,2));
    % fprintf('fCall = %g\n', fCall);
    % 
    % fprintf('Non-NaN yFund dist count: %d\n', sum(isfinite(yFund(:,1))));
    % fprintf('Non-NaN yFund NAV count: %d\n', sum(isfinite(yFund(:,2))));
    % 
    % disp('First observed distribution rows:');
    % disp(fDsTime');
    % 
    % disp('Observed distribution sizes from yFund:');
    % disp(fDsSize');
    % 
    % disp('CFandVhat distributions at same rows:');
    % disp(CFandVhat(fDsTime,2)');
    % 
    % disp('CFandVhat distributions at next rows:');
    % disp(CFandVhat(fDsTime+1,2)');
% keyboard   

if ismembertol(fDsSize',CFandVhat(fDsTime,2)',0.001,'ByRows',true) || ismembertol(fDsSize'*fCall,CFandVhat(fDsTime,2)',0.001,'ByRows',true)
   disp('cash flow schedule and observation vector need to be re-aligned')
   yFund=yFund(2:end,:);
   %rmt and rct start is assumed to be aligned with yFund vector
   rmt      = rmt(2:end); 
   rct      = rct(2:end);
   rmt_lead = rmt_lead(2:end);
   yDatesNeedShift=1;
   if  ismembertol(fDsSize'*fCall,CFandVhat(fDsTime,2)',0.001,'ByRows',true) && fCall~=1
       CFandVhat = CFandVhat/fCall; %since the observation vector is already scaled
       % ===== DEBUG: check scaling anchor fCall =====
       disp('--- DEBUG fCall normalization (branch: already rescaled) ---');
       disp(['fCall = ', num2str(fCall)]);
       disp(['log(fCall) = ', num2str(log(fCall))]);
       fprintf('yFund current col1 min/max: %g / %g\n', min(yFund(:,1),[],'omitnan'), max(yFund(:,1),[],'omitnan'));
       fprintf('yFund current col2 min/max: %g / %g\n', min(yFund(:,2),[],'omitnan'), max(yFund(:,2),[],'omitnan'));

       tmpY = yFund - log(fCall);
       fprintf('yFund IF-scaled col1 min/max: %g / %g\n', min(tmpY(:,1),[],'omitnan'), max(tmpY(:,1),[],'omitnan'));
       fprintf('yFund IF-scaled col2 min/max: %g / %g\n', min(tmpY(:,2),[],'omitnan'), max(tmpY(:,2),[],'omitnan'));
       disp('but the table of  naive nowcasts already rescaled')
   else
       CFandVhat = CFandVhat/fCall;
       yFund     = yFund-log(fCall);
       % ===== DEBUG: check scaling anchor fCall =====
       disp('--- DEBUG fCall normalization (branch: scaling applied) ---');
       disp(['fCall = ', num2str(fCall)]);
       disp(['log(fCall) = ', num2str(log(fCall))]);
       fprintf('yFund current col1 min/max: %g / %g\n', min(yFund(:,1),[],'omitnan'), max(yFund(:,1),[],'omitnan'));
       fprintf('yFund current col2 min/max: %g / %g\n', min(yFund(:,2),[],'omitnan'), max(yFund(:,2),[],'omitnan'));
   end
   
   %check if mapping is provided and seems well aligned and recompute if not 
   try
       M0   = otherInput.Mt;
       kchg = [0; log(M0(3:end)./M0(2:end-1))];
       M0   = M0(2:TT-yDatesNeedShift+1);
       if min(find((kchg~=0),3,'first')~=find((netCF~=0),3,'first')) || max(isnan(M0))
           error('return-to-value mapping provided is invalide or misaligned ')
       end
   catch      
       dki_=log(CFandVhat(2:end,3)+CFandVhat(2:end,2)-CFandVhat(2:end,1))-log(CFandVhat(2:end,3));
       dki_(isnan(dki_))=0;
       M0=exp(cumsum(dki_,1));
       disp('initial return-to-value mapping (re)computed from naive nowcast')
       noObs = all(isnan(yFund),2);
       M0(noObs) = 1;
       M0(~isfinite(M0) | M0<=0) = 1;
   end   
elseif  ismembertol(fDsSize',CFandVhat(fDsTime+1,2)',0.001,'ByRows',true) || ismembertol(fDsSize'*fCall,CFandVhat(fDsTime+1,2)',0.001,'ByRows',true)
   yDatesNeedShift=0;
   if  ismembertol(fDsSize'*fCall,CFandVhat(fDsTime+1,2)',0.001,'ByRows',true) && fCall~=1
       CFandVhat = CFandVhat/fCall; %since the observation vector is already scaled
       disp('Cash flow schedule looks properly aligned')
       disp('but the table of cash flows and naive nowcasts was rescaled')
   else
       CFandVhat = CFandVhat/fCall;
       yFund     = yFund-log(fCall);
   end
   %check if mapping is provided and seems well aligned and recompute if not 
   try
       M0   = otherInput.Mt(1:TT);
       kchg = [log(M0(2:end)./M0(1:end-1))];
       if sum(find((kchg~=0),3,'first')~=find((netCF(2:end)~=0),3,'first')) || max(isnan(M0(1:end-1)))
           error('return-to-value mapping provided is invalide or misaligned ')
       end
   catch
       dki_=log(CFandVhat(2:end,3)+CFandVhat(2:end,2)-CFandVhat(2:end,1))-log(CFandVhat(2:end,3));
       dki_(isnan(dki_))=0;
       M0=exp(cumsum(dki_,1));
       disp('initial return-to-value mapping (re)computed from naive nowcast')
       noObs = all(isnan(yFund),2);
       M0(noObs) = 1;
       M0(~isfinite(M0) | M0<=0) = 1;
   end
else
   error('cash flow data appears misaligned or not porperly scaled, estimation impossible')
end
TT=TT-yDatesNeedShift;
CFandVhatXt0  = CFandVhat(2:TT+1,:); %cash flow and naive nowcasts exluding first contribution (set to 1)
% disp('--- DEBUG after CFandVhatXt0 creation ---');
% fprintf('TT = %d\n', TT);
% fprintf('size(CFandVhatXt0) = %d x %d\n', size(CFandVhatXt0,1), size(CFandVhatXt0,2));
% fprintf('CFandVhatXt0 NAV min/max: %g / %g\n', min(CFandVhatXt0(:,3),[],'omitnan'), max(CFandVhatXt0(:,3),[],'omitnan'));
% fprintf('exp(yFund NAV) min/max: %g / %g\n', min(exp(yFund(:,2)),[],'omitnan'), max(exp(yFund(:,2)),[],'omitnan'));
obsNAVperiods = ~isnan(yFund(:,2));
       NAV_Ts = (1:TT)';
NAV_Ts(~obsNAVperiods)=[];  

%set time points of interest  
%T0 -- the last week to be used for parameter estimation
%T1 -- T1>T0 the week which NAVs nowcasts are taken for OOS error measurement
%TT -- the last nowcast horizon / cash flow info
cumDfrac=cumsum(CFandVhatXt0(:,2))/sum(CFandVhatXt0(:,2));
if isfield(otherInput,'T0')==0
    T80D = find((cumDfrac>=0.8),1);
%     T0   = min([max([210 floor(length(yFund)*.8) T80D]) TT-104 470]);
    T0   = min([max([floor(length(yFund)*.8) T80D]) TT-104]);
    Tidx = find(NAV_Ts-T0>=0,1,'first');
    T0   = NAV_Ts(Tidx);
    T1   = T0+7;
%     Tidx = find(NAV_Ts-T1>=0,1,'first');
%     if isempty(Tidx)
%         T1=T0;
%     else
%         T1   = min(TT-26,NAV_Ts(Tidx));
%     end
else
    T0=otherInput.T0;
    try
        T1=min(max(TT-13,otherInput.T1),T0+13);
    catch
        T1=T0+7;
    end
end
   lookBackT=min(52*3,floor(0.75*T0));
%    keyboard
%check if either distributions or smoothing functions are provided
if isfield(otherInput.Params0,'deltaFnPreset')==1
    idxDelta = find(otherInput.Params0.deltaFnPreset~=0, 3, 'first');
    if ~isempty(idxDelta) && min(fDsTime == idxDelta)==1
        try
            deltaFnPreset=otherInput.Params0.deltaFnPreset;
            deltaFnPreset=deltaFnPreset(1+yDatesNeedShift:TT+yDatesNeedShift);
            disp('pre-set distribution function is used')
            delta0=1; del_lb=1/1.05; del_ub=1.05; %parameter becomes a scaling factor
        catch
            delta0=0.06; del_lb=0.01; del_ub=0.5;
        end
    end
else
    delta0=0.05; del_lb=0.01; del_ub=0.5;
    deltaFnPreset=[];
end
if isfield(otherInput.Params0,'lambdaFnPreset')==1 && ~isempty(otherInput.Params0.lambdaFnPreset)
    lambdaFnPreset = otherInput.Params0.lambdaFnPreset;
    try
        lambdaFnPreset=otherInput.Params0.lambdaFnPreset(1+yDatesNeedShift:TT+yDatesNeedShift);
        disp('pre-set smoothing function is used')
        lambd0=1; lam_lb=0.99; lam_ub=1.01; % parameter becomes a scaling factor
    catch
        lambdaFnPreset=[];
        lambd0=0.9; lam_lb=0.01; lam_ub=0.995;
    end
end
uvar_h = mean(sig_vec(1:T0).^2);

%initialize the Outputs vector
FundOutput=[];
FundOutput.Details.T0=T0;
FundOutput.Details.T1=T1;
FundOutput.Details.TT=TT;


otherOutput=[];
otherOutput.T0_Dfrac = cumDfrac(T0);
otherOutput.TT_Dfrac = cumDfrac(TT);
otherOutput.TT_V2cumD= CFandVhatXt0(TT)/cumDfrac(TT);
otherOutput.CFandVhatXt0   =  CFandVhatXt0;
otherOutput.yFund    =  yFund;
otherOutput.rmt_lead =  rmt_lead;
otherOutput.rmt      =  rmt;
otherOutput.M0       =  M0(1:TT);


%setup initial parameter values, and their upper and lower bounds
if isfield(otherInput.Params0,'params')==0 && isfield(otherInput.Params0,'priorBet')==0
    disp('Initial paratemer value or anchors were not given, fallback values for BO funds from Ang et al. are used')
end
% note that alfa and psi are at weekly frequency

if ~exist('del_lb','var') || isempty(del_lb), delta0 = 0.05; del_lb = 0.01; del_ub = 0.5; deltaFnPreset = []; end
if ~exist('lambd0','var') || isempty(lambd0), lambd0 = 0.9; lam_lb = 0.01; lam_ub = 0.995; lambdaFnPreset = []; end
                % alfa  beta   delta   lambda   F    sig_d  sig_n   Fc    psi bet_i
ParamsFull0 =   [0      1.0   .02       lambd0  2    .01    .01    1.0  .001   0.2];
lbFull      =   [-.03   0.0    del_lb  lam_lb  0.1   0      .001   0.01  -.03   0.01];
ubFull      =   [+.03   4.0    del_ub  lam_ub  10    4.00   .20    5     +.03   1.51];

% by-default profile anchors are point&SE estimates for buyout funds from Ang et al
beta_pEst   =  1.25;
beta_pSE    =  0.25;
try
    ParamsFull0  =  otherInput.Params0.params;
    lbFull       =  otherInput.Params0.params_lb;
    ubFull       =  otherInput.Params0.params_ub;
catch
end
try
    beta_pEst   =  otherInput.Params0.priorBet(1);
    beta_pSE    =  otherInput.Params0.priorBet(2);
catch
end
ibet      =  fitlm(rmt(1:T0),rct(1:T0));
beta_c2m  =  [ibet.Coefficients{2,1}];
uvar_i    =  ibet.MSE;
uvar_m    =  var(rmt(1:T0));

otherOutput.beta_c2m =  beta_c2m;
otherOutput.icept_c2m = [ibet.Coefficients{1,1}];
otherOutput.uvar_m   =  uvar_m;
otherOutput.uvar_i   =  uvar_i;
otherOutput.uvar_h   =  uvar_h;

%% Step 2  -- profile alpha and beta estimates

%annulized alpha's range symmetric around the best guess
alfa_pa_range   = ( -0.035:.005:0.035)'; 
% alfa_pa_range   = [ -0.035 -0.03 (-.025:.0125:.025) 0.03 0.035]'; %coarsen the grid for speed
%percentiles range around priors for beta level from the literature (beta_pEst)
bet_pctl_range  = [0.01 (.05:.075:.95) 0.99]';
if beta_pSE<0.02 % in case we want beta to stick to the prior
    bet_pctl_range  = [.5]';
end
beta_p=beta_pEst; 

% 'for best-guess alpha' use using KortewegNagel 2020 bechmark portfolio
% method by with comp.asset's beta as a proxy for the fund's beta
T=T0;
rmadj=beta_p*cumsum(rmt(1:T))+.5*beta_p*(beta_p-1)*uvar_m*(1:1:T)';
    C_pv      = abs(CFandVhatXt0(1:T,1))./exp(rmadj); 
    D_pv      = abs(CFandVhatXt0(1:T,2))./exp(rmadj);
    pvCF      = [-1; D_pv-C_pv];
    % take T0 naive NAV nowcast as the terminal distributon
    lNAV_pv   = abs(CFandVhatXt0(T,3))./exp(rmadj(end));
    pvCF(end)=pvCF(end)+lNAV_pv;
    %fall-back annualized alpha estimate (if irr-solver fails) assumes duration is 70% of fund's life   
    cumC_pv   = cumsum(C_pv,1)+1;  % recall that 1st cointrib. rescaled to be 1
    cumD_pv   = cumsum(D_pv,1);
    pme_T     = log((cumD_pv(end)+lNAV_pv) / cumC_pv(end));
    Fdur_yrs  = 0.7*length(cumD_pv)/52;
    logpme_pa = pme_T / Fdur_yrs; 
try
       cfDatesVec=(now:7:now+length(pvCF)*7-1)';
       log_alfa_pa = log(1+xirr(pvCF(pvCF~=0),cfDatesVec(pvCF~=0)));  
    if isnan(log_alfa_pa) || ~isfinite(log_alfa_pa) 
       log_alfa_pa = logpme_pa;    
    end
catch
       log_alfa_pa = logpme_pa;   
end


%finilize alpha&beta range for profiling and present grids for SSM
%likelihood and penalty functions
Beta_range    = norminv(bet_pctl_range)*beta_pSE+beta_pEst; 
Alfa_range    = exp((log_alfa_pa+alfa_pa_range)/52)-1; 
ProfGridLlhd  = -Inf(length(Beta_range),length(Alfa_range)); 
ProfGridPlty  = -Inf(length(Beta_range),length(Alfa_range));
PenWgt        = 3;
ProfGridPlty2 = -Inf(length(Beta_range),length(Alfa_range));
ProfGridPars  = nan(length(Beta_range),length(Alfa_range),7); 

%%%% Setup the full observation vector, i.e. [d_t nav_t-1 rc_t+1]
%Assume that NAV appraiser do not "peak" beyond the report quarter
logNAVs       = [nan; yFund(1:end-1,2); nan(TT-length(yFund)-1,1) ];  
%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better to treat it as a nav report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 
logDs = [yFund(:,1); nan(TT-length(yFund),1)];
if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
    logNAVs(TT) = max( log( exp(logNAVs(TT))+exp(logDs(TT)) ) , logDs(TT) );
    logDs(TT)   = nan;
    M0(TT)=M0(TT-1); % likely redundant since the mapping-vlaue is lagged for NAV anyway
end
yFull = [logDs logNAVs [rct(2:TT); nan] ];

%Define the SSM model to profile alfa&beta w/o Comp.Asset and length T0
otherData=[];
otherData.UpdateMapping  = otherInput.UpdateMapping;
otherData.CFandVhatXt0   = CFandVhatXt0;
otherData.deltaFnPreset  = deltaFnPreset;
otherData.lambdaFnPreset = lambdaFnPreset;
otherData.rmt            = rmt;
otherData.rmt_lead       = rmt_lead;
otherData.sig_vec        = sig_vec;
otherData.resolvingDist  = 0; % since T0<TT the observation vector cannot have it

Params07 = ParamsFull0(1:7);
lb7      = lbFull(1:7);
ub7      = ubFull(1:7);
SSM_y2T0 = ssm(@(params)ParamMap_FundOnlySSM(params,T0,otherData));
y2_adjT0 = yFull(1:T0,1:2) + [log(M0(1:T0)) [ nan; log(M0(1:T0-1)) ] ];

warning('off','all')
parfor_progress(0);
dummy  = parfor_progress(16+length(Alfa_range)+1);
Aeq    = [1 0 0 0 0 0 0;  0 1 0 0 0 0 0 ];


%Loop to profile alpha and beta estimates
parfor p2=1:length(Alfa_range)
    llkhd   = nan(length(Beta_range),1);
    pnlty   = nan(length(Beta_range),1);
    estpars = nan(length(Beta_range),7);
    alpha_p = Alfa_range(p2);
    
    for p1=1:length(Beta_range)
        warning('off','all')
        beta_p = Beta_range(p1);
        beq    = [alpha_p; beta_p];
        try
            [estMdl_y2T0,estParam,~,estLL]=estimate(SSM_y2T0, y2_adjT0, Params07, ...
                'univariate',1,'tol',7.77e-14,'lb',lb7,'ub',ub7,'Aeq',Aeq,'beq',beq,'Display','off');
            llkhd(p1)     = estLL;
            estpars(p1,:) = estParam;
            lambda        = estParam(4);
            xhatb =smooth(estMdl_y2T0,y2_adjT0); %filter returns via backward recursion
%             obtain NAV smoothing bias (=rbar_1t-r_1t) estimate as of T0 and
%             recompute PME using bias-adjusted as-reported NAVs it as last distributions
            [~,~,~,NAVbiasEst]=StatesTimeAlign(xhatb,lambda,otherData);
            Vhat     = CFandVhatXt0(1:T0,3).*exp(-NAVbiasEst);
            PMEhat   = PMEtoDate(Vhat,rmt,T0,CFandVhatXt0,[alpha_p beta_p uvar_m ]);
            PME_T    = mean(PMEhat(end-1:end)); % average over last two quarters
            pnlty(p1)  = PME_T;
        catch
            llkhd(p1)     = nan;
            pnlty(p1)     = nan;
            estpars(p1,:) = Params07;
        end
    end
    ProfGridLlhd(:,p2)   = llkhd;
    ProfGridPlty(:,p2)   = pnlty;
    ProfGridPars(:,p2,:) = estpars;
    parfor_progress;
end
norm_Llhd      = (ProfGridLlhd-min(ProfGridLlhd(:),[],1,'omitnan'));  
norm_Llhd      =  norm_Llhd/nanstd(norm_Llhd(:),0,1);
norm_Plty      = (abs(ProfGridPlty-1)-min(abs(ProfGridPlty(:)-1),[],1,'omitnan'))/nanstd(abs(abs(ProfGridPlty(:)-1)),0,1);
penalized_Llhd =  norm_Llhd - PenWgt*norm_Plty; %overweight the penalty
penalized_Llhd(1,:)   =  penalized_Llhd(1,:)-1; % downweight exterme betas 
penalized_Llhd(end,:) =  penalized_Llhd(end,:)-1; % downweight edges betas


[~,LLidx]       = max(penalized_Llhd(:));
[maxRow,maxCol] = ind2sub(size(penalized_Llhd),LLidx);

estParam7 = squeeze(ProfGridPars(maxRow,maxCol,:))';
beq       = [Alfa_range(maxCol)+0.5*uvar_m*Beta_range(maxRow)*(1-Beta_range(maxRow)); Beta_range(maxRow)]; %% covert the ittercept for a fully log CAPM


FundOutput.profiling     = [];
FundOutput.profiling.alpha_range = Alfa_range;
FundOutput.profiling.beta_range  = Beta_range;

FundOutput.profiling.LlhdRaw  = ProfGridLlhd;
FundOutput.profiling.LlhdNrom = norm_Llhd;
FundOutput.profiling.Penalty  = norm_Plty;
FundOutput.profiling.LlhdPen  = penalized_Llhd;
FundOutput.profiling.betDomR  = mean(ProfGridLlhd(end,:))-mean(ProfGridLlhd(1,:));
FundOutput.profiling.alfDomR  = mean(ProfGridLlhd(:,end))-mean(ProfGridLlhd(:,1));
FundOutput.profiling.Frange   = max(ProfGridPlty2(:))-min(ProfGridPlty2(:));


if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
    otherData.resolvingDist=1;
end

SSM_y2   = ssm(@(params)ParamMap_FundOnlySSM(estParam7,TT,otherData));

y2_adjT0 = yFull(1:T0,1:2) + [log(M0(1:T0)) [ nan; log(M0(1:T0-1)) ] ];

Options=optimoptions('fmincon','UseParallel',true);
[estSSM_y2T0,EstParams7,~,MaxLL_y2PenT0]=estimate(SSM_y2, y2_adjT0, estParam7, ...
     'univariate',1,'tol',7.77e-14,'lb',lb7,'ub',ub7,'Aeq',Aeq,'beq',beq,'Display','off','Options',Options);  
% keyboard
otherData.uvar_f   =  uvar_h*EstParams7(5)^2;
otherData.uvar_f   =  uvar_h*3;
otherData.yFull  = yFull;
otherData.V0     = CFandVhatXt0(:,3);
otherData.M0     = M0;
otherData.lambda = EstParams7(4);
otherData.delta  = EstParams7(3);
otherData.lambda = EstParams7(4);
otherData.sigmad = EstParams7(6);
otherData.sigman = EstParams7(7);

otherData.Params0 = otherInput.Params0;

%Obtain nowcasts through T1 from SSM without Comp.Asset 
y2_adjT1 = yFull(1:T1,1:2) + [log(M0(1:T1)) [ nan; log(M0(1:T1-1)) ] ];
otherData.resolvingDist = 0;
otherData.Smooth=0;
[~,noCAvalues,~,~]  = AssetValueFromSSM(y2_adjT1,estSSM_y2T0,otherData);
VhatSSM_atT1    = noCAvalues.Vhat(end);
VhatNaive_atT1  = CFandVhatXt0(T1,3);

%Obtain nowcasts through TT from SSM without Comp.Asset 
if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
    otherData.resolvingDist=1;
end
y2_adjTT = yFull(1:TT,1:2) + [log(M0(1:TT)) [ nan; log(M0(1:TT-1)) ] ];
    otherData.yadj    = y2_adjTT;
    
[Khat,noCAvalues,~,rt]= AssetValueFromSSM(y2_adjTT,estSSM_y2T0,otherData); 
PME_1toTT_Vhat        = PMEtoDate(noCAvalues.Vhat,rt,TT,CFandVhatXt0,[]);
    SSM_FullErrMean   = nanmean(PME_1toTT_Vhat)-1; 
    SSM_FullRMSE      = sqrt(nanmean((PME_1toTT_Vhat-1).^2));
    SSM_InSampErrMean = nanmean(PME_1toTT_Vhat(T0-lookBackT:T1-1))-1; 
    SSM_InSampRMSE    = sqrt(nanmean((PME_1toTT_Vhat(T0-lookBackT:T1-1)-1).^2));
    SSM_hybridErrMean = nanmean(PME_1toTT_Vhat(T1:end))-1; 
    SSM_hybridRMSE    = sqrt(nanmean((PME_1toTT_Vhat(T1:end)-1).^2));
%take post-T1 cash flows and rescale them by asset value estimate as of T1
%which is assumed to be the first contribution
    CFs_postT1     = CFandVhatXt0(T1+1:TT,:)/VhatSSM_atT1;
    PME_T1toTT_NAV = PMEtoDate(CFs_postT1(:,3),rt(T1+1:TT),TT-T1,CFs_postT1,[]); 
    SSM_fosError   = PME_T1toTT_NAV(end)-1;
% ... now obtain FOS using the naive nowcast as of T1 and Comp.asset
    % CFs_postT1     = CFandVhatXt0(T1+1:TT,:)/VhatNaive_atT1;
    % PME_T1toTT_NAV = PMEtoDate(CFs_postT1(:,3),rct(T1+1:TT),TT-T1,CFs_postT1,[]); 
    % Naive_fosError = PME_T1toTT_NAV(end)-1;

    CFs_postT1           = CFandVhatXt0(T1+1:TT,:)/VhatNaive_atT1;
    PME_T1toTT_NAV_Naive = PMEtoDate(CFs_postT1(:,3),rct(T1+1:TT),TT-T1,CFs_postT1,[]); 
    Naive_fosError       = PME_T1toTT_NAV_Naive(end)-1;
    
    FundOutput.Details.PME_postT1_Naive = PME_T1toTT_NAV_Naive;
    FundOutput.Details.OOS_horizon_weeks = (T1+1:TT)';

    disp('--- DEBUG Naive OOS ---');
    fprintf('VhatNaive_atT1 = %g\n', VhatNaive_atT1);
    fprintf('rct post-T1 min/max = %g / %g\n', ...
        min(rct(T1+1:TT),[],'omitnan'), max(rct(T1+1:TT),[],'omitnan'));
    %fprintf('PME_T1toTT_NAV(end) for Naive = %g\n', PME_T1toTT_NAV(end));
    fprintf('PME_T1toTT_NAV_Naive(end) = %g\n', PME_T1toTT_NAV_Naive(end));
    fprintf('Naive_fosError = %g\n', Naive_fosError);

%the hybrid-method errors using naive nowcasts and Comp.asset
PME_1toTT_Naive     = PMEtoDate(CFandVhatXt0(:,3),rct,TT,CFandVhatXt0,[]);
    Naive_FullErrMean   = nanmean(PME_1toTT_Vhat)-1; 
    Naive_FullRMSE      = sqrt(nanmean((PME_1toTT_Vhat-1).^2));
    Naive_InSampErrMean = nanmean(PME_1toTT_Vhat(T0-lookBackT:T1-1))-1; 
    Naive_InSampRMSE    = sqrt(nanmean((PME_1toTT_Vhat(T0-lookBackT:T1-1)-1).^2));
    Naive_hybridErrMean = nanmean(PME_1toTT_Naive(T1:end))-1; 
    Naive_hybridRMSE    = sqrt(nanmean((PME_1toTT_Naive(T1:end)-1).^2));
FundOutput.Details.Naive_NE   = [Naive_InSampErrMean Naive_InSampRMSE Naive_hybridErrMean Naive_hybridRMSE Naive_fosError];

FundOutput.Details.PME_1toTT_Naive = PME_1toTT_Naive;

    otherData.estSSM    = estSSM_y2T0;
    otherData.yadj      = y2_adjT0;
    otherData.PenWgt    = PenWgt;
    otherData.estParam7 = EstParams7;
    otherData.rmt       = rmt;
    
    otherData.fix_alpha = EstParams7(1);
    otherData.fix_beta  = EstParams7(2);
    otherData.uvar_m    = uvar_m;
    otherData.resolvingDist = 0;

FundOutput.Details.MaxLL_y2PenT0  = MaxLL_y2PenT0;
FundOutput.Details.Params7noi     = EstParams7;
FundOutput.Details.rt_noCA_noi    = rt;

%standard errors for paramter estimates
StdErr = nan(7,1);
if otherInput.ComputeSE==1
    try
        StdErr  = avar_mle(@penalizedLL2,EstParams7,otherData);
    catch
    end
end
FundOutput.Details.Params7noi_SEs = StdErr';

%estimate fund returns' autocorrelations, beta, and alpha from filtered series
[rho, ols_a, ols_b, varest]  = RetProp(rt(1:TT),rmt(1:TT));
FundOutput.Details.rtProp_noCA_noi= [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];
%same but quarterly
wkCnt = [ (1:1:TT)'  [0; yFund(2:TT,2)] ];
wkCnt(isnan(wkCnt(:,2)),:) = []; wkCnt(:,2)=[];
blkDD = zeros(wkCnt(end),length(wkCnt)-1);
t0=1;  t1=wkCnt(2);  blkDD(t0:t1,1)=1;  
for ww = 2:length(wkCnt)-1
    t0 = wkCnt(ww)+1;
    t1 = wkCnt(ww+1);
    blkDD(t0:t1,ww)=1;
end
[rho, ols_a, ols_b, varest] = RetQprop(rt(1:wkCnt(end)),rmt(1:wkCnt(end)),blkDD);
FundOutput.Details.QrtProp_noCA_noi= [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];

FundOutput.Details.V_noCA_noi     = noCAvalues.Vhat;
FundOutput.Details.Bias_noCA_noi  = noCAvalues.NAVbias;
FundOutput.Details.Noise_noCA_noi = noCAvalues.NAVnoise;
FundOutput.Details.SSM_NE_noCA_noi= [SSM_InSampErrMean SSM_InSampRMSE SSM_hybridErrMean   SSM_hybridRMSE   SSM_fosError];
FundOutput.Details.CFandVhatXt0   = CFandVhatXt0;

otherOutput.K_noCA_noi    = Khat;
otherOutput.Kerr_noCA_noi = noCAvalues.sigma_v;

parhist0        = [0 EstParams7 nan nan nan  nan MaxLL_y2PenT0 ];

%legacy output structure
Legacy=[];
Legacy.estParam = [ EstParams7  FundOutput.Details.rtProp_noCA_noi(end-1)  FundOutput.Details.rtProp_noCA_noi(3)   nan nan nan   Naive_fosError SSM_fosError ...
                    Naive_FullErrMean Naive_InSampErrMean Naive_hybridErrMean ...
                    SSM_FullErrMean   SSM_InSampErrMean   SSM_hybridErrMean ...
                    Naive_FullRMSE    Naive_InSampRMSE    Naive_hybridRMSE ...
                    SSM_FullRMSE      SSM_InSampRMSE      SSM_hybridRMSE   cumDfrac(TT)-cumDfrac(T0)]  ;               
Legacy.estParamSE = [ StdErr' FundOutput.Details.rtProp_noCA_noi(end)  FundOutput.Details.rtProp_noCA_noi(4)  nan nan nan ];
    xhatb=smooth(estSSM_y2T0,y2_adjTT);
    xhatf=smooth(estSSM_y2T0,y2_adjTT);
    xhat =[zeros(size(xhatb,1),1) xhatb];
    xhat(:,1)  =exp(xhatf(:,2));
    xhat(:,end)=exp(xhatb(:,2))./Khat;
Legacy.xhat = xhat;
% keyboard

%returns implied by naive nowcasts
rt_naive = log(CFandVhatXt0(:,3)+CFandVhatXt0(:,2)-CFandVhatXt0(:,1))-[0; log(CFandVhatXt0(1:end-1,3))];
FundOutput.Details.Naive_rt       = rt_naive;
%properties at weekly frequency
[rho, ols_a, ols_b, varest] = RetProp(rt_naive(1:TT),rmt(1:TT));
FundOutput.Details.Naive_rtProp  = [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];
%also naive but at quarterly freq
[rho, ols_a, ols_b, varest] = RetQprop(rt_naive(1:wkCnt(end)),rmt(1:wkCnt(end)),blkDD);
FundOutput.Details.Naive_QrtProp = [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];


%% Step 3 -- Identify remaining parameters
 
ParamsXab0 = [EstParams7(3:end) ParamsFull0(8:10)];
lbXab      =  lbFull(3:10);
ubXab      =  ubFull(3:10);

%setup estimation loop and starting points
otherData.V0     = CFandVhatXt0(:,3);
otherData.M0     = M0;
%refine initial mapping as de-biased Naive nowcast
% keyboard

if otherInput.UpdateMapping==1
    otherData.V0 = CFandVhatXt0(:,3).*exp(-noCAvalues.NAVbias);
            dki_ = log(otherData.V0+CFandVhatXt0(1:end,2)-CFandVhatXt0(1:end,1))-log(otherData.V0);
       dki_(isnan(dki_))=0;
    otherData.M0 = exp(cumsum(dki_,1));
end
otherData.delta  = EstParams7(3);
otherData.lambda = EstParams7(4);
otherData.sigmad = EstParams7(6);
otherData.sigman = EstParams7(7);


otherData.resolvingDist = 0;
% keyboard
ii=0;
par_chg=1;
Parameters=[];
Models=[];
otherData.Smooth=1;
while par_chg>0.05
    ii=ii+1;
    warning('off','all')
    try
    rctMapTT = (ParamsXab0(end)*otherData.fix_beta-beta_c2m)*rmt_lead(1:TT); %analytica rct-adjustment
%     rctMapTT = zeros(TT,1); %analytica rct-adjustment
    y3_adjTT = yFull(1:TT,:) + [log(otherData.M0(1:TT)) [nan; log(otherData.M0(1:TT-1))] rctMapTT ];

    noObsTT = all(isnan(yFull(1:TT,:)),2);
    y3_adjTT(noObsTT,:) = 0;
    y3_adjTT(~isfinite(y3_adjTT) | ~isreal(y3_adjTT)) = 0;

    SSM_y3     =  ssm(@(params)ParamMap_FullSSM_fixedAlphaBeta(params,TT,otherData));
    
    otherData.resolvingDist=0;
    % --- Guard: M0 must be positive because we take log(M0) ---
    noObs = all(isnan(yFull(1:T0,:)), 2);     % weeks with no observations at all

    % Check not only whether it is <= 0, but also whether the number is real
    m0_bad_before = (~isfinite(otherData.M0) | ~isreal(otherData.M0) | real(otherData.M0)<=0);
    m0_badT0_before = sum(m0_bad_before(1:T0));
    m0_noObsT0 = sum(noObs);

    % --- Guard: M0 must be positive because we take log(M0) ---
    otherData.M0(noObs) = 1;
    otherData.M0(m0_bad_before) = 1;

    DBG_T0 = struct();
    DBG_T0.T0 = T0;
    DBG_T0.noObsT0 = m0_noObsT0;
    DBG_T0.badM0T0_before = m0_badT0_before;
    assignin('base','DBG_T0',DBG_T0);
    %otherData.M0(noObs) = 1;                  % neutral mapping -> log(1)=0
    %otherData.M0(~isfinite(otherData.M0) | otherData.M0<=0) = 1;

    y3_adjT0 = yFull(1:T0,:) + [log(otherData.M0(1:T0)) [nan; log(otherData.M0(1:T0-1))] rctMapTT(1:T0) ];
    % bad = ~isfinite(y3_adjT0) | ~isreal(y3_adjT0);
    % if any(bad,'all')
    %     disp('Non-finite or non-real observations detected in y3_adjT0:');
    %     [r,c] = find(bad);
    %     disp([r(1:min(20,end)) c(1:min(20,end))]); % first 20 locations
    %     disp('Example values:');
    %     for k=1:min(5,numel(r))
    %         fprintf('y3_adjT0(%d,%d) = %g\n', r(k), c(k), y3_adjT0(r(k),c(k)));
    %     end
    %     fprintf('Min/Max otherData.M0: %g / %g\n', min(otherData.M0), max(otherData.M0));
    %     fprintf('Count M0<=0: %d\n', sum(otherData.M0<=0));
    %     error('Stop: y3_adjT0 contains invalid observations');
    % end

    % Keep only rows where at least one observation is available (no all-NaN rows)
    keep = ~all(isnan(y3_adjT0), 2);
    % % If still any NaN/Inf remains in kept rows, drop those rows too (strict)
    % %keep = keep & all(isfinite(y3_adjT0), 2);
    y3_adjT0_est = y3_adjT0(keep, :);
    % 
    % % --- Check: estimation input must be finite & real (NaN allowed) ---
    badMask = (~isfinite(y3_adjT0_est) & ~isnan(y3_adjT0_est)) | ~isreal(y3_adjT0_est);

    DBG_Y = struct();
    DBG_Y.badCount = nnz(badMask);                  % how many bad counts are there
    DBG_Y.badRows  = find(any(badMask,2));          % which rows contain them
    DBG_Y.badCols  = find(any(badMask,1));          % which columns contain them
    assignin('base','DBG_Y',DBG_Y);

    if DBG_Y.badCount > 0
        error('Stop: y3_adjT0_est contains non-finite or non-real values. Check DBG_Y in workspace.');
    end
    % ---------------------------------------------------------------

    fprintf('Rows kept for estimation: %d out of %d\n', sum(keep), size(y3_adjT0,1));
    [estSSM_y3T0,EstParamsXab,~,LL_y3]=estimate(SSM_y3, y3_adjT0_est, ParamsXab0, ...
        'univariate',1,'tol',7.77e-14,'lb',lbXab,'ub',ubXab,'Display','off','Options',Options);
    LL_y3=LL_y3/1000;
    
        
    if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
        otherData.resolvingDist=1;
    else
        otherData.resolvingDist=0;
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%
    [Khat,Nowcasts,~,~] = AssetValueFromSSM(y3_adjTT,estSSM_y3T0,otherData); 

    %retain parameter estimates and full models from each interations
    Models     = [Models;{ii, estSSM_y3T0, Khat, LL_y3}];
    par_chg=sqrt(mean((EstParamsXab./ParamsXab0-1).^2));
    Parameters = [Parameters; [ii otherData.fix_alpha otherData.fix_beta EstParamsXab par_chg LL_y3]];

    %update input parameters for mapping in the next iteration
    otherData.uvar_f   =  uvar_h*EstParamsXab(3)^2;
    otherData.V0     = Nowcasts.Vhat;
    otherData.M0     = Khat;
    otherData.delta  = EstParamsXab(1);
    otherData.lambda = EstParamsXab(2);
    otherData.sigmad = EstParamsXab(4);
    otherData.sigman = EstParamsXab(5);
    ParamsXab0       = EstParamsXab;
        MaxLL_y3     = LL_y3;
    
    parfor_progress;
    
    if ii>14
        disp('Conversion difficulty, pick highest likelihood so far')

        if isempty(Models)
            error('ii>14: Model is empty. No successful conversion iteration to pick from.');
        end
       
        [~,LLidx]    = max(cell2mat(Models(:,end)));
        estSSM_y3T0  = Models{LLidx,2};
        otherData.M0 = Models{LLidx,3};
        EstParamsXab = Parameters(LLidx,4:11);
        MaxLL_y3     = Models{LLidx,4};
        break
    end
    catch ME
        rethrow (ME)
    end    
end
% keyboard
if CompAsset==3
    %%%%%%%%%%%%%%%%%%%%%%%%%%%
    %expanded parameter set for rct-adjustment via SSM w/ regressor
    ParamsPlus0 = [EstParamsXab (EstParamsXab(end)*otherData.fix_beta-beta_c2m)];
    BetAdjRge   = [(EstParamsXab(end)*0.25*otherData.fix_beta-beta_c2m) (EstParamsXab(end)*4*otherData.fix_beta-beta_c2m)];
    lbXabPlus   = [lbXab min(BetAdjRge)];
    ubXabPlus   = [ubXab max(BetAdjRge)];
    y3_adjTT = yFull(1:TT,:) + [log(otherData.M0(1:TT)) [nan; log(otherData.M0(1:TT-1))] zeros(TT,1) ];
    
    SSM_y3     =  ssm(@(params)ParamMap_FullSSM_fixedAlphaBeta_rcadj(params,y3_adjTT,TT,otherData));
    
    y3_adjT0 = yFull(1:T0,:) + [log(otherData.M0(1:T0)) [nan; log(otherData.M0(1:T0-1))] zeros(T0,1) ];
    [estSSM_y3T0,EstParamsPlus,~,~]=estimate(SSM_y3, y3_adjT0, ParamsPlus0, ...
        'univariate',1,'tol',7.77e-14,'lb',lbXabPlus,'ub',ubXabPlus,'Display','off');
    
    EstParamsXab=EstParamsPlus(1:end-1);
    otherData.delta  = EstParamsXab(1);
    otherData.lambda = EstParamsXab(2);
    otherData.sigmad = EstParamsXab(4);
    otherData.sigman = EstParamsXab(5);

end
    otherData.delta  = EstParamsXab(1);
    otherData.lambda = EstParamsXab(2);
    otherData.sigmad = EstParamsXab(4);
    otherData.sigman = EstParamsXab(5);

%Obtain nowcasts through TT from SSM with Comp.Asset 
    otherData.Smooth=1;
if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
    otherData.resolvingDist=1;
end
[Khat,FullNowcasts,~,rt] = AssetValueFromSSM(y3_adjTT,estSSM_y3T0,otherData);
if otherData.resolvingDist==1
   FullNowcasts.Vhat(end)=0; 
end
% keyboard
PME_1toTT_Vhat        = PMEtoDate(FullNowcasts.Vhat,rt,TT,CFandVhatXt0,[]);

    SSM_FullErrMean   = nanmean(PME_1toTT_Vhat)-1; 
    SSM_FullRMSE      = sqrt(nanmean((PME_1toTT_Vhat-1).^2));
    SSM_InSampErrMean = nanmean(PME_1toTT_Vhat(T0-lookBackT:T1-1))-1; 
    SSM_InSampRMSE    = sqrt(nanmean((PME_1toTT_Vhat(T0-lookBackT:T1-1)-1).^2));
    SSM_hybridErrMean = nanmean(PME_1toTT_Vhat(T1:end))-1; 
    SSM_hybridRMSE    = sqrt(nanmean((PME_1toTT_Vhat(T1:end)-1).^2));
    
    FundOutput.Details.PME_1toTT_SSM = PME_1toTT_Vhat;
%take post-T1 cash flows and rescale them by asset value estimate as of T1
%which is assumed to be the first contribution
    otherData.Smooth=1;
    otherData.resolvingDist = 0;
%     keyboard
% y3_adjT1   = yFull(1:T1,:) + [log(otherData.M0(1:T1)) [nan; log(otherData.M0(1:T1-1))] rctMapTT(1:T1) ];    
y3_adjT1   = yFull(1:T1,:) + [log(Khat(1:T1)) [nan; log(Khat(1:T1-1))] rctMapTT(1:T1) ];    
[~,ThruT1nowcasts,~,~]  = AssetValueFromSSM(y3_adjT1,estSSM_y3T0,otherData);
    VhatSSM_atT1   = ThruT1nowcasts.Vhat(end);

   disp('--- DEBUG OOS level comparison at T1 ---');
    fprintf('VhatSSM_atT1 = %g\n', VhatSSM_atT1);
    fprintf('FullNowcasts.Vhat(T1) = %g\n', FullNowcasts.Vhat(T1));
    fprintf('FullNowcasts.Vhat(T1+1) = %g\n', FullNowcasts.Vhat(T1+1));
    fprintf('Naive NAV at T1 = %g\n', CFandVhatXt0(T1,3));
    fprintf('Ratio FullNowcasts.Vhat(T1) / VhatSSM_atT1 = %g\n', FullNowcasts.Vhat(T1) / VhatSSM_atT1);
    
    disp('--- DEBUG SSM OOS alternative normalization test ---');
    CFs_postT1_alt = [CFandVhatXt0(T1+1:TT,1:2) FullNowcasts.Vhat(T1+1:TT)] / FullNowcasts.Vhat(T1);
    PME_T1toTT_NAV_alt = PMEtoDate(CFs_postT1_alt(:,3), rt(T1+1:TT), TT-T1, CFs_postT1_alt, []);
    SSM_fosError_alt = PME_T1toTT_NAV_alt(end) - 1;
    fprintf('PME_T1toTT_NAV(end) alt = %g\n', PME_T1toTT_NAV_alt(end));
    fprintf('SSM_fosError alt = %g\n', SSM_fosError_alt);

    %CFs_postT1     = [CFandVhatXt0(T1+1:TT,1:2) FullNowcasts.Vhat(T1+1:TT)] /VhatSSM_atT1;
%     CFs_postT1     = [CFandVhatXt0(T1+1:TT,1:2) FullNowcasts.Vhat(T1+1:TT)] / FullNowcasts.Vhat(T1);
% %     CFs_postT1     = [CFandVhatXt0(T1+1:TT,:) ] /VhatSSM_atT1;
%     PME_T1toTT_NAV = PMEtoDate(CFs_postT1(:,3),rt(T1+1:TT),TT-T1,CFs_postT1,[]); 
%     SSM_fosError   = PME_T1toTT_NAV(end)-1;

    CFs_postT1         = [CFandVhatXt0(T1+1:TT,1:2) FullNowcasts.Vhat(T1+1:TT)] / FullNowcasts.Vhat(T1);
    PME_T1toTT_NAV_SSM = PMEtoDate(CFs_postT1(:,3),rt(T1+1:TT),TT-T1,CFs_postT1,[]); 
    SSM_fosError       = PME_T1toTT_NAV_SSM(end)-1;

    FundOutput.Details.PME_postT1_SSM = PME_T1toTT_NAV_SSM;
    FundOutput.Details.OOS_horizon_weeks = (T1+1:TT)';

    disp('--- DEBUG SSM OOS ---');
    fprintf('T1 = %d, TT = %d\n', T1, TT);
    fprintf('VhatSSM_atT1 = %g\n', VhatSSM_atT1);
    fprintf('Naive NAV at T1 = %g\n', CFandVhatXt0(T1,3));
    fprintf('FullNowcasts.Vhat post-T1 min/max = %g / %g\n', ...
        min(FullNowcasts.Vhat(T1+1:TT),[],'omitnan'), ...
        max(FullNowcasts.Vhat(T1+1:TT),[],'omitnan'));
    fprintf('rt post-T1 min/max = %g / %g\n', ...
        min(rt(T1+1:TT),[],'omitnan'), max(rt(T1+1:TT),[],'omitnan'));
    %fprintf('PME_T1toTT_NAV(end) for SSM = %g\n', PME_T1toTT_NAV(end));
    fprintf('PME_T1toTT_NAV_SSM(end) = %g\n', PME_T1toTT_NAV_SSM(end));
    fprintf('SSM_fosError = %g\n', SSM_fosError);
    
%estimate fund returns' autocorrelations, beta, and alpha from smoohted series
[rho, ols_a, ols_b, varest]  = RetProp(rt(1:TT),rmt(1:TT));
FundOutput.Details.rtProp_i15= [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];
FundOutput.Details.SSM_NE_i15 = [SSM_InSampErrMean SSM_InSampRMSE SSM_hybridErrMean SSM_hybridRMSE SSM_fosError];


%estimate fund returns' autocorrelations, beta, and alpha from filtered series
otherData.Smooth=0;    
[~,KFnowcasts,~,rt_kf] = AssetValueFromSSM(y3_adjTT,estSSM_y3T0,otherData); 
FundOutput.BiastKF   = KFnowcasts.NAVbias;
FundOutput.rt_kf   = rt_kf;

[rho, ols_a, ols_b, varest]  = RetProp(rt_kf(1:TT),rmt(1:TT));
FundOutput.Details.rtPropKF_i15= [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];
otherData.Smooth=1;


%Record additional output 
otherOutput.M_i15      = Khat;
otherOutput.M_i15      = Khat;
otherOutput.sigv_i15   = FullNowcasts.sigma_v;
otherOutput.ParameterHist = [parhist0 ; Parameters];
otherOutput.Lambda_t      =  FullNowcasts.LambHat;
try
otherOutput.true_Vt       =  otherInput.Params0.TrueVs(1:TT)/otherInput.Params0.TrueVs(1);
catch
end

FundOutput.Details.ParamsFull = [otherData.fix_alpha otherData.fix_beta EstParamsXab(1:8)];
FundOutput.Vt      = FullNowcasts.Vhat;
FundOutput.rt      = rt;
FundOutput.Biast   = FullNowcasts.NAVbias;
FundOutput.Details.Noise_i15  = FullNowcasts.NAVnoise;
FundOutput.Details.MaxLL_i15  = MaxLL_y3;

otherData.estSSM      = estSSM_y3T0;
otherData.yadj        = y3_adjT0;
otherData.ParamsFull  = FundOutput.Details.ParamsFull;

%estimate standard errors for parameters estimates
StdErr = nan(10,1);
if otherInput.ComputeSE==1
    try
        StdErr  = avar_mle(@penalizedLL3,FundOutput.Details.ParamsFull,otherData);
    catch
    end
end
FundOutput.Details.ParamsFull_SEs = StdErr';

Legacy.estParami  = [ FundOutput.Details.ParamsFull(1:7) FundOutput.Details.rtProp_i15(end-1) ...
                    FundOutput.Details.rtProp_i15(3)  FundOutput.Details.ParamsFull(8:end) ...
                    Naive_fosError      SSM_fosError  ...
                    Naive_FullErrMean Naive_InSampErrMean Naive_hybridErrMean ...
                    SSM_FullErrMean   SSM_InSampErrMean   SSM_hybridErrMean ...
                    Naive_FullRMSE    Naive_InSampRMSE    Naive_hybridRMSE ...
                    SSM_FullRMSE      SSM_InSampRMSE      SSM_hybridRMSE   cumDfrac(TT)-cumDfrac(T0)]  ;
Legacy.estParamSEi = [ StdErr(1:7)' FundOutput.Details.rtProp_i15(end)  FundOutput.Details.rtProp_i15(4)  StdErr(8:end)' ];
    xhatb=smooth(estSSM_y3T0,y3_adjTT);
    xhatf=smooth(estSSM_y3T0,y3_adjTT);
    xhat =[zeros(size(xhatb,1),1) xhatb];
    xhat(:,1)  = exp(xhatf(:,2));
    xhat(:,end)= exp(xhatb(:,2))./Khat;
Legacy.xhati   = xhat;
Legacy.parhist = [parhist0 ; Parameters];
% keyboard

%filtered return series properties at quarterly freq
[rho, ols_a, ols_b, varest, q_rt] = RetQprop(rt(1:wkCnt(end)),rmt(1:wkCnt(end)),blkDD);
FundOutput.Details.QrtProp_i15= [ols_a.b ols_a.se ols_b.b ols_b.se varest.v1 varest.v2 rho.b rho.se ];
FundOutput.Details.Qrt_i15 = q_rt;                             
FundOutput.Details.VarParEstBased  = FundOutput.Details.ParamsFull(2)^2*uvar_m  + FundOutput.Details.ParamsFull(5)^2*uvar_i;


%% Produce additional output
if CFandVhatXt0(TT,2)>0 && CFandVhatXt0(TT,3)<0.01
    otherData.resolvingDist=1;
end
    otherData.Smooth=1;

% Nowcasting performance metrics using SSM-based NAVs but use the comp asset returns instead of
% the filtered returns
    CFs_postT1     = [CFandVhatXt0(T1+1:TT,1:2) FundOutput.Vt(T1+1:TT)]/VhatSSM_atT1;
%     CFs_postT1     = [CFandVhatXt0(T1+1:TT,:) ]/VhatSSM_atT1;
    PME_T1toTT_NAV = PMEtoDate(CFs_postT1(:,3),rct(T1+1:TT),TT-T1,CFs_postT1,[]); 
    Naive_fosError = PME_T1toTT_NAV(end)-1;

    disp('--- DEBUG Semi case: SSM NAV + Naive/CompAsset returns ---');
    fprintf('PME_T1toTT_NAV(end) = %g\n', PME_T1toTT_NAV(end));
    fprintf('Stored fosError = %g\n', Naive_fosError);

    PME_1toTT_Naive     = PMEtoDate(FundOutput.Vt,rct,TT,CFandVhatXt0,[]);
    Naive_InSampErrMean = nanmean(PME_1toTT_Naive(T0-lookBackT:T1-1))-1; 
    Naive_InSampRMSE    = sqrt(nanmean((PME_1toTT_Naive(T0-lookBackT:T1-1)-1).^2));
    Naive_hybridErrMean = nanmean(PME_1toTT_Naive(T1:end))-1; 
    Naive_hybridRMSE    = sqrt(nanmean((PME_1toTT_Naive(T1:end)-1).^2));
FundOutput.Details.SemiNaive_NE_i15   = [Naive_InSampErrMean Naive_InSampRMSE Naive_hybridErrMean Naive_hybridRMSE Naive_fosError];    
%now use filtered returns but as-reported NAVs
    CFs_postT1     = CFandVhatXt0(T1+1:TT,:)/CFandVhatXt0(T1,3);
    PME_T1toTT_NAV = PMEtoDate(CFs_postT1(:,3),rt(T1+1:TT),TT-T1,CFs_postT1,[]); 
    Naive_fosError = PME_T1toTT_NAV(end)-1;

    disp('--- DEBUG Semi case: Naive NAV + SSM returns ---');
    fprintf('PME_T1toTT_NAV(end) = %g\n', PME_T1toTT_NAV(end));
    fprintf('Stored fosError = %g\n', Naive_fosError);

    PME_1toTT_Naive     = PMEtoDate(CFandVhatXt0(:,3),rt,TT,CFandVhatXt0,[]);
    Naive_InSampErrMean = nanmean(PME_1toTT_Naive(T0-lookBackT:T1-1))-1; 
    Naive_InSampRMSE    = sqrt(nanmean((PME_1toTT_Naive(T0-lookBackT:T1-1)-1).^2));
    Naive_hybridErrMean = nanmean(PME_1toTT_Naive(T1:end))-1; 
    Naive_hybridRMSE    = sqrt(nanmean((PME_1toTT_Naive(T1:end)-1).^2));
FundOutput.Details.SemiNaive2_NE_i15  = [Naive_InSampErrMean Naive_InSampRMSE Naive_hybridErrMean Naive_hybridRMSE Naive_fosError];    


%now produce NAV nowcasts without observing the latest NAV report
%T0+1,...,+4 periods after T1 
NAV_Ts_postT0    = T0+find(~isnan(yFund(T0:end,2)),5,'first')-1;
             pT0 = NAV_Ts_postT0(end)-NAV_Ts_postT0(1)+1;
ssmRealTimeNAV   = nan(1,pT0);
SemiSSM_RT_NAV   = nan(1,pT0);
NaiveRealTimeNAV = nan(1,pT0);
SemiNaiveRT_NAV  = nan(1,pT0); 


for h=1:length(NAV_Ts_postT0)-1
    y3_adjT_             = y3_adjTT(1:NAV_Ts_postT0(h+1),:);
    y3_adjT_(end-1:end,2)= nan;
    [~,ExT4nowcast,~,rt] = AssetValueFromSSM(y3_adjT_,estSSM_y3T0,otherData);
    t0 = NAV_Ts_postT0(h)+1; t0r=t0-NAV_Ts_postT0(1)+1;
    t1 = NAV_Ts_postT0(h+1); t1r=t1-NAV_Ts_postT0(1)+1;
    
    ssmRealTimeNAV(t0r:t1r)    = ExT4nowcast.Vhat(t0:t1);
    
    NaiveNowcast = CFandVhatXt0(t0,3);   
    otherData.rct=rct;
    NaiveRealTimeNAV(t0r:t1r)  = NaiveRealTime(NaiveNowcast,t0,t1,otherData);
    SemiSSM_RT_NAV(t0r:t1r)    = NaiveRealTime(ExT4nowcast.Vhat(t0),t0,t1,otherData);
    
    otherData.rct=rt;
    SemiNaiveRT_NAV(t0r:t1r)   = NaiveRealTime(NaiveNowcast,t0,t1,otherData);
    
    if NAV_Ts_postT0(h+1)<TT
       otherData.resolvingDist = 0;
    else 
       otherData.resolvingDist = 1; 
    end
end
    y3_adjT_             = y3_adjTT(1:NAV_Ts_postT0(1),:);
    [~,T0nowcast,~,~] = AssetValueFromSSM(y3_adjT_,estSSM_y3T0,otherData);
NaiveRealTimeNAV(1) = CFandVhatXt0(NAV_Ts_postT0(1),3);
ssmRealTimeNAV(1)   = T0nowcast.Vhat(NAV_Ts_postT0(1));
try
    y3_adjT_ = y3_adjTT(1:NAV_Ts_postT0(end)+1,:);
catch
    y3_adjT_ = y3_adjTT;
end
[~,pT4nowcast,~,~] = AssetValueFromSSM(y3_adjT_,estSSM_y3T0,otherData);

FundOutput.Details.periods_T0T4        = NAV_Ts_postT0;
FundOutput.Details.NaiveRealTime_T0T4  = NaiveRealTimeNAV';
FundOutput.Details.SemiNaiveRT_NAV_T0T4= SemiNaiveRT_NAV';
FundOutput.Details.SemiSSM_RT_NAV_T0T4 = SemiSSM_RT_NAV';
% FundOutput.Details.ssmRealTimeNAV_T0T4 = ssmRealTimeNAV';
% FundOutput.Details.ssmNAV_T0T4         = pT4nowcast.Vhat(NAV_Ts_postT0(1):NAV_Ts_postT0(end));
% FundOutput.Details.Naive_T0T4          = CFandVhatXt0(NAV_Ts_postT0(1):NAV_Ts_postT0(end),3);
% FundOutput.Details.Naive_T0T4          = CFandVhatXt0(NAV_Ts_postT0(1):NAV_Ts_postT0(end),3);
nav_idx_local = NAV_Ts_postT0(1):NAV_Ts_postT0(end);

ssmNAV_raw = pT4nowcast.Vhat(nav_idx_local);
ssmRT_raw  = ssmRealTimeNAV';
naive_raw  = CFandVhatXt0(nav_idx_local,3);
repNAV_raw = exp(yFund(nav_idx_local,2));

% Compute a ratio at common observation points to rescale the SSM series to the NAV scale.
idx_scale = isfinite(ssmNAV_raw) & isfinite(repNAV_raw) & (ssmNAV_raw>0) & (repNAV_raw>0);

if any(idx_scale)
    k_ssm_to_nav = median(repNAV_raw(idx_scale) ./ ssmNAV_raw(idx_scale));
else
    k_ssm_to_nav = 1;
end

disp(['DEBUG: k_ssm_to_nav = ', num2str(k_ssm_to_nav)]);

FundOutput.Details.ssmNAV_T0T4         = ssmNAV_raw * k_ssm_to_nav;
FundOutput.Details.ssmRealTimeNAV_T0T4 = ssmRT_raw * k_ssm_to_nav;
FundOutput.Details.Naive_T0T4          = naive_raw;
FundOutput.Details.SSMtoNAVscaleK      = k_ssm_to_nav;

fprintf('repNAV_raw min/max: %g / %g\n', min(repNAV_raw,[],'omitnan'), max(repNAV_raw,[],'omitnan'));
fprintf('ssmNAV_raw min/max: %g / %g\n', min(ssmNAV_raw,[],'omitnan'), max(ssmNAV_raw,[],'omitnan'));
fprintf('ssmNAV_rescaled min/max: %g / %g\n', min(FundOutput.Details.ssmNAV_T0T4,[],'omitnan'), max(FundOutput.Details.ssmNAV_T0T4,[],'omitnan'));
fprintf('naive_raw min/max: %g / %g\n', min(naive_raw,[],'omitnan'), max(naive_raw,[],'omitnan'));

% % --- FIX: normalize Naive_T0T4 to the same scale as ssmNAV_T0T4 (T0-T4) ---
% ssmTmp = FundOutput.Details.ssmNAV_T0T4(:);
% naiTmp = FundOutput.Details.Naive_T0T4(:);
% idx = isfinite(ssmTmp) & isfinite(naiTmp) & (ssmTmp>0) & (naiTmp>0);
% if any(idx)
%     k = median(naiTmp(idx) ./ ssmTmp(idx));
%     disp(['DEBUG: applying Naive_T0T4 scaling, k=', num2str(k)]);
%     FundOutput.Details.Naive_T0T4 = FundOutput.Details.Naive_T0T4 ./ k;
%     FundOutput.Details.NaiveScaleK = k;   % store it for logging
% else
%     FundOutput.Details.NaiveScaleK = NaN;
% end
FundOutput.Details.NaiveScaleK = NaN;
disp('Naive_T0T4 manual k-scaling is disabled for debugging');
FundOutput.Details.ReportedNAVs_T0T4   = exp(yFund(NAV_Ts_postT0(1):NAV_Ts_postT0(end),2));
FundOutput.Details.Distributions_T0T4  = sum(CFandVhatXt0(NAV_Ts_postT0(1):NAV_Ts_postT0(end),2));
FundOutput.Details.Distributions_pT0   = sum(CFandVhatXt0(T0:end,2));

if isfield(otherInput.Params0,'TrueVs')==1
    TT=TT-1; %otherwise need to recode the terminal distributions
    
    TrueVs = otherOutput.true_Vt;
    FundOutput.Details.TrueVs_T0T4            =  TrueVs(NAV_Ts_postT0(1):NAV_Ts_postT0(end));
    FundOutput.Details.ssmRealTimeAerr_T0T4   = (ssmRealTimeNAV'-FundOutput.Details.TrueVs_T0T4);
    FundOutput.Details.NaiveRealTimeAerr_T0T4 = (NaiveRealTimeNAV'-FundOutput.Details.TrueVs_T0T4);
    FundOutput.Details.NaiveRealTimeErr_T0T4  = (NaiveRealTimeNAV'./FundOutput.Details.TrueVs_T0T4-1);
    FundOutput.Details.SemiNaive_RT_T0T4      = (SemiNaiveRT_NAV'./FundOutput.Details.TrueVs_T0T4-1);
    FundOutput.Details.SemiSSM_RT_Err_T0T4    = (SemiSSM_RT_NAV'./FundOutput.Details.TrueVs_T0T4-1);
    FundOutput.Details.ssmRealTimeErr_T0T4    = (ssmRealTimeNAV'./FundOutput.Details.TrueVs_T0T4-1);
    
    absT4 = min(TT,NAV_Ts_postT0(end));
    NAV_Ts_postT0=NAV_Ts_postT0-NAV_Ts_postT0(1)+1;
    
    %scalled by the first call
    FundOutput.Details.ssmNAVrmseA_vTru_pT0_RT     = [pT4nowcast.Vhat(T1)-TrueVs(T1) ...
        sqrt(mean((pT4nowcast.Vhat(T0+1:absT4)-TrueVs(T0+1:absT4)).^2)) ...
        sqrt(mean((FundOutput.Details.ssmRealTimeAerr_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.ssmRealTimeAerr_T0T4(NAV_Ts_postT0(2:end))).^2))];
    FundOutput.Details.NaiveNAVrmseA_vTru_pT0_RT  = [CFandVhatXt0(T1,3)-TrueVs(T1) ...
        sqrt(mean((FundOutput.Details.Naive_T0T4-FundOutput.Details.TrueVs_T0T4).^2)) ...
        sqrt(mean((FundOutput.Details.NaiveRealTimeAerr_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.NaiveRealTimeAerr_T0T4(NAV_Ts_postT0(2:end))).^2))];
    %scaled by true value of the assets
    FundOutput.Details.ssmNAVrmse_vTru_pT0_RT     = [pT4nowcast.Vhat(T1)/TrueVs(T1)-1 ...
        sqrt(mean((pT4nowcast.Vhat(T0+1:absT4)./TrueVs(T0+1:absT4)-1).^2)) ...
        sqrt(mean((FundOutput.Details.ssmRealTimeErr_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.ssmRealTimeErr_T0T4(NAV_Ts_postT0(2:end))).^2))];
    FundOutput.Details.SssmNAVrmse_vTru_pT0_RT    = [nan nan ...
        sqrt(mean((FundOutput.Details.SemiSSM_RT_Err_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.SemiSSM_RT_Err_T0T4(NAV_Ts_postT0(2:end))).^2))];
    FundOutput.Details.SNaiveNAVrmse_vTru_pT0_RT  = [nan nan ...
        sqrt(mean((FundOutput.Details.SemiNaive_RT_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.SemiNaive_RT_T0T4(NAV_Ts_postT0(2:end))).^2))];
    FundOutput.Details.NaiveNAVrmse_vTru_pT0_RT   = [CFandVhatXt0(T1,3)/TrueVs(T1)-1 ...
        sqrt(mean((FundOutput.Details.Naive_T0T4./FundOutput.Details.TrueVs_T0T4-1).^2)) ...
        sqrt(mean((FundOutput.Details.NaiveRealTimeErr_T0T4(2:end)).^2)) ...
        sqrt(mean((FundOutput.Details.NaiveRealTimeErr_T0T4(NAV_Ts_postT0(2:end))).^2))];
    
    temp=[FundOutput.Details.ssmNAVrmseA_vTru_pT0_RT; FundOutput.Details.ssmNAVrmse_vTru_pT0_RT; ...
        FundOutput.Details.SssmNAVrmse_vTru_pT0_RT; FundOutput.Details.SNaiveNAVrmse_vTru_pT0_RT; ...
        FundOutput.Details.NaiveNAVrmse_vTru_pT0_RT; FundOutput.Details.NaiveNAVrmseA_vTru_pT0_RT];
    FundOutput.NAVnowcastVtrueT0toT4 =array2table(temp,'RowNames',...
        {'SSMto1stCall','SSMtoTrueV','SSMnavButNaiveRet','SSMretButNaiveNAV','NaiveToTrueV','NaiveTo1stCall'},...
        'VariableNames',{'EstVtru_atT0','RMSE_HS_T0toT4','RMSE_RT_T1toT4','RMSE_RT_atT1T4'});
    
    temp=FundOutput.Details.periods_T0T4';
    numTs = length(NAV_Ts_postT0);
    if numTs==5
        FundOutput.RT_nowcastQuarters =array2table(temp,'RowNames',{'Week # since inception'},...
            'VariableNames',{'T0','T1','T2','T3','T4'});
    elseif numTs==4
        FundOutput.RT_nowcastQuarters =array2table(temp,'RowNames',{'Week # since inception'},...
            'VariableNames',{'T0','T1','T2','T4'});
    elseif numTs==3
        FundOutput.RT_nowcastQuarters =array2table(temp,'RowNames',{'Week # since inception'},...
            'VariableNames',{'T0','T1','T4'});
    elseif numTs==2
        FundOutput.RT_nowcastQuarters =array2table(temp,'RowNames',{'Week # since inception'},...
            'VariableNames',{'T0','T4'});
    end
    
    TT=TT+1;
    disp('Nowcasted vs True NAV stats added')
    otherOutput.TrueVs=otherInput.Params0.TrueVs(1:TT);
    otherOutput.TrueRs=(otherOutput.TrueVs+CFandVhatXt0(:,2)-CFandVhatXt0(:,1)) ...
                       ./[1; otherOutput.TrueVs(1:end-1)] - 1;
    FundOutput.Details.PME_1toTT_SSMrtVtruNAV = PMEtoDate(otherOutput.TrueVs,FundOutput.rt,TT,CFandVhatXt0,[]);
    FundOutput.Details.PME_1toTT_rctVtruNAV   = PMEtoDate(otherOutput.TrueVs,rct,TT,CFandVhatXt0,[]);
    FundOutput.Details.PME_1toTT_NairtVtruNAV = PMEtoDate(otherOutput.TrueVs,rt_naive,TT,CFandVhatXt0,[]);
    
end

try
    if otherInput.arithmetCAPM==1
        varAdj = 0.5*FundOutput.Details.rtProp_i15(5)...
               - 0.5*FundOutput.Details.ParamsFull(2)*(1-FundOutput.Details.ParamsFull(2))*uvar_m;
        FundOutput.Details.ParamsFull(1)=FundOutput.Details.ParamsFull(1) + varAdj;
        FundOutput.profiling.alpha_range=FundOutput.profiling.alpha_range + varAdj;
        Legacy.estParam(1) = Legacy.estParam(1) + varAdj;
        Legacy.estParami(1) = Legacy.estParami(1) + varAdj;
        disp('Parameters vector reports arithmetic CAPM alpha')
    end
catch
end
   
temp=[FundOutput.Details.Naive_rtProp([1 3 6 7]); FundOutput.Details.rtProp_i15([1 3 6 7]); FundOutput.Details.rtPropKF_i15([1 3 6 7]) ];
FundOutput.WeeklyReturnNowcastProperties =array2table(temp,'RowNames',{'Naive returns','SSM smoothed','SSM filtered'},...
    'VariableNames',{'olsAlfa','olsBeta','olsIdVar','AR1rho'});

temp=[T0 T0-lookBackT T0 T1 TT]';
FundOutput.Horizons =array2table(temp,'VariableNames',{'WeekSinceInception'},...
    'RowNames',{'Parameter Estimatioon Sample','First Week for in-Sample RMSE','Last Week for in-Sample RMSE',...
                'First week for OOS','Last week for OSS and Hybrid'});

temp=[FundOutput.Details.Naive_NE([2 4 5]);         FundOutput.Details.SemiNaive2_NE_i15([2 4 5]); ...
      FundOutput.Details.SemiNaive_NE_i15([2 4 5]); FundOutput.Details.SSM_NE_i15([2 4 5])];
FundOutput.NowcastErrs_at1QafterParEst = array2table(temp,'RowNames',{'Naive','NaiveNAVssmRet','SSMnavNaiveRet','SSM'},...
    'VariableNames',{'inSamplRMSE','HybridRMSE','OOSerr'});

temp=[FundOutput.Details.ParamsFull; FundOutput.Details.ParamsFull_SEs];
FundOutput.ParameterEstimates =array2table(temp,'RowNames',{'MLE coef','Numeric SE'},...
    'VariableNames',{'alpha','beta','delta','lambda','F','sigd','sign','Fc','psi','betai'});

 
 

% keyboard
warning('on','all')
dummy=parfor_progress(0);
end





function [A,B,C,D,Mean0,Cov0,StateType] = ParamMap_FundOnlySSM(params,T,otherData)
% This function implicitly defines the following state-space model:
% x_t = A(t)*x_{t-1} + B(t)*u_t
% y_t = C(t)*x_t     + D(t)*e_t

% Allocate parameters
alpha = params(1);
beta  = params(2);
delta = params(3);
lambd = params(4);
F     = params(5);
sigd  = params(6);
sign  = params(7);


lvec  = lambdaFun(lambd,T,otherData);
dstar = delStarFun(delta,T,otherData);
rm    = otherData.rmt_lead;
vol   = otherData.sig_vec;

%initialize state -- one the first one is realy stochastic (but stationary)
Mean0 = [0 0 0 1];
Cov0 = zeros(length(Mean0));
StateType = [0 0 0 1];
Cov0(1,1)=F*vol(1);
% Cov0(1,1)=0.05;

% Build the time-varying coefficient matrices
A = cell(T,1);
B = cell(T,1);
C = cell(T,1);
for t = 1:T
    A{t} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            0  1-lvec(t) lvec(t)  0;...
            0        0       0    1 ];
        
    B{t} = [F*vol(t) 0 0 0 ; zeros(3,4)];
    
    C{t} = [0   1   0  dstar(t);  0   0   1  0];
end
D = diag([sigd, sign]); % this matrix is fixed unless obs.vector includes resolving Dist.

%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better treat it as a NAV report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 
if otherData.resolvingDist==1
    D = cell(T,1);
    for t = 1:T-1
        D{t} = diag([sigd, sign]);
    end
    A{T} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            1   	 1       0    0;...
            0        0       0    1 ];    
    D{T} = diag([sigd, 0]);
end
% keyboard
end



function [A,B,C,D,Mean0,Cov0,StateType] = ParamMap_FullSSM_fixedAlphaBeta(params,T,otherData)
% This function implicitly defines the following state-space model:
% x_t = A(t)*x_{t-1} + B(t)*u_t
% y_t = C(t)*x_t     + D(t)*e_t

% Allocate parameters
alpha = otherData.fix_alpha;
beta  = otherData.fix_beta;

delta = params(1);
lambd = params(2);
F     = params(3);
sigd  = params(4);
sign  = params(5);

Fc    = params(6);
psi   = params(7);
beti  = params(8)';

lvec  = lambdaFun(lambd,T,otherData);
dstar = delStarFun(delta,T,otherData);
rm    = otherData.rmt_lead;
vol   = otherData.sig_vec;

%initialize state -- one the first one is realy stochastic (but stationary)
Mean0 = [0 0 0 1];
Cov0 = zeros(length(Mean0));
StateType = [0 0 0 1];
Cov0(1,1)=F*vol(1);
% Cov0(1,1)=0.05;

% Build the time-varying coefficient matrices
A = cell(T,1);
B = cell(T,1);
C = cell(T,1);
D = cell(T,1);

for t = 1:T
    A{t} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            0  1-lvec(t) lvec(t)  0;...
            0        0       0    1 ];
        
    B{t} = [F*vol(t) 0 0 0 ; zeros(3,4)];
    
    C{t} = [0     1    0   dstar(t);...
            0     0    1   0       ;...
            beti  0    0   psi ];
        
    D{t} = diag([sigd sign Fc*vol(t)]);
     
end

%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better treat it as a NAV report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 
if otherData.resolvingDist==1
    A{T} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            1   	 1       0    0;...
            0        0       0    1 ];    
    D{T} = diag([sigd 0 Fc*vol(T)]);
end
% keyboard
end

function [A,B,C,D,Mean0,Cov0,StateType,DeflateY] = ParamMap_FullSSM_fixedAlphaBeta_rcadj(params,y,T,otherData)
% This function implicitly defines the following state-space model:
% x_t = A(t)*x_{t-1} + B(t)*u_t
% y_t = C(t)*x_t     + D(t)*e_t

% Allocate parameters
alpha = otherData.fix_alpha;
beta  = otherData.fix_beta;

delta = params(1);
lambd = params(2);
F     = params(3);
sigd  = params(4);
sign  = params(5);

Fc    = params(6);
psi   = params(7);
beti  = params(8);

rcadj = params(9);

lvec  = lambdaFun(lambd,T,otherData);
dstar = delStarFun(delta,T,otherData);
rm    = rmt_lead;
vol   = otherData.sig_vec;

%initialize state -- one the first one is realy stochastic (but stationary)
Mean0 = [0 0 0 1];
Cov0 = zeros(length(Mean0));
StateType = [0 0 0 1];
Cov0(1,1)=F*vol(1);

% Build the time-varying coefficient matrices
A = cell(T,1);
B = cell(T,1);
C = cell(T,1);
D = cell(T,1);

for t = 1:T
    A{t} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            0  1-lvec(t) lvec(t)  0;...
            0        0       0    1 ];
        
    B{t} = [F*vol(t) 0 0 0 ; zeros(3,4)];
    
    C{t} = [0     1    0   dstar(t);...
            0     0    1   0       ;...
            beti  0    0   psi ];
        
    D{t} = diag([sigd sign Fc*vol(t)]);
     
end

%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better treat it as a NAV report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 
if otherData.resolvingDist==1
    A{T} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            1   	 1       0    0;...
            0        0       0    1 ];    
    D{T} = diag([sigd 0 Fc*vol(T)]);
end
% keyboard
DeflateY=y;
DeflateY(:,3)=y(:,3)+rcadj*otherData.rmt_lead;

end



function [A,B,C,D,Mean0,Cov0,StateType] = ParamMap_FullSSM(params10,T,otherData)
% This function implicitly defines the following state-space model:
% x_t = A(t)*x_{t-1} + B(t)*u_t
% y_t = C(t)*x_t     + D(t)*e_t

% Allocate parameters
alpha = params10(1);
beta  = params10(2);

delta = params10(3);
lambd = params10(4);
F     = params10(5);
sigd  = params10(6);
sign  = params10(7);

Fc    = params10(8);
psi   = params10(9);
beti  = params10(10);

lvec  = lambdaFun(lambd,T,otherData);
dstar = delStarFun(delta,T,otherData);
rm    = otherData.rmt_lead;
vol   = otherData.sig_vec;

%initialize state -- one the first one is realy stochastic (but stationary)
Mean0 = [0 0 0 1];
Cov0 = zeros(length(Mean0));
StateType = [0 0 0 1];
Cov0(1,1)=F*vol(1);

% Build the time-varying coefficient matrices
A = cell(T,1);
B = cell(T,1);
C = cell(T,1);
D = cell(T,1);

for t = 1:T
    A{t} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            0  1-lvec(t) lvec(t)  0;...
            0        0       0    1 ];
        
    B{t} = [F*vol(t) 0 0 0 ; zeros(3,4)];
    
    C{t} = [0     1    0   dstar(t);...
            0     0    1   0       ;...
            beti  0    0   psi ];
        
    D{t} = diag([sigd sign Fc*vol(t)]);
     
end

%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better treat it as a NAV report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 
if otherData.resolvingDist==1
    A{T} = [0        0       0    alpha+beta*rm(t);...
            1        1       0    0;...
            1   	 1       0    0;...
            0        0       0    1 ];    
    D{T} = diag([sigd 0 Fc*vol(T)]);
end

end


function [StdErr, VCV, H, I, Scores] = avar_mle(fxn,X,varargin)
%This function calculates the sandwich estimate of the MLE aVar matrix
%using the numerical differentiation techniques in "Applied Computational
%Economics and Finance" by Miranda and Fackler
otherData=varargin{1};

[f00, llik] = feval(fxn,X',otherData);
k = length(X); 
n = length(llik);
%Tolerance as in p. 104, eqn. 2 [estimation tolerances should be at least 1e-5]
h = eps.^(1/4).*max(abs(X),1); 
ee = sparse(1:k,1:k,h,k,k);

%Initiate Matrices
Scores = zeros(n,k); H = zeros(k,k);  
f0p = zeros(k,1); f0m = zeros(k,1); 
%Numeric approximation of f' (p. 98, eqn. 5.1)
parfor i = 1:k
    pX=X'+ee(:,i);
    [f0p(i), llikp] = feval(fxn,pX,otherData);
    mX=X'-ee(:,i);
    [f0m(i), llikm] = feval(fxn,mX,otherData);
    
    Scores(:,i) = (llikp-llikm)./(2*h(i)); 
end
%Numeric approximation of f'' (p. 102, eqn. 5)
diagH=zeros(k,1);
parfor i = 1:k
	diagH(i) = (f0p(i)-2*f00+f0m(i))./(h(i)*h(i));
    jj=zeros(1,k);
    for j = 1:i-1
          pX=X'+ee(:,i)+ee(:,j);
          fpp = feval(fxn,pX,otherData); 
          mX=X'-ee(:,i)-ee(:,j)
          fmm = feval(fxn,mX,otherData);
          
          jj(j) = (2*f00+fpp+fmm-f0p(i)-f0p(j)-f0m(i)-f0m(j))./(2*h(j).*h(i));
    end
    H(i,:) = jj;
end
H = H+diag(diagH);
H = (H+H') - eye(size(H,1)).*diag(H);    
I = (1/n).*Scores'*Scores;                      %Estimate of Information Matrix
H = (1/n).*H;                                   %Estimate of Hessian
VCV = (1/n).*(H\eye(k))*I*(H\eye(k));           %Sandwich Estimate of aVar
StdErr = sqrt(diag(VCV));
end

function [penLL, pllik] = penalizedLL2(params,otherData)
%this is an auxiliary function for Numerical SE estimation 
Aeq    = eye(length(params));
beq    = otherData.estParam7;
lambda = otherData.estParam7(4);

yadj   = otherData.yadj;
T      = length(yadj);
estMdl = otherData.estSSM;

setMdl   = ssm(@(params)ParamMap_FundOnlySSM(params,T,otherData));
[LL,llik] = getTVSSMloglikes(setMdl,yadj,params,'univariate',1,'tol',7.77e-14,'Aeq',Aeq,'beq',beq);

AlphaBetaVar = [otherData.fix_alpha otherData.fix_beta otherData.uvar_m];

xhatb  = smooth(estMdl,yadj);

[~,~,~,NAVbiasEst] = StatesTimeAlign(xhatb,lambda,otherData);

Vhat     = otherData.CFandVhatXt0(1:T,3).*exp(-NAVbiasEst(1:T));
PMEhat   = PMEtoDate(Vhat,otherData.rmt,T,otherData.CFandVhatXt0,AlphaBetaVar);
PME_T    = nanmean(PMEhat(T-52:T)); 

penaltyFn=abs(PME_T-1);

penLL=LL-LL*penaltyFn;
pllik=llik-LL*penaltyFn/T;

end


function [penLL, pllik] = penalizedLL3(params,otherData)
%this is an auxiliary function for Numerical SE estimation 
Aeq    = eye(length(params));
beq    = otherData.ParamsFull;
lambda = otherData.ParamsFull(4);

yadj   = otherData.yadj;
T      = length(yadj);
estMdl = otherData.estSSM;

setMdl   = ssm(@(params)ParamMap_FullSSM(params,T,otherData));
[LL,llik] = getTVSSMloglikes(setMdl,yadj,params,'univariate',1,'tol',7.77e-14,'Aeq',Aeq,'beq',beq);


AlphaBetaVar = [otherData.fix_alpha otherData.fix_beta otherData.uvar_m];

xhatb  = smooth(estMdl,yadj);

[~,~,~,NAVbiasEst] = StatesTimeAlign(xhatb,lambda,otherData);

Vhat     = otherData.CFandVhatXt0(1:T,3).*exp(-NAVbiasEst(1:T));
PMEhat   = PMEtoDate(Vhat,otherData.rmt,T,otherData.CFandVhatXt0,AlphaBetaVar);
PME_T    = nanmean(PMEhat(T-52:T)); % average over the last 3-4 quarters

penaltyFn=abs(PME_T-1);

penLL=LL-LL*penaltyFn;
pllik=llik-LL*penaltyFn/T;
 
end



function [Mhat,Values,r1t,rt] = AssetValueFromSSM(yadj,estMdl,otherData)
%This function refines the mapping between return and asset values to
%ensure that estimated asset values are (a) not too far from the reported 
%NAVs once unsmoothed, and (b) positive even if the period Contributiosn are removed.
%To achieve this, an auxiliary SSM is build to filter the change in the
%mapping, while using the NAV reports and intital mapping as noisy signals.
  
  T = length(yadj); 
  yrsi = (1:1:T)'/52;

  logNAVt = otherData.yFull(1:T,2); %logs of reported NAVs
  m0      = log(otherData.M0(1:T)); %asset-to-value mapping used in estMdl
  V0      = otherData.V0(1:T); %initial estimate of asset value

  lambda   = otherData.lambda;
  sigman   = otherData.sigman;
  sigmad   = otherData.sigmad;
  delta    = otherData.delta;
  
  logitDel = delStarFun(delta,T,otherData);
  
  Vnaiv    = abs(otherData.CFandVhatXt0(1:T,3)); %naive nowcasts
  Cs       = abs(otherData.CFandVhatXt0(1:T,1)); 
  Ds       = abs(otherData.CFandVhatXt0(1:T,2));

  if otherData.Smooth==1
      xhatb     = smooth(estMdl,yadj);
  else
      xhatb     = filter(estMdl,yadj);
  end
  [rt,r1t,rbar_1t,NAVbias,LambHat] ...
            = StatesTimeAlign(xhatb,lambda,otherData);

   %setup noisy signals about the asset-to-value mapping     
     mdt = logitDel+r1t-log(Ds);
     mdt(~isfinite(mdt)) = nan;
     mnt = rbar_1t-logNAVt;
        
% keyboard  
  %Since neither deltaStar nor new asset-to-value mapping are defined
  %for the terminal distribution, it is better treat it as a nav report  
  %but without either bias or noise. 
  if otherData.resolvingDist==1
     Vnaiv(end)  = Vnaiv(end)+Ds(end);
     mdt(end) = nan;
     mnt(end) = r1t(end)-log(Ds(end));
     Ds(end)     = 0;
     NAVbias(end)= 0;
  end
  
  Vunsm     = Vnaiv.*exp(-NAVbias); %NAVbias = rbar_1t-r1t
  
  % ----------------Old Version for dmFull--------------
  dmFull  =  log(V0 + Ds - Cs) - log(V0); % log change in mapping estimate increment
  err = (V0-Cs<=0); %rare but not impossible pathology
  dmFull(err) = log(0.0001+Ds(err)) - log(V0(err)); 

  y4m = [mdt  mnt];  %oservation vector for the aux.SSM

  navWeeks  = (~isnan(logNAVt));
  cfsWeeks  = (Cs-Ds~=0);

% setup mapping variance vector
  Ierr = ones(T,1); 
  Ierr(navWeeks==1 & cfsWeeks==0) = 0; % no mapping changes in weeks with NAVs only
  Ierr(Ds>Cs)=(1+(Ds(Ds>Cs)-Cs(Ds>Cs))./(V0(Ds>Cs)+Ds(Ds>Cs)-Cs(Ds>Cs)));
  Ierr(Cs>Ds)=(1+(Cs(Cs>Ds)-Ds(Cs>Ds))./(V0(Cs>Ds)+Ds(Cs>Ds)));
   
%only keep weeks 1 and w/ either CFs or NAVs
  SelectW = (navWeeks~=0 | cfsWeeks~=0);
  SelectW(1)=1;
  y4m = y4m(SelectW,:); 
  dm  = dmFull(SelectW);
  Ierr = Ierr(SelectW);
%take 1-period leads to allign state variables properly
  dm   = [dm(2:end); 0];       
  Ierr = [Ierr(2:end);0];
  
  noiseScale = sqrt(yrsi(SelectW));
  noiseScale = ones(length(noiseScale),1);
  
  %restrict the valuation error sd from prev. iteration to be between 1 and 25%:
  ub   = .25; 
  lb   = .01;
  sigman_vec=ones(length(y4m),1)*sigman./noiseScale;
  sigmad_vec=ones(length(y4m),1)*max(sigmad,0.05)./noiseScale;

%attmpt to imrove the NAV-to-return mapping (see I-A.2.1) 
  Mssm = ssm(@(sigmav)refineM(sigmav,sigman_vec,sigmad_vec,dm,Ierr));
try
    
  [estMssm,sigmav]   = estimate(Mssm,y4m,0.1,...
      'univariate',1,'tol',7.77e-14,'lb',lb,'ub',ub,'Display','off');
   logMestSelectW = smooth(estMssm,y4m); 
   logMchgSelectW = [logMestSelectW(1,2); logMestSelectW(2:end,2)-logMestSelectW(1:end-1,2)];
   logMchgAll     = zeros(length(m0),1);
   logMchgAll(SelectW) = logMchgSelectW(:,1);
   % checking for possible pathologies resulting from overly noisy NAVs and Ds
   MapErrS = ((logMchgAll<0&(Ds-Cs)>0)|(logMchgAll>0&(Ds-Cs)<0))&abs(dmFull)<=0.02&abs(logMchgAll)<=0.02;
   MapErrB = ((logMchgAll<0&(Ds-Cs)>0)|(logMchgAll>0&(Ds-Cs)<0))&(abs(dmFull)>0.02|abs(logMchgAll)>0.02);
%   [sum(MapErrB,1) sum(MapErrS)]
   if sum(MapErrB,1)>=1
%        keyboard
       sigmav=nan;
       Mhat=exp(m0); % fallback to the starting mapping if the refinement throws an error 
%        disp('reads fall back')
%        error('M falls back')
   else
      logMchgAll(MapErrS) = 0.25*dmFull(MapErrS); 
    Mhat=exp(cumsum(logMchgAll));
   end
%    logMchgAll(logMchgAll<0&(Ds-Cs)>0)=0.5*dmFull(logMchgAll<0&(Ds-Cs)>0); 
%    logMchgAll(logMchgAll>0&(Ds-Cs)<0)=0.5*dmFull(logMchgAll>0&(Ds-Cs)<0); 
catch
   sigmav=nan;
   Mhat=exp(m0); % fallback to the starting mapping if the refinement throws an error 
end
try
    if otherData.UpdateMapping==0
        Mhat=exp(m0); % fallback to the starting mapping
    end
catch
end
   Vhat      = exp(r1t)./Mhat; 
   
   % how much the de-smoothed naive nowcast is different from SSM-nowcast:
   NAVnoise  = log(Vunsm./Vhat); 
   Values = [];
   Values.Vhat      = Vhat;
   Values.NAVnoise  = NAVnoise;
   Values.NAVbias   = NAVbias;
   Values.sigma_v   = sigmav;
   Values.LambHat   = LambHat;
   
end


function [A,B,C,D,Mean0,Cov0,StateType] = refineM(sigmav,sigman,sigmad,dm,Ierr)
% This functions that defines the following state-space model to refine the
% asset to value mapping function
% x_t = A(t)*x_{t-1} + B(t)*u_t
% y_t = C(t)*x_t     + D(t)*e_t

%initialize state
StateType = [0 0 1];
Mean0     = [0 0 1];
Cov0      = zeros(length(Mean0));
% Cov0(1,1) = sigmav*Ierr(1);

% Build time-varying coefficient matrices
N = length(Ierr);
A = cell(N,1);
B = cell(N,1);
D = cell(N,1);
for n = 1:N
    A{n} = [ 0 0 dm(n); 1  1 0;  0  0 1 ];
    B{n} = [sigmav*Ierr(n) 0 0]';
    D{n} = [sigmad(n) 0 ;  0  sigman(n)];
end
C = [0 1 0; 0 1 0];



end



function PMEhat =PMEtoDate(Vhat,rt,T,CFandVhatXt0,AlphaBetaVar)
% This is an auxiliary function that computes PME-to-date given the asset value
% estimates from t=0,...,T   return series setup as r_tT and the
% corresponding series of Distributions and Contributiosn for each t
Ds    =  abs(CFandVhatXt0(1:T,2));
Cs    =  abs(CFandVhatXt0(1:T,1));
if isempty(AlphaBetaVar)
  cumr  =  cumsum(rt(1:T));
  r_tT  =  cumr(end) - cumr;

  D_fv    =  Ds.*exp(r_tT);
  C_fv    =  Cs.*exp(r_tT);
  cumD_fv =  cumsum(D_fv,1) .* exp(-r_tT);
  cumC_fv = (cumsum(C_fv,1) + exp(cumr(end))) .* exp(-r_tT);
%exp(cumr(end)) is the future value of the normalized to 1 initial Contribution 
else
    
  alpha    =  AlphaBetaVar(1);
  beta_m   =  AlphaBetaVar(2);
  uvar_m   =  AlphaBetaVar(3);
  try
      uvar_i = AlphaBetaVar(4);
  catch
      uvar_i = 0.0000; 
  end
  vardj    =  0.5*beta_m*(beta_m-1)*uvar_m*(1:T)';
%   vardj    =  0.5*(-uvar_i+beta_m*(beta_m-1)*uvar_m)*(1:T)';
  rmadj    =  alpha*(1:1:T)'+beta_m*cumsum(rt(1:T))+vardj;
  r_tT     =  rmadj(T) - rmadj;
  
  D_fv    =  Ds.*exp(r_tT);
  C_fv    =  Cs.*exp(r_tT);
  cumD_fv =  cumsum(D_fv,1) .* exp(-r_tT);
  cumC_fv = (cumsum(C_fv,1) + exp(rmadj(T))) .* exp(-r_tT);
  
end

PMEhat  = (Vhat(1:T)+cumD_fv)./cumC_fv;

end



function [rt,r_1t,rbar_1t,NAVbias,Lambda_vec]=StatesTimeAlign(xhat,lambda,otherData)
%this auxiliary function aligns and augments SSM output
T=length(xhat);

[Lambda_vec, lambdaT] = lambdaFun(lambda,T,otherData);
lambdaTb   = Lambda_vec(T); %since lambdaFun() returns a 1-week lagged series
if otherData.resolvingDist==1
    lambdaT    = 0;
end
rt_lead    =  xhat(:,1);
rt         = [xhat(1,2); rt_lead(1:end-1)];

r_1t       =  xhat(:,2);
r1tbar_lag =  xhat(:,3);

rbar_1Tb   = lambdaTb*r1tbar_lag(end-1) + (1-lambdaTb)*r_1t(end-1);
rbar_1t    = [r1tbar_lag(2:end-1);   rbar_1Tb; ...
              lambdaT*rbar_1Tb + (1-lambdaT)*r_1t(end)];

NAVbias    = rbar_1t-r_1t;

end



function DelStar_vec=delStarFun(delta,T,otherData)
%this is \delta(\cdot)_t function -- see Section 3 for details

Ds=otherData.CFandVhatXt0(1:T,2);
VsHat=otherData.CFandVhatXt0(1:T,3);

if isempty(otherData.deltaFnPreset)
   yrsi=min((1:1:T)'/52,12);   
   if isfield(otherData,'delCons')==0
      del0=0.00001; 
   else
      del0=delCons; 
   end   
   delFun  = max(0,min(0.99, del0 + delta*yrsi));  
else
   delFun  = delta*otherData.deltaFnPreset(1:T);
end

DelStar_vec = log( delFun./(1-delFun) );
DelStar_vec(~isfinite(DelStar_vec)) = 0; %parameter matricies must not have missing values

%Since neither deltaStar nor new asset-to-value mapping (K_T) are defined
%for the terminal distribution, it is better treat it as a nav report  
%but without either bias (set lambda()_T to 0) or noise (set the noise- 
%-sensitivity matrix to 0 for period T) and use K_T-1 as the mapping. 

% try
if Ds(T)>0 && VsHat(T)<0.01
   DelStar_vec(T) = 0; 
end
% catch
%     keyboard
% end

end  



function [Lambda_vec,LambT]=lambdaFun(lambda,T,otherData)
%this is \lambda(\cdot)_t function -- see Section 3 for details

Cs=otherData.CFandVhatXt0(1:T,1);
Ds=otherData.CFandVhatXt0(1:T,2);
VsHat=otherData.CFandVhatXt0(1:T,3);

if isempty(otherData.lambdaFnPreset)
    lamwgt_C=Cs./ VsHat;
    lamwgt_D=Ds./(Ds+VsHat);
    wt=lamwgt_C+lamwgt_D;
    scale=(ones(length(wt),1)-min(1,wt));
else
    scale  = otherData.lambdaFnPreset(1:T);
end

Lambda_vec=lambda*scale;
LambT = Lambda_vec(T);
Lambda_vec    = [0; Lambda_vec(1:end-1)];

% Lambda_vec    = [Lambda_vec(1); Lambda_vec(1); Lambda_vec(1:end-2)];
    
end  

function NaiveRealTimeNAV      = NaiveRealTime(V0,T_V0,nowcastT,otherData)
%this is an auxiliary functions to produce naive nowcasts
TT   = nowcastT - T_V0 +1;
Cs   = [0; otherData.CFandVhatXt0(T_V0+1:nowcastT,1)];
Ds   = [0; otherData.CFandVhatXt0(T_V0+1:nowcastT,2)];
rct  = [0; otherData.rct(T_V0+1:nowcastT)];

if isfield(otherData,'beta_scale')==0
    scale=1;
    drift=0;
else
    scale  = otherData.beta_scale;
    drift  = otherData.drift2fund;
end

NaiveRealTimeNAV=ones(TT,1)*V0;
for t = 2:TT
    NaiveRealTimeNAV(t) = NaiveRealTimeNAV(t-1)*exp(scale*rct(t)+drift)+Cs(t)-Ds(t);
end
end

function [rho, ols_a, ols_b, varest] = RetProp(rt,rmt)
%this is an auxiliary functions that summarizes the given return series rt properties
%rt and rmt are assumed to be in logs, and rmt is a risk factor 

rho=[];
ols_a=[];
ols_b=[];
varest=[];

AR1 = arima(1,0,0);
[AR1est,vcv]=estimate(AR1,exp(rt)-1,'Display','off');
AR1se     = sqrt(diag(vcv));

rho.se  = AR1se(2);
rho.b    = cell2mat(AR1est.AR(1));

ols  = fitlm(exp(rmt)-1,exp(rt)-1);
ols_a.b  = ols.Coefficients{1,1};
ols_a.se = ols.Coefficients{1,2};
ols_b.b  = ols.Coefficients{2,1};
ols_b.se = ols.Coefficients{2,2};

varest.v1 = ols.MSE;
varest.v2 = var(rt);
end

function [rho, ols_a, ols_b, varest, q_ret]  = RetQprop(rt,rmt,blkDD)
%this is an auxiliary functions that summarizes the given return series rt properties
%rt and rmt are assumed to be in logs, and rmt is a risk factor 
%it assumes the rt and rmt are weekly and aggreates them to quarterly

if nargin<3
    tempQ=floor(length(rt)/13)-1;
    tempC=repmat({ones(13,1)},1,tempQ);
    blkDD=blkdiag(tempC{:});
end

q_ret  = (rt(1:size(blkDD,1))'*blkDD)';
q_mret = (rmt(1:size(blkDD,1))'*blkDD)';

rho=[];
ols_a=[];
ols_b=[];
varest=[];
try
    AR1 = arima(1,0,0);
    [AR1est,vcv]=estimate(AR1,exp(q_ret)-1,'Display','off');
    AR1se     = sqrt(diag(vcv));
    
    rho.se  = AR1se(2);
    rho.b    = cell2mat(AR1est.AR(1));
    
catch
    rho.se=nan; rho.b=nan; varest.v1=nan; varest.v2=nan;
end
ols  = fitlm(exp(q_mret)-1,exp(q_ret)-1);
ols_a.b  = ols.Coefficients{1,1};
ols_a.se = ols.Coefficients{1,2};
ols_b.b  = ols.Coefficients{2,1};
ols_b.se = ols.Coefficients{2,2};
varest.v1 = ols.MSE;
varest.v2 = var(q_ret);
           
end
