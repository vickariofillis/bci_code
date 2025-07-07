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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev-basic)      run_toplev_basic=true ;;
    --toplev-full)       run_toplev_full=true ;;
    --toplev-execution)  run_toplev_execution=true ;;
    --maya)              run_maya=true ;;
    --pcm)               run_pcm=true ;;
    --short)
      run_toplev_basic=true
      run_toplev_full=false
      run_toplev_execution=true
      run_maya=true
      run_pcm=true
      ;;
    --long)
      run_toplev_basic=true
      run_toplev_full=true
      run_toplev_execution=true
      run_maya=true
      run_pcm=true
      ;;
    *) echo "Usage: $0 [--toplev-basic] [--toplev-execution] [--toplev-full] [--maya] [--pcm] [--short] [--long]" >&2; exit 1 ;;
  esac
  shift
done
if ! $run_toplev_basic && ! $run_toplev_full && ! $run_toplev_execution && ! $run_maya && ! $run_pcm; then
  run_toplev_basic=true
  run_toplev_full=true
  run_toplev_execution=true
  run_maya=true
  run_pcm=true
fi

# Describe this workload
workload_desc="ID-3 (Compression)"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev_full && tools_list+=("toplev-full")
$run_toplev_execution && tools_list+=("toplev-execution")
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
pcm_gen_start=0
pcm_gen_end=0
pcm_mem_start=0
pcm_mem_end=0
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

# Create placeholder logs for disabled tools so that done.log always lists
# every profiling stage.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log

################################################################################
### 2. Change into the ID-3 code directory
################################################################################
cd /local/bci_code/id_3/code

source /local/tools/compression_env/bin/activate

################################################################################
### 3. PCM profiling
################################################################################
################################################################################
if $run_pcm; then
  echo "PCM profiling started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo modprobe msr
  pcm_gen_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_3_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac \
    >>/local/data/results/id_3_pcm.log 2>&1
  '
  pcm_gen_end=$(date +%s)
  pcm_mem_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_3_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac \
    >>/local/data/results/id_3_pcm_memory.log 2>&1
  '
  pcm_mem_end=$(date +%s)
  pcm_power_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_3_pcm_power.csv -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac \
    >>/local/data/results/id_3_pcm_power.log 2>&1
  '
  pcm_power_end=$(date +%s)
  pcm_pcie_start=$(date +%s)
  sudo bash -lc '
    source /local/tools/compression_env/bin/activate
    cd /local/bci_code/id_3/code
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_3_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac \
    >>/local/data/results/id_3_pcm_pcie.log 2>&1
  '
  pcm_pcie_end=$(date +%s)
  pcm_end=$(date +%s)
  echo "PCM profiling finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  pcm_gen_runtime=$((pcm_gen_end - pcm_gen_start))
  pcm_mem_runtime=$((pcm_mem_end - pcm_mem_start))
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  {
    echo "PCM runtime:    $(secs_to_dhm "$pcm_runtime")"
    echo "pcm:           $(secs_to_dhm "$pcm_gen_runtime")"
    echo "pcm-memory:    $(secs_to_dhm "$pcm_mem_runtime")"
    echo "pcm-power:     $(secs_to_dhm "$pcm_power_runtime")"
    echo "pcm-pcie:      $(secs_to_dhm "$pcm_pcie_runtime")"
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
    source /local/tools/compression_env/bin/activate

    # Start Maya in the background, pinned to CPU 5
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_3_maya.txt 2>&1 &

    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    # Run the workload pinned to CPU 6
    taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac \
      >> /local/data/results/id_3_maya.log 2>&1

    kill "$MAYA_PID"
  '
  maya_end=$(date +%s)
  echo "Maya profiling finished at: $(timestamp)"
  maya_runtime=$((maya_end - maya_start))
  echo "Maya runtime:   $(secs_to_dhm "$maya_runtime")" \
    > /local/data/results/done_maya.log
fi

################################################################################
### 6. Toplev basic profiling
################################################################################

if $run_toplev_basic; then
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o /local/data/results/id_3_toplev_basic.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac
  ' &> /local/data/results/id_3_toplev_basic.log
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_toplev_basic.log
fi

################################################################################
### 7. Toplev execution profiling
################################################################################

if $run_toplev_execution; then
  echo "Toplev execution profiling started at: $(timestamp)"
  toplev_execution_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_3_toplev_execution.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac
  ' &>  /local/data/results/id_3_toplev_execution.log
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_toplev_execution.log
fi

################################################################################

################################################################################
### 8. Toplev full profiling
################################################################################

if $run_toplev_full; then
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)

  sudo -E cset shield --exec -- bash -lc '
    source /local/tools/compression_env/bin/activate

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_3_toplev_full.csv -- \
        taskset -c 6 /local/tools/compression_env/bin/python scripts/benchmark-lossless.py aind-np1 0.1s flac
  ' &>  /local/data/results/id_3_toplev_full.log
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_toplev_full.log
fi

################################################################################
### 11. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting id_3_maya.txt → id_3_maya.csv"
  awk '{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }' \
    /local/data/results/id_3_maya.txt \
    > /local/data/results/id_3_maya.csv
fi

################################################################################
### 12. Signal completion for tmux monitoring
################################################################################
echo "All done. Results are in /local/data/results/"

echo "Experiment finished at: $(timestamp)"

################################################################################
### 13. Write completion file with runtimes
################################################################################

{
  echo "Done"
  for log in \
      done_toplev_basic.log \
      done_toplev_full.log \
      done_toplev_execution.log \
      done_maya.log \
      done_pcm.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done.log

rm -f /local/data/results/done_toplev_basic.log \
      /local/data/results/done_toplev_full.log \
      /local/data/results/done_toplev_execution.log \
      /local/data/results/done_maya.log \
      /local/data/results/done_pcm.log
