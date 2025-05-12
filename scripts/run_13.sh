#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
chown -R $USER /local;

################################################################################

### Run workload ID-13 (Movement Intent)

cd ~;

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

# Taskset version
