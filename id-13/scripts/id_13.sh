#!/bin/bash

# Get current date
d=$(date +%Y-%m-%d)
# Create stats folder of current date if it doesn't exist
if [ ! -d "/scratch/e/enright/vickario/research/bci/stats/id-13/$d" ]; then
  mkdir /scratch/e/enright/vickario/research/bci/stats/id-13/$d
fi

# Array of job scripts
declare -a arr=("nvidia_smi.sh"
                "perf_stat_1.sh"
                "perf_record_1.sh"
                )

# Iterate over job scripts
for i in "${arr[@]}"
do
    # Make job(s) scripts executable
    chmod +x $i
    # Scehdule job(s)
    sbatch $i
done