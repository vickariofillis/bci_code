import numpy as np
from scipy import signal
from scipy.signal import resample, hann
from sklearn import preprocessing

# optional modules for trying out different transforms
try:
    import pywt
except ImportError as e:
    pass

try:
    from scikits.talkbox.features import mfcc
except ImportError as e:
    pass

import matplotlib.pyplot as plt
import seaborn as sns
import sys

# Import logging helpers
from common.logging_helpers import get_log_filename, write_headers_to_csv, write_features_to_csv

np.set_printoptions(threshold=sys.maxsize)

# NOTE(mike): All transforms take in data of the shape (NUM_CHANNELS, NUM_FEATURES)
# Although some have been written work on the last axis and may work on any-dimension data.

class FFT:
    """
    Apply Fast Fourier Transform to the last axis.
    """
    def get_name(self):
        return "fft"

    def apply(self, data, patient_id, logging_enabled):
        axis = data.ndim - 1
        transformed_data = np.fft.rfft(data, axis=axis)
        
        # Logging
        if logging_enabled:
            feature_names = [f"fft_{i}" for i in range(transformed_data.shape[axis])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class Slice:
    """
    Take a slice of the data on the last axis.
    e.g. Slice(1, 48) works like a normal python slice, that is 1-47 will be taken
    """
    def __init__(self, start, end):
        self.start = start
        self.end = end

    def get_name(self):
        return "slice%d-%d" % (self.start, self.end)

    def apply(self, data, patient_id, logging_enabled):
        ## BCINOTE: attempted to replicate desired slicing since original code produced "IndexError: only integers, slices (`:`), ellipsis (`...`), numpy.newaxis (`None`) and integer or boolean arrays are valid indices"
        # s = [slice(None),] * data.ndim
        # s[-1] = slice(self.start, self.end)
        # return data[s]
        transformed_data = data[..., slice(self.start, self.end)]

        # Logging
        if logging_enabled:
            feature_names = [f"slice_{i}" for i in range(self.start, self.end)]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class LPF:
    """
    Low-pass filter using FIR window
    """
    def __init__(self, f):
        self.f = f

    def get_name(self):
        return 'lpf%d' % self.f

    def apply(self, data, patient_id, logging_enabled):
        nyq = self.f / 2.0
        cutoff = min(self.f, nyq-1)
        h = signal.firwin(numtaps=101, cutoff=cutoff, nyq=nyq)

        # data[i][ch][dim0]
        for i in range(len(data)):
            data_point = data[i]
            for j in range(len(data_point)):
                data_point[j] = signal.lfilter(h, 1.0, data_point[j])

        # Logging
        if logging_enabled:
            feature_names = [f"lpf_{i}" for i in range(data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return data


class MFCC:
    """
    Mel-frequency cepstrum coefficients
    """
    def get_name(self):
        return "mfcc"

    def apply(self, data, patient_id, logging_enabled):
        all_ceps = []
        for ch in data:
            ceps, mspec, spec = mfcc(ch)
            all_ceps.append(ceps.ravel())

        transformed_data = np.array(all_ceps)
        
        # Logging
        if logging_enabled:
            feature_names = [f"mfcc_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class Magnitude:
    """
    Take magnitudes of Complex data
    """
    def get_name(self):
        return "mag"

    def apply(self, data, patient_id, logging_enabled):
        transformed_data = np.absolute(data)

        # Logging
        if logging_enabled:
            feature_names = [f"mag_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class MagnitudeAndPhase:
    """
    Take the magnitudes and phases of complex data and append them together.
    """
    def get_name(self):
        return "magphase"

    def apply(self, data, patient_id, logging_enabled):
        magnitudes = np.absolute(data)
        phases = np.angle(data)
        transformed_data = np.concatenate((magnitudes, phases), axis=1)
        
        # Logging
        if logging_enabled:
            feature_names = [f"magphase_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)

        return transformed_data


class Log10:
    """
    Apply Log10
    """
    def get_name(self):
        return "log10"

    def apply(self, data, patient_id, logging_enabled):
        # 10.0 * log10(re * re + im * im)
        indices = np.where(data <= 0)
        data[indices] = np.max(data)
        data[indices] = (np.min(data) * 0.1)
        transformed_data = np.log10(data)
       
        # Logging
        if logging_enabled:
            feature_names = [f"log10_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)

        return transformed_data


class Stats:
    """
    Subtract the mean, then take (min, max, standard_deviation) for each channel.
    """
    def get_name(self):
        return "stats"

    def apply(self, data, patient_id, logging_enabled):
        # data[ch][dim]
        shape = data.shape
        out = np.empty((shape[0], 3))
        for i in range(len(data)):
            ch_data = data[i]
            ch_data = data[i] - np.mean(ch_data)
            outi = out[i]
            outi[0] = np.std(ch_data)
            outi[1] = np.min(ch_data)
            outi[2] = np.max(ch_data)

        # Logging
        if logging_enabled:
            feature_names = [f'{stat}_{i}' for i in range(shape[0]) for stat in ['std', 'min', 'max']]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, out)

        return out


class Resample:
    """
    Resample time-series data.
    """
    def __init__(self, sample_rate):
        self.f = sample_rate

    def get_name(self):
        return "resample%d" % self.f

    def apply(self, data, patient_id, logging_enabled):
        axis = data.ndim - 1
        if data.shape[-1] > self.f:
            transformed_data = resample(data, self.f, axis=axis)
        else:
            transformed_data = data

        # Logging
        if logging_enabled:
            feature_names = [f"resample_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class ResampleHanning:
    """
    Resample time-series data using a Hanning window
    """
    def __init__(self, sample_rate):
        self.f = sample_rate

    def get_name(self):
        return "resample%dhanning" % self.f

    def apply(self, data, patient_id, logging_enabled):
        axis = data.ndim - 1
        transformed_data = resample(data, self.f, axis=axis, window=hann(M=data.shape[axis]))
        
        # Logging
        if logging_enabled:
            feature_names = [f"resamplehanning_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class DaubWaveletStats:
    """
    Daubechies wavelet coefficients. For each block of co-efficients
    take (mean, std, min, max)
    """
    def __init__(self, n):
        self.n = n

    def get_name(self):
        return "dwtdb%dstats" % self.n

    def apply(self, data, patient_id, logging_enabled):
        # data[ch][dim0]
        shape = data.shape
        out = np.empty((shape[0], 4 * (self.n * 2 + 1)), dtype=np.float64)

        def set_stats(outi, x, offset):
            outi[offset*4] = np.mean(x)
            outi[offset*4+1] = np.std(x)
            outi[offset*4+2] = np.min(x)
            outi[offset*4+3] = np.max(x)

        for i in range(len(data)):
            outi = out[i]
            new_data = pywt.wavedec(data[i], 'db%d' % self.n, level=self.n*2)
            for i, x in enumerate(new_data):
                set_stats(outi, x, i)

        # Logging
        if logging_enabled:
            feature_names = [f"dwtdb{self.n}stats_{i}" for i in range(out.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, out)

        return out


class UnitScale:
    """
    Scale across the last axis.
    """
    def get_name(self):
        return 'unit-scale'

    def apply(self, data, patient_id, logging_enabled):
        transformed_data = preprocessing.scale(data, axis=data.ndim-1)

        # Logging
        if logging_enabled:
            feature_names = [f"unit-scale_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)

        return transformed_data


class UnitScaleFeat:
    """
    Scale across the first axis, i.e. scale each feature.
    """
    def get_name(self):
        return 'unit-scale-feat'

    def apply(self, data, patient_id, logging_enabled):
        transformed_data = preprocessing.scale(data, axis=0)

        # Logging
        if logging_enabled:
            feature_names = [f"unit-scale-feat_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)

        return transformed_data


class CorrelationMatrix:
    """
    Calculate correlation coefficients matrix across all EEG channels.
    """
    def get_name(self):
        return 'corr-mat'

    def apply(self, data, patient_id, logging_enabled):
        transformed_data = np.corrcoef(data)
        upper_triangle = upper_right_triangle(transformed_data)

        # Logging
        if logging_enabled:
            feature_names = [f"corr-mat_{i}" for i in range(len(upper_triangle))]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class Eigenvalues:
    """
    Take eigenvalues of a matrix, and sort them by magnitude in order to
    make them useful as features (as they have no inherent order).
    """
    def get_name(self):
        return 'eigenvalues'

    def apply(self, data, patient_id, logging_enabled):
        w, v = np.linalg.eig(data)
        w = np.absolute(w)
        w.sort()

        # Logging
        if logging_enabled:
            feature_names = [f"eigenvalue_{i}" for i in range(len(w))]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, w)
        
        return w


# Take the upper right triangle of a matrix
def upper_right_triangle(matrix):
    accum = []
    for i in range(matrix.shape[0]):
        for j in range(i+1, matrix.shape[1]):
            accum.append(matrix[i, j])

    return np.array(accum)


class OverlappingFFTDeltas:
    """
    Calculate overlapping FFT windows. The time window will be split up into num_parts,
    and parts_per_window determines how many parts form an FFT segment.

    e.g. num_parts=4 and parts_per_windows=2 indicates 3 segments
    parts = [0, 1, 2, 3]
    segment0 = parts[0:1]
    segment1 = parts[1:2]
    segment2 = parts[2:3]

    Then the features used are (segment2-segment1, segment1-segment0)

    NOTE: Experimental, not sure if this works properly.
    """
    def __init__(self, num_parts, parts_per_window, start, end):
        self.num_parts = num_parts
        self.parts_per_window = parts_per_window
        self.start = start
        self.end = end

    def get_name(self):
        return "overlappingfftdeltas%d-%d-%d-%d" % (self.num_parts, self.parts_per_window, self.start, self.end)

    def apply(self, data, patient_id, logging_enabled):
        axis = data.ndim - 1

        parts = np.split(data, self.num_parts, axis=axis)

        #if slice end is 208, we want 208hz
        partial_size = (1.0 * self.parts_per_window) / self.num_parts
        #if slice end is 208, and partial_size is 0.5, then end should be 104
        partial_end = int(self.end * partial_size)

        partials = []
        for i in range(self.num_parts - self.parts_per_window + 1):
            combined_parts = parts[i:i+self.parts_per_window]
            if self.parts_per_window > 1:
                d = np.concatenate(combined_parts, axis=axis)
            else:
                d = combined_parts
            d = Slice(self.start, partial_end).apply(np.fft.rfft(d, axis=axis))
            d = Magnitude().apply(d)
            d = Log10().apply(d)
            partials.append(d)

        diffs = []
        for i in range(1, len(partials)):
            diffs.append(partials[i] - partials[i-1])

        transformed_data = np.concatenate(diffs, axis=axis)

        # Logging
        if logging_enabled:
            feature_names = [f"overlappingfftdeltas_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class FFTWithOverlappingFFTDeltas:
    """
    As above but appends the whole FFT to the overlapping data.

    NOTE: Experimental, not sure if this works properly.
    """
    def __init__(self, num_parts, parts_per_window, start, end):
        self.num_parts = num_parts
        self.parts_per_window = parts_per_window
        self.start = start
        self.end = end

    def get_name(self):
        return "fftwithoverlappingfftdeltas%d-%d-%d-%d" % (self.num_parts, self.parts_per_window, self.start, self.end)

    def apply(self, data, patient_id, logging_enabled):
        axis = data.ndim - 1

        full_fft = np.fft.rfft(data, axis=axis)
        full_fft = Magnitude().apply(full_fft)
        full_fft = Log10().apply(full_fft)

        parts = np.split(data, self.num_parts, axis=axis)

        #if slice end is 208, we want 208hz
        partial_size = (1.0 * self.parts_per_window) / self.num_parts
        #if slice end is 208, and partial_size is 0.5, then end should be 104
        partial_end = int(self.end * partial_size)

        partials = []
        for i in range(self.num_parts - self.parts_per_window + 1):
            d = np.concatenate(parts[i:i+self.parts_per_window], axis=axis)
            d = Slice(self.start, partial_end).apply(np.fft.rfft(d, axis=axis))
            d = Magnitude().apply(d)
            d = Log10().apply(d)
            partials.append(d)

        out = [full_fft]
        for i in range(1, len(partials)):
            out.append(partials[i] - partials[i-1])

        transformed_data = np.concatenate(out, axis=axis)

        # Logging
        if logging_enabled:
            feature_names = [f"fftwithoverlappingfftdeltas_{i}" for i in range(transformed_data.shape[1])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class FreqCorrelation:
    """
    Correlation in the frequency domain. First take FFT with (start, end) slice options,
    then calculate correlation co-efficients on the FFT output, followed by calculating
    eigenvalues on the correlation co-efficients matrix.

    The output features are (fft, upper_right_diagonal(correlation_coefficients), eigenvalues)

    Features can be selected/omitted using the constructor arguments.
    """
    def __init__(self, start, end, scale_option, with_fft=False, with_corr=True, with_eigen=True):
        self.start = start
        self.end = end
        self.scale_option = scale_option
        self.with_fft = with_fft
        self.with_corr = with_corr
        self.with_eigen = with_eigen
        assert scale_option in ('us', 'usf', 'none')
        assert with_corr or with_eigen

    def get_name(self):
        selections = []
        if not self.with_corr:
            selections.append('nocorr')
        if not self.with_eigen:
            selections.append('noeig')
        if len(selections) > 0:
            selection_str = '-' + '-'.join(selections)
        else:
            selection_str = ''
        return 'freq-correlation-%d-%d-%s-%s%s' % (self.start, self.end, 'withfft' if self.with_fft else 'nofft',
                                                   self.scale_option, selection_str)

    def apply(self, data, patient_id, logging_enabled):
        data1 = FFT().apply(data, patient_id, False)
        data1 = Slice(self.start, self.end).apply(data1, patient_id, False)
        data1 = Magnitude().apply(data1, patient_id, False)
        data1 = Log10().apply(data1, patient_id, False)

        data2 = data1
        if self.scale_option == 'usf':
            data2 = UnitScaleFeat().apply(data2, patient_id, False)
        elif self.scale_option == 'us':
            data2 = UnitScale().apply(data2, patient_id, False)

        data2 = CorrelationMatrix().apply(data2, patient_id, False)

        if self.with_eigen:
            w = Eigenvalues().apply(data2, patient_id, False)

        out = []
        if self.with_corr:
            data2 = upper_right_triangle(data2)
            out.append(data2)
        if self.with_eigen:
            out.append(w)
        if self.with_fft:
            data1 = data1.ravel()
            out.append(data1)
        for d in out:
            assert d.ndim == 1

        transformed_data = np.concatenate(out, axis=0)

        # Logging
        if logging_enabled:
            feature_names = [f"freq-correlation_{i}" for i in range(transformed_data.shape[0])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class TimeCorrelation:
    """
    Correlation in the time domain. First downsample the data, then calculate correlation co-efficients
    followed by calculating eigenvalues on the correlation co-efficients matrix.

    The output features are (upper_right_diagonal(correlation_coefficients), eigenvalues)

    Features can be selected/omitted using the constructor arguments.
    """
    def __init__(self, max_hz, scale_option, with_corr=True, with_eigen=True):
        self.max_hz = max_hz
        self.scale_option = scale_option
        self.with_corr = with_corr
        self.with_eigen = with_eigen
        assert scale_option in ('us', 'usf', 'none')
        assert with_corr or with_eigen

    def get_name(self):
        selections = []
        if not self.with_corr:
            selections.append('nocorr')
        if not self.with_eigen:
            selections.append('noeig')
        if len(selections) > 0:
            selection_str = '-' + '-'.join(selections)
        else:
            selection_str = ''
        return 'time-correlation-r%d-%s%s' % (self.max_hz, self.scale_option, selection_str)

    def apply(self, data, patient_id, logging_enabled):
        # so that correlation matrix calculation doesn't crash
        for ch in data:
            if np.alltrue(ch == 0.0):
                ch[-1] += 0.00001

        data1 = data
        if data1.shape[1] > self.max_hz:
            data1 = Resample(self.max_hz).apply(data1, patient_id, False)

        if self.scale_option == 'usf':
            data1 = UnitScaleFeat().apply(data1, patient_id, False)
        elif self.scale_option == 'us':
            data1 = UnitScale().apply(data1, patient_id, False)

        data1 = CorrelationMatrix().apply(data1, patient_id, False)

        if self.with_eigen:
            w = Eigenvalues().apply(data1, patient_id, False)

        out = []
        if self.with_corr:
            data1 = upper_right_triangle(data1)
            out.append(data1)
        if self.with_eigen:
            out.append(w)

        for d in out:
            assert d.ndim == 1

        transformed_data = np.concatenate(out, axis=0)

        # Logging
        if logging_enabled:
            feature_names = [f"time-correlation_{i}" for i in range(transformed_data.shape[0])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class TimeFreqCorrelation:
    """
    Combines time and frequency correlation, taking both correlation coefficients and eigenvalues.
    """
    def __init__(self, start, end, max_hz, scale_option):
        self.start = start
        self.end = end
        self.max_hz = max_hz
        self.scale_option = scale_option
        assert scale_option in ('us', 'usf', 'none')

    def get_name(self):
        return 'time-freq-correlation-%d-%d-r%d-%s' % (self.start, self.end, self.max_hz, self.scale_option)

    def apply(self, data, patient_id, logging_enabled):
        data1 = TimeCorrelation(self.max_hz, self.scale_option).apply(data, patient_id, False)
        data2 = FreqCorrelation(self.start, self.end, self.scale_option).apply(data, patient_id, False)
        assert data1.ndim == data2.ndim
        transformed_data = np.concatenate((data1, data2), axis=data1.ndim-1)

        # Logging
        if logging_enabled:
            feature_names = [f"time-freq-correlation_{i}" for i in range(transformed_data.shape[0])]
            filename = get_log_filename(patient_id)
            write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data


class FFTWithTimeFreqCorrelation:
    """
    Combines FFT with time and frequency correlation, taking both correlation coefficients and eigenvalues.
    """
    def __init__(self, start, end, max_hz, scale_option):
        self.start = start
        self.end = end
        self.max_hz = max_hz
        self.scale_option = scale_option

    def get_name(self):
        return 'fft-with-time-freq-corr-%d-%d-r%d-%s' % (self.start, self.end, self.max_hz, self.scale_option)

    def apply(self, data, patient_id, logging_enabled):
        data1 = TimeCorrelation(self.max_hz, self.scale_option).apply(data, patient_id, False)
        data2 = FreqCorrelation(self.start, self.end, self.scale_option, with_fft=True).apply(data, patient_id, False)
        assert data1.ndim == data2.ndim

        transformed_data = np.concatenate((data1, data2), axis=data1.ndim-1)

        # Logging
        if logging_enabled:
            feature_names = [f"fft-with-time-freq-corr_{i}" for i in range(transformed_data.shape[0])]
            filename = get_log_filename(patient_id)
            #write_headers_to_csv(filename, ["Feature Name", "Feature Value"])
            write_headers_to_csv(filename, feature_names)
            write_features_to_csv(filename, feature_names, transformed_data)
        
        return transformed_data
