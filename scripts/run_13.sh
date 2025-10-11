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
IDTAG=${IDTAG:-id_13}
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

# Format seconds with adaptive units
secs_to_dhm() {
  local total=${1:-0}
  if (( total < 0 )); then
    total=$((-total))
  fi
  if (( total < 60 )); then
    printf '%ds' "${total}"
  elif (( total < 3600 )); then
    local minutes=$((total / 60))
    local seconds=$((total % 60))
    printf '%dm %ds' "${minutes}" "${seconds}"
  elif (( total < 86400 )); then
    local hours=$((total / 3600))
    local minutes=$(((total % 3600) / 60))
    printf '%dh %dm' "${hours}" "${minutes}"
  else
    local days=$((total / 86400))
    local hours=$(((total % 86400) / 3600))
    local minutes=$(((total % 3600) / 60))
    printf '%dd %dh %dm' "${days}" "${hours}" "${minutes}"
  fi
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
  if ! setsid bash -lc "exec ${cmd}" </dev/null >>"${logfile}" 2>&1 & then
    log_info "${name}: failed to launch"
    printf -v "${pid_var}" ''
    return 1
  fi

  local pid=$!
  if [[ -z ${pid} ]]; then
    log_info "${name}: failed to capture pid"
    printf -v "${pid_var}" ''
    return 1
  fi

  if ! taskset -cp "${TOOLS_CPU}" "${pid}" >/dev/null 2>&1; then
    log_info "${name}: unable to set affinity to CPU ${TOOLS_CPU}"
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
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
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
  log_debug "pcm-pcie completed in $(secs_to_dhm "$pcm_pcie_runtime")"
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
      '${PCM_INTERVAL_SEC}' -- \
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
  log_debug "pcm completed in $(secs_to_dhm "$pcm_runtime")"
fi

if $run_pcm_memory && ! $run_pcm_power; then
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
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
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
  log_debug "pcm-memory completed in $(secs_to_dhm "$pcm_mem_runtime")"
fi

if $run_pcm_power; then
  echo
  echo "----------------------------"
  echo "PCM-POWER"
  echo "----------------------------"
  log_debug "Launching pcm-power two-pass flow (CSV=${RESULT_PREFIX}_pcm_power.csv, log=${RESULT_PREFIX}_pcm_power.log, profiler CPU=${PCM_CPU}, workload CPU=${WORKLOAD_CPU})"
  idle_wait

  log_info "Starting two-pass pcm-power collection"

  PFX="${RESULT_PREFIX:-${IDTAG:-id_X}}"
  PFX="${PFX##*/}"
  PQOS_LOG="${LOGDIR}/pqos.log"
  TSTAT_LOG="${LOGDIR}/turbostat.log"
  PCM_MEMORY_LOG="${LOGDIR}/pcm_memory_dram.log"
  PQOS_CSV="${OUTDIR}/${PFX}_pqos.csv"
  PCM_MEMORY_CSV="${OUTDIR}/${PFX}_pcm_memory_dram.csv"
  turbostat_txt="${RESULT_PREFIX}_turbostat.txt"
  turbostat_csv="${RESULT_PREFIX}_turbostat.csv"

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
      if [[ ${cpu} == "${WORKLOAD_CPU}" || ${cpu} == "${TOOLS_CPU}" || ${cpu} == "${PCM_CPU}" ]]; then
        continue
      fi
      others_list+=("${cpu}")
    done
  fi
  if [[ ${#others_list[@]} -gt 0 ]]; then
    OTHERS=$(IFS=,; printf '%s' "${others_list[*]}")
  fi

  PASS1_START_TS=""
  PASS1_END_TS=""
  PASS2_START_TS=""
  PASS2_END_TS=""
  PQOS_PID=""
  TURBOSTAT_PID=""

  echo "Pass 1: pqos + pcm-power"
  sudo -n umount /sys/fs/resctrl >/dev/null 2>&1 || true
  sudo -n mount -t resctrl resctrl /sys/fs/resctrl >/dev/null 2>&1 || true
  sudo -n pqos -R >/dev/null 2>&1 || true

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
    printf -v PQOS_CMD "pqos -I -u csv -o %q -i %s -m %q" \
      "${PQOS_CSV}" "${PQOS_INTERVAL_TICKS}" "${PQOS_GROUPS}"
    {
      printf '[pqos] cmd: %s\n' "${PQOS_CMD}"
      printf '[pqos] groups: workload=%s others=%s\n' "${WORKLOAD_CPU}" "${OTHERS:-<none>}"
    } >>"${PQOS_LOG}"
    if spawn_sidecar "pqos" "${PQOS_CMD}" "${PQOS_LOG}" PQOS_PID; then
      log_info "pqos running for Pass 1"
      sleep 0.2
    fi
  else
    log_info "Skipping pqos sidecar (MBM not available)"
  fi

  PASS1_START_TS=$(date +%s)
  echo "pcm-power (Pass 1) started at: $(timestamp)"
  sudo sh -c '
    taskset -c '${PCM_CPU}' /local/tools/pcm/build/bin/pcm-power '${PCM_POWER_INTERVAL_SEC}' \
      -p 0 -a 10 -b 20 -c 30 \
      -csv='${RESULT_PREFIX}_pcm_power.csv' -- \
      taskset -c '${WORKLOAD_CPU}' /local/bci_code/id_1/main \
    >>'${RESULT_PREFIX}_pcm_power.log' 2>&1
  '
  PASS1_END_TS=$(date +%s)
  echo "pcm-power (Pass 1) finished at: $(timestamp)"

  if [[ -n ${PQOS_PID} ]]; then
    stop_gently "pqos" "${PQOS_PID}"
  fi

  pass1_runtime=$((PASS1_END_TS - PASS1_START_TS))

  idle_wait

  echo "Pass 2: pcm-memory + turbostat"
  sudo -n umount /sys/fs/resctrl >/dev/null 2>&1 || true

  printf -v TSTAT_CMD "turbostat --interval %s --quiet --enable Time_Of_Day_Seconds --show Time_Of_Day_Seconds,CPU,Busy%%,Bzy_MHz --out %q" \
    "${TS_INTERVAL}" "${turbostat_txt}"
  printf '[turbostat] cmd: %s\n' "${TSTAT_CMD}" >>"${TSTAT_LOG}"
  if spawn_sidecar "turbostat" "${TSTAT_CMD}" "${TSTAT_LOG}" TURBOSTAT_PID; then
    log_info "turbostat running for Pass 2"
  fi

  PCM_MEMORY_ENV_PREFIX="env"
  if [[ -n ${PCM_NO_MSR:-} ]]; then
    PCM_MEMORY_ENV_PREFIX+=" PCM_NO_MSR=${PCM_NO_MSR}"
  fi

  PASS2_START_TS=$(date +%s)
  echo "pcm-memory (Pass 2) started at: $(timestamp)"
  sudo sh -c '
    '${PCM_MEMORY_ENV_PREFIX}' taskset -c '${TOOLS_CPU}' /local/tools/pcm/build/bin/pcm-memory '${PCM_MEMORY_INTERVAL_SEC}' -nc -csv='${PCM_MEMORY_CSV}' -- \
      taskset -c '${WORKLOAD_CPU}' /local/bci_code/id_1/main \
    >>'${PCM_MEMORY_LOG}' 2>&1
  '
  PASS2_END_TS=$(date +%s)
  echo "pcm-memory (Pass 2) finished at: $(timestamp)"

  if [[ -n ${TURBOSTAT_PID} ]]; then
    stop_gently "turbostat" "${TURBOSTAT_PID}"
  fi

  pass2_runtime=$((PASS2_END_TS - PASS2_START_TS))

  printf 'pcm-power pass 1 runtime: %s\n' "$(secs_to_dhm "$pass1_runtime")" > "${OUTDIR}/done.log"
  printf 'pcm-power pass 2 runtime: %s\n' "$(secs_to_dhm "$pass2_runtime")" >> "${OUTDIR}/done.log"

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
import csv
import math
import os
import statistics
import tempfile
from collections import OrderedDict
from pathlib import Path
import re

EPS = 1e-9


def log(msg):
    print(f"[attrib] {msg}")


def warn(msg):
    print(f"[attrib][WARN] {msg}")


def error(msg):
    print(f"[attrib][ERROR] {msg}")


def ok(msg):
    print(f"[attrib][OK] {msg}")


def safe_float(value):
    if value is None:
        return math.nan
    try:
        return float(str(value).strip())
    except (ValueError, TypeError):
        return math.nan


def flatten_headers(header1, header2):
    width = max(len(header1), len(header2))
    top = list(header1) + [""] * (width - len(header1))
    bottom = list(header2) + [""] * (width - len(header2))
    merged = []
    for a, b in zip(top, bottom):
        a = (a or "").strip()
        b = (b or "").strip()
        if a and b:
            merged.append(f"{a} {b}")
        else:
            merged.append(a or b)
    return merged


def trim_trailing_empty_columns(header1, header2, rows):
    h1 = list(header1)
    h2 = list(header2)
    data = [list(row) for row in rows]
    while h1 and h2 and not (h1[-1].strip() or h2[-1].strip()):
        h1 = h1[:-1]
        h2 = h2[:-1]
        data = [row[:-1] if row else [] for row in data]
    return h1, h2, data


def ensure_width(row, width):
    if len(row) < width:
        row.extend([""] * (width - len(row)))
    return row


def parse_pcm_power(pcm_path):
    if not pcm_path.exists():
        error(f"pcm-power CSV missing at {pcm_path}")
        return None
    with open(pcm_path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        error("pcm-power CSV missing headers or data; aborting attribution")
        return None
    header1 = list(rows[0])
    header2 = list(rows[1]) if len(rows) > 1 else []
    data_rows = [list(row) for row in rows[2:]]
    header1, header2, data_rows = trim_trailing_empty_columns(header1, header2, data_rows)
    width = max(len(header2), max((len(row) for row in data_rows), default=0))
    header1 = header1 + [""] * (max(0, width - len(header1)))
    header2 = header2 + [""] * (max(0, width - len(header2)))
    for row in data_rows:
        ensure_width(row, width)
    try:
        watts_idx = max(idx for idx, value in enumerate(header2) if value.strip() == "Watts")
        dram_idx = max(idx for idx, value in enumerate(header2) if value.strip() == "DRAM Watts")
    except ValueError:
        error("required Watts or DRAM Watts column missing after normalization; aborting attribution")
        return None
    pkg_powers = []
    dram_powers = []
    for row in data_rows:
        pkg_value = safe_float(row[watts_idx])
        dram_value = safe_float(row[dram_idx])
        pkg_powers.append(0.0 if math.isnan(pkg_value) else max(pkg_value, 0.0))
        dram_powers.append(0.0 if math.isnan(dram_value) else max(dram_value, 0.0))
    return header1, header2, data_rows, pkg_powers, dram_powers


def parse_core_list(text):
    text = (text or "").replace('"', "").replace("[", "").replace("]", "").replace("{", "").replace("}", "").strip()
    if not text:
        return set()
    result = set()
    for part in text.split(","):
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
                rng = range(start, end + 1)
            else:
                rng = range(end, start + 1)
            result.update(rng)
        else:
            try:
                result.add(int(part))
            except ValueError:
                continue
    return result


def parse_pqos_means(path, workload_cpu):
    if not path.exists():
        warn(f"pqos CSV missing at {path}; assuming zero bandwidth")
        return 0.0, 0.0, 0
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        mbt_pattern = re.compile(r"mbt.*mb/s", re.IGNORECASE)
        mbl_pattern = re.compile(r"mbl.*mb/s", re.IGNORECASE)
        pqos_field = None
        for name in fieldnames:
            if mbt_pattern.search(name or ""):
                pqos_field = name
                break
        if pqos_field is None:
            for name in fieldnames:
                if mbl_pattern.search(name or ""):
                    pqos_field = name
                    break
        if pqos_field is None:
            warn("pqos MB* column not found; assuming zero bandwidth")
            return 0.0, 0.0, 0
        entries = OrderedDict()
        for row in reader:
            time_value = (row.get("Time") or "").strip()
            core_value = row.get("Core")
            if not time_value or core_value is None:
                continue
            mb_value = safe_float(row.get(pqos_field))
            if math.isnan(mb_value):
                continue
            core_set = parse_core_list(core_value)
            if not core_set:
                continue
            entries.setdefault(time_value, []).append({"core": frozenset(core_set), "mb": max(mb_value, 0.0)})
    if not entries:
        warn("pqos CSV contained no usable samples")
        return 0.0, 0.0, 0
    workload_core = frozenset({workload_cpu})
    totals = []
    workload_totals = []
    for samples in entries.values():
        total = 0.0
        workload = 0.0
        for entry in samples:
            value = entry["mb"]
            total += value
            if entry["core"] == workload_core:
                workload += value
        totals.append(total)
        workload_totals.append(workload)
    total_mean = statistics.fmean(totals) if totals else 0.0
    workload_mean = statistics.fmean(workload_totals) if workload_totals else 0.0
    return workload_mean, total_mean, len(totals)


def parse_pcm_memory_mean(path):
    if not path.exists():
        warn(f"pcm-memory CSV missing at {path}; assuming zero bandwidth")
        return 0.0, 0, False
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        warn("pcm-memory CSV missing headers; assuming zero bandwidth")
        return 0.0, 0, False
    header1 = rows[0]
    header2 = rows[1] if len(rows) > 1 else []
    flat_headers = flatten_headers(header1, header2)
    system_idx = None
    for idx, name in enumerate(flat_headers):
        lowered = (name or "").strip().lower()
        if lowered == "system memory":
            system_idx = idx
            break
    if system_idx is None:
        for idx, name in enumerate(flat_headers):
            lowered = (name or "").strip().lower()
            if "system" in lowered and "memory" in lowered and "skt" not in lowered:
                system_idx = idx
                break
    if system_idx is None:
        warn("pcm-memory System Memory column not found; assuming zero bandwidth")
        return 0.0, 0, False
    values = []
    for row in rows[2:]:
        if system_idx >= len(row):
            continue
        value = safe_float(row[system_idx])
        if math.isnan(value):
            continue
        values.append(max(value, 0.0))
    if not values:
        warn("pcm-memory CSV contained no usable System Memory samples")
        return 0.0, 0, False
    return statistics.fmean(values), len(values), True


def parse_turbostat_shares(path, workload_cpu):
    if not path.exists():
        warn(f"turbostat CSV missing at {path}; assuming zero CPU share")
        return []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        rows = []
        for row in reader:
            try:
                cpu = int((row.get("CPU") or "").strip())
                busy = float((row.get("Busy%") or "").strip())
                bzy = float((row.get("Bzy_MHz") or "").strip())
            except (ValueError, TypeError):
                continue
            rows.append({"cpu": cpu, "busy": busy, "bzy": bzy})
    if not rows:
        warn("turbostat CSV contained no usable samples")
        return []
    cpu_ids = sorted({entry["cpu"] for entry in rows})
    n_cpus = len(cpu_ids)
    if not n_cpus:
        return []
    shares = []
    index = 0
    total_rows = len(rows)
    while index + n_cpus <= total_rows:
        block = rows[index : index + n_cpus]
        index += n_cpus
        cpus_in_block = {entry["cpu"] for entry in block}
        if len(cpus_in_block) < max(1, math.ceil(0.8 * n_cpus)):
            continue
        total_weight = 0.0
        workload_weight = 0.0
        for entry in block:
            busy = max(entry["busy"], 0.0)
            mhz = max(entry["bzy"], 0.0)
            weight = (busy / 100.0) * mhz
            total_weight += weight
            if entry["cpu"] == workload_cpu:
                workload_weight += weight
        if total_weight > EPS:
            fraction = max(min(workload_weight / total_weight, 1.0), 0.0)
            shares.append(fraction)
    if not shares:
        warn("turbostat produced no complete CPU blocks; assuming zero CPU share")
    return shares


def main():
    outdir = os.environ.get("OUTDIR")
    idtag = os.environ.get("IDTAG")
    if not outdir or not idtag:
        error("OUTDIR or IDTAG not set; skipping attribution step")
        return
    base_dir = Path(outdir)
    result_prefix = os.environ.get("RESULT_PREFIX")
    pfx_source = result_prefix or idtag or "id_X"
    pfx = os.path.basename(pfx_source)

    def build_prefix_path(suffix: str) -> Path:
        if result_prefix:
            return Path(f"{result_prefix}{suffix}")
        return base_dir / f"{idtag}{suffix}"

    pcm_path = build_prefix_path("_pcm_power.csv")
    turbostat_path = build_prefix_path("_turbostat.csv")
    pqos_path = base_dir / f"{pfx}_pqos.csv"
    pcm_memory_path = base_dir / f"{pfx}_pcm_memory_dram.csv"

    workload_cpu_str = os.environ.get("WORKLOAD_CPU", "0")
    try:
        workload_cpu = int(workload_cpu_str)
    except ValueError:
        workload_cpu = 0

    log(
        "files: pcm={} ({}), turbostat={} ({}), pqos={} ({}), pcm-memory={} ({})".format(
            pcm_path,
            "exists" if pcm_path.exists() else "missing",
            turbostat_path,
            "exists" if turbostat_path.exists() else "missing",
            pqos_path,
            "exists" if pqos_path.exists() else "missing",
            pcm_memory_path,
            "exists" if pcm_memory_path.exists() else "missing",
        )
    )

    parsed = parse_pcm_power(pcm_path)
    if parsed is None:
        return
    header1, header2, data_rows, pkg_powers, dram_powers = parsed
    row_count = len(data_rows)
    log(f"pcm-power samples: {row_count}")

    pqos_workload_mean, pqos_total_mean, pqos_count = parse_pqos_means(pqos_path, workload_cpu)
    pcm_system_mean, pcm_count, pcm_system_found = parse_pcm_memory_mean(pcm_memory_path)
    turbostat_shares = parse_turbostat_shares(turbostat_path, workload_cpu)
    cpu_share_mean = statistics.fmean(turbostat_shares) if turbostat_shares else 0.0

    if not pcm_system_found:
        pcm_system_mean = pqos_total_mean
        log(
            "pcm-memory system mean unavailable; falling back to pqos total mean {:.3f}".format(
                pqos_total_mean
            )
        )

    share_mean = (pqos_workload_mean / pqos_total_mean) if pqos_total_mean > EPS else 0.0
    share_mean = max(min(share_mean, 1.0), 0.0)
    g_mean = max(pcm_system_mean - pqos_total_mean, 0.0)
    w_attrib_mean = pqos_workload_mean + share_mean * g_mean

    log(
        "pqos means: workload={:.3f} MB/s, all={:.3f} MB/s (samples={})".format(
            pqos_workload_mean,
            pqos_total_mean,
            pqos_count,
        )
    )
    log(
        "pcm-memory system mean: {:.3f} MB/s (samples={})".format(
            pcm_system_mean,
            pcm_count,
        )
    )
    log(
        "derived DRAM share: share_mean={:.4f}, G_mean={:.3f}, workload_attrib_mean={:.3f}".format(
            share_mean,
            g_mean,
            w_attrib_mean,
        )
    )
    log(
        "turbostat CPU share: mean={:.4f} (chunks={})".format(
            cpu_share_mean,
            len(turbostat_shares),
        )
    )

    pkg_actuals = [pkg * cpu_share_mean for pkg in pkg_powers]
    dram_actuals = [dram * share_mean for dram in dram_powers]

    header1 = list(header1)
    header2 = list(header2)
    data_rows = [list(row) for row in data_rows]
    header1.extend(["", ""])
    header2.extend(["Actual Watts", "Actual DRAM Watts"])

    for row, pkg_value, dram_value in zip(data_rows, pkg_actuals, dram_actuals):
        row.append(f"{pkg_value:.6f}")
        row.append(f"{dram_value:.6f}")

    stat_info = None
    try:
        stat_info = os.stat(pcm_path)
    except FileNotFoundError:
        pass

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

    ok(
        "appended Actual Watts / Actual DRAM Watts using cpu_share_mean={:.4f}, dram_share_mean={:.4f}".format(
            cpu_share_mean,
            share_mean,
        )
    )


if __name__ == "__main__":
    main()
PY

  log_debug "pcm-power completed in $(secs_to_dhm "$pass1_runtime") (Pass 1) + $(secs_to_dhm "$pass2_runtime") (Pass 2)"

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
  MAYA_TXT_PATH="${RESULT_PREFIX}_maya.txt"
  MAYA_LOG_PATH="${RESULT_PREFIX}_maya.log"
  MAYA_DONE_PATH="${OUTDIR}/done_maya.log"
  maya_failed=false
  maya_status=0
  : > "$MAYA_LOG_PATH"
  : > "$MAYA_TXT_PATH"
  maya_subshell=$(cat <<'EOF'
set -euo pipefail
export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

exec >> "$MAYA_LOG_PATH" 2>&1
echo "[INFO] Maya wrapper started at $(date '+%Y-%m-%d %H:%M:%S')"

command -v /local/bci_code/tools/maya/Dist/Release/Maya >/dev/null || {
  echo "[ERROR] Maya binary not found"
  exit 127
}
test -x /local/bci_code/tools/maya/Dist/Release/Maya || {
  echo "[ERROR] Maya not executable"
  exit 126
}

# Start Maya on CPU 5 in background; capture PID immediately
taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
  > "$MAYA_TXT_PATH" 2>&1 &
MAYA_PID=$!

kill -0 "$MAYA_PID" 2>/dev/null || {
  echo "[ERROR] Maya failed to start"
  exit 1
}

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

workload_status=0
# Run workload on CPU 6
taskset -c 6 /local/tools/matlab/bin/matlab \
  -nodisplay -nosplash \
  -r "cd('/local/bci_code/id_13'); motor_movement('/local/data/S5_raw_segmented.mat', '/local/tools/fieldtrip/fieldtrip-20240916'); exit;" \
  >> "$MAYA_LOG_PATH" 2>&1 || workload_status=$?

if (( workload_status != 0 )); then
  echo "[WARN] Workload exited with status ${workload_status}"
fi

# Idempotent teardown with escalation and reap
for sig in TERM KILL; do
  if kill -0 "$MAYA_PID" 2>/dev/null; then
    kill -s "$sig" "$MAYA_PID" 2>/dev/null || true
    timeout 5s bash -lc "while kill -0 $MAYA_PID 2>/dev/null; do sleep 0.2; done" || true
  fi
  kill -0 "$MAYA_PID" 2>/dev/null || break
done

set +e
wait "$MAYA_PID"
wait_status=$?
set -e

if (( wait_status == 143 || wait_status == 15 )); then
  if (( workload_status == 0 )) && grep -q "Workload finished successfully" "$MAYA_LOG_PATH"; then
    echo "[INFO] Maya received SIGTERM after successful workload completion; treating as expected shutdown."
    wait_status=0
  fi
fi

if (( wait_status != 0 )); then
  {
    echo "==================== MAYA FAILURE ===================="
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Exit code: ${wait_status}"
    if [[ -s "$MAYA_TXT_PATH" ]]; then
      echo "[INFO] Maya output preserved at ${MAYA_TXT_PATH}"
    else
      echo "[WARN] ${MAYA_TXT_PATH} missing or empty"
    fi
    echo "===================================================="
  } >> "$MAYA_LOG_PATH"
fi

exit "$wait_status"
EOF
)
  {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') Launching Maya wrapper command:"
    printf 'sudo -E cset shield --exec -- bash -lc %q\n' "$maya_subshell"
  } >> "$MAYA_LOG_PATH"
  if ! MAYA_TXT_PATH="$MAYA_TXT_PATH" MAYA_LOG_PATH="$MAYA_LOG_PATH" sudo -E cset shield --exec -- bash -lc "$maya_subshell" 2>>"$MAYA_LOG_PATH"; then
    maya_failed=true
    maya_status=$?
  fi

  if $maya_failed; then
    echo "Maya profiling failed with status ${maya_status}. See ${MAYA_LOG_PATH} for details."
    exit "$maya_status"
  fi

  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > "$MAYA_DONE_PATH"
  log_debug "Maya completed in $(secs_to_dhm "$maya_runtime")"
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
      -l3 -I '${TOPLEV_BASIC_INTERVAL_MS}' -v --no-multiplex \
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
  log_debug "Toplev basic completed in $(secs_to_dhm "$toplev_basic_runtime")"
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
      -l1 -I '${TOPLEV_EXECUTION_INTERVAL_MS}' -v -x, \
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
  log_debug "Toplev execution completed in $(secs_to_dhm "$toplev_execution_runtime")"
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
      -l6 -I '${TOPLEV_FULL_INTERVAL_MS}' -v --no-multiplex --all -x, \
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
  log_debug "Toplev full completed in $(secs_to_dhm "$toplev_full_runtime")"
fi
echo

################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  if (( maya_status != 0 )); then
    log_debug "Skipping Maya CSV conversion due to failure status ${maya_status}"
  elif [[ ! -s "$MAYA_TXT_PATH" ]]; then
    echo "[WARN] Maya output ${MAYA_TXT_PATH} is empty; skipping CSV conversion."
  else
    echo "Converting id_13_maya.txt → id_13_maya.csv"
    log_debug "Converting Maya output to CSV"
    awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
      "$MAYA_TXT_PATH" > "${RESULT_PREFIX}_maya.csv"
    log_debug "Maya CSV generated"
  fi
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
