#!/usr/bin/env bash
set -euo pipefail

# ID-1 run script for Raspberry Pi
REPO_DIR="/home/vic/bci_code"
DATA_DIR="/home/vic/data"
RESULTS_DIR="$DATA_DIR/results"
LOG_DIR="$REPO_DIR/logs"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run_1.log") 2>&1

if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  script_path="$(readlink -f "$0")"
  exec tmux new-session -s "$session_name" "$script_path" "$@"
fi

run_maya=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --maya) run_maya=true ;;
    *) echo "Usage: $0 [--maya]" >&2; exit 1 ;;
  esac
  shift
done

echo "Testing ID-1 (Seizure Detection – Laelaps)"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

timestamp() { date '+%Y-%m-%d - %H:%M'; }

echo "Experiment started at: $(timestamp)"

cd "$REPO_DIR/id_1"

if $run_maya; then
  echo "Maya profiling started at: $(timestamp)"
  "$REPO_DIR/tools/maya/Dist/Release/Maya" --mode Baseline > "$RESULTS_DIR/id_1_maya.txt" 2>&1 &
  maya_pid=$!
  sleep 1
  ./main >> "$RESULTS_DIR/id_1.log" 2>&1
  kill "$maya_pid"
  echo "Maya profiling finished at: $(timestamp)"
else
  ./main > "$RESULTS_DIR/id_1.log" 2>&1
fi

echo "Experiment finished at: $(timestamp)"
