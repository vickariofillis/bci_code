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
start_ts=$(date +%s)
./main > "$RESULTS_DIR/id_1.log" 2>&1
end_ts=$(date +%s)

echo "Experiment finished at: $(timestamp)"
runtime=$((end_ts - start_ts))
echo "Runtime: $(secs_to_dhm "$runtime")" > "$RESULTS_DIR/done.log"

