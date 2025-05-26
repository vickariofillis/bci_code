#!/usr/bin/env bash
set -euo pipefail

################################################################################
### run_id20_lm.sh
###   – Toplev + Maya profiling for the WFST/LM workload
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
# Ensure LD_LIBRARY_PATH exists so path.sh can append to it
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
# Run path.sh
. path.sh
# Export PYTHONPATH
export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

### Toplev profiling (LM)
sudo -E cset shield --exec -- sh -c '
  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_lm_toplev.csv -- \
      bash -lc " \
        cd /local/tools/bci_project && \
        source /local/tools/bci_env/bin/activate && \
        export LD_LIBRARY_PATH=\"${LD_LIBRARY_PATH:-}\" && \
        . path.sh && \
        export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\" && \
        python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
          --lmDir=/local/data/languageModel/ \
          --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        >> /local/data/results/id_20_3gram_lm_toplev.log 2>&1 \
      "
'

### Maya profiling (LM)
sudo -E cset shield --exec -- sh -c '
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_lm_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  taskset -c 6 bash -lc " \
    cd /local/tools/bci_project && \
    source /local/tools/bci_env/bin/activate && \
    export LD_LIBRARY_PATH=\"${LD_LIBRARY_PATH:-}\" && \
    . path.sh && \
    export PYTHONPATH=\"\$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:\${PYTHONPATH:-}\" && \
    python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
      --lmDir=/local/data/languageModel/ \
      --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    >> /local/data/results/id_20_3gram_lm_maya.log 2>&1 \
  "

  kill "$MAYA_PID"
'

### Convert Maya output to CSV
echo "Converting id_20_3gram_lm_maya.txt → id_20_3gram_lm_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_lm_maya.txt \
  > /local/data/results/id_20_3gram_lm_maya.csv

echo "LM profiling complete; results in /local/data/results/"
