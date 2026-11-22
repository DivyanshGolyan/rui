"""The infrastructure verdict of a failed job: whether its failure was the runner's or the network's, not a check's.

A leaf module: it imports nothing from tests/ci, so the issue filer (report_issue.py) and the
failure-cause explainer (failure_cause.py, which imports the filer) can share it without a cycle.
"""
import re

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


def needs_log(job):
    return any(step["conclusion"] == "failure" and infra_step(step["name"]) for step in job.get("steps") or ())
