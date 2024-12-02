#!/bin/bash

# Get current date
d=$(date +%Y-%m-%d)

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/id-13/$(d)/slurm_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/id-13/$(d)/slurm_%j.out

module load anaconda3

# Perf stat
perf stat -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -x, -o /scratch/e/enright/vickario/research/bci/stats/id-13/$d/perf_stat_1_${SLURM_JOB_ID}.csv -- python motor.py