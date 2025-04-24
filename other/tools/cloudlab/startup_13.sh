#!/bin/bash

################################################################################

### Log keeping

# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Function for setting a title to the terminal tab

bashrc="$HOME/.bashrc"

# Don’t add it twice
if ! grep -q 'function set-title' "$bashrc"; then
  cat <<'EOF' >> "$bashrc"

# Set Title to a terminal tab
function set-title() {
    if [[ -z "$orig" ]]; then
        orig=$PS1
    fi
    title="\[\e]2;$*\a\]"
    PS1=${orig}${title}
}
EOF

  echo "✅ set-title() added to $bashrc"
else
  echo "ℹ️  set-title() already present in $bashrc"
fi

# Reload ~/.bashrc so you can use it immediately
# (you can also just open a new shell)
source "$bashrc"

################################################################################

# ### Partition, Format, and Mount /dev/sdb at /local/data with 300GB or Maximum Available

# # Desired partition size in GB
# desired_gb=300

# # Check if partition /dev/sdb1 exists; if not, create it.
# if [ ! -b /dev/sdb1 ]; then
#     echo "Partition /dev/sdb1 not found. Preparing to create a new partition on /dev/sdb."

#     # Get total size of /dev/sdb in bytes
#     total_bytes=$(sudo blockdev --getsize64 /dev/sdb)
#     # Convert total size to GB (integer approximation)
#     total_gb=$(echo "$total_bytes/1024/1024/1024" | bc)
#     echo "Total size of /dev/sdb: ${total_gb}GB"

#     # Determine the partition end point: desired size or total size, whichever is smaller.
#     if [ "$total_gb" -ge "$desired_gb" ]; then
#         partition_end="${desired_gb}GB"
#     else
#         partition_end="${total_gb}GB"
#     fi
#     echo "Will create partition ending at: $partition_end"

#     # Create a new GPT partition table and a primary partition.
#     sudo parted /dev/sdb --script mklabel gpt
#     sudo parted /dev/sdb --script mkpart primary ext4 0GB $partition_end

#     # Allow the kernel time to recognize the new partition.
#     sleep 5
# fi

# # Format the partition as ext4 (this will erase any existing data on /dev/sdb1).
# echo "Formatting /dev/sdb1 as ext4..."
# sudo mkfs.ext4 -F /dev/sdb1

# # Create the mount point and mount the partition.
# echo "Mounting /dev/sdb1 at /local/data..."
# sudo mkdir -p /local/data
# sudo mount /dev/sdb1 /local/data

# # Verify the mount.
# df -h /local/data

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential

################################################################################

### Create general directories
cd /local; mkdir -p tools; mkdir -p data;
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

### Setting up ID-13 (Movement Intent)

# Create directories
cd /local; mkdir -p tools; cd tools

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

### Off-line every cpuX except cpu0, no matter how many there are

for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
  cpu=${cpu_dir##*/cpu}
  if [ "$cpu" -ne 0 ]; then
    echo 0 | sudo tee "$cpu_dir/online"
  fi
done

# Verify
echo "Remaining online CPUs:" 
cat /sys/devices/system/cpu/online
