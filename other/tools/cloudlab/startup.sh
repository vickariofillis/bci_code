#!/bin/bash

################################################################################

### General updates and installing pmu-tools ###

# Update the package lists.
sudo apt-get update

# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential

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

################################################################################

### Setting up ID-20 (speech decoding) datasets

cd /local
mkdir data
cd data

# Download competitionData.tar.gz
# wget https://datadryad.org/downloads/file_stream/2547369 -O competitionData.tar.gz
# Download languageModel_5gram.tar.gz
# wget https://datadryad.org/downloads/file_stream/2547359 -O languageModel_5gram.tar.gz
# Download languageModel_5gram.tar.gz
# wget https://datadryad.org/downloads/file_stream/2547356 -O languageModel_5gram.tar.gz

# Untar competitionData.tar.gz
# tar -xvf competitionData.tar.gz
# Untar languageModel_5gram.tar.gz
# tar -xvf languageModel_5gram.tar.gz
# Untar languageModel_5gram.tar.gz
# tar -xvf languageModel_5gram.tar.gz

wget https://datadryad.org/downloads/file_stream/2547371 -O diagnosticBlocks.tar.gz
tar -xvf diagnosticBlocks.tar.gz