#!/usr/bin/env python3
"""Execute the existing selected DAGs, without caching their acceptance."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

from select_tests import execution_batches


FAILURE_STATE = re.compile(
    r"^retained (?:(?:dispatch|control) integration failure state|"
    r"terminal restoration state \(completed=False\)|native observation failure state|"
    r"canonical failure state|persistent permission failure state|opaque-Session failure state): (/.+)$")
MAX_DIRECTORIES = 16
MAX_FILES = 128
MAX_FILE_BYTES = 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024


def retain_failure_logs(states, destination, published_output=b""):
    # Native fixtures may preserve before TemporaryDirectory teardown while
    # the gate recorder also writes. One try-only directory lock keeps the
    # existing job-wide caps exact; contention is reported, never waited on.
    destination.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(destination, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Failure diagnostic retention unavailable: busy custody", file=sys.stderr)
            return
        _retain_failure_logs(states, destination, published_output)
    finally:
        os.close(descriptor)


def _retain_failure_logs(states, destination, published_output):
    """Copy bounded fixture diagnostics only; never open or query a Store.

    No SQLite, HOME, credentials, request records, provider capture, scratch,
    executables or arbitrary payload files. Symlinks and special files are not
    followed. Oversized diagnostics are omitted whole, not silently truncated.
    """
    retained = [path for path in destination.rglob("*") if path.is_file() and not path.is_symlink()]
    remaining = MAX_TOTAL_BYTES - sum(path.stat().st_size for path in retained)
    files = len(retained)
    roots = sum(path.is_dir() and not path.is_symlink() for path in destination.iterdir())
    if published_output and files < MAX_FILES and len(published_output) <= min(MAX_FILE_BYTES, remaining):
        # Exact bounded bytes already published to this job's Actions log, not
        # a new Host/provider capture. Needed when a retained root has only
        # private Store files, which must not be uploaded.
        output = destination / "selected-gate.log"
        if not output.exists():
            output.write_bytes(published_output)
            remaining -= len(published_output)
            files += 1
    for state in states[:MAX_DIRECTORIES]:
        if state.is_symlink() or not state.is_dir():
            continue
        # Stable custody across pre-teardown and post-gate calls; never replace
        # earlier evidence or reset the existing aggregate retention bounds.
        target = destination / hashlib.sha256(os.fsencode(state)).hexdigest()[:16]
        if not target.exists():
            if roots >= MAX_DIRECTORIES:
                continue
            roots += 1
        target.mkdir(parents=True, exist_ok=True)
        # Explicit fixture-owned labels and boundary metadata, no payloads.
        # Suffixes alone do not prove artifact custody/privacy.
        for directory, children, names in os.walk(state, followlinks=False):
            children[:] = sorted(name for name in children if not (
                name.startswith(".") or any(word in name.lower() for word in
                ("store", "home", "credential", "auth", "scratch", "request", "provider"))
                or (Path(directory) / name).is_symlink()))
            for name in sorted(names):
                if files >= MAX_FILES:
                    return
                if name not in ("probe.log", "pty-failure.json") and not re.fullmatch(r"observation-failure-[1-9][0-9]*\.json", name):
                    continue
                source = Path(directory) / name
                output = target / source.relative_to(state)
                if output.exists():
                    continue
                try:
                    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        info = os.fstat(stream.fileno())
                        if not stat.S_ISREG(info.st_mode) or info.st_size > min(MAX_FILE_BYTES, remaining):
                            continue
                        data = stream.read(min(MAX_FILE_BYTES, remaining) + 1)
                        if len(data) > min(MAX_FILE_BYTES, remaining):
                            continue
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(data)
                    remaining -= len(data)
                    files += 1
                except OSError as error:
                    print(f"Failure diagnostic copy unavailable: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", help="JSON array from the selector")
    parser.add_argument("--check-part", choices=("all", "execution", "callers"), default="all")
    args = parser.parse_args()
    for batch in execution_batches(json.loads(args.targets), args.check_part):
        print("Executing: " + " ".join(batch), flush=True)
        start = time.monotonic()
        states = []
        published_output = bytearray()
        with subprocess.Popen(["zig", "build", *batch, "--summary", "all"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as result:
            for line in iter(lambda: result.stdout.readline(65536), b""):
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                if published_output is not None:
                    if len(published_output) + len(line) <= MAX_FILE_BYTES:
                        published_output.extend(line)
                    else:
                        published_output = None  # Omit whole, never truncate.
                marker = FAILURE_STATE.fullmatch(line.decode("utf-8", "replace").strip())
                if marker and len(states) < MAX_DIRECTORIES:
                    state = Path(marker[1])
                    if state not in states:
                        states.append(state)
            result.wait()
        print(f"Completed {' '.join(batch)}: {time.monotonic() - start:.3f}s; exit {result.returncode}",
              flush=True)
        if result.returncode:
            destination = os.environ.get("RUI_FAILURE_ARTIFACTS")
            if destination:
                try:
                    retain_failure_logs(states, Path(destination), bytes(published_output or b""))
                except OSError as error:
                    print(f"Failure diagnostic retention unavailable: {error}", file=sys.stderr)
            raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
