#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
chown -R $USER /local;

################################################################################

### Run workload ID-1 (Seizure Detection - Laelaps)

cd ~;
/local/tools/pmu-tools/toplev -l6 -I 500 --no-multiplex --all -x, -o /local/data/results/c_profile.csv -- /local/code/Laelaps_C/main >> /local/data/results/c_log_file.log 2>&1 | tee /local/data/results/toplev_log.txt