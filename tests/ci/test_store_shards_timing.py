from contextlib import redirect_stderr, redirect_stdout
import io
import unittest

import store_shards


class StoreTimingReportTest(unittest.TestCase):
    def test_ci_97_only_successful_shards_report_slowest_completed_tests(self):
        tests = [("test-z", 4.0, "OK"), ("test-a", 4.0, "OK"), ("test-c", 3.0, "OK"),
                 ("test-d", 2.0, "OK"), ("test-e", 1.0, "OK"), ("test-f", 0.5, "OK"),
                 ("skipped", 20.0, "SKIP")]
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            store_shards.report(store_shards.Result("Store shard 1/4", 0, 9.0, tests, ""))
        self.assertEqual(output.getvalue().splitlines(), [
            "Store shard 1/4: 6 passed, 1 skipped, 9.000s; exit 0",
            "Store shard 1/4 slow test: 4.000s observed; test-a",
            "Store shard 1/4 slow test: 4.000s observed; test-z",
            "Store shard 1/4 slow test: 3.000s observed; test-c",
            "Store shard 1/4 slow test: 2.000s observed; test-d",
            "Store shard 1/4 slow test: 1.000s observed; test-e",
        ])
        self.assertEqual(errors.getvalue(), "")
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            store_shards.report(store_shards.Result("failed shard", 1, 2.0, tests, "broken", ["unit-test"]))
        self.assertNotIn("slow test", output.getvalue())
        self.assertIn("broken", errors.getvalue())
        self.assertIn("failed command: unit-test", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
