from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

from host_memory import (COMPARABLE, PER_AGENT_BUDGET, RAMP_FROM, RAMP_TO, Ramp, Readings, SCENARIOS,
                         summary, verdict)

MACHINE = {"image": "ubuntu24 20261101.1", "cpu": "Example CPU @ 2.10GHz", "kernel": "6.8.0", "glibc": "glibc 2.39"}
BUDGET_KIB = (RAMP_TO - RAMP_FROM) * PER_AGENT_BUDGET // 1024   # 3600 KiB of slope is exactly the budget
BASE = 100_000


def ramp_of(delta, base=BASE):
    return Ramp(base, base + delta)


def runs(*deltas):
    return [ramp_of(delta) for delta in deltas]


class VerdictTest(unittest.TestCase):
    def test_a_median_within_budget_passes(self):
        judged = verdict(runs(3000, 3000, 3000, 3000, 3000))
        self.assertTrue(judged.within)
        self.assertEqual(judged.per_agent, 3000 * 1024 // 900)
        self.assertIn("within", judged.line)
        self.assertIn("median of 5", judged.line)

    def test_a_median_exactly_at_budget_passes(self):
        judged = verdict(runs(BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB))
        self.assertTrue(judged.within)
        self.assertEqual(judged.per_agent, PER_AGENT_BUDGET)

    def test_a_median_just_past_budget_fails_naming_median_and_budget(self):
        # smaps reports KiB, so the smallest step past the budget is one KiB of slope (about 1.14 bytes per agent).
        judged = verdict(runs(BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1))
        self.assertFalse(judged.within)
        self.assertEqual(judged.per_agent, 4097)
        self.assertTrue(judged.line.startswith("Host memory gate failed: "), judged.line)
        self.assertIn("4,097 bytes", judged.line)
        self.assertIn("4,096-byte budget", judged.line)

    def test_a_bimodal_step_at_ramp_from_does_not_move_an_over_budget_median(self):
        # One run reads 200 KiB high at RAMP_FROM only, so its slope is 200 KiB low; the median stays over budget.
        judged = verdict(runs(BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1, BUDGET_KIB + 1 - 200))
        self.assertFalse(judged.within)

    def test_a_bimodal_step_at_ramp_to_does_not_move_a_within_median(self):
        # One run reads 200 KiB high at RAMP_TO only, so its slope is 200 KiB high; the median stays within.
        judged = verdict(runs(BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB + 200))
        self.assertTrue(judged.within)

    def test_three_of_five_runs_is_measured(self):
        judged = verdict(runs(3000, 3100, 2900))
        self.assertTrue(judged.within)
        self.assertEqual(judged.per_agent, 3000 * 1024 // 900)

    def test_two_of_five_runs_is_not_measured_and_fails(self):
        judged = verdict(runs(3000, 3000))
        self.assertFalse(judged.within)
        self.assertIsNone(judged.per_agent)
        self.assertIn("not measured", judged.line)
        self.assertIn("2 of 5 ramp runs completed", judged.line)

    def test_a_reason_string_fails_as_not_measured_and_quotes_the_reason(self):
        judged = verdict("the model listing never held")
        self.assertFalse(judged.within)
        self.assertIsNone(judged.per_agent)
        self.assertEqual(judged.line, "Host memory gate failed: per-agent cost not measured: "
                                      "the model listing never held")

    def test_a_negative_slope_is_measured_within_and_reported_as_is(self):
        judged = verdict(runs(-1000, -1000, -1000, -1000, -1000))
        self.assertTrue(judged.within)
        self.assertEqual(judged.per_agent, -1000 * 1024 // 900)
        self.assertIn(f"{-1000 * 1024 // 900:,} bytes", judged.line)

    def test_an_even_run_count_takes_the_upper_middle_so_it_never_rounds_toward_passing(self):
        judged = verdict(runs(BUDGET_KIB, BUDGET_KIB, BUDGET_KIB + 1, BUDGET_KIB + 1))
        self.assertFalse(judged.within)


class SummaryTest(unittest.TestCase):
    def readings(self, ramps, rows=None):
        return Readings(rows or {"Empty Host": [2188, 2184, 2192], "Model listing held at start": [10, 20],
                                 "MCP tool listing held at start": [30, 40]}, ramps)

    def test_each_scenario_is_one_row_and_the_ramp_has_its_two_rows_and_a_per_agent_line(self):
        ramps = runs(3000, 3000, 3000, 3000, 3000)
        judged = verdict(ramps)
        text = summary("rui 0.70.0 (abc123)", MACHINE, self.readings(ramps), judged)
        self.assertIn("Measured on rui 0.70.0 (abc123) on ubuntu24 20261101.1, Example CPU @ 2.10GHz, "
                      "kernel 6.8.0, glibc 2.39.", text)
        self.assertIn("| Empty Host | Private_Dirty | 3 | 2188 | 2184-2192 |", text)
        self.assertIn("| 100 agents waiting on the model | Private_Dirty | 5 |", text)
        self.assertIn("| 1,000 agents waiting on the model | Private_Dirty | 5 |", text)
        self.assertIn("| Model listing held at start | Anonymous | 2 | 15 | 10-20 |", text)
        self.assertIn(f"Per agent (100 -> 1,000 waiting agents, same Host): {judged.per_agent:,} bytes median of 5", text)
        self.assertIn(COMPARABLE, text)
        self.assertTrue(text.endswith(judged.line))

    def test_a_ramp_that_did_not_run_is_a_not_measured_row_and_the_gate_fails(self):
        judged = verdict("no ramp run started")
        text = summary("rui 0.70.0 (abc123)", MACHINE, self.readings("no ramp run started"), judged)
        self.assertIn("| 1,000 agents waiting on the model | Private_Dirty | not measured: no ramp run started | | |", text)
        self.assertIn("Per agent (100 -> 1,000 waiting agents, same Host): not measured.", text)
        self.assertTrue(text.endswith(judged.line))

    def test_a_publish_only_failure_stays_a_row(self):
        ramps = runs(3000, 3000, 3000)
        text = summary("rui 0.70.0 (abc123)", MACHINE,
                       self.readings(ramps, {"Empty Host": "timed out | twice"}), verdict(ramps))
        self.assertIn("| Empty Host | Private_Dirty | not measured: timed out / twice | | |", text)

    def test_scenarios_have_distinct_names_and_read_a_smaps_rollup_field(self):
        self.assertEqual(len({scenario.name for scenario in SCENARIOS}), len(SCENARIOS))
        self.assertTrue({scenario.metric for scenario in SCENARIOS} <= {"Private_Dirty", "Anonymous"})


class MainTest(unittest.TestCase):
    def run_main(self, binary, environment=None):
        return subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("host_memory.py")), str(binary)],
                              capture_output=True, text=True, timeout=60, env=environment)

    def test_a_run_that_cannot_start_is_not_measured_and_exits_one(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_main(Path(directory) / "absent-rui")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(result.stdout.startswith("### Host memory\n\nNot measured: "), result.stdout)
        self.assertIn("not measured", result.stdout)
        self.assertIn("not measured", result.stderr)

    def test_the_notes_file_gets_the_same_text_when_the_environment_names_one(self):
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "notes.md"
            result = self.run_main(Path(directory) / "absent-rui", {**os.environ, "RUI_HOST_MEMORY_NOTES": str(notes)})
            self.assertEqual(result.returncode, 1)
            self.assertEqual(notes.read_text(), result.stdout)


if __name__ == "__main__":
    unittest.main()
