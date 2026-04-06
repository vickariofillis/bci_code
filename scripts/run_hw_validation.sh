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
BENCH_SIZE_KB="${BENCH_SIZE_KB:-0}"
BENCH_STRIDE_BYTES="${BENCH_STRIDE_BYTES:-64}"
BENCH_THREADS="${BENCH_THREADS:-1}"
BENCH_READ_ONLY="${BENCH_READ_ONLY:-false}"
TS_INTERVAL="${TS_INTERVAL:-0.25}"
PQOS_INTERVAL_SEC="${PQOS_INTERVAL_SEC:-0.5}"
PERF_EVENTS="${PERF_EVENTS:-cycles,ref-cycles,instructions,cache-references,cache-misses}"
PREFETCH_SPEC="${PREFETCH_SPEC:-}"
PF_SCOPE="${PF_SCOPE:-siblings}"
TURBO_STATE="${TURBO_STATE:-}"
PKGCAP_REQUEST="${PKGCAP_REQUEST:-off}"
DRAMCAP_REQUEST="${DRAMCAP_REQUEST:-off}"
COREFREQ_REQUEST="${COREFREQ_REQUEST:-off}"
UNCORE_REQUEST="${UNCORE_REQUEST:-off}"
LLC_REQUEST="${LLC_REQUEST:-100}"
MBA_REQUEST="${MBA_REQUEST:-off}"
MBA_SCOPE="${MBA_SCOPE:-cpu}"
CPU_TOPOLOGY_ONLY=false
run_perf=true
run_turbostat=true

usage() {
  cat <<'EOF'
Usage: run_hw_validation.sh [options]

Options:
  --cpu-topology                    Print resolved CPU topology/capacity and exit
  --scenario <preflight|benchmark>   Validation mode (default: benchmark)
  --tag <label>                      Prefix for result files
  --mode <compute|stream|stride|ptrchase|cachefit|adjacent|stridechase|pairchase|pairdelay>
  --seconds <float>                  Fixed-duration benchmark runtime
  --iterations <count>               Fixed-iteration benchmark count
  --size-mb <count>                  Working-set size in MiB
  --size-kb <count>                  Working-set size in KiB (overrides MiB if set)
  --stride-bytes <count>             Stride size for stride/cachefit modes
  --threads <count>                  Benchmark thread count (default: 1)
  --read-only <on|off>               Use load-only access pattern when supported
  --perf-events <csv>                perf stat event list (default: common cache/core set)
  --workload-cpu <id>                Explicit workload CPU
  --tools-cpu <id>                   Explicit tools CPU
  --turbo <on|off>                   Requested turbo state
  --pkgcap <watts|off>               Package RAPL limit
  --dramcap <watts|off>              DRAM RAPL limit
  --corefreq <ghz|off>               Requested core frequency
  --uncorefreq <ghz|off>             Requested uncore frequency
  --llc <percent>                    Requested LLC allocation percentage
  --mba <percent|off>                Requested MBA percentage for workload group
  --mba-scope <pid|cpu>              MBA scoping mode (default: cpu)
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
    --cpu-topology) CPU_TOPOLOGY_ONLY=true ;;
    --scenario) SCENARIO="$2"; shift ;;
    --tag) VALIDATION_TAG="$2"; shift ;;
    --mode) BENCH_MODE="$2"; shift ;;
    --seconds) BENCH_SECONDS="$2"; shift ;;
    --iterations) BENCH_ITERATIONS="$2"; shift ;;
    --size-mb) BENCH_SIZE_MB="$2"; shift ;;
    --size-kb) BENCH_SIZE_KB="$2"; shift ;;
    --stride-bytes) BENCH_STRIDE_BYTES="$2"; shift ;;
    --threads) BENCH_THREADS="$2"; shift ;;
    --read-only) [[ "${2,,}" == "on" ]] && BENCH_READ_ONLY=true || BENCH_READ_ONLY=false; shift ;;
    --perf-events) PERF_EVENTS="$2"; shift ;;
    --workload-cpu) WORKLOAD_CPU="$2"; shift ;;
    --tools-cpu) TOOLS_CPU="$2"; shift ;;
    --turbo) TURBO_STATE="$2"; shift ;;
    --pkgcap) PKGCAP_REQUEST="$2"; shift ;;
    --dramcap) DRAMCAP_REQUEST="$2"; shift ;;
    --corefreq) COREFREQ_REQUEST="$2"; shift ;;
    --uncorefreq) UNCORE_REQUEST="$2"; shift ;;
    --llc) LLC_REQUEST="$2"; shift ;;
    --mba) MBA_REQUEST="$2"; shift ;;
    --mba-scope) MBA_SCOPE="$2"; shift ;;
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
if $CPU_TOPOLOGY_ONLY; then
  print_cpu_topology_report "${TOOLS_CPU_COUNT_RESOLVED:-1}" "${RESERVED_BACKGROUND_CPU_COUNT:-1}"
  echo "Selected socket: ${SELECTED_SOCKET_ID:-unknown}"
  echo "Resolved workload CPUs: ${WORKLOAD_CPUS:-${WORKLOAD_CPU:-}}"
  echo "Resolved tool CPUs: ${TOOLS_CPUS:-${TOOLS_CPU:-}}"
  echo "Reserved background CPUs: ${BACKGROUND_CPUS:-<none>}"
  exit 0
fi
rapl_discover_for_cpu "${WORKLOAD_CPU}"

BENCH_JSON="${OUTDIR}/${VALIDATION_TAG}_bench.json"
OBSERVER_BENCH_JSON="${OUTDIR}/${VALIDATION_TAG}_observer_bench.json"
SUMMARY_JSON="${OUTDIR}/${VALIDATION_TAG}_summary.json"
PERF_CSV="${OUTDIR}/${VALIDATION_TAG}_perf.csv"
TURBOSTAT_TXT="${OUTDIR}/${VALIDATION_TAG}_turbostat.txt"
PRECHECK_TXT="${OUTDIR}/${VALIDATION_TAG}_preflight.txt"
PKG_STATE_BEFORE_JSON="${OUTDIR}/${VALIDATION_TAG}_pkg_state_before.json"
PKG_STATE_AFTER_JSON="${OUTDIR}/${VALIDATION_TAG}_pkg_state_after.json"
DRAM_STATE_BEFORE_JSON="${OUTDIR}/${VALIDATION_TAG}_dram_state_before.json"
DRAM_STATE_AFTER_JSON="${OUTDIR}/${VALIDATION_TAG}_dram_state_after.json"
UNCORE_STATE_JSON="${OUTDIR}/${VALIDATION_TAG}_uncore_state.json"
UNCORE_SAMPLES_JSONL="${OUTDIR}/${VALIDATION_TAG}_uncore_samples.jsonl"
PREFETCH_STATE_JSON="${OUTDIR}/${VALIDATION_TAG}_prefetch_state.json"
MBA_STATE_JSON="${OUTDIR}/${VALIDATION_TAG}_mba_state.json"
MBA_ASSIGNMENTS_JSONL="${OUTDIR}/${VALIDATION_TAG}_mba_assignments.jsonl"
RESCTRL_INFO_TXT="${OUTDIR}/${VALIDATION_TAG}_resctrl_info.txt"

{
  echo "scenario=${SCENARIO}"
  echo "hostname=$(hostname)"
  echo "date=$(date -Iseconds)"
  echo "cpu_model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)"
  print_topology_preflight
  echo "online_cpus=$(cat /sys/devices/system/cpu/online)"
  echo "selected_socket=${SELECTED_SOCKET_ID:-}"
  echo "resolved_workload_cpus=${WORKLOAD_CPUS:-${WORKLOAD_CPU:-}}"
  echo "resolved_tools_cpus=${TOOLS_CPUS:-${TOOLS_CPU:-}}"
  echo "background_cpus=${BACKGROUND_CPUS:-}"
  echo "hw_control_bench_present=$([[ -x ${BENCHMARK_BIN} ]] && echo yes || echo no)"
  echo "toplev_present=$([[ -x /local/tools/pmu-tools/toplev ]] && echo yes || echo no)"
  echo "pcm_present=$([[ -x /local/tools/pcm/build/bin/pcm || -x $(command -v pcm 2>/dev/null) ]] && echo yes || echo no)"
  echo "pqos_present=$([[ -x $(command -v pqos 2>/dev/null) ]] && echo yes || echo no)"
  echo "turbostat_present=$([[ -x $(command -v turbostat 2>/dev/null) ]] && echo yes || echo no)"
  echo "perf_present=$([[ -x $(command -v perf 2>/dev/null) ]] && echo yes || echo no)"
  echo "cpupower_present=$([[ -x $(command -v cpupower 2>/dev/null) ]] && echo yes || echo no)"
  echo "msr_present=$([[ -x $(command -v rdmsr 2>/dev/null) && -x $(command -v wrmsr 2>/dev/null) ]] && echo yes || echo no)"
  intel_speed_select_path="$(bci_locate_intel_speed_select || true)"
  echo "intel_speed_select_present=$([[ -n ${intel_speed_select_path} ]] && echo yes || echo no)"
  echo "intel_speed_select_path=${intel_speed_select_path}"
  echo "uncore_present=$({ uncore_probe_present; } >/dev/null 2>&1 && echo yes || echo no)"
  echo "resctrl_present=$([[ -d /sys/fs/resctrl || -d /sys/fs/resctrl/info ]] && echo yes || echo no)"
  echo "rapl_package_path=${RAPL_PACKAGE_PATH:-}"
  echo "rapl_dram_path=${RAPL_DRAM_PATH:-}"
  echo "mba_request=${MBA_REQUEST}"
  echo "mba_scope=${MBA_SCOPE}"
  if [[ -d /sys/fs/resctrl/info/MB ]]; then
    echo "mba_present=yes"
    echo "mba_bandwidth_gran=$(cat /sys/fs/resctrl/info/MB/bandwidth_gran 2>/dev/null || true)"
    echo "mba_min_bandwidth=$(cat /sys/fs/resctrl/info/MB/min_bandwidth 2>/dev/null || true)"
    echo "mba_num_closids=$(cat /sys/fs/resctrl/info/MB/num_closids 2>/dev/null || true)"
  else
    echo "mba_present=no"
  fi
} > "${PRECHECK_TXT}"

if [[ "${SCENARIO}" == "preflight" ]]; then
  python3 - "${PRECHECK_TXT}" "${SUMMARY_JSON}" <<'PY'
import json
import re
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
trap_add 'core_restore_snapshot || true' EXIT
trap_add 'turbo_restore_snapshot || true' EXIT
trap_add 'uncore_restore_snapshot || true' EXIT
trap_add '[[ ${LLC_RESTORE_REGISTERED:-false} == true ]] && restore_llc_defaults || true' EXIT
trap_add '[[ ${MBA_RESTORE_REGISTERED:-false} == true ]] && restore_mba_defaults || true' EXIT
trap_add 'rapl_restore_domain "${RAPL_PACKAGE_PATH:-}" || true; rapl_restore_domain "${RAPL_DRAM_PATH:-}" || true' EXIT

record_uncore_sample() {
  python3 - "${UNC_PATH}" <<'PY'
import json
import pathlib
import time
import sys

root = pathlib.Path(sys.argv[1])
payload = {"timestamp": time.time(), "dies": []}
for path in sorted(root.glob("package_*_die_*")):
    entry = {"die": path.name}
    for name in ("min_freq_khz", "max_freq_khz"):
        candidate = path / name
        entry[name] = candidate.read_text(encoding="utf-8").strip() if candidate.exists() else None
    payload["dies"].append(entry)
print(json.dumps(payload, sort_keys=True))
PY
}

record_mba_assignment_sample() {
  local ids_csv="${1:-}"
  python3 - "${ids_csv}" <<'PY'
import json
import sys
import time

raw = sys.argv[1].strip()
ids = [int(tok) for tok in raw.split(",") if tok]
print(json.dumps({"timestamp": time.time(), "task_ids": ids}, sort_keys=True))
PY
}

start_runtime_monitors() {
  local bench_pid="${1:?missing bench pid}"

  if [[ -d "${UNC_PATH}" ]]; then
    : > "${UNCORE_SAMPLES_JSONL}"
    (
      while kill -0 "${bench_pid}" 2>/dev/null; do
        record_uncore_sample >> "${UNCORE_SAMPLES_JSONL}" || true
        sleep "${TS_INTERVAL}"
      done
      record_uncore_sample >> "${UNCORE_SAMPLES_JSONL}" || true
    ) &
    UNC_SAMPLER_PID=$!
  fi

  if [[ "${MBA_REQUEST,,}" != "off" && "${MBA_SCOPE}" == "pid" ]]; then
    : > "${MBA_ASSIGNMENTS_JSONL}"
    (
      while kill -0 "${bench_pid}" 2>/dev/null; do
        local ids ids_csv tid
        ids="$(mba_collect_task_ids "${bench_pid}" 2>/dev/null || true)"
        if [[ -n "${ids}" ]]; then
          while IFS= read -r tid; do
            [[ -n "${tid}" ]] || continue
            mba_assign_tasks "${RDT_GROUP_WL}" "${tid}" || true
          done <<< "${ids}"
          ids_csv="$(printf '%s\n' "${ids}" | paste -sd, -)"
          record_mba_assignment_sample "${ids_csv}" >> "${MBA_ASSIGNMENTS_JSONL}" || true
          printf '%s\n' "$(mba_group_state_json "${RDT_GROUP_WL}")" > "${MBA_STATE_JSON}"
        fi
        sleep 0.2
      done
      ids="$(mba_collect_task_ids "${bench_pid}" 2>/dev/null || true)"
      if [[ -n "${ids}" ]]; then
        while IFS= read -r tid; do
          [[ -n "${tid}" ]] || continue
          mba_assign_tasks "${RDT_GROUP_WL}" "${tid}" || true
        done <<< "${ids}"
        ids_csv="$(printf '%s\n' "${ids}" | paste -sd, -)"
        record_mba_assignment_sample "${ids_csv}" >> "${MBA_ASSIGNMENTS_JSONL}" || true
      fi
      printf '%s\n' "$(mba_group_state_json "${RDT_GROUP_WL}")" > "${MBA_STATE_JSON}"
    ) &
    MBA_REFRESH_PID=$!
  elif [[ "${MBA_REQUEST,,}" != "off" ]]; then
    printf '%s\n' "$(mba_group_state_json "${RDT_GROUP_WL}")" > "${MBA_STATE_JSON}"
  fi
}

stop_runtime_monitors() {
  if [[ -n ${UNC_SAMPLER_PID:-} ]]; then
    wait "${UNC_SAMPLER_PID}" 2>/dev/null || true
    unset UNC_SAMPLER_PID
  fi
  if [[ -n ${MBA_REFRESH_PID:-} ]]; then
    wait "${MBA_REFRESH_PID}" 2>/dev/null || true
    unset MBA_REFRESH_PID
  fi
}

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
  turbo_snapshot_current || die "Failed to snapshot current turbo state"
  turbo_apply_state "${TURBO_STATE}" || die "Failed to apply requested turbo state '${TURBO_STATE}'"
  turbo_report_state "${TURBO_STATE,,}"
fi

CPU_LIST="$(build_cpu_list)"
if [[ "${COREFREQ_REQUEST,,}" != "off" && -n "${COREFREQ_REQUEST}" ]]; then
  PIN_FREQ_KHZ="$(awk -v ghz="${COREFREQ_REQUEST}" 'BEGIN{printf "%.0f", ghz * 1000000}')"
  IFS=',' read -r -a cpu_array <<< "${CPU_LIST}"
  core_snapshot_current "${cpu_array[@]}" || true
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

if [[ "${MBA_REQUEST,,}" != "off" && -n "${MBA_REQUEST}" ]]; then
  mba_setup_once --mba "${MBA_REQUEST}" --mba-scope "${MBA_SCOPE}" --wl-cpus "${WORKLOAD_CPUS}" --tools-cpus "${TOOLS_CPUS}"
fi

printf '%s\n' "$(rapl_domain_state_json "${RAPL_PACKAGE_PATH:-}")" > "${PKG_STATE_BEFORE_JSON}"
printf '%s\n' "$(rapl_domain_state_json "${RAPL_DRAM_PATH:-}")" > "${DRAM_STATE_BEFORE_JSON}"

RAPL_WINDOW_US="${RAPL_WINDOW_US:-10000}"
if [[ "${PKGCAP_REQUEST,,}" != "off" && -n "${RAPL_PACKAGE_PATH:-}" ]]; then
  rapl_snapshot_domain "${RAPL_PACKAGE_PATH}"
  rapl_apply_power_limit_watts "${RAPL_PACKAGE_PATH}" "${PKGCAP_REQUEST}" "${RAPL_WINDOW_US}"
fi
if [[ "${DRAMCAP_REQUEST,,}" != "off" && -n "${RAPL_DRAM_PATH:-}" ]]; then
  if [[ -e "${RAPL_DRAM_PATH}/enabled" ]]; then
    rapl_enable_domain "${RAPL_DRAM_PATH}" || true
  fi
  rapl_snapshot_domain "${RAPL_DRAM_PATH}"
  rapl_apply_power_limit_watts "${RAPL_DRAM_PATH}" "${DRAMCAP_REQUEST}" "${RAPL_WINDOW_US}"
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
  taskset -c "${WORKLOAD_CPUS}"
  "${BENCHMARK_BIN}"
  --mode "${BENCH_MODE}"
  --seconds "${BENCH_SECONDS}"
  --iterations "${BENCH_ITERATIONS}"
  --size-mb "${BENCH_SIZE_MB}"
  --stride-bytes "${BENCH_STRIDE_BYTES}"
  --threads "${BENCH_THREADS}"
)

if [[ "${BENCH_SIZE_KB}" != "0" && -n "${BENCH_SIZE_KB}" ]]; then
  benchmark_cmd+=(--size-kb "${BENCH_SIZE_KB}")
fi

if [[ "${BENCH_READ_ONLY}" == true ]]; then
  benchmark_cmd+=(--read-only)
fi

observer_cmd=()
observer_pid=""
if [[ "${MBA_REQUEST,,}" != "off" && -n "${MBA_REQUEST}" ]]; then
  observer_cmd=(
    taskset -c "${TOOLS_CPUS}"
    "${BENCHMARK_BIN}"
    --mode stream
    --seconds "${BENCH_SECONDS}"
    --iterations 0
    --size-mb "${BENCH_SIZE_MB}"
    --threads "${TOOLS_CPU_COUNT_RESOLVED:-1}"
  )
fi

if [[ ${#observer_cmd[@]} -gt 0 ]]; then
  "${observer_cmd[@]}" > "${OBSERVER_BENCH_JSON}" &
  observer_pid=$!
fi

if $run_perf && command -v perf >/dev/null 2>&1; then
  (
    perf stat -x, -o "${PERF_CSV}" -e "${PERF_EVENTS}" -- \
      "${benchmark_cmd[@]}" > "${BENCH_JSON}"
  ) &
  bench_pid=$!
  start_runtime_monitors "${bench_pid}"
  wait "${bench_pid}"
else
  (
    "${benchmark_cmd[@]}" > "${BENCH_JSON}"
  ) &
  bench_pid=$!
  start_runtime_monitors "${bench_pid}"
  wait "${bench_pid}"
fi

stop_runtime_monitors

if [[ -n "${observer_pid}" ]]; then
  wait "${observer_pid}"
fi

pkg_energy_after="$(rapl_read_energy_uj "${RAPL_PACKAGE_PATH}" 2>/dev/null || true)"
dram_energy_after="$(rapl_read_energy_uj "${RAPL_DRAM_PATH}" 2>/dev/null || true)"

printf '%s\n' "$(rapl_domain_state_json "${RAPL_PACKAGE_PATH:-}")" > "${PKG_STATE_AFTER_JSON}"
printf '%s\n' "$(rapl_domain_state_json "${RAPL_DRAM_PATH:-}")" > "${DRAM_STATE_AFTER_JSON}"

python3 - "${UNCORE_REQUEST}" "${UNC_PATH}" <<'PY' > "${UNCORE_STATE_JSON}"
import json
import pathlib
import sys

request = sys.argv[1]
root = pathlib.Path(sys.argv[2])
payload = {"request": request or "off", "dies": []}
for path in sorted(root.glob("package_*_die_*")):
    entry = {"die": path.name}
    for name in ("initial_min_freq_khz", "initial_max_freq_khz", "min_freq_khz", "max_freq_khz"):
        candidate = path / name
        entry[name] = candidate.read_text(encoding="utf-8").strip() if candidate.exists() else None
    payload["dies"].append(entry)
print(json.dumps(payload, sort_keys=True))
PY

python3 - "${WORKLOAD_CPU}" <<'PY' > "${PREFETCH_STATE_JSON}"
import json
import subprocess
import sys

cpu = sys.argv[1].strip()
payload = {"cpu": cpu or None, "siblings": []}
if cpu:
    try:
        sibs = subprocess.check_output(
            ["bash", "-lc", f"cat /sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"],
            text=True,
        ).strip()
        for token in sibs.split(","):
            token = token.strip()
            if not token:
                continue
            if "-" in token:
                start, end = token.split("-", 1)
                ids = range(int(start), int(end) + 1)
            else:
                ids = [int(token)]
            for sibling in ids:
                try:
                    value = subprocess.check_output(
                        ["sudo", "rdmsr", "-p", str(sibling), "0x1a4", "-0"],
                        text=True,
                    ).strip()
                except Exception:
                    value = None
                payload["siblings"].append({"cpu": sibling, "msr_0x1a4": value})
    except Exception:
        pass
print(json.dumps(payload, sort_keys=True))
PY

if [[ -d /sys/fs/resctrl ]]; then
  {
    echo "[schemata]"
    cat /sys/fs/resctrl/schemata 2>/dev/null || true
    echo
    echo "[info]"
    find /sys/fs/resctrl/info -maxdepth 2 -type f -print -exec cat {} \; 2>/dev/null || true
  } > "${RESCTRL_INFO_TXT}"
fi

if [[ "${MBA_REQUEST,,}" != "off" && -n "${MBA_REQUEST}" ]]; then
  if [[ ! -s "${MBA_STATE_JSON}" ]]; then
    printf '%s\n' "$(mba_group_state_json "${RDT_GROUP_WL}")" > "${MBA_STATE_JSON}"
  fi
else
  printf '%s\n' "null" > "${MBA_STATE_JSON}"
fi

if [[ -n ${TS_PID_VALIDATION:-} ]]; then
  stop_turbostat "${TS_PID_VALIDATION}" || true
  unset TS_PID_VALIDATION
fi

python3 - "${BENCH_JSON}" "${SUMMARY_JSON}" "${PRECHECK_TXT}" "${PERF_CSV}" "${TURBOSTAT_TXT}" \
  "${pkg_energy_before}" "${pkg_energy_after}" "${dram_energy_before}" "${dram_energy_after}" \
  "${RAPL_PACKAGE_PATH:-}" "${RAPL_DRAM_PATH:-}" "${PKGCAP_REQUEST}" "${DRAMCAP_REQUEST}" \
  "${COREFREQ_REQUEST}" "${UNCORE_REQUEST}" "${LLC_REQUEST}" "${PREFETCH_SPEC}" "${TURBO_STATE}" \
  "${MBA_REQUEST}" "${MBA_SCOPE}" "${WORKLOAD_CPU}" "${PKG_STATE_BEFORE_JSON}" "${PKG_STATE_AFTER_JSON}" \
  "${DRAM_STATE_BEFORE_JSON}" "${DRAM_STATE_AFTER_JSON}" "${UNCORE_STATE_JSON}" "${PREFETCH_STATE_JSON}" \
  "${MBA_STATE_JSON}" "${OBSERVER_BENCH_JSON}" "${RESCTRL_INFO_TXT}" "${UNCORE_SAMPLES_JSONL}" "${MBA_ASSIGNMENTS_JSONL}" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

(bench_path, summary_path, preflight_path, perf_path, turbostat_path,
 pkg_before, pkg_after, dram_before, dram_after, pkg_path, dram_path,
 pkg_request, dram_request, corefreq_request, uncore_request, llc_request,
 prefetch_request, turbo_request, mba_request, mba_scope, workload_cpu,
 pkg_state_before_path, pkg_state_after_path, dram_state_before_path, dram_state_after_path,
 uncore_state_path, prefetch_state_path, mba_state_path, observer_bench_path, resctrl_info_path,
 uncore_samples_path, mba_assignments_path) = sys.argv[1:]

bench_payload = {}
if Path(bench_path).exists():
    text = Path(bench_path).read_text().strip()
    if text:
        last_line = text.splitlines()[-1]
        sanitized = re.sub(r'(?<=:)(-?inf|nan)(?=[,}])', 'null', last_line)
        bench_payload = json.loads(sanitized)

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

def load_json_file(path_text: str):
    path = Path(path_text)
    if not path.exists():
        return None
    text = path.read_text().strip()
    if not text:
        return None
    return json.loads(text)

def load_json_lines(path_text: str):
    path = Path(path_text)
    if not path.exists():
        return []
    rows = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue
    return rows

def median(values):
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0

def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return ordered[lo]
    frac = pos - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac

perf_rows = []
perf_metrics = {}
if Path(perf_path).exists():
    for raw in Path(perf_path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(",")
        if len(parts) < 3:
            continue
        value = parts[0].strip()
        unit = parts[1].strip()
        event = parts[2].strip()
        row = {"value_raw": value, "unit": unit or None, "event": event}
        perf_rows.append(row)
        try:
            perf_metrics[event] = float(value)
        except ValueError:
            perf_metrics[event] = value

turbostat_rows = []
if Path(turbostat_path).exists():
    headers = None
    for raw in Path(turbostat_path).read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        if headers is None and "CPU" in line and "Busy%" in line and "Bzy_MHz" in line:
            headers = re.split(r"\s+", line)
            continue
        if headers is None:
            continue
        parts = re.split(r"\s+", line)
        if len(parts) != len(headers):
            continue
        row = dict(zip(headers, parts))
        if row.get("CPU") != workload_cpu:
            continue
        try:
            busy = float(row.get("Busy%", "nan"))
            bzy = float(row.get("Bzy_MHz", "nan"))
        except ValueError:
            continue
        turbostat_rows.append({"busy_pct": busy, "bzy_mhz": bzy})

busy_filtered = [row["bzy_mhz"] for row in turbostat_rows if row["busy_pct"] >= 70.0]
busy_samples = busy_filtered if busy_filtered else [row["bzy_mhz"] for row in turbostat_rows]
busy_pcts = [row["busy_pct"] for row in turbostat_rows]
pkg_watts = []
ram_watts = []
for row in turbostat_rows:
    raw_pkg = row.get("PkgWatt")
    raw_ram = row.get("RAMWatt")
    try:
        if raw_pkg not in (None, "", "-"):
            pkg_watts.append(float(raw_pkg))
    except ValueError:
        pass
    try:
        if raw_ram not in (None, "", "-"):
            ram_watts.append(float(raw_ram))
    except ValueError:
        pass

pkg_delta = delta(pkg_before, pkg_after)
dram_delta = delta(dram_before, dram_after)
elapsed = bench_payload.get("elapsed_sec")
package_avg_watts = (pkg_delta / 1_000_000.0 / elapsed) if pkg_delta is not None and elapsed else None
dram_avg_watts = (dram_delta / 1_000_000.0 / elapsed) if dram_delta is not None and elapsed else None

observer_payload = {}
if Path(observer_bench_path).exists():
    text = Path(observer_bench_path).read_text().strip()
    if text:
      try:
        observer_payload = json.loads(text.splitlines()[-1])
      except Exception:
        observer_payload = {}

uncore_state = load_json_file(uncore_state_path)
uncore_samples = load_json_lines(uncore_samples_path)
mba_group_state = load_json_file(mba_state_path)
mba_assignment_samples = load_json_lines(mba_assignments_path)
unique_mba_task_ids = sorted({
    int(task_id)
    for sample in mba_assignment_samples
    for task_id in sample.get("task_ids", [])
})

summary = {
    "scenario": "benchmark",
    "benchmark": bench_payload,
    "observer_benchmark": observer_payload or None,
    "preflight": preflight,
    "requests": {
        "turbo": turbo_request or "unchanged",
        "pkgcap": pkg_request,
        "dramcap": dram_request,
        "corefreq": corefreq_request,
        "uncorefreq": uncore_request,
        "llc": llc_request,
        "mba": mba_request,
        "mba_scope": mba_scope,
        "prefetcher": prefetch_request or "unchanged",
    },
    "rapl": {
        "package_path": pkg_path or None,
        "dram_path": dram_path or None,
        "package_energy_delta_uj": delta(pkg_before, pkg_after),
        "dram_energy_delta_uj": delta(dram_before, dram_after),
        "package_avg_watts": package_avg_watts,
        "dram_avg_watts": dram_avg_watts,
        "package_state_before": load_json_file(pkg_state_before_path),
        "package_state_after": load_json_file(pkg_state_after_path),
        "dram_state_before": load_json_file(dram_state_before_path),
        "dram_state_after": load_json_file(dram_state_after_path),
    },
    "turbostat": {
        "workload_cpu": workload_cpu,
        "sample_count": len(turbostat_rows),
        "busy_filtered_sample_count": len(busy_filtered),
        "median_busy_pct": median(busy_pcts),
        "median_bzy_mhz": median(busy_samples),
        "p95_bzy_mhz": percentile(busy_samples, 0.95),
        "median_pkg_watt": median(pkg_watts),
        "median_ram_watt": median(ram_watts),
    },
    "uncore": {
        "state": uncore_state,
        "runtime_samples": uncore_samples,
        "runtime_sample_count": len(uncore_samples),
    },
    "prefetch": load_json_file(prefetch_state_path),
    "mba": {
        "group_state": mba_group_state,
        "assignment_samples": mba_assignment_samples,
        "assignment_sample_count": len(mba_assignment_samples),
        "unique_task_ids": unique_mba_task_ids,
    },
    "artifacts": {
        "bench_json": bench_path,
        "observer_bench_json": observer_bench_path if Path(observer_bench_path).exists() else None,
        "perf_csv": perf_path if Path(perf_path).exists() else None,
        "turbostat_txt": turbostat_path if Path(turbostat_path).exists() else None,
        "preflight_txt": preflight_path,
        "resctrl_info_txt": resctrl_info_path if Path(resctrl_info_path).exists() else None,
    },
    "perf": {
        "events": perf_rows,
        "metrics": perf_metrics,
    },
}

Path(summary_path).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))
PY
