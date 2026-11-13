#!/usr/bin/env python3
"""Keep one `ci-red` issue open while the main build is red, naming the PRs that crossed.

No check runs on `main` after a merge, and PRs need no up-to-date base, so two
PRs green alone can break `main` together (#1410). main-build.yml compiles
`main` after every push. A red build files, or updates and comments on, one open
issue naming each PR merged since the last green main build; the next green
build comments on it and closes it. The revert of the later crossing PR is the
fast fix (docs/agents/landing.md, "CI failures").

Unlike report_issue.py's per-signature issues, this one tracks a state of
`main`, so green alone closes it; its cause label is still the closer's.
"""
import argparse
from dataclasses import dataclass
import json
import os
import re
import subprocess

from report_issue import LABEL, gh, run_jobs

WORKFLOW = "main-build.yml"
TITLE = "Main build red"
MARKER = "<!-- main-build-red -->"
# A squash merge's subject ends with its PR number.
PR_NUMBER = re.compile(r"\(#([1-9][0-9]*)\)$")


@dataclass(frozen=True)
class Commit:
    sha: str
    subject: str
    pr: int | None


def git(*args, cwd=None):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, cwd=cwd).stdout


def crossing(green, head, cwd=None):
    """The first-parent commits after the last green build up to head, oldest first.

    Without a green ancestor (no green build yet, or one off this history) only
    head is named, and the second value says the range is unknown.
    """
    known = green is not None and subprocess.run(
        ["git", "merge-base", "--is-ancestor", green, head], cwd=cwd, capture_output=True).returncode == 0
    span = [f"{green}..{head}"] if known else ["-1", head]
    log = git("log", "--first-parent", "--reverse", "--format=%H%x1f%s", *span, cwd=cwd)
    commits = []
    for line in log.splitlines():
        sha, subject = line.split("\x1f", 1)
        number = PR_NUMBER.search(subject)
        commits.append(Commit(sha, subject, int(number[1]) if number else None))
    return commits, known


def decide(result, issue):
    """What a finished build does to the open issue: create, update, close or nothing."""
    if result == "failure":
        return "update" if issue is not None else "create"
    if result == "success":
        return "close" if issue is not None else "none"
    raise ValueError(f"A main build result is success or failure, not {result!r}")


def plain(text):
    """A subject cannot mention anyone in the issue."""
    return text.replace("@", "@\u200b")  # a zero-width space after each @


def named(commit):
    return f"#{commit.pr}" if commit.pr else f"`{commit.sha[:12]}`"


def render(repository, commits, known, green, head, url, failed):
    if known:
        lines = [f"The main build is red on `{head}`. PRs merged since the last green main build `{green}`, "
                 "oldest first:"]
    else:
        lines = [f"The main build is red on `{head}`. No green main build precedes it, so only its newest "
                 "commit is named:"]
    lines += [""] + [f"- {named(commit)} {plain(commit.subject)} (`{commit.sha[:12]}`)" for commit in commits]
    lines += ["", f"Latest failure: {url}"]
    if failed:
        lines += ["", "Failed jobs:", ""] + [f"- [{plain(name)}]({link})" for name, link in failed]
    guide = f"https://github.com/{repository}/blob/main/docs/agents/landing.md#ci-failures"
    lines += ["", "Each PR passed alone, so look for two of these that changed the same code; reverting the later "
              f"one is the fast fix ([CI failures]({guide})). A runner or network failure files this too: rerun "
              "the failed jobs. The next green main build closes this issue; give it a cause label when it closes.",
              "", MARKER]
    return "\n".join(lines)


def open_issue(repository):
    """The open main-build issue with the lowest number, or None."""
    rows = json.loads(gh("issue", "list", "--repo", repository, "--state", "open", "--label", LABEL,
                         "--limit", "1000", "--json", "number,body"))
    numbers = sorted(row["number"] for row in rows if MARKER in (row["body"] or ""))
    return numbers[0] if numbers else None


def last_green(repository):
    """The head SHA of the newest successful main build, or None."""
    runs = json.loads(gh("api", f"repos/{repository}/actions/workflows/{WORKFLOW}/runs"
                                "?branch=main&status=success&per_page=1"))["workflow_runs"]
    return runs[0]["head_sha"] if runs else None


def failed_jobs(repository, run_id):
    return [(job["name"], job["html_url"]) for job in run_jobs(repository, run_id)
            if job["conclusion"] in ("failure", "timed_out")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--result", required=True, help="the build job's result: success or failure")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    url = f"https://github.com/{repository}/actions/runs/{args.run_id}"
    issue = open_issue(repository)
    action = decide(args.result, issue)
    if action == "close":
        gh("issue", "close", str(issue), "--repo", repository, "--reason", "completed",
           "--comment", f"The main build is green on `{args.sha}`: {url}")
    elif action in ("create", "update"):
        green = last_green(repository)
        commits, known = crossing(green, args.sha)
        body = render(repository, commits, known, green, args.sha, url, failed_jobs(repository, args.run_id))
        if action == "create":
            issue = gh("issue", "create", "--repo", repository, "--title", TITLE, "--label", LABEL,
                       "--body", body).strip()
        else:
            gh("issue", "edit", str(issue), "--repo", repository, "--body", body)
            names = ", ".join(named(commit) for commit in commits)
            gh("issue", "comment", str(issue), "--repo", repository,
               "--body", f"The main build failed again on `{args.sha}`: {url}. Merged since the last green "
                         f"build: {names}.")
    print(f"Main build {args.result}: {action}" + (f" {issue}" if issue else ""))


if __name__ == "__main__":
    main()
