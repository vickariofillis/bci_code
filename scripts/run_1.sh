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
workload_desc="ID-1 (Seizure Detection – Laelaps)"

# Announce planned run and provide 10s window to cancel
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

# Prepare placeholder logs for any disabled tools so that log consolidation
# works regardless of the selected combination.
$run_toplev_basic || echo "Toplev-basic run skipped" > /local/data/results/done_toplev_basic.log
$run_toplev_full || echo "Toplev-full run skipped" > /local/data/results/done_toplev_full.log
$run_toplev_execution || \
  echo "Toplev-execution run skipped" > /local/data/results/done_toplev_execution.log
$run_maya || echo "Maya run skipped" > /local/data/results/done_maya.log
$run_pcm || echo "PCM run skipped" > /local/data/results/done_pcm.log
$run_pcm_memory || echo "PCM-memory run skipped" > /local/data/results/done_pcm_memory.log
$run_pcm_power || echo "PCM-power run skipped" > /local/data/results/done_pcm_power.log
$run_pcm_pcie || echo "PCM-pcie run skipped" > /local/data/results/done_pcm_pcie.log

################################################################################
### 2. Change into the proper directory
################################################################################
cd ~

################################################################################
### 3. Power envelope & topology prep (3 CPUs: house=0, meas=5, work=6)
###    - Enforce 15W package cap (10ms window) + 5W DRAM cap
###    - Disable Turbo
###    - Fix 1.2GHz on selected CPUs
###    - Keep CPUs 0,5,6 online; disable HT siblings; offline everything else
###    - Steer IRQs to CPU0; keep cset disabled until after PCM
################################################################################
# Defaults can be overridden via env if needed
HOUSE_CPU=${HOUSE_CPU:-0}
MEAS_CPU=${MEAS_CPU:-5}
WORK_CPU=${WORK_CPU:-6}
FREQ=${FREQ:-1200MHz}
PKG_W=${PKG_W:-15}
RAPL_WIN_US=${RAPL_WIN_US:-10000000}

echo "Power/topology: PKG=${PKG_W}W, DRAM=5W, Turbo=off, Freq=${FREQ}, CPUs {house=${HOUSE_CPU}, meas=${MEAS_CPU}, work=${WORK_CPU}}"

# Modules/tools
sudo modprobe msr || true

# Disable Turbo
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null || true

# Fix frequency on selected CPUs (each CPU has its own policy on this node)
for cpu in "$HOUSE_CPU" "$MEAS_CPU" "$WORK_CPU"; do
  sudo cpupower -c "$cpu" frequency-set -g userspace
  sudo cpupower -c "$cpu" frequency-set -d "$FREQ" -u "$FREQ" -f "$FREQ"
done

# Bias energy policy (harmless with fixed freq)
x86_energy_perf_policy --all power >/dev/null 2>&1 || true

# Package cap (µW) + averaging window (µs)
DOM=/sys/class/powercap/intel-rapl:0
if [ -e "$DOM/constraint_0_power_limit_uw" ]; then
  echo $((PKG_W*1000000)) | sudo tee "$DOM/constraint_0_power_limit_uw" >/dev/null
  echo "$RAPL_WIN_US"     | sudo tee "$DOM/constraint_0_time_window_us"  >/dev/null || true
fi

# DRAM cap: keep 5W as discussed
DRAM=/sys/class/powercap/intel-rapl:0:0
if [ -e "$DRAM/constraint_0_power_limit_uw" ]; then
  echo $((5*1000000)) | sudo tee "$DRAM/constraint_0_power_limit_uw" >/dev/null
fi

# Keep this shell on housekeeping CPU so offlining others is safe
taskset -pc "$HOUSE_CPU" $$ >/dev/null 2>&1 || true

# Helper: disable HT siblings except the chosen logical CPU
disable_siblings_except_self() {
  local cpu=$1
  local f="/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
  [ -r "$f" ] || return 0
  IFS=',' read -ra parts <<< "$(cat "$f")"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      start=${p%-*}; end=${p#*-}
      for s in $(seq "$start" "$end"); do
        [ "$s" != "$cpu" ] && [ -e "/sys/devices/system/cpu/cpu$s/online" ] && echo 0 | sudo tee "/sys/devices/system/cpu/cpu$s/online" >/dev/null || true
      done
    else
      [ "$p" != "$cpu" ] && [ -e "/sys/devices/system/cpu/cpu$p/online" ] && echo 0 | sudo tee "/sys/devices/system/cpu/cpu$p/online" >/dev/null || true
    fi
  done
}

# Online only housekeeping + measurement + workload; offline everything else
for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
  cpu=${cpu_path##*/cpu}
  [ -e "$cpu_path/online" ] || continue
  if [ "$cpu" = "$HOUSE_CPU" ] || [ "$cpu" = "$MEAS_CPU" ] || [ "$cpu" = "$WORK_CPU" ]; then
    echo 1 | sudo tee "$cpu_path/online" >/dev/null
  else
    echo 0 | sudo tee "$cpu_path/online" >/dev/null || true
  fi
done

# Ensure single thread per chosen core
disable_siblings_except_self "$HOUSE_CPU"
disable_siblings_except_self "$MEAS_CPU"
disable_siblings_except_self "$WORK_CPU"

# Steer interrupts to housekeeping CPU; stop irqbalance if present
systemctl stop irqbalance 2>/dev/null || true
for f in /proc/irq/*/smp_affinity_list; do echo "$HOUSE_CPU" | sudo tee "$f" >/dev/null; done

# Show final set
echo -n "Online CPUs: "
grep -H . /sys/devices/system/cpu/cpu*/online 2>/dev/null | awk -F'[/:]' '$0 ~ /online/ && $NF==1 {print $(NF-1)}' | xargs echo

################################################################################
### 4. PCM profiling
################################################################################

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  sudo modprobe msr
fi

if $run_pcm; then
  echo "pcm started at: $(timestamp)"
  pcm_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm \
      -csv=/local/data/results/id_1_pcm.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm.log 2>&1
  '
  pcm_end=$(date +%s)
  echo "pcm finished at: $(timestamp)"
  pcm_runtime=$((pcm_end - pcm_start))
  echo "pcm runtime: $(secs_to_dhm "$pcm_runtime")" \
    > /local/data/results/done_pcm.log
fi

if $run_pcm_memory; then
  echo "pcm-memory started at: $(timestamp)"
  pcm_memory_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-memory \
      -csv=/local/data/results/id_1_pcm_memory.csv \
      0.5 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_memory.log 2>&1
  '
  pcm_memory_end=$(date +%s)
  echo "pcm-memory finished at: $(timestamp)"
  pcm_memory_runtime=$((pcm_memory_end - pcm_memory_start))
  echo "pcm-memory runtime: $(secs_to_dhm "$pcm_memory_runtime")" \
    > /local/data/results/done_pcm_memory.log
fi

if $run_pcm_power; then
  echo "pcm-power started at: $(timestamp)"
  pcm_power_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-power 0.5 \
      -p 0 -a 10 -b 20 -c 30 \
      -csv=/local/data/results/id_1_pcm_power.csv -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_power.log 2>&1
  '
  pcm_power_end=$(date +%s)
  echo "pcm-power finished at: $(timestamp)"
  pcm_power_runtime=$((pcm_power_end - pcm_power_start))
  echo "pcm-power runtime: $(secs_to_dhm "$pcm_power_runtime")" \
    > /local/data/results/done_pcm_power.log
fi

if $run_pcm_pcie; then
  echo "pcm-pcie started at: $(timestamp)"
  pcm_pcie_start=$(date +%s)
  sudo sh -c '
    taskset -c 5 /local/tools/pcm/build/bin/pcm-pcie \
      -csv=/local/data/results/id_1_pcm_pcie.csv \
      -B 1.0 -- \
      taskset -c 6 /local/bci_code/id_1/main \
    >>/local/data/results/id_1_pcm_pcie.log 2>&1
  '
  pcm_pcie_end=$(date +%s)
  echo "pcm-pcie finished at: $(timestamp)"
  pcm_pcie_runtime=$((pcm_pcie_end - pcm_pcie_start))
  echo "pcm-pcie runtime: $(secs_to_dhm "$pcm_pcie_runtime")" \
    > /local/data/results/done_pcm_pcie.log
fi

if $run_pcm || $run_pcm_memory || $run_pcm_power || $run_pcm_pcie; then
  echo "PCM profiling finished at: $(timestamp)"
fi

################################################################################
### 5. Shield CPUs 5 and 6 (reserve them for our measurement + workload)
################################################################################
sudo cset shield --cpu 5,6 --kthread=on

################################################################################
### 6. Maya profiling
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
### 7. Toplev basic profiling
################################################################################

if $run_toplev_basic; then
  echo "Toplev basic profiling started at: $(timestamp)"
  toplev_basic_start=$(date +%s)
  sudo cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l3 -I 500 -v --no-multiplex \
      -A --per-thread --columns \
      --nodes "!Instructions,CPI,L1MPKI,L2MPKI,L3MPKI,Backend_Bound.Memory_Bound*/3,IpBranch,IpCall,IpLoad,IpStore" -m -x, \
      -o /local/data/results/id_1_toplev_basic.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_basic.log 2>&1'
  toplev_basic_end=$(date +%s)
  echo "Toplev basic profiling finished at: $(timestamp)"
  toplev_basic_runtime=$((toplev_basic_end - toplev_basic_start))
  echo "Toplev-basic runtime: $(secs_to_dhm "$toplev_basic_runtime")" \
    > /local/data/results/done_toplev_basic.log
fi

################################################################################
### 8. Toplev execution profiling
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
### 9. Toplev full profiling
################################################################################

if $run_toplev_full; then
  echo "Toplev full profiling started at: $(timestamp)"
  toplev_full_start=$(date +%s)
  sudo cset shield --exec -- sh -c '
    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 -v --no-multiplex --all -x, \
      -o /local/data/results/id_1_toplev_full.csv -- \
        taskset -c 6 /local/bci_code/id_1/main \
          >> /local/data/results/id_1_toplev_full.log 2>&1
  '
  toplev_full_end=$(date +%s)
  echo "Toplev full profiling finished at: $(timestamp)"
  toplev_full_runtime=$((toplev_full_end - toplev_full_start))
  echo "Toplev-full runtime: $(secs_to_dhm "$toplev_full_runtime")" \
    > /local/data/results/done_toplev_full.log
fi

################################################################################
### 10. Convert Maya raw output files into CSV
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
### 11. Signal completion for tmux monitoring
################################################################################    
echo "All done. Results are in /local/data/results/"
echo "Experiment finished at: $(timestamp)"

################################################################################
### 12. Write completion file with runtimes
################################################################################
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
      /local/data/results/done_pcm.log \
      /local/data/results/done_pcm_memory.log \
      /local/data/results/done_pcm_power.log \
      /local/data/results/done_pcm_pcie.log
