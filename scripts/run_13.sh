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
run_maya=false
run_pcm=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toplev) run_toplev=true ;;
    --maya)   run_maya=true ;;
    --pcm)    run_pcm=true ;;
    *) echo "Usage: $0 [--toplev] [--maya] [--pcm]" >&2; exit 1 ;;
  esac
  shift
done
if ! $run_toplev && ! $run_maya && ! $run_pcm; then
  run_toplev=true
  run_maya=true
  run_pcm=true
fi

# Describe this workload
workload_desc="ID-13 (Movement Intent)"

# Announce planned run and provide 10s window to cancel
tools_list=()
$run_toplev && tools_list+=("toplev")
$run_maya && tools_list+=("maya")
$run_pcm  && tools_list+=("pcm")
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
pcm_start=0
pcm_end=0

# Format seconds as "Xd Yh Zm"
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

################################################################################
### Create results directory (if it doesn't exist already)
################################################################################
cd /local; mkdir -p data/results
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################
### Run workload ID-13 (Movement Intent)
################################################################################
cd ~

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

if $run_toplev; then
  toplev_start=$(date +%s)
  sudo -E cset shield --exec -- bash -lc '
    export MLM_LICENSE_FILE="27000@mlm.ece.utoronto.ca"
    export LM_LICENSE_FILE="$MLM_LICENSE_FILE"
    export MATLAB_PREFDIR="/local/tools/matlab_prefs/R2024b"

    taskset -c 5 /local/tools/pmu-tools/toplev \
      -l6 -I 500 --no-multiplex --all -x, \
      -o /local/data/results/id_13_toplev.csv -- \
        taskset -c 6 /local/tools/matlab/bin/matlab \
          -nodisplay -nosplash \
          -r "cd('\''/local/bci_code/id_13'\''); motor_movement('\''/local/data/S5_raw_segmented.mat'\'', '\''/local/tools/fieldtrip/fieldtrip-20240916'\''); exit;"
  ' &> /local/data/results/id_13_toplev.log
  toplev_end=$(date +%s)
fi

if $run_maya; then
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
fi

if $run_pcm; then
  pcm_start=$(date +%s)
  sudo cset shield --reset
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
fi

################################################################################
if $run_maya; then
### Convert Maya raw output to CSV
echo "Converting id_13_maya.txt → id_13_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
  /local/data/results/id_13_maya.txt > /local/data/results/id_13_maya.csv
fi

echo "All done. Results are in /local/data/results/"

# Signal completion for script monitoring

################################################################################


# Write completion file with runtimes
toplev_runtime=0
maya_runtime=0
pcm_runtime=0
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
  if $run_pcm; then
    pcm_runtime=$((pcm_end - pcm_start))
    echo
    echo "PCM runtime:    $(secs_to_dhm "$pcm_runtime")"
  fi
} > /local/data/results/done.log

