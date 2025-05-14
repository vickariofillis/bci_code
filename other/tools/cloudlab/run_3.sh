#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
chown -R $USER /local;

################################################################################

### Run workload ID-3 (Compression)
cd /local/code/ephys-compression;
/local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/aind-np1-flac-profile.csv \
    -- python scripts/benchmark-lossless.py aind-np1 0.1s flac >> /local/data/results/aind-np1-flac-compression.log \
    2>&1 | tee /local/data/results/aind-np1-flac-toplev-compression.log

