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
function motor_movement(dataPath, libPath)
    maxNumCompThreads(1);
    startTime = datetime('now','TimeZone','UTC');
    log_phase('LOAD','START');
    tStart = cputime;
    %load('S5_raw_segmented.mat');
    tmp = load(dataPath);
    if isfield(tmp, 'data')
        data = tmp.data;
    else
        error("%s does not contain variable 'data'", dataPath);
    end
    log_phase('LOAD','END');
    
    addpath(libPath);
    %addpath('C:\Users\saray\Desktop\fieldtrip-20240916');
    %addpath('tools/fieldtrip/fieldtrip-20240916');
    disp("Loaded data structure:");
    disp(whos); % Lists variables in workspace
    
    % if exist('data', 'var')
    %     disp("Data is loaded successfully.");
    % else
    %     error("Data structure 'data' is missing in the loaded file.");
    % end
    % if isfield(data, 'trial')
    %     for i = 1:length(data.trial)
    %         if all(data.trial{i}(:) == 0)
    %             disp(['Warning: Trial ', num2str(i), ' contains only zeros.']);
    %         elseif all(isnan(data.trial{i}(:)))
    %             disp(['Warning: Trial ', num2str(i), ' contains only NaNs.']);
    %         else
    %             disp(['Trial ', num2str(i), ' contains valid data.']);
    %         end
    %     end
    % else
    %     error("Field 'trial' is missing in data structure.");
    % end
    
    %Synthetic Data
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
    % subset_trials = 1:5; % First 5 trials
    % subset_channels = 1:10; % First 10 channels
    % data_subset = data;
    % data_subset.trial = data.trial(subset_trials);
    % data_subset.time = data.time(subset_trials);
    % data_subset.trialinfo = data.trialinfo(subset_trials, :);
    % data_subset.label = data.label(subset_channels);
    
    %Validate content of the data
    % for i = 1:length(data.trial)
    %     data.trial{i} = data.trial{i}(subset_channels, :);
    % end
    for i = 1:length(data.trial)
        if isempty(data.trial{i}) || all(data.trial{i}(:) == 0)
            disp(['Warning: Subset Trial ', num2str(i), ' contains only zeros or is empty.']);
        end
    end
    
    log_phase('PARTITION','START');
    
     w = data.time{1}(end)-data.time{1}(1); % window length
    
    cfg = [];
    cfg.length = w*.9;
    cfg.overlap = 1-((w-cfg.length)/(10-1));
    data_r = ft_redefinetrial(cfg, data);
    disp(['w = ', num2str(w)]);
    disp(['cfg.length = ', num2str(cfg.length)]);
    disp(['cfg.overlap = ', num2str(cfg.overlap)]);
    log_phase('PARTITION','END');
    
    %Verify redefined data
    % if isempty(data_r.trial)
    %     error("Redefined trial data is empty.");
    % else
    %     disp("Redefined trial data contains valid entries.");
    % end
    % perform IRASA and regular spectral analysis
    log_phase('IRASA','START');
    cfg = [];
    cfg.foilim = [1 50];
    cfg.taper = 'hanning';
    cfg.pad = 'nextpow2';
    cfg.keeptrials = 'yes';
    cfg.method = 'irasa';
    
    % disp('Checking data_r before frequency analysis:');
    % if isempty(data_r)
    %     error('data_r is empty.');
    % end
    % 
    % disp(['Size of first trial: ', num2str(size(data_r.trial{1}))]);
    % if all(cellfun(@(x) all(isnan(x(:))), data_r.trial))
    %     error('All trials in data_r contain only NaN values.');
    % end
    frac_r = ft_freqanalysis(cfg, data_r);
    log_phase('IRASA','END');
    
    
    % disp('Checking frac_r output:');
    
    % if isempty(frac_r)
    %     error('frac_r is empty after ft_freqanalysis.');
    % else
    %     disp(['frac_r.freq size: ', num2str(size(frac_r.freq))]);
    %     disp(['frac_r.powspctrm size: ', num2str(size(frac_r.powspctrm))]);
    % end
    % 
    % if all(isnan(frac_r.powspctrm(:)))
    %     error('frac_r.powspctrm contains only NaN values.');
    % else
    %     disp('frac_r contains valid power spectrum data.');
    %     disp(['First 10 valid frac_r.powspctrm values: ', num2str(frac_r.powspctrm(1:min(10, numel(frac_r.powspctrm))))]);
    % end
    log_phase('MTMFFT','START');
    
    cfg.method = 'mtmfft';
    orig_r = ft_freqanalysis(cfg, data_r);
    log_phase('MTMFFT','END');
    % disp('Checking orig_r output:');
    % if isempty(orig_r.powspctrm)
    %     error('orig_r.powspctrm is empty.');
    % elseif all(isnan(orig_r.powspctrm(:)))
    %     error('orig_r.powspctrm contains only NaN values.');
    % else
    %     disp('orig_r contains valid power spectrum data.');
    %     disp(['First 10 valid orig_r.powspctrm values: ', num2str(orig_r.powspctrm(1:min(10, numel(orig_r.powspctrm))))]);
    % end
    
    % average across the sub-segments
    frac_s = {};
    orig_s = {};
    % disp('Inspecting frac_r.trialinfo:');
    % disp(frac_r.trialinfo);
    % disp('Size of frac_r.trialinfo:');
    % disp(size(frac_r.trialinfo)); % Should print [num_trials, num_columns]
    % 
    % disp('Unique values in trialinfo columns:');
    % for col = 1:size(frac_r.trialinfo, 2)
    %     disp(['Column ', num2str(col), ': ' num2str(unique(frac_r.trialinfo(:, col))')]);
    % end
    % 
    % disp('Finding the correct column for trial indices...');
    num_trials = size(frac_r.trialinfo, 1);
    trial_col = NaN; % Initialize as not found
    
    for col = 1:size(frac_r.trialinfo, 2)
        unique_vals = unique(frac_r.trialinfo(:, col));
        
        % Check if all values are integers and sequential trial numbers
        if all(mod(unique_vals, 1) == 0) && all(unique_vals >= 1) && all(unique_vals <= num_trials)
            trial_col = col;
            break; % Stop searching after the first valid column is found
        end
    end
    
    % if isnan(trial_col)
    %     error('Could not find a suitable trial index column in frac_r.trialinfo.');
    % else
    %     disp(['Using column ', num2str(trial_col), ' for trial selection.']);
    % end
    
    log_phase('AVGSEG','START');
    
    for rpt = unique(frac_r.trialinfo(:, trial_col))'
     cfg = [];
     cfg.trials = find(frac_r.trialinfo(:, trial_col) == rpt); % find(frac_r.trialinfo(:,1) == 1); %find(frac_r.trialinfo==rpt);
     % if isempty(cfg.trials)
     %        disp(['Warning: No matching trials found for rpt = ', num2str(rpt)]);
     %    else
     %        disp(['Selected trials for rpt = ', num2str(rpt), ': ', mat2str(cfg.trials)]);
     %    end
     % disp(['Selected trials for rpt = ', num2str(rpt), ': ', mat2str(cfg.trials)]);
     cfg.avgoverrpt = 'yes';
     frac_s{end+1} = ft_selectdata(cfg, frac_r); %this causes the NaN values
     orig_s{end+1} = ft_selectdata(cfg, orig_r);
    end
    % disp('Checking frac_s dimensions before ft_appendfreq:');
    % for i = 1:length(frac_s)
    %     disp(['frac_s{', num2str(i), '} powspctrm size: ', num2str(size(frac_s{i}.powspctrm))]);
    % end
    
    % disp('Checking orig_s dimensions before ft_appendfreq:');
    % for i = 1:length(orig_s)
    %     disp(['orig_s{', num2str(i), '} powspctrm size: ', num2str(size(orig_s{i}.powspctrm))]);
    % end
    % disp('Checking frac_s before ft_appendfreq:');
    % for i = 1:length(frac_s)
    %     if isempty(frac_s{i}.powspctrm)
    %         disp(['Warning: frac_s{', num2str(i), '} is empty.']);
    %     elseif all(isnan(frac_s{i}.powspctrm(:)))
    %         disp(['Warning: frac_s{', num2str(i), '} contains only NaNs.']);
    %     else
    %         disp(['frac_s{', num2str(i), '} contains valid data.']);
    %     end
    % end
    
    frac_a = ft_appendfreq([], frac_s{:});
    orig_a = ft_appendfreq([], orig_s{:});
    log_phase('AVGSEG','END');
    log_phase('AVGTRIAL','START');
    % average across trials
    cfg = [];
    cfg.trials = 'all';
    cfg.avgoverrpt = 'yes';
    frac = ft_selectdata(cfg, frac_a);
    orig = ft_selectdata(cfg, orig_a);
    % subtract the fractal component from the power spectrum
    cfg = [];
    log_phase('AVGTRIAL','END');
    
    % disp('Checking frac.powspctrm:');
    % if isempty(frac.powspctrm)
    %     error('frac.powspctrm is empty.');
    % elseif all(isnan(frac.powspctrm(:)))
    %     error('frac.powspctrm contains only NaN values.');
    % else
    %     disp(['frac.powspctrm size: ', num2str(size(frac.powspctrm))]);
    %     disp(['First 10 valid frac.powspctrm values: ', num2str(frac.powspctrm(1:min(10, numel(frac.powspctrm))))]);
    % end
    
    % disp('Checking orig.powspctrm:');
    % if isempty(orig.powspctrm)
    %     error('orig.powspctrm is empty.');
    % elseif all(isnan(orig.powspctrm(:)))
    %     error('orig.powspctrm contains only NaN values.');
    % else
    %     disp(['orig.powspctrm size: ', num2str(size(orig.powspctrm))]);
    %     disp(['First 10 valid orig.powspctrm values: ', num2str(orig.powspctrm(1:min(10, numel(orig.powspctrm))))]);
    % end
    
    
    
    log_phase('SUBTRACT','START');
    
    cfg.parameter = 'powspctrm';
    cfg.operation = 'x2-x1';
    osci = ft_math(cfg, frac, orig);
    
    log_phase('SUBTRACT','END');
    
    % plot the fractal component and the power spectrum
    figure; plot(frac.freq, frac.powspctrm, ...
     'linewidth', 3, 'color', [0 0 0])
    hold on; plot(orig.freq, orig.powspctrm, ...
     'linewidth', 3, 'color', [.6 .6 .6])
    % plot the full-width half-maximum of the oscillatory component
    % power_avg = mean(osci.powspctrm, 1); % Average power across channels
    % y = power_avg(:); 
    tEnd = cputime - tStart
    disp(tEnd)
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

    % save the figure and signal completion
    saveas(gcf, '/local/data/results/osci_plot.png');
    fprintf('Workload finished successfully\n');

    function log_phase(name, stage)
        nowTime = datetime('now','TimeZone','UTC');
        absTS = posixtime(nowTime);
        relTS = absTS - posixtime(startTime);
        fprintf('PHASE %s %s ABS:%.6f REL:%.6f\n', name, stage, absTS, relTS);
    end
end
