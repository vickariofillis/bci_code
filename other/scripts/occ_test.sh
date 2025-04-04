#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_occ_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_occ_%j.out

module load anaconda3

# Run the CPU burn test in the background
python3 /scratch/e/enright/vickario/research/bci/bci_code/other/tools/cpu_burn.py 3 &

# Run hwmon tracking for the same duration as CPU burn
python3 /scratch/e/enright/vickario/research/bci/bci_code/other/tools/hwmon_tracking.py 3 /scratch/e/enright/vickario/research/bci/stats/temp/hwmon_metrics.csv

wait
