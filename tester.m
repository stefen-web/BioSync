
%% BrainBeats Automated Analysis

% ===== USER SETTINGS =====

input_file = '/Users/atbender/Documents/BIOSYNC_DATA/027/027_resting1.set';

ecg_channel = 'ECG_1';
preprocess_eeg = true;
power_line_hz = 50;

% ===== AUTOMATIC OUTPUT DIRECTORY =====

[input_dir, input_name, input_ext] = fileparts(input_file);

output_dir = fullfile(input_dir, ...
    [input_name '_Analysis']);

if ~isfile(input_file)
    error('Dataset not found: %s', input_file);
end

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

% ===== INITIALIZE EEGLAB =====

eeglab('nogui');

if isempty(which('brainbeats_process'))
    error('BrainBeats was not found.');
end

% Start logging
diary(fullfile(output_dir, 'analysis_log.txt'));
diary on;

try
    % ===== LOAD DATA =====

    EEG = pop_loadset( ...
        'filename', [input_name input_ext], ...
        'filepath', input_dir);

    EEG = eeg_checkset(EEG);

    labels = {EEG.chanlocs.labels};

    if ~any(strcmpi(labels, ecg_channel))
        error('ECG channel not found.');
    end

    % ===== REMOVE AUXILIARY CHANNELS =====

    aux_names = {'PPG','EOG','VEOG','HEOG', ...
                 'EMG','GSR','EDA','AUX'};

    remove_mask = ismember( ...
        cellfun(@upper, labels, 'UniformOutput', false), ...
        aux_names);
    remove_mask(strcmpi(labels, ecg_channel)) = false;

    if any(remove_mask)
        EEG = pop_select(EEG, ...
            'nochannel', labels(remove_mask));
    end

    % Set analysis output destination
    EEG.filepath = output_dir;
    EEG.filename = [input_name '.set'];

    % ===== BRAINBEATS ANALYSIS =====

    set(groot, 'DefaultFigureVisible', 'off');

    EEG = brainbeats_process(EEG,'analysis','hep','heart_signal','ecg','heart_channels',{'ECG'},'ecg_peakthresh',0.35,'ecg_refperiod',0.25,'ecg_searchback',1,'clean_eeg',1,'clean_method','asr_ica','ref','average','highpass',0.5,'lowpass',30,'linenoise',60,'filttype','noncausal','corrThresh',0.65,'detectMethod','grubbs','icamethod',2,'heart_removal','ica','conf_thresh',0.75,'hep_level','channels','hep_roi',{'F1' 'F2' 'F3' 'F4' 'Fz' 'FC1' 'FC2' 'FC3' 'FC4' 'FCz' 'C1' 'C2' 'C3' 'C4' 'Cz'},'hep_window',[-300 600],'hep_baseline','none','hep_tf_freqs',[4 30],'hep_surrogates',100,'keep_heart',0,'vis_cleaning',1,'vis_outputs',1,'save',1);

    % EEG = brainbeats_process(EEG, ...
    %     'analysis', 'hep', ...
    %     'heart_signal', 'ECG', ...
    %     'heart_channels', {ecg_channel}, ...
    %     'clean_eeg', preprocess_eeg, ...
    %     'linenoise', power_line_hz, ...
    %     'ica_method', 2, ...
    %     'hep_level', 'channels', ...
    %     'keep_heart', true, ...
    %     'vis_cleaning', true, ...
    %     'vis_outputs', true, ...
    %     'save', true);
    % ===== SAVE VISUALIZATIONS =====

    figures_dir = fullfile(output_dir, 'Figures');

    if ~exist(figures_dir, 'dir')
        mkdir(figures_dir);
    end

    figs = findall(groot, 'Type', 'figure');

    for i = 1:numel(figs)
        exportgraphics(figs(i), ...
            fullfile(figures_dir, ...
            sprintf('Figure_%02d.png', i)), ...
            'Resolution', 300);
    end

    % Restore normal figure behavior
    set(groot, 'DefaultFigureVisible', 'on');

    % ===== SAVE RESULTS =====

    brainbeats_results = EEG.brainbeats;

    save(fullfile(output_dir, ...
        [input_name '_brainbeats_results.mat']), ...
        'brainbeats_results', '-v7.3');

    fprintf('\nBrainBeats analysis completed.\n');
    fprintf('Results saved to:\n%s\n', output_dir);

catch ME
    fprintf(2, 'Analysis failed: %s\n', ME.message);
    diary off;
    rethrow(ME);
end

diary off;
