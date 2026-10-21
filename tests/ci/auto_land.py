#!/usr/bin/env python3
"""Fast-forward main to a green wip/land-N tip, then start main's post-push CI.

Runs from trusted main code when Selected checks or the upgrade check
completes on a landing tip. The tip is fetched as data and pushed, never run.
It lands only the branch's current tip, only as a non-force fast-forward, only
while no `landing-freeze` issue is open, and only on the latest Selected run
for that exact commit; a strict delta also needs its upgrade run and the Mac
aggregate. Anything else waits for the next completion or for the lander lane
to restack.
"""
import argparse
import json
import os
import re
import subprocess

from main_health import FREEZE, UPGRADE, changed, dispatch, gh, git, latest, repair, required
from strict_paths import strict

BRANCH = re.compile(r"wip/land-[0-9]+")
# GITHUB_TOKEN has no `workflows` permission, so GitHub rejects its push of
# any commit that changes a workflow file.
WORKFLOW_FILES = ".github/workflows/"


def decide(frozen, fast_forward, selected, upgrade, changed):
    """Return 'frozen', 'not-fast-forward', 'pending', 'red', 'manual' or 'land'.

    selected and upgrade are the latest runs on the tip, or None; selected
    carries its `macos` aggregate conclusion when the delta is strict.
    """
    if frozen:
        return "frozen"
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
    """Decide one tip and land it; True when main is now sha."""
    fast_forward = subprocess.run(["git", "merge-base", "--is-ancestor", main_sha, sha]).returncode == 0
    paths = changed(main_sha, sha) if fast_forward else []
    frozen = json.loads(gh("issue", "list", "--repo", os.environ["GITHUB_REPOSITORY"], "--state", "open",
                           "--label", FREEZE, "--json", "number"))
    selected = latest("check.yml", sha, branch)
    upgrade = latest(UPGRADE, sha, branch) if strict(paths) else None
    if selected and strict(paths):
        selected["macos"] = macos(selected)
    verdict = decide(bool(frozen), fast_forward, selected, upgrade, paths)
    links = "\n".join(f"- {name}: {run['conclusion'] or run['status']} {run['html_url']}"
                      for name, run in (("Selected", selected), ("upgrade", upgrade)) if run)
    print(f"{branch} {sha} onto main {main_sha}: {verdict}\n{links}")
    if verdict == "manual":
        print("GITHUB_TOKEN cannot push workflow-file changes; this tip needs a manual push.")
    if verdict != "land":
        return False
    repair(main_sha)
    # Non-force: a moved main rejects the push instead of being overwritten.
    pushed = subprocess.run(["git", "push", "origin", f"{sha}:refs/heads/main"], capture_output=True, text=True)
    if pushed.returncode:
        git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
        if git("rev-parse", "origin/main") != main_sha:
            print(f"not a fast-forward: main moved from {main_sha}; restack {branch}")
            return False
        raise SystemExit(f"Push of {sha} to main failed:\n{pushed.stderr}")
    print(f"Fast-forwarded main {main_sha} to {sha}")
    dispatch(sha, main_sha, required(main_sha, sha))
    return True


if __name__ == "__main__":
    main()
