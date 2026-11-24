import json
import sys
import unittest
from unittest.mock import patch

import run_selected
from select_tests import execution_batches


class NativePartitionTest(unittest.TestCase):
    def test_ci_96_both_partitions_run_once_and_fail_closed(self):
        targets = ["admission-debug-integration", "check-full", "test-full"]
        batches = [["check-full", "-Dcheck-part=execution"], ["admission-debug-integration"],
                   ["test-full"], ["check-full", "-Dcheck-part=callers"]]
        self.assertEqual(execution_batches(targets, "both"), batches)
        for failed in (None, *range(len(batches))):
            with self.subTest(failed=failed):
                calls = []
                def execute(batch, artifacts):
                    calls.append(batch)
                    return (1, "failed") if len(calls) - 1 == failed else (0, "")
                args = ["run_selected.py", json.dumps(targets), "--check-part", "both"]
                with patch.object(run_selected, "execute", execute), patch.object(run_selected, "summarize"), \
                     patch.object(run_selected, "record_failure"), patch.object(sys, "argv", args):
                    if failed is None:
                        run_selected.main()
                    else:
                        with self.assertRaises(SystemExit) as exit_status:
                            run_selected.main()
                        self.assertEqual(exit_status.exception.code, 1)
                self.assertEqual(calls, batches if failed is None else batches[:failed + 1])
        with self.assertRaises(ValueError):
            execution_batches(["test-logic"], "both")


if __name__ == "__main__":
    unittest.main()
