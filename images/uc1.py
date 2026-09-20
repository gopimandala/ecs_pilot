import argparse
import os
import time
import sys
from multiprocessing import Process


def run_workload():
    """
    Core Application Logic.
    Your main looping and processing structure stays completely clean, 
    untouched, and readable here.
    """
    parser = argparse.ArgumentParser()
    delay_env = os.getenv("DELAY_S") or "0"
    parser.add_argument("delay_s", nargs="?", type=int, default=int(delay_env))
    args = parser.parse_args()
    
    # Bound cap to safely protect demo iterations
    delay_s = min(max(args.delay_s, 0), 40)

    for iteration in range(1, 6):
        print(f"iteration {iteration}/5 before it sleeps for {delay_s}s", flush=True)
        time.sleep(delay_s)

    print("job completed successfully", flush=True)


def main():
    # 1. Read the environment timeout limit passed down by your Terraform infrastructure
    timeout_limit = int(os.getenv("TASK_TIMEOUT_SECONDS", "30"))

    # 2. Spawn your core workload inside an isolated child process context
    worker_process = Process(target=run_workload)
    worker_process.start()

    # 3. Wait strictly up to the timeout limit for the worker process to complete
    worker_process.join(timeout=timeout_limit)

    # 4. If the process is still alive after join returns, it breached the ceiling
    if worker_process.is_alive():
        print(
            f"\n[ERROR] Application self-regulated failure: Task exceeded its {timeout_limit}s limit!",
            flush=True,
        )
        # Forcefully terminate the stuck execution branch immediately
        worker_process.terminate()
        worker_process.join()  # Prevent zombie system processes by reaping resources
        sys.exit(124)          # Return distinct failure code 124 to your monitor script

    # 5. Mirror the exit code of the completed workload process (0 for success, non-zero for bugs)
    sys.exit(worker_process.exitcode)


if __name__ == "__main__":
    main()
