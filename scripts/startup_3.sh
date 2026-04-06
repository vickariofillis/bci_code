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

BCI_REPO_URL=${BCI_REPO_URL:-https://github.com/vickariofillis/bci_code.git}
BCI_REPO_REF=${BCI_REPO_REF:-main}
BCI_REPO_DIR=${BCI_REPO_DIR:-/local/bci_code}
BCI_SKIP_CLONE=${BCI_SKIP_CLONE:-0}
BCI_CANONICAL_REPO_LINK=/local/bci_code

STARTUP_LOG_DIR=/local/logs
STARTUP_LOG_PATH=${STARTUP_LOG_DIR}/startup.log
STARTUP_DONE_PATH=${STARTUP_LOG_DIR}/startup.done
STARTUP_FAILED_PATH=${STARTUP_LOG_DIR}/startup.failed

mkdir -p "${STARTUP_LOG_DIR}"
rm -f "${STARTUP_DONE_PATH}" "${STARTUP_FAILED_PATH}"
exec > >(tee -a "${STARTUP_LOG_PATH}") 2>&1

startup_on_error() {
  local ec=$?
  echo "ERROR: '${BASH_COMMAND}' failed (exit ${ec}) at ${BASH_SOURCE[1]}:${BASH_LINENO[0]}" >&2
  touch "${STARTUP_FAILED_PATH}" 2>/dev/null || true
  exit "${ec}"
}

trap startup_on_error ERR

is_truthy() {
  case "${1:-}" in
    1|on|true|yes|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_bci_repo() {
  local repo_dir="${BCI_REPO_DIR}"
  local repo_parent
  repo_parent="$(dirname "${repo_dir}")"
  mkdir -p "${repo_parent}"

  if is_truthy "${BCI_SKIP_CLONE}"; then
    [[ -d "${repo_dir}/.git" ]] || {
      echo "ERROR: BCI_SKIP_CLONE is set but ${repo_dir} is not a git checkout" >&2
      exit 1
    }
    echo "Using existing BCI checkout at ${repo_dir} (BCI_SKIP_CLONE=${BCI_SKIP_CLONE})"
  else
    if [[ -d "${repo_dir}/.git" ]]; then
      echo "Refreshing existing BCI checkout at ${repo_dir}"
      git -C "${repo_dir}" fetch --tags origin "${BCI_REPO_REF}" || git -C "${repo_dir}" fetch --tags origin
    else
      echo "Cloning ${BCI_REPO_URL} into ${repo_dir}"
      git clone "${BCI_REPO_URL}" "${repo_dir}"
    fi

    if ! git -C "${repo_dir}" checkout "${BCI_REPO_REF}"; then
      git -C "${repo_dir}" checkout -B "${BCI_REPO_REF}" "origin/${BCI_REPO_REF}"
    fi
  fi

  if [[ "${repo_dir}" != "${BCI_CANONICAL_REPO_LINK}" ]]; then
    ln -sfn "${repo_dir}" "${BCI_CANONICAL_REPO_LINK}"
  fi
}

### Log keeping

# Get ownership of /local and grant read and execute permissions to everyone
ORIG_USER=${SUDO_USER:-$(id -un)}
ORIG_GROUP=$(id -gn "$ORIG_USER")
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod -R a+rx /local
bci_write_node_owner_metadata "$ORIG_USER" "$ORIG_GROUP"

################################################################################

### Prepare bci_code repo

# Move to proper directory
cd /local
ensure_bci_repo
# Make Maya tool
cd "${BCI_CANONICAL_REPO_LINK}/tools/maya"
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

bci_prepare_local_data_mount
bci_report_local_data_mount

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo apt-get install -y git build-essential cpuset cmake intel-cmt-cat msr-tools numactl

################################################################################

### Create general directories
cd /local; mkdir -p tools; mkdir -p data;
cd data/; mkdir -p results;

################################################################################

### Installing pmu-tools

# Change directories
cd /local/tools/;
if [[ -d pmu-tools/.git ]]; then
  echo "→ Reusing existing pmu-tools checkout"
else
  # git clone https://github.com/andikleen/pmu-tools.git
  # Cloning modified pmu-tools repository (includes run information in results csv)
  git clone https://github.com/vickariofillis/pmu-tools.git
fi
cd pmu-tools/
# Install python3-pip and then install the required Python packages.
sudo apt-get install -y python3-pip
pip install -r requirements.txt
# Adjust kernel parameters to enable performance measurements.
sudo sysctl -w 'kernel.perf_event_paranoid=-1'
sudo sysctl -w 'kernel.nmi_watchdog=0'
# Install perf tools.
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-$(uname -r)
bci_probe_intel_speed_select
# Download events (for toplev)
sudo /local/tools/pmu-tools/event_download.py

################################################################################

### Installing intel-pcm

# Move to the directory that holds all tool source
cd /local/tools
if [[ -d pcm/.git ]]; then
  echo "→ Reusing existing intel-pcm checkout"
else
  git clone --recursive https://github.com/intel/pcm
fi
# Enter the repository
cd pcm
# Create a build directory
mkdir -p build
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

if command -v aws >/dev/null 2>&1; then
  echo "AWS CLI already installed: $(aws --version 2>&1)"
else
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  echo "Extracting awscliv2.zip"
  if unzip -oq "awscliv2.zip"; then
    rm "awscliv2.zip"
  else
    echo "Extraction failed, archive not removed."
  fi
  sudo ./aws/install --update
fi

mkdir -p /local/data/ephys-compression-benchmark/aind-np2

# Default short NP2 dataset for ID-3.
bci_retry_command 8 15 \
    env AWS_RETRY_MODE=adaptive AWS_MAX_ATTEMPTS=10 \
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

bci_write_node_owner_metadata "$EXPECTED_USER" "$EXPECTED_GROUP"
touch "${STARTUP_DONE_PATH}"
rm -f "${STARTUP_FAILED_PATH}"
echo "✅ startup_3.sh completed successfully"
