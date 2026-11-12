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
    def check(screen, first, browsing):
        # Model fixtures read the binary argument at import; these pure screen
        # checks do not start a fixture or require a terminal emulator.
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import assert_navigation_history
        assert_navigation_history(screen, first, browsing)

    @staticmethod
    def screen(first, count, chip="↓"):
        return "\n".join([f"History line {n:03d}" for n in range(first, first + count)] + [chip])

    def test_continuous_feed_ranges_and_reserved_chip(self):
        self.check(self.screen(83, 17, "TD4 history end\n"), 83, False)
        for first in (65, 74, 80, 81, 82):
            with self.subTest(first=first):
                self.check(self.screen(first, 18), first, True)
                # Reject the old live-sized screen and any one-row
                # distance/direction error, not merely marker presence.
                for actual, count in ((first, 19), (first - 1, 18), (first + 1, 18)):
                    with self.assertRaisesRegex(AssertionError, "navigation history anchor/distance"):
                        self.check(self.screen(actual, count), first, True)
        for chip in ("", "↓ 1 new"):
            with self.assertRaisesRegex(AssertionError, "navigation marker"):
                self.check(self.screen(74, 18, chip), 74, True)

    def test_chat_info_observes_fields_footer_and_fitted_folder(self):
        with patch.object(sys, "argv", [sys.argv[0], sys.executable]):
            from scenarios import chat_info_ready

        class Terminal:
            def __init__(self, lines):
                self.completed = "\n".join(lines)
                self.screen = self

            def wait(self, predicate, *, label):
                assert predicate(), label

        lines = ["History line 099", "TD4 history end", "─" * 80, " Chat",
                 "   Effort          low", "   Permissions     run without asking",
                 "   Tools           bash", "   Folder          …/long-parent/specimen",
                 "   Model           gpt-6-luna", "",
                 "   Rename     Archive     Copy last answer", "", "─" * 80, " › ", "─" * 80,
                 " ‹ Chat · info       esc close"]
        chat_info_ready(Terminal(lines), "specimen")
        # Each contract observation must fail independently; the old /status
        # page and an Unknown-command notice cannot satisfy panel readiness.
        for label in ("Effort", "Permissions", "Tools", "Folder", "Model", "Rename", "Archive", "Copy last answer", " · info", "esc close"):
            with self.subTest(missing=label), self.assertRaisesRegex(AssertionError, "chat info fields and footer"):
                chat_info_ready(Terminal([line.replace(label, "missing") for line in lines]), "specimen")
        with self.assertRaisesRegex(AssertionError, "chat info fields and footer"):
            chat_info_ready(Terminal([line.replace("…/long-parent/specimen", "unavailable") for line in lines]), "specimen")
        for changed, expected in (
                ([*lines[:-1], " ‹ Chat · info", lines[-1]], "single bottom info footer"),
                ([line.replace("…/long-parent/specimen", "…/long-parent/spec") for line in lines], "Folder retains basename"),
                ([*lines[:9], "not a gap", *lines[10:]], "chat info action separator")):
            with self.subTest(expected=expected), self.assertRaisesRegex(AssertionError, expected):
                chat_info_ready(Terminal(changed), "specimen")

    def test_all_navigation_vectors_keep_their_input_intent(self):
        rows = inventory()
        self.assertEqual(len(rows), 51)
        navigation = {row["name"]: row for row in rows if row["scenario"] == "navigation"}
        self.assertEqual(set(navigation), {
            "key-pgup", "key-pgdn", "key-shift-pgup", "key-shift-up",
            "key-up-csi", "key-up-ss3", "key-end-csi-f", "key-end-ss3-f",
            "key-end-csi-4", "key-esc", "wheel-alt-scroll", "chat-info"})
        self.assertTrue(navigation["chat-info"]["chat_info"])
        self.assertEqual(navigation["chat-info"]["chunks"][0]["hex"], b"\x1bi".hex())
        self.assertEqual(navigation["chat-info"]["return_chunks"][0]["hex"], b"\x1b".hex())
        for name, encoded in (("key-end-csi-f", b"\x1b[F"),
                              ("key-end-ss3-f", b"\x1bOF"),
                              ("key-end-csi-4", b"\x1b[4~")):
            self.assertEqual(navigation[name]["return_chunks"][0]["hex"], encoded.hex())
        self.assertEqual([step["first_history"] for step in navigation["key-pgdn"]["middle"]], [74])
        self.assertEqual([step["first_history"] for step in navigation["wheel-alt-scroll"]["middle"]], [81, 82])


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
