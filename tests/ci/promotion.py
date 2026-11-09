#!/usr/bin/env python3
"""Find the commit in a promotion batch that turned a failing check red.

A promotion qualifies main HEAD against the batch since `stable`, the last
promoted release. When a job fails, it replays its own failing command on the
same runner: first at HEAD, to confirm the red reproduces, then by binary
search over the batch's first-parent commits. `stable` is presumed good, since
it passed promotion; it is replayed only when the first commit of the batch
fails. Replay output goes to files, not the job log, so the issue filer reads
only the original failure. The verdict never turns a promotion green.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def fetch(base, head):
    """Make the batch's history local; CI checkouts are shallow."""
    if git("rev-parse", "--is-shallow-repository") == "true":
        git("fetch", "--quiet", "--unshallow", "--no-tags", "origin", head)
    for sha in (base, head):
        if subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode:
            git("fetch", "--quiet", "--no-tags", "origin", sha)


def batch(base, head):
    """The first-parent commits after `base` up to `head`, oldest first."""
    if subprocess.run(["git", "merge-base", "--is-ancestor", base, head]).returncode:
        raise SystemExit(f"{base} is not an ancestor of {head}; the batch has no linear history")
    listed = git("rev-list", "--first-parent", "--reverse", f"{base}..{head}")
    return listed.split() if listed else []


def bisect(commits, base, passes):
    """Locate the first failing commit, given `passes(sha)` for each replay.

    Returns a verdict dictionary: `not-reproduced` when HEAD passes again,
    `before-batch` when `stable` fails too, else `culprit` with its commit.
    """
    if not commits:
        return dict(verdict="empty-batch", replays=[])
    replays = []

    def run(sha):
        ok = passes(sha)
        replays.append(dict(sha=sha, passed=ok))
        return ok

    if run(commits[-1]):
        return dict(verdict="not-reproduced", replays=replays)
    good, bad = -1, len(commits) - 1
    while bad - good > 1:
        middle = (good + bad) // 2
        if run(commits[middle]):
            good = middle
        else:
            bad = middle
    if bad == 0 and not run(base):
        return dict(verdict="before-batch", replays=replays)
    return dict(verdict="culprit", culprit=commits[bad], replays=replays)


def describe(result, base, head):
    verdict = result["verdict"]
    if verdict == "culprit":
        subject = git("log", "-1", "--format=%s", result["culprit"])
        return f"first failing commit {result['culprit']} ({subject})"
    return {
        "empty-batch": f"no commits between {base} and {head}",
        "not-reproduced": f"did not fail again at {head}; treat it as a flake until it recurs",
        "before-batch": f"fails at {base} too, before this batch; look at the runner or a test that depends on time",
    }[verdict]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="last promoted commit (stable)")
    parser.add_argument("--head", required=True, help="promotion candidate (main HEAD)")
    parser.add_argument("--logs", required=True, type=Path, help="directory for each replay's output")
    parser.add_argument("command", nargs="+", help="the failing command, replayed in each commit's tree")
    args = parser.parse_args()
    fetch(args.base, args.head)
    commits = batch(args.base, args.head)
    args.logs.mkdir(parents=True, exist_ok=True)

    # Replays report only through their log files and the verdict.
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_STEP_SUMMARY"}

    def passes(sha):
        git("checkout", "--quiet", "--force", "--detach", sha)
        with open(args.logs / f"{sha}.log", "w") as log:
            code = subprocess.run(args.command, stdout=log, stderr=subprocess.STDOUT, env=env).returncode
        print(f"replay at {sha}: {'passed' if code == 0 else f'failed (exit {code})'}", flush=True)
        return code == 0

    try:
        result = bisect(commits, args.base, passes)
    finally:
        git("checkout", "--quiet", "--force", "--detach", args.head)
    result.update(base=args.base, head=args.head, batch=len(commits))
    (args.logs / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    line = f"Promotion bisect: {describe(result, args.base, args.head)}"
    # report_issue.py copies this line onto the issue it files for the job.
    print(line)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            print(f"\n{line}\n", file=output)


if __name__ == "__main__":
    sys.exit(main())
