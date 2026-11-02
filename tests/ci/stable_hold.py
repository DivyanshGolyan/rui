#!/usr/bin/env python3
"""Show what holds stable, and warn when a PR touches a held fixture without citing it.

`status` lists open stable-red issues by fixture and the hours since the
last push to stable (the last promotion), for every status update.
`pr` runs in the policy job: an open stable-red issue whose fixture or test
paths the PR changes must be cited `Fixes #N` or `Refs #N` in the PR body or
a commit, or the fix leaves stable held (#724 fixed #711 and #712 uncited).
"""
import argparse
from datetime import datetime, timezone
import json
import os
import re
import subprocess

from auto_land import CLOSING_KEYWORD, STABLE_RED, git, gh
from report_issue import signature_state
from select_tests import changed_paths

REFERENCE = re.compile(r"\brefs?:?\s+#([0-9]+)\b", re.IGNORECASE)


def held(repository):
    """(number, title, paths) of each open stable-red issue."""
    # REST, not `gh issue list`: GraphQL fails through the cloud sessions' proxy.
    # Pages by hand: `gh api --paginate` also fails through that proxy.
    rows, page = [], 1
    while batch := json.loads(gh("api", f"repos/{repository}/issues?labels={STABLE_RED}&state=open"
                                        f"&per_page=100&page={page}")):
        rows += batch
        page += 1
    return [(row["number"], row["title"], (signature_state(row["body"]) or {}).get("paths", []))
            for row in rows if "pull_request" not in row]


def cited(text):
    return ({int(number) for target, number in CLOSING_KEYWORD.findall(text) if not target}
            | {int(number) for number in REFERENCE.findall(text)})


def uncited(issues, paths, text):
    """Issues whose paths the change touches and that the text never cites."""
    touched, numbers = set(paths), cited(text)
    return [(number, title, sorted(touched & set(held_paths))) for number, title, held_paths in issues
            if touched & set(held_paths) and number not in numbers]


def status(issues, promoted_at, now):
    lines = []
    if promoted_at:
        hours = (now - datetime.fromisoformat(promoted_at.replace("Z", "+00:00"))).total_seconds() / 3600
        lines.append(f"Last stable promotion {hours:.0f} h ago.")
    else:
        lines.append("No stable promotion found.")
    if not issues:
        return lines + ["Stable is not held: no open stable-red issues."]
    by_path = {}
    for number, title, paths in issues:
        for path in paths or ["(no fixture recorded)"]:
            by_path.setdefault(path, []).append(f"#{number} {title}")
    lines.append(f"Stable is held by {len(issues)} open stable-red issue(s):")
    for path in sorted(by_path):
        lines.append(f"  {path}")
        lines.extend(f"    {entry}" for entry in by_path[path])
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "DivyanshGolyan/rui"))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    pr = sub.add_parser("pr")
    pr.add_argument("--base", required=True)
    pr.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    if args.command == "status":
        issues = held(args.repository)
        # The last push to stable is the last promotion; a release can lag it or be lost.
        pushes = json.loads(gh("api", f"repos/{args.repository}/activity?ref=refs/heads/stable&per_page=1"))
        promoted_at = pushes[0]["timestamp"] if pushes else None
        print("\n".join(status(issues, promoted_at, datetime.now(timezone.utc))))
        return
    try:
        issues = held(args.repository)
    except subprocess.CalledProcessError as error:
        # The warning never gates the policy job, so an API outage must not either.
        print(f"::warning::Could not list open stable-red issues, so uncited fixes were not checked: "
              f"{(error.stderr or '').strip()}")
        return
    paths, base = changed_paths(args.base, args.head)
    text = os.environ.get("PR_BODY", "") + "\n" + git("log", "--format=%B", f"{base}..{args.head}")
    for number, title, touched in uncited(issues, paths, text):
        print(f"::warning::This change touches {', '.join(touched)}, held by open stable-red #{number} "
              f"({title}). If it fixes it, write `Fixes #{number}`; otherwise `Refs #{number}`.")


if __name__ == "__main__":
    main()
