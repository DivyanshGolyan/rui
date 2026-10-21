#!/usr/bin/env python3
"""Act on main's post-push CI: advance stable, or revert and freeze, or file an issue.

stable advances only to a main commit whose post-push workflows all passed.
A red result in Store, recovery or upgrade (the strict paths, or the upgrade
workflow itself) is reverted with an ordinary non-force commit and freezes
landing through an open `landing-freeze` issue. Any other red files an issue.
"""
import argparse
import json
import os
import subprocess
import time

from select_tests import changed_paths
from strict_paths import strict

UPGRADE = "previous-release-upgrade.yml"
FREEZE = "landing-freeze"
# GITHUB_TOKEN pushes start no workflows, so its pushes dispatch main's CI.
EVENTS = ("push", "workflow_dispatch")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def changed(base, sha):
    # NUL-delimited, so Git never quotes a strict path out of recognition.
    return changed_paths(base, sha)[0]


def latest(workflow, sha, branch):
    """The newest run of workflow on this exact commit and branch; reruns keep the run."""
    repository = os.environ["GITHUB_REPOSITORY"]
    rows = [row for event in EVENTS for row in json.loads(gh(
        "api", f"repos/{repository}/actions/workflows/{workflow}/runs"
               f"?head_sha={sha}&branch={branch}&event={event}&per_page=100"))["workflow_runs"]]
    rows = [row for row in rows if row["head_sha"] == sha and row["head_branch"] == branch
            and row["head_repository"]["full_name"] == repository]
    return max(rows, key=lambda row: row["id"], default=None)


def pushes(stable, head):
    """{after: before} for each push that moved main from stable to head, oldest first.

    Push boundaries come from GitHub's ref activity, never from which commits
    happen to have runs: a push whose post-push CI is missing must hold stable,
    not pass as an inner commit of a later push. Unless the activity chains
    head back to stable push by push, this fails and stable holds. Without
    stable, only head's own push is known.
    """
    repository = os.environ["GITHUB_REPOSITORY"]
    activity = [row for page in json.loads(gh("api", "--paginate", "--slurp",
                                              f"repos/{repository}/activity?ref=refs/heads/main&per_page=100"))
                for row in page]
    moves = {row["after"]: row["before"] for row in reversed(activity)}
    chain, sha = {}, head
    while sha != stable:
        if sha not in moves or sha in chain:
            raise SystemExit(f"GitHub's push activity for main does not chain {head} back to "
                             f"{stable or 'its previous main'}; stable holds until it does.")
        chain[sha] = moves[sha]
        sha = moves[sha]
        if stable is None:
            break
    return dict(reversed(chain.items()))


def required(before, sha):
    """Post-push workflows one push needs, as its push triggers would start them."""
    return ["check.yml", *([UPGRADE] if strict(changed(before, sha)) else [])]


def runs(sha, earlier):
    """Selected for this exact push; the upgrade run of the newest strict push.

    earlier lists (push, before) since stable, newest first, starting with sha.
    A push that misses the upgrade path filter has no upgrade run of its own,
    so the newest strict push's run (or a later push's) decides; an older
    strict push's run does not cover a newer strict change.
    """
    result = {"check.yml": latest("check.yml", sha, "main")}
    for push, before in earlier:
        result[UPGRADE] = latest(UPGRADE, push, "main")
        if result[UPGRADE] or UPGRADE in required(before, push):
            break
    return {workflow: run for workflow, run in result.items() if run}


def open_issue(title):
    repository = os.environ["GITHUB_REPOSITORY"]
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "open",
                           "--search", f'in:title "{title}"', "--json", "number,title"))
    return next((issue["number"] for issue in issues if issue["title"] == title), None)


def filed(title):
    """Whether an issue with this exact title was ever filed, open or closed."""
    repository = os.environ["GITHUB_REPOSITORY"]
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "all",
                           "--search", f'in:title "{title}"', "--json", "title"))
    return any(issue["title"] == title for issue in issues)


def report(title, body, label=None):
    """Comment on the open issue with this exact title, or open one."""
    repository = os.environ["GITHUB_REPOSITORY"]
    existing = open_issue(title)
    if existing:
        gh("issue", "comment", str(existing), "--repo", repository, "--body", body)
        return existing
    if label:
        # Creating an existing label fails; the label only has to exist.
        subprocess.run(["gh", "label", "create", label, "--repo", repository, "--color", "B60205"],
                       capture_output=True)
    return gh("issue", "create", "--repo", repository, "--title", title, "--body", body,
              *(["--label", label] if label else [])).strip()


def dispatch(sha, before, workflows):
    """Start main's post-push workflows for a GITHUB_TOKEN push of before..sha.

    Selected diffs from before like a push. A dispatch runs on main's head, so
    if main moved first the run is kept but sha has no exact post-push run,
    and this fails instead of claiming one.
    """
    repository = os.environ["GITHUB_REPOSITORY"]
    moved = []
    for workflow in workflows:
        base = ["-f", f"inputs[base]={before}"] if workflow == "check.yml" else []
        for attempt in range(3):
            try:
                run = json.loads(gh("api", "-X", "POST", f"repos/{repository}/actions/workflows/{workflow}/dispatches",
                                    "-f", "ref=main", "-F", "return_run_details=true", *base))
                break
            except subprocess.CalledProcessError as error:
                if attempt == 2:
                    raise SystemExit(f"main {sha} landed, but dispatching {workflow} failed; the next auto-land "
                                     f"run dispatches it while main is still {sha}:\n{error.stderr}") from error
                time.sleep(10)
        head = json.loads(gh("api", f"repos/{repository}/actions/runs/{run['workflow_run_id']}"))["head_sha"]
        print(f"Dispatched {workflow} on main {head}: {run['html_url']}")
        if head != sha:
            moved.append(f"{workflow} ran on {head}: {run['html_url']}")
    if moved:
        raise SystemExit(f"main {sha} landed, but main moved before its post-push CI was dispatched, so {sha} "
                         f"has no exact post-push run:\n" + "\n".join(moved) + "\nThose runs stay; they are not "
                         f"{sha}'s. stable holds before {sha}; main health files an issue for a user decision.")


def decide(results, changed, own=()):
    """Return 'pending', 'green', 'revert' or 'issue' for one main push.

    changed spans everything since stable; own lists the workflows this push
    itself needs, so a push that undoes a strict change (a revert) still
    waits for its own upgrade run although the span since stable is clean.
    """
    needed = {"check.yml", *own} | ({UPGRADE} if strict(changed) else set())
    if needed - results.keys() or any(run["status"] != "completed" for run in results.values()):
        return "pending"
    red = {name for name, run in results.items() if run["conclusion"] != "success"}
    if not red:
        return "green"
    # Revert scope stays the span since stable; a clean span has nothing to revert.
    return "revert" if strict(changed) or UPGRADE in red else "issue"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    issue = commands.add_parser("report")
    issue.add_argument("--title", required=True)
    issue.add_argument("--body", required=True)
    args = parser.parse_args()
    if args.command == "report":
        print(report(args.title, args.body))
        return
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
    # stable is absent until main's first green post-push run.
    subprocess.run(["git", "fetch", "--quiet", "origin", "+refs/heads/stable:refs/remotes/origin/stable"],
                   capture_output=True)
    stable = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "origin/stable"],
                            capture_output=True, text=True).stdout.strip() or None
    head = git("rev-parse", "origin/main")
    boundaries = pushes(stable, head)
    # GitHub drops a pending run when a newer one queues in this concurrency
    # group, so every run decides each main push since stable, oldest first,
    # and never relies on its own triggering event.
    order = list(boundaries)
    start = 0
    for index, sha in enumerate(order):
        earlier = [(push, boundaries[push]) for push in reversed(order[start:index + 1])]
        if (verdict := decide_push(stable, sha, earlier)) == "pending":
            # stable never passes a push without its own finished post-push CI.
            if index + 1 < len(order) and any(latest(workflow, sha, "main") is None
                                              for workflow in required(boundaries[sha], sha)):
                stranded(sha, order[index + 1:])
            return
        if verdict == "green":
            stable, start = sha, index + 1


def stranded(sha, later):
    """Report a push whose exact post-push CI can no longer start.

    A dispatch runs on main's head, so once a later push exists nothing can
    start sha's own runs; stable stays held for a user decision.
    """
    title = f"Main push {sha[:12]} has no post-push CI"
    if not filed(title):
        report(title, f"main {sha} was followed by {', '.join(push[:12] for push in later)} before its own "
                      "post-push CI started, so no exact run can exist and stable stays before it. "
                      "Decide by hand whether to revert it; agents never move stable.")


def decide_push(stable, sha, earlier):
    # Everything since the last green commit is suspect, not only this push.
    base = stable or earlier[-1][1]
    results = runs(sha, earlier)
    verdict = decide(results, changed(base, sha), required(earlier[0][1], sha))
    links = "\n".join(f"- {name}: {run['conclusion'] or run['status']} {run['html_url']}"
                      for name, run in sorted(results.items()))
    print(f"{sha}: {verdict}\n{links}")
    if verdict == "green":
        # Non-force: the push fails rather than move stable backwards.
        git("push", "origin", f"{sha}:refs/heads/stable")
    elif verdict == "issue":
        title = f"Main red after push {sha[:12]}"
        if not filed(title):
            report(title, f"Post-push CI failed on main {sha}. Fix forward.\n\n{links}")
    elif verdict == "revert" and not filed(f"Landing frozen: main red after push {sha[:12]}"):
        # One automatic revert per red push, even after its freeze issue closes.
        commits = git("rev-list", "--reverse", f"{base}..{sha}").split()
        try:
            # Revert on top of current main, which may have moved since checkout.
            git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
            git("checkout", "--quiet", "--detach", "origin/main")
            before = git("rev-parse", "HEAD")
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "revert", "--no-edit", *reversed(commits))
            git("push", "origin", "HEAD:refs/heads/main")
            outcome = f"Reverted {base[:12]}..{sha[:12]} with a non-force commit {git('rev-parse', 'HEAD')}."
            try:
                # The revert push, like the auto-lander's, starts no workflows itself.
                reverted = git("rev-parse", "HEAD")
                dispatch(reverted, before, required(before, reverted))
            except (SystemExit, subprocess.CalledProcessError) as error:
                outcome += f"\n\nDispatching main's post-push CI failed; dispatch it by hand.\n\n{error}"
        except subprocess.CalledProcessError as error:
            outcome = f"Automatic revert of {base[:12]}..{sha[:12]} failed; revert it by hand.\n\n{error.stderr}"
        report(f"Landing frozen: main red after push {sha[:12]}",
               f"Post-push Store/recovery/upgrade CI failed on main {sha}. {outcome}\n\n"
               f"Landing stays frozen until this issue is closed.\n\n{links}", FREEZE)
    return verdict


if __name__ == "__main__":
    main()
