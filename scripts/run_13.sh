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
workload_desc="ID-13 (Movement Intent)"

: "${TS_INTERVAL:=1}"
: "${TS_CORES:=6}"
: "${TS_OUT:=/local/data/results/id_13_turbostat.txt}"

PQOS_INTERVAL_SEC="0.5"
PQOS_TICKS="5"
PQOS_OUT="/local/data/results/id_13_pqos_core6.csv"
PQOS_CORES_WORKLOAD="6"
PQOS_CORES_ALL="$(tr -d $'\n' </sys/devices/system/cpu/online 2>/dev/null || echo '')"
PQOS_CORES_COMPL="$(python3 - <<'PY'
import os
online=os.environ.get('PQOS_CORES_ALL','').strip()
w=os.environ.get('PQOS_CORES_WORKLOAD','').strip()
def expand(spec):
    out=set()
    for part in spec.split(','):
        part=part.strip()
        if not part:
            continue
        if '-' in part:
            a,b=map(int,part.split('-'))
            out.update(range(a,b+1))
        else:
            out.add(int(part))
    return out
wset=expand(w)
blocks=[]
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
            cur.append(f"{i}-{j}" if j>i else f"{i}")
            i=j+1
        blocks.extend(cur)
    else:
        if int(part) not in wset:
            blocks.append(part)
print(','.join(blocks))
PY
)"
log_debug "turbostat defaults interval=${TS_INTERVAL}s cores=${TS_CORES} out=${TS_OUT}"
log_debug "pqos workload cores=${PQOS_CORES_WORKLOAD} complement=${PQOS_CORES_COMPL} online=${PQOS_CORES_ALL}"
echo "pqos plan: interval=${PQOS_INTERVAL_SEC}s ticks=${PQOS_TICKS}x100ms workload_core=${PQOS_CORES_WORKLOAD} complement=${PQOS_CORES_COMPL} out=${PQOS_OUT}"

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
log_debug "Placeholder completion markers generated for disabled profilers"
if ! $run_pcm; then
  log_debug "PCM disabled -> populated /local/data/results/done_pcm.log"
fi
if ! $run_pcm_memory; then
  log_debug "PCM-memory disabled -> populated /local/data/results/done_pcm_memory.log"
fi
if ! $run_pcm_power; then
  log_debug "PCM-power disabled -> populated /local/data/results/done_pcm_power.log"
fi
if ! $run_pcm_pcie; then
  log_debug "PCM-pcie disabled -> populated /local/data/results/done_pcm_pcie.log"
fi

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
### 3. Change into the home directory
################################################################################
cd ~
log_debug "Changed working directory to ${PWD}"

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
  log_debug "Launching pcm-pcie (CSV=/local/data/results/id_13_pcm_pcie.csv, log=/local/data/results/id_13_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
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
  log_debug "pcm-pcie completed in ${pcm_pcie_runtime}s"
fi

if $run_pcm; then
  echo
  echo "----------------------------"
  echo "PCM"
  echo "----------------------------"
  log_debug "Launching pcm (CSV=/local/data/results/id_13_pcm.csv, log=/local/data/results/id_13_pcm.log, profiler CPU=5, workload CPU=6)"
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
  log_debug "pcm completed in ${pcm_runtime}s"
fi

if $run_pcm_memory; then
  echo
  echo "----------------------------"
  echo "PCM-MEMORY"
  echo "----------------------------"
  log_debug "Launching pcm-memory (CSV=/local/data/results/id_13_pcm_memory.csv, log=/local/data/results/id_13_pcm_memory.log, profiler CPU=5, workload CPU=6)"
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
  log_debug "pcm-memory completed in ${pcm_mem_runtime}s"
fi

if $run_pcm_power; then
  echo
  echo "----------------------------"
  echo "PCM-POWER"
  echo "----------------------------"
  log_debug "Preparing pcm-power with csv=/local/data/results/id_13_pcm_power.csv log=/local/data/results/id_13_pcm_power.log workload_cpu=6 profiler_cpu=5"
  idle_wait
  echo "pcm-power started at: $(timestamp)"
  pcm_power_start=$(date +%s)
  log_debug "Starting turbostat: interval=${TS_INTERVAL}s cpus=${TS_CORES} output=${TS_OUT}"
  sudo bash -lc "
    taskset -c 1 turbostat --interval ${TS_INTERVAL} --cpu ${TS_CORES} --out ${TS_OUT}
  " >/dev/null 2>&1 &
  TURBOSTAT_PID=$!
  log_debug "turbostat pid=${TURBOSTAT_PID}"
  sudo pqos -I -R >/dev/null 2>&1 || true
  log_debug "Starting pqos monitor: ticks=${PQOS_TICKS} file=${PQOS_OUT}"
  sudo nohup bash -lc "
    exec taskset -c 1 pqos \
      -I \
      -u csv \
      -o \"${PQOS_OUT}\" \
      -i \"${PQOS_TICKS}\" \
      -m \"all:${PQOS_CORES_WORKLOAD};all:${PQOS_CORES_COMPL}\"
  " >/local/logs/pqos.log 2>&1 &
  PQOS_PID=$!
  log_debug "pqos pid=${PQOS_PID}"
  log_debug "Launching pcm-power workload (CSV=/local/data/results/id_13_pcm_power.csv, log=/local/data/results/id_13_pcm_power.log, profiler CPU=5, workload CPU=6)"
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
  pcm_power_status=$?
  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  echo "pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")" \
    > /local/data/results/done_pcm_power.log
  log_debug "pcm-power completed in ${pcm_power_runtime}s (status=${pcm_power_status})"
  if [ -n "${PQOS_PID:-}" ] && sudo kill -0 "$PQOS_PID" 2>/dev/null; then
    log_debug "Stopping pqos (pid=${PQOS_PID})"
    sudo kill -TERM "$PQOS_PID" 2>/dev/null || true
    for _ in {1..10}; do
      sudo kill -0 "$PQOS_PID" 2>/dev/null || break
      sleep 0.2
    done
    sudo kill -KILL "$PQOS_PID" 2>/dev/null || true
    wait "$PQOS_PID" 2>/dev/null || true
  fi
  if kill -0 "${TURBOSTAT_PID}" 2>/dev/null; then
    log_debug "Stopping turbostat (pid=${TURBOSTAT_PID})"
    sudo kill -TERM "${TURBOSTAT_PID}" 2>/dev/null || true
    for _ in {1..10}; do
      sudo kill -0 "${TURBOSTAT_PID}" 2>/dev/null || break
      sleep 0.2
    done
    sudo kill -KILL "${TURBOSTAT_PID}" 2>/dev/null || true
    wait "${TURBOSTAT_PID}" 2>/dev/null || true
  fi
  echo "turbostat (tail):"
  tail -n 5 "${TS_OUT}" || true
  export A_PCM="/local/data/results/id_13_pcm_power.csv"
  export A_PQ="${PQOS_OUT}"
  export A_TS="${TS_OUT}"
  export A_ONLINE="${PQOS_CORES_ALL}"
  export A_WCORE="${PQOS_CORES_WORKLOAD}"
  python3 - <<'PY'
import csv
import os
import tempfile

pcm_path = os.environ.get('A_PCM')
pq_path = os.environ.get('A_PQ')
ts_path = os.environ.get('A_TS')
online = os.environ.get('A_ONLINE', '')
w_spec = os.environ.get('A_WCORE', '')

def expand(spec):
    out = []
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            try:
                start, end = [int(x) for x in part.split('-', 1)]
            except ValueError:
                continue
            if start <= end:
                out.extend(range(start, end + 1))
            else:
                out.extend(range(start, end - 1, -1))
        else:
            try:
                out.append(int(part))
            except ValueError:
                continue
    return out

def clamp(value):
    return max(0.0, min(1.0, value))

def safe_float(val):
    try:
        return float(val)
    except (TypeError, ValueError):
        return None

busy_system = []
busy_workload = []
w_set = set(expand(w_spec))
if ts_path and os.path.exists(ts_path):
    with open(ts_path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) < 4:
                continue
            if parts[0] == '-' and parts[1] == '-':
                val = safe_float(parts[3])
                if val is not None:
                    busy_system.append(val)
            else:
                try:
                    cpu_id = int(parts[1])
                except ValueError:
                    continue
                if cpu_id in w_set:
                    val = safe_float(parts[3])
                    if val is not None:
                        busy_workload.append(val)

online_set = set(expand(online))
N_online = len(online_set)
f_busy = None
if busy_system and busy_workload and N_online:
    mean_sys = sum(busy_system) / len(busy_system)
    mean_work = sum(busy_workload) / len(busy_workload)
    if mean_sys > 0:
        f_busy = clamp((mean_work / 100.0) / (N_online * (mean_sys / 100.0)))

pq_totals = {
    'workload': {'mb': 0.0, 'llc': 0.0, 'miss': 0.0},
    'other': {'mb': 0.0, 'llc': 0.0, 'miss': 0.0},
}
if pq_path and os.path.exists(pq_path):
    with open(pq_path, newline='', encoding='utf-8', errors='ignore') as f:
        reader = csv.DictReader(f)
        for row in reader:
            core_label = (row.get('Core') or '').strip()
            bucket = 'workload' if core_label == w_spec else 'other'
            mbl = safe_float(row.get('MBL[MB/s]')) or 0.0
            mbr = safe_float(row.get('MBR[MB/s]')) or 0.0
            llc = safe_float(row.get('LLC[KB]')) or 0.0
            miss = safe_float(row.get('LLC Misses')) or 0.0
            pq_totals[bucket]['mb'] += mbl + mbr
            pq_totals[bucket]['llc'] += llc
            pq_totals[bucket]['miss'] += miss

total_mb = pq_totals['workload']['mb'] + pq_totals['other']['mb']
total_miss = pq_totals['workload']['miss'] + pq_totals['other']['miss']
f_mbw = (pq_totals['workload']['mb'] / total_mb) if total_mb > 0 else None
f_llcmiss = (pq_totals['workload']['miss'] / total_miss) if total_miss > 0 else None

f_busy_for_mix = f_busy if f_busy is not None else None
f_llc_for_mix = f_llcmiss if f_llcmiss is not None else None
if f_busy_for_mix is not None and f_llc_for_mix is not None:
    f_pkg = clamp(0.6 * f_busy_for_mix + 0.4 * f_llc_for_mix)
elif f_busy_for_mix is not None:
    f_pkg = clamp(f_busy_for_mix)
elif f_llc_for_mix is not None:
    f_pkg = clamp(f_llc_for_mix)
else:
    f_pkg = 0.0

if f_mbw is not None:
    f_dram = clamp(f_mbw)
elif f_llc_for_mix is not None:
    f_dram = clamp(f_llc_for_mix)
elif f_busy_for_mix is not None:
    f_dram = clamp(f_busy_for_mix)
else:
    f_dram = 0.0

print(f"[attrib] N_online={N_online}  f_busy={(f_busy or 0.0):.3f}  f_llcmiss={(0.0 if f_llcmiss is None else f_llcmiss):.3f}  f_mbw={(0.0 if f_mbw is None else f_mbw):.3f}  -> f_pkg={f_pkg:.3f}  f_dram={f_dram:.3f}")

if not pcm_path or not os.path.exists(pcm_path):
    print(f"[attrib] PCM CSV missing at {pcm_path}; skipping augmentation")
    raise SystemExit(0)

with open(pcm_path, newline='', encoding='utf-8', errors='ignore') as f:
    rows = list(csv.reader(f))

if len(rows) < 2:
    raise SystemExit(0)

header1 = rows[0]
header2 = rows[1]
data_rows = rows[2:]

pkg_idx = None
dram_idx = None
for idx, (h1, h2) in enumerate(zip(header1, header2)):
    h1s = (h1 or '').strip()
    h2s = (h2 or '').strip().lower()
    if h1s.startswith('S0') and h2s == 'watts':
        pkg_idx = idx
    if h1s.startswith('S0') and h2s == 'dram watts':
        dram_idx = idx

def compute_actual(row, idx, factor):
    if idx is None or idx >= len(row):
        return ''
    val = safe_float(row[idx])
    if val is None:
        return ''
    return f"{val * factor:.2f}"

reuse_empty = False
if data_rows and all((len(r) > 0 and (r[-1] == '' or r[-1] is None)) for r in data_rows):
    reuse_empty = True

if reuse_empty and header1:
    header1[-1] = 'Workload'
    header2[-1] = 'Actual Watts'
else:
    header1.append('Workload')
    header2.append('Actual Watts')

header1.append('Workload')
header2.append('Actual DRAM Watts')

updated_rows = []
for row in data_rows:
    pkg_actual = compute_actual(row, pkg_idx, f_pkg)
    dram_actual = compute_actual(row, dram_idx, f_dram)
    new_row = list(row)
    if reuse_empty and new_row:
        new_row[-1] = pkg_actual
    else:
        new_row.append(pkg_actual)
    new_row.append(dram_actual)
    updated_rows.append(new_row)

with tempfile.NamedTemporaryFile('w', delete=False, newline='', encoding='utf-8') as tmp:
    writer = csv.writer(tmp)
    writer.writerow(header1)
    writer.writerow(header2)
    writer.writerows(updated_rows)
    tmp_path = tmp.name

os.replace(tmp_path, pcm_path)
PY
  echo "[attrib] Finished augmenting ${A_PCM} with Actual Watts columns"
  log_debug "Appended Actual Watts columns to ${A_PCM} using pqos=${A_PQ} turbostat=${A_TS}"
  if [ "${pcm_power_status}" -ne 0 ]; then
    exit "${pcm_power_status}"
  fi
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
  log_debug "Launching Maya profiler (text=/local/data/results/id_13_maya.txt, log=/local/data/results/id_13_maya.log)"
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
  log_debug "Launching toplev basic (CSV=/local/data/results/id_13_toplev_basic.csv, log=/local/data/results/id_13_toplev_basic.log)"
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
  log_debug "Launching toplev execution (CSV=/local/data/results/id_13_toplev_execution.csv, log=/local/data/results/id_13_toplev_execution.log)"
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
  log_debug "Launching toplev full (CSV=/local/data/results/id_13_toplev_full.csv, log=/local/data/results/id_13_toplev_full.log)"
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
  log_debug "Toplev full completed in ${toplev_full_runtime}s"
fi
echo

################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_13_maya.txt → id_13_maya.csv"
  log_debug "Converting Maya output to CSV"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
    /local/data/results/id_13_maya.txt > /local/data/results/id_13_maya.csv
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
