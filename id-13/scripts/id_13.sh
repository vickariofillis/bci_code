#!/bin/bash

# Get current date
d=$(date +%Y-%m-%d)

# Array of tools
declare -a arr=(
                # "nvidia_smi"
                "perf_stat_1"
                # "perf_record_1"
                )



# Create stats folder of current date if they don't exist
for i in "${arr[@]}"
do
    if [[ ${i} =~ ^perf_stat_. ]]; then
        echo "perf_stat_."
        if [ ! -d "/scratch/e/enright/vickario/research/bci/stats/id-13/perf_stat/$d" ]; then
          mkdir /scratch/e/enright/vickario/research/bci/stats/id-13/perf_stat/$d
        fi
    elif [[ ${i} =~ ^perf_record_. ]]; then
        echo "perf_record_."
        if [ ! -d "/scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/$d" ]; then
          mkdir /scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/$d
        fi
    elif [[ ${i} =~ ^nvidia_smi ]]; then
        echo "nvidia_smi"
        if [ ! -d "/scratch/e/enright/vickario/research/bci/stats/id-13/nvidia_smi/$d" ]; then
          mkdir /scratch/e/enright/vickario/research/bci/stats/id-13/nvidia_smi/$d
        fi
    else
        echo "No match found."
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