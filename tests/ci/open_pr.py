#!/usr/bin/env python3
"""Open a ready PR so selected CI and Codex review start together.

Merge still requires current-candidate admission and the Codex evidence in
CODING_STANDARDS.md. `ready` converts older drafts without another push.

  open_pr.py open --title TITLE --body-file FILE [--base main]
  open_pr.py ready
"""
import argparse
import json
import subprocess
import sys
from urllib.parse import quote

from conflict_alert import gh, github
from pr_overlap import branch_changes, origin_repo, overlaps, report


def create_args(repo, title, body_file, base, branch):
    """REST `gh api` arguments creating a ready PR without draft conversion.

    `gh pr create`, `gh pr comment` and `gh pr list` use GraphQL, which cloud sessions are refused.
    """
    return ["api", "-X", "POST", f"repos/{repo}/pulls", "-f", f"title={title}", "-f", f"head={branch}",
            "-f", f"base={base}", "-F", "draft=false", "-F", f"body=@{body_file}"]


def open_refusal(local_head, pushed_head, dirty=False):
    if dirty:
        return "Commit or discard local changes first: open requires a committed head."
    if pushed_head is None:
        return "Push the branch first: it has no upstream on origin."
    if local_head != pushed_head:
        return "Push the branch first: origin does not have this commit as its head."
    return None


def ready_refusal(pr, local_head, dirty):
    """Why the PR (a REST pull request) cannot become ready yet, or None.

    Convert an older draft when: the PR's head on GitHub is this checkout's committed
    head, with nothing left uncommitted to push after it.
    """
    if pr is None:
        return "This branch has no open PR; open one with `open_pr.py open`."
    if not pr["draft"]:
        return f"PR #{pr['number']} is already ready for review."
    if dirty:
        return "Commit or discard local changes first: ready requires a committed head."
    head = pr["head"]["sha"]
    if head != local_head:
        return (f"PR #{pr['number']}'s head on GitHub is {head[:10]}, not this checkout's "
                f"{local_head[:10]}: push the last planned commit first.")
    return None


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    opening = commands.add_parser("open", help="check overlap with open PRs, then open a ready PR")
    opening.add_argument("--title", required=True)
    opening.add_argument("--body-file", required=True)
    opening.add_argument("--base", default="main")
    commands.add_parser("ready", help="mark this branch's older draft ready to run CI beside review")
    args = parser.parse_args()
    branch, head = git("branch", "--show-current"), git("rev-parse", "HEAD")
    try:
        repo = origin_repo()
        if args.command == "open":
            if refusal := open_refusal(head, git("rev-parse", "--verify", "-q", f"origin/{branch}"), bool(git("status", "--porcelain"))):
                print(refusal, file=sys.stderr)
                return 1
            report(overlaps(github, repo, branch, *branch_changes(f"origin/{args.base}")))
            pr = json.loads(gh(*create_args(repo, args.title, args.body_file, args.base, branch)))
            print(pr["html_url"])
            github("POST", f"repos/{repo}/issues/{pr['number']}/comments", [("body", "@codex review")])
            print("Opened ready and requested Codex review. Selected CI runs beside review. "
                  "Merge requires current-candidate admission and clean Codex evidence; "
                  "request review again when a semantic change invalidates it.")
            return 0
        owner = repo.split("/")[0]
        found = github("GET", f"repos/{repo}/pulls?state=open&head={quote(f'{owner}:{branch}', safe=':/')}")
        pr = found[0] if found else None
        if refusal := ready_refusal(pr, head, bool(git("status", "--porcelain"))):
            print(refusal, file=sys.stderr)
            return 1
        # GitHub's REST API has no ready-for-review endpoint, so this one step stays on GraphQL.
        gh("pr", "ready", str(pr["number"]), "--repo", repo)
        print(f"PR #{pr['number']} is ready; its full selected suite now runs on {head[:10]}.")
        return 0
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot reach GitHub: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
