#!/usr/bin/env python3
"""Fast-forward main and stable to a green wip/land-N tip.

Runs from trusted main code when Selected checks or the upgrade check
completes on a landing tip. The tip is fetched as data and pushed, never run.
It lands only the branch's current tip, only as a non-force fast-forward, and
only on the latest Selected push or dispatched run for that exact commit; a
dispatched Selected run counts only when main contains its base. A strict
delta against main also needs its upgrade run and the Mac aggregate. One atomic
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
# check.yml's run-name for a dispatch; the base it selected from.
DISPATCH_BASE = re.compile(r"Selected checks from base ([0-9a-f]{40})")
# GITHUB_TOKEN has no `workflows` permission, so GitHub rejects its push of
# any commit that changes a workflow file.
WORKFLOW_FILES = ".github/workflows/"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def latest(workflow, sha, branch):
    """The newest push or dispatched run of workflow on this exact commit and branch.

    A dispatch can replace a cancelled push run; reruns keep the run.
    """
    repository = os.environ["GITHUB_REPOSITORY"]
    rows = [row for event in ("push", "workflow_dispatch") for row in json.loads(gh(
        "api", f"repos/{repository}/actions/workflows/{workflow}/runs"
               f"?head_sha={sha}&branch={branch}&event={event}&per_page=100"))["workflow_runs"]]
    rows = [row for row in rows if row["head_sha"] == sha and row["head_branch"] == branch
            and row["head_repository"]["full_name"] == repository]
    return max(rows, key=lambda row: row["id"], default=None)


def decide(fast_forward, selected, upgrade, changed):
    """Return 'not-fast-forward', 'unqualified', 'pending', 'red', 'manual' or 'land'.

    selected and upgrade are the latest runs on the tip, or None; selected
    carries `covers`, whether its selection base spans main to the tip, and
    its `macos` aggregate conclusion when the delta is strict.
    """
    if not fast_forward:
        return "not-fast-forward"
    if selected is not None and not selected["covers"]:
        # A dispatch from a base main does not contain may have skipped owners.
        return "unqualified"
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


def number(branch):
    return int(branch.rsplit("-", 1)[1])


def contains(sha, ancestor):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, sha],
                          stderr=subprocess.DEVNULL).returncode == 0


def tips():
    """Fetch main and every wip/land-N; return [(branch, sha)], lowest N first."""
    git("fetch", "--quiet", "--prune", "origin", "+refs/heads/main:refs/remotes/origin/main",
        "+refs/heads/wip/land-*:refs/remotes/origin/wip/land-*")
    refs = [line.split() for line in git("for-each-ref", "--format=%(refname:lstrip=3) %(objectname)",
                                         "refs/remotes/origin/wip/land-*").splitlines()]
    return sorted((ref for ref in refs if BRANCH.fullmatch(ref[0])), key=lambda ref: number(ref[0]))


def preflight(branch, sha):
    """Fail a landing-tip push before it qualifies a second open stack.

    At most one wip/land-N is open: refs main already contains are landed and
    never count; any other ref is a second open stack, even one this push
    contains. Add work to the open stack by pushing its own branch, or retire
    it (back it up, then delete it) before starting the next number.
    """
    if not BRANCH.fullmatch(branch):
        raise SystemExit(f"{branch} is not a wip/land-N landing branch")
    refs = tips()
    main_sha = git("rev-parse", "origin/main")
    newer = [other for other, _ in refs if number(other) > number(branch)]
    if newer:
        raise SystemExit(f"{branch} is below {newer[-1]}; land numbers only increase")
    others = [f"{other} {tip}" for other, tip in refs if other != branch and not contains(main_sha, tip)]
    if others:
        raise SystemExit(f"{', '.join(others)} is still open; push to it, wait until it lands, or retire it")
    print(f"{branch} {sha} is the only open landing stack")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", metavar="BRANCH",
                        help="fail unless BRANCH at HEAD is the only open landing stack")
    args = parser.parse_args()
    if args.preflight:
        return preflight(args.preflight, git("rev-parse", "HEAD"))
    # The triggering event only wakes the lander: GitHub drops a pending run
    # when a newer one queues, so every run decides the current open stack.
    refs = tips()
    if not refs:
        return
    # Only the highest-numbered tip is open; lower ones landed or were superseded.
    branch, sha = refs[-1]
    main_sha = git("rev-parse", "origin/main")
    if contains(main_sha, sha):
        print(f"{branch} {sha} is already in main")
        return
    land(branch, sha, main_sha)


def land(branch, sha, main_sha):
    """Decide one tip and land it; True when main and stable are now sha."""
    fast_forward = contains(sha, main_sha)
    # NUL-delimited, so Git never quotes a strict path out of recognition.
    paths = changed_paths(main_sha, sha)[0] if fast_forward else []
    selected = latest("check.yml", sha, branch)
    if selected:
        selected["covers"] = covers(selected, sha, main_sha, paths)
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


def covers(selected, sha, main_sha, paths):
    """Whether the Selected run's selection spans every path main..sha changes.

    A push run selects from the main merge base, which the one open stack keeps
    equal to main. A dispatch selects from its recorded base, which main must
    contain and whose delta to sha must include every path main..sha changes.
    """
    if selected["event"] == "push":
        return True
    base = DISPATCH_BASE.fullmatch(selected.get("display_title") or "")
    if not base or not contains(main_sha, base[1]):
        return False
    return set(paths) <= set(changed_paths(base[1], sha)[0])


def moved(main_sha, branch):
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
    if git("rev-parse", "origin/main") == main_sha:
        return False
    print(f"main moved from {main_sha}; re-deciding {branch} on the next run")
    return True


if __name__ == "__main__":
    main()
