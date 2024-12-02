#!/bin/bash

# Get current date
d=$(date +%Y-%m-%d)

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/id-13/$(d)/slurm_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/id-13/$(d)/slurm_%j.out

module load anaconda3

# Perf record
perf record -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -F 1 -o /scratch/e/enright/vickario/research/bci/stats/id-13/$d/perf_record_1_${SLURM_JOB_ID}.data -- python motor.py