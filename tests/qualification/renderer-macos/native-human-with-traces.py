"""Run the unchanged native renderer group, retaining its owned PTY byte streams.

Only descriptors returned by the fixture's open_pty are observed. No byte,
return value, signal, terminal setting, listener or assertion is changed.
"""
import hashlib
import json
import os
import pathlib
import resource
import runpy
import sys
import threading
import time

source, binary, destination = map(pathlib.Path, sys.argv[1:4])
selected = sys.argv[4] if len(sys.argv) == 5 else "renderer"
assert selected in ("all", "renderer", "persistent-opening", "persistent-permission")
source, binary, destination = source.resolve(), binary.resolve(), destination.resolve()
destination.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(source / "tests/integration"))
inherited_term = os.environ.get("TERM")
import terminal_process

original_open = terminal_process.open_pty
original_read, original_write = os.read, os.write
lock = threading.Lock()
descriptors = {}
serial = 0
records = 0
target = source / "tests/integration/human_cli_integration.py"


def event(value):
    global records
    with open(destination / "pty-events.jsonl", "a") as output:
        output.write(json.dumps(value) + "\n")
    records += 1


def opened(*args, **kwargs):
    global serial
    master, slave = original_open(*args, **kwargs)
    with lock:
        serial += 1
        descriptors[master] = serial
        event({"event": "open", "pty": serial, "master": master, "slave": slave, "t_ns": time.monotonic_ns()})
    return master, slave


def keep(fd, direction, data, started):
    with lock:
        number = descriptors.get(fd)
        if number is None or not data or not os.isatty(fd):
            return
        path = destination / f"pty-{number:03}-{direction}.bin"
        with open(path, "ab") as output:
            offset = output.tell()
            output.write(data)
        event({"event": direction, "pty": number, "t_ns": started, "t_end_ns": time.monotonic_ns(),
               "offset": offset, "length": len(data)})


def read(fd, size):
    started = time.monotonic_ns()
    data = original_read(fd, size)
    keep(fd, "output", data, started)
    return data


def write(fd, data):
    started = time.monotonic_ns()
    count = original_write(fd, data)
    keep(fd, "input", data[:count], started)
    return count


terminal_process.open_pty = opened
os.read, os.write = read, write
identity = {"source": str(source), "binary": str(binary), "binary_sha256": hashlib.file_digest(open(binary, "rb"), "sha256").hexdigest(),
            "target_sha256": hashlib.file_digest(open(target, "rb"), "sha256").hexdigest(), "method": "unchanged native case with owned-PTY read/write observation",
            "rlimit_nofile": resource.getrlimit(resource.RLIMIT_NOFILE),
            "selected": selected, "inherited_term": inherited_term, "pty_term": os.environ.get("TERM")}
sys.argv = [str(target), str(binary), selected]
completed = False
try:
    if selected in ("all", "renderer", "persistent-permission"):
        runpy.run_path(str(target), run_name="__main__")
    else:
        runpy.run_path(str(target))["persistent_opening_case"]()
    completed = True
finally:
    terminal_process.open_pty = original_open
    os.read, os.write = original_read, original_write
    identity.update(completed=completed, ptys=serial, events=records)
    (destination / "trace-summary.json").write_text(json.dumps(identity, indent=1))
