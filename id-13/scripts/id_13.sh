#!/bin/bash

# Get current date
d=$(date +%Y-%m-%d)

# Array of tools
declare -a arr=("nvidia_smi"
                # "perf_stat_1"
                # "perf_record_1"
                )

# Create stats folder of current date if they don't exist
for i in "${arr[@]}"
do
    if [ ! -d "/scratch/e/enright/vickario/research/bci/stats/id-13/${i}/$d" ]; then
      mkdir /scratch/e/enright/vickario/research/bci/stats/id-13/${i}/$d
    fi
done

# Iterate over job scripts
for i in "${arr[@]}"
do
    # Make job(s) scripts executable
    chmod +x ${i}.sh
    # Scehdule job(s)
    sbatch ${i}.sh
done