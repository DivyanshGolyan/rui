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

        def hold_refresh():
            ready_r, ready_w = os.pipe()
            release_r, release_w = os.pipe()
            try:
                child = subprocess.Popen(
                    [actor, "hold-refresh", path], stderr=subprocess.PIPE, text=True,
                    pass_fds=(ready_w, release_r),
                    env={**os.environ, "RUI_CREDENTIAL_ACTOR_READY_FD": str(ready_w),
                         "RUI_CREDENTIAL_ACTOR_RELEASE_FD": str(release_r)},
                )
                children.append(child)
                os.close(ready_w)
                ready_w = -1
                os.close(release_r)
                release_r = -1
                assert select.select([ready_r], [], [], 20)[0], "refresh never durably entered pending"
                assert os.read(ready_r, 1) == b"1"
                return child, release_w
            except BaseException:
                os.close(release_w)
                raise
            finally:
                os.close(ready_r)
                if ready_w >= 0:
                    os.close(ready_w)
                if release_r >= 0:
                    os.close(release_r)

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
        assert command("inspect") == "2 ready rui-test-account"
        codex.credentials(path)
        claimant, release_w = hold_refresh()
        try:
            waiter = subprocess.Popen([actor, "lease", path], stderr=subprocess.PIPE, text=True)
            children.append(waiter)
            os.write(release_w, b"1")
            _, claimant_error = claimant.communicate(timeout=20)
            assert claimant.returncode == 0, claimant_error
            _, observed = waiter.communicate(timeout=20)
            assert waiter.returncode == 0 and observed.strip() == "2 rui-test-account", observed
        finally:
            os.close(release_w)

        codex.credentials(path)
        claimant, release_w = hold_refresh()
        try:
            claimant.kill()
            claimant.communicate(timeout=20)
        finally:
            os.close(release_w)
        assert command("inspect") == "1 refresh_pending rui-test-account"
        rejected = subprocess.run([actor, "lease", path], capture_output=True, text=True, timeout=20)
        assert rejected.returncode != 0 and "RefreshRequiresLogin" in rejected.stderr, rejected.stderr
        command("login")
        command("stale-refresh")
        assert command("inspect") == "2 ready account-B"
        print("Codex native credential mutation passed: one refresh claimant, live contender waits for committed generation, claimant crash requires login, stale completion cannot replace new account")
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=10)
        shutil.rmtree(root)


if __name__ == "__main__":
    run(pathlib.Path(sys.argv[1]).resolve())
