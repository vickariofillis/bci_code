#!/usr/bin/env bash
set -euo pipefail

################################################################################
### run_id20_rnn.sh
###   – Toplev + Maya profiling for the RNN workload
################################################################################

### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################

cd ~;

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
cset shield --cpu 5,6,15,16 --kthread=on

# Move to proper directory
cd /local/tools/bci_project/
# Source virtual environment
source /local/tools/bci_env/bin/activate
# Run path.sh
. path.sh
# Export PYTHONPATH
export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:$PYTHONPATH"

### Toplev profiling (RNN)
sudo -E cset shield --exec -- sh -c '
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_rnn_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/ \
        >> /local/data/results/id_20_rnn_toplev.log 2>&1
'

### Maya profiling (RNN)
sudo -E cset shield --exec -- sh -c '
  # Start Maya on core 5
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_rnn_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  # Run RNN workload on core 6
  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
    --datasetPath=/local/data/ptDecoder_ctc \
    --modelPath=/local/data/speechBaseline4/ \
    >> /local/data/results/id_20_rnn_maya.log 2>&1

  kill "$MAYA_PID"
'

### Convert Maya output to CSV
echo "Converting id_20_rnn_maya.txt → id_20_rnn_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }' \
  /local/data/results/id_20_rnn_maya.txt \
  > /local/data/results/id_20_rnn_maya.csv

echo "RNN profiling complete; results in /local/data/results/"
