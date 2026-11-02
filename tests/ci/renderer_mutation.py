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
import sys
import tempfile
import time


@dataclasses.dataclass(frozen=True)
class Check:
    target: str
    name: str

    def command(self, root, output, environment):
        if self.target == "sequence-model":
            return [sys.executable, str(root / "tests/integration/session_sequence_model.py"),
                    "--source", str(root), "--output", str(output),
                    "--cache", str(Path(environment["ZIG_LOCAL_CACHE_DIR"]) / "sequence-model"),
                    "--selector", self.name.removeprefix("TD1 sequence model ")]
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


def model(selector):
    return Check("sequence-model", "TD1 sequence model " + selector)


# Exact anchors intentionally fail closed when the protection changes. Add or
# revise a mutation alongside its maintained owning test, not a copied oracle.
MUTATIONS = (
    # 11f02d17 moved transcript Marks from SessionFrontend to session_reads.
    Mutation("mark-collision", "latest read replaces a same-offset boundary", "f15c2b57",
             "src/session_reads.zig",
             "self.items[self.count - 1] = mark;", "// Keep the stale mark.",
             native("a transcript joins at the first retained boundary or shows the gap after the newest evicted one")),
    Mutation("mark-eviction-edge", "a boundary exactly at retained origin is usable", "4d5cf8ba",
             "src/session_reads.zig", "if (mark.offset >= front) return .{ .joined = mark };",
             "if (mark.offset > front) return .{ .joined = mark };",
             native("a transcript joins at the first retained boundary or shows the gap after the newest evicted one")),
    Mutation("conversation-cursor", "Admission rows are not Conversation cursors", "a68b4c76",
             "src/session_reads.zig", "else => if (first.position > 1) .{ .end = first.position - 1 } else null,",
             "else => .{ .end = first.position },",
             native("a live page's beginning precedes its first item, without repeating or skipping one")),
    Mutation("loan-cursor-owner", "releasing submission cannot erase next draft or caret", "1566667d",
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
    Mutation("input-expiry-edge", "pending input expires at the inclusive 80ms/2s deadline", "1566667d",
             "src/TerminalInput.zig", "if (remaining <= 0) return .expire;",
             "if (remaining < 0) return .expire;",
             logic("TD2 SessionTerminal expiry boundaries use a controlled clock and retain queued bytes")),
    Mutation("escape-suffix", "an interrupted OSC retains the following sequence", "0e3b44b5",
             "src/TerminalInput.zig", "self.used -= result.n;", "self.used = 0;",
             logic("an interrupted OSC keeps the following sequence and key")),
    Mutation("approval-contiguity", "only contiguous delivered Action rows permit approval", "4d5cf8ba",
             "src/TerminalFrame.zig",
             "if (self.first.order(input.action_seen) != .gt and shown.next.order(input.action_seen) == .gt)",
             "if (shown.next.order(input.action_seen) == .gt)",
             logic("Action approval requires contiguous displayed rows and resets after resize")),
    Mutation("consent-freshness", "a pending decoder never grants fresh permission input", "771a8de5",
             "src/SessionScreen.zig", "service != .empty or decoder_pending or blocked",
             "service != .empty or (decoder_pending and false) or blocked",
             native("a decision prompt is offered only after its own delivered frame")),
    Mutation("incomplete-classification", "only a bare ESC or ESC ESC may expire as Escape", "359567e6",
             "src/TerminalInput.zig", ".escape else .incomplete;", ".escape else .escape;",
             logic("TD2 incomplete prefixes expire fatally without modifying or submitting drafts")),
    Mutation("mouse-framing", "X10 payload never becomes composer text", "10e07b17",
             "src/TerminalInput.zig", 'if (!self.paste and std.mem.startsWith(u8, bytes, "\\x1b[M")) {',
             'if (false and !self.paste and std.mem.startsWith(u8, bytes, "\\x1b[M")) {',
             logic("fragmented X10 mouse reports are consumed whole, never as typed text")),
    Mutation("stale-details", "a delayed details page cannot cover a later Message", "67f80e38",
             "src/SessionFrontend.zig", "self.admission.details_sent == self.admission.sent", "true",
             model("pages")),
    Mutation("stale-transcript", "a delayed history page belongs to its transcript generation", "4d5cf8ba",
             "src/SessionFrontend.zig", "self.job.transcript == self.transcript.id", "true",
             model("pages")),
    Mutation("send-generation", "sending invalidates already running details work", "67f80e38",
             "src/SessionFrontend.zig", "self.admission.sent += 1;", "self.admission.sent += 0;",
             model("pages")),
    Mutation("send-queued-history", "sending discards a queued older-page request", "5bb24efe",
             "src/SessionFrontend.zig",
             "self.inspection.status_requested = false;\n    self.transcript.history_requested = null;\n    self.dropMessageRequest();",
             "self.inspection.status_requested = false;\n    self.dropMessageRequest();",
             model("pages")),
    Mutation("send-queued-status", "sending discards a queued status-page request", "67f80e38",
             "src/SessionFrontend.zig",
             "self.inspection.status_requested = false;\n    self.transcript.history_requested = null;\n    self.dropMessageRequest();",
             "self.transcript.history_requested = null;\n    self.dropMessageRequest();",
             model("pages")),
    Mutation("send-latest-view", "sending leaves a frozen inspection for latest conversation", "67f80e38",
             "src/SessionFrontend.zig",
             "self.dropMessageRequest();\n    try self.terminal.screen.latest();\n}",
             "self.dropMessageRequest();\n}",
             model("pages")),
    Mutation("ack-frontier", "older captures cannot decrease delivered admission frontier", "3c690817",
             "src/SessionFrontend.zig", "@max(self.admission.delivered, result.delivered)", "result.delivered",
             model("acknowledgement")),
    Mutation("late-ack-echo", "late acceptance cannot resurrect Sent after delivery", "3c690817",
             "src/SessionFrontend.zig", "if (admission > self.admission.delivered) admission else null", "admission",
             model("acknowledgement")),
    Mutation("echo-retirement-edge", "delivery at the exact admission clears Sent", "41984558",
             "src/SessionFrontend.zig", "if (admission <= self.admission.delivered)", "if (admission < self.admission.delivered)",
             model("acknowledgement")),
    # 1f52ba94 split the paused draft: typing beside a shown Action is its reason.
    Mutation("paused-draft-submission", "paused approval cannot submit the retained draft", "52e9055d",
             "src/session_consent.zig", "return (consent == null or reason) and !blockers.opening",
             "return (consent == null or reason or true) and !blockers.opening",
             model("focus")),
    Mutation("paused-editor-owner", "a hidden Action keeps the draft and its own caret", "52e9055d",
             "src/session_consent.zig",
             "if (!shown.action_page) return .{ .approval = .paused };",
             "if (!shown.action_page) return .{ .row = .selector, .approval = .paused };",
             model("focus")),
    Mutation("reason-editor-owner", "typing beside a shown Action keeps the draft and its own caret", "52e9055d",
             "src/session_consent.zig",
             "if (pending.row == .draft) return .{ .approval = if (command_blocked) .paused else .reason };",
             "if (pending.row == .draft) return .{ .row = .selector, .approval = if (command_blocked) .paused else .reason };",
             model("focus")),
    Mutation("reason-letter", "a draft of one choice letter never denies as a reason", "1f52ba94",
             "src/session_consent.zig", "return text.len == 1 and std.mem.indexOfScalar",
             "return false and text.len == 1 and std.mem.indexOfScalar",
             model("focus")),
    Mutation("unread-action-decision", "choice submission requires a completely delivered Action", "4d5cf8ba",
             "src/session_consent.zig", "if (!shown.read) return .{ .row = .selector, .approval = .reading };",
             "if (false and !shown.read) return .{ .row = .selector, .approval = .reading };",
             model("focus")),
    Mutation("frame-publication", "failed frame output cannot advance inspected rows or approval", "4d5cf8ba",
             "src/SessionScreen.zig", "    try out.writeAll(frame.written());",
             "    self.action_seen = layout.action_seen;\n    try out.writeAll(frame.written());",
             model("publication")),
    Mutation("frame-flush-publication", "accepted writes without successful flush cannot certify a frame", "4d5cf8ba",
             "src/SessionScreen.zig", "    try out.writeAll(frame.written());\n    try out.flush();",
             "    try out.writeAll(frame.written());\n    self.action_seen = layout.action_seen;\n    try out.flush();",
             model("publication")),
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
    return {"command": command, "cwd": str(root), "returncode": process.returncode,
            "timeout": timed_out, "seconds": round(time.monotonic() - start, 3),
            "log_sha256": sha(log)}


def run_check(check, root, log, timeout, environment):
    deadline = time.monotonic() + timeout
    model_output = log.with_suffix(".model")
    result = execute(check.command(root, model_output, environment), root, log, timeout, environment)
    output = log.read_text(errors="replace")
    if result["timeout"] or result["returncode"] not in (0, 1):
        result["outcome"] = classify(result, output, check)
        return result
    if check.target == "sequence-model":
        # The maintained runner already executed its exact binary directly.
        # Consume that evidence rather than performing a third model execution.
        receipt_path = model_output / "receipt.json"
        try:
            receipt = json.loads(receipt_path.read_text())
            binary = Path(receipt["binary"])
            valid = (receipt["source"] == str(root) and
                     receipt["selector"] == check.name.removeprefix("TD1 sequence model ") and
                     receipt["source_unchanged"] is True and
                     receipt["overlay_unchanged"] is True and
                     receipt["exit"] == receipt["direct_exit"] == result["returncode"] and
                     sha(binary) == receipt["binary_sha256"])
        except (OSError, ValueError, KeyError, TypeError):
            valid = False
        if not valid:
            result["outcome"] = "invalid-model-receipt"
            return result
        result["receipt_sha256"] = sha(receipt_path)
        result["binary_sha256"] = receipt["binary_sha256"]
        result["assertion"] = {"returncode": receipt["direct_exit"]}
        result["outcome"] = classify(result, output, check)
        return result
    # Zig 0.17's build protocol can say "failed without output", omitting the
    # assertion error. Execute that SAME narrow binary in terminal-report mode
    # for a named OK/FAIL and error type, not a second build or acceptance retry.
    binaries = []
    for line in output.splitlines():
        if line.startswith("info(verbose): "):
            command = shlex.split(line.removeprefix("info(verbose): "))
            while command and re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", command[0]):
                command.pop(0)
            if command and Path(command[0]).name == "test" and Path(command[0]).is_file():
                binaries.append(Path(command[0]))
    if not result["timeout"] and len(binaries) == 1:
        binary = binaries[0]
        result["binary_sha256"] = sha(binary)
        diagnostic = log.with_suffix(".assertion.log")
        result["assertion"] = execute([str(binary)], root, diagnostic, max(0, deadline - time.monotonic()),
                                      {**environment, "RUI_TEST_EXACT_INACTIVITY": "0"})
        output += "\n" + diagnostic.read_text(errors="replace")
        if result["assertion"]["timeout"]:
            result["timeout"] = True
    result["outcome"] = classify(result, output, check)
    return result


def classify(result, output, check):
    if result["timeout"]:
        return "timeout"
    if result["returncode"] not in (0, 1):
        return "build-or-process-error"
    # A named assertion is necessary but not sufficient: reject an accompanying
    # compile failure or abnormal child exit. Never accept a generic nonzero.
    if re.search(r"compilation errors?|error: (?:the following command|unable to)|terminated by signal", output):
        return "build-or-process-error"
    if result["returncode"] == 0:
        named_pass = re.search(re.escape(check.name) + r"\.\.\.OK", output)
        return "passed" if named_pass and result.get("assertion", {}).get("returncode") == 0 else "no-tests"
    named_failure = re.search(r"error: '(?:[^\n]*\.)?" + re.escape(check.name) + r"' failed", output)
    assertion = False
    records = list(re.finditer(r"(?m)^\d+/\d+ ([^\n]+?)\.\.\.", output))
    for index, record in enumerate(records):
        if record[1] != check.name and not record[1].endswith("." + check.name):
            continue
        end = records[index + 1].start() if index + 1 < len(records) else len(output)
        # Assertions print expected/found diagnostics before their FAIL record.
        # Never borrow a failure from the next test's record.
        errors = re.findall(r"(?:^|\n)FAIL \(([^)\n]+)\)(?=\n|$)", output[record.end():end])
        assertion = bool(errors and re.fullmatch(r"TestExpected\w*|TestUnexpectedResult", errors[-1]))
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
    report["nofile_soft"] = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
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
                if manifest(baseline, paths) != original:
                    raise ValueError("baseline source changed before execution")
                log = output / f"baseline-{index}.log"
                result = run_check(check, baseline, log, timeout, environment)
                after = manifest(baseline, paths)
                result["source_unchanged"] = after == original
                if not result["source_unchanged"]:
                    write_json(output / f"baseline-{index}.source-after.json", after)
                    result["outcome"] = "source-drift"
                result.update(check=dataclasses.asdict(check))
                report["baseline"].append(result)
                write_json(report_path, report)
                if result["outcome"] != "passed":
                    raise RuntimeError(f"unchanged baseline failed: {check.name}: {result['outcome']}")
            for mutation in selected:
                isolated = scratch / mutation.name
                copy_source(source, isolated, paths)
                if manifest(isolated, paths) != original:
                    raise ValueError("mutant source identity mismatch before mutation")
                patch = apply(isolated, mutation)
                (output / f"{mutation.name}.patch").write_text(patch)
                expected = {**original, mutation.path: manifest(isolated, [Path(mutation.path)])[mutation.path]}
                if manifest(isolated, paths) != expected:
                    raise ValueError("mutation changed files outside its declared protection")
                log = output / f"{mutation.name}.log"
                result = run_check(mutation.check, isolated, log, timeout, environment)
                after = manifest(isolated, paths)
                result["source_unchanged"] = after == expected
                if not result["source_unchanged"]:
                    write_json(output / f"{mutation.name}.source-after.json", after)
                    result["outcome"] = "source-drift"
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
    parser.add_argument("--target", choices=sorted({m.check.target for m in MUTATIONS}),
                        help="Run one check family; omitted means every protection")
    parser.add_argument("--timeout", type=int, default=600, help="per build plus direct assertion; timeout never counts as a kill")
    args = parser.parse_args()
    selected = [m for m in MUTATIONS if (args.mutation is None or m.name in args.mutation) and
                (args.target is None or m.check.target == args.target)]
    if not selected:
        parser.error("no protections match --target and --mutation")
    try:
        return 0 if run(args.source, args.output, selected, args.timeout) else 1
    except (OSError, ValueError, RuntimeError) as error:
        print(f"renderer mutation gate failed: {error}", flush=True)
        return 1
    finally:
        report = args.output.resolve() / "report.json"
        if report.is_file():
            print(f"Evidence: {report} (logs beside it). Keep this attempt; "
                  "any rerun requires a fresh --output directory.", flush=True)
        else:
            print("No report was created. Use a fresh --output directory.", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
