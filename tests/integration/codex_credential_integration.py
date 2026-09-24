#!/usr/bin/env python3
"""Native cross-process mutation of Rui's credential owner, without live tokens."""

import fcntl
import os
import pathlib
import select
import shutil
import subprocess
import sys
import tempfile
import time

import codex_integration as codex


def run(actor):
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-credential.")).resolve()
    private = root / "private"
    private.mkdir(mode=0o700)
    path = private / "codex.json"
    children = []
    try:
        codex.credentials(path)
        def command(action):
            return subprocess.run([actor, action, path], capture_output=True, text=True,
                                  timeout=20, check=True).stderr.strip()

        assert command("inspect") == "1 ready rui-test-account"
        read_fd, write_fd = os.pipe()
        try:
            with open(private / ".codex.json.lock", "r+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                for _ in range(2):
                    children.append(subprocess.Popen(
                        [actor, "claim", path], stderr=subprocess.PIPE, text=True,
                        pass_fds=(write_fd,),
                        env={**os.environ, "RUI_CREDENTIAL_ACTOR_READY_FD": str(write_fd)},
                    ))
                os.close(write_fd)
                write_fd = -1
                ready = b""
                deadline = time.monotonic() + 20
                while len(ready) < 2:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and select.select([read_fd], [], [], remaining)[0], "actors did not reach lock"
                    chunk = os.read(read_fd, 2 - len(ready))
                    assert chunk, "actor exited before lock barrier"
                    ready += chunk
                assert ready == b"11"
            results = []
            for child in children:
                _, stderr = child.communicate(timeout=20)
                assert child.returncode == 0, stderr
                results.append(stderr.strip())
            assert sorted(results) == ["claimed", "lost"], results
        finally:
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)
        assert command("inspect") == "1 refresh_pending rui-test-account"
        command("login")
        command("stale-refresh")
        assert command("inspect") == "2 ready account-B"
        print("Codex native credential mutation passed: two processes claim one generation, explicit login supersedes pending refresh, stale completion cannot replace account")
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=10)
        shutil.rmtree(root)


if __name__ == "__main__":
    run(pathlib.Path(sys.argv[1]).resolve())
