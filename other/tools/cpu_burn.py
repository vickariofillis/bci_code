import multiprocessing
import time
import signal
import sys
import argparse

def cpu_stress():
    while True:
        pass  # Keep the CPU busy

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

def signal_handler(sig, frame):
    print("CPU stress test stopped.")
    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run a CPU stress test and collect OCC metrics.")
    parser.add_argument("minutes", type=int, help="Duration of the CPU stress test in minutes.")
    parser.add_argument("output_file", type=str, help="Path to the output CSV file.")
    args = parser.parse_args()

    # Convert minutes to seconds
    duration = args.minutes * 60

    print(f"Starting CPU stress test for {args.minutes} minutes. Press Ctrl+C to stop.")

    # Register signal handler for graceful exit
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Get the number of CPU cores
    num_cores = multiprocessing.cpu_count()
    print(f"Using {num_cores} CPU cores.")

    # Start a process for each core
    processes = []
    for _ in range(num_cores):
        p = multiprocessing.Process(target=cpu_stress)
        p.start()
        processes.append(p)

    try:
        from pathlib import Path
        hwmon_dir = Path("/sys/class/hwmon/hwmon0")
        collect_metrics(hwmon_dir, args.output_file, duration)
    except KeyboardInterrupt:
        print("Stopping CPU stress test...")
    finally:
        for p in processes:
            p.terminate()
        print("CPU stress test and OCC metric collection completed.")
