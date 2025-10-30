#!/usr/bin/env bash
# Strict mode + propagate ERR into functions, subshells, and pipelines
set -Eeuo pipefail
set -o errtrace

# Resolve script directory (for sourcing helpers.sh colocated with the script)
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helpers if available; otherwise provide a minimal fallback on_error
if [[ -f "${SCRIPT_DIR}/helpers.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/helpers.sh"
else
  on_error() {
    local ec=$?
    # ${BASH_LINENO[0]} is the line in caller; ${BASH_SOURCE[1]} is the caller file.
    echo "ERROR: '${BASH_COMMAND}' failed (exit ${ec}) at ${BASH_SOURCE[1]}:${BASH_LINENO[0]}" >&2
    exit "${ec}"
  }
fi

# Install error trap
trap on_error ERR

# Lightweight guard for required executables
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command '$1' not found"; exit 1; }; }

# Example prereq checks (adjust per script needs)
require_cmd git
require_cmd sudo
require_cmd tee
require_cmd make

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
sudo apt-get install -y git build-essential cpuset cmake intel-cmt-cat

################################################################################

### Create general directories
cd /local; mkdir -p tools; mkdir -p data;
cd data/; mkdir -p results;

################################################################################

### Installing pmu-tools

# Change directories
cd /local/tools/;
# Clone the pmu-tools repository.
# git clone https://github.com/andikleen/pmu-tools.git
# Cloning modified pmu-tools repository (includes run information in results csv)
git clone https://github.com/vickariofillis/pmu-tools.git
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

### Installing intel-pcm

# Move to the directory that holds all tool source
cd /local/tools
# Download pcm-repository in /local/tools
git clone --recursive https://github.com/intel/pcm
# Enter the repository
cd pcm
# Create a build directory
mkdir build
# Switch into build directory
cd build
# Configure the build with cmake
cmake ..
# Compile PCM using all cores
cmake --build . --parallel


################################################################################

### Setting up ID-3 (Compression)

cd /local/data

sudo chown -R $USER /local/data

#### Installing AWS CLI

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
echo "Extracting awscliv2.zip"
if unzip "awscliv2.zip"; then
  rm "awscliv2.zip"
else
  echo "Extraction failed, archive not removed."
fi
sudo ./aws/install

mkdir -p /local/data/ephys-compression-benchmark/aind-np1

# Datasets
aws s3 sync --no-sign-request \
    s3://aind-benchmark-data/ephys-compression/aind-np1/625749_2022-08-03_15-15-06_ProbeA/ \
    /local/data/ephys-compression-benchmark/aind-np1/625749_2022-08-03_15-15-06_ProbeA
# aws s3 sync --no-sign-request \
#     s3://aind-benchmark-data/ephys-compression/aind-np1/634568_2022-08-05_15-59-46_ProbeA/ \
#     /local/data/ephys-compression-benchmark/aind-np1/634568_2022-08-05_15-59-46_ProbeA
# aws s3 sync --no-sign-request \
#     s3://aind-benchmark-data/ephys-compression/aind-np1/634569_2022-08-09_16-14-38_ProbeA/ \
#     /local/data/ephys-compression-benchmark/aind-np1/634569_2022-08-09_16-14-38_ProbeA
# aws s3 sync --no-sign-request \
#     s3://aind-benchmark-data/ephys-compression/aind-np1/634571_2022-08-04_14-27-05_ProbeA/ \
#     /local/data/ephys-compression-benchmark/aind-np1/634571_2022-08-04_14-27-05_ProbeA


#### Compression Benchmark

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
#cd /local/; mkdir -p code; cd code

#git clone https://github.com/AllenNeuralDynamics/ephys-compression.git

#cd ephys-compression

#sed -i 's|data_folder = Path("..\/data")|data_folder = Path("\/local\/data")|' scripts/benchmark-lossless.py
#sed -i 's|results_folder = Path("..\/results")|results_folder = Path("\/local\/data\/results")|' scripts/benchmark-lossless.py
#sed -i 's|scratch_folder = Path("..\/scratch")|scratch_folder = Path("\/local\/data\/scratch")|' scripts/benchmark-lossless.py


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

