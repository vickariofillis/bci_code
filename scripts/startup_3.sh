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

################################################################################

# Create general directories
cd /local; mkdir -p tools; mkdir -p data;
cd data/; mkdir -p results;

################################################################################

# Installing pmu-tools

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

# Download data

cd /local/data

sudo chown -R $USER /local/data

## Installing AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

mkdir -p /local/data/ephys-compression-benchmark/aind-np1

## Amazon CLI
aws s3 sync --no-sign-request \
    s3://aind-benchmark-data/ephys-compression/aind-np1/625749_2022-08-03_15-15-06_ProbeA/ \
    /local/data/ephys-compression-benchmark/aind-np1/625749_2022-08-03_15-15-06_ProbeA

################################################################################

cd /local/tools

# Create virtual environment
sudo apt install python3.10-venv -y
python3.10 -m venv compression_env

# Activate virtual environment
source compression_env/bin/activate

# Install python dependencies
pip install \
    numpy \
    numcodecs \
    flac_numcodecs \
    wavpack_numcodecs \
    spikeinterface==0.102.1 \
    pandas \
    probeinterface \
    pyFLAC \
    zarr \
    tqdm

# Download ephys-compression-benchmark
cd /local/; mkdir -p code; cd code

git clone https://github.com/AllenNeuralDynamics/ephys-compression.git

cd ephys-compression

sed -i 's|data_folder = Path("..\/data")|data_folder = Path("\/local\/data")|' scripts/benchmark-lossless.py
sed -i 's|results_folder = Path("..\/results")|results_folder = Path("\/local\/data\/results")|' scripts/benchmark-lossless.py
sed -i 's|scratch_folder = Path("..\/scratch")|scratch_folder = Path("\/local\/data\/scratch")|' scripts/benchmark-lossless.py


################################################################################



