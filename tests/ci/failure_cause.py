#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess

from report_issue import gh, job_log

AGGREGATES = frozenset({"linux", "macos", "admission"})
INFRA_STEPS = frozenset({
    "Set up job",
    "Install the pinned packages tests/ci imports",
    "Install the pinned workflow linter",
    "Start MySQL 8.4 for the live dialect and settings-document checks",
    "Wait for MySQL 8.4",
    "Start Postgres 15 with TLS for test-pg's live rounds",
    "Check out the previous known installed build",
    "Restore the pinned previous release's compilation",
})
INFRA_ACTIONS = ("actions/checkout", "actions/setup-node", "actions/upload-artifact", "./.github/actions/setup")
NETWORK = re.compile(
    r"returned error: 5\d\d|HTTP 5\d\d|\b5\d\d (?:Internal Server Error|Bad Gateway|Service Unavailable|"
    r"Gateway Time-?out)|error: connection-failed|Could not resolve host|Temporary failure in name resolution|"
    r"NameResolutionError|Connection reset by peer|Connection timed out|ETIMEDOUT|ECONNRESET|EAI_AGAIN|"
    r"TLS handshake timeout|toomanyrequests|Operation timed out")
RUNNER_LOST = re.compile(
    r"was not acquired by Runner|received a shutdown signal|lost communication with the server|"
    r"hosted runner encountered an error")
STAMP = re.compile(r"^\ufeff?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)")
TAIL_LINES = 25


def infra_step(name):
    return name in INFRA_STEPS or any(name == f"Run {action}" or name.startswith(f"Run {action}@")
                                      for action in INFRA_ACTIONS)


def step_log(log, step):
    start, end = step["started_at"][:19], step["completed_at"][:19]
    lines, inside = [], False
    for line in log.splitlines():
        if stamp := STAMP.match(line):
            inside = start <= stamp[1] <= end
        if inside:
            lines.append(line)
    errors = [index for index, line in enumerate(lines) if "##[error]" in line]
    if errors:
        lines = lines[:errors[-1] + 1]
    return "\n".join(lines[-TAIL_LINES:])


def cause(job, annotations, log):
    if job["status"] != "completed":
        return "infra", "no runner took the job"
    if lost := next((note for note in annotations if RUNNER_LOST.search(note)), None):
        return "infra", lost
    stopped = next((step for step in job.get("steps") or () if step["conclusion"] in ("failure", "cancelled")), None)
    if stopped is None:
        if job["conclusion"] == "cancelled":
            return "infra", "cancelled before any step ran"
        return "check", f"{job['conclusion']} without a failed step"
    where = f"{stopped['conclusion']} at '{stopped['name']}'"
    if not infra_step(stopped["name"]):
        return "check", where
    if stopped["conclusion"] == "cancelled":
        return "infra", where
    if log is None:
        return "check", f"{where}; its log is unavailable, so no network error is proven"
    if network := NETWORK.search(step_log(log, stopped)):
        return "infra", f"{where}: {network[0]}"
    return "check", f"{where} without a network error"


def causes(jobs, annotations_of, log_of, finished=True):
    found = []
    for job in jobs:
        if job["name"] in AGGREGATES or job["conclusion"] in ("success", "skipped", "neutral"):
            continue
        if job["status"] != "completed" and not finished:
            continue
        kind, why = cause(job, annotations_of(job), log_of(job) if needs_log(job) else None)
        found.append((job["name"], kind, why))
    return found


def needs_log(job):
    return any(step["conclusion"] == "failure" and infra_step(step["name"]) for step in job.get("steps") or ())


def retry_refusal(run, found, head):
    if run["conclusion"] != "failure":
        return f"the run concluded {run['conclusion']}"
    if run["event"] != "pull_request":
        return f"the run is a {run['event']} run, not a pull request's admission"
    if run["run_attempt"] != 1:
        return f"attempt {run['run_attempt']} already follows a retry or a manual rerun"
    if not found:
        return "only an aggregate failed, so the failure is its requirement, not infrastructure"
    if checks := [name for name, kind, _ in found if kind != "infra"]:
        return "checks failed: " + ", ".join(checks)
    if head is None:
        return "the run names no open pull request in this repository"
    if head != run["head_sha"]:
        return f"the PR's head moved to {head}; a rerun would cancel its newer run"
    return None


def annotations(repository, job):
    try:
        notes = json.loads(gh("api", f"repos/{repository}/check-runs/{job['id']}/annotations"))
    except subprocess.CalledProcessError:
        return []
    return [note["message"] for note in notes]


def fetch(repository, run_id, attempt, finished):
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100"))
    jobs = [job for page in pages for job in page["jobs"]]
    return causes(jobs, lambda job: annotations(repository, job), lambda job: job_log(repository, job["id"]),
                  finished)


def explain(repository, run_id, attempt, event):
    found = fetch(repository, run_id, attempt, finished=False)
    lines = [f"{name}: {kind}: {why}" for name, kind, why in found]
    if not found:
        lines.append("No job of this run failed: the requirement above failed by itself, "
                     "such as a draft or a selection its results do not match.")
    elif all(kind == "infra" for _, kind, _ in found):
        follow = ("Selected checks reruns the failed jobs once when the run finishes."
                  if event == "pull_request" and attempt == "1" else "Rerun the failed jobs.")
        lines.append(f"Infrastructure only, no check failed. {follow}")
    print("\n".join(f"::error::{line}" for line in lines))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            print("\n".join(f"- {line}" for line in lines), file=output)


def retry(repository, run_id, dry_run):
    run = json.loads(gh("api", f"repos/{repository}/actions/runs/{run_id}"))
    found = fetch(repository, run_id, run["run_attempt"], finished=True)
    for name, kind, why in found:
        print(f"{name}: {kind}: {why}")
    pulls = run.get("pull_requests") or ()
    pull = json.loads(gh("api", f"repos/{repository}/pulls/{pulls[0]['number']}")) if pulls else None
    head = pull["head"]["sha"] if pull and pull["state"] == "open" else None
    if refusal := retry_refusal(run, found, head):
        print(f"No retry: {refusal}.")
        return
    print(f"Infrastructure only on attempt 1 of {run['head_sha']}: rerunning the failed jobs once.")
    if not dry_run:
        gh("api", "-X", "POST", f"repos/{repository}/actions/runs/{run_id}/rerun-failed-jobs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("explain", help="name each failed job of this run attempt and its cause")
    rerun = commands.add_parser("retry", help="rerun a completed run's failed jobs once if only infrastructure failed")
    rerun.add_argument("--run-id", required=True)
    rerun.add_argument("--dry-run", action="store_true", help="classify without rerunning")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    if args.command == "explain":
        explain(repository, os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"],
                os.environ.get("GITHUB_EVENT_NAME"))
    else:
        retry(repository, args.run_id, args.dry_run)


if __name__ == "__main__":
    main()
