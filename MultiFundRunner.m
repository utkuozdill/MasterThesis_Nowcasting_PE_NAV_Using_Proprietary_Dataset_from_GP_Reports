function MultiFundRunner()

    baseDir = pwd;  % run this in the python data cleaning folder
    dataDir = fullfile(baseDir, 'dropbox_batch/');
    outBase = fullfile(baseDir, 'output_multirun_dropbox');

    repcodePath = '/Users/utkuozdil/Desktop/TUM/Thesis/Repcode'; 

    if ~isfolder(outBase), mkdir(outBase); end

    d = dir(fullfile(dataDir, 'fund_*'));
    d = d([d.isdir]);
    fundFolders = {d.name};

    fund_id = strings(0,1);
    status  = strings(0,1);
    message = strings(0,1);

    fprintf('Found %d funds in %s\n', numel(fundFolders), dataDir);

    for i = 1:numel(fundFolders)
        ff = fundFolders{i};
        fid = erase(ff,'fund_');

        fundFolder = fullfile(dataDir, ff);
        fundOutDir = fullfile(outBase, ff);

        fprintf('\n[%d/%d] %s\n', i, numel(fundFolders), fid);

        try
            BatchTrialRunner(fundFolder, fundOutDir, repcodePath);

            fund_id(end+1,1) = string(fid);
            status(end+1,1)  = "SUCCESS";
            message(end+1,1) = "";

        catch ME
            if strcmp(ME.identifier, 'BATCH:SKIP')
                fund_id(end+1,1) = string(fid);
                status(end+1,1)  = "SKIPPED";
                message(end+1,1) = string(ME.message);
                fprintf('SKIPPED %s: %s\n', fid, ME.message);
                continue;
            end
            
            if ~isfolder(fundOutDir), mkdir(fundOutDir); end
            fidLog = fullfile(fundOutDir,'error.txt');
            fh = fopen(fidLog,'w');
            if fh ~= -1
                fprintf(fh,'%s\n', ME.getReport('extended','hyperlinks','off'));
                fclose(fh);
            end

            fund_id(end+1,1) = string(fid);
            status(end+1,1)  = "FAIL";
            message(end+1,1) = string(ME.message);

            fprintf('FAILED %s: %s\n', fid, ME.message);
        end
    end

    T = table(fund_id, status, message);
    writetable(T, fullfile(outBase,'batch_log.csv'));

    fprintf('SUCCESS count: %d\n', sum(status=="SUCCESS"));
    fprintf('SKIPPED count: %d\n', sum(status=="SKIPPED"));
    fprintf('FAIL count: %d\n', sum(status=="FAIL"));
    fprintf('\nDone. Log saved: %s\n', fullfile(outBase,'batch_log.csv'));
end