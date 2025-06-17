#!/bin/bash

# Format seconds as "Xd Yh Zm"
secs_to_dhm() {
  local total=$1
  printf '%dd %dh %dm' $((total/86400)) $(((total%86400)/3600)) $(((total%3600)/60))
}

################################################################################
### Create results directory (if it doesn't exist already)
cd /local; mkdir -p data; cd data; mkdir -p results;
# Get ownership of /local and grant read and execute permissions to everyone
chown -R "$USER":"$(id -gn)" /local
chmod -R a+rx /local

################################################################################

cd /local/bci_code/id_3/code

source /local/tools/compression_env/bin/activate

# Remove processes from Core 8 (CPU 5 and CPU 15) and Core 9 (CPU 6 and CPU 16)
sudo cset shield --cpu 5,6,15,16 --kthread=on
toplev_start=$(date +%s)


### Toplev profiling
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/compression_env/bin/activate

  taskset -c 5 /local/tools/pmu-tools/toplev \
    -l6 -I 500 --no-multiplex --all -x, \
    -o /local/data/results/id_3_aind_np1_flac_toplev.csv -- \
      taskset -c 6 python3 scripts/benchmark-lossless.py aind-np1 0.1s flac
' &>  /local/data/results/id_3_aind_np1_flac_toplev.log
toplev_end=$(date +%s)

### Maya profiling
maya_start=$(date +%s)
sudo -E cset shield --exec -- bash -lc '
  source /local/tools/compression_env/bin/activate

  # Start Maya in the background, pinned to CPU 5
  taskset -c 5 /local/bci_code/tools/maya/Dist/Release/Maya --mode Baseline \
    > /local/data/results/id_3_aind_np1_flac_maya.txt 2>&1 &

  sleep 1
  MAYA_PID=$(pgrep -n -f "Dist/Release/Maya")

  # Run the workload pinned to CPU 6
  taskset -c 6 python3 scripts/benchmark-lossless.py aind-np1 0.1s flac \
    >> /local/data/results/id_3_aind_np1_flac_maya.log 2>&1

  kill "$MAYA_PID"
'
maya_end=$(date +%s)

### Convert Maya output to CSV
echo "Converting id_3_aind_np1_flac_maya.txt → id_3_aind_np1_flac_maya.csv"
awk '{ for(i=1;i<=NF;i++){ printf "%s%s",$i,(i<NF?",":"") } print "" }' \
  /local/data/results/id_3_aind_np1_flac_maya.txt \
  > /local/data/results/id_3_aind_np1_flac_maya.csv

echo "aind-np1-flac profiling complete; results in /local/data/results/"

# Signal completion for script monitoring

# Write completion file with runtimes
toplev_runtime=$((toplev_end - toplev_start))
maya_runtime=$((maya_end - maya_start))
cat <<EOF > /local/data/results/done.log
Done

Toplev runtime: $(secs_to_dhm "$toplev_runtime")

Maya runtime:   $(secs_to_dhm "$maya_runtime")
EOF
