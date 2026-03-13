#!/usr/bin/env bash
# Strict mode + propagate ERR into functions, subshells, and pipelines
set -Eeuo pipefail
# --- Root + tmux (bci) auto-wrap (safe attach-or-create) ---
# Absolute path to this script for safe re-exec
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REAL="${SCRIPT_DIR}/$(basename "$0")"

# Ensure root so the tmux server/session are root-owned
if [[ $EUID -ne 0 ]]; then
  exec sudo -E env -u TMUX BCI_TMUX_AUTOWRAP=1 "$SCRIPT_REAL" "$@"
fi

# tmux must be available before we try to use it
command -v tmux >/dev/null || { echo "ERROR: tmux not installed/in PATH"; exit 2; }

# If not already inside tmux, enter/prepare the 'bci' session
if [[ -z ${TMUX:-} && -n ${BCI_TMUX_AUTOWRAP:-} ]]; then
  if tmux has-session -t bci 2>/dev/null; then
    # Session exists: create a new window running THIS script, then attach
    win="bci-$(basename "$0")-$$"
    tmux new-window -t bci -n "$win" "$SCRIPT_REAL" "$@"
    if [[ -t 1 ]]; then
      exec tmux attach -t bci \; select-window -t "$win"
    else
      # Non-interactive caller (e.g., CI/cron): do not attach
      exit 0
    fi
  else
    # No session: create it and run THIS script as the first window
    if [[ -t 1 ]]; then
      exec tmux new-session -s bci -n "bci-$(basename "$0")" "$SCRIPT_REAL" "$@"
    else
      tmux new-session -d -s bci -n "bci-$(basename "$0")" "$SCRIPT_REAL" "$@"
      exit 0
    fi
  fi
fi
# ensure downstream shell sessions do not inherit the sentinel
unset BCI_TMUX_AUTOWRAP || true
# --- end auto-wrap ---
set -o errtrace

# Resolve script directory (for sourcing helpers.sh colocated with the script)

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

bci_init_node_owner
ORIG_USER="${BCI_NODE_OWNER_USER}"
ORIG_GROUP="${BCI_NODE_OWNER_GROUP}"
bci_apply_local_owner_access
# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Clone bci_code repo

# Move to proper directory
cd /local
BCI_ROOT="$(bci_prepare_repo)"
export BCI_ROOT
# Make Maya tool
cd "${BCI_ROOT}/tools/maya"
make CONF=Release
if [[ -f "${BCI_ROOT}/scripts/helper/hw_control_bench.c" ]]; then
  mkdir -p /local/tools
  gcc -O3 -std=c11 -pthread "${BCI_ROOT}/scripts/helper/hw_control_bench.c" -o /local/tools/hw_control_bench
fi

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
    echo "→ Unrecognized hardware ($hw_model); falling back to the existing /local filesystem."
    if [[ ! -d /local ]]; then
      echo "   /local is missing on this node. Add a storage case or attach a blockstore in your RSpec."
      exit 1
    fi
    sudo mkdir -p /local/data
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
install_startup_packages git build-essential cpuset cmake intel-cmt-cat msr-tools numactl

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

sudo chown -R "${ORIG_USER}:${ORIG_GROUP}" /local/data

#### Installing AWS CLI

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
echo "Extracting awscliv2.zip"
if unzip "awscliv2.zip"; then
  rm "awscliv2.zip"
else
  echo "Extraction failed, archive not removed."
fi
sudo ./aws/install

mkdir -p /local/data/ephys-compression-benchmark/aind-np2

# Short NP2 dataset for ID-3 (Neuropixels 2.0 session)
aws s3 sync --no-sign-request \
    s3://aind-benchmark-data/ephys-compression/aind-np2/612962_2022-04-13_19-18-04_ProbeB/ \
    /local/data/ephys-compression-benchmark/aind-np2/612962_2022-04-13_19-18-04_ProbeB

# Legacy NP1 sessions (kept for reference)
# aws s3 sync --no-sign-request \
#     s3://aind-benchmark-data/ephys-compression/aind-np1/625749_2022-08-03_15-15-06_ProbeA/ \
#     /local/data/ephys-compression-benchmark/aind-np1/625749_2022-08-03_15-15-06_ProbeA
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

bci_apply_local_owner_access
bci_verify_local_owner_access
