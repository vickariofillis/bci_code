#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_nvidia_smi_%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_nvidia_smi_%j.out

module load anaconda3

# Start nvidia-smi monitoring in the background and save the output to a file
nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.total,memory.used,power.draw --format=csv -l 1 > /scratch/e/enright/vickario/research/bci/stats/temp/nvidia_smi_${SLURM_JOB_ID}.log &

# Get the PID of the nvidia-smi monitoring
SMI_PID=$!

# Kill the nvidia-smi process after the program completes
kill $SMI_PID

# Get current date
d=$(date +%Y-%m-%d)

# Copy slurm output files
cp /scratch/e/enright/vickario/research/bci/stats/temp/slurm_nvidia_smi_${SLURM_JOB_ID}.err /scratch/e/enright/vickario/research/bci/stats/id-13/nvidia_smi/${d}/
cp /scratch/e/enright/vickario/research/bci/stats/temp/slurm_nvidia_smi_${SLURM_JOB_ID}.out /scratch/e/enright/vickario/research/bci/stats/id-13/nvidia_smi/${d}/
cp scratch/e/enright/vickario/research/bci/stats/temp/nvidia_smi_${SLURM_JOB_ID}.log /scratch/e/enright/vickario/research/bci/stats/id-13/nvidia_smi/${d}/