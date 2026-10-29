#!/usr/bin/env python3
"""Execute the existing selected DAGs, without caching their acceptance."""
import argparse
import json
import os
import subprocess
import time

from select_tests import execution_batches

# Marks a batch's retry in the job log; report_issue.py files the failure before it.
RETRIED = "one automatic retry"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", help="JSON array from the selector")
    parser.add_argument("--check-part", choices=("all", "execution", "callers"), default="all")
    parser.add_argument("--ci-artifacts", help="Verified emitted executables from this run's producer")
    parser.add_argument("--retry", action="store_true",
                        help="Rerun a failed batch once; the selector allows it only without strict paths")
    args = parser.parse_args()
    targets = json.loads(args.targets)
    for batch in execution_batches(targets, args.check_part):
        returncode = execute(batch, args.ci_artifacts)
        if returncode and args.retry:
            note = (f"{' '.join(batch)} failed (exit {returncode}); {RETRIED}. "
                    "A pass after this retry is a flake to fix, not a clean pass.")
            print(f"::warning::{note}", flush=True)
            summarize(note)
            returncode = execute(batch, args.ci_artifacts)
            if not returncode:
                summarize(f"{' '.join(batch)} passed on its automatic retry after failing.")
        if returncode:
            summarize(f"Executed {' '.join(batch)}: failed (exit {returncode}). "
                      "Inspect the failed step. Retained artifacts are diagnostics, not acceptance.")
            raise SystemExit(returncode)
    summarize(f"Executed {', '.join(targets)} (partition {args.check_part}): passed. Fresh execution.")


def summarize(line):
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            print(line, file=summary)


def execute(batch, ci_artifacts):
    print("Executing: " + " ".join(batch), flush=True)
    start = time.monotonic()
    artifacts = ["-Dci-artifacts=" + ci_artifacts] if ci_artifacts else []
    # Fixtures copy their own retained diagnostics; this only runs the gate.
    returncode = subprocess.run(["zig", "build", *batch, *artifacts, "--summary", "all"]).returncode
    print(f"Completed {' '.join(batch)}: {time.monotonic() - start:.3f}s; exit {returncode}", flush=True)
    return returncode


if __name__ == "__main__":
    main()
