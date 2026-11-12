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
from terminal_process import (close_pty, CAPTURES, TerminalOutput, answers_to, capture_descriptors, open_pty,
                              register_capture, spawn, terminal_process)
from terminal_screen import ScreenCapture


# libghostty-vt's answer to DA1: a VT220 with ANSI colour.
DEVICE_ANSWER = b"\x1b[?62;22c"


class TerminalProcessTest(unittest.TestCase):
    def test_composer_oracles_follow_the_caret_pane(self):
        from human_cli_fixture import composer_empty, composer_ready

        for prefix in (" ", "list text│ ", "中       │ "):
            for text, caret in (("café", 6), ("x │ y", 7)):
                with self.subTest(prefix=prefix, text=text):
                    capture = ScreenCapture(columns=80, rows=4)
                    self.assertFalse(capture.draft("", 2))
                    # An earlier identical User row is not the focused draft.
                    capture.feed(("\x1b[?2026h\x1b[2J\x1b[H › " + text + "\r\n" +
                                  prefix + "› " + text + "\x1b[?2026l").encode())
                    cursor = capture.screen.cursor
                    self.assertTrue(capture.draft(text, caret))
                    self.assertFalse(capture.draft(text, caret - 1))
                    self.assertFalse(capture.draft("wrong", caret))
                    self.assertTrue(composer_ready(capture.completed, cursor.x, cursor.y))
                    self.assertFalse(composer_empty(capture.completed, cursor.y))
                    capture.feed(("\x1b[?2026h\r\x1b[2K" + prefix + "› \x1b[?2026l").encode())
                    self.assertTrue(capture.draft("", 2))
                    self.assertTrue(composer_empty(capture.completed, capture.screen.cursor.y))
                    capture.feed(b"\x1b[D")
                    self.assertFalse(capture.draft("", 2))

        from human_cli_fixture import conversation_text
        self.assertEqual(conversation_text("list│ › line1    01:23\nlist│   line2\n    │ edited 2"),
                         "› line1    01:23\n  line2\nedited 2")

    def test_overview_oracle_requires_list_footer_without_editor(self):
        from human_cli_fixture import overview_frame

        with patch("human_cli_fixture.keyed_frame") as keyed:
            overview_frame(17, lambda screen: "Settings" in screen)
        predicate = keyed.call_args.args[2]
        listed = "  + New Session\n  Settings\nenter open"
        # A list accepts keys with no editor cursor, including a cursor
        # position that could not be an input row.
        self.assertTrue(predicate(listed, 0, 0))
        self.assertFalse(predicate(listed.replace("enter open", ""), 0, 0))
        self.assertFalse(predicate(listed + "\n › Type a task", 3, 3))
        self.assertFalse(predicate(" › Type a task\ngpt-6-luna", 3, 0))

    def test_screen_theme_queries_keep_defaults_and_report_light_terminal(self):
        replies = []
        default = ScreenCapture(8, 2, reply=replies.append)
        default.feed(b"\x1b]11;?\x1b\\\x1b[?996n")
        self.assertEqual(replies, [b"\x1b]11;rgb:2828/2c2c/3434\x1b\\", b"\x1b[?997;1n"])
        replies.clear()
        day = ScreenCapture(8, 2, reply=replies.append, background=(243, 238, 226),
                            foreground=(47, 43, 37), color_scheme="light")
        day.feed(b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[?996n")
        self.assertEqual(replies, [b"\x1b]10;rgb:2f2f/2b2b/2525\x1b\\",
                                   b"\x1b]11;rgb:f3f3/eeee/e2e2\x1b\\", b"\x1b[?997;2n"])
        day.feed(b"\x1b[?2026hX\x1b[?2026l")
        self.assertEqual((day.frame.background, day.frame.foreground), ("f3eee2", "2f2b25"))
        with self.assertRaises(ValueError):
            ScreenCapture(color_scheme="sepia")

    def test_committed_style_resolves_native_palette_and_blank_backgrounds(self):
        from terminal_screen import Cell
        self.assertEqual(Cell("X", None, False), Cell("X", None, False, False))
        capture = ScreenCapture(12, 3, foreground=(47, 43, 37), background=(243, 238, 226))
        # Override a palette slot: the oracle must use the terminal's palette,
        # not a second ANSI table. Erased blank cells also retain backgrounds.
        capture.feed(b"\x1b]4;1;rgb:12/34/56\x1b\\"
                     b"\x1b[?2026h\x1b[38;5;1;48;2;1;2;3;1;2;3;4:3;7;9;53mX"
                     b"\x1b[0;48;2;4;5;6m\x1b[K\x1b[?25l\x1b[?2026l")
        frame = capture.frame
        cell = frame.cells[0][0]
        self.assertEqual(cell.fg, 1)  # Existing style oracles retain their vocabulary.
        self.assertEqual((cell.fg_rgb, cell.bg), ("123456", "010203"))
        self.assertEqual(frame.colors(cell), ("010203", "123456"))
        self.assertTrue(all((cell.bold, cell.reverse, cell.italic, cell.faint, cell.strike, cell.overline)))
        self.assertEqual(cell.underline, 3)
        self.assertEqual(frame.cells[0][1].bg, "040506")
        self.assertFalse(frame.visible)
        self.assertEqual((frame.cursor.x, frame.cursor.y), (1, 0))
        capture.feed(b"\x1b[?2026h\x1b[0mY\x1b[?25h\x1b[?2026l")
        self.assertEqual(frame.cells[0][1].data, " ")  # Immutable old commit.
        self.assertTrue(capture.frame.visible)
        self.assertEqual(capture.frame.cells[0][1].data, "Y")

    def test_mouse_encoder_obeys_terminal_modes_and_held_button(self):
        capture = ScreenCapture()
        for action in ("press", "release", "move", "wheel-up", "wheel-down"):
            self.assertEqual(capture.mouse(action, 2, 3), b"")
        capture.feed(b"\x1b[?1000h")
        self.assertEqual(capture.mouse("press", 2, 3), b"\x1b[M #$")
        self.assertEqual(capture.mouse("release", 2, 3), b"\x1b[M##$")
        self.assertEqual(capture.mouse("move", 2, 3), b"")
        capture.feed(b"\x1b[?1000l\x1b[?1002h\x1b[?1006h")
        self.assertEqual(capture.mouse("press", 2, 3), b"\x1b[<0;3;4M")
        self.assertEqual(capture.mouse("release", 2, 3), b"\x1b[<0;3;4m")
        self.assertEqual(capture.mouse("press", 2, 3, "right"), b"\x1b[<2;3;4M")
        self.assertEqual(capture.mouse("press", 2, 3, "middle"), b"\x1b[<1;3;4M")
        self.assertEqual(capture.mouse("move", 2, 3), b"")
        self.assertEqual(capture.mouse("move", 2, 3, pressed=True), b"\x1b[<32;3;4M")
        self.assertEqual(capture.mouse("wheel-up", 2, 3), b"\x1b[<64;3;4M")
        self.assertEqual(capture.mouse("wheel-down", 2, 3), b"\x1b[<65;3;4M")
        capture.feed(b"\x1b[?1002l\x1b[?1003h")
        self.assertEqual(capture.mouse("move", 2, 3), b"\x1b[<35;3;4M")
        capture.feed(b"\x1b[?1003l")
        self.assertEqual(capture.mouse("press", 2, 3), b"")

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

    def test_background_collection_drains_exited_job_before_releasing_slave(self):
        received, observation = bytearray(), {}
        completed = threading.Event()
        program = "import os, tty; tty.setraw(0); os.write(1, b'Detached. Host work continues.')"
        with terminal_process([sys.executable, "-c", program], env=os.environ) as (process, master):
            # Start collection after exit: the final drain, not the live read
            # loop, must collect the tail from the still-retained terminal.
            self.assertEqual(process.wait(timeout=5), 0)
            slave = self.descriptors[1]

            def collected(error):
                observation.update(error=error, data=bytes(received), slave_open=os.isatty(slave),
                                   raw=not (termios.tcgetattr(master)[3] & termios.ICANON))
                completed.set()

            output = TerminalOutput(process, master, received.extend, collected)
            try:
                wait_for(completed.is_set, "final retained-slave collection", drain=False)
                self.assertEqual(observation, {"error": None, "data": b"Detached. Host work continues.",
                                               "slave_open": True, "raw": True})
            finally:
                output.close()
        self.assert_descriptors_closed()

    def test_background_collection_preserves_every_chunk_and_reports_completion(self):
        received, observation = bytearray(), {}
        completed = threading.Event()
        count = 2 * 1024 * 1024
        program = ("import os, tty\ntty.setraw(0)\ndata = b'x' * " + str(count) + "\n"
                   "while data:\n n = os.write(1, data)\n data = data[n:]\nos.write(1, b'final tail')")

        def collected(error):
            observation.update(error=error, data=bytes(received), slave_open=os.isatty(self.descriptors[1]))
            completed.set()

        with terminal_process([sys.executable, "-c", program], env=os.environ,
                              feed=received.extend, collected=collected) as (process, _master):
            wait_for(completed.is_set, "continuous terminal collection", drain=False)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(observation, {"error": None, "data": b"x" * count + b"final tail", "slave_open": True})
        self.assert_descriptors_closed()

    def test_background_feed_failure_reaches_scope_disposal(self):
        entered = threading.Event()

        def feed(_data):
            entered.set()
            raise RuntimeError("terminal feed failed")

        with self.assertRaisesRegex(RuntimeError, "terminal feed failed"):
            with terminal_process(child(), env=os.environ, feed=feed):
                wait_for(entered.is_set, "failing terminal feed", drain=False)
        self.assert_descriptors_closed()

    def test_background_feed_eio_is_reported_not_mistaken_for_terminal_eof(self):
        observation = {}
        completed = threading.Event()

        def feed(_data):
            raise OSError(errno.EIO, "consumer failure")

        def collected(error):
            observation["error"] = error
            completed.set()

        with self.assertRaisesRegex(OSError, "consumer failure"):
            with terminal_process(child(), env=os.environ, feed=feed, collected=collected) as (process, _master):
                wait_for(completed.is_set, "consumer EIO outcome", drain=False)
                self.assertIsInstance(observation["error"], OSError)
                self.assertEqual(observation["error"].errno, errno.EIO)
                with self.assertRaises(OSError) as retained:
                    process.output.check()
                self.assertIs(retained.exception, observation["error"])
        self.assert_descriptors_closed()

    def test_collector_failure_does_not_replace_a_primary_body_failure(self):
        entered = threading.Event()
        failure = RuntimeError("collector failure")

        def feed(_data):
            entered.set()
            raise failure

        with self.assertRaisesRegex(ValueError, "primary body failure") as primary:
            with terminal_process(child(), env=os.environ, feed=feed, collected=lambda _error: None) as (process, _master):
                wait_for(lambda: entered.is_set() and process.output.complete, "retained collector failure", drain=False)
                with self.assertRaises(RuntimeError) as retained:
                    process.output.check()
                self.assertIs(retained.exception, failure)
                raise ValueError("primary body failure")
        self.assertTrue(any("collector failure" in note for note in primary.exception.__notes__))
        self.assert_descriptors_closed()

    def test_final_collection_callback_failure_is_shared_by_check_and_close(self):
        failure = RuntimeError("final commit failure")

        def collected(_error):
            raise failure

        with self.assertRaises(RuntimeError) as disposed:
            with terminal_process([sys.executable, "-c", "pass"], env=os.environ,
                                  feed=lambda _data: None, collected=collected) as (process, _master):
                wait_for(lambda: process.output.complete, "final collection callback", drain=False)
                with self.assertRaises(RuntimeError) as retained:
                    process.output.check()
                self.assertIs(retained.exception, failure)
        self.assertIs(disposed.exception, failure)
        self.assert_descriptors_closed()

    def test_callback_failure_keeps_the_original_collection_error(self):
        failure = RuntimeError("original collection failure")

        def feed(_data):
            raise failure

        def collected(_error):
            raise ValueError("secondary callback failure")

        with self.assertRaises(RuntimeError) as disposed:
            with terminal_process(child(), env=os.environ, feed=feed, collected=collected) as (process, _master):
                wait_for(lambda: process.output.complete, "collection and callback failure", drain=False)
                with self.assertRaises(RuntimeError) as retained:
                    process.output.check()
                self.assertIs(retained.exception, failure)
        self.assertIs(disposed.exception, failure)
        self.assertTrue(any("secondary callback failure" in note for note in failure.__notes__))
        self.assert_descriptors_closed()

    def test_wait_drains_writer_and_opt_out_preserves_output(self):
        master, slave = open_pty()
        self.assertNotIn(master, capture_descriptors())
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        self.assertIn(master, capture_descriptors())
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

    def test_wait_wakes_for_small_terminal_refills(self):
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        writer = subprocess.Popen([sys.executable, "-c", "import os; os.write(1, b'x' * 131072)"], stdout=slave)
        self.addCleanup(stop_process, writer, timeout=5)
        real_read, real_select = os.read, select.select
        just_read = False

        def small_read(fd, size):
            nonlocal just_read
            chunk = real_read(fd, min(size, 1024) if fd == master else size)
            if fd == master and chunk:
                just_read = True
            return chunk

        def refilling(readers, writers, errors, timeout=None):
            nonlocal just_read
            if readers == [master] and timeout == 0 and just_read:
                # Model Darwin's writer not having refilled its small PTY
                # buffer yet: every bounded drain batch ends after one read.
                just_read = False
                return [], [], []
            return real_select(readers, writers, errors, timeout)

        with patch("terminal_process.os.read", side_effect=small_read), \
             patch("terminal_process.select.select", side_effect=refilling):
            # Blind 25ms sleeps need at least 128 polls (3.2s). Readability
            # must wake the waiter instead, without enlarging the drain batch.
            wait_for(lambda: writer.poll() is not None and len(received) == 131072,
                     "small-buffer PTY writer", timeout=2)
            self.assertEqual(writer.returncode, 0)
        self.assertEqual(received, b"x" * 131072)

    def test_other_thread_wait_does_not_steal_terminal_output(self):
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        os.write(slave, b"for the reader")
        self.assertTrue(select.select([master], [], [], 5)[0])
        watched = []

        def worker_wait():
            watched.extend(capture_descriptors())
            wait_for(lambda: True, "worker observation")

        worker = threading.Thread(target=worker_wait)
        worker.start()
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive(), "worker wait did not finish")
        self.assertEqual(watched, [], "worker monitored another reader's PTY")
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
                 patch("terminal_process.os.read", side_effect=[b"x"] * 32 + [b""]):
                self.assertEqual(observe(), 16)

    def test_short_terminal_reads_make_progress_between_observations(self):
        master, slave = open_pty()
        received = bytearray()
        register_capture(master, type("Capture", (), {"feed": received.extend})())
        observations = []

        def observe():
            observations.append(len(received))
            return len(received) >= 65536

        # Darwin can return small chunks even with a much larger read buffer.
        with patch("terminal_process.select.select", return_value=([master], [], [])), \
             patch("terminal_process.os.read", return_value=b"x" * 128):
            wait_for(observe, "short terminal reads", interval=0)
        self.assertLessEqual(len(observations), 32)

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
        self.assertNotIn(master, capture_descriptors())

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
        self.assertNotIn(master, capture_descriptors())

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

    def test_approval_title_count_uses_one_committed_frame_not_read_history(self):
        import human_cli_fixture as human

        title = "? Check successful shell exit"
        for history, expected_titles in ((True, 2), (False, 1)):
            with self.subTest(history=history):
                master, slave = open_pty()
                capture = human.terminal_capture(master)
                capture.feed(("\x1b[?1049h\x1b[?2026h\x1b[H\x1b[2J" + title +
                              "\r\n? Needs approval\x1b[?2026l").encode())
                generation = capture.generation
                # The next frame contains the request and the choice, but its
                # final synchronized-write boundary arrives in a separate read.
                capture.feed(("\x1b[?2026h\x1b[H\x1b[2J  " + title +
                              "\r\n    $ true\r\n────────────────────────\r\n"
                              " › " + human.CHOICE + "\r\n────────────────────────").encode())
                self.assertEqual(capture.generation, generation)
                self.assertNotIn(human.CHOICE, capture.completed)
                os.write(slave, b"\x1b[?2026l")
                if history:
                    proposal = human.read_terminal(master, human.CHOICE)
                else:
                    proposal = human.keyed_frame(master, b"",
                        lambda frame, x, y: human.CHOICE in frame and title in frame)
                rows = [row.strip() for row in proposal.splitlines()]
                self.assertEqual(rows.count(title), expected_titles)
                self.assertIn("$ true", rows)
                self.assertIn(human.CHOICE, proposal)
                # The committed choice frame itself always has exactly one
                # title and the command above it, never an intermediate write.
                current = [row.strip() for row in capture.completed.splitlines()]
                self.assertEqual(current.count(title), 1)
                self.assertLess(current.index(title), current.index("› " + human.CHOICE))
                self.assertLess(current.index("$ true"), current.index("› " + human.CHOICE))

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
