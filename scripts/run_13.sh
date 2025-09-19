#!/bin/bash
set -euo pipefail

################################################################################
### 0. Initialize environment (tmux, logging, CLI parsing, helpers)
################################################################################

# Detect help requests early so we can show usage without spawning tmux
request_help=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      request_help=true
      break
      ;;
  esac
done

# Start tmux session if running outside tmux
if [[ -z ${TMUX:-} && $request_help == "false" ]]; then
  session_name="$(basename "$0" .sh)"
  script_path="$(readlink -f "$0")"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$script_path" "$@"
fi

# Create unified log file
mkdir -p /local/logs
exec > >(tee -a /local/logs/run.log) 2>&1

# Define command-line interface metadata
CLI_OPTIONS=(
  "-h, --help||Show this help message and exit"
  "--toplev-basic||Run Intel toplev in basic metric mode"
  "--toplev-execution||Run Intel toplev in execution pipeline mode"
  "--toplev-full||Run Intel toplev in full metric mode"
  "--maya||Run the Maya microarchitectural profiler"
  "--pcm||Run pcm core/socket counters"
  "--pcm-memory||Run the pcm-memory bandwidth profiler"
  "--pcm-power||Run the pcm-power energy profiler"
  "--pcm-pcie||Run the pcm-pcie bandwidth profiler"
  "--pcm-all||Enable every PCM profiler (default when no PCM flag is set)"
  "--short||Shortcut for a quick pass (toplev-basic, toplev-execution, Maya, all PCM tools)"
  "--long||Run the full profiling suite (all tools enabled)"
  "--turbo|state|Set CPU Turbo Boost state (on/off; default: off)"
  "--cpu-cap|watts|Set CPU package power cap in watts (default: 15)"
  "--dram-cap|watts|Set DRAM power cap in watts (default: 5)"
  "--freq|ghz|Pin CPUs to the specified frequency in GHz (default: 1.2)"
)

print_help() {
  local script_name="$(basename "$0")"
  echo "Usage: ${script_name} [options]"
  echo
  echo "Options:"
  local entry flag value desc display_flag
  for entry in "${CLI_OPTIONS[@]}"; do
    IFS='|' read -r flag value desc <<< "$entry"
    display_flag="$flag"
    if [[ -n $value ]]; then
      display_flag+=" <${value}>"
    fi
    printf '  %-28s %s\n' "$display_flag" "$desc"
  done
  echo
  echo "Options that require values will display the value name in angle brackets."
  echo "If no options are provided, all profilers run by default."
}

# Parse tool selection arguments
run_toplev_basic=false
run_toplev_full=false
run_toplev_execution=false
run_maya=false
run_pcm=false
run_pcm_memory=false
run_pcm_power=false
run_pcm_pcie=false
turbo_state="${TURBO_STATE:-off}"
pkg_cap_w="${PKG_W:-15}"
dram_cap_w="${DRAM_W:-5}"
freq_request=""
pin_freq_khz_default="${PIN_FREQ_KHZ:-1200000}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev-basic)      run_toplev_basic=true ;;
    --toplev-full)       run_toplev_full=true ;;
    --toplev-execution)  run_toplev_execution=true ;;
    --maya)              run_maya=true ;;
    --pcm)               run_pcm=true ;;
    --pcm-memory)        run_pcm_memory=true ;;
    --pcm-power)         run_pcm_power=true ;;
    --pcm-pcie)          run_pcm_pcie=true ;;
    --turbo=*)
      turbo_state="${1#--turbo=}"
      ;;
    --turbo)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --turbo" >&2
        exit 1
      fi
      turbo_state="$2"
      shift
      ;;
    --cpu-cap=*)
      pkg_cap_w="${1#--cpu-cap=}"
      ;;
    --cpu-cap)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --cpu-cap" >&2
        exit 1
      fi
      pkg_cap_w="$2"
      shift
      ;;
    --dram-cap=*)
      dram_cap_w="${1#--dram-cap=}"
      ;;
    --dram-cap)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --dram-cap" >&2
        exit 1
      fi
      dram_cap_w="$2"
      shift
      ;;
    --freq=*)
      freq_request="${1#--freq=}"
      ;;
    --freq)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --freq" >&2
        exit 1
      fi
      freq_request="$2"
      shift
      ;;
    --pcm-all)
      run_pcm=true
      run_pcm_memory=true
      run_pcm_power=true
      run_pcm_pcie=true
      ;;
    --short)
      run_toplev_basic=true
      run_toplev_full=false
      run_toplev_execution=true
      run_maya=true
      run_pcm=true
      run_pcm_memory=true
      run_pcm_power=true
      run_pcm_pcie=true
      ;;
    --long)
      run_toplev_basic=true
      run_toplev_full=true
      run_toplev_execution=true
      run_maya=true
      run_pcm=true
      run_pcm_memory=true
      run_pcm_power=true
      run_pcm_pcie=true
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_help >&2
      exit 1
      ;;
  esac
  shift
done

turbo_state="${turbo_state,,}"
case "$turbo_state" in
  on|off) ;;
  *)
    echo "Invalid value for --turbo: '$turbo_state' (expected 'on' or 'off')" >&2
    exit 1
    ;;
esac

if [[ ! $pkg_cap_w =~ ^[0-9]+$ ]]; then
  echo "Invalid value for --cpu-cap: '$pkg_cap_w' (expected integer watts)" >&2
  exit 1
fi

if [[ ! $dram_cap_w =~ ^[0-9]+$ ]]; then
  echo "Invalid value for --dram-cap: '$dram_cap_w' (expected integer watts)" >&2
  exit 1
fi

freq_request="${freq_request,,}"
if [[ -n $freq_request ]]; then
  if [[ ! $freq_request =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Invalid value for --freq: '$freq_request' (expected GHz as a number)" >&2
    exit 1
  fi
  PIN_FREQ_KHZ="$(awk -v ghz="$freq_request" 'BEGIN{printf "%d", ghz*1000000}')"
else
  if [[ ! $pin_freq_khz_default =~ ^[0-9]+$ ]]; then
    echo "Invalid PIN_FREQ_KHZ default: '$pin_freq_khz_default'" >&2
    exit 1
  fi
  PIN_FREQ_KHZ="$pin_freq_khz_default"
fi

PKG_W="$pkg_cap_w"
DRAM_W="$dram_cap_w"

freq_target_ghz="$(awk -v khz="$PIN_FREQ_KHZ" 'BEGIN{printf "%.3f", khz/1000000}')"
if ! $run_toplev_basic && ! $run_toplev_full && ! $run_toplev_execution && \
   ! $run_maya && ! $run_pcm && ! $run_pcm_memory && \
   ! $run_pcm_power && ! $run_pcm_pcie; then
  run_toplev_basic=true
  run_toplev_full=true
  run_toplev_execution=true
  run_maya=true
  run_pcm=true
  run_pcm_memory=true
  run_pcm_power=true
  run_pcm_pcie=true
fi

# Describe this workload for logging
workload_desc="ID-13 (Movement Intent)"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev_full && tools_list+=("toplev-full")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_maya && tools_list+=("maya")
$run_pcm && tools_list+=("pcm")
$run_pcm_memory && tools_list+=("pcm-memory")
$run_pcm_power && tools_list+=("pcm-power")
$run_pcm_pcie && tools_list+=("pcm-pcie")
tool_msg=$(IFS=, ; echo "${tools_list[*]}")
echo "Testing $workload_desc with tools: $tool_msg"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

# Record experiment start time
echo "Experiment started at: $(TZ=America/Toronto date '+%Y-%m-%d - %H:%M')"

# Helper for consistent timestamps
timestamp() {
  TZ=America/Toronto date '+%Y-%m-%d - %H:%M'
}

# Initialize timing variables
toplev_basic_start=0
toplev_basic_end=0
toplev_full_start=0
toplev_full_end=0
toplev_execution_start=0
toplev_execution_end=0
maya_start=0
maya_end=0
pcm_start=0
pcm_end=0
pcm_mem_start=0
pcm_mem_end=0
pcm_power_start=0
pcm_power_end=0
pcm_pcie_start=0
pcm_pcie_end=0

# Format seconds as "Xd Yh Zm"
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

# Wait for system to cool/idle before each run
idle_wait() {
  local MIN_SLEEP="${IDLE_MIN_SLEEP:-45}"
  local TEMP_TARGET_MC="${IDLE_TEMP_TARGET_MC:-50000}"
  local TEMP_PATH="${IDLE_TEMP_PATH:-/sys/class/thermal/thermal_zone0/temp}"
  local MAX_WAIT="${IDLE_MAX_WAIT:-600}"
  local SLEEP_STEP=3
  local waited=0
  local message="minimum sleep ${MIN_SLEEP}s elapsed"

  sleep "${MIN_SLEEP}"
  waited=$((waited+MIN_SLEEP))
  if [ -r "${TEMP_PATH}" ]; then
    while :; do
      t=$(cat "${TEMP_PATH}" 2>/dev/null || echo "")
      if [ -n "$t" ] && [ "$t" -le "$TEMP_TARGET_MC" ]; then
        message="temperature ${t}mc ≤ ${TEMP_TARGET_MC}mc"
        break
      fi
      if [ "$waited" -ge "$MAX_WAIT" ]; then
        message="timeout at ${waited}s; temperature ${t:-unknown}mc"
        break
      fi
      sleep "$SLEEP_STEP"
      waited=$((waited+SLEEP_STEP))
    done
  else
    message="temperature sensor unavailable"
  fi
  echo "Idle wait complete after ${waited}s (${message})"
  echo
}

################################################################################
### 1. Create results directory and placeholder logs
################################################################################
cd /local; mkdir -p data/results
# Determine permissions target based on original invoking user
RUN_USER=${SUDO_USER:-$(id -un)}
RUN_GROUP=$(id -gn "$RUN_USER")
# Get ownership of /local and grant read+execute to everyone
chown -R "$RUN_USER":"$RUN_GROUP" /local
chmod -R a+rx /local

# Prepare placeholder logs for any disabled tools so that later consolidation
# yields a consistent done.log.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_pcm_pcie.log

################################################################################
### 2. Configure and verify power settings
################################################################################
# Load msr module to allow power management commands
sudo modprobe msr || true

# Summarize requested power configuration
echo "Requested Turbo Boost: $turbo_state"
echo "Requested CPU package power cap: ${PKG_W} W"
echo "Requested DRAM power cap: ${DRAM_W} W"
echo "Requested frequency pin: ${freq_target_ghz} GHz (${PIN_FREQ_KHZ} KHz)"

# Configure turbo state (ignore failures)
if [[ $turbo_state == "off" ]]; then
  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
  echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost      >/dev/null 2>&1 || true
else
  echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
  echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost      >/dev/null 2>&1 || true
fi

# RAPL package & DRAM caps (safe defaults; no-op if absent)
: "${RAPL_WIN_US:=10000}"   # 10ms
DOM=/sys/class/powercap/intel-rapl:0
[ -e "$DOM/constraint_0_power_limit_uw" ] && \
  echo $((PKG_W*1000000)) | sudo tee "$DOM/constraint_0_power_limit_uw" >/dev/null || true
[ -e "$DOM/constraint_0_time_window_us" ] && \
  echo "$RAPL_WIN_US"     | sudo tee "$DOM/constraint_0_time_window_us" >/dev/null || true
DRAM=/sys/class/powercap/intel-rapl:0:0
[ -e "$DRAM/constraint_0_power_limit_uw" ] && \
  echo $((DRAM_W*1000000)) | sudo tee "$DRAM/constraint_0_power_limit_uw" >/dev/null || true

# Determine CPU list from this script’s existing taskset/cset lines
SCRIPT_FILE="$(readlink -f "$0")"
CPU_LIST_RAW="$(
  { grep -Eo 'taskset -c[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $3}';
    grep -Eo 'cset shield --cpu[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $4}'; } 2>/dev/null
)"
CPU_LIST="$(echo "$CPU_LIST_RAW" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | uniq | paste -sd, -)"
[ -z "$CPU_LIST" ] && CPU_LIST="0"   # fallback, should not happen

# Mandatory frequency pinning on the CPUs already used by this script
: "${PIN_FREQ_KHZ:=1200000}"   # e.g., 1.2 GHz
for cpu in $(echo "$CPU_LIST" | tr ',' ' '); do
  # Try cpupower first
  sudo cpupower -c "$cpu" frequency-set -g userspace >/dev/null 2>&1 || true
  sudo cpupower -c "$cpu" frequency-set -d "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
  sudo cpupower -c "$cpu" frequency-set -u "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
  # Fallback to sysfs if cpupower not available
  if [ -d "/sys/devices/system/cpu/cpu$cpu/cpufreq" ]; then
    echo userspace | sudo tee "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" >/dev/null 2>&1 || true
    echo "$PIN_FREQ_KHZ" | sudo tee "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_min_freq" >/dev/null 2>&1 || true
    echo "$PIN_FREQ_KHZ" | sudo tee "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_max_freq" >/dev/null 2>&1 || true
  fi
done

# Display resulting power, turbo, and frequency settings
# Ensure CPU_LIST exists (fallback recompute from this script)
if [ -z "${CPU_LIST:-}" ]; then
  SCRIPT_FILE="$(readlink -f "$0")"
  CPU_LIST_RAW="$(
    { grep -Eo 'taskset -c[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $3}';
      grep -Eo 'cset shield --cpu[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $4}'; } 2>/dev/null
  )"
  CPU_LIST="$(echo "$CPU_LIST_RAW" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | uniq | paste -sd, -)"
  [ -z "$CPU_LIST" ] && CPU_LIST="0"
fi

echo
echo "----------------------------"
echo "Power and frequency settings"
echo "----------------------------"

# Turbo state
if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
  echo "intel_pstate.no_turbo = $(cat /sys/devices/system/cpu/intel_pstate/no_turbo) (1=disabled)"
fi
if [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
  echo "cpufreq.boost        = $(cat /sys/devices/system/cpu/cpufreq/boost) (0=disabled)"
fi

# RAPL package/DRAM caps
DOM=/sys/class/powercap/intel-rapl:0
if [ -r "$DOM/constraint_0_power_limit_uw" ]; then
  pkg_uw=$(cat "$DOM/constraint_0_power_limit_uw")
  printf "RAPL PKG limit       = %.3f W\n" "$(awk -v x="$pkg_uw" 'BEGIN{print x/1000000}')"
fi
if [ -r "$DOM/constraint_0_time_window_us" ]; then
  echo "RAPL PKG window (us) = $(cat "$DOM/constraint_0_time_window_us")"
fi
DRAM=/sys/class/powercap/intel-rapl:0:0
if [ -r "$DRAM/constraint_0_power_limit_uw" ]; then
  dram_uw=$(cat "$DRAM/constraint_0_power_limit_uw")
  printf "RAPL DRAM limit      = %.3f W\n" "$(awk -v x="$dram_uw" 'BEGIN{print x/1000000}')"
fi

# Frequency pinning status for all CPUs used in this script
for cpu in $(echo "$CPU_LIST" | tr ',' ' '); do
  base="/sys/devices/system/cpu/cpu$cpu/cpufreq"
  if [ -d "$base" ]; then
    gov=$(cat "$base/scaling_governor" 2>/dev/null || echo "?")
    fmin=$(cat "$base/scaling_min_freq" 2>/dev/null || echo "?")
    fmax=$(cat "$base/scaling_max_freq" 2>/dev/null || echo "?")
    echo "cpu$cpu: governor=$gov min_khz=$fmin max_khz=$fmax"
  fi
done
echo

################################################################################
### 3. Change into the home directory
################################################################################
cd ~

################################################################################
### 4. PCM profiling
################################################################################

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  sudo modprobe msr
fi

if $run_pcm_pcie; then
  echo
  echo "----------------------------"
  echo "PCM-PCIE"
  echo "----------------------------"
  idle_wait
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_13_pcm_pcie.csv \
      -B 1.0 -- \
      bash -lc "
        export MLM_LICENSE_FILE=\"27000@mlm.ece.utoronto.ca\"
        export LM_LICENSE_FILE=\"${MLM_LICENSE_FILE}\"
        export MATLAB_PREFDIR=\"/local/tools/matlab_prefs/R2024b\"

        taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash \
          -r \"cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;\"
      "
  ' >> /local/data/results/id_13_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_pcm_pcie.log
fi

if $run_pcm; then
  echo
  echo "----------------------------"
  echo "PCM"
  echo "----------------------------"
  idle_wait
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo -E bash -lc '
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_13_pcm.csv \
      0.5 -- \
      bash -lc "
        export MLM_LICENSE_FILE=\"27000@mlm.ece.utoronto.ca\"
        export LM_LICENSE_FILE=\"${MLM_LICENSE_FILE}\"
        export MATLAB_PREFDIR=\"/local/tools/matlab_prefs/R2024b\"

        taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash \
          -r \"cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;\"
      "
  ' >> /local/data/results/id_13_pcm.log 2>&1
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_pcm.log
fi

if $run_pcm_memory; then
  echo
  echo "----------------------------"
  echo "PCM-MEMORY"
  echo "----------------------------"
  idle_wait
  echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo -E bash -lc '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_13_pcm_memory.csv \
      0.5 -- \
      bash -lc "
        export MLM_LICENSE_FILE=\"27000@mlm.ece.utoronto.ca\"
        export LM_LICENSE_FILE=\"${MLM_LICENSE_FILE}\"
        export MATLAB_PREFDIR=\"/local/tools/matlab_prefs/R2024b\"

        taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash \
          -r \"cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;\"
      "
  ' >> /local/data/results/id_13_pcm_memory.log 2>&1
  pcm_mem_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_mem_runtime")" \
    > /local/data/results/done_pcm_memory.log
fi

if $run_pcm_power; then
  echo
  echo "----------------------------"
  echo "PCM-POWER"
  echo "----------------------------"
  idle_wait
  echo "pcm-power started at: $(timestamp)"
  pcm_power_start=$(date +%s)
  sudo -E bash -lc '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_13_pcm_power.csv -- \
      bash -lc "
        export MLM_LICENSE_FILE=\"27000@mlm.ece.utoronto.ca\"
        export LM_LICENSE_FILE=\"${MLM_LICENSE_FILE}\"
        export MATLAB_PREFDIR=\"/local/tools/matlab_prefs/R2024b\"

        taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash \
          -r \"cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;\"
      "
  ' >> /local/data/results/id_13_pcm_power.log 2>&1
  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  echo "pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")" \
    > /local/data/results/done_pcm_power.log
fi

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  echo "PCM profiling finished at: $(timestamp)"
fi
################################################################################
### 5. Shield Core 8 (CPU 5) and Core 9 (CPU 6)
###    (reserve them for our measurement + workload)
################################################################################
echo
echo "----------------------------"
echo "CPU shielding"
echo "----------------------------"
sudo cset shield --cpu 5,6 --kthread=on
echo

################################################################################
### 6. Maya profiling
################################################################################

if $run_maya; then
  echo
  echo "----------------------------"
  echo "MAYA"
  echo "----------------------------"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    set -euo pipefail
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    # Start Maya on CPU 5 in background; capture PID immediately
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_13_maya.txt 2>&1 &
    MAYA_PID=$!

    # Small startup delay to avoid cold-start hiccups
    sleep 1

    # Portable verification (no 'ps ... cpuset')
    {
      echo "[verify] maya pid=$MAYA_PID"
      ps -o pid,psr,comm -p "$MAYA_PID" || true                # processor column is widely supported
      taskset -cp "$MAYA_PID" || true                          # shows allowed CPUs
      # cpuset/cgroup path (v1 or v2)
      cat "/proc/$MAYA_PID/cpuset" 2>/dev/null || \
      cat "/proc/$MAYA_PID/cgroup" 2>/dev/null || true
    } || true

    # Run workload on CPU 6
    taskset -c 6 /local/tools/matlab/bin/matlab \
      -nodisplay -nosplash \
      -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
      >> /local/data/results/id_13_maya.log 2>&1 || true

    # Idempotent teardown with escalation and reap
    for sig in TERM KILL; do
      if kill -0 "$MAYA_PID" 2>/dev/null; then
        kill -s "$sig" "$MAYA_PID" 2>/dev/null || true
        timeout 5s bash -lc "while kill -0 $MAYA_PID 2>/dev/null; do sleep 0.2; done" || true
      fi
      kill -0 "$MAYA_PID" 2>/dev/null || break
    done
    wait "$MAYA_PID" 2>/dev/null || true
  '
  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_maya.log
fi
echo

################################################################################
### 7. Toplev basic profiling
################################################################################

if $run_toplev_basic; then
  echo
  echo "----------------------------"
  echo "TOPLEV BASIC"
  echo "----------------------------"
  idle_wait
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o /local/data/results/id_13_toplev_basic.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev_basic.log
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_toplev_basic.log
fi
echo

################################################################################
### 8. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  echo
  echo "----------------------------"
  echo "TOPLEV EXECUTION"
  echo "----------------------------"
  idle_wait
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_13_toplev_execution.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_toplev_execution.log
fi
echo

################################################################################
### 9. Toplev full profiling
################################################################################

if $run_toplev_full; then
  echo
  echo "----------------------------"
  echo "TOPLEV FULL"
  echo "----------------------------"
  idle_wait
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_13_toplev_full.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev_full.log
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_toplev_full.log
fi
echo

################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_13_maya.txt → id_13_maya.csv"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
    /local/data/results/id_13_maya.txt > /local/data/results/id_13_maya.csv
fi
echo

################################################################################
### 11. Signal completion for tmux monitoring
################################################################################
echo "All done. Results are in /local/data/results/"
echo "Experiment finished at: $(timestamp)"

################################################################################
### 12. Write completion file with runtimes
################################################################################

{
  echo "Done"
  for log in \
      done_toplev_basic.log \
      done_toplev_full.log \
      done_toplev_execution.log \
      done_maya.log \
      done_pcm.log \
      done_pcm_memory.log \
      done_pcm_power.log \
      done_pcm_pcie.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done.log

rm -f /local/data/results/done_toplev_basic.log \
      /local/data/results/done_toplev_full.log \
      /local/data/results/done_toplev_execution.log \
      /local/data/results/done_maya.log \
      /local/data/results/done_pcm.log \
      /local/data/results/done_pcm_memory.log \
      /local/data/results/done_pcm_power.log \
      /local/data/results/done_pcm_pcie.log

################################################################################
### 13. Clean up CPU shielding
################################################################################

sudo cset shield --reset || true
