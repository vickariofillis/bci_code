import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import hann, welch
from scipy.optimize import curve_fit

# Time axis
t = np.linspace(0, 1, 1000)

# Generate pink noise and add oscillation
data = {'trial': [], 'time': [], 'label': ['chan'], 'trialinfo': []}
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
cfg_taper = hann(len(t))
cfg_pad = 'nextpow2'

# Calculate power spectrum using Welch's method
frac_r = []
orig_r = []
for trial in data['trial']:
    freq, power = welch(trial, fs=1000, window=cfg_taper, nperseg=len(t), scaling='density')
    frac_r.append(power)
    orig_r.append(power)

# Average across trials
frac_avg = np.mean(frac_r, axis=0)
orig_avg = np.mean(orig_r, axis=0)

# Subtract fractal component from power spectrum
osci_powspctrm = orig_avg - frac_avg

# Fit a Gaussian to the oscillatory component
def gauss(x, a, x0, sigma):
    return a * np.exp(-(x - x0) ** 2 / (2 * sigma ** 2))

popt, _ = curve_fit(gauss, freq, osci_powspctrm)
mean = popt[1]
std = popt[2] / np.sqrt(2) * 2.3548
fwhm = [mean - std / 2, mean + std / 2]

'''
# Plot the results
plt.figure()
plt.plot(freq, frac_avg, linewidth=3, color='black', label='Fractal component')
plt.plot(freq, orig_avg, linewidth=3, color=[0.6, 0.6, 0.6], label='Power spectrum')

# Plot FWHM of the oscillatory component
yl = plt.ylim()
plt.fill_between(fwhm, yl[0], yl[1], color='white', alpha=0.5, label='FWHM oscillation')
plt.legend()
plt.xlabel('Frequency (Hz)')
plt.ylabel('Power')
plt.ylim(yl)
plt.show()
'''