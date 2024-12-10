import multiprocessing
import time
import signal
import sys
import argparse

def cpu_stress():
    while True:
        pass  # Keep the CPU busy

def signal_handler(sig, frame):
    print("CPU stress test stopped.")
    sys.exit(0)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run a CPU stress test for a specified duration.")
    parser.add_argument("minutes", type=int, help="Duration of the CPU stress test in minutes.")
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
        # Run for the specified duration
        time.sleep(duration)
    except KeyboardInterrupt:
        print("Stopping CPU stress test...")
    finally:
        for p in processes:
            p.terminate()
        print("CPU stress test completed.")
