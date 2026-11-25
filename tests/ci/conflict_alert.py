#!/usr/bin/env python3
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
    pr = api("GET", f"repos/{repo}/pulls/{number}")
    if pr["state"] != "open" or pr["mergeable"] is False:
        return pr
    if pr["mergeable"]:
        merge = api("GET", f"repos/{repo}/commits/{pr['merge_commit_sha']}")
        if merge["parents"][0]["sha"] == main_sha:
            return pr
    return None


def cancel_checks(api, repo, head):
    for status in ("queued", "in_progress"):
        for run in pages(api, f"repos/{repo}/actions/runs?head_sha={head}&status={status}", "workflow_runs"):
            if run["name"] == "Selected checks" and run["event"] == "pull_request":
                api("POST", f"repos/{repo}/actions/runs/{run['id']}/cancel")


def alert(api, repo, main_sha, attempts=10, delay=6, sleep=time.sleep):
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
                    f"{marker}\nThis PR conflicts with main at {main_sha[:12]}, so GitHub runs no checks on it and its running checks were cancelled. "
                    "Merge origin/main into the branch and push."))])
                alerted.append(number)
                cancel_checks(api, repo, pr["head"]["sha"])
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
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
