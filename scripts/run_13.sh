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
workload_desc="ID-13 (Movement Intent)"

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

# Helper for consistent timestamps
timestamp() {
  TZ=America/Toronto date '+%Y-%m-%d - %H:%M'
}

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

# Prepare placeholder logs for any disabled tools so that later consolidation
# yields a consistent done.log.
$run_toplev || echo "Toplev run skipped" > /local/data/results/done_toplev.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_toplev_memory || \
  echo "Toplev-memory run skipped" > /local/data/results/done_toplev_memory.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log

################################################################################
### 2. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project

################################################################################
### 3. PCM profiling
################################################################################
################################################################################
if $run_pcm; then
  echo "PCM profiling started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo modprobe msr
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_13_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
    >>/local/data/results/id_13_pcm.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_13_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
    >>/local/data/results/id_13_pcm_memory.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_13_pcm_power.csv -- \
      taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
    >>/local/data/results/id_13_pcm_power.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_13_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/tools/matlab/bin/matlab -nodisplay -nosplash -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
    >>/local/data/results/id_13_pcm_pcie.log 2>&1
  '
  pcm_end=$(date +%s)
  echo "PCM profiling finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  {
    echo "PCM runtime:    $(secs_to_dhm "$pcm_runtime")"
  } > /local/data/results/done_pcm.log
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
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_13_maya.txt 2>&1 &
    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    taskset -c 6 /local/tools/matlab/bin/matlab \
      -nodisplay -nosplash \
      -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;" \
      >> /local/data/results/id_13_maya.log 2>&1

    kill "$MAYA_PID"
  '
  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_maya.log
fi

################################################################################
### 6. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_13_toplev_execution.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_toplev_execution.log
fi

################################################################################
### 7. Toplev memory profiling
################################################################################

if $run_toplev_memory; then
  echo "Toplev memory profiling started at: $(timestamp)"
  toplev_memory_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --nodes "!Backend_Bound.Memory_Bound*/3" -x, \
      -o /local/data/results/id_13_toplev_memory.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev_memory.log
  toplev_memory_end=$(date +%s)
  echo "Toplev memory profiling finished at: $(timestamp)"
  toplev_memory_runtime=$((toplev_memory_end - toplev_memory_start))
  echo "Toplev-memory runtime: $(secs_to_dhm "$toplev_memory_runtime")" \
    > /local/data/results/done_toplev_memory.log
fi

################################################################################
### 8. Toplev profiling
################################################################################

if $run_toplev; then
  echo "Toplev profiling started at: $(timestamp)"
  toplev_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_13_toplev.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev.log
  toplev_end=$(date +%s)
  echo "Toplev profiling finished at: $(timestamp)"
  toplev_runtime=$((toplev_end - toplev_start))
  echo "Toplev runtime: $(secs_to_dhm "$toplev_runtime")" \
    > /local/data/results/done_toplev.log
fi

################################################################################
### 9. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_13_maya.txt → id_13_maya.csv"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
    /local/data/results/id_13_maya.txt > /local/data/results/id_13_maya.csv
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
      done_toplev.log \
      done_toplev_execution.log \
      done_toplev_memory.log \
      done_maya.log \
      done_pcm.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done.log

rm -f /local/data/results/done_toplev.log \
      /local/data/results/done_toplev_execution.log \
      /local/data/results/done_toplev_memory.log \
      /local/data/results/done_maya.log \
      /local/data/results/done_pcm.log
