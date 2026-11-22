#!/usr/bin/env python3
"""File each CI failure under its cause: one issue per signature, reopened when it recurs.

A cause is a signature: the failing fixture and its raising line, a Zig test,
or a gate's own error, read from the jobs' full logs. Each signature has one
`ci-red` issue that recurrences comment on. A later green run never closes it;
the commit that fixes the fixture or its owner says `Fixes #N`, and a failure
on a commit containing that fix reopens the issue.

Each cause also names its escape class: why the ready PR tier did not run the
failing check. The label is the record of that class. A new issue whose class a
selection rule can fix, and which had an issue in the 14 days before this run,
is flagged, since the PR tier then needs that rule.
"""
import argparse
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

from infra_cause import cause as infra_verdict, needs_log
from promotion_lines import BISECT_PREFIX, EXCERPT_PREFIX, SUSPECT_PREFIX
from collections import namedtuple

from qualification import FULL_PARTS, matrix_name


LABEL = "ci-red"
ESCAPE_LABEL = "escape:"
REPEAT_LABEL = "escape-repeat"
REPEAT_WINDOW = timedelta(days=14)
# The classes a selection rule can fix; a second issue of one of these within the window is a repeat.
FIXABLE = frozenset({"own-files", "promotion-only", "live-mysql", "macos", "upgrade"})
ESCAPE_REASONS = {
    "own-files": "the PR tier runs this target only when the diff touches its own files, so a change elsewhere skips it.",
    "promotion-only": "the PR tier never runs this target, whatever the diff touches.",
    "live-mysql": "the PR job starts no MySQL server, so a live MySQL leg runs only in Promote.",
    "macos": "the ready PR tier runs no macOS job, so Promote is the first check to run this one.",
    "upgrade": "the ready PR tier never runs the previous-release upgrade check, which tests the release executables.",
    "pr-tier": "the PR tier did run this target, so its selection or a test that fails only in combination let the failure through.",
    "cold-cache-timeout": "a cold cache takes longer than the PR tier's warm runs, so the step's time limit is reached only in Promote.",
    "unknown": "no rule places this job or target in a class, so it needs classifying by hand.",
}
# Whole-tier jobs: the renderer contracts, the release build and the cache-execution proof run only in Promote.
WHOLE_TIER_JOB = re.compile(r"\b(?:renderer|release_build) /|\bcache execution\b")
MACOS_JOB = re.compile(r"\bmacos")
UPGRADE_JOB = re.compile(r"\bupgrade \(")
# A timed-out job's cancelled steps that build or test: the cold-cache time limit.
COLD_STEP = re.compile(r"build|compile|test|run (?:required|selected)", re.IGNORECASE)
MYSQL = re.compile(r"mysql", re.IGNORECASE)
# A shard names its targets in parentheses: "linux suites (a+b)"; the check-full parts are named full-<part>.
SHARD_TARGETS = re.compile(r"\(([^()]+)\)\s*$")
PART_TARGETS = {matrix_name("check-full", part): "check-full" for part in FULL_PARTS}
FIXED_BY = re.compile(r"Fixed by ([0-9a-f]{40})\b")
STATE = re.compile(r"<!-- ci-signature: (\{.*?\}) -->")
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ", re.M)
FIXTURE = re.compile(r'^\s*run_case \S+ (\S+) [^\n]*?"\$directory/(?!host_process\.py")([^"]+)"', re.M)
RECORD = re.compile(r"^([a-z0-9-]+) (passed|failed): exit=\d+.*$", re.M)
# Zig prints "failed command:" for any step with stderr, passing or not; only an
# exit or signal line before it marks the step failed. A standalone gate names
# its script there.
COMMAND = re.compile(r"^error: process (?:exited with code \d+|terminated with signal \w+)(?: \(expected exited with code 0\))?\n"
                     r"failed command: (.+)$", re.M)
SCRIPT = re.compile(r"tests/integration/[\w./-]+\.py")
FAILED_COMMAND = re.compile(r"^failed command: (.+)$", re.M)
# A terminal launcher emits the same envelope, retaining an assertion error
# when its process supplies one instead of a signal. The name can itself
# contain a quoted failure phrase, so its closing delimiter is the last one.
ZIG_CRASH = re.compile(r"^error: '(.+)' (terminated with signal \w+|failed(?: \([\w.]+\))?)", re.M)
# A failing assertion can print its diagnostics between the test's name and its
# FAIL record; the record never lies past the next numbered test.
ZIG_FAIL = re.compile(r"^\d+/\d+ (\S[^\n]*?)\.\.\.(?:(?!\n\d+/\d+ ).)*?FAIL \((\w+)\)$", re.M | re.S)
UNITTEST = re.compile(r"^(?:ERROR|FAIL): \w+ \(([\w.]+)\)[^\n]*\n-{70}\n(.*?)(?=^[=-]{70}$|\Z)", re.M | re.S)
GATE = re.compile(r"^([a-z][\w-]*(?: [\w-]+)*) gate failed: (.+)$", re.M)
WHITESPACE = re.compile(r"^([^\s:][^:\n]*):\d+: (trailing whitespace|new blank line at EOF|space before tab in indent|"
                        r"indent with spaces|tab in indent|leftover conflict marker)\.$", re.M)
WHITESPACE_PATHS = 10
CARETS = re.compile(r"[\s~^]+")
FRAME = re.compile(r'^  File "([^"]+)", line \d+, in \S+$')
# An aggregate's own steps: its requirement, and the explain step that names its failed jobs (failure_cause.py explain),
# which exits non-zero whenever it names one. Either failing alone means the aggregate only reports its needs.
AGGREGATE_STEPS = ("Require every selected ", "Name each failed job and its cause")
# The lines a promotion step writes for its failure: its suspects, any manual bisect verdict and its output excerpt.
PROMOTION_LINE = re.compile(rf"^(?:{re.escape(SUSPECT_PREFIX)}|{re.escape(BISECT_PREFIX)}|{re.escape(EXCERPT_PREFIX)}).+$",
                            re.M)
# A job with no parsed cause shows this many trailing log lines, unless its log already carries an excerpt.
UNPARSED_TAIL_LINES = 40
# The runner's own error line that ends a failed step; the fallback tail ends there, not in later cleanup steps.
STEP_EXIT = "##[error]Process completed with exit code"
# GitHub refuses an issue body over 65536 characters, so a detail keeps lines and total length well under it.
DETAIL_LINE_WIDTH = 400
DETAIL_CHARS = 30000
TRUNCATED = "... (truncated; the run's log has the rest)"
ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# Seconds before each repeated log download; a log can lag its job's completion.
LOG_RETRY_DELAYS = (10, 30)


@dataclass
class Cause:
    signature: str
    paths: list = field(default_factory=list)
    detail: str = ""
    zig_test: str = ""
    python_test: str = ""
    zig_binary: str = ""
    escape: str = ""


def gh(*args):
    try:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as error:
        # Older gh releases print escaped output without this newer opt-in.
        if "--allow-escape-sequences" not in args or "unknown flag: --allow-escape-sequences" not in (error.stderr or ""):
            raise
        return subprocess.run(["gh", *(arg for arg in args if arg != "--allow-escape-sequences")],
                              check=True, capture_output=True, text=True).stdout


def untimed(log):
    return STAMP.sub("", log.lstrip("﻿"))


def fixture_path(script):
    path = Path(os.path.normpath(script))
    return path.as_posix() if path.is_relative_to("tests/integration") else None


def fixtures(check_sh=Path("tests/integration/check.sh")):
    return {name: path for name, script in FIXTURE.findall(check_sh.read_text())
            if (path := fixture_path(f"tests/integration/{script}"))}


def tracebacks(log):
    lines = log.splitlines()
    for start, line in enumerate(lines):
        if line != "Traceback (most recent call last):":
            continue
        frames, index = [], start + 1
        while index < len(lines) and (frame := FRAME.match(lines[index])):
            index += 1
            source = []
            while index < len(lines) and lines[index].startswith("    "):
                if not CARETS.fullmatch(lines[index]):
                    source.append(lines[index].strip())
                index += 1
            frames.append((frame[1], " ".join(source)))
        if frames and index < len(lines) and lines[index][:1] not in ("", " "):
            yield frames, lines[index]


def zig_paths(test):
    module = re.split(r"\.(?:decltest|test)\.", test, maxsplit=1)[0]
    if "." in module:
        path = Path("src", module.replace(".", "/") + ".zig")
        if path.is_file():
            return [str(path)]
    matches = sorted(Path("src").rglob(module.split(".", 1)[0] + ".zig"))
    return [str(matches[0])] if len(matches) == 1 else []


def zig_binary(log, start):
    command = FAILED_COMMAND.search(log, start)
    if command is None or RECORD.search(log, start, command.start()):
        return ""
    previous = [match.end() for match in FAILED_COMMAND.finditer(log, 0, start)]
    previous += [match.end() for match in RECORD.finditer(log, 0, start)]
    lower = max(previous, default=0)
    diagnostics = list(ZIG_CRASH.finditer(log, lower, command.start()))
    diagnostics += list(ZIG_FAIL.finditer(log, lower, command.start()))
    if len(diagnostics) != 1:
        return ""
    try:
        words = shlex.split(command[1])
    except ValueError:
        return ""
    return Path(words[0]).name if words else ""


def raising_line(parsed, path):
    own = tuple("/" + name for name in (path, re.sub(r"_integration\.py$", "_cases.py", path)))
    found = None
    for frames, error in parsed:
        inside = [code for file, code in frames if file.endswith(own)]
        if inside:
            found = inside[-1], error
    return found


def case_output(log, records, index):
    record = records[index]
    after = log[record.end():records[index + 1].start() if index + 1 < len(records) else len(log)]
    if index == 0:
        return after, log[:record.start()]
    return after, log[records[index - 1].end():record.start()]


def fixture_cause(path, spans):
    for span in spans:
        if raised := raising_line(list(tracebacks(span)), path):
            code, error = raised
            return Cause(f"{path}: {code} raised {error.split(':', 1)[0]}", [path], error)
    return None


def failure_causes(log, cases, keep_unexplained=False):
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
        cause = fixture_cause(path, spans) if path else None
        if cause:
            found.append(cause)
        else:
            unparsed.append(Cause(f"{path or name}: exit without a parsed traceback", [path] if path else []))
    for command in COMMAND.findall(log):
        if "check.sh" in command or not (script := SCRIPT.search(command)):
            continue
        if path := fixture_path(script[0]):
            found.append(fixture_cause(path, (log,)) or Cause(f"{path}: exit without a parsed traceback", [path]))
    for crash in ZIG_CRASH.finditer(log):
        test, how = crash.groups()
        following = log[crash.end():].split("\n")[1:4]
        detail = "\n".join(line.strip() for line in following if line.startswith("  "))
        found.append(Cause(f"zig test '{test}' {how}", zig_paths(test), detail, zig_test=test, zig_binary=zig_binary(log, crash.end())))
    for failure in ZIG_FAIL.finditer(log):
        test, error = failure.groups()
        found.append(Cause(f"zig test '{test}' failed ({error})", zig_paths(test), zig_test=test,
                           zig_binary=zig_binary(log, failure.end())))
    for test, output in UNITTEST.findall(log):
        modules = sorted(Path("tests").rglob(test.split(".", 1)[0] + ".py"))
        paths = [str(modules[0])] if len(modules) == 1 else []
        raised = raising_line(list(tracebacks(output)), paths[0]) if paths else None
        failure = f"{raised[0]} raised {raised[1].split(':', 1)[0]}" if raised else "failed"
        found.append(Cause(f"python test '{test}': {failure}", paths, raised[1] if raised else "", python_test=test))
    for gate, message in GATE.findall(log):
        found.append(Cause(f"{gate} gate failed: {message}"))
    if problems := WHITESPACE.findall(log):
        paths = sorted({path for path, _ in problems})
        detail = "\n".join(f"{path}: {kind}" for path, kind in problems[:5])
        found.append(Cause("whitespace check (git diff --check) failed", paths[:WHITESPACE_PATHS],
                           f"{len(problems)} problems in {len(paths)} files, first:\n{detail}"))
    found += [cause for cause in unparsed if keep_unexplained or cause.paths or not found]
    unique = {}
    for cause in found:
        unique.setdefault((cause.signature, cause.zig_binary), cause)
    return list(unique.values())


def compile_targets(log):
    lines = untimed(log).splitlines()
    for index in range(len(lines) - 1, -1, -1):
        line = lines[index]
        if line.startswith("zig build ci-build "):
            for arg in shlex.split(line):
                if arg.startswith("-Dci-targets="):
                    return arg.partition("=")[2].split(",")
        if line.strip().startswith("TARGETS: "):
            value = "\n".join(lines[index:]).lstrip().removeprefix("TARGETS: ")
            try:
                targets, _ = json.JSONDecoder().raw_decode(value)
            except ValueError:
                continue
            if isinstance(targets, list) and all(isinstance(target, str) for target in targets):
                return targets
    return []


def signature_state(body):
    match = STATE.search(body or "")
    return json.loads(match[1]) if match else None


def bounded(detail):
    lines = [line if len(line) <= DETAIL_LINE_WIDTH else line[:DETAIL_LINE_WIDTH] + " ..."
             for line in detail.splitlines()]
    text = "\n".join(lines)
    return text if len(text) <= DETAIL_CHARS else text[:DETAIL_CHARS].rsplit("\n", 1)[0] + "\n" + TRUNCATED


def fenced(text):
    """Text inside a tilde fence longer than any tilde run it holds, so log text cannot close it."""
    fence = "~" * max(3, 1 + max((len(run) for run in re.findall(r"~+", text)), default=0))
    return [fence, text, fence]


def render(state, detail, escape=""):
    lines = ["CI failed with this signature:", "", *fenced(state["signature"])]
    if detail:
        lines += ["", *fenced(bounded(detail))]
    paths = ", ".join(f"`{path}`" for path in state["paths"]) or "none known"
    lines += ["", f"Fixture or test paths: {paths}. Close this with `Fixes #N` in the commit that "
                  "fixes the fixture or its owner; a later green run alone does not fix it."]
    if escape:
        lines += ["", f"Escape class: {escape}: {ESCAPE_REASONS[escape.split(':')[0]]}"]
    lines += ["", f"<!-- ci-signature: {json.dumps(state, sort_keys=True)} -->"]
    return "\n".join(lines)


def known_issues(repository):
    """Each ci-red issue as (number, state, signature state, escape class or "", created time)."""
    rows = json.loads(gh("issue", "list", "--repo", repository, "--state", "all", "--label", LABEL,
                         "--limit", "1000", "--json", "number,state,body,labels,createdAt"))
    return [(row["number"], row["state"], state,
             next((label["name"][len(ESCAPE_LABEL):] for label in row["labels"] if label["name"].startswith(ESCAPE_LABEL)), ""),
             datetime.fromisoformat(row["createdAt"].replace("Z", "+00:00")))
            for row in rows if (state := signature_state(row["body"]))]


def repeat_of(escape, issues, now):
    """The newest issue of this escape class created within REPEAT_WINDOW before now, or None.

    Only a class a selection rule can fix repeats; the class is compared whole, so a target-keyed class
    repeats only for its own target.
    """
    if not escape or escape.split(":")[0] not in FIXABLE:
        return None
    earlier = [number for number, _, _, kind, created in issues if kind == escape and now - REPEAT_WINDOW <= created]
    return max(earlier, default=None)


def ensure_labels(repository, colours):
    """Create each label a filing needs, right before the issue create or edit that uses it."""
    for label, colour in colours:
        gh("label", "create", label, "--repo", repository, "--force", "--color", colour)


def fixing_commit(repository, number):
    pages = json.loads(gh("api", f"repos/{repository}/issues/{number}/timeline?per_page=100",
                          "--paginate", "--slurp"))
    fix = None
    for event in (event for page in pages for event in page):
        named = FIXED_BY.match(event.get("body") or "") if event.get("event") == "commented" else None
        if event.get("event") == "closed" and event.get("commit_id"):
            fix = event["commit_id"]
        elif named:
            fix = named[1]
    return fix


def contains(repository, sha, ancestor):
    status = json.loads(gh("api", f"repos/{repository}/compare/{ancestor}...{sha}"))["status"]
    return status in ("ahead", "identical")


def file_cause(repository, issues, cause, workflow, sha, url, labels, now, prior):
    """File one cause. `issues` grows with this run's new issues; `prior` is the issue list before the run's jobs."""
    note = f"{workflow} failed on `{sha}`: {url}"
    matches = sorted((row for row in issues if row[2]["signature"] == cause.signature),
                     key=lambda row: (row[1] == "OPEN", row[0]))
    if matches:
        number, state, recorded, kind, created = matches[-1]
        fix = state != "OPEN" and fixing_commit(repository, number)
        if fix and not contains(repository, sha, fix):
            gh("issue", "comment", str(number), "--repo", repository,
               "--body", f"{note}. This predates its fix `{fix}`, so the issue stays closed.")
            return number
        recorded.update(last_sha=sha, workflows=sorted({*recorded["workflows"], workflow}))
        ensure_labels(repository, [(label, "D93F0B") for label in labels])
        # The body's class is the issue's label, so a hand-relabelled issue keeps its own class.
        gh("issue", "edit", str(number), "--repo", repository, "--body", render(recorded, cause.detail, kind),
           *(arg for label in labels for arg in ("--add-label", label)))
        if state != "OPEN":
            gh("issue", "reopen", str(number), "--repo", repository)
            issues[issues.index(matches[-1])] = (number, "OPEN", recorded, kind, created)
            note = f"Failed again after its fix. {note}"
        gh("issue", "comment", str(number), "--repo", repository, "--body", note)
        return number
    recorded = dict(signature=cause.signature, paths=cause.paths, workflows=[workflow], last_sha=sha)
    title = f"CI red: {cause.signature}"
    if len(title) > 200:
        title = title[:197] + "..."
    repeat = repeat_of(cause.escape, prior, now)
    escape_labels = [f"{ESCAPE_LABEL}{cause.escape}"] if cause.escape else []
    escape_labels += [REPEAT_LABEL] if repeat else []
    ensure_labels(repository, [(LABEL, "B60205"), *((label, "D93F0B") for label in labels),
                               *((label, "FBCA04" if label.startswith(ESCAPE_LABEL) else "D93F0B") for label in escape_labels)])
    args = ["issue", "create", "--repo", repository, "--title", title,
            "--body", render(recorded, cause.detail, cause.escape) + f"\n\nFirst seen: {note}"]
    for label in (LABEL, *labels, *escape_labels):
        args += ["--label", label]
    created = gh(*args).strip()
    number = int(created.rsplit("/", 1)[-1])
    issues.append((number, "OPEN", recorded, cause.escape, now))
    if repeat:
        gh("issue", "comment", str(number), "--repo", repository,
           "--body", f"Second {cause.escape} escape in 14 days (#{repeat}): add a narrow select_tests rule (see #1965 unit 2)")
    return created


def job_log(repository, job_id):
    for delay in (*LOG_RETRY_DELAYS, None):
        try:
            return gh("api", "--allow-escape-sequences", f"repos/{repository}/actions/jobs/{job_id}/logs")
        except subprocess.CalledProcessError as failure:
            print(f"::warning::Log of job {job_id} unavailable: {(failure.stderr or '').strip()}")
        if delay is None:
            return None
        time.sleep(delay)


def run_jobs(repository, run_id, attempt=None):
    suffix = f"/attempts/{attempt}" if attempt is not None else ""
    pages = json.loads(gh("api", "--paginate", "--slurp",
                          f"repos/{repository}/actions/runs/{run_id}{suffix}/jobs?per_page=100"))
    return [job for page in pages for job in page["jobs"]]


def failed_steps(job):
    return [step["name"] for step in job.get("steps") or () if step.get("conclusion") == "failure"]


def aggregate_only(job):
    failed = failed_steps(job)
    return bool(failed) and all(name.startswith(AGGREGATE_STEPS) for name in failed)


def annotations(repository, job):
    try:
        notes = json.loads(gh("api", f"repos/{repository}/check-runs/{job['id']}/annotations"))
    except subprocess.CalledProcessError:
        return []
    return [note["message"] for note in notes]


def cause_target(cause, fixture_targets, shard):
    """The target a cause names: its zig test binary, or the fixture whose file it failed in; "" when neither.

    A file the fixture table does not name (mysql_wire_integration.py) names the shard target of its stem.
    """
    if cause.zig_binary:
        return cause.zig_binary
    for path in cause.paths:
        if path in fixture_targets:
            return fixture_targets[path]
        stem = Path(path).stem.replace("_", "-")
        if stem in shard:
            return stem
    return ""


def shard_targets(job):
    """The targets a job's shard names, in order; a whole-tier job names none."""
    named = SHARD_TARGETS.search(job["name"])
    return [PART_TARGETS.get(token, token) for token in named[1].split("+")] if named else []


EscapeOwners = namedtuple("EscapeOwners", "own_files unit_roots promotion_only live_mysql fixtures")


def escape_owners():
    """The selection owners the classifier reads. Imported here: select_tests reads the repository when it loads."""
    from select_tests import FIXTURES, PR_OWN_FILE_TARGETS, PR_UNIT_ROOTS, PROMOTION_ONLY_TARGETS, tree_graph
    return EscapeOwners(own_files=PR_OWN_FILE_TARGETS, unit_roots=PR_UNIT_ROOTS, promotion_only=PROMOTION_ONLY_TARGETS,
                        live_mysql=frozenset(tree_graph().live_mysql), fixtures=frozenset(FIXTURES))


def target_class(target, leg, owners):
    """The class of one target: what keeps the PR tier from running it, or the tier that does.

    A unit root the PR tier always runs is pr-tier even where promotion's core also lists it (test-logic).
    """
    if target in owners.own_files:
        return f"own-files:{target}"
    if leg:
        return f"live-mysql:{target}"
    if target in owners.unit_roots:
        return "pr-tier"
    if target in owners.promotion_only:
        return f"promotion-only:{target}"
    if target in owners.live_mysql:
        return f"live-mysql:{target}"
    if target in owners.fixtures:
        return "pr-tier"
    return "unknown"


def escape_class(job, cause, owners, fixture_targets):
    """Why the ready PR tier did not run a failed job's cause: its class label, without the escape prefix."""
    steps = job.get("steps") or ()
    timed = job.get("conclusion") == "timed_out" or any(step.get("conclusion") == "cancelled" for step in steps)
    stopped = [step["name"] for step in steps if step.get("conclusion") == "cancelled"] if timed else failed_steps(job)
    if timed and any(COLD_STEP.search(name) for name in stopped):
        return "cold-cache-timeout"
    if UPGRADE_JOB.search(job["name"]):
        return "upgrade"
    if MACOS_JOB.search(job["name"]):
        return "macos"
    if WHOLE_TIER_JOB.search(job["name"]):
        return "promotion-only"
    # The cause's text without the job's own name, which an unparsed signature carries.
    text = [cause.signature.replace(job["name"], ""), *cause.paths, cause.zig_test, cause.python_test, cause.zig_binary, *stopped]
    leg = any(MYSQL.search(part) for part in text)
    # A named target counts when the job's shard lists it, or the job lists none; a binary or fixture the shard
    # does not list (unit-store-tests in check-full) leaves the shard's own targets to classify.
    shard = shard_targets(job)
    named = cause_target(cause, fixture_targets, shard)
    targets = [named] if named and (not shard or named in shard) else shard
    classes = {target_class(target, leg, owners) for target in targets} if targets else {"unknown"}
    if len(classes) == 1:
        return classes.pop()
    if leg:
        return "live-mysql"
    return "unknown"


def unparsed_cause(log, workflow, job):
    """A signature naming the failed step, so it stays stable across runs; the log's tail says what happened."""
    # A timed-out job marks the step it stopped in cancelled, not failed.
    failed = failed_steps(job) or [step["name"] for step in job.get("steps") or ()
                                   if step.get("conclusion") == "cancelled"]
    where = (f"failed at step{'s' if len(failed) > 1 else ''} " + ", ".join(f"'{name}'" for name in failed)
             if failed else "failed with no failed step recorded")
    text = untimed(log)
    excerpted = any(line.startswith(EXCERPT_PREFIX) for line in text.splitlines())
    lines = text.splitlines()
    end = next((index + 1 for index, line in enumerate(lines) if line.startswith(STEP_EXIT)), len(lines))
    tail = "" if excerpted else "\n".join(ESCAPE.sub("", line) for line in lines[max(0, end - UNPARSED_TAIL_LINES):end])
    return Cause(f"{workflow}: job '{job['name']}' {where}", detail=tail)


def job_causes(log, cases, workflow, job):
    """A job's causes, each with the promotion lines that locate it attached to its detail."""
    if log is None:
        return [Cause(f"{workflow}: job '{job['name']}' log unavailable")]
    causes = failure_causes(log, cases) or [unparsed_cause(log, workflow, job)]
    verdicts = PROMOTION_LINE.findall(untimed(log))
    if verdicts:
        scope = ([f"The job '{job['name']}' failed with {len(causes)} causes; each line above locates one "
                  "failed step, and a step with several causes names only its earliest."]
                 if len(causes) > 1 else [])
        for cause in causes:
            cause.detail = "\n".join(filter(None, (cause.detail, *verdicts, *scope)))
    return causes


def main(now=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True, help="name recorded on each issue")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--label", action="append", default=[])
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    url = f"https://github.com/{repository}/actions/runs/{args.run_id}"
    now = now or datetime.now(timezone.utc)
    issues, cases = known_issues(repository), fixtures()
    prior = list(issues)
    owners = escape_owners()
    fixture_targets = {path: name for name, path in cases.items()}
    for job in run_jobs(repository, args.run_id):
        if job["conclusion"] not in ("failure", "timed_out") or aggregate_only(job):
            continue
        log = job_log(repository, job["id"])
        infra = infra_verdict(job, annotations(repository, job), log if needs_log(job) else None)[0] == "infra"
        for cause in job_causes(log, cases, args.workflow, job):
            cause.escape = "" if infra else escape_class(job, cause, owners, fixture_targets)
            print(file_cause(repository, issues, cause, args.workflow, args.sha, url, args.label, now, prior))


if __name__ == "__main__":
    main()
