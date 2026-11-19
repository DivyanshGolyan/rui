#!/usr/bin/env python3
"""Label each PR with the workstream of its Goal issue so the PR list scans by workstream.

Issues own the workstream: a PR inherits the workstream label of its Goal issue,
or of that issue's nearest parent that carries one. A PR whose Goal names no
labelled issue but changes only CI tooling gets CI. The labeler only adds labels.
"""
import argparse
import os
import re
import subprocess
import sys

from conflict_alert import github, pages
from pr_shape import goal_lines

WORKSTREAMS = ("TUI", "Host parity", "background tasks", "images", "Host consolidation", "Store", "CI", "drift")
CI_TOOLING = (".github/", "tests/ci/")
MAX_DEPTH = 10


def unavailable(error):
    """A missing, deleted or transferred issue; Goal validation checks only the text."""
    return isinstance(error, subprocess.CalledProcessError) and re.search(r"HTTP (404|410)\b", error.stderr or "")


def goal_issues(body, repo):
    """Issue numbers named on visible goal lines (Goal: or Fixes), in order."""
    issue = re.compile(r"(?<![\w/])(?:#([0-9]+)|https://github\.com/" + re.escape(repo) + r"/issues/([0-9]+))(?![\w/])")
    numbers = []
    for text in goal_lines(body):
        numbers += [int(match[1] or match[2]) for match in issue.finditer(text)]
    return list(dict.fromkeys(numbers))


def workstream(api, repo, number):
    """Workstream labels on the issue or its nearest labelled parent."""
    parent = re.compile(r"/repos/" + re.escape(repo) + r"/issues/([0-9]+)$")
    wanted = {name.casefold(): name for name in WORKSTREAMS}
    for _ in range(MAX_DEPTH):
        try:
            issue = api("GET", f"repos/{repo}/issues/{number}")
        except subprocess.CalledProcessError as error:
            if unavailable(error):
                return set()
            raise
        found = {wanted[label["name"].casefold()] for label in issue["labels"] if label["name"].casefold() in wanted}
        if found:
            return found
        up = parent.search(issue.get("parent_issue_url") or "")
        if up is None:
            return set()
        number = int(up[1])
    return set()


def labels_for(api, repo, pr):
    found = set()
    for number in goal_issues(pr["body"], repo):
        found |= workstream(api, repo, number)
    if not found:
        paths = [entry["filename"] for entry in pages(api, f"repos/{repo}/pulls/{pr['number']}/files?")]
        if paths and all(path.startswith(CI_TOOLING) for path in paths):
            found.add("CI")
    return found


def label(api, repo, pr):
    """Add the PR's missing workstream labels; return what was added."""
    present = {entry["name"].casefold() for entry in pr["labels"]}
    missing = sorted(name for name in labels_for(api, repo, pr) if name.casefold() not in present)
    if missing:
        api("POST", f"repos/{repo}/issues/{pr['number']}/labels", [("labels[]", name) for name in missing])
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--pr", type=int)
    which.add_argument("--all-open", action="store_true")
    args = parser.parse_args()
    if not args.repo:
        parser.error("provide --repo or GITHUB_REPOSITORY")
    prs = (pages(github, f"repos/{args.repo}/pulls?state=open") if args.all_open
           else [github("GET", f"repos/{args.repo}/pulls/{args.pr}")])
    failed = []
    for pr in prs:
        try:
            added = label(github, args.repo, pr)
        except subprocess.CalledProcessError as error:
            failed.append(pr["number"])
            print(f"#{pr['number']}: failed: {(error.stderr or '').strip()}", file=sys.stderr)
            continue
        print(f"#{pr['number']}: {', '.join(added) if added else 'no change'}")
    if failed:
        sys.exit(f"labelling failed for {', '.join(f'#{number}' for number in failed)}")


if __name__ == "__main__":
    main()
