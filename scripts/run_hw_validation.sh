#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"
trap on_error ERR

SCENARIO="benchmark"
VALIDATION_TAG="${VALIDATION_TAG:-hw_validation}"
OUTDIR="${OUTDIR:-/local/data/results/validator}"
LOGDIR="${LOGDIR:-/local/logs}"
WORKLOAD_CPU="${WORKLOAD_CPU:-}"
TOOLS_CPU="${TOOLS_CPU:-}"
BENCHMARK_BIN="${BENCHMARK_BIN:-/local/tools/hw_control_bench}"
BENCH_MODE="${BENCH_MODE:-stream}"
BENCH_SECONDS="${BENCH_SECONDS:-2.0}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-0}"
BENCH_SIZE_MB="${BENCH_SIZE_MB:-256}"
BENCH_STRIDE_BYTES="${BENCH_STRIDE_BYTES:-64}"
BENCH_THREADS="${BENCH_THREADS:-1}"
TS_INTERVAL="${TS_INTERVAL:-0.25}"
PQOS_INTERVAL_SEC="${PQOS_INTERVAL_SEC:-0.5}"
PREFETCH_SPEC="${PREFETCH_SPEC:-}"
PF_SCOPE="${PF_SCOPE:-package}"
TURBO_STATE="${TURBO_STATE:-}"
PKGCAP_REQUEST="${PKGCAP_REQUEST:-off}"
DRAMCAP_REQUEST="${DRAMCAP_REQUEST:-off}"
COREFREQ_REQUEST="${COREFREQ_REQUEST:-off}"
UNCORE_REQUEST="${UNCORE_REQUEST:-off}"
LLC_REQUEST="${LLC_REQUEST:-100}"
run_perf=true
run_turbostat=true

usage() {
  cat <<'EOF'
Usage: run_hw_validation.sh [options]

Options:
  --scenario <preflight|benchmark>   Validation mode (default: benchmark)
  --tag <label>                      Prefix for result files
  --mode <compute|stream|stride|ptrchase|cachefit>
  --seconds <float>                  Fixed-duration benchmark runtime
  --iterations <count>               Fixed-iteration benchmark count
  --size-mb <count>                  Working-set size in MiB
  --stride-bytes <count>             Stride size for stride/cachefit modes
  --threads <count>                  Benchmark thread count (default: 1)
  --workload-cpu <id>                Explicit workload CPU
  --tools-cpu <id>                   Explicit tools CPU
  --turbo <on|off>                   Requested turbo state
  --pkgcap <watts|off>               Package RAPL limit
  --dramcap <watts|off>              DRAM RAPL limit
  --corefreq <ghz|off>               Requested core frequency
  --uncorefreq <ghz|off>             Requested uncore frequency
  --llc <percent>                    Requested LLC allocation percentage
  --prefetcher <on|off|bits>         Requested prefetcher pattern
  --perf <on|off>                    Enable perf stat sidecar (default: on)
  --turbostat <on|off>               Enable turbostat sidecar (default: on)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --scenario) SCENARIO="$2"; shift ;;
    --tag) VALIDATION_TAG="$2"; shift ;;
    --mode) BENCH_MODE="$2"; shift ;;
    --seconds) BENCH_SECONDS="$2"; shift ;;
    --iterations) BENCH_ITERATIONS="$2"; shift ;;
    --size-mb) BENCH_SIZE_MB="$2"; shift ;;
    --stride-bytes) BENCH_STRIDE_BYTES="$2"; shift ;;
    --threads) BENCH_THREADS="$2"; shift ;;
    --workload-cpu) WORKLOAD_CPU="$2"; shift ;;
    --tools-cpu) TOOLS_CPU="$2"; shift ;;
    --turbo) TURBO_STATE="$2"; shift ;;
    --pkgcap) PKGCAP_REQUEST="$2"; shift ;;
    --dramcap) DRAMCAP_REQUEST="$2"; shift ;;
    --corefreq) COREFREQ_REQUEST="$2"; shift ;;
    --uncorefreq) UNCORE_REQUEST="$2"; shift ;;
    --llc) LLC_REQUEST="$2"; shift ;;
    --prefetcher) PREFETCH_SPEC="$2"; shift ;;
    --perf) [[ "${2,,}" == "off" ]] && run_perf=false; shift ;;
    --turbostat) [[ "${2,,}" == "off" ]] && run_turbostat=false; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "${OUTDIR}" "${LOGDIR}"
ensure_workload_and_tools_cpus
rapl_discover_for_cpu "${WORKLOAD_CPU}"

BENCH_JSON="${OUTDIR}/${VALIDATION_TAG}_bench.json"
SUMMARY_JSON="${OUTDIR}/${VALIDATION_TAG}_summary.json"
PERF_CSV="${OUTDIR}/${VALIDATION_TAG}_perf.csv"
TURBOSTAT_TXT="${OUTDIR}/${VALIDATION_TAG}_turbostat.txt"
PRECHECK_TXT="${OUTDIR}/${VALIDATION_TAG}_preflight.txt"

{
  echo "scenario=${SCENARIO}"
  echo "hostname=$(hostname)"
  echo "date=$(date -Iseconds)"
  echo "cpu_model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)"
  print_topology_preflight
  echo "online_cpus=$(cat /sys/devices/system/cpu/online)"
  echo "pqos_present=$([[ -x $(command -v pqos 2>/dev/null) ]] && echo yes || echo no)"
  echo "turbostat_present=$([[ -x $(command -v turbostat 2>/dev/null) ]] && echo yes || echo no)"
  echo "perf_present=$([[ -x $(command -v perf 2>/dev/null) ]] && echo yes || echo no)"
  echo "cpupower_present=$([[ -x $(command -v cpupower 2>/dev/null) ]] && echo yes || echo no)"
  echo "msr_present=$([[ -x $(command -v rdmsr 2>/dev/null) && -x $(command -v wrmsr 2>/dev/null) ]] && echo yes || echo no)"
  echo "uncore_present=$([[ -d ${UNC_PATH} ]] && echo yes || echo no)"
  echo "resctrl_present=$([[ -d /sys/fs/resctrl || -d /sys/fs/resctrl/info ]] && echo yes || echo no)"
  echo "rapl_package_path=${RAPL_PACKAGE_PATH:-}"
  echo "rapl_dram_path=${RAPL_DRAM_PATH:-}"
} > "${PRECHECK_TXT}"

if [[ "${SCENARIO}" == "preflight" ]]; then
  python3 - "${PRECHECK_TXT}" "${SUMMARY_JSON}" <<'PY'
import json
import sys
from pathlib import Path

preflight = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    preflight[key] = value

summary = {"scenario": "preflight", "preflight": preflight}
Path(sys.argv[2]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
  exit 0
fi

trap_add '[[ -n ${TS_PID_VALIDATION:-} ]] && stop_turbostat "${TS_PID_VALIDATION}" || true' EXIT
trap_add 'uncore_restore_snapshot || true' EXIT
trap_add '[[ ${LLC_RESTORE_REGISTERED:-false} == true ]] && restore_llc_defaults || true' EXIT

PF_SNAPSHOT_OK=false
if [[ -n "${PREFETCH_SPEC:-}" ]]; then
  PF_DISABLE_MASK="$(pf_parse_spec_to_disable_mask "${PREFETCH_SPEC}")"
  if pf_snapshot_for_core "${WORKLOAD_CPU}"; then
    PF_SNAPSHOT_OK=true
  fi
  trap_add '[[ ${PF_SNAPSHOT_OK:-false} == true ]] && pf_restore_for_core "${WORKLOAD_CPU}" || true' EXIT
  pf_apply_for_core "${WORKLOAD_CPU}" "${PF_DISABLE_MASK}"
  pf_verify_for_core "${WORKLOAD_CPU}" || true
fi

if [[ -n "${TURBO_STATE:-}" ]]; then
  if [[ "${TURBO_STATE,,}" == "off" ]]; then
    echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
    echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || true
  elif [[ "${TURBO_STATE,,}" == "on" ]]; then
    echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
    echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1 || true
  fi
fi

CPU_LIST="$(build_cpu_list)"
if [[ "${COREFREQ_REQUEST,,}" != "off" && -n "${COREFREQ_REQUEST}" ]]; then
  PIN_FREQ_KHZ="$(awk -v ghz="${COREFREQ_REQUEST}" 'BEGIN{printf "%.0f", ghz * 1000000}')"
  IFS=',' read -r -a cpu_array <<< "${CPU_LIST}"
  for cpu in "${cpu_array[@]}"; do
    sudo cpupower -c "${cpu}" frequency-set -g userspace >/dev/null 2>&1 || true
    sudo cpupower -c "${cpu}" frequency-set -d "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
    sudo cpupower -c "${cpu}" frequency-set -u "${PIN_FREQ_KHZ}KHz" >/dev/null 2>&1 || true
  done
  core_apply_pin_khz_softcheck "${PIN_FREQ_KHZ}" "${cpu_array[@]}"
fi

if [[ "${UNCORE_REQUEST,,}" != "off" && -n "${UNCORE_REQUEST}" ]]; then
  uncore_apply_pin_ghz "${UNCORE_REQUEST}"
fi

if [[ "${LLC_REQUEST}" != "100" ]]; then
  llc_core_setup_once --llc "${LLC_REQUEST}" --wl-core "${WORKLOAD_CPU}" --tools-core "${TOOLS_CPU}"
fi

RAPL_WINDOW_US="${RAPL_WINDOW_US:-10000}"
if [[ "${PKGCAP_REQUEST,,}" != "off" && -n "${RAPL_PACKAGE_PATH:-}" ]]; then
  rapl_apply_power_limit_watts "${RAPL_PACKAGE_PATH}" "${PKGCAP_REQUEST}" "${RAPL_WINDOW_US}"
fi
if [[ "${DRAMCAP_REQUEST,,}" != "off" && -n "${RAPL_DRAM_PATH:-}" ]]; then
  rapl_apply_power_limit_watts "${RAPL_DRAM_PATH}" "${DRAMCAP_REQUEST}"
fi

pkg_energy_before=""
pkg_energy_after=""
dram_energy_before=""
dram_energy_after=""
pkg_energy_before="$(rapl_read_energy_uj "${RAPL_PACKAGE_PATH}" 2>/dev/null || true)"
dram_energy_before="$(rapl_read_energy_uj "${RAPL_DRAM_PATH}" 2>/dev/null || true)"

if $run_turbostat && command -v turbostat >/dev/null 2>&1; then
  start_turbostat validation "${TS_INTERVAL}" "${TOOLS_CPU}" "${TURBOSTAT_TXT}" "TS_PID_VALIDATION" || true
fi

benchmark_cmd=(
  taskset -c "${WORKLOAD_CPU}"
  "${BENCHMARK_BIN}"
  --mode "${BENCH_MODE}"
  --seconds "${BENCH_SECONDS}"
  --iterations "${BENCH_ITERATIONS}"
  --size-mb "${BENCH_SIZE_MB}"
  --stride-bytes "${BENCH_STRIDE_BYTES}"
  --threads "${BENCH_THREADS}"
)

if $run_perf && command -v perf >/dev/null 2>&1; then
  perf stat -x, -o "${PERF_CSV}" -e cycles,ref-cycles,instructions,cache-references,cache-misses -- \
    "${benchmark_cmd[@]}" > "${BENCH_JSON}"
else
  "${benchmark_cmd[@]}" > "${BENCH_JSON}"
fi

pkg_energy_after="$(rapl_read_energy_uj "${RAPL_PACKAGE_PATH}" 2>/dev/null || true)"
dram_energy_after="$(rapl_read_energy_uj "${RAPL_DRAM_PATH}" 2>/dev/null || true)"

if [[ -n ${TS_PID_VALIDATION:-} ]]; then
  stop_turbostat "${TS_PID_VALIDATION}" || true
  unset TS_PID_VALIDATION
fi

python3 - "${BENCH_JSON}" "${SUMMARY_JSON}" "${PRECHECK_TXT}" "${PERF_CSV}" "${TURBOSTAT_TXT}" \
  "${pkg_energy_before}" "${pkg_energy_after}" "${dram_energy_before}" "${dram_energy_after}" \
  "${RAPL_PACKAGE_PATH:-}" "${RAPL_DRAM_PATH:-}" "${PKGCAP_REQUEST}" "${DRAMCAP_REQUEST}" \
  "${COREFREQ_REQUEST}" "${UNCORE_REQUEST}" "${LLC_REQUEST}" "${PREFETCH_SPEC}" "${TURBO_STATE}" <<'PY'
import json
import sys
from pathlib import Path

(bench_path, summary_path, preflight_path, perf_path, turbostat_path,
 pkg_before, pkg_after, dram_before, dram_after, pkg_path, dram_path,
 pkg_request, dram_request, corefreq_request, uncore_request, llc_request,
 prefetch_request, turbo_request) = sys.argv[1:]

bench_payload = {}
if Path(bench_path).exists():
    text = Path(bench_path).read_text().strip()
    if text:
        bench_payload = json.loads(text.splitlines()[-1])

preflight = {}
for line in Path(preflight_path).read_text().splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        preflight[key] = value

def delta(before: str, after: str):
    if not before or not after:
        return None
    try:
        return int(after) - int(before)
    except ValueError:
        return None

summary = {
    "scenario": "benchmark",
    "benchmark": bench_payload,
    "preflight": preflight,
    "requests": {
        "turbo": turbo_request or "unchanged",
        "pkgcap": pkg_request,
        "dramcap": dram_request,
        "corefreq": corefreq_request,
        "uncorefreq": uncore_request,
        "llc": llc_request,
        "prefetcher": prefetch_request or "unchanged",
    },
    "rapl": {
        "package_path": pkg_path or None,
        "dram_path": dram_path or None,
        "package_energy_delta_uj": delta(pkg_before, pkg_after),
        "dram_energy_delta_uj": delta(dram_before, dram_after),
    },
    "artifacts": {
        "bench_json": bench_path,
        "perf_csv": perf_path if Path(perf_path).exists() else None,
        "turbostat_txt": turbostat_path if Path(turbostat_path).exists() else None,
        "preflight_txt": preflight_path,
    },
}

Path(summary_path).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
