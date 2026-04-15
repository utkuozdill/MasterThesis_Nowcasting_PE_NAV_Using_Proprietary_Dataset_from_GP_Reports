function BatchTrialRunner(fundFolder, outFundDir, repcodePath)
% BatchTrialRunner - TrialRunner logic for one fund folder, batch-safe outputs
% fundFolder   : .../multibatch_run_funds/fund_<uuid>
% outFundDir   : .../output_multirun/fund_<uuid>
% repcodePath  : '/Users/.../Repcode'

    arguments
        fundFolder (1,:) char
        outFundDir (1,:) char
        repcodePath (1,:) char
    end

    % ---- NO clearvars here (batch-safe) ----
    close all;

    % --- Identify FundID from folder name ---
    [~, folderName] = fileparts(fundFolder);
    assert(startsWith(folderName,'fund_'), 'fundFolder must be .../fund_<FundID>');
    FundID = erase(folderName,'fund_');

    % --- Paths ---
    FundFolder = fundFolder;
    RepcodePath = repcodePath;

    fprintf('FundID         : %s\n', FundID);
    fprintf('Fund Folder    : %s\n', FundFolder);
    fprintf('Repcode Path   : %s\n', RepcodePath);

    %% 1) ADD REPCODE TO PATH
    assert(isfolder(RepcodePath), 'RepcodePath not found.');
    addpath(genpath(RepcodePath));

    %% 2) CHECK FUND FILES EXIST
    assert(isfolder(FundFolder), 'Fund folder not found.');
    needFiles = {'Cs.csv','Ds.csv','yFund.csv','CFandVhat.csv','rmt.csv','rct.csv'};
    for i = 1:numel(needFiles)
        f = fullfile(FundFolder, needFiles{i});
        assert(isfile(f), ['Missing file: ' f]);
    end

    %% 3) READ INPUTS
    Cs = readmatrix(fullfile(FundFolder, 'Cs.csv'));
    Ds = readmatrix(fullfile(FundFolder, 'Ds.csv'));

    opts = delimitedTextImportOptions("NumVariables", 2);
    opts.DataLines = [1 Inf];
    opts.Delimiter = ";";
    opts.VariableTypes = ["double","double"];
    opts.ExtraColumnsRule = "ignore";
    opts.EmptyLineRule = "read";

    T = readtable(fullfile(FundFolder,'yFund.csv'), opts);
    yFund = table2array(T);

    % --- Pre-check: minimum information to attempt estimation ---
    navObs  = sum(isfinite(yFund(:,2)));
    distObs = sum(isfinite(yFund(:,1)));

    fprintf('NAV obs=%d | Dist obs=%d\n', navObs, distObs);

    % 1) No distributions -> always skip
    if distObs == 0
        if ~exist(outFundDir,'dir'); mkdir(outFundDir); end
        fh = fopen(fullfile(outFundDir,'skip_reason.txt'),'w');
        if fh ~= -1
            fprintf(fh, 'Skipped: distObs=0 (no distributions). navObs=%d.\n', navObs);
            fclose(fh);
        end
        throw(MException('BATCH:SKIP', sprintf('Skipped: distObs=0 (no distributions). navObs=%d.', navObs)));
    end

    % 2) Very low information -> skip
    if (navObs < 6) || (distObs < 2)
        if ~exist(outFundDir,'dir'); mkdir(outFundDir); end
        fh = fopen(fullfile(outFundDir,'skip_reason.txt'),'w');
        if fh ~= -1
            fprintf(fh, 'Skipped: low information (navObs=%d, distObs=%d). ', navObs, distObs);
            fprintf(fh, 'Often triggers "objective undefined at initial point" in FMINCON.\n');
            fclose(fh);
        end
        warning('Skipping fund due to low information (navObs=%d, distObs=%d).', navObs, distObs);
        throw(MException('BATCH:SKIP', sprintf('Skipped: low information (navObs=%d, distObs=%d).', navObs, distObs)));
    end

    CFandVhat = readmatrix(fullfile(FundFolder, 'CFandVhat.csv'));
    rmt = readmatrix(fullfile(FundFolder, 'rmt.csv'));
    rct = readmatrix(fullfile(FundFolder, 'rct.csv'));

    fprintf('Loaded: Cs=%d, Ds=%d, yFund=%dx%d, CFandVhat=%dx%d, rmt=%d, rct=%d\n', ...
        length(Cs), length(Ds), size(yFund,1), size(yFund,2), ...
        size(CFandVhat,1), size(CFandVhat,2), length(rmt), length(rct));

    %% 4) SANITY CHECKS
    assert(size(yFund,2)==2, 'yFund must be 2 columns: [logDist, logNAV].');
    assert(length(Cs)==length(Ds), 'Cs and Ds length mismatch.');
    assert(length(Cs)==size(yFund,1), 'Cs/Ds length must equal yFund rows.');
    assert(size(CFandVhat,2)==3, 'CFandVhat must have 3 columns: [Cs Ds NAV0].');
    assert(size(CFandVhat,1)==length(Cs), 'CFandVhat rows must match Cs length.');

    assert(all(isfinite(rmt)), 'rmt contains NaN/Inf.');
    assert(all(isfinite(rct)), 'rct contains NaN/Inf.');
    assert(all(CFandVhat(:,3) > 0), 'NAV0 has <=0 values -> mapping/log may break.');
    assert(~any(isinf(yFund(:))), 'yFund contains Inf -> likely log(0) slipped in.');

    %% 5) BUILD otherInput STRUCT
    otherInput = struct();
    otherInput.CFandVhat = CFandVhat;
    otherInput.rmt = rmt;
    otherInput.rct = rct;

    otherInput.Params0 = [];
    otherInput.Params0.lambdaFnPreset = [];
    otherInput.Params0.deltaFnPreset  = [];

    otherInput.UpdateMapping = 1;
    otherInput.ComputeSE = 1;
    otherInput.arithmetCAPM = 0;

    %% 5.1) RULE-BASED T0/T1 OVERRIDE
    minNavObs_uptoT0   = 7;
    minDistObs_afterT1 = 1;
    quarterWeeks       = 13;
    minT0              = 52;

    idxNAV  = find(isfinite(yFund(:,2)));
    idxDist = find(Ds > 0);
    TT      = length(Cs);

    T0_rule = NaN;
    T1_rule = NaN;

    candT0 = idxNAV(idxNAV >= minT0 & idxNAV <= (TT - 52));

    for k = 1:numel(candT0)
        T0c = candT0(k);
        T1c = T0c + quarterWeeks;

        if T1c > TT
            continue
        end

        nav_upto   = sum(idxNAV <= T0c);
        dist_after = sum(idxDist >= T1c);

        if (nav_upto >= minNavObs_uptoT0) && (dist_after >= minDistObs_afterT1)
            T0_rule = T0c;
            T1_rule = T1c;
            break
        end
    end

    if ~isnan(T0_rule)
        otherInput.T0 = T0_rule;
        otherInput.T1 = T1_rule;
        fprintf('✅ Rule-based T0/T1 override applied: T0=%d, T1=%d | nav<=T0=%d | dist>=T1=%d\n', ...
            T0_rule, T1_rule, sum(idxNAV<=T0_rule), sum(idxDist>=T1_rule));
    else
        fprintf('ℹ️ No rule-based T0 found. Using PEfundSSM default T0/T1 handling.\n');
    end

    %% 6) RUN MODEL
    fprintf('Running PEfundSSM...\n');
    [FundOutput, otherOutput, ~] = PEfundSSM(yFund, otherInput);
    fprintf('✅ PEfundSSM completed.\n');

    disp('--- POST-PEfundSSM CHECK ---');
    D = FundOutput.Details;
    if isfield(D,'NaiveScaleK')
        fprintf('NaiveScaleK: %g\n', D.NaiveScaleK);
    else
        disp('NaiveScaleK field NOT found.');
    end
    fprintf('Naive_T0T4 min/max: %g / %g\n', min(D.Naive_T0T4,[],'omitnan'), max(D.Naive_T0T4,[],'omitnan'));
    fprintf('ssmNAV_T0T4 min/max: %g / %g\n', min(D.ssmNAV_T0T4,[],'omitnan'), max(D.ssmNAV_T0T4,[],'omitnan'));

    %% 7) EXPORT LIKE CASE0 (BUT TO outFundDir)
    if ~isfolder(outFundDir), mkdir(outFundDir); end
    outXlsx = fullfile(outFundDir,'EstimationSummary.xlsx');
    if isfile(outXlsx), delete(outXlsx); end

    writetable(FundOutput.Horizons, outXlsx, 'Sheet',1,'Range','A1','WriteRowNames',true);
    writetable(FundOutput.ParameterEstimates, outXlsx, 'Sheet',1,'Range','A10','WriteRowNames',true);
    writetable(FundOutput.NowcastErrs_at1QafterParEst, outXlsx, 'Sheet',1,'Range','A20','WriteRowNames',true);
    writetable(FundOutput.WeeklyReturnNowcastProperties, outXlsx, 'Sheet',1,'Range','A30','WriteRowNames',true);

    D  = FundOutput.Details;
    p  = D.periods_T0T4(:);
    rep = D.ReportedNAVs_T0T4(:);
    ssm = D.ssmNAV_T0T4(:);
    ssmrt = D.ssmRealTimeNAV_T0T4(:);
    naive = D.Naive_T0T4(:);

    L = min([numel(p), numel(rep), numel(ssm), numel(ssmrt), numel(naive)]);
    NAVtab = table();
    NAVtab.periods     = p(1:L);
    NAVtab.ReportedNAV = rep(1:L);
    NAVtab.SSM_NAV     = ssm(1:L);
    NAVtab.SSM_RT_NAV  = ssmrt(1:L);
    NAVtab.Naive_NAV   = naive(1:L);

    fprintf('EXPORT CHECK -> Naive_NAV min/max: %g / %g\n', ...
        min(NAVtab.Naive_NAV,[],'omitnan'), max(NAVtab.Naive_NAV,[],'omitnan'));

    writetable(NAVtab, outXlsx, 'Sheet',1,'Range','A40');
    disp(['✅ Wrote Excel: ' outXlsx]);

    %% 8) FIGURES -> outFundDir/figures
    figDir = fullfile(outFundDir,'figures');
    if ~isfolder(figDir), mkdir(figDir); end

    %% Figure 01: Grouped nowcast metrics (Naive vs SSM only)
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

            saveFigBoth(figDir, '01_nowcast_metrics_grouped');
        else
            warning('Figure 01 skipped: required rows or variables not found.');
        end
    end
catch ME
    warning('Figure 01 failed: %s', ME.message);
end

%% Figure 02: OOS metric only, with zero line
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

            saveFigBoth(figDir, '02_oos_metric_by_method');
        end
    end
catch ME
    warning('Figure 02 failed: %s', ME.message);
end


%% Figure 03: Observed NAV dates only - Reported vs SSM scatter
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

            saveFigBoth(figDir, '03_observed_nav_scatter_reported_vs_ssm');
        end
    end
catch ME
    warning('Figure 03 failed: %s', ME.message);
end

% 
%% Figure 04: OOS PME path comparison (the same paths used for table OOSerr)
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

                saveFigBoth(figDir, '04_oos_pme_path_naive_vs_ssm');
            else
                warning('Figure 04 skipped: no finite post-T1 PME values found.');
            end
        else
            warning('Figure 04 skipped: post-T1 PME series were not stored in FundOutput.Details.');
        end
    end
catch ME
    warning('Figure 04 failed: %s', ME.message);
end


end

function saveFigBoth(figDir_, baseName)
    pngPath = fullfile(figDir_, [baseName '.png']);
    pdfPath = fullfile(figDir_, [baseName '.pdf']);
    exportgraphics(gcf, pngPath, 'Resolution', 200);
    exportgraphics(gcf, pdfPath, 'ContentType', 'vector');
end