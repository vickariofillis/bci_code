#!/usr/bin/env bash
set -euo pipefail

################################################################################

# Create results directory (if it doesn't exist already)
cd /local; mkdir -p data/results

# Get ownership of /local and grant read+execute to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################

### Run workload ID-1 (Seizure Detection – Laelaps)

cd ~

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
sudo cset shield --cpu 5,6,15,16 --kthread=on

# Toplev profiling
sudo cset shield --exec -- sh -c '
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_1_toplev.csv -- \
      taskset -c 6 /local/bci_code/id_1/main \
        >> /local/data/results/id_1_toplev.log 2>&1
'

# Maya profiling
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

################################################################################

### Convert Maya raw output to CSV

echo "Converting Maya output to CSV → /local/data/results/id_1_maya.csv"
awk '
{
  for (i = 1; i <= NF; i++) {
    printf "%s%s", $i, (i < NF ? "," : "")
  }
  print ""
}
' /local/data/results/id_1_maya.txt > /local/data/results/id_1_maya.csv

echo "All done. Results are in /local/data/results/"
