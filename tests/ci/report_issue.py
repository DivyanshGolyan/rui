#!/usr/bin/env python3
"""File a scheduled run's failure: comment on the open issue with this exact title, or open one."""
import argparse
import json
import os
import subprocess


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", required=True)
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    issues = json.loads(gh("issue", "list", "--repo", repository, "--state", "open",
                           "--search", f'in:title "{args.title}"', "--json", "number,title"))
    existing = next((issue["number"] for issue in issues if issue["title"] == args.title), None)
    if existing:
        gh("issue", "comment", str(existing), "--repo", repository, "--body", args.body)
        print(existing)
    else:
        print(gh("issue", "create", "--repo", repository, "--title", args.title, "--body", args.body).strip())


if __name__ == "__main__":
    main()
