#!/usr/bin/env python3
"""Execute the existing selected DAGs, without caching their acceptance."""
import argparse
import json
import subprocess
import time

from select_tests import execution_batches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", help="JSON array from the selector")
    parser.add_argument("--check-part", choices=("all", "execution", "callers"), default="all")
    args = parser.parse_args()
    for batch in execution_batches(json.loads(args.targets), args.check_part):
        print("Executing: " + " ".join(batch), flush=True)
        start = time.monotonic()
        result = subprocess.run(["zig", "build", *batch, "--summary", "all"])
        print(f"Completed {' '.join(batch)}: {time.monotonic() - start:.3f}s; exit {result.returncode}",
              flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
