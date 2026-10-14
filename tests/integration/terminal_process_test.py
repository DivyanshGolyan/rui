"""Native ownership checks for ordinary terminal conversations."""

import errno
import os
import pty
import select
import sys
import unittest
from unittest.mock import patch

from host_process import stop_process
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
