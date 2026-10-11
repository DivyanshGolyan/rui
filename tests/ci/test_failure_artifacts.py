import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_selected


class FailureArtifactsTest(unittest.TestCase):
    def run_gate(self, failed):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("dispatch", "terminal"):
                state = root / name
                state.mkdir()
                (state / "probe.log").write_text("fixture evidence")
                (state / "rui.sqlite3").write_text("private canonical payload")
                (state / "credentials.json").write_text("secret")
                (state / "payload.log").write_text("private data despite diagnostic suffix")
                (state / "tokens.stdout").write_text("secret despite diagnostic suffix")
                (state / "escape.log").symlink_to(state / "credentials.json")
            zig = root / "zig"
            zig.write_text(f'''#!/bin/sh
echo 'retained dispatch integration failure state: {root / "dispatch"}' >&2
echo 'retained terminal restoration state (completed=False): {root / "terminal"}' >&2
exit {int(failed)}
''')
            zig.chmod(0o755)
            destination = root / "artifacts"
            result = subprocess.run([
                "python3", "-B", "tests/ci/run_selected.py", '["test-logic"]',
            ], env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                        RUI_FAILURE_ARTIFACTS=str(destination)), capture_output=True, text=True)
            self.assertEqual(result.returncode, int(failed), result.stdout + result.stderr)
            if failed:
                evidence = list(destination.rglob("probe.log"))
                self.assertEqual(len(evidence), 2, "both retained failure markers must be collected")
                self.assertTrue(all(path.read_text() == "fixture evidence" for path in evidence))
                self.assertFalse(list(destination.rglob("rui.sqlite3")))
                self.assertFalse(list(destination.rglob("credentials.json")))
                self.assertFalse(list(destination.rglob("escape.log")))
                self.assertFalse(list(destination.rglob("payload.log")))
                self.assertFalse(list(destination.rglob("tokens.stdout")))
                self.assertIn("retained dispatch integration failure state:",
                              (destination / "selected-gate.log").read_text())
            else:
                self.assertFalse(destination.exists(), "successful checks must not capture")

    def test_failure_retains_both_marker_forms_without_private_files(self):
        self.run_gate(True)

    def test_success_does_not_capture(self):
        self.run_gate(False)

    def test_diagnostic_bounds_and_private_subdirectories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            for name in ("home", "store", "scratch", "requests", "provider"):
                (state / name).mkdir()
                (state / name / "probe.log").write_bytes(b"secret")
            (state / "auth.log").write_bytes(b"secret")
            for name, data in (("a", b"1234"), ("b", b"12345"), ("c", b"1234"), ("d", b"1")):
                (state / name).mkdir()
                (state / name / "probe.log").write_bytes(data)
            destination = root / "artifacts"
            with patch.multiple(run_selected, MAX_FILE_BYTES=4, MAX_TOTAL_BYTES=8,
                                MAX_FILES=2, MAX_DIRECTORIES=1):
                run_selected.retain_failure_logs([state, state], destination)
            self.assertEqual(sorted(path.relative_to(destination).as_posix() for path in destination.rglob("*.log")),
                             ["0/a/probe.log", "0/c/probe.log"])
            self.assertEqual(sum(path.stat().st_size for path in destination.rglob("*.log")), 8)
            self.assertFalse((destination / "1").exists())

    def test_failed_job_without_retained_roots_still_keeps_published_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_selected.retain_failure_logs([], root, b"original failed assertion\n")
            self.assertEqual((root / "selected-gate.log").read_bytes(), b"original failed assertion\n")

    def test_native_workflow_uploads_each_failed_part_with_short_retention(self):
        workflow = Path(".github/workflows/check.yml").read_text()
        self.assertEqual(workflow.count("RUI_FAILURE_ARTIFACTS:"), 2)
        self.assertEqual(workflow.count("retention-days: 3"), 2)
        self.assertEqual(workflow.count("if: ${{ failure() }}"), 2)


if __name__ == "__main__":
    unittest.main()
