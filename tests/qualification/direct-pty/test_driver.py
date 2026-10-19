"""Cheap native controls for byte custody, observation and failure oracles."""
import json
import os
import pathlib
import sys
import tempfile
import unittest

from driver import DirectPty, ScreenCapture


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


if __name__ == "__main__":
    unittest.main()
