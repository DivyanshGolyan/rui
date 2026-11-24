#!/usr/bin/env python3

"""Real OS temp cleaners against a live Host's endpoint (#2128).

A Host holds an exclusive flock on its interface directory D, which holds its
socket. This ages every node of D to the epoch, as days of idleness would, then
runs Apple's clean-tmps find lines against the runtime directory and, where it
exists, systemd-tmpfiles --clean. After each pass the Host must still answer,
D must still be locked by it, and D/rui.sock must remain.

Apple's find lines are BSD find (`-dx`, `-fstype local`), which GNU find rejects,
so the find pass runs on Darwin only; systemd-tmpfiles covers Linux. Ctime cannot
be aged: the kernel sets it to now on every utime, so the model in
src/host_endpoint.zig reads atime and mtime only. Runs as the fixture user; no
root is needed.

Usage: temp_cleaners.py RUI
"""

import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile

import os_semantics
from host_process import canonical_fixture_root, start_ready_process, stop_process

# crontabs-54 files/daily/110.clean-tmps with daily_clean_tmps_days=0, the
# arguments exactly as the script builds them.
APPLE_LINES = (
    ["find", "-dx", ".", "-fstype", "local", "-type", "f", "-atime", "+0", "-mtime", "+0", "-ctime", "+0", "-delete"],
    ["find", "-dx", ".", "-fstype", "local", "!", "-name", ".", "-type", "d", "-empty", "-mtime", "+0",
     "!", "-name", ".vfs_rsrc_streams_*", "-delete"],
)


def age_tree(directory):
    """Set every node of D, D included, to the epoch."""
    nodes = [directory] + [os.path.join(root, name) for root, dirs, files in os.walk(directory) for name in dirs + files]
    for node in nodes:
        os.utime(node, (0, 0), follow_symlinks=False)


def aged_probe(runtime, label):
    """A stale regular file beside D: each pass must remove it, which proves the pass ran."""
    probe = runtime / f"rui-temp-cleaners-probe-{label}-{os.getpid()}"
    probe.write_text("probe\n")
    os.utime(probe, (0, 0), follow_symlinks=False)
    return probe


def assert_endpoint_survives(binary, store, directory, label):
    socket_path = directory / "rui.sock"
    answer = subprocess.run([binary, "host", "status", "--store", store], capture_output=True, text=True, timeout=30)
    assert answer.returncode == 0, (label, answer.stdout, answer.stderr)
    assert json.loads(answer.stdout)["status"] == "ready", (label, answer.stdout)
    assert stat.S_ISSOCK(os.lstat(socket_path).st_mode), f"{label}: rui.sock was removed or replaced"
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        assert not os_semantics.try_lock(descriptor), f"{label}: the Host no longer holds D's lock"
    finally:
        os.close(descriptor)
    print(f"temp cleaners: {label}: Host answers, D is locked, rui.sock remains", flush=True)


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="rui-temp-cleaners-") as temporary:
        root = canonical_fixture_root(temporary)
        store = root / "store"
        store.mkdir(mode=0o700)
        process, fields = start_ready_process(
            [binary, "host", "serve", "--store", store, "--set", "execution.activeCapacity=1", "--set", "providers={}"],
            required_fields={"execution": "unavailable"})
        try:
            socket_path = pathlib.Path(fields["socket"])
            directory = socket_path.parent
            runtime = directory.parent
            assert len(directory.name) == 32, directory

            age_tree(directory)
            if os_semantics.DARWIN:
                probe = aged_probe(runtime, "apple")
                for line in APPLE_LINES:
                    subprocess.run(line, cwd=runtime, check=True, capture_output=True, timeout=60)
                assert not probe.exists(), "apple clean-tmps did not run: its probe survived"
                assert_endpoint_survives(binary, store, directory, "apple clean-tmps")
            else:
                print("temp cleaners: Apple's find lines are BSD find; the clean-tmps pass runs on Darwin only", flush=True)

            tmpfiles = shutil.which("systemd-tmpfiles")
            if tmpfiles is None:
                print("temp cleaners: systemd-tmpfiles not installed; systemd pass skipped", flush=True)
            else:
                config = root / "tmpfiles.conf"
                config.write_text(f"d {runtime} 0700 - - 0\n")
                age_tree(directory)
                probe = aged_probe(runtime, "systemd")
                subprocess.run([tmpfiles, "--clean", str(config)], check=True, capture_output=True, timeout=60)
                assert not probe.exists(), "systemd-tmpfiles did not run: its probe survived"
                assert_endpoint_survives(binary, store, directory, "systemd-tmpfiles")
        finally:
            stop_process(process)


if __name__ == "__main__":
    main()
