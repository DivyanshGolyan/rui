#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from git_command import git
import steps


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


def bisect(commits, base, passes):
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
        return f"first fails at {result['culprit']} ({subject})"
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
    fetch(args.base, args.head)
    commits = batch(args.base, args.head)
    args.logs.mkdir(parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_STEP_SUMMARY"}
    results, lines = [], []
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
            result = bisect(commits, args.base, passes)
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
