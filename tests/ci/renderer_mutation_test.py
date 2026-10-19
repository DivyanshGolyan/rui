#!/usr/bin/env python3
"""Tests of the mutation gate's evidence contract, not renderer substitutes."""
import dataclasses
import json
import os
from pathlib import Path
import subprocess
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
        for output in (
            "error: 'Module.another test' failed: error.TestExpectedEqual",
            self.assertion.replace("TestExpectedEqual", "FileNotFound"),
            "error: 'Module.a named renderer boundary' failed without output",
            self.assertion + "compilation errors",
            self.assertion + "terminated by signal 6",
            "a named renderer boundary\nerror.TestExpectedEqual",
        ):
            with self.subTest(output=output):
                self.assertNotEqual(gate.classify(failed, output, self.check), "behavioral-kill")
        self.assertEqual(gate.classify({**failed, "timeout": True}, self.assertion, self.check), "timeout")
        self.assertEqual(gate.classify({**failed, "returncode": 0}, "0/0 tests passed", self.check), "no-tests")

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
