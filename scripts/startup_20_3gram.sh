#!/bin/bash
set -e

################################################################################

### Log keeping

# Get ownership of /local and grant read and execute permissions to everyone
ORIG_USER=${SUDO_USER:-$(id -un)}
ORIG_GROUP=$(id -gn "$ORIG_USER")
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod -R a+rx /local
# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Clone bci_code repo

# Move to proper directory
cd /local
# Clone directory
git clone https://github.com/vickariofillis/bci_code.git
# Make Maya tool
cd bci_code/tools/maya
make CONF=Release

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

### Increase storage

# 1) Detect hardware
hw_model="unknown"
if [ -r /sys/devices/virtual/dmi/id/product_name ]; then
  hw_model=$(cat /sys/devices/virtual/dmi/id/product_name)
fi
echo "Hardware model: $hw_model"

# 2) Storage setup by model
case "$hw_model" in

  # Any C220 family (c240g5, c220g2, UCSC-C220-M4S, etc.)
  *c240g5*|*C240G5*|*c220g2*|*C220G2*|*C220*|*UCSC-C220*)
    echo "→ Detected C220/C240 family: partitioning /dev/sdb → /local/data"

    desired_gb=300
    if [ ! -b /dev/sdb1 ]; then
      echo "Partition /dev/sdb1 missing, creating new on /dev/sdb…"
      total_bytes=$(sudo blockdev --getsize64 /dev/sdb)
      total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))
      echo "Disk /dev/sdb is ${total_gb}GB"

      if [ "$total_gb" -ge "$desired_gb" ]; then
        partition_end="${desired_gb}GB"
      else
        partition_end="${total_gb}GB"
      fi
      echo "Creating partition 0–${partition_end}"

      sudo parted /dev/sdb --script mklabel gpt
      sudo parted /dev/sdb --script mkpart primary ext4 0GB $partition_end
      sleep 5
    fi

    echo "Formatting /dev/sdb1 as ext4…"
    sudo mkfs.ext4 -F /dev/sdb1

    echo "Mounting /dev/sdb1 at /local/data…"
    sudo mkdir -p /local/data
    sudo mount /dev/sdb1 /local/data
    ;;

  # XL170 family
  *XL170*|*xl170*|*ProLiant\ XL170r*|*XL170r*)
    echo "→ Detected XL170: expanding /dev/sda3 to fill SSD…"

    if ! command -v growpart &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y cloud-guest-utils
    fi

    echo "Running growpart /dev/sda 3"
    sudo growpart /dev/sda 3

    echo "Resizing ext4 on /dev/sda3"
    sudo resize2fs /dev/sda3

    echo "Ensuring /local/data exists"
    sudo mkdir -p /local/data
    ;;

  # Any other hardware
  *)
    echo "→ Unrecognized hardware ($hw_model)."
    echo "   Please add a case for this node or attach a blockstore in your RSpec."
    exit 1
    ;;
esac

# 3) Final check
echo "=== /local/data usage ==="
df -h /local/data
echo "========================="

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential
# Install necessary packages
sudo apt-get install -y zlib1g-dev automake autoconf cmake sox gfortran libtool protobuf-compiler python3.10 python2.7 pip  python3.10-venv curl g++ graphviz libatlas3-base libtool pkg-config subversion unzip wget cpuset

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

### Setting up ID-20 (Speech Decoding) - 3 gram model

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
if [ $? -eq 0 ]; then
  rm languageModel.tar.gz
else
  echo "Extraction failed, archive not removed."
fi

# Process ptDecoder_ctc file
if [ -f "${PROJECT_DATA}/ptDecoder_ctc" ]; then
    echo "Found ptDecoder_ctc file in project storage. Copying..."
    cp "${PROJECT_DATA}/ptDecoder_ctc" .
else
    echo "ptDecoder_ctc not found as a file. Downloading zip from Google Drive..."
    gdown https://drive.google.com/uc?id=1931UPY6hrK3ipHxDJLdn4x_6vjqMq_iA -O ptDecoder_ctc.zip
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

### Clone bci_code directory

# Move to proper directory
cd /local/tools/bci_project/
# Clone directory
git clone https://github.com/vickariofillis/bci_code.git

################################################################################

# Get ownership of /local and grant read and execute permissions to everyone
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
sudo chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod    -R a+rx                  /local

###  Final verification of /local ownership & permissions
# Determine who *should* own /local (the user who invoked sudo, or yourself if not using sudo)
EXPECTED_USER=${SUDO_USER:-$(id -un)}
EXPECTED_GROUP=$(id -gn "$EXPECTED_USER")
echo "Verifying that everything under /local is owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and has a+rx..."

# 1) Any file not owned by EXPECTED_USER:EXPECTED_GROUP?
bad_owner=$(find /local \
    ! -user "$EXPECTED_USER" -o ! -group "$EXPECTED_GROUP" \
    -print -quit 2>/dev/null || true)

# 2) Any entry missing read for all? (i.e. not -r--r--r--)
bad_read=$(find /local \
    ! -perm -444 \
    -print -quit 2>/dev/null || true)

# 3) Any entry missing exec for all? (i.e. not --x--x--x--)
bad_exec=$(find /local \
    ! -perm -111 \
    -print -quit 2>/dev/null || true)

if [[ -z "$bad_owner" && -z "$bad_read" && -z "$bad_exec" ]]; then
    echo "✅ All files under /local are owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and have a+rx"
else
    [[ -n "$bad_owner" ]] && echo "❌ Ownership mismatch example: $bad_owner"
    [[ -n "$bad_read"  ]] && echo "❌ Missing read bit example:  $bad_read"
    [[ -n "$bad_exec"  ]] && echo "❌ Missing exec bit example:  $bad_exec"
    exit 1
fi
