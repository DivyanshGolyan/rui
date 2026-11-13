#!/usr/bin/env python3
"""Comment on each open PR that a move of main left conflicting.

GitHub runs no checks on a PR that conflicts with its base, and no event says
so: the PR just sits without CI (#780 waited about 45 minutes). After every
PR merge, it asks GitHub for each open PR's merge state and comments on each
conflicting PR once per PR head, naming the main commit. The comment is the
event that reaches whoever watches the PR.
"""
import json
import os
import subprocess
import sys
import time

MARKER = "<!-- conflict-alert head={head} -->"


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def github(method, path, fields=()):
    args = ["api", "-X", method, path]
    for name, value in fields:
        args += ["-f", f"{name}={value}"]
    return json.loads(gh(*args) or "null")


def pages(api, path, key=None):
    """Every row of a paged list: `gh api --paginate` fails through the cloud sessions' proxy.

    key names the list inside an object envelope, such as Actions' `workflow_runs`.
    Rows arrive lazily, so a caller that stops early requests no further page.
    """
    page = 1
    while True:
        batch = api("GET", f"{path}&per_page=100&page={page}")
        if key is not None:
            batch = batch[key]
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def judged(api, repo, number, main_sha):
    """The PR if GitHub has judged it against main_sha, else None.

    GitHub recomputes mergeability in the background after main moves, so an
    early read can still return the old answer: a clean answer counts only
    when its test merge sits on main_sha.
    """
    pr = api("GET", f"repos/{repo}/pulls/{number}")
    if pr["state"] != "open" or pr["mergeable"] is False:
        return pr
    if pr["mergeable"]:
        merge = api("GET", f"repos/{repo}/commits/{pr['merge_commit_sha']}")
        if merge["parents"][0]["sha"] == main_sha:
            return pr
    return None


def alert(api, repo, main_sha, attempts=10, delay=6, sleep=time.sleep):
    """Comment on every open PR into main that conflicts with main_sha.

    Returns the PRs commented on, the PRs GitHub had not judged in time, and
    the PRs whose reads failed; one PR's failure does not stop the others.
    Every round reads all PRs still unjudged, so the wait is one deadline for
    the whole move of main, not one per PR: GitHub often leaves a clean PR's
    test merge on an older main, and each such PR used to cost a full wait.
    """
    waiting = [pr["number"] for pr in pages(api, f"repos/{repo}/pulls?state=open&base=main")]
    alerted, failed = [], []
    for attempt in range(attempts):
        unjudged = []
        for number in waiting:
            try:
                pr = judged(api, repo, number, main_sha)
                if pr is None:
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
                failed.append(number)
        waiting = unjudged
        if not waiting:
            break
        if attempt + 1 < attempts:
            sleep(delay)
    for number in waiting:
        print(f"::warning::#{number}: GitHub did not judge its merge with {main_sha[:12]} in time")
    return alerted, waiting, failed


def main():
    alerted, _late, failed = alert(github, os.environ["GITHUB_REPOSITORY"], os.environ["MAIN_SHA"])
    print("commented on:", " ".join(f"#{number}" for number in alerted) or "none")
    # A late answer is GitHub being slow, not a fault here: its warning is the report,
    # and the next move of main checks that PR again. Only a failed read fails the job.
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
