import numpy as np
import matplotlib.pyplot as plt
from scipy.signal.windows import hann
from scipy.signal import welch
from scipy.optimize import curve_fit
from scipy.io import loadmat



import_data = True

#Selecting the open source data
if import_data: 
    mat_file = loadmat('data/S5_raw_segmented.mat', squeeze_me=True, struct_as_record=False)

    data_square = mat_file['data']
    data = {'trial': [], 'time': [], 'label': ['chan'], 'trialinfo': []}
    if hasattr(data_square, 'label'):
            label_data = data_square.label
            if isinstance(label_data, np.ndarray) and label_data.dtype == object:
                data['label'] = [str(item[0]) if isinstance(item, (list, np.ndarray)) else str(item) for item in label_data]
            else:
                data['label'] = label_data

    if hasattr(data_square, 'trial'):
        trial_data = data_square.trial
        if isinstance(trial_data, (np.ndarray, list)):
            data['trial'] = [t.tolist() if isinstance(t, np.ndarray) else t for t in trial_data]

    if hasattr(data_square, 'time'):
            time_data = data_square.time
            if isinstance(time_data, (np.ndarray, list)):
                data['time'] = [t.tolist() if isinstance(t, np.ndarray) else t for t in time_data]

    if hasattr(data_square, 'trialinfo'):
            trialinfo_data = data_square.trialinfo
            if isinstance(trialinfo_data, np.ndarray):
                data['trialinfo'] = trialinfo_data.tolist()
else:
    # Generate pink noise and add oscillation
    data = {'trial': [], 'time': [], 'label': ['chan'], 'trialinfo': []}
    # Time axis
    t = np.linspace(0, 1, 1000)
    for rpt in range(1, 101):
        # Generate pink noise (1/f noise)
        white_noise = np.random.randn(len(t))
        b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
        a = [1, -2.494956002, 2.017265875, -0.522189400]
        pink_noise = np.convolve(white_noise, b, mode='same')
        
        # Add 15 Hz oscillation
        fn = pink_noise + np.cos(2 * np.pi * 15 * t)
        
        # Store trial data
        data['trial'].append(fn)
        data['time'].append(t)
        data['trialinfo'].append(rpt)
        

# Partition data into overlapping sub-segments
window_length = data['time'][0][-1] - data['time'][0][0]
cfg_length = window_length * 0.9
cfg_overlap = 1 - ((window_length - cfg_length) / (10 - 1))

# Perform IRASA and spectral analysis (approximated using Welch's method)
cfg_foilim = [1, 50]
cfg_taper = hann(len(data['time']))
cfg_pad = 'nextpow2'

# Calculate power spectrum using Welch's method
frac_r = []
orig_r = []
for trial in data['trial']:
    freq, power = welch(trial, fs=1000, window=cfg_taper, nperseg=len(data['time']), scaling='density')
    frac_r.append(power)
    orig_r.append(power)

# Average across trials
if import_data:
    frac_avg = np.mean(frac_r, axis=0)
    orig_avg = np.mean(orig_r, axis=0)
else:
    frac_avg = np.mean(frac_r)
    orig_avg = np.mean(orig_r)

# Subtract fractal component from power spectrum
osci_powspctrm = orig_avg - frac_avg
if import_data:
    osci_powspctrm_avg = np.mean(osci_powspctrm, axis=0)
else:
    osci_powspctrm_avg = osci_powspctrm
# Fit a Gaussian to the oscillatory component
def gauss(x, a, x0, sigma):
    return a * np.exp(-(x - x0) ** 2 / (2 * sigma ** 2))

popt, _ = curve_fit(gauss, freq, osci_powspctrm_avg)
mean = popt[1]
std = popt[2] / np.sqrt(2) * 2.3548
fwhm = [mean - std / 2, mean + std / 2]


# Plot the results
plt.figure()
if import_data:
    frac_avg_1d = np.mean(frac_avg, axis=0)
    orig_avg_1d = np.mean(orig_avg, axis=0)
else:
    frac_avg_1d = frac_avg
    orig_avg_1d = orig_avg

plt.plot(freq, frac_avg_1d, linewidth=3, color='black', label='Fractal component')
plt.plot(freq, orig_avg_1d, linewidth=3, color=[0.6, 0.6, 0.6], label='Power spectrum')

# Plot FWHM of the oscillatory component
yl = plt.ylim()
plt.fill_between(fwhm, yl[0], yl[1], color='white', alpha=0.5, label='FWHM oscillation')
plt.legend()
plt.xlabel('Frequency (Hz)')
plt.ylabel('Power')
plt.ylim(yl)
plt.show()