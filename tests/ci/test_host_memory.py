from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from host_memory import COMPARABLE, SCENARIOS, Scenario, summary

MACHINE = {"image": "ubuntu24 20261101.1", "cpu": "Example CPU @ 2.10GHz", "kernel": "6.8.0", "glibc": "glibc 2.39"}
TWO = (Scenario("Empty Host", "Private_Dirty", None), Scenario("Listing held", "Anonymous", None))


class HostMemoryTest(unittest.TestCase):
    def test_each_scenario_is_one_row_with_its_metric_runs_median_and_range(self):
        text = summary("rui 0.70.0 (abc123)", MACHINE, {"Empty Host": [2188, 2184, 2192], "Listing held": [10, 20]}, TWO)
        self.assertIn("(rui 0.70.0 (abc123)), on a GitHub-hosted runner "
                      "(ubuntu24 20261101.1, Example CPU @ 2.10GHz, kernel 6.8.0, glibc 2.39)", text)
        self.assertIn("| Empty Host | Private_Dirty | 3 | 2188 | 2184-2192 |", text)
        self.assertIn("| Listing held | Anonymous | 2 | 15 | 10-20 |", text)
        self.assertTrue(text.endswith(COMPARABLE))

    def test_a_scenario_that_failed_says_not_measured_in_its_own_row(self):
        text = summary("rui 0.70.0 (abc123)", MACHINE, {"Empty Host": [1], "Listing held": "timed out | twice"}, TWO)
        self.assertIn("| Empty Host | Private_Dirty | 1 | 1 | 1-1 |", text)
        self.assertIn("| Listing held | Anonymous | not measured: timed out / twice | | |", text)

    def test_a_run_that_cannot_start_prints_not_measured_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("host_memory.py")),
                                     str(Path(directory) / "absent-rui")], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("### Host memory\n\nNot measured: "), result.stdout)

    def test_scenarios_have_distinct_names_and_read_a_smaps_rollup_field(self):
        self.assertEqual(len({scenario.name for scenario in SCENARIOS}), len(SCENARIOS))
        self.assertTrue({scenario.metric for scenario in SCENARIOS} <= {"Private_Dirty", "Anonymous"})


if __name__ == "__main__":
    unittest.main()
