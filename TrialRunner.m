%% TRIAL RUNNER - Brown PE Nowcasting (Sectioned)
% Current Folder MUST be: .../TUM/Thesis/python data cleanin/

clc; clear; close all;

%% 0) SETTINGS (paths + fund id)

% Trial fund
FundID = '48b60287-d48d-4b8a-ae4c-7ebcedc99707';

% Data folder is relative to CURRENT FOLDER:
% ./Cleaned_Data_New/fund_<FundID>/r
BaseDataPath = fullfile(pwd, 'dropbox_batch/');
FundFolder   = fullfile(BaseDataPath, ['fund_' FundID]);

% Repcode path (CHANGE THIS to your real path)
RepcodePath = '/Users/utkuozdil/Desktop/TUM/Thesis/Repcode';

fprintf('Current Folder: %s\n', pwd);
fprintf('Fund Folder    : %s\n', FundFolder);
fprintf('Repcode Path   : %s\n\n', RepcodePath);

%% 1) ADD REPCODE TO PATH (do NOT move Brown files)
assert(isfolder(RepcodePath), 'RepcodePath not found. Fix the absolute path in the script.');
addpath(genpath(RepcodePath));

% Confirm PEfundSSM is visible
disp('Checking PEfundSSM on MATLAB path...');
which PEfundSSM -all

%% 2) CHECK FUND FILES EXIST
assert(isfolder(FundFolder), 'Fund folder not found. Check Current Folder or FundID.');

needFiles = {'Cs.csv','Ds.csv','yFund.csv','CFandVhat.csv','rmt.csv', 'rct.csv'};
for i = 1:numel(needFiles)
    f = fullfile(FundFolder, needFiles{i});
    assert(isfile(f), ['Missing file: ' f]);
end
disp('✅ All required files exist.');

%% 3) READ INPUTS
Cs = readmatrix(fullfile(FundFolder, 'Cs.csv'));
Ds = readmatrix(fullfile(FundFolder, 'Ds.csv'));

% Robust read for yFund (handles many NaNs / empty cells)
opts = delimitedTextImportOptions("NumVariables", 2);
opts.DataLines = [1 Inf];
opts.Delimiter = ";";
opts.VariableTypes = ["double","double"];
opts.ExtraColumnsRule = "ignore";
opts.EmptyLineRule = "read";

T = readtable(fullfile(FundFolder,'yFund.csv'), opts);
yFund = table2array(T);

% CFandVhat format: [Cs, Ds, NAV0]
CFandVhat = readmatrix(fullfile(FundFolder, 'CFandVhat.csv'));

% rmt format: weekly log market return
rmt = readmatrix(fullfile(FundFolder, 'rmt.csv'));

% rct format comp asset log returns
rct = readmatrix(fullfile(FundFolder, 'rct.csv'));

fprintf('Loaded: Cs=%d, Ds=%d, yFund=%dx%d, CFandVhat=%dx%d, rmt=%d, rct=%d\n\n', ...
    length(Cs), length(Ds), size(yFund,1), size(yFund,2), size(CFandVhat,1), size(CFandVhat,2), length(rmt), length(rct));


%% 4) SANITY CHECKS (to avoid "finite and real" errors)
assert(size(yFund,2)==2, 'yFund must be 2 columns: [logDist, logNAV].');
assert(length(Cs)==length(Ds), 'Cs and Ds length mismatch.');
assert(length(Cs)==size(yFund,1), 'Cs/Ds length must equal yFund rows.');
assert(size(CFandVhat,2)==3, 'CFandVhat must have 3 columns: [Cs Ds NAV0].');
assert(size(CFandVhat,1)==length(Cs), 'CFandVhat rows must match Cs length.');

assert(all(isfinite(rmt)), 'rmt contains NaN/Inf.');
assert(all(CFandVhat(:,3) > 0), 'NAV0 has <=0 values -> mapping/log may break.');
assert(~any(isinf(yFund(:))), 'yFund contains Inf -> likely log(0) slipped in.');

disp('✅ Sanity checks passed.');

%% 5) BUILD otherInput STRUCT (minimum required fields)  
otherInput = struct();
otherInput.CFandVhat = CFandVhat;
otherInput.rmt = rmt;
otherInput.rct = rct;

% Brown style: Params0 exists, presets empty (NOT NaN)
otherInput.Params0 = [];
otherInput.Params0.lambdaFnPreset = [];
otherInput.Params0.deltaFnPreset  = [];

otherInput.UpdateMapping = 1;
otherInput.ComputeSE = 1;
otherInput.arithmetCAPM = 0;

%% 5.1) RULE-BASED T0/T1 OVERRIDE (optional, to ensure dist exists in OOS window)
% Goal: pick a T0 such that there is at least some distribution activity after T1
% and enough NAV observations up to T0 for estimation.

minNavObs_uptoT0   = 7;   % minimum NAV observation for estimation 
minDistObs_afterT1 = 1;   % minimum distribution in OOS window (>=1; make it 2 if you want)
quarterWeeks       = 13;  % 1 quarter ≈ 13 wks
minT0              = 52;  % to avoid selectiong very early T0 (1 year)

idxNAV  = find(isfinite(yFund(:,2)));  % NAV observations (log NAV)
idxDist = find(Ds > 0);                % distribution weeks (cash flow schedule)
TT      = length(Cs);

T0_rule = NaN;
T1_rule = NaN;

% Candidate T0s: Select in weeks contain NAV observation 
candT0 = idxNAV(idxNAV >= minT0 & idxNAV <= (TT - 52));  % avoid very late T0 as well

for k = 1:numel(candT0)
    T0c = candT0(k);
    T1c = T0c + quarterWeeks;

    if T1c > TT
        continue
    end

    nav_upto = sum(idxNAV <= T0c);
    dist_after = sum(idxDist >= T1c);

    if (nav_upto >= minNavObs_uptoT0) && (dist_after >= minDistObs_afterT1)
        T0_rule = T0c;
        T1_rule = T1c;
        break
    end
end

if ~isnan(T0_rule)
    otherInput.T0 = T0_rule;
    otherInput.T1 = T1_rule;  % Uses it if available inside PEfundSSM
    fprintf('✅ Rule-based T0/T1 override applied: T0=%d, T1=%d | nav<=T0=%d | dist>=T1=%d\n', ...
        T0_rule, T1_rule, sum(idxNAV<=T0_rule), sum(idxDist>=T1_rule));
else
    fprintf('ℹ️ No rule-based T0 found (dist after T1 or NAV obs constraints). Using PEfundSSM default T0.\n');
end

%% 6) RUN MODEL
fprintf('\n⏳ Running PEfundSSM for Fund %s ...\n', FundID);
[FundOutput, otherOutput, ~] = PEfundSSM(yFund, otherInput);
fprintf('✅ PEfundSSM completed.\n\n');

%% 7) PRINT QUICK SUMMARY (fields may differ by version)
disp('--- Quick output summary (if fields exist) ---');
if isfield(FundOutput,'AlphaHat'),  fprintf('AlphaHat   : %.6f\n', FundOutput.AlphaHat); end
if isfield(FundOutput,'BetaHat'),   fprintf('BetaHat    : %.6f\n', FundOutput.BetaHat);  end
if isfield(FundOutput,'LambdaHat'), fprintf('LambdaHat  : %.6f\n', FundOutput.LambdaHat); end
if isfield(FundOutput,'sigma_nHat'),fprintf('sigma_nHat : %.6f\n', FundOutput.sigma_nHat); end
disp('Done.');
% ===== EXPORT LIKE CASE0 =====
outDir = fullfile(pwd,'Output');
if ~isfolder(outDir), mkdir(outDir); end
outXlsx = fullfile(outDir,'EstimationSummary.xlsx');
if isfile(outXlsx), delete(outXlsx); end

D = FundOutput.Details;
fprintf('\n--- POST-PEfundSSM CHECK ---\n');
if isfield(D,'NaiveScaleK')
    fprintf('NaiveScaleK: %g\n', D.NaiveScaleK);
else
    disp('NaiveScaleK field NOT found.');
end
fprintf('Naive_T0T4 min/max: %g / %g\n', min(D.Naive_T0T4,[],'omitnan'), max(D.Naive_T0T4,[],'omitnan'));
fprintf('ssmNAV_T0T4 min/max: %g / %g\n', min(D.ssmNAV_T0T4,[],'omitnan'), max(D.ssmNAV_T0T4,[],'omitnan'));

% 1) Direct tables (already exist)
writetable(FundOutput.Horizons, outXlsx, 'Sheet',1,'Range','A1','WriteRowNames',true);
writetable(FundOutput.ParameterEstimates, outXlsx, 'Sheet',1,'Range','A10','WriteRowNames',true);
writetable(FundOutput.NowcastErrs_at1QafterParEst, outXlsx, 'Sheet',1,'Range','A20','WriteRowNames',true);
writetable(FundOutput.WeeklyReturnNowcastProperties, outXlsx, 'Sheet',1,'Range','A30','WriteRowNames',true);

% 2) Build NAV T0-T4 table from Details
D = FundOutput.Details;

p  = D.periods_T0T4(:);
rep = D.ReportedNAVs_T0T4(:);
ssm = D.ssmNAV_T0T4(:);
ssmrt = D.ssmRealTimeNAV_T0T4(:);
naive = D.Naive_T0T4(:);
%snrt = D.SemiNaiveRT_NAV_T0T4(:);
%ssmrt2 = D.SemiSSM_RT_NAV_T0T4(:);

L = min([numel(p), numel(rep), numel(ssm), numel(ssmrt), numel(naive)]);

NAVtab = table();
NAVtab.periods = p(1:L);
NAVtab.ReportedNAV = rep(1:L);
NAVtab.SSM_NAV = ssm(1:L);
NAVtab.SSM_RT_NAV = ssmrt(1:L);
NAVtab.Naive_NAV = naive(1:L);
%NAVtab.SemiNaive_RT_NAV = snrt(1:L);
%NAVtab.SemiSSM_RT_NAV = ssmrt2(1:L);

fprintf('EXPORT CHECK -> Naive_NAV min/max: %g / %g\n', min(NAVtab.Naive_NAV,[],'omitnan'), max(NAVtab.Naive_NAV,[],'omitnan'));
%fprintf('EXPORT CHECK -> SemiNaive_RT_NAV min/max: %g / %g\n', min(NAVtab.SemiNaive_RT_NAV,[],'omitnan'), max(NAVtab.SemiNaive_RT_NAV,[],'omitnan'));
disp(outXlsx);

writetable(NAVtab, outXlsx, 'Sheet',1,'Range','A40');

disp(['✅ Wrote Excel: ' outXlsx]);

% %% 7.1) EXTRA TABLE: All reported NAV weeks (not only T0-T4)
% % Uses ALL weeks where yFund(:,2) is observed (reported NAV).
% % Compares Reported NAV (level) vs FundOutput.Vt (weekly nowcast, model scale)
% 
% Vt_all = FundOutput.Vt(:);
% T_all  = min(numel(Vt_all), size(yFund,1));
% 
% y2_all = yFund(1:T_all, 2);          % log(reported NAV), NaN if missing
% idxNAV_all = isfinite(y2_all);       % all weeks with reported NAV
% 
% AllNAVtab = table();
% AllNAVtab.week_index = find(idxNAV_all);
% AllNAVtab.ReportedNAV_level = exp(y2_all(idxNAV_all));
% AllNAVtab.SSM_Vt_level = Vt_all(idxNAV_all);
% AllNAVtab.SSM_over_Reported = AllNAVtab.SSM_Vt_level ./ AllNAVtab.ReportedNAV_level;
% 
% % Write as a new sheet in the SAME Excel
% writetable(AllNAVtab, outXlsx, 'Sheet', 'All_NAV_Obs');
% 
% disp('✅ Wrote sheet: All_NAV_Obs (all reported NAV weeks)');
% 
% % =============================

%% 8) PLOTS (Reported NAV vs Naive vs SSM) - SIMPLE SET

% --- output folder for figures ---
figDir = fullfile(pwd,'Output','Figures');
if ~isfolder(figDir), mkdir(figDir); end

% --- Basic series ---
V = FundOutput.Vt;                  
Tplot = min([numel(V), size(yFund,1)]);
Vplot = V(1:Tplot);
yFundPlot = yFund(1:Tplot,:);
navObsLvlPlot = exp(yFundPlot(:,2));
idxNavObsPlot = isfinite(navObsLvlPlot) & isfinite(Vplot);

% %% Plot 1: Vt
% figure('Name','Vt (weekly nowcast)','Color','w');
% plot(Vplot,'LineWidth',1.5);
% title('Weekly Nowcasted Fund Value (Vt)');
% xlabel('Week index'); ylabel('Vt (model scale)');
% grid on;
% saveFigBoth(figDir, '01_Vt_weekly_nowcast');
% 
% %% Plot 2: Vt vs Reported NAV (level)
% figure('Name','Vt vs Reported NAV (level)','Color','w');
% plot(Vplot,'LineWidth',1.5); hold on;
% scatter(find(idxNavObsPlot), navObsLvlPlot(idxNavObsPlot), 35, 'filled');
% title('Vt vs Reported NAV (level)');
% xlabel('Week index'); ylabel('Value (level)');
% legend({'Vt','Reported NAV'},'Location','best');
% grid on;
% saveFigBoth(figDir, '02_Vt_vs_ReportedNAV_level');
% 
% %% Plot 3: log(Vt) vs log(Reported NAV)
% figure('Name','log(Vt) vs log(Reported NAV)','Color','w');
% plot(log(Vplot),'LineWidth',1.5); hold on;
% scatter(find(isfinite(yFundPlot(:,2))), yFundPlot(isfinite(yFundPlot(:,2)),2), 35, 'filled');
% title('log(Vt) vs yFund(:,2) = log(Reported NAV)');
% xlabel('Week index'); ylabel('Log value');
% legend({'log(Vt)','log(Reported NAV)'},'Location','best');
% grid on;
%saveFigBoth(figDir, '03_logVt_vs_logReportedNAV');

% %% Plot 4: NAV comparison in T0-T4 window
% if isfield(FundOutput,'Details') && isfield(FundOutput.Details,'periods_T0T4')
%     D = FundOutput.Details;
% 
%     p     = D.periods_T0T4(:);
%     rep   = D.ReportedNAVs_T0T4(:);
%     ssm   = D.ssmNAV_T0T4(:);
%     naive = D.Naive_T0T4(:);
% 
%     L = min([numel(p), numel(rep), numel(ssm), numel(naive)]);
%     p=p(1:L); rep=rep(1:L); ssm=ssm(1:L); naive=naive(1:L);
% 
%     figure('Name','NAV comparison (T0-T4)','Color','w');
%     plot(p, ssm, 'LineWidth', 1.5); hold on;
%     plot(p, naive, 'LineWidth', 1.5);
%     scatter(p(isfinite(rep)), rep(isfinite(rep)), 45, 'filled');
%     title('Reported vs SSM vs Naive (T0-T4 window)');
%     xlabel('Week index'); ylabel('NAV (level)');
%     legend({'SSM NAV','Naive NAV','Reported NAV'},'Location','best');
%     grid on;
%     saveFigBoth(figDir, '04_NAV_comparison_T0T4');
% else
%     disp('Plot 4 skipped: FundOutput.Details.periods_T0T4 not found.');
% end
% 
disp("✅ Figures saved to: " + figDir);
% 
function saveFigBoth(figDir, baseName)
    % Save current figure to PNG + PDF
    pngPath = fullfile(figDir, [baseName '.png']);
    pdfPath = fullfile(figDir, [baseName '.pdf']);

    exportgraphics(gcf, pngPath, 'Resolution', 200);
    exportgraphics(gcf, pdfPath, 'ContentType', 'vector');
end
%% 11) EXTRA FIGURES FOR THESIS / MEETING

fprintf('\n--- CREATING EXTRA THESIS FIGURES ---\n');

%% Figure 05: Full-window SSM NAV + Reported NAV + Distributions
% Useful, because it mimics Brown-style single-fund intuition
% without showing the anchor-based naive line in the T0-T4 window.

try
    if isfield(FundOutput,'Vt') && exist('yFund','var')
        Vfull = FundOutput.Vt(:);

        if isfield(FundOutput,'Details') && isfield(FundOutput.Details,'SSMtoNAVscaleK') ...
                && isfinite(FundOutput.Details.SSMtoNAVscaleK) && FundOutput.Details.SSMtoNAVscaleK > 0
            kScale = FundOutput.Details.SSMtoNAVscaleK;
        else
            kScale = 1;
        end

        Tplot = min(numel(Vfull), size(yFund,1));
        weeks = (1:Tplot)';

        ssmNAV_full = Vfull(1:Tplot) * kScale;

        repNAV_full = nan(Tplot,1);
        idxRep = isfinite(yFund(1:Tplot,2));
        repNAV_full(idxRep) = exp(yFund(idxRep,2));

        dist_full = nan(Tplot,1);
        idxDist = isfinite(yFund(1:Tplot,1));
        dist_full(idxDist) = exp(yFund(idxDist,1));

        figure('Name','Full-window SSM NAV, reported NAV, distributions','Color','w');
        yyaxis left
        plot(weeks, ssmNAV_full, 'LineWidth', 1.6); hold on;
        scatter(weeks(idxRep), repNAV_full(idxRep), 28, 'filled');
        ylabel('NAV level');

        yyaxis right
        bar(weeks(idxDist), dist_full(idxDist), 0.8);
        ylabel('Distributions');

        xlabel('Week index');
        title('Single-fund path: SSM NAV, reported NAV, and distributions');
        legend({'SSM NAV','Reported NAV','Distributions'}, 'Location','best');
        grid on;

        saveFigBoth(figDir, '05_fullwindow_ssm_reported_distributions');
    end
catch ME
    warning('Figure 05 failed: %s', ME.message);
end

%% Figure 06: Reported NAV bias relative to SSM at observed NAV dates
% This is more informative than plotting naive in the anchor window.
% Positive values mean reported NAV > SSM NAV.

try
    if isfield(FundOutput,'Vt') && exist('yFund','var')
        Vfull = FundOutput.Vt(:);

        if isfield(FundOutput,'Details') && isfield(FundOutput.Details,'SSMtoNAVscaleK') ...
                && isfinite(FundOutput.Details.SSMtoNAVscaleK) && FundOutput.Details.SSMtoNAVscaleK > 0
            kScale = FundOutput.Details.SSMtoNAVscaleK;
        else
            kScale = 1;
        end

        Tplot = min(numel(Vfull), size(yFund,1));
        weeks = (1:Tplot)';

        ssmNAV_full = Vfull(1:Tplot) * kScale;

        idxRep = isfinite(yFund(1:Tplot,2));
        repWeeks = weeks(idxRep);
        repNAV = exp(yFund(idxRep,2));
        ssmAtRep = ssmNAV_full(idxRep);

        biasRatio = repNAV ./ ssmAtRep - 1;

        figure('Name','Reported NAV bias relative to SSM','Color','w');
        stem(repWeeks, biasRatio, 'filled');
        yline(0, '--');
        xlabel('Week index');
        ylabel('(Reported NAV / SSM NAV) - 1');
        title('Reported NAV bias relative to SSM at observed NAV dates');
        grid on;

        saveFigBoth(figDir, '06_reported_nav_bias_vs_ssm');
    end
catch ME
    warning('Figure 06 failed: %s', ME.message);
end

%% Figure 07: Grouped nowcast metrics (Naive vs SSM only)
% Uses the estimation summary table already produced by the model.

try
    if isfield(FundOutput,'NowcastErrs_at1QafterParEst') && istable(FundOutput.NowcastErrs_at1QafterParEst)
        Tm = FundOutput.NowcastErrs_at1QafterParEst;

        if isempty(Tm.Properties.RowNames)
            rowNames = string(1:height(Tm));
        else
            rowNames = string(Tm.Properties.RowNames);
        end

        % Keep only Naive and SSM rows
        rowNamesClean = lower(strtrim(rowNames));
        keepRows = ismember(rowNamesClean, ["naive","ssm"]);

        Tm = Tm(keepRows, :);
        rowNames = rowNames(keepRows);

        wantedVars = {'inSamplRMSE','HybridRMSE','OOSerr'};
        keepVars = ismember(wantedVars, Tm.Properties.VariableNames);
        wantedVars = wantedVars(keepVars);

        if ~isempty(wantedVars) && height(Tm) >= 1
            Y = Tm{:, wantedVars};

            figure('Name','Nowcast metrics by method','Color','w');
            bar(Y, 'grouped');

            ax = gca;
            ax.XColor = 'k';
            ax.YColor = 'k';
            ax.Color = 'w';

            xticks(1:numel(rowNames));
            xticklabels(rowNames);
            xlabel('Method', 'Color', 'k');
            ylabel('Metric value', 'Color', 'k');
            title('Nowcast metrics by method', 'Color', 'k');

            lgd = legend(wantedVars, 'Location','best');
            lgd.TextColor = 'k';
            lgd.Color = 'w';
            lgd.EdgeColor = 'k';

            grid on;

            saveFigBoth(figDir, '07_nowcast_metrics_grouped');
        else
            warning('Figure 07 skipped: required rows or variables not found.');
        end
    end
catch ME
    warning('Figure 07 failed: %s', ME.message);
end

%% Figure 08: OOS metric only, with zero line
% Nice for meetings because it isolates the controversial result.

try
    if isfield(FundOutput,'NowcastErrs_at1QafterParEst') && istable(FundOutput.NowcastErrs_at1QafterParEst)
        Tm = FundOutput.NowcastErrs_at1QafterParEst;

        if isempty(Tm.Properties.RowNames)
            rowNames = string(1:height(Tm));
        else
            rowNames = string(Tm.Properties.RowNames);
        end

        % Keep only Naive and SSM
        rowNamesClean = lower(strtrim(rowNames));
        keepRows = ismember(rowNamesClean, ["naive","ssm"]);

        Tm = Tm(keepRows,:);
        rowNames = rowNames(keepRows);

        if ismember('OOSerr', Tm.Properties.VariableNames)
            Y = Tm{:,'OOSerr'};

            figure('Name','Out-of-sample metric by method','Color','w');
            bar(Y);

            ax = gca;
            ax.XColor = 'k';
            ax.YColor = 'k';
            ax.Color = 'w';

            xticks(1:numel(rowNames));
            xticklabels(rowNames);
            xlabel('Method');
            ylabel('OOS error');
            title('Out-of-sample metric by method','Color','k');
            grid on;

            saveFigBoth(figDir, '08_oos_metric_by_method');
        end
    end
catch ME
    warning('Figure 08 failed: %s', ME.message);
end

% %% Figure 09: Return diagnostics - AR(1)
% % Brown emphasizes return diagnostics beyond RMSE.
% 
% try
%     if isfield(FundOutput,'WeeklyReturnNowcastProperties') && istable(FundOutput.WeeklyReturnNowcastProperties)
%         Tw = FundOutput.WeeklyReturnNowcastProperties;
% 
%         if isempty(Tw.Properties.RowNames)
%             rowNames = string(1:height(Tw));
%         else
%             rowNames = string(Tw.Properties.RowNames);
%         end
% 
%         if ismember('AR1rho', Tw.Properties.VariableNames)
%             figure('Name','AR(1) of nowcasted return series','Color','w');
%             bar(categorical(rowNames), Tw{:,'AR1rho'});
%             yline(0, '--');
%             xlabel('Method');
%             ylabel('AR(1)');
%             title('AR(1) diagnostic of nowcasted return series');
%             grid on;
% 
%             saveFigBoth(figDir, '09_return_diagnostic_ar1');
%         end
%     end
% catch ME
%     warning('Figure 09 failed: %s', ME.message);
% end

% %% Figure 10: Return diagnostics - OLS beta
% % Good for showing whether filtered returns imply more reasonable risk exposure.
% 
% try
%     if isfield(FundOutput,'WeeklyReturnNowcastProperties') && istable(FundOutput.WeeklyReturnNowcastProperties)
%         Tw = FundOutput.WeeklyReturnNowcastProperties;
% 
%         if isempty(Tw.Properties.RowNames)
%             rowNames = string(1:height(Tw));
%         else
%             rowNames = string(Tw.Properties.RowNames);
%         end
% 
%         if ismember('olsBeta', Tw.Properties.VariableNames)
%             figure('Name','OLS beta of nowcasted return series','Color','w');
%             bar(categorical(rowNames), Tw{:,'olsBeta'});
%             yline(1, '--');
%             xlabel('Method');
%             ylabel('OLS beta');
%             title('OLS beta diagnostic of nowcasted return series');
%             grid on;
% 
%             saveFigBoth(figDir, '10_return_diagnostic_beta');
%         end
%     end
% catch ME
%     warning('Figure 10 failed: %s', ME.message);
% end
% 
% disp(['✅ Extra thesis figures saved to: ' figDir]);
%% Figure 11: Observed NAV dates only - Reported vs SSM scatter
try
    if isfield(FundOutput,'Details')
        D = FundOutput.Details;

        if isfield(D,'ReportedNAVs_T0T4') && isfield(D,'ssmNAV_T0T4')
            rep = D.ReportedNAVs_T0T4(:);
            ssm = D.ssmNAV_T0T4(:);

            idx = isfinite(rep) & isfinite(ssm) & rep>0 & ssm>0;

            figure('Name','Observed NAV dates: Reported vs SSM','Color','w');
            scatter(rep(idx), ssm(idx), 45, 'filled'); hold on;

            mn = min([rep(idx); ssm(idx)]);
            mx = max([rep(idx); ssm(idx)]);
            plot([mn mx], [mn mx], '--', 'LineWidth', 1.2);

            ax = gca;
            ax.XColor = 'k';
            ax.YColor = 'k';
            ax.Color = 'w';

            xlabel('Reported NAV', 'Color', 'k');
            ylabel('SSM NAV', 'Color', 'k');
            title('Observed NAV dates only: Reported vs SSM', 'Color', 'k');
            grid on;

            saveFigBoth(figDir, '11_observed_nav_scatter_reported_vs_ssm');
        end
    end
catch ME
    warning('Figure 11 failed: %s', ME.message);
end

% 
%% Figure 13: OOS PME path comparison (the same paths used for table OOSerr)
try
    if isfield(FundOutput,'Details')
        D = FundOutput.Details;

        if isfield(D,'PME_postT1_Naive') && isfield(D,'PME_postT1_SSM')
            pmeNaive = D.PME_postT1_Naive(:);
            pmeSSM   = D.PME_postT1_SSM(:);

            L = min(numel(pmeNaive), numel(pmeSSM));
            pmeNaive = pmeNaive(1:L);
            pmeSSM   = pmeSSM(1:L);

            if isfield(D,'OOS_horizon_weeks')
                weeks = D.OOS_horizon_weeks(:);
                weeks = weeks(1:L);
            else
                weeks = (1:L)';
            end

            idx = isfinite(pmeNaive) & isfinite(pmeSSM) & isfinite(weeks);

            if any(idx)
                figure('Name','OOS PME path comparison','Color','w');
                plot(weeks(idx), pmeNaive(idx), 'LineWidth', 1.8); hold on;
                plot(weeks(idx), pmeSSM(idx),   'LineWidth', 1.8);
                yline(1, '--k', 'LineWidth', 1.0);

                if isfield(D,'T1') && isfinite(D.T1)
                    xline(D.T1, ':', 'T1', 'LabelVerticalAlignment','bottom','Color','k');
                end
                if isfield(D,'TT') && isfinite(D.TT)
                    xline(D.TT, ':', 'TT', 'LabelVerticalAlignment','bottom','Color','k');
                end

                ax = gca;
                ax.XColor = 'k';
                ax.YColor = 'k';
                ax.Color = 'w';

                xlabel('Week index','Color','k');
                ylabel('Post-T1 PME','Color','k');
                title('OOS PME path comparison: Naive vs SSM','Color','k');
                legend({'Naive post-T1 PME','SSM post-T1 PME','Reference = 1'}, 'Location','best');
                grid on;
                hold off;

                saveFigBoth(figDir, '13_oos_pme_path_naive_vs_ssm');
            else
                warning('Figure 13 skipped: no finite post-T1 PME values found.');
            end
        else
            warning('Figure 13 skipped: post-T1 PME series were not stored in FundOutput.Details.');
        end
    end
catch ME
    warning('Figure 13 failed: %s', ME.message);
end

%% Figure 14: Reported NAV deviation relative to SSM at observed NAV dates
try
    if isfield(FundOutput,'Vt') && exist('yFund','var')
        Vfull = FundOutput.Vt(:);

        if isfield(FundOutput,'Details') && isfield(FundOutput.Details,'SSMtoNAVscaleK') ...
                && isfinite(FundOutput.Details.SSMtoNAVscaleK) && FundOutput.Details.SSMtoNAVscaleK > 0
            kScale = FundOutput.Details.SSMtoNAVscaleK;
        else
            kScale = 1;
        end

        Tplot = min(numel(Vfull), size(yFund,1));
        weeks = (1:Tplot)';

        ssmNAV_full = Vfull(1:Tplot) * kScale;

        idxRep = isfinite(yFund(1:Tplot,2));
        repWeeks = weeks(idxRep);
        repNAV = exp(yFund(idxRep,2));
        ssmAtRep = ssmNAV_full(idxRep);

        idx = isfinite(repNAV) & isfinite(ssmAtRep) & repNAV > 0 & ssmAtRep > 0;
        repWeeks = repWeeks(idx);
        repNAV = repNAV(idx);
        ssmAtRep = ssmAtRep(idx);

        devRatio = repNAV ./ ssmAtRep - 1;

        figure('Name','Reported NAV deviation relative to SSM','Color','w');
        stem(repWeeks, devRatio, 'filled', 'LineWidth', 1.1); hold on;
        yline(0, '--k', 'LineWidth', 1.0);
        xlabel('Week index');
        ylabel('(Reported NAV / SSM NAV) - 1');
        title('Reported NAV deviation relative to SSM at observed NAV dates');
        grid on;
        hold off;

        saveFigBoth(figDir, '14_reported_nav_deviation_vs_ssm');
    end
catch ME
    warning('Figure 14 failed: %s', ME.message);
end

%% Table B: Window summary
try
    if isfield(FundOutput,'Details')
        D = FundOutput.Details;

        T0 = NaN; T1 = NaN; TT = NaN;
        if isfield(D,'T0'); T0 = D.T0; end
        if isfield(D,'T1'); T1 = D.T1; end
        if isfield(D,'TT'); TT = D.TT; end

        Twin = table(T0, T1, TT);

        writetable(Twin, fullfile(figDir, 'Table_window_summary.xlsx'));
        writetable(Twin, fullfile(figDir, 'Table_window_summary.csv'));
    end
catch ME
    warning('Window summary table export failed: %s', ME.message);
end