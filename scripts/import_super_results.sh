#!/usr/bin/env bash
# Stage super_run archives into stats_dir with workload config layer.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: import_super_results.sh --archive super_<tag>.tgz --stats-dir /path/to/stats_dir [--workcfg NAME]

Required flags:
  --archive    Path to the super_<tag>.tgz produced by scripts/get_results.sh
  --stats-dir  Destination stats directory (bci_r stats_dir root)

Optional flags:
  --workcfg    Workload configuration name (default: "default")
               ID3 presets: flac_comp, flac_decomp, flac_both,
                            zstd_comp, zstd_decomp, zstd_both
EOF
  exit 1
}

ARCHIVE=""
STATS_DIR=""
WORKCFG="default"

while (($# > 0)); do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || usage
      ARCHIVE="$2"
      shift 2
      ;;
    --stats-dir)
      [[ $# -ge 2 ]] || usage
      STATS_DIR="$2"
      shift 2
      ;;
    --workcfg)
      [[ $# -ge 2 ]] || usage
      WORKCFG="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${ARCHIVE}" || -z "${STATS_DIR}" ]]; then
  echo "Missing required --archive or --stats-dir" >&2
  usage
fi

if [[ ! -f "${ARCHIVE}" ]]; then
  echo "Archive not found: ${ARCHIVE}" >&2
  exit 1
fi

mkdir -p "${STATS_DIR}"

TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT INT TERM

tar -xzf "${ARCHIVE}" -C "${TMPDIR}"

SUPER_ROOT="${TMPDIR}/super"
if [[ ! -d "${SUPER_ROOT}" ]]; then
  echo "Expected 'super' directory inside ${ARCHIVE}" >&2
  exit 1
fi

ORIGINAL_DIR="${STATS_DIR}/1.original"
mkdir -p "${ORIGINAL_DIR}"

imported=0

for workload_dir in "${SUPER_ROOT}"/*; do
  [[ -d "${workload_dir}" ]] || continue
  workload="$(basename "${workload_dir}")"

  for variant_dir in "${workload_dir}"/*; do
    [[ -d "${variant_dir}" ]] || continue
    param_dir="$(basename "${variant_dir}")"

    for run_dir in "${variant_dir}"/*; do
      [[ -d "${run_dir}" ]] || continue
      run_index="$(basename "${run_dir}")"

      dest_root="${ORIGINAL_DIR}/${workload}/${WORKCFG}/${param_dir}/${run_index}"
      mkdir -p "${dest_root}/logs" "${dest_root}/output"

      if [[ -d "${run_dir}/logs" ]]; then
        cp -a "${run_dir}/logs/." "${dest_root}/logs/" || true
      fi
      if [[ -d "${run_dir}/output" ]]; then
        cp -a "${run_dir}/output/." "${dest_root}/output/" || true
      fi
      if [[ -f "${run_dir}/meta.json" ]]; then
        cp -a "${run_dir}/meta.json" "${dest_root}/" || true
      fi
      if [[ -f "${run_dir}/transcript.log" ]]; then
        cp -a "${run_dir}/transcript.log" "${dest_root}/" || true
      fi

      ((imported++))
    done
  done
done

if (( imported == 0 )); then
  echo "No run directories found in ${ARCHIVE}" >&2
  exit 1
fi

echo "Imported ${imported} run(s) into ${ORIGINAL_DIR}"
