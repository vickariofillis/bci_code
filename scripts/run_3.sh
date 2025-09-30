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

# Shared environment knobs
WORKLOAD_CPU=${WORKLOAD_CPU:-6}
PCM_CPU=${PCM_CPU:-5}
TOOLS_CPU=${TOOLS_CPU:-1}
OUTDIR=${OUTDIR:-/local/data/results}
LOGDIR=${LOGDIR:-/local/logs}
IDTAG=${IDTAG:-id_3}
TS_INTERVAL=${TS_INTERVAL:-0.5}
PQOS_INTERVAL_TICKS=${PQOS_INTERVAL_TICKS:-5}

RESULT_PREFIX="${OUTDIR}/${IDTAG}"

# Create unified log file
mkdir -p "${OUTDIR}" "${LOGDIR}"
RUN_LOG="${LOGDIR}/run.log"
exec > >(tee -a "${RUN_LOG}") 2>&1

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

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_debug() {
  $debug_enabled && printf '[DEBUG] %s\n' "$*"
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
  TZ=America/Toronto date '+%Y-%m-%d - %H:%M:%S'
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

prefix_lines() {
  local prefix="$1"
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    log_info "${prefix}: ${line}"
  done
}

spawn_sidecar() {
  local name="$1"
  local cmd="$2"
  local logfile="$3"
  local pid_var="$4"

  log_info "Launching ${name} at $(timestamp): ${cmd}"
  local child
  if ! child="$(sudo -n bash -lc "exec ${cmd} </dev/null >>'${logfile}' 2>&1 & echo \\$!")"; then
    log_info "${name}: failed to launch (sudo exit $?)"
    printf -v "${pid_var}" ''
    return 1
  fi

  local pid
  pid="$(echo "${child}" | tr -d '[:space:]')"
  if [[ -z ${pid} ]]; then
    log_info "${name}: failed to capture pid"
    printf -v "${pid_var}" ''
    return 1
  fi

  log_info "${name}: started pid=${pid} at $(timestamp)"
  sleep 0.1
  ps -o pid,psr,comm -p "${pid}" 2>&1 | prefix_lines "${name}"
  taskset -cp "${pid}" 2>&1 | prefix_lines "${name}"
  printf -v "${pid_var}" '%s' "${pid}"
  return 0
}

stop_gently() {
  local name="$1"
  local pid="$2"

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  for sig in INT TERM KILL; do
    if kill -0 "${pid}" 2>/dev/null; then
      log_info "Stopping ${name} pid=${pid} with SIG${sig}"
      kill -s "${sig}" "${pid}" 2>/dev/null || true
      timeout 5s bash -lc "while kill -0 ${pid} 2>/dev/null; do sleep 0.2; done" 2>/dev/null || true
    fi
  done

  if kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} still running after escalation"
  else
    log_info "${name}: pid=${pid} stopped"
  fi
}

expand_cpu_mask() {
  local mask="$1"
  local -a cpus=()
  local part start end
  local -a parts=()
  IFS=',' read -r -a parts <<<"${mask}"
  for part in "${parts[@]}"; do
    if [[ ${part} == *-* ]]; then
      IFS='-' read -r start end <<<"${part}"
      for ((cpu=start; cpu<=end; cpu++)); do
        cpus+=("${cpu}")
      done
    else
      cpus+=("${part}")
    fi
  done
  echo "${cpus[@]}"
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
  echo "PCM-POWER"
  echo "----------------------------"
  log_debug "Launching pcm-power (CSV=${RESULT_PREFIX}_pcm_power.csv, log=${RESULT_PREFIX}_pcm_power.log, profiler CPU=${PCM_CPU}, workload CPU=${WORKLOAD_CPU})"
  idle_wait

  log_info "Starting sidecars for pcm-power"

  PQOS_PID=""
  TURBOSTAT_PID=""
  PQOS_START_TS=""
  TSTAT_START_TS=""
  PQOS_STOP_TS=""
  TSTAT_STOP_TS=""
  PQOS_LOG="${LOGDIR}/pqos.log"
  TSTAT_LOG="${LOGDIR}/turbostat.log"
  ONLINE_MASK=""
  OTHERS=""
  MBM_AVAILABLE=0

  if [[ -r /sys/devices/system/cpu/online ]]; then
    ONLINE_MASK="$(</sys/devices/system/cpu/online)"
  fi

  declare -a ONLINE_CPUS=()
  if [[ -n ${ONLINE_MASK} ]]; then
    ONLINE_CPU_LIST="$(expand_cpu_mask "${ONLINE_MASK}")"
    if [[ -n ${ONLINE_CPU_LIST} ]]; then
      IFS=' ' read -r -a ONLINE_CPUS <<<"${ONLINE_CPU_LIST}"
    fi
  fi

  declare -a others_list=()
  if [[ ${#ONLINE_CPUS[@]} -gt 0 ]]; then
    for cpu in "${ONLINE_CPUS[@]}"; do
      if [[ "${cpu}" != "${WORKLOAD_CPU}" ]]; then
        others_list+=("${cpu}")
      fi
    done
  fi
  if [[ ${#others_list[@]} -gt 0 ]]; then
    OTHERS=$(IFS=,; printf '%s' "${others_list[*]}")
  fi

  if ! mountpoint -q /sys/fs/resctrl 2>/dev/null; then
    sudo -n mount -t resctrl resctrl /sys/fs/resctrl >/dev/null 2>>"${PQOS_LOG}" || true
  fi

  resctrl_features=""
  resctrl_num_rmids=""
  if [[ -r /sys/fs/resctrl/info/L3_MON/mon_features ]]; then
    resctrl_features="$(cat /sys/fs/resctrl/info/L3_MON/mon_features 2>/dev/null || true)"
  fi
  if [[ -r /sys/fs/resctrl/info/L3_MON/num_rmids ]]; then
    resctrl_num_rmids="$(cat /sys/fs/resctrl/info/L3_MON/num_rmids 2>/dev/null || true)"
  fi
  [[ ${resctrl_features} == *mbm_total_bytes* ]] && MBM_AVAILABLE=1
  {
    printf '[resctrl] L3_MON features: %s\n' "${resctrl_features:-<missing>}"
    printf '[resctrl] num_rmids: %s\n' "${resctrl_num_rmids:-<missing>}"
    printf '[resctrl] MBM_AVAILABLE=%s\n' "${MBM_AVAILABLE}"
  } >>"${PQOS_LOG}"

  export RDT_IFACE=OS

  if [[ ${MBM_AVAILABLE} -eq 1 ]]; then
    PQOS_GROUPS="mbt:[${WORKLOAD_CPU}]"
    if [[ -n ${OTHERS} ]]; then
      PQOS_GROUPS="${PQOS_GROUPS};mbt:[${OTHERS}]"
    fi
    printf -v PQOS_CMD "taskset -c %s pqos -I -u csv -o %q -i %s -m %q" \
      "${TOOLS_CPU}" "${RESULT_PREFIX}_pqos.csv" "${PQOS_INTERVAL_TICKS}" "${PQOS_GROUPS}"
    {
      printf '[pqos] cmd: %s\n' "${PQOS_CMD}"
      printf '[pqos] groups: workload=[%s] others=[%s]\n' "${WORKLOAD_CPU}" "${OTHERS:-<none>}"
    } >>"${PQOS_LOG}"
    if spawn_sidecar "pqos" "${PQOS_CMD}" "${PQOS_LOG}" PQOS_PID; then
      PQOS_START_TS=$(date +%s)
    fi
  else
    log_info "Skipping pqos sidecar (MBM not available)"
  fi

  printf -v TSTAT_CMD "taskset -c %s turbostat --interval %s --quiet --enable Time_Of_Day_Seconds --show Time_Of_Day_Seconds,CPU,Busy%%,Bzy_MHz --out %q" \
    "${TOOLS_CPU}" "${TS_INTERVAL}" "${RESULT_PREFIX}_turbostat.txt"
  printf '[turbostat] cmd: %s\n' "${TSTAT_CMD}" >>"${TSTAT_LOG}"
  if spawn_sidecar "turbostat" "${TSTAT_CMD}" "${TSTAT_LOG}" TURBOSTAT_PID; then
    TSTAT_START_TS=$(date +%s)
  fi

  echo "pcm-power started at: $(timestamp)"
  pcm_power_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_3_pcm_power.csv -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac /local/data/results/workload_pcm_power.csv \
    >>/local/data/results/id_3_pcm_power.log 2>&1
  '
  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))

  log_info "Stopping pcm-power sidecars"
  if [[ -n ${PQOS_PID} ]]; then
    stop_gently "pqos" "${PQOS_PID}"
    PQOS_STOP_TS=$(date +%s)
  fi
  if [[ -n ${TURBOSTAT_PID} ]]; then
    stop_gently "turbostat" "${TURBOSTAT_PID}"
    TSTAT_STOP_TS=$(date +%s)
  fi

  declare -a summary_lines
  summary_lines=("pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")")
  if [[ -n ${PQOS_START_TS} && -n ${PQOS_STOP_TS} ]]; then
    pqos_overlap=$((PQOS_STOP_TS - PQOS_START_TS))
    summary_lines+=("pqos runtime (overlap with pcm-power): $(secs_to_dhm "$pqos_overlap")")
  fi
  if [[ -n ${TSTAT_START_TS} && -n ${TSTAT_STOP_TS} ]]; then
    tstat_overlap=$((TSTAT_STOP_TS - TSTAT_START_TS))
    summary_lines+=("turbostat runtime (overlap with pcm-power): $(secs_to_dhm "$tstat_overlap")")
  fi
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/${IDTAG}_pcm_power.done"
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/done_pcm_power.log"
  rm -f "${OUTDIR}/${IDTAG}_pcm_power.done"

  turbostat_txt="${RESULT_PREFIX}_turbostat.txt"
  turbostat_csv="${RESULT_PREFIX}_turbostat.csv"
  if [[ -f ${turbostat_txt} ]]; then
    : > "${turbostat_csv}"
    awk -v out="${turbostat_csv}" '
      BEGIN { header_printed=0 }
      /^[[:space:]]*$/ { next }
      $2 == "-" { next }
      $1 == "Time_Of_Day_Seconds" {
        if (!header_printed) {
          gsub(/[[:space:]]+/, ",")
          print >> out
          header_printed=1
        }
        next
      }
      {
        if (!header_printed) { next }
        gsub(/[[:space:]]+/, ",")
        print >> out
      }
    ' "${turbostat_txt}"
  fi

  if [[ -n ${OUTDIR:-} && -n ${IDTAG:-} && -f ${OUTDIR}/${IDTAG}_pcm_power.csv ]]; then
    python3 <<'PY'
import csv
import datetime as _dt
import math
import os
import statistics
from pathlib import Path

DELTA_T_SEC = 0.5
EPS = 1e-9

outdir = os.environ.get("OUTDIR", "")
idtag = os.environ.get("IDTAG", "")
workload_cpu_raw = os.environ.get("WORKLOAD_CPU", "0")

try:
    workload_cpu = int(workload_cpu_raw)
except ValueError:
    workload_cpu = 0

pcm_path = Path(outdir) / f"{idtag}_pcm_power.csv"
tstat_path = Path(outdir) / f"{idtag}_turbostat.csv"
pqos_path = Path(outdir) / f"{idtag}_pqos.csv"

def _parse_datetime(date_str: str, time_str: str):
    stamp = f"{date_str.strip()} {time_str.strip()}".strip()
    stamp = stamp.replace("T", " ")
    fmts = ["%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"]
    for fmt in fmts:
        try:
            return _dt.datetime.strptime(stamp, fmt)
        except ValueError:
            continue
    try:
        return _dt.datetime.fromisoformat(stamp)
    except ValueError:
        return None

def _parse_time_only(stamp: str):
    stamp = stamp.replace("T", " ").strip()
    fmts = ["%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"]
    for fmt in fmts:
        try:
            return _dt.datetime.strptime(stamp, fmt)
        except ValueError:
            continue
    try:
        return _dt.datetime.fromisoformat(stamp)
    except ValueError:
        return None

def _clamp(val, low=0.0, high=1.0):
    return max(low, min(high, val))

def _parse_float(value: str, default: float = 0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default

if not pcm_path.exists():
    raise SystemExit(0)

with pcm_path.open(newline="") as f:
    reader = csv.reader(f)
    try:
        header_top = next(reader)
        header_bottom = next(reader)
    except StopIteration:
        raise SystemExit(0)
    data_rows = [row for row in reader if any(cell.strip() for cell in row)]

if not data_rows:
    raise SystemExit(0)

max_len = max(len(header_top), len(header_bottom), *(len(r) for r in data_rows))
header_top += [""] * (max_len - len(header_top))
header_bottom += [""] * (max_len - len(header_bottom))
for row in data_rows:
    row += [""] * (max_len - len(row))

columns = list(zip(header_top, header_bottom))

existing_actual_idxs = [idx for idx, col in enumerate(columns) if col[1].strip() in {"Actual Watts", "Actual DRAM Watts"}]
if existing_actual_idxs:
    for idx in sorted(existing_actual_idxs, reverse=True):
        if idx < len(header_top):
            del header_top[idx]
        if idx < len(header_bottom):
            del header_bottom[idx]
        for row in data_rows:
            if idx < len(row):
                del row[idx]
    columns = list(zip(header_top, header_bottom))

def _find_column(name: str, last=False):
    indices = [idx for idx, col in enumerate(columns) if col[1].strip() == name]
    if not indices:
        return None
    return indices[-1] if last else indices[0]

date_idx = _find_column("Date")
time_idx = _find_column("Time")
pkg_idx = _find_column("Watts", last=True)
dram_idx = _find_column("DRAM Watts", last=True)

if None in (date_idx, time_idx, pkg_idx, dram_idx):
    raise SystemExit(0)

pcm_entries = []
for row in data_rows:
    date = row[date_idx].strip()
    time_str = row[time_idx].strip()
    dt = _parse_datetime(date, time_str)
    timestamp = dt.timestamp() if dt else None
    pkg_power = max(_parse_float(row[pkg_idx], 0.0), 0.0)
    dram_power = max(_parse_float(row[dram_idx], 0.0), 0.0)
    pcm_entries.append({
        "timestamp": timestamp,
        "pkg": pkg_power,
        "dram": dram_power,
    })

n_pcm = len(pcm_entries)

turbostat_blocks = []
if tstat_path.exists():
    with tstat_path.open(newline="") as f:
        reader = csv.DictReader(f)
        t_rows = []
        for row in reader:
            try:
                cpu = int(row.get("CPU", ""))
                busy = float(row.get("Busy%", ""))
                mhz = float(row.get("Bzy_MHz", ""))
                ts = float(row.get("Time_Of_Day_Seconds", ""))
            except (TypeError, ValueError):
                continue
            if not math.isfinite(ts):
                continue
            t_rows.append({"cpu": cpu, "busy": busy, "mhz": mhz, "time": ts})

    unique_cpus = sorted({row["cpu"] for row in t_rows})
    n_cpus = len(unique_cpus)
    if n_cpus > 0:
        block_size = n_cpus
        for i in range(0, len(t_rows) - block_size + 1, block_size):
            block_rows = t_rows[i : i + block_size]
            cpus_in_block = {r["cpu"] for r in block_rows}
            if n_cpus == 0 or len(cpus_in_block) / max(n_cpus, 1) < 0.8:
                continue
            tau = statistics.median(r["time"] for r in block_rows)
            turbostat_blocks.append({"rows": block_rows, "tau": tau})

def _select_block(blocks, t_start):
    if not blocks or t_start is None:
        return None, False
    t_end = t_start + DELTA_T_SEC
    center = t_start + DELTA_T_SEC / 2.0
    in_window = [b for b in blocks if t_start <= b["tau"] < t_end]
    if in_window:
        chosen = min(in_window, key=lambda b: abs(b["tau"] - center))
        return chosen, True
    chosen = min(blocks, key=lambda b: abs(b["tau"] - center))
    if abs(chosen["tau"] - center) <= 0.40:
        return chosen, False
    return None, False

pkg_raw = []
pkg_in_window = 0

if not turbostat_blocks:
    pkg_raw = [0.0] * n_pcm
else:
    for entry in pcm_entries:
        block, in_window = _select_block(turbostat_blocks, entry["timestamp"])
        if block is not None:
            total_weight = 0.0
            workload_weight = 0.0
            for row in block["rows"]:
                busy = max(row["busy"], 0.0) / 100.0
                mhz = max(row["mhz"], 0.0)
                weight = busy * mhz
                if math.isfinite(weight):
                    total_weight += weight
                    if row["cpu"] == workload_cpu:
                        workload_weight = weight
            frac = _clamp(workload_weight / max(total_weight, EPS)) if total_weight > 0 else 0.0
            pkg_raw.append(frac * entry["pkg"])
            if in_window:
                pkg_in_window += 1
        else:
            pkg_raw.append(None)

pqos_samples = []
pqos_has_valid_time = False
if pqos_path.exists():
    with pqos_path.open(newline="") as f:
        reader = csv.reader(f)
        try:
            pqos_header = next(reader)
        except StopIteration:
            pqos_header = []
            reader = []

        header_map = {name.strip(): idx for idx, name in enumerate(pqos_header)}
        time_idx = header_map.get("Time")
        core_idx = header_map.get("Core")
        mbt_idx = None
        for idx, name in enumerate(pqos_header):
            name_l = name.lower()
            if "mbt" in name_l and "/s" in name_l:
                mbt_idx = idx
        if None not in (time_idx, core_idx, mbt_idx):
            sample_rows = []
            for row in reader:
                if not any(cell.strip() for cell in row):
                    continue
                row += [""] * (len(pqos_header) - len(row))
                sample_rows.append(row)

            def parse_core_set(text: str):
                text = text.strip().strip('"')
                if not text:
                    return set()
                cores = set()
                for part in text.split(','):
                    part = part.strip()
                    if not part:
                        continue
                    if '-' in part and part.replace('-', '').isdigit():
                        start_str, end_str = part.split('-', 1)
                        if start_str.isdigit() and end_str.isdigit():
                            start_i = int(start_str)
                            end_i = int(end_str)
                            if end_i >= start_i:
                                cores.update(range(start_i, end_i + 1))
                            continue
                    if part.isdigit():
                        cores.add(int(part))
                return cores

            grouped = []
            current_time = None
            for row in sample_rows:
                time_str = row[time_idx].strip()
                if current_time is None or time_str != current_time:
                    grouped.append({"time_str": time_str, "rows": []})
                    current_time = time_str
                core_set = parse_core_set(row[core_idx])
                mbt_val = _parse_float(row[mbt_idx], 0.0)
                grouped[-1]["rows"].append({"cores": core_set, "mbt": max(mbt_val, 0.0)})

            if grouped:
                time_strings = [g["time_str"] for g in grouped]
                has_subsec = any("." in ts.split()[-1] for ts in time_strings if ts)
                base_time = None
                if not has_subsec:
                    base_dt = _parse_time_only(grouped[0]["time_str"])
                    if base_dt:
                        base_time = base_dt.timestamp()
                for idx, group in enumerate(grouped):
                    if has_subsec:
                        dt = _parse_time_only(group["time_str"])
                        sigma = dt.timestamp() if dt else None
                    else:
                        sigma = base_time + idx * DELTA_T_SEC if base_time is not None else None
                    if sigma is not None:
                        pqos_has_valid_time = True
                    mbt_core = None
                    mbt_others = 0.0
                    for row in group["rows"]:
                        if row["cores"] == {workload_cpu}:
                            mbt_core = row["mbt"]
                        else:
                            mbt_others += row["mbt"]
                    if mbt_core is None:
                        mbt_core = 0.0
                    pqos_samples.append({
                        "time": sigma,
                        "mbt_core": max(mbt_core, 0.0),
                        "mbt_others": max(mbt_others, 0.0),
                    })

def _select_sample(samples, t_start):
    if not samples or t_start is None:
        return None, False
    t_end = t_start + DELTA_T_SEC
    center = t_start + DELTA_T_SEC / 2.0
    in_window = [s for s in samples if s["time"] is not None and t_start <= s["time"] < t_end]
    if in_window:
        chosen = min(in_window, key=lambda s: abs(s["time"] - center))
        return chosen, True
    valid = [s for s in samples if s["time"] is not None]
    if not valid:
        return None, False
    chosen = min(valid, key=lambda s: abs(s["time"] - center))
    if abs(chosen["time"] - center) <= 0.40:
        return chosen, False
    return None, False

dram_raw = []
dram_in_window = 0

pqos_available = pqos_has_valid_time and any(sample["time"] is not None for sample in pqos_samples)

if not pqos_available:
    dram_raw = [0.0] * n_pcm
else:
    for entry in pcm_entries:
        sample, in_window = _select_sample(pqos_samples, entry["timestamp"])
        if sample is not None:
            total = max(sample["mbt_core"], 0.0) + max(sample["mbt_others"], 0.0)
            frac = _clamp(sample["mbt_core"] / max(total, EPS)) if total > 0 else 0.0
            dram_raw.append(frac * entry["dram"])
            if in_window:
                dram_in_window += 1
        else:
            dram_raw.append(None)

def _interpolate(series):
    if not series:
        return []
    if all(value is None for value in series):
        return [0.0] * len(series)
    forward = [None] * len(series)
    backward = [None] * len(series)
    last = None
    for idx, value in enumerate(series):
        if value is not None:
            last = value
        forward[idx] = last
    last = None
    for idx in range(len(series) - 1, -1, -1):
        value = series[idx]
        if value is not None:
            last = value
        backward[idx] = last
    result = []
    for idx, value in enumerate(series):
        if value is not None:
            result.append(max(value, 0.0))
            continue
        f_val = forward[idx]
        b_val = backward[idx]
        if f_val is not None and b_val is not None:
            result.append(max(0.0, 0.5 * (f_val + b_val)))
        elif f_val is not None:
            result.append(max(0.0, f_val))
        elif b_val is not None:
            result.append(max(0.0, b_val))
        else:
            result.append(0.0)
    return result

if pkg_raw and len(pkg_raw) != n_pcm:
    pkg_raw.extend([0.0] * (n_pcm - len(pkg_raw)))
if dram_raw and len(dram_raw) != n_pcm:
    dram_raw.extend([0.0] * (n_pcm - len(dram_raw)))

pkg_series = pkg_raw if pkg_raw and all(v is not None for v in pkg_raw) else _interpolate(pkg_raw)
dram_series = dram_raw if dram_raw and all(v is not None for v in dram_raw) else _interpolate(dram_raw)

if len(pkg_series) < n_pcm:
    pkg_series += [0.0] * (n_pcm - len(pkg_series))
if len(dram_series) < n_pcm:
    dram_series += [0.0] * (n_pcm - len(dram_series))

pkg_min = min(pkg_series) if pkg_series else 0.0
dram_min = min(dram_series) if dram_series else 0.0
pkg_all_non_negative = pkg_min >= -EPS
dram_all_non_negative = dram_min >= -EPS

if not turbostat_blocks:
    print("[WARN] No turbostat blocks found; Actual Watts default to 0.")
else:
    pkg_ratio = pkg_in_window / n_pcm if n_pcm else 1.0
    if pkg_ratio < 0.95:
        print(f"[WARN] Turbostat in-window coverage below 95%: {pkg_ratio:.1%}")

if not pqos_available:
    if pqos_path.exists():
        print("[WARN] No usable pqos samples found; Actual DRAM Watts default to 0.")
else:
    dram_ratio = dram_in_window / n_pcm if n_pcm else 1.0
    if dram_ratio < 0.95:
        print(f"[WARN] PQOS in-window coverage below 95%: {dram_ratio:.1%}")

if not pkg_all_non_negative:
    print("[WARN] Negative package attribution detected; values were clipped to zero.")
if not dram_all_non_negative:
    print("[WARN] Negative DRAM attribution detected; values were clipped to zero.")

if any(val is None for val in pkg_series) or any(val is None for val in dram_series):
    print("[WARN] Interpolation failed to produce complete attribution series.")

header_top.extend(["S0", "S0"])
header_bottom.extend(["Actual Watts", "Actual DRAM Watts"])

for row, pkg_val, dram_val in zip(data_rows, pkg_series, dram_series):
    row.append(f"{max(pkg_val, 0.0):.6f}")
    row.append(f"{max(dram_val, 0.0):.6f}")

with pcm_path.open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(header_top)
    writer.writerow(header_bottom)
    writer.writerows(data_rows)
PY
  fi

  log_debug "pcm-power completed in ${pcm_power_runtime}s"
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
