#!/usr/bin/env python3
"""Execute the existing selected DAGs, without caching their acceptance."""
import argparse
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
    r"terminal restoration state \(completed=False\)): (/.+)$")
MAX_DIRECTORIES = 16
MAX_FILES = 128
MAX_FILE_BYTES = 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024


def retain_failure_logs(states, destination, published_output=b""):
    """Copy bounded fixture diagnostics only; never open or query a Store.

    No SQLite, HOME, credentials, request records, provider capture, scratch,
    executables or arbitrary payload files. Symlinks and special files are not
    followed. Oversized diagnostics are omitted whole, not silently truncated.
    """
    remaining, files = MAX_TOTAL_BYTES, 0
    destination.mkdir(parents=True, exist_ok=True)
    if published_output and len(published_output) <= min(MAX_FILE_BYTES, remaining):
        # Exact bounded bytes already published to this job's Actions log, not
        # a new Host/provider capture. Needed when a retained root has only
        # private Store files, which must not be uploaded.
        (destination / "selected-gate.log").write_bytes(published_output)
        remaining -= len(published_output)
        files += 1
    for index, state in enumerate(states[:MAX_DIRECTORIES]):
        if state.is_symlink() or not state.is_dir():
            continue
        target = destination / str(index)
        target.mkdir(parents=True, exist_ok=True)
        # The terminal fixture owns probe.log: fixed labels, no payloads.
        # Suffixes alone do not prove artifact custody/privacy.
        for directory, children, names in os.walk(state, followlinks=False):
            children[:] = sorted(name for name in children if not (
                name.startswith(".") or any(word in name.lower() for word in
                ("store", "home", "credential", "auth", "scratch", "request", "provider"))
                or (Path(directory) / name).is_symlink()))
            for name in sorted(names):
                if files >= MAX_FILES:
                    return
                if name != "probe.log":
                    continue
                source = Path(directory) / name
                try:
                    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        info = os.fstat(stream.fileno())
                        if not stat.S_ISREG(info.st_mode) or info.st_size > min(MAX_FILE_BYTES, remaining):
                            continue
                        data = stream.read(min(MAX_FILE_BYTES, remaining) + 1)
                        if len(data) > min(MAX_FILE_BYTES, remaining):
                            continue
                    output = target / source.relative_to(state)
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
