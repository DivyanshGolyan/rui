#!/usr/bin/env python3
"""Producer-boundary regressions. Synthetic commands are not native UI evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).with_name("session_sequence_model.py")
FRONTEND = """
            const action_visible = self.actionVisible();
            self.dirty = false;
            if (!approval_ready and self.approvalReady()) {
if (self.consent.promptCompleted(service, false, false)) {
"""
COMMAND = r'''
import os
from pathlib import Path
import signal
import sys

def drift(stage):
    if os.environ.get("TD1_DRIFT_STAGE") != stage:
        return
    path = Path.cwd() / "src/owner.zig"
    kind = os.environ["TD1_DRIFT_KIND"]
    if kind == "bytes":
        path.write_bytes(b"altered executed source")
    elif kind == "mode":
        path.chmod(path.stat().st_mode ^ 0o111)
    elif kind == "delete":
        path.unlink()
    elif kind == "add":
        path.with_name("unexpected.zig").write_text("unexpected source")
    elif kind == "link":
        original = path.read_bytes()
        path.unlink()
        target = Path(os.environ["TD1_LINK_TARGET"])
        target.write_bytes(original)
        path.symlink_to(target)

if Path(sys.argv[0]).name == "zig":
    binary = Path(os.environ["TD1_BINARY"])
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!" + sys.executable + "\n" + os.environ["TD1_COMMAND"])
    binary.chmod(0o755)
    print(f"info(verbose): RUI_TEST_EXACT_INACTIVITY=0 {binary} --cache-dir=synthetic --listen=-", flush=True)
    drift("build")
    code = int(os.environ.get("TD1_BUILD_EXIT", "0"))
    if code < 0:
        os.kill(os.getpid(), signal.SIGKILL)
    raise SystemExit(code)
Path(os.environ["TD1_DIRECT_MARKER"]).write_text("executed")
drift("direct")
code = int(os.environ.get("TD1_DIRECT_EXIT", "0"))
print("1/2 tests.test_0...OK")
print("2/2 SessionFrontend.test.TD1 sequence model pages..." + ("FAIL (TestUnexpectedResult)" if code else "OK"))
raise SystemExit(code)
'''


class ProducerTests(unittest.TestCase):
    def invoke(self, root, *, stage="", kind="", build_exit=0, direct_exit=0):
        source = root / "supplied"
        (source / "src").mkdir(parents=True)
        (source / "src/SessionFrontend.zig").write_text(FRONTEND)
        (source / "src/owner.zig").write_text("original supplied source")
        for name in ("build.zig", "build.zig.zon"):
            (source / name).write_text("synthetic build input")
        tools = root / "tools"
        tools.mkdir()
        zig = tools / "zig"
        zig.write_text("#!" + sys.executable + "\n" + COMMAND)
        zig.chmod(0o755)
        marker = root / "direct-ran"
        output = root / "output"
        environment = {
            **os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "TD1_BINARY": str(root / "artifact/test"), "TD1_COMMAND": COMMAND,
            "TD1_DIRECT_MARKER": str(marker), "TD1_DRIFT_STAGE": stage,
            "TD1_DRIFT_KIND": kind, "TD1_BUILD_EXIT": str(build_exit),
            "TD1_DIRECT_EXIT": str(direct_exit),
            "TD1_LINK_TARGET": str(root / "replacement"),
        }
        result = subprocess.run(
            [sys.executable, str(RUNNER), "--source", str(source), "--output", str(output),
             "--cache", str(root / "cache"), "--selector", "pages"],
            env=environment, capture_output=True, text=True, timeout=10,
        )
        receipt = json.loads((output / "receipt.json").read_text())
        self.assertEqual((source / "src/owner.zig").read_text(), "original supplied source")
        return result, receipt, marker.exists()

    def test_drift_in_executed_overlay_never_qualifies_supplied_source(self):
        for stage in ("build", "direct"):
            for kind in ("bytes", "mode", "delete", "add", "link"):
                with self.subTest(stage=stage, kind=kind), tempfile.TemporaryDirectory() as directory:
                    result, receipt, replayed = self.invoke(Path(directory), stage=stage, kind=kind)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue(receipt["source_unchanged"])
                    self.assertFalse(receipt["overlay_unchanged"])
                    self.assertEqual(replayed, stage == "direct")
                    if stage == "build":
                        self.assertIsNone(receipt["direct_exit"])

    def test_abnormal_build_never_replays_even_with_a_discoverable_binary(self):
        for code in (-9, 42):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                result, receipt, replayed = self.invoke(Path(directory), build_exit=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(receipt["exit"], code)
                self.assertIsNone(receipt["direct_exit"])
                self.assertFalse(replayed)

    def test_unchanged_success_and_typed_failure_retain_matching_authority(self):
        for code in (0, 1):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                result, receipt, replayed = self.invoke(Path(directory), build_exit=code, direct_exit=code)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertTrue(replayed)
                self.assertTrue(receipt["source_unchanged"] and receipt["overlay_unchanged"])
                self.assertEqual(receipt["exit"], receipt["direct_exit"])
                self.assertEqual(receipt["assertions"], ["TestUnexpectedResult"] if code else [])
                self.assertEqual(set(receipt["overlay"]["observations"]),
                                 {"before_build", "after_build", "before_direct", "after_direct"})
                self.assertEqual(set(receipt["overlay"]["observations"].values()),
                                 {receipt["overlay"]["expected_sha256"]})


if __name__ == "__main__":
    unittest.main()
