%% Batch BrainBeats HEP Analysis — 32 EEG + ECG_1, excluding EGG channels
%
% HOW TO USE:
%   1) Set data_root below to the TOP data folder containing participants.
%   2) Run this script in MATLAB (with EEGLAB + BrainBeats installed).
%
% Example layout:
%   BIOSYNC_DATA/
%     027/
%       027_resting1.set
%       027_resting2.set
%     028/
%       028_resting1.set
%
% For each .set file, creates an adjacent folder named <dataset>_Analysis:
%   BIOSYNC_DATA/027/027_resting1_Analysis/
%     analysis_log.txt
%     027_resting1_brainbeats_results.mat
%     Figures/
%
% All .set files in participant subfolders (including nested folders) are
% processed. Any existing *_Analysis folders are excluded from the search,
% so previously generated output .set files are NOT analyzed again.
% Failed datasets are logged, and the batch continues to the next dataset.
% A CSV summary is written to the top-level data folder.
% The BrainBeats completion gong is disabled, preventing audio device errors.
% Completed analyses are SKIPPED on future runs. Completion means the
% nonempty <dataset>_brainbeats_results.mat file AND Figures folder exist.
% Partial/failed runs are retried automatically. To force a rerun of one
% completed dataset, delete/rename its results .mat file.

% ===== ONLY PATH YOU NEED TO EDIT =====
data_root = '/Users/atbender/Documents/BIOSYNC_DATA';

run_brainbeats_batch(data_root);

%% ===== LOCAL FUNCTIONS (no changes needed below) =====

function run_brainbeats_batch(data_root)
    if ~isfolder(data_root)
        error('Data folder not found: %s', data_root);
    end

    % The validated montage used in the working single-file script.
    ecg_channel = 'ECG_1';
    preprocess_eeg = true;
    power_line_hz = 60;
    keep_heart_in_output = false;

    eeg_channels = { ...
        'Fp1', 'Fz', 'F3', 'F7', 'FT9', 'FC5', 'FC1', 'C3', ...
        'T7', 'TP9', 'CP5', 'CP1', 'Pz', 'P3', 'P7', 'O1', ...
        'Oz', 'O2', 'P4', 'P8', 'TP10', 'CP6', 'CP2', 'Cz', ...
        'C4', 'T8', 'FT10', 'FC6', 'FC2', 'F4', 'F8', 'Fp2'};

    hep_roi = {'F3', 'Fz', 'F4', 'FC1', 'FC2', 'C3', 'Cz', 'C4'};

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

    statuses = strings(n, 1);
    messages = strings(n, 1);
    output_dirs = strings(n, 1);
    elapsed_seconds = zeros(n, 1);

    % ===== PROCESS EACH FILE INDEPENDENTLY =====
    for k = 1:n
        source_path = paths{k};
        [source_dir, source_name, ~] = fileparts(source_path);
        output_dir = fullfile(source_dir, [source_name '_HEP_Analysis']);
        output_dirs(k) = string(output_dir);

        fprintf('\n[%d/%d] %s\n', k, n, source_path);
        t_start = tic;

        % Only skip a dataset when the result file and figure directory
        % both exist. This avoids skipping a run that failed at the gong
        % or during export. An existing output folder alone is NOT enough.
        results_file = fullfile(output_dir, ...
            [source_name '_brainbeats_results.mat']);
        figures_dir = fullfile(output_dir, 'Figures');
        result_info = dir(results_file);
        results_saved = ~isempty(result_info) && ...
            ~result_info(1).isdir && result_info(1).bytes > 0;
        if results_saved && isfolder(figures_dir)
            statuses(k) = "SKIPPED";
            messages(k) = "Completed output already exists";
            fprintf('SKIPPED (already completed): %s\n', source_path);
            elapsed_seconds(k) = toc(t_start);
            continue;
        end

        try
            if ~exist(output_dir, 'dir')
                mkdir(output_dir);
            end

            % Each recording gets its own analysis log. An onCleanup
            % inside this function closes the diary even on failure.
            analyze_one_recording(source_path, output_dir, ...
                eeg_channels, ecg_channel, hep_roi, ...
                preprocess_eeg, power_line_hz, keep_heart_in_output);

            statuses(k) = "SUCCESS";
            messages(k) = "";
            fprintf('SUCCESS: %s\n', source_name);

        catch ME
            statuses(k) = "FAILED";
            messages(k) = string(ME.message);
            fprintf(2, 'FAILED: %s\n  %s\n', source_path, ME.message);
            % Continue with the other participant files.
        end

        elapsed_seconds(k) = toc(t_start);
    end

    % ===== SAVE BATCH-WIDE SUMMARY =====
    summary = table(string(paths(:)), output_dirs, statuses, ...
        elapsed_seconds, messages, ...
        'VariableNames', {'InputFile', 'AnalysisFolder', 'Status', ...
                          'ElapsedSeconds', 'ErrorMessage'});
    summary_file = fullfile(data_root, 'BrainBeats_Batch_Summary.csv');
    writetable(summary, summary_file);

    fprintf('\n====== BRAINBEATS BATCH FINISHED ======\n');
    fprintf('Found:     %d\n', n);
    fprintf('Succeeded: %d\n', nnz(statuses == "SUCCESS"));
    fprintf('Skipped:   %d\n', nnz(statuses == "SKIPPED"));
    fprintf('Failed:    %d\n', nnz(statuses == "FAILED"));
    fprintf('Summary:   %s\n', summary_file);
end

function analyze_one_recording(source_path, output_dir, ...
    eeg_channels, ecg_channel, hep_roi, ...
    preprocess_eeg, power_line_hz, keep_heart_in_output)

    [input_dir, input_name, input_ext] = fileparts(source_path);

    diary(fullfile(output_dir, 'analysis_log.txt'));
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

        % ===== ORIGINAL, WORKING BRAINBEATS PARAMETERS =====
        EEG = brainbeats_process(EEG, ...
            'analysis', 'hep', ...
            'heart_signal', 'ecg', ...
            'heart_channels', {ecg_channel}, ...
            'ecg_peakthresh', 0.35, ...
            'ecg_refperiod', 0.25, ...
            'ecg_searchback', 1, ...
            'clean_eeg', preprocess_eeg, ...
            'clean_method', 'asr_ica', ...
            'ref', 'average', ...
            'highpass', 0.5, ...
            'lowpass', 30, ...
            'linenoise', power_line_hz, ...
            'filttype', 'noncausal', ...
            'corrThresh', 0.65, ...
            'detectMethod', 'grubbs', ...
            'icamethod', 2, ...
            'heart_removal', 'ica', ...
            'conf_thresh', 0.75, ...
            'hep_level', 'channels', ...
            'hep_roi', hep_roi, ...
            'hep_window', [-300 600], ...
            'hep_baseline', 'none', ...
            'hep_tf_freqs', [4 30], ...
            'hep_surrogates', 100, ...
            'keep_heart', keep_heart_in_output, ...
            'vis_cleaning', 1, ...
            'vis_outputs', 1, ...
            'gong', false, ... % No completion sound (avoids MATLAB audio device error)
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
                    fullfile(figures_dir, sprintf('Figure_%02d.png', j)), ...
                    'Resolution', 300);
            catch fig_err
                % Figure-export problems should not erase valid results.
                fprintf(2, 'Warning: could not export figure %d: %s\n', ...
                        j, fig_err.message);
            end
        end

        % ===== SAVE RESULTS =====
        if ~isfield(EEG, 'brainbeats')
            error('BrainBeats returned without EEG.brainbeats results.');
        end
        brainbeats_results = EEG.brainbeats;
        save(fullfile(output_dir, ...
            [input_name '_brainbeats_results.mat']), ...
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
