#!/usr/bin/env python3
"""Land Linux-green tips on main; promote exact Mac-and-upgrade-green main SHAs to stable.

Runs from trusted main code. Main and stable writes share one serialized
workflow and are non-force. Landing dispatches the existing qualification
workflows explicitly because GITHUB_TOKEN pushes do not emit push workflows.
Missing or failed Mac qualification holds stable, never main.
"""
import argparse
import json
import os
import re
import subprocess

from select_tests import changed_paths

BRANCH = re.compile(r"wip/land-[0-9]+")
UPGRADE = "previous-release-upgrade.yml"
# check.yml's run-name for a dispatch; the base it selected from.
DISPATCH_BASE = re.compile(r"Selected checks from base ([0-9a-f]{40})")
STABLE_BASE = re.compile(r"Stable qualification from base ([0-9a-f]{40})")
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
    Main's Selected acceptance is stable qualification, not diagnostic dispatches.
    """
    repository = os.environ["GITHUB_REPOSITORY"]
    # Filtered workflow listings can temporarily omit existing runs. Read
    # every unfiltered page; API/pagination failures must propagate, not dispatch.
    pages = json.loads(gh("api", f"repos/{repository}/actions/workflows/{workflow}/runs?per_page=100",
                         "--paginate", "--slurp"))
    if not isinstance(pages, list) or not pages:
        raise ValueError("workflow history must contain API pages")
    rows = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("workflow_runs"), list):
            raise ValueError("workflow history page must contain workflow_runs")
        for row in page["workflow_runs"]:
            if (not isinstance(row, dict) or type(row.get("id")) is not int or row["id"] <= 0
                    or any(not isinstance(row.get(key), str)
                           for key in ("head_sha", "head_branch", "event", "display_title"))
                    or not isinstance(row.get("head_repository"), dict)
                    or not isinstance(row["head_repository"].get("full_name"), str)):
                raise ValueError("workflow history run has invalid identity")
            rows.append(row)
    rows = [row for row in rows if row["event"] in ("push", "workflow_dispatch")
            and row["head_sha"] == sha and row["head_branch"] == branch
            and row["head_repository"]["full_name"] == repository]
    if workflow == "check.yml" and branch == "main":
        rows = [row for row in rows if STABLE_BASE.fullmatch(row.get("display_title") or "")]
    return max(rows, key=lambda row: row["id"], default=None)


def decide(fast_forward, selected, changed):
    """Return 'not-fast-forward', 'unqualified', 'pending', 'red', 'manual' or 'land'.

    selected carries coverage and the Linux aggregate. Overall run status and
    Mac results cannot delay or reject a successful Linux aggregate.
    """
    if not fast_forward:
        return "not-fast-forward"
    if selected is not None and not selected["covers"]:
        # A dispatch from a base main does not contain may have skipped owners.
        return "unqualified"
    if selected is None or selected.get("linux") is None:
        return "pending"
    if selected["linux"] != "success":
        return "red"
    if any(path.startswith(WORKFLOW_FILES) for path in changed):
        return "manual"
    return "land"


def aggregate(run, name):
    """Conclusion of a Selected aggregate in its latest attempt."""
    repository = os.environ["GITHUB_REPOSITORY"]
    jobs = json.loads(gh("api", f"repos/{repository}/actions/runs/{run['id']}/jobs"
                                "?filter=latest&per_page=100"))["jobs"]
    return next((job["conclusion"] for job in jobs if job["name"] == name), None)


def stable_ready(selected, upgrade):
    """Both complete workflows and a real Mac aggregate must pass on this SHA."""
    return bool(selected and upgrade
                and STABLE_BASE.fullmatch(selected.get("display_title") or "")
                and selected.get("covers", False)
                and selected.get("macos") == "success"
                and all(run["status"] == "completed" and run["conclusion"] == "success"
                        for run in (selected, upgrade)))


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
    parser.add_argument("--qualify-main", action="store_true",
                        help="dispatch only absent current-main Mac and upgrade qualification")
    parser.add_argument("--promote-stable", action="store_true",
                        help="promote the newest exact-SHA qualified main commit")
    parser.add_argument("--check-qualification-run", type=int, metavar="RUN_ID",
                        help="validate a main qualification parent before the bounded CLI wait")
    args = parser.parse_args()
    if args.check_qualification_run is not None:
        return check_qualification_run(args.check_qualification_run)
    if args.preflight:
        return preflight(args.preflight, git("rev-parse", "HEAD"))
    if args.qualify_main:
        return qualify_main()
    if args.promote_stable:
        return promote_stable()
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


def check_qualification_run(run_id):
    """A parent ID permits only a wait; it supplies no landing or promotion evidence."""
    if run_id <= 0:
        raise SystemExit("qualification run ID must be positive")
    repository = os.environ["GITHUB_REPOSITORY"]
    run = json.loads(gh("api", f"repos/{repository}/actions/runs/{run_id}"))
    path = run["path"]
    if (run["head_repository"]["full_name"] != repository
            or run["head_branch"] != "main" or run["event"] != "workflow_dispatch"
            or path not in (".github/workflows/check.yml", f".github/workflows/{UPGRADE}")
            or (path == ".github/workflows/check.yml"
                and not STABLE_BASE.fullmatch(run.get("display_title") or ""))):
        raise SystemExit("parent must be this repository's dispatched main qualification")


def land(branch, sha, main_sha):
    """Decide one tip and fast-forward main; the always-run phase qualifies it."""
    fast_forward = contains(sha, main_sha)
    # NUL-delimited, so Git never quotes a strict path out of recognition.
    paths = changed_paths(main_sha, sha)[0] if fast_forward else []
    selected = latest("check.yml", sha, branch)
    if selected:
        selected["covers"] = covers(selected, sha, main_sha, paths)
        selected["linux"] = aggregate(selected, "linux")
    verdict = decide(fast_forward, selected, paths)
    links = "\n".join(f"- {name}: {run['conclusion'] or run['status']} {run['html_url']}"
                      for name, run in (("Selected", selected),) if run)
    print(f"{branch} {sha} onto main {main_sha}: {verdict}\n{links}")
    if verdict == "manual":
        print("GITHUB_TOKEN cannot push workflow-file changes; this tip needs a manual push.")
    if verdict != "land":
        return False
    # Re-decide coverage if main moved. The workflow serializes both ref writers.
    if moved(main_sha, branch):
        return False
    pushed = subprocess.run(["git", "push", "origin", f"{sha}:refs/heads/main"],
                            capture_output=True, text=True)
    if pushed.returncode:
        if moved(main_sha, branch):
            return False
        raise SystemExit(f"Push of {sha} to main failed:\n{pushed.stderr}")
    print(f"Fast-forwarded main from {main_sha} to {sha}; stable unchanged")
    return True


def qualify_main():
    """Fill absent runs only; existing pending, offline or red runs are not retried.

    The workflow's always-run promotion phase calls this under the shared writer
    lock, including after a main push whose earlier dispatch was interrupted.
    """
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main",
        "+refs/heads/stable:refs/remotes/origin/stable")
    sha = git("rev-parse", "origin/main")
    base = git("rev-parse", "origin/stable")
    if sha != base and contains(sha, base):
        if latest("check.yml", sha, "main") is None:
            gh("workflow", "run", "check.yml", "--ref", "main", "-f", f"base={base}", "-f", "stable=true")
            print(f"Dispatched missing Mac qualification on main {sha} from stable {base}")
        if latest(UPGRADE, sha, "main") is None:
            gh("workflow", "run", UPGRADE, "--ref", "main")
            print(f"Dispatched missing upgrade qualification on main {sha}")
    return sha, base


def promote_stable():
    """Repair missing main runs, then promote the newest qualified main ancestor."""
    main_sha, stable_sha = qualify_main()
    if not contains(main_sha, stable_sha):
        print("stable is not on main's history; stable promotion held")
        return
    for sha in git("rev-list", "--first-parent", f"{stable_sha}..{main_sha}").splitlines():
        selected = latest("check.yml", sha, "main")
        if not selected:
            continue
        selected["covers"] = covers(selected, sha, stable_sha,
                                    changed_paths(stable_sha, sha)[0], STABLE_BASE)
        selected["macos"] = aggregate(selected, "macos")
        upgrade = latest(UPGRADE, sha, "main")
        if not stable_ready(selected, upgrade):
            continue
        # Non-force rejects divergence or a concurrent promotion past this SHA.
        git("push", "origin", f"{sha}:refs/heads/stable")
        print(f"Promoted stable from {stable_sha} to {sha}\n"
              f"Mac: {selected['html_url']}\nUpgrade: {upgrade['html_url']}")
        return
    print(f"No newer exact-SHA Mac-and-upgrade-green main commit; stable remains {stable_sha}")


def covers(selected, sha, destination_sha, paths, title=DISPATCH_BASE):
    """Whether selection spans every changed path from the destination to sha.

    A push run selects from the main merge base, which the one open stack keeps
    equal to main. A dispatch selects from its recorded base, which the current
    destination (main or stable) must contain; base..sha must include every
    path destination..sha changes, including reversions after the base.
    """
    if selected["event"] == "push":
        return title is DISPATCH_BASE
    base = title.fullmatch(selected.get("display_title") or "")
    if not base or not contains(destination_sha, base[1]):
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
