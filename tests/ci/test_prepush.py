import ast
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import prepush

ROOT = prepush.ROOT

SOURCE_CHECKS = {"tests/ci: test_import_architecture.py", "tests/ci: test_provider_locality.py",
                 "tests/ci: test_wire_version.py", "tests/ci: test_harness_contracts.py",
                 "tests/ci: test_platform_boundary.py"}
FIXTURE_CHECKS = {"tests/ci: test_wire_version.py", "tests/ci: test_harness_contracts.py",
                  "tests/ci: test_platform_boundary.py"}

AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', (prepush.ROOT / "build.zig").read_text()))


class PrepushTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.addCleanup(patch.stopall)
        patch.object(prepush, "ROOT", self.root).start()

    def file(self, path, text=""):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commands(self, paths, deleted=()):
        for path in paths:
            if path not in deleted:
                self.file(path)
        return dict(prepush.checks(paths, AVAILABLE, "BASE"))

    def test_docs_only_select_whitespace_and_scoped_sentence_checks(self):
        commands = self.commands(["AGENTS.md", "docs/agents/landing.md", ".claude/skills/rui-ci-triage/SKILL.md"])
        self.assertEqual(set(commands), {"whitespace", "markdown sentences"})
        self.assertEqual(commands["markdown sentences"][2:], ["--check", "AGENTS.md", "docs/agents/landing.md"])

    def test_sentence_checks_keep_the_existing_document_scope(self):
        commands = self.commands(["research/results.md", "THIRD_PARTY_NOTICES.md", ".github/notes.md"])
        self.assertEqual(set(commands), {"whitespace"})

    def test_zig_change_formats_only_its_file_and_keeps_selected_builds(self):
        commands = self.commands(["src/request_encoding.zig"])
        self.assertEqual(set(commands), SOURCE_CHECKS | {"whitespace", "zig fmt", "development selection", "macOS type check"})
        self.assertEqual(commands["zig fmt"], ["zig", "fmt", "--check", "--ast-check", "src/request_encoding.zig"])
        self.assertEqual(commands["development selection"], ["zig", "build", "test-logic", "--summary", "line"])

    def test_cli_inventory_uses_its_existing_owner_predicate(self):
        for path in ("src/cli.zig", "src/cli_args.zig", "src/client.zig", "src/preferences.zig", "src/caller_new.zig"):
            with self.subTest(path=path):
                names = list(self.commands([path]))
                self.assertLess(names.index("caller errors"), names.index("development selection"))
        self.assertNotIn("caller errors", self.commands(["src/store/Store.zig"]))

    def test_python_fixture_lints_only_the_changed_file_without_cross_compilation(self):
        commands = self.commands(["tests/integration/activity_integration.py"])
        self.assertEqual(set(commands), FIXTURE_CHECKS | {"whitespace", "undefined Python names", "development selection"})
        self.assertEqual(commands["undefined Python names"][1:], ["-m", "ruff", "check", "--select", "F821", "tests/integration/activity_integration.py"])

    def test_owned_policy_changes_run_their_focused_test_once(self):
        self.file("tests/ci/test_prepush.py")
        commands = self.commands(["tests/ci/prepush.py", "tests/ci/test_prepush.py"])
        policy = {name: command for name, command in commands.items() if name.startswith("tests/ci")}
        self.assertEqual(set(policy), {"tests/ci: test_prepush.py", "tests/ci: test_caller_errors.py", "tests/ci: test_selection.py", "tests/ci: test_harness_contracts.py"})
        self.assertEqual(policy["tests/ci: test_prepush.py"][3:], ["-B", "-m", "unittest", "discover", "-s", "tests/ci", "-p", "test_prepush.py"])
        self.assertEqual(policy["tests/ci: test_selection.py"][-2:], ["-k", "SelectionTest.test_prepush_leaves_server_targets_to_ci"])

    def test_unknown_or_shared_policy_inputs_fall_back_to_full_policy_tests(self):
        for path in (".github/workflows/check.yml", "tests/ci/shared_new.py", "tests/ci/requirements.txt", ".claude/hooks/block_full_runs.py", ".claude/settings.json", "build.zig.zon"):
            with self.subTest(path=path):
                commands = self.commands([path])
                self.assertEqual(commands["tests/ci"][3:], ["-B", "-m", "unittest", "discover", "-s", "tests/ci"])

    def test_focused_policy_discovery_has_its_fixture_import_path(self):
        self.file("tests/ci/test_prepush.py")
        commands = self.commands(["tests/ci/prepush.py"])
        for name, command in commands.items():
            if name.startswith("tests/ci"):
                self.assertEqual(command[0], "env")
                self.assertTrue(command[1].startswith(f"PYTHONPATH={self.root / 'tests/integration'}"))

    def test_full_policy_selection_subsumes_focused_tests(self):
        commands = self.commands(["tests/ci/test_prepush.py", ".github/workflows/check.yml"])
        self.assertEqual([name for name in commands if name.startswith("tests/ci")], ["tests/ci"])

    def test_mixed_changes_union_and_deduplicate_commands(self):
        paths = ["AGENTS.md", "src/cli_args.zig", "tests/integration/activity_integration.py"]
        self.commands(paths)
        commands = list(prepush.checks(paths + paths, AVAILABLE, "BASE"))
        self.assertEqual(len(commands), len(dict(commands)))
        self.assertEqual(set(dict(commands)), SOURCE_CHECKS | {"whitespace", "markdown sentences", "zig fmt", "caller errors", "undefined Python names", "development selection", "macOS type check"})

    def test_deleted_files_still_select_owner_checks_but_not_file_tools(self):
        commands = self.commands(["src/cli_args.zig", "tests/integration/activity_integration.py", "AGENTS.md"], deleted=["src/cli_args.zig", "tests/integration/activity_integration.py", "AGENTS.md"])
        self.assertEqual(set(commands), SOURCE_CHECKS | {"whitespace", "caller errors", "development selection", "macOS type check"})
        self.assertIn("tests/ci", self.commands(["tests/ci/test_removed.py"], deleted=["tests/ci/test_removed.py"]))

    def test_build_changes_keep_development_selection_and_cross_compilation(self):
        commands = self.commands(["build.zig"])
        self.assertTrue({"whitespace", "zig fmt", "tests/ci", "development selection", "macOS type check"} <= set(commands))
        self.assertNotIn("check-full", commands["development selection"])

    def test_client_changes_run_the_client_check_without_a_zig_build(self):
        commands = self.commands(["clients/ts/src/index.ts"])
        self.assertEqual(set(commands), {"whitespace", "TypeScript client"})
        self.assertEqual(commands["TypeScript client"], ["npm", "--prefix", "clients/ts", "run", "check"])

    def test_client_and_zig_changes_keep_both_owners_once(self):
        commands = self.commands(["clients/ts/src/index.ts", "src/request_encoding.zig", "clients/ts/package.json"])
        self.assertEqual(set(commands), SOURCE_CHECKS | {"whitespace", "zig fmt", "TypeScript client", "development selection", "macOS type check"})

    def test_openapi_changes_check_the_client_and_its_native_owner(self):
        commands = self.commands(["openapi.json"])
        self.assertEqual(set(commands), {"whitespace", "TypeScript client", "development selection"})

    def test_native_helpers_do_not_run_unrelated_policy_or_typechecks(self):
        self.assertEqual(set(self.commands(["src/bash_platform.c"])), {"whitespace", "development selection"})

    def test_qualification_go_keeps_wire_and_native_evidence_policies(self):
        commands = self.commands(["tests/qualification/example.go"])
        self.assertEqual(set(commands), {"whitespace", "development selection", "tests/ci: test_wire_version.py", "tests/ci: test_harness_contracts.py"})
        self.assertEqual(commands["tests/ci: test_harness_contracts.py"][-2:], ["-k", "QualificationEvidenceTest"])

    def test_experimental_zig_does_not_borrow_another_owners_build_targets(self):
        commands = self.commands(["research/matklad-experiments/parser/probe.zig", "tests/integration/activity_integration.py"])
        self.assertNotIn("macOS type check", commands)
        self.assertIn("development selection", commands)
        self.assertIn("zig fmt", commands)

    def test_observation_changes_select_codec_and_ordering_checks_in_one_command(self):
        commands = self.commands(["src/TestObservation.zig", "tests/qualification/measurement/observation.go"])
        command = commands["tests/ci: test_harness_contracts.py"]
        self.assertEqual(command.count("-p"), 1)
        filters = {command[index + 1] for index, item in enumerate(command) if item == "-k"}
        self.assertEqual(filters, {"ObservationCodecTest", "QualificationEvidenceTest", "SleepOrderingTest.test_tree_matches_the_shrink_only_allowlist"})

    def test_store_schema_keeps_history_coherence_and_engine_boundaries(self):
        commands = self.commands(["src/store/schema.zig"])
        self.assertTrue(SOURCE_CHECKS | {"tests/ci: test_store_schema_version.py", "tests/ci: test_store_schema_fixtures.py", "tests/ci: test_store_engine_boundary.py", "tests/ci: test_store_conformance.py"} <= set(commands))

    def test_store_live_server_targets_stay_with_ci(self):
        commands = self.commands(["src/store/rsql.zig"])
        self.assertEqual(commands["development selection"], ["zig", "build", "test-logic", "--summary", "line"])

    def test_every_platform_scanned_domain_selects_the_existing_platform_gate(self):
        for pattern in prepush.PLATFORM_SCANNED:
            with self.subTest(pattern=pattern):
                commands = self.commands([pattern.replace("*", "new_owner")])
                self.assertIn("tests/ci: test_platform_boundary.py", commands)

    def test_sleep_policy_covers_all_source_and_ci_test_domains(self):
        for path in ("src/example.zig", "tests/integration/new_actor.zig", "tests/qualification/new_probe.zig", "tests/integration/new_fixture.py", "tests/ci/test_new_owner.py", "tests/ci/renderer_mutation_test.py"):
            with self.subTest(path=path):
                commands = self.commands([path])
                if "tests/ci" in commands:
                    continue
                self.assertIn("tests/ci: test_harness_contracts.py", commands)
                self.assertIn("SleepOrderingTest.test_tree_matches_the_shrink_only_allowlist", commands["tests/ci: test_harness_contracts.py"])

    def test_integration_zig_keeps_test_reachability_platform_and_sleep_policies(self):
        commands = self.commands(["tests/integration/mysql_wire_test.zig"])
        self.assertTrue({"tests/ci: test_import_architecture.py", "tests/ci: test_platform_boundary.py", "tests/ci: test_harness_contracts.py"} <= set(commands))

    def test_explicit_policy_routes_name_existing_test_modules_and_filters(self):
        for _, tests in prepush.SOURCE_POLICY:
            for module, pattern in tests:
                with self.subTest(module=module, pattern=pattern):
                    tree = ast.parse((ROOT / "tests/ci" / module).read_text())
                    methods = [f"{node.name}.{child.name}" for node in tree.body if isinstance(node, ast.ClassDef)
                               for child in node.body if isinstance(child, ast.FunctionDef) and child.name.startswith("test_")]
                    self.assertTrue(methods)
                    if pattern != "*":
                        self.assertTrue(any(pattern in method for method in methods), "route would silently run zero tests")

    def test_empty_diff_runs_nothing(self):
        self.assertEqual(self.commands([]), {})

    def test_plan_does_not_execute_checks(self):
        self.file("build.zig")
        with patch("sys.argv", ["prepush.py", "--plan"]), patch.object(prepush, "changed_paths", return_value=(["AGENTS.md"], "BASE")), patch.object(prepush.subprocess, "check_output", return_value="BASE\n"), patch.object(prepush.subprocess, "run") as run, redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as result:
                prepush.main()
        self.assertEqual(result.exception.code, 0)
        run.assert_not_called()
        plan = json.loads(output.getvalue())
        self.assertEqual(plan["base"], "BASE")
        self.assertEqual(plan["paths"], ["AGENTS.md"])
        self.assertEqual([check["name"] for check in plan["checks"]], ["whitespace"])

    def test_execution_runs_each_command_once_and_reports_failures(self):
        self.file("build.zig")
        checks = [("first", ["first"]), ("second", ["second"])]
        with patch("sys.argv", ["prepush.py"]), patch.object(prepush, "changed_paths", return_value=(["file"], "BASE")), patch.object(prepush.subprocess, "check_output", return_value="BASE\n"), patch.object(prepush, "checks", return_value=iter(checks)), patch.object(prepush.subprocess, "run", side_effect=[type("Result", (), {"returncode": 1})(), type("Result", (), {"returncode": 0})()]) as run, redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as result:
                prepush.main()
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1]), {"failed": ["first"]})


if __name__ == "__main__":
    unittest.main()
