import argparse
import os
import time


def main():
    parser = argparse.ArgumentParser()
    delay_env = os.getenv("DELAY_S") or "0"
    parser.add_argument("delay_s", nargs="?", type=int, default=int(delay_env))
    args = parser.parse_args()
    delay_s = min(max(args.delay_s, 0), 20)

    for iteration in range(1, 6):
        print(f"iteration {iteration}/5 before it sleeps for {delay_s}s", flush=True)
        time.sleep(delay_s)

    print("job completed successfully", flush=True)


if __name__ == "__main__":
    main()
