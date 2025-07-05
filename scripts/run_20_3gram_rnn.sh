#!/bin/bash
set -euo pipefail

# If the script is launched outside a tmux session, re-run it inside tmux so
# that it keeps running even if the SSH connection drops.
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$0" "$@"
fi

# Log to /local/logs/run.log
mkdir -p /local/logs
exec > >(tee -a /local/logs/run.log) 2>&1


# Parse tool selection arguments inside tmux
run_toplev=false
run_toplev_execution=false
run_toplev_memory=false
run_maya=false
run_pcm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev)            run_toplev=true ;;
    --toplev-execution)  run_toplev_execution=true ;;
    --toplev-memory)     run_toplev_memory=true ;;
    --maya)              run_maya=true ;;
    --pcm)               run_pcm=true ;;
    --short)
      run_toplev=false
      run_toplev_execution=true
      run_toplev_memory=true
      run_maya=true
      run_pcm=true
      ;;
    --long)
      run_toplev=true
      run_toplev_execution=true
      run_toplev_memory=true
      run_maya=true
      run_pcm=true
      ;;
    *) echo "Usage: $0 [--toplev] [--toplev-execution] [--toplev-memory] [--maya] [--pcm] [--short] [--long]" >&2; exit 1 ;;
  esac
  shift
done
if ! $run_toplev && ! $run_toplev_execution && ! $run_toplev_memory \
    && ! $run_maya && ! $run_pcm; then
  run_toplev=true
  run_toplev_execution=true
  run_toplev_memory=true
  run_maya=true
  run_pcm=true
fi

# Describe this workload
workload_desc="ID-20 3gram RNN"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev && tools_list+=("toplev")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_toplev_memory && tools_list+=("toplev-memory")
$run_maya && tools_list+=("maya")
$run_pcm  && tools_list+=("pcm")
tool_msg=$(IFS=, ; echo "${tools_list[*]}")
echo "Testing $workload_desc with tools: $tool_msg"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

echo "Experiment started at: $(TZ=America/Toronto date '+%Y-%m-%d - %H:%M')"

# Initialize timing variables
toplev_start=0
toplev_end=0
toplev_execution_start=0
toplev_execution_end=0
toplev_memory_start=0
toplev_memory_end=0
maya_start=0
maya_end=0
pcm_start=0
pcm_end=0
pcm_memory_start=0
pcm_memory_end=0
pcm_power_start=0
pcm_power_end=0
pcm_pcie_start=0
pcm_pcie_end=0

# Format seconds as "Xd Yh Zm"
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

################################################################################
### 1. Create results directory (if it doesn't exist already)
################################################################################
cd /local; mkdir -p data/results
# Get ownership of /local and grant read+execute to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################
### 2. Shield Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
###    (reserve them for our measurement + workload)
################################################################################
sudo cset shield --cpu 5,6,15,16 --kthread=on

################################################################################
### 3. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project

################################################################################
### 4. Maya profiling
################################################################################

if $run_maya; then
  maya_start=$(date +%s)

  # Run the RNN script under Maya (Maya on CPU 5, workload on CPU 6)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  # Start Maya in the background, pinned to CPU 5
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_rnn_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  # Run the workload pinned to CPU 6
  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
    --datasetPath=/local/data/ptDecoder_ctc \
    --modelPath=/local/data/speechBaseline4/ \
    >> /local/data/results/id_20_3gram_rnn_maya.log 2>&1

  kill "$MAYA_PID"
  '
  maya_end=$(date +%s)
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_rnn_maya.log
fi

################################################################################
### 5. PCM profiling
################################################################################

if $run_pcm; then
  pcm_start=$(date +%s)
  sudo cset shield --reset
  sudo modprobe msr
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_20_3gram_rnn_pcm.csv \
      0.5 -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm.log 2>&1
  pcm_end=$(date +%s)

  pcm_memory_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_20_3gram_rnn_pcm_memory.csv \
      0.5 -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_memory.log 2>&1
  pcm_memory_end=$(date +%s)

  pcm_power_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_20_3gram_rnn_pcm_power.csv -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_power.log 2>&1
  pcm_power_end=$(date +%s)

  pcm_pcie_start=$(date +%s)
  sudo -E bash -lc '
    source /local/tools/bci_env/bin/activate
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    . path.sh
    export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

    taskset -c 6 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_20_3gram_rnn_pcm_pcie.csv \
      -B 1.0 -- \
      bash -lc "
        source /local/tools/bci_env/bin/activate
        . path.sh
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\"
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
          --datasetPath=/local/data/ptDecoder_ctc \
          --modelPath=/local/data/speechBaseline4/
      "
  ' >>/local/data/results/id_20_3gram_rnn_pcm_pcie.log 2>&1
  pcm_pcie_end=$(date +%s)
  pcm_runtime=$((pcm_end - pcm_start))
  pcm_memory_runtime=$((pcm_memory_end - pcm_memory_start))
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  {
    echo "PCM runtime:         $(secs_to_dhm "$pcm_runtime")"
    echo "PCM-memory runtime:  $(secs_to_dhm "$pcm_memory_runtime")"
    echo "PCM-power runtime:   $(secs_to_dhm "$pcm_power_runtime")"
    echo "PCM-pcie runtime:    $(secs_to_dhm "$pcm_pcie_runtime")"
  } > /local/data/results/done_rnn_pcm.log
fi

################################################################################
### 6. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l1 -I 500 -v -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev_execution.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/
  ' &> /local/data/results/id_20_3gram_rnn_toplev_execution.log
  toplev_execution_end=$(date +%s)
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_rnn_toplev_execution.log
fi

################################################################################
### 7. Toplev memory profiling
################################################################################

if $run_toplev_memory; then
  toplev_memory_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc "
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH='${LD_LIBRARY_PATH:-}'
  . path.sh
  export PYTHONPATH='$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}'

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l3 -I 500 -v --nodes '!Backend_Bound.Memory_Bound*/3' -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev_memory.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/
  " &> /local/data/results/id_20_3gram_rnn_toplev_memory.log
  toplev_memory_end=$(date +%s)
  toplev_memory_runtime=$((toplev_memory_end - toplev_memory_start))
  echo "Toplev-memory runtime: $(secs_to_dhm "$toplev_memory_runtime")" \
    > /local/data/results/done_rnn_toplev_memory.log
fi

################################################################################
### 8. Toplev profiling
################################################################################

if $run_toplev; then
  toplev_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

toplev_end=$(date +%s)
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 -v --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/
  ' &> /local/data/results/id_20_3gram_rnn_toplev.log
  toplev_end=$(date +%s)
  toplev_runtime=$((toplev_end - toplev_start))
  echo "Toplev runtime: $(secs_to_dhm "$toplev_runtime")" \
    > /local/data/results/done_rnn_toplev.log
fi
################################################################################
### 9. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_20_3gram_rnn_maya.txt → id_20_3gram_rnn_maya.csv"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
    /local/data/results/id_20_3gram_rnn_maya.txt \
    > /local/data/results/id_20_3gram_rnn_maya.csv
fi

################################################################################
### 10. Signal completion for tmux monitoring
################################################################################
echo "All done. Results are in /local/data/results/"

################################################################################
### 11. Write completion file with runtimes
################################################################################
{
  echo "Done"
  if $run_toplev; then
    echo
    cat /local/data/results/done_rnn_toplev.log
  fi
  if $run_toplev_execution; then
    echo
    cat /local/data/results/done_rnn_toplev_execution.log
  fi
  if $run_toplev_memory; then
    echo
    cat /local/data/results/done_rnn_toplev_memory.log
  fi
  if $run_maya; then
    echo
    cat /local/data/results/done_rnn_maya.log
  fi
  if $run_pcm; then
    echo
    cat /local/data/results/done_rnn_pcm.log
  fi
} > /local/data/results/done_rnn.log

rm -f /local/data/results/done_rnn_toplev.log \
      /local/data/results/done_rnn_toplev_execution.log \
      /local/data/results/done_rnn_toplev_memory.log \
      /local/data/results/done_rnn_maya.log \
      /local/data/results/done_rnn_pcm.log
