#!/bin/bash

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential
# Install necessary packages
sudo apt-get install -y zlib1g-dev automake autoconf cmake sox gfortran libtool protobuf-compiler python3.10 python2.7 pip  python3.10-venv curl g++ graphviz libatlas3-base libtool pkg-config subversion unzip wget

################################################################################

### Installing pmu-tools

# Create directories
mkdir /local/tools; cd /local/tools/
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

### Download other tools related to the workload (ID-20)

# Move to proper directory
cd /local/tools
# Clone Kaldi
git clone https://github.com/kaldi-asr/kaldi.git
# Clone Pykaldi
git clone https://github.com/pykaldi/pykaldi.git
# Download pykaldi
wget https://github.com/pykaldi/pykaldi/releases/download/v0.2.2/pykaldi-0.2.2-cp310-cp310-linux_x86_64.whl.gz
# Unzip pykaldi
gzip -d pykaldi-0.2.2-cp310-cp310-linux_x86_64.whl.gz

################################################################################

### Set up directories for the related tools

# Create directories
cd /local/tools; mkdir bci_project
# Transfer necessary files
cp /local/tools/pykaldi/tools/install_kaldi.sh /local/tools/bci_project
cp /local/tools/pykaldi/tools/path.sh /local/tools/bci_project
# Change directory
cd /local/tools/kaldi/tools/extras
# Sudo install mkl.sh
sudo ./install_mkl.sh
# Move to proper directory
cd /local/tools
# Create virtual environment
python3.10 -m venv bci_env
# Activate virtual environment
source bci_env/bin/activate
# Install python dependencies for pykaldi
pip install numpy==1.26.4
pip install pykaldi-0.2.2-cp310-cp310-linux_x86_64.whl
# Move to proper directory
cd /local/tools/bci_project
# Install kaldi
./install_kaldi.sh
# Give executable permissions to path.sh and run it
. path.sh
# Install more tools
pip install edit_distance==1.0.6 g2p_en==2.1.0 hydra-core==1.3.2
pip install hydra-submitit-launcher==1.1.5 hydra-optuna-sweeper==1.2.0
pip install scipy==1.11.1 numba==0.58.1 scikit-learn==1.3.2 
pip install gdown 
pip install torch

################################################################################

### Setting up ID-20 (speech decoding)

# Create directories
cd /local; mkdir data; cd data

## Download competitionData.tar.gz
#wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3" https://datadryad.org/downloads/file_stream/2547369 -O competitionData.tar.gz
# Download languageModel_5gram.tar.gz (5-gram model)
wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3" https://datadryad.org/downloads/file_stream/2547359 -O languageModel_5gram.tar.gz
# Download languageModel.tar.gz (3-gram model)
wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3" https://datadryad.org/downloads/file_stream/2547356 -O languageModel.tar.gz

## Untar competitionData.tar.gz
#tar -xvf competitionData.tar.gz
# Untar languageModel_5gram.tar.gz
tar -xvf languageModel_5gram.tar.gz
# Untar languageModel.tar.gz
tar -xvf languageModel.tar.gz

# Download pre-processed competitionData from drive (ptDecoder_ctc.zip)
gdown https://drive.google.com/uc?id=1931UPY6hrK3ipHxDJLdn4x_6vjqMq_iA
# Download RNN model from drive (speechBaseline4.zip)
gdown https://drive.google.com/uc?id=1VajRoWKkOCmgTDDzlALsTnTzf77V7Pq7

# Unzip ptDecoder_ctc.zip
unzip ptDecoder_ctc.zip
# Unzip speechBaseline4.zip
unzip speechBaseline4.zip

################################################################################

### Increase swap space

# cd ~
# sudo swapoff /swapfile
# sudo rm /swapfile
# sudo fallocate -l 40G /swapfile
# sudo chmod 600 /swapfile
# sudo mkswap /swapfile
# sudo swapon /swapfile

################################################################################

