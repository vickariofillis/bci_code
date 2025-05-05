#!/bin/bash

################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
chown -R $USER /local;

################################################################################

### Run workload ID-13 (Movement Intent)

