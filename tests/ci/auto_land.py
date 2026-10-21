#!/usr/bin/env python3
"""Fast-forward main and stable to a green wip/land-N tip.

Runs from trusted main code when Selected checks or the upgrade check
completes on a landing tip. The tip is fetched as data and pushed, never run.
It lands only the branch's current tip, only as a non-force fast-forward, and
only on the latest Selected push run for that exact commit; a strict delta
against main also needs its upgrade run and the Mac aggregate. One atomic
push moves main and stable together, so stable is always the last landed
tip. Anything else waits for the next completion or for the lander lane to
restack.
"""
import argparse
import json
import os
import re
import subprocess

from select_tests import changed_paths
from strict_paths import strict

BRANCH = re.compile(r"wip/land-[0-9]+")
UPGRADE = "previous-release-upgrade.yml"
# GITHUB_TOKEN has no `workflows` permission, so GitHub rejects its push of
# any commit that changes a workflow file.
WORKFLOW_FILES = ".github/workflows/"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def latest(workflow, sha, branch):
    """The newest push run of workflow on this exact commit and branch; reruns keep the run."""
    repository = os.environ["GITHUB_REPOSITORY"]
    rows = json.loads(gh("api", f"repos/{repository}/actions/workflows/{workflow}/runs"
                                f"?head_sha={sha}&branch={branch}&event=push&per_page=100"))["workflow_runs"]
    rows = [row for row in rows if row["head_sha"] == sha and row["head_branch"] == branch
            and row["head_repository"]["full_name"] == repository]
    return max(rows, key=lambda row: row["id"], default=None)


def decide(fast_forward, selected, upgrade, changed):
    """Return 'not-fast-forward', 'pending', 'red', 'manual' or 'land'.

    selected and upgrade are the latest runs on the tip, or None; selected
    carries its `macos` aggregate conclusion when the delta is strict.
    """
    if not fast_forward:
        return "not-fast-forward"
    required = [selected, *([upgrade] if strict(changed) else [])]
    if any(run is None or run["status"] != "completed" for run in required):
        return "pending"
    if any(run["conclusion"] != "success" for run in required):
        return "red"
    if strict(changed) and selected.get("macos") != "success":
        # Selection always runs Mac for strict paths; never land without it.
        return "red"
    if any(path.startswith(WORKFLOW_FILES) for path in changed):
        return "manual"
    return "land"


def macos(run):
    """Conclusion of the Selected run's Mac aggregate in its latest attempt."""
    repository = os.environ["GITHUB_REPOSITORY"]
    jobs = json.loads(gh("api", f"repos/{repository}/actions/runs/{run['id']}/jobs"
                                "?filter=latest&per_page=100"))["jobs"]
    return next((job["conclusion"] for job in jobs if job["name"] == "macos"), None)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    # The triggering event only wakes the lander: GitHub drops a pending run
    # when a newer one queues, so every run decides each branch's current tip.
    git("fetch", "--quiet", "--prune", "origin", "+refs/heads/main:refs/remotes/origin/main",
        "+refs/heads/wip/land-*:refs/remotes/origin/wip/land-*")
    main_sha = git("rev-parse", "origin/main")
    tips = [line.split() for line in git("for-each-ref", "--format=%(refname:lstrip=3) %(objectname)",
                                         "refs/remotes/origin/wip/land-*").splitlines()]
    for branch, sha in sorted((tip for tip in tips if BRANCH.fullmatch(tip[0])),
                              key=lambda tip: int(tip[0].rsplit("-", 1)[1])):
        if subprocess.run(["git", "merge-base", "--is-ancestor", sha, main_sha]).returncode == 0:
            print(f"{branch} {sha} is already in main")
            continue
        if land(branch, sha, main_sha):
            main_sha = sha
        elif git("rev-parse", "origin/main") != main_sha:
            return


def land(branch, sha, main_sha):
    """Decide one tip and land it; True when main and stable are now sha."""
    fast_forward = subprocess.run(["git", "merge-base", "--is-ancestor", main_sha, sha]).returncode == 0
    # NUL-delimited, so Git never quotes a strict path out of recognition.
    paths = changed_paths(main_sha, sha)[0] if fast_forward else []
    selected = latest("check.yml", sha, branch)
    upgrade = latest(UPGRADE, sha, branch) if strict(paths) else None
    if selected and strict(paths):
        selected["macos"] = macos(selected)
    verdict = decide(fast_forward, selected, upgrade, paths)
    links = "\n".join(f"- {name}: {run['conclusion'] or run['status']} {run['html_url']}"
                      for name, run in (("Selected", selected), ("upgrade", upgrade)) if run)
    print(f"{branch} {sha} onto main {main_sha}: {verdict}\n{links}")
    if verdict == "manual":
        print("GITHUB_TOKEN cannot push workflow-file changes; this tip needs a manual push.")
    if verdict != "land":
        return False
    # The classification above is against main_sha. A main that moved, even to
    # an ancestor of sha, may make the actual delta strict, so re-decide on the
    # next run. Only this lander writes main, inside one concurrency group, so
    # main cannot move between this check and the push.
    if moved(main_sha, branch):
        return False
    # Atomic and non-force: a diverged main or a stable off main's line rejects
    # both refs, so stable never names a tip that main did not take.
    pushed = subprocess.run(["git", "push", "--atomic", "origin", f"{sha}:refs/heads/main",
                             f"{sha}:refs/heads/stable"], capture_output=True, text=True)
    if pushed.returncode:
        if moved(main_sha, branch):
            return False
        raise SystemExit(f"Push of {sha} to main and stable failed; neither moved:\n{pushed.stderr}")
    print(f"Fast-forwarded main and stable from {main_sha} to {sha}")
    return True


def moved(main_sha, branch):
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
    if git("rev-parse", "origin/main") == main_sha:
        return False
    print(f"main moved from {main_sha}; re-deciding {branch} on the next run")
    return True


if __name__ == "__main__":
    main()
