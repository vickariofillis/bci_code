#!/usr/bin/env bash
set -euo pipefail

################################################################################
### Create results directory (if it doesn't exist already)
cd /local
mkdir -p data/results
# Get ownership of /local and grant read and execute permissions to everyone
sudo chown -R $USER:$USER /local  
chmod -R a+rx /local
################################################################################

### Run workload ID-1 (Seizure Detection - Laelaps)

cd ~
# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
sudo cset shield --cpu 5,6,15,16 --kthread=on

### 1) Toplev profiling
sudo cset shield --exec -- sh -c '
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_1_results.csv -- \
      taskset -c 6 /local/code/Laelaps_C/main \
        >> /local/data/results/id_1.log 2>&1
'

### 2) Maya profiling
sudo cset shield --exec -- sh -c '
  # Start Maya on core 5, backgrounding it
  taskset -c 5 bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_1_maya.txt 2>&1 &
  MAYA_PID=$!

  # Run the exact same workload on core 6
  taskset -c 6 /local/code/Laelaps_C/main \
    >> /local/data/results/id_1_maya.log 2>&1

  # Once the workload exits, kill Maya so it stops measuring
  kill $MAYA_PID
'

################################################################################

### Convert Maya output to CSV

echo "Converting /local/data/results/id_1_maya.txt → id_1_maya.csv"
awk '
{
  # join fields with commas
  for (i = 1; i <= NF; i++) {
    printf "%s%s", $i, (i < NF ? "," : "")
  }
  print ""
}
' /local/data/results/id_1_maya.txt > /local/data/results/id_1_maya.csv

echo "All done. Results in /local/data/results/"
