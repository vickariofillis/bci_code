#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
# Get ownership of /local and grant read and execute permissions to everyone
chown -R $USER:$USER /local  
chmod -R a+rx /local

################################################################################

### Run workload ID-1 (Seizure Detection - Laelaps)

cd ~;

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

# Taskset version
sudo cset shield --exec -- sh -c '
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_1_results.csv -- \
      taskset -c 6 /local/code/Laelaps_C/main \
        >> /local/data/results/id_1.log 2>&1 \
'
