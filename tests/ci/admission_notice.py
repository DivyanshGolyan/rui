#!/usr/bin/env python3
"""Tell a PR why its admission failed, and rerun a failed admission after a PR body edit.

comment: after a Selected checks run on a pull request fails, post the admission job's errors
on the PR once per run attempt, so the author sees the reason without opening the run.
rerun: after an edit changes a PR's body, rerun the head's newest run when only plan and admission
failed. Both read the live body (pr_shape.py), so a body fix needs no push.
"""
import os
import subprocess
import sys

from conflict_alert import github, pages

WORKFLOW = "Selected checks"
MARKER = "<!-- admission-failure run={run} attempt={attempt} -->"
NOISE = "Process completed with exit code"
BODY_JOBS = {"plan", "admission"}


def admission(jobs):
    return next((job for job in jobs if job["name"] == "admission"), None)


def reasons(annotations):
    found = []
    for item in annotations:
        message = (item.get("message") or "").strip()
        if item.get("annotation_level") == "failure" and message and not message.startswith(NOISE):
            if message not in found:
                found.append(message)
    return found


def comment_body(run, job, annotations):
    marker = MARKER.format(run=run["id"], attempt=run.get("run_attempt", 1))
    lines = reasons(annotations) or ["No error annotation; open the job for its log."]
    listed = "\n".join(f"- {line}" for line in lines)
    return (f"{marker}\nAdmission failed for `{run['head_sha'][:12]}` ([job]({job['html_url']})):\n\n{listed}\n\n"
            "A body fix reruns admission by itself; a code fix needs a push.")


def comment(api, repo, run_id):
    run = api("GET", f"repos/{repo}/actions/runs/{run_id}")
    if run["event"] != "pull_request" or run["conclusion"] != "failure":
        return None
    job = admission(api("GET", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")["jobs"])
    if job is None or job["conclusion"] != "failure":
        return None
    numbers = [pr["number"] for pr in run.get("pull_requests") or []] or [
        pr["number"] for pr in api("GET", f"repos/{repo}/commits/{run['head_sha']}/pulls")
        if pr["state"] == "open"]
    if not numbers:
        return None
    number = numbers[0]
    pr = api("GET", f"repos/{repo}/pulls/{number}")
    if pr["state"] != "open" or pr["draft"] or pr["head"]["sha"] != run["head_sha"]:
        return None
    body = comment_body(run, job, list(pages(api, f"repos/{repo}/check-runs/{job['id']}/annotations?")))
    marker = body.split("\n", 1)[0]
    if any(marker in (c.get("body") or "") for c in pages(api, f"repos/{repo}/issues/{number}/comments?")):
        return None
    api("POST", f"repos/{repo}/issues/{number}/comments", [("body", body)])
    return number


def newest_run(runs):
    runs = [run for run in runs if run["name"] == WORKFLOW and run["event"] == "pull_request"]
    return max(runs, key=lambda run: run["run_number"], default=None)


def rerun(api, repo, head_sha):
    run = newest_run(api("GET", f"repos/{repo}/actions/runs?head_sha={head_sha}&per_page=100")["workflow_runs"])
    if run is None or run["status"] != "completed":
        return None
    failed = {job["name"] for job in api("GET", f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")["jobs"]
              if job["conclusion"] == "failure"}
    # Only plan's PR shape and admission read the body; a failed build or test needs a push, not this rerun.
    if "admission" not in failed or not failed <= BODY_JOBS:
        return None
    api("POST", f"repos/{repo}/actions/runs/{run['id']}/rerun-failed-jobs")
    return run["id"]


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    try:
        if sys.argv[1] == "comment":
            print("commented on:", comment(github, repo, os.environ["RUN_ID"]))
        else:
            print("reran run:", rerun(github, repo, os.environ["HEAD_SHA"]))
    except subprocess.CalledProcessError as error:
        print(f"::error::{error}: {(error.stderr or '').strip()}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
