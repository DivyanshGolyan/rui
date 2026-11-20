import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).with_name("case_deadline.py")


class CaseDeadlineTest(unittest.TestCase):
    def run_case(self, seconds, *command):
        return subprocess.run([sys.executable, str(SCRIPT), str(seconds), *command],
                              capture_output=True, text=True, timeout=60)

    def test_a_finished_case_keeps_its_exit_status(self):
        for status in (0, 3):
            with self.subTest(status=status):
                result = self.run_case(30, "sh", "-c", f"exit {status}")
                self.assertEqual(result.returncode, status, result)
                self.assertEqual(result.stderr, "")

    def test_a_hung_case_fails_with_124_and_its_whole_group_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / "grandchild.pid"
            result = self.run_case(1, "sh", "-c", f"sleep 60 & echo $! > {marker}; wait")
            self.assertEqual(result.returncode, 124, result)
            self.assertIn("still running after 1s", result.stderr)
            pid = int(marker.read_text())
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail("the case's background child outlived the deadline")


if __name__ == "__main__":
    unittest.main()
