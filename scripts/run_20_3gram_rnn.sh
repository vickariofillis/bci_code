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
IDTAG=${IDTAG:-id_20_3gram_rnn}
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
PFX="${RESULT_PREFIX:-${IDTAG:-id_20_3gram_rnn}}"
PFX="${PFX##*/}"

export PFX

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
workload_desc="ID-20 3gram RNN"

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

# Create placeholder logs whenever a tool is disabled so the final summary is
# predictable regardless of the chosen subset.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_rnn_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_rnn_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_rnn_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_rnn_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_rnn_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_rnn_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_rnn_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_rnn_pcm_pcie.log
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
  log_debug "Launching pcm-pcie (CSV=/local/data/results/id_20_3gram_rnn_pcm_pcie.csv, log=/local/data/results/id_20_3gram_rnn_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  # Standalone run: uses PCM_MEMORY_INTERVAL_SEC (independent of pcm-power cadence).
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_20_3gram_rnn_pcm_pcie.csv \
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_rnn_pcm_pcie.log
  log_debug "pcm-pcie completed in $(secs_to_dhm "$pcm_pcie_runtime")"
fi

if $run_pcm; then
  echo
  echo "----------------------------"
  echo "PCM"
  echo "----------------------------"
  log_debug "Launching pcm (CSV=/local/data/results/id_20_3gram_rnn_pcm.csv, log=/local/data/results/id_20_3gram_rnn_pcm.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_20_3gram_rnn_pcm.csv \
      '${PCM_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm.log 2>&1
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_rnn_pcm.log
  log_debug "pcm completed in $(secs_to_dhm "$pcm_runtime")"
fi

if $run_pcm_memory; then
  echo
  echo "----------------------------"
  echo "PCM-MEMORY"
  echo "----------------------------"
  log_debug "Launching pcm-memory (CSV=/local/data/results/id_20_3gram_rnn_pcm_memory.csv, log=/local/data/results/id_20_3gram_rnn_pcm_memory.log, profiler CPU=5, workload CPU=6)"
  idle_wait
  echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_20_3gram_rnn_pcm_memory.csv \
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_memory.log 2>&1
  pcm_mem_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_mem_runtime")" \
    > /local/data/results/done_rnn_pcm_memory.log
  log_debug "pcm-memory completed in $(secs_to_dhm "$pcm_mem_runtime")"
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
  PCM_MEMORY_PID=""
  PQOS_START_TS=""
  TSTAT_START_TS=""
  PCM_MEMORY_START_TS=""
  PQOS_STOP_TS=""
  TSTAT_STOP_TS=""
  PCM_MEMORY_STOP_TS=""
  PQOS_LOG="${LOGDIR}/pqos.log"
  TSTAT_LOG="${LOGDIR}/turbostat.log"
  PCM_MEMORY_LOG="${LOGDIR}/pcm_memory_sidecar.log"
  PQOS_CSV="${OUTDIR}/${PFX}_pqos.csv"
  SIDE_PMEM_CSV="${OUTDIR}/${PFX}_pcm_memory.csv"
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
    pqos_groups=("mbt:[${WORKLOAD_CPU}]")
    if [[ -n ${OTHERS} ]]; then
      pqos_groups+=("mbt:[${OTHERS}]")
    fi
    PQOS_GROUPS=$(IFS=';'; printf '%s' "${pqos_groups[*]}")
    printf -v PQOS_CMD "taskset -c %s pqos -I -u csv -o %q -i %s -m %q" \
      "${TOOLS_CPU}" "${PQOS_CSV}" "${PQOS_INTERVAL_TICKS}" "${PQOS_GROUPS}"
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

  PCM_MEMORY_BIN="/local/tools/pcm/build/bin/pcm-memory"
  if [[ -x ${PCM_MEMORY_BIN} ]]; then
    PCM_MEMORY_ENV_PREFIX=""
    if [[ -n ${PCM_NO_MSR:-} ]]; then
      PCM_MEMORY_ENV_PREFIX="env PCM_NO_MSR=${PCM_NO_MSR} "
    fi
    printf -v PCM_MEMORY_CMD "%staskset -c %s %q %s -nc -csv=%q" \
      "${PCM_MEMORY_ENV_PREFIX}" "${TOOLS_CPU}" "${PCM_MEMORY_BIN}" "${PCM_POWER_INTERVAL_SEC}" "${SIDE_PMEM_CSV}"
    printf '[pcm-memory] cmd: %s\n' "${PCM_MEMORY_CMD}" >>"${PCM_MEMORY_LOG}"
    # Intentional: use PCM_POWER_INTERVAL_SEC here to time-align pcm-memory with pcm-power windows.
    if spawn_sidecar "pcm-memory" "${PCM_MEMORY_CMD}" "${PCM_MEMORY_LOG}" PCM_MEMORY_PID; then
      PCM_MEMORY_START_TS=$(date +%s)
    fi
  else
    log_info "pcm-memory binary not found at ${PCM_MEMORY_BIN}; skipping sidecar"
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
      -csv=/local/data/results/id_20_3gram_rnn_pcm_power.csv -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_power.log 2>&1
  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))

  log_info "Stopping pcm-power sidecars"
  if [[ -n ${PCM_MEMORY_PID} ]]; then
    stop_gently "pcm-memory" "${PCM_MEMORY_PID}"
    PCM_MEMORY_STOP_TS=$(date +%s)
  fi
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
  if [[ -n ${PCM_MEMORY_START_TS} && -n ${PCM_MEMORY_STOP_TS} ]]; then
    pcm_memory_overlap=$((PCM_MEMORY_STOP_TS - PCM_MEMORY_START_TS))
    summary_lines+=("pcm-memory runtime (overlap with pcm-power): $(secs_to_dhm "$pcm_memory_overlap")")
  fi
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/${IDTAG}_pcm_power.done"
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/done_rnn_pcm_power.log"
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
import re
import tempfile
import time
from pathlib import Path

EPS = 1e-9
DEFAULT_INTERVAL = 0.5
ALIGN_TOLERANCE = 0.40
SYSTEM_REGEX = re.compile(r"(?i)\bsystem\b.*\bmemory\b.*\(mb/s\)")


def read_interval(name, fallback):
    raw = os.environ.get(name)
    if raw is None:
        return fallback
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return fallback
    return value if value > EPS else fallback


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
    if not cleaned:
        raise ValueError("empty timestamp")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(cleaned, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    raise ValueError(f"unable to parse datetime '{text}'")


def parse_pcm_timestamp(date_text, time_text, previous, interval):
    combined = f"{date_text.strip()} {time_text.strip()}".strip()
    if not combined:
        if previous is not None:
            return previous + interval, True
        return 0.0, True
    try:
        return parse_datetime(combined), False
    except ValueError:
        if previous is not None:
            return previous + interval, True
        return 0.0, True


def try_parse_datetime(text):
    cleaned = (text or "").strip()
    if not cleaned:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(cleaned, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    return None


def safe_float(value):
    try:
        if value is None:
            return math.nan
        return float(str(value).strip() or math.nan)
    except (TypeError, ValueError):
        return math.nan


def ensure_length(row, length):
    if len(row) < length:
        row.extend([""] * (length - len(row)))
    elif len(row) > length:
        del row[length:]
    return row


def normalize_headers(header1, header2, data_rows):
    target_len = max(len(header1), len(header2))
    ensure_length(header1, target_len)
    ensure_length(header2, target_len)
    for row in data_rows:
        ensure_length(row, target_len)
    return target_len


def drop_existing_actual(header1, header2, data_rows):
    drop_indices = [
        idx
        for idx, name in enumerate(header2)
        if name.strip() in {"Actual Watts", "Actual DRAM Watts"}
    ]
    if not drop_indices:
        return
    for idx in sorted(drop_indices, reverse=True):
        del header1[idx]
        del header2[idx]
        for row in data_rows:
            if len(row) > idx:
                del row[idx]
    normalize_headers(header1, header2, data_rows)


def load_pcm_power(pcm_path, interval):
    if not pcm_path.exists():
        error(f"pcm-power CSV missing at {pcm_path}; aborting attribution")
        return None
    with open(pcm_path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        error("pcm-power CSV missing headers or data; aborting attribution")
        return None
    header1 = list(rows[0])
    header2 = list(rows[1])
    data_rows = [list(row) for row in rows[2:]]
    row_count = len(data_rows)
    ghost = False
    if (
        header1
        and header2
        and header1[-1] == ""
        and header2[-1] == ""
        and row_count
    ):
        empty_cells = sum(1 for row in data_rows if not row or row[-1] == "")
        if empty_cells / row_count >= 0.95:
            ghost = True
    if ghost:
        header1 = header1[:-1]
        header2 = header2[:-1]
        data_rows = [row[:-1] if row else [] for row in data_rows]
    normalize_headers(header1, header2, data_rows)
    drop_existing_actual(header1, header2, data_rows)
    normalize_headers(header1, header2, data_rows)
    date_idx = next((i for i, v in enumerate(header2) if v.strip() == "Date"), None)
    time_idx = next((i for i, v in enumerate(header2) if v.strip() == "Time"), None)
    dram_indices = [i for i, v in enumerate(header2) if v.strip() == "DRAM Watts"]
    if date_idx is None or time_idx is None or not dram_indices:
        error("pcm-power CSV missing Date/Time/DRAM Watts columns; aborting attribution")
        return None
    dram_idx = dram_indices[-1]
    pcm_times = []
    dram_watts = []
    fallback_count = 0
    previous = None
    for row in data_rows:
        date_val = row[date_idx] if date_idx < len(row) else ""
        time_val = row[time_idx] if time_idx < len(row) else ""
        timestamp, used_fallback = parse_pcm_timestamp(date_val, time_val, previous, interval)
        if used_fallback:
            fallback_count += 1
        pcm_times.append(timestamp)
        previous = timestamp
        dram_value = safe_float(row[dram_idx]) if dram_idx < len(row) else math.nan
        dram_watts.append(0.0 if math.isnan(dram_value) else max(dram_value, 0.0))
    if fallback_count:
        warn(f"pcm timestamp fallbacks applied={fallback_count}")
    return {
        "header1": header1,
        "header2": header2,
        "rows": data_rows,
        "times": pcm_times,
        "dram": dram_watts,
        "ghost": ghost,
    }


def flatten_header_rows(rows, width):
    padded = []
    for row in rows:
        padded_row = list(row) + [""] * (width - len(row))
        padded.append(padded_row)
    flattened = []
    for idx in range(width):
        parts = []
        for row in padded:
            cell = row[idx].strip()
            if cell:
                parts.append(cell)
        flattened.append(" ".join(parts))
    return padded, flattened


def load_pcm_memory(memory_path, interval):
    if not memory_path.exists():
        log(f"pcm-memory CSV missing at {memory_path}; falling back to MBM-only attribution")
        return [], True
    with open(memory_path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 3:
        warn("pcm-memory CSV missing headers or data; falling back to MBM-only attribution")
        return [], True
    header_rows = rows[:2]
    data_rows = rows[2:]
    width = max(len(row) for row in header_rows)
    padded_headers, flattened = flatten_header_rows(header_rows, width)
    data_rows = [list(row) + [""] * (width - len(row)) for row in data_rows]
    system_idx = None
    for idx, label in enumerate(flattened):
        if SYSTEM_REGEX.search(label):
            system_idx = idx
            break
    if system_idx is None:
        warn("System memory column not found in pcm-memory CSV; falling back to MBM-only attribution")
        return [], True
    header2 = padded_headers[1] if len(padded_headers) > 1 else padded_headers[0]
    date_idx = next((i for i, v in enumerate(header2) if v.strip().lower() == "date"), None)
    time_idx = next((i for i, v in enumerate(header2) if v.strip().lower() == "time"), None)
    if date_idx is None or time_idx is None:
        warn("pcm-memory CSV missing Date/Time columns; falling back to MBM-only attribution")
        return [], True
    samples = []
    previous = None
    for row in data_rows:
        if system_idx >= len(row):
            continue
        system_val = safe_float(row[system_idx])
        if math.isnan(system_val):
            continue
        date_val = row[date_idx] if date_idx < len(row) else ""
        time_val = row[time_idx] if time_idx < len(row) else ""
        timestamp, _ = parse_pcm_timestamp(date_val, time_val, previous, interval)
        previous = timestamp
        samples.append({"time": timestamp, "value": max(system_val, 0.0)})
    return samples, False


def normalize_core_label(text):
    cleaned = (text or "").replace('"', "").strip()
    cleaned = cleaned.replace("mbt:", "").replace("mbl:", "").replace("mbr:", "")
    cleaned = cleaned.replace("[", "").replace("]", "").replace("{", "").replace("}", "")
    return cleaned.strip()


def classify_core(label, workload_cpu):
    if not label:
        return None
    lowered = label.lower()
    workload_str = str(workload_cpu)
    if lowered == workload_str:
        return "workload"
    if label.isdigit() and int(label) == workload_cpu:
        return "workload"
    if "other" in lowered:
        return "others"
    parts = [part.strip() for part in label.split(",") if part.strip()]
    if len(parts) == 1 and parts[0] == workload_str:
        return "workload"
    return "others"


def detect_mb_columns(fieldnames):
    if not fieldnames:
        return None
    for name in fieldnames:
        lower = (name or "").lower()
        if "mbt" in lower and "mb/s" in lower:
            return (name,), "mbt"
    left = right = None
    for name in fieldnames:
        lower = (name or "").lower()
        if "mbl" in lower and "mb/s" in lower:
            left = name
        elif "mbr" in lower and "mb/s" in lower:
            right = name
    if left and right:
        return (left, right), "mbl+mbr"
    return None


def load_pqos(pqos_path, workload_cpu):
    if not pqos_path.exists():
        log(f"pqos CSV missing at {pqos_path}; MBM totals unavailable")
        return []
    with open(pqos_path, newline="") as f:
        reader = csv.DictReader(f)
        columns = detect_mb_columns(reader.fieldnames)
        if columns is None:
            warn("pqos CSV missing MBT/MBL/MBR columns; MBM totals unavailable")
            return []
        mb_fields, mode = columns
        log(f"pqos MB column mode: {mode}")
        samples = {}
        for row in reader:
            row_map = {(k or "").strip().lower(): v for k, v in row.items()}
            time_raw = row_map.get("time")
            core_raw = row_map.get("core")
            if time_raw is None or core_raw is None:
                continue
            timestamp = try_parse_datetime(time_raw)
            if timestamp is None:
                continue
            total = 0.0
            seen_value = False
            for field in mb_fields:
                value = safe_float(row.get(field))
                if math.isnan(value):
                    continue
                total += value
                seen_value = True
            if not seen_value:
                continue
            label = classify_core(normalize_core_label(core_raw), workload_cpu)
            if label is None:
                continue
            sample = samples.setdefault(timestamp, {"time": timestamp, "W": None, "others": 0.0, "has_others": False})
            value = max(total, 0.0)
            if label == "workload":
                sample["W"] = (sample["W"] or 0.0) + value
            else:
                sample["others"] += value
                sample["has_others"] = True
    ordered = []
    for timestamp in sorted(samples):
        entry = samples[timestamp]
        entry["W"] = entry["W"] or 0.0
        if entry.get("has_others"):
            entry["A"] = entry["W"] + entry["others"]
        else:
            entry["A"] = entry["W"]
        ordered.append(entry)
    return ordered


def fill_series(values):
    n = len(values)
    forward = [None] * n
    backward = [None] * n
    last = None
    for idx, value in enumerate(values):
        if value is not None:
            last = value
        forward[idx] = last
    last = None
    for idx in range(n - 1, -1, -1):
        value = values[idx]
        if value is not None:
            last = value
        backward[idx] = last
    filled = []
    interpolated = 0
    for idx, value in enumerate(values):
        if value is not None:
            filled.append(value)
            continue
        candidates = [v for v in (forward[idx], backward[idx]) if v is not None]
        if len(candidates) == 2:
            filled_val = 0.5 * (candidates[0] + candidates[1])
            interpolated += 1
        elif candidates:
            filled_val = candidates[0]
            interpolated += 1
        else:
            filled_val = None
        filled.append(filled_val)
    return filled, interpolated


def nearest_sample(times, samples, target):
    if not times:
        return None, None
    idx = bisect.bisect_left(times, target)
    best_idx = None
    best_diff = None
    for cand in (idx - 1, idx):
        if 0 <= cand < len(times):
            diff = abs(times[cand] - target)
            if best_diff is None or diff < best_diff:
                best_idx = cand
                best_diff = diff
    if best_idx is None:
        return None, None
    return samples[best_idx], best_diff


def align_series(pcm_times, pqos_samples, memory_samples, interval):
    pqos_times = [entry["time"] for entry in pqos_samples]
    memory_times = [entry["time"] for entry in memory_samples]
    S = [None] * len(pcm_times)
    W = [None] * len(pcm_times)
    A = [None] * len(pcm_times)
    pqos_matches = 0
    memory_matches = 0
    for idx, start in enumerate(pcm_times):
        center = start + 0.5 * interval
        sample, diff = nearest_sample(pqos_times, pqos_samples, center)
        if sample is not None and (diff is not None and diff <= ALIGN_TOLERANCE):
            W[idx] = sample["W"]
            A[idx] = sample["A"]
            pqos_matches += 1
        sample, diff = nearest_sample(memory_times, memory_samples, center)
        if sample is not None and (diff is not None and diff <= ALIGN_TOLERANCE):
            S[idx] = sample["value"]
            memory_matches += 1
    return S, W, A, pqos_matches, memory_matches


def write_back(pcm_path, header1, header2, data_rows):
    try:
        stat_info = os.stat(pcm_path)
    except FileNotFoundError:
        stat_info = None
        warn("pcm-power CSV missing during write-back; skipping permission restore")
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
    with open(pcm_path, newline="") as f:
        audit_rows = list(csv.reader(f))
    if len(audit_rows) >= 2 and audit_rows[1]:
        tail = audit_rows[1][-1].strip()
        if tail != "Actual DRAM Watts":
            error(f"write-back audit failed: expected tail header 'Actual DRAM Watts', found '{tail}'")
    ok("write-back completed")


def compute_actual_watts(dram, S, W, A):
    actual = []
    for dram_w, sys_bw, w_bw, a_bw in zip(dram, S, W, A):
        sys_bw = sys_bw if sys_bw is not None else 0.0
        w_bw = w_bw if w_bw is not None else 0.0
        a_bw = a_bw if a_bw is not None else 0.0
        if sys_bw <= EPS:
            actual.append(0.0)
            continue
        gray = max(sys_bw - a_bw, 0.0)
        share = (w_bw / a_bw) if a_bw > EPS else 0.0
        workload_bw = w_bw + share * gray
        value = dram_w * (workload_bw / sys_bw)
        value = max(min(value, dram_w), 0.0)
        actual.append(value)
    return actual


def main():
    interval = read_interval("PCM_POWER_INTERVAL_SEC", DEFAULT_INTERVAL)
    pqos_interval = read_interval("PQOS_INTERVAL_SEC", interval)
    outdir = os.environ.get("OUTDIR")
    if not outdir:
        error("OUTDIR not set; skipping attribution")
        return
    pfx = os.environ.get("PFX") or os.environ.get("IDTAG") or "id_generic"
    workload_cpu_raw = os.environ.get("WORKLOAD_CPU", "0")
    try:
        workload_cpu = int(workload_cpu_raw)
    except ValueError:
        workload_cpu = 0
    base_dir = Path(outdir)
    pcm_path = base_dir / f"{pfx}_pcm_power.csv"
    pqos_path = base_dir / f"{pfx}_pqos.csv"
    memory_path = base_dir / f"{pfx}_pcm_memory.csv"
    log(
        "files: pcm={} ({}), pqos={} ({}), pcm-memory={} ({})".format(
            pcm_path,
            "exists" if pcm_path.exists() else "missing",
            pqos_path,
            "exists" if pqos_path.exists() else "missing",
            memory_path,
            "exists" if memory_path.exists() else "missing",
        )
    )
    log(
        "intervals: pcm={:.3f}s, pqos={:.3f}s, tolerance={:.2f}s".format(
            interval,
            pqos_interval,
            ALIGN_TOLERANCE,
        )
    )
    pcm = load_pcm_power(pcm_path, interval)
    if pcm is None:
        return
    pqos_samples = load_pqos(pqos_path, workload_cpu)
    memory_samples, memory_fallback = load_pcm_memory(memory_path, interval)
    S_series, W_series, A_series, pqos_matches, memory_matches = align_series(
        pcm["times"], pqos_samples, memory_samples, interval
    )
    row_count = len(pcm["rows"])
    if row_count:
        pqos_coverage = pqos_matches / row_count
        memory_coverage = memory_matches / row_count
        log(
            "alignment: pqos matched {}/{} ({:.1f}%), pcm-memory matched {}/{} ({:.1f}%)".format(
                pqos_matches,
                row_count,
                pqos_coverage * 100.0,
                memory_matches,
                row_count,
                memory_coverage * 100.0,
            )
        )
        if pqos_coverage < 0.95:
            warn(
                f"pqos in-window coverage = {pqos_matches}/{row_count} = {pqos_coverage * 100:.1f}% (<95%)"
            )
        if memory_samples and memory_coverage < 0.95:
            warn(
                f"pcm-memory in-window coverage = {memory_matches}/{row_count} = {memory_coverage * 100:.1f}% (<95%)"
            )
    pqos_available = any(value is not None for value in W_series) or any(
        value is not None for value in A_series
    )
    if not pqos_available:
        W_series = [0.0] * row_count
        A_series = [0.0] * row_count
    else:
        W_series, w_interp = fill_series(W_series)
        A_series, a_interp = fill_series(A_series)
        if any(value is None for value in W_series) or any(value is None for value in A_series):
            warn("pqos series still missing after fill; zeroing remaining gaps")
            W_series = [value if value is not None else 0.0 for value in W_series]
            A_series = [value if value is not None else 0.0 for value in A_series]
    if memory_fallback or not any(value is not None for value in S_series):
        if memory_fallback:
            log("pcm-memory unavailable; using MBM totals for system bandwidth")
        S_series = A_series[:]
    else:
        S_series, s_interp = fill_series(S_series)
        if any(value is None for value in S_series):
            warn("pcm-memory series still missing after fill; falling back to MBM totals for those entries")
            S_series = [value if value is not None else A_series[idx] for idx, value in enumerate(S_series)]
    actual = compute_actual_watts(pcm["dram"], S_series, W_series, A_series)
    mean_actual = sum(actual) / row_count if row_count else 0.0
    mean_dram = sum(pcm["dram"]) / row_count if row_count else 0.0
    if mean_actual > mean_dram + 1e-6:
        warn(
            f"mean Actual DRAM Watts ({mean_actual:.3f}) exceeds mean measured DRAM Watts ({mean_dram:.3f})"
        )
    else:
        log(
            "mean watts: measured={:.3f}W, attributed={:.3f}W".format(
                mean_dram,
                mean_actual,
            )
        )
    header1 = pcm["header1"]
    header2 = pcm["header2"]
    data_rows = pcm["rows"]
    header1.append("S0")
    header2.append("Actual DRAM Watts")
    for idx, row in enumerate(data_rows):
        row.append(f"{actual[idx]:.6f}")
    write_back(pcm_path, header1, header2, data_rows)


if __name__ == "__main__":
    main()

PY

  log_debug "pcm-power completed in $(secs_to_dhm "$pcm_power_runtime")"
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
  log_debug "Launching Maya profiler (text=/local/data/results/id_20_3gram_rnn_maya.txt, log=/local/data/results/id_20_3gram_rnn_maya.log)"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)

  # Run the RNN script under Maya (Maya on CPU 5, workload on CPU 6)
  MAYA_TXT_PATH="${RESULT_PREFIX}_maya.txt"
  MAYA_LOG_PATH="${RESULT_PREFIX}_maya.log"
  MAYA_DONE_PATH="${OUTDIR}/done_rnn_maya.log"
  maya_failed=false
  maya_status=0
  : > "$MAYA_LOG_PATH"
  : > "$MAYA_TXT_PATH"
  maya_subshell=$(cat <<'EOF'
set -euo pipefail
source /local/tools/bci_env/bin/activate
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
. path.sh
export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

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
taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
  --datasetPath=/local/data/ptDecoder_ctc \
  --modelPath=/local/data/speechBaseline4/ \
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
  log_debug "Launching toplev basic (CSV=/local/data/results/id_20_3gram_rnn_toplev_basic.csv, log=/local/data/results/id_20_3gram_rnn_toplev_basic.log)"
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
    -o /local/data/results/id_20_3gram_rnn_toplev_basic.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/ \
        >> /local/data/results/id_20_3gram_rnn_toplev_basic.log 2>&1
  '
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_rnn_toplev_basic.log
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
  log_debug "Launching toplev execution (CSV=/local/data/results/id_20_3gram_rnn_toplev_execution.csv, log=/local/data/results/id_20_3gram_rnn_toplev_execution.log)"
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
    -o /local/data/results/id_20_3gram_rnn_toplev_execution.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/
  ' &> /local/data/results/id_20_3gram_rnn_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_rnn_toplev_execution.log
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
  log_debug "Launching toplev full (CSV=/local/data/results/id_20_3gram_rnn_toplev_full.csv, log=/local/data/results/id_20_3gram_rnn_toplev_full.log)"
  idle_wait
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I '${TOPLEV_FULL_INTERVAL_MS}' --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev_full.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/ \
        >> /local/data/results/id_20_3gram_rnn_toplev_full.log 2>&1
  '
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_rnn_toplev_full.log
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
    echo "Converting id_20_3gram_rnn_maya.txt → id_20_3gram_rnn_maya.csv"
    log_debug "Converting Maya output to CSV"
    awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
      "$MAYA_TXT_PATH" \
      > "${RESULT_PREFIX}_maya.csv"
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
        done_rnn_toplev_basic.log \
        done_rnn_toplev_full.log \
      done_rnn_toplev_execution.log \
      done_rnn_maya.log \
      done_rnn_pcm.log \
      done_rnn_pcm_memory.log \
      done_rnn_pcm_power.log \
      done_rnn_pcm_pcie.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done_rnn.log
log_debug "Wrote /local/data/results/done_rnn.log"

rm -f /local/data/results/done_rnn_toplev_basic.log \
      /local/data/results/done_rnn_toplev_full.log \
      /local/data/results/done_rnn_toplev_execution.log \
      /local/data/results/done_rnn_maya.log \
      /local/data/results/done_rnn_pcm.log \
      /local/data/results/done_rnn_pcm_memory.log \
      /local/data/results/done_rnn_pcm_power.log \
      /local/data/results/done_rnn_pcm_pcie.log
log_debug "Removed intermediate done_* logs"

################################################################################
### 13. Clean up CPU shielding
################################################################################

sudo cset shield --reset || true
log_debug "cset shield reset issued"
