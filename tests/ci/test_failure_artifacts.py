import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import threading
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

    def test_only_exact_diagnostic_names_are_copied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            # Each lacks the prefix, the suffix, or a canonical positive number.
            for name in ("17.json", "observation-failure-18", "observation-failure-07.json",
                         "observation-failure-.json", "observation-failure-٣.json", "xprobe.log"):
                (state / name).write_text("private")
            (state / "observation-failure-19.json").write_text("evidence")
            destination = root / "artifacts"
            destination.mkdir()
            host_process.copy_failure_diagnostics(state, destination)
            self.assertEqual([path.name for path in destination.rglob("*") if path.is_file()],
                             ["observation-failure-19.json"])

    def test_diagnostic_bounds_hold_across_concurrent_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            for name, data in (("a", b"1234"), ("b", b"12345"), ("c", b"1234"), ("d", b"1")):
                (state / name).mkdir(parents=True)
                (state / name / "probe.log").write_bytes(data)
            destination = root / "artifacts"
            destination.mkdir()
            # Seventeen fixtures pass any budget check before any of them writes.
            barrier, walk = threading.Barrier(17), os.walk
            def gated_walk(*args, **kwargs):
                barrier.wait(timeout=10)
                return walk(*args, **kwargs)
            with patch.object(host_process.os, "walk", gated_walk):
                workers = [threading.Thread(target=host_process.copy_failure_diagnostics,
                                            args=(state, destination)) for _ in range(17)]
                for worker in workers:
                    worker.start()
                for worker in workers:
                    worker.join(timeout=10)
            slots = list(destination.iterdir())
            self.assertEqual(len(slots), 16, "job-wide root cap")
            copied = [path for path in destination.rglob("*") if path.is_file()]
            self.assertEqual(len(copied), 16 * 4)
            self.assertLessEqual(len(copied), 128)
            self.assertLessEqual(sum(path.stat().st_size for path in copied), 16 * 1024 * 1024)
            # Per-root file and byte bounds, without the global defaults.
            with patch.multiple(host_process, MAX_RETAINED_BYTES_PER_ROOT=8, MAX_RETAINED_FILES_PER_ROOT=2):
                bounded = root / "bounded"
                bounded.mkdir()
                host_process.copy_failure_diagnostics(state, bounded)
            slot, = bounded.iterdir()
            self.assertEqual(sorted(path.relative_to(slot).as_posix() for path in slot.rglob("*.log")),
                             ["a/probe.log", "c/probe.log"])

    def test_reporting_failure_never_replaces_the_original_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "real").mkdir()
            (root / "link").symlink_to(root / "real")
            state = root / "state"
            state.mkdir()
            (state / "probe.log").write_text("evidence")
            host_process._failure_destination.cache_clear()
            self.addCleanup(host_process._failure_destination.cache_clear)
            original = AssertionError("original fixture failure")
            try:
                try:
                    raise original
                finally:
                    output = self.retain(state, root / "link")
            except AssertionError as error:
                self.assertIs(error, original)
            self.assertIn("Failure diagnostic retention unavailable: AssertionError", output)
            self.assertEqual(list((root / "real").iterdir()), [])

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
