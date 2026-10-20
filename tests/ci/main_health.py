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

from strict_paths import strict

# Post-push workflows whose results decide main's health.
WORKFLOWS = ("check.yml", "previous-release-upgrade.yml")
UPGRADE = "previous-release-upgrade.yml"
FREEZE = "landing-freeze"
# GITHUB_TOKEN pushes start no workflows, so its pushes dispatch main's CI.
EVENTS = ("push", "workflow_dispatch")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def post_push_runs():
    """Recent pushed or dispatched runs of each post-push workflow on main."""
    repository = os.environ["GITHUB_REPOSITORY"]
    return {workflow: [row for event in EVENTS for row in json.loads(gh(
        "api", f"repos/{repository}/actions/workflows/{workflow}/runs"
               f"?event={event}&branch=main&per_page=100"))["workflow_runs"]
        if row["head_branch"] == "main" and row["head_repository"]["full_name"] == repository]
        for workflow in WORKFLOWS}


def runs(rows, sha, commits):
    """Selected for this commit; the upgrade check's newest run since stable.

    A push that misses the upgrade path filter has no upgrade run of its own,
    so an earlier strict commit's run since stable still decides.
    """
    result = {}
    for workflow, candidates in (("check.yml", [sha]), (UPGRADE, commits)):
        for commit in candidates:
            matching = [row for row in rows[workflow] if row["head_sha"] == commit]
            if matching:
                # Reruns keep the run; its latest attempt is the result.
                result[workflow] = max(matching, key=lambda row: row["id"])
                break
    return result


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


def dispatch(sha, before):
    """Start main's post-push CI for a GITHUB_TOKEN push of before..sha.

    Selected diffs from before like a push; the upgrade check runs on strict
    paths only, like its push filter. A run that GitHub started on a newer
    main is reported; that commit's own run then also covers sha.
    """
    repository = os.environ["GITHUB_REPOSITORY"]
    changed = git("diff", "--no-renames", "--name-only", before, sha).splitlines()
    for workflow in WORKFLOWS:
        if workflow == UPGRADE and not strict(changed):
            continue
        base = ["-f", f"inputs[base]={before}"] if workflow == "check.yml" else []
        for attempt in range(3):
            try:
                run = json.loads(gh("api", "-X", "POST", f"repos/{repository}/actions/workflows/{workflow}/dispatches",
                                    "-f", "ref=main", "-F", "return_run_details=true", *base))
                break
            except subprocess.CalledProcessError as error:
                if attempt == 2:
                    raise SystemExit(f"main {sha} landed, but dispatching {workflow} failed; dispatch it on main "
                                     f"by hand or stable cannot advance:\n{error.stderr}") from error
                time.sleep(10)
        head = json.loads(gh("api", f"repos/{repository}/actions/runs/{run['workflow_run_id']}"))["head_sha"]
        print(f"Dispatched {workflow} on main {head}: {run['html_url']}")
        if head != sha:
            print(f"main moved past {sha} before dispatch; {head}'s post-push CI covers it")


def decide(results, changed):
    """Return 'pending', 'green', 'revert' or 'issue' for one main commit."""
    required = {"check.yml"} | ({UPGRADE} if strict(changed) else set())
    if required - results.keys() or any(run["status"] != "completed" for run in results.values()):
        return "pending"
    red = {name for name, run in results.items() if run["conclusion"] != "success"}
    if not red:
        return "green"
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
    rows = post_push_runs()
    tested = {row["head_sha"] for row in rows["check.yml"]}
    # GitHub drops a pending run when a newer one queues in this concurrency
    # group, so every run decides each main push since stable, oldest first,
    # and never relies on its own triggering event.
    for sha in git("rev-list", "--reverse", f"{stable}..{head}").split() if stable else [head]:
        if sha != head and sha not in tested:
            continue  # An inner commit of one push; the push's tip decides it.
        if (verdict := decide_push(rows, stable, sha)) == "pending":
            # stable never passes a push whose post-push CI is still running.
            return
        if verdict == "green":
            stable = sha


def decide_push(rows, stable, sha):
    # Everything since the last green commit is suspect, not only this push.
    base = stable or f"{sha}~1"
    changed = git("diff", "--no-renames", "--name-only", base, sha).splitlines()
    results = runs(rows, sha, git("rev-list", f"{base}..{sha}").split())
    verdict = decide(results, changed)
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
                dispatch(git("rev-parse", "HEAD"), before)
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
