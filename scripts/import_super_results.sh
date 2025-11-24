#!/usr/bin/env bash
# Stage super_run archives into stats_dir with workload config layer.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: import_super_results.sh --archive super_<tag>.tgz --stats-dir /path/to/stats_dir

Required flags:
  --archive    Path to the super_<tag>.tgz produced by scripts/get_results.sh
  --stats-dir  Destination stats directory (bci_r stats_dir root)

Layouts handled:
  - New: SUPER_ROOT/<workload>/<mode>/<variant>/<run_index>/
  - Legacy: SUPER_ROOT/<workload>/<variant>/<run_index>/ (treated as mode "default")
Import target structure:
  <stats_dir>/<workload>/<mode>/<variant>/<run_index>/
EOF
  exit 1
}

ARCHIVE=""
STATS_DIR=""

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

stage_run() { # $1=run_dir, $2=dest_root
  local run_dir="$1"
  local dest_root="$2"
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
}

for workload_dir in "${SUPER_ROOT}"/*; do
  [[ -d "${workload_dir}" ]] || continue
  workload="$(basename "${workload_dir}")"

  layout="old"
  shopt -s nullglob
  for child in "${workload_dir}"/*; do
    [[ -d "${child}" ]] || continue
    depth3=("${child}"/*/*/meta.json)
    if ((${#depth3[@]})); then layout="new"; break; fi
    depth2=("${child}"/*/meta.json)
    if ((${#depth2[@]})); then layout="old"; break; fi
  done
  shopt -u nullglob

  if [[ "${layout}" == "new" ]]; then
    for mode_dir in "${workload_dir}"/*; do
      [[ -d "${mode_dir}" ]] || continue
      mode="$(basename "${mode_dir}")"

      for variant_dir in "${mode_dir}"/*; do
        [[ -d "${variant_dir}" ]] || continue
        param_dir="$(basename "${variant_dir}")"

        for run_dir in "${variant_dir}"/*; do
          [[ -d "${run_dir}" ]] || continue
          run_index="$(basename "${run_dir}")"

          dest_root="${ORIGINAL_DIR}/${workload}/${mode}/${param_dir}/${run_index}"
          stage_run "${run_dir}" "${dest_root}"
        done
      done
    done
  else
    mode="default"
    for variant_dir in "${workload_dir}"/*; do
      [[ -d "${variant_dir}" ]] || continue
      param_dir="$(basename "${variant_dir}")"

      for run_dir in "${variant_dir}"/*; do
        [[ -d "${run_dir}" ]] || continue
        run_index="$(basename "${run_dir}")"

        dest_root="${ORIGINAL_DIR}/${workload}/${mode}/${param_dir}/${run_index}"
        stage_run "${run_dir}" "${dest_root}"
      done
    done
  fi
done

if (( imported == 0 )); then
  echo "No run directories found in ${ARCHIVE}" >&2
  exit 1
fi

echo "Imported ${imported} run(s) into ${ORIGINAL_DIR}"
