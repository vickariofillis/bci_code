#!/bin/bash
set -euo pipefail

################################################################################
### 1. Create results directory (if it doesn't exist already)
################################################################################
cd /local; mkdir -p data/results
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################
### 2. Shield CPUs 5, 6, 15, and 16 (reserve them for our measurement + workload)
################################################################################
sudo cset shield --cpu 5,6,15,16 --kthread=on

################################################################################
### 3. Change into the BCI project directory
################################################################################
cd /local/tools/bci_project

################################################################################
### 4. Toplev profiling
################################################################################

# Run the RNN script under toplev (toplev on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_rnn_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
        --datasetPath=/local/data/ptDecoder_ctc \
        --modelPath=/local/data/speechBaseline4/
' &> /local/data/results/id_20_3gram_rnn_toplev.log

# Run the LM script under toplev (toplev on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_lm_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
        --lmDir=/local/data/languageModel/ \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl
' &> /local/data/results/id_20_3gram_lm_toplev.log

# Run the LLM script under toplev (toplev on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_20_3gram_llm_toplev.csv -- \
      taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
        --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
        --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl
' &> /local/data/results/id_20_3gram_llm_toplev.log

################################################################################
### 5. Maya profiling
################################################################################

# Run the RNN script under Maya (Maya on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  # Start Maya in the background, pinned to CPU 5
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_rnn_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  # Run the workload pinned to CPU 6
  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/rnn_run.py \
    --datasetPath=/local/data/ptDecoder_ctc \
    --modelPath=/local/data/speechBaseline4/ \
    >> /local/data/results/id_20_3gram_rnn_maya.log 2>&1

  kill "$MAYA_PID"
'

# Run the LM script under Maya (Maya on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_lm_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/wfst_model_run.py \
    --lmDir=/local/data/languageModel/ \
    --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    >> /local/data/results/id_20_3gram_lm_maya.log 2>&1

  kill "$MAYA_PID"
'

# Run the LLM script under Maya (Maya on CPU 5, workload on CPU 6)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/bci_env/bin/activate
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  . path.sh
  export PYTHONPATH="$(pwd)/bci_code/id_20/code/neural_seq_decoder/src:${PYTHONPATH:-}"

  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_20_3gram_llm_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  taskset -c 6 python3 bci_code/id_20/code/neural_seq_decoder/scripts/llm_model_run.py \
    --rnnRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/rnn_output/rnn_results.pkl \
    --nbRes=/proj/nejsustain-PG0/data/bci/id-20/outputs/3gram/lm_output/nbest_results.pkl \
    >> /local/data/results/id_20_3gram_llm_maya.log 2>&1

  kill "$MAYA_PID"
'

################################################################################
### 6. Convert Maya raw output files into CSV
################################################################################

echo "Converting id_20_3gram_rnn_maya.txt → id_20_3gram_rnn_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_rnn_maya.txt \
  > /local/data/results/id_20_3gram_rnn_maya.csv

echo "Converting id_20_3gram_lm_maya.txt → id_20_3gram_lm_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_lm_maya.txt \
  > /local/data/results/id_20_3gram_lm_maya.csv

echo "Converting id_20_3gram_llm_maya.txt → id_20_3gram_llm_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s", $i, (i<NF?",":"") } print "" }' \
  /local/data/results/id_20_3gram_llm_maya.txt \
  > /local/data/results/id_20_3gram_llm_maya.csv

echo "Maya profiling complete; CSVs are in /local/data/results/"

# Signal completion

################################################################################

echo Done > /local/data/results/done.log
