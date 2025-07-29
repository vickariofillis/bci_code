#!/usr/bin/env bash
set -euo pipefail

# ID-1 run script adapted for Raspberry Pi

REPO_DIR="/home/vic/bci_code"
DATA_DIR="/home/vic/data"
RESULTS_DIR="$DATA_DIR/results"
LOG_DIR="$REPO_DIR/logs"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/run_1.log") 2>&1

# Re-run inside tmux if needed
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  script_path="$(readlink -f "$0")"
  exec tmux new-session -s "$session_name" "$script_path" "$@"
fi

# Tool selection flags (toplev and pcm families)
run_toplev_basic=false
run_toplev_full=false
run_toplev_execution=false
run_maya=false
run_pcm=false
run_pcm_memory=false
run_pcm_power=false
run_pcm_pcie=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev-basic)      run_toplev_basic=true ;;
    --toplev-full)       run_toplev_full=true ;;
    --toplev-execution)  run_toplev_execution=true ;;
    --maya)              run_maya=true ;;
    --pcm)               run_pcm=true ;;
    --pcm-memory)        run_pcm_memory=true ;;
    --pcm-power)         run_pcm_power=true ;;
    --pcm-pcie)          run_pcm_pcie=true ;;
    --pcm-all)
      run_pcm=true
      run_pcm_memory=true
      run_pcm_power=true
      run_pcm_pcie=true
      ;;
    --short)
      run_toplev_basic=true
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
    *)
      echo "Usage: $0 [--toplev-basic] [--toplev-execution] [--toplev-full] [--maya] [--pcm] [--pcm-memory] [--pcm-power] [--pcm-pcie] [--pcm-all] [--short] [--long]" >&2
      exit 1
      ;;
  esac
  shift
done

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

workload_desc="ID-1 (Seizure Detection – Laelaps)"

# Countdown
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev_full && tools_list+=("toplev-full")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_maya && tools_list+=("maya")
$run_pcm && tools_list+=("pcm")
$run_pcm_memory && tools_list+=("pcm-memory")
$run_pcm_power && tools_list+=("pcm-power")
$run_pcm_pcie && tools_list+=("pcm-pcie")

tool_msg=$(IFS=, ; echo "${tools_list[*]}")

echo "Testing $workload_desc with tools: $tool_msg"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

echo "Experiment started at: $(date '+%Y-%m-%d - %H:%M')"

# helper for timestamps
timestamp() {
  date '+%Y-%m-%d - %H:%M'
}

################################################################################
### 1. Prepare placeholders
################################################################################
$run_toplev_basic || echo "Toplev-basic run skipped" > "$RESULTS_DIR/done_toplev_basic.log"
$run_toplev_full || echo "Toplev-full run skipped" > "$RESULTS_DIR/done_toplev_full.log"
$run_toplev_execution || echo "Toplev-execution run skipped" > "$RESULTS_DIR/done_toplev_execution.log"
$run_maya || echo "Maya run skipped" > "$RESULTS_DIR/done_maya.log"
$run_pcm || echo "PCM run skipped" > "$RESULTS_DIR/done_pcm.log"
$run_pcm_memory || echo "PCM-memory run skipped" > "$RESULTS_DIR/done_pcm_memory.log"
$run_pcm_power || echo "PCM-power run skipped" > "$RESULTS_DIR/done_pcm_power.log"
$run_pcm_pcie || echo "PCM-pcie run skipped" > "$RESULTS_DIR/done_pcm_pcie.log"

################################################################################
### 2. Run workload directly (simplified for Pi)
################################################################################
cd "$REPO_DIR/id_1"
./main > "$RESULTS_DIR/id_1.log" 2>&1

################################################################################
### 3. Signal completion
################################################################################
echo "Experiment finished at: $(timestamp)" | tee -a "$RESULTS_DIR/id_1.log"

{
  echo "Done"
  for log in \
      done_toplev_basic.log \
      done_toplev_full.log \
      done_toplev_execution.log \
      done_maya.log \
      done_pcm.log \
      done_pcm_memory.log \
      done_pcm_power.log \
      done_pcm_pcie.log; do
    if [[ -f "$RESULTS_DIR/$log" ]]; then
      echo
      cat "$RESULTS_DIR/$log"
    fi
  done
} > "$RESULTS_DIR/done.log"

rm -f "$RESULTS_DIR/done_toplev_basic.log" \
      "$RESULTS_DIR/done_toplev_full.log" \
      "$RESULTS_DIR/done_toplev_execution.log" \
      "$RESULTS_DIR/done_maya.log" \
      "$RESULTS_DIR/done_pcm.log" \
      "$RESULTS_DIR/done_pcm_memory.log" \
      "$RESULTS_DIR/done_pcm_power.log" \
      "$RESULTS_DIR/done_pcm_pcie.log"
