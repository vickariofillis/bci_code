#!/bin/bash

################################################################################

### Log keeping

# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Partition, Format, and Mount /dev/sdb at /local/data with 300GB or Maximum Available

# Desired partition size in GB
desired_gb=300

# Check if partition /dev/sdb1 exists; if not, create it.
if [ ! -b /dev/sdb1 ]; then
    echo "Partition /dev/sdb1 not found. Preparing to create a new partition on /dev/sdb."

    # Get total size of /dev/sdb in bytes
    total_bytes=$(sudo blockdev --getsize64 /dev/sdb)
    # Convert total size to GB (integer approximation)
    total_gb=$(echo "$total_bytes/1024/1024/1024" | bc)
    echo "Total size of /dev/sdb: ${total_gb}GB"

    # Determine the partition end point: desired size or total size, whichever is smaller.
    if [ "$total_gb" -ge "$desired_gb" ]; then
        partition_end="${desired_gb}GB"
    else
        partition_end="${total_gb}GB"
    fi
    echo "Will create partition ending at: $partition_end"

    # Create a new GPT partition table and a primary partition.
    sudo parted /dev/sdb --script mklabel gpt
    sudo parted /dev/sdb --script mkpart primary ext4 0GB $partition_end

    # Allow the kernel time to recognize the new partition.
    sleep 5
fi

# Format the partition as ext4 (this will erase any existing data on /dev/sdb1).
echo "Formatting /dev/sdb1 as ext4..."
sudo mkfs.ext4 -F /dev/sdb1

# Create the mount point and mount the partition.
echo "Mounting /dev/sdb1 at /local/data..."
sudo mkdir -p /local/data
sudo mount /dev/sdb1 /local/data

# Verify the mount.
df -h /local/data

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential
# Install necessary packages
sudo apt-get install -y zlib1g-dev automake autoconf cmake sox gfortran libtool protobuf-compiler python3.10 python2.7 pip  python3.10-venv curl g++ graphviz libatlas3-base libtool pkg-config subversion unzip wget

################################################################################

# Create general directories
cd /local; mkdir -p tools;
cd data/; mkdir -p results;

################################################################################

### Installing pmu-tools

# Change directories
cd /local/tools/;
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
cd /local/tools; mkdir -p bci_project
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
pip install transformers
pip install accelerate

################################################################################

### Setting up ID-20 (speech decoding) - 3 gram model

# Set variables for the source and destination directories
PROJECT_DATA="/proj/nejsustain-PG0/data/bci/id-20"
DEST_DATA="/local/data"

# Create the destination directory if it doesn't exist.
mkdir -p ${DEST_DATA}
cd ${DEST_DATA}

# Process languageModel.tar.gz (3-gram model)
if [ -f "${PROJECT_DATA}/languageModel.tar.gz" ]; then
    echo "Found languageModel.tar.gz in project storage. Copying..."
    cp "${PROJECT_DATA}/languageModel.tar.gz" .
else
    echo "languageModel.tar.gz not found. Downloading..."
    wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3" \
         https://datadryad.org/downloads/file_stream/2547356 -O languageModel.tar.gz
fi
# Always extract languageModel.tar.gz
echo "Extracting languageModel.tar.gz"
tar -xvf languageModel.tar.gz

# Process ptDecoder_ctc directory
if [ -d "${PROJECT_DATA}/ptDecoder_ctc" ]; then
    echo "Found ptDecoder_ctc directory in project storage. Copying..."
    cp -r "${PROJECT_DATA}/ptDecoder_ctc" .
else
    echo "ptDecoder_ctc not found as a directory. Downloading zip from Google Drive..."
    gdown https://drive.google.com/uc?id=1931UPY6hrK3ipHxDJLdn4x_6vjqMq_iA
    echo "Extracting ptDecoder_ctc.zip"
    unzip ptDecoder_ctc.zip
fi

# Process speechBaseline4 directory
if [ -d "${PROJECT_DATA}/speechBaseline4" ]; then
    echo "Found speechBaseline4 directory in project storage. Copying..."
    cp -r "${PROJECT_DATA}/speechBaseline4" .
else
    echo "speechBaseline4 not found as a directory. Downloading zip from Google Drive..."
    gdown https://drive.google.com/uc?id=1VajRoWKkOCmgTDDzlALsTnTzf77V7Pq7
    echo "Extracting speechBaseline4.zip"
    unzip speechBaseline4.zip
fi

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

