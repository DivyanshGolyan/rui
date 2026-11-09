#!/usr/bin/env python3
"""List open PRs sharing files with the committed branch before opening a PR."""
import argparse
import json
import subprocess
import sys

from conflict_alert import gh, github, pages


def overlaps(api, repo, branch, paths):
    result = []
    for pr in pages(api, f"repos/{repo}/pulls?state=open"):
        head = pr["head"]
        if head["ref"] == branch and (head["repo"] or {}).get("full_name") == repo:
            continue
        files = list(pages(api, f"repos/{repo}/pulls/{pr['number']}/files?"))
        if len(files) >= 3000:
            raise ValueError(f"PR #{pr['number']} has at least 3000 files; GitHub's file list may be incomplete")
        their_paths = {name for file in files for name in (file["filename"], file.get("previous_filename")) if name}
        shared = sorted(paths & their_paths)
        if shared:
            result.append((pr["number"], shared))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main", help="base for the committed branch diff")
    args = parser.parse_args()
    try:
        repo = json.loads(gh("repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
        branch = subprocess.check_output(["git", "branch", "--show-current"], text=True).strip()
        paths = set(subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", f"{args.base}...HEAD"]
        ).decode().split("\0")) - {""}
        found = overlaps(github, repo, branch, paths)
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Cannot check PR overlap: {error}", file=sys.stderr)
        return 1
    for number, shared in found:
        print(f"#{number}: {', '.join(shared)}")
    if not found:
        print("No shared files in open PRs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
