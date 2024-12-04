#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_%j.out

module load anaconda3

# Get current date
d=$(date +%Y-%m-%d)

# Perf record
# Hardware Events
perf record -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -F 1 -o /scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/$d/perf_record_1_${SLURM_JOB_ID}.data -- python motor.py

# Move slurm output files
mv /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_${SLURM_JOB_ID}.err /scratch/e/enright/vickario/research/bci/stats/id-13/${d}/
mv /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_${SLURM_JOB_ID}.out /scratch/e/enright/vickario/research/bci/stats/id-13/${d}/