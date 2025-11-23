#!/usr/bin/env bash
# Strict mode + propagate ERR into functions, subshells, and pipelines
set -Eeuo pipefail
# --- Root + tmux (bci) auto-wrap (safe attach-or-create) ---
# Absolute path to this script for safe re-exec
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_REAL="${SCRIPT_DIR}/$(basename "$0")"

# Ensure root so the tmux server/session are root-owned
if [[ $EUID -ne 0 ]]; then
  exec sudo -E env -u TMUX "$SCRIPT_REAL" "$@"
fi

# tmux must be available before we try to use it
command -v tmux >/dev/null || { echo "ERROR: tmux not installed/in PATH"; exit 2; }

# If not already inside tmux, enter/prepare the 'bci' session
if [[ -z ${TMUX:-} ]]; then
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
require_cmd python3

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

### ID1: create data_converter.py for P12 long-term data (ID12_81h.mat)

cat >/local/data_converter.py <<'EOF'
#!/usr/bin/env python3
"""data_converter.py

Convert Patient 12's long-term 1-hour file (ID12_81h.mat) into a C header
compatible with the Laelaps ID1 C implementation.

Assumptions:
  - Input .mat file contains variable 'EEG' with shape either
    (samples, channels) or (channels, samples).
  - For P12 long-term, we expect 56 channels and 3,686,400 samples at 1024 Hz.
  - We downsample from 1024 Hz to 512 Hz by taking every 2nd sample along time.
  - Output header defines:
      float Test_EEG1[NUM_SAMPLES][56];

    where NUM_SAMPLES = 3,686,400 / 2 = 1,843,200.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from scipy.io import loadmat


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--mat",
        required=True,
        help="Path to the ID12_81h.mat file (Patient 12 long-term 1h).",
    )
    p.add_argument(
        "--out",
        required=True,
        help="Path to the output header (e.g., id_1/patient/data2.h).",
    )
    p.add_argument(
        "--mat-var",
        default="EEG",
        help="Name of the variable in the .mat file that holds the EEG matrix "
             "(default: EEG).",
    )
    return p.parse_args()


def load_eeg_matrix(mat_path: Path, var_name: str) -> np.ndarray:
    try:
        mat = loadmat(mat_path)
    except Exception as e:
        raise RuntimeError(f"Failed to load {mat_path}: {e}") from e

    if var_name not in mat:
        raise KeyError(f"{mat_path} does not contain variable {var_name!r}")

    data = np.asarray(mat[var_name], dtype=np.float32)
    if data.ndim != 2:
        raise ValueError(
            f"{mat_path}: expected 2D matrix for {var_name!r}, got shape {data.shape}"
        )

    r, c = data.shape
    if r == 56 and c % 1024 == 0:
        data = data.T  # (channels, samples) → (samples, channels)
    elif c == 56 and r % 1024 == 0:
        pass          # already (samples, channels)
    else:
        raise ValueError(
            f"{mat_path}: unexpected shape {data.shape}, expected 56xN or Nx56 "
            "with N divisible by 1024"
        )

    samples, channels = data.shape
    if channels != 56:
        raise ValueError(
            f"{mat_path}: expected 56 channels after orientation, got {channels}"
        )
    if samples % 1024 != 0:
        raise ValueError(
            f"{mat_path}: expected samples to be a multiple of 1024, got {samples}"
        )

    print(
        f"[info] {mat_path}: raw samples={samples}, channels={channels}",
        file=sys.stderr,
    )
    return data


def main() -> None:
    args = parse_args()
    mat_path = Path(args.mat)
    out_path = Path(args.out)

    data = load_eeg_matrix(mat_path, args.mat_var)
    samples_raw, channels = data.shape
    if channels != 56:
        raise RuntimeError(
            f"Expected 56 channels, got {channels} from {mat_path}"
        )

    # Downsample from 1024 Hz to 512 Hz by taking every 2nd sample.
    data_ds = data[::2, :]
    samples_ds, channels_ds = data_ds.shape
    print(
        f"[info] downsampled: samples={samples_ds}, channels={channels_ds}",
        file=sys.stderr,
    )

    array_name = "Test_EEG1"

    with out_path.open("w") as f:
        f.write("#ifndef DATA2_H_\\n")
        f.write("#define DATA2_H_\\n\\n")
        f.write("#include <stdio.h>\\n")
        f.write("#include \\\"init.h\\\"\\n\\n")
        f.write("// Auto-generated from P12 long-term 1h file ID12_81h.mat\\n")
        f.write(f"// Source: {mat_path}\\n")
        f.write(
            f"// Shape after conversion: samples={samples_ds}, channels={channels_ds}\\n\\n"
        )

        f.write(
            f"float {array_name}[{samples_ds}][{channels_ds}] = {{\\n"
        )

        for i in range(samples_ds):
            row = data_ds[i]
            values = ", ".join(f"{float(x):.7g}" for x in row)
            comma = "," if i < samples_ds - 1 else ""
            f.write(f"{{{values}}}{comma}\\n")

        f.write("};\\n\\n")
        f.write("#endif\\n")

    print(f"[info] wrote header {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
EOF

chmod +x /local/data_converter.py

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
  *c240g5*|*C240G5*|*c220g2*|*C220G2*|*C220*|*UCSC-C240*|*UCSC-C220*)
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

### Setting up ID-1 (Seizure Detection - Laelaps)

# Clone the bci_code repository if it's not already present
cd /local
if [ ! -d bci_code ]; then
    git clone https://github.com/vickariofillis/bci_code.git
fi

# Set variables for the source and destination directories
PROJECT_DATA="/proj/nejsustain-PG0/data/bci/id-1"
DEST_CODE="/local/bci_code/id_1"

# Ensure destination directory exists and create test/patient layout
mkdir -p ${DEST_CODE}/test ${DEST_CODE}/patient
cd ${DEST_CODE}

# Copy data.h if available in project storage; otherwise download it into test/
if [ -f "${PROJECT_DATA}/data.h" ]; then
    echo "Found data.h in project storage. Copying..."
    cp "${PROJECT_DATA}/data.h" "${DEST_CODE}/test/data.h"
else
    echo "data.h not found. Downloading..."
    curl -L "https://drive.usercontent.google.com/download?id=1HFm67GHZZbtzRSB4ZXcjuUNn5Gh9uI93&confirm=xxx" -o "${DEST_CODE}/test/data.h"
fi

# Copy data2.h if available in project storage; otherwise download it into test/
if [ -f "${PROJECT_DATA}/data2.h" ]; then
    echo "Found data2.h in project storage. Copying..."
    cp "${PROJECT_DATA}/data2.h" "${DEST_CODE}/test/data2.h"
else
    echo "data2.h not found. Downloading..."
    curl -L "https://drive.usercontent.google.com/download?id=1Yi9pr8-RFxi_9xgks_7h_HWjAZ5tmTnu&confirm=xxx" -o "${DEST_CODE}/test/data2.h"
fi

# Initialize the patient dataset headers using the short test data
cp "${DEST_CODE}/test/data.h" "${DEST_CODE}/patient/data.h"

################################################################################

### ID1: download Patient 12 long-term file and prepare patient data

cd /local/bci_code/id_1

# Download 1-hour file for Patient 12 (81st hour)
wget -O /local/bci_code/id_1/ID12_81h.mat \
  http://ieeg-swez.ethz.ch/long-term_dataset/ID12/ID12_81h.mat

# Ensure Python dependencies for the converter are available
sudo apt-get install -y python3-numpy python3-scipy

# Generate patient/data2.h from ID12_81h.mat using the converter
mkdir -p /local/bci_code/id_1/patient
python3 /local/data_converter.py \
  --mat /local/bci_code/id_1/ID12_81h.mat \
  --out /local/bci_code/id_1/patient/data2.h

# Build the Laelaps binaries for both modes
cd /local/bci_code
make id_1/main_test id_1/main_patient

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
