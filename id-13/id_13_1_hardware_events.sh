#!/bin/bash
#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0

module load anaconda3
# source activate conda_env
perf stat -o /scratch/e/enright/vickario/research/bci/stats/id-13/1_hardware_events.txt -B -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend python motor.py