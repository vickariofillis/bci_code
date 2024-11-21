#!/bin/bash
#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/other/slurm-%x%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/other/slurm-%x%j.out

module load anaconda3
# source activate conda_env

# Start nvidia-smi monitoring in the background and save the output to a file
nvidia-smi --query-gpu=index,timestamp,name,driver_version,uuid,utilization.gpu,utilization.memory,memory.total,memory.used,memory.free,temperature.gpu,power.draw,power.limit,clocks.current.graphics,clocks.current.sm,clocks.current.memory,clocks.max.graphics,clocks.max.sm,clocks.max.memory,fan.speed,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,encoder.stats.sessionCount,encoder.stats.averageFps,encoder.stats.averageLatency --format=csv -l 1 > /scratch/e/enright/vickario/research/bci/stats/other/gpu_stats_${SLURM_JOB_ID}.log &

# Get the PID of the nvidia-smi monitoring
SMI_PID=$!

perf stat  -e branch-instructions,branch-misses,cache-misses,cache-references,cpu-cycles,instructions,stalled-cycles-backend,stalled-cycles-frontend -x, -o /scratch/e/enright/vickario/research/bci/stats/other/1_hardware_events${SLURM_JOB_ID}.csv -- /scratch/e/enright/vickario/tools/gpu-burn 180

# Kill the nvidia-smi process after the program completes
kill $SMI_PID