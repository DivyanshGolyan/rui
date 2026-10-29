#!/usr/bin/env python3
"""File each CI failure under its cause: one issue per signature, reopened when it recurs.

A cause is a signature: the failing fixture and its raising line, a Zig test,
or a gate's own error, read from the jobs' full logs. Each signature has one
`ci-red` issue that recurrences comment on. A later green run never closes it;
the commit that fixes the fixture or its owner says `Fixes #N`, and a failure
after that reopens the issue.
"""
import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import subprocess
import time

from run_selected import RETRIED

LABEL = "ci-red"
STATE = re.compile(r"<!-- ci-signature: (\{.*?\}) -->")
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ", re.M)
# The fixture is the first script after the case name, past any `env VAR=…` wrapper.
FIXTURE = re.compile(r'^\s*run_case \S+ (\S+) [^\n]*?"\$directory/([^"]+)"', re.M)
RECORD = re.compile(r"^([a-z0-9-]+) (passed|failed): exit=\d+.*$", re.M)
# Zig's line for a failed build step; a standalone gate names its script here.
COMMAND = re.compile(r"^failed command: (.+)$", re.M)
SCRIPT = re.compile(r"tests/integration/[\w./-]+\.py")
ZIG_CRASH = re.compile(r"^error: '(.+?)' (terminated with signal \w+|failed)", re.M)
# A failing assertion can print its diagnostics between the test's name and its
# FAIL record; the record never lies past the next numbered test.
ZIG_FAIL = re.compile(r"^\d+/\d+ (\S[^\n]*?)\.\.\.(?:(?!\n\d+/\d+ ).)*?FAIL \((\w+)\)$", re.M | re.S)
GATE = re.compile(r"^([a-z][\w-]*(?: [\w-]+)*) gate failed: (.+)$", re.M)
CARETS = re.compile(r"[\s~^]+")
FRAME = re.compile(r'^  File "([^"]+)", line \d+, in \S+$')
# check.yml's linux and macos aggregates only require their needs' results; a
# suite's failure fails them too, and the suite's own log carries the cause.
AGGREGATE_STEP = "Require every selected "
# Seconds before each repeated log download; a log can lag its job's completion.
LOG_RETRY_DELAYS = (10, 30)


@dataclass
class Cause:
    signature: str
    paths: list = field(default_factory=list)
    detail: str = ""


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def untimed(log):
    """Drop the BOM and the timestamp GitHub prefixes to every log line."""
    return STAMP.sub("", log.lstrip("﻿"))


def fixtures(check_sh=Path("tests/integration/check.sh")):
    """The integration driver's case names mapped to their fixture paths."""
    return {name: f"tests/integration/{script}" for name, script in FIXTURE.findall(check_sh.read_text())}


def tracebacks(log):
    """Each Python traceback as (frames of (file, source statement), exception line)."""
    lines = log.splitlines()
    for start, line in enumerate(lines):
        if line != "Traceback (most recent call last):":
            continue
        frames, index = [], start + 1
        while index < len(lines) and (frame := FRAME.match(lines[index])):
            index += 1
            # The whole statement, so assertions sharing a first line stay
            # distinct; caret markers are dropped.
            source = []
            while index < len(lines) and lines[index].startswith("    "):
                if not CARETS.fullmatch(lines[index]):
                    source.append(lines[index].strip())
                index += 1
            frames.append((frame[1], " ".join(source)))
        if frames and index < len(lines) and lines[index][:1] not in ("", " "):
            yield frames, lines[index]


def zig_paths(test):
    """The one source file whose name is the test's module, or none if ambiguous."""
    matches = sorted(Path("src").rglob(test.split(".", 1)[0] + ".zig"))
    return [str(matches[0])] if len(matches) == 1 else []


def raising_line(parsed, path):
    """The last traceback's deepest source line inside the fixture, with its exception."""
    found = None
    for frames, error in parsed:
        inside = [code for file, code in frames if file.endswith("/" + path)]
        if inside:
            found = inside[-1], error
    return found


def case_output(log, records, index):
    """The output check.sh printed for one case.

    A batch case's record precedes its log; a serial case's output precedes its
    record. The span before a record belongs to the previous case in a batch,
    so it is read only when that case runs a different fixture.
    """
    record = records[index]
    after = log[record.end():records[index + 1].start() if index + 1 < len(records) else len(log)]
    if index == 0:
        return after, log[:record.start()]
    return after, log[records[index - 1].end():record.start()]


def fixture_cause(name, path, spans):
    for span in spans:
        if raised := raising_line(list(tracebacks(span)), path):
            code, error = raised
            return Cause(f"{name}: {code} raised {error.split(':', 1)[0]}", [path], error)
    return None


def failure_causes(log, cases):
    """Every failure signature in one job's log, without repeats."""
    log = untimed(log)
    found, unparsed = [], []
    records = list(RECORD.finditer(log))
    for index, record in enumerate(records):
        name, verdict = record.groups()
        if verdict != "failed":
            continue
        path = cases.get(name)
        after, before = case_output(log, records, index)
        neighbour = cases.get(records[index - 1][1]) if index else None
        spans = (after,) if neighbour == path else (after, before)
        cause = fixture_cause(name, path, spans) if path else None
        if cause:
            found.append(cause)
        else:
            unparsed.append(Cause(f"{name}: exit without a parsed traceback", [path] if path else []))
    # A gate build.zig runs directly, without check.sh's records.
    for command in COMMAND.findall(log):
        if "check.sh" in command or not (script := SCRIPT.search(command)):
            continue
        path = script[0]
        name = Path(path).stem
        cause = fixture_cause(name, path, (log,))
        found.append(cause or Cause(f"{name}: exit without a parsed traceback", [path]))
    for crash in ZIG_CRASH.finditer(log):
        test, how = crash.groups()
        # The test's stderr follows, indented: the failed expectation, then the panic.
        following = log[crash.end():].split("\n")[1:4]
        detail = "\n".join(line.strip() for line in following if line.startswith("  "))
        found.append(Cause(f"zig test '{test}' {how}", zig_paths(test), detail))
    for test, error in ZIG_FAIL.findall(log):
        found.append(Cause(f"zig test '{test}' failed ({error})", zig_paths(test)))
    for gate, message in GATE.findall(log):
        found.append(Cause(f"{gate} gate failed: {message}"))
    # A record the logs explain elsewhere (a Zig binary's case) adds nothing.
    found += [cause for cause in unparsed if cause.paths or not found]
    unique = {}
    for cause in found:
        unique.setdefault(cause.signature, cause)
    return list(unique.values())


def signature_state(body):
    match = STATE.search(body or "")
    return json.loads(match[1]) if match else None


def render(state, detail):
    # Fenced text cannot mention people, link issues or break the markdown.
    lines = ["CI failed with this signature:", "", "~~~", state["signature"], "~~~"]
    if detail:
        lines += ["", "~~~", detail, "~~~"]
    paths = ", ".join(f"`{path}`" for path in state["paths"]) or "none known"
    lines += ["", f"Fixture or test paths: {paths}. Close this with `Fixes #N` in the commit that "
                  "fixes the fixture or its owner; a later green run alone does not fix it.",
              "", f"<!-- ci-signature: {json.dumps(state, sort_keys=True)} -->"]
    return "\n".join(lines)


def known_issues(repository):
    rows = json.loads(gh("issue", "list", "--repo", repository, "--state", "all", "--label", LABEL,
                         "--limit", "1000", "--json", "number,state,body"))
    return [(row["number"], row["state"], state) for row in rows if (state := signature_state(row["body"]))]


def file_cause(repository, issues, cause, workflow, sha, url, retried, labels):
    """Comment on the signature's issue, reopening it after a claimed fix, or open one."""
    seen = "passed only on its automatic retry after failing" if retried else "failed"
    note = f"{workflow} {seen} on `{sha}`: {url}"
    # Prefer the open issue, then the newest closed one.
    matches = sorted((row for row in issues if row[2]["signature"] == cause.signature),
                     key=lambda row: (row[1] == "OPEN", row[0]))
    if matches:
        number, state, recorded = matches[-1]
        recorded.update(last_sha=sha, workflows=sorted({*recorded["workflows"], workflow}))
        # A signature Daily Mac or a landing retry filed first still gains this
        # run's labels, such as stable-red.
        gh("issue", "edit", str(number), "--repo", repository, "--body", render(recorded, cause.detail),
           *(arg for label in labels for arg in ("--add-label", label)))
        if state != "OPEN":
            gh("issue", "reopen", str(number), "--repo", repository)
            issues[issues.index(matches[-1])] = (number, "OPEN", recorded)
            note = f"Failed again after its fix. {note}"
        gh("issue", "comment", str(number), "--repo", repository, "--body", note)
        return number
    recorded = dict(signature=cause.signature, paths=cause.paths, workflows=[workflow], last_sha=sha)
    title = f"CI red: {cause.signature}"
    if len(title) > 200:
        title = title[:197] + "..."
    args = ["issue", "create", "--repo", repository, "--title", title,
            "--body", render(recorded, cause.detail) + f"\n\nFirst seen: {note}"]
    for label in (LABEL, *labels):
        args += ["--label", label]
    created = gh(*args).strip()
    issues.append((int(created.rsplit("/", 1)[-1]), "OPEN", recorded))
    return created


def job_log(repository, job_id):
    """A job's full log, or None after three failed downloads."""
    for delay in (*LOG_RETRY_DELAYS, None):
        try:
            return gh("api", f"repos/{repository}/actions/jobs/{job_id}/logs")
        except subprocess.CalledProcessError as failure:
            print(f"::warning::Log of job {job_id} unavailable: {(failure.stderr or '').strip()}")
        if delay is None:
            return None
        time.sleep(delay)


def run_jobs(repository, run_id):
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100"))
    return [job for page in pages for job in page["jobs"]]


def aggregate_only(job):
    """A job whose every failed step is an aggregate's check of its needs."""
    failed = [step["name"] for step in job.get("steps") or () if step.get("conclusion") == "failure"]
    return bool(failed) and all(name.startswith(AGGREGATE_STEP) for name in failed)


def job_causes(log, cases, workflow, job, failed):
    """A failed job's causes, or a passing job's retried failures; a failure always has one."""
    if log is None:
        return [Cause(f"{workflow}: job '{job['name']}' log unavailable")] if failed else []
    if not failed and RETRIED not in log:
        return []
    # A passing job's failure records all come from first attempts it retried.
    outcome = "failed" if failed else "passed on retry"
    return failure_causes(log, cases) or [Cause(f"{workflow}: job '{job['name']}' {outcome}; cause not parsed")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True, help="name recorded on each issue")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--retried-only", action="store_true",
                        help="file the failures that passing jobs retried, not failed jobs (landing tips)")
    parser.add_argument("--label", action="append", default=[])
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    url = f"https://github.com/{repository}/actions/runs/{args.run_id}"
    for label, color in ((LABEL, "B60205"), *((label, "D93F0B") for label in args.label)):
        gh("label", "create", label, "--repo", repository, "--force", "--color", color)
    issues, cases = known_issues(repository), fixtures()
    for job in run_jobs(repository, args.run_id):
        failed = job["conclusion"] in ("failure", "timed_out")
        if job["conclusion"] != "success" if args.retried_only else not failed or aggregate_only(job):
            continue
        log = job_log(repository, job["id"])
        for cause in job_causes(log, cases, args.workflow, job, failed):
            print(file_cause(repository, issues, cause, args.workflow, args.sha, url, not failed, args.label))


if __name__ == "__main__":
    main()
