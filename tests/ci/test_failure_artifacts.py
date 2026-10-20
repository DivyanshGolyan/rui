import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import host_process


class FailureArtifactsTest(unittest.TestCase):
    def retain(self, state, destination):
        with patch.dict(os.environ, RUI_FAILURE_ARTIFACTS=str(destination)) if destination else \
                contextlib.nullcontext(), contextlib.redirect_stderr(io.StringIO()) as output:
            host_process.retain_failure_state("canonical failure state", state)
        return output.getvalue()

    def test_retained_fixture_copies_labelled_diagnostics_without_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            (state / "case").mkdir(parents=True)
            for name in ("probe.log", "pty-failure.json", "observation-failure-17.json"):
                (state / "case" / name).write_text("fixture evidence")
            for name in ("rui.sqlite3", "credentials.json", "payload.log", "tokens.stdout",
                         "observation-failure-07.json", "observation-failure-.json"):
                (state / name).write_text("private")
            (state / "escape.log").symlink_to(state / "credentials.json")
            (state / "store").mkdir()
            (state / "store" / "probe.log").write_text("private")
            self.assertEqual(self.retain(state, None), f"retained canonical failure state: {state}\n")
            destination = root / "artifacts"
            self.retain(state, destination)
            copied, = destination.iterdir()
            self.assertEqual(sorted(path.relative_to(copied).as_posix() for path in copied.rglob("*") if path.is_file()),
                             ["case/observation-failure-17.json", "case/probe.log", "case/pty-failure.json"])
            self.assertTrue(all(path.read_text() == "fixture evidence" for path in copied.rglob("*") if path.is_file()))
            # Each retention gets its own directory; an earlier copy is never replaced.
            (state / "case" / "probe.log").write_text("changed")
            self.retain(state, destination)
            self.assertEqual(len(list(destination.iterdir())), 2)
            self.assertEqual((copied / "case/probe.log").read_text(), "fixture evidence")

    def test_diagnostic_bounds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            for name, data in (("a", b"1234"), ("b", b"12345"), ("c", b"1234"), ("d", b"1")):
                (state / name).mkdir(parents=True)
                (state / name / "probe.log").write_bytes(data)
            destination = root / "artifacts"
            destination.mkdir()
            with patch.multiple(host_process, MAX_RETAINED_FILE_BYTES=4, MAX_RETAINED_BYTES=8,
                                MAX_RETAINED_FILES=2, MAX_RETAINED_ROOTS=1):
                host_process.copy_failure_diagnostics(state, destination)
                host_process.copy_failure_diagnostics(state, destination)
            copied, = destination.iterdir()
            self.assertEqual(sorted(path.relative_to(copied).as_posix() for path in copied.rglob("*.log")),
                             ["a/probe.log", "c/probe.log"])
            # Byte and file caps span roots: a later root cannot reset them.
            with patch.multiple(host_process, MAX_RETAINED_FILE_BYTES=4, MAX_RETAINED_BYTES=8,
                                MAX_RETAINED_FILES=4, MAX_RETAINED_ROOTS=16):
                host_process.copy_failure_diagnostics(state, destination)
            self.assertEqual(len(list(destination.iterdir())), 1)

    def test_native_workflow_uploads_each_failed_part_with_short_retention(self):
        for name, parts in (("check.yml", 2), ("previous-release-upgrade.yml", 1)):
            with self.subTest(workflow=name):
                workflow = Path(".github/workflows", name).read_text()
                self.assertEqual(workflow.count("RUI_FAILURE_ARTIFACTS:"), parts)
                # Acceptance receipts and synthetic upgrade Stores are separate
                # artifacts. Check the bounded failure upload contract itself.
                blocks = workflow.split("      - name: Retain bounded failed-fixture diagnostics\n")[1:]
                self.assertEqual(len(blocks), parts)
                for block in blocks:
                    upload = block.split("      - name:", 1)[0]
                    self.assertIn("if: ${{ failure() }}", upload)
                    self.assertIn("path: ${{ runner.temp }}/rui-failure-artifacts", upload)
                    self.assertIn("retention-days: 3", upload)


if __name__ == "__main__":
    unittest.main()
