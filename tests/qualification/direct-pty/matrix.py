#!/usr/bin/env python3
"""Synthetic primary key matrix and tmux smoke, not physical-human qualification."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import platform
import resource
import signal
import subprocess
import sys
import threading
import time
import traceback

import driver  # noqa: F401, puts tests/integration on sys.path
import host_process

HERE = pathlib.Path(__file__).resolve().parent
STOP = threading.Event()
ACTIVE = set()
LOCK = threading.Lock()
STOP_NUMBER = 0


def chunk(data, delay_before=0):
    return {"hex": data.hex(), "delay_before": delay_before}


def row(name, data, expected):
    return {"name": name, "scenario": "editor", "chunks": [chunk(data)], "expected": expected}


def inventory():
    rows = [
        row("typing", "A中é!\r".encode(), "A中é!"),
        row("left-csi", b"ac\x1b[Db\r", "abc"),
        row("left-ss3", b"ac\x1bODb\r", "abc"),
        row("right-csi", b"ac\x01\x1b[Cb\r", "abc"),
        row("home-end", b"bc\x1b[Ha\x1b[FZ\r", "abcZ"),
        row("ctrl-a-e", b"bc\x01a\x05Z\r", "abcZ"),
        row("ctrl-k", b"abcd\x1b[D\x1b[D\x0bZ\r", "abZ"),
        row("ctrl-u", b"discard\x15keep\r", "keep"),
        row("ctrl-w", b"ask src/foo-bar\x17Z\r", "ask Z"),
        row("alt-backspace", b"ask src/foo-bar\x1b\x7fZ\r", "ask src/foo-Z"),
        row("delete", b"abc\x1b[D\x1b[3~Z\r", "abZ"),
        row("ctrl-d-nonempty", b"abc\x1b[D\x04Z\r", "abZ"),
        row("backspace-grapheme", "A中é🧑‍🌾\x7fZ\r".encode(), "A中éZ"),
        row("alt-unbound", b"ab\x1bzQ\r", "abQ"),
        # ARCHITECTURE.md: Alt-Enter (ESC CR, Ghostty Shift-Enter) adds a line.
        row("alt-enter", b"ab\x1b\rQ\r", "ab\nQ"),
        row("alt-unicode", "ab\x1béQ\r".encode(), "abQ"),
        row("kitty-alt", b"ab\x1b[122;3uQ\r", "abQ"),
        row("kitty-shift-enter", b"one t\x1b[13;2uZwo!\r", "one t\nZwo!"),
        row("kitty-ctrl-a-e", b"bc\x1b[97;5ua\x1b[101;5uZ\r", "abcZ"),
        row("kitty-alt-j", b"one\x1b[106;3utwo\r", "one\ntwo"),
        row("double-esc-arrow", b"ac\x1b\x1b[Db\r", "abc"),
        row("double-esc-paste", b"a\x1b\x1b[200~b\x1b[201~\r", "ab"),
        row("paste", b"\x1b[200~line1\nline2\x1b[201~\r", "line1\nline2"),
        row("alt-j", b"line1\x1bjline2\r", "line1\nline2"),
        row("focus-reports", b"ab\x1b[I\x1b[OZ\r", "abZ"),
        row("terminal-string", b"ab\x1b]0;not text\x07Z\r", "abZ"),
        row("unknown-csi", b"ab\x1b[999~Z\r", "abZ"),
        row("mouse-sgr-wheel", b"a\x1b[<64;10;10M\x1b[<65;10;10MZ\r", "aZ"),
        row("mouse-x10-wheel", b"a\x1b[M`**\x1b[Ma**Z\r", "aZ"),
    ]
    rows += [
        {"name": "fragmented-csi", "scenario": "editor", "chunks":
            [chunk(b"ac\x1b["), chunk(b"Db\r", 0.02)], "expected": "abc"},
        {"name": "fragmented-utf8", "scenario": "editor", "chunks":
            [chunk(b"A\xe4"), chunk(b"\xb8", 0.02), chunk(b"\xadZ\r", 0.02)], "expected": "A中Z"},
        {"name": "fragmented-paste", "scenario": "editor", "chunks":
            [chunk(b"\x1b[20"), chunk(b"0~one\ntwo\x1b[20", 0.02), chunk(b"1~\r", 0.02)],
            "expected": "one\ntwo"},
        {"name": "mouse-x10-split", "scenario": "editor", "chunks":
            [chunk(b"a\x1b[M"), chunk(b" isZ\r", 0.02)], "expected": "aZ"},
        {"name": "bare-esc-expiry", "scenario": "editor", "chunks":
            [chunk(b"ab\x1b"), chunk(b"Z\r", 0.15)], "expected": "abZ"},
        {"name": "resize", "scenario": "editor", "chunks":
            [chunk("A中bc\x1b[D".encode()), {"resize": [32, 12]}, chunk(b"Z\r", 0.1)], "expected": "A中bZc"},
    ]
    for name, data in (("incomplete-csi", b"\x1b["), ("incomplete-ss3", b"\x1bO"),
                       ("incomplete-utf8", b"\xc3"), ("incomplete-paste", b"\x1b[200~unfinished")):
        rows.append({"name": name, "scenario": "expiry", "chunks": [chunk(data)]})
    for name, data in (("paste-controls", b"\x1b[200~a\x12b\x1b[201~\r"),
                       ("malformed-utf8", b"bad\xc3(\r")):
        rows.append({"name": name, "scenario": "rejection", "chunks": [chunk(data)]})
    rows.append({"name": "recovery-raw", "scenario": "recovery", "chunks": [chunk(b"\x12")]})
    for name, enter, leave, first in (
        ("key-pgup", b"\x1b[5~", b"\x07", 61),
        ("key-pgdn", b"\x1b[5~" * 2, b"\x1b[6~", 41),
        ("key-shift-pgup", b"\x1b[5;2~", b"\x07", 61),
        ("key-up-csi", b"\x1b[A", b"\x07", 80),
        ("key-up-ss3", b"\x1bOA", b"\x07", 80),
        ("key-end-csi-f", b"\x1b[5~", b"\x1b[F", 61),
        ("key-end-ss3-f", b"\x1b[5~", b"\x1bOF", 61),
        ("key-end-csi-4", b"\x1b[5~", b"\x1b[4~", 61),
        ("key-esc", b"\x1b[5~", b"\x1b", 61),
        ("wheel-alt-scroll", b"\x1b[A" * 3, b"\x1b[B", 78),
        ("status", b"/status\r", b"\x1b", None),
    ):
        vector = {"name": name, "scenario": "navigation", "chunks": [chunk(enter)],
                  "return_chunks": [chunk(leave)], "status": name == "status", "first_history": first}
        if name == "key-pgdn":
            vector["middle"] = [{"chunks": [chunk(b"\x1b[6~")], "first_history": 61}]
        elif name == "wheel-alt-scroll":
            vector["middle"] = [{"chunks": [chunk(b"\x1b[B")], "first_history": first} for first in (79, 80)]
        rows.append(vector)
    for name, data, expected in (
        ("typing", b"tmux typing\r", "tmux typing"),
        ("paste", b"one\ntwo", "one\ntwo"),
        ("resize", "A中bc\x1b[DZ\r".encode(), "A中bZc"),
        ("alt-j", b"one\x1bjtwo\r", "one\ntwo"),
        ("status", b"/status\r", None),
    ):
        rows.append({"name": "tmux-" + name, "scenario": "tmux", "chunks": [chunk(data)], "expected": expected})
    return rows


def sha256(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def interrupted(number, frame):
    # A second signal cannot interrupt mandatory cleanup of owned children.
    for selected in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(selected, signal.SIG_IGN)
    raise SystemExit(128 + number)


def cancel(number, frame):
    global STOP_NUMBER
    STOP_NUMBER = number
    for selected in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(selected, signal.SIG_IGN)
    STOP.set()
    with LOCK:
        for process in ACTIVE:
            if process.poll() is None:
                process.send_signal(number)


def worker(binary, output, vector):
    # No preexec_fn in a threaded parent. Every worker sets its own limit before
    # launching any fixture, and children inherit it with the hard limit intact.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if hard < 256:
        raise RuntimeError(f"hard NOFILE {hard} cannot provide required soft 256")
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard))
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    # Imported here: model_fixture reads its binary from this process's argv at import.
    from scenarios import Fixture, SCENARIOS
    from tmux_smoke import smoke
    SCENARIOS["tmux"] = smoke
    result = {"row": vector["name"], "status": "setup", "soft_nofile": 256,
              "pid": os.getpid(), "binary_sha256": sha256(binary), "vector": vector}
    started = time.monotonic()
    code = 0
    try:
        with Fixture(binary, output) as fixture:
            result["status"] = "running"
            SCENARIOS[vector["scenario"]](fixture, vector)
        result["status"] = "passed"
    except BaseException as error:
        was_setup = result["status"] == "setup"
        result["status"] = ("interrupted" if isinstance(error, SystemExit) else
                            "setup" if was_setup else "timeout" if isinstance(error, TimeoutError)
                            else "assertion" if isinstance(error, AssertionError) else "error")
        result["error"] = repr(error)
        result["traceback"] = traceback.format_exc()
        code = error.code if isinstance(error, SystemExit) else {
            "assertion": 1, "setup": 2, "timeout": 3, "error": 4}[result["status"]]
    result["seconds"] = time.monotonic() - started
    (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"{result['row']}: {result['status']} ({result['seconds']:.3f}s)", flush=True)
    if code:
        print(result["traceback"], file=sys.stderr)
    return code


def run_one(binary, root, vector):
    output = root / vector["name"]
    output.mkdir()
    (output / "vector.json").write_text(json.dumps(vector, ensure_ascii=False, indent=2))
    with open(output / "worker.log", "wb") as log:
        with LOCK:
            if STOP.is_set():
                return {"row": vector["name"], "status": "cancelled"}
            process = subprocess.Popen([sys.executable, str(__file__), str(binary), "--output", str(output),
                "--worker", str(output / "vector.json")], stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True)
            ACTIVE.add(process)
        try:
            code = process.wait()
        finally:
            with LOCK:
                ACTIVE.remove(process)
    result_file = output / "result.json"
    result = json.loads(result_file.read_text()) if result_file.exists() else {
        "row": vector["name"], "status": "worker-failed", "exit": code}
    result["worker_exit"] = code
    if result["row"] != vector["name"] or (result["status"] == "passed" and code != 0):
        result = {"row": vector["name"], "status": "exit-receipt-mismatch", "worker_exit": code,
                  "receipt": result}
    print(f"{vector['name']}: {result['status']}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--jobs", type=int, default=4, choices=range(1, 9))
    parser.add_argument("--row", action="append", help="stable row selector; repeat to select several")
    parser.add_argument("--surface", choices=("direct", "tmux", "all"), default="all")
    parser.add_argument("--vectors", type=pathlib.Path, help="JSON array of external byte vectors (TD2)")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--worker", type=pathlib.Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if args.worker:
        return worker(binary, args.output, json.loads(args.worker.read_text()))
    rows = json.loads(args.vectors.read_text()) if args.vectors else inventory()
    names = [item["name"] for item in rows]
    assert len(names) == len(set(names)), "duplicate row names"
    assert all(name and all(c.isalnum() or c in "-_" for c in name) for name in names), "unsafe row name"
    if args.row:
        unknown = set(args.row) - set(names)
        if unknown:
            parser.error(f"unknown row {', '.join(sorted(unknown))}; use --list for stable selectors")
        rows = [item for item in rows if item["name"] in args.row]
    if args.surface != "all":
        rows = [item for item in rows if (item["scenario"] == "tmux") == (args.surface == "tmux")]
    assert rows, "no selected rows"
    if args.list:
        print("\n".join(item["name"] for item in rows))
        return 0
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = {"synthetic": True, "platform": platform.platform(), "machine": platform.machine(),
        "python": sys.version, "binary_sha256": sha256(binary), "jobs": args.jobs,
        "harness_sha256": {path.name: sha256(path) for path in sorted(HERE.glob("*.py"))},
        "source": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=HERE, text=True).strip(),
        "tree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=HERE, text=True).strip()}
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2))
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, cancel)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(lambda vector: run_one(binary, output, vector), rows))
    (output / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
    passed = sum(result["status"] == "passed" for result in results)
    print(f"{passed}/{len(results)} synthetic primary matrix/smoke rows passed; physical terminals unverified")
    if STOP_NUMBER:
        return 128 + STOP_NUMBER
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
