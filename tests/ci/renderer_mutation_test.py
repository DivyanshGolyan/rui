#!/usr/bin/env python3
"""Tests of the mutation gate's evidence contract, not renderer substitutes."""
import dataclasses
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import renderer_mutation as gate


class MutationGateTests(unittest.TestCase):
    check = gate.logic("a named renderer boundary")
    assertion = ("error: 'Module.a named renderer boundary' failed without output\n"
                 "2/2 Module.a named renderer boundary...FAIL (TestExpectedEqual)\n")

    def test_only_the_named_behavioral_failure_is_a_kill(self):
        failed = {"returncode": 1, "timeout": False, "assertion": {"returncode": 1}}
        self.assertEqual(gate.classify(failed, self.assertion, self.check), "behavioral-kill")
        diagnostics = self.assertion.replace("...FAIL", "...expected 8, found 7\nFAIL")
        self.assertEqual(gate.classify(failed, diagnostics, self.check), "behavioral-kill")
        for output in (
            "error: 'Module.another test' failed: error.TestExpectedEqual",
            self.assertion.replace("TestExpectedEqual", "FileNotFound"),
            "error: 'Module.a named renderer boundary' failed without output",
            self.assertion + "compilation errors",
            self.assertion + "terminated by signal 6",
            "a named renderer boundary\nerror.TestExpectedEqual",
            diagnostics.replace("found 7\nFAIL", "found 7\n3/3 Module.another test...FAIL"),
        ):
            with self.subTest(output=output):
                self.assertNotEqual(gate.classify(failed, output, self.check), "behavioral-kill")
        self.assertEqual(gate.classify({**failed, "timeout": True}, self.assertion, self.check), "timeout")
        self.assertEqual(gate.classify({**failed, "returncode": 0}, "0/0 tests passed", self.check), "no-tests")

    def test_unhealthy_build_exit_cannot_count_or_replay(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "test"
            binary.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                              "Path('replayed').touch()\n"
                              "print('2/2 Module.a named renderer boundary...FAIL (TestExpectedEqual)')\n"
                              "raise SystemExit(1)\n")
            binary.chmod(0o755)
            for status in (-9, -11, 42):
                with self.subTest(status=status):
                    script = ("import os, resource; resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); "
                              f"print('info(verbose): {binary} --listen=-', flush=True); "
                              "print(\"error: 'Module.a named renderer boundary' failed without output\", flush=True); "
                              f"os.kill(os.getpid(), {-status})" if status < 0 else
                              f"print('info(verbose): {binary} --listen=-', flush=True); "
                              "print(\"error: 'Module.a named renderer boundary' failed without output\", flush=True); "
                              f"raise SystemExit({status})")
                    with patch.object(gate.Check, "command", return_value=[sys.executable, "-c", script]):
                        result = gate.run_check(self.check, root, root / f"exit-{status}.log", 5, dict(os.environ))
                    self.assertEqual(result["returncode"], status)
                    self.assertEqual(result["outcome"], "build-or-process-error")
                    self.assertFalse((root / "replayed").exists())

    def test_environment_prefixed_native_binary_is_executed_and_identified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "test"
            binary.write_text("#!/usr/bin/env python3\n"
                              "print('2/2 Module.a named renderer boundary...OK')\n")
            binary.chmod(0o755)
            script = f"print('info(verbose): RUI_TEST_EXACT_INACTIVITY=0 {binary} --listen=-')"
            with patch.object(gate.Check, "command", return_value=[sys.executable, "-c", script]):
                result = gate.run_check(self.check, root, root / "native.log", 5, dict(os.environ))
            self.assertEqual(result["outcome"], "passed")
            self.assertEqual(result["binary_sha256"], gate.sha(binary))

    def test_model_receipt_must_bind_source_selector_exits_and_actual_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "already-executed-test"
            binary.write_text("retained model binary")
            check = gate.model("pages")
            for status in (0, 1):
                receipt = {"source": str(root), "selector": "pages", "source_unchanged": True,
                           "overlay_unchanged": True,
                           "exit": status, "direct_exit": status,
                           "binary": str(binary), "binary_sha256": gate.sha(binary)}
                for index, alteration in enumerate(({}, {"source": "/wrong-source"}, {"selector": "focus"},
                                                     {"source_unchanged": False}, {"overlay_unchanged": False},
                                                     {"overlay_unchanged": None}, {"direct_exit": -9},
                                                     {"exit": 1 - status}, {"binary_sha256": "wrong"})):
                    with self.subTest(status=status, alteration=alteration):
                        log = root / f"model-{status}-{index}.log"
                        output = log.with_suffix(".model")
                        output.mkdir()
                        gate.write_json(output / "receipt.json", {**receipt, **alteration})
                        transcript = ("2/2 Module.TD1 sequence model pages...OK\n" if status == 0 else
                                      "error: 'Module.TD1 sequence model pages' failed without output\n"
                                      "2/2 Module.TD1 sequence model pages...FAIL (TestExpectedEqual)\n")
                        command = [sys.executable, "-c", f"print({transcript!r}); raise SystemExit({status})"]
                        with patch.object(gate.Check, "command", return_value=command):
                            result = gate.run_check(check, root, log, 5, dict(os.environ))
                        expected = "invalid-model-receipt" if alteration else "passed" if status == 0 else "behavioral-kill"
                        self.assertEqual(result["outcome"], expected)
                        if not alteration:
                            self.assertEqual(result["receipt_sha256"], gate.sha(output / "receipt.json"))

    def test_source_drift_during_baseline_or_mutant_execution_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "owner.zig").write_text("guard A;\n")
            mutation = gate.Mutation("A", "invariant", "fix", "owner.zig", "guard A", "no A", self.check)
            for stage in ("baseline", "A"):
                with self.subTest(stage=stage):
                    # A real builder changes a tracked input while emitting the
                    # expected test transcript. Caller-tree checks cannot see it.
                    script = ("from pathlib import Path\n"
                              "owner = Path('owner.zig')\n"
                              "failed = 'no A' in owner.read_text()\n"
                              "binary = Path('test').resolve()\n"
                              "binary.write_text('#!/usr/bin/env python3\\nprint(' + repr("
                              "'2/2 Module.a named renderer boundary...FAIL (TestExpectedEqual)' if failed else "
                              "'2/2 Module.a named renderer boundary...OK') + ')\\nraise SystemExit(' + str(int(failed)) + ')\\n')\n"
                              "binary.chmod(0o755)\n"
                              f"if Path.cwd().name == {stage!r}: owner.write_text('builder changed input')\n"
                              "print(f'info(verbose): {binary} --listen=-')\n"
                              "if failed: print(\"error: 'Module.a named renderer boundary' failed without output\")\n"
                              "raise SystemExit(int(failed))\n")
                    output = root / stage
                    with patch.object(gate, "tracked", return_value=[Path("owner.zig")]), \
                         patch.object(gate.subprocess, "check_output", return_value="fixture"), \
                         patch.object(gate.Check, "command", return_value=[sys.executable, "-c", script]):
                        if stage == "baseline":
                            with self.assertRaisesRegex(RuntimeError, "source-drift"):
                                gate.run(source, output, [mutation], 5)
                        else:
                            self.assertFalse(gate.run(source, output, [mutation], 5))
                    report = json.loads((output / "report.json").read_text())
                    self.assertTrue(report["tree_unchanged"])
                    rows = report["baseline"] if stage == "baseline" else report["mutations"]
                    self.assertEqual(rows[-1]["outcome"], "source-drift")
                    self.assertEqual((source / "owner.zig").read_text(), "guard A;\n")

    def test_isolated_mutants_and_baseline_preserve_caller_tree_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            (source / "owner.zig").write_text("guard A; guard B;\n")
            subprocess.run(["git", "add", "."], cwd=source, check=True)
            subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-qm", "fixture"], cwd=source, check=True)
            mutations = [gate.Mutation(name, "invariant", "fix", "owner.zig", before, after, self.check)
                         for name, before, after in [("A", "guard A", "no A"), ("B", "guard B", "no B")]]
            seen = []

            def run_check(check, directory, log, timeout, environment):
                text = (directory / "owner.zig").read_text()
                seen.append(text)
                failed = "no A" in text
                log.write_text(self.assertion if failed else "2/2 Module.a named renderer boundary...OK\n")
                result = {"returncode": int(failed), "timeout": False, "assertion": {"returncode": int(failed)}}
                return {**result, "outcome": gate.classify(result, log.read_text(), check)}

            with patch.object(gate, "run_check", run_check):
                self.assertFalse(gate.run(source, root / "evidence", mutations, 1))
            self.assertEqual(seen, ["guard A; guard B;\n", "no A; guard B;\n", "guard A; no B;\n"])
            self.assertEqual((source / "owner.zig").read_text(), seen[0])
            report = json.loads((root / "evidence/report.json").read_text())
            self.assertTrue(report["tree_unchanged"])
            self.assertEqual([row["outcome"] for row in report["mutations"]], ["behavioral-kill", "survived-gap"])
            self.assertIn("-guard A; guard B;", (root / "evidence/A.patch").read_text())
            with self.assertRaisesRegex(ValueError, "fresh evidence"):
                gate.run(source, root / "evidence", mutations, 1)
            empty = root / "empty"
            empty.mkdir()
            result = subprocess.run([sys.executable, gate.__file__, "--source", str(source),
                                     "--output", str(empty)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("No report was created", result.stdout)
            self.assertNotIn("Evidence:", result.stdout)

    def test_baseline_failure_stops_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mutation = gate.MUTATIONS[0]
            (root / "owner").write_text("unchanged")
            with patch.object(gate, "tracked", return_value=[Path("owner")]), \
                 patch.object(gate.subprocess, "check_output", return_value="fixture"), \
                 patch.object(gate, "run_check") as execute:
                def failure(check, directory, log, timeout, environment):
                    log.write_text("compile failure")
                    return {"returncode": 1, "timeout": False, "outcome": "build-or-process-error"}
                execute.side_effect = failure
                with self.assertRaisesRegex(RuntimeError, "unchanged baseline failed"):
                    gate.run(root, root / "evidence", [mutation], 1)
                self.assertEqual(execute.call_count, 1)
            report = json.loads((root / "evidence/report.json").read_text())
            self.assertTrue(report["tree_unchanged"])
            self.assertEqual(report["mutations"], [])

    def test_duplicate_or_missing_anchor_is_not_a_kill(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mutation = dataclasses.replace(gate.MUTATIONS[0], path="source", before="guard", after="removed")
            for content in ("unrelated", "guard guard"):
                (root / "source").write_text(content)
                with self.assertRaisesRegex(ValueError, "exactly one anchor"):
                    gate.apply(root, mutation)
                self.assertEqual((root / "source").read_text(), content)

    def test_target_partition_runs_each_protection_once_and_rejects_empty_selection(self):
        seen = []
        for target in ("test", "test-logic", "sequence-model"):
            with self.subTest(target=target), patch.object(sys, "argv", [
                    gate.__file__, "--output", "unused", "--target", target]), \
                    patch.object(gate, "run", return_value=True) as run:
                self.assertEqual(gate.main(), 0)
                selected = run.call_args.args[2]
                self.assertTrue(selected)
                self.assertTrue(all(mutation.check.target == target for mutation in selected))
                seen.extend(mutation.name for mutation in selected)
        self.assertCountEqual(seen, [mutation.name for mutation in gate.MUTATIONS])
        with patch.object(sys, "argv", [gate.__file__, "--output", "unused", "--target", "test",
                                        "--mutation", "stale-details"]), patch.object(gate, "run") as run:
            with self.assertRaises(SystemExit) as error:
                gate.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()

    def test_timeout_is_reaped_and_recorded_not_counted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = gate.execute(["python3", "-c", "import time; time.sleep(30)"], root,
                                  root / "timeout.log", 0.1, dict(os.environ))
            self.assertTrue(result["timeout"])
            self.assertLess(result["returncode"], 0)
            self.assertEqual(gate.classify(result, self.assertion, self.check), "timeout")


if __name__ == "__main__":
    unittest.main()
