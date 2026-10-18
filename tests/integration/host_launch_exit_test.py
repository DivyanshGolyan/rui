#!/usr/bin/env python3
"""Host-launch fixture oracles; not native Host qualification."""

from contextlib import contextmanager, redirect_stderr
import errno
import io
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import Mock, patch


def check_failure_retention(root_owner, read_status):
    owner = sys.modules[read_status.__module__]
    Path = owner.pathlib.Path
    with tempfile.TemporaryDirectory(prefix="rui-launch-retention-test-") as directory:
        base = Path(directory)
        command = base / "rui"
        for status_code, cleanup_fails in ((0, False), (7, False), (0, True)):
            command.write_text(f"#!{sys.executable}\nimport sys\nprint('Host: owned but unavailable')\nprint('status diagnostic', file=sys.stderr)\nsys.exit({status_code})\n")
            command.chmod(0o700)
            destination = base / f"{status_code}-{cleanup_fails}"
            child = None
            root = None
            failure = AssertionError("ready observation failed")
            output = io.StringIO()
            def cleanup(_):
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                if cleanup_fails:
                    raise OSError(errno.EIO, "cleanup diagnostic")
            try:
                with patch.object(owner, "RUI", command), \
                        patch.object(owner, "forced_crash_cleanup", side_effect=cleanup), \
                        patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=str(destination)), redirect_stderr(output):
                    try:
                        with root_owner() as value:
                            root = Path(value)
                            store = root / "store"
                            (store / "diagnostics").mkdir(parents=True)
                            (store / "rui.sqlite3").write_bytes(b"private saved work")
                            (store / "diagnostics/host-1.jsonl").write_text('{"phase":"ready","detail":"serving"}\n')
                            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
                            if status_code:
                                try:
                                    read_status(store, os.environ)
                                except AssertionError as error:
                                    failure = error
                                    raise
                                raise AssertionError("status command failure was suppressed")
                            assert read_status(store, os.environ) == "Host: owned but unavailable\n"
                            raise failure
                    except AssertionError as error:
                        assert error is failure, "retention or cleanup replaced the original failure"
                assert root.is_dir(), "failed Host-launch root was deleted"
                assert child.poll() is not None, "failure retention leaked a live process"
                assert (store / "rui.sqlite3").read_bytes() == b"private saved work"
                assert f"retained native observation failure state: {root}" in output.getvalue()
                captured = json.loads((root / "probe.log").read_text())
                assert captured["stdout"] == "Host: owned but unavailable\n"
                assert captured["stderr"] == "status diagnostic\n" and captured["returncode"] == status_code
                metadata = json.loads(next(root.glob("observation-failure-*.json")).read_text())
                assert metadata["failure"] == "AssertionError"
                assert metadata["host_diagnostics"]["store/diagnostics/host-1.jsonl"] == '{"phase":"ready","detail":"serving"}\n'
                assert list(destination.rglob("probe.log")), "status missing from bounded CI artifacts"
                assert list(destination.rglob("observation-failure-*.json")), "diagnostics missing from bounded CI artifacts"
                assert not list(destination.rglob("rui.sqlite3")), "private Store was uploaded"
                if cleanup_fails:
                    assert any("cleanup diagnostic" in note for note in failure.__notes__)
            finally:
                if child is not None and child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                if root is not None and root.exists():
                    shutil.rmtree(root)
        with root_owner() as value:
            successful = Path(value)
        assert not successful.exists(), "successful Host-launch root was retained"
    print("Host-launch failure retention: actual status, diagnostics, private Store, process disposal and primary failure passed")


def check_process_discovery(cleanup):
    owner = sys.modules[cleanup.__module__]
    Path = owner.pathlib.Path
    with tempfile.TemporaryDirectory(prefix="rui-proc-discovery-") as directory:
        store = Path(directory).resolve() / "store"
        proc = Path("/proc")
        vanished, selected, unrelated, other_store = (proc / str(pid) for pid in (41001, 41002, 41003, 41004))
        command = [str(owner.RUI), "serve", "--store", str(store)]
        arguments = {
            selected: command,
            unrelated: [sys.executable, "-c", "pass"],
            other_store: [*command[:-1], str(store.with_name("other-store"))],
        }
        for failure in (FileNotFoundError(errno.ENOENT, "vanished"),
                        ProcessLookupError(errno.ESRCH, "vanished"),
                        OSError(errno.EIO, "discovery read failed")):
            killed = set()

            def read(path):
                if path.parent == vanished:
                    raise failure
                if int(path.parent.name) in killed:
                    raise FileNotFoundError(errno.ENOENT, "retired")
                return b"\0".join(part.encode() for part in arguments[path.parent]) + b"\0"

            def kill(pid, sig):
                assert pid == int(selected.name) and sig == owner.signal.SIGKILL, (pid, sig)
                killed.add(pid)

            # Model an enumerated process exiting before its cmdline read.
            # Keep a live match after it, plus unrelated process/Store controls.
            with patch.object(Path, "is_dir", return_value=True), \
                    patch.object(Path, "iterdir", return_value=[vanished, selected, unrelated, other_store]), \
                    patch.object(Path, "read_bytes", read), patch.object(owner.os, "kill", kill):
                if failure.errno == errno.EIO:
                    try:
                        cleanup(store)
                    except OSError as error:
                        assert error is failure, error
                    else:
                        raise AssertionError("real process-discovery read failure was suppressed")
                    assert not killed, "cleanup acted on an incomplete process census"
                else:
                    cleanup(store)
                    assert killed == {int(selected.name)}, killed
                    assert owner.matching_processes(store) == [], "retired process still discovered"
    print("Host process discovery: ENOENT/ESRCH retirement, exact Store selection and real read failures passed")


@contextmanager
def child_pty(source, *, close_slave=False):
    master, slave = pty.openpty()
    caller = None
    try:
        caller = subprocess.Popen([sys.executable, "-c", source],
            stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
        if close_slave:
            os.close(slave)
            slave = None
        yield caller, master
    finally:
        try:
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
        finally:
            try:
                os.close(master)
            finally:
                if slave is not None:
                    os.close(slave)


def check_exit_reader(wait_for_exit):
    from human_cli_integration import action_ready
    check_action_ready(action_ready)
    owner = sys.modules[wait_for_exit.__module__]
    # Exercise both platform EOF forms independently of this machine and
    # ensure unrelated read failures do not become successful EOF/reap.
    for effect in (b"", OSError(errno.EIO, "PTY EOF"), OSError(errno.EBADF, "bad descriptor")):
        caller = SimpleNamespace(args=["adapter"], poll=Mock(return_value=None), wait=Mock(return_value=17))
        output = bytearray(b"entry:")
        with patch.object(owner.select, "select", return_value=([123], [], [])), \
                patch.object(owner.os, "read", side_effect=[effect]):
            if isinstance(effect, OSError) and effect.errno == errno.EBADF:
                try:
                    wait_for_exit(caller, 123, output, time.monotonic() + 5)
                except OSError as error:
                    assert error.errno == errno.EBADF, error
                else:
                    raise AssertionError("unexpected read failure accepted as EOF")
                caller.wait.assert_not_called()
            else:
                assert wait_for_exit(caller, 123, output, time.monotonic() + 5) == 17
                caller.wait.assert_called_once()
        assert output == b"entry:", "EOF/error changed retained transcript"

    # More than three read windows, asymmetric ends, and a nonzero exit:
    # neither waiting before reading nor dropping late bytes can pass.
    payload = b"head:" + b"a" * 131072 + b"b" * 65531 + b":tail"
    source = """
import os
payload = b'head:' + b'a' * 131072 + b'b' * 65531 + b':tail'
while payload:
    count = os.write(1, payload)
    payload = payload[count:]
raise SystemExit(17)
"""
    with child_pty(source) as (caller, master):
        output = bytearray(b"entry:")
        assert wait_for_exit(caller, master, output, time.monotonic() + 5) == 17
        assert output == b"entry:" + payload, "reader lost or reordered transcript bytes"
        assert caller.returncode == 17, "reader did not reap actual caller outcome"

    # EOF is not child exit. Observe the actual monotonic operand to require
    # exactly the remaining allowance, not a fresh five seconds at reap.
    with child_pty("import os,time; os.close(1); os.close(2); time.sleep(30)", close_slave=True) as (caller, master):
        deadline = time.monotonic() + 0.2
        original_wait = caller.wait
        original_clock = time.monotonic
        last_sample = None
        waited = False

        def sample():
            nonlocal last_sample
            last_sample = original_clock()
            return last_sample

        def reap(*, timeout):
            nonlocal waited
            waited = True
            assert last_sample is not None
            assert timeout == max(0, deadline - last_sample), "renewed reap budget"
            return original_wait(timeout=timeout)

        with patch.object(owner.time, "monotonic", sample), patch.object(caller, "wait", reap):
            try:
                wait_for_exit(caller, master, bytearray(), deadline)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("EOF accepted without caller exit")
        assert waited, "reader did not exercise EOF-to-reap boundary"

    # A retained slave is quiet rather than EOF. Silence still cannot count as
    # child exit, while post-reap collection must preserve all unread bytes.
    with child_pty("import time; time.sleep(30)") as (caller, master):
        try:
            wait_for_exit(caller, master, bytearray(), time.monotonic() + 0.2)
        except subprocess.TimeoutExpired:
            assert caller.poll() is None, "quiet timeout did not hold a live child"
        else:
            raise AssertionError("quiet live terminal accepted as exited")
    with child_pty("import os; os.write(1,b'head:asymmetric-tail'); raise SystemExit(17)") as (caller, master):
        assert caller.wait(timeout=5) == 17
        output = bytearray(b"entry:")
        assert wait_for_exit(caller, master, output, time.monotonic() + 5) == 17
        assert output == b"entry:head:asymmetric-tail", "delayed collector lost unread exit output"

    with child_pty("import os; os.write(1,b'z')") as (caller, master):
        output = bytearray(b"x" * (1024 * 1024 - 2))
        assert wait_for_exit(caller, master, output, time.monotonic() + 5) == 0
        assert output == b"x" * (1024 * 1024 - 2) + b"z", "below-bound bytes lost"

    # Cross the fixture's strict 1-MiB retained transcript bound with one
    # actual byte; failure must preserve, not silently truncate, prior bytes.
    with child_pty("import os; os.write(1,b'z')") as (caller, master):
        output = bytearray(b"x" * (1024 * 1024 - 1))
        try:
            wait_for_exit(caller, master, output, time.monotonic() + 5)
        except AssertionError as error:
            assert str(error) == "unexpected unbounded terminal output", error
        else:
            raise AssertionError("crossing output was silently accepted")
        assert output == b"x" * (1024 * 1024 - 1), "overflow altered retained bytes"

    print("host-launch exit reader: exact transcript/outcome/reap, remaining budget and overflow passed")


def check_action_ready(action_ready):
    """Real PTY saturation, followed by the OS drain/flush/notify ordering.

    Linux tcdrain may return with unread master bytes; Darwin can wait there.
    Saturation makes withheld credit deterministic on either platform without
    replacing tcdrain with a fixture notification or sleeping writer.
    """
    master, slave = pty.openpty()
    ready_read, ready_write = os.pipe()
    held_read, held_write = os.pipe()
    release_read, release_write = os.pipe()
    caller = None
    try:
        source = """
import os,sys,termios
ready,held,release = map(int,sys.argv[1:])
os.set_blocking(1, False)
count = 0
while True:
    try:
        count += os.write(1, b'q' * 4096)
        assert count < 1024 * 1024, 'PTY did not saturate'
    except BlockingIOError:
        break
os.set_blocking(1, True)
os.write(held, str(count).encode())
tail = b't' * 65536 + b':final-choice-prompt:'
while tail:
    tail = tail[os.write(1, tail):]
termios.tcdrain(1)
termios.tcflush(0, termios.TCIFLUSH)
os.write(ready, b'xx')
os.read(release, 1)
"""
        caller = subprocess.Popen([sys.executable, "-c", source,
            str(ready_write), str(held_write), str(release_read)],
            pass_fds=(ready_write, held_write, release_read),
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        assert select.select([held_read], [], [], 5)[0], "PTY saturation not reached"
        count = int(os.read(held_read, 32))
        # Execute the old pipe-only implementation at its intended assertion.
        try:
            assert select.select([ready_read], [], [], 0.05)[0], "Action input flush did not finish"
        except AssertionError as error:
            assert str(error) == "Action input flush did not finish"
            print("action-ready counterexample RED: pipe-only wait blocked with actual PTY credit withheld")
        else:
            raise AssertionError("withheld PTY credit unexpectedly completed readiness")
        assert caller.poll() is None
        output = action_ready(ready_read, master, timeout=5)
        assert output == "q" * count + "t" * 65536 + ":final-choice-prompt:", "final presentation bytes lost"
        assert os.read(ready_read, 1) == b"x", "collector consumed future readiness"
        os.write(release_write, b"x")
        _, errors = caller.communicate(timeout=5)
        assert caller.returncode == 0 and not errors, errors
    finally:
        if caller is not None and caller.poll() is None:
            caller.kill()
            caller.communicate(timeout=5)
        for fd in (master, slave, ready_read, ready_write, held_read, held_write, release_read, release_write):
            os.close(fd)

    owner = sys.modules[action_ready.__module__]
    # Original deadline, not a fresh budget after each credited output window.
    with patch.object(owner.time, "monotonic", side_effect=[10, 11, 14]), \
            patch.object(owner.select, "select", return_value=([123], [], [])) as waited, \
            patch.object(owner.os, "read", return_value=b"prefix"):
        try:
            action_ready(456, 123, timeout=3)
        except AssertionError as error:
            assert error.args[0] == ("Action input flush did not finish", b"prefix"), error
        else:
            raise AssertionError("collector renewed its deadline")
        waited.assert_called_once_with([456, 123], [], [], 2)
    print("action-ready credit: exact final transcript, one notification and original deadline passed")
