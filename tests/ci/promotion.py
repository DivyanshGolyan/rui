#!/usr/bin/env python3
"""Find the commit in a promotion batch that turned a failing check red.

A promotion qualifies main HEAD against the batch since `stable`, the last
promoted release. When a job fails, each step it recorded as failed
(steps.py, run_selected.py) is bisected on its own, on the same runner: its
recorded command is replayed first at HEAD, to confirm the red reproduces,
then by binary search over the batch's first-parent commits. `stable` is
presumed good, since it passed promotion; it is replayed only when the first
commit of the batch fails. A one-commit batch is its culprit without replays,
and Linux replays stop at BISECT_CAP_SECONDS. A failure before any recorded step, such as setup,
has nothing to replay. A macOS runner does not replay at all (replays_here):
its replays cost the most runner-minutes. Replay output goes to files, not the
job log, so the issue filer reads only the original failure. The verdict never
turns a promotion green.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from git_command import git
import steps

# Linux replays stop starting after this much bisect time per job; the Promote 38-45 window's
# slowest find landed at 80 minutes (its last replay started at 66), so 90 leaves room for a slower runner.
BISECT_CAP_SECONDS = 90 * 60


def replays_here(environ=os.environ):
    """False on a macOS runner. Promote runs 38 to 45 spent 569 of their 1,575 bisect minutes
    there, mostly replays of full-callers and full-execution that ran for over an hour and
    often failed for the machine's own reasons. Outside GitHub Actions, RUNNER_OS is unset and
    the replay runs."""
    return environ.get("RUNNER_OS") != "macOS"


def fetch(base, head):
    if git("rev-parse", "--is-shallow-repository") == "true":
        git("fetch", "--quiet", "--unshallow", "--no-tags", "origin", head)
    for sha in (base, head):
        if subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode:
            git("fetch", "--quiet", "--no-tags", "origin", sha)


def batch(base, head):
    if subprocess.run(["git", "merge-base", "--is-ancestor", base, head]).returncode:
        raise SystemExit(f"{base} is not an ancestor of {head}; the batch has no linear history")
    listed = git("rev-list", "--first-parent", "--reverse", f"{base}..{head}")
    return listed.split() if listed else []


def bisect(commits, base, passes, deadline=None, clock=time.monotonic):
    """Return the batch's first failing commit, or the narrowed range when the deadline stops it.

    A batch of one commit is its own culprit, since `base` passed. No new replay starts once
    `clock()` reaches `deadline`; the caller shares one deadline across a job's failed steps.
    """
    if not commits:
        return dict(verdict="empty-batch", replays=[])
    if len(commits) == 1:
        return dict(verdict="single-commit", culprit=commits[0], replays=[])
    replays = []

    def run(sha):
        ok = passes(sha)
        replays.append(dict(sha=sha, passed=ok))
        return ok

    def capped(good, bad):
        return dict(verdict="capped", first=commits[good + 1], last=commits[bad], narrowed=bad - good,
                    replays=replays)

    def out_of_time():
        return deadline is not None and clock() >= deadline

    good, bad = -1, len(commits) - 1
    if out_of_time():
        return capped(good, bad)
    if run(commits[bad]):
        return dict(verdict="not-reproduced", replays=replays)
    while bad - good > 1:
        if out_of_time():
            return capped(good, bad)
        middle = (good + bad) // 2
        if run(commits[middle]):
            good = middle
        else:
            bad = middle
    if bad == 0:
        if out_of_time():
            return capped(good, bad)
        if not run(base):
            return dict(verdict="before-batch", replays=replays)
    return dict(verdict="culprit", culprit=commits[bad], replays=replays)


def describe(result, base, head):
    verdict = result["verdict"]
    if verdict == "single-commit":
        return f"the batch holds one commit, {result['culprit']}; it is the culprit"
    if verdict == "culprit":
        subject = git("log", "-1", "--format=%s", result["culprit"])
        return f"first fails at {result['culprit']} ({subject})"
    if verdict == "capped":
        return (f"stopped at the {BISECT_CAP_SECONDS // 60}-minute cap after {len(result['replays'])} replays; "
                f"the first failing commit is one of the {result['narrowed']} commits from {result['first']} "
                f"to {result['last']}")
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
    parser.add_argument("--failed", type=Path, default=steps.record_path(), help="the job's failure record")
    args = parser.parse_args()
    failed = steps.failures(args.failed) if args.failed else []
    if not failed:
        print("Promotion bisect: no recorded step failed, so there is nothing to replay; read the job's failed step")
        return
    if not replays_here():
        # The issue filer attaches "Promotion bisect:" lines to the failure, so this one keeps that prefix.
        print("Promotion bisect: skipped on macOS; read the failed step's log")
        return
    fetch(args.base, args.head)
    commits = batch(args.base, args.head)
    args.logs.mkdir(parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_STEP_SUMMARY"}
    results, lines = [], []
    deadline = time.monotonic() + BISECT_CAP_SECONDS
    for index, step in enumerate(failed):
        def passes(sha, step=step, index=index):
            git("checkout", "--quiet", "--force", "--detach", sha)
            name = f"{index}-{sha}"
            replay_env = dict(env, STEP_OUTPUT=str(args.logs / f"{name}-output"))
            with open(args.logs / f"{name}.log", "w") as log:
                code = subprocess.run(step["argv"], stdout=log, stderr=subprocess.STDOUT, env=replay_env).returncode
            print(f"{step['name']}: replay at {sha}: {'passed' if code == 0 else f'failed (exit {code})'}", flush=True)
            return code == 0

        try:
            result = bisect(commits, args.base, passes, deadline=deadline)
        finally:
            git("checkout", "--quiet", "--force", "--detach", args.head)
        result.update(step=step["name"], argv=step["argv"])
        results.append(result)
        lines.append(f"Promotion bisect: {step['name']}: {describe(result, args.base, args.head)}")
    verdict = dict(base=args.base, head=args.head, batch=len(commits), steps=results)
    (args.logs / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
    print("\n".join(lines))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            print("\n" + "\n".join(lines) + "\n", file=output)


if __name__ == "__main__":
    sys.exit(main())
