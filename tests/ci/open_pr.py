#!/usr/bin/env python3
"""Open a draft for Codex review; mark it ready only once Codex is clean.

Draft CI runs quick checks only; local prepush.py owns development feedback.
The opener requests Codex review on the draft. Push fixes to the draft and
comment `@codex review` after each push: Codex reviews drafts only on request.
Once Codex is clean on the current head, run `ready` to start the full suite.

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

    Run ready once Codex is clean: the PR's head on GitHub is this checkout's committed
    head, with nothing left uncommitted to push after it.
    """
    if pr is None:
        return "This branch has no open PR; open one with `open_pr.py open`."
    if not pr["isDraft"]:
        return f"PR #{pr['number']} is already ready for review."
    if dirty:
        return "Commit or discard local changes first: ready requires a committed, Codex-clean head."
    if pr["headRefOid"] != local_head:
        return (f"PR #{pr['number']}'s head on GitHub is {pr['headRefOid'][:10]}, not this checkout's "
                f"{local_head[:10]}: push the last planned commit and request `@codex review` first.")
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
    commands.add_parser("ready", help="mark this branch's draft PR ready once Codex is clean on its head")
    args = parser.parse_args()
    branch, head = git("branch", "--show-current"), git("rev-parse", "HEAD")
    try:
        if args.command == "open":
            if refusal := open_refusal(head, git("rev-parse", "--verify", "-q", f"origin/{branch}")):
                print(refusal, file=sys.stderr)
                return 1
            repo = json.loads(gh("repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
            report(overlaps(github, repo, branch, *branch_changes(f"origin/{args.base}")))
            url = gh(*create_args(args.title, args.body_file, args.base, branch)).strip()
            print(url)
            gh("pr", "comment", url, "--body", "@codex review")
            print("Opened as a draft and requested Codex review. Push fixes to the draft, then comment "
                  "`@codex review` after each push. Once Codex is clean on the current head, run: "
                  "python3 tests/ci/open_pr.py ready (starts the full suite).")
            return 0
        found = json.loads(gh("pr", "list", "--head", branch, "--state", "open",
                              "--json", "number,isDraft,headRefOid"))
        pr = found[0] if found else None
        if refusal := ready_refusal(pr, head, bool(git("status", "--porcelain"))):
            print(refusal, file=sys.stderr)
            return 1
        gh("pr", "ready", str(pr["number"]))
        print(f"PR #{pr['number']} is ready; its full selected suite now runs on {head[:10]}.")
        return 0
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot reach GitHub: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
