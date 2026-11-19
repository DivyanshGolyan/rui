import re
import unittest
from pathlib import Path

import race_sweep


class StallPlanTest(unittest.TestCase):
    def test_one_seed_always_names_the_same_bounded_stalls(self):
        for seed in range(50):
            with self.subTest(seed=seed):
                plan = race_sweep.stalls(seed, 4)
                self.assertEqual(plan, race_sweep.stalls(seed, 4))
                self.assertEqual(len(plan), 4)
                for chosen in plan:
                    self.assertIn(chosen.syscall, race_sweep.SYSCALLS)
                    self.assertIn(chosen.where, race_sweep.WHERE)
                    self.assertTrue(1 <= chosen.call <= race_sweep.MAX_CALL)

    def test_seeds_differ(self):
        self.assertGreater(len({tuple(race_sweep.stalls(seed, 2)) for seed in range(20)}), 1)

    def test_a_stall_delays_one_call_site_of_every_traced_process(self):
        argv = race_sweep.Stall("sendmsg", "enter", 102).argv()
        self.assertEqual(argv[:2], ["strace", "-f"])
        self.assertIn("trace=sendmsg", argv)
        self.assertIn("inject=sendmsg:delay_enter=250000:when=102", argv)


class CommandTest(unittest.TestCase):
    def test_targets_run_through_the_selected_runner_on_this_runs_artifacts(self):
        self.assertEqual(race_sweep.selected('["pause-socket-test"]'),
                         ["python3", "-B", "tests/ci/run_selected.py", '["pause-socket-test"]',
                          "--ci-artifacts", ".zig-cache/o/ci-compiled"])
        self.assertEqual(race_sweep.starved(["x"]), ["taskset", "-c", race_sweep.CORES, "x"])

    def test_every_stall_run_reports_its_reproduction_and_any_failure_fails(self):
        lines = []
        results = iter([0, 3])
        self.assertEqual(race_sweep.stall('["test-native"]', 7, 2, run=lambda command: next(results),
                                          say=lines.append), 1)
        self.assertEqual(len(lines), 2)
        self.assertIn("passed", lines[0])
        self.assertIn("failed (exit 3)", lines[1])
        for line, chosen in zip(lines, race_sweep.stalls(7, 2)):
            self.assertIn(f"when={chosen.call}", line)
            self.assertIn("tests/ci/run_selected.py", line)

    def test_no_targets_is_refused(self):
        with self.assertRaises(SystemExit):
            race_sweep.main(["stall", "[]"])


class FileTest(unittest.TestCase):
    def test_a_failure_comments_on_the_open_race_sweep_issue(self):
        calls = []
        def call(*args):
            calls.append(args)
            return "41\n" if args[:2] == ("issue", "list") else ""
        self.assertEqual(race_sweep.file("https://run/9", "abc", call=call), "41")
        self.assertIn("race-sweep", calls[0])
        self.assertEqual(calls[1][:3], ("issue", "comment", "41"))
        self.assertIn("https://run/9", calls[1][-1])
        self.assertEqual(len(calls), 2)

    def test_with_none_open_it_opens_one_and_never_uses_ci_red(self):
        calls = []
        def call(*args):
            calls.append(args)
            return "https://issue/42\n" if args[:2] == ("issue", "create") else ""
        self.assertEqual(race_sweep.file("https://run/9", "abc", call=call), "https://issue/42")
        self.assertEqual([args[:2] for args in calls], [("issue", "list"), ("label", "create"), ("issue", "create")])
        self.assertNotIn("ci-red", repr(calls))


class WorkflowTest(unittest.TestCase):
    def test_only_promotes_daily_run_starts_the_sweep_as_its_own_run(self):
        workflows = {path.name: path.read_text() for path in Path(".github/workflows").glob("*.yml")}
        sweep = workflows["race-sweep.yml"].split("\npermissions:", 1)[0]
        self.assertIn("  workflow_dispatch:", sweep)
        self.assertNotIn("workflow_call:", sweep)
        self.assertNotIn("schedule:", sweep)
        self.assertFalse([name for name, body in workflows.items() if "uses: ./.github/workflows/race-sweep.yml" in body])
        self.assertEqual([name for name, body in sorted(workflows.items())
                          if "gh workflow run race-sweep.yml" in body], ["promote.yml"])
        caller = re.search(r"(?ms)^  race_sweep:\n(.*?)(?=^  [\w-]+:\n|\Z)", workflows["promote.yml"]).group(1)
        self.assertIn("if: ${{ needs.batch.outputs.daily == 'true' }}", caller)
        self.assertIn("gh workflow run race-sweep.yml", caller)
        self.assertIn('echo "daily=$daily" >> "$GITHUB_OUTPUT"', workflows["promote.yml"])

    def test_both_shakers_run_and_either_failure_files_its_own_issue(self):
        text = Path(".github/workflows/race-sweep.yml").read_text()
        self.assertIn('race_sweep.py starve "$STARVE"', text)
        self.assertIn('race_sweep.py stall "$STALL" --seed "$SEED"', text)
        self.assertEqual(text.count("continue-on-error: true"), 2)
        self.assertIn("steps.starve.outcome != 'success' || steps.stall.outcome != 'success'", text)
        self.assertIn('race_sweep.py file --run-url "$RUN_URL" --sha "$GITHUB_SHA"', text)
        self.assertNotIn("report_issue.py", text)
        self.assertIn('echo "found=true" >> "$GITHUB_OUTPUT"', text)
        self.assertIn("if: ${{ failure() && needs.sweep.outputs.found == 'true' }}", text)


if __name__ == "__main__":
    unittest.main()
