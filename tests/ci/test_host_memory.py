from pathlib import Path
import contextlib
import io
import os
import resource
import subprocess
import sys
import tempfile
import unittest

from host_memory import (COMPARABLE, FIXTURE_DESCRIPTORS, MIN_RAMP_RUNS, PER_AGENT_BUDGET, RAMP_FROM, RAMP_RUNS, RAMP_TO,
                         Ramp, Readings, SCENARIOS, raise_descriptor_limit, ramp_runs, summary, verdict)

MACHINE = {"image": "ubuntu24 20261101.1", "cpu": "Example CPU @ 2.10GHz", "kernel": "6.8.0", "glibc": "glibc 2.39"}
BUDGET_KIB = (RAMP_TO - RAMP_FROM) * PER_AGENT_BUDGET // 1024   # 3600 KiB of slope is exactly the budget
BASE = 100_000

# The Host's own refusal, as start_ready_process reports it when the Host exits before ready (server.zig prints this line).
HOST_REFUSAL = ("rui: Host cannot start: descriptor soft limit 64 is below the minimum intake requirement 4,311 "
                "(10 ordinary clients). Rui already tried raising it.")

# What a scripted ramp raises. "before" and "held" fail before the reading (held is held_exactly's own message);
# "teardown" fails after the reading, while the Host stops.
FAILURES = {
    "before": "the model listing never held",
    "held": "3 model requests held, expected exactly 5",
    "teardown": "Host did not stop within 10 seconds",
}


def ramp_of(delta, base=BASE):
    return Ramp(base, base + delta)


def runs(*deltas):
    return [ramp_of(delta) for delta in deltas]


def scripted_ramp(outcomes):
    """A stand-in for host_memory.ramp. Each run takes the next outcome: "ok", or one of FAILURES."""
    remaining = iter(outcomes)
    started = []

    @contextlib.contextmanager
    def fake(binary, root, store):
        outcome = next(remaining)
        started.append(outcome)
        if outcome in ("before", "held"):
            raise RuntimeError(FAILURES[outcome])
        yield Ramp(BASE, BASE + 3000)
        if outcome == "teardown":
            raise RuntimeError(FAILURES[outcome])

    return fake, started


def quietly(call):
    with contextlib.redirect_stderr(io.StringIO()):
        return call()


def run_main(binary, environment=None):
    return subprocess.run([sys.executable, "-B", str(Path(__file__).with_name("host_memory.py")), str(binary)],
                          capture_output=True, text=True, timeout=60, env=environment)


def raise_once(soft, hard, refuse=False):
    """Run raise_descriptor_limit over a fake limit; return the soft limit it reports and the setrlimit calls."""
    limits = {"now": (soft, hard)}
    calls = []

    def setrlimit(which, value):
        calls.append((which, value))
        if refuse:
            raise ValueError("not permitted")
        limits["now"] = value

    returned = raise_descriptor_limit(getrlimit=lambda which: limits["now"], setrlimit=setrlimit)
    return returned, calls


class PerAgentVerdictTest(unittest.TestCase):
    def test_ci_90_per_agent_verdict_over_its_whole_domain(self):
        over_by_one = BUDGET_KIB + 1
        cases = (
            # name, ramps or reason, passes, per_agent, fragment of the gate sentence
            ("median well within budget", runs(3000, 3000, 3000, 3000, 3000), True, 3000 * 1024 // 900, "median of 5"),
            ("median exactly at budget", runs(*[BUDGET_KIB] * 5), True, PER_AGENT_BUDGET, "within"),
            ("median 1 KiB of slope over budget", runs(*[over_by_one] * 5), False, 4097, "4,096-byte budget"),
            ("bimodal step at ramp_from cannot lower an over-budget median", runs(
                over_by_one, over_by_one, over_by_one, over_by_one, over_by_one - 200), False, 4097, "4,096-byte budget"),
            ("bimodal step at ramp_to cannot raise a within median", runs(
                BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB, BUDGET_KIB + 200), True, PER_AGENT_BUDGET, "within"),
            (f"{MIN_RAMP_RUNS} of {RAMP_RUNS} runs is measured", runs(3000, 3100, 2900), True, 3000 * 1024 // 900,
             f"median of {MIN_RAMP_RUNS}"),
            (f"one run short of {MIN_RAMP_RUNS}", runs(*[3000] * (MIN_RAMP_RUNS - 1)), False, None,
             f"{MIN_RAMP_RUNS - 1} of {RAMP_RUNS} ramp runs completed"),
            ("no ramp completed", [], False, None, f"0 of {RAMP_RUNS} ramp runs completed"),
            ("negative slope is measured and reported as is", runs(-1000, -1000, -1000, -1000, -1000), True,
             -1000 * 1024 // 900, "bytes"),
            ("an even run count takes the upper middle", runs(BUDGET_KIB, BUDGET_KIB, over_by_one, over_by_one),
             False, 4097, "4,097 bytes"),
            ("a not-measured reason fails and is quoted", "the model listing never held", False, None,
             "per-agent cost not measured: the model listing never held"),
        )
        for name, ramps, passes, per_agent, fragment in cases:
            with self.subTest(case=name):
                judged = verdict(ramps)
                self.assertEqual(judged.within, passes)
                self.assertEqual(judged.per_agent, per_agent)
                self.assertIn(fragment, judged.line)
                self.assertTrue(judged.line.startswith("Host memory gate " + ("passed" if passes else "failed")), judged.line)


class CleanRampTest(unittest.TestCase):
    def test_ci_91_only_a_clean_ramp_counts_toward_the_verdict(self):
        # (name, outcome of each run, runs that count)
        outcome_cases = (
            ("every run clean", ["ok"] * RAMP_RUNS, RAMP_RUNS),
            ("failure before the reading, every run", ["before"] * RAMP_RUNS, 0),
            ("held-count shortfall, every run", ["held"] * RAMP_RUNS, 0),
            ("failure at teardown, every run", ["teardown"] * RAMP_RUNS, 0),
            ("teardown failures cannot make up the minimum", ["ok", "ok", "teardown", "teardown", "teardown"], 2),
            ("failures before the reading cannot make up the minimum", ["ok", "ok", "before", "held", "before"], 2),
            ("clean runs reach the minimum", ["ok", "ok", "ok", "teardown", "before"], 3),
        )
        for name, outcomes, counted in outcome_cases:
            with self.subTest(case=name):
                fake, started = scripted_ramp(outcomes)
                result = quietly(lambda: ramp_runs(Path("rui"), Path("root"), raise_limit=lambda: FIXTURE_DESCRIPTORS,
                                                   open_ramp=fake))
                self.assertEqual(started, outcomes)
                if counted == 0:
                    self.assertIsInstance(result, str)
                    self.assertIn(FAILURES[outcomes[-1]], result)
                    judged = verdict(result)
                    self.assertFalse(judged.within)
                    self.assertIsNone(judged.per_agent)
                    self.assertTrue(judged.line.startswith("Host memory gate failed: per-agent cost not measured: "))
                    continue
                self.assertIsInstance(result, list)
                self.assertEqual(len(result), counted)
                if counted < MIN_RAMP_RUNS:
                    judged = verdict(result)
                    self.assertFalse(judged.within)
                    self.assertIsNone(judged.per_agent)
                    self.assertIn(f"{counted} of {RAMP_RUNS} ramp runs completed", judged.line)
                else:
                    self.assertTrue(verdict(result, budget=10**9).within)

        # The fixture's own descriptor headroom: a shortfall is not measured and starts no Host.
        shortfall_cases = (
            (FIXTURE_DESCRIPTORS, None),
            (FIXTURE_DESCRIPTORS + 1, None),
            (resource.RLIM_INFINITY, None),
            (FIXTURE_DESCRIPTORS - 1, f"{FIXTURE_DESCRIPTORS - 1:,}"),
        )
        for limit, shown in shortfall_cases:
            with self.subTest(descriptor_limit=limit):
                fake, started = scripted_ramp(["ok"] * RAMP_RUNS)
                result = quietly(lambda: ramp_runs(Path("rui"), Path("root"), raise_limit=lambda: limit, open_ramp=fake))
                if shown is None:
                    self.assertIsInstance(result, list)
                    self.assertEqual(len(started), RAMP_RUNS)
                else:
                    self.assertIsInstance(result, str)
                    self.assertIn("fixture's descriptor limit", result)
                    self.assertIn(shown, result)
                    self.assertIn(f"{FIXTURE_DESCRIPTORS:,}", result)
                    self.assertEqual(started, [])

        # The Host's own refusal to start is reported with its own reason and never counted.
        @contextlib.contextmanager
        def refused(binary, root, store):
            raise RuntimeError(f"Host exited before ready; stdout=b''; stderr_tail=b'{HOST_REFUSAL}'")
            yield  # pragma: no cover

        result = quietly(lambda: ramp_runs(Path("rui"), Path("root"), raise_limit=lambda: FIXTURE_DESCRIPTORS, open_ramp=refused))
        self.assertIsInstance(result, str)
        self.assertIn("rui: Host cannot start: descriptor soft limit 64 is below the minimum intake requirement", result)
        judged = verdict(result)
        self.assertFalse(judged.within)
        self.assertIsNone(judged.per_agent)
        self.assertIn("Host cannot start", judged.line)

        # Raising the soft descriptor limit to the hard limit, and what is kept when the raise is refused.
        raise_cases = (
            ("soft below hard is raised to hard", 1024, 4096, False, 4096, [(resource.RLIMIT_NOFILE, (4096, 4096))]),
            ("a refused raise keeps the soft limit", 1024, 4096, True, 1024, [(resource.RLIMIT_NOFILE, (4096, 4096))]),
            ("soft equal to hard is left alone", 4096, 4096, False, 4096, []),
        )
        for name, soft, hard, refuse, returned, calls in raise_cases:
            with self.subTest(case=name):
                self.assertEqual(raise_once(soft, hard, refuse), (returned, calls))


class MemoryTableTest(unittest.TestCase):
    def test_ci_92_memory_table_and_exit_status_over_its_rows(self):
        version = "rui 0.70.0 (abc123)"
        ramps = runs(3000, 3000, 3000, 3000, 3000)
        judged = verdict(ramps)

        with self.subTest(case="measured ramp with every publish-only row measured"):
            readings = Readings({"Empty Host": [2188, 2184, 2192], "Model listing held at start": [10, 20],
                                 "MCP tool listing held at start": [30, 40]}, ramps)
            text = summary(version, MACHINE, readings, judged)
            self.assertIn(f"Measured on {version} on ubuntu24 20261101.1, Example CPU @ 2.10GHz, "
                          "kernel 6.8.0, glibc 2.39.", text)
            self.assertIn("| Empty Host | Private_Dirty | 3 | 2188 | 2184-2192 |", text)
            self.assertIn("| 100 agents waiting on the model | Private_Dirty | 5 |", text)
            self.assertIn("| 1,000 agents waiting on the model | Private_Dirty | 5 |", text)
            self.assertIn("| Model listing held at start | Anonymous | 2 | 15 | 10-20 |", text)
            self.assertIn(f"Per agent ({RAMP_FROM:,} -> {RAMP_TO:,} waiting agents, same Host): {judged.per_agent:,} bytes "
                          "median of 5", text)
            self.assertIn(COMPARABLE, text)
            self.assertTrue(text.endswith(judged.line))

        with self.subTest(case="ramp did not run"):
            not_run = verdict("no ramp run started")
            text = summary(version, MACHINE, Readings({}, "no ramp run started"), not_run)
            self.assertIn("| 1,000 agents waiting on the model | Private_Dirty | not measured: no ramp run started | | |", text)
            self.assertIn(f"Per agent ({RAMP_FROM:,} -> {RAMP_TO:,} waiting agents, same Host): not measured.", text)
            self.assertTrue(text.endswith(not_run.line))

        with self.subTest(case="publish-only failure leaves the verdict and its line as they were"):
            text = summary(version, MACHINE, Readings({"Empty Host": "timed out | twice"}, ramps), judged)
            self.assertIn("| Empty Host | Private_Dirty | not measured: timed out / twice | | |", text)
            self.assertTrue(judged.within)
            self.assertTrue(text.endswith(judged.line))

        with self.subTest(case="scenario rows have distinct names and smaps fields"):
            self.assertEqual(len({scenario.name for scenario in SCENARIOS}), len(SCENARIOS))
            self.assertTrue({scenario.metric for scenario in SCENARIOS} <= {"Private_Dirty", "Anonymous"})

        with self.subTest(case="absent binary is not measured and exits 1"):
            with tempfile.TemporaryDirectory() as directory:
                result = run_main(Path(directory) / "absent-rui")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertTrue(result.stdout.startswith("### Host memory\n\nNot measured: "), result.stdout)
            self.assertIn("not measured", result.stdout)
            self.assertIn("not measured", result.stderr)

        with self.subTest(case="notes file gets the same text"):
            with tempfile.TemporaryDirectory() as directory:
                notes = Path(directory) / "notes.md"
                result = run_main(Path(directory) / "absent-rui", {**os.environ, "RUI_HOST_MEMORY_NOTES": str(notes)})
                self.assertEqual(result.returncode, 1)
                self.assertEqual(notes.read_text(), result.stdout)


if __name__ == "__main__":
    unittest.main()
