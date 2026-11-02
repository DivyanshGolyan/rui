#!/usr/bin/env python3
"""Comment on each open PR that a push to main left conflicting.

GitHub runs no checks on a PR that conflicts with its base, and no event says
so: the PR just sits without CI (#780 waited about 45 minutes). After every
push to main this asks GitHub for each open PR's merge state and comments on
each conflicting PR once per PR head, naming the main commit. The comment is
the event that reaches whoever watches the PR.
"""
import json
import os
import time
import urllib.request

API = "https://api.github.com"
MARKER = "<!-- conflict-alert head={head} -->"


def github(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def settled(api, repo, number, attempts=10, delay=6, sleep=time.sleep):
    """GitHub computes mergeability after a push in the background; a read
    starts it, and later reads return it once known."""
    for attempt in range(attempts):
        pr = api("GET", f"/repos/{repo}/pulls/{number}")
        if pr["mergeable"] is not None:
            return pr
        if attempt + 1 < attempts:
            sleep(delay)
    return pr


def comments(api, repo, number):
    page = 1
    while True:
        batch = api("GET", f"/repos/{repo}/issues/{number}/comments?per_page=100&page={page}")
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def alert(api, repo, main_sha, sleep=time.sleep):
    """Comment on every open PR into main that conflicts with it; return their numbers."""
    alerted = []
    numbers = [pr["number"] for pr in api("GET", f"/repos/{repo}/pulls?state=open&base=main&per_page=100")]
    for number in numbers:  # Start GitHub computing every PR's mergeability before waiting on any.
        api("GET", f"/repos/{repo}/pulls/{number}")
    for number in numbers:
        pr = settled(api, repo, number, sleep=sleep)
        if pr["mergeable"] is not False:
            continue
        marker = MARKER.format(head=pr["head"]["sha"])
        if any(marker in comment["body"] for comment in comments(api, repo, pr["number"])):
            continue
        api("POST", f"/repos/{repo}/issues/{pr['number']}/comments", {"body": (
            f"{marker}\nThis PR conflicts with main at {main_sha[:12]}, so GitHub runs no checks on it. "
            "Merge origin/main into the branch and push.")})
        alerted.append(pr["number"])
    return alerted


def main():
    alerted = alert(github, os.environ["GITHUB_REPOSITORY"], os.environ["MAIN_SHA"])
    print("conflicting:", " ".join(f"#{number}" for number in alerted) or "none newly")


if __name__ == "__main__":
    main()
