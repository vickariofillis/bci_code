#!/bin/bash

#SBATCH --nodes=1
#SBATCH --gpus-per-node=1
#SBATCH --time=0:15:0
#SBATCH -e /scratch/e/enright/vickario/research/bci/stats/temp/slurm_occ__%j.err
#SBATCH -o /scratch/e/enright/vickario/research/bci/stats/temp/slurm_occ_%j.out

module load anaconda3

# IBM OCC (hwmon)
python3 /scratch/e/enright/vickario/tools/cpu-burn.py

# Directory containing hwmon metrics
HWMON_DIR="/sys/class/hwmon/hwmon0"
OUTPUT_FILE="/scratch/e/enright/vickario/research/bci/stats/temp/hwmon_metrics.csv"

# Set the sampling period in seconds (modular)
SAMPLING_PERIOD=1

# Write CSV header
echo "Iteration,Label,Current Value,Highest Value,Lowest Value" > $OUTPUT_FILE

# Function to collect metrics
collect_metrics() {
    local iteration=$1
    for label_file in "$HWMON_DIR"/*_label; do
        # Get the base metric name (e.g., power1)
        base_name=$(basename "$label_file" _label)

        # Read the label, current, highest, and lowest values
        label=$(cat "$label_file")
        current_value=$(cat "$HWMON_DIR/${base_name}_input" 2>/dev/null || echo "N/A")
        highest_value=$(cat "$HWMON_DIR/${base_name}_highest" 2>/dev/null || echo "N/A")
        lowest_value=$(cat "$HWMON_DIR/${base_name}_lowest" 2>/dev/null || echo "N/A")

        # Append the metric to the CSV
        echo "$iteration,$label,$current_value,$highest_value,$lowest_value" >> $OUTPUT_FILE
    done
}

# Periodically collect metrics until the job ends
iteration=0
while true; do
    collect_metrics $iteration
    iteration=$((iteration + 1))
    sleep $SAMPLING_PERIOD
done

echo "Metrics collected periodically and written to $OUTPUT_FILE"
