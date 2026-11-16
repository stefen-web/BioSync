%% RESUMABLE BIOSYNC HEP MEAN AMPLITUDE EXTRACTION (350-600 ms)
%
% Reads ALREADY-COMPLETED BrainBeats HEP datasets. Does NOT rerun BrainBeats.
%
% HOW TO USE
%   1. Set data_root below (same path used by HEPv2.m and HRVv2.m).
%   2. Save this file and run it in MATLAB with EEGLAB installed.
%   3. Rerun any time: completed text reports are skipped; failed/incomplete
%      reports are retried, without interrupting other participants.
%
% INPUT (example)
%   BIOSYNC_DATA/027/027_resting1_HEP_Analysis/027_resting1_HEP.set
%
% OUTPUT (same directory as that HEP .set, NOT the original .set)
%   BIOSYNC_DATA/027/027_resting1_HEP_Analysis/
%       027_resting1_HEP_Analysis.txt
%
% Each report contains the arithmetic mean HEP amplitude across the
% 350-600 ms post-R-peak time points and across the saved heartbeat epochs,
% SEPARATELY for Cz, C3, C4, F3, F4, Fz, FC1, and FC2.
%
% BrainBeats may interpolate electrodes it detected as bad. Such channels
% are explicitly marked UNAVAILABLE instead of being treated as good data.
% Missing, nonfinite, or flat channels are also marked UNAVAILABLE.
% A recording is treated as successful if >=1 specified channel is valid;
% missing/faulty channels do not cause the recording to be retried forever.
% A recording with NO valid specified channels remains FAILED and is retried.
%
% BrainBeats plots may use a 20% trimmed mean; this report intentionally
% uses the ordinary ARITHMETIC mean requested, not a trimmed mean.
%
% ===== ONLY PATH YOU NEED TO EDIT =====
data_root = '/Users/atbender/Documents/BIOSYNC_DATA';

run_biosync_hep_mean_amplitude_batch(data_root);

%% ===== LOCAL FUNCTIONS =====

function run_biosync_hep_mean_amplitude_batch(data_root)
    if ~isfolder(data_root)
        error('BIOSYNC data folder does not exist: %s', data_root);
    end

    channels = {'Cz','C3','C4','F3','F4','Fz','FC1','FC2'};
    time_window_ms = [350 600];
    summary_file = fullfile(data_root, 'HEP_Mean_Amplitude_Batch_Summary.csv');

    % Find HEP ANALYSIS FOLDERS, not the original participant .set files.
    matches = [dir(fullfile(data_root, '*_HEP_Analysis')); ...
               dir(fullfile(data_root, '**', '*_HEP_Analysis'))];
    matches = matches([matches.isdir]);
    directories = cell(numel(matches),1);
    for i = 1:numel(matches)
        directories{i} = fullfile(matches(i).folder, matches(i).name);
    end
    directories = unique(directories);
    directories = sort(directories);

    n = numel(directories);
    if n == 0
        fprintf('No *_HEP_Analysis directories found in %s\n', data_root);
        return;
    end

    fprintf('Found %d HEP analysis folder(s).\n', n);
    % EEGLAB is used only to LOAD the finished HEP .set files.
    eeglab('nogui');

    source_sets = strings(n,1);
    output_files = strings(n,1);
    statuses = repmat("PENDING",n,1);
    computed_channels = zeros(n,1);
    elapsed_seconds = zeros(n,1);
    messages = strings(n,1);

    for i = 1:n
        folder = directories{i};
        [~, folder_name] = fileparts(folder);
        base_name = regexprep(folder_name, '_HEP_Analysis$', '', 'ignorecase');
        source_sets(i) = string(fullfile(folder, [base_name '_HEP.set']));
        output_files(i) = string(fullfile(folder, [folder_name '.txt']));
    end

    save_summary_safely(summary_file, directories, source_sets, ...
        output_files, statuses, computed_channels, elapsed_seconds, messages);

    for i = 1:n
        t_start = tic;
        hep_set = char(source_sets(i));
        result_txt = char(output_files(i));
        fprintf('\n[%d/%d] %s\n', i, n, directories{i});

        % Skip only a report with our completion signature and all 8 rows.
        % The folder or a partial .txt alone never counts as complete.
        if report_is_complete(result_txt, channels)
            statuses(i) = "SKIPPED";
            messages(i) = "Valid 350-600 ms report already exists";
            fprintf('  SKIPPED: report already completed.\n');
        else
            statuses(i) = "IN_PROGRESS";
            save_summary_safely(summary_file, directories, source_sets, ...
                output_files, statuses, computed_channels, elapsed_seconds, messages);
            try
                if ~isfile(hep_set)
                    error('Cannot find completed HEP dataset: %s', hep_set);
                end

                [means, notes, n_epochs, sample_range, unit] = ...
                    extract_from_hep_set(hep_set, channels, time_window_ms);
                n_valid = sum(isfinite(means));
                if n_valid == 0
                    error(['All eight requested electrodes were unavailable; ' ...
                           'no usable HEP amplitudes could be extracted.']);
                end

                % Atomic output: a crashed write cannot be mistaken for a
                % finished report when the script is run again.
                write_hep_report(result_txt, hep_set, channels, means, notes, ...
                    n_epochs, sample_range, unit, time_window_ms);
                if ~report_is_complete(result_txt, channels)
                    error('New report did not pass the completion check: %s',result_txt);
                end
                computed_channels(i) = n_valid;
                statuses(i) = "SUCCESS";
                messages(i) = sprintf('%d of %d electrode(s) calculated', ...
                    n_valid, numel(channels));
                fprintf('  SUCCESS: %d/%d electrodes. Saved: %s\n', ...
                    n_valid, numel(channels), result_txt);

            catch ME
                % A failure in one dataset must never stop other datasets.
                statuses(i) = "FAILED";
                messages(i) = string(ME.message);
                fprintf(2,'  FAILED: %s\n', ME.message);
                fprintf(2,'  (Will retry on the next run.)\n');
            end
        end

        elapsed_seconds(i) = toc(t_start);
        save_summary_safely(summary_file, directories, source_sets, ...
            output_files, statuses, computed_channels, elapsed_seconds, messages);
    end

    fprintf('\n====== HEP MEAN AMPLITUDE EXTRACTION FINISHED ======\n');
    fprintf('Analysis folders: %d\n', n);
    fprintf('New reports:      %d\n', nnz(statuses == "SUCCESS"));
    fprintf('Already complete: %d\n', nnz(statuses == "SKIPPED"));
    fprintf('Failed / retry:   %d\n', nnz(statuses == "FAILED"));
    fprintf('Batch summary:    %s\n',summary_file);
end

function [amplitudes, notes, n_epochs, sample_range, unit] = ...
        extract_from_hep_set(hep_set, channels, time_window_ms)
    % Read the HEP .set created by BrainBeats, NOT its source continuous .set.
    [folder,name,extension] = fileparts(hep_set);
    EEG = pop_loadset('filename',[name extension],'filepath',folder);
    EEG = eeg_checkset(EEG);

    if ~isfield(EEG,'epoch') || isempty(EEG.epoch) || EEG.trials < 1
        error('File is not a heartbeat-epoched HEP dataset: %s', hep_set);
    end
    if ~isfield(EEG,'data') || isempty(EEG.data) || ...
            ~isfield(EEG,'times') || isempty(EEG.times)
        error('HEP dataset does not contain usable EEG data or time points.');
    end
    if ~isfield(EEG,'chanlocs') || isempty(EEG.chanlocs)
        error('HEP dataset has no electrode labels.');
    end
    if size(EEG.data,1) ~= numel(EEG.chanlocs) || ...
            size(EEG.data,2) ~= numel(EEG.times)
        error('HEP data dimensions disagree with channel labels or time axis.');
    end
    if ndims(EEG.data) >= 3 && size(EEG.data,3) ~= EEG.trials
        error('HEP data epoch count does not match EEG.trials.');
    end

    t = double(EEG.times(:)); % EEGLAB times are milliseconds from R-peak
    dt = 1000 / double(EEG.srate);
    if ~all(isfinite(t)) || any(diff(t) <= 0)
        error('HEP time axis is not finite and strictly increasing.');
    end
    % BrainBeats sometimes crops to times STRICTLY LESS than 600 ms, so
    % its last sample may be just below 600 ms. Allow up to 2 sample steps.
    if t(1) > time_window_ms(1) || ...
            t(end) < time_window_ms(2) - 2*dt
        error('HEP epochs do not cover the required 350-600 ms window.');
    end
    time_idx = find(t >= time_window_ms(1) - 1e-6 & ...
                    t <= time_window_ms(2) + 1e-6);
    if isempty(time_idx)
        error('No EEG samples found in the 350-600 ms window.');
    end
    sample_range = [t(time_idx(1)), t(time_idx(end)), numel(time_idx)];
    n_epochs = EEG.trials;

    % Sources used by BrainBeats to record channels removed for low quality.
    % These may be interpolated back into EEG.data, so we MUST check them.
    rejected_labels = {};
    if isfield(EEG,'brainbeats') && isstruct(EEG.brainbeats)
        bb = EEG.brainbeats;
        if isfield(bb,'preprocessings') && isstruct(bb.preprocessings) && ...
                isfield(bb.preprocessings,'removed_eeg_channels')
            rejected_labels = as_channel_labels(bb.preprocessings.removed_eeg_channels);
        end
        if isfield(bb,'parameters') && isstruct(bb.parameters) && ...
                isfield(bb.parameters,'removed_eeg_channels')
            param_bad = as_channel_labels(bb.parameters.removed_eeg_channels);
            rejected_labels = [rejected_labels param_bad]; %#ok<AGROW>
        end
    end
    rejected_labels = unique(lower(strtrim(string(rejected_labels))));
    all_labels = strtrim(string({EEG.chanlocs.labels}));

    % The supplied HEPv2.m uses average reference, so amplitudes are uV.
    % Read an explicit unit if one was saved (e.g. uV/cm^2 for CSD).
    unit = 'uV';
    if isfield(EEG,'brainbeats') && isstruct(EEG.brainbeats) && ...
            isfield(EEG.brainbeats,'prestim') && ...
            isstruct(EEG.brainbeats.prestim) && ...
            isfield(EEG.brainbeats.prestim,'unit') && ...
            ~isempty(EEG.brainbeats.prestim.unit)
        saved_unit = EEG.brainbeats.prestim.unit;
        if ischar(saved_unit) || isstring(saved_unit)
            unit = char(saved_unit);
        end
    end

    amplitudes = nan(1,numel(channels));
    notes = repmat({'UNAVAILABLE'},1,numel(channels));
    for k = 1:numel(channels)
        label = channels{k};
        try
            matches = find(strcmpi(all_labels,label));
            if isempty(matches)
                notes{k} = 'UNAVAILABLE: electrode absent from HEP dataset';
                continue;
            end
            if numel(matches) > 1
                notes{k} = 'UNAVAILABLE: duplicate electrode label';
                continue;
            end
            if any(strcmpi(rejected_labels,label))
                notes{k} = ['UNAVAILABLE: BrainBeats flagged this electrode ' ...
                            'as bad (it may have been interpolated)'];
                continue;
            end

            % 1 electrode x selected time points x epochs -> all values.
            segment = double(EEG.data(matches,time_idx,:));
            segment = segment(:);
            if isempty(segment) || any(~isfinite(segment))
                notes{k} = 'UNAVAILABLE: missing, NaN, or infinite EEG samples';
                continue;
            end
            if max(segment) - min(segment) < 1e-10
                notes{k} = 'UNAVAILABLE: flat/constant EEG signal';
                continue;
            end

            % Equivalent to averaging the HEP waveform across heartbeats,
            % then taking its mean amplitude over 350-600 ms.
            amplitudes(k) = mean(segment);
            notes{k} = 'OK';
        catch channel_error
            notes{k} = ['UNAVAILABLE: ' one_line(channel_error.message)];
            % Continue with the next requested electrode.
        end
    end
end

function labels = as_channel_labels(value)
    labels = {};
    if isempty(value)
        return;
    end
    if ischar(value)
        labels = cellstr(value);
    elseif isstring(value)
        labels = cellstr(value(:));
    elseif iscell(value)
        for i = 1:numel(value)
            if ischar(value{i}) || isstring(value{i})
                labels{end+1} = char(value{i}); %#ok<AGROW>
            end
        end
    elseif isstruct(value) && isfield(value,'labels')
        labels = {value.labels};
    end
    labels = strtrim(labels);
end

function write_hep_report(result_txt, hep_set, channels, amplitudes, notes, ...
                          n_epochs, sample_range, unit, time_window_ms)
    [~, folder_name] = fileparts(fileparts(result_txt));
    partial_txt = [result_txt '.partial'];
    fid = fopen(partial_txt,'w');
    if fid < 0
        error('Could not open text report for writing: %s', partial_txt);
    end
    file_guard = onCleanup(@() fclose(fid));

    fprintf(fid,'HEARTBEAT-EVOKED POTENTIAL: MEAN AMPLITUDE REPORT\n');
    fprintf(fid,'Analysis folder: %s\n',folder_name);
    fprintf(fid,'HEP dataset: %s\n',hep_set);
    fprintf(fid,'Time window requested: %.0f-%.0f ms after ECG R-peak\n',time_window_ms);
    fprintf(fid,'Samples used: %.4f to %.4f ms (%d samples per epoch)\n',sample_range);
    fprintf(fid,'Valid saved heartbeat epochs: %d\n',n_epochs);
    fprintf(fid,'Units: %s\n',unit);
    fprintf(fid,['Statistic: ordinary arithmetic mean over all saved heartbeat ' ...
                 'epochs and all samples in the specified window.\n']);
    fprintf(fid,'Additional baseline correction by this script: none\n');
    fprintf(fid,['Faulty electrodes removed/interpolated by BrainBeats are ' ...
                 'not assigned amplitudes.\n\n']);
    fprintf(fid,'Electrode\tMean amplitude (%s)\tResult\n',unit);
    fprintf(fid,'------------------------------------------------------------\n');
    for k = 1:numel(channels)
        if isfinite(amplitudes(k))
            value = sprintf('%+.6f',amplitudes(k));
        else
            value = 'N/A';
        end
        fprintf(fid,'%s\t%s\t%s\n',channels{k},value,one_line(notes{k}));
    end
    fprintf(fid,'\nElectrodes calculated: %d/%d\n',sum(isfinite(amplitudes)),numel(channels));
    fprintf(fid,'REPORT_SIGNATURE: HEP_MEAN_350_600_v1\n');
    fprintf(fid,'EXTRACTION_STATUS: COMPLETE\n'); % MUST be the final line

    clear file_guard; % close file before rename
    [ok,msg] = movefile(partial_txt,result_txt,'f');
    if ~ok
        error('Could not finalize report (%s): %s',result_txt,msg);
    end
end

function tf = report_is_complete(path,channels)
    tf = false;
    if ~isfile(path)
        return;
    end
    try
        content = fileread(path);
        if ~contains(content,'REPORT_SIGNATURE: HEP_MEAN_350_600_v1')
            return;
        end
        if isempty(regexp(strtrim(content), ...
                'EXTRACTION_STATUS: COMPLETE$', 'once'))
            return;
        end
        for k = 1:numel(channels)
            % The tab ensures that each channel has a separate output row.
            if ~contains(content,sprintf('\n%s\t',channels{k}))
                return;
            end
        end
        tf = true;
    catch
        % A truncated/unreadable report is retried next run.
    end
end

function txt = one_line(txt)
    txt = regexprep(char(txt),'[\r\n\t]',' ');
end

function save_summary_safely(summary_file,directories,source_sets, ...
                              output_files,statuses,computed_channels, ...
                              elapsed_seconds,messages)
    % Summary is informational; its absence must never stop batch extraction.
    try
        summary = table(string(directories(:)),source_sets,output_files, ...
            statuses,computed_channels,elapsed_seconds,messages, ...
            'VariableNames',{'AnalysisFolder','HEPSetFile','ReportFile', ...
                             'Status','ElectrodesCalculated', ...
                             'ElapsedSeconds','Message'});
        partial = [summary_file '.partial'];
        writetable(summary,partial);
        [ok,msg] = movefile(partial,summary_file,'f');
        if ~ok
            fprintf(2,'Warning: could not save summary: %s\n',msg);
        end
    catch ME
        fprintf(2,'Warning: could not save summary: %s\n',ME.message);
    end
end
