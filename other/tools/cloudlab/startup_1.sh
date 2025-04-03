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