#!/usr/bin/env bash
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
run_toplev=false
run_toplev_execution=false
run_toplev_memory=false
run_toplev_ip=false
run_maya=false
run_pcm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev-basic)      run_toplev_basic=true ;;
    --toplev)            run_toplev=true ;;
    --toplev-execution)  run_toplev_execution=true ;;
    --toplev-memory)     run_toplev_memory=true ;;
    --toplev-ip)         run_toplev_ip=true ;;
    --maya)              run_maya=true ;;
    --pcm)               run_pcm=true ;;
    --short)
      run_toplev_basic=true
      run_toplev=false
      run_toplev_execution=true
      run_toplev_memory=true
      run_toplev_ip=true
      run_maya=true
      run_pcm=true
      ;;
    --long)
      run_toplev_basic=true
      run_toplev=true
      run_toplev_execution=true
      run_toplev_memory=true
      run_toplev_ip=true
      run_maya=true
      run_pcm=true
      ;;
    *) echo "Usage: $0 [--toplev] [--toplev-execution] [--toplev-memory] [--toplev-ip] [--maya] [--pcm] [--short] [--long]" >&2; exit 1 ;;
  esac
  shift
done
if ! $run_toplev_basic && ! $run_toplev && ! $run_toplev_execution && ! $run_toplev_memory \
    && ! $run_toplev_ip && ! $run_maya && ! $run_pcm; then
  run_toplev_basic=true
  run_toplev=true
  run_toplev_execution=true
  run_toplev_memory=true
  run_toplev_ip=true
  run_maya=true
  run_pcm=true
fi

# Describe this workload
workload_desc="ID-1 (Seizure Detection – Laelaps)"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev_basic && tools_list+=("toplev-basic")
$run_toplev && tools_list+=("toplev")
$run_toplev_execution && tools_list+=("toplev-execution")
$run_toplev_memory && tools_list+=("toplev-memory")
$run_toplev_ip && tools_list+=("toplev-ip")
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
toplev_start=0
toplev_end=0
toplev_execution_start=0
toplev_execution_end=0
toplev_memory_start=0
toplev_memory_end=0
toplev_ip_start=0
toplev_ip_end=0
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

# Prepare placeholder logs for any disabled tools so that log consolidation
# works regardless of the selected combination.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_toplev_basic.log
$run_toplev || echo "Toplev run skipped" > /local/data/results/done_toplev.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_toplev_memory || \
  echo "Toplev-memory run skipped" > /local/data/results/done_toplev_memory.log
$run_toplev_ip || \
  echo "Toplev-ip run skipped" > /local/data/results/done_toplev_ip.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log

################################################################################
### 2. Change into the proper directory
################################################################################
cd ~

################################################################################
### 3. PCM profiling
################################################################################

if $run_pcm; then
  echo "PCM profiling started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo modprobe msr
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_1_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_1_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_memory.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_1_pcm_power.csv -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_power.log 2>&1
  '
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_1_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_pcie.log 2>&1
  '
  pcm_end=$(date +%s)
  echo "PCM profiling finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "PCM runtime:    $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_pcm.log
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
  sudo cset shield --exec -- sh -c '
    # Start Maya on core 5 in background, log raw output
    taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
      > /local/data/results/id_1_maya.txt 2>&1 &

    # Give Maya a moment to start and then grab its PID
    sleep 1
    MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

    # Run the same workload on core 6, log its output
    taskset -c 6 /local/bci_code/id_1/main \
      >> /local/data/results/id_1_maya.log 2>&1

    # After workload exits, terminate Maya
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
  sudo cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l0 -I 500 -v --nodes "!Instructions,CPI" -x, \
      -o /local/data/results/id_1_toplev_basic.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_basic.log 2>&1
  '
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
  sudo cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l1 -I 500 -v -x, \
      -o /local/data/results/id_1_toplev_execution.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_execution.log 2>&1
  '
  toplev_execution_end=$(date +%s)
  echo "Toplev execution profiling finished at: $(timestamp)"
  toplev_execution_runtime=$((toplev_execution_end - toplev_execution_start))
  echo "Toplev-execution runtime: $(secs_to_dhm "$toplev_execution_runtime")" \
    > /local/data/results/done_toplev_execution.log
fi

################################################################################
### 8. Toplev memory profiling
################################################################################

if $run_toplev_memory; then
  echo "Toplev memory profiling started at: $(timestamp)"
  toplev_memory_start=$(date +%s)
  sudo cset shield --exec -- sh -c "
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --nodes '!Backend_Bound.Memory_Bound*/3' -x, \
      -o /local/data/results/id_1_toplev_memory.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_memory.log 2>&1
  "
  toplev_memory_end=$(date +%s)
  echo "Toplev memory profiling finished at: $(timestamp)"
  toplev_memory_runtime=$((toplev_memory_end - toplev_memory_start))
  echo "Toplev-memory runtime: $(secs_to_dhm "$toplev_memory_runtime")" \
    > /local/data/results/done_toplev_memory.log
fi

################################################################################
### 9. Toplev IP profiling
################################################################################

if $run_toplev_ip; then
  echo "Toplev IP profiling started at: $(timestamp)"
  toplev_ip_start=$(date +%s)
  sudo cset shield --exec -- sh -c "
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l0 -I 500 -m --nodes '!IpBranch,IpCall,IpLoad,IpStore' -v -x, \
      -o /local/data/results/id_1_toplev_ip.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_ip.log 2>&1
  "
  toplev_ip_end=$(date +%s)
  echo "Toplev IP profiling finished at: $(timestamp)"
  toplev_ip_runtime=$((toplev_ip_end - toplev_ip_start))
  echo "Toplev-ip runtime: $(secs_to_dhm \"$toplev_ip_runtime\")" \
    > /local/data/results/done_toplev_ip.log
fi

################################################################################
### 10. Toplev profiling
################################################################################

if $run_toplev; then
  echo "Toplev profiling started at: $(timestamp)"
  toplev_start=$(date +%s)
  sudo cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_1_toplev.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev.log 2>&1
  '
  toplev_end=$(date +%s)
  echo "Toplev profiling finished at: $(timestamp)"
  toplev_runtime=$((toplev_end - toplev_start))
  echo "Toplev runtime: $(secs_to_dhm "$toplev_runtime")" \
    > /local/data/results/done_toplev.log
fi

################################################################################
### 11. Convert Maya raw output files into CSV
################################################################################

if $run_maya; then
  echo "Converting Maya output to CSV → /local/data/results/id_1_maya.csv"
  awk '
  {
    for (i = 1; i <= NF; i++) {
      printf "%s%s", $i, (i < NF ? "," : "")
    }
    print ""
  }
  ' /local/data/results/id_1_maya.txt > /local/data/results/id_1_maya.csv
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
      done_toplev.log \
      done_toplev_execution.log \
      done_toplev_memory.log \
      done_toplev_ip.log \
      done_maya.log \
      done_pcm.log; do
    if [[ -f /local/data/results/$log ]]; then
      echo
      cat /local/data/results/$log
    fi
  done
} > /local/data/results/done.log

rm -f /local/data/results/done_toplev_basic.log \
      /local/data/results/done_toplev.log \
      /local/data/results/done_toplev_execution.log \
      /local/data/results/done_toplev_memory.log \
      /local/data/results/done_toplev_ip.log \
      /local/data/results/done_maya.log \
      /local/data/results/done_pcm.log
