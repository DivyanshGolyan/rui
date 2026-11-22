#!/usr/bin/env python3
"""Explain a red promotion step: rank the batch's commits as its suspects, or bisect it by hand.

A promotion qualifies main HEAD against the batch since `stable`, the last
promoted release. When a job fails, `suspects` reads the job's failure record
(steps.py, run_selected.py) and ranks the batch's commits by how the selector
reaches each failed step's targets: a commit whose own source or script a
target runs ranks first, then one the selector's import, link or path rules
reach it through, then one a fallback or coverage rule alone selects. No step
is replayed. A failed step's log tail rides in the record and prints beside
the ranking.

`bisect` is the manual path: a named step's recorded command is replayed at
the batch's first-parent commits by binary search, capped at BISECT_CAP_SECONDS.
Replay output goes to files. The verdict never turns a promotion green.
"""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time

from git_command import git
import build_files
from promotion_lines import BISECT_PREFIX, EXCERPT_PREFIX, SUSPECT_PREFIX
import select_tests
import steps

# Manual bisect replays stop starting after this much time, shared by the step's replays.
# The Promote 38-45 window's slowest find landed at 80 minutes (its last replay started at 66), so 90 leaves room for a slower runner.
BISECT_CAP_SECONDS = 90 * 60
TOP_SUSPECTS = 5
# A commit the selector could not read: it stays listed, ranked after every attributed commit.
UNATTRIBUTED = "unattributed"
# What a batch commit can touch that the selector reads: the sources, tests and build the target graph is made of.
SNAPSHOT = ("src", "tests", "build", "build.zig", "build.zig.zon")
TIER_LABELS = {select_tests.DIRECT: "tier a (own source)", select_tests.GRAPH: "tier b (import or rule)",
               select_tests.BROAD: "tier c (fallback)", UNATTRIBUTED: "unattributed (the selector could not read this commit)"}


def targets_of(step_name):
    """A step's build targets: a run_selected batch names them space-separated, flags excluded."""
    return [word for word in step_name.split() if not word.startswith("-")]


def fetch(base, head):
    if git("rev-parse", "--is-shallow-repository") == "true":
        git("fetch", "--quiet", "--unshallow", "--no-tags", "origin", head)
    for sha in (base, head):
        if subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode:
            git("fetch", "--quiet", "--no-tags", "origin", sha)


def batch(base, head):
    if subprocess.run(["git", "merge-base", "--is-ancestor", base, head]).returncode:
        raise SystemExit(f"{base} is not an ancestor of {head}; the batch has no linear history")
    listed = git("rev-list", "--first-parent", "--reverse", f"{base}..{head}")
    return listed.split() if listed else []


# Words a log or a diff shares by accident: they say nothing about which commit broke a step.
GENERIC_TOKENS = frozenset({
    "error", "errors", "failed", "failure", "failures", "fails", "fail", "test", "tests", "testing", "expected",
    "actual", "output", "stdout", "stderr", "assert", "assertion", "exit", "process", "command", "replay",
    "passed", "passes", "return", "returns", "function", "import", "public", "private", "string", "value",
    "values", "none", "true", "false", "traceback", "during", "before", "after", "should", "could", "would",
    "there", "their", "which", "where", "while", "never", "always", "build", "python", "unittest", "files",
    "file", "lines", "line", "error:", "ERROR", "FAIL", "PASS", "result", "results", "status", "failing",
})
# Tokens a log excerpt or a diff line names: a source file, a path, a quoted string or an identifier.
FILE_TOKEN = re.compile(r"[A-Za-z_][\w-]*\.(?:go|zig|py|sh|ts|c|h|cjs|json|md|yml|txt)\b")
PATH_TOKEN = re.compile(r"[\w.-]+(?:/[\w.-]+)+\.\w+")
QUOTED_TOKEN = re.compile(r'"([^"\n]{5,80})"')
WORD_TOKEN = re.compile(r"[A-Za-z_]\w{4,}")
LOG_TOKENS_SHOWN = 4


# A log line that says what failed: a failing test or assertion, a panic, an error, or a file:line reference.
FAILURE_LINE = re.compile(r"FAIL|panic|[Ee]rror|assert|[Ee]xpected|Traceback|\b[\w/.-]+\.(?:go|zig|py|sh|cjs|ts):\d+")
# A name a log shares with the code that produced it: snake_case, CamelCase or a dotted or qualified name.
IDENTIFIER_TOKEN = re.compile(r"[a-z]+_\w+|[A-Z][a-z]+[A-Z]\w*|[a-z]+[A-Z]\w*|[A-Za-z_]\w*\.\w+")


def tokens_of(text):
    """The identifying tokens of a diff line, with the generic ones dropped."""
    found = set(PATH_TOKEN.findall(text)) | set(FILE_TOKEN.findall(text)) | set(QUOTED_TOKEN.findall(text))
    found |= set(WORD_TOKEN.findall(text))
    return {token for token in found if token not in GENERIC_TOKENS}


def log_tokens_of(excerpt):
    """The tokens of a failed step's excerpt that name what failed: failure lines, and identifier-shaped names.

    Plain words (a session, a build, a path segment) match nearly every commit, so only snake_case, CamelCase,
    qualified and quoted names and file names count; the excerpt's other lines are its passing output.
    """
    failing = "\n".join(line for line in excerpt if FAILURE_LINE.search(line))
    found = set(PATH_TOKEN.findall(failing)) | set(FILE_TOKEN.findall(failing)) | set(QUOTED_TOKEN.findall(failing))
    found |= set(IDENTIFIER_TOKEN.findall(failing))
    return {token for token in found if token not in GENERIC_TOKENS}


def change_tokens(patch):
    """{path: tokens} for a `git diff -U0` text: the added and removed lines of each file, and its path."""
    tokens, path = {}, None
    for line in patch.splitlines():
        if line.startswith("diff --git a/"):
            path = line.rsplit(" b/", 1)[-1]
            tokens[path] = tokens_of(path)
        elif path is not None and line[:1] in ("+", "-") and line[:3] not in ("+++", "---"):
            tokens[path] |= tokens_of(line[1:])
    return tokens


def common_tokens(entries):
    """Tokens most of the batch shares: they match every commit, so a match on one says nothing."""
    if len(entries) < 4:
        return frozenset()
    seen = {}
    for entry in entries:
        for token in set().union(*entry.get("tokens", {}).values()):
            seen[token] = seen.get(token, 0) + 1
    return frozenset(token for token, count in seen.items() if count > len(entries) / 2)


def rank(targets, entries, limit=TOP_SUSPECTS, log=frozenset()):
    """The batch's commits that a failed step points at, the most likely first.

    `entries` run oldest first; each is {"sha", "subject", "paths": {path: {target: tier}}, "tokens": {path:
    tokens}}. A path's map holds the tier at which the selector reaches each target it changes
    (select_tests.attribute); its tokens are the identifiers its added and removed lines name. `log` holds the
    identifiers of the failed step's output. A commit whose changed lines name log tokens ranks first, most
    shared tokens first; a tie falls back to the selector's tier (own source, import or rule, fallback) and
    then to newer commits. Returns dicts with the commit's tier (None when only the log points at it), the
    tokens it shares with the log, and the touched paths that the selector reaches or the log names.
    """
    shared_away = common_tokens(entries)
    log = frozenset(log) - shared_away
    ranked = []
    for position, entry in enumerate(entries):
        best, files = None, []
        for path, reaches in entry["paths"].items():
            tiers = [reaches[target] for target in targets if target in reaches]
            if not tiers:
                continue
            tier = min(tiers)
            if best is None or tier < best:
                best, files = tier, [path]
            elif tier == best:
                files.append(path)
        matched = {path: hits for path, tokens in entry.get("tokens", {}).items()
                   if (hits := (tokens & log) - shared_away)}
        shared = set().union(*matched.values()) if matched else set()
        if entry.get("error") and targets:
            best = UNATTRIBUTED
        elif best is None and not shared or entry.get("error"):
            continue
        ranked.append(dict(sha=entry["sha"], subject=entry["subject"], tier=best, log=sorted(shared),
                           files=sorted(set(files) | set(matched)), position=position))
    ranked.sort(key=lambda suspect: (suspect["tier"] == UNATTRIBUTED, 0 if suspect["log"] else 1,
                                     -len(suspect["log"]), rank_tier(suspect["tier"]), -suspect["position"]))
    return ranked[:limit]


def rank_tier(tier):
    """Where a tier sorts: the selector's tiers first, a commit with no selector tier after them."""
    return 3 if tier is None or tier == UNATTRIBUTED else tier


def pull_request(subject):
    match = re.search(r"\(#(\d+)\)\s*$", subject)
    return f"PR #{match[1]}" if match else "no PR number in the subject"


def reason(suspect):
    """Why a suspect ranks: the log tokens it shares, the selector tier it reaches, or both."""
    parts = []
    if suspect["log"]:
        shown = ", ".join(suspect["log"][:LOG_TOKENS_SHOWN])
        parts.append(f"log match on {len(suspect['log'])} token{'s' if len(suspect['log']) != 1 else ''} ({shown})")
    if suspect["tier"] is not None:
        parts.append(TIER_LABELS[suspect["tier"]])
    return ", ".join(parts) or "log match"


def suspect_lines(name, targets, ranked, size):
    """The `Promotion suspects:` lines for one failed step; the issue filer copies each one."""
    if size == 0:
        return [f"{SUSPECT_PREFIX}{name}: no commits between the base and head, so nothing to rank"]
    if not ranked and not targets:
        return [f"{SUSPECT_PREFIX}{name}: not a selector target; read its log"]
    if not ranked:
        return [f"{SUSPECT_PREFIX}{name}: none of the {size} batch commits selects {', '.join(targets)}; "
                "read the failed step's log"]
    return [f"{SUSPECT_PREFIX}{name}: {number}. {suspect['sha']} {pull_request(suspect['subject'])}, "
            f"{reason(suspect)}: {suspect['subject']}" + (f"; touched {', '.join(suspect['files'])}" if suspect["files"] else "")
            for number, suspect in enumerate(ranked, 1)]


def snapshot_attribution(sha):
    """One batch commit's entry for rank(): the selector's reach of each path the commit changes, at its tree."""
    paths, parent = select_tests.changed_paths(f"{sha}^1", sha)
    subject = git("log", "-1", "--format=%s", sha)
    patch = subprocess.run(["git", "diff", "--no-renames", "-U0", parent, sha], cwd=select_tests.ROOT, check=True,
                           capture_output=True, text=True, errors="surrogateescape").stdout
    entry = dict(sha=sha, subject=subject, paths={}, tokens=change_tokens(patch))
    if not paths:
        return entry
    with tempfile.TemporaryDirectory(prefix="promotion-snapshot-") as scratch:
        root = Path(scratch)
        listed = git("ls-tree", "--name-only", sha, cwd=select_tests.ROOT).split()
        present = [name for name in listed if name in SNAPSHOT]
        archive = subprocess.run(["git", "archive", "--format=tar", sha, *present], cwd=select_tests.ROOT,
                                 check=True, capture_output=True).stdout
        tarfile.open(fileobj=io.BytesIO(archive)).extractall(root, filter="data")

        def read(name):
            return (root / name).read_text(encoding="utf-8", errors="surrogateescape") if (root / name).is_file() else None

        names = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file())
        contents = select_tests.revision_contents(paths, parent, sha)
        entry["paths"] = attribute_paths(paths, root, names, read, contents)
    return entry


def attribute_paths(paths, root, names, read, contents):
    """{path: {target: tier}} for one commit's changed paths, read from its snapshot at `root`."""
    graph = select_tests.Graph(names, read)
    available = set(build_files.steps(root))
    literals = select_tests.fixture_literals_of(graph, read)
    return {path: select_tests.attribute(path, graph, available, read, contents=contents, fixture_literals=literals)
            for path in paths}


def attributed(shas, attribute=snapshot_attribution):
    """One entry per batch commit. A commit whose attribution raises is kept as unattributed; the report still lists the rest."""
    entries = []
    for sha in shas:
        try:
            entries.append(attribute(sha))
        except Exception as error:
            print(f"{SUSPECT_PREFIX}note: could not attribute {sha} ({error!r}); it is listed last as unattributed")
            entries.append(dict(sha=sha, subject="(subject unavailable)", paths={}, tokens={}, error=repr(error)))
    return entries


def excerpt_lines(name, failed):
    """The failed step's output tail, each line prefixed so the issue filer's parsers skip it."""
    excerpt = failed.get("excerpt") or []
    if not excerpt:
        return []
    return [f"{EXCERPT_PREFIX}{name}: last {len(excerpt)} lines of the failed step's output:",
            *(f"{EXCERPT_PREFIX}{name}: {line}" for line in excerpt),
            f"{EXCERPT_PREFIX}{name}: end of excerpt"]


def suspect_report(failed, entries, known=None):
    """Every line the suspects report prints for the recorded failed steps, given the batch's entries (oldest first).

    `known` holds the build targets at HEAD; a step name that is not one of them has no target to rank by.
    """
    if not failed:
        return [f"{SUSPECT_PREFIX}no recorded step failed, so there is nothing to rank; read the job's failed step"]
    lines = []
    for failure in failed:
        targets = [target for target in targets_of(failure["name"]) if known is None or target in known]
        log = log_tokens_of(failure.get("excerpt") or [])
        lines += suspect_lines(failure["name"], targets, rank(targets, entries, log=log), len(entries))
        lines += excerpt_lines(failure["name"], failure)
    return lines


def suspects(base, head, failed_path):
    failed = steps.failures(failed_path) if failed_path else []
    entries, known = [], None
    if failed:
        fetch(base, head)
        entries = attributed(batch(base, head))
        known = set(build_files.steps(select_tests.ROOT))
    print("\n".join(suspect_report(failed, entries, known)))


def capped(good, bad, commits, replays):
    # `good` is -1 until a batch commit passes; then the failing commit lies in commits[good+1..bad].
    return dict(verdict="capped", first=commits[good + 1], last=commits[bad], narrowed=bad - good,
                batch_passed=good >= 0, replays=replays)


def bisect(commits, base, passes, deadline=None, clock=time.monotonic):
    """Return the batch's first failing commit, or the narrowed range when the deadline stops it.

    No new replay starts once `clock()` reaches `deadline`; the caller shares one deadline across
    a job's failed steps.
    """
    if not commits:
        return dict(verdict="empty-batch", replays=[])
    replays = []

    def run(sha):
        ok = passes(sha)
        replays.append(dict(sha=sha, passed=ok))
        return ok

    def out_of_time():
        return deadline is not None and clock() >= deadline

    good, bad = -1, len(commits) - 1
    if out_of_time():
        return capped(good, bad, commits, replays)
    if run(commits[bad]):
        return dict(verdict="not-reproduced", replays=replays)
    while bad - good > 1:
        if out_of_time():
            return capped(good, bad, commits, replays)
        middle = (good + bad) // 2
        if run(commits[middle]):
            good = middle
        else:
            bad = middle
    if bad == 0:
        if out_of_time():
            return capped(good, bad, commits, replays)
        if not run(base):
            return dict(verdict="before-batch", replays=replays)
    return dict(verdict="culprit", culprit=commits[bad], replays=replays)


def capped_line(result):
    """The verdict for a bisect that the cap stopped; the issue filer copies it, so each case must hold."""
    minutes = BISECT_CAP_SECONDS // 60
    replays = result["replays"]
    if not replays:
        return f"the {minutes}-minute cap left this step unreplayed; read its log"
    count = f"{len(replays)} replay{'s' if len(replays) != 1 else ''}"
    first, last = result["first"], result["last"]
    if not result["batch_passed"]:
        # Nothing in the batch has passed yet, and stable is never replayed when the cap stops the search.
        found = f"is {first}" if first == last else f"is one of {first} to {last}"
        return (f"stopped at the {minutes}-minute cap after {count}; the first failing commit {found} "
                f"or before this batch (stable not checked)")
    return (f"stopped at the {minutes}-minute cap after {count}; the first failing commit is one of the "
            f"{result['narrowed']} commits from {first} to {last}")


def describe(result, base, head):
    verdict = result["verdict"]
    if verdict == "culprit":
        subject = git("log", "-1", "--format=%s", result["culprit"])
        return f"first fails at {result['culprit']} ({subject})"
    if verdict == "capped":
        return capped_line(result)
    return {
        "empty-batch": f"no commits between {base} and {head}",
        "not-reproduced": f"did not fail again at {head}; treat it as a flake until it recurs",
        "before-batch": f"fails at {base} too, before this batch; look at the runner or a test that depends on time",
    }[verdict]


def bisect_steps(failed, commits, base, head, replay, deadline, clock=time.monotonic, saved=None):
    """Bisect each failed step in turn; all of them share one deadline.

    `replay(index, step, sha)` runs the step's command at `sha` and returns whether it passed. `saved(results)`
    runs after each step finishes, with every result so far. Returns the per-step results and their verdict lines.
    """
    results, lines = [], []
    for index, step in enumerate(failed):
        result = bisect(commits, base, lambda sha: replay(index, step, sha), deadline=deadline, clock=clock)
        result.update(step=step["name"], argv=step["argv"])
        results.append(result)
        lines.append(f"{BISECT_PREFIX}{step['name']}: {describe(result, base, head)}")
        if saved:
            saved(results)
    return results, lines


def run_bisect(base, head, failed, logs):
    if not failed:
        print(f"{BISECT_PREFIX}no recorded step failed, so there is nothing to replay; read the job's failed step")
        return
    fetch(base, head)
    commits = batch(base, head)
    logs.mkdir(parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_STEP_SUMMARY"}

    def replay(index, step, sha):
        git("checkout", "--quiet", "--force", "--detach", sha)
        name = f"{index}-{sha}"
        replay_env = dict(env, STEP_OUTPUT=str(logs / f"{name}-output"))
        with open(logs / f"{name}.log", "w") as log:
            code = subprocess.run(step["argv"], stdout=log, stderr=subprocess.STDOUT, env=replay_env).returncode
        print(f"{step['name']}: replay at {sha}: {'passed' if code == 0 else f'failed (exit {code})'}", flush=True)
        return code == 0

    def save(results):
        verdict = dict(base=base, head=head, batch=len(commits), steps=results)
        (logs / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")

    deadline = time.monotonic() + BISECT_CAP_SECONDS
    save([])
    try:
        _, lines = bisect_steps(failed, commits, base, head, replay, deadline, saved=save)
    finally:
        git("checkout", "--quiet", "--force", "--detach", head)
    print("\n".join(lines))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            print("\n" + "\n".join(lines) + "\n", file=output)


def bisect_targets(step_name):
    """The build targets a manual bisect replays, refused unless each one is a target at HEAD.

    A step name that is not a build target (a script's step such as pty) has no `zig build` command to replay.
    """
    targets = targets_of(step_name)
    known = set(build_files.steps(select_tests.ROOT))
    unknown = [target for target in targets if target not in known]
    if not targets or unknown:
        named = ", ".join(unknown) or step_name or "(none)"
        raise SystemExit(f"bisect-step {named!r} is not a build target at HEAD, so there is no zig build command to replay; "
                         "name the selector targets the failed step ran (its space-separated targets)")
    return targets


def manual_steps(step_name):
    """The failed step a manual bisect replays: its command as run_selected.py would run it."""
    from run_selected import command  # run_selected imports the issue filer, which imports this module
    return [dict(name=step_name, argv=command(bisect_targets(step_name)))]


def manual_bisect(base, head, step_name, logs):
    run_bisect(base, head, manual_steps(step_name), logs)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    rank_parser = commands.add_parser("suspects", help="rank the batch's commits for each recorded failed step")
    rank_parser.add_argument("--base", required=True, help="last promoted commit (stable)")
    rank_parser.add_argument("--head", required=True, help="promotion candidate (main HEAD)")
    rank_parser.add_argument("--failed", type=Path, default=steps.record_path(), help="the job's failure record")
    bisect_parser = commands.add_parser("bisect", help="manual: replay one step across base..head by binary search")
    bisect_parser.add_argument("--base", required=True, help="commit the batch starts after")
    bisect_parser.add_argument("--head", required=True, help="last commit of the batch")
    bisect_parser.add_argument("--step", required=True, help="the failed step's name: its space-separated targets")
    bisect_parser.add_argument("--logs", required=True, type=Path, help="directory for each replay's output")
    targets_parser = commands.add_parser("bisect-targets", help="print a manual bisect's targets as the setup action takes them")
    targets_parser.add_argument("--step", required=True, help="the failed step's name: its space-separated targets")
    args = parser.parse_args()
    if args.command == "suspects":
        suspects(args.base, args.head, args.failed)
    elif args.command == "bisect-targets":
        print(json.dumps(bisect_targets(args.step)))
    else:
        manual_bisect(args.base, args.head, args.step, args.logs)


if __name__ == "__main__":
    sys.exit(main())
