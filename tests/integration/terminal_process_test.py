"""Native ownership checks for ordinary terminal conversations."""

import errno
import os
import pty
import select
import subprocess
import sys
import unittest
from unittest.mock import patch

from host_process import dispose_all, stop_process
from terminal_process import terminal_process


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
                os.close(fd)
            except OSError as error:
                if error.errno != errno.EBADF:
                    raise

    def assert_descriptors_closed(self):
        self.assertEqual(len(self.descriptors), 2)
        for fd in self.descriptors:
            with self.assertRaises(OSError) as raised:
                os.fstat(fd)
            self.assertEqual(raised.exception.errno, errno.EBADF)

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
        # The kernel, not just Popen's returncode, must confirm reap.
        with self.assertRaises(ChildProcessError):
            os.waitpid(process.pid, os.WNOHANG)
        self.assert_descriptors_closed()

    def test_scope_retires_live_child(self):
        with terminal_process(child(), env=os.environ) as (process, master):
            self.start_dialogue(process, master)
        self.assert_retired(process)

    def test_exit_tail_finishes_screen_before_reentry(self):
        with patch.object(sys, "argv", [sys.argv[0], "unused-rui"]):
            import human_cli_integration as human
        master, slave = pty.openpty()
        release_read, release_write = os.pipe()
        first = second = None
        try:
            first = subprocess.Popen([sys.executable, "-c",
                "import os, sys; os.write(1, b'\x1b[?1049h\x1b[?2026hFIRST'); "
                "os.read(int(sys.argv[1]), 1); "
                "os.write(1, b'\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l')",
                str(release_read)], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                pass_fds=(release_read,))
            prefix = bytearray()
            while b"FIRST" not in prefix:
                self.assertTrue(select.select([master], [], [], 5)[0])
                chunk = os.read(master, 1024)
                self.assertTrue(chunk)
                prefix.extend(chunk)
                human.capture_for(master).feed(chunk)
            os.write(release_write, b"r")
            tail, errors = human.terminal_exit(first, master)
            self.assertEqual(first.returncode, 0, errors)
            self.assertIn(b"\x1b[?1049l", tail)
            second = subprocess.Popen([sys.executable, "-c",
                "import os; os.write(1, b'\x1b[?1049h\x1b[?2026hSECOND\x1b[?2026l')"],
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            shown = human.read_terminal(master, "SECOND")
            self.assertIn("SECOND", shown)
            self.assertNotIn("FIRST", shown)
        finally:
            dispose_all(lambda: stop_process(second, timeout=5) if second is not None else None,
                        lambda: stop_process(first, timeout=5) if first is not None else None,
                        lambda: second.stderr.close() if second is not None else None,
                        lambda: first.stderr.close() if first is not None else None,
                        lambda: os.close(release_read), lambda: os.close(release_write),
                        lambda: os.close(master), lambda: os.close(slave))
        self.assert_retired(first)
        self.assert_retired(second)

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


def child():
    return [sys.executable, "-u", "-c", "import os, time; os.write(1, b'!'); time.sleep(60)"]


def prove_terminal_process():
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(TerminalProcessTest))
    assert result.wasSuccessful(), "terminal process ownership failed"


if __name__ == "__main__":
    unittest.main()
