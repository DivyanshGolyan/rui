#!/usr/bin/env python3
"""Bounded renderer protection removals, never a mutation-score waiver.

Each check first executes against an unchanged source copy. Each mutant then
gets its own source copy and must fail its named behavioral assertion. Build
errors, crashes, missing tests, timeouts, drift and survivors fail the gate.
Compiler/package caches may be shared; test acceptance is always executed.
"""
import argparse
import dataclasses
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import signal
import shlex
import subprocess
import tempfile
import time


@dataclasses.dataclass(frozen=True)
class Check:
    target: str
    name: str

    def command(self):
        return ["zig", "build", self.target, "-j2", "-Dtest-filter=" + self.name,
                "--summary", "all", "--verbose"]


@dataclasses.dataclass(frozen=True)
class Mutation:
    name: str
    invariant: str
    fix: str
    path: str
    before: str
    after: str
    check: Check


def logic(name):
    return Check("test-logic", name)


def native(name):
    return Check("test", name)


# Exact anchors intentionally fail closed when the protection changes. Add or
# revise a mutation alongside its maintained owning test, not a copied oracle.
MUTATIONS = (
    Mutation("mark-collision", "latest read replaces a same-offset boundary", "f15c2b57",
             "src/SessionFrontend.zig",
             "self.items[self.count - 1].cursor = cursor;", "// Keep the stale cursor.",
             native("transcript boundaries survive live eviction and bounded recording")),
    Mutation("mark-eviction-edge", "a boundary exactly at retained origin is usable", "6277744c",
             "src/SessionFrontend.zig", "if (mark.offset >= front) return mark;",
             "if (mark.offset > front) return mark;",
             native("transcript boundaries survive live eviction and bounded recording")),
    Mutation("conversation-cursor", "Admission rows are not Conversation cursors", "52e9055d",
             "src/session_reads.zig", "else => if (first.position > 1) .{ .end = first.position - 1 } else null,",
             "else => .{ .end = first.position },",
             native("a live page's beginning precedes its first item, without repeating or skipping one")),
    Mutation("unsettled-publication", "a changed capture publishes no cursor or status", "41984558",
             "src/SessionFrontend.zig", "} else if (!self.job.result.settled) {",
             "} else if (false) {",
             native("after three changed reads in a row the newest capture applies")),
    Mutation("loan-cursor-owner", "releasing submission cannot erase next draft or caret", "359567e6",
             "src/SessionInput.zig",
             "self.editors[submitted.bank] = .{ .buffer = &self.banks[submitted.bank] };",
             "self.editors[self.active] = .{ .buffer = &self.banks[submitted.bank] };",
             logic("SessionInput loan release preserves next Unicode draft and cursor")),
    Mutation("paste-provenance", "paste data never becomes a fresh typed decision", "359567e6",
             "src/TerminalInput.zig", ".event = event, .pasted = pasted",
             ".event = event, .pasted = !pasted",
             logic("terminal input owns fragmentation and paste provenance without an event queue")),
    Mutation("escape-alt", "ESC prefix preserves the key's Alt modifier", "6277744c",
             "src/TerminalInput.zig", "key.mods.alt = true;", "key.mods.alt = false;",
             logic("TD2 binding outcomes across raw ESC-prefix and kitty at every fragmentation boundary")),
    Mutation("input-expiry-edge", "pending input expires at the inclusive 80ms/2s deadline", "359567e6",
             "src/SessionTerminal.zig", "now - self.pending_at >= (if (pending == .escape)",
             "now - self.pending_at > (if (pending == .escape)",
             logic("TD2 SessionTerminal expiry boundaries use a controlled clock and retain queued bytes")),
    Mutation("escape-suffix", "an interrupted OSC retains the following sequence", "0e3b44b5",
             "src/TerminalInput.zig", "self.used -= result.n;", "self.used = 0;",
             logic("an interrupted OSC keeps the following sequence and key")),
    Mutation("approval-contiguity", "only contiguous delivered Action rows permit approval", "41984558",
             "src/TerminalFrame.zig",
             "if (self.first.order(input.action_seen) != .gt and shown.next.order(input.action_seen) == .gt)",
             "if (shown.next.order(input.action_seen) == .gt)",
             logic("Action approval requires contiguous displayed rows and resets after resize")),
    Mutation("consent-freshness", "a pending decoder never grants fresh permission input", "359567e6",
             "src/session_consent.zig", "service != .empty or decoder_pending or stopped",
             "service != .empty or (decoder_pending and false) or stopped",
             logic("consent requires real emptiness after completed prompt")),
)


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def tracked(root):
    result = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    paths = [Path(os.fsdecode(name)) for name in result.split(b"\0") if name]
    for path in paths:
        if (root / path).is_symlink() or not (root / path).is_file():
            raise ValueError(f"source must contain regular tracked files: {path}")
    return paths


def manifest(root, paths):
    return {str(path): {"sha256": sha(root / path), "mode": (root / path).stat().st_mode & 0o777}
            for path in paths}


def copy_source(source, destination, paths):
    destination.mkdir()
    for path in paths:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / path, target)


def apply(root, mutation):
    path = root / mutation.path
    before = path.read_text()
    count = before.count(mutation.before)
    if count != 1:
        raise ValueError(f"{mutation.name}: expected exactly one anchor, found {count}")
    after = before.replace(mutation.before, mutation.after, 1)
    path.write_text(after)
    return "".join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                        fromfile=mutation.path, tofile=mutation.path))


def execute(command, root, log, timeout, environment):
    """Own and reap the process group even on timeout or interrupted capture."""
    start = time.monotonic()
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=root, env=environment,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    return {"command": command, "returncode": process.returncode,
            "timeout": timed_out, "seconds": round(time.monotonic() - start, 3),
            "log_sha256": sha(log)}


def run_check(check, root, log, timeout, environment):
    result = execute(check.command(), root, log, timeout, environment)
    output = log.read_text(errors="replace")
    # Zig 0.17's build protocol can say "failed without output", omitting the
    # assertion error. Execute that SAME narrow binary in terminal-report mode
    # for a named OK/FAIL and error type, not a second build or acceptance retry.
    binaries = []
    for line in output.splitlines():
        if line.startswith("info(verbose): "):
            command = shlex.split(line.removeprefix("info(verbose): "))
            if command and Path(command[0]).name == "test" and Path(command[0]).is_file():
                binaries.append(Path(command[0]))
    if not result["timeout"] and len(binaries) == 1:
        binary = binaries[0]
        result["binary_sha256"] = sha(binary)
        diagnostic = log.with_suffix(".assertion.log")
        result["assertion"] = execute([str(binary)], root, diagnostic, timeout,
                                      {**environment, "RUI_TEST_EXACT_INACTIVITY": "0"})
        output += "\n" + diagnostic.read_text(errors="replace")
        if result["assertion"]["timeout"]:
            result["timeout"] = True
    result["outcome"] = classify(result, output, check)
    return result


def classify(result, output, check):
    if result["timeout"]:
        return "timeout"
    # A named assertion is necessary but not sufficient: reject an accompanying
    # compile failure or abnormal child exit. Never accept a generic nonzero.
    if re.search(r"compilation errors?|error: (?:the following command|unable to)|terminated by signal", output):
        return "build-or-process-error"
    if result["returncode"] == 0:
        named_pass = re.search(re.escape(check.name) + r"\.\.\.OK", output)
        return "passed" if named_pass and result.get("assertion", {}).get("returncode") == 0 else "no-tests"
    named_failure = re.search(r"error: '(?:[^\n]*\.)?" + re.escape(check.name) + r"' failed", output)
    assertion = re.search(re.escape(check.name) + r"\.\.\.FAIL \((TestExpected\w*|TestUnexpectedResult)\)", output)
    if named_failure and assertion and result.get("assertion", {}).get("returncode") == 1:
        return "behavioral-kill"
    return "unclassified-failure"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def run(source, output, selected, timeout):
    source, output = source.resolve(), output.resolve()
    if output.exists():
        raise ValueError("use a fresh evidence directory; previous failures are never overwritten")
    output.mkdir(parents=True)
    paths = tracked(source)
    original = manifest(source, paths)
    write_json(output / "source.json", original)
    environment = dict(os.environ)
    # Packages are immutable compilation inputs, not source overlays or tests.
    environment["ZIG_LOCAL_PKG_DIR"] = str(Path(environment.get("ZIG_LOCAL_PKG_DIR", source / "zig-pkg")).resolve())
    zig = Path(shutil.which("zig") or "missing-zig").resolve()
    report = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
              "tracked_diff": subprocess.check_output(["git", "diff", "HEAD", "--stat"], cwd=source, text=True),
              "platform": platform.platform(), "zig_sha256": sha(zig),
              "source_manifest_sha256": sha(output / "source.json"),
              "baseline": [], "mutations": [], "tree_unchanged": False}
    report_path = output / "report.json"
    low, high = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(low, 256), high))
    try:
        with tempfile.TemporaryDirectory(prefix="rui-mutations-") as temporary:
            scratch = Path(temporary)
            # Sharing compiler objects does not reuse Run-step acceptance.
            environment["ZIG_LOCAL_CACHE_DIR"] = str(scratch / "cache")
            checks = list(dict.fromkeys(mutation.check for mutation in selected))
            baseline = scratch / "baseline"
            copy_source(source, baseline, paths)
            if manifest(baseline, paths) != original:
                raise ValueError("baseline source identity mismatch")
            for index, check in enumerate(checks):
                log = output / f"baseline-{index}.log"
                result = run_check(check, baseline, log, timeout, environment)
                result.update(check=dataclasses.asdict(check))
                report["baseline"].append(result)
                write_json(report_path, report)
                if result["outcome"] != "passed":
                    raise RuntimeError(f"unchanged baseline failed: {check.name}: {result['outcome']}")
            for mutation in selected:
                isolated = scratch / mutation.name
                copy_source(source, isolated, paths)
                patch = apply(isolated, mutation)
                (output / f"{mutation.name}.patch").write_text(patch)
                expected = {**original, mutation.path: manifest(isolated, [Path(mutation.path)])[mutation.path]}
                if manifest(isolated, paths) != expected:
                    raise ValueError("mutation changed files outside its declared protection")
                log = output / f"{mutation.name}.log"
                result = run_check(mutation.check, isolated, log, timeout, environment)
                outcome = result["outcome"]
                result.update(mutation=dataclasses.asdict(mutation), outcome="survived-gap" if outcome == "passed" else outcome)
                report["mutations"].append(result)
                write_json(report_path, report)
                print(f"{mutation.name}: {result['outcome']}", flush=True)
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, (low, high))
        report["tree_unchanged"] = manifest(source, paths) == original and tracked(source) == paths
        write_json(report_path, report)
    return report["tree_unchanged"] and len(report["mutations"]) == len(selected) and all(
        row["outcome"] == "behavioral-kill" for row in report["mutations"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mutation", action="append", choices=[m.name for m in MUTATIONS])
    parser.add_argument("--timeout", type=int, default=300, help="per narrow check; timeout never counts as a kill")
    args = parser.parse_args()
    selected = [m for m in MUTATIONS if args.mutation is None or m.name in args.mutation]
    try:
        return 0 if run(args.source, args.output, selected, args.timeout) else 1
    except (OSError, ValueError, RuntimeError) as error:
        print(f"renderer mutation gate failed: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
