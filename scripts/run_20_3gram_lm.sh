#!/bin/bash
set -euo pipefail

# If the script is launched outside a tmux session, re-run it inside tmux so
# that it keeps running even if the SSH connection drops.
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$0" "$@"
fi

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

# Run the LM script under toplev (toplev on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_lm_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
        --lmDir=/local/data/languageModel/ \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
' &> /local/data/results/id_20_3gram_lm_toplev.log
toplev_end=$(date +%s)

################################################################################
### 5. Maya profiling
maya_start=$(date +%s)
################################################################################

# Run the LM script under Maya (Maya on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_lm_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
    --lmDir=/local/data/languageModel/ \
    --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    >> /local/data/results/id_20_3gram_lm_maya.log 2>&1

  kill "$MAYA_PID"
'
maya_end=$(date +%s)

################################################################################
### 6. Convert Maya raw output files into CSV
################################################################################

echo "Converting id_20_3gram_lm_maya.txt → id_20_3gram_lm_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_lm_maya.txt \
  > /local/data/results/id_20_3gram_lm_maya.csv

echo "Maya profiling complete; CSVs are in /local/data/results/"

# Signal completion

################################################################################


# Write completion file with runtimes
toplev_runtime=$((toplev_end - toplev_start))
maya_runtime=$((maya_end - maya_start))
cat <<EOF > /local/data/results/done.log
Done

Toplev runtime: $(secs_to_dhm "$toplev_runtime")

Maya runtime:   $(secs_to_dhm "$maya_runtime")
EOF
