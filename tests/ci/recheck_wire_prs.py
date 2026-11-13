#!/usr/bin/env python3
"""Recheck wire-changing PRs after publication, using the repository's Actions token.

The gate compares committed openapi.json with the newest v0.S.N git tag, and
reads src/wire_version.zig. Either path (including a rename away) qualifies.
check.yml's policy job discovers test_wire_version.py; admission directly needs
policy. POST actions/jobs/ID/rerun reruns policy and its dependents, not the
native builds. policy's checkout uses fetch-depth: 0, fetching the new tag even
when the run keeps its original SHA.

Only open, non-draft PRs based on main qualify. Use the latest check.yml PR run
for the exact current head and PR number, never an older completed run. Poll
active runs every 60 seconds, then rerun policy even if its original checkout
preceded publication. One 90-minute budget covers all PRs, discovery and API
calls; timeout names the PRs left unrechecked. No completed policy job yet is
a logged skip, not an error. API errors fail the command. Required permissions:
actions: write, pull-requests: read, contents: read (also at a reusable caller).
"""
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from urllib.parse import urlencode

from conflict_alert import github, pages


WORKFLOW = ".github/workflows/check.yml"
WIRE_PATHS = frozenset(("openapi.json", "src/wire_version.zig"))
POLL_SECONDS = 60
TIMEOUT_SECONDS = 90 * 60


@dataclass(frozen=True)
class Selection:
    job_id: int | None
    reason: str
    waiting: bool = False


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
        return Selection(None, f"latest run {run['id']} is {run['status']}", waiting=True)
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


def same_pr(original, current):
    return main_pr(current) and current["head"]["sha"] == original["head"]["sha"]


def changed_files(api, repo, number):
    files = list(pages(api, f"repos/{repo}/pulls/{number}/files?"))
    if len(files) >= 3000:
        raise ValueError(f"PR #{number} has at least 3000 files; GitHub's file list may be incomplete")
    return files


def recheck_one(api, repo, pr, files):
    number = pr["number"]
    current = api("GET", f"repos/{repo}/pulls/{number}")
    if not main_pr(current):
        return Selection(None, "PR changed while selecting")
    if current["head"]["sha"] != pr["head"]["sha"]:
        files = changed_files(api, repo, number)
    if not touches_wire(files):
        return Selection(None, "no wire contract files")
    selected_pr = current
    runs = check_runs(api, repo, current)
    run = latest_run(current, runs)
    jobs = (collection(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs")
            if run is not None and run["status"] == "completed" else [])
    selection = select_rerun(current, files, runs, jobs)
    if selection.job_id is None:
        return selection
    # Revalidate before POST, including an intervening head change or rerun
    # of the same workflow run ID. A changed head is selected afresh next poll.
    current = api("GET", f"repos/{repo}/pulls/{number}")
    if not same_pr(selected_pr, current):
        return Selection(None, "PR changed while selecting", waiting=main_pr(current))
    fresh_runs = check_runs(api, repo, current)
    fresh = latest_run(current, fresh_runs)
    if fresh is not None and (fresh["id"], fresh["run_attempt"]) != (run["id"], run["run_attempt"]):
        return Selection(None, "latest run changed while selecting", waiting=True)
    selection = select_rerun(current, files, fresh_runs, jobs)
    if selection.job_id is not None:
        print(f"Rerun PR #{number}: job {selection.job_id}, {selection.reason}", flush=True)
        api("POST", f"repos/{repo}/actions/jobs/{selection.job_id}/rerun")
    return selection


def recheck(api, repo, *, clock=None, sleep=None):
    clock, sleep = clock or time.monotonic, sleep or time.sleep
    deadline = clock() + TIMEOUT_SECONDS
    pending = {}
    discovery_complete = False

    def check_budget():
        remaining = deadline - clock()
        if remaining <= 0:
            raise TimeoutError("recheck budget exhausted")
        return remaining

    def bounded_api(method, path):
        check_budget()
        result = api(method, path)
        check_budget()
        return result

    try:
        # Inventory before waiting, so timeout can name every unrechecked PR
        # and one slow run cannot prevent ready PRs from being rechecked.
        for pr in pages(bounded_api, f"repos/{repo}/pulls?state=open&base=main"):
            if main_pr(pr):
                pending[pr["number"]] = (pr, None)
        for number, (pr, _) in list(pending.items()):
            files = changed_files(bounded_api, repo, number)
            if touches_wire(files):
                pending[number] = (pr, files)
            else:
                del pending[number]
        discovery_complete = True
        while pending:
            for number, (pr, files) in list(pending.items()):
                selection = recheck_one(bounded_api, repo, pr, files)
                if selection.waiting:
                    print(f"Wait PR #{number}: {selection.reason}", flush=True)
                else:
                    if selection.job_id is None:
                        print(f"Skip PR #{number}: {selection.reason}", flush=True)
                    del pending[number]
            if pending:
                sleep(min(POLL_SECONDS, check_budget()))
    except TimeoutError as error:
        numbers = ", ".join(f"#{number}" for number in sorted(pending)) or "unknown"
        phase = " (PR discovery incomplete)" if not discovery_complete else ""
        raise TimeoutError(f"90-minute budget exhausted; could not recheck PRs: {numbers}{phase}") from error


def alarm_timeout(_signal, _frame):
    raise TimeoutError("90-minute recheck watchdog expired")


def main():
    # The job runs on Ubuntu. A watchdog also interrupts a hung REST subprocess;
    # monotonic checks in recheck own normal polling and testable timeout policy.
    previous = signal.signal(signal.SIGALRM, alarm_timeout)
    signal.alarm(TIMEOUT_SECONDS)
    try:
        recheck(github, os.environ["GITHUB_REPOSITORY"])
    except (subprocess.CalledProcessError, ValueError, KeyError, TimeoutError) as error:
        print(f"::error::Cannot recheck wire PRs: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    return 0


if __name__ == "__main__":
    sys.exit(main())
