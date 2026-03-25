#!/bin/bash
# Wrapper to run ID-20 RNN then WFST LM using the same RNN results pickle.
set -Eeuo pipefail
set -o errtrace

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "${SCRIPT_DIR}/helpers.sh"

trap on_error ERR

usage() {
  cat <<'USAGE'
Usage: run_20_3gram_rnnlm.sh [flags...]

Runs the ID-20 RNN stage followed by the WFST LM stage, plumbing the same
RNN results pickle into both. All standard run_20_3gram_* flags are forwarded.

Special flags:
  --rnn-output <path>   Override the shared RNN results pickle path
  --rnn-res <path>      Alias for --rnn-output (LM input path)
  --id20-rnn-model <m>  Passed only to the RNN stage (baseline|k16_s4|k32_s2|k32_s8|k64_s4)
  RNN mt flags          --cpu-topology, --workload-cpus, --workload-cpu-count,
                        --workload-smt-policy, --tools-cpus, --tools-cpu-count,
                        --socket-id, and --workload-threads are passed only to
                        the RNN stage
USAGE
}

COMMON_ARGS=()
RNN_ONLY_ARGS=()
RNN_MT_ARGS=()
RNN_OUTPUT_OVERRIDE=""
RNN_RES_OVERRIDE=""
RNN_MODEL_VALUE=""
RNN_CPU_TOPOLOGY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --rnn-output=*)
      RNN_OUTPUT_OVERRIDE="${1#--rnn-output=}"
      ;;
    --rnn-output)
      [[ $# -ge 2 ]] || { echo "Missing value for --rnn-output" >&2; exit 1; }
      RNN_OUTPUT_OVERRIDE="$2"
      shift
      ;;
    --rnn-res=*)
      RNN_RES_OVERRIDE="${1#--rnn-res=}"
      ;;
    --rnn-res)
      [[ $# -ge 2 ]] || { echo "Missing value for --rnn-res" >&2; exit 1; }
      RNN_RES_OVERRIDE="$2"
      shift
      ;;
    --id20-rnn-model=*)
      RNN_MODEL_VALUE="${1#--id20-rnn-model=}"
      RNN_ONLY_ARGS+=("$1")
      ;;
    --id20-rnn-model)
      [[ $# -ge 2 ]] || { echo "Missing value for --id20-rnn-model" >&2; exit 1; }
      RNN_MODEL_VALUE="$2"
      RNN_ONLY_ARGS+=("$1" "$2")
      shift
      ;;
    --cpu-topology)
      RNN_CPU_TOPOLOGY_ONLY=true
      RNN_MT_ARGS+=("$1")
      ;;
    --workload-cpus=*|--workload-cpu-count=*|--workload-smt-policy=*|--tools-cpus=*|--tools-cpu-count=*|--socket-id=*|--workload-threads=*)
      RNN_MT_ARGS+=("$1")
      ;;
    --workload-cpus|--workload-cpu-count|--workload-smt-policy|--tools-cpus|--tools-cpu-count|--socket-id|--workload-threads)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
      RNN_MT_ARGS+=("$1" "$2")
      shift
      ;;
    --)
      shift
      COMMON_ARGS+=("$@")
      break
      ;;
    *)
      COMMON_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ -n ${RNN_OUTPUT_OVERRIDE} && -n ${RNN_RES_OVERRIDE} && ${RNN_OUTPUT_OVERRIDE} != "${RNN_RES_OVERRIDE}" ]]; then
  echo "ERROR: --rnn-output and --rnn-res must match when both are provided." >&2
  exit 1
fi

PIPELINE_RNN_PATH="${RNN_OUTPUT_OVERRIDE:-${RNN_RES_OVERRIDE:-}}"
if [[ -z ${PIPELINE_RNN_PATH} ]]; then
  model_label="$(echo "${RNN_MODEL_VALUE:-baseline}" | tr '[:upper:]' '[:lower:]')"
  model_label="$(printf '%s' "$model_label" | sed -E 's/[^[:alnum:]_-]/_/g; s/_+/_/g; s/_$//')"
  timestamp="$(date +%Y%m%d_%H%M%S)"
  PIPELINE_RNN_PATH="/local/data/results/id_20_rnnlm_${model_label}_${timestamp}.pkl"
fi

rnn_args=("${COMMON_ARGS[@]}" "${RNN_MT_ARGS[@]}" "${RNN_ONLY_ARGS[@]}" --rnn-output "${PIPELINE_RNN_PATH}")
lm_args=("${COMMON_ARGS[@]}" --rnn-res "${PIPELINE_RNN_PATH}")

if [[ ${RNN_CPU_TOPOLOGY_ONLY} != true ]]; then
  mkdir -p "$(dirname "${PIPELINE_RNN_PATH}")"
  echo "[INFO] Using shared RNN results path: ${PIPELINE_RNN_PATH}"
fi

echo "[INFO] Running ID-20 RNN stage..."
bash "${SCRIPT_DIR}/run_20_3gram_rnn.sh" "${rnn_args[@]}"

if [[ ${RNN_CPU_TOPOLOGY_ONLY} == true ]]; then
  exit 0
fi

echo "[INFO] Running ID-20 WFST LM stage..."
bash "${SCRIPT_DIR}/run_20_3gram_lm.sh" "${lm_args[@]}"
