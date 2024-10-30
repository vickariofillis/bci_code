import pickle
import hickle as hkl

objects = []

with open("data-cache/classifier_Dog_1_fft-with-time-freq-corr-1-48-r400-usf_rf3000mss2Bfrs0.pickle", "rb") as openfile:
    while True:
        try:
            objects.append(pickle.load(openfile))
        except EOFError:
            break

data = hkl.load("data-cache/data_ictal_Dog_1_fft-with-time-freq-corr-1-48-r400-usf.hkl")

print(data)
print(type(data))
print(type(data['X']))
print(type(data['X'][0]))
print(len(data['X']))
print(len(data['X'][0]))
print(type(data['y']))
print(len(data['y']))
print(type(data['latencies']))
print(len(data['latencies']))