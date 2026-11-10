#!/usr/bin/env python3
"""Execute the existing selected DAGs, without caching their acceptance."""
import argparse
import json
import os
import subprocess
import sys
import time

from select_tests import execution_batches
from build_artifact import pr_ci
import quarantine
from report_issue import fixtures
from steps import record_failure

# Marks a batch's retry in the job log; report_issue.py files the failure before it.
RETRIED = "one automatic retry"
# A unit test past this is stalled: Zig's runner kills it and names it,
# where a job timeout reports only "cancelled" (#755 stalled 34 minutes).
TEST_TIMEOUT = "5m"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", help="JSON array from the selector")
    parser.add_argument("--check-part", choices=("all", "execution", "callers"), default="all")
    parser.add_argument("--ci-artifacts", help="Verified emitted executables from this run's producer")
    parser.add_argument("--retry", action="store_true",
                        help="Rerun a failed batch once; the selector allows it only without strict paths")
    parser.add_argument("--quarantine", choices=("off", "admission", "promotion"), default="off",
                        help="Rerun a batch that failed only on listed flakes (quarantine.json); admission "
                             "then passes a second such failure, promotion fails it")
    args = parser.parse_args()
    targets = json.loads(args.targets)
    for batch in execution_batches(targets, args.check_part):
        returncode, output = execute(batch, args.ci_artifacts)
        if returncode and args.quarantine != "off" and (flakes := listed(output)):
            note = (f"{' '.join(batch)} failed only on listed flakes ({issues(flakes)}); "
                    "rerunning it once. A listed flake still needs its fix.")
            print(f"::warning::{note}", flush=True)
            summarize(note)
            returncode, output = execute(batch, args.ci_artifacts)
            if not returncode:
                summarize(f"{' '.join(batch)} passed on its rerun after failing on listed flakes.")
            elif args.quarantine == "admission" and (again := listed(output)):
                note = (f"{' '.join(batch)} failed again only on listed flakes ({issues(again)}). Not blocking PR "
                        "admission; promotion blocks on two consecutive failures.")
                print(f"::warning::{note}", flush=True)
                summarize(note)
                returncode = 0
        elif returncode and args.retry:
            note = (f"{' '.join(batch)} failed (exit {returncode}); {RETRIED}. "
                    "A pass after this retry is a flake to fix, not a clean pass.")
            print(f"::warning::{note}", flush=True)
            summarize(note)
            returncode, _ = execute(batch, args.ci_artifacts)
            if not returncode:
                summarize(f"{' '.join(batch)} passed on its automatic retry after failing.")
        if returncode:
            # A replay in another commit's tree builds from its source, not this run's artifacts.
            record_failure(' '.join(batch), command(batch))
            summarize(f"Executed {' '.join(batch)}: failed (exit {returncode}). "
                      "Inspect the failed step. Retained artifacts are diagnostics, not acceptance.")
            raise SystemExit(returncode)
    summarize(f"Executed {', '.join(targets)} (partition {args.check_part}): passed. Fresh execution.")


def listed(output):
    return quarantine.listed(output, quarantine.entries(), quarantine.today(), fixtures())


def issues(flakes):
    return ", ".join(f"#{flake['issue']} owned by {flake['owner']}" for flake in flakes)


def summarize(line):
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            print(line, file=summary)


def command(batch, ci_artifacts=None):
    artifacts = ["-Dci-artifacts=" + ci_artifacts] if ci_artifacts else []
    # Fixtures copy their own retained diagnostics; this only runs the gate.
    mode = ["-Dpr-ci=true"] if pr_ci() else []
    return ["zig", "build", *batch, *mode, *artifacts, "--summary", "all", "--test-timeout", TEST_TIMEOUT]


def execute(batch, ci_artifacts):
    """Run one batch, streaming its output; (exit code, output) for the quarantine to read."""
    print("Executing: " + " ".join(batch), flush=True)
    start = time.monotonic()
    output = []
    with subprocess.Popen(command(batch, ci_artifacts), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace") as process:
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            output.append(line)
    returncode = process.returncode
    print(f"Completed {' '.join(batch)}: {time.monotonic() - start:.3f}s; exit {returncode}", flush=True)
    return returncode, "".join(output)


if __name__ == "__main__":
    main()
