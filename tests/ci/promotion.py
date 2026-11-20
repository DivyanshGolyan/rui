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
import select_tests
import steps

# Manual bisect replays stop starting after this much time, shared by the step's replays.
# The Promote 38-45 window's slowest find landed at 80 minutes (its last replay started at 66), so 90 leaves room for a slower runner.
BISECT_CAP_SECONDS = 90 * 60
# The line prefixes the issue filer attaches to a failure (report_issue.py reads both).
BISECT_PREFIX = "Promotion bisect: "
SUSPECT_PREFIX = "Promotion suspects: "
TOP_SUSPECTS = 5
# What a batch commit can touch that the selector reads: the sources, tests and build the target graph is made of.
SNAPSHOT = ("src", "tests", "build", "build.zig", "build.zig.zon")
TIER_LABELS = {select_tests.DIRECT: "tier a (own source)", select_tests.GRAPH: "tier b (import or rule)",
               select_tests.BROAD: "tier c (fallback)"}


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


def rank(targets, entries, limit=TOP_SUSPECTS):
    """The batch's commits that select one of `targets`, most direct first, newer first within a tier.

    `entries` run oldest first; each is {"sha", "subject", "paths": {path: {target: tier}}}, where a path's
    map holds the tier at which the selector reaches each target that path changes (select_tests.attribute).
    Returns dicts with the commit's tier and the touched paths that reach a target at that tier.
    """
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
        if best is not None:
            ranked.append(dict(sha=entry["sha"], subject=entry["subject"], tier=best,
                               files=sorted(files), position=position))
    ranked.sort(key=lambda suspect: (suspect["tier"], -suspect["position"]))
    return ranked[:limit]


def pull_request(subject):
    match = re.search(r"\(#(\d+)\)\s*$", subject)
    return f"PR #{match[1]}" if match else "no PR number in the subject"


def suspect_lines(name, targets, ranked, size):
    """The `Promotion suspects:` lines for one failed step; the issue filer copies each one."""
    if size == 0:
        return [f"{SUSPECT_PREFIX}{name}: no commits between the base and head, so nothing to rank"]
    if not targets:
        return [f"{SUSPECT_PREFIX}{name}: not a selector target, so no batch commit can be ranked; read the failed step's log"]
    if not ranked:
        return [f"{SUSPECT_PREFIX}{name}: none of the {size} batch commits selects {', '.join(targets)}; "
                "read the failed step's log"]
    return [f"{SUSPECT_PREFIX}{name}: {number}. {suspect['sha']} {pull_request(suspect['subject'])}, "
            f"{TIER_LABELS[suspect['tier']]}: {suspect['subject']}; touched {', '.join(suspect['files'])}"
            for number, suspect in enumerate(ranked, 1)]


def snapshot_attribution(sha):
    """One batch commit's entry for rank(): the selector's reach of each path the commit changes, at its tree."""
    paths, parent = select_tests.changed_paths(f"{sha}^1", sha)
    subject = git("log", "-1", "--format=%s", sha)
    entry = dict(sha=sha, subject=subject, paths={})
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
        try:
            graph = select_tests.Graph(names, read)
            available = set(build_files.steps(root))
            literals = select_tests.fixture_literals_of(graph, read)
            entry["paths"] = {path: select_tests.attribute(path, graph, available, read, contents=contents,
                                                           fixture_literals=literals)
                              for path in paths}
        except (ValueError, AttributeError, IndexError) as error:
            # The selector cannot read this commit (an unknown import, or a tree without the functional cores the
            # graph reads, as before logic_tests.zig): any target may hide behind it, so each is a broad suspect.
            print(f"{SUSPECT_PREFIX}note: the selector cannot read {sha} ({error!r}); every target is a broad suspect")
            every = {target: select_tests.BROAD for target in available}
            entry["paths"] = {path: dict(every) for path in paths}
    return entry


def excerpt_lines(name, failed):
    excerpt = failed.get("excerpt") or []
    if not excerpt:
        return []
    return [f"--- {name}: last {len(excerpt)} lines of the failed step's output ---", *excerpt, "--- end of excerpt ---"]


def suspect_report(failed, entries):
    """Every line the suspects report prints for the recorded failed steps, given the batch's entries (oldest first)."""
    if not failed:
        return [f"{SUSPECT_PREFIX}no recorded step failed, so there is nothing to rank; read the job's failed step"]
    lines = []
    for failure in failed:
        targets = targets_of(failure["name"])
        lines += suspect_lines(failure["name"], targets, rank(targets, entries), len(entries))
        lines += excerpt_lines(failure["name"], failure)
    return lines


def suspects(base, head, failed_path):
    failed = steps.failures(failed_path) if failed_path else []
    entries = []
    if failed:
        fetch(base, head)
        entries = [snapshot_attribution(sha) for sha in batch(base, head)]
    print("\n".join(suspect_report(failed, entries)))


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


def bisect_steps(failed, commits, base, head, replay, deadline, clock=time.monotonic):
    """Bisect each failed step in turn; all of them share one deadline.

    `replay(index, step, sha)` runs the step's command at `sha` and returns whether it passed.
    Returns the per-step results and their verdict lines.
    """
    results, lines = [], []
    for index, step in enumerate(failed):
        result = bisect(commits, base, lambda sha: replay(index, step, sha), deadline=deadline, clock=clock)
        result.update(step=step["name"], argv=step["argv"])
        results.append(result)
        lines.append(f"{BISECT_PREFIX}{step['name']}: {describe(result, base, head)}")
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

    deadline = time.monotonic() + BISECT_CAP_SECONDS
    try:
        results, lines = bisect_steps(failed, commits, base, head, replay, deadline)
    finally:
        git("checkout", "--quiet", "--force", "--detach", head)
    verdict = dict(base=base, head=head, batch=len(commits), steps=results)
    (logs / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
    print("\n".join(lines))
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as output:
            print("\n" + "\n".join(lines) + "\n", file=output)


def manual_steps(step_name):
    """The failed step a manual bisect replays: its command as run_selected.py would run it."""
    from run_selected import command  # run_selected imports the issue filer, which imports this module
    return [dict(name=step_name, argv=command(targets_of(step_name)))]


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
    args = parser.parse_args()
    if args.command == "suspects":
        suspects(args.base, args.head, args.failed)
    else:
        manual_bisect(args.base, args.head, args.step, args.logs)


if __name__ == "__main__":
    sys.exit(main())
