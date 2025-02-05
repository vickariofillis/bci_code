%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% MATLAB script for the extraction of rhythmic spectral features
% from the electrophysiological signal based on Irregular Resampling
% Auto-Spectral Analysis (IRASA, Wen & Liu, Brain Topogr. 2016)
%
% Ensure FieldTrip is correcty added to the MATLAB path:
% addpath <path to fieldtrip home directory>
% ft_defaults
%
% From Stolk et al., Electrocorticographic dissociation of alpha and
% beta rhythmic activity in the human sensorimotor system
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% generate trials with a 15 Hz oscillation embedded in pink noise
load('data/S5_raw_segmented.mat');
disp("Loaded data structure:");
disp(whos); % Lists variables in workspace

if exist('data', 'var')
    disp("Data is loaded successfully.");
else
    error("Data structure 'data' is missing in the loaded file.");
end
if isfield(data, 'trial')
    for i = 1:length(data.trial)
        if all(data.trial{i}(:) == 0)
            disp(['Warning: Trial ', num2str(i), ' contains only zeros.']);
        elseif all(isnan(data.trial{i}(:)))
            disp(['Warning: Trial ', num2str(i), ' contains only NaNs.']);
        else
            disp(['Trial ', num2str(i), ' contains valid data.']);
        end
    end
else
    error("Field 'trial' is missing in data structure.");
end




% Ensure that the loaded data matches your expectations
% data = raw_data.data;

% 
% t = (1:1000)/1000; % time axis
% for rpt = 1:100
%  generate pink noiseg
%  dspobj = dsp.ColoredNoise('Color', 'pink', ...
%  'SamplesPerFrame', length(t));
%  fn = dspobj()';
%  % add a 15 Hz oscillation
%  data.trial{1,rpt} = fn + cos(2*pi*15*t);
%  data.time{1,rpt} = t;
%  data.label{1} = 'chan';
%  data.trialinfo(rpt,1) = rpt;
% end
%partition the data into ten overlapping sub-segments
subset_trials = 1:5; % First 5 trials
subset_channels = 1:10; % First 10 channels
data_subset = data;
data_subset.trial = data.trial(subset_trials);
data_subset.time = data.time(subset_trials);
data_subset.trialinfo = data.trialinfo(subset_trials, :);
data_subset.label = data.label(subset_channels);
for i = 1:length(data_subset.trial)
    data_subset.trial{i} = data_subset.trial{i}(subset_channels, :);
end
for i = 1:length(data_subset.trial)
    if isempty(data_subset.trial{i}) || all(data_subset.trial{i}(:) == 0)
        disp(['Warning: Subset Trial ', num2str(i), ' contains only zeros or is empty.']);
    end
end

 w = data_subset.time{1}(end)-data_subset.time{1}(1); % window length

cfg = [];
cfg.length = w*.9;
cfg.overlap = 1-((w-cfg.length)/(10-1));
data_r = ft_redefinetrial(cfg, data_subset);

if isempty(data_r.trial)
    error("Redefined trial data is empty.");
else
    disp("Redefined trial data contains valid entries.");
end
% perform IRASA and regular spectral analysis
cfg = [];
cfg.foilim = [1 50];
cfg.taper = 'hanning';
cfg.pad = 'nextpow2';
cfg.keeptrials = 'yes';
cfg.method = 'irasa';
frac_r = ft_freqanalysis(cfg, data_r);
cfg.method = 'mtmfft';
orig_r = ft_freqanalysis(cfg, data_r);
% average across the sub-segments
frac_s = {};
orig_s = {};
for rpt = unique(frac_r.trialinfo)'
 cfg = [];
 cfg.trials = find(frac_r.trialinfo(:,1) == 1); %find(frac_r.trialinfo==rpt);
 cfg.avgoverrpt = 'yes';
 frac_s{end+1} = ft_selectdata(cfg, frac_r);
 orig_s{end+1} = ft_selectdata(cfg, orig_r);
end
frac_a = ft_appendfreq([], frac_s{:});
orig_a = ft_appendfreq([], orig_s{:});
% average across trials
cfg = [];
cfg.trials = 'all';
cfg.avgoverrpt = 'yes';
frac = ft_selectdata(cfg, frac_a);
orig = ft_selectdata(cfg, orig_a);
% subtract the fractal component from the power spectrum
cfg = [];
cfg.parameter = 'powspctrm';
cfg.operation = 'x2-x1';
osci = ft_math(cfg, frac, orig);
% plot the fractal component and the power spectrum
figure; plot(frac.freq, frac.powspctrm, ...
 'linewidth', 3, 'color', [0 0 0])
hold on; plot(orig.freq, orig.powspctrm, ...
 'linewidth', 3, 'color', [.6 .6 .6])
% plot the full-width half-maximum of the oscillatory component
% power_avg = mean(osci.powspctrm, 1); % Average power across channels
% y = power_avg(:); 
channel_index = 1; % Example: First channel
if isempty(osci.powspctrm) || all(isnan(osci.powspctrm(:)))
    error("osci.powspctrm is empty or contains only NaN values.");
else
    disp("osci.powspctrm contains valid data.");
end
osci_1d = squeeze(osci.powspctrm(channel_index, :, :));
disp(size(osci_1d));
x_data = osci.freq(:); 
y_data = osci_1d(:);
valid_idx = ~isnan(x_data) & ~isnan(y_data); % Logical index for valid (non-NaN) data
x_data = x_data(valid_idx);
y_data = y_data(valid_idx);
f = fit(x_data, y_data, 'gauss1');
 
mean = f.b1;
std = f.c1/sqrt(2)*2.3548;
fwhm = [mean-std/2 mean+std/2];
yl = get(gca, 'YLim');
p = patch([fwhm flip(fwhm)], [yl(1) yl(1) yl(2) yl(2)], [1 1 1]);
uistack(p, 'bottom');
legend('FWHM oscillation', 'Fractal component', 'Power spectrum');
xlabel('Frequency'); ylabel('Power');
set(gca, 'YLim', yl);
