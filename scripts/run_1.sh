#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
chown -R $USER /local;

################################################################################

### Run workload ID-1 (Seizure Detection - Laelaps)

cd ~;

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

# Default version
/local/tools/pmu-tools/toplev -l6 -I 500 --no-multiplex --all -x, -o /local/data/results/id_1_profile.csv -- /local/code/Laelaps_C/main >> /local/data/results/id_1_profile.log 2>&1 | tee /local/data/results/id_1_toplev.log

# Taskset version
# /local/tools/pmu-tools/toplev \
#   -l6 -I 500 --no-multiplex --all -x, \
#   -o /local/data/results/c_profile.csv -- \
#   /usr/bin/taskset -c 0 /local/code/Laelaps_C/main \
#     >> /local/data/results/c_log_file.log 2>&1 \
# | tee /local/data/results/toplev_log.txt
