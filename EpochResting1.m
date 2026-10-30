function extract_resting1_batch(dataFolder)
% EXTRACT_RESTING1_BATCH Process BrainVision recordings for all participants.
%
% Usage:
%   extract_resting1_batch('/path/to/top/data/folder')
%
% Expected organization:
%   dataFolder/
%       Participant01/
%           recordingA.vhdr  (with recordingA.eeg and recordingA.vmrk)
%           recordingB.vhdr  (with recordingB.eeg and recordingB.vmrk)
%       Participant02/
%           recordingC.vhdr  (with recordingC.eeg and recordingC.vmrk)
%
% For EACH .vhdr file directly inside a participant folder, this function:
%   1. Imports the recording with EEGLAB/bva-io.
%   2. Finds the FIRST S 11 and the NEXT S255 after it.
%   3. Extracts the data from S 11 up to (but not including) S255.
%   4. Saves <recording>_resting1.set next to the original .vhdr file.
%
% Files that already have an output are skipped (not overwritten).
% A bad recording is reported but does not stop other recordings.
% Requires EEGLAB with the bva-io BrainVision import plugin.

    % The only required input is the top-level data folder.
    if nargin ~= 1 || ~(ischar(dataFolder) || (isstring(dataFolder) && isscalar(dataFolder)))
        error('Provide the path to the top-level data folder, e.g. extract_resting1_batch(''/path/to/data'').');
    end
    dataFolder = char(dataFolder);
    assert(isfolder(dataFolder), 'Data folder does not exist: %s', dataFolder);

    % Initialize EEGLAB and its plugins just once.
    eeglab('nogui');

    % Examine each participant folder directly inside the top-level folder.
    participants = dir(dataFolder);
    participants = participants([participants.isdir]);
    participants = participants(~ismember({participants.name}, {'.', '..'}));

    totalRecordings = 0;
    savedCount = 0;
    skippedCount = 0;
    failedCount = 0;

    fprintf('\nFound %d participant folders under: %s\n', numel(participants), dataFolder);

    for p = 1:numel(participants)
        participantName = participants(p).name;
        participantFolder = fullfile(dataFolder, participantName);

        % A participant can have one or multiple BrainVision recordings.
        vhdrFiles = dir(fullfile(participantFolder, '*.vhdr'));
        fprintf('\n[%d/%d] %s: %d .vhdr file(s)\n', ...
            p, numel(participants), participantName, numel(vhdrFiles));

        for f = 1:numel(vhdrFiles)
            vhdrFile = vhdrFiles(f).name;
            [~, recordingName] = fileparts(vhdrFile);
            outputName = [recordingName '_resting1.set'];
            outputPath = fullfile(participantFolder, outputName);
            totalRecordings = totalRecordings + 1;

            fprintf('  Processing: %s\n', vhdrFile);

            % Avoid overwriting results from previous runs.
            if isfile(outputPath)
                fprintf('    SKIPPED (output already exists): %s\n', outputName);
                skippedCount = skippedCount + 1;
                continue;
            end

            try
                % Import continuous BrainVision data and its events.
                EEG = pop_loadbv(participantFolder, vhdrFile);
                assert(EEG.trials == 1, 'Expected a continuous (single-epoch) recording.');
                assert(~isempty(EEG.event), 'No events were imported from this recording.');

                % Normalize trigger names: "S 11" and "S11" both become "S11".
                eventTypes = strings(numel(EEG.event), 1);
                for k = 1:numel(EEG.event)
                    eventTypes(k) = regexprep(upper(string(EEG.event(k).type)), '\s+', '');
                end
                eventSamples = [EEG.event.latency]';

                % FIRST S 11 chronologically, regardless of event array order.
                startCandidates = find(eventTypes == "S11");
                assert(~isempty(startCandidates), 'No S 11 trigger was found.');
                [~, firstStart] = min(eventSamples(startCandidates));
                startIdx = startCandidates(firstStart);
                startSample = round(eventSamples(startIdx));

                % NEXT S255 occurring after the selected S 11.
                endCandidates = find(eventTypes == "S255" & eventSamples > eventSamples(startIdx));
                assert(~isempty(endCandidates), 'No S255 trigger was found after the first S 11.');
                [~, firstEnd] = min(eventSamples(endCandidates));
                endIdx = endCandidates(firstEnd);
                endSample = round(eventSamples(endIdx)) - 1; % Exclude the end marker.

                assert(startSample >= 1 && endSample <= EEG.pnts && endSample >= startSample, ...
                    'The trigger positions do not define a valid extraction window.');

                % Preserve original recordings; extract and save next to them.
                EEG_cut = pop_select(EEG, 'point', [startSample endSample]);
                EEG_cut.setname = [recordingName '_resting1'];
                EEG_cut = eeg_checkset(EEG_cut);
                EEG_cut = pop_saveset(EEG_cut, ...
                    'filename', outputName, ...
                    'filepath', participantFolder, ...
                    'savemode', 'onefile');

                fprintf('    SAVED: %s\n', outputPath);
                fprintf('    First S 11: %.2f seconds\n', (startSample - 1) / EEG.srate);
                fprintf('    Next S255:  %.2f seconds\n', (eventSamples(endIdx) - 1) / EEG.srate);
                fprintf('    Extracted duration: %.2f seconds\n', EEG_cut.pnts / EEG_cut.srate);
                savedCount = savedCount + 1;

            catch ME
                failedCount = failedCount + 1;
                fprintf(2, '    FAILED: %s\n', ME.message);
            end

            % Release large arrays before loading the next recording.
            clear EEG EEG_cut;
        end
    end

    fprintf('\n===== Batch extraction complete =====\n');
    fprintf('Recordings found: %d\n', totalRecordings);
    fprintf('Saved:            %d\n', savedCount);
    fprintf('Skipped existing: %d\n', skippedCount);
    fprintf('Failed:           %d\n', failedCount);
end
