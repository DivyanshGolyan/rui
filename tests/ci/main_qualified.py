#!/usr/bin/env python3
"""Own the `main-qualified` record: which main commits passed the full tier.

Promote (promote.yml) runs every three hours and by hand. It runs the full
qualification tier (qualification-tier.yml) on the commit it publishes when
that commit has no verdict yet, and publishes a commit with a green record from
the archives that run built and tested, without qualifying it again. Each run
records its verdict as a commit status named `main-qualified` whose target is
that run. A scheduled run skips a HEAD whose record is red, since the failing
run filed its issues under its own label (main-red or promotion-red), and fails,
naming that run, until the red is cleared.

Commands (each prints KEY=VALUE lines for $GITHUB_OUTPUT):

  choose --main SHA [--sha SHA|qualified] [--scheduled]
      Promote's commit: main HEAD, a named first-parent commit of main after
      stable, or the newest green one; with `reuse`, `run` and `version` when
      its green record's archives can still be published. A scheduled run with
      a red HEAD promotes nothing (size 0) instead of refusing, and sets
      `red_run` to the red record's run so Promote's batch job fails.
  verdict RESULT...
      The record's state for the tier job results.
  record --sha SHA --state STATE --run-id ID [--version V]
      Write the record.

Only GitHub Actions in this repository writes the record; a status from any
other creator is ignored. A red record refuses a manual publication: fix
forward and promote a later commit, or choose an earlier green one.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import os
import re
import subprocess
import sys

import git_command
from report_issue import gh

CONTEXT = "main-qualified"
CREATOR = "github-actions[bot]"
# Green records Qualify main wrote stay publishable until their archives expire (seven days).
WORKFLOWS = (".github/workflows/main-qualifier.yml", ".github/workflows/promote.yml")
PLATFORMS = ("linux-x86_64", "linux-arm64", "darwin-arm64")
# What Release publishes from a qualifying run (release-build.yml uploads them).
RELEASE_ARTIFACTS = frozenset({*(f"rui-{platform}" for platform in PLATFORMS), "rui-npm", "rui-digests"})
# Publication and its retries must finish before the archives expire.
EXPIRY_MARGIN = timedelta(hours=2)
RUN_URL = re.compile(r"/actions/runs/([1-9][0-9]*)$")
VERSION = re.compile(r"release (\S+)$")
SHA = re.compile(r"[0-9a-f]{40}")


@dataclass(frozen=True)
class Record:
    state: str
    run_id: str | None
    version: str


def git(*args):
    return git_command.git(*args)


def api(path, *fields, method="GET"):
    args = ["api", "--method", method, path]
    for key, value in fields:
        args += ["-f", f"{key}={value}"]
    return json.loads(gh(*args) or "null")


def run_of(repository, run_id, request=api):
    """The qualifying run, or None when GitHub no longer has it (HTTP 404); other errors raise."""
    try:
        return request(f"repos/{repository}/actions/runs/{run_id}")
    except subprocess.CalledProcessError as failure:
        if "HTTP 404" in (failure.stderr or ""):
            return None
        raise


def describe(state, version):
    """The status description; parse() reads the version back from it."""
    if state != "success":
        return {"failure": "Full tier failed; see the run", "error": "Not finished; the next run qualifies again",
                "pending": "Qualifying"}[state]
    return f"Qualified with release {version}" if version else "Qualified; no new release"


def parse(statuses):
    """The newest record GitHub Actions wrote among a commit's statuses, newest first."""
    for status in statuses:
        if status.get("context") != CONTEXT or (status.get("creator") or {}).get("login") != CREATOR:
            continue
        run = RUN_URL.search(status.get("target_url") or "")
        version = VERSION.search(status.get("description") or "")
        return Record(status["state"], run[1] if run else None, version[1] if version else "")
    return None


def record_of(repository, sha):
    return parse(api(f"repos/{repository}/commits/{sha}/statuses?per_page=100"))


def verdict(results):
    """Success only when every tier succeeded; any failure is red; otherwise unfinished."""
    if results and all(result == "success" for result in results):
        return "success"
    return "failure" if "failure" in results else "error"


def last_green(commits, record):
    """The newest commit, of first-parent COMMITS newest first, with a green record."""
    for sha in commits:
        found = record(sha)
        if found is not None and found.state == "success":
            return sha
    return None


def first_parent(base, head):
    """First-parent commits after BASE up to HEAD, newest first."""
    return git("rev-list", "--first-parent", f"{base}..{head}").split()


def batch_log(base, head):
    return [f"- {line}" for line in git("log", "--first-parent", "--format=%h %s", f"{base}..{head}").splitlines()]


def stable(head):
    git("fetch", "--quiet", "origin", "+refs/heads/stable:refs/remotes/origin/stable")
    floor = git("rev-parse", "origin/stable")
    if subprocess.run(["git", "merge-base", "--is-ancestor", floor, head], check=False).returncode != 0:
        raise SystemExit(f"stable {floor} is not an ancestor of {head}")
    return floor


def reusable(record, run, artifacts, planned, sha, now):
    """Why the green RECORD's archives cannot be published for SHA, or None when they can."""
    if record is None or record.state != "success":
        return "no green record"
    if run is None or run.get("head_sha") != sha or run.get("path", "").split("@")[0] not in WORKFLOWS:
        return f"run {record.run_id} is not a qualification of {sha}"
    if planned != record.version:
        return f"the release plan is now {planned or 'none'}, not {record.version or 'none'}"
    if not record.version:
        return None
    live = {artifact["name"] for artifact in artifacts if not artifact.get("expired")
            and datetime.fromisoformat(artifact["expires_at"]) > now + EXPIRY_MARGIN}
    missing = sorted(RELEASE_ARTIFACTS - live)
    return f"run {record.run_id} no longer holds {', '.join(missing)}" if missing else None


def plan(sha):
    """The version release.py would plan for SHA now, or empty when a release already includes it."""
    import release
    return release.plan(sha) or ""


def choose(main, sha, commits, record, publishable, scheduled=False):
    """Promote's commit among COMMITS after stable (newest, main first) and its green record when
    PUBLISHABLE(record, commit) finds no reason to qualify again: (commit, record or None, reason).
    A SCHEDULED run whose commit failed promotes nothing: (None, the red record, reason)."""
    if sha in ("", main):
        chosen = main
    elif sha == "qualified":
        chosen = last_green(commits, record)
        if chosen is None:
            raise SystemExit(f"no main commit after stable has a green {CONTEXT} record")
    elif SHA.fullmatch(sha) and sha in commits:
        chosen = sha
    else:
        raise SystemExit(f"{sha} is not a first-parent main commit after stable")
    if chosen not in commits:
        return chosen, None, "stable already holds it"
    own = record(chosen)
    if own is not None and own.state == "failure":
        if scheduled:
            if own.run_id is None:
                raise SystemExit(f"{chosen} failed qualification, but its {CONTEXT} record names no run")
            return None, own, (f"{chosen} failed qualification in run {own.run_id}; "
                               "the next scheduled run waits for a fix on main")
        raise SystemExit(f"{chosen} failed qualification in run {own.run_id}; fix forward and promote a later "
                         "commit, or choose an earlier green one with sha=qualified")
    reason = publishable(own, chosen) if own is not None and own.state == "success" else "no green record"
    if reason is not None and chosen != main:
        raise SystemExit(f"{chosen} cannot be published as qualified ({reason}); Promote qualifies only main HEAD")
    return chosen, own if reason is None else None, reason


def skipped(base, red):
    """Promote's outputs for a scheduled run over a red HEAD: nothing promoted, and the red record's run named."""
    return {"head": "", "base": base, "size": "0", "reuse": "false", "run": "", "version": "", "red_run": red.run_id}


def promoted(base, head, size, own):
    """Promote's outputs for a commit it publishes or qualifies: no red_run, since the head is not red."""
    outputs = {"head": head, "base": base, "size": str(size), "reuse": "false", "run": "", "version": ""}
    if own is not None:
        outputs.update(reuse="true", run=own.run_id, version=own.version)
    return outputs


def record(repository, sha, state, run_id, version):
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    api(f"repos/{repository}/statuses/{sha}", ("state", state), ("context", CONTEXT),
        ("description", describe(state, version)),
        ("target_url", f"{server}/{repository}/actions/runs/{run_id}"), method="POST")


def emit(outputs, lines):
    for line in lines:
        print(line, file=sys.stderr)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and lines:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for key, value in outputs.items():
        print(f"{key}={value}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    commands = parser.add_subparsers(dest="command", required=True)
    chosen = commands.add_parser("choose")
    chosen.add_argument("--main", required=True)
    chosen.add_argument("--sha", default="")
    chosen.add_argument("--scheduled", action="store_true")
    judged = commands.add_parser("verdict")
    judged.add_argument("results", nargs="+")
    written = commands.add_parser("record")
    written.add_argument("--sha", required=True)
    written.add_argument("--state", choices=("success", "failure", "error", "pending"), required=True)
    written.add_argument("--run-id", required=True)
    written.add_argument("--version", default="")
    args = parser.parse_args()
    repository = args.repository

    def recorded(sha):
        return record_of(repository, sha)

    if args.command == "choose":
        floor = stable(args.main)
        commits = first_parent(floor, args.main)

        def publishable(own, sha):
            run = run_of(repository, own.run_id) if own.run_id else None
            artifacts = api(f"repos/{repository}/actions/runs/{own.run_id}/artifacts?per_page=100")["artifacts"] if run else []
            return reusable(own, run, artifacts, plan(sha), sha, datetime.now(timezone.utc))

        chosen, own, reason = choose(args.main, args.sha, commits, recorded, publishable, args.scheduled)
        if chosen is None:
            emit(skipped(floor, own), [reason])
            return 0
        size = len(first_parent(floor, chosen))
        lines = [f"Promoting {size} main commits after stable {floor}, up to {chosen}:", *batch_log(floor, chosen)]
        outputs = promoted(floor, chosen, size, own)
        if not size:
            lines.append("stable already holds this commit; nothing to promote")
        elif own is not None:
            lines.append(f"{chosen} passed qualification in run {own.run_id}; publishing its archives")
        else:
            lines.append(f"Qualifying {chosen} here: {reason}")
        emit(outputs, lines)
    elif args.command == "verdict":
        print(f"state={verdict(args.results)}")
    else:
        record(repository, args.sha, args.state, args.run_id, args.version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
