import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from select_tests import execution_batches


class NativePartitionTest(unittest.TestCase):
    def test_ci_96_both_partitions_run_once_and_fail_closed(self):
        targets = ["admission-debug-integration", "check-full", "test-full"]
        batches = [["check-full", "-Dcheck-part=execution"], ["admission-debug-integration"],
                   ["test-full"], ["check-full", "-Dcheck-part=callers"]]
        self.assertEqual(execution_batches(targets, "both"), batches)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            zig = root / "zig"
            zig.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
log = Path(os.environ["BATCH_LOG"])
rows = json.loads(log.read_text()) if log.exists() else []
rows.append(sys.argv[1:])
log.write_text(json.dumps(rows))
sys.exit(1 if str(len(rows) - 1) == os.environ["FAIL_BATCH"] else 0)
''')
            zig.chmod(0o755)
            for failed in (None, *range(len(batches))):
                with self.subTest(failed=failed):
                    log = root / "batches.json"
                    log.unlink(missing_ok=True)
                    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               BATCH_LOG=str(log), FAIL_BATCH=str(failed))
                    env.pop("GITHUB_STEP_SUMMARY", None)
                    env.pop("RUI_STEP_FAILURES", None)
                    result = subprocess.run([sys.executable, "-B", "tests/ci/run_selected.py",
                                             json.dumps(targets), "--check-part", "both",
                                             "--ci-artifacts", "compiled"],
                                            env=env, capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0 if failed is None else 1, result.stdout + result.stderr)
                    actual = json.loads(log.read_text())
                    expected = batches if failed is None else batches[:failed + 1]
                    self.assertEqual(actual, [["build", *batch, "-Dci-artifacts=compiled", "--summary", "all",
                                               "--test-timeout", "5m"] for batch in expected])
        with self.assertRaises(ValueError):
            execution_batches(["test-logic"], "both")


if __name__ == "__main__":
    unittest.main()
