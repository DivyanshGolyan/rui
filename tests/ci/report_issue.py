#!/usr/bin/env python3
import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time


LABEL = "ci-red"
FIXED_BY = re.compile(r"Fixed by ([0-9a-f]{40})\b")
STATE = re.compile(r"<!-- ci-signature: (\{.*?\}) -->")
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ", re.M)
FIXTURE = re.compile(r'^\s*run_case \S+ (\S+) [^\n]*?"\$directory/(?!host_process\.py")([^"]+)"', re.M)
RECORD = re.compile(r"^([a-z0-9-]+) (passed|failed): exit=\d+.*$", re.M)
# Zig prints "failed command:" for any step with stderr, passing or not; only an
# exit or signal line before it marks the step failed. A standalone gate names
# its script there.
COMMAND = re.compile(r"^error: process (?:exited with code \d+|terminated with signal \w+)\n"
                     r"failed command: (.+)$", re.M)
SCRIPT = re.compile(r"tests/integration/[\w./-]+\.py")
FAILED_COMMAND = re.compile(r"^failed command: (.+)$", re.M)
ZIG_CRASH = re.compile(r"^error: '(.+?)' (terminated with signal \w+|failed)", re.M)
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
AGGREGATE_STEP = "Require every selected "
BISECT = re.compile(r"^Promotion bisect: .+$", re.M)
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


def fixtures(check_sh=Path("tests/integration/check.sh")):
    return {name: f"tests/integration/{script}" for name, script in FIXTURE.findall(check_sh.read_text())}


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
        path = script[0]
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


def render(state, detail):
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


def file_cause(repository, issues, cause, workflow, sha, url, labels):
    note = f"{workflow} failed on `{sha}`: {url}"
    matches = sorted((row for row in issues if row[2]["signature"] == cause.signature),
                     key=lambda row: (row[1] == "OPEN", row[0]))
    if matches:
        number, state, recorded = matches[-1]
        fix = state != "OPEN" and fixing_commit(repository, number)
        if fix and not contains(repository, sha, fix):
            gh("issue", "comment", str(number), "--repo", repository,
               "--body", f"{note}. This predates its fix `{fix}`, so the issue stays closed.")
            return number
        recorded.update(last_sha=sha, workflows=sorted({*recorded["workflows"], workflow}))
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


def aggregate_only(job):
    failed = [step["name"] for step in job.get("steps") or () if step.get("conclusion") == "failure"]
    return bool(failed) and all(name.startswith(AGGREGATE_STEP) for name in failed)


def job_causes(log, cases, workflow, job):
    if log is None:
        return [Cause(f"{workflow}: job '{job['name']}' log unavailable")]
    return failure_causes(log, cases) or [Cause(f"{workflow}: job '{job['name']}' failed; cause not parsed")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True, help="name recorded on each issue")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--label", action="append", default=[])
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    url = f"https://github.com/{repository}/actions/runs/{args.run_id}"
    for label, color in ((LABEL, "B60205"), *((label, "D93F0B") for label in args.label)):
        gh("label", "create", label, "--repo", repository, "--force", "--color", color)
    issues, cases = known_issues(repository), fixtures()
    for job in run_jobs(repository, args.run_id):
        if job["conclusion"] not in ("failure", "timed_out") or aggregate_only(job):
            continue
        log = job_log(repository, job["id"])
        verdicts = BISECT.findall(untimed(log)) if log is not None else []
        causes = job_causes(log, cases, args.workflow, job)
        for cause in causes:
            if verdicts:
                scope = ([f"The job '{job['name']}' failed with {len(causes)} causes; each line above bisects one "
                          "failed step, and a step with several causes names only its earliest."]
                         if len(causes) > 1 else [])
                cause.detail = "\n".join(filter(None, (cause.detail, *verdicts, *scope)))
            print(file_cause(repository, issues, cause, args.workflow, args.sha, url, args.label))


if __name__ == "__main__":
    main()
