#!/usr/bin/env python3
"""Comment on each open PR that a move of main left conflicting.

GitHub runs no checks on a PR that conflicts with its base, and no event says
so: the PR just sits without CI (#780 waited about 45 minutes). After every
move of main (a PR merge, or Auto-land's fast-forward, which dispatches this)
it asks GitHub for each open PR's merge state and comments on each
conflicting PR once per PR head, naming the main commit. The comment is the
event that reaches whoever watches the PR.
"""
import json
import os
import subprocess
import sys
import time

from auto_land import gh

MARKER = "<!-- conflict-alert head={head} -->"


def github(method, path, fields=()):
    args = ["api", "-X", method, path]
    for name, value in fields:
        args += ["-f", f"{name}={value}"]
    return json.loads(gh(*args) or "null")


def pages(api, path):
    """Every row of a paged list: `gh api --paginate` fails through the cloud sessions' proxy."""
    page = 1
    while True:
        batch = api("GET", f"{path}&per_page=100&page={page}")
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def settled(api, repo, number, main_sha, attempts=10, delay=6, sleep=time.sleep):
    """The PR once GitHub has judged it against main_sha, or None.

    GitHub recomputes mergeability in the background after main moves, so an
    early read can still return the old answer: a clean answer counts only
    when its test merge sits on main_sha.
    """
    for attempt in range(attempts):
        pr = api("GET", f"repos/{repo}/pulls/{number}")
        if pr["state"] != "open" or pr["mergeable"] is False:
            return pr
        if pr["mergeable"]:
            merge = api("GET", f"repos/{repo}/commits/{pr['merge_commit_sha']}")
            if merge["parents"][0]["sha"] == main_sha:
                return pr
        if attempt + 1 < attempts:
            sleep(delay)
    return None


def alert(api, repo, main_sha, sleep=time.sleep):
    """Comment on every open PR into main that conflicts with main_sha.

    Returns the PRs commented on and the PRs that could not be judged; one
    PR's failure does not stop the others.
    """
    numbers = [pr["number"] for pr in pages(api, f"repos/{repo}/pulls?state=open&base=main")]
    for number in numbers:  # Start GitHub computing every PR's mergeability before waiting on any.
        try:
            api("GET", f"repos/{repo}/pulls/{number}")
        except subprocess.CalledProcessError:
            pass  # Only a head start: the judging read below retries this PR and reports its failure.
    alerted, unjudged = [], []
    for number in numbers:
        try:
            pr = settled(api, repo, number, main_sha, sleep=sleep)
            if pr is None:
                print(f"::warning::#{number}: GitHub did not judge its merge with {main_sha[:12]} in time")
                unjudged.append(number)
                continue
            if pr["state"] != "open" or pr["mergeable"]:
                continue
            marker = MARKER.format(head=pr["head"]["sha"])
            if any(marker in comment["body"] for comment in pages(api, f"repos/{repo}/issues/{number}/comments?")):
                continue
            api("POST", f"repos/{repo}/issues/{number}/comments", [("body", (
                f"{marker}\nThis PR conflicts with main at {main_sha[:12]}, so GitHub runs no checks on it. "
                "Merge origin/main into the branch and push."))])
            alerted.append(number)
        except (subprocess.CalledProcessError, KeyError, IndexError) as failure:
            print(f"::warning::#{number}: {failure}: {getattr(failure, 'stderr', '') or ''}".strip())
            unjudged.append(number)
    return alerted, unjudged


def main():
    alerted, unjudged = alert(github, os.environ["GITHUB_REPOSITORY"], os.environ["MAIN_SHA"])
    print("commented on:", " ".join(f"#{number}" for number in alerted) or "none")
    sys.exit(1 if unjudged else 0)


if __name__ == "__main__":
    main()
