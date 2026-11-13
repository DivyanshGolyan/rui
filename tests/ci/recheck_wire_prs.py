#!/usr/bin/env python3
"""Recheck wire-changing PRs after publication, using the repository's Actions token.

The gate compares committed openapi.json with the newest v0.S.N git tag, and
reads src/wire_version.zig. Either path (including a rename away) qualifies.
check.yml's policy job discovers test_wire_version.py; admission directly needs
policy. POST actions/jobs/ID/rerun reruns policy and its dependents, not the
native builds. policy's checkout uses fetch-depth: 0, fetching the new tag even
when the run keeps its original SHA.

Only open, non-draft PRs based on main qualify. Use the latest check.yml PR run
for the exact current head and PR number, never an older completed run. Skip
an active latest run as requested: it may fetch the new tag itself. This is not
a guarantee if policy already fetched tags before publication and native jobs
are still running. No completed policy job yet is a logged skip, not an error.
API errors fail the command. Required permissions: actions: write,
pull-requests: read, contents: read (also required at a reusable caller).
"""
import os
import subprocess
import sys
from dataclasses import dataclass
from urllib.parse import urlencode

from conflict_alert import github, pages


WORKFLOW = ".github/workflows/check.yml"
WIRE_PATHS = frozenset(("openapi.json", "src/wire_version.zig"))


@dataclass(frozen=True)
class Selection:
    job_id: int | None
    reason: str


def main_pr(pr):
    return pr["state"] == "open" and not pr["draft"] and pr["base"]["ref"] == "main"


def touches_wire(files):
    return any(path in WIRE_PATHS for file in files
               for path in (file["filename"], file.get("previous_filename")))


def latest_run(pr, runs):
    """Attribute by PR and head, not a branch name shared with another fork."""
    matches = [run for run in runs
               if run["event"] == "pull_request" and run["path"] == WORKFLOW
               and run["head_sha"] == pr["head"]["sha"]
               and any(pull["number"] == pr["number"] for pull in run["pull_requests"])]
    return max(matches, key=lambda run: run["run_number"], default=None)


def select_rerun(pr, files, runs, jobs):
    """Pure decision over REST snapshots; jobs are from the run's latest execution."""
    if not main_pr(pr):
        return Selection(None, "not an open, non-draft PR based on main")
    if not touches_wire(files):
        return Selection(None, "no wire contract files")
    run = latest_run(pr, runs)
    if run is None:
        return Selection(None, "no check.yml PR run for the current head yet")
    if run["status"] != "completed":
        return Selection(None, f"latest run {run['id']} is {run['status']}")
    policy = [job for job in jobs if job["run_id"] == run["id"]
              and job["run_attempt"] == run["run_attempt"] and job["name"] == "policy"]
    if len(policy) > 1:
        raise ValueError(f"run {run['id']} has multiple latest policy jobs")
    if not policy or policy[0]["status"] != "completed" or policy[0]["conclusion"] == "skipped":
        return Selection(None, f"run {run['id']} has no completed policy check yet")
    return Selection(policy[0]["id"], f"policy in run {run['id']} and its dependents (including admission)")


def collection(api, path, key):
    """Reuse the REST pager for object-wrapped Actions collections too."""
    return list(pages(lambda method, endpoint: api(method, endpoint)[key], path))


def check_runs(api, repo, pr):
    query = urlencode({"event": "pull_request", "head_sha": pr["head"]["sha"]})
    return collection(api, f"repos/{repo}/actions/workflows/check.yml/runs?{query}", "workflow_runs")


def recheck(api, repo):
    for pr in pages(api, f"repos/{repo}/pulls?state=open&base=main"):
        if not main_pr(pr):
            continue
        number = pr["number"]
        files = list(pages(api, f"repos/{repo}/pulls/{number}/files?"))
        if len(files) >= 3000:
            raise ValueError(f"PR #{number} has at least 3000 files; GitHub's file list may be incomplete")
        if not touches_wire(files):
            continue
        runs = check_runs(api, repo, pr)
        run = latest_run(pr, runs)
        jobs = (collection(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs")
                if run is not None and run["status"] == "completed" else [])
        selection = select_rerun(pr, files, runs, jobs)
        if selection.job_id is not None:
            # A new head gets its own run; do not act on a PR closed, drafted or
            # retargeted while we were reading its files and jobs.
            current = api("GET", f"repos/{repo}/pulls/{number}")
            if not main_pr(current) or current["head"]["sha"] != pr["head"]["sha"]:
                print(f"Skip PR #{number}: PR changed while selecting", flush=True)
                continue
            # Refresh the run list too: a newer active run must not expose an
            # older green run, including a rerun of the same workflow run ID.
            selection = select_rerun(current, files, check_runs(api, repo, current), jobs)
        if selection.job_id is None:
            print(f"Skip PR #{number}: {selection.reason}", flush=True)
            continue
        print(f"Rerun PR #{number}: job {selection.job_id}, {selection.reason}", flush=True)
        api("POST", f"repos/{repo}/actions/jobs/{selection.job_id}/rerun")


def main():
    try:
        recheck(github, os.environ["GITHUB_REPOSITORY"])
    except (subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"::error::Cannot recheck wire PRs: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
