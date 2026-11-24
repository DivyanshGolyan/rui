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


def after_ready_transition(api, repo, number, run, jobs):
    events = pages(api, f"repos/{repo}/issues/{number}/timeline?", None)
    ready = max((event["created_at"] for event in events if event.get("event") == "ready_for_review"), default="")
    plan = next((job for job in jobs if job["name"] == "plan"), {})
    markers = {step["name"] for step in plan.get("steps", [])}
    if "PR admission trigger draft" in markers:
        return False
    if "PR admission trigger ready" in markers:
        return run["created_at"] >= ready
    return run["created_at"] > ready


def recheck(api, repo, number, head, *, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + WAIT_SECONDS
    while True:
        pr = api("GET", f"repos/{repo}/pulls/{number}")
        if (pr["state"] != "open" or pr["draft"] or pr["head"]["sha"] != head
                or (pr["head"].get("repo") or {}).get("full_name") != repo):
            return "PR is closed, draft, or no longer at the published head"
        run = current_run(api, repo, pr)
        if run is None:
            return "No current PR run; its future admission will read the screens"
        jobs = list(pages(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
        if not after_ready_transition(api, repo, number, run, jobs):
            return "::warning::Cannot distinguish this run from a ready transition; verify the current admission and rerun it if needed"
        admission = next((job for job in jobs if job["name"] == "admission"), None)
        if admission is None or admission["status"] in ("queued", "waiting", "pending", "requested"):
            return "Admission has not started; it will read the screens"
        if admission["status"] != "completed" or run["status"] != "completed":
            if clock() >= deadline:
                return "::warning::Admission did not finish; rerun it manually if it failed before seeing the screens"
            sleep(POLL_SECONDS)
            continue
        if admission["conclusion"] != "failure":
            return "Admission did not fail; no retry needed"
        current = api("GET", f"repos/{repo}/pulls/{number}")
        if (current["state"] != "open" or current["draft"] or current["head"]["sha"] != head
                or (current["head"].get("repo") or {}).get("full_name") != repo
                or current["head"]["ref"] != pr["head"]["ref"]):
            return "PR changed while selecting admission"
        fresh = current_run(api, repo, current)
        if fresh is None or (fresh["id"], fresh["run_attempt"], fresh["status"]) != (run["id"], run["run_attempt"], "completed") or not after_ready_transition(api, repo, number, fresh, jobs):
            continue
        api("POST", f"repos/{repo}/actions/jobs/{admission['id']}/rerun")
        return f"Rerun admission in run {run['id']}"


if __name__ == "__main__":
    print(recheck(github, os.environ["GITHUB_REPOSITORY"], os.environ["PR"], os.environ["HEAD_SHA"]))
