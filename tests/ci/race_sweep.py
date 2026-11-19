#!/usr/bin/env python3
"""Shake selected targets to expose latent scheduling races before CI load does.

A latent race is a test that passes only because one thread or process usually
runs before another. Two shakers, chosen after replaying five known races
(#1815, #1892, #1784, #1721, #1706):

- starve: the targets share two cores with busy loops, so every wait that is
  really a deadline runs out (#1815's class).
- stall: each run stalls one syscall at one call site by a fixed delay, chosen
  from a seed, through strace's fault injection. No code changes; it reaches Zig
  binaries, Python fixtures and their children alike (#1892's class).

Every failure prints the command that reproduces it, and `file` keeps one open
issue labelled race-sweep current, apart from main's ci-red issues. A stall run under strace
is slower than an untraced one, so confirm a failure on the fixed code and with
a deterministic replay before calling it a race.
"""
import argparse
import json
import os
import random
import shlex
import subprocess
import sys
from typing import NamedTuple

# Socket sends, plain writes, thread wake-ups and reads: the handoffs where the
# known races sat. Stalling exit as well as entry delays the thread after it wakes.
SYSCALLS = ("sendmsg", "write", "futex", "read")
WHERE = ("enter", "exit")
# strace counts each thread's calls separately, so when=N stalls the Nth call of
# every thread that makes one; the known races sat within the first 160.
MAX_CALL = 160
DELAY_MS = 250
HOGS = 8
CORES = "0,1"
LABEL = "race-sweep"


class Stall(NamedTuple):
    syscall: str
    where: str
    call: int

    def argv(self):
        return ["strace", "-f", "-qq", "-o", "/dev/null", "-e", f"trace={self.syscall}",
                "-e", f"inject={self.syscall}:delay_{self.where}={DELAY_MS * 1000}:when={self.call}"]


def stalls(seed: int, runs: int) -> list[Stall]:
    """The stall each run injects; one seed always names the same runs."""
    chooser = random.Random(seed)
    return [Stall(chooser.choice(SYSCALLS), chooser.choice(WHERE), chooser.randint(1, MAX_CALL))
            for _ in range(runs)]


def selected(targets: str) -> list[str]:
    return ["python3", "-B", "tests/ci/run_selected.py", targets, "--ci-artifacts", ".zig-cache/o/ci-compiled"]


def starved(command: list[str]) -> list[str]:
    return ["taskset", "-c", CORES, *command]


def report(line: str):
    print(line, flush=True)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write(line + "\n")


def execute(command: list[str]) -> int:
    return subprocess.run(command).returncode


def starve(targets: str) -> int:
    hogs = [subprocess.Popen(["taskset", "-c", CORES, "sh", "-c", "while :; do :; done"]) for _ in range(HOGS)]
    try:
        command = starved(selected(targets))
        status = execute(command)
    finally:
        for hog in hogs:
            hog.kill()
            hog.wait()
    verdict = "passed" if status == 0 else f"failed (exit {status})"
    report(f"- starve {targets}: {verdict} on {CORES} beside {HOGS} busy loops; reproduce: "
           f"`{shlex.join(command)}` with the busy loops running")
    return status


def stall(targets: str, seed: int, runs: int, run=execute, say=report) -> int:
    failed = 0
    for index, chosen in enumerate(stalls(seed, runs)):
        command = [*chosen.argv(), *selected(targets)]
        status = run(command)
        verdict = "passed" if status == 0 else f"failed (exit {status})"
        say(f"- stall {index + 1}/{runs} (seed {seed}) {chosen.syscall} {chosen.where} call {chosen.call}: "
            f"{verdict}; reproduce: `{shlex.join(command)}`")
        failed += status != 0
    return 1 if failed else 0


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def file(run_url: str, sha: str, call=gh) -> str:
    """Records a failed sweep on the one open race-sweep issue, opening it if none is open."""
    body = (f"Race sweep failed on `{sha}`: {run_url}\n\n"
            "The run's step summary gives each failure's reproduction command. "
            "See docs/verification/gates.md#race-sweep before calling one a race.")
    found = call("issue", "list", "--label", LABEL, "--state", "open", "--json", "number", "--jq", ".[0].number").strip()
    if found:
        call("issue", "comment", found, "--body", body)
        return found
    call("label", "create", LABEL, "--force", "--color", "fbca04",
         "--description", "A nightly race sweep found a latent scheduling race")
    return call("issue", "create", "--title", "Race sweep found a latent race", "--label", LABEL, "--body", body).strip()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    for mode in ("starve", "stall"):
        shaker = modes.add_parser(mode)
        shaker.add_argument("targets", help="JSON array of selector targets")
        shaker.add_argument("--seed", type=int, default=0)
        shaker.add_argument("--runs", type=int, default=2)
    filer = modes.add_parser("file")
    filer.add_argument("--run-url", required=True)
    filer.add_argument("--sha", required=True)
    args = parser.parse_args(argv)
    if args.mode == "file":
        print(file(args.run_url, args.sha))
        return 0
    if not json.loads(args.targets):
        raise SystemExit("race_sweep: no targets")
    if args.mode == "starve":
        return starve(args.targets)
    return stall(args.targets, args.seed, args.runs)


if __name__ == "__main__":
    sys.exit(main())
