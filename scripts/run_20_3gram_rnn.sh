#!/bin/bash
set -euo pipefail

# If the script is launched outside a tmux session, re-run it inside tmux so
# that it keeps running even if the SSH connection drops.
if [[ -z ${TMUX:-} ]]; then
  session_name="$(basename "$0" .sh)"
  script_path="$(readlink -f "$0")"
  echo "Running outside tmux. Starting tmux session '$session_name'."
  exec tmux new-session -s "$session_name" "$script_path" "$@"
fi

# Log to /local/logs/run.log
mkdir -p /local/logs
exec > >(tee -a /local/logs/run.log) 2>&1


# Parse tool selection arguments inside tmux
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
      run_toplev_full=false
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
    *) echo "Usage: $0 [--toplev-basic] [--toplev-execution] [--toplev-full] [--maya] [--pcm] [--pcm-memory] [--pcm-power] [--pcm-pcie] [--pcm-all] [--short] [--long]" >&2; exit 1 ;;
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

# Describe this workload
workload_desc="ID-20 3gram RNN"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev_full && tools_list+=("toplev-full")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_maya && tools_list+=("maya")
$run_pcm  && tools_list+=("pcm")
$run_pcm_memory && tools_list+=("pcm-memory")
$run_pcm_power && tools_list+=("pcm-power")
$run_pcm_pcie && tools_list+=("pcm-pcie")
tool_msg=$(IFS=, ; echo "${tools_list[*]}")
echo "Testing $workload_desc with tools: $tool_msg"
for i in {10..1}; do
  echo "$i"
  sleep 1
done

echo "Experiment started at: $(TZ=America/Toronto date '+%Y-%m-%d - %H:%M')"

# Helper for consistent timestamps
timestamp() {
  TZ=America/Toronto date '+%Y-%m-%d - %H:%M'
}

# Initialize timing variables
toplev_basic_start=0
toplev_basic_end=0
toplev_full_start=0
toplev_full_end=0
toplev_execution_start=0
toplev_execution_end=0
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
# Determine permissions target based on original invoking user
RUN_USER=${SUDO_USER:-$(id -un)}
RUN_GROUP=$(id -gn "$RUN_USER")
# Get ownership of /local and grant read+execute to everyone
chown -R "$RUN_USER":"$RUN_GROUP" /local
chmod -R a+rx /local

# Create placeholder logs whenever a tool is disabled so the final summary is
# predictable regardless of the chosen subset.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_rnn_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_rnn_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_rnn_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_rnn_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_rnn_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_rnn_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_rnn_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_rnn_pcm_pcie.log

################################################################################
### 2. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project

################################################################################
### 3. PCM profiling
################################################################################

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  sudo modprobe msr
fi

if $run_pcm; then

  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
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
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_rnn_pcm.log

  echo "pcm-memory started at: $(timestamp)"
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
  echo "pcm-memory finished at: $(timestamp)"
  pcm_memory_runtime=$((pcm_memory_end - pcm_memory_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_memory_runtime")" \
    > /local/data/results/done_rnn_pcm_memory.log

  echo "pcm-power started at: $(timestamp)"
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
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  echo "pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")" \
    > /local/data/results/done_rnn_pcm_power.log

  echo "pcm-pcie started at: $(timestamp)"
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
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_rnn_pcm_pcie.log
fi

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  echo "PCM profiling finished at: $(timestamp)"
fi

################################################################################
### 4. Shield Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
###    (reserve them for our measurement + workload)
################################################################################
sudo cset shield --cpu 5,6,15,16 --kthread=on

################################################################################
### 5. Maya profiling
################################################################################

if $run_maya; then
  echo "Maya profiling started at: $(timestamp)"
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
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_rnn_maya.log
fi

################################################################################
### 6. Toplev basic profiling
################################################################################

if $run_toplev_basic; then
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l3 -I 500 -v --no-multiplex \
    -A --per-thread --columns \
    --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev_basic.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/ \
        >> /local/data/results/id_20_3gram_rnn_toplev_basic.log 2>&1
  '
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_rnn_toplev_basic.log
fi

################################################################################
### 7. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  echo "Toplev execution profiling started at: $(timestamp)"
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
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_rnn_toplev_execution.log
fi

################################################################################
### 8. Toplev full profiling
################################################################################

if $run_toplev_full; then
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev_full.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/ \
        >> /local/data/results/id_20_3gram_rnn_toplev_full.log 2>&1
  '
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_rnn_toplev_full.log
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
echo "Experiment finished at: $(timestamp)"

################################################################################
### 11. Write completion file with runtimes
################################################################################
{
  echo "Done"
    for log in \
        done_rnn_toplev_basic.log \
        done_rnn_toplev_full.log \
      done_rnn_toplev_execution.log \
      done_rnn_maya.log \
      done_rnn_pcm.log \
      done_rnn_pcm_memory.log \
      done_rnn_pcm_power.log \
      done_rnn_pcm_pcie.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done_rnn.log

rm -f /local/data/results/done_rnn_toplev_basic.log \
      /local/data/results/done_rnn_toplev_full.log \
      /local/data/results/done_rnn_toplev_execution.log \
      /local/data/results/done_rnn_maya.log \
      /local/data/results/done_rnn_pcm.log \
      /local/data/results/done_rnn_pcm_memory.log \
      /local/data/results/done_rnn_pcm_power.log \
      /local/data/results/done_rnn_pcm_pcie.log
