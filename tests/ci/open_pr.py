#!/usr/bin/env python3
"""Open a PR as a draft, and mark it ready once its last planned push is on GitHub.

A ready PR runs the full review selection on every push, and a new push
cancels the run in flight: in 18 hours, 40 ready-PR runs (3,179
runner-minutes) were cancelled by the author's next push. A draft runs only
the cheap development selection, so a PR stays a draft until its author
has nothing more to push.

  open_pr.py open --title TITLE --body-file FILE [--base main]
  open_pr.py ready
"""
import argparse
import json
import subprocess
import sys

from conflict_alert import gh, github
from pr_overlap import branch_changes, overlaps, report


def create_args(title, body_file, base, branch):
    """`gh pr create` for a draft: the opener has no way to open a ready PR."""
    return ["pr", "create", "--draft", "--base", base, "--head", branch, "--title", title, "--body-file", body_file]


def open_refusal(local_head, pushed_head):
    if pushed_head is None:
        return "Push the branch first: it has no upstream on origin."
    if local_head != pushed_head:
        return "Push the branch first: origin does not have this commit as its head."
    return None


def ready_refusal(pr, local_head, dirty):
    """Why the PR cannot become ready yet, or None.

    Ready means done: the PR's head on GitHub is this checkout's committed
    head, with nothing left uncommitted to push after it.
    """
    if pr is None:
        return "This branch has no open PR; open one with `open_pr.py open`."
    if not pr["isDraft"]:
        return f"PR #{pr['number']} is already ready for review."
    if dirty:
        return "Commit or discard local changes first: ready means no further push is planned."
    if pr["headRefOid"] != local_head:
        return (f"PR #{pr['number']}'s head on GitHub is {pr['headRefOid'][:10]}, not this checkout's "
                f"{local_head[:10]}: push the last planned commit first.")
    return None


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    opening = commands.add_parser("open", help="check overlap with open PRs, then open a draft PR")
    opening.add_argument("--title", required=True)
    opening.add_argument("--body-file", required=True)
    opening.add_argument("--base", default="main")
    commands.add_parser("ready", help="mark this branch's draft PR ready after its last planned push")
    args = parser.parse_args()
    branch, head = git("branch", "--show-current"), git("rev-parse", "HEAD")
    try:
        if args.command == "open":
            if refusal := open_refusal(head, git("rev-parse", "--verify", "-q", f"origin/{branch}")):
                print(refusal, file=sys.stderr)
                return 1
            repo = json.loads(gh("repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
            report(overlaps(github, repo, branch, *branch_changes(f"origin/{args.base}")))
            print(gh(*create_args(args.title, args.body_file, args.base, branch)).strip())
            print("Opened as a draft. After the last planned push, run: python3 tests/ci/open_pr.py ready")
            return 0
        found = json.loads(gh("pr", "list", "--head", branch, "--state", "open",
                              "--json", "number,isDraft,headRefOid"))
        pr = found[0] if found else None
        if refusal := ready_refusal(pr, head, bool(git("status", "--porcelain"))):
            print(refusal, file=sys.stderr)
            return 1
        gh("pr", "ready", str(pr["number"]))
        print(f"PR #{pr['number']} is ready; its review selection now runs on {head[:10]}.")
        return 0
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot reach GitHub: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
