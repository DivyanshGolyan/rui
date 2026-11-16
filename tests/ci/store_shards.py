#!/usr/bin/env python3
"""Run one compiled Store root concurrently, or refresh its live-MySQL timings.

    store_shards.py run BINARY --timeout 1200 [BINARY_ARGUMENTS...]
    store_shards.py native BINARY --timeout 1200
    store_shards.py aggregate BINARY --timeout 1200
    store_shards.py measure BINARY --timeout 1800 --output tests/ci/store_test_times.json

RUI_UNIT_SHARD is zero-based i/K. Assignment belongs to the binary's partition
owner; this script owns process lifetimes and the Store dialect record join.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import host_process
import live_engines
import unit_test_metadata as metadata

SHARD_COUNT = 4
MAX_OUTPUT = 64 * 1024 * 1024
END = re.compile(rb"(?:^|\n)(OK|SKIP|FAIL[^\n]*)\r?\n")


class TerminalTimes:
    """Consume stock-runner terminal output as it arrives, including partial lines."""
    def __init__(self, names, on_start=None):
        self.names = names
        self.on_start = on_start
        self.buffer = b""
        self.active = None
        self.results = []

    def feed(self, data, now):
        self.buffer += data
        while True:
            if self.active is None:
                index = len(self.results)
                if index == len(self.names):
                    return
                name = self.names[index]
                marker = f"{index + 1}/{len(self.names)} {name}...".encode()
                position = self.buffer.find(marker)
                if position == -1:
                    return
                self.active = (name, now)
                if self.on_start:
                    self.on_start(index)
                self.buffer = self.buffer[position + len(marker):]
            match = END.search(self.buffer)
            if match is None:
                return
            name, start = self.active
            self.results.append((name, max(0, now - start), match[1].decode()))
            self.active = None
            self.buffer = self.buffer[match.end():]

    def finish(self):
        if self.active is not None or len(self.names) != len(self.results):
            raise ValueError("incomplete terminal test inventory")
        return self.results


@dataclass
class Result:
    label: str
    status: int
    seconds: float
    tests: list
    diagnostic: str


def execute(binary, arguments, environ, timeout, label, stop=None, test_timeout=None, parallel_after=None, on_parallel=None):
    start = time.monotonic()
    def on_start(index):
        if parallel_after is not None and index == parallel_after:
            if any(state not in ("OK", "SKIP") for _, _, state in parser.results):
                if stop is not None:
                    stop.set()
            else:
                on_parallel()
    parser = TerminalTimes(metadata.query(binary, timeout=min(30, timeout), environ=environ), on_start)
    output = bytearray()
    status = None
    diagnostic = ""
    process = subprocess.Popen([str(Path(binary).resolve()), *arguments], env=environ,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                if stop is not None and stop.is_set():
                    status, diagnostic = 130, "unit root interrupted"
                    break
                if now - start >= timeout:
                    status, diagnostic = 124, f"process deadline exceeded ({timeout:g}s)"
                    break
                if test_timeout and parser.active and now - parser.active[1] >= test_timeout:
                    status, diagnostic = 124, f"test timeout ({test_timeout:g}s): {parser.active[0]}"
                    break
                for key, _ in selector.select(min(0.1, max(0, timeout - (now - start)))):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    output.extend(data)
                    if len(output) > MAX_OUTPUT:
                        status, diagnostic = 1, "unit root output exceeds size limit"
                        break
                    parser.feed(data, time.monotonic())
                if status is not None:
                    break
        if status is None:
            status = process.wait()
        if status == 0:
            try:
                parser.finish()
                if on_parallel:
                    on_parallel()
            except ValueError as error:
                status, diagnostic = 1, str(error)
    finally:
        # A test can leave descendants holding the output pipe. Own and reap the
        # entire process group on timeout, failure, cancellation and completion.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()
    if status:
        diagnostic = output.decode("utf-8", errors="replace") + "\n" + diagnostic
    return Result(label, status, time.monotonic() - start, parser.results, diagnostic)


def merge_records(paths, destination):
    counts = {}
    for path in paths:
        # Every process that shadows SQL must produce its own record. Never let
        # a missing record be covered by another shard's successful counters.
        current = live_engines.parse_record(Path(path).read_text())
        if not current or any(value < 0 for value in current.values()):
            raise ValueError(f"invalid MySQL dialect record: {path}")
        for name, value in current.items():
            counts[name] = counts.get(name, 0) + value
    destination = Path(destination)
    temporary = destination.with_name(destination.name + f".{os.getpid()}.tmp")
    try:
        temporary.write_text(" ".join(f"{name}={value}" for name, value in sorted(counts.items())) + "\n")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def report(result):
    passed = sum(state == "OK" for _, _, state in result.tests)
    skipped = sum(state == "SKIP" for _, _, state in result.tests)
    print(f"{result.label}: {passed} passed, {skipped} skipped, {result.seconds:.3f}s; exit {result.status}", flush=True)
    if result.diagnostic:
        print(result.diagnostic, file=sys.stderr, flush=True)


def duration(text):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ns|us|ms|s|m|h)?", text)
    if not match:
        raise ValueError(f"invalid test timeout: {text}")
    return float(match[1]) * {None: 1, "ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}[match[2]]


@contextmanager
def cancellation(stop):
    previous = {}
    caught = []
    def cancel(signum, frame):
        caught.append(signum)
        stop.set()
    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, cancel)
    try:
        yield caught
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def run(binary, arguments, timeout, mode, environ, output=None):
    started = time.monotonic()
    record = environ.get(live_engines.MYSQL_RECORD)
    count = SHARD_COUNT if mode == "run" else 1
    stop = threading.Event()
    test_timeout = duration(environ["RUI_UNIT_TEST_TIMEOUT"]) if environ.get("RUI_UNIT_TEST_TIMEOUT") else None
    with tempfile.TemporaryDirectory(prefix="rui-store-shards-") as directory:
        jobs = []
        records = []
        for index in range(count):
            child = dict(environ)
            child["RUI_TEST_EXACT_INACTIVITY"] = "0"
            child.pop("RUI_UNIT_SHARD", None)
            child.pop("RUI_UNIT_EXCLUSIVE", None)
            child["RUI_UNIT_MYSQL_NAMESPACE"] = f"s{os.getpid()}_{index}"
            if mode == "native":
                child["RUI_UNIT_MYSQL_NAMESPACE"] = f"n{os.getpid()}"
            if mode == "run":
                child["RUI_UNIT_SHARD"] = f"{index}/{count}"
            if record:
                path = str(Path(directory) / f"record-{index}") if mode == "run" else record
                if mode == "native":
                    path = record + ".native"
                Path(path).unlink(missing_ok=True)
                child[live_engines.MYSQL_RECORD] = path
                records.append(path)
            jobs.append((child, f"Store shard {index + 1}/{count}" if mode == "run" else mode))
        # Clear previous acceptance before any child starts.
        if record and mode != "native":
            Path(record).unlink(missing_ok=True)
        results = []
        with cancellation(stop) as caught, live_engines.mysql_lease(environ, exclusive=mode != "native", timeout=timeout, stop=stop) as lock, ThreadPoolExecutor(max_workers=count) as pool:
            released = threading.Event()
            exclusive_count = len(metadata.query(binary, timeout=min(30, timeout),
                                  environ=dict(jobs[0][0], RUI_UNIT_EXCLUSIVE="1"))) if mode == "run" else 0
            def release():
                if not released.is_set():
                    if lock is not None:
                        fcntl.flock(lock, fcntl.LOCK_SH)
                    released.set()
            if mode == "run" and not exclusive_count:
                release()
            def first():
                try:
                    result = execute(binary, arguments, jobs[0][0], timeout, jobs[0][1], stop, test_timeout,
                                     exclusive_count if mode == "run" else None, release if mode == "run" else None)
                    if result.status:
                        stop.set()
                    return result
                except BaseException:
                    stop.set()
                    raise
                finally:
                    released.set()
            def peer(child, label):
                released.wait()
                if stop.is_set():
                    return Result(label, 130, 0, [], "cancelled before exclusive phase completed")
                return execute(binary, arguments, child, timeout, label, stop, test_timeout)
            futures = [pool.submit(first), *[pool.submit(peer, child, label) for child, label in jobs[1:]]]
            try:
                for future in as_completed(futures):
                    result = future.result()
                    results.append(result)
                    report(result)
            except BaseException:
                stop.set()
                raise
        status = (128 + caught[0]) if caught else next((result.status for result in results if result.status), 0)
        if status:
            return status
        if mode == "measure":
            results_by_name = {name: seconds for name, seconds, state in results[0].tests if state in ("OK", "SKIP")}
            if len(results_by_name) != len(results[0].tests):
                raise ValueError("measurement requires a complete successful inventory with unique names")
            Path(output).write_text(json.dumps(results_by_name, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
            total = sum(results_by_name.values())
            top = sorted(results_by_name.items(), key=lambda item: (-item[1], item[0]))[:20]
            print(f"Measured {len(results_by_name)} tests: total {total:.3f}s; top 20 {(sum(seconds for _, seconds in top) / total if total else 0):.1%}")
            for name, seconds in top:
                print(f"{seconds:.3f}s {name}")
        if record and mode == "run":
            merge_records(records, record)
        print(f"{'Store root' if mode == 'run' else mode} wall: {time.monotonic() - started:.3f}s; "
              f"{sum(len(result.tests) for result in results)} tests across {count} processes", flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("run", "native", "aggregate", "measure"))
    parser.add_argument("binary")
    parser.add_argument("--timeout", type=float, default=1200)
    parser.add_argument("--output", default="tests/ci/store_test_times.json")
    args, arguments = parser.parse_known_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be finite and positive")
    if args.mode == "measure" and "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","):
        parser.error("measurement requires live MySQL in RUI_TEST_REQUIRE_ENGINES")
    try:
        return run(args.binary, arguments, args.timeout, args.mode, os.environ, args.output)
    except (OSError, ValueError) as error:
        print(f"unit root launcher: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    host_process.enter()
    sys.exit(main())
