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
        targets = ["admission-debug-integration", "check-full", "future-integration", "test-full"]
        batches = [["check-full", "-Dcheck-part=execution"], ["future-integration"],
                   ["admission-debug-integration"], ["test-full"], ["check-full", "-Dcheck-part=callers"]]
        cases = (
            (targets, batches),
            (["check-full"], [["check-full", "-Dcheck-part=execution"],
                              ["check-full", "-Dcheck-part=callers"]]),
            (["test-logic", "check-full"], [["check-full", "-Dcheck-part=execution"],
                                            ["test-logic"], ["check-full", "-Dcheck-part=callers"]]),
        )
        for selected, expected in cases:
            with self.subTest(selected=selected):
                self.assertEqual(execution_batches(selected, "both"), expected)
        for selected in ([], ["test-logic"]):
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                execution_batches(selected, "both")
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
                    record = root / "rui-failed-steps.jsonl"
                    record.unlink(missing_ok=True)
                    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               BATCH_LOG=str(log), FAIL_BATCH=str(failed), RUNNER_TEMP=str(root))
                    env.pop("GITHUB_STEP_SUMMARY", None)
                    env.pop("GITHUB_EVENT_NAME", None)  # a pull_request event adds -Dpr-ci=true on Linux
                    result = subprocess.run([sys.executable, "-B", "tests/ci/run_selected.py",
                                             json.dumps(targets), "--check-part", "both",
                                             "--ci-artifacts", "compiled"],
                                            env=env, capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 0 if failed is None else 1, result.stdout + result.stderr)
                    actual = json.loads(log.read_text())
                    expected = batches if failed is None else batches[:failed + 1]
                    self.assertEqual(actual, [["build", *batch, "-Dci-artifacts=compiled", "--summary", "all",
                                               "--test-timeout", "5m"] for batch in expected])
                    if failed is None:
                        self.assertFalse(record.exists())
                    else:
                        rows = [json.loads(line) for line in record.read_text().splitlines() if line.strip()]
                        self.assertEqual([row["name"] for row in rows], [" ".join(batches[failed])], rows)
            result = subprocess.run([sys.executable, "-B", "tests/ci/run_selected.py",
                                     json.dumps(["test-logic"]), "--check-part", "both"],
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
