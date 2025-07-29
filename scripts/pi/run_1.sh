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
# Convert seconds to "Xd Yh Zm" for the done file
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

echo "Experiment started at: $(timestamp)"

cd "$REPO_DIR/id_1"

if $run_maya; then
  echo "Maya profiling started at: $(timestamp)"
  maya_start=$(date +%s)
  "$REPO_DIR/tools/maya/Dist/Release/Maya" --mode Baseline > "$RESULTS_DIR/id_1_maya.txt" 2>&1 &
  maya_pid=$!
  sleep 1
  ./main >> "$RESULTS_DIR/id_1.log" 2>&1
  kill "$maya_pid"
  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime: $(secs_to_dhm "$maya_runtime")" > "$RESULTS_DIR/done_maya.log"
else
  ./main > "$RESULTS_DIR/id_1.log" 2>&1
fi

# Convert Maya's raw output to CSV for easier analysis
if $run_maya; then
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i,(i<NF?"," : "") } print "" }' \
      "$RESULTS_DIR/id_1_maya.txt" > "$RESULTS_DIR/id_1_maya.csv"
fi

echo "Experiment finished at: $(timestamp)"

# Consolidate runtime info
{
  echo "Done"
  [[ -f "$RESULTS_DIR/done_maya.log" ]] && cat "$RESULTS_DIR/done_maya.log"
} > "$RESULTS_DIR/done.log"

rm -f "$RESULTS_DIR/done_maya.log"

