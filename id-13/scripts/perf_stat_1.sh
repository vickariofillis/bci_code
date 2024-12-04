#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_stat_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_stat_%j.out

module load anaconda3

# Perf stat
# Hardware Events
perf stat -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -x, -o /scratch/e/enright/vickario/research/bci/stats/id-13/$d/perf_stat_1_${SLURM_JOB_ID}.csv -- python motor.py

# Get current date
d=$(date +%Y-%m-%d)

# Move slurm output files
mv /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_stat_${SLURM_JOB_ID}.err /scratch/e/enright/vickario/research/bci/stats/id-13/${d}/
mv /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_stat_${SLURM_JOB_ID}.out /scratch/e/enright/vickario/research/bci/stats/id-13/${d}/