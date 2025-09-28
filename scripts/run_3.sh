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

ORIGINAL_ARGS=("$@")

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
  "--debug|state|Enable verbose debug logging (on/off; default: off)"
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
  "--cpu-cap|watts|Set CPU package power cap in watts or 'off' to disable (default: 15)"
  "--dram-cap|watts|Set DRAM power cap in watts or 'off' to disable (default: 5)"
  "--freq|ghz|Pin CPUs to the specified frequency in GHz or 'off' to disable pinning (default: 1.2)"
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
debug_state="off"
debug_enabled=false

log_debug() {
  if $debug_enabled; then
    printf '[DEBUG] %s\n' "$*"
  fi
}
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
    --debug=*)
      debug_state="${1#--debug=}"
      ;;
    --debug)
      if [[ $# -gt 1 && ${2:-} != -* ]]; then
        debug_state="$2"
        shift
      else
        debug_state="on"
      fi
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

debug_state="${debug_state,,}"
case "$debug_state" in
  on)
    debug_enabled=true
    ;;
  off)
    debug_enabled=false
    ;;
  *)
    echo "Invalid value for --debug: '$debug_state' (expected 'on' or 'off')" >&2
    exit 1
    ;;
esac
log_debug "Debug logging enabled (state=${debug_state})"

if $debug_enabled; then
  script_real_path="$(readlink -f "$0")"
  if [[ ${#ORIGINAL_ARGS[@]} -gt 0 ]]; then
    original_args_pretty="${ORIGINAL_ARGS[*]}"
  else
    original_args_pretty="<none>"
  fi
  initial_cwd="$(pwd)"
  effective_user="$(id -un)"
  effective_group="$(id -gn)"
  effective_gid="$(id -g)"
  log_debug "Invocation context:"
  log_debug "  script path: ${script_real_path}"
  log_debug "  arguments: ${original_args_pretty}"
  log_debug "  initial working directory: ${initial_cwd}"
  log_debug "  effective user: ${effective_user} (uid=${UID})"
  log_debug "  effective group: ${effective_group} (gid=${effective_gid})"
fi

turbo_state="${turbo_state,,}"
case "$turbo_state" in
  on|off) ;;
  *)
    echo "Invalid value for --turbo: '$turbo_state' (expected 'on' or 'off')" >&2
    exit 1
    ;;
esac

pkg_cap_off=false
if [[ ${pkg_cap_w,,} == off ]]; then
  pkg_cap_off=true
  PKG_W=""
else
  if [[ ! $pkg_cap_w =~ ^[0-9]+$ ]]; then
    echo "Invalid value for --cpu-cap: '$pkg_cap_w' (expected integer watts or 'off')" >&2
    exit 1
  fi
  PKG_W="$pkg_cap_w"
fi

dram_cap_off=false
if [[ ${dram_cap_w,,} == off ]]; then
  dram_cap_off=true
  DRAM_W=""
else
  if [[ ! $dram_cap_w =~ ^[0-9]+$ ]]; then
    echo "Invalid value for --dram-cap: '$dram_cap_w' (expected integer watts or 'off')" >&2
    exit 1
  fi
  DRAM_W="$dram_cap_w"
fi

freq_pin_off=false
freq_request="${freq_request,,}"
if [[ -n $freq_request ]]; then
  if [[ $freq_request == off ]]; then
    freq_pin_off=true
    PIN_FREQ_KHZ=""
  elif [[ $freq_request =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    PIN_FREQ_KHZ="$(awk -v ghz="$freq_request" 'BEGIN{printf "%d", ghz*1000000}')"
  else
    echo "Invalid value for --freq: '$freq_request' (expected GHz as a number or 'off')" >&2
    exit 1
  fi
else
  if [[ ${pin_freq_khz_default,,} == off ]]; then
    freq_pin_off=true
    PIN_FREQ_KHZ=""
  else
    if [[ ! $pin_freq_khz_default =~ ^[0-9]+$ ]]; then
      echo "Invalid PIN_FREQ_KHZ default: '$pin_freq_khz_default'" >&2
      exit 1
    fi
    PIN_FREQ_KHZ="$pin_freq_khz_default"
  fi
fi

freq_target_ghz=""
freq_pin_display="off"
if ! $freq_pin_off; then
  freq_target_ghz="$(awk -v khz="$PIN_FREQ_KHZ" 'BEGIN{printf "%.3f", khz/1000000}')"
  freq_pin_display="${freq_target_ghz} GHz (${PIN_FREQ_KHZ} KHz)"
fi
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

if $debug_enabled; then
  log_debug "Configuration summary:"
  log_debug "  Turbo Boost request: ${turbo_state}"
  log_debug "  CPU package cap: ${pkg_cap_w}"
  log_debug "  DRAM cap: ${dram_cap_w}"
  log_debug "  Frequency request: ${freq_request:-default (${pin_freq_khz_default} KHz)}"
  log_debug "  Tools enabled -> toplev_basic=${run_toplev_basic}, toplev_full=${run_toplev_full}, toplev_execution=${run_toplev_execution}, maya=${run_maya}, pcm=${run_pcm}, pcm_memory=${run_pcm_memory}, pcm_power=${run_pcm_power}, pcm_pcie=${run_pcm_pcie}"
fi

# Describe this workload for logging
workload_desc="ID-3 (Compression)"

# --- Turbostat sampling config (seconds) ---
: "${TS_INTERVAL:=1}"                # sample every N seconds
: "${TS_CORES:=6}"                   # core(s) where workload runs
: "${TS_OUT:=/local/data/results/id_3_turbostat.txt}"

# --- PQoS (OS/resctrl) monitoring config ---
PQOS_INTERVAL_SEC="0.5"                  # match pcm-power’s 0.5s cadence
PQOS_TICKS="5"                           # 0.5s / 0.1s (pqos -i uses 100ms ticks)
PQOS_OUT="/local/data/results/id_3_pqos_core6.csv"
PQOS_LOG="/local/logs/$(basename "$0" .sh)_pqos.log"
PQOS_CORES_WORKLOAD="6"
PQOS_CORES_ALL="$(tr -d $'\n' </sys/devices/system/cpu/online)"
PQOS_CORES_COMPL="$(python3 - <<'PY'
import os
online=os.environ.get("PQOS_CORES_ALL","" ).strip()
w=os.environ.get("PQOS_CORES_WORKLOAD","6").strip()
wset=set()
for part in w.split(','):
    part=part.strip()
    if not part:
        continue
    if '-' in part:
        a,b=map(int,part.split('-'))
        wset.update(range(a,b+1))
    else:
        wset.add(int(part))
segments=[]
for part in online.split(','):
    part=part.strip()
    if not part:
        continue
    if '-' in part:
        a,b=map(int,part.split('-'))
        cur=[]
        i=a
        while i<=b:
            if i in wset:
                i+=1
                continue
            j=i
            while j+1<=b and (j+1) not in wset:
                j+=1
            cur.append((i,j))
            i=j+1
        for s,e in cur:
            segments.append(f"{s}-{e}" if s!=e else f"{s}")
    else:
        x=int(part)
        if x not in wset:
            segments.append(part)
print(','.join(segments))
PY
)"
if [[ -z ${PQOS_CORES_COMPL// } ]]; then
  PQOS_CORES_COMPL="$PQOS_CORES_WORKLOAD"
fi

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
log_debug "Countdown before launch: 10 seconds to cancel"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

# Record experiment start time
echo "Experiment started at: $(TZ=America/Toronto date '+%Y-%m-%d - %H:%M')"
log_debug "Experiment start timestamp captured (timezone America/Toronto)"

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

  log_debug "Idle wait parameters: min=${MIN_SLEEP}s target=${TEMP_TARGET_MC}mc path=${TEMP_PATH}"
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
  log_debug "Idle wait complete after ${waited}s (${message})"
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
log_debug "Prepared /local/data/results (owner ${RUN_USER}:${RUN_GROUP})"

# Create placeholder logs for disabled tools so that done.log always lists
# every profiling stage.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_pcm_pcie.log
log_debug "Placeholder completion markers generated for disabled profilers"

################################################################################
### 2. Configure and verify power settings
################################################################################
# Load msr module to allow power management commands
sudo modprobe msr || true

# Summarize requested power configuration
echo "Requested Turbo Boost: $turbo_state"
if $pkg_cap_off; then
  echo "Requested CPU package power cap: off"
else
  echo "Requested CPU package power cap: ${PKG_W} W"
fi
if $dram_cap_off; then
  echo "Requested DRAM power cap: off"
else
  echo "Requested DRAM power cap: ${DRAM_W} W"
fi
echo "Requested frequency pin: ${freq_pin_display}"
echo "pqos plan: interval=${PQOS_INTERVAL_SEC}s ticks=${PQOS_TICKS}x100ms workload_core=${PQOS_CORES_WORKLOAD} complement=${PQOS_CORES_COMPL} out=${PQOS_OUT}"
log_debug "PQoS configuration -> workload=${PQOS_CORES_WORKLOAD}, complement=${PQOS_CORES_COMPL}, interval=${PQOS_INTERVAL_SEC}s, ticks=${PQOS_TICKS}, out=${PQOS_OUT}, log=${PQOS_LOG}"
log_debug "Power configuration requests -> turbo=${turbo_state}, pkg=${pkg_cap_w}, dram=${dram_cap_w}, freq_display=${freq_pin_display}"

# Configure turbo state (ignore failures)
if [[ $turbo_state == "off" ]]; then
  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
  echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost      >/dev/null 2>&1 || true
else
  echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
  echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost      >/dev/null 2>&1 || true
fi
log_debug "Turbo boost interfaces updated for state=${turbo_state}"

# RAPL package & DRAM caps (safe defaults; no-op if absent)
: "${RAPL_WIN_US:=10000}"   # 10ms
DOM=/sys/class/powercap/intel-rapl:0
if ! $pkg_cap_off; then
  [ -e "$DOM/constraint_0_power_limit_uw" ] && \
    echo $((PKG_W*1000000)) | sudo tee "$DOM/constraint_0_power_limit_uw" >/dev/null || true
  [ -e "$DOM/constraint_0_time_window_us" ] && \
    echo "$RAPL_WIN_US"     | sudo tee "$DOM/constraint_0_time_window_us" >/dev/null || true
  log_debug "Package RAPL limit applied (${PKG_W} W, window ${RAPL_WIN_US} us)"
else
  echo "Skipping CPU package power cap configuration (off)"
  log_debug "Package RAPL limit skipped"
fi
DRAM=/sys/class/powercap/intel-rapl:0:0
if ! $dram_cap_off; then
  [ -e "$DRAM/constraint_0_power_limit_uw" ] && \
    echo $((DRAM_W*1000000)) | sudo tee "$DRAM/constraint_0_power_limit_uw" >/dev/null || true
  log_debug "DRAM RAPL limit applied (${DRAM_W} W)"
else
  echo "Skipping DRAM power cap configuration (off)"
  log_debug "DRAM RAPL limit skipped"
fi

# Determine CPU list from this script’s existing taskset/cset lines
SCRIPT_FILE="$(readlink -f "$0")"
CPU_LIST_RAW="$(
  { grep -Eo 'taskset -c[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $3}';
    grep -Eo 'cset shield --cpu[[:space:]]+[0-9,]+' "$SCRIPT_FILE" | awk '{print $4}'; } 2>/dev/null
)"
CPU_LIST="$(echo "$CPU_LIST_RAW" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | uniq | paste -sd, -)"
[ -z "$CPU_LIST" ] && CPU_LIST="0"   # fallback, should not happen

# Mandatory frequency pinning on the CPUs already used by this script
if ! $freq_pin_off; then
  log_debug "Applying frequency pinning to CPUs ${CPU_LIST} at ${PIN_FREQ_KHZ} KHz"
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
else
  echo "Skipping frequency pinning (off)"
  log_debug "Frequency pinning skipped"
fi

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
log_debug "CPUs considered for telemetry reporting: ${CPU_LIST}"

echo
echo "----------------------------"
echo "Power and frequency settings"
echo "----------------------------"
log_debug "Summarizing power/frequency state from sysfs"

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
### 3. Change into the ID-3 code directory
################################################################################
cd /local/bci_code/id_3/code
log_debug "Changed working directory to /local/bci_code/id_3/code"

source /local/tools/compression_env/bin/activate

################################################################################
### 4. PCM profiling
################################################################################

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  sudo modprobe msr
  log_debug "Ensured msr kernel module is loaded for PCM"
fi

if $run_pcm_pcie; then
  echo
  echo "----------------------------"
  echo "PCM-PCIE"
  echo "----------------------------"
  log_debug "Launching pcm-pcie (CSV=/local/data/results/id_3_pcm_pcie.csv, log=/local/data/results/id_3_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_3_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_pcm_pcie.csv \
    >>/local/data/results/id_3_pcm_pcie.log 2>&1
  '
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_pcm_pcie.log
  log_debug "pcm-pcie completed in ${pcm_pcie_runtime}s"
fi

if $run_pcm; then
  echo
  echo "----------------------------"
  echo "PCM"
  echo "----------------------------"
  log_debug "Launching pcm (CSV=/local/data/results/id_3_pcm.csv, log=/local/data/results/id_3_pcm.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_3_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_pcm.csv \
    >>/local/data/results/id_3_pcm.log 2>&1
  '
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_pcm.log
  log_debug "pcm completed in ${pcm_runtime}s"
fi

if $run_pcm_memory; then
  echo
  echo "----------------------------"
  echo "PCM-MEMORY"
  echo "----------------------------"
  log_debug "Launching pcm-memory (CSV=/local/data/results/id_3_pcm_memory.csv, log=/local/data/results/id_3_pcm_memory.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_3_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_pcm_memory.csv \
    >>/local/data/results/id_3_pcm_memory.log 2>&1
  '
  pcm_mem_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_mem_runtime")" \
    > /local/data/results/done_pcm_memory.log
  log_debug "pcm-memory completed in ${pcm_mem_runtime}s"
fi

if $run_pcm_power; then
  echo
  echo "----------------------------"
  echo "PCM-POWER (with turbostat + pqos)"
  echo "----------------------------"
  log_debug "Launching pcm-power with instrumentation (CSV=/local/data/results/id_3_pcm_power.csv, pqos_out=${PQOS_OUT}, ts_out=${TS_OUT})"
  idle_wait
  echo "pcm-power started at: $(timestamp)"
  log_debug "Starting turbostat+pqos instrumentation"
  pcm_power_start=$(date +%s)

  sudo bash -lc "
    taskset -c 1 turbostat --interval ${TS_INTERVAL} --cpu ${TS_CORES} --out ${TS_OUT}
  " >/dev/null 2>&1 &
  TURBOSTAT_PID=$!
  echo "turbostat started (pinned to CPU1): PID ${TURBOSTAT_PID}"
  log_debug "turbostat launched (pid=${TURBOSTAT_PID})"

  sudo pqos -I -R >/dev/null 2>&1 || true
  sudo nohup bash -lc "
    exec taskset -c 1 pqos \
      -I \
      -u csv \
      -o \"$PQOS_OUT\" \
      -i \"$PQOS_TICKS\" \
      -m \"all:${PQOS_CORES_WORKLOAD};all:${PQOS_CORES_COMPL}\"
  " >"${PQOS_LOG}" 2>&1 &
  PQOS_PID=$!
  echo "pqos started (OS/resctrl mode, pinned to CPU1): pid=${PQOS_PID}, groups=[${PQOS_CORES_WORKLOAD}] vs [${PQOS_CORES_COMPL}], i=${PQOS_TICKS}x100ms, out=${PQOS_OUT}"
  log_debug "pqos launched (pid=${PQOS_PID})"

  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_3_pcm_power.csv -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_pcm_power.csv \
    >>/local/data/results/id_3_pcm_power.log 2>&1
  '
  pcm_power_status=$?

  if [ -n "${PQOS_PID:-}" ] && sudo kill -0 "$PQOS_PID" 2>/dev/null; then
    sudo kill -TERM "$PQOS_PID" 2>/dev/null || true
    for _ in {1..10}; do sudo kill -0 "$PQOS_PID" 2>/dev/null || break; sleep 0.2; done
    sudo kill -KILL "$PQOS_PID" 2>/dev/null || true
    wait "$PQOS_PID" 2>/dev/null || true
  fi
  echo "pqos stopped"
  log_debug "pqos instrumentation stopped"

  if kill -0 "${TURBOSTAT_PID}" 2>/dev/null; then
    sudo kill -TERM "${TURBOSTAT_PID}" 2>/dev/null || true
    for _ in {1..10}; do if ! sudo kill -0 "${TURBOSTAT_PID}" 2>/dev/null; then break; fi; sleep 0.2; done
    sudo kill -KILL "${TURBOSTAT_PID}" 2>/dev/null || true
    wait "${TURBOSTAT_PID}" 2>/dev/null || true
    echo "turbostat stopped"
  fi
  log_debug "turbostat instrumentation stopped"

  echo "turbostat (tail):"
  tail -n 5 "${TS_OUT}" || true

  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  echo "pcm-power runtime: $(secs_to_dhm \"$pcm_power_runtime\")" \
    > /local/data/results/done_pcm_power.log
  log_debug "pcm-power completed in ${pcm_power_runtime}s"

  if (( pcm_power_status != 0 )); then
    log_debug "pcm-power exited with status ${pcm_power_status}"
    exit "$pcm_power_status"
  fi

  export A_PCM="/local/data/results/id_3_pcm_power.csv"
  export A_PQ="$PQOS_OUT"
  export A_TS="$TS_OUT"
  export A_ONLINE="$PQOS_CORES_ALL"
  export A_WCORE="$PQOS_CORES_WORKLOAD"
  log_debug "Invoking power attribution helper (pcm=${A_PCM}, pqos=${A_PQ}, turbostat=${A_TS})"

  python3 - <<'PY'
import os, csv, re, statistics

pcm_path = os.environ['A_PCM']
pq_path  = os.environ['A_PQ']
ts_path  = os.environ['A_TS']
online   = os.environ.get('A_ONLINE', '')
wcore    = os.environ.get('A_WCORE', '6').strip()

def count_online(cpu_str):
    total = 0
    for part in cpu_str.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            start_cpu, end_cpu = part.split('-')
            total += int(end_cpu) - int(start_cpu) + 1
        else:
            total += 1
    return total

sys_busy = []
core_busy = []
try:
    with open(ts_path, 'r', errors='ignore') as fh:
        for raw in fh:
            cols = re.split(r'\s+', raw.strip())
            if len(cols) < 4:
                continue
            if cols[0] == '-' and cols[1] == '-':
                try:
                    sys_busy.append(float(cols[3]))
                except ValueError:
                    pass
            elif len(cols) > 2 and cols[1] == wcore:
                try:
                    core_busy.append(float(cols[3]))
                except ValueError:
                    pass
except FileNotFoundError:
    pass

online_count = count_online(online) if online else None
f_busy = None
if sys_busy and core_busy and online_count and online_count > 0:
    sys_mean = statistics.mean(sys_busy)
    if sys_mean > 0:
        f_busy = (statistics.mean(core_busy) / 100.0) / (online_count * (sys_mean / 100.0))

sum_mbl_w = sum_mbr_w = sum_llc_w = sum_llcmiss_w = 0.0
sum_mbl_o = sum_mbr_o = sum_llc_o = sum_llcmiss_o = 0.0

def fnum(val):
    try:
        return float(val)
    except (TypeError, ValueError):
        return 0.0

try:
    with open(pq_path, 'r', newline='', errors='ignore') as fh:
        rdr = csv.DictReader(fh)
        for row in rdr:
            core = str(row.get('Core', '')).strip()
            mbl = fnum(row.get('MBL[MB/s]', 0.0))
            mbr = fnum(row.get('MBR[MB/s]', 0.0))
            llc = fnum(row.get('LLC[KB]', 0.0))
            mis = fnum(row.get('LLC Misses', 0.0))
            if core == wcore:
                sum_mbl_w += mbl
                sum_mbr_w += mbr
                sum_llc_w += llc
                sum_llcmiss_w += mis
            else:
                sum_mbl_o += mbl
                sum_mbr_o += mbr
                sum_llc_o += llc
                sum_llcmiss_o += mis
except FileNotFoundError:
    pass

def safe_frac(num, den):
    return (num / den) if den and den > 0 else None

f_mbw = safe_frac(sum_mbl_w + sum_mbr_w, (sum_mbl_w + sum_mbr_w + sum_mbl_o + sum_mbr_o))
f_llcmiss = safe_frac(sum_llcmiss_w, (sum_llcmiss_w + sum_llcmiss_o))

if f_mbw is not None and f_mbw > 0:
    f_dram = f_mbw
elif f_llcmiss is not None and f_llcmiss > 0:
    f_dram = f_llcmiss
elif f_busy is not None:
    f_dram = max(0.0, min(1.0, f_busy))
else:
    f_dram = 0.0

if f_llcmiss is None and f_busy is None:
    f_pkg = 0.0
elif f_llcmiss is None:
    f_pkg = f_busy
elif f_busy is None:
    f_pkg = f_llcmiss
else:
    f_pkg = 0.6 * f_busy + 0.4 * f_llcmiss
f_pkg = max(0.0, min(1.0, f_pkg if f_pkg is not None else 0.0))

print(
    f"[attrib] N_online={online_count} f_busy={(0.0 if f_busy is None else f_busy):.3f} "
    f"f_llcmiss={(0.0 if f_llcmiss is None else f_llcmiss):.3f} f_mbw={(0.0 if f_mbw is None else f_mbw):.3f} "
    f"-> f_pkg={f_pkg:.3f} f_dram={f_dram:.3f}"
)

with open(pcm_path, 'r', newline='', errors='ignore') as fin:
    reader = csv.reader(fin)
    header_top = next(reader, [])
    header_bottom = next(reader, [])
    rows = list(reader)

placeholder_idx = None
def find_idx(label, top, bottom):
    candidates = [i for i, (grp, lab) in enumerate(zip(top, bottom))
                  if lab.strip() == label and grp.strip().startswith('S0')]
    return candidates[-1] if candidates else None

idx_pkg = find_idx('Watts', header_top, header_bottom)
idx_dram = find_idx('DRAM Watts', header_top, header_bottom)

if idx_pkg is None or idx_dram is None:
    print('[attrib] WARNING: could not find PCM power columns, left file unchanged')
    with open(pcm_path, 'w', newline='') as fout:
        writer = csv.writer(fout)
        writer.writerow(header_top)
        writer.writerow(header_bottom)
        writer.writerows(rows)
else:
    if header_top and header_bottom and len(header_top) == len(header_bottom):
        if header_top[-1].strip() == '' and header_bottom[-1].strip() == '':
            placeholder_idx = len(header_bottom) - 1

    reuse_existing = placeholder_idx is not None
    if reuse_existing:
        header_top_out = list(header_top)
        header_bottom_out = list(header_bottom)
        header_top_out[placeholder_idx] = 'S0'
        header_bottom_out[placeholder_idx] = 'Actual Watts'
        header_top_out.append('S0')
        header_bottom_out.append('Actual DRAM Watts')
    else:
        header_top_out = list(header_top) + ['S0', 'S0']
        header_bottom_out = list(header_bottom) + ['Actual Watts', 'Actual DRAM Watts']
        placeholder_idx = len(header_bottom_out) - 2

    dram_index = len(header_bottom_out) - 1
    print(f"[attrib] placeholder_reused={reuse_existing} actual_idx={placeholder_idx} dram_idx={dram_index}")

    tmp_path = pcm_path + '.tmp'
    with open(tmp_path, 'w', newline='') as fout:
        writer = csv.writer(fout)
        writer.writerow(header_top_out)
        writer.writerow(header_bottom_out)

        for row in rows:
            row_out = list(row)
            while len(row_out) <= placeholder_idx:
                row_out.append('')
            while len(row_out) <= dram_index:
                row_out.append('')

            try:
                pkg_w = float(row[idx_pkg])
            except (TypeError, ValueError):
                pkg_w = None
            try:
                dram_w = float(row[idx_dram])
            except (TypeError, ValueError):
                dram_w = None

            aw = f"{pkg_w * f_pkg:.2f}" if pkg_w is not None else ''
            adw = f"{dram_w * f_dram:.2f}" if dram_w is not None else ''

            row_out[placeholder_idx] = aw
            row_out[dram_index] = adw

            writer.writerow(row_out)

import os as _os
_os.replace(tmp_path, pcm_path)
PY
  log_debug "Power attribution helper finished (pcm=${A_PCM})"

  echo "[attrib] Finished augmenting /local/data/results/id_3_pcm_power.csv with Actual Watts columns"
fi

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  echo "PCM profiling finished at: $(timestamp)"
  log_debug "PCM toolchain complete"
fi

################################################################################
### 5. Shield Core 8 (CPU 5) and Core 9 (CPU 6)
###    (reserve them for our measurement + workload)
################################################################################
echo
echo "----------------------------"
echo "CPU shielding"
echo "----------------------------"
log_debug "Applying cset shielding to CPUs 5 and 6"
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
  log_debug "Launching Maya profiler (text=/local/data/results/id_3_maya.txt, log=/local/data/results/id_3_maya.log)"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    set -euo pipefail
    source /local/tools/compression_env/bin/activate

    # Start Maya on CPU 5 in background; capture PID immediately
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_3_maya.txt 2>&1 &
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
    taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_maya.csv \
      >> /local/data/results/id_3_maya.log 2>&1 || true

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
  log_debug "Maya completed in ${maya_runtime}s"
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
  log_debug "Launching toplev basic (CSV=/local/data/results/id_3_toplev_basic.csv, log=/local/data/results/id_3_toplev_basic.log)"
  idle_wait
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o /local/data/results/id_3_toplev_basic.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_toplev_basic.csv
  ' &> /local/data/results/id_3_toplev_basic.log
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_toplev_basic.log
  log_debug "Toplev basic completed in ${toplev_basic_runtime}s"
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
  log_debug "Launching toplev execution (CSV=/local/data/results/id_3_toplev_execution.csv, log=/local/data/results/id_3_toplev_execution.log)"
  idle_wait
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_3_toplev_execution.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_toplev_execution.csv
  ' &>  /local/data/results/id_3_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_toplev_execution.log
  log_debug "Toplev execution completed in ${toplev_execution_runtime}s"
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
  log_debug "Launching toplev full (CSV=/local/data/results/id_3_toplev_full.csv, log=/local/data/results/id_3_toplev_full.log)"
  idle_wait
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)

  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_3_toplev_full.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_toplev_full.csv
  ' &>  /local/data/results/id_3_toplev_full.log
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_toplev_full.log
  log_debug "Toplev full completed in ${toplev_full_runtime}s"
fi
echo

################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_3_maya.txt → id_3_maya.csv"
  log_debug "Converting Maya output to CSV"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }' \
    /local/data/results/id_3_maya.txt \
    > /local/data/results/id_3_maya.csv
  log_debug "Maya CSV generated"
fi
echo

################################################################################
### 11. Signal completion for tmux monitoring
################################################################################
echo "All done. Results are in /local/data/results/"
echo "Experiment finished at: $(timestamp)"
log_debug "Experiment complete; collating runtimes"

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
log_debug "Wrote /local/data/results/done.log"

rm -f /local/data/results/done_toplev_basic.log \
      /local/data/results/done_toplev_full.log \
      /local/data/results/done_toplev_execution.log \
      /local/data/results/done_maya.log \
      /local/data/results/done_pcm.log \
      /local/data/results/done_pcm_memory.log \
      /local/data/results/done_pcm_power.log \
      /local/data/results/done_pcm_pcie.log
log_debug "Removed intermediate done_* logs"

################################################################################
### 13. Clean up CPU shielding
################################################################################

sudo cset shield --reset || true
log_debug "cset shield reset issued"
