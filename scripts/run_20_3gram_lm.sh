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
TOOLS_CPU=${TOOLS_CPU:-5}
OUTDIR=${OUTDIR:-/local/data/results}
LOGDIR=${LOGDIR:-/local/logs}
IDTAG=${IDTAG:-id_20_3gram_lm}
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

# Expand /sys/devices/system/cpu/online (e.g., "0-3,6,8-9") into one integer per line.
expand_online() {
  local s; s="$(cat /sys/devices/system/cpu/online)"
  local out=() parts=()
  IFS=',' read -r -a parts <<< "$s"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      local a=${p%-*} b=${p#*-}
      for ((i=a; i<=b; i++)); do out+=("$i"); done
    else
      out+=("$p")
    fi
  done
  printf "%s\n" "${out[@]}"
}

# others_list_csv EXCLUDES any CPUs passed as arguments and returns a CSV list.
# Usage:
#   OTHERS="$(others_list_csv "$TOOLS_CPU" "$PCM_CPU" "$WORKLOAD_CPU")"
others_list_csv() {
  local exclude=("$@")
  local all=() out=()
  mapfile -t all < <(expand_online)
  for c in "${all[@]}"; do
    local skip=0
    for e in "${exclude[@]}"; do
      if [[ "$c" == "$e" ]]; then skip=1; break; fi
    done
    [[ $skip -eq 0 ]] && out+=("$c")
  done
  local IFS=,
  echo "${out[*]}"
}

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

print_section() {
  local title="$1"
  echo
  echo "################################################################################"
  printf '### %s\n' "$title"
  echo "################################################################################"
  echo
}

print_tool_header() {
  local title="$1"
  echo
  echo "--------------------------------------------------------------------------------"
  printf '### %s\n' "$title"
  echo "--------------------------------------------------------------------------------"
  echo
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
workload_desc="ID-20 3gram LM"

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

mount_resctrl_and_reset() {
  local pqos_log="${LOGDIR}/pqos.log"
  mkdir -p "${LOGDIR}"
  printf '[%s] mount_resctrl_and_reset: sudo umount /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
  sudo umount /sys/fs/resctrl >>"${pqos_log}" 2>&1 || true
  printf '[%s] mount_resctrl_and_reset: sudo mount -t resctrl resctrl /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
  sudo mount -t resctrl resctrl /sys/fs/resctrl >>"${pqos_log}" 2>&1
  printf '[%s] mount_resctrl_and_reset: sudo pqos -R\n' "$(timestamp)" >>"${pqos_log}"
  sudo pqos -R >>"${pqos_log}" 2>&1
  export RDT_IFACE=OS
  printf '[%s] mount_resctrl_and_reset: export RDT_IFACE=OS\n' "$(timestamp)" >>"${pqos_log}"
}

unmount_resctrl_quiet() {
  local pqos_log="${LOGDIR}/pqos.log"
  mkdir -p "${LOGDIR}"
  printf '[%s] unmount_resctrl_quiet: sudo umount /sys/fs/resctrl\n' "$(timestamp)" >>"${pqos_log}"
  sudo umount /sys/fs/resctrl >>"${pqos_log}" 2>&1 || true
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

  local proc_ready=false
  local attempt
  for attempt in {1..6}; do
    if [[ -e "/proc/${pid}" ]]; then
      proc_ready=true
      break
    fi
    sleep 0.05
  done
  if [[ ${proc_ready} != true ]]; then
    log_info "${name}: WARNING /proc/${pid} not available after wait"
  fi

  local pin_output=""
  local pin_rc=0
  pin_output="$(sudo -n taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)" || pin_rc=$?
  if (( pin_rc == 0 )); then
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_info "${name}: taskset -cp ${TOOLS_CPU} ${pid}: ${line}"
    done <<<"${pin_output}"
  else
    log_info "${name}: WARNING taskset -cp ${TOOLS_CPU} ${pid} failed (exit ${pin_rc})"
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      log_info "${name}: WARNING ${line}"
    done <<<"${pin_output}"
  fi

  ps -o pid,psr,comm -p "${pid}" 2>&1 | prefix_lines "${name}"
  taskset -cp "${pid}" 2>&1 | prefix_lines "${name}"
  printf -v "${pid_var}" '%s' "${pid}"
  return 0
}

spawn_tstat() {
  local cmd="$1" pidfile="$2" logfile="$3"
  local pid=""
  : >"${pidfile}"
  setsid bash -lc 'echo $$ > '"${pidfile}"'; exec '"${cmd}"'' </dev/null >>"${logfile}" 2>&1 &
  for i in {1..20}; do
    if [[ -s "${pidfile}" ]] && pid="$(<"${pidfile}")" && [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
      local pin_output="" pin_rc=0
      if pin_output="$(taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)"; then
        pin_rc=0
      else
        pin_rc=$?
        pin_output="$(sudo -n taskset -cp "${TOOLS_CPU}" "${pid}" 2>&1)" || pin_rc=$?
      fi
      if [[ -n ${pin_output} ]]; then
        printf '%s\n' "${pin_output}" >>"${logfile}"
      fi
      if (( pin_rc == 0 )); then
        while IFS= read -r line; do
          [[ -z ${line} ]] && continue
          log_info "turbostat: taskset -cp ${TOOLS_CPU} ${pid}: ${line}"
        done <<<"${pin_output}"
      else
        log_info "turbostat: WARNING taskset -cp ${TOOLS_CPU} ${pid} failed (exit ${pin_rc})"
        while IFS= read -r line; do
          [[ -z ${line} ]] && continue
          log_info "turbostat: WARNING ${line}"
        done <<<"${pin_output}"
      fi
      ps -o pid,psr,comm -p "${pid}" 2>&1 | tee -a "${logfile}" | prefix_lines "turbostat"
      taskset -cp "${pid}" 2>&1 | tee -a "${logfile}" | prefix_lines "turbostat"
      printf -v TURBOSTAT_PID '%s' "${pid}"
      return 0
    fi
    sleep 0.05
  done
  echo "[turbostat] failed to start" >>"${logfile}"
  return 1
}

stop_gently() {
  local name="$1"
  local pid="$2"

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} already stopped"
    return 0
  fi

  local wait_between=0.2

  log_info "Stopping ${name} pid=${pid} with SIGINT"
  kill -s INT "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} stopped after SIGINT"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGTERM"
  kill -s TERM "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if ! kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} stopped after SIGTERM"
    return 0
  fi

  log_info "Stopping ${name} pid=${pid} with SIGKILL"
  kill -s KILL "${pid}" 2>/dev/null || true
  sleep "${wait_between}"
  if kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} still running after SIGKILL"
  else
    log_info "${name}: pid=${pid} stopped after SIGKILL"
  fi
}

ensure_background_stopped() {
  local name="$1"
  local pid="$2"

  if [[ -z ${pid:-} ]]; then
    return 0
  fi

  if kill -0 "${pid}" 2>/dev/null; then
    log_info "${name}: pid=${pid} still running after cleanup"
    echo "${name} is still running (pid=${pid}); aborting" >&2
    exit 1
  fi
}

guard_no_pqos_active() {
  local existing=""

  if [[ -n ${PQOS_PID:-} ]] && kill -0 "${PQOS_PID}" 2>/dev/null; then
    existing="${PQOS_PID}"
  fi

  if [[ -z ${existing} ]]; then
    existing="$(pgrep -x pqos 2>/dev/null || true)"
  fi

  if [[ -n ${existing} ]]; then
    log_info "Guardrail: pqos already running (pid(s): ${existing})"
    echo "pqos must not be running before starting this pass" >&2
    exit 1
  fi
}

pids_pcm_power() {
  local pids=""
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local comm
    comm="$(sudo cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "pcm-power" ]]; then
      pids+="${pids:+ }$pid"
    fi
  done < <(sudo pgrep -d$'\n' -f '(^|/| )pcm-power( |$)' 2>/dev/null || true)
  echo "$pids"
}

pids_pcm_memory() {
  local pids=""
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local comm
    comm="$(sudo cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [[ "$comm" == "pcm-memory" ]]; then
      pids+="${pids:+ }$pid"
    fi
  done < <(sudo pgrep -d$'\n' -f '(^|/| )pcm-memory( |$)' 2>/dev/null || true)
  echo "$pids"
}

debug_list_pcm_procs() {
  local pp
  pp="$( {
      for p in $(pids_pcm_power); do echo "$p"; done
      for p in $(pids_pcm_memory); do echo "$p"; done
    } | tr ' ' '\n' | sort -u )"
  [[ -z "$pp" ]] && return 0
  echo "[DEBUG] Live PCM processes:"
  while IFS= read -r pid; do
    sudo ps -o pid,ppid,user,stat,etime,cmd= -p "$pid" 2>/dev/null || true
  done <<< "$pp"
}

cleanup_pcm_processes() {
  local targets
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  [[ -z "$targets" ]] && return 0

  echo "[INFO] Cleaning up stray PCM processes: $targets"
  while IFS= read -r pid; do sudo kill -INT "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 1
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  while IFS= read -r pid; do sudo kill -TERM "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 1
  targets="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  while IFS= read -r pid; do sudo kill -KILL "$pid" 2>/dev/null || true; done <<< "$targets"
  sleep 0.3
}

guard_no_pcm_active() {
  local pp
  pp="$( { echo "$(pids_pcm_power)"; echo "$(pids_pcm_memory)"; } | tr ' ' '\n' | sort -u )"
  if [[ -n "$pp" ]]; then
    log_info "Guardrail: pcm tools still running (pid(s): $pp)"
    debug_list_pcm_procs
    echo "pcm-power/pcm-memory must be stopped before launching pqos" >&2
    exit 1
  fi
}

start_turbostat() {
  local pass="$1" interval="$2" cpu="$3" outfile="$4" varname="$5"
  taskset -c "$cpu" turbostat \
    --interval "$interval" \
    --quiet \
    --show Time_Of_Day_Seconds,CPU,Busy%,Bzy_MHz \
    --out "$outfile" &

  local ts_pid=$!
  export "$varname"="$ts_pid"
  echo "[INFO] turbostat ${pass}: started pid=${ts_pid}"
}

stop_turbostat() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -INT "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -TERM "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if sudo kill -0 "$pid" 2>/dev/null; then
    sudo kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

trap '[[ -n ${TS_PID_PASS1:-} ]] && stop_turbostat "$TS_PID_PASS1"; [[ -n ${TS_PID_PASS2:-} ]] && stop_turbostat "$TS_PID_PASS2"; cleanup_pcm_processes || true' EXIT

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
print_section "1. Create results directory and placeholder logs"

cd /local; mkdir -p data/results
# Determine permissions target based on original invoking user
RUN_USER=${SUDO_USER:-$(id -un)}
RUN_GROUP=$(id -gn "$RUN_USER")
# Get ownership of /local and grant read+execute to everyone
chown -R "$RUN_USER":"$RUN_GROUP" /local
chmod -R a+rx /local
log_debug "Prepared /local/data/results (owner ${RUN_USER}:${RUN_GROUP})"

# Create placeholder logs for tools that aren't selected so that the final
# summary always lists every stage.
$run_toplev_basic || echo "Toplev-basic run skipped" > "${OUTDIR}/done_lm_toplev_basic.log"
$run_toplev_full || echo "Toplev-full run skipped" > "${OUTDIR}/done_lm_toplev_full.log"
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > "${OUTDIR}/done_lm_toplev_execution.log"
$run_maya || echo "Maya run skipped" > "${OUTDIR}/done_lm_maya.log"
$run_pcm || echo "PCM run skipped" > "${OUTDIR}/done_lm_pcm.log"
$run_pcm_memory || echo "PCM-memory run skipped" > "${OUTDIR}/done_lm_pcm_memory.log"
$run_pcm_power || {
  {
    echo "pcm-power runtime: N/A (pcm-power disabled)"
    echo "pcm-power Pass 1 runtime: N/A (pcm-power disabled)"
    echo "pcm-memory Pass 2 runtime: N/A (pcm-power disabled)"
    echo "pqos Pass 3 runtime: N/A (pcm-power disabled)"
  } > "${OUTDIR}/done_lm_pcm_power.log"
}
$run_pcm_pcie || echo "PCM-pcie run skipped" > "${OUTDIR}/done_lm_pcm_pcie.log"
log_debug "Placeholder completion markers generated for disabled profilers"

################################################################################
### 2. Configure and verify power settings
################################################################################
print_section "2. Configure and verify power settings"

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

print_tool_header "Power and frequency settings"
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
print_section "3. Change into the BCI project directory"

cd /local/tools/bci_project
log_debug "Changed working directory to /local/tools/bci_project"

################################################################################
### 4. PCM profiling
################################################################################

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  print_section "4. PCM profiling"

  sudo modprobe msr
  log_debug "Ensured msr kernel module is loaded for PCM"

  if $run_pcm_pcie; then
    print_tool_header "PCM-PCIE"
    log_debug "Launching pcm-pcie (CSV=/local/data/results/id_20_3gram_lm_pcm_pcie.csv, log=/local/data/results/id_20_3gram_lm_pcm_pcie.log, profiler CPU=5, workload CPU=6)"
    idle_wait
    echo "pcm-pcie started at: $(timestamp)"
    pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_20_3gram_lm_pcm_pcie.csv \
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
          --lmDir=/local/data/languageModel/ \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_lm_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > "${OUTDIR}/done_lm_pcm_pcie.log"
  log_debug "pcm-pcie completed in $(secs_to_dhm "$pcm_pcie_runtime")"
  fi

  if $run_pcm; then
    print_tool_header "PCM"
    log_debug "Launching pcm (CSV=/local/data/results/id_20_3gram_lm_pcm.csv, log=/local/data/results/id_20_3gram_lm_pcm.log, profiler CPU=5, workload CPU=6)"
    idle_wait
    echo "pcm started at: $(timestamp)"
    pcm_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_20_3gram_lm_pcm.csv \
      '${PCM_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
          --lmDir=/local/data/languageModel/ \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_lm_pcm.log 2>&1
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > "${OUTDIR}/done_lm_pcm.log"
  log_debug "pcm completed in $(secs_to_dhm "$pcm_runtime")"
  fi

  if $run_pcm_memory; then
    print_tool_header "PCM-MEMORY"
    log_debug "Launching pcm-memory (CSV=/local/data/results/id_20_3gram_lm_pcm_memory.csv, log=/local/data/results/id_20_3gram_lm_pcm_memory.log, profiler CPU=5, workload CPU=6)"
    idle_wait
    unmount_resctrl_quiet
    echo "pcm-memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_20_3gram_lm_pcm_memory.csv \
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
          --lmDir=/local/data/languageModel/ \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_lm_pcm_memory.log 2>&1
  pcm_mem_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_mem_runtime")" \
    > "${OUTDIR}/done_lm_pcm_memory.log"
  log_debug "pcm-memory completed in $(secs_to_dhm "$pcm_mem_runtime")"
  fi

  if $run_pcm_power; then
    print_tool_header "PCM-POWER"
    log_debug "Launching pcm-power (CSV=${RESULT_PREFIX}_pcm_power.csv, log=${RESULT_PREFIX}_pcm_power.log, profiler CPU=${PCM_CPU}, workload CPU=${WORKLOAD_CPU})"
    PFX="${RESULT_PREFIX:-${IDTAG:-id_X}}"
    PFX="${PFX##*/}"
    PQOS_PID=""
  TURBOSTAT_PID=""
  PQOS_LOG="${LOGDIR}/pqos.log"
  PCM_MEMORY_LOG="${LOGDIR}/pcm_memory_dram.log"
  PQOS_CSV="${OUTDIR}/${PFX}_pqos.csv"
  PCM_MEMORY_CSV="${OUTDIR}/${PFX}_pcm_memory_dram.csv"
  OTHERS=""

  pcm_power_overall_start=$(date +%s)

  TSTAT_PASS1_TXT="${RESULT_PREFIX}_turbostat_pass1.txt"
  TSTAT_PASS2_TXT="${RESULT_PREFIX}_turbostat_pass2.txt"
  PQOS_LOG="${LOGDIR}/pqos.log"
  PCM_MEMORY_LOG="${LOGDIR}/pcm_memory_dram.log"
  PQOS_CSV="${OUTDIR}/${PFX}_pqos.csv"
  PCM_MEMORY_CSV="${OUTDIR}/${PFX}_pcm_memory_dram.csv"

  : >"${PQOS_LOG}"
  : >"${PCM_MEMORY_LOG}"

  log_info "Pass 1: pcm-power + turbostat"
  guard_no_pqos_active

  start_turbostat "pass1" "${TS_INTERVAL}" "${TOOLS_CPU}" "${TSTAT_PASS1_TXT}" "TS_PID_PASS1"

  echo "pcm-power started at: $(timestamp)"
  pass1_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${PCM_CPU}"' /local/tools/pcm/build/bin/pcm-power '"${PCM_POWER_INTERVAL_SEC}"' \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_20_3gram_lm_pcm_power.csv -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \\
          --lmDir=/local/data/languageModel/ \\
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_lm_pcm_power.log 2>&1
  pass1_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pass1_runtime=$((pass1_end - pass1_start))

  stop_turbostat "${TS_PID_PASS1:-}"
  unset TS_PID_PASS1

  cleanup_pcm_processes

  pqos -I -R || true

  idle_wait

  log_debug "Note: Pass 2 runs pcm-memory as part of the attribution pipeline (required for DRAM attribution), even if --pcm-memory flag is false."
  log_info "Pass 2: pcm-memory + turbostat"
  guard_no_pqos_active

  start_turbostat "pass2" "${TS_INTERVAL}" "${TOOLS_CPU}" "${TSTAT_PASS2_TXT}" "TS_PID_PASS2"

  echo "pcm-memory started at: $(timestamp)"
  pass2_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm-memory '"${PCM_MEMORY_INTERVAL_SEC}"' -nc \
      -csv='"${PCM_MEMORY_CSV}"' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \\
          --lmDir=/local/data/languageModel/ \\
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
      "
  ' >>"${PCM_MEMORY_LOG}" 2>&1
  pass2_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pass2_runtime=$((pass2_end - pass2_start))

  stop_turbostat "${TS_PID_PASS2:-}"
  unset TS_PID_PASS2

  cleanup_pcm_processes

  pqos -I -R || true

  idle_wait

  log_info "Pass 3: pqos MBM only"
  cleanup_pcm_processes
  guard_no_pcm_active

  # Include all cores except PCM and WORKLOAD in OTHERS; keep TOOLS as a separate group
  OTHERS="$(others_list_csv "${PCM_CPU}" "${WORKLOAD_CPU}")"
  TOOLS_GROUP="${TOOLS_CPU}"
  log_info "PQoS others list: ${OTHERS:-<empty>}"

  # If TOOLS_GROUP already happens to be in OTHERS, don’t duplicate it
  if [[ -n "${OTHERS}" && ",${OTHERS}," == *",${TOOLS_GROUP},"* ]]; then
    MON_SPEC="all:${WORKLOAD_CPU};all:${OTHERS}"
  else
    if [[ -n "${OTHERS}" ]]; then
      MON_SPEC="all:${WORKLOAD_CPU};all:${OTHERS};all:${TOOLS_GROUP}"
    else
      MON_SPEC="all:${WORKLOAD_CPU};all:${TOOLS_GROUP}"
    fi
  fi

  mount_resctrl_and_reset

  pass3_start=$(date +%s)
  taskset -c "${TOOLS_CPU}" pqos -I -u csv -o "${PQOS_CSV}" -i "${PQOS_INTERVAL_TICKS}" \
    -m "${MON_SPEC}" >>"${PQOS_LOG}" 2>&1 &
  PQOS_PID=$!
  log_info "pqos pass3: started pid=${PQOS_PID} (groups workload=${WORKLOAD_CPU} others=${OTHERS:-<none>})"

  echo "pqos workload run started at: $(timestamp)"
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    bash -lc "
      source /local/tools/bci_env/bin/activate
      . path.sh
      export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
      taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \\
        --lmDir=/local/data/languageModel/ \\
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
    "
  ' >>/local/data/results/id_20_3gram_lm_pqos_workload.log 2>&1
  echo "pqos workload run finished at: $(timestamp)"
  pass3_end=$(date +%s)
  pass3_runtime=$((pass3_end - pass3_start))

  if [[ -n ${PQOS_PID} ]]; then
    kill -INT "${PQOS_PID}" 2>/dev/null || true
    wait "${PQOS_PID}" 2>/dev/null || true
  fi
  ensure_background_stopped "pqos pass3" "${PQOS_PID}"
  PQOS_PID=""

  unmount_resctrl_quiet

  pcm_power_overall_end=$(date +%s)
  pcm_power_runtime=$((pcm_power_overall_end - pcm_power_overall_start))

  declare -a summary_lines
  summary_lines=(
    "pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")"
    "pcm-power Pass 1 runtime: $(secs_to_dhm "$pass1_runtime")"
    "pcm-memory Pass 2 runtime: $(secs_to_dhm "$pass2_runtime")"
    "pqos Pass 3 runtime: $(secs_to_dhm "$pass3_runtime")"
  )
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/${IDTAG}_pcm_power.done"
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/done_lm_pcm_power.log"
  rm -f "${OUTDIR}/${IDTAG}_pcm_power.done"

  turbostat_txt="${RESULT_PREFIX}_turbostat.txt"
  turbostat_csv="${RESULT_PREFIX}_turbostat.csv"
  : > "${turbostat_txt}"
  if [[ -f ${TSTAT_PASS1_TXT} ]]; then
    cat "${TSTAT_PASS1_TXT}" >>"${turbostat_txt}"
  fi
  if [[ -f ${TSTAT_PASS2_TXT} ]]; then
    cat "${TSTAT_PASS2_TXT}" >>"${turbostat_txt}"
  fi

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
import statistics
import tempfile
import time
from pathlib import Path

EPS = 1e-9
DEFAULT_INTERVAL = 0.5
ALIGN_TOLERANCE_SEC = 0.40
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


PCM_POWER_INTERVAL_SEC = read_interval("PCM_POWER_INTERVAL_SEC", DEFAULT_INTERVAL)
PQOS_INTERVAL_SEC = read_interval("PQOS_INTERVAL_SEC", PCM_POWER_INTERVAL_SEC)
TURBOSTAT_INTERVAL_SEC = read_interval("TS_INTERVAL", DEFAULT_INTERVAL)
DELTA_T_SEC = PCM_POWER_INTERVAL_SEC


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


def compute_elapsed_series(values):
    if not values:
        return []
    origin = values[0]
    return [value - origin for value in values]


def atomic_write_csv(path, header, rows):
    parent = Path(path).parent
    parent.mkdir(parents=True, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=str(parent), newline="")
    try:
        with tmp:
            writer = csv.writer(tmp)
            writer.writerow(header)
            writer.writerows(rows)
        if os.path.getsize(tmp.name) == 0:
            raise IOError("temporary attrib file is empty")
        os.replace(tmp.name, path)
        with open(path, "r+") as f:
            os.fsync(f.fileno())
    finally:
        try:
            os.unlink(tmp.name)
        except FileNotFoundError:
            pass


def normalize_entry_times(entries, key):
    if not entries:
        return
    origin = entries[0].get(key)
    if origin is None:
        return
    for entry in entries:
        value = entry.get(key)
        if value is None:
            continue
        entry[key] = value - origin


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


def flatten_headers(header1, header2):
    width = max(len(header1), len(header2))
    result = []
    for idx in range(width):
        top = header1[idx].strip() if idx < len(header1) and header1[idx] else ""
        bottom = header2[idx].strip() if idx < len(header2) and header2[idx] else ""
        pieces = [piece for piece in (top, bottom) if piece]
        label = " ".join(pieces).strip()
        if not label:
            result.append("")
            continue
        label = re.sub(r"\s+", " ", label)
        if label.lower().startswith("system "):
            label = re.sub(r"\s*\(.*?\)\s*$", "", label)
        result.append(label)
    return result


def try_parse_pcm_memory_timestamp(date_text, time_text):
    combined = f"{date_text.strip()} {time_text.strip()}".strip()
    if not combined:
        return None
    for fmt in DATETIME_FORMATS:
        try:
            dt = datetime.datetime.strptime(combined, fmt)
            return time.mktime(dt.timetuple()) + dt.microsecond / 1_000_000.0
        except ValueError:
            continue
    return None


def drop_initial_pcm_memory_outliers(entries):
    if len(entries) < 2:
        return entries
    result = entries[:]
    dropped = 0
    while len(result) >= 2 and dropped < 2:
        tail_values = [entry["value"] for entry in result[1:] if entry["value"] > 0.0]
        if len(tail_values) < 4:
            break
        tail_values.sort()
        perc_index = max(0, min(len(tail_values) - 1, math.ceil(0.95 * len(tail_values)) - 1))
        perc95 = tail_values[perc_index]
        if perc95 <= 0.0:
            break
        first_value = result[0]["value"]
        if first_value > 50.0 * perc95:
            log(
                "pcm-memory: dropping initial outlier sample value={:.3f}, threshold={:.3f}".format(
                    first_value, perc95
                )
            )
            result.pop(0)
            dropped += 1
            continue
        break
    return result


def filter_pcm_memory_entries(entries, turbostat_times, pqos_times):
    if not entries:
        return entries
    bounds = []
    if turbostat_times:
        bounds.append((min(turbostat_times), max(turbostat_times)))
    if pqos_times:
        bounds.append((min(pqos_times), max(pqos_times)))
    if len(bounds) < 2:
        return entries
    start = max(b[0] for b in bounds)
    end = min(b[1] for b in bounds)
    if start > end:
        return entries
    lower = start - ALIGN_TOLERANCE_SEC
    upper = end + ALIGN_TOLERANCE_SEC
    filtered = [entry for entry in entries if lower <= entry["time"] <= upper]
    if len(filtered) != len(entries):
        log(
            "pcm-memory: trimmed samples to active window (before={}, after={})".format(
                len(entries), len(filtered)
            )
        )
    return filtered


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
            value = max(entry.get("mb", 0.0), 0.0)
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
    attrib_path = build_prefix_path("_attrib.csv")

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
    log(
        "intervals: pcm={:.4f}s, pqos={:.4f}s, turbostat={:.4f}s, pcm-memory(sidecar)={:.4f}s".format(
            PCM_POWER_INTERVAL_SEC,
            PQOS_INTERVAL_SEC,
            TURBOSTAT_INTERVAL_SEC,
            PCM_POWER_INTERVAL_SEC,
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

    power_header1 = header1[:]
    power_header2 = header2[:]
    power_data = [row[:] for row in data_rows]

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

    pcm_times = compute_elapsed_series(pcm_times)

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

    if turbostat_blocks:
        normalize_entry_times(turbostat_blocks, "tau")

    pqos_entries_raw = []
    pqos_field = None
    pcm_memory_entries = []
    if pqos_path.exists():
        with open(pqos_path, newline="") as f:
            reader = csv.DictReader(f)
            fieldnames = reader.fieldnames or []
            mbt_pattern = re.compile(r"mbt.*mb/s", re.IGNORECASE)
            mbl_pattern = re.compile(r"mbl.*mb/s", re.IGNORECASE)
            for name in fieldnames:
                if mbt_pattern.search(name):
                    pqos_field = name
                    break
            if pqos_field is None:
                for name in fieldnames:
                    if mbl_pattern.search(name):
                        pqos_field = name
                        break
            if pqos_field is None:
                error("pqos MB* column not found; skipping pqos attribution")
            else:
                log(f"pqos bandwidth column selected: {pqos_field}")
                for row in reader:
                    time_value = row.get("Time")
                    core_value = row.get("Core")
                    if time_value is None or core_value is None:
                        continue
                    mb_value = safe_float(row.get(pqos_field))
                    if math.isnan(mb_value):
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
                        "mb": max(mb_value, 0.0),
                    })

    if pcm_memory_path.exists():
        with open(pcm_memory_path, newline="") as f:
            pcm_rows = list(csv.reader(f))
        if len(pcm_rows) >= 2:
            mem_header_top = pcm_rows[0]
            mem_header_bot = pcm_rows[1] if len(pcm_rows) > 1 else []
            flat_headers = flatten_headers(mem_header_top, mem_header_bot)
            multi_header_detected = any(cell.strip() for cell in mem_header_top) and any(
                cell.strip() for cell in mem_header_bot
            )
            system_idx = None
            system_label = None
            for idx, name in enumerate(flat_headers):
                if name.strip().lower() == "system memory":
                    system_idx = idx
                    system_label = name.strip() or "System Memory"
                    break
            if system_idx is None:
                for idx, name in enumerate(flat_headers):
                    lowered = name.strip().lower()
                    if not lowered:
                        continue
                    if "system" in lowered and "memory" in lowered and "skt" not in lowered:
                        system_idx = idx
                        system_label = name.strip() or "System Memory"
                        break
            date_idx = next(
                (idx for idx, name in enumerate(flat_headers) if name.strip().lower() == "date"),
                None,
            )
            time_idx = next(
                (idx for idx, name in enumerate(flat_headers) if name.strip().lower() == "time"),
                None,
            )
            if system_idx is None:
                warn("pcm-memory System Memory column not found")
            elif date_idx is None or time_idx is None:
                warn("pcm-memory Date/Time columns not found")
            else:
                if multi_header_detected and system_label:
                    log(f"pcm-memory: multi-row header detected; using '{system_label}'")
                parsed_entries = []
                for row in pcm_rows[2:]:
                    if len(row) <= system_idx:
                        continue
                    raw_value = row[system_idx] if system_idx < len(row) else ""
                    value = safe_float(raw_value)
                    if math.isnan(value):
                        continue
                    date_value = row[date_idx] if date_idx < len(row) else ""
                    time_value = row[time_idx] if time_idx < len(row) else ""
                    sigma = try_parse_pcm_memory_timestamp(date_value, time_value)
                    if sigma is None:
                        continue
                    parsed_entries.append({"time": sigma, "value": max(value, 0.0)})
                parsed_entries.sort(key=lambda entry: entry["time"])
                pcm_memory_entries.extend(drop_initial_pcm_memory_outliers(parsed_entries))
        log(f"pcm-memory samples parsed: {len(pcm_memory_entries)}")

    if pcm_memory_entries:
        pcm_memory_entries.sort(key=lambda entry: entry["time"])
        normalize_entry_times(pcm_memory_entries, "time")

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
    if pqos_entries:
        normalize_entry_times(pqos_entries, "sigma")
    pqos_times = [sample["sigma"] for sample in pqos_entries]
    turbostat_times = [block["tau"] for block in turbostat_blocks]
    if pcm_memory_entries:
        pcm_memory_entries = filter_pcm_memory_entries(pcm_memory_entries, turbostat_times, pqos_times)
    pcm_memory_times = [entry["time"] for entry in pcm_memory_entries]
    pcm_memory_values = [entry["value"] for entry in pcm_memory_entries]

    cpu_share_raw = []
    pqos_core_raw = []
    pqos_total_raw = []
    system_memory_raw = []
    ts_in_window = ts_near = ts_miss = 0
    pqos_in_window = pqos_near = pqos_miss = 0
    system_in_window = system_near = system_miss = 0
    pqos_bandwidth_core_sum = 0.0
    pqos_bandwidth_other_sum = 0.0
    pqos_bandwidth_total_sum = 0.0
    pqos_bandwidth_sample_count = 0
    pqos_data_available = False
    system_data_available = False
    force_pkg_zero = not turbostat_times
    force_pqos_zero = not pqos_times
    force_system_zero = not pcm_memory_times

    ts_tolerance = max(PCM_POWER_INTERVAL_SEC, TURBOSTAT_INTERVAL_SEC) * 0.80
    pqos_tolerance = ALIGN_TOLERANCE_SEC
    pcm_memory_tolerance = ALIGN_TOLERANCE_SEC

    for idx, window_start in enumerate(pcm_times):
        window_end = window_start + DELTA_T_SEC
        window_center = window_start + 0.5 * DELTA_T_SEC

        if force_pkg_zero:
            cpu_share_raw.append(0.0)
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
                cpu_share_raw.append(None)
                ts_miss += 1
            else:
                if in_window:
                    ts_in_window += 1
                elif near:
                    ts_near += 1
                total_busy = 0.0
                workload_busy = 0.0
                for entry in block["rows"]:
                    busy = max(entry["busy"], 0.0)
                    total_busy += busy
                    if entry["cpu"] == workload_cpu:
                        workload_busy = busy
                fraction = clamp01(workload_busy / total_busy) if total_busy > EPS else 0.0
                cpu_share_raw.append(fraction)

        if force_pqos_zero:
            pqos_core_raw.append(0.0)
            pqos_total_raw.append(0.0)
            pqos_miss += 1
        else:
            selected_samples = pqos_entries_for_window(
                pqos_times,
                pqos_entries,
                window_start,
                window_end,
                PQOS_INTERVAL_SEC,
            )
            sample_entries = None
            if selected_samples:
                pqos_in_window += 1
                sample_entries = selected_samples
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
                    pqos_core_raw.append(None)
                    pqos_total_raw.append(None)
                    pqos_miss += 1
                else:
                    if in_window:
                        pqos_in_window += 1
                    elif near:
                        pqos_near += 1
                    sample_entries = [sample]
            if sample_entries is not None:
                core_bandwidth, total_bandwidth, sample_count = average_mbl_components(
                    sample_entries, workload_core_set
                )
                if sample_count:
                    pqos_data_available = True
                    core_bandwidth = max(core_bandwidth, 0.0)
                    total_bandwidth = max(total_bandwidth, 0.0)
                    other_bandwidth = max(total_bandwidth - core_bandwidth, 0.0)
                    pqos_core_raw.append(core_bandwidth)
                    pqos_total_raw.append(total_bandwidth)
                    pqos_bandwidth_core_sum += core_bandwidth * sample_count
                    pqos_bandwidth_other_sum += other_bandwidth * sample_count
                    pqos_bandwidth_total_sum += total_bandwidth * sample_count
                    pqos_bandwidth_sample_count += sample_count
                else:
                    pqos_core_raw.append(None)
                    pqos_total_raw.append(None)
                    pqos_miss += 1

        if force_system_zero:
            system_memory_raw.append(None)
            system_miss += 1
        else:
            sample_value, in_window, near = select_entry(
                pcm_memory_times,
                pcm_memory_values,
                window_start,
                window_end,
                window_center,
                pcm_memory_tolerance,
            )
            if sample_value is None:
                system_memory_raw.append(None)
                system_miss += 1
            else:
                if in_window:
                    system_in_window += 1
                elif near:
                    system_near += 1
                system_data_available = True
                system_memory_raw.append(max(sample_value, 0.0))

    log(f"alignment turbostat: in_window={ts_in_window}, near={ts_near}, miss={ts_miss}")
    log(f"alignment pqos: in_window={pqos_in_window}, near={pqos_near}, miss={pqos_miss}")
    log(
        f"alignment pcm-memory: in_window={system_in_window}, near={system_near}, miss={system_miss}"
    )
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
        system_coverage = system_in_window / row_count
        if ts_coverage < 0.95:
            warn(f"turbostat in-window coverage = {ts_in_window}/{row_count} = {ts_coverage * 100:.1f}% (<95%)")
        if pqos_coverage < 0.95:
            warn(f"pqos in-window coverage = {pqos_in_window}/{row_count} = {pqos_coverage * 100:.1f}% (<95%)")
        if pcm_memory_times and system_coverage < 0.95:
            warn(
                f"pcm-memory in-window coverage = {system_in_window}/{row_count} = {system_coverage * 100:.1f}% (<95%)"
            )

    cpu_share_filled, cpu_share_interpolated = fill_series(cpu_share_raw)
    pqos_core_filled, pqos_core_interpolated = fill_series(pqos_core_raw)
    pqos_total_filled, pqos_total_interpolated = fill_series(pqos_total_raw)
    system_memory_filled, system_memory_interpolated = fill_series(system_memory_raw)

    if not pqos_data_available:
        pqos_core_filled = [0.0] * row_count
        pqos_total_filled = [0.0] * row_count
        pqos_core_interpolated = pqos_total_interpolated = 0

    if not pcm_memory_times or not system_data_available:
        system_memory_filled = pqos_total_filled[:]
        system_memory_interpolated = 0

    def has_none(values):
        return any(v is None for v in values)

    if has_none(cpu_share_raw) or has_none(pqos_core_raw) or has_none(pqos_total_raw) or has_none(system_memory_raw):
        log("raw series contained missing entries prior to fill")

    cpu_share_missing_after = sum(1 for value in cpu_share_filled if value is None)
    core_missing_after = sum(1 for value in pqos_core_filled if value is None)
    total_missing_after = sum(1 for value in pqos_total_filled if value is None)
    system_missing_after = sum(1 for value in system_memory_filled if value is None)
    if cpu_share_missing_after or core_missing_after or total_missing_after or system_missing_after:
        error(
            "missing values remain after fill (cpu_share_missing={}, core_missing={}, total_missing={}, system_missing={})".format(
                cpu_share_missing_after,
                core_missing_after,
                total_missing_after,
                system_missing_after,
            )
        )

    log(
        f"fill cpu share: interpolated={cpu_share_interpolated}, first3={take_first(cpu_share_filled)}, last3={take_last(cpu_share_filled)}"
    )
    log(
        f"fill pqos workload: interpolated={pqos_core_interpolated}, first3={take_first(pqos_core_filled)}, last3={take_last(pqos_core_filled)}"
    )
    log(
        f"fill pqos total: interpolated={pqos_total_interpolated}, first3={take_first(pqos_total_filled)}, last3={take_last(pqos_total_filled)}"
    )
    log(
        f"fill system memory: interpolated={system_memory_interpolated}, first3={take_first(system_memory_filled)}, last3={take_last(system_memory_filled)}"
    )

    pkg_attr_values = []
    dram_attr_values = []
    non_dram_totals = []
    cpu_share_values = []
    mbm_share_values = []
    gray_values = []
    summary_rows = []

    for idx in range(row_count):
        pkg_total = pkg_powers[idx] if idx < len(pkg_powers) else 0.0
        dram_total = dram_powers[idx] if idx < len(dram_powers) else 0.0
        cpu_share_value = cpu_share_filled[idx] if idx < len(cpu_share_filled) else 0.0
        cpu_share_value = clamp01(cpu_share_value)
        workload_mb = pqos_core_filled[idx] if idx < len(pqos_core_filled) else 0.0
        total_mb = pqos_total_filled[idx] if idx < len(pqos_total_filled) else 0.0
        system_mb = system_memory_filled[idx] if idx < len(system_memory_filled) else total_mb
        if not math.isfinite(system_mb):
            system_mb = total_mb
        pkg_total = max(pkg_total, 0.0)
        workload_mb = max(workload_mb, 0.0)
        total_mb = max(total_mb, 0.0)
        system_mb = max(system_mb, 0.0)
        gray_mb = max(system_mb - total_mb, 0.0)
        share_mbm = (workload_mb / total_mb) if total_mb > EPS else 0.0
        share_mbm = clamp01(share_mbm)
        workload_attributed = workload_mb + share_mbm * gray_mb
        dram_total = max(dram_total, 0.0)
        non_dram_total = max(pkg_total - dram_total, 0.0)
        if system_mb > EPS:
            dram_attr = dram_total * (workload_attributed / system_mb)
        else:
            dram_attr = dram_total * share_mbm
        max_dram = max(dram_total, 0.0)
        dram_attr = max(0.0, min(dram_attr, max_dram))
        pkg_attr = non_dram_total * cpu_share_value
        max_pkg_non_dram = max(non_dram_total, 0.0)
        pkg_attr = max(0.0, min(pkg_attr, max_pkg_non_dram))

        pkg_attr_values.append(pkg_attr)
        dram_attr_values.append(dram_attr)
        non_dram_totals.append(non_dram_total)
        cpu_share_values.append(cpu_share_value)
        mbm_share_values.append(share_mbm)
        gray_values.append(gray_mb)
        summary_rows.append(
            [
                str(idx),
                f"{pkg_total:.6f}",
                f"{dram_total:.6f}",
                f"{system_mb:.6f}",
                f"{workload_mb:.6f}",
                f"{total_mb:.6f}",
                f"{cpu_share_value:.6f}",
                f"{share_mbm:.6f}",
                f"{gray_mb:.6f}",
                f"{workload_attributed:.6f}",
                f"{pkg_attr:.6f}",
                f"{dram_attr:.6f}",
            ]
        )

    if cpu_share_values:
        max_cpu_share = max(cpu_share_values)
        min_cpu_share = min(cpu_share_values)
        if min_cpu_share < -EPS:
            warn(f"cpu_share below 0 (min={min_cpu_share:.6f})")
        if max_cpu_share > 1.0 + EPS:
            warn(f"cpu_share above 1 (max={max_cpu_share:.6f})")

    if mbm_share_values:
        max_mbm_share = max(mbm_share_values)
        min_mbm_share = min(mbm_share_values)
        if min_mbm_share < -EPS:
            warn(f"mbm_share below 0 (min={min_mbm_share:.6f})")
        if max_mbm_share > 1.0 + EPS:
            warn(f"mbm_share above 1 (max={max_mbm_share:.6f})")

    if gray_values and min(gray_values) < -EPS:
        warn(f"gray bandwidth below 0 (min={min(gray_values):.6f})")

    pkg_attr_excess = []
    dram_attr_excess = []
    for idx in range(min(len(pkg_attr_values), len(pkg_powers))):
        limit_pkg = pkg_powers[idx]
        limit_non_dram = non_dram_totals[idx] if idx < len(non_dram_totals) else limit_pkg
        effective_limit = min(limit_pkg, limit_non_dram)
        if pkg_attr_values[idx] > effective_limit + EPS:
            pkg_attr_excess.append(pkg_attr_values[idx] - effective_limit)
    for idx in range(min(len(dram_attr_values), len(dram_powers))):
        if dram_attr_values[idx] > dram_powers[idx] + EPS:
            dram_attr_excess.append(dram_attr_values[idx] - dram_powers[idx])
    if pkg_attr_excess:
        warn(f"pkg_attr exceeds non-DRAM limit (max_excess={max(pkg_attr_excess):.6f})")
    if dram_attr_excess:
        warn(f"dram_attr exceeds dram_total (max_excess={max(dram_attr_excess):.6f})")

    mean_pkg_total = statistics.mean(pkg_powers) if pkg_powers else 0.0
    mean_dram_total = statistics.mean(dram_powers) if dram_powers else 0.0
    mean_non_dram_total = statistics.mean(non_dram_totals) if non_dram_totals else 0.0
    mean_pkg_attr = statistics.mean(pkg_attr_values) if pkg_attr_values else 0.0
    mean_dram_attr = statistics.mean(dram_attr_values) if dram_attr_values else 0.0
    mean_gray = statistics.mean(gray_values) if gray_values else 0.0
    if mean_pkg_attr > mean_pkg_total + EPS:
        warn(
            f"mean Actual_Watts ({mean_pkg_attr:.3f}) exceeds mean pcm-power Watts ({mean_pkg_total:.3f})"
        )
    if mean_pkg_attr > mean_non_dram_total + EPS:
        warn(
            f"mean Actual_Watts ({mean_pkg_attr:.3f}) exceeds mean non-DRAM power ({mean_non_dram_total:.3f})"
        )
    if mean_dram_attr > mean_dram_total + EPS:
        warn(
            f"mean Actual_DRAM_Watts ({mean_dram_attr:.3f}) exceeds mean pcm-power DRAM Watts ({mean_dram_total:.3f})"
        )
    log(
        "ATTRIB mean: pkg_total={:.3f}, dram_total={:.3f}, pkg_attr(Actual Watts)={:.3f}, "
        "dram_attr(Actual DRAM Watts)={:.3f}, gray_MBps={:.3f}".format(
            mean_pkg_total,
            mean_dram_total,
            mean_pkg_attr,
            mean_dram_attr,
            mean_gray,
        )
    )

    log(
        f"fill pkg attribution: first3={take_first(pkg_attr_values)}, last3={take_last(pkg_attr_values)}"
    )
    log(
        f"fill dram attribution: first3={take_first(dram_attr_values)}, last3={take_last(dram_attr_values)}"
    )

    summary_header = [
        "sample",
        "pkg_watts_total",
        "dram_watts_total",
        "imc_bw_MBps_total",
        "mbm_workload_MBps",
        "mbm_allcores_MBps",
        "cpu_share",
        "mbm_share",
        "gray_bw_MBps",
        "workload_attrib_bw_MBps",
        "pkg_attr_watts",
        "dram_attr_watts",
    ]
    atomic_write_csv(attrib_path, summary_header, summary_rows)
    log(
        f"wrote attribution summary: rows={len(summary_rows)} path={attrib_path} size={os.path.getsize(attrib_path)}B"
    )

    cols_before = len(power_header2)

    power_header1.extend(["S0", "S0"])
    power_header2.extend(["Actual Watts", "Actual DRAM Watts"])
    appended_headers = ["Actual Watts", "Actual DRAM Watts"]
    for idx in range(len(power_data)):
        non_dram_total = non_dram_totals[idx] if idx < len(non_dram_totals) else 0.0
        share_value = cpu_share_filled[idx] if idx < len(cpu_share_filled) else 0.0
        share_value = 0.0 if share_value is None else clamp01(share_value)
        max_non_dram = max(non_dram_total, 0.0)
        pkg_value = max(0.0, min(non_dram_total * share_value, max_non_dram))
        dram_value = dram_attr_values[idx] if idx < len(dram_attr_values) else 0.0
        dram_value = max(0.0, dram_value)
        if idx < len(pkg_attr_values):
            pkg_attr_values[idx] = pkg_value
        else:
            pkg_attr_values.append(pkg_value)
        if idx < len(dram_attr_values):
            dram_attr_values[idx] = dram_value
        else:
            dram_attr_values.append(dram_value)
        power_data[idx].append(f"{pkg_value:.6f}")
        power_data[idx].append(f"{dram_value:.6f}")

    cols_after = len(power_header2)
    log(f"writeback: pre_shape={len(power_data)}x{cols_before}, post_shape={len(power_data)}x{cols_after}")
    log(f"writeback: appended_headers={appended_headers}")
    log(
        "writeback: ghost_readded={}".format(
            "no (dropped empty column)" if ghost else "not needed"
        )
    )
    header2_tail_after = power_header2[-6:] if len(power_header2) >= 6 else power_header2[:]
    log(f"header2 tail after write: {header2_tail_after}")

    try:
        stat_info = os.stat(pcm_path)
    except FileNotFoundError:
        stat_info = None
        warn("pcm-power CSV missing when capturing permissions; skipping restore")
    tmp_file = tempfile.NamedTemporaryFile("w", delete=False, dir=str(pcm_path.parent), newline="")
    try:
        with tmp_file:
            writer = csv.writer(tmp_file)
            writer.writerow(power_header1)
            writer.writerow(power_header2)
            writer.writerows(power_data)
        if os.path.getsize(tmp_file.name) == 0:
            raise IOError("temporary power file is empty")
        os.replace(tmp_file.name, pcm_path)
    finally:
        try:
            os.unlink(tmp_file.name)
        except FileNotFoundError:
            pass
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

  log_debug "pcm-power completed in $(secs_to_dhm "$pcm_power_runtime")"
  fi

  echo "PCM profiling finished at: $(timestamp)"
  log_debug "PCM toolchain complete"
fi

################################################################################
### 5. Shield Core 8 (CPU 5) and Core 9 (CPU 6)
###    (reserve them for our measurement + workload)
################################################################################
print_section "5. Shield Core 8 (CPU 5) and Core 9 (CPU 6) (reserve them for our measurement + workload)"

print_tool_header "CPU shielding"
log_debug "Applying cset shielding to CPUs 5 and 6"
sudo cset shield --cpu 5,6 --kthread=on
echo

################################################################################
### 6. Maya profiling
################################################################################

if $run_maya; then
  print_section "6. Maya profiling"

  print_tool_header "MAYA"
  log_debug "Launching Maya profiler (text=/local/data/results/id_20_3gram_lm_maya.txt, log=/local/data/results/id_20_3gram_lm_maya.log)"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)

  # Run the LM script under Maya (Maya on CPU 5, workload on CPU 6)
  MAYA_TXT_PATH="${RESULT_PREFIX}_maya.txt"
  MAYA_LOG_PATH="${RESULT_PREFIX}_maya.log"
  MAYA_DONE_PATH="${OUTDIR}/done_lm_maya.log"
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
taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
  --lmDir=/local/data/languageModel/ \
  --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
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
  echo
fi

################################################################################
### 7. Toplev basic profiling
################################################################################

if $run_toplev_basic; then
  print_section "7. Toplev basic profiling"

  print_tool_header "TOPLEV BASIC"
  log_debug "Launching toplev basic (CSV=/local/data/results/id_20_3gram_lm_toplev_basic.csv, log=/local/data/results/id_20_3gram_lm_toplev_basic.log)"
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
    -o /local/data/results/id_20_3gram_lm_toplev_basic.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
        --lmDir=/local/data/languageModel/ \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        >> /local/data/results/id_20_3gram_lm_toplev_basic.log 2>&1
  '
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > "${OUTDIR}/done_lm_toplev_basic.log"
  log_debug "Toplev basic completed in $(secs_to_dhm "$toplev_basic_runtime")"
  echo
fi

################################################################################
### 8. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  print_section "8. Toplev execution profiling"

  print_tool_header "TOPLEV EXECUTION"
  log_debug "Launching toplev execution (CSV=/local/data/results/id_20_3gram_lm_toplev_execution.csv, log=/local/data/results/id_20_3gram_lm_toplev_execution.log)"
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
    -o /local/data/results/id_20_3gram_lm_toplev_execution.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
        --lmDir=/local/data/languageModel/ \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
  ' &> /local/data/results/id_20_3gram_lm_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > "${OUTDIR}/done_lm_toplev_execution.log"
  log_debug "Toplev execution completed in $(secs_to_dhm "$toplev_execution_runtime")"
  echo
fi

################################################################################
### 9. Toplev full profiling
################################################################################

if $run_toplev_full; then
  print_section "9. Toplev full profiling"

  print_tool_header "TOPLEV FULL"
  log_debug "Launching toplev full (CSV=/local/data/results/id_20_3gram_lm_toplev_full.csv, log=/local/data/results/id_20_3gram_lm_toplev_full.log)"
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
    -o /local/data/results/id_20_3gram_lm_toplev_full.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
        --lmDir=/local/data/languageModel/ \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
  ' >> /local/data/results/id_20_3gram_lm_toplev_full.log 2>&1
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > "${OUTDIR}/done_lm_toplev_full.log"
  log_debug "Toplev full completed in $(secs_to_dhm "$toplev_full_runtime")"
  echo
fi
################################################################################
### 10. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  print_section "10. Convert Maya raw output files into CSV"

  if (( maya_status != 0 )); then
    log_debug "Skipping Maya CSV conversion due to failure status ${maya_status}"
  elif [[ ! -s "$MAYA_TXT_PATH" ]]; then
    echo "[WARN] Maya output ${MAYA_TXT_PATH} is empty; skipping CSV conversion."
  else
    echo "Converting id_20_3gram_lm_maya.txt → id_20_3gram_lm_maya.csv"
    log_debug "Converting Maya output to CSV"
    awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
      "$MAYA_TXT_PATH" \
      > "${RESULT_PREFIX}_maya.csv"
    log_debug "Maya CSV generated"
  fi
  echo
fi

################################################################################
### 11. Signal completion for tmux monitoring
################################################################################
print_section "11. Signal completion for tmux monitoring"

echo "All done. Results are in /local/data/results/"
echo "Experiment finished at: $(timestamp)"
log_debug "Experiment complete; collating runtimes"

################################################################################
### 12. Write completion file with runtimes
################################################################################
print_section "12. Write completion file with runtimes"


completion_logs=(
  done_lm_toplev_basic.log
  done_lm_toplev_full.log
  done_lm_toplev_execution.log
  done_lm_maya.log
  done_lm_pcm.log
  done_lm_pcm_memory.log
  done_lm_pcm_power.log
  done_lm_pcm_pcie.log
)

final_done_path="${OUTDIR}/done.log"
: > "${final_done_path}"
for log in "${completion_logs[@]}"; do
  log_path="${OUTDIR}/${log}"
  if [[ -s "${log_path}" ]]; then
    if [[ -s "${final_done_path}" ]]; then
      printf '\n' >> "${final_done_path}"
    fi
    cat "${log_path}" >> "${final_done_path}"
  fi
done
log_debug "Wrote ${final_done_path}"

declare -a completion_log_paths=()
for log in "${completion_logs[@]}"; do
  completion_log_paths+=("${OUTDIR}/${log}")
done
rm -f "${completion_log_paths[@]}"
log_debug "Removed intermediate done_* logs"

################################################################################
### 13. Clean up CPU shielding
################################################################################
print_section "13. Clean up CPU shielding"


sudo cset shield --reset || true
log_debug "cset shield reset issued"
