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
IDTAG=${IDTAG:-id_20_3gram_llm}
TOPLEV_BASIC_INTERVAL_SEC=${TOPLEV_BASIC_INTERVAL_SEC:-0.5}
TOPLEV_EXECUTION_INTERVAL_SEC=${TOPLEV_EXECUTION_INTERVAL_SEC:-0.5}
TOPLEV_FULL_INTERVAL_SEC=${TOPLEV_FULL_INTERVAL_SEC:-0.5}
PCM_INTERVAL_SEC=${PCM_INTERVAL_SEC:-0.5}
PCM_MEMORY_INTERVAL_SEC=${PCM_MEMORY_INTERVAL_SEC:-0.5}
PCM_POWER_INTERVAL_SEC=${PCM_POWER_INTERVAL_SEC:-0.5}
PCM_PCIE_INTERVAL_SEC=${PCM_PCIE_INTERVAL_SEC:-0.5}
PQOS_INTERVAL_SEC=${PQOS_INTERVAL_SEC:-0.5}
TS_INTERVAL=${TS_INTERVAL:-0.5}
PQOS_INTERVAL_TICKS=${PQOS_INTERVAL_TICKS:-5}

# Ensure shared knobs are visible to child processes (e.g., inline Python blocks).
export WORKLOAD_CPU PCM_CPU TOOLS_CPU OUTDIR LOGDIR IDTAG TS_INTERVAL PQOS_INTERVAL_TICKS \
  PCM_INTERVAL_SEC PCM_MEMORY_INTERVAL_SEC PCM_POWER_INTERVAL_SEC PCM_PCIE_INTERVAL_SEC \
  PQOS_INTERVAL_SEC TOPLEV_BASIC_INTERVAL_SEC TOPLEV_EXECUTION_INTERVAL_SEC \
  TOPLEV_FULL_INTERVAL_SEC

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
  "--interval-toplev-basic|seconds|Set sampling interval for toplev-basic in seconds (default: 0.5)"
  "--interval-toplev-execution|seconds|Set sampling interval for toplev-execution in seconds (default: 0.5)"
  "--interval-toplev-full|seconds|Set sampling interval for toplev-full in seconds (default: 0.5)"
  "--interval-pcm|seconds|Set sampling interval for pcm in seconds (default: 0.5)"
  "--interval-pcm-memory|seconds|Set sampling interval for pcm-memory in seconds (default: 0.5)"
  "--interval-pcm-power|seconds|Set sampling interval for pcm-power in seconds (default: 0.5)"
  "--interval-pcm-pcie|seconds|Set sampling interval for pcm-pcie in seconds (default: 0.5)"
  "--interval-pqos|seconds|Set sampling interval for pqos in seconds (default: 0.5)"
  "--interval-turbostat|seconds|Set sampling interval for turbostat in seconds (default: 0.5)"
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

require_positive_number() {
  local label="$1"
  local value="$2"
  if [[ ! $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Invalid interval for ${label}: '$value' (expected positive number)" >&2
    exit 1
  fi
  if ! awk -v v="$value" 'BEGIN{exit (v > 0 ? 0 : 1)}'; then
    echo "Interval for ${label} must be greater than zero" >&2
    exit 1
  fi
}

set_interval_value() {
  local var_name="$1"
  local label="$2"
  local value="$3"
  require_positive_number "$label" "$value"
  printf -v "$var_name" '%s' "$value"
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
    --interval-toplev-basic=*)
      set_interval_value TOPLEV_BASIC_INTERVAL_SEC "--interval-toplev-basic" "${1#--interval-toplev-basic=}"
      ;;
    --interval-toplev-basic)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-toplev-basic" >&2
        exit 1
      fi
      set_interval_value TOPLEV_BASIC_INTERVAL_SEC "--interval-toplev-basic" "$2"
      shift
      ;;
    --interval-toplev-execution=*)
      set_interval_value TOPLEV_EXECUTION_INTERVAL_SEC "--interval-toplev-execution" "${1#--interval-toplev-execution=}"
      ;;
    --interval-toplev-execution)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-toplev-execution" >&2
        exit 1
      fi
      set_interval_value TOPLEV_EXECUTION_INTERVAL_SEC "--interval-toplev-execution" "$2"
      shift
      ;;
    --interval-toplev-full=*)
      set_interval_value TOPLEV_FULL_INTERVAL_SEC "--interval-toplev-full" "${1#--interval-toplev-full=}"
      ;;
    --interval-toplev-full)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-toplev-full" >&2
        exit 1
      fi
      set_interval_value TOPLEV_FULL_INTERVAL_SEC "--interval-toplev-full" "$2"
      shift
      ;;
    --interval-pcm=*)
      set_interval_value PCM_INTERVAL_SEC "--interval-pcm" "${1#--interval-pcm=}"
      ;;
    --interval-pcm)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-pcm" >&2
        exit 1
      fi
      set_interval_value PCM_INTERVAL_SEC "--interval-pcm" "$2"
      shift
      ;;
    --interval-pcm-memory=*)
      set_interval_value PCM_MEMORY_INTERVAL_SEC "--interval-pcm-memory" "${1#--interval-pcm-memory=}"
      ;;
    --interval-pcm-memory)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-pcm-memory" >&2
        exit 1
      fi
      set_interval_value PCM_MEMORY_INTERVAL_SEC "--interval-pcm-memory" "$2"
      shift
      ;;
    --interval-pcm-power=*)
      set_interval_value PCM_POWER_INTERVAL_SEC "--interval-pcm-power" "${1#--interval-pcm-power=}"
      ;;
    --interval-pcm-power)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-pcm-power" >&2
        exit 1
      fi
      set_interval_value PCM_POWER_INTERVAL_SEC "--interval-pcm-power" "$2"
      shift
      ;;
    --interval-pcm-pcie=*)
      set_interval_value PCM_PCIE_INTERVAL_SEC "--interval-pcm-pcie" "${1#--interval-pcm-pcie=}"
      ;;
    --interval-pcm-pcie)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-pcm-pcie" >&2
        exit 1
      fi
      set_interval_value PCM_PCIE_INTERVAL_SEC "--interval-pcm-pcie" "$2"
      shift
      ;;
    --interval-pqos=*)
      set_interval_value PQOS_INTERVAL_SEC "--interval-pqos" "${1#--interval-pqos=}"
      ;;
    --interval-pqos)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-pqos" >&2
        exit 1
      fi
      set_interval_value PQOS_INTERVAL_SEC "--interval-pqos" "$2"
      shift
      ;;
    --interval-turbostat=*)
      set_interval_value TS_INTERVAL "--interval-turbostat" "${1#--interval-turbostat=}"
      ;;
    --interval-turbostat)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --interval-turbostat" >&2
        exit 1
      fi
      set_interval_value TS_INTERVAL "--interval-turbostat" "$2"
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

# Derive tool-specific interval representations
format_interval_for_display() {
  awk -v v="$1" 'BEGIN{printf "%.4f", v + 0}'
}

TOPLEV_BASIC_INTERVAL_MS=$(awk -v s="$TOPLEV_BASIC_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')
TOPLEV_EXECUTION_INTERVAL_MS=$(awk -v s="$TOPLEV_EXECUTION_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')
TOPLEV_FULL_INTERVAL_MS=$(awk -v s="$TOPLEV_FULL_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')

normalize_interval_var() {
  local var_name="$1"
  local value="$2"
  local formatted
  formatted=$(format_interval_for_display "$value")
  printf -v "$var_name" '%s' "$formatted"
}

normalize_interval_var PCM_INTERVAL_SEC "$PCM_INTERVAL_SEC"
normalize_interval_var PCM_MEMORY_INTERVAL_SEC "$PCM_MEMORY_INTERVAL_SEC"
normalize_interval_var PCM_POWER_INTERVAL_SEC "$PCM_POWER_INTERVAL_SEC"
normalize_interval_var PCM_PCIE_INTERVAL_SEC "$PCM_PCIE_INTERVAL_SEC"
normalize_interval_var PQOS_INTERVAL_SEC "$PQOS_INTERVAL_SEC"
normalize_interval_var TS_INTERVAL "$TS_INTERVAL"
normalize_interval_var TOPLEV_BASIC_INTERVAL_SEC "$TOPLEV_BASIC_INTERVAL_SEC"
normalize_interval_var TOPLEV_EXECUTION_INTERVAL_SEC "$TOPLEV_EXECUTION_INTERVAL_SEC"
normalize_interval_var TOPLEV_FULL_INTERVAL_SEC "$TOPLEV_FULL_INTERVAL_SEC"

pqos_ticks_calc=$(awk -v s="$PQOS_INTERVAL_SEC" 'BEGIN{
  if (s <= 0) {
    print "INVALID";
    exit 0;
  }
  ticks = s * 10;
  rounded = int(ticks + 0.5);
  diff = ticks - rounded;
  if (diff < 0) diff = -diff;
  if (diff <= 1e-6) {
    if (rounded < 1) {
      print "INVALID";
    } else {
      print rounded;
    }
  } else {
    print "INVALID";
  }
}')
if [[ $pqos_ticks_calc == INVALID ]]; then
  echo "Invalid value for --interval-pqos: '${PQOS_INTERVAL_SEC}' (expected multiple of 0.1 seconds)" >&2
  exit 1
fi
PQOS_INTERVAL_TICKS="$pqos_ticks_calc"
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
  log_debug "  Interval toplev-basic: ${TOPLEV_BASIC_INTERVAL_SEC}s (${TOPLEV_BASIC_INTERVAL_MS} ms)"
  log_debug "  Interval toplev-execution: ${TOPLEV_EXECUTION_INTERVAL_SEC}s (${TOPLEV_EXECUTION_INTERVAL_MS} ms)"
  log_debug "  Interval toplev-full: ${TOPLEV_FULL_INTERVAL_SEC}s (${TOPLEV_FULL_INTERVAL_MS} ms)"
  log_debug "  Interval pcm: ${PCM_INTERVAL_SEC}s"
  log_debug "  Interval pcm-memory: ${PCM_MEMORY_INTERVAL_SEC}s"
  log_debug "  Interval pcm-power: ${PCM_POWER_INTERVAL_SEC}s"
  log_debug "  Interval pcm-pcie: ${PCM_PCIE_INTERVAL_SEC}s"
  log_debug "  Interval pqos: ${PQOS_INTERVAL_SEC}s (${PQOS_INTERVAL_TICKS} ticks)"
  log_debug "  Interval turbostat: ${TS_INTERVAL}s"
  log_debug "  Tools enabled -> toplev_basic=${run_toplev_basic}, toplev_full=${run_toplev_full}, toplev_execution=${run_toplev_execution}, maya=${run_maya}, pcm=${run_pcm}, pcm_memory=${run_pcm_memory}, pcm_power=${run_pcm_power}, pcm_pcie=${run_pcm_pcie}"
fi

# Describe this workload for logging
workload_desc="ID-20 3gram LLM"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev_full && tools_list+=("toplev-full")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_maya && tools_list+=("maya")
$run_pcm  && tools_list+=("pcm")
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

# Prepare placeholder logs for any disabled tool so that done.log contains an
# entry for every possible stage.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_llm_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_llm_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_llm_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_llm_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_llm_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_llm_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_llm_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_llm_pcm_pcie.log
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
### 3. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project
log_debug "Changed working directory to /local/tools/bci_project"

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
  log_debug "Launching pcm-pcie (CSV=/local/data/results/id_20_3gram_llm_pcm_pcie.csv, log=/local/data/results/id_20_3gram_llm_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_20_3gram_llm_pcm_pcie.csv \
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_llm_pcm_pcie.log
  log_debug "pcm-pcie completed in ${pcm_pcie_runtime}s"
fi

if $run_pcm; then
  echo
  echo "----------------------------"
  echo "PCM"
  echo "----------------------------"
  log_debug "Launching pcm (CSV=/local/data/results/id_20_3gram_llm_pcm.csv, log=/local/data/results/id_20_3gram_llm_pcm.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_20_3gram_llm_pcm.csv \
      '${PCM_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm.log 2>&1
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_llm_pcm.log
  log_debug "pcm completed in ${pcm_runtime}s"
fi

if $run_pcm_memory; then
  echo
  echo "----------------------------"
  echo "PCM-MEMORY"
  echo "----------------------------"
  log_debug "Launching pcm-memory (CSV=/local/data/results/id_20_3gram_llm_pcm_memory.csv, log=/local/data/results/id_20_3gram_llm_pcm_memory.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_20_3gram_llm_pcm_memory.csv \
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_memory.log 2>&1
  pcm_mem_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_mem_runtime")" \
    > /local/data/results/done_llm_pcm_memory.log
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
    PQOS_GROUPS="all:${WORKLOAD_CPU}"
    if [[ -n ${OTHERS} ]]; then
      PQOS_GROUPS="${PQOS_GROUPS};all:${OTHERS}"
    fi
    printf -v PQOS_CMD "taskset -c %s pqos -I -u csv -o %q -i %s -m %q" \
      "${TOOLS_CPU}" "${RESULT_PREFIX}_pqos.csv" "${PQOS_INTERVAL_TICKS}" "${PQOS_GROUPS}"
    {
      printf '[pqos] cmd: %s\n' "${PQOS_CMD}"
      printf '[pqos] groups: workload=%s others=%s\n' "${WORKLOAD_CPU}" "${OTHERS:-<none>}"
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
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-power '${PCM_POWER_INTERVAL_SEC}' \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_20_3gram_llm_pcm_power.csv -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_power.log 2>&1
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
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/done_llm_pcm_power.log"
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

  python3 <<'PY'
import bisect
import csv
import datetime
import math
import os
import statistics
import tempfile
import time
from pathlib import Path

EPS = 1e-9
DEFAULT_INTERVAL = 0.5
DATETIME_FORMATS = ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S")


def read_interval(name, fallback):
    raw = os.environ.get(name)
    if raw is None:
        return fallback
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return fallback
    return value if value > EPS else fallback


PCM_INTERVAL_SEC = read_interval("PCM_POWER_INTERVAL_SEC", DEFAULT_INTERVAL)
PQOS_INTERVAL_SEC = read_interval("PQOS_INTERVAL_SEC", PCM_INTERVAL_SEC)
TURBOSTAT_INTERVAL_SEC = read_interval("TS_INTERVAL", DEFAULT_INTERVAL)
DELTA_T_SEC = PCM_INTERVAL_SEC


def log(msg):
    print(f"[attrib] {msg}")


def warn(msg):
    print(f"[attrib][WARN] {msg}")


def error(msg):
    print(f"[attrib][ERROR] {msg}")


def ok(msg):
    print(f"[attrib][OK] {msg}")


def parse_datetime(text):
    cleaned = text.strip()
    for fmt in DATETIME_FORMATS:
        try:
            dt = datetime.datetime.strptime(cleaned, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    raise ValueError(f"unable to parse datetime '{text}'")


def parse_pcm_timestamp(date_text, time_text, previous):
    combined = f"{date_text.strip()} {time_text.strip()}".strip()
    if not combined:
        if previous is not None:
            return previous + DELTA_T_SEC, True
        return 0.0, True
    try:
        return parse_datetime(combined), False
    except ValueError:
        if previous is not None:
            return previous + DELTA_T_SEC, True
        return 0.0, True


def try_parse_pqos_time(time_text):
    cleaned = time_text.strip()
    if not cleaned:
        return None
    try:
        return parse_datetime(cleaned)
    except ValueError:
        return None


def safe_float(value):
    if value is None:
        return math.nan
    text = str(value).strip()
    if not text:
        return math.nan
    try:
        return float(text)
    except ValueError:
        return math.nan


def clamp01(value):
    return max(0.0, min(1.0, value))


def fill_series(raw_values):
    n = len(raw_values)
    if n == 0:
        return [], 0
    if all(v is None for v in raw_values):
        return [0.0] * n, 0
    forward = [None] * n
    prev = None
    for idx, value in enumerate(raw_values):
        if value is not None:
            prev = value
        forward[idx] = prev
    backward = [None] * n
    nxt = None
    for idx in range(n - 1, -1, -1):
        value = raw_values[idx]
        if value is not None:
            nxt = value
        backward[idx] = nxt
    result = []
    interpolated = 0
    for idx, value in enumerate(raw_values):
        if value is not None:
            result.append(max(0.0, value))
            continue
        fwd = forward[idx]
        bwd = backward[idx]
        if fwd is not None and bwd is not None:
            interpolated += 1
            result.append(max(0.0, 0.5 * (fwd + bwd)))
        elif fwd is not None:
            result.append(max(0.0, fwd))
        elif bwd is not None:
            result.append(max(0.0, bwd))
        else:
            result.append(0.0)
    return result, interpolated


def take_first(values, count=3):
    return [round(v, 3) for v in values[:count]]


def take_last(values, count=3):
    if not values:
        return []
    return [round(v, 3) for v in values[-count:]]


def is_numeric(cell):
    text = str(cell).strip()
    if not text:
        return False
    try:
        float(text)
        return True
    except ValueError:
        return False


def select_entry(times, entries, window_start, window_end, window_center, tolerance):
    if not times:
        return None, False, False
    idx = bisect.bisect_left(times, window_start)
    if idx < len(times) and times[idx] < window_end:
        return entries[idx], True, False
    candidates = []
    if idx < len(times):
        candidates.append(idx)
    if idx > 0:
        candidates.append(idx - 1)
    if not candidates:
        return None, False, False
    best_idx = None
    best_diff = None
    for candidate in candidates:
        diff = abs(times[candidate] - window_center)
        if best_diff is None or diff < best_diff:
            best_idx = candidate
            best_diff = diff
    if best_idx is not None and best_diff is not None and best_diff <= tolerance:
        return entries[best_idx], False, True
    return None, False, False


def pqos_entries_for_window(times, entries, window_start, window_end, interval):
    if not entries:
        return []
    left = bisect.bisect_left(times, window_start)
    right = bisect.bisect_right(times, window_end)
    idx_start = max(0, left - 1)
    idx_end = min(len(entries), right + 1)
    selected = []
    for idx in range(idx_start, idx_end):
        sample = entries[idx]
        sigma = sample.get("sigma")
        if sigma is None:
            continue
        sample_start = sigma - interval
        sample_end = sigma
        if sample_end > window_start and sample_start < window_end:
            selected.append(sample)
    if not selected and left < len(entries):
        sample = entries[left]
        sigma = sample.get("sigma")
        if sigma is not None:
            sample_start = sigma - interval
            sample_end = sigma
            if sample_end > window_start and sample_start < window_end:
                selected.append(sample)
    return selected


def average_mbl_components(samples, workload_core_set):
    if not samples:
        return 0.0, 0.0, 0
    core_total = 0.0
    bandwidth_total = 0.0
    count = 0
    for sample in samples:
        core_sum = 0.0
        total_sum = 0.0
        for entry in sample.get("rows", []):
            value = max(entry.get("mbl", 0.0), 0.0)
            total_sum += value
            if entry["core"] == workload_core_set:
                core_sum += value
        core_total += core_sum
        bandwidth_total += total_sum
        count += 1
    if count == 0:
        return 0.0, 0.0, 0
    return core_total / count, bandwidth_total / count, count


def main():
    outdir = os.environ.get("OUTDIR")
    idtag = os.environ.get("IDTAG")
    workload_cpu_str = os.environ.get("WORKLOAD_CPU", "0")
    try:
        workload_cpu = int(workload_cpu_str)
    except ValueError:
        workload_cpu = 0
    workload_core_set = frozenset({workload_cpu})

    if not outdir or not idtag:
        error("OUTDIR or IDTAG not set; skipping attribution step")
        return

    base_dir = Path(outdir)
    pcm_path = base_dir / f"{idtag}_pcm_power.csv"
    turbostat_path = base_dir / f"{idtag}_turbostat.csv"
    pqos_path = base_dir / f"{idtag}_pqos.csv"

    log(
        "files: pcm={} ({}), turbostat={} ({}), pqos={} ({})".format(
            pcm_path,
            "exists" if pcm_path.exists() else "missing",
            turbostat_path,
            "exists" if turbostat_path.exists() else "missing",
            pqos_path,
            "exists" if pqos_path.exists() else "missing",
        )
    )
    log(
        "intervals: pcm={:.4f}s, pqos={:.4f}s, turbostat={:.4f}s".format(
            PCM_INTERVAL_SEC,
            PQOS_INTERVAL_SEC,
            TURBOSTAT_INTERVAL_SEC,
        )
    )

    if not pcm_path.exists():
        error(f"pcm-power CSV missing at {pcm_path}; aborting attribution")
        return

    with open(pcm_path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        error("pcm-power CSV missing headers or data; aborting attribution")
        return

    header1 = list(rows[0])
    header2 = list(rows[1])
    data_rows = [list(row) for row in rows[2:]]
    row_count = len(data_rows)

    log(f"header lengths: top={len(header1)}, bottom={len(header2)}")
    tail_preview = header2[-4:] if len(header2) >= 4 else header2[:]
    log(f"header2 last4: {tail_preview}")
    watts_idx_pre = [idx for idx, name in enumerate(header2) if name.strip() == "Watts"]
    dram_idx_pre = [idx for idx, name in enumerate(header2) if name.strip() == "DRAM Watts"]
    log(
        "header index pre: Watts={}, DRAM Watts={}".format(
            watts_idx_pre[-1] if watts_idx_pre else "NA",
            dram_idx_pre[-1] if dram_idx_pre else "NA",
        )
    )

    ghost_ratio = 0.0
    ghost = False
    if header1 and header2 and header1[-1] == "" and header2[-1] == "":
        empty_cells = 0
        for row in data_rows:
            if not row or row[-1] == "":
                empty_cells += 1
        ghost_ratio = empty_cells / row_count if row_count else 1.0
        ghost = ghost_ratio >= 0.95
    log(f"ghost column detected: {'yes' if ghost else 'no'} (empty_ratio={ghost_ratio:.3f})")

    if ghost:
        header1 = header1[:-1]
        header2 = header2[:-1]
        data_rows = [row[:-1] if row else [] for row in data_rows]

    target_len = max(len(header1), len(header2))
    if len(header1) < target_len:
        header1.extend([""] * (target_len - len(header1)))
    if len(header2) < target_len:
        header2.extend([""] * (target_len - len(header2)))
    target_len = len(header2)
    for row in data_rows:
        if len(row) < target_len:
            row.extend([""] * (target_len - len(row)))
        elif len(row) > target_len:
            del row[target_len:]

    existing_actual_indices = [idx for idx, name in enumerate(header2) if name.strip() in ("Actual Watts", "Actual DRAM Watts")]
    removed_existing = len(existing_actual_indices)
    if removed_existing:
        for idx in sorted(existing_actual_indices, reverse=True):
            del header1[idx]
            del header2[idx]
            for row in data_rows:
                if len(row) > idx:
                    del row[idx]

    target_len = len(header2)
    for row in data_rows:
        if len(row) < target_len:
            row.extend([""] * (target_len - len(row)))
        elif len(row) > target_len:
            del row[target_len:]

    watts_indices = [idx for idx, name in enumerate(header2) if name.strip() == "Watts"]
    dram_indices = [idx for idx, name in enumerate(header2) if name.strip() == "DRAM Watts"]
    if not watts_indices or not dram_indices:
        error("required Watts or DRAM Watts column missing after normalization; aborting attribution")
        return
    watts_idx = watts_indices[-1]
    dram_idx = dram_indices[-1]

    def find_column(name):
        for idx, value in enumerate(header2):
            if value == name:
                return idx
        return None

    date_idx = find_column("Date")
    time_idx = find_column("Time")
    if date_idx is None or time_idx is None:
        error("Date/Time columns not found in pcm-power CSV; aborting attribution")
        return

    log(f"writeback: watts_idx={watts_idx}, dram_idx={dram_idx}, removed_existing={removed_existing}")

    pcm_times = []
    pkg_powers = []
    dram_powers = []
    timestamp_fallbacks = 0
    previous_timestamp = None
    for row in data_rows:
        date_value = row[date_idx] if date_idx < len(row) else ""
        time_value = row[time_idx] if time_idx < len(row) else ""
        timestamp, used_fallback = parse_pcm_timestamp(date_value, time_value, previous_timestamp)
        if used_fallback:
            timestamp_fallbacks += 1
        pcm_times.append(timestamp)
        previous_timestamp = timestamp
        pkg_value = safe_float(row[watts_idx]) if watts_idx < len(row) else math.nan
        dram_value = safe_float(row[dram_idx]) if dram_idx < len(row) else math.nan
        pkg_powers.append(0.0 if math.isnan(pkg_value) else max(pkg_value, 0.0))
        dram_powers.append(0.0 if math.isnan(dram_value) else max(dram_value, 0.0))

    if timestamp_fallbacks:
        log(f"pcm timestamp fallbacks applied={timestamp_fallbacks}")

    turbostat_blocks = []
    if turbostat_path.exists():
        with open(turbostat_path, newline="") as f:
            reader = csv.DictReader(f)
            tstat_rows = []
            for row in reader:
                try:
                    cpu = int((row.get("CPU") or "").strip())
                    busy = float((row.get("Busy%") or "").strip())
                    bzy = float((row.get("Bzy_MHz") or "").strip())
                    tod = float((row.get("Time_Of_Day_Seconds") or "").strip())
                except (ValueError, AttributeError):
                    continue
                tstat_rows.append({"cpu": cpu, "busy": busy, "bzy": bzy, "time": tod})
        if tstat_rows:
            cpu_ids = sorted({entry["cpu"] for entry in tstat_rows})
            n_cpus = len(cpu_ids)
            if n_cpus:
                index = 0
                total_rows = len(tstat_rows)
                while index + n_cpus <= total_rows:
                    block_rows = tstat_rows[index : index + n_cpus]
                    index += n_cpus
                    cpu_in_block = {entry["cpu"] for entry in block_rows}
                    if len(cpu_in_block) < max(1, math.ceil(0.8 * n_cpus)):
                        continue
                    tau = statistics.median(entry["time"] for entry in block_rows)
                    turbostat_blocks.append({"tau": tau, "rows": block_rows})

    pqos_entries_raw = []
    mbl_field = None
    if pqos_path.exists():
        with open(pqos_path, newline="") as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames or []
            for name in fieldnames:
                lower = name.lower()
                if "mbl" in lower and "/s" in lower:
                    mbl_field = name
                    break
            if mbl_field is None:
                error("pqos MBL column not found; skipping pqos attribution")
            else:
                for row in reader:
                    time_value = row.get("Time")
                    core_value = row.get("Core")
                    if time_value is None or core_value is None:
                        continue
                    mbl_value = safe_float(row.get(mbl_field))
                    if math.isnan(mbl_value):
                        continue
                    core_clean = core_value.replace('"', "").strip()
                    core_clean = core_clean.replace("[", "").replace("]", "")
                    core_clean = core_clean.replace("{", "").replace("}", "")
                    if not core_clean:
                        continue
                    core_set = set()
                    for part in core_clean.split(","):
                        part = part.strip()
                        if not part:
                            continue
                        if ":" in part:
                            part = part.split(":", 1)[1].strip()
                        if not part:
                            continue
                        if "-" in part:
                            start_str, end_str = part.split("-", 1)
                            try:
                                start = int(start_str.strip())
                                end = int(end_str.strip())
                            except ValueError:
                                continue
                            if start <= end:
                                core_set.update(range(start, end + 1))
                            else:
                                core_set.update(range(end, start + 1))
                        else:
                            try:
                                core_set.add(int(part))
                            except ValueError:
                                continue
                    if not core_set:
                        continue
                    pqos_entries_raw.append({
                        "time": time_value.strip(),
                        "core": frozenset(core_set),
                        "mbl": max(mbl_value, 0.0),
                    })

    pqos_samples = []
    current_sample = None
    current_time = None
    seen_cores = set()
    for entry in pqos_entries_raw:
        time_value = entry["time"]
        core_set = entry["core"]
        if current_sample is None:
            current_sample = {"time": time_value, "rows": []}
            current_time = time_value
            seen_cores = set()
        else:
            if time_value != current_time:
                pqos_samples.append(current_sample)
                current_sample = {"time": time_value, "rows": []}
                current_time = time_value
                seen_cores = set()
            elif core_set in seen_cores:
                pqos_samples.append(current_sample)
                current_sample = {"time": time_value, "rows": []}
                current_time = time_value
                seen_cores = set()
        current_sample["rows"].append(entry)
        seen_cores.add(core_set)
    if current_sample is not None:
        pqos_samples.append(current_sample)

    has_subseconds = any("." in sample["time"].split()[-1] for sample in pqos_samples) if pqos_samples else False
    if pqos_samples:
        if has_subseconds:
            for sample in pqos_samples:
                sample["sigma"] = try_parse_pqos_time(sample["time"])
        else:
            base_time = try_parse_pqos_time(pqos_samples[0]["time"])
            if base_time is None:
                base_time = 0.0
            for idx, sample in enumerate(pqos_samples):
                sample["sigma"] = base_time + idx * PQOS_INTERVAL_SEC

    pqos_entries = [sample for sample in pqos_samples if sample.get("sigma") is not None]
    pqos_times = [sample["sigma"] for sample in pqos_entries]
    turbostat_times = [block["tau"] for block in turbostat_blocks]

    pkg_raw = []
    dram_raw = []
    ts_in_window = ts_near = ts_miss = 0
    pqos_in_window = pqos_near = pqos_miss = 0
    pqos_bandwidth_core_sum = 0.0
    pqos_bandwidth_other_sum = 0.0
    pqos_bandwidth_total_sum = 0.0
    pqos_bandwidth_sample_count = 0
    force_pkg_zero = not turbostat_times
    force_dram_zero = not pqos_times

    ts_tolerance = max(PCM_INTERVAL_SEC, TURBOSTAT_INTERVAL_SEC) * 0.80
    pqos_tolerance = max(PCM_INTERVAL_SEC, PQOS_INTERVAL_SEC) * 0.80

    for idx, window_start in enumerate(pcm_times):
        window_end = window_start + DELTA_T_SEC
        window_center = window_start + 0.5 * DELTA_T_SEC

        if force_pkg_zero:
            pkg_raw.append(0.0)
            ts_miss += 1
        else:
            block, in_window, near = select_entry(
                turbostat_times,
                turbostat_blocks,
                window_start,
                window_end,
                window_center,
                ts_tolerance,
            )
            if block is None:
                pkg_raw.append(None)
                ts_miss += 1
            else:
                if in_window:
                    ts_in_window += 1
                elif near:
                    ts_near += 1
                total_weight = 0.0
                workload_weight = 0.0
                for entry in block["rows"]:
                    busy = max(entry["busy"], 0.0)
                    mhz = max(entry["bzy"], 0.0)
                    weight = (busy / 100.0) * mhz
                    total_weight += weight
                    if entry["cpu"] == workload_cpu:
                        workload_weight = weight
                fraction = clamp01(workload_weight / total_weight) if total_weight > EPS else 0.0
                pkg_raw.append(fraction * pkg_powers[idx])

        if force_dram_zero:
            dram_raw.append(0.0)
            pqos_miss += 1
        else:
            selected_samples = pqos_entries_for_window(
                pqos_times,
                pqos_entries,
                window_start,
                window_end,
                PQOS_INTERVAL_SEC,
            )
            mbl_core = 0.0
            mbl_total = 0.0
            mbl_count = 0
            if selected_samples:
                pqos_in_window += 1
                mbl_core, mbl_total, mbl_count = average_mbl_components(
                    selected_samples, workload_core_set
                )
            else:
                sample, in_window, near = select_entry(
                    pqos_times,
                    pqos_entries,
                    window_start,
                    window_end,
                    window_center,
                    pqos_tolerance,
                )
                if sample is None:
                    dram_raw.append(None)
                    pqos_miss += 1
                    continue
                if in_window:
                    pqos_in_window += 1
                elif near:
                    pqos_near += 1
                mbl_core, mbl_total, mbl_count = average_mbl_components(
                    [sample], workload_core_set
                )
            core_bandwidth = max(mbl_core, 0.0)
            total_bandwidth = max(mbl_total, 0.0)
            other_bandwidth = max(total_bandwidth - core_bandwidth, 0.0)
            fraction = (
                clamp01(core_bandwidth / total_bandwidth)
                if total_bandwidth > EPS
                else 0.0
            )
            if mbl_count:
                pqos_bandwidth_core_sum += core_bandwidth * mbl_count
                pqos_bandwidth_other_sum += other_bandwidth * mbl_count
                pqos_bandwidth_total_sum += total_bandwidth * mbl_count
                pqos_bandwidth_sample_count += mbl_count
            dram_raw.append(fraction * dram_powers[idx])

    log(f"alignment turbostat: in_window={ts_in_window}, near={ts_near}, miss={ts_miss}")
    log(f"alignment pqos: in_window={pqos_in_window}, near={pqos_near}, miss={pqos_miss}")
    if pqos_bandwidth_sample_count:
        avg_core_bandwidth = pqos_bandwidth_core_sum / pqos_bandwidth_sample_count
        avg_other_bandwidth = pqos_bandwidth_other_sum / pqos_bandwidth_sample_count
        avg_total_bandwidth = pqos_bandwidth_total_sum / pqos_bandwidth_sample_count
    else:
        avg_core_bandwidth = avg_other_bandwidth = avg_total_bandwidth = 0.0
    log(
        "average pqos bandwidth: workload_core={:.2f} MB/s, complementary_cores={:.2f} MB/s, all_cores={:.2f} MB/s".format(
            avg_core_bandwidth,
            avg_other_bandwidth,
            avg_total_bandwidth,
        )
    )
    if row_count:
        ts_coverage = ts_in_window / row_count
        pqos_coverage = pqos_in_window / row_count
        if ts_coverage < 0.95:
            warn(f"turbostat in-window coverage = {ts_in_window}/{row_count} = {ts_coverage * 100:.1f}% (<95%)")
        if pqos_coverage < 0.95:
            warn(f"pqos in-window coverage = {pqos_in_window}/{row_count} = {pqos_coverage * 100:.1f}% (<95%)")

    pkg_filled, pkg_interpolated = fill_series(pkg_raw)
    dram_filled, dram_interpolated = fill_series(dram_raw)

    def has_none(values):
        return any(v is None for v in values)

    if has_none(pkg_raw) or has_none(dram_raw):
        log("raw series contained missing entries prior to fill")

    pkg_missing_after = sum(1 for value in pkg_filled if value is None)
    dram_missing_after = sum(1 for value in dram_filled if value is None)
    if pkg_missing_after or dram_missing_after:
        error(f"missing values remain after fill (pkg_missing={pkg_missing_after}, dram_missing={dram_missing_after})")

    if pkg_filled and min(pkg_filled) < -EPS:
        error(f"negative attribution after clamp (min_pkg={min(pkg_filled):.6f}, min_dram={min(dram_filled) if dram_filled else 0.0:.6f})")
    if dram_filled and min(dram_filled) < -EPS:
        error(f"negative attribution after clamp (min_pkg={min(pkg_filled) if pkg_filled else 0.0:.6f}, min_dram={min(dram_filled):.6f})")

    log(f"fill pkg: interpolated={pkg_interpolated}, first3={take_first(pkg_filled)}, last3={take_last(pkg_filled)}")
    log(f"fill dram: interpolated={dram_interpolated}, first3={take_first(dram_filled)}, last3={take_last(dram_filled)}")

    cols_before = len(header2)
    header1.extend(["S0", "S0"])
    header2.extend(["Actual Watts", "Actual DRAM Watts"])
    cols_after = len(header2)
    appended_headers = ["Actual Watts", "Actual DRAM Watts"]
    for idx, row in enumerate(data_rows):
        row.append(f"{pkg_filled[idx]:.6f}")
        row.append(f"{dram_filled[idx]:.6f}")

    log(f"writeback: pre_shape={row_count}x{cols_before}, post_shape={row_count}x{cols_after}")
    log(f"writeback: appended_headers={appended_headers}")
    log(
        "writeback: ghost_readded={}".format(
            "no (dropped empty column)" if ghost else "not needed"
        )
    )
    header2_tail_after = header2[-6:] if len(header2) >= 6 else header2[:]
    log(f"header2 tail after write: {header2_tail_after}")

    try:
        stat_info = os.stat(pcm_path)
    except FileNotFoundError:
        stat_info = None
        warn("pcm-power CSV missing when capturing permissions; skipping restore")
    tmp_file = tempfile.NamedTemporaryFile("w", delete=False, dir=str(pcm_path.parent), newline="")
    try:
        writer = csv.writer(tmp_file)
        writer.writerow(header1)
        writer.writerow(header2)
        writer.writerows(data_rows)
    finally:
        tmp_file.close()
    os.replace(tmp_file.name, pcm_path)
    if stat_info is not None:
        try:
            os.chmod(pcm_path, stat_info.st_mode & 0o777)
            if os.geteuid() == 0:
                os.chown(pcm_path, stat_info.st_uid, stat_info.st_gid)
        except OSError as exc:
            warn(f"failed to restore pcm-power CSV permissions: {exc}")

    with open(pcm_path, "r", newline="") as f:
        raw_lines = f.read().splitlines()
    audit_rows = list(csv.reader(raw_lines))
    audit_ok = True
    if len(audit_rows) < 2:
        error("write-back audit failed: insufficient header rows")
        audit_ok = False
    else:
        audit_header1 = list(audit_rows[0])
        audit_header2 = list(audit_rows[1])
        audit_data_rows = [list(row) for row in audit_rows[2:]]
        trimmed_header1 = audit_header1[:]
        trimmed_header2 = audit_header2[:]
        trimmed_data = [row[:] for row in audit_data_rows]
        while trimmed_header1 and trimmed_header2 and trimmed_header1[-1] == "" and trimmed_header2[-1] == "":
            trimmed_header1 = trimmed_header1[:-1]
            trimmed_header2 = trimmed_header2[:-1]
            trimmed_data = [row[:-1] if row else [] for row in trimmed_data]
        tail = trimmed_header2[-2:] if len(trimmed_header2) >= 2 else []
        header2_raw_line = raw_lines[1] if len(raw_lines) > 1 else ""
        if tail != ["Actual Watts", "Actual DRAM Watts"]:
            error(f"write-back audit failed: tail(header2)={trimmed_header2[-6:] if len(trimmed_header2) >= 6 else trimmed_header2}")
            error(f"header2_raw: {header2_raw_line}")
            audit_ok = False
        if audit_ok and trimmed_data:
            total_rows = len(trimmed_data)
            numeric_count = 0
            for row in trimmed_data:
                if len(row) < len(trimmed_header2):
                    row = row + [""] * (len(trimmed_header2) - len(row))
                if is_numeric(row[-2]) and is_numeric(row[-1]):
                    numeric_count += 1
            if total_rows:
                numeric_ratio = numeric_count / total_rows
            else:
                numeric_ratio = 1.0
            if numeric_ratio < 0.99:
                error(f"write-back audit failed: non-numeric cells found (count={total_rows - numeric_count})")
                error(f"header2_raw: {header2_raw_line}")
                audit_ok = False
    if audit_ok:
        ok(f"appended columns: Actual Watts, Actual DRAM Watts (rows={row_count}, cols={cols_after})")


if __name__ == "__main__":
    main()
PY

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
  log_debug "Launching Maya profiler (text=/local/data/results/id_20_3gram_llm_maya.txt, log=/local/data/results/id_20_3gram_llm_maya.log)"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)

  # Run the LLM script under Maya (Maya on CPU 5, workload on CPU 6)
  sudo -E cset shield --exec -- bash -lc '
  set -euo pipefail
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  maya_txt="/local/data/results/id_20_3gram_llm_maya.txt"
  maya_log="/local/data/results/id_20_3gram_llm_maya.log"

  # Start Maya on CPU 5 in background; capture PID immediately
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > "$maya_txt" 2>&1 &
  MAYA_PID=$!

  # Small startup delay to avoid cold-start hiccups
  sleep 1

  if ! kill -0 "$MAYA_PID" 2>/dev/null; then
    echo "[ERROR] Maya exited before startup"
    tail -n +1 "$maya_txt" || true
    exit 1
  fi

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
  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
    --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl \
    >> "$maya_log" 2>&1 || true

  if ! kill -0 "$MAYA_PID" 2>/dev/null; then
    echo "[ERROR] Maya exited during workload"
    tail -n +1 "$maya_txt" || true
    exit 1
  fi

  # Idempotent teardown with escalation and reap
  for sig in TERM KILL; do
    if kill -0 "$MAYA_PID" 2>/dev/null; then
      kill -s "$sig" "$MAYA_PID" 2>/dev/null || true
      timeout 5s bash -lc "while kill -0 $MAYA_PID 2>/dev/null; do sleep 0.2; done" || true
    fi
    kill -0 "$MAYA_PID" 2>/dev/null || break
  done
  wait_status=0
  if wait "$MAYA_PID" 2>/dev/null; then
    wait_status=0
  else
    wait_status=$?
  fi

  case "$wait_status" in
    0|137|143)
      ;;
    *)
      echo "[ERROR] Maya exited with status $wait_status"
      tail -n +1 "$maya_txt" || true
      exit "$wait_status"
      ;;
  esac
  '
  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_llm_maya.log
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
  log_debug "Launching toplev basic (CSV=/local/data/results/id_20_3gram_llm_toplev_basic.csv, log=/local/data/results/id_20_3gram_llm_toplev_basic.log)"
  idle_wait
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l3 -I '${TOPLEV_BASIC_INTERVAL_MS}' -v --no-multiplex \
    -A --per-thread --columns \
    --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_basic.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' &> /local/data/results/id_20_3gram_llm_toplev_basic.log
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_llm_toplev_basic.log
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
  log_debug "Launching toplev execution (CSV=/local/data/results/id_20_3gram_llm_toplev_execution.csv, log=/local/data/results/id_20_3gram_llm_toplev_execution.log)"
  idle_wait
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l1 -I '${TOPLEV_EXECUTION_INTERVAL_MS}' -v -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_execution.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' &> /local/data/results/id_20_3gram_llm_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_llm_toplev_execution.log
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
  log_debug "Launching toplev full (CSV=/local/data/results/id_20_3gram_llm_toplev_full.csv, log=/local/data/results/id_20_3gram_llm_toplev_full.log)"
  idle_wait
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I '${TOPLEV_FULL_INTERVAL_MS}' -v --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_full.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' >> /local/data/results/id_20_3gram_llm_toplev_full.log 2>&1
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_llm_toplev_full.log
  log_debug "Toplev full completed in ${toplev_full_runtime}s"
fi
echo

################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_20_3gram_llm_maya.txt → id_20_3gram_llm_maya.csv"
  log_debug "Converting Maya output to CSV"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
    /local/data/results/id_20_3gram_llm_maya.txt \
    > /local/data/results/id_20_3gram_llm_maya.csv
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
      done_llm_toplev_basic.log \
      done_llm_toplev_full.log \
      done_llm_toplev_execution.log \
      done_llm_maya.log \
      done_llm_pcm.log \
      done_llm_pcm_memory.log \
      done_llm_pcm_power.log \
      done_llm_pcm_pcie.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done_llm.log
log_debug "Wrote /local/data/results/done_llm.log"

rm -f /local/data/results/done_llm_toplev_basic.log \
      /local/data/results/done_llm_toplev_full.log \
      /local/data/results/done_llm_toplev_execution.log \
      /local/data/results/done_llm_maya.log \
      /local/data/results/done_llm_pcm.log \
      /local/data/results/done_llm_pcm_memory.log \
      /local/data/results/done_llm_pcm_power.log \
      /local/data/results/done_llm_pcm_pcie.log
log_debug "Removed intermediate done_* logs"

################################################################################
### 13. Clean up CPU shielding
################################################################################

sudo cset shield --reset || true
log_debug "cset shield reset issued"
