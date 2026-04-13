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
# - WORKLOAD_CPUS / TOOLS_CPUS: workload and profiling CPU masks.
# - OUTDIR / LOGDIR: directories for experiment data and aggregated logs.
# - IDTAG: identifier used to namespace output files.
# - *_INTERVAL_* / TS_INTERVAL / PQOS_INTERVAL_TICKS: sampler cadences in seconds or PQoS ticks.

WORKLOAD_CPUS=${WORKLOAD_CPUS:-${WORKLOAD_CPU:-}}
TOOLS_CPUS=${TOOLS_CPUS:-${TOOLS_CPU:-}}
WORKLOAD_CPU_COUNT=${WORKLOAD_CPU_COUNT:-}
TOOLS_CPU_COUNT=${TOOLS_CPU_COUNT:-}
WORKLOAD_SMT_POLICY=${WORKLOAD_SMT_POLICY:-spillover}
WORKLOAD_HIGH_PRIORITY_CPUS=${WORKLOAD_HIGH_PRIORITY_CPUS:-}
WORKLOAD_LOW_PRIORITY_CPUS=${WORKLOAD_LOW_PRIORITY_CPUS:-}
WORKLOAD_HIGH_PRIORITY_COUNT=${WORKLOAD_HIGH_PRIORITY_COUNT:-}
WORKLOAD_LOW_PRIORITY_COUNT=${WORKLOAD_LOW_PRIORITY_COUNT:-}
SOCKET_ID_REQUEST=${SOCKET_ID_REQUEST:-auto}
RESERVED_BACKGROUND_CPU_COUNT=${RESERVED_BACKGROUND_CPU_COUNT:-1}
CPU_TOPOLOGY_ONLY=false
PLACEMENT_SMOKE_SECONDS=${PLACEMENT_SMOKE_SECONDS:-}
WORKLOAD_CPU="${WORKLOAD_CPUS}"
TOOLS_CPU="${TOOLS_CPUS}"
WORKLOAD_THREADS=${WORKLOAD_THREADS:-}
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
PREFETCH_SPEC="${PREFETCH_SPEC:-}"
PF_SNAPSHOT_OK=false
PORTABLE_SHARED_RNN_RESULTS_PATH="/local/data/results/id20_shared_rnn_results.pkl"
ID20_RNN_RESULTS_PATH=""
PORTABLE_SHARED_NBEST_RESULTS_PATH="/local/data/results/id20_shared_nbest_results.pkl"
ID20_NBEST_OUTPUT_PATH=""

# Default resctrl/LLC policy knobs. These govern the cache-isolation helpers.
# - WORKLOAD_CORE_DEFAULT / TOOLS_CORE_DEFAULT: fallback CPU selections for isolation.
# - RDT_GROUP_*: resctrl group names for workload vs. background traffic.
# - LLC_*: bookkeeping flags for exclusive cache allocation.
WORKLOAD_CORE_DEFAULT=${WORKLOAD_CORE_DEFAULT:-${WORKLOAD_CPUS}}
TOOLS_CORE_DEFAULT=${TOOLS_CORE_DEFAULT:-${TOOLS_CPUS}}
RDT_GROUP_WL=${RDT_GROUP_WL:-wl_core}
RDT_GROUP_SYS=${RDT_GROUP_SYS:-sys_rest}
LLC_RESTORE_REGISTERED=false
LLC_EXCLUSIVE_ACTIVE=false
LLC_REQUESTED_PERCENT=100

# Ensure shared knobs are visible to child processes (e.g., inline Python blocks).
export WORKLOAD_CPUS TOOLS_CPUS WORKLOAD_CPU TOOLS_CPU WORKLOAD_CPU_COUNT TOOLS_CPU_COUNT \
  WORKLOAD_SMT_POLICY WORKLOAD_HIGH_PRIORITY_CPUS WORKLOAD_LOW_PRIORITY_CPUS \
  WORKLOAD_HIGH_PRIORITY_COUNT WORKLOAD_LOW_PRIORITY_COUNT \
  SOCKET_ID_REQUEST RESERVED_BACKGROUND_CPU_COUNT WORKLOAD_THREADS PLACEMENT_SMOKE_SECONDS \
  OUTDIR LOGDIR IDTAG TS_INTERVAL PQOS_INTERVAL_TICKS PCM_INTERVAL_SEC \
  PCM_MEMORY_INTERVAL_SEC PCM_POWER_INTERVAL_SEC PCM_PCIE_INTERVAL_SEC PQOS_INTERVAL_SEC \
  TOPLEV_BASIC_INTERVAL_SEC TOPLEV_EXECUTION_INTERVAL_SEC TOPLEV_FULL_INTERVAL_SEC \
  ID20_RNN_RESULTS_PATH ID20_NBEST_OUTPUT_PATH

RESULT_PREFIX="${OUTDIR}/${IDTAG}"
ID20_LM_WORKLOAD_SCRIPT_RAW="${LOGDIR}/id20_lm_workload_raw.sh"

# Honor --help before creating log directories or touching /local.
if [[ "${request_help}" == true ]]; then
  print_help
  exit 0
fi

# Define command-line interface metadata
CLI_OPTIONS=(
  "-h, --help||Show this help message and exit"
  "--debug|state|Enable verbose debug logging (on/off; default: off)"
  "--cpu-topology||Print logical CPU IDs, sockets, cores, SMT sibling groups, and auto-pick capacity, then exit"
  "__GROUP_BREAK__"
  "--workload-cpus|mask|Explicit workload CPU mask override. Ordinary runs otherwise use deterministic socket-0 defaults."
  "--workload-cpu-count|count|Auto-pick N workload logical CPUs/threads on socket 0 using the shared deterministic order"
  "--workload-smt-policy|mode|SMT auto-pick policy: off, spillover, or pack (default: spillover)"
  "--workload-high-priority-cpus|mask|Explicit SST high-tier subset of --workload-cpus (c6620 only; must match the hardware high-tier CPU list and does not redefine it)"
  "--workload-low-priority-cpus|mask|Explicit SST low-tier subset of --workload-cpus (c6620 only; must match the hardware low-tier CPU list and does not redefine it)"
  "--workload-high-priority-count|count|Auto-pick this many workload logical CPUs from the hardware high-priority SST tier (c6620 only; requires --workload-cpu-count)"
  "--workload-low-priority-count|count|Auto-pick this many workload logical CPUs from the hardware low-priority SST tier (c6620 only; requires --workload-cpu-count)"
  "--tools-cpus|mask|Explicit tool CPU mask override. Ordinary runs otherwise use the deterministic socket-0 tool default."
  "--tools-cpu-count|count|Auto-pick N tool logical CPUs on socket 0 (default when unspecified: the legacy tool CPU)"
  "--socket-id|id|Socket selector for explicit masks or auto-pick bookkeeping; only 0 or auto are accepted (auto resolves to 0)"
  "--workload-threads|count|WFST worker count; defaults to the resolved workload logical CPU count"
  "--placement-smoke-seconds|seconds|Bound the workload with timeout for placement verification; timeout is treated as success once placement metadata exists"
  "__GROUP_BREAK__"
  "--turbo|state|Set CPU Turbo Boost state (on/off; default: off)"
  "--cstates|state|Disable CPU idle states deeper than C1 (on/off; default: on)"
  "--pkgcap|watts|Set CPU package power cap in watts or 'off' to disable (default: off)"
  "--dramcap|watts|Set DRAM power cap in watts or 'off' to disable (default: off)"
  "--llc|percent|Reserve exclusive LLC percentage for the workload core (default: 100)"
  "--mba|percent/off|Throttle workload memory bandwidth allocation percentage or 'off' (default: off)"
  "--mba-scope|mode|MBA scope: cpu (default) or pid"
  "--corefreq|ghz|Pin CPUs to the specified frequency in GHz or 'off' to disable pinning (default: 2.4)"
  "--uncorefreq|ghz|Pin uncore (ring/LLC) frequency to this value in GHz (e.g., 2.0)"
  "--prefetcher|on/off or 4bits|Hardware prefetchers for the workload core only. on=all enabled, off=all disabled, or 4 bits (1=enable,0=disable) in order: L2_streamer L2_adjacent L1D_streamer L1D_IP"
  "--rnn-res|path|Optional path to RNN results pickle for WFST decoder (default: /local/data/results/id20_shared_rnn_results.pkl)"
  "--nb-output|path|Optional path to write WFST n-best pickle (default: IDTAG-scoped path under /local/data/results)"
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
MBA_REQUEST="${MBA_REQUEST:-off}"
MBA_SCOPE="${MBA_SCOPE:-cpu}"
MBA_TRACK_INTERVAL_SEC="${MBA_TRACK_INTERVAL_SEC:-0.2}"
pin_corefreq_khz_default="${PIN_FREQ_KHZ:-2400000}"
UNCORE_FREQ_GHZ=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu-topology)
      CPU_TOPOLOGY_ONLY=true
      ;;
    --workload-cpus=*)
      WORKLOAD_CPUS="${1#--workload-cpus=}"
      ;;
    --workload-cpus)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-cpus" >&2
        exit 1
      fi
      WORKLOAD_CPUS="$2"
      shift
      ;;
    --workload-cpu-count=*)
      WORKLOAD_CPU_COUNT="${1#--workload-cpu-count=}"
      ;;
    --workload-cpu-count)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-cpu-count" >&2
        exit 1
      fi
      WORKLOAD_CPU_COUNT="$2"
      shift
      ;;
    --workload-smt-policy=*)
      WORKLOAD_SMT_POLICY="${1#--workload-smt-policy=}"
      ;;
    --workload-smt-policy)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-smt-policy" >&2
        exit 1
      fi
      WORKLOAD_SMT_POLICY="$2"
      shift
      ;;
    --workload-high-priority-cpus=*)
      WORKLOAD_HIGH_PRIORITY_CPUS="${1#--workload-high-priority-cpus=}"
      ;;
    --workload-high-priority-cpus)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-high-priority-cpus" >&2
        exit 1
      fi
      WORKLOAD_HIGH_PRIORITY_CPUS="$2"
      shift
      ;;
    --workload-low-priority-cpus=*)
      WORKLOAD_LOW_PRIORITY_CPUS="${1#--workload-low-priority-cpus=}"
      ;;
    --workload-low-priority-cpus)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-low-priority-cpus" >&2
        exit 1
      fi
      WORKLOAD_LOW_PRIORITY_CPUS="$2"
      shift
      ;;
    --workload-high-priority-count=*)
      WORKLOAD_HIGH_PRIORITY_COUNT="${1#--workload-high-priority-count=}"
      ;;
    --workload-high-priority-count)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-high-priority-count" >&2
        exit 1
      fi
      WORKLOAD_HIGH_PRIORITY_COUNT="$2"
      shift
      ;;
    --workload-low-priority-count=*)
      WORKLOAD_LOW_PRIORITY_COUNT="${1#--workload-low-priority-count=}"
      ;;
    --workload-low-priority-count)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-low-priority-count" >&2
        exit 1
      fi
      WORKLOAD_LOW_PRIORITY_COUNT="$2"
      shift
      ;;
    --tools-cpus=*)
      TOOLS_CPUS="${1#--tools-cpus=}"
      ;;
    --tools-cpus)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --tools-cpus" >&2
        exit 1
      fi
      TOOLS_CPUS="$2"
      shift
      ;;
    --tools-cpu-count=*)
      TOOLS_CPU_COUNT="${1#--tools-cpu-count=}"
      ;;
    --tools-cpu-count)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --tools-cpu-count" >&2
        exit 1
      fi
      TOOLS_CPU_COUNT="$2"
      shift
      ;;
    --socket-id=*)
      SOCKET_ID_REQUEST="${1#--socket-id=}"
      ;;
    --socket-id)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --socket-id" >&2
        exit 1
      fi
      SOCKET_ID_REQUEST="$2"
      shift
      ;;
    --workload-threads=*)
      WORKLOAD_THREADS="${1#--workload-threads=}"
      ;;
    --workload-threads)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --workload-threads" >&2
        exit 1
      fi
      WORKLOAD_THREADS="$2"
      shift
      ;;
    --placement-smoke-seconds=*)
      PLACEMENT_SMOKE_SECONDS="${1#--placement-smoke-seconds=}"
      ;;
    --placement-smoke-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --placement-smoke-seconds" >&2
        exit 1
      fi
      PLACEMENT_SMOKE_SECONDS="$2"
      shift
      ;;
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
    --rnn-res=*)
      ID20_RNN_RESULTS_PATH="${1#--rnn-res=}"
      ;;
    --rnn-res)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --rnn-res" >&2
        exit 1
      fi
      ID20_RNN_RESULTS_PATH="$2"
      shift
      ;;
    --nb-output=*)
      ID20_NBEST_OUTPUT_PATH="${1#--nb-output=}"
      ;;
    --nb-output)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --nb-output" >&2
        exit 1
      fi
      ID20_NBEST_OUTPUT_PATH="$2"
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
    --mba=*)
      MBA_REQUEST="${1#--mba=}"
      ;;
    --mba)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --mba" >&2
        exit 1
      fi
      MBA_REQUEST="$2"
      shift
      ;;
    --mba-scope=*)
      MBA_SCOPE="${1#--mba-scope=}"
      ;;
    --mba-scope)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --mba-scope" >&2
        exit 1
      fi
      MBA_SCOPE="$2"
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

WORKLOAD_CPU="${WORKLOAD_CPUS}"
TOOLS_CPU="${TOOLS_CPUS}"

WORKLOAD_SMT_POLICY="${WORKLOAD_SMT_POLICY,,}"
case "${WORKLOAD_SMT_POLICY}" in
  off|spillover|pack)
    ;;
  *)
    echo "Invalid value for --workload-smt-policy: '${WORKLOAD_SMT_POLICY}' (expected off, spillover, or pack)" >&2
    exit 1
    ;;
esac
for pair in \
  "WORKLOAD_CPU_COUNT:${WORKLOAD_CPU_COUNT:-}" \
  "WORKLOAD_HIGH_PRIORITY_COUNT:${WORKLOAD_HIGH_PRIORITY_COUNT:-}" \
  "WORKLOAD_LOW_PRIORITY_COUNT:${WORKLOAD_LOW_PRIORITY_COUNT:-}" \
  "TOOLS_CPU_COUNT:${TOOLS_CPU_COUNT:-}" \
  "PLACEMENT_SMOKE_SECONDS:${PLACEMENT_SMOKE_SECONDS:-}" \
  "WORKLOAD_THREADS:${WORKLOAD_THREADS:-}" \
  "RESERVED_BACKGROUND_CPU_COUNT:${RESERVED_BACKGROUND_CPU_COUNT:-}"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  [[ -z "${value}" ]] && continue
  case "${value}" in
    ''|*[!0-9]*)
      echo "Invalid numeric value for ${key}: '${value}'" >&2
      exit 1
      ;;
  esac
done
if (( TOOLS_CPU_COUNT < 0 )); then
  echo "Invalid --tools-cpu-count value: ${TOOLS_CPU_COUNT} (must be >= 0)" >&2
  exit 1
fi
if (( RESERVED_BACKGROUND_CPU_COUNT < 0 )); then
  echo "Invalid reserved background CPU count: ${RESERVED_BACKGROUND_CPU_COUNT} (must be >= 0)" >&2
  exit 1
fi
selection_assignments="$(
  resolve_cpu_selection \
    "${WORKLOAD_CPUS}" \
    "${WORKLOAD_CPU_COUNT}" \
    "${WORKLOAD_SMT_POLICY}" \
    "${TOOLS_CPUS}" \
    "${TOOLS_CPU_COUNT}" \
    "${SOCKET_ID_REQUEST}" \
    "${RESERVED_BACKGROUND_CPU_COUNT}" \
    "${WORKLOAD_HIGH_PRIORITY_CPUS}" \
    "${WORKLOAD_LOW_PRIORITY_CPUS}" \
    "${WORKLOAD_HIGH_PRIORITY_COUNT}" \
    "${WORKLOAD_LOW_PRIORITY_COUNT}"
)"
eval "${selection_assignments}"
WORKLOAD_CPUS="${workload_cpus}"
TOOLS_CPUS="${tools_cpus}"
BACKGROUND_CPUS="${background_cpus}"
SELECTED_SOCKET_ID="${selected_socket}"
CPU_SELECTION_MODE="${cpu_selection_mode:-unknown}"
WORKLOAD_CPU_COUNT_RESOLVED="${workload_count}"
TOOLS_CPU_COUNT_RESOLVED="${tools_count}"
WORKLOAD_USED_SMT="${workload_used_smt}"
WORKLOAD_HIGH_PRIORITY_CPUS="${workload_high_priority_cpus:-}"
WORKLOAD_LOW_PRIORITY_CPUS="${workload_low_priority_cpus:-}"
WORKLOAD_SST_REQUESTED="${workload_sst_requested:-false}"
WORKLOAD_SST_ACTIVE="${workload_sst_active:-false}"
SST_HIGH_PRIORITY_CPUS_AVAILABLE="${sst_high_priority_cpus_available:-}"
SST_LOW_PRIORITY_CPUS_AVAILABLE="${sst_low_priority_cpus_available:-}"
SST_FEATURE_STATUS="${sst_feature_status:-unknown}"
SST_STATUS_MESSAGE="${sst_status_message:-}"
SST_NODE_TYPE="${sst_node_type:-unknown}"
WORKLOAD_CPU="${WORKLOAD_CPUS}"
TOOLS_CPU="${TOOLS_CPUS}"
CONTROL_CPUS="${BACKGROUND_CPUS:-${TOOLS_CPUS}}"
WORKLOAD_CPUSET_NAME="${WORKLOAD_CPUSET_NAME:-user/bci_workload}"
TOOLS_CPUSET_NAME="${TOOLS_CPUSET_NAME:-user/bci_tools}"
WORKLOAD_CORE_DEFAULT="${WORKLOAD_CPUS}"
TOOLS_CORE_DEFAULT="${TOOLS_CPUS}"
if [[ -z "${WORKLOAD_THREADS:-}" ]]; then
  WORKLOAD_THREADS="${WORKLOAD_CPU_COUNT_RESOLVED}"
fi
if (( WORKLOAD_THREADS < 1 )); then
  echo "Invalid --workload-threads value: ${WORKLOAD_THREADS} (must be >= 1)" >&2
  exit 1
fi
export WORKLOAD_CPUS TOOLS_CPUS WORKLOAD_CPU TOOLS_CPU BACKGROUND_CPUS CONTROL_CPUS \
  WORKLOAD_CPUSET_NAME TOOLS_CPUSET_NAME SELECTED_SOCKET_ID WORKLOAD_THREADS \
  CPU_SELECTION_MODE MBA_REQUEST MBA_SCOPE MBA_TRACK_INTERVAL_SEC \
  WORKLOAD_HIGH_PRIORITY_CPUS WORKLOAD_LOW_PRIORITY_CPUS \
  WORKLOAD_SST_REQUESTED WORKLOAD_SST_ACTIVE \
  SST_HIGH_PRIORITY_CPUS_AVAILABLE SST_LOW_PRIORITY_CPUS_AVAILABLE \
  SST_FEATURE_STATUS SST_STATUS_MESSAGE SST_NODE_TYPE
if $CPU_TOPOLOGY_ONLY; then
  print_cpu_topology_report "${TOOLS_CPU_COUNT_RESOLVED}" "${RESERVED_BACKGROUND_CPU_COUNT}"
  echo "Selected socket: ${SELECTED_SOCKET_ID}"
  echo "Resolved workload CPUs: ${WORKLOAD_CPUS}"
  echo "Resolved tool CPUs: ${TOOLS_CPUS}"
  echo "Reserved background CPUs: ${BACKGROUND_CPUS:-<none>}"
  print_sst_selection_report
  exit 0
fi

MBA_ASSIGNMENTS_PATH="${RESULT_PREFIX}_mba_assignments.jsonl"
EPP_SAMPLES_PATH="${RESULT_PREFIX}_epp_samples.tsv"
EPP_SUMMARY_PATH="${RESULT_PREFIX}_epp_summary.json"
WORKLOAD_REP_CPU="$(cpu_mask_first_cpu "${WORKLOAD_CPU}")"
export WORKLOAD_REP_CPU

# Create unified log file after early-exit modes have been handled.
mkdir -p "${OUTDIR}" "${LOGDIR}"
RUN_LOG="${LOGDIR}/run.log"
bci_init_run_log "${RUN_LOG}"
bci_apply_sst_run_mode
bci_write_placement_metadata "${RESULT_PREFIX}"

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

log_sst_selection_state

cat > "${ID20_LM_WORKLOAD_SCRIPT_RAW}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd /local/tools/bci_project
source /local/tools/bci_env/bin/activate
. path.sh
export PYTHONPATH="\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}"
run_cmd=(
  taskset -c "${WORKLOAD_CPU}"
  python3
  bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py
  --lmDir=/local/data/languageModel/
  --workload-cpus="${WORKLOAD_CPU}"
  --workload-threads "${WORKLOAD_THREADS}"
  --rnnRes="${ID20_RNN_RESULTS_PATH}"
)
if [[ -n "${ID20_NBEST_OUTPUT_PATH:-}" ]]; then
  run_cmd+=(--nbestPath="${ID20_NBEST_OUTPUT_PATH}")
fi
if [[ -n "\${PLACEMENT_SMOKE_SECONDS:-}" ]]; then
  set +e
  timeout --signal=TERM --kill-after=10s "\${PLACEMENT_SMOKE_SECONDS}s" "\${run_cmd[@]}"
  rc=\$?
  set -e
  if [[ \$rc -eq 124 && -s "\${PLACEMENT_METADATA_PATH:-}" ]]; then
    echo "[INFO] placement smoke timeout reached after \${PLACEMENT_SMOKE_SECONDS}s"
    exit 0
  fi
  exit \$rc
fi
exec "\${run_cmd[@]}"
EOF
chmod 755 "${ID20_LM_WORKLOAD_SCRIPT_RAW}"

MBA_SCOPE="${MBA_SCOPE,,}"
case "${MBA_SCOPE}" in
  cpu|pid) ;;
  *)
    echo "Invalid value for --mba-scope: '${MBA_SCOPE}' (expected 'cpu' or 'pid')" >&2
    exit 1
    ;;
esac
if (( WORKLOAD_THREADS == WORKLOAD_CPU_COUNT_RESOLVED )); then
  echo "[INFO] WFST worker configuration: matched (${WORKLOAD_THREADS} workers on ${WORKLOAD_CPU_COUNT_RESOLVED} workload CPUs)"
elif (( WORKLOAD_THREADS < WORKLOAD_CPU_COUNT_RESOLVED )); then
  echo "[INFO] WFST worker configuration: undersubscribed (${WORKLOAD_THREADS} workers on ${WORKLOAD_CPU_COUNT_RESOLVED} workload CPUs)"
else
  echo "[INFO] WFST worker configuration: oversubscribed (${WORKLOAD_THREADS} workers on ${WORKLOAD_CPU_COUNT_RESOLVED} workload CPUs)"
fi

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

enforce_c240g5_control_policy --pkgcap "${pkgcap_w}" --dramcap "${dramcap_w}" --llc "${llc_percent_request}"
if [[ "${MBA_SCOPE}" == "pid" ]] && { $run_toplev_basic || $run_toplev_execution || $run_toplev_full || $run_maya || $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; }; then
  echo "[MBA] --mba-scope pid is not supported on the LM profiler path because the tool wrappers and workload share the same shell tree; use --mba-scope cpu instead." >&2
  exit 1
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

if [[ -z ${ID20_RNN_RESULTS_PATH:-} ]]; then
  ID20_RNN_RESULTS_PATH="${PORTABLE_SHARED_RNN_RESULTS_PATH}"
fi
if [[ -z ${ID20_NBEST_OUTPUT_PATH:-} ]]; then
  ID20_NBEST_OUTPUT_PATH="${PORTABLE_SHARED_NBEST_RESULTS_PATH}"
fi
LM_PCM_PCIE_CSV="${RESULT_PREFIX}_pcm_pcie.csv"
LM_PCM_PCIE_LOG="${RESULT_PREFIX}_pcm_pcie.log"
LM_PCM_CSV="${RESULT_PREFIX}_pcm.csv"
LM_PCM_LOG="${RESULT_PREFIX}_pcm.log"
LM_PCM_MEMORY_CSV="${RESULT_PREFIX}_pcm_memory.csv"
LM_PCM_MEMORY_LOG_STAGE1="${RESULT_PREFIX}_pcm_memory.log"
LM_PCM_POWER_CSV="${RESULT_PREFIX}_pcm_power.csv"
LM_PCM_POWER_LOG="${RESULT_PREFIX}_pcm_power.log"
LM_PQOS_WORKLOAD_LOG="${RESULT_PREFIX}_pqos_workload.log"
LM_TOPLEV_BASIC_CSV="${RESULT_PREFIX}_toplev_basic.csv"
LM_TOPLEV_BASIC_LOG="${RESULT_PREFIX}_toplev_basic.log"
LM_TOPLEV_EXECUTION_CSV="${RESULT_PREFIX}_toplev_execution.csv"
LM_TOPLEV_EXECUTION_LOG="${RESULT_PREFIX}_toplev_execution.log"
LM_TOPLEV_FULL_CSV="${RESULT_PREFIX}_toplev_full.csv"
LM_TOPLEV_FULL_LOG="${RESULT_PREFIX}_toplev_full.log"
LM_MAYA_TXT_PATH="${RESULT_PREFIX}_maya.txt"
LM_MAYA_LOG_PATH="${RESULT_PREFIX}_maya.log"
LM_DONE_TOPLEV_BASIC="${RESULT_PREFIX}_done_lm_toplev_basic.log"
LM_DONE_TOPLEV_FULL="${RESULT_PREFIX}_done_lm_toplev_full.log"
LM_DONE_TOPLEV_EXECUTION="${RESULT_PREFIX}_done_lm_toplev_execution.log"
LM_DONE_MAYA="${RESULT_PREFIX}_done_lm_maya.log"
LM_DONE_PCM="${RESULT_PREFIX}_done_lm_pcm.log"
LM_DONE_PCM_MEMORY="${RESULT_PREFIX}_done_lm_pcm_memory.log"
LM_DONE_PCM_POWER="${RESULT_PREFIX}_done_lm_pcm_power.log"
LM_DONE_PCM_PCIE="${RESULT_PREFIX}_done_lm_pcm_pcie.log"
LM_FINAL_DONE_PATH="${RESULT_PREFIX}_done.log"

if $debug_enabled; then
  log_debug "Configuration summary:"
  log_debug "  Turbo Boost request: ${turbo_state}"
  log_debug "  CPU package cap: ${pkgcap_w}"
  log_debug "  DRAM cap: ${dramcap_w}"
  log_debug "  Socket request: ${SOCKET_ID_REQUEST}"
  log_debug "  Resolved socket: ${SELECTED_SOCKET_ID}"
  log_debug "  Workload CPUs: ${WORKLOAD_CPUS}"
  log_debug "  Tool CPUs: ${TOOLS_CPUS}"
  log_debug "  Reserved background CPUs: ${BACKGROUND_CPUS:-<none>}"
  log_debug "  Control CPUs: ${CONTROL_CPUS:-<none>}"
  log_debug "  Workload SMT policy: ${WORKLOAD_SMT_POLICY} (used_smt=${WORKLOAD_USED_SMT})"
  log_debug "  Workload concurrency: ${WORKLOAD_THREADS}"
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
  log_debug "  WFST RNN results path: ${ID20_RNN_RESULTS_PATH}"
  log_debug "  WFST n-best output path: ${ID20_NBEST_OUTPUT_PATH}"
  log_debug_blank
fi

# Describe this workload for logging
workload_desc="ID-20 3gram LM"

log_workload_concurrency_state "${WORKLOAD_THREADS}" "${WORKLOAD_CPU_COUNT_RESOLVED}"

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

llc_core_setup_once --llc "${llc_percent_request}" --wl-cpus "${WORKLOAD_CPU}" --tools-cpus "${TOOLS_CPU}"
mba_setup_once --mba "${MBA_REQUEST}" --mba-scope "${MBA_SCOPE}" --wl-cpus "${WORKLOAD_CPU}" --tools-cpus "${TOOLS_CPU}"
start_energy_policy_monitor "${WORKLOAD_REP_CPU}" "${EPP_SAMPLES_PATH}" "${EPP_SUMMARY_PATH}" "1" "ENERGY_POLICY_MONITOR_PID"

# Hardware prefetchers: apply only if user provided --prefetcher
PF_DISABLE_MASK=""
if [[ -n "${PREFETCH_SPEC:-}" ]]; then
  PF_DISABLE_MASK="$(pf_parse_spec_to_disable_mask "${PREFETCH_SPEC}")" \
    || { echo "[FATAL] Invalid --prefetcher value: ${PREFETCH_SPEC}"; exit 1; }
  pf_bits_summary="$(pf_bits_one_liner "${PF_DISABLE_MASK}")"
  log_debug "[PF] user pattern=${PREFETCH_SPEC} (1=enable,0=disable) -> ${pf_bits_summary}"

  if pf_snapshot_for_mask "${WORKLOAD_CPU}"; then
    PF_SNAPSHOT_OK=true
  else
    log_warn "[PF] snapshot failed; will attempt to apply anyway"
  fi

  pf_apply_for_mask "${WORKLOAD_CPU}" "${PF_DISABLE_MASK}"
  pf_verify_for_mask "${WORKLOAD_CPU}" || log_warn "[PF] verify failed; state may be unchanged"
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
trap_add '[[ -n ${PREFETCH_SPEC:-} && ${PF_SNAPSHOT_OK:-false} == true ]] && pf_restore_for_mask "${WORKLOAD_CPU}" || true' EXIT
trap_add 'stop_mba_pid_tracker "${MBA_TRACKER_PID:-}" || true' EXIT
trap_add 'stop_energy_policy_monitor "${ENERGY_POLICY_MONITOR_PID:-}" "${EPP_SAMPLES_PATH}" "${EPP_SUMMARY_PATH}" || true' EXIT
trap_add 'restore_cpu_isolation || true' EXIT

################################################################################
### 0b. Prepare CPU steering before profiling starts
################################################################################
print_section "0b. Prepare CPU steering before profiling starts"

print_tool_header "CPU steering"
log_debug "Resetting any stale CPU isolation state before preparing PCM visibility"
reset_stale_cpu_isolation
log_debug "Preparing IRQ/workqueue steering before PCM profiling (workload=${WORKLOAD_CPU}, tools=${TOOLS_CPU}, control=${CONTROL_CPUS}, background=${BACKGROUND_CPUS:-<none>})"
prepare_cpu_steering "${WORKLOAD_CPU}" "${TOOLS_CPU}" "${BACKGROUND_CPUS:-}"
echo "Planned workload/tool CPUs: ${SHIELDED_CPUS:-${TOOLS_CPU},${WORKLOAD_CPU}}"
echo "Control CPUs: ${CONTROL_CPUS:-<none>}"
echo "Non-workload CPUs: ${NON_WORKLOAD_CPUS:-<unknown>}"
echo

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

# Create placeholder logs for tools that aren't selected so that the final
# summary always lists every stage.
$run_toplev_basic || write_done_skipped "Toplev Basic" "${LM_DONE_TOPLEV_BASIC}"
$run_toplev_full || write_done_skipped "Toplev Full" "${LM_DONE_TOPLEV_FULL}"
$run_toplev_execution || \
  write_done_skipped "Toplev Execution" "${LM_DONE_TOPLEV_EXECUTION}"
$run_maya || write_done_skipped "Maya" "${LM_DONE_MAYA}"
$run_pcm || write_done_skipped "PCM" "${LM_DONE_PCM}"
$run_pcm_memory || write_done_skipped "PCM Memory" "${LM_DONE_PCM_MEMORY}"
$run_pcm_power || write_done_skipped "PCM Power" "${LM_DONE_PCM_POWER}"
$run_pcm_pcie || write_done_skipped "PCM PCIE" "${LM_DONE_PCM_PCIE}"
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
    log_debug "Launching PCM PCIE (CSV=${LM_PCM_PCIE_CSV}, log=${LM_PCM_PCIE_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
    idle_wait
    echo "PCM PCIE started at: $(timestamp)"
    pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm-pcie \
      -csv='"${LM_PCM_PCIE_CSV}"' \
      -B '${PCM_PCIE_INTERVAL_SEC}' -- \
      bash -lc "
        bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
      "
  ' >>"${LM_PCM_PCIE_LOG}" 2>&1
  pcm_pcie_end=$(date +%s)
  echo "PCM PCIE finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  write_done_runtime "PCM PCIE" "$(secs_to_dhm "$pcm_pcie_runtime")" "${LM_DONE_PCM_PCIE}"
  log_debug "PCM PCIE completed in $(secs_to_dhm "$pcm_pcie_runtime")"
  fi

  if $run_pcm; then
    print_tool_header "PCM"
    log_debug "Launching PCM (CSV=${LM_PCM_CSV}, log=${LM_PCM_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
    idle_wait
    echo "PCM started at: $(timestamp)"
    pcm_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pcm/build/bin/pcm \
      -csv='"${LM_PCM_CSV}"' \
      '${PCM_INTERVAL_SEC}' -- \
      bash -lc "
        bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
      "
  ' >>"${LM_PCM_LOG}" 2>&1
  pcm_end=$(date +%s)
  echo "PCM finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  write_done_runtime "PCM" "$(secs_to_dhm "$pcm_runtime")" "${LM_DONE_PCM}"
  log_debug "PCM completed in $(secs_to_dhm "$pcm_runtime")"
  fi

  if $run_pcm_memory; then
    print_tool_header "PCM Memory"
    log_debug "Launching PCM Memory (CSV=${LM_PCM_MEMORY_CSV}, log=${LM_PCM_MEMORY_LOG_STAGE1}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
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
      -csv='"${LM_PCM_MEMORY_CSV}"' \
      '${PCM_MEMORY_INTERVAL_SEC}' -- \
      bash -lc "
        bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
      "
  ' >>"${LM_PCM_MEMORY_LOG_STAGE1}" 2>&1
  pcm_mem_end=$(date +%s)
  echo "PCM Memory finished at: $(timestamp)"
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  write_done_runtime "PCM Memory" "$(secs_to_dhm "$pcm_mem_runtime")" "${LM_DONE_PCM_MEMORY}"
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
      -csv='"${LM_PCM_POWER_CSV}"' -- \
      bash -lc "
        bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
      "
  ' >>"${LM_PCM_POWER_LOG}" 2>&1
  pass1_end=$(date +%s)
  echo "PCM Power finished at: $(timestamp)"
  pass1_runtime=$((pass1_end - pass1_start))

  stop_turbostat "${TS_PID_PASS1:-}"
  unset TS_PID_PASS1

  cleanup_pcm_processes

  if [[ ${LLC_EXCLUSIVE_ACTIVE:-false} == true ]]; then
    log_debug "Skipping pqos -R because LLC exclusive allocation is active"
  else
    pqos_reset_os_best_effort
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
        bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
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
    pqos_reset_os_best_effort
  fi

  idle_wait

  log_info "Pass 3: pqos MBM only"
  cleanup_pcm_processes
  guard_no_pcm_active

  # Include all cores except TOOLS and WORKLOAD in OTHERS; keep TOOLS as a separate group
  OTHERS="$(others_list_csv "${TOOLS_CPU}" "${WORKLOAD_CPU}")"
  TOOLS_GROUP="${TOOLS_CPU}"
  log_info "PQoS others list: ${OTHERS:-<empty>}"
  MON_SPEC="$(pqos_monitor_spec_all_groups "${WORKLOAD_CPU}" "${OTHERS}" "${TOOLS_GROUP}")"
  [[ -n "${MON_SPEC}" ]] || { echo "Failed to build pqos monitor spec" >&2; exit 1; }

  pass3_runtime=0
  pass3_summary="skipped: PQoS monitoring unavailable on this platform/runtime"
  if pqos_prepare_monitoring_runtime && pqos_monitoring_probe "${WORKLOAD_CPU}"; then
    pass3_start=$(date +%s)
    pqos_prepare_monitoring_runtime
    pqos_cmd="$(pqos_build_monitor_command "${PQOS_CSV}" "${PQOS_INTERVAL_TICKS}" "${MON_SPEC}" "${PQOS_LOG}" "${TOOLS_CPU}")"
    if start_background_system_tool "pqos pass3" "${pqos_cmd}" "PQOS_PID"; then
      log_info "pqos pass3: started pid=${PQOS_PID} (groups workload=${WORKLOAD_CPU} others=${OTHERS:-<none>})"
      log_debug "Launching pqos pass3 (log=${PQOS_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU}, others cores=${OTHERS:-<none>})"

      pqos_workload_rc=0
      echo "pqos workload run started at: $(timestamp)"
      set +e
      sudo -E bash -lc '
        source /local/tools/bci_env/bin/activate
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
        . path.sh
        export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

        bash -lc "
          bash \"${ID20_LM_WORKLOAD_SCRIPT_RAW}\"
        "
      ' >>"${LM_PQOS_WORKLOAD_LOG}" 2>&1
      pqos_workload_rc=$?
      set -e
      echo "pqos workload run finished at: $(timestamp)"
      pass3_end=$(date +%s)
      pass3_runtime=$((pass3_end - pass3_start))
      pass3_summary="runtime: $(secs_to_dhm "$pass3_runtime")"

      if [[ -n ${PQOS_PID} ]]; then
        kill -INT "${PQOS_PID}" 2>/dev/null || true
        wait "${PQOS_PID}" 2>/dev/null || true
      fi
      ensure_background_stopped "pqos pass3" "${PQOS_PID}"
      PQOS_PID=""
      if (( pqos_workload_rc != 0 )); then
        log_warn "PQoS workload run failed with exit ${pqos_workload_rc}; see ${LM_PQOS_WORKLOAD_LOG}"
        exit "${pqos_workload_rc}"
      fi
    else
      log_warn "PQoS monitor launch failed after a successful probe; skipping pass 3 MBM collection."
      printf '[%s] pass3 skipped: pqos monitor launch failed after successful probe\n' \
        "$(timestamp)" >>"${PQOS_LOG}"
      printf '[%s] pass3 skipped: pqos monitor launch failed after successful probe\n' \
        "$(timestamp)" >"${LM_PQOS_WORKLOAD_LOG}"
    fi
  else
    log_warn "PQoS monitoring unavailable on this platform/runtime; skipping pass 3 MBM collection."
    printf '[%s] pass3 skipped: pqos monitoring unavailable on this platform/runtime\n' \
      "$(timestamp)" >>"${PQOS_LOG}"
    printf '[%s] pass3 skipped: pqos monitoring unavailable on this platform/runtime\n' \
      "$(timestamp)" >"${LM_PQOS_WORKLOAD_LOG}"
  fi
  pqos_finish_monitoring_runtime

  pqos_logging_enabled=false

  pcm_power_overall_end=$(date +%s)
  pcm_power_runtime=$((pcm_power_overall_end - pcm_power_overall_start))

  declare -a summary_lines
  summary_lines=(
    "PCM Power runtime: $(secs_to_dhm "$pcm_power_runtime")"
    "PCM Power Pass 1 runtime: $(secs_to_dhm "$pass1_runtime")"
    "PCM Memory Pass 2 runtime: $(secs_to_dhm "$pass2_runtime")"
    "pqos Pass 3 ${pass3_summary}"
  )
  printf '%s\n' "${summary_lines[@]}" > "${OUTDIR}/${IDTAG}_pcm_power.done"
  write_done_runtime "PCM Power" "$(secs_to_dhm "$pcm_power_runtime")" "${LM_DONE_PCM_POWER}"
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
log_debug "Activating CPU isolation after PCM profiling (workload=${WORKLOAD_CPU}, tools=${TOOLS_CPU}, control=${CONTROL_CPUS:-<none>}, background=${BACKGROUND_CPUS:-<none>})"
apply_cpu_isolation "${WORKLOAD_CPU}" "${TOOLS_CPU}" "${BACKGROUND_CPUS:-}"
echo "Shielded CPUs: ${SHIELDED_CPUS:-${TOOLS_CPU},${WORKLOAD_CPU}}"
echo

################################################################################
### 6. Maya profiling
################################################################################

if $run_maya; then
  print_section "6. Maya profiling"

  print_tool_header "MAYA"
  log_debug "Launching Maya profiler (text=${LM_MAYA_TXT_PATH}, log=${LM_MAYA_LOG_PATH}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)

  # Run the LM script under Maya (Maya on TOOLS_CPU, workload on WORKLOAD_CPU)
  MAYA_TXT_PATH="${LM_MAYA_TXT_PATH}"
  MAYA_LOG_PATH="${LM_MAYA_LOG_PATH}"
  MAYA_DONE_PATH="${LM_DONE_MAYA}"
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
bash "${ID20_LM_WORKLOAD_SCRIPT_RAW}" >> "$MAYA_LOG_PATH" 2>&1 || workload_status=$?

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
  log_debug "Launching Toplev Basic (CSV=${LM_TOPLEV_BASIC_CSV}, log=${LM_TOPLEV_BASIC_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
  idle_wait
  echo "Toplev Basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  if bci_toplev_basic_supports_rich_nodes; then
    sudo -E cset shield --exec -- bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pmu-tools/toplev \
      -l3 -I '${TOPLEV_BASIC_INTERVAL_MS}' -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o '"${LM_TOPLEV_BASIC_CSV}"' -- \
        bash '"${ID20_LM_WORKLOAD_SCRIPT_RAW}"' \
          >> '"${LM_TOPLEV_BASIC_LOG}"' 2>&1
    '
  else
    echo "[INFO] Rich toplev basic node set unavailable; using generic simple-model topdown pass." >> "${LM_TOPLEV_BASIC_LOG}"
    sudo -E cset shield --exec -- bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c '"${TOOLS_CPU}"' /local/tools/pmu-tools/toplev \
      -l1 -I '${TOPLEV_BASIC_INTERVAL_MS}' -v --per-thread -x, \
      -o '"${LM_TOPLEV_BASIC_CSV}"' -- \
        bash '"${ID20_LM_WORKLOAD_SCRIPT_RAW}"' \
          >> '"${LM_TOPLEV_BASIC_LOG}"' 2>&1
    '
  fi
  toplev_basic_end=$(date +%s)
  echo "Toplev Basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  write_done_runtime "Toplev Basic" "$(secs_to_dhm "$toplev_basic_runtime")" "${LM_DONE_TOPLEV_BASIC}"
  log_debug "Toplev Basic completed in $(secs_to_dhm "$toplev_basic_runtime")"
  echo
fi

################################################################################
### 8. Toplev Execution profiling
################################################################################

if $run_toplev_execution; then
  print_section "8. Toplev Execution profiling"

  print_tool_header "Toplev Execution"
  log_debug "Launching Toplev Execution (CSV=${LM_TOPLEV_EXECUTION_CSV}, log=${LM_TOPLEV_EXECUTION_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
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
    -o '"${LM_TOPLEV_EXECUTION_CSV}"' -- \
        bash '"${ID20_LM_WORKLOAD_SCRIPT_RAW}"'
  ' &> '"${LM_TOPLEV_EXECUTION_LOG}"'
  toplev_execution_end=$(date +%s)
  echo "Toplev Execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  write_done_runtime "Toplev Execution" "$(secs_to_dhm "$toplev_execution_runtime")" "${LM_DONE_TOPLEV_EXECUTION}"
  log_debug "Toplev Execution completed in $(secs_to_dhm "$toplev_execution_runtime")"
  echo
fi

################################################################################
### 9. Toplev Full profiling
################################################################################

if $run_toplev_full; then
  print_section "9. Toplev Full profiling"

  print_tool_header "Toplev Full"
  log_debug "Launching Toplev Full (CSV=${LM_TOPLEV_FULL_CSV}, log=${LM_TOPLEV_FULL_LOG}, tool core=${TOOLS_CPU}, workload core=${WORKLOAD_CPU})"
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
    -o '"${LM_TOPLEV_FULL_CSV}"' -- \
      bash '"${ID20_LM_WORKLOAD_SCRIPT_RAW}"' \
  ' >> '"${LM_TOPLEV_FULL_LOG}"' 2>&1
  toplev_full_end=$(date +%s)
  echo "Toplev Full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  write_done_runtime "Toplev Full" "$(secs_to_dhm "$toplev_full_runtime")" "${LM_DONE_TOPLEV_FULL}"
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
    echo "Converting $(basename "$MAYA_TXT_PATH") → $(basename "${RESULT_PREFIX}_maya.csv")"
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
  "${LM_DONE_TOPLEV_BASIC}"
  "${LM_DONE_TOPLEV_FULL}"
  "${LM_DONE_TOPLEV_EXECUTION}"
  "${LM_DONE_MAYA}"
  "${LM_DONE_PCM}"
  "${LM_DONE_PCM_MEMORY}"
  "${LM_DONE_PCM_POWER}"
  "${LM_DONE_PCM_PCIE}"
)

final_done_path="${LM_FINAL_DONE_PATH}"
: > "${final_done_path}"
for log in "${completion_logs[@]}"; do
  if [[ -s "${log}" ]]; then
    if [[ -s "${final_done_path}" ]]; then
      printf '\n' >> "${final_done_path}"
    fi
    cat "${log}" >> "${final_done_path}"
  fi
done
bci_append_placement_pointer "${final_done_path}"
log_debug "Wrote ${final_done_path}"

rm -f "${completion_logs[@]}"
log_debug "Removed intermediate done_* logs"

################################################################################
### 13. Clean up CPU shielding
################################################################################
print_section "13. Clean up CPU shielding"


sudo cset shield --reset || true
log_debug "cset shield reset issued"
bci_close_run_log
