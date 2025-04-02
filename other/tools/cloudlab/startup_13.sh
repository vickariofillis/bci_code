#!/bin/bash

################################################################################

### Log keeping

# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential

################################################################################

# Installing pmu-tools

# Create directories
cd /local; mkdir tools; cd tools/
# Clone the pmu-tools repository.
git clone https://github.com/andikleen/pmu-tools.git
cd pmu-tools/
# Install python3-pip and then install the required Python packages.
sudo apt-get install -y python3-pip
pip install -r requirements.txt
# Adjust kernel parameters to enable performance measurements.
sudo sysctl -w 'kernel.perf_event_paranoid=-1'
sudo sysctl -w 'kernel.nmi_watchdog=0'
# Install perf tools.
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-$(uname -r)
# Download events (for toplev)
sudo /local/tools/pmu-tools/event_download.py

################################################################################

### Setting up ID-13 (movement intent)

# Create directories
cd /local; mkdir tools; cd tools

# Download Matlab
curl -L "https://drive.usercontent.google.com/download?id={1BNoA51EHC6VbPVwtkzzw5wSs1pJ2yYD6}&confirm=xxx" -o matlab_R2024b_Linux.zip
# Unzip Matlab
unzip matlab_R2024b_Linux.zip -d matlab/
# Download Fieldtrip
curl -L "https://drive.usercontent.google.com/download?id={1KVb_tsA1KzC7AhaZUKvR0wuR9Ob9bTJe}&confirm=xxx" -o fieldtrip-20240916.zip
# Unzip Fieldtrip
unzip fieldtrip-20240916.zip -d fieldtrip/

# Create directories
cd /local/data;

# Download data files (patient 4)
wget https://osf.io/download/mgn6y/ -O S4_raw_segmented.mat
# Download data files (patient 5)
wget https://osf.io/download/qmsc4/ -O S5_raw_segmented.mat
# Download data files (patient 5)
wget https://osf.io/download/dtqky/ -O S6_raw_segmented.mat

################################################################################
