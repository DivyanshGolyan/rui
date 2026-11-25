#!/usr/bin/env python3
"""Print the PR merge commit built on main as it is now.

GitHub recomputes refs/pull/N/merge lazily, so a run triggered minutes after main moved can still
check a merge on the old main (#2288 tested main before #2284). Asking for the PR makes GitHub
rebuild the merge; wait until its first parent is main's current head.
"""
import os
import sys
import time

from conflict_alert import github

ATTEMPTS = 12
PAUSE_SECONDS = 5


class Stale(Exception):
    """GitHub did not rebuild the PR merge on main's head in time."""


def fresh_merge(api, repo, number, sleep=time.sleep):
    for _ in range(ATTEMPTS):
        main = api("GET", f"repos/{repo}/branches/main")["commit"]["sha"]
        pr = api("GET", f"repos/{repo}/pulls/{number}")
        if pr["mergeable"] is False:
            raise Stale(f"PR #{number} conflicts with main {main[:12]}; merge main into it")
        merge = pr.get("merge_commit_sha")
        if merge and pr["mergeable"] is not None:
            parents = api("GET", f"repos/{repo}/commits/{merge}")["parents"]
            if parents and parents[0]["sha"] == main:
                return merge, main
        sleep(PAUSE_SECONDS)
    raise Stale(f"GitHub did not rebuild PR #{number}'s merge on main within "
                f"{ATTEMPTS * PAUSE_SECONDS} s; rerun the plan job")


def main():
    try:
        merge, base = fresh_merge(github, os.environ["GITHUB_REPOSITORY"], os.environ["PR_NUMBER"])
    except Stale as error:
        print(f"::error::{error}")
        return 1
    print(f"Candidate {merge} merges the PR into main {base}", file=sys.stderr)
    print(merge)
    return 0


if __name__ == "__main__":
    sys.exit(main())
