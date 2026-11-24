#!/usr/bin/env python3
import os
import time

from conflict_alert import github, pages
from recheck_wire_prs import check_runs, latest_run


POLL_SECONDS = 5
WAIT_SECONDS = 420


def current_run(api, repo, pr):
    runs = (run for run in check_runs(api, repo, pr) if run["head_branch"] == pr["head"]["ref"])
    return latest_run(pr, runs)


def eligible_pr(pr, repo, head):
    return (pr["state"] == "open" and not pr["draft"] and pr["head"]["sha"] == head
            and (pr["head"].get("repo") or {}).get("full_name") == repo)


def decide(pr, repo, number, head, run, jobs, events, expired):
    if not eligible_pr(pr, repo, head):
        return "stop", "PR is closed, draft, or no longer at the published head"
    if run is None:
        return "stop", "No current PR run; its future admission will read the screens"
    ready = max((event["created_at"] for event in events if event.get("event") == "ready_for_review"), default="")
    plan = next((job for job in jobs if job["name"] == "plan"), {})
    triggers = {step["name"] for step in plan.get("steps", [])
                if step["name"].startswith("PR admission trigger ")}
    associated = {str(item["number"]) for item in run.get("pull_requests", [])}
    provenance = (triggers == {f"PR admission trigger {number} ready"} and run["created_at"] >= ready
                  if triggers else associated == {str(number)} and run["created_at"] > ready)
    if not provenance:
        return "stop", "::warning::Cannot confirm the PR or ready transition for this run; verify the current admission and rerun it if needed"
    admission = next((job for job in jobs if job["name"] == "admission"), None)
    if admission is None or admission["status"] in ("queued", "waiting", "pending", "requested"):
        return "stop", "Admission has not started; it will read the screens"
    if admission["status"] != "completed" or run["status"] != "completed":
        if expired:
            return "stop", "::warning::Admission did not finish; rerun it manually if it failed before seeing the screens"
        return "wait", None
    if admission["conclusion"] != "failure":
        return "stop", "Admission did not fail; no retry needed"
    return "rerun", admission["id"]


def snapshot(api, repo, number, head):
    pr = api("GET", f"repos/{repo}/pulls/{number}")
    if not eligible_pr(pr, repo, head):
        return pr, None, [], []
    run = current_run(api, repo, pr)
    if run is None:
        return pr, None, [], []
    jobs = list(pages(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
    events = list(pages(api, f"repos/{repo}/issues/{number}/timeline?"))
    return pr, run, jobs, events


def recheck(api, repo, number, head, *, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + WAIT_SECONDS
    while True:
        pr, run, jobs, events = snapshot(api, repo, number, head)
        action, value = decide(pr, repo, number, head, run, jobs, events, clock() >= deadline)
        if action == "stop":
            return value
        if action == "wait":
            sleep(POLL_SECONDS)
            continue
        fresh_pr, fresh_run, fresh_jobs, fresh_events = snapshot(api, repo, number, head)
        if (fresh_pr["head"]["ref"] != pr["head"]["ref"] or fresh_run is None
                or (fresh_run["id"], fresh_run["run_attempt"]) != (run["id"], run["run_attempt"])):
            continue
        fresh_action, fresh_value = decide(fresh_pr, repo, number, head, fresh_run, fresh_jobs, fresh_events, clock() >= deadline)
        if (fresh_action, fresh_value) != ("rerun", value):
            continue
        api("POST", f"repos/{repo}/actions/jobs/{value}/rerun")
        return f"Rerun admission in run {run['id']}"


if __name__ == "__main__":
    print(recheck(github, os.environ["GITHUB_REPOSITORY"], os.environ["PR"], os.environ["HEAD_SHA"]))
