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

from strict_paths import strict

# Post-push workflows whose results decide main's health.
WORKFLOWS = ("check.yml", "previous-release-upgrade.yml")
UPGRADE = "previous-release-upgrade.yml"
FREEZE = "landing-freeze"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def runs(sha):
    repository = os.environ["GITHUB_REPOSITORY"]
    result = {}
    for workflow in WORKFLOWS:
        rows = json.loads(gh("api", f"repos/{repository}/actions/workflows/{workflow}/runs"
                                    f"?head_sha={sha}&event=push&branch=main&per_page=20"))["workflow_runs"]
        if rows:
            # Reruns keep the run; its latest attempt is the result.
            result[workflow] = max(rows, key=lambda row: row["id"])
    return result


def open_issue(title):
    repository = os.environ["GITHUB_REPOSITORY"]
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "open",
                           "--search", f'in:title "{title}"', "--json", "number,title"))
    return next((issue["number"] for issue in issues if issue["title"] == title), None)


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


def decide(results, changed):
    """Return 'pending', 'green', 'revert' or 'issue' for one main commit."""
    if "check.yml" not in results or any(run["status"] != "completed" for run in results.values()):
        return "pending"
    red = {name for name, run in results.items() if run["conclusion"] != "success"}
    if not red:
        return "green"
    return "revert" if strict(changed) or UPGRADE in red else "issue"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check").add_argument("sha")
    issue = commands.add_parser("report")
    issue.add_argument("--title", required=True)
    issue.add_argument("--body", required=True)
    args = parser.parse_args()
    if args.command == "report":
        print(report(args.title, args.body))
        return
    sha = args.sha
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main")
    # stable is absent until main's first green post-push run.
    subprocess.run(["git", "fetch", "--quiet", "origin", "+refs/heads/stable:refs/remotes/origin/stable"],
                   capture_output=True)
    stable = subprocess.run(["git", "rev-parse", "--verify", "--quiet", "origin/stable"],
                            capture_output=True, text=True).stdout.strip() or None
    if stable and subprocess.run(["git", "merge-base", "--is-ancestor", sha, stable]).returncode == 0:
        print(f"{sha} is already covered by stable {stable}")
        return
    # Everything since the last green commit is suspect, not only this push.
    base = stable or f"{sha}~1"
    changed = git("diff", "--no-renames", "--name-only", base, sha).splitlines()
    results = runs(sha)
    verdict = decide(results, changed)
    links = "\n".join(f"- {name}: {run['conclusion'] or run['status']} {run['html_url']}"
                      for name, run in sorted(results.items()))
    print(f"{sha}: {verdict}\n{links}")
    if verdict == "green":
        # Non-force: the push fails rather than move stable backwards.
        git("push", "origin", f"{sha}:refs/heads/stable")
    elif verdict == "issue":
        title = f"Main red after push {sha[:12]}"
        if not open_issue(title):
            report(title, f"Post-push CI failed on main {sha}. Fix forward.\n\n{links}")
    elif verdict == "revert" and not open_issue(f"Landing frozen: main red after push {sha[:12]}"):
        commits = git("rev-list", "--reverse", f"{base}..{sha}").split()
        try:
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "revert", "--no-edit", *reversed(commits))
            git("push", "origin", "HEAD:refs/heads/main")
            outcome = f"Reverted {base[:12]}..{sha[:12]} with a non-force commit {git('rev-parse', 'HEAD')}."
        except subprocess.CalledProcessError as error:
            outcome = f"Automatic revert of {base[:12]}..{sha[:12]} failed; revert it by hand.\n\n{error.stderr}"
        report(f"Landing frozen: main red after push {sha[:12]}",
               f"Post-push Store/recovery/upgrade CI failed on main {sha}. {outcome}\n\n"
               f"Landing stays frozen until this issue is closed.\n\n{links}", FREEZE)


if __name__ == "__main__":
    main()
