%% RESUMABLE Batch BrainBeats EEG and HRV Features — 32 EEG + ECG_1, excluding EGG
%
% HOW TO USE:
%   1) Set data_root below to the TOP data folder containing participants.
%   2) Save this file as tester_brainbeats_batch_resume.m.
%   3) Run tester_brainbeats_batch_resume in MATLAB (EEGLAB + BrainBeats required).
%   4) If interrupted, re-run the same command. Completed results are skipped.
%
% RESUME RULES:
%   - Already completed: validate the saved EEG/HRV feature results and SKIP.
%   - Previously failed: retry automatically.
%   - Never analyzed: run the full analysis.
%   - Analysis folder existing does NOT mean analysis completed.
%   - A missing, partial, or unreadable result .mat is NOT considered complete.
%   - Summary CSV is updated before and after every recording, so Ctrl+C
%     does not erase the status of earlier recordings.
%
% Example layout:
%   BIOSYNC_DATA/
%     027/
%       027_resting1.set
%       027_resting2.set
%     028/
%       028_resting1.set
%
% For each .set file, uses the same adjacent <dataset>_Analysis folder:
%   BIOSYNC_DATA/027/027_resting1_Analysis/
%     features_analysis_log.txt
%     027_resting1_brainbeats_features_results.mat
%     027_resting1_features.mat             (BrainBeats native export)
%     Figures/
%       Features_Figure_01.png
%
% Feature-specific file names preserve any earlier HEP analysis outputs
% inside the SAME _Analysis folder instead of overwriting them.
%
% All .set files in participant subfolders (including nested folders) are
% processed. Any existing *_Analysis folders are excluded from the search,
% so previously generated output .set files are NOT analyzed again.
% Failed datasets are logged, and the batch continues to the next dataset.
% A separate features CSV summary is updated after EACH recording in the
% top-level data folder. The completion check uses the final features
% results MAT file, not just a previous summary status or existing folder.
% Extracts HRV and EEG features in time, frequency, and nonlinear domains.
% HRV uses ECG and BrainBeats' default normalized Lomb-Scargle periodogram.
% EEG is cleaned in continuous mode (ASR + ICA/ICLabel) with 1-40 Hz filtering.
% Recordings too short for some HRV metrics may produce warnings or missing
% metrics; the BrainBeats length checks are preserved.
% REQUIRES: MATLAB, EEGLAB, and the BrainBeats plugin.


% ===== ONLY PATH YOU NEED TO EDIT =====
data_root = '/Users/atbender/Documents/BIOSYNC_DATA';

run_brainbeats_features_batch_resume(data_root);

%% ===== LOCAL FUNCTIONS (no changes needed below) =====

function run_brainbeats_features_batch_resume(data_root)
    if ~isfolder(data_root)
        error('Data folder not found: %s', data_root);
    end

    % The validated montage used in the working single-file script.
    ecg_channel = 'ECG_1';
    preprocess_eeg = true;
    power_line_hz = 60;
    % This is the features mode, not heartbeat-evoked potential (HEP) mode.
    % Set true only if the Parallel Computing Toolbox is available and
    % you want BrainBeats to use a parallel pool for feature calculation.
    use_parallel = false;

    eeg_channels = { ...
        'Fp1', 'Fz', 'F3', 'F7', 'FT9', 'FC5', 'FC1', 'C3', ...
        'T7', 'TP9', 'CP5', 'CP1', 'Pz', 'P3', 'P7', 'O1', ...
        'Oz', 'O2', 'P4', 'P8', 'TP10', 'CP6', 'CP2', 'Cz', ...
        'C4', 'T8', 'FT10', 'FC6', 'FC2', 'F4', 'F8', 'Fp2'};


    % ===== FIND ALL SOURCE .set FILES =====
    % Include files directly under data_root as well as nested participants.
    recordings = [dir(fullfile(data_root, '*.set')); ...
                  dir(fullfile(data_root, '**', '*.set'))];
    recordings = recordings(~[recordings.isdir]);

    % Ignore any .set saved by BrainBeats inside an *_Analysis folder.
    is_source = true(numel(recordings), 1);
    for k = 1:numel(recordings)
        path_parts = regexp(recordings(k).folder, '[\\/]', 'split');
        is_source(k) = ~any(endsWith(path_parts, '_Analysis', 'IgnoreCase', true));
    end
    recordings = recordings(is_source);

    % MATLAB's recursive wildcard may also include the top-level files;
    % de-duplicate before processing.
    paths = arrayfun(@(r) fullfile(r.folder, r.name), recordings, ...
                     'UniformOutput', false);
    [~, unique_idx] = unique(paths, 'stable');
    recordings = recordings(sort(unique_idx));
    paths = paths(sort(unique_idx));

    % Deterministic alphabetical order, grouped naturally by folder.
    [~, order] = sort(lower(string(paths)));
    recordings = recordings(order);
    paths = paths(order);

    n = numel(paths);
    if n == 0
        fprintf('No source .set files found under: %s\n', data_root);
        return;
    end

    fprintf('Found %d source .set file(s) under %s\n', n, data_root);

    % ===== INITIALIZE EEGLAB ONCE =====
    eeglab('nogui');
    if isempty(which('brainbeats_process'))
        error('BrainBeats was not found. Enable the EEGLAB BrainBeats plugin.');
    end

    initial_visibility = get(groot, 'DefaultFigureVisible');
    visibility_guard = onCleanup(@() set(groot, ...
        'DefaultFigureVisible', initial_visibility)); %#ok<NASGU>
    set(groot, 'DefaultFigureVisible', 'off');

    statuses = repmat("PENDING", n, 1);
    messages = strings(n, 1);
    output_dirs = strings(n, 1);
    elapsed_seconds = zeros(n, 1);
    summary_file = fullfile(data_root, 'BrainBeats_Features_Batch_Summary.csv');

    % Prepare an output folder path for every recording, including skipped
    % files, so the CSV remains useful after an interrupted batch.
    for k = 1:n
        [source_dir, source_name, ~] = fileparts(paths{k});
        output_dirs(k) = string(fullfile(source_dir, [source_name '_HRV_Analysis']));
    end

    % Save a live status file, then update it after each dataset. Completion
    % detection does NOT depend on CSV contents, which may be absent after
    % Ctrl+C or left over from an earlier run.
    save_batch_summary(summary_file, paths, output_dirs, statuses, ...
                       elapsed_seconds, messages);

    n_skipped = 0;
    n_success = 0;
    n_failed = 0;

    % ===== PROCESS EACH FILE INDEPENDENTLY =====
    for k = 1:n
        source_path = paths{k};
        [~, source_name, ~] = fileparts(source_path);
        output_dir = char(output_dirs(k));
        features_result_file = fullfile(output_dir, ...
            [source_name '_brainbeats_features_results.mat']);

        fprintf('\n[%d/%d] %s\n', k, n, source_path);

        % ===== RESUME CHECK =====
        % A valid completed EEG+HRV MAT is the success criterion. In
        % particular, do NOT skip simply because _Analysis exists.
        % This also recognizes work completed with the original HRV script
        % (before it supported resume), without requiring a marker file.
        if is_complete_features_result(features_result_file)
            statuses(k) = "SKIPPED";
            messages(k) = "Already complete: valid EEG/HRV results found";
            n_skipped = n_skipped + 1;
            fprintf('SKIPPED (already complete): %s\n', source_name);
            save_batch_summary(summary_file, paths, output_dirs, ...
                               statuses, elapsed_seconds, messages);
            continue;
        end

        if isfile(features_result_file)
            fprintf(['Existing feature results are incomplete or unreadable; ' ...
                     'retrying: %s\n'], features_result_file);
        end

        t_start = tic;
        statuses(k) = "IN_PROGRESS";
        messages(k) = "";
        save_batch_summary(summary_file, paths, output_dirs, ...
                           statuses, elapsed_seconds, messages);

        try
            if ~exist(output_dir, 'dir')
                mkdir(output_dir);
            end

            % Each recording has its own log and isolated figure cleanup.
            analyze_one_recording(source_path, output_dir, ...
                eeg_channels, ecg_channel, ...
                preprocess_eeg, power_line_hz, use_parallel);

            % Only mark SUCCESS after verifying the saved results actually
            % contain both EEG and HRV feature data. If MATLAB was stopped
            % mid-write, next run will retry this recording.
            if ~is_complete_features_result(features_result_file)
                error(['Analysis ended but did not leave a readable ' ...
                       'EEG + HRV features results MAT file: %s'], ...
                       features_result_file);
            end

            statuses(k) = "SUCCESS";
            messages(k) = "";
            n_success = n_success + 1;
            fprintf('SUCCESS: %s\n', source_name);

        catch ME
            statuses(k) = "FAILED";
            messages(k) = string(ME.message);
            n_failed = n_failed + 1;
            fprintf(2, 'FAILED: %s\n  %s\n', source_path, ME.message);
            % Continue with other participants; this one will retry on
            % the next run, because no VALID completed result is present.
        end

        elapsed_seconds(k) = toc(t_start);
        save_batch_summary(summary_file, paths, output_dirs, ...
                           statuses, elapsed_seconds, messages);
    end

    fprintf('\n====== BRAINBEATS EEG/HRV FEATURES BATCH FINISHED ======\n');
    fprintf('Found:     %d\n', n);
    fprintf('Succeeded: %d\n', n_success);
    fprintf('Skipped:   %d (previously completed)\n', n_skipped);
    fprintf('Failed:    %d\n', n_failed);
    fprintf('Summary:   %s\n', summary_file);
end


function tf = is_complete_features_result(result_file)
    % Check for the feature-specific MAT file, not HEP output or folders.
    % A previous run may have been interrupted during save; loading and
    % checking the expected fields prevents incomplete output from being
    % treated as successful analysis.
    tf = false;
    if ~isfile(result_file)
        return;
    end

    try
        result = load(result_file, 'brainbeats_results');
        if ~isfield(result, 'brainbeats_results') || ...
                ~isstruct(result.brainbeats_results)
            return;
        end
        bb = result.brainbeats_results;
        tf = isfield(bb, 'features') && ...
             isstruct(bb.features) && ...
             isfield(bb.features, 'EEG') && ...
             isfield(bb.features, 'HRV') && ...
             ~isempty(bb.features.EEG) && ...
             ~isempty(bb.features.HRV);
    catch ME
        fprintf(2, ['Warning: Could not validate existing feature result ' ...
                    '%s (%s). Will rerun.\n'], result_file, ME.message);
    end
end

function save_batch_summary(summary_file, paths, output_dirs, ...
                            statuses, elapsed_seconds, messages)
    % Write status after each recording, rather than waiting for the batch
    % to finish. Write to a staging CSV and rename to avoid truncating the
    % previous summary if MATLAB is interrupted mid-write.
    summary = table(string(paths(:)), output_dirs, statuses, ...
        elapsed_seconds, messages, ...
        'VariableNames', {'InputFile', 'AnalysisFolder', 'Status', ...
                          'ElapsedSeconds', 'ErrorMessage'});
    temp_file = [summary_file '.partial.csv'];
    writetable(summary, temp_file);
    [moved, msg] = movefile(temp_file, summary_file, 'f');
    if ~moved
        error('Could not update batch summary %s: %s', summary_file, msg);
    end
end

function analyze_one_recording(source_path, output_dir, ...
    eeg_channels, ecg_channel, ...
    preprocess_eeg, power_line_hz, use_parallel)

    [input_dir, input_name, input_ext] = fileparts(source_path);

    diary(fullfile(output_dir, 'features_analysis_log.txt'));
    diary on;
    diary_guard = onCleanup(@() diary('off')); %#ok<NASGU>

    % Remember which MATLAB figures existed BEFORE this dataset.
    % The cleanup runs on both success and failure so one file's plots
    % cannot carry into the next file's exported Figures folder.
    existing_figs = findall(groot, 'Type', 'figure');
    figures_guard = onCleanup(@() close_new_figures(existing_figs)); %#ok<NASGU>

    fprintf('Source: %s\n', source_path);
    fprintf('Output: %s\n', output_dir);

    try
        % ===== LOAD DATA =====
        EEG = pop_loadset('filename', [input_name input_ext], ...
                          'filepath', input_dir);
        EEG = eeg_checkset(EEG);

        labels = strtrim({EEG.chanlocs.labels});
        label_keys = lower(string(labels));
        eeg_keys = lower(string(eeg_channels));

        if numel(unique(label_keys)) ~= numel(label_keys)
            error('Duplicate electrode labels. Check the .set channel locations.');
        end

        [eeg_found, eeg_idx] = ismember(eeg_keys, label_keys);
        if ~all(eeg_found)
            error('Missing required EEG channels: %s', ...
                  strjoin(eeg_channels(~eeg_found), ', '));
        end

        ecg_idx = find(strcmpi(labels, ecg_channel));
        if numel(ecg_idx) ~= 1
            error('Expected one %s channel; found %d.', ...
                  ecg_channel, numel(ecg_idx));
        end

        % ===== KEEP ONLY 32 EEG + ECG_1 =====
        % Removes EGG_1..EGG_4 and any other auxiliary electrodes.
        keep_idx = [eeg_idx(:)' ecg_idx];
        excluded_idx = setdiff(1:EEG.nbchan, keep_idx);
        if ~isempty(excluded_idx)
            fprintf('Excluded %d non-EEG/non-ECG channel(s): %s\n', ...
                    numel(excluded_idx), strjoin(labels(excluded_idx), ', '));
        end

        EEG = pop_select(EEG, 'channel', keep_idx);
        EEG = eeg_checkset(EEG);

        for j = 1:EEG.nbchan
            if strcmpi(EEG.chanlocs(j).labels, ecg_channel)
                EEG.chanlocs(j).type = 'ECG';
            else
                EEG.chanlocs(j).type = 'EEG';
            end
        end
        if EEG.nbchan ~= 33
            error('Expected 32 EEG channels + 1 ECG channel; found %d.', EEG.nbchan);
        end

        fprintf('Selected 32 EEG channels + ECG channel %s.\n', ecg_channel);

        % BrainBeats should save inside this file's own adjacent _Analysis
        % folder, never into the original participant folder.
        EEG.filepath = output_dir;
        EEG.filename = [input_name '.set'];

        % ===== BRAINBEATS: EEG AND HRV FEATURE EXTRACTION =====
        % Unlike HEP mode, features mode analyzes the CONTINUOUS EEG and
        % ECG/NN intervals separately. No HEP epochs, ROI, or surrogates.
        %
        % Explicitly select all three feature domains for both modalities.
        % The frequency-window defaults (including normalized Lomb-Scargle
        % for HRV, and Hamming windows for EEG PSD) are supplied by BrainBeats.
        %
        % Use 1-40 Hz EEG filtering so gamma-band (30-40 Hz) features are
        % retained. The original HEP script used 0.5-30 Hz, appropriate for
        % HEP but not for this features analysis.
        % Continuous EEG artifact removal uses ASR (30-SD cutoff) + ICA;
        % in feature mode ICLabel also removes heart-classified components.
        EEG = brainbeats_process(EEG, ...
            'analysis', 'features', ...
            'heart_signal', 'ecg', ...
            'heart_channels', {ecg_channel}, ...
            'ecg_peakthresh', 0.35, ...
            'ecg_refperiod', 0.25, ...
            'ecg_searchback', 1, ...
            'clean_eeg', preprocess_eeg, ...
            'clean_method', 'asr_ica', ...
            'ref', 'average', ...
            'highpass', 1, ...
            'lowpass', 40, ...
            'linenoise', power_line_hz, ...
            'filttype', 'noncausal', ...
            'corrThresh', 0.65, ...
            'asr_cutoff', 30, ...
            'asr_mem', 0.80, ...
            'icamethod', 2, ...
            'hrv_features', {'time', 'frequency', 'nonlinear'}, ...
            'eeg_features', {'time', 'frequency', 'nonlinear'}, ...
            'eeg_frange', [1 40], ...
            'parpool', use_parallel, ...
            'vis_cleaning', 1, ...
            'vis_outputs', 1, ...
            'gong', false, ...
            'save', 1);

        % ===== EXPORT FIGURES CREATED FOR THIS FILE ONLY =====
        figures_dir = fullfile(output_dir, 'Figures');
        if ~exist(figures_dir, 'dir')
            mkdir(figures_dir);
        end
        current_figs = findall(groot, 'Type', 'figure');
        new_figs = figures_not_in(current_figs, existing_figs);
        for j = 1:numel(new_figs)
            try
                exportgraphics(new_figs(j), ...
                    fullfile(figures_dir, sprintf('Features_Figure_%02d.png', j)), ...
                    'Resolution', 300);
            catch fig_err
                % Figure-export problems should not erase valid results.
                fprintf(2, 'Warning: could not export figure %d: %s\n', ...
                        j, fig_err.message);
            end
        end

        % ===== SAVE RESULTS =====
        if ~isfield(EEG, 'brainbeats') || ...
                ~isfield(EEG.brainbeats, 'features') || ...
                ~isstruct(EEG.brainbeats.features) || ...
                ~isfield(EEG.brainbeats.features, 'EEG') || ...
                ~isfield(EEG.brainbeats.features, 'HRV')
            error(['BrainBeats returned without the expected EEG and HRV ' ...
                   'feature results.']);
        end
        % Full BrainBeats output includes features, parameters and
        % preprocessing information. Keep the same variable name as HEP.m.
        brainbeats_results = EEG.brainbeats;
        save(fullfile(output_dir, ...
            [input_name '_brainbeats_features_results.mat']), ...
            'brainbeats_results', '-v7.3');

        fprintf('Completed analysis: %s\n', source_path);

    catch ME
        fprintf(2, 'Analysis failed: %s\n', getReport(ME, 'extended', ...
            'hyperlinks', 'off'));
        rethrow(ME);
    end
end

function close_new_figures(existing_figs)
    current_figs = findall(groot, 'Type', 'figure');
    new_figs = figures_not_in(current_figs, existing_figs);
    for k = 1:numel(new_figs)
        if isgraphics(new_figs(k))
            delete(new_figs(k));
        end
    end
end

function new_figs = figures_not_in(all_figs, previous_figs)
    % Compare graphics handles directly (rather than sorting handles).
    new_figs = all_figs;
    for j = numel(new_figs):-1:1
        if any(new_figs(j) == previous_figs)
            new_figs(j) = [];
        end
    end
end
