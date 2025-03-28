#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_%j.out

module load anaconda3

# Perf record
# Hardware Events
perf record -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -F 1 -o /scratch/e/enright/vickario/research/bci/stats/temp/perf_record_1_${SLURM_JOB_ID}.data -- python /scratch/e/enright/vickario/research/bci/bci_code/id-13/motor.py

# Get current date
d=$(date +%Y-%m-%d)

# Move slurm output files
cp /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_${SLURM_JOB_ID}.err /scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/${d}/
cp /scratch/e/enright/vickario/research/bci/stats/temp/slurm_perf_record_${SLURM_JOB_ID}.out /scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/${d}/
cp /scratch/e/enright/vickario/research/bci/stats/temp/perf_record_1_${SLURM_JOB_ID}.data /scratch/e/enright/vickario/research/bci/stats/id-13/perf_record/${d}/