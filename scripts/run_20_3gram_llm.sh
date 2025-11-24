#!/bin/bash
# Strengthened error handling: propagate ERR into functions/subshells
set -Eeuo pipefail
set -o errtrace
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

trap on_error ERR

################################################################################
### 0. Initialize environment (logging, CLI parsing, helpers)
################################################################################

# Detect help requests early so we can show usage without side effects.
# request_help tracks whether -h/--help was provided to skip initialization work.
request_help=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      # Exit early when help is requested to keep usage output readable.
      request_help=true
      break
      ;;
  esac
done

# Preserve the original argv for debug logging later in the script.
ORIGINAL_ARGS=("$@")

# Shared environment knobs. Each variable can be overridden by the caller.
# - WORKLOAD_CPU / TOOLS_CPU: default CPU affinity for the workload and profiling tools.
# - OUTDIR / LOGDIR: directories for experiment data and aggregated logs.
# - IDTAG: identifier used to namespace output files.
# - *_INTERVAL_* / TS_INTERVAL / PQOS_INTERVAL_TICKS: sampler cadences in seconds or PQoS ticks.

WORKLOAD_CPU=${WORKLOAD_CPU:-6}
TOOLS_CPU=${TOOLS_CPU:-5}
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
PREFETCH_SPEC="${PREFETCH_SPEC:-}"
PF_SNAPSHOT_OK=false

# Default resctrl/LLC policy knobs. These govern the cache-isolation helpers.
# - WORKLOAD_CORE_DEFAULT / TOOLS_CORE_DEFAULT: fallback CPU selections for isolation.
# - RDT_GROUP_*: resctrl group names for workload vs. background traffic.
# - LLC_*: bookkeeping flags for exclusive cache allocation.
WORKLOAD_CORE_DEFAULT=${WORKLOAD_CORE_DEFAULT:-6}
TOOLS_CORE_DEFAULT=${TOOLS_CORE_DEFAULT:-5}
RDT_GROUP_WL=${RDT_GROUP_WL:-wl_core}
RDT_GROUP_SYS=${RDT_GROUP_SYS:-sys_rest}
LLC_RESTORE_REGISTERED=false
LLC_EXCLUSIVE_ACTIVE=false
LLC_REQUESTED_PERCENT=100

# Ensure shared knobs are visible to child processes (e.g., inline Python blocks).
export WORKLOAD_CPU TOOLS_CPU OUTDIR LOGDIR IDTAG TS_INTERVAL PQOS_INTERVAL_TICKS \
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
  "__GROUP_BREAK__"
  "--turbo|state|Set CPU Turbo Boost state (on/off; default: off)"
  "--cstates|state|Disable CPU idle states deeper than C1 (on/off; default: on)"
  "--pkgcap|watts|Set CPU package power cap in watts or 'off' to disable (default: off)"
  "--dramcap|watts|Set DRAM power cap in watts or 'off' to disable (default: off)"
  "--llc|percent|Reserve exclusive LLC percentage for the workload core (default: 100)"
  "--corefreq|ghz|Pin CPUs to the specified frequency in GHz or 'off' to disable pinning (default: 2.4)"
  "--uncorefreq|ghz|Pin uncore (ring/LLC) frequency to this value in GHz (e.g., 2.0)"
  "--prefetcher|on/off or 4bits|Hardware prefetchers for the workload core only. on=all enabled, off=all disabled, or 4 bits (1=enable,0=disable) in order: L2_streamer L2_adjacent L1D_streamer L1D_IP"
  "__GROUP_BREAK__"
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
  "__GROUP_BREAK__"
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

# Parse tool selection arguments
run_toplev_basic=false
run_toplev_full=false
run_toplev_execution=false
run_maya=false
run_pcm=false
run_pcm_memory=false
run_pcm_power=false
run_pcm_pcie=false
pqos_logging_enabled=false
debug_state="off"
debug_enabled=false
cstates_request="${DISABLE_IDLE_STATES:-on}"
disable_idle_states=true
idle_state_snapshot=""
idle_states_modified=false
turbo_state="${TURBO_STATE:-off}"
pkgcap_w="${PKG_W:-off}"
dramcap_w="${DRAM_W:-off}"
corefreq_request=""
llc_percent_request=100
pin_corefreq_khz_default="${PIN_FREQ_KHZ:-2400000}"
UNCORE_FREQ_GHZ=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cstates=*)
      cstates_request="${1#--cstates=}"
      ;;
    --cstates)
      if [[ $# -gt 1 && ${2:-} != -* ]]; then
        cstates_request="$2"
        shift
      else
        cstates_request="on"
      fi
      ;;
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
    --pkgcap=*)
      pkgcap_w="${1#--pkgcap=}"
      ;;
    --pkgcap)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --pkgcap" >&2
        exit 1
      fi
      pkgcap_w="$2"
      shift
      ;;
    --dramcap=*)
      dramcap_w="${1#--dramcap=}"
      ;;
    --dramcap)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --dramcap" >&2
        exit 1
      fi
      dramcap_w="$2"
      shift
      ;;
    --corefreq=*)
      corefreq_request="${1#--corefreq=}"
      ;;
    --corefreq)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --corefreq" >&2
        exit 1
      fi
      corefreq_request="$2"
      shift
      ;;
    --uncorefreq=*)
      UNCORE_FREQ_GHZ="${1#--uncorefreq=}"
      ;;
    --uncorefreq)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --uncorefreq" >&2
        exit 1
      fi
      UNCORE_FREQ_GHZ="$2"
      shift
      ;;
    --prefetcher=*)
      PREFETCH_SPEC="${1#--prefetcher=}"
      ;;
    --prefetcher)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --prefetcher (use on/off or 4 bits like 1011)" >&2
        exit 1
      fi
      PREFETCH_SPEC="$2"
      shift
      ;;
    --llc=*)
      llc_percent_request="${1#--llc=}"
      ;;
    --llc)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --llc" >&2
        exit 1
      fi
      llc_percent_request="$2"
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

cstates_request="${cstates_request,,}"
case "$cstates_request" in
  on|yes|true)
    disable_idle_states=true
    ;;
  off|no|false)
    disable_idle_states=false
    ;;
  *)
    echo "Invalid value for --cstates: '$cstates_request' (expected 'on' or 'off')" >&2
    exit 1
    ;;
esac
log_debug "C-states request: ${cstates_request}"
log_debug_blank

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
  log_debug_blank
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
if [[ ${pkgcap_w,,} == off ]]; then
  pkg_cap_off=true
  PKG_W=""
else
  if [[ ! $pkgcap_w =~ ^[0-9]+$ ]]; then
    echo "Invalid value for --pkgcap: '$pkgcap_w' (expected integer watts or 'off')" >&2
    exit 1
  fi
  PKG_W="$pkgcap_w"
fi

dram_cap_off=false
if [[ ${dramcap_w,,} == off ]]; then
  dram_cap_off=true
  DRAM_W=""
else
  if [[ ! $dramcap_w =~ ^[0-9]+$ ]]; then
    echo "Invalid value for --dramcap: '$dramcap_w' (expected integer watts or 'off')" >&2
    exit 1
  fi
  DRAM_W="$dramcap_w"
fi

corefreq_pin_off=false
corefreq_request="${corefreq_request,,}"
if [[ -n $corefreq_request ]]; then
  if [[ $corefreq_request == off ]]; then
    corefreq_pin_off=true
    PIN_FREQ_KHZ=""
  elif [[ $corefreq_request =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    PIN_FREQ_KHZ="$(awk -v ghz="$corefreq_request" 'BEGIN{printf "%d", ghz*1000000}')"
  else
    echo "Invalid value for --corefreq: '$corefreq_request' (expected GHz as a number or 'off')" >&2
    exit 1
  fi
else
  if [[ ${pin_corefreq_khz_default,,} == off ]]; then
    corefreq_pin_off=true
    PIN_FREQ_KHZ=""
  else
    if [[ ! $pin_corefreq_khz_default =~ ^[0-9]+$ ]]; then
      echo "Invalid PIN_FREQ_KHZ default: '$pin_corefreq_khz_default'" >&2
      exit 1
    fi
    PIN_FREQ_KHZ="$pin_corefreq_khz_default"
  fi
fi

corefreq_target_ghz=""
corefreq_pin_display="off"
if ! $corefreq_pin_off; then
  corefreq_target_ghz="$(awk -v khz="$PIN_FREQ_KHZ" 'BEGIN{printf "%.3f", khz/1000000}')"
  corefreq_pin_display="${corefreq_target_ghz} GHz (${PIN_FREQ_KHZ} KHz)"
fi

uncorefreq_request_display="${UNCORE_FREQ_GHZ:-off}"
if [[ -n ${UNCORE_FREQ_GHZ:-} ]]; then
  case ${UNCORE_FREQ_GHZ,,} in
    off)
      UNCORE_FREQ_GHZ=""
      ;;
    *)
      if [[ ! ${UNCORE_FREQ_GHZ} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "Invalid value for --uncorefreq: '${UNCORE_FREQ_GHZ}' (expected GHz as a number or 'off')" >&2
        exit 1
      fi
      ;;
  esac
fi
uncorefreq_pin_display="off"
if [[ -n ${UNCORE_FREQ_GHZ:-} ]]; then
  uncorefreq_pin_display="${UNCORE_FREQ_GHZ} GHz"
fi

TOPLEV_BASIC_INTERVAL_MS=$(awk -v s="$TOPLEV_BASIC_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')
TOPLEV_EXECUTION_INTERVAL_MS=$(awk -v s="$TOPLEV_EXECUTION_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')
TOPLEV_FULL_INTERVAL_MS=$(awk -v s="$TOPLEV_FULL_INTERVAL_SEC" 'BEGIN{printf "%d", s * 1000}')

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
  log_debug "  CPU package cap: ${pkgcap_w}"
  log_debug "  DRAM cap: ${dramcap_w}"
  log_debug "  Core frequency request: ${corefreq_request:-default (${pin_corefreq_khz_default} KHz)}"
  log_debug "  Uncore frequency request: ${uncorefreq_request_display}"
  log_debug "  Prefetcher request: ${PREFETCH_SPEC:-(none)}"
  log_debug "  Interval toplev-basic: ${TOPLEV_BASIC_INTERVAL_SEC}s (${TOPLEV_BASIC_INTERVAL_MS} ms)"
  log_debug "  Interval toplev-execution: ${TOPLEV_EXECUTION_INTERVAL_SEC}s (${TOPLEV_EXECUTION_INTERVAL_MS} ms)"
  log_debug "  Interval toplev-full: ${TOPLEV_FULL_INTERVAL_SEC}s (${TOPLEV_FULL_INTERVAL_MS} ms)"
  log_debug "  Interval pcm: ${PCM_INTERVAL_SEC}s"
  log_debug "  Interval pcm-memory: ${PCM_MEMORY_INTERVAL_SEC}s"
  log_debug "  Interval pcm-power: ${PCM_POWER_INTERVAL_SEC}s"
  log_debug "  Interval pcm-pcie: ${PCM_PCIE_INTERVAL_SEC}s"
  log_debug "  Interval pqos: ${PQOS_INTERVAL_SEC}s (${PQOS_INTERVAL_TICKS} ticks)"
  log_debug "  Interval turbostat: ${TS_INTERVAL}s"
  log_debug "  Disable idle states deeper than C1: ${disable_idle_states}"
  log_debug "  LLC reservation request: ${llc_percent_request}%"
  log_debug "  Tools enabled -> toplev_basic=${run_toplev_basic}, toplev_full=${run_toplev_full}, toplev_execution=${run_toplev_execution}, maya=${run_maya}, pcm=${run_pcm}, pcm_memory=${run_pcm_memory}, pcm_power=${run_pcm_power}, pcm_pcie=${run_pcm_pcie}"
  log_debug_blank
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

ensure_idle_states_disabled

llc_core_setup_once --llc "${llc_percent_request}" --wl-core "${WORKLOAD_CPU}" --tools-core "${TOOLS_CPU}"

# Hardware prefetchers: apply only if user provided --prefetcher
PF_DISABLE_MASK=""
if [[ -n "${PREFETCH_SPEC:-}" ]]; then
  PF_DISABLE_MASK="$(pf_parse_spec_to_disable_mask "${PREFETCH_SPEC}")" \
    || { echo "[FATAL] Invalid --prefetcher value: ${PREFETCH_SPEC}"; exit 1; }
  pf_bits_summary="$(pf_bits_one_liner "${PF_DISABLE_MASK}")"
  log_debug "[PF] user pattern=${PREFETCH_SPEC} (1=enable,0=disable) -> ${pf_bits_summary}"

  if pf_snapshot_for_core "${WORKLOAD_CPU}"; then
    PF_SNAPSHOT_OK=true
  else
    log_warn "[PF] snapshot failed; will attempt to apply anyway"
  fi

  pf_apply_for_core "${WORKLOAD_CPU}" "${PF_DISABLE_MASK}"
  pf_verify_for_core "${WORKLOAD_CPU}" || log_warn "[PF] verify failed; state may be unchanged"
fi

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

trap_add '[[ -n ${TS_PID_PASS1:-} ]] && stop_turbostat "$TS_PID_PASS1"; [[ -n ${TS_PID_PASS2:-} ]] && stop_turbostat "$TS_PID_PASS2"; cleanup_pcm_processes || true; uncore_restore_snapshot || true; restore_idle_states_if_needed' EXIT
trap_add '[[ -n ${PREFETCH_SPEC:-} && ${PF_SNAPSHOT_OK:-false} == true ]] && pf_restore_for_core "${WORKLOAD_CPU}" || true' EXIT

################################################################################
### 1. Create results directory and placeholder logs
################################################################################
print_section "1. Create results directory and placeholder logs"

cd /local; mkdir -p data/results
# Determine permissions target based on original invoking user
RUN_USER=${SUDO_USER:-$(id -un)}
RUN_GROUP=$(id -gn "$RUN_USER")
# Get ownership of /local and grant read+execute to everyone (except super_run.sh)
mkdir -p /local/data/results /local/logs
for path in /local/data /local/logs; do
  [[ -d "$path" ]] || continue
  chown -R "$RUN_USER":"$RUN_GROUP" "$path" 2>/dev/null || true
  chmod -R a+rx "$path" 2>/dev/null || true
done
log_debug "Prepared /local/data/results (owner ${RUN_USER}:${RUN_GROUP})"

# Prepare placeholder logs for any disabled tool so that done.log contains an
# entry for every possible stage.
$run_toplev_basic || write_done_skipped "Toplev Basic" "${OUTDIR}/done_llm_toplev_basic.log"
$run_toplev_full || write_done_skipped "Toplev Full" "${OUTDIR}/done_llm_toplev_full.log"
$run_toplev_execution || \
  write_done_skipped "Toplev Execution" "${OUTDIR}/done_llm_toplev_execution.log"
$run_maya || write_done_skipped "Maya" "${OUTDIR}/done_llm_maya.log"
$run_pcm || write_done_skipped "PCM" "${OUTDIR}/done_llm_pcm.log"
$run_pcm_memory || write_done_skipped "PCM Memory" "${OUTDIR}/done_llm_pcm_memory.log"
$run_pcm_power || write_done_skipped "PCM Power" "${OUTDIR}/done_llm_pcm_power.log"
$run_pcm_pcie || write_done_skipped "PCM PCIE" "${OUTDIR}/done_llm_pcm_pcie.log"
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
echo "Requested core frequency pin: ${corefreq_pin_display}"
echo "Requested uncore frequency pin: ${uncorefreq_pin_display}"
log_debug "Power configuration requests -> turbo=${turbo_state}, pkg=${pkgcap_w}, dram=${dramcap_w}, corefreq_display=${corefreq_pin_display}, uncore_display=${uncorefreq_pin_display}"

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

# Build CPU list from configured pins and any literals in the script (non-fatal scan)
CPU_LIST="$(build_cpu_list)"
[ -n "${CPU_LIST}" ] || { echo "[ERROR] Failed to compute CPU_LIST"; exit 1; }

# Mandatory frequency pinning on the CPUs already used by this script
if ! $corefreq_pin_off; then
  log_debug "Applying frequency pinning to CPUs ${CPU_LIST} at ${PIN_FREQ_KHZ} KHz"
  IFS=',' read -r -a cpu_array <<< "${CPU_LIST}"
  for cpu in "${cpu_array[@]}"; do
    sudo cpupower -c "$cpu" frequency-set -g userspace >/dev/null 2>&1 || true
    sudo cpupower -c "$cpu" frequency-set -d "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
    sudo cpupower -c "$cpu" frequency-set -u "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
  done
  if ((${#cpu_array[@]} > 0)); then
    core_apply_pin_khz_softcheck "${PIN_FREQ_KHZ}" "${cpu_array[@]}"
  fi
else
  echo "Skipping frequency pinning (off)"
  log_debug "Frequency pinning skipped"
fi

if [[ -n ${UNCORE_FREQ_GHZ:-} ]]; then
  log_debug "Requesting uncore frequency pin: ${UNCORE_FREQ_GHZ} GHz"
  uncore_apply_pin_ghz "${UNCORE_FREQ_GHZ}"
fi

# Display resulting power, turbo, and frequency settings
# CPU_LIST was computed above; reuse for telemetry reporting
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

# RAPL package/DRAM caps (include sysfs + MSR views)
DOM=/sys/class/powercap/intel-rapl:0
rapl_report_combined_limits "Package" "$DOM" "constraint_0" 0x614
DRAM=/sys/class/powercap/intel-rapl:0:0
if [ -d "$DRAM" ]; then
  rapl_report_combined_limits "DRAM" "$DRAM" "constraint_0" 0x618
else
  echo "DRAM RAPL domain not present"
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
if uncore_available; then
  log_debug "Summarizing uncore limits (kHz)"
  for D in "${UNC_PATH}"/package_*_die_*; do
    [[ -d "$D" ]] || continue
    log_debug "$(basename "$D"): min=$(<"$D/min_freq_khz") max=$(<"$D/max_freq_khz") (initial_min=$(<"$D/initial_min_freq_khz") initial_max=$(<"$D/initial_max_freq_khz"))"
  done
fi
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
    print_tool_header "PCM PCIE"
    log_debug "Launching PCM PCIE (CSV=/local/data/results/id_20_3gram_llm_pcm_pcie.csv, log=/local/data/results/id_20_3gram_llm_pcm_pcie.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
    idle_wait
    echo "PCM PCIE started at: $(timestamp)"
    pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_20_3gram_llm_pcm_pcie.csv \
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  echo "PCM PCIE finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  write_done_runtime "PCM PCIE" "$(secs_to_dhm "$pcm_pcie_runtime")" "${OUTDIR}/done_llm_pcm_pcie.log"
  log_debug "PCM PCIE completed in $(secs_to_dhm "$pcm_pcie_runtime")"
  fi

  if $run_pcm; then
    print_tool_header "PCM"
    log_debug "Launching PCM (CSV=/local/data/results/id_20_3gram_llm_pcm.csv, log=/local/data/results/id_20_3gram_llm_pcm.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
    idle_wait
    echo "PCM started at: $(timestamp)"
    pcm_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_20_3gram_llm_pcm.csv \
      '${PCM_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm.log 2>&1
  pcm_end=$(date +%s)
  echo "PCM finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  write_done_runtime "PCM" "$(secs_to_dhm "$pcm_runtime")" "${OUTDIR}/done_llm_pcm.log"
  log_debug "PCM completed in $(secs_to_dhm "$pcm_runtime")"
  fi

  if $run_pcm_memory; then
    print_tool_header "PCM Memory"
    log_debug "Launching PCM Memory (CSV=/local/data/results/id_20_3gram_llm_pcm_memory.csv, log=/local/data/results/id_20_3gram_llm_pcm_memory.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
    idle_wait
    unmount_resctrl_quiet
    echo "PCM Memory started at: $(timestamp)"
  pcm_mem_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_20_3gram_llm_pcm_memory.csv \
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_memory.log 2>&1
  pcm_mem_end=$(date +%s)
  echo "PCM Memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  write_done_runtime "PCM Memory" "$(secs_to_dhm "$pcm_mem_runtime")" "${OUTDIR}/done_llm_pcm_memory.log"
  log_debug "PCM Memory completed in $(secs_to_dhm "$pcm_mem_runtime")"
  fi

  if $run_pcm_power; then
    pqos_logging_enabled=true
    print_tool_header "PCM Power"
    log_debug "Launching PCM Power (CSV=${RESULT_PREFIX}_pcm_power.csv, log=${RESULT_PREFIX}_pcm_power.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
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

  log_info "Pass 1: PCM Power + turbostat"
  guard_no_pqos_active

  start_turbostat "pass1" "${TS_INTERVAL}" "${TOOLS_CPU}" "${TSTAT_PASS1_TXT}" "TS_PID_PASS1"

  echo "PCM Power started at: $(timestamp)"
  pass1_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm-power '"${PCM_POWER_INTERVAL_SEC}"' \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_20_3gram_llm_pcm_power.csv -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \\
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \\
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>/local/data/results/id_20_3gram_llm_pcm_power.log 2>&1
  pass1_end=$(date +%s)
  echo "PCM Power finished at: $(timestamp)"
  pass1_runtime=$((pass1_end - pass1_start))

  stop_turbostat "${TS_PID_PASS1:-}"
  unset TS_PID_PASS1

  cleanup_pcm_processes

  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    log_debug "Skipping pqos -R because LLC exclusive allocation is active"
  else
    pqos -I -R || true
  fi

  idle_wait

  log_debug "Note: Pass 2 runs PCM Memory as part of the attribution pipeline (required for DRAM attribution), even if --pcm-memory flag is false."
  log_info "Pass 2: PCM Memory + turbostat"
  guard_no_pqos_active

  start_turbostat "pass2" "${TS_INTERVAL}" "${TOOLS_CPU}" "${TSTAT_PASS2_TXT}" "TS_PID_PASS2"

  log_debug "Launching PCM Memory pass2 (CSV=${PCM_MEMORY_CSV}, log=${PCM_MEMORY_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  echo "PCM Memory started at: $(timestamp)"
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
        taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \\
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \\
          --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
      "
  ' >>"${PCM_MEMORY_LOG}" 2>&1
  pass2_end=$(date +%s)
  echo "PCM Memory finished at: $(timestamp)"
  pass2_runtime=$((pass2_end - pass2_start))

  stop_turbostat "${TS_PID_PASS2:-}"
  unset TS_PID_PASS2

  cleanup_pcm_processes

  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    log_debug "Skipping pqos -R because LLC exclusive allocation is active"
  else
    pqos -I -R || true
  fi

  idle_wait

  log_info "Pass 3: pqos MBM only"
  cleanup_pcm_processes
  guard_no_pcm_active

  # Include all cores except TOOLS and WORKLOAD in OTHERS; keep TOOLS as a separate group
  OTHERS="$(others_list_csv "${TOOLS_CPU}" "${WORKLOAD_CPU}")"
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
  log_debug "Launching pqos pass3 (log=${PQOS_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU}, others cores=${OTHERS:-<none>})"

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
      taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \\
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \\
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
    "
  ' >>/local/data/results/id_20_3gram_llm_pqos_workload.log 2>&1
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

  pqos_logging_enabled=false

  pcm_power_overall_end=$(date +%s)
  pcm_power_runtime=$((pcm_power_overall_end - pcm_power_overall_start))

  declare -a summary_lines
  summary_lines=(
    "PCM Power runtime: $(secs_to_dhm "$pcm_power_runtime")"
    "PCM Power Pass 1 runtime: $(secs_to_dhm "$pass1_runtime")"
    "PCM Memory Pass 2 runtime: $(secs_to_dhm "$pass2_runtime")"
    "pqos Pass 3 runtime: $(secs_to_dhm "$pass3_runtime")"
  )
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/${IDTAG}_pcm_power.done"
  write_done_runtime "PCM Power" "$(secs_to_dhm "$pcm_power_runtime")" "${OUTDIR}/done_llm_pcm_power.log"
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

  python3 "${SCRIPT_DIR}/helper/metrics_attribution.py"

  log_debug "PCM Power completed in $(secs_to_dhm "$pcm_power_runtime")"
  fi

  echo "PCM profiling finished at: $(timestamp)"
  log_debug "PCM toolchain complete"
fi

################################################################################
### 5. Shield tool and workload CPUs
###    (reserve them for our measurement + workload)
################################################################################
print_section "5. Shield CPUs ${TOOLS_CPU} (tools) and ${WORKLOAD_CPU} (workload) (reserve them for our measurement + workload)"

print_tool_header "CPU shielding"
log_debug "Applying cset shielding to CPUs ${TOOLS_CPU} and ${WORKLOAD_CPU}"
sudo cset shield --cpu "${TOOLS_CPU},${WORKLOAD_CPU}" --kthread=on
echo

################################################################################
### 6. Maya profiling
################################################################################

if $run_maya; then
  print_section "6. Maya profiling"

  print_tool_header "MAYA"
  log_debug "Launching Maya profiler (text=/local/data/results/id_20_3gram_llm_maya.txt, log=/local/data/results/id_20_3gram_llm_maya.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)

  # Run the LLM script under Maya (Maya on TOOLS_CPU, workload on WORKLOAD_CPU)
  MAYA_TXT_PATH="${RESULT_PREFIX}_maya.txt"
  MAYA_LOG_PATH="${RESULT_PREFIX}_maya.log"
  MAYA_DONE_PATH="${OUTDIR}/done_llm_maya.log"
  maya_failed=false
  maya_status=0
  : > "$MAYA_LOG_PATH"
  : > "$MAYA_TXT_PATH"
  maya_subshell=$(cat <<'EOF'
set -euo pipefail

: "${TOOLS_CPU:?missing TOOLS_CPU}"
: "${WORKLOAD_CPU:?missing WORKLOAD_CPU}"
echo "[debug] pinning: TOOLS_CPU=${TOOLS_CPU} WORKLOAD_CPU=${WORKLOAD_CPU}"

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

# Start Maya on TOOLS_CPU in background; capture PID immediately
taskset -c "${TOOLS_CPU}" /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
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
# Run workload on WORKLOAD_CPU
taskset -c "${WORKLOAD_CPU}" python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
  --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
  --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl \
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
  write_done_runtime "Maya" "$(secs_to_dhm "$maya_runtime")" "$MAYA_DONE_PATH"
  log_debug "Maya completed in $(secs_to_dhm "$maya_runtime")"
  echo
fi

################################################################################
### 7. Toplev Basic profiling
################################################################################

if $run_toplev_basic; then
  print_section "7. Toplev Basic profiling"

  print_tool_header "Toplev Basic"
  log_debug "Launching Toplev Basic (CSV=/local/data/results/id_20_3gram_llm_toplev_basic.csv, log=/local/data/results/id_20_3gram_llm_toplev_basic.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Toplev Basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c '"${TOOLS_CPU}"' /local/tools/pmu-tools/toplev \
    -l3 -I '${TOPLEV_BASIC_INTERVAL_MS}' -v --no-multiplex \
    -A --per-thread --columns \
    --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_basic.csv -- \
      taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' &> /local/data/results/id_20_3gram_llm_toplev_basic.log
  toplev_basic_end=$(date +%s)
  echo "Toplev Basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  write_done_runtime "Toplev Basic" "$(secs_to_dhm "$toplev_basic_runtime")" "${OUTDIR}/done_llm_toplev_basic.log"
  log_debug "Toplev Basic completed in $(secs_to_dhm "$toplev_basic_runtime")"
  echo
fi

################################################################################
### 8. Toplev Execution profiling
################################################################################

if $run_toplev_execution; then
  print_section "8. Toplev Execution profiling"

  print_tool_header "Toplev Execution"
  log_debug "Launching Toplev Execution (CSV=/local/data/results/id_20_3gram_llm_toplev_execution.csv, log=/local/data/results/id_20_3gram_llm_toplev_execution.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Toplev Execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c '"${TOOLS_CPU}"' /local/tools/pmu-tools/toplev \
    -l1 -I '${TOPLEV_EXECUTION_INTERVAL_MS}' -v -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_execution.csv -- \
      taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' &> /local/data/results/id_20_3gram_llm_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev Execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  write_done_runtime "Toplev Execution" "$(secs_to_dhm "$toplev_execution_runtime")" "${OUTDIR}/done_llm_toplev_execution.log"
  log_debug "Toplev Execution completed in $(secs_to_dhm "$toplev_execution_runtime")"
  echo
fi

################################################################################
### 9. Toplev Full profiling
################################################################################

if $run_toplev_full; then
  print_section "9. Toplev Full profiling"

  print_tool_header "Toplev Full"
  log_debug "Launching Toplev Full (CSV=/local/data/results/id_20_3gram_llm_toplev_full.csv, log=/local/data/results/id_20_3gram_llm_toplev_full.log, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Toplev Full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c '"${TOOLS_CPU}"' /local/tools/pmu-tools/toplev \
    -l6 -I '${TOPLEV_FULL_INTERVAL_MS}' -v --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_llm_toplev_full.csv -- \
      taskset -c '"${WORKLOAD_CPU}"' python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' >> /local/data/results/id_20_3gram_llm_toplev_full.log 2>&1
  toplev_full_end=$(date +%s)
  echo "Toplev Full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  write_done_runtime "Toplev Full" "$(secs_to_dhm "$toplev_full_runtime")" "${OUTDIR}/done_llm_toplev_full.log"
  log_debug "Toplev Full completed in $(secs_to_dhm "$toplev_full_runtime")"
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
    echo "Converting id_20_3gram_llm_maya.txt → id_20_3gram_llm_maya.csv"
    log_debug "Converting Maya output to CSV"
    awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
      "$MAYA_TXT_PATH" \
      > "${RESULT_PREFIX}_maya.csv"
    log_debug "Maya CSV generated"
  fi
  echo
fi

################################################################################
### 11. Experiment completion summary
################################################################################
print_section "11. Experiment completion summary"

echo "All done. Results are in /local/data/results/"
echo "Experiment finished at: $(timestamp)"
log_debug "Experiment complete; collating runtimes"

################################################################################
### 12. Write completion file with runtimes
################################################################################
print_section "12. Write completion file with runtimes"


completion_logs=(
  done_llm_toplev_basic.log
  done_llm_toplev_full.log
  done_llm_toplev_execution.log
  done_llm_maya.log
  done_llm_pcm.log
  done_llm_pcm_memory.log
  done_llm_pcm_power.log
  done_llm_pcm_pcie.log
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
