#!/usr/bin/env python3
"""Run a job's named steps and record each one that fails, for a promotion to replay.

Each argument is NAME=COMMAND. Every step runs, in order, under `bash -euc`,
even after an earlier one fails, and the job fails when any step did. A step
that writes results gets a fresh, not yet created `$STEP_OUTPUT`: NAME under
--output-root, which this creates. Under GitHub Actions each failed step's name and command are
appended to the job's failure record, unexpanded, so promotion.py replays the
same command in another commit's tree with that tree's environment. The
command list in the workflow is the only copy of each command.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def record_path():
    """The job's failure record, or None outside GitHub Actions."""
    temp = os.environ.get("RUNNER_TEMP")
    return Path(temp) / "rui-failed-steps.jsonl" if temp else None


def record_failure(name, argv):
    """Append a failed step: what promotion.py replays to bisect it."""
    if path := record_path():
        with open(path, "a") as record:
            print(json.dumps(dict(name=name, argv=argv)), file=record)


def failures(path):
    """Recorded failed steps in run order; none when nothing was recorded."""
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def parse(step):
    name, separator, command = step.partition("=")
    if not (separator and name and command.strip()) or "/" in name:
        raise argparse.ArgumentTypeError(f"expected NAME=COMMAND, got {step!r}")
    return name, command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, help="parent of each step's $STEP_OUTPUT")
    parser.add_argument("steps", nargs="+", type=parse, metavar="NAME=COMMAND")
    args = parser.parse_args()
    if len({name for name, _ in args.steps}) != len(args.steps):
        parser.error("step names must be unique")
    if args.output_root:
        args.output_root.mkdir(parents=True, exist_ok=True)
    failed = []
    for name, command in args.steps:
        argv = ["bash", "-euc", command]
        env = dict(os.environ)
        if args.output_root:
            env["STEP_OUTPUT"] = str(args.output_root / name)
        print(f"::group::{name}: {command}", flush=True)
        code = subprocess.run(argv, env=env).returncode
        print("::endgroup::", flush=True)
        if code:
            print(f"::error::{name} failed (exit {code})", flush=True)
            failed.append(name)
            record_failure(name, argv)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            for name, _ in args.steps:
                print(f"- {name}: {'failed' if name in failed else 'passed'}", file=output)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
