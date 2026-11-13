#!/usr/bin/env python3
"""Recheck wire-changing PRs after publication, using the repository's Actions token.

The gate compares committed openapi.json with the newest v0.S.N git tag, and
reads src/wire_version.zig. Either path (including a rename away) qualifies.
check.yml's policy job discovers test_wire_version.py; admission directly needs
policy. POST actions/jobs/ID/rerun reruns policy and its dependents, not the
native builds. policy's checkout uses fetch-depth: 0, fetching the new tag even
when the run keeps its original SHA.

Only open, non-draft PRs based on main qualify. Use the latest check.yml PR run
for the PR's exact current head (SHA and head repository, so fork heads, whose
runs GitHub lists with no pull_requests, match too), never an older completed
run. RELEASE_PUBLISHED_AT is the release's published_at; the tag exists by
then. A latest attempt whose policy job (or, before policy starts, the run)
started at or after it already reads the new tag: no wait, no rerun. Otherwise
poll an active run every 60 seconds, then rerun policy. One 90-minute budget
covers all PRs, discovery and API calls; timeout names the PRs left
unrechecked. No completed policy job yet is a logged skip, not an error. API
errors fail the command. Required permissions: actions: write,
pull-requests: read, contents: read (also at a reusable caller).
"""
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
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


def timestamp(value):
    """GitHub's UTC ISO 8601 time; a missing or malformed one is a ValueError."""
    if not isinstance(value, str):
        raise ValueError(f"expected a GitHub timestamp, got {value!r}")
    moment = datetime.fromisoformat(value)
    if moment.tzinfo is None:
        raise ValueError(f"GitHub timestamp has no time zone: {value!r}")
    return moment


def latest_run(pr, runs):
    """Attribute by head SHA and head repository, the same rule for fork and
    same-repository heads (GitHub lists no pull_requests for fork runs)."""
    head_repo = (pr["head"].get("repo") or {}).get("full_name")
    if head_repo is None:
        return None
    matches = [run for run in runs
               if run["event"] == "pull_request" and run["path"] == WORKFLOW
               and run["head_sha"] == pr["head"]["sha"]
               and (run.get("head_repository") or {}).get("full_name") == head_repo]
    return max(matches, key=lambda run: run["run_number"], default=None)


def checked_since(run, policy):
    """When the latest attempt's policy checkout could first read tags: its
    start, or the run's start while policy has not started."""
    if policy is not None and policy["status"] in ("in_progress", "completed"):
        return timestamp(policy["started_at"])
    return timestamp(run["run_started_at"])


def select_rerun(pr, files, runs, jobs, published):
    """Pure decision over REST snapshots; jobs are from the run's latest
    execution; published is the release's publication time."""
    if not main_pr(pr):
        return Selection(None, "not an open, non-draft PR based on main")
    if not touches_wire(files):
        return Selection(None, "no wire contract files")
    run = latest_run(pr, runs)
    if run is None:
        return Selection(None, "no check.yml PR run for the current head yet")
    policy = [job for job in jobs if job["run_id"] == run["id"]
              and job["run_attempt"] == run["run_attempt"] and job["name"] == "policy"]
    if len(policy) > 1:
        raise ValueError(f"run {run['id']} has multiple latest policy jobs")
    policy = policy[0] if policy else None
    if checked_since(run, policy) >= published:
        return Selection(None, f"run {run['id']} checks after publication; it reads the new release itself")
    if run["status"] != "completed":
        return Selection(None, f"latest run {run['id']} is {run['status']}", waiting=True)
    if policy is None or policy["status"] != "completed" or policy["conclusion"] == "skipped":
        return Selection(None, f"run {run['id']} has no completed policy check yet")
    return Selection(policy["id"], f"policy in run {run['id']} and its dependents (including admission)")


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


def recheck_one(api, repo, pr, files, published):
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
    # Active runs too: policy's start decides whether the run needs a wait.
    jobs = (collection(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs")
            if run is not None else [])
    selection = select_rerun(current, files, runs, jobs, published)
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
    selection = select_rerun(current, files, fresh_runs, jobs, published)
    if selection.job_id is not None:
        print(f"Rerun PR #{number}: job {selection.job_id}, {selection.reason}", flush=True)
        api("POST", f"repos/{repo}/actions/jobs/{selection.job_id}/rerun")
    return selection


def recheck(api, repo, published, *, clock=None, sleep=None):
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
                selection = recheck_one(bounded_api, repo, pr, files, published)
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
        recheck(github, os.environ["GITHUB_REPOSITORY"], timestamp(os.environ["RELEASE_PUBLISHED_AT"]))
    except (subprocess.CalledProcessError, ValueError, KeyError, TimeoutError) as error:
        print(f"::error::Cannot recheck wire PRs: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    return 0


if __name__ == "__main__":
    sys.exit(main())
