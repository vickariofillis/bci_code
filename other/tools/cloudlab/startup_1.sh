#!/bin/bash

################################################################################

### General updates

# Update the package lists.
sudo apt-get update

# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential

################################################################################

# Installing pmu-tools

# Create directories
cd /local
mkdir tools
cd tools/

# Clone the pmu-tools repository.
sudo git clone https://github.com/andikleen/pmu-tools.git
cd pmu-tools/

# Install python3-pip and then install the required Python packages.
sudo apt-get install -y python3-pip
pip install -r requirements.txt

# Adjust kernel parameters to enable performance measurements.
sudo sysctl -w 'kernel.perf_event_paranoid=-1'
sudo sysctl -w 'kernel.nmi_watchdog=0'

# Install perf tools.
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-$(uname -r)

################################################################################

### Setting up ID-1 - (Laelaps)

# Create directories
cd /local/; mkdir laelaps; cd laelaps
# Download Laelaps code (OpenMP version)
wget http://ieeg-swez.ethz.ch/DATE2019/Laelaps_OpenMP.zip
# Unzip
unzip Laelaps_OpenMP.zip
# Install
cd Laelaps_C/;
gcc -std=c99 -fopenmp main.c -o main -lm command

################################################################################