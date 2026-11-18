#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

from conflict_alert import github, pages


WORKFLOW = ".github/workflows/check.yml"
WIRE_PATHS = frozenset(("openapi.json", "src/wire_version.zig"))
POLL_SECONDS = 60
TIMEOUT_SECONDS = 90 * 60
MAX_API_FAILURES = 3
RERUN_WINDOW = timedelta(days=30)


class Unrechecked(Exception):
    """Some PRs could not be rechecked; the message names each and why."""


@dataclass(frozen=True)
class Selection:
    job_id: int | None
    reason: str
    waiting: bool = False
    failed: bool = False


def main_pr(pr):
    return pr["state"] == "open" and not pr["draft"] and pr["base"]["ref"] == "main"


def touches_wire(files):
    return any(path in WIRE_PATHS for file in files
               for path in (file["filename"], file.get("previous_filename")))


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError(f"expected a GitHub timestamp, got {value!r}")
    moment = datetime.fromisoformat(value)
    if moment.tzinfo is None:
        raise ValueError(f"GitHub timestamp has no time zone: {value!r}")
    return moment


def latest_run(pr, runs):
    head_repo = (pr["head"].get("repo") or {}).get("full_name")
    if head_repo is None:
        return None
    matches = [run for run in runs
               if run["event"] == "pull_request" and run["path"] == WORKFLOW
               and run["head_sha"] == pr["head"]["sha"]
               and (run.get("head_repository") or {}).get("full_name") == head_repo]
    return max(matches, key=lambda run: run["run_number"], default=None)


# The jobs that run the policy checks: `policy`, or on a ready PR the single `linux pr` job.
POLICY_JOBS = ("policy", "linux pr")


def checked_since(run, policy):
    if policy is not None and policy["status"] in ("in_progress", "completed"):
        return timestamp(policy["started_at"])
    return timestamp(run["run_started_at"])


def select_rerun(pr, files, runs, jobs, published, now):
    if not main_pr(pr):
        return Selection(None, "not an open, non-draft PR based on main")
    if not touches_wire(files):
        return Selection(None, "no wire contract files")
    run = latest_run(pr, runs)
    if run is None:
        return Selection(None, "no check.yml PR run for the current head yet")
    latest = [job for job in jobs if job["run_id"] == run["id"]
              and job["run_attempt"] == run["run_attempt"] and job["name"] in POLICY_JOBS]
    policy = [job for job in latest if job["conclusion"] != "skipped"] or latest[:1]
    if len(policy) > 1:
        raise ValueError(f"run {run['id']} has multiple latest policy jobs")
    policy = policy[0] if policy else None
    if checked_since(run, policy) >= published:
        return Selection(None, f"run {run['id']} checks after publication; it reads the new release itself")
    if now - timestamp(run["created_at"]) > RERUN_WINDOW:
        return Selection(None, f"run {run['id']} is older than GitHub's 30-day rerun limit; "
                               "push to the PR to start a fresh run", failed=True)
    if run["status"] != "completed":
        return Selection(None, f"latest run {run['id']} is {run['status']}", waiting=True)
    if policy is None or policy["status"] != "completed" or policy["conclusion"] == "skipped":
        return Selection(None, f"run {run['id']} has no completed policy check yet")
    return Selection(policy["id"], f"{policy['name']} in run {run['id']} and its dependents (including admission)")


def check_runs(api, repo, pr):
    query = urlencode({"event": "pull_request", "head_sha": pr["head"]["sha"]})
    return list(pages(api, f"repos/{repo}/actions/workflows/check.yml/runs?{query}", "workflow_runs"))


def same_pr(original, current):
    return main_pr(current) and current["head"]["sha"] == original["head"]["sha"]


def changed_files(api, repo, number):
    files = list(pages(api, f"repos/{repo}/pulls/{number}/files?"))
    if len(files) >= 3000:
        raise ValueError(f"PR #{number} has at least 3000 files; GitHub's file list may be incomplete")
    return files


def recheck_one(api, repo, pr, files, published, now):
    number = pr["number"]
    current = api("GET", f"repos/{repo}/pulls/{number}")
    if not main_pr(current):
        return Selection(None, "PR changed while selecting")
    if files is None or current["head"]["sha"] != pr["head"]["sha"]:
        files = changed_files(api, repo, number)
    if not touches_wire(files):
        return Selection(None, "no wire contract files")
    selected_pr = current
    runs = check_runs(api, repo, current)
    run = latest_run(current, runs)
    jobs = (list(pages(api, f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest", "jobs"))
            if run is not None else [])
    selection = select_rerun(current, files, runs, jobs, published, now())
    if selection.job_id is None:
        return selection
    current = api("GET", f"repos/{repo}/pulls/{number}")
    if not same_pr(selected_pr, current):
        return Selection(None, "PR changed while selecting", waiting=main_pr(current))
    fresh_runs = check_runs(api, repo, current)
    fresh = latest_run(current, fresh_runs)
    if fresh is not None and (fresh["id"], fresh["run_attempt"]) != (run["id"], run["run_attempt"]):
        return Selection(None, "latest run changed while selecting", waiting=True)
    selection = select_rerun(current, files, fresh_runs, jobs, published, now())
    if selection.job_id is not None:
        print(f"Rerun PR #{number}: job {selection.job_id}, {selection.reason}", flush=True)
        api("POST", f"repos/{repo}/actions/jobs/{selection.job_id}/rerun")
    return selection


def api_error(error):
    return (error.stderr or "").strip() or str(error)


def unrechecked(reasons):
    return ", ".join(f"#{number} ({reasons[number]})" for number in sorted(reasons)) or "unknown"


def utc_now():
    return datetime.now(timezone.utc)


def recheck(api, repo, published, *, clock=None, sleep=None, now=None):
    clock, sleep, now = clock or time.monotonic, sleep or time.sleep, now or utc_now
    deadline = clock() + TIMEOUT_SECONDS
    pending = {}
    reasons = {}
    failures = {}
    listed = False

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

    def give_up(number, reason):
        print(f"Fail PR #{number}: {reason}", flush=True)
        reasons[number] = reason
        del pending[number]

    def per_pr(number, step):
        try:
            result = step()
        except subprocess.CalledProcessError as error:
            failures[number] = failures.get(number, 0) + 1
            reason = f"API error: {api_error(error)}"
            if failures[number] >= MAX_API_FAILURES:
                give_up(number, f"{reason} ({MAX_API_FAILURES} consecutive failures)")
            else:
                print(f"Retry PR #{number} next poll: {reason}", flush=True)
                reasons[number] = reason
            return False, None
        except (ValueError, KeyError) as error:
            give_up(number, f"invalid data: {error}")
            return False, None
        failures.pop(number, None)
        return True, result

    def done(number):
        del pending[number]
        reasons.pop(number, None)

    try:
        for pr in pages(bounded_api, f"repos/{repo}/pulls?state=open&base=main"):
            if main_pr(pr):
                pending[pr["number"]] = (pr, None)
                reasons[pr["number"]] = "PR discovery incomplete"
        listed = True
        for number, (pr, _) in list(pending.items()):
            ok, files = per_pr(number, lambda: changed_files(bounded_api, repo, number))
            if not ok:
                continue
            if touches_wire(files):
                pending[number] = (pr, files)
                reasons[number] = "not rechecked yet"
            else:
                done(number)
        while pending:
            for number, (pr, files) in list(pending.items()):
                ok, selection = per_pr(number, lambda: recheck_one(bounded_api, repo, pr, files, published, now))
                if not ok:
                    continue
                if selection.failed:
                    give_up(number, selection.reason)
                elif selection.waiting:
                    print(f"Wait PR #{number}: {selection.reason}", flush=True)
                    reasons[number] = selection.reason
                else:
                    if selection.job_id is None:
                        print(f"Skip PR #{number}: {selection.reason}", flush=True)
                    done(number)
            if pending:
                sleep(min(POLL_SECONDS, check_budget()))
    except TimeoutError as error:
        names = unrechecked(reasons) if listed else "unknown (open PR list incomplete)"
        raise TimeoutError(f"90-minute budget exhausted; could not recheck PRs: {names}") from error
    if reasons:
        raise Unrechecked(f"could not recheck PRs: {unrechecked(reasons)}")


def alarm_timeout(_signal, _frame):
    raise TimeoutError("90-minute recheck watchdog expired")


def main():
    previous = signal.signal(signal.SIGALRM, alarm_timeout)
    signal.alarm(TIMEOUT_SECONDS)
    try:
        recheck(github, os.environ["GITHUB_REPOSITORY"], timestamp(os.environ["RELEASE_PUBLISHED_AT"]))
    except (subprocess.CalledProcessError, ValueError, KeyError, TimeoutError, Unrechecked) as error:
        print(f"::error::Cannot recheck wire PRs: {getattr(error, 'stderr', '') or error}", file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    return 0


if __name__ == "__main__":
    sys.exit(main())
