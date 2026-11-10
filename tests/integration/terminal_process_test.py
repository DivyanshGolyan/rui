"""Native checks for processes on test PTYs: each runs as the foreground job
of the PTY's session leader, and its conversation owner retires it."""

import errno
import fcntl
import json
import os
import pty
import resource
import select
import signal
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
from unittest.mock import patch

from host_process import stop_process, wait_for
from terminal_process import close_pty, CAPTURES, answers_to, open_pty, register_capture, spawn, terminal_process
from terminal_screen import ScreenCapture


# libghostty-vt's answer to DA1: a VT220 with ANSI colour.
DEVICE_ANSWER = b"\x1b[?62;22c"


class TerminalProcessTest(unittest.TestCase):
    def setUp(self):
        self.descriptors = []
        real_openpty = pty.openpty

        def allocate():
            pair = real_openpty()
            self.descriptors.extend(pair)
            return pair

        self.allocation = patch("terminal_process.pty.openpty", side_effect=allocate)
        self.allocation.start()

    def tearDown(self):
        self.allocation.stop()
        # Keep a broken owner from leaking descriptors during a negative control.
        for fd in self.descriptors:
            try:
                close_pty(fd)
            except OSError as error:
                if error.errno != errno.EBADF:
                    raise

    def assert_descriptors_closed(self):
        self.assertEqual(len(self.descriptors), 2)
        for fd in self.descriptors:
            with self.assertRaises(OSError) as raised:
                os.fstat(fd)
            self.assertEqual(raised.exception.errno, errno.EBADF)

    def test_wait_drains_writer_and_opt_out_preserves_output(self):
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        os.write(slave, b"pending")
        # The opt-out must leave PTY output unread.
        wait_for(lambda: True, "without drainage", drain=False)
        self.assertEqual(received, b"")
        self.assertTrue(select.select([master], [], [], 0)[0])
        writer = subprocess.Popen([sys.executable, "-c", "import os; os.write(1, b'x' * 131072)"], stdout=slave)
        self.addCleanup(stop_process, writer, timeout=5)
        wait_for(lambda: writer.poll() is not None, "PTY writer", timeout=10)
        self.assertEqual(writer.returncode, 0)
        wait_for(lambda: len(received) == 131079, "all PTY output")

    def test_other_thread_wait_does_not_steal_terminal_output(self):
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        os.write(slave, b"for the reader")
        self.assertTrue(select.select([master], [], [], 5)[0])
        worker = threading.Thread(target=lambda: wait_for(lambda: True, "worker observation"))
        worker.start()
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive(), "worker wait did not finish")
        self.assertEqual(received, b"")
        self.assertTrue(select.select([master], [], [], 0)[0], "worker stole the reader's bytes")
        self.assertEqual(os.read(master, 14), b"for the reader")
        os.write(slave, b"owner drains")
        wait_for(lambda: received == b"owner drains", "owner drainage")

    def test_continuously_readable_terminal_yields_to_observer(self):
        import human_cli_fixture as human
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        # Simulate a chatty PTY without a timing-dependent writer. The last
        # empty chunk bounds the old unbounded loop for the negative control.
        for observe in (lambda: wait_for(lambda: len(received), "continuous output"),
                        lambda: human.draining(master, lambda: len(received), received.extend)()):
            received.clear()
            with patch("terminal_process.select.select", return_value=([master], [], [])), \
                 patch("terminal_process.os.read", side_effect=[b"x"] * 10 + [b""]):
                self.assertEqual(observe(), 1)

    def test_reused_pipe_is_not_drained(self):
        master, slave = open_pty()
        register_capture(master, type("Capture", (), {"feed": lambda _, data: self.fail(data)})())
        close_pty(master)
        read, write = os.pipe()
        self.addCleanup(close_quietly, write)
        if read != master:
            os.dup2(read, master)
            os.close(read)
        os.write(write, b"keep")
        wait_for(lambda: True, "unrelated pipe")
        self.assertEqual(os.read(master, 4), b"keep")
        self.assertNotIn(master, CAPTURES)

    def test_reused_other_pty_is_not_drained(self):
        master, slave = open_pty()
        register_capture(master, type("Capture", (), {"feed": lambda _, data: self.fail(data)})())
        close_pty(master, slave)
        other_master, other_slave = pty.openpty()
        self.assertEqual(other_master, master)
        os.write(other_slave, b"keep")
        wait_for(lambda: True, "unrelated PTY")
        self.assertEqual(os.read(other_master, 4), b"keep")
        self.assertNotIn(master, CAPTURES)

    def test_read_terminal_accepts_already_drained_frame(self):
        import human_cli_fixture as human
        master, slave = open_pty()
        human.terminal_capture(master)
        os.write(slave, b"\x1b[?2026h\x1b[H\x1b[2Jalready visible\x1b[?2026l")
        wait_for(lambda: "already visible" in human.current_screen(master), "drained marker")
        self.assertIn("already visible", human.read_terminal(master, "already visible", timeout=.1))
        with self.assertRaises(AssertionError):
            human.read_terminal(master, "already visible", timeout=.05, fresh=True)
        os.write(slave, "\x1b[?2026h\x1b[H\x1b[2Janswer\r\n › \x1b[?2026l".encode())
        wait_for(lambda: "answer" in human.current_screen(master), "drained composer")
        self.assertIn("answer", human.read_terminal(master, "answer", timeout=.1, composer=True))

    def test_failed_launch_closes_terminal(self):
        with self.assertRaises(FileNotFoundError):
            with terminal_process(["/nonexistent/rui-terminal-test"], env=os.environ):
                self.fail("failed launch entered the conversation")
        self.assert_descriptors_closed()

    def start_dialogue(self, process, master):
        self.addCleanup(stop_process, process, timeout=5)
        self.assertTrue(select.select([master], [], [], 5)[0], "child did not write readiness")
        self.assertEqual(os.read(master, 1), b"!")
        self.assertIsNone(process.poll(), "child must still need retirement")
        for fd in self.descriptors:
            os.fstat(fd)

    def assert_retired(self, process):
        # The leader reported the job's status after reaping it; the kernel
        # must agree that no such process remains.
        self.assertIsNotNone(process.returncode)
        with self.assertRaises(ProcessLookupError):
            os.kill(process.pid, 0)
        self.assert_descriptors_closed()

    def test_scope_retires_live_child(self):
        with terminal_process(child(), env=os.environ) as (process, master):
            self.start_dialogue(process, master)
        self.assert_retired(process)

    def test_body_failure_stays_primary_when_close_fails(self):
        primary = AssertionError("conversation assertion failed")
        real_close = os.close

        def close(fd):
            real_close(fd)
            if fd == self.descriptors[0]:
                raise OSError("injected master close failure")

        with patch("terminal_process.os.close", side_effect=close):
            with self.assertRaises(AssertionError) as raised:
                with terminal_process(child(), env=os.environ) as (process, master):
                    self.start_dialogue(process, master)
                    raise primary
        self.assertIs(raised.exception, primary)
        self.assertIn("injected master close failure", " ".join(primary.__notes__))
        self.assert_retired(process)

    def test_stop_failure_fails_successful_body_and_closes_terminal(self):
        failure = OSError("injected retirement failure")

        def stop(process, **kwargs):
            # The slave must remain alive until child retirement on Darwin.
            for fd in self.descriptors:
                os.fstat(fd)
            stop_process(process, **kwargs)
            raise failure

        with patch("terminal_process.stop_process", side_effect=stop):
            with self.assertRaises(OSError) as raised:
                with terminal_process(child(), env=os.environ) as (process, master):
                    self.start_dialogue(process, master)
        self.assertIs(raised.exception, failure)
        self.assert_retired(process)

    def job(self, source, slave, **options):
        """Run Python `source` as a job on `slave`."""
        options.setdefault("stdout", slave)
        options.setdefault("stderr", slave)
        process = spawn([sys.executable, "-I", "-c", source], stdin=slave, **options)
        self.addCleanup(stop_process, process, timeout=5)
        return process

    def reporter(self):
        """A pipe whose write end sits at a number no stdio uses; returns
        (read end, write end). The fixture closes the write end once passed."""
        read, write = os.pipe()
        high = fcntl.fcntl(write, fcntl.F_DUPFD, 37)
        os.close(write)
        self.addCleanup(close_quietly, read)
        return read, high

    def report(self, read):
        """What the job wrote to the reporter, once it closed its end."""
        data = b""
        deadline = time.monotonic() + 5
        while True:
            remaining = deadline - time.monotonic()
            self.assertTrue(remaining > 0 and select.select([read], [], [], remaining)[0],
                            ("the job never finished its report", data))
            chunk = os.read(read, 65536)
            if not chunk:
                return json.loads(data)
            data += chunk

    def test_job_owns_the_terminal_in_the_foreground(self):
        master, slave = open_pty()
        read, write = self.reporter()
        process = self.job(OWNER.replace("REPORT", str(write)), slave, pass_fds=(write,))
        os.close(write)
        seen = self.report(read)
        self.assertEqual(seen["tty"], "opened", seen)
        self.assertTrue(seen["same_terminal"], "/dev/tty is not the PTY on stdin")
        self.assertTrue(seen["foreground"], seen)
        # The three bytes it wrote stay unread: its exit must not wait for them.
        self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(changed(termios.tcgetattr(slave)), (False, 7), "the PTY lost the job's termios")
        fresh = os.open(os.ttyname(slave), os.O_RDWR | os.O_NOCTTY)
        try:
            self.assertEqual(changed(termios.tcgetattr(fresh)), (False, 7))
        finally:
            os.close(fresh)
        self.assertEqual(os.read(master, 16), b"abc")
        # Why the PTY survives on Darwin: the job never led the session.
        self.assertTrue(seen["group_leader"], seen)
        self.assertFalse(seen["session_leader"], seen)
        self.assertEqual(seen["session"], process.leader.process.pid, seen)

    def test_shell_leaves_the_terminal_usable(self):
        # On Darwin a shell that leads its own session revokes the PTY on exit.
        master, slave = open_pty()
        shell = spawn(["bash", "-c", "sleep 0.2"], stdin=slave, stdout=slave, stderr=slave)
        self.addCleanup(stop_process, shell, timeout=5)
        self.assertEqual(shell.wait(timeout=5), 0)
        termios.tcgetattr(slave)
        os.write(master, b"ping\n")
        self.assertTrue(select.select([slave], [], [], 5)[0], "input never reached the slave")
        self.assertEqual(os.read(slave, 16), b"ping\n")
        os.write(slave, b"pong")
        echoed = b""
        while b"pong" not in echoed:
            self.assertTrue(select.select([master], [], [], 5)[0], echoed)
            echoed += os.read(master, 64)
        read, write = self.reporter()
        process = self.job(OWNER.replace("REPORT", str(write)), slave, pass_fds=(write,))
        os.close(write)
        seen = self.report(read)
        self.assertEqual((seen["tty"], seen["foreground"]), ("opened", True), seen)
        self.assertEqual(process.wait(timeout=5), 0)

    def test_status_relays_through_the_leader(self):
        master, slave = open_pty()
        self.assertEqual(self.job("import sys; sys.exit(3)", slave).wait(timeout=5), 3)
        sleeper = self.job("import time; time.sleep(30)", slave)
        self.assertIsNone(sleeper.poll())
        sleeper.kill()
        self.assertEqual(sleeper.wait(timeout=5), -signal.SIGKILL)
        # ^C with ISIG on reaches the foreground job only.
        interrupted = self.job("import os, time; os.write(1, b'R'); time.sleep(30)", slave,
                               default_signals=(signal.SIGINT,))
        self.assertEqual(os.read(master, 1), b"R")
        os.write(master, b"\x03")
        try:
            interrupted.wait(timeout=5)
        except subprocess.TimeoutExpired:
            seen = subprocess.run(["ps", "-o", "pid,pgid,tpgid,stat,command", "-p",
                                   f"{interrupted.pid},{interrupted.leader.process.pid}"],
                                  capture_output=True, text=True).stdout
            raise AssertionError(("^C did not end the foreground job",
                                  bool(termios.tcgetattr(slave)[3] & termios.ISIG), seen)) from None
        self.assertEqual(interrupted.returncode, -signal.SIGINT)
        self.assertIsNone(interrupted.leader.process.poll(), "^C reached the leader")
        self.assertEqual(self.job("pass", slave).wait(timeout=5), 0)

    def test_descriptors_arrive_at_their_numbers(self):
        master, slave = open_pty()
        read, write = self.reporter()
        # Below the fixture's own limit, which a job inherits (macOS starts at 256).
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        process = self.job(DESCRIPTORS.replace("REPORT", str(write)), slave, stderr=subprocess.PIPE,
                           pass_fds=(write,), rlimits={resource.RLIMIT_NOFILE: (soft - 1, hard)})
        os.close(write)
        seen = self.report(read)
        self.assertEqual(seen["held"], [0, 1, 2, write], "the job holds descriptors it was not given")
        self.assertEqual(seen["nofile"], soft - 1)
        self.assertEqual(process.communicate(timeout=5), (None, b"err-text"))
        self.assertEqual(process.returncode, 0)
        for args, cwd in ((["/nonexistent/rui-terminal-test"], None), (["rui-terminal-test-missing"], None),
                          (["true"], "/nonexistent")):
            with self.assertRaises(FileNotFoundError):
                spawn(args, cwd=cwd, stdin=slave, stdout=slave, stderr=slave)

    def test_closed_terminal_hangs_up_job_and_leader(self):
        master, slave = open_pty()
        process = self.job("import os, time; os.write(1, b'R'); time.sleep(30)", slave,
                           default_signals=(signal.SIGHUP,))
        self.assertEqual(os.read(master, 1), b"R")
        close_pty(master)
        self.assertEqual(process.wait(timeout=5), -signal.SIGHUP)
        self.assertEqual(process.leader.process.wait(timeout=5), 0)

    def test_fixture_crash_leaves_no_process(self):
        # Another process holds the master, so only the control socket tells
        # the leader its fixture is gone.
        master, slave = open_pty()
        marker = os.path.join(self.enterContext(tempfile.TemporaryDirectory()), "hangup")
        fixture = subprocess.Popen([sys.executable, "-c", CRASHING_FIXTURE, os.path.dirname(os.path.abspath(__file__)),
                                    str(slave), marker], pass_fds=(slave,), stdout=subprocess.PIPE)
        self.addCleanup(fixture.stdout.close)
        pids = json.loads(fixture.stdout.readline())
        self.assertEqual(os.read(master, 1), b"R")
        fixture.kill()
        fixture.wait()
        wait_for(lambda: [pid for pid in pids if running(pid)], "the job and leader to end with their fixture",
                 ready=lambda survivors: not survivors)
        with open(marker) as seen:
            self.assertEqual(seen.read(), "SIGHUP")

    def converse(self, source, env=None):
        """Run `source` on a fresh PTY; return (process, master)."""
        master, slave = open_pty()
        process = spawn([sys.executable, "-c", source], env=env, stdin=slave, stdout=slave,
                        stderr=subprocess.PIPE)
        self.addCleanup(stop_process, process, timeout=5)
        return process, master

    def output(self, process, master, until, capture=None):
        """Read the master, as fixtures do, until it holds `until`; a
        `capture` sees each read, as a fixture's screen observer does."""
        output = b""
        while until not in output:
            self.assertTrue(select.select([master], [], [], 5)[0], (output, process.poll()))
            chunk = os.read(master, 4096)
            if capture is not None:
                capture.feed(chunk)
            output += chunk
        return output

    def test_answers_reach_the_terminal_the_command_reads(self):
        # stdin and stdout on different PTYs: the observer of stdout's master
        # sees the request, and its terminal answers on stdin's, where vaxis
        # reads.
        input_master, input_slave = open_pty()
        output_master, output_slave = open_pty()
        process = spawn([sys.executable, "-c",
                         "import os, sys, tty\n"
                         "tty.setraw(0)\n"
                         "os.write(1, b'\\x1b[c')\n"
                         f"answer = os.read(0, {len(DEVICE_ANSWER)})\n"
                         "os.write(1, b'answer=' + answer.hex().encode() + b'.')\n"],
                        stdin=input_slave, stdout=output_slave, stderr=subprocess.PIPE)
        self.addCleanup(stop_process, process, timeout=5)
        capture = ScreenCapture(reply=answers_to(output_master))
        self.assertIn(b"answer=" + DEVICE_ANSWER.hex().encode() + b".",
                      self.output(process, output_master, b".", capture))
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
        self.assertFalse(select.select([output_slave], [], [], 0)[0], "answer went to the output PTY")

    def test_observer_answers_a_split_request_once_unless_silent(self):
        # The request arrives in two reads; the answer comes once, before
        # the next byte the fixture writes. A silent observer answers nothing.
        process, master = self.converse(
            "import os, sys, tty\n"
            "tty.setraw(0)\n"
            "os.write(1, b'\\x1b[')\n"
            "os.read(0, 1)\n"
            "os.write(1, b'c')\n"
            f"answer = os.read(0, {len(DEVICE_ANSWER)})\n"
            "os.write(1, b'answer=' + answer.hex().encode() + b'.')\n"
            "os.read(0, 1)\n"
            "os.write(1, b'\\x1b[c')\n"
            "os.write(1, b'next=' + os.read(0, 1) + b'.')\n")
        capture = ScreenCapture(reply=answers_to(master))
        self.output(process, master, b"\x1b[", capture)
        os.write(master, b"g")
        self.assertIn(b"answer=" + DEVICE_ANSWER.hex().encode() + b".", self.output(process, master, b".", capture))
        capture = ScreenCapture()
        os.write(master, b"g")
        self.output(process, master, b"\x1b[c", capture)
        os.write(master, b"z")
        self.assertIn(b"next=z.", self.output(process, master, b"next=", capture))
        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())


# Reports how the job sees its terminal, changes its termios through /dev/tty,
# then writes three bytes nobody reads.
OWNER = """
import errno, json, os, termios
seen = {"session": os.getsid(0), "session_leader": os.getsid(0) == os.getpid(),
        "group_leader": os.getpgrp() == os.getpid()}
try:
    tty = os.open("/dev/tty", os.O_RDWR)
except OSError as error:
    seen["tty"] = errno.errorcode[error.errno]
else:
    seen["tty"] = "opened"
    seen["foreground"] = os.tcgetpgrp(tty) == os.getpgrp()
    attributes = termios.tcgetattr(tty)
    attributes[3] &= ~termios.ECHO
    attributes[6][termios.VMIN] = 7
    termios.tcsetattr(tty, termios.TCSANOW, attributes)
    stdin = termios.tcgetattr(0)
    seen["same_terminal"] = not stdin[3] & termios.ECHO and stdin[6][termios.VMIN] in (7, b"\\x07")
os.write(REPORT, json.dumps(seen).encode())
os.write(1, b"abc")
"""

DESCRIPTORS = """
import json, os, resource, sys
held = []
for fd in range(4096):
    try:
        os.fstat(fd)
        held.append(fd)
    except OSError:
        pass
sys.stderr.write("err-text")
os.write(REPORT, json.dumps({"held": held, "nofile": resource.getrlimit(resource.RLIMIT_NOFILE)[0]}).encode())
"""

# Starts one job that records a hangup, prints both pids, then waits to be killed.
CRASHING_FIXTURE = """
import json, sys, time
sys.path.insert(0, sys.argv[1])
import signal
from terminal_process import spawn
slave, marker = int(sys.argv[2]), sys.argv[3]
job = spawn([sys.executable, "-I", "-c",
    "import os, signal, sys, time\\n"
    "def hangup(*_):\\n"
    "    open(sys.argv[1], 'w').write('SIGHUP')\\n"
    "    os._exit(0)\\n"
    "signal.signal(signal.SIGHUP, hangup)\\n"
    "os.write(1, b'R')\\n"
    "time.sleep(30)\\n", marker], stdin=slave, stdout=slave, stderr=slave, default_signals=(signal.SIGHUP,))
print(json.dumps([job.leader.process.pid, job.pid]), flush=True)
time.sleep(60)
"""


def changed(attributes):
    """(ECHO, VMIN) as the OWNER job sets them."""
    minimum = attributes[6][termios.VMIN]
    return bool(attributes[3] & termios.ECHO), minimum if isinstance(minimum, int) else ord(minimum)


def running(pid):
    """Not gone and not a zombie waiting for its reaper."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return not state.startswith("Z")


def close_quietly(fd):
    try:
        os.close(fd)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise


def child():
    return [sys.executable, "-u", "-c", "import os, time; os.write(1, b'!'); time.sleep(60)"]


def prove_terminal_process():
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(TerminalProcessTest))
    assert result.wasSuccessful(), "terminal process ownership failed"
