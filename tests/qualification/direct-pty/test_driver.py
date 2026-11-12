"""Cheap native controls for byte custody, observation and failure oracles."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from driver import DirectPty, ScreenCapture
from matrix import inventory, run_one
import host_process


class NavigationTests(unittest.TestCase):
    @staticmethod
    def check(screen, first, browsing, feed_rows):
        # Model fixtures read the binary argument at import; these pure screen
        # checks do not start a fixture or require a terminal emulator.
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import assert_navigation_history
        assert_navigation_history(screen, first, browsing, feed_rows)

    @staticmethod
    def screen(first, count, chip="↓"):
        return "\n".join([f"History line {n:03d}" for n in range(first, first + count)]
                         + [chip, "─" * 80, " › ", "─" * 80, " ‹ fixture"])

    def test_continuous_feed_ranges_and_reserved_chip(self):
        # Cover both the old and reclaimed-row layouts, plus other pane sizes.
        # Only the composer boundary supplies capacity; exact content and
        # anchor/distance checks still reject missing/extra rows and keys.
        for feed_rows in (8, 18, 19, 27):
            live_first = 101 - feed_rows
            self.check(self.screen(live_first, feed_rows - 1, "TD4 history end\n"), live_first, False, feed_rows)
            for back in (1, 3, feed_rows // 2, 2 * (feed_rows // 2)):
                first = live_first - back
                with self.subTest(feed_rows=feed_rows, first=first):
                    self.check(self.screen(first, feed_rows), first, True, feed_rows)
                    for actual, count in ((first, feed_rows + 1), (first, feed_rows - 1),
                                          (first - 1, feed_rows), (first + 1, feed_rows)):
                        with self.assertRaisesRegex(AssertionError, "navigation (history anchor/distance|feed capacity changed)"):
                            self.check(self.screen(actual, count), first, True, feed_rows)
            for chip in ("", "↓ 1 new"):
                with self.assertRaisesRegex(AssertionError, "navigation marker"):
                    self.check(self.screen(live_first - 1, feed_rows, chip), live_first - 1, True, feed_rows)

    def test_capacity_comes_from_composer_not_history_count(self):
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import navigation_rows, navigation_first
        for rows in (8, 18, 19, 27):
            screen = self.screen(0, rows)
            self.assertEqual(navigation_rows(screen.replace("History line", "Other output")), rows)
            live_first = 101 - rows
            self.assertEqual(navigation_first(live_first, rows, {"pages": 2, "lines": 1}),
                             live_first - 2 * (rows // 2) - 1)
            with self.assertRaisesRegex(AssertionError, "navigation composer rule"):
                navigation_rows(screen.replace("─", " "))

    def test_status_work_below_long_path_viewport(self):
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import status_work

        class Terminal:
            def __init__(self, lines, feed_rows):
                self.lines, self.top, self.generation = lines, 0, 1
                self.feed_rows = feed_rows
                self.screen = self
                self.markers, self.sent = [], []

            @property
            def completed(self):
                return "\n".join(self.lines[self.top:self.top + self.feed_rows])

            def reached(self, text):
                return text in self.completed

            def marker(self, text):
                self.markers.append(text)
                assert self.reached(text), text

            def send(self, data):
                self.sent.append(data)
                self.top += max(1, self.feed_rows // 2)
                self.generation += 1

            def wait(self, predicate, *, label, after):
                assert self.generation > after and predicate(), label

        lines = [" Status · aaaaaa", "Permissions     bypass"] + ["long path continuation"] * 27 + [" Work"]
        for feed_rows in (8, 18, 19, 27):
            with self.subTest(feed_rows=feed_rows):
                page_rows = feed_rows // 2
                tty = Terminal(lines, feed_rows)
                status_work(tty, "aaaaaa", 1024, feed_rows)
                self.assertEqual(tty.markers, [" Status · ", " · aaaaaa", "Permissions     "])
                pages = (len(lines) - feed_rows + page_rows - 1) // page_rows
                self.assertEqual(tty.sent, [b"\x1b[6~"] * pages)
                self.assertTrue(tty.reached(" Work"))
                # Missing Work must fail within a document-derived key budget.
                missing = Terminal(lines[:-1] + ["missing heading"], feed_rows)
                with self.assertRaisesRegex(AssertionError, "status Work within bounded page"):
                    status_work(missing, "aaaaaa", 1024, feed_rows)
                self.assertLessEqual(len(missing.sent), (14 * 2 + 4 + 2 * 26 + page_rows - 1) // page_rows)

    def test_all_navigation_vectors_keep_their_input_intent(self):
        rows = inventory()
        self.assertEqual(len(rows), 51)
        navigation = {row["name"]: row for row in rows if row["scenario"] == "navigation"}
        self.assertEqual(set(navigation), {
            "key-pgup", "key-pgdn", "key-shift-pgup", "key-shift-up",
            "key-up-csi", "key-up-ss3", "key-end-csi-f", "key-end-ss3-f",
            "key-end-csi-4", "key-esc", "wheel-alt-scroll", "status"})
        for name, encoded in (("key-end-csi-f", b"\x1b[F"),
                              ("key-end-ss3-f", b"\x1bOF"),
                              ("key-end-csi-4", b"\x1b[4~")):
            self.assertEqual(navigation[name]["return_chunks"][0]["hex"], encoded.hex())
        self.assertEqual([step["back"] for step in navigation["key-pgdn"]["middle"]], [{"pages": 1, "lines": 0}])
        self.assertEqual([step["back"] for step in navigation["wheel-alt-scroll"]["middle"]],
                         [{"pages": 0, "lines": 2}, {"pages": 0, "lines": 1}])


class ExitTests(unittest.TestCase):
    def test_leave_sends_ctrl_c_then_checks_restoration(self):
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import leave
        calls = []
        class Terminal:
            def send(self, data):
                calls.append(("send", data))
            def finish(self):
                calls.append(("finish",))
        leave(Terminal())
        self.assertEqual(calls, [("send", b"\x03"), ("finish",)])


class DriverTests(unittest.TestCase):
    def test_master_bytes_and_restoration(self):
        # Includes NUL, invalid UTF-8, CR, control, escape and paste bytes. A
        # text encoder, ICRNL, tmux key substitution or short write loses here.
        payload = b"A\x00\xff\r\x12\x1b[D\x1b[200~x\nY\x1b[201~"
        child = r'''
import os, sys, termios, tty
original = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b'\x1b[?1049h\x1b[?2026hready\x1b[?2026l')
    data = b''
    while len(data) < int(sys.argv[1]):
        data += os.read(0, int(sys.argv[1]) - len(data))
    os.write(1, b'\x1b[?2026h\r\n' + data.hex().encode() + b'\x1b[?2026l')
finally:
    termios.tcsetattr(0, termios.TCSANOW, original)
    os.write(1, b'\x1b[?1049l\x1b[?2004l\x1b[?25h')
'''
        with tempfile.TemporaryDirectory() as directory:
            with DirectPty([sys.executable, "-c", child, str(len(payload))], env=os.environ,
                           cwd=directory, output=directory) as tty:
                tty.marker("ready")
                tty.send(payload)
                tty.finish()
            self.assertEqual((pathlib.Path(directory) / "input.bin").read_bytes(), payload)
            self.assertIn(payload.hex().encode(), (pathlib.Path(directory) / "output.bin").read_bytes())
            events = [json.loads(line) for line in (pathlib.Path(directory) / "events.jsonl").read_text().splitlines()]
            self.assertEqual([event["event"] for event in events], ["launch", "observed", "input", "retired"])

    def test_open_or_erased_frame_does_not_establish_readiness(self):
        screen = ScreenCapture()
        screen.feed(b"\x1b[?1049h\x1b[?2026hready")
        self.assertFalse(screen.reached("ready"), "open frame supplied readiness")
        screen.feed(b"\r\x1b[2Kgone\x1b[?2026l")
        self.assertFalse(screen.reached("ready"), "erased marker supplied readiness")
        screen.feed(b"\x1b[?2026h\r\x1b[2Kready\x1b[?2026l")
        self.assertTrue(screen.reached("ready"))

    def test_restoration_excludes_only_darwin_kernel_bits(self):
        # Exercise finish's real restoration boundary. Model the Darwin-only
        # write-history and collector-mark bits even on Linux, but never
        # excuse NONBLOCK, access mode, APPEND or an unknown bit alongside them.
        import fcntl
        child = "import os; os.write(1, b'\\x1b[?1049l\\x1b[?2004l\\x1b[?25h')"
        for platform, delta, accepted in (
            ("darwin", 0x10000, True),
            ("linux", 0x10000, False),
            ("darwin", 0x10000 | os.O_NONBLOCK, False),
            ("darwin", 0x10000 | os.O_RDWR, False),
            ("darwin", 0x10000 | os.O_APPEND, False),
            ("darwin", 0x10000 | 0x200000, False),
            ("darwin", 0x1000, True),
            ("darwin", 0x1000 | 0x10000, True),
            ("linux", 0x1000, False),
            ("darwin", 0x1000 | os.O_NONBLOCK, False),
        ):
            with self.subTest(platform=platform, delta=hex(delta)), tempfile.TemporaryDirectory() as directory:
                with DirectPty([sys.executable, "-c", child], env=os.environ,
                               cwd=directory, output=directory) as tty:
                    real_fcntl = fcntl.fcntl
                    def flags(fd, command, *args):
                        value = real_fcntl(fd, command, *args)
                        return tty.flags ^ delta if fd == tty.slave and command == fcntl.F_GETFL else value
                    with patch("driver.sys.platform", platform), patch("driver.fcntl.fcntl", flags):
                        if accepted:
                            tty.finish()
                        else:
                            with self.assertRaisesRegex(AssertionError, "file flags"):
                                tty.finish()

    def test_primary_failure_survives_cleanup_and_child_retires(self):
        # Exercise the actual context-manager owner, not just dispose_all.
        child = "import time; time.sleep(30)"
        with tempfile.TemporaryDirectory() as directory:
            tty = DirectPty([sys.executable, "-c", child], env=os.environ, cwd=directory, output=directory)
            with self.assertRaisesRegex(RuntimeError, "original body failure"):
                with tty:
                    raise RuntimeError("original body failure")
            self.assertIsNotNone(tty.process.poll())
            with self.assertRaises(OSError):
                os.fstat(tty.master)

    def test_pass_receipt_requires_successful_worker_exit(self):
        # A real child writes a valid receipt, then exits normally, fails, or
        # dies by signal. The controller must not turn the last two green.
        launch = subprocess.Popen
        for status in (0, 17, -signal.SIGTERM):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                def child(args, **kwargs):
                    output = args[args.index("--output") + 1]
                    source = '''import json, os, pathlib, signal, sys
pathlib.Path(sys.argv[1], "result.json").write_text(json.dumps({"row": "probe", "status": "passed"}))
status = int(sys.argv[2])
if status < 0:
    os.kill(os.getpid(), -status)
sys.exit(status)
'''
                    return launch([sys.executable, "-c", source, output, str(status)], **kwargs)
                with patch("matrix.subprocess.Popen", child):
                    result = run_one(pathlib.Path(sys.executable), pathlib.Path(directory), {"name": "probe"})
                self.assertEqual(result["worker_exit"], status)
                self.assertEqual(result["status"], "passed" if status == 0 else "exit-receipt-mismatch")


if __name__ == "__main__":
    host_process.enter()
    unittest.main()
