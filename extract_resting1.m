%% Extract first S 11 -> next S255 and save as <recording>_resting1.set
% Requires EEGLAB and its bva-io BrainVision import plugin.
% Keep the .vhdr, .eeg, and .vmrk files together in the same folder.

% Initialize EEGLAB (and its plugins) without opening another EEGLAB window.
eeglab('nogui');

% Choose a BrainVision header file (.vhdr).
[vhdrFile, vhdrFolder] = uigetfile('*.vhdr', 'Select BrainVision .vhdr file');
if isequal(vhdrFile, 0)
    disp('No file selected. Nothing was changed.');
    return;
end

% Import the continuous recording and its marker events.
EEG = pop_loadbv(vhdrFolder, vhdrFile);
assert(EEG.trials == 1, 'Expected a continuous (single-epoch) recording.');
assert(~isempty(EEG.event), 'No events were imported from the BrainVision recording.');

% Normalize trigger names: "S 11" and "S11" both become "S11".
eventTypes = strings(numel(EEG.event), 1);
for k = 1:numel(EEG.event)
    eventTypes(k) = regexprep(upper(string(EEG.event(k).type)), '\s+', '');
end
eventSamples = [EEG.event.latency]';

% Find the FIRST S11 chronologically (regardless of event index).
startCandidates = find(eventTypes == "S11");
assert(~isempty(startCandidates), 'No S 11 trigger was found.');
[~, firstStart] = min(eventSamples(startCandidates));
startIdx = startCandidates(firstStart);
startSample = round(eventSamples(startIdx));

% Find the NEXT S255 after that S11, by timestamp.
endCandidates = find(eventTypes == "S255" & eventSamples > eventSamples(startIdx));
assert(~isempty(endCandidates), 'No S255 trigger was found after the first S 11.');
[~, firstEnd] = min(eventSamples(endCandidates));
endIdx = endCandidates(firstEnd);
endSample = round(eventSamples(endIdx)) - 1; % Stop before the end marker.

assert(startSample >= 1 && endSample <= EEG.pnts && endSample >= startSample, ...
    'The trigger positions do not define a valid extraction window.');

% Cut out the paradigm; the original BrainVision files remain unchanged.
EEG_cut = pop_select(EEG, 'point', [startSample endSample]);
[~, recordingName] = fileparts(vhdrFile);
outputName = [recordingName '_resting1.set'];
EEG_cut.setname = [recordingName '_resting1'];
EEG_cut = eeg_checkset(EEG_cut);

% Prevent accidental overwriting of an existing extraction.
outputPath = fullfile(vhdrFolder, outputName);
assert(~isfile(outputPath), 'Output already exists: %s', outputPath);

% Save a single .set file next to the source .vhdr file.
EEG_cut = pop_saveset(EEG_cut, ...
    'filename', outputName, ...
    'filepath', vhdrFolder, ...
    'savemode', 'onefile');

fprintf('\nSaved: %s\n', outputPath);
fprintf('First S 11: %.2f seconds\n', (startSample - 1) / EEG.srate);
fprintf('Next S255:  %.2f seconds\n', (eventSamples(endIdx) - 1) / EEG.srate);
fprintf('Extracted duration: %.2f seconds\n', EEG_cut.pnts / EEG_cut.srate);
