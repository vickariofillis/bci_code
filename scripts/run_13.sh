#!/bin/bash
set -euo pipefail

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

################################################################################
### Toplev profiling
################################################################################

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

################################################################################
### Maya profiling
################################################################################

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

################################################################################
### Convert Maya raw output to CSV
################################################################################

echo "Converting id_13_maya.txt → id_13_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?"," : "") } print "" }' \
  /local/data/results/id_13_maya.txt > /local/data/results/id_13_maya.csv

echo "All done. Results are in /local/data/results/"

# Signal completion for script monitoring

################################################################################

echo Done > /local/data/results/done.log
