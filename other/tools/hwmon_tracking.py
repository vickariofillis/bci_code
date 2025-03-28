import time
import argparse
from pathlib import Path

def collect_metrics(hwmon_dir, output_file, duration):
    start_time = time.time()
    iteration = 0

    # Write CSV header
    with open(output_file, "w") as f:
        f.write("Label,Iteration,Current Value,Highest Value,Lowest Value\n")

    while time.time() - start_time < duration:
        with open(output_file, "a") as f:
            for label_file in hwmon_dir.glob("*_label"):
                base_name = label_file.stem[:-6]  # Remove _label suffix

                label = label_file.read_text().strip()
                current_value = (hwmon_dir / f"{base_name}_input").read_text().strip() if (hwmon_dir / f"{base_name}_input").exists() else "N/A"
                highest_value = (hwmon_dir / f"{base_name}_highest").read_text().strip() if (hwmon_dir / f"{base_name}_highest").exists() else "N/A"
                lowest_value = (hwmon_dir / f"{base_name}_lowest").read_text().strip() if (hwmon_dir / f"{base_name}_lowest").exists() else "N/A"

                f.write(f"{label},{iteration},{current_value},{highest_value},{lowest_value}\n")

        iteration += 1
        time.sleep(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Track hwmon stats and write them to a CSV file.")
    parser.add_argument("duration", type=int, help="Duration of tracking in minutes.")
    parser.add_argument("output_file", type=str, help="Path to the output CSV file.")
    args = parser.parse_args()

    # Convert minutes to seconds
    duration = args.duration * 60

    hwmon_dir = Path("/sys/class/hwmon/hwmon0")

    print(f"Starting hwmon tracking for {args.duration} minutes. Writing to {args.output_file}.")
    collect_metrics(hwmon_dir, args.output_file, duration)
    print("Hwmon tracking completed.")
