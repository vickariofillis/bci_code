#!/bin/bash
set -euo pipefail

# If the script is launched outside a tmux session, re-run it inside tmux so
# that it keeps running even if the SSH connection drops.
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$0" "$@"
fi

# Prompt for run ID to avoid overwriting results
read -rp "Enter run number (1-3): " run_id
if [[ ! $run_id =~ ^[1-3]$ ]]; then
  echo "Run number must be 1, 2, or 3" >&2
  exit 1
fi

# Parse tool selection arguments inside tmux
run_toplev=false
run_maya=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev) run_toplev=true ;;
    --maya)   run_maya=true ;;
    *) echo "Usage: $0 [--toplev] [--maya]" >&2; exit 1 ;;
  esac
  shift
done
if ! $run_toplev && ! $run_maya; then
  run_toplev=true
  run_maya=true
fi

# Describe this workload
workload_desc="ID-20 3gram LLM"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev && tools_list+=("toplev")
$run_maya && tools_list+=("maya")
tool_msg=$(IFS=, ; echo "${tools_list[*]}")
echo "Testing $workload_desc with tools: $tool_msg"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

# Initialize timing variables
toplev_start=0
toplev_end=0
maya_start=0
maya_end=0

# Format seconds as "Xd Yh Zm"
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

################################################################################
### 1. Create results directory (if it doesn't exist already)
################################################################################
cd /local; mkdir -p data/results
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
toplev_start=$(date +%s)
chmod -R a+rx /local

################################################################################
### 2. Shield CPUs 5, 6, 15, and 16 (reserve them for our measurement + workload)
################################################################################
sudo cset shield --cpu 5,6,15,16 --kthread=on

################################################################################
### 3. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project

################################################################################
### 4. Toplev profiling
################################################################################

if $run_toplev; then
  toplev_start=$(date +%s)

  # Run the LLM script under toplev (toplev on CPU 5, workload on CPU 6)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_llm_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
  ' &> /local/data/results/id_20_3gram_llm_toplev.log
  toplev_end=$(date +%s)
fi

################################################################################
### 5. Maya profiling
if $run_maya; then
  maya_start=$(date +%s)
################################################################################

  # Run the LLM script under Maya (Maya on CPU 5, workload on CPU 6)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_llm_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
    --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl \
    >> /local/data/results/id_20_3gram_llm_maya.log 2>&1

  kill "$MAYA_PID"
  '
  maya_end=$(date +%s)
fi

################################################################################
if $run_maya; then
### 6. Convert Maya raw output files into CSV
################################################################################

echo "Converting id_20_3gram_llm_maya.txt → id_20_3gram_llm_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_llm_maya.txt \
  > /local/data/results/id_20_3gram_llm_maya.csv

echo "Maya profiling complete; CSVs are in /local/data/results/"
fi

# Signal completion

################################################################################


# Write completion file with runtimes
toplev_runtime=0
maya_runtime=0
{
  echo "Done"
  if $run_toplev; then
    toplev_runtime=$((toplev_end - toplev_start))
    echo
    echo "Toplev runtime: $(secs_to_dhm "$toplev_runtime")"
  fi
  if $run_maya; then
    maya_runtime=$((maya_end - maya_start))
    echo
    echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")"
  fi
} > /local/data/results/done.log

# Attempt to copy results back to the invoking host
client_ip=${SSH_CLIENT%% *}
dest_user=${SCP_USER:-vic}
dest_dir="/home/vic/Downloads/BCI/results/id_20/$run_id"
if [[ -n $client_ip ]]; then
  echo "Copying results to $dest_user@$client_ip:$dest_dir"
  ssh "$dest_user@$client_ip" "mkdir -p '$dest_dir'" && \
  scp /local/data/results/id_20_* "$dest_user@$client_ip:$dest_dir/" || \
  echo "SCP transfer failed; ensure SSH access from this node to $client_ip" >&2
else
  echo "SSH_CLIENT not set; skipping automatic SCP" >&2
fi
