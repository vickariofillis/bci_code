#!/bin/bash
set -euo pipefail

# If the script is launched outside a tmux session, re-run it inside tmux so
# that it keeps running even if the SSH connection drops.
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$0" "$@"
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
workload_desc="ID-20 (Speech Decoding)"

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

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################

### Run workload ID-20 (Speech Decoding)

cd ~;

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

# Move to proper directory
cd /local/tools/bci_project/
# Source virtual environment
source /local/tools/bci_env/bin/activate
# Run path.sh
. path.sh
# Export PYTHONPATH
export PYTHONPATH=$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:$PYTHONPATH

if $run_toplev; then
  toplev_start=$(date +%s)
  ### Toplev profiling

  # Run the RNN script
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 --no-multiplex --all -x, \
      -o /local/data/results/id_20_rnn_toplev.csv -- \
        taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/ \
          >> /local/data/results/id_20_rnn_toplev.log 2>&1
  '

  # Run the LM script
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 --no-multiplex --all -x, \
      -o /local/data/results/id_20_lm_toplev.csv -- \
        taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
          --lmDir=/local/data/languageModel/ \
          >> /local/data/results/id_20_lm_toplev.log 2>&1
  '

  # Run the LLM script
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 --no-multiplex --all -x, \
      -o /local/data/results/id_20_llm_toplev.csv -- \
        taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
          >> /local/data/results/id_20_llm_toplev.log 2>&1
  '
  toplev_end=$(date +%s)
fi

if $run_maya; then
  ### Maya profiling
  maya_start=$(date +%s)

  # Run the RNN script
  sudo -E cset shield --exec -- sh -c '
    # Start Maya on core 5 in background, log raw output
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_20_rnn_maya.txt 2>&1 &

    # Give Maya a moment to start and then grab its PID
    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    # Run the RNN workload on core 6
    taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
      --datasetPath=/local/data/ptDecoder_ctc \
      --modelPath=/local/data/speechBaseline4/ \
      >> /local/data/results/id_20_rnn_maya.log 2>&1

    # After workload exits, terminate Maya
    kill "$MAYA_PID"
  '

  # Run the LM script
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_20_lm_maya.txt 2>&1 &

    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
      --lmDir=/local/data/languageModel/ \
      >> /local/data/results/id_20_lm_maya.log 2>&1

    kill "$MAYA_PID"
  '

  # Run the LLM script
  sudo -E cset shield --exec -- sh -c '
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_20_llm_maya.txt 2>&1 &

    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
      >> /local/data/results/id_20_llm_maya.log 2>&1

    kill "$MAYA_PID"
  '
  maya_end=$(date +%s)
fi

################################################################################

if $run_maya; then
### Convert Maya raw output to CSV

echo "Converting id_20_rnn_maya.txt → id_20_rnn_maya.csv"
awk '
{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }
' /local/data/results/id_20_rnn_maya.txt > /local/data/results/id_20_rnn_maya.csv

echo "Converting id_20_lm_maya.txt → id_20_lm_maya.csv"
awk '
{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }
' /local/data/results/id_20_lm_maya.txt > /local/data/results/id_20_lm_maya.csv

echo "Converting id_20_llm_maya.txt → id_20_llm_maya.csv"
awk '
{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }
' /local/data/results/id_20_llm_maya.txt > /local/data/results/id_20_llm_maya.csv

echo "Maya profiling complete; CSVs available in /local/data/results/"
fi

# Indicate completion for external monitoring tools

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
