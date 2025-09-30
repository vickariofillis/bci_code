#!/usr/bin/env bash
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
IDTAG=${IDTAG:-id_1}
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
workload_desc="ID-1 (Seizure Detection – Laelaps)"

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

# Prepare placeholder logs for any disabled tools so that log consolidation
# works regardless of the selected combination.
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
### 3. Change into the proper directory
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
  log_debug "Launching pcm-pcie (CSV=/local/data/results/id_1_pcm_pcie.csv, log=/local/data/results/id_1_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_1_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_pcie.log 2>&1
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
  log_debug "Launching pcm (CSV=/local/data/results/id_1_pcm.csv, log=/local/data/results/id_1_pcm.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_1_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm.log 2>&1
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
  log_debug "Launching pcm-memory (CSV=/local/data/results/id_1_pcm_memory.csv, log=/local/data/results/id_1_pcm_memory.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_1_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_memory.log 2>&1
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
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_1_pcm_power.csv -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_power.log 2>&1
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

  python3 <<'PYTHON'
import csv
import math
import os
import statistics
import sys
from datetime import datetime

DELTA_T_SEC = 0.5
EPS = 1e-9

def parse_datetime(date_str: str, time_str: str) -> datetime:
    combined = f"{date_str.strip()} {time_str.strip()}"
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(combined, fmt)
        except ValueError:
            continue
    raise ValueError(f"Unrecognised timestamp: {combined}")

def parse_datetime_string(value: str) -> datetime:
    parts = value.strip().split()
    if len(parts) < 2:
        raise ValueError(f"Unrecognised timestamp: {value}")
    date_part = parts[0]
    time_part = " ".join(parts[1:])
    return parse_datetime(date_part, time_part)

def has_fractional_seconds(value: str) -> bool:
    parts = value.strip().split()
    if len(parts) < 2:
        return False
    return "." in parts[-1]

def safe_float(value: str):
    value = value.strip()
    if not value:
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    if math.isnan(parsed) or math.isinf(parsed):
        return None
    return parsed

def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))

def expand_core_set(token: str):
    token = token.strip()
    if not token:
        return []
    if "-" in token:
        start_str, end_str = token.split("-", 1)
        try:
            start = int(start_str)
            end = int(end_str)
        except ValueError:
            return []
        if end < start:
            start, end = end, start
        return list(range(start, end + 1))
    try:
        return [int(token)]
    except ValueError:
        return []

def parse_core_field(field: str):
    field = field.strip().strip('"').strip("'")
    if not field:
        return set()
    cores = set()
    for part in field.split(","):
        for expanded in expand_core_set(part):
            cores.add(expanded)
    return cores

def interpolate_series(raw_values):
    n = len(raw_values)
    if n == 0:
        return []
    if all(v is None for v in raw_values):
        return [0.0] * n
    forward = [None] * n
    last = None
    for i, value in enumerate(raw_values):
        if value is not None:
            last = value
        forward[i] = last
    backward = [None] * n
    last = None
    for idx in range(n - 1, -1, -1):
        value = raw_values[idx]
        if value is not None:
            last = value
        backward[idx] = last
    filled = []
    for i, value in enumerate(raw_values):
        if value is not None:
            filled.append(max(value, 0.0))
            continue
        prev_val = forward[i]
        next_val = backward[i]
        if prev_val is not None and next_val is not None:
            interp = 0.5 * (prev_val + next_val)
        elif prev_val is not None:
            interp = prev_val
        elif next_val is not None:
            interp = next_val
        else:
            interp = 0.0
        filled.append(max(interp, 0.0))
    return filled

outdir = os.environ.get("OUTDIR")
idtag = os.environ.get("IDTAG")
workload_cpu = int(os.environ.get("WORKLOAD_CPU", "0"))
if not outdir or not idtag:
    sys.exit(0)

pcm_path = os.path.join(outdir, f"{idtag}_pcm_power.csv")
tstat_path = os.path.join(outdir, f"{idtag}_turbostat.csv")
pqos_path = os.path.join(outdir, f"{idtag}_pqos.csv")
tstat_file_present = os.path.exists(tstat_path)
pqos_file_present = os.path.exists(pqos_path)

if not os.path.exists(pcm_path):
    print(f"[pcm-power] Missing pcm-power CSV at {pcm_path}", file=sys.stderr)
    sys.exit(0)

with open(pcm_path, newline="") as f:
    reader = csv.reader(f)
    rows = [list(row) for row in reader if row]

if len(rows) < 3:
    print(f"[pcm-power] Not enough data rows in {pcm_path}", file=sys.stderr)
    sys.exit(0)

header_top = rows[0]
header_bottom = rows[1]
data_rows = rows[2:]

def find_last_index(seq, target):
    for idx in range(len(seq) - 1, -1, -1):
        if seq[idx].strip() == target:
            return idx
    raise ValueError(target)

try:
    idx_date = next(i for i, name in enumerate(header_bottom) if name.strip() == "Date")
    idx_time = next(i for i, name in enumerate(header_bottom) if name.strip() == "Time")
    idx_watts = find_last_index(header_bottom, "Watts")
    idx_dram_watts = find_last_index(header_bottom, "DRAM Watts")
except StopIteration as exc:
    print(f"[pcm-power] Missing required column: {exc}", file=sys.stderr)
    sys.exit(0)
except ValueError as exc:
    print(f"[pcm-power] Missing required column: {exc}", file=sys.stderr)
    sys.exit(0)

timestamps = []
pkg_power = []
dram_power = []
for row in data_rows:
    if len(row) < len(header_bottom):
        row.extend([""] * (len(header_bottom) - len(row)))
    date_str = row[idx_date].strip()
    time_str = row[idx_time].strip()
    try:
        ts = parse_datetime(date_str, time_str).timestamp()
    except ValueError:
        print(f"[pcm-power] Failed to parse timestamp '{date_str} {time_str}'", file=sys.stderr)
        sys.exit(0)
    timestamps.append(ts)
    pkg_val = safe_float(row[idx_watts])
    dram_val = safe_float(row[idx_dram_watts])
    pkg_power.append(max(pkg_val if pkg_val is not None else 0.0, 0.0))
    dram_power.append(max(dram_val if dram_val is not None else 0.0, 0.0))

total_rows = len(timestamps)

tstat_rows = []
if tstat_file_present:
    with open(tstat_path, newline="") as f:
        reader = csv.DictReader(f)
        for entry in reader:
            try:
                time_val = safe_float(entry.get("Time_Of_Day_Seconds", ""))
                cpu_val = entry.get("CPU", "").strip()
                busy_val = safe_float(entry.get("Busy%", ""))
                bzy_val = safe_float(entry.get("Bzy_MHz", ""))
            except AttributeError:
                continue
            if None in (time_val, busy_val, bzy_val):
                continue
            try:
                cpu_int = int(cpu_val)
            except ValueError:
                continue
            tstat_rows.append({
                "time": time_val,
                "cpu": cpu_int,
                "busy": max(busy_val, 0.0),
                "bzy": max(bzy_val, 0.0),
            })

unique_cpus = sorted({row["cpu"] for row in tstat_rows})
num_cpus = len(unique_cpus)
tstat_blocks = []
if num_cpus > 0:
    for offset in range(0, len(tstat_rows) - num_cpus + 1, num_cpus):
        block = tstat_rows[offset:offset + num_cpus]
        covered = {row["cpu"] for row in block}
        if len(covered) / max(num_cpus, 1) < 0.8:
            continue
        tau = statistics.median(row["time"] for row in block)
        tstat_blocks.append({
            "tau": tau,
            "rows": block,
        })

pqos_samples = []
if pqos_file_present:
    with open(pqos_path, newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            header = []
        header = [col.strip() for col in header]
        def find_col(name):
            for idx, col in enumerate(header):
                if col.lower() == name:
                    return idx
            raise ValueError(name)
        try:
            time_idx = find_col("time")
            core_idx = find_col("core")
        except ValueError:
            time_idx = core_idx = None
        mbt_idx = None
        for idx, col in enumerate(header):
            col_lower = col.lower()
            if "mbt" in col_lower and "/s" in col_lower:
                mbt_idx = idx
        if time_idx is not None and core_idx is not None and mbt_idx is not None:
            current_time = None
            current_rows = []
            ordered_times = []
            grouped_rows = []
            for row in reader:
                if not row:
                    continue
                time_str = row[time_idx].strip()
                if not time_str:
                    continue
                if current_time is None:
                    current_time = time_str
                if time_str != current_time:
                    ordered_times.append(current_time)
                    grouped_rows.append(current_rows)
                    current_rows = []
                    current_time = time_str
                current_rows.append(row)
            if current_rows:
                ordered_times.append(current_time)
                grouped_rows.append(current_rows)

            processed_samples = []
            has_subseconds = any(has_fractional_seconds(t) for t in ordered_times)
            base_epoch = None
            for index, (time_str, rows_for_time) in enumerate(zip(ordered_times, grouped_rows)):
                mbt_core = 0.0
                mbt_other = 0.0
                for row in rows_for_time:
                    mbt_val = safe_float(row[mbt_idx]) or 0.0
                    cores = parse_core_field(row[core_idx])
                    if cores == {workload_cpu}:
                        mbt_core += max(mbt_val, 0.0)
                    else:
                        mbt_other += max(mbt_val, 0.0)
                if has_subseconds:
                    sample_epoch = parse_datetime_string(time_str).timestamp()
                else:
                    if base_epoch is None:
                        base_epoch = parse_datetime_string(time_str).timestamp()
                    sample_epoch = base_epoch + index * DELTA_T_SEC
                processed_samples.append({
                    "sigma": sample_epoch,
                    "core": max(mbt_core, 0.0),
                    "other": max(mbt_other, 0.0),
                })
            pqos_samples = processed_samples
        else:
            pqos_samples = []

pkg_core_raw = [None] * total_rows
dram_core_raw = [None] * total_rows
tstat_in_window = 0
pqos_in_window = 0

for idx, (start_ts, p_pkg, p_dram) in enumerate(zip(timestamps, pkg_power, dram_power)):
    window_end = start_ts + DELTA_T_SEC
    window_center = start_ts + DELTA_T_SEC / 2.0

    selected_block = None
    in_window = False
    for block in tstat_blocks:
        if start_ts <= block["tau"] < window_end:
            selected_block = block
            in_window = True
            break
    if selected_block is None and tstat_blocks:
        selected_block = min(tstat_blocks, key=lambda b: abs(b["tau"] - window_center))
        if abs(selected_block["tau"] - window_center) > 0.40:
            selected_block = None
    if selected_block is not None:
        if in_window:
            tstat_in_window += 1
        total_weight = 0.0
        core_weight = 0.0
        for row in selected_block["rows"]:
            weight = (row["busy"] / 100.0) * row["bzy"]
            if weight < 0.0:
                weight = 0.0
            total_weight += weight
            if row["cpu"] == workload_cpu:
                core_weight = weight
        fraction = clamp(core_weight / max(total_weight, EPS) if total_weight > 0.0 else 0.0)
        pkg_core_raw[idx] = fraction * max(p_pkg, 0.0)
    if selected_block is None and not tstat_blocks:
        pkg_core_raw[idx] = 0.0

    selected_sample = None
    sample_in_window = False
    if pqos_samples:
        for sample in pqos_samples:
            if start_ts <= sample["sigma"] < window_end:
                selected_sample = sample
                sample_in_window = True
                break
        if selected_sample is None:
            best_sample = min(pqos_samples, key=lambda s: abs(s["sigma"] - window_center))
            if abs(best_sample["sigma"] - window_center) <= 0.40:
                selected_sample = best_sample
        if selected_sample is not None:
            if sample_in_window:
                pqos_in_window += 1
            total_mbt = max(selected_sample["core"], 0.0) + max(selected_sample["other"], 0.0)
            fraction = clamp(
                (selected_sample["core"] / max(total_mbt, EPS)) if total_mbt > 0.0 else 0.0
            )
            dram_core_raw[idx] = fraction * max(p_dram, 0.0)
    else:
        dram_core_raw[idx] = 0.0

pkg_core = interpolate_series(pkg_core_raw)
dram_core = interpolate_series(dram_core_raw)

if pkg_core_raw.count(None) == total_rows and not tstat_blocks:
    pkg_core = [0.0] * total_rows
if dram_core_raw.count(None) == total_rows and not pqos_samples:
    dram_core = [0.0] * total_rows

if total_rows:
    ratio = tstat_in_window / total_rows
    if ratio < 0.95:
        print(
            f"[pcm-power] turbostat in-window coverage below 95% ({ratio:.1%})",
            file=sys.stderr,
        )
if total_rows and (pqos_file_present or pqos_samples):
    ratio = pqos_in_window / total_rows
    if ratio < 0.95:
        print(
            f"[pcm-power] pqos in-window coverage below 95% ({ratio:.1%})",
            file=sys.stderr,
        )

if any(value < -EPS for value in pkg_core + dram_core):
    print("[pcm-power] Negative attribution detected", file=sys.stderr)

rows[0].extend(["S0", "S0"])
rows[1].extend(["Actual Watts", "Actual DRAM Watts"])
for i, row in enumerate(data_rows):
    while len(row) < len(rows[0]) - 2:
        row.append("")
    row.append(format(pkg_core[i], ".6f"))
    row.append(format(dram_core[i], ".6f"))

with open(pcm_path, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerows(rows[:2] + data_rows)
PYTHON

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
  log_debug "Launching Maya profiler (text=/local/data/results/id_1_maya.txt, log=/local/data/results/id_1_maya.log)"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    set -euo pipefail

    # Start Maya on CPU 5 in background; capture PID immediately
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_1_maya.txt 2>&1 &
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
    taskset -c 6 /local/bci_code/id_1/main >> /local/data/results/id_1_maya.log 2>&1 || true

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
  log_debug "Launching toplev basic (CSV=/local/data/results/id_1_toplev_basic.csv, log=/local/data/results/id_1_toplev_basic.log)"
  idle_wait
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o /local/data/results/id_1_toplev_basic.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_basic.log 2>&1'
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
  log_debug "Launching toplev execution (CSV=/local/data/results/id_1_toplev_execution.csv, log=/local/data/results/id_1_toplev_execution.log)"
  idle_wait
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_1_toplev_execution.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_execution.log 2>&1
  '
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
  log_debug "Launching toplev full (CSV=/local/data/results/id_1_toplev_full.csv, log=/local/data/results/id_1_toplev_full.log)"
  idle_wait
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_1_toplev_full.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_full.log 2>&1
  '
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
  echo "Converting id_1_maya.txt → id_1_maya.csv"
  log_debug "Converting Maya output to CSV"
  awk '
  {
    for (i = 1; i <= NF; i++) {
      printf "%s%s", $i, (i < NF ? "," : "")
    }
    print ""
  }
  ' /local/data/results/id_1_maya.txt > /local/data/results/id_1_maya.csv
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
