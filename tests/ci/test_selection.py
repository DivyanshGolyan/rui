import ast
import json
import re
import os
from contextlib import ExitStack
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from textwrap import dedent
from unittest.mock import patch

from select_tests import (CACHE_POLICY, CHECK_COVERS, FIXTURE_COVERS, FIXTURES, LIVE_MYSQL_TARGETS, LIVE_POSTGRES_TARGETS, LIVE_RULES,
                          POLICY_SELF_CHECKS, RENDERER_HARNESSES, RULES, SCREEN_TARGETS, TEST_CODE, Graph, execution_batches, matches, select,
                          setup_requirements, tree_graph)
from qualification import NATIVE, RESOURCES, qualification, shards

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from host_process import dispose_all, wait_for


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))


def named_paths(patterns):
    """Each path a rule's patterns name: a literal pattern itself, and every
    tracked file a glob matches, less the rule's "!" exclusions."""
    tracked = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    included = [pattern for pattern in patterns if not pattern.startswith("!")]
    named = {pattern for pattern in included if not any(char in pattern for char in "*?[")}
    named |= {path for path in tracked if matches(path, patterns)}
    return sorted(path for path in named if matches(path, patterns))


def covered(target, targets):
    """`target` runs when `targets` are selected, directly or inside check or check-full."""
    return (target in targets or target in CHECK_COVERS and bool(targets & {"check", "check-full"})
            or target in {"test-native", "test-store"} and "test" in targets
            or any(target in cases and broad in targets for broad, cases in FIXTURE_COVERS.items())
            or target in {"check", "stack-frames"} and "check-full" in targets
            or target == "stack-frames" and "check" in targets)


class WorkflowEntrypointsTest(unittest.TestCase):
    def test_workflows_have_no_scheduled_triggers_or_branches(self):
        workflows = sorted(Path(".github/workflows").glob("*.y*ml"))
        self.assertTrue(workflows)
        for path in workflows:
            with self.subTest(workflow=path.name):
                self.assertNotRegex(path.read_text(), r"(?m)^\s*schedule\s*:")
                self.assertNotRegex(path.read_text(), r"github\.event_name\s*==\s*[\"']schedule[\"']")

    def test_removed_scheduled_wrappers_have_no_live_references(self):
        removed = ("daily-macos.yml", "cold-acceptance.yml",
                   "Daily changed-main macOS", "Scheduled cold acceptance")
        paths = [*Path(".github").rglob("*.y*ml"), Path("VERIFICATION.md"),
                 Path("tests/ci/platform_boundary.py")]
        for name in removed[:2]:
            self.assertFalse(Path(".github/workflows", name).exists(), name)
        for path in paths:
            with self.subTest(path=str(path)):
                for name in removed:
                    self.assertNotIn(name, path.read_text())


class RuleMatchTest(unittest.TestCase):
    def test_a_lone_change_to_any_path_a_rule_names_selects_that_rule(self):
        # A shortcut in select() may add to a path's selection but never skip
        # its rules: the tests/ci shortcut once dropped live_engine_step.py's
        # live rules (Codex P2 on #873), as the draft cut once dropped `test`.
        failures = []
        rules = [(rule, None) for rule in RULES[:len(RULES) - len(LIVE_RULES)]] + [(rule[:4], rule[4]) for rule in LIVE_RULES]
        for (patterns, checks, _, reason), served_by in rules:
            for path in named_paths(patterns):
                for phase in ("development", "review"):
                    targets = set(select([path], phase, AVAILABLE)["targets"])
                    wanted = set(checks) if phase == "review" else set()
                    if checks and not targets:
                        failures.append((phase, path, reason, "selected nothing"))
                    missing = {target for target in wanted if not covered(target, targets)}
                    if missing:
                        failures.append((phase, path, reason, sorted(missing)))
                    if served_by and not targets & served_by:
                        failures.append((phase, path, reason, "starts no server"))
        self.assertEqual(failures, [])


class SelectionTest(unittest.TestCase):
    def test_native_conformance_dependencies_keep_live_mysql(self):
        graph = tree_graph()
        for path in ("src/find_tools.zig", "src/find_tools_tests.zig", "src/read_transcript.zig",
                     "src/launch_frame.zig"):
            for phase in ("development", "review"):
                with self.subTest(path=path, phase=phase):
                    result = select([path], phase, AVAILABLE, graph)
                    self.assertIn("test", result["targets"])
                    self.assertIn("test", result["server_targets"])
        for path in graph.live_conformance & graph.reached["test-native"]:
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE, graph)
                self.assertTrue(set(result["targets"]) & LIVE_MYSQL_TARGETS)

    def test_unit_roots_follow_store_imports(self):
        native = select(["src/session_consent.zig"], "review", AVAILABLE)["targets"]
        self.assertIn("test-native", native)
        self.assertNotIn("test-store", native)
        self.assertNotIn("test", native)
        store = select(["src/store/rsql.zig"], "review", AVAILABLE)["targets"]
        self.assertIn("test", store)
        self.assertNotIn("test-native", store)
        self.assertNotIn("test-store", store)

    def test_upgrade_owners_select_standalone_fixture_in_both_phases(self):
        paths = ("src/upgrade.zig", "src/installation_path.zig", "src/TerminalEditor.zig", "src/Installation.zig", "src/release_candidate.zig",
                 "src/upgrade_process.zig", "src/HostLifecycle.zig", "src/host_identity.zig",
                 "src/host_identity.c", "src/UpgradePanel.zig", "src/host_launch.c",
                 "src/cli.zig", "src/cli_args.zig", "src/client.zig", "src/slash_commands.zig",
                 "src/Overview.zig", "src/overview_view.zig", "src/SessionFrontend.zig",
                 "tests/integration/upgrade_integration.py", "release/publish.sh", "release/install.sh",
                 "install.sh", "build.zig")
        for path in paths:
            for phase in ("development", "review"):
                with self.subTest(path=path, phase=phase):
                    result = select([path], phase, AVAILABLE)
                    self.assertIn("upgrade-integration", result["targets"])
                    if phase == "review":
                        self.assertIn("upgrade-integration", result["native_targets"])

    def test_installer_owners_select_standalone_fixture_in_both_phases(self):
        paths = ("tests/integration/installer_integration.py", "tests/ci/fake_rui.py",
                 "tests/ci/test_install.py", "tests/ci/test_installer_boundary.py", "tests/ci/test_release.py", "tests/ci/release.py",
                 "tests/ci/release_numbers.py", "tests/ci/qualification.py", "src/Installation.zig", "src/installation_path.zig",
                 "src/release_candidate.zig", "src/cli.zig", "src/cli_args.zig", "src/store/schema.zig",
                 "src/fetch_dependencies.sh", "release/publish.sh", "release/install.sh",
                 "install.sh", "build.zig", "build.zig.zon")
        for path in paths:
            for phase in ("development", "review"):
                with self.subTest(path=path, phase=phase):
                    result = select([path], phase, AVAILABLE)
                    self.assertIn("installer-integration", result["targets"])
                    if phase == "review":
                        self.assertIn("installer-integration", result["native_targets"])
                    else:
                        self.assertEqual(result["native_targets"], [])

    def test_request_wait_selects_its_native_oracle_and_portable_core(self):
        for path in ("src/client.zig", "src/cli_args.zig", "src/server.zig",
                     "src/TestObservation.zig", "tests/integration/request_wait_integration.py",
                     "tests/integration/model_fixture.py", "tests/integration/host_process.py",
                     "tests/integration/bash_fixture.py", "tests/integration/canonical_fixture.py"):
            selected = set(select([path], "review", AVAILABLE)["targets"])
            self.assertTrue(covered("request-wait-integration", selected), (path, selected))
        core = select(["src/request_wait.zig"], "review", AVAILABLE)["targets"]
        self.assertIn("test-logic", core)
        self.assertIn("request-wait-integration", core)

    def test_catalog_sources_select_the_portable_catalog_tests(self):
        for path in ("src/models_dev.zig", "src/model_catalog.zig",
                     "src/model_catalog_main.zig", "src/model_catalog_snapshot.zig"):
            for phase in ("development", "review"):
                with self.subTest(path=path, phase=phase):
                    targets = select([path], phase, AVAILABLE)["targets"]
                    self.assertIn("test-logic", targets)
                    self.assertNotIn("check", targets)

    def test_development_does_not_claim_native_acceptance(self):
        # The Store keeps its root for the live MySQL check; nothing else widens.
        result = select(["src/bash_platform.c", "src/store.zig"], "development", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic", "test-store"])
        self.assertFalse(result["native_required"])
        self.assertEqual(select(["src/bash_platform.c"], "development", AVAILABLE)["targets"], ["test-logic"])

    def test_a_store_change_starts_mysql_for_the_live_dialect_check_in_every_phase(self):
        for phase in ("development", "review"):
            with self.subTest(phase=phase):
                result = select(["src/store/rsql.zig"], phase, AVAILABLE)
                self.assertTrue(set(result["targets"]) & LIVE_MYSQL_TARGETS, result["targets"])

    def test_every_live_rule_selects_a_target_that_starts_its_server(self):
        for patterns, _, _, reason, served_by in LIVE_RULES:
            path = next(pattern.replace("*", "x") for pattern in patterns if not pattern.startswith("!"))
            for phase in ("development", "review"):
                with self.subTest(reason=reason, phase=phase):
                    self.assertIn(reason, select([path], phase, AVAILABLE)["reasons"])
                    self.assertTrue(set(select([path], phase, AVAILABLE)["targets"]) & served_by)

    def test_prepush_leaves_server_targets_to_ci(self):
        import prepush
        for path in ("src/store/rsql.zig", "src/store/wire/mysql_connection.zig", "src/store/wire/pg.zig"):
            with self.subTest(path=path):
                builds = [command for name, command in prepush.checks([path], AVAILABLE, "HEAD") if name == "development selection"]
                self.assertEqual(builds, [["zig", "build", "test-logic", "--summary", "line"]])

    def test_live_server_targets_match_the_workflow_conditions_that_start_the_servers(self):
        workflow = Path(".github/workflows/check.yml").read_text()

        def named(line):
            return frozenset(re.findall(r"contains\(matrix\.targets, '([a-z0-9-]+)'\)", line))

        live_mysql = next(line for line in workflow.splitlines() if line.strip().startswith("LIVE_MYSQL:"))
        self.assertEqual(named(live_mysql), LIVE_MYSQL_TARGETS)
        postgres = workflow.split("- name: Start Postgres 15", 1)[1].splitlines()[1]
        self.assertTrue(postgres.strip().startswith("if:"), postgres)
        self.assertEqual(named(postgres), LIVE_POSTGRES_TARGETS)

    def test_portable_owner_does_not_require_full_suite(self):
        result = select(["src/request_encoding.zig"], "review", AVAILABLE)
        self.assertIn("test-logic", result["targets"])
        self.assertNotIn("check", result["targets"])

    def test_host_frame_inputs_select_the_linux_frame_gate(self):
        # src/preferences.zig reaches the Host only through stack_frames.json's
        # host_modules; #975's 8 KiB frame was caught there.
        for path in ("src/request_encoding.zig", "src/h2/Engine.zig", "src/bash_platform.c", "build.zig",
                     "src/preferences.zig", "src/store.zig", "tests/ci/stack_frames.json", "tests/ci/stack_frames.py"):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                self.assertIn("stack-frames", result["targets"])
                self.assertNotIn("stack-frames", result["native_targets"])
        # Zig the Host never compiles has no Host frame.
        for path in ("src/SessionFrontend.zig", "src/tests.zig", "src/logic_tests.zig", "src/store/wire/pg.zig"):
            with self.subTest(path=path):
                self.assertNotIn("stack-frames", select([path], "review", AVAILABLE)["targets"])

    def test_logic_root_selects_its_executable_root(self):
        for path in ("src/logic_tests.zig", "src/core_boundary.zig"):
            self.assertEqual(select([path], "review", AVAILABLE)["targets"], ["test-logic"])

    def test_native_unit_aggregate_selects_its_root_not_check(self):
        alone = select(["src/tests.zig"], "review", AVAILABLE)
        self.assertEqual((alone["targets"], alone["native_targets"]), (["test-native"], ["test-native"]))
        # What it newly lists selects what reaches that file, not check.
        owned = select(["src/tests.zig", "src/mcp/Running.zig"], "review", AVAILABLE)["targets"]
        self.assertTrue({"launch-frame-integration", "test-native"} <= set(owned))
        self.assertNotIn("check", owned)

    def test_shared_context_text_keeps_all_request_oracle_consumers(self):
        # The Host embeds both texts in requests; fixtures and Go request oracles read them.
        request = {"test-native", "dispatch-integration", "transport-h2-integration"}
        for path, readers in (("src/model_instructions.txt", {"codex-h2-integration", "current-facts-integration",
                                                               "server-delivery-integration", "peer-integration",
                                                               "measurement-check"}),
                              ("src/peer_message.txt", {"peer-integration", "sender-identity-integration"})):
            with self.subTest(path=path):
                targets = set(select([path], "review", AVAILABLE)["targets"])
                self.assertEqual({target for target in request | readers if not covered(target, targets)}, set())

    def test_cli_configuration_surface_runs_the_measurement_configure_contract(self):
        for path in ("src/cli_args.zig", "src/client.zig", "src/configure_input.zig", "src/product_defaults.zig",
                     "src/protocol.zig", "src/store/domain/configuration.zig", "openapi.json"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                with self.subTest(path=path, family=family):
                    self.assertIn("measurement-check", result[family])

    def test_every_functional_core_selects_the_boundary_check(self):
        source = (Path(__file__).resolve().parents[2] / "src" / "logic_tests.zig").read_text()
        listed = source.split("const cores = .{", 1)[1].split("\n};", 1)[0]
        cores = re.findall(r'\.\{ "([^"]+\.zig)", @import', listed)
        self.assertIn("BashLifecycle.zig", cores)
        for core in cores:
            with self.subTest(core=core):
                self.assertIn("test-logic", select([f"src/{core}"], "review", AVAILABLE)["targets"])

    def test_store_tests_reach_no_store_caller(self):
        # The Store's tests cross only the Store's interface. A file that
        # imports store.zig tests its own behavior over a Store in its own
        # file; a Store test importing it would make every change to its
        # callers rerun the Store's tests.
        graph = tree_graph()
        store = [name for name in graph.every if name.startswith("src/store/")]
        callers = sorted(name for name in graph.closure(graph.every, store)
                         if not name.startswith("src/store/") and "src/store.zig" in graph.every.get(name, ()))
        self.assertEqual(callers, [], "Store tests reach these Store callers; move the tests that "
                         "import them into the callers")

    def test_store_code_imports_no_protocol(self):
        # The Store reads and writes plain values; the Host translates
        # between them and the wire, so a wire change does not reach it.
        graph = tree_graph()
        importers = sorted(name for name, imported in graph.production.items()
                           if name.startswith("src/store/") and not matches(name, TEST_CODE)
                           and "src/protocol.zig" in imported)
        self.assertEqual(importers, [], "Store code imports protocol.zig; import the leaf that owns the "
                         "value, and translate wire types where the Host calls the Store")

    def test_registered_cores_reach_only_unit_roots_unless_a_fixture_names_them(self):
        # A core's value tests own its decisions. A fixture that asserts one
        # names it as an owner, and keeps it.
        graph = tree_graph()
        self.assertTrue(graph.cores)
        for core in sorted(graph.cores):
            with self.subTest(core=core):
                reached = graph.targets(core) or set()
                # What compiles the core or reads it, as fixtures read owned values.
                compiled = {target for target, files in graph.reached.items() if core in files}
                named = {target for target, (_, _, owners) in FIXTURES.items() if core in owners}
                self.assertTrue(named <= reached)
                self.assertEqual(reached - compiled - named, set())
        for path in ("src/cli_value.zig", "src/draft_layout.zig", "src/keymap.zig"):
            with self.subTest(path=path):
                self.assertNotIn("check", select([path], "review", AVAILABLE)["targets"])

    def test_http2_client_selects_its_own_tests(self):
        for path in ("src/h2/Engine.zig", "src/h2/policy.zig"):
            with self.subTest(path=path):
                targets = select([path], "review", AVAILABLE)["targets"]
                self.assertIn("test-h2", targets)
                self.assertNotIn("check", targets)
        self.assertIn("test-logic", select(["src/h2/policy.zig"], "review", AVAILABLE)["targets"])

    def test_postgres_wire_client_selects_its_own_tests_and_shared_trust_reaches_them(self):
        self.assertEqual(select(["src/store/wire/pg.zig"], "review", AVAILABLE)["targets"], ["test-pg"])
        shared = set(select(["src/tls_client/tls_client.zig"], "review", AVAILABLE)["targets"])
        self.assertTrue({"test-h2", "test-pg", "mysql-wire-integration"} <= shared)
        for path in ("src/h2/tls.zig", "src/h2/Engine.zig", "src/h2/Connection.zig", "src/h2/Stream.zig"):
            with self.subTest(path=path):
                self.assertNotIn("test-pg", select([path], "review", AVAILABLE)["targets"])

    def test_store_rule_leaves_wire_clients_to_their_own_rules(self):
        self.assertNotIn("dispatch-debug-integration", select(["src/store/wire/mysql.zig"], "review", AVAILABLE)["targets"])
        self.assertIn("dispatch-debug-integration", select(["src/store/rsql.zig"], "review", AVAILABLE)["targets"])
        self.assertFalse(matches("src/store/wire/pg.zig", ("src/store/*", "!src/store/wire/*")))
        self.assertTrue(matches("src/store/domain/turn.zig", ("src/store/*", "!src/store/wire/*")))

    def test_portable_roots_keep_their_native_owner_checks(self):
        for path, owner in (("src/SessionInput.zig", "human-cli-integration"), ("src/tools.zig", "bash-integration")):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertTrue({"test-logic", owner} <= set(result[family]))
                    self.assertNotIn("check", result[family])

    def test_response_timing_keeps_native_timeout_consumers(self):
        result = select(["src/ResponseTiming.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration", "request-wait-integration", "test-full", "test-logic"}
                            <= set(result[family]))
        self.assertTrue(result["native_required"])

    def test_test_full_runs_beside_a_full_native_suite(self):
        # test-full holds only the real-time witness; test, check or check-full runs the rest.
        for path in ("src/client.zig", "src/ResponseTiming.zig", "build.zig", "build.zig.zon",
                     "install.sh", ".github/actions/setup/action.yml"):
            with self.subTest(path=path):
                targets = set(select([path], "review", AVAILABLE)["targets"])
                self.assertIn("test-full", targets)
                self.assertTrue(targets & {"test", "test-native", "check", "check-full"})
        self.assertIn("check-full", NATIVE)

    def test_frontend_selects_the_pty_fixtures_that_drive_it_not_check(self):
        for path in ("src/SessionFrontend.zig", "src/SessionTerminal.zig", "src/Overview.zig"):
            with self.subTest(path=path):
                result = select([path, "README.md"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("human-cli-integration", result[family])
                    self.assertNotIn("check", result[family])
        # The human CLI gate runs the PTY cases it composes; they are not selected twice.
        result = select(["src/SessionFrontend.zig", "tests/integration/terminal_restoration_cases.py"],
                        "review", AVAILABLE)
        self.assertNotIn("terminal-restoration-integration", result["targets"])

    def test_renderer_diff_skips_check_before_landing(self):
        for paths in (["src/SessionFrontend.zig"], ["src/TerminalText.zig"], ["src/AnswerRenderer.zig"],
                      ["src/ConversationViewport.zig"], ["src/session_sequence_model_test.zig"],
                      ["src/request_encoding.zig"], ["README.md"]):
            with self.subTest(paths=paths):
                landing = select(paths, "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertNotIn("check", landing[family])

    def test_strict_paths_never_retry(self):
        # Each of these selected retryable suites before strictness decided retries.
        for paths in (["tests/integration/bash_integration.py"], ["src/store.zig"], ["src/server.zig"],
                      ["src/server_execution.zig"], ["src/server_host.zig"],
                      ["src/cli.zig", "build.zig.zon"]):
            with self.subTest(paths=paths):
                self.assertFalse(select(paths, "review", AVAILABLE)["retry"])
        for paths in (["src/cli.zig"], ["tests/integration/codex_integration.py"], ["src/bash_platform.c"]):
            with self.subTest(paths=paths):
                self.assertTrue(select(paths, "review", AVAILABLE)["retry"])

    def test_composed_gates_do_not_cover_the_separate_logic_root(self):
        for logic in ("src/logic_tests.zig", "src/AnswerRenderer.zig",
                      "src/request_encoding.zig", "src/execution_turn.zig",
                      "src/ResponseTiming.zig"):
            for composed in ("tests/integration/host_process.py", "build.zig"):
                with self.subTest(logic=logic, composed=composed):
                    result = select([logic, composed], "review", AVAILABLE)
                    self.assertIn("test-logic", result["targets"])
                    self.assertTrue(set(result["targets"]) & {"check", "check-full"})

    def test_docs_are_not_runtime_acceptance(self):
        self.assertEqual(select(["VERIFICATION.md"], "review", AVAILABLE)["targets"], [])

    def test_linux_status_requires_policy_even_without_native_work(self):
        workflow = Path('.github/workflows/check.yml').read_text()
        job = re.search(r'(?ms)^  linux:\n(.*?)(?=^  [a-z_]+:|\Z)', workflow)[1]
        expression = re.search(r'if: \$\{\{ (.*?) \}\}', job)[1]
        expression = re.sub(r'!(?!=)', 'not ', expression.replace('&&', 'and').replace('||', 'or'))
        script = dedent(job.split('run: |\n', 1)[1].split('\n      - ', 1)[0])
        cases = []
        for targets in ('[]', ''):  # Documentation and duplicate-push suppression.
            cases.append((targets, 'success', 'success', 'skipped', 'skipped', False, 'success'))
            for result in ('failure', 'cancelled', 'skipped'):
                cases.extend([
                    (targets, 'success', result, 'skipped', 'skipped', False, 'failure'),
                    (targets, result, 'success', 'skipped', 'skipped', False, 'failure'),
                ])
            for result in ('success', 'failure', 'cancelled'):
                cases.extend([
                    (targets, 'success', 'success', result, 'skipped', False, 'failure'),
                    (targets, 'success', 'success', 'skipped', result, False, 'failure'),
                ])
        cases.append(('["test-logic"]', 'success', 'success', 'success', 'success', False, 'success'))
        for result in ('failure', 'cancelled', 'skipped'):
            cases.extend([
                ('["test-logic"]', 'success', result, 'success', 'success', False, 'failure'),
                ('["test-logic"]', 'success', 'success', result, 'success', False, 'failure'),
                ('["test-logic"]', 'success', 'success', 'success', result, False, 'failure'),
            ])
        cases.append(('[]', 'skipped', 'skipped', 'skipped', 'skipped', True, 'skipped'))
        # The macOS type-check runs exactly when the Linux build does.
        cases = [(*case, case[3]) for case in cases]
        for result in ('failure', 'cancelled', 'skipped'):
            cases.append(('["test-logic"]', 'success', 'success', 'success', 'success', False, 'failure', result))
        for result in ('success', 'failure'):
            cases.append(('[]', 'success', 'success', 'skipped', 'skipped', False, 'failure', result))
        # The unit producer runs exactly when the plan splits the Linux build.
        cases = [(*case, 'false', 'skipped') for case in cases]
        green = ('["check"]', 'success', 'success', 'success', 'success', False)
        cases.append((*green, 'success', 'success', 'true', 'success'))
        for result in ('failure', 'cancelled', 'skipped'):
            cases.append((*green, 'failure', 'success', 'true', result))
        cases.append((*green, 'failure', 'success', 'false', 'success'))
        cases = [(*case, 'false', 'skipped') for case in cases]
        for targets in ('[]', '["check"]'):
            build = native = typecheck = 'skipped' if targets == '[]' else 'success'
            for codegen, result, expected in (('true', 'success', 'success'),
                                             ('true', 'failure', 'failure'),
                                             ('true', 'cancelled', 'failure'),
                                             ('true', 'skipped', 'failure'),
                                             ('false', 'success', 'failure')):
                cases.append((targets, 'success', 'success', build, native, False, expected,
                              typecheck, 'false', 'skipped', codegen, result))
        for targets, plan, policy, build, native, private, expected, typecheck, split, unit, codegen, codegen_result in cases:
            with self.subTest(targets=targets, plan=plan, policy=policy, build=build, native=native, private=private,
                              typecheck=typecheck, split=split, unit=unit):
                needs = SimpleNamespace(plan=SimpleNamespace(result=plan, outputs=SimpleNamespace(targets=targets)))
                github = SimpleNamespace(event=SimpleNamespace(repository=SimpleNamespace(private=private)))
                admitted = eval(expression, {'__builtins__': {}, 'always': lambda: True,
                                             'needs': needs, 'github': github})
                # Actions implicitly adds success() unless a status-check
                # function appears; a skipped dependency otherwise skips us.
                if not re.search(r'\b(?:always|success|failure|cancelled)\s*\(', expression):
                    admitted = admitted and all(value == 'success' for value in (plan, policy, build, native, typecheck))
                actual = 'skipped'
                if admitted:
                    result = subprocess.run(['bash', '-e', '-c', script], capture_output=True,
                                            env={**os.environ, 'TARGETS': targets, 'PLAN_RESULT': plan,
                                                 'POLICY_RESULT': policy, 'BUILD_RESULT': build,
                                                 'NATIVE_RESULT': native, 'TYPECHECK_RESULT': typecheck,
                                                 'SPLIT': split, 'UNIT_RESULT': unit,
                                                 'CODEGEN': codegen, 'CODEGEN_RESULT': codegen_result})
                    actual = 'success' if result.returncode == 0 else 'failure'
                self.assertEqual(actual, expected)

    def test_producers_split_only_beside_other_compiles(self):
        from qualification import split_build
        for targets in (["check"], ["check-full"], ["test", "test-logic"], ["test-native", "test-logic"],
                        ["test-store", "test-logic"],
                        ["check", "admission-debug-integration"]):
            self.assertTrue(split_build(targets), targets)
        for targets in ([], ["test"], ["test-native"], ["test-store"], ["test-logic", "admission-debug-integration"]):
            self.assertFalse(split_build(targets), targets)

    def test_macos_split_workflow_uses_the_shared_handoff(self):
        workflow = Path('.github/workflows/check.yml').read_text()
        jobs = dict(re.findall(r'(?ms)^  ([a-z_]+):\n(.*?)(?=^  [a-z_]+:|\Z)', workflow))
        self.assertIn('macos_split: ${{ steps.select.outputs.macos_split }}', jobs['plan'])
        for name, part, artifact in (('macos_build', 'compiled', 'compiled-macos'),
                                     ('macos_build_unit', 'compiled-unit', 'compiled-macos-unit')):
            job = jobs[name]
            self.assertIn('needs: plan', job)
            self.assertIn('runs-on: macos-15', job)
            self.assertIn('timeout-minutes: ' + ('60' if name == 'macos_build' else '15'), job)
            self.assertIn('check-part: ' + part + '\n', job)
            self.assertIn('TARGETS: ${{ needs.plan.outputs.native_targets }}', job)
            self.assertIn('artifact: ${{ steps.publish.outputs.artifact-id }}', job)
            self.assertIn('name: ' + artifact + '-${{ github.run_attempt }}', job)
            self.assertIn('if-no-files-found: error', job)
        self.assertIn("if: ${{ needs.plan.outputs.macos_split == 'true' }}", jobs['macos_build_unit'])
        self.assertIn('build "$TARGETS" --part unit', jobs['macos_build_unit'])
        self.assertIn("PART: ${{ needs.plan.outputs.macos_split == 'true' && 'rest' || 'all' }}",
                      jobs['macos_build'])
        self.assertIn('build "$TARGETS" --part "$PART"', jobs['macos_build'])
        suites = jobs['macos_suites']
        self.assertIn('needs: [plan, macos_build, macos_build_unit]', suites)
        self.assertIn('max-parallel: 3', suites)
        self.assertIn('ARTIFACT_ID: ${{ needs.macos_build.outputs.artifact }}', suites)
        self.assertIn('UNIT_ARTIFACT_ID: ${{ needs.macos_build_unit.outputs.artifact }}', suites)
        restore = 'run: python3 -B tests/ci/build_artifact.py restore "$TARGETS" --artifact-id "$ARTIFACT_ID" --artifact-id "$UNIT_ARTIFACT_ID"'
        for name in ('linux_suites', 'macos_suites'):
            self.assertIn(restore, jobs[name])
        self.assertIn('needs: [plan, macos_build, macos_build_unit, macos_suites]', jobs['macos'])
        self.assertIn('UNIT_RESULT: ${{ needs.macos_build_unit.result }}', jobs['macos'])
        self.assertIn('SPLIT: ${{ needs.plan.outputs.macos_split }}', jobs['macos'])
        # Admission cannot outrun the native unit producer.
        for name in ('admission',):
            self.assertRegex(jobs[name], r'needs: \[[^\n]*\bmacos\b')

    def test_macos_suites_and_aggregate_require_the_expected_unit_result(self):
        workflow = Path('.github/workflows/check.yml').read_text()
        suites = re.search(r'(?ms)^  macos_suites:\n(.*?)(?=^  [a-z_]+:|\Z)', workflow)[1]
        gate = re.search(r'(?ms)^  macos:\n(.*?)(?=^  [a-z_]+:|\Z)', workflow)[1]
        expression = re.search(r'if: \$\{\{ (.*?) \}\}', suites)[1]
        # cancelled() overrides Actions' implicit success(), including skipped needs.
        self.assertIn('!cancelled()', expression)
        expression = re.sub(r'!(?!=)', 'not ', expression.replace('&&', 'and').replace('||', 'or'))
        self.assertIn('always()', gate)
        script = dedent(gate.split('run: |\n', 1)[1].split('\n      - ', 1)[0])
        for split in ('true', 'false'):
            for unit in ('success', 'skipped', 'failure', 'cancelled'):
                for build, native in (('success', 'success'), ('failure', 'skipped'),
                                      ('cancelled', 'skipped'), ('skipped', 'skipped'),
                                      ('success', 'failure'), ('success', 'cancelled'),
                                      ('success', 'skipped')):
                    with self.subTest(split=split, unit=unit, build=build, native=native):
                        expected_unit = unit == ('success' if split == 'true' else 'skipped')
                        needs = SimpleNamespace(
                            plan=SimpleNamespace(outputs=SimpleNamespace(native='true', macos_split=split)),
                            macos_build=SimpleNamespace(result=build),
                            macos_build_unit=SimpleNamespace(result=unit))
                        admitted = eval(expression, {'__builtins__': {}, 'cancelled': lambda: False,
                                                     'needs': needs})
                        self.assertEqual(admitted, build == 'success' and expected_unit)
                        result = subprocess.run(['bash', '-e', '-c', script], capture_output=True,
                                                env=dict(os.environ, PLAN_RESULT='success', BUILD_RESULT=build,
                                                         NATIVE_RESULT=native, SPLIT=split, UNIT_RESULT=unit))
                        self.assertEqual(result.returncode == 0,
                                         build == native == 'success' and expected_unit)
        needs.plan.outputs.native = 'false'
        self.assertFalse(eval(expression, {'__builtins__': {}, 'cancelled': lambda: False, 'needs': needs}))
        needs.plan.outputs.native = 'true'
        self.assertFalse(eval(expression, {'__builtins__': {}, 'cancelled': lambda: True, 'needs': needs}))
        for plan in ('failure', 'cancelled', 'skipped'):
            result = subprocess.run(['bash', '-e', '-c', script], capture_output=True,
                                    env=dict(os.environ, PLAN_RESULT=plan, BUILD_RESULT='success',
                                             NATIVE_RESULT='success', SPLIT='true', UNIT_RESULT='success'))
            self.assertNotEqual(result.returncode, 0)

    def test_codegen_is_required_but_not_a_dependency_of_suite_startup(self):
        text = Path('.github/workflows/check.yml').read_text()
        codegen = re.search(r'(?ms)^  linux_codegen:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
        suites = re.search(r'(?ms)^  linux_suites:\n(.*?)(?=^  [a-z_]+:|\Z)', text)[1]
        self.assertIn('needs: plan', codegen)
        self.assertIn('zig build stack-frames -Dcpu=baseline --summary all', codegen)
        self.assertNotIn('-Dpr-ci', codegen)
        self.assertNotIn('linux_codegen', suites)

    def test_shared_state_and_unknown_code_fail_closed(self):
        for path in ("src/future_owner.zig", "tests/integration/future_case.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["check"])
            self.assertTrue(result["native_required"])

    def test_store_sql_keeps_native_owner_without_unrelated_mac_suite(self):
        # Both systems also run the bounded Debug failure-provenance subset;
        # neither composed gate executes the Debug artifact through it.
        result = select(["src/store.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"dispatch-debug-integration", "dispatch-integration", "test"} <= set(result[family]))
            self.assertNotIn("check", result[family])
            self.assertNotIn("human-cli-integration", result[family])
        self.assertTrue(result["native_required"])
        full = select(["src/store.zig", "build.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertIn("dispatch-debug-integration", full[family])

    def test_bash_keeps_real_custody_and_recovery_checks(self):
        result = select(["src/bash_platform.c"], "review", AVAILABLE)
        self.assertIn("bash-lifecycle-integration", result["targets"])
        self.assertIn("bash-recovery-integration", result["targets"])
        self.assertTrue(result["native_required"])

    def test_bash_lifecycle_values_keep_portable_and_native_owner_checks(self):
        for path in ("src/BashLifecycle.zig", "src/deadline.zig"):
            result = select([path], "review", AVAILABLE)
            native = sorted(["bash-integration", "bash-lifecycle-integration", "bash-owner-integration",
                             "bash-recovery-integration", "test" if path == "src/deadline.zig" else "test-native", "test-logic"])
            self.assertEqual(result["native_targets"], native, path)
            self.assertEqual(result["targets"], sorted(native + ["stack-frames"]), path)

    def test_codex_credential_values_keep_portable_and_native_owner_checks(self):
        for path in ("src/codex_credential_policy.zig", "src/codex_token_wire.zig"):
            result = select([path], "review", AVAILABLE)
            native = ["codex-credential-integration", "codex-h2-integration", "codex-integration", "test", "test-logic"]
            self.assertEqual(result["native_targets"], native)
            self.assertEqual(result["targets"], sorted(native + ["stack-frames"]))

    def test_union_deduplicates_only_checks_owned_by_broad_gate(self):
        result = select(["tests/integration/host_process.py", "src/codex_credentials.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertIn("check", result[family])
            self.assertTrue({"codex-credential-integration", "codex-h2-integration"} <= set(result[family]))
            self.assertFalse(set(result[family]) & CHECK_COVERS)

    def test_build_changes_keep_long_and_debug_checks(self):
        result = select(["build.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration",
                             "test-full", "current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertIn("check-full", result["targets"])
        self.assertIn("check-full", result["native_targets"])
        self.assertIn("login-signal-integration", result["targets"])
        self.assertNotIn("login-signal-integration", result["native_targets"])

    def test_transport_inputs_keep_both_native_h2_owners(self):
        for path in ("src/build_transport.sh", "build.zig.zon", "src/os/socket.zig",
                     "tests/integration/h2_fixture.py", "tests/integration/codex_h2_cases.py"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn("transport-h2-integration", result[family])
                self.assertIn("codex-h2-integration", result[family])

    def test_startup_capacity_owners_keep_every_refusal_oracle(self):
        for path in ("src/descriptor_capacity.zig", "src/descriptor_limit.zig",
                     "src/server.zig", "src/server_execution.zig", "src/server_host.zig",
                     "src/platform.zig", "src/cli.zig", "src/host_launch.c",
                     "tests/integration/descriptor_capacity_integration.py",
                     "tests/integration/host_launch_integration.py"):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    checks = set(result[family])
                    self.assertIn("codex-h2-integration", checks)
                    self.assertIn("transport-h2-integration", checks)
                    if not checks & {"check", "check-full"}:
                        self.assertTrue({"test", "host-launch-integration",
                                         "descriptor-capacity-integration"} <= checks)

    def test_bootstrap_action_is_not_cheap_ci_policy(self):
        for path in (".github/actions/setup/action.yml", "install.sh", "src/fetch_dependencies.sh"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertTrue({"admission-debug-integration", "test-full",
                                 "transport-h2-integration",
                                 "codex-h2-integration"} <= set(result[family]))
            self.assertIn("check-full", result["targets"])

    def test_shared_driver_selects_one_native_inventory(self):
        for paths in (["tests/integration/check.sh"],
                      ["tests/integration/check.sh", "build.zig"],
                      ["tests/integration/check.sh", "src/server.zig"],
                      ["tests/integration/check.sh", "tests/integration/terminal_restoration_integration.py"]):
            result = select(paths, "review", AVAILABLE)
            self.assertIn("check-full", result["targets"])
            self.assertIn("check-full", result["native_targets"])
            for family in ("targets", "native_targets"):
                self.assertNotIn("check", result[family])
                self.assertNotIn("terminal-restoration-integration", result[family])

    def test_standalone_oracles_have_executable_platform_routes(self):
        for owner in ("login-signal", "current-facts", "server-delivery"):
            path = f"tests/integration/{owner.replace('-', '_')}_integration.py"
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], [f"{owner}-integration"])
            self.assertEqual(result["native_targets"],
                             [] if owner == "login-signal" else [f"{owner}-integration"])
            combined = select([path, "build.zig"], "review", AVAILABLE)
            self.assertIn(f"{owner}-integration", combined["targets"])

    def test_standalone_imported_helpers_keep_their_real_oracles(self):
        result = select(["tests/integration/model_fixture.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertEqual(execution_batches(["current-facts-integration", "server-delivery-integration"]),
                         [["current-facts-integration"], ["server-delivery-integration"]])

    def test_a_helper_reached_through_another_library_keeps_its_consumer(self):
        # codex_h2_integration calls h2_fixture.closed_host_request, which calls
        # control_fixture.read_http_response (Codex P2 on #1102). The fixtures
        # those helpers came from no longer reach codex-h2.
        for path in ("tests/integration/control_fixture.py", "tests/integration/h2_fixture.py"):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("codex-h2-integration", result[family])
        for path in ("tests/integration/control_integration.py", "tests/integration/transport_h2_integration.py"):
            with self.subTest(path=path):
                self.assertNotIn("codex-h2-integration", select([path], "review", AVAILABLE)["targets"])
        scenarios = select(["tests/integration/dispatch_integration.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"dispatch-debug-integration", "dispatch-integration"} <= set(scenarios[family]))

    def test_helper_modules_select_the_fixtures_that_import_them(self):
        # A helper selects every fixture that imports it, and check once it
        # reaches every case check runs; a fixture script selects only the
        # targets that run it.
        for path, owners in (("host_process.py", {"check", "launch-frame-integration", "ts-client"}),
                             ("control_fixture.py", {"control-integration", "dispatch-integration",
                                                     "transport-h2-integration"}),
                             ("canonical_fixture.py", {"human-cli-integration", "request-wait-integration"})):
            with self.subTest(path=path):
                result = select([f"tests/integration/{path}"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertTrue(owners <= set(result[family]), sorted(owners - set(result[family])))
        self.assertNotIn("check", select(["tests/integration/control_fixture.py"], "review", AVAILABLE)["targets"])
        for path, target in (("control_integration.py", "control-integration"),
                             ("dispatch_integration.py", "dispatch-integration"),
                             ("canonical_failure_integration.py", "canonical-failure-integration")):
            with self.subTest(path=path):
                result = select([f"tests/integration/{path}"], "review", AVAILABLE)
                self.assertIn(target, result["targets"])
                self.assertNotIn("human-cli-integration", result["targets"])

    def test_shared_fixture_helpers_keep_composed_and_separate_consumers(self):
        for name in ("host_process.py",):
            path = f"tests/integration/{name}"
            standalone = {"codex-h2-integration", "transport-h2-integration", "server-delivery-integration",
                          "current-facts-integration"}
            for composed, paths in (("check", [path]), ("check-full", [path, "build.zig"])):
                with self.subTest(name=name, composed=composed):
                    result = select(paths, "review", AVAILABLE)
                    for family in ("targets", "native_targets"):
                        self.assertTrue({composed, *standalone} <= set(result[family]))
                        self.assertNotIn("control-integration", result[family])

    def test_canonical_failure_is_covered_by_the_composed_human_cli_gate(self):
        path = "tests/integration/canonical_failure_cases.py"
        alone = select([path], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertIn("human-cli-integration", alone[family])
            self.assertNotIn("canonical-failure-integration", alone[family])
            self.assertNotIn("check", alone[family])
        for composed in ("tests/integration/host_process.py", "build.zig"):
            combined = select([path, composed], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertNotIn("canonical-failure-integration", combined[family])
                self.assertIn("current-facts-integration", combined[family])

    def test_policy_self_checks_run_only_when_their_inputs_change(self):
        driver, admission, publication, artifact = (unit for unit, _ in POLICY_SELF_CHECKS)
        for paths, run in (
                (["src/cli.zig", "src/store/Store.zig", "tests/integration/human_cli_integration.py",
                  "README.md", "clients/ts/src/wire.ts"], set()),
                (["tests/ci/select_tests.py"], {driver, admission, publication, artifact}),
                (["tests/ci/requirements.txt"], {driver, admission, publication, artifact}),
                (["build.zig"], {driver, admission}),
                ([".github/workflows/release.yml"], {admission}),
                (["src/wire_version.zig"], {driver}),
                (["tests/integration/check.sh"], {driver}),
                (["tests/integration/host_process.py", "src/cli.zig"], {driver})):
            for phase in ("development", "review"):
                with self.subTest(paths=paths, phase=phase):
                    skips = select(paths, phase, AVAILABLE)["policy_skips"]
                    self.assertEqual(set(skips), {driver, admission, publication, artifact} - run)

    def test_ci_policy_does_not_make_build_qualification_universal(self):
        for path in (".github/workflows/check.yml",
                     ".github/workflows/cache-maintenance.yml", ".github/scripts/prune-caches.cjs",
                     "tests/ci/select_tests.py", "tests/ci/run_selected.py",
                     "tests/integration/previous_release_upgrade.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], [])
            self.assertEqual(result["native_targets"], [])

    def test_renderer_harnesses_select_no_blocking_target(self):
        workflow = Path(".github/workflows/renderer-contracts.yml").read_text()
        filters = re.findall(r"(?m)^    paths:\n((?:      - '[^']+'\n)+)", workflow)
        self.assertEqual(len(filters), 1)
        for block in filters:
            harnesses = {p for p in re.findall(r"'([^']+)'", block) if p.startswith("tests/integration/")}
            # The restoration fixture is also a blocking gate, so it keeps its own selection.
            self.assertEqual(harnesses - {"tests/integration/terminal_restoration_*"},
                             set(RENDERER_HARNESSES))
        for path in ("tests/integration/input_equivalence.py", "tests/integration/session_sequence_model.py",
                     "tests/integration/session_sequence_model_test.py"):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                self.assertEqual(result["targets"] + result["native_targets"], [])

    def test_missing_required_target_is_an_error_not_a_skip(self):
        with self.assertRaisesRegex(ValueError, "absent"):
            select(["src/bash.zig"], "review", AVAILABLE - {"bash-recovery-integration"})

    def test_new_session_policy_paths_keep_portable_and_original_native_gates(self):
        # Select each path alone: a simultaneous CLI or logic-root edit must not
        # mask missing coverage when a later change touches only the new owner.
        cases = {
            "src/new_session_selection.zig": {"admission-debug-integration", "human-cli-integration", "test-logic"},
            "src/preference_values.zig": {"admission-debug-integration", "admission-integration", "test-logic"},
            "src/provider_selection.zig": {"admission-debug-integration", "test-logic"},
            "src/model_capability.zig": {"dispatch-integration", "test", "test-logic", "transport-h2-integration"},
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                self.assertTrue(expected <= set(result["native_targets"]), sorted(expected - set(result["native_targets"])))
                self.assertNotIn("check", result["targets"])
                combined = select([path, "tests/integration/host_process.py"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("test-logic", combined[family])
                    self.assertIn("check", combined[family])

    def test_preference_owner_and_fixture_use_canonical_membership(self):
        result = select(["src/preferences.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration", "preference-policy-integration"} <= set(result[family]))
        for path in ("tests/integration/preference_policy_integration.py",
                     "tests/integration/preference_policy.zig"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["preference-policy-integration"])
            self.assertEqual(result["native_targets"], ["preference-policy-integration"])
            combined = select([path, "tests/integration/host_process.py"], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn("check", combined[family])
                self.assertNotIn("preference-policy-integration", combined[family])

    def test_installer_report_runs_the_fixture_that_pins_its_json_reader(self):
        result = select(["release/publish.sh"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["host-status-integration", "installer-integration", "upgrade-integration"])
        self.assertEqual(result["native_targets"], ["host-status-integration", "installer-integration", "upgrade-integration"])
        self.assertTrue(result["mac_required"])

    def test_existing_fixture_target_and_new_fixture_fallback(self):
        targets = select(["tests/integration/host_stop_integration.py"], "review", AVAILABLE)["targets"]
        self.assertIn("host-stop-integration", targets)
        self.assertNotIn("check", targets)

    def test_each_fixture_script_alone_selects_its_target(self):
        for target, (scripts, executables, _) in FIXTURES.items():
            for path in (*scripts, *executables):
                with self.subTest(target=target, path=path):
                    result = select([path], "review", AVAILABLE)
                    covering = {broad for broad, cases in FIXTURE_COVERS.items() if target in cases}
                    self.assertTrue(({target} | covering | {"check", "check-full"}) & set(result["targets"]))

    def test_every_script_the_build_runs_is_a_declared_fixture(self):
        # A script outside FIXTURES would reach no target through the graph.
        declared = {script for scripts, _, _ in FIXTURES.values() for script in scripts}
        named = set(re.findall(r'"(tests/integration/[\w]+\.(?:py|sh))"', Path("build.zig").read_text()))
        runners = {"tests/integration/check.sh", "tests/integration/host_process.py"}
        undeclared = {path for path in named - declared - runners if not matches(path, RENDERER_HARNESSES)}
        self.assertEqual(undeclared, set())
        for target in FIXTURES:
            self.assertIn(target, AVAILABLE)

    def test_a_named_import_the_graph_cannot_resolve_is_refused(self):
        files = {"src/logic_tests.zig": "const cores = .{\n};\n",
                 "src/cli.zig": 'const future = @import("future_module");\n'}
        with self.assertRaisesRegex(ValueError, "future_module"):
            Graph(files, files.__getitem__)

    def test_h2_fixture_and_companion_keep_both_owning_targets(self):
        # The transport oracle test checks codex-h2's cases; the transport cases
        # and their companion test are the transport target's own.
        for path, expected in (("tests/integration/codex_h2_cases.py",
                                ["codex-h2-integration", "transport-h2-integration"]),
                               ("tests/integration/transport_h2_cases.py", ["transport-h2-integration"]),
                               ("tests/integration/transport_h2_integration_test.py", ["transport-h2-integration"])):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], expected)
            self.assertEqual(result["native_targets"], expected)

    def test_public_read_fixture_and_client_select_owner_once(self):
        for owner in ("activity",):
            for suffix in ("_integration.py", "_client.zig"):
                path = f"tests/integration/{owner}{suffix}"
                result = select([path], "review", AVAILABLE)
                self.assertEqual(result["targets"], [f"{owner}-integration"])
                self.assertEqual(result["native_targets"], [f"{owner}-integration"])
                combined = select([path, "tests/integration/host_process.py"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("check", combined[family])
                    self.assertNotIn(f"{owner}-integration", combined[family])

    def test_admission_owners_keep_complete_debug_matrix(self):
        for path in ("src/server.zig", "src/server_execution.zig", "src/server_host.zig",
                     "tests/integration/admission_integration.sh"):
            result = select([path, "src/store.zig"], "review", AVAILABLE)
            self.assertIn("admission-debug-integration", result["targets"])
            self.assertIn("admission-debug-integration", result["native_targets"])

    def test_qualification_code_is_not_treated_as_stored_evidence(self):
        for path in ("tests/qualification/linux-memory/test_run.py",
                     "tests/qualification/linux-memory/malloc_probe.c"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["test-logic"])
            self.assertTrue(result["linux_memory_checks"])
            self.assertTrue(result["manual_checks"])
        result = select(["tests/qualification/transport-topology/measure.py"], "review", AVAILABLE)
        self.assertTrue(result["manual_checks"])
        self.assertFalse(result["linux_memory_checks"])
        self.assertEqual(select(["tests/qualification/linux-memory/results.json"], "review", AVAILABLE)["targets"], [])

    def test_real_mcp_sdk_is_selected_with_transport_and_fixture(self):
        for path in ("src/mcp/Listing.zig", "src/http1/request.zig",
                     "tests/integration/mcp_sdk/server.mjs",
                     "tests/integration/mcp_sdk/package-lock.json"):
            targets = set(select([path], "review", AVAILABLE)["targets"])
            self.assertTrue(covered("launch-frame-integration", targets), (path, targets))
        for target in ("launch-frame-integration", "check", "check-full"):
            self.assertTrue(setup_requirements([target])["node"], target)

    def test_setup_installs_fixture_packages_for_any_target(self):
        self.assertEqual(setup_requirements([]), {"go": False, "node": False, "python": False, "screen": False, "tmux": False})
        self.assertEqual(setup_requirements(["test-logic"]), {"go": False, "node": False, "python": True, "screen": False, "tmux": False})
        self.assertEqual(setup_requirements(["measurement-check"]), {"go": True, "node": False, "python": True, "screen": False, "tmux": False})
        self.assertEqual(setup_requirements(["ts-client"]), {"go": False, "node": True, "python": True, "screen": False, "tmux": False})
        imported = set()
        for fixture in (Path(__file__).parents[1] / "integration").glob("*.py"):
            imported |= set(re.findall(r"(?m)^\s*(?:import|from) (h2)\b", fixture.read_text()))
        pinned = {line.split("==")[0] for line in (Path(__file__).parents[1] / "integration/requirements.txt").read_text().split()}
        self.assertLessEqual(imported, pinned)

    def test_screen_package_is_fetched_only_for_steps_that_run_the_observer(self):
        # installer-integration runs install.sh, which must never fetch ghostty.
        for targets in ([], ["test-logic"], ["installer-integration"], ["ts-client"]):
            with self.subTest(targets=targets):
                self.assertFalse(setup_requirements(targets)["screen"])
        for targets in (["check"], ["check-full"], ["terminal-restoration-integration"], ["test-logic", "direct-pty"]):
            with self.subTest(targets=targets):
                self.assertTrue(setup_requirements(targets)["screen"])
        build = (Path(__file__).parents[2] / "build.zig").read_text()
        self.assertLessEqual(SCREEN_TARGETS, set(re.findall(r'b\.step\(\s*"([^"]+)"', build)))
        # Every fixture that reaches the observer runs with its library named,
        # and setup fetches the package for it.
        observing = tree_graph().targets("tests/integration/terminal_screen.py")
        self.assertLessEqual(observing, SCREEN_TARGETS)
        for target in observing:
            with self.subTest(target=target):
                fixture = FIXTURES[target][0][0]
                run = re.search(r'(\w+)\.addFileArg\(b\.path\("' + re.escape(fixture) + r'"\)\)', build)
                self.assertIsNotNone(run, fixture)
                self.assertIn(f"const {run[1]} = screenCommand(", build, fixture)
        # install.sh fetches the graph fetch_dependencies.sh walks from the root
        # manifest; ghostty's path dependencies would also make it exit 1.
        root = Path(__file__).parents[2]
        script = (root / "src/fetch_dependencies.sh").read_text()
        self.assertEqual(re.findall(r'(?m)^prepare_dependencies "(.*)"$', script), ['$repo/build.zig.zon'])
        self.assertNotIn("screen-emulator", script)
        manifest = (root / "build.zig.zon").read_text()
        for name in ("ghostty", "screen-emulator"):
            self.assertNotIn(name, manifest)

    def test_tmux_requirement_only_follows_upgrade_target(self):
        for targets in ([], ["check"], ["check-full"], ["installer-integration"], ["test-logic", "check-full"]):
            with self.subTest(targets=targets):
                self.assertFalse(setup_requirements(targets)["tmux"])
        for targets in (["upgrade-integration"], ["check", "upgrade-integration"]):
            with self.subTest(targets=targets):
                self.assertTrue(setup_requirements(targets)["tmux"])

    def test_setup_uses_actual_shard_targets_without_losing_resource_go(self):
        for platform in ("linux", "macos"):
            for row in qualification("all", platform)["include"]:
                with self.subTest(platform=platform, row=row["name"]):
                    required = setup_requirements(row["targets"])
                    if row["resource"]:
                        self.assertTrue(required["go"])
                        self.assertFalse(required["tmux"])
                    elif "measurement-check" not in row["targets"]:
                        self.assertFalse(required["go"])
        for path, jobs in ((".github/workflows/check.yml", ("linux_suites", "macos_suites")),
                           (".github/workflows/qualify-macos.yml", ("qualify",))):
            workflow = Path(path).read_text()
            for job in jobs:
                with self.subTest(path=path, job=job):
                    body = re.split(r"(?m)^  [a-z_]+:\s*$", workflow.split(f"  {job}:\n", 1)[1], 1)[0]
                    setup = body.split("- uses: ./.github/actions/setup", 1)[1].split("      - name:", 1)[0]
                    self.assertIn("targets: ${{ toJSON(matrix.targets) }}", setup)
                    self.assertIn("compiled: 'true'", setup)
        for path, jobs in ((".github/workflows/check.yml", ("linux_build", "macos_build")),
                           (".github/workflows/qualify-macos.yml", ("compile",))):
            workflow = Path(path).read_text()
            for job in jobs:
                with self.subTest(path=path, job=job):
                    body = re.split(r"(?m)^  [a-z_]+:\s*$", workflow.split(f"  {job}:\n", 1)[1], 1)[0]
                    setup = body.split("- uses: ./.github/actions/setup", 1)[1].split("      - name:", 1)[0]
                    self.assertIn("check-part: compiled", setup)
                    self.assertIn("targets: ${{ needs.plan.outputs.", setup)

    def test_tmux_setup_checks_and_installs_real_command(self):
        setup = Path(".github/actions/setup/action.yml").read_text()
        step = setup.split("    - name: Install tmux for upgrade integration\n", 1)[1].split("    - uses:", 1)[0]
        self.assertIn("steps.requirements.outputs.tmux == 'true' && inputs.check-part != 'compiled'", step)
        script = dedent(step.split("      run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            log = root / "log"
            def tool(name, body):
                path = tools / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            tool("uname", 'echo "$TEST_OS"\n')
            installer = ("""printf '%s %s\n' "${0##*/}" "$*" >> "$LOG"
if [ "$MODE" = fail ]; then exit 42; fi
if [ "$MODE" != missing ]; then
  case "$*" in *install*) printf '#!/bin/sh\nexit 0\n' > "$TOOLS/tmux"; /bin/chmod +x "$TOOLS/tmux" ;; esac
fi
""")
            tool("brew", installer)
            tool("sudo", installer)
            def run(os_name, mode="ok", present=False):
                tmux = tools / "tmux"
                tmux.unlink(missing_ok=True)
                log.unlink(missing_ok=True)
                if present:
                    tool("tmux", "exit 0\n")
                env = {"PATH": str(tools), "TEST_OS": os_name, "MODE": mode,
                       "LOG": str(log), "TOOLS": str(tools)}
                result = subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True)
                return result, log.read_text().splitlines() if log.exists() else []
            for os_name in ("Darwin", "Linux"):
                with self.subTest(os=os_name, present=True):
                    result, calls = run(os_name, present=True)
                    self.assertEqual((result.returncode, calls), (0, []))
            for os_name, expected in (("Darwin", ["brew install tmux"]),
                                      ("Linux", ["sudo apt-get update -q", "sudo apt-get install -yq tmux"])):
                with self.subTest(os=os_name):
                    result, calls = run(os_name)
                    self.assertEqual((result.returncode, calls), (0, expected))
                    self.assertTrue(result.stdout.strip().endswith("/tmux"))
            result, calls = run("FreeBSD")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])
            for os_name in ("Darwin", "Linux"):
                for mode in ("fail", "missing"):
                    with self.subTest(os=os_name, mode=mode):
                        result, calls = run(os_name, mode=mode)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertTrue(calls)

    def test_shards_keep_every_selected_target_and_both_full_parts(self):
        targets = ["check-full", "codex-credential-integration", "test-full", "measurement-check"]
        rows = shards(targets)["include"]
        self.assertEqual(len({row["name"] for row in rows}), len(rows))
        self.assertEqual([row["targets"] for row in rows],
                         [["check-full"], ["check-full"], ["codex-credential-integration"],
                          ["test-full"], ["measurement-check"]])
        self.assertEqual([batch for row in rows for batch in execution_batches(row["targets"], row["part"])],
                         [["check-full", "-Dcheck-part=execution"], ["check-full", "-Dcheck-part=callers"],
                          ["codex-credential-integration"], ["test-full"], ["measurement-check"]])
        self.assertEqual(shards([]), {"include": []})

    def test_macos_native_work_fits_three_workers_without_losing_selected_checks(self):
        rows = qualification("native", "macos")["include"]
        self.assertEqual(len(rows), 3, "avoid queuing twelve setup/build copies on three Mac workers")
        execution = next(row for row in rows if row["part"] == "execution")
        self.assertEqual(execution["targets"], ["check-full", "test-logic"])
        self.assertEqual(execution_batches(execution["targets"], execution["part"]),
                         [["check-full", "-Dcheck-part=execution"], ["test-logic"]])
        callers = next(row for row in rows if row["part"] == "callers")
        self.assertEqual(callers["targets"], ["check-full"])
        batches = [batch for row in rows for batch in execution_batches(row["targets"], row["part"])]
        selected = [target for batch in batches for target in batch if not target.startswith("-")]
        self.assertCountEqual(selected, [*NATIVE, "check-full"])
        self.assertEqual(sum("-Dcheck-part=execution" in batch for batch in batches), 1)
        self.assertEqual(sum("-Dcheck-part=callers" in batch for batch in batches), 1)

    def test_native_and_all_include_standalone_installer(self):
        for platform in ("linux", "macos"):
            for suite in ("native", "all"):
                with self.subTest(platform=platform, suite=suite):
                    rows = qualification(suite, platform)["include"]
                    self.assertEqual(sum("installer-integration" in row["targets"] for row in rows), 1)

    def test_qualification_uses_existing_platform_targets_and_isolates_resources(self):
        for platform in ("linux", "macos"):
            rows = qualification("all", platform)["include"]
            targets = {target for row in rows for target in row["targets"]}
            self.assertTrue(targets <= AVAILABLE)
            resources = set(RESOURCES) if platform == "macos" else {
                "measure-repeat-work", "measure-model-output", "measure-model-queue",
                "measure-model-control", "measure-call-classification", "measure-execution-service",
            }
            self.assertTrue(set(NATIVE) | resources <= targets)
            self.assertEqual("login-signal-integration" in targets, platform == "linux")
            self.assertEqual("stack-frames" in targets, platform == "linux")
            self.assertEqual({row["targets"][0] for row in rows if row["resource"]}, resources)
            self.assertTrue(all(len(row["targets"]) == 1 for row in rows if row["resource"] or platform == "linux"))
        self.assertEqual(qualification("footprint", "macos"), shards(["measure-repeat-work"]))
        self.assertFalse(any(row["resource"] for row in qualification("native", "linux")["include"]))

    def test_output_shards_retain_growth_spill_and_every_two_round_capacity(self):
        rows = shards(["measure-model-output"])["include"]
        self.assertEqual([row["args"] for row in rows], [
            ["--growth-only"], ["--capacity", "1"], ["--capacity", "8"],
            ["--capacity", "16"], ["--capacity", "100"],
        ])
        self.assertEqual(len({row["name"] for row in rows}), 5)
        self.assertTrue(all(row["targets"] == ["measure-model-output"] for row in rows))

    def test_requested_ref_cannot_publish_shared_caches(self):
        # The server's scoped token, not requested-ref setup code, owns access.
        for name in ('qualify-macos.yml', 'previous-release-upgrade.yml', 'release.yml'):
            with self.subTest(workflow=name):
                workflow = Path('.github/workflows', name).read_text()
                self.assertRegex(workflow, r'(?m)^cache-mode: read$')
                self.assertEqual(len(re.findall(r'(?m)^\s*cache-mode:', workflow)), 1,
                                 'a job override could restore cache-write authority')
                checkouts = re.findall(r'(?ms)^      - uses: actions/checkout@.*?(?=^      - |\Z)', workflow)
                if name == 'release.yml':
                    publisher = re.search(r'(?ms)^  publish:\n(.*?)(?=^  [\w-]+:|\Z)', workflow)[1]
                    self.assertIn("github.ref == 'refs/heads/main'", publisher)
                    self.assertIn("needs.plan.result == 'success'", publisher)
                    self.assertNotIn('uses: ./.github/actions/setup', publisher)
                    self.assertNotIn('uses: actions/cache', publisher)
                    trusted = re.search(r'(?ms)^      - uses: actions/checkout@.*?(?=^      - |\Z)', publisher)[0]
                    self.assertEqual([line.strip() for line in trusted.splitlines()[1:] if line.strip()], [
                        'with:', 'ref: ${{ github.sha }}', 'fetch-depth: 0', 'persist-credentials: true',
                    ])
                    self.assertEqual(workflow.count('persist-credentials: true'), 1)
                    checkouts.remove(trusted)
                for checkout in checkouts:
                    self.assertIn('persist-credentials: false', checkout)
                    self.assertNotIn('persist-credentials: true', checkout)
                if name == 'qualify-macos.yml':
                    self.assertIn('workflow_call:', workflow)
                # A save the token refuses only warns; restore-only setup is quiet.
                self.assertEqual(workflow.count("publish-caches: 'false'"),
                                 workflow.count('uses: ./.github/actions/setup'))
        for path in Path('.github/workflows').glob('*.yml'):
            if path.name not in ('qualify-macos.yml', 'previous-release-upgrade.yml', 'release.yml'):
                workflow = path.read_text()
                if path.name == 'check.yml':
                    # Policy only needs a compiler for the first caller-error
                    # inventory. Its conditional setup must not consume or
                    # publish native build caches; every native setup still
                    # uses the default publishing behavior below.
                    policy = re.search(r'(?ms)^  policy:\n(.*?)(?=^  [\w-]+:\n|\Z)', workflow).group(1)
                    bootstrap_steps = re.findall(
                        r'(?m)^      - uses: \./\.github/actions/setup\n(?:        .*\n)*', policy)
                    self.assertEqual(len(bootstrap_steps), 1)
                    self.assertEqual(policy.count('uses: ./.github/actions/setup'), 1)
                    bootstrap = bootstrap_steps[0]
                    self.assertEqual([line.strip() for line in bootstrap.splitlines()
                                      if line.strip() and not line.lstrip().startswith('#')], [
                        '- uses: ./.github/actions/setup',
                        "if: ${{ steps.caller-bootstrap.outputs.needed == 'true' }}",
                        'with:',
                        "targets: '[]'",
                        "compiled: 'true'",
                        "cold: 'true'",
                        "publish-caches: 'false'",
                    ])
                    self.assertIn('id: caller-bootstrap', policy)
                    self.assertIn('python3 -B tests/ci/caller_errors.py --bootstrap-needed', policy)
                    workflow = workflow.replace(bootstrap, '', 1)
                self.assertNotIn('publish-caches', workflow, f'{path.name} native checks must keep publishing')
        setup = Path('.github/actions/setup/action.yml').read_text()
        self.assertNotIn('actions/cache/save@', setup)
        steps = re.findall(r'(?m)^    - uses: actions/cache(/restore)?@.*\n((?:      .*\n)+)', setup)
        def guard(body):
            return re.search(r'(?m)^      if: \$\{\{ (.*) \}\}$', body).group(1)
        def contents(body):
            return re.sub(r'(?m)^      (?:if|id): .*\n', '', body)
        saves = [body for restore, body in steps if not restore]
        restores = [body for restore, body in steps if restore]
        self.assertEqual(len(saves), setup.count('uses: actions/cache@'))
        self.assertEqual(len(saves), len(restores))
        for save, restore in zip(saves, restores):
            self.assertRegex(guard(save), r"^inputs\.publish-caches == 'true'(?: && [^|]*)?$")
            self.assertEqual(guard(restore), guard(save).replace("publish-caches == 'true'", "publish-caches != 'true'", 1))
            self.assertEqual(contents(restore), contents(save))

    def test_ci_test_methods_cannot_silently_replace_another_check(self):
        for path in Path('tests/ci').glob('test_*.py'):
            for node in ast.walk(ast.parse(path.read_text())):
                if isinstance(node, ast.ClassDef):
                    methods = [method.name for method in node.body
                               if isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef))]
                    self.assertEqual(len(methods), len(set(methods)), (str(path), node.name))

    def test_batches_share_builds_but_isolate_timing_witnesses(self):
        targets = ["test", "dispatch-integration", "transport-h2-integration",
                   "test-full", "admission-debug-integration",
                   "host-launch-integration", "check-full"]
        self.assertEqual(execution_batches(targets), [
            ["test", "dispatch-integration"],
            ["transport-h2-integration"],
            ["test-full"], ["admission-debug-integration"],
            ["host-launch-integration"], ["check-full"],
        ])
        self.assertEqual(execution_batches([]), [])

    def test_cache_proof_tracks_cache_policy_not_every_runtime_edit(self):
        for path in ("build.zig", ".github/actions/setup/action.yml", "tests/ci/cache_execution.py",
                     ".github/workflows/cache-maintenance.yml", ".github/workflows/qualify-macos.yml",
                     ".github/scripts/prune-caches.cjs"):
            self.assertTrue(select([path], "review", AVAILABLE)["cache_execution_checks"])
        self.assertEqual([path for path in CACHE_POLICY if not Path(path).is_file()], [])
        for path in ("src/store.zig", ".github/main-ruleset.json", ".github/workflows/renderer-contracts.yml"):
            self.assertFalse(select([path], "review", AVAILABLE)["cache_execution_checks"])

    def test_cache_maintenance_preserves_unowned_and_current_caches(self):
        result = subprocess.run(["node", "--test", "tests/ci/cache_maintenance.test.cjs"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_isolated_full_check_parts_keep_other_selected_work_once(self):
        targets = ["admission-debug-integration", "check-full", "test-full"]
        self.assertEqual(execution_batches(targets, "execution"),
                         [["check-full", "-Dcheck-part=execution"],
                          ["admission-debug-integration"], ["test-full"]])
        self.assertEqual(execution_batches(targets, "callers"), [
            ["admission-debug-integration"], ["check-full", "-Dcheck-part=callers"],
            ["test-full"],
        ])
        with self.assertRaises(ValueError):
            execution_batches(["test-logic"], "execution")

    def test_a_dispatch_selects_from_its_explicit_base(self):
        # Manual diagnostic selection uses its explicit base.
        workflow = Path('.github/workflows/check.yml').read_text()
        prefix = dedent(re.search(
            r'(?s)        run: \|\n(          set -euo pipefail\n.*?)'
            r'          python3 tests/ci/select_tests.py', workflow)[1])
        candidate = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        with patch.dict(os.environ, BASE='1' * 40, EVENT_NAME='workflow_dispatch', CANDIDATE_REF=candidate):
            result = subprocess.run(['bash', '-c', prefix + 'printf "%s" "$BASE"'],
                                    capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, '1' * 40)


class FullCheckPartitionTest(unittest.TestCase):
    @staticmethod
    def wait_for_group_retirement(group, deadline):
        # A delivered signal, leader reap and pipe EOF do not retire private
        # peers with redirected captures. Zombies cannot create more files.
        def live_members():
            census = subprocess.run(["ps", "-axo", "pgid=,stat="], capture_output=True,
                                    text=True, check=True, timeout=max(0, deadline - time.monotonic()))
            return [state for pgid, state in (row.split() for row in census.stdout.splitlines())
                    if int(pgid) == group and not state.startswith("Z")]
        wait_for(live_members, f"live driver group {group} to retire", interval=.005, deadline=deadline,
                 ready=lambda live: not live)

    def run_part(self, part, fail="", overlap=False, hold="", timing=False, clock_error="",
                 timeout=60, python_delay=0, fail_at=""):
        with ExitStack() as owner:
            root = Path(tempfile.mkdtemp())
            process = None
            retired = False
            disposal_deadline = None

            def dispose_root(kind, failure, traceback):
                try:
                    if process is not None and not retired:
                        self.wait_for_group_retirement(
                            process.pid, disposal_deadline if disposal_deadline is not None
                            else time.monotonic() + 5)
                    shutil.rmtree(root)
                except BaseException as cleanup:
                    if failure is None:
                        cleanup.add_note(f"retained driver root: {root}")
                        raise
                    failure.add_note(f"driver root disposal failed: {cleanup!r}")
                    failure.add_note(f"retained driver root: {root}")

            owner.push(dispose_root)
            # Exercise the shell gate's public commands without launching product
            # fixtures. A controlled clock checks elapsed reporting, not speed.
            command = '''#!/bin/sh
if [ "$1" = - ]; then exec "$TEST_PYTHON" "$@"; fi
if [ "$(basename "${1:-}")" = host_process.py ] && [ "$2" = exec ]; then shift 2; exec "$@"; fi
fixture=$(basename "${1:-$0}")
base_fixture=$fixture
case "$fixture" in
    human_cli_integration.py|terminal_restoration_integration.py|canonical_failure_integration.py)
        test "$RUI_TEST_TERMINAL_NOTICE" = notice || exit 46 ;;
esac
if [ "$fixture" = human_cli_integration.py ]; then
    fixture="$fixture${3:+:$3}"
fi
identity="$fixture.$2"
printf "%s %s\\n" "$identity" "$$" >> "$GATE_DIR/peer-pids"
if [ "$CHECK_TIMING" = 1 ]; then
    case "$fixture" in
        human_cli_integration.py:callers|preference_policy_integration.py)
            touch "$GATE_DIR/$fixture.started"
            read -r release < "$GATE_DIR/$fixture.release"
            test "$release" = r || exit 45 ;;
    esac
fi
if [ "$CHECK_OVERLAP" = 1 ]; then
    touch "$GATE_DIR/$identity.started"
    if [ "$base_fixture" = human_cli_integration.py ]; then
        while [ ! -e "$GATE_DIR/activity_integration.py.release.started" ]; do
            sleep 0.01
        done
    fi
    case "$fixture:$2" in
        host_launch_integration.py:*|host_process_test.py:*|host_allocator_test.py:*|admission_integration.sh:debug)
            touch "$GATE_DIR/isolated.started"
            peers="human_cli_integration.py:callers.release human_cli_integration.py:renderer.release
                terminal_restoration_integration.py.release canonical_failure_integration.py.release
                preference_policy_integration.py.preferences
                session_list_integration.py.release conversation_page_integration.py.release
                activity_integration.py.release
                host_status_integration.py.release host_stop_integration.py.release"
            if [ "$TEST_PART" = parallel ]; then
                peers="$peers native. admission_integration.sh.release dispatch_integration.py.release
                    bash_owner_integration.py.release bash_integration.py.release
                    peer_integration.py.release sender_identity_integration.py.release
                    bash_lifecycle_integration.py.release bash_recovery_integration.py.release
                    codex_integration.py.release control_integration.py.release
                    descriptor_capacity_integration.py.release"
            fi
            for peer in $peers; do
                if [ ! -e "$GATE_DIR/$peer.done" ]; then exit 44; fi
            done ;;
    esac
    if [ "$fixture" = "$HOLD_FIXTURE" ] && [ "$2" != debug ]; then
        read -r release < "$GATE_DIR/release"
        test "$release" = r || exit 45
    fi
    touch "$GATE_DIR/$identity.done"
fi
printf "%s %s\\n" "$fixture" "$2" >> "$GATE_DIR/invocations"
if [ "$fixture" = "$FAIL_FIXTURE" ] || [ "$base_fixture" = "$FAIL_FIXTURE" ]; then exit 42; fi
'''
            for name in ("python3", "sh", "native"):
                (root / name).write_text(command)
                (root / name).chmod(0o755)
            invocations = root / "invocations"
            invocations.touch()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FAIL_FIXTURE=fail,
                       CHECK_OVERLAP=str(int(overlap)), GATE_DIR=str(root), TEST_PYTHON=sys.executable,
                       HOLD_FIXTURE=hold, TEST_PART=part, CHECK_TIMING=str(int(timing)))
            if python_delay:
                (root / "sitecustomize.py").write_text(
                    f"import time\ntime.sleep({python_delay!r})\n")
                env["PYTHONPATH"] = str(root)
            if clock_error:
                (root / "sitecustomize.py").write_text(
                    "import sys, time\n"
                    "def fail_clock():\n    raise OSError('injected clock failure')\n"
                    f"if (len(sys.argv) == 1) == {clock_error == 'start'!r}:\n"
                    "    time.monotonic_ns = fail_clock\n")
                env["PYTHONPATH"] = str(root)
            arguments = (["parallel", str(root / "native"), "status", "sessions", "activity", "preferences", "notice"]
                         if part == "parallel" else
                         ["status", "sessions", "activity", "preferences", part, "notice"])
            command = [
                "/bin/sh", "tests/integration/check.sh", "release", "debug", *arguments,
            ]
            releases = []
            if timing:
                clock = root / "clock"
                clock.write_text("10000000000")
                (root / "sitecustomize.py").write_text(
                    "import os, time\nfrom pathlib import Path\n"
                    "time.monotonic_ns = lambda: int(Path(os.environ['GATE_DIR'], 'clock').read_text())\n")
                env.update(PYTHONPATH=str(root), TMPDIR=str(root))
                fixtures = ("human_cli_integration.py:callers", "preference_policy_integration.py")
            # The serial driver starts 43 real interpreters, including its
            # version check. This is a functional test, not a startup benchmark.
            # One coarse deadline owns readiness, drainage and every child.
            deadline = time.monotonic() + timeout
            try:
                if timing:
                    for fixture in fixtures:
                        fifo = root / f"{fixture}.release"
                        os.mkfifo(fifo)
                        releases.append(os.open(fifo, os.O_RDWR | os.O_NONBLOCK))
                elif hold:
                    os.mkfifo(root / "release")
                    releases.append(os.open(root / "release", os.O_RDWR | os.O_NONBLOCK))
                with ExitStack() as streams:
                    process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, start_new_session=True)
                    streams.push(lambda *exc: dispose_all(process.stdout.close, process.stderr.close))
                    try:
                        try:
                            if timing:
                                def timed_started():
                                    self.assertIsNone(process.poll())
                                    return all((root / f"{fixture}.started").exists() for fixture in fixtures)
                                wait_for(timed_started, "both timed fixtures to start", interval=.005, deadline=deadline)
                                if fail_at == "timed_ready":
                                    self.fail("injected failure at timed_ready")
                                clock.with_suffix(".next").write_text("13000000000")
                                clock.with_suffix(".next").replace(clock)
                                os.write(releases[1], b"r\n")
                                # Completion timing belongs to the peer, not
                                # the later inventory-order wait for it.
                                def timing_recorded():
                                    self.assertIsNone(process.poll())
                                    return any(path.read_text().strip()
                                               for path in root.glob("rui-check.*/preference-policy.status"))
                                wait_for(timing_recorded, "the completed peer to record timing before the inventory wait",
                                         interval=.005, deadline=deadline)
                                if fail_at == "timed_recorded":
                                    self.fail("injected failure at timed_recorded")
                                clock.with_suffix(".next").write_text("30000000000")
                                clock.with_suffix(".next").replace(clock)
                            elif hold:
                                def held_started():
                                    self.assertIsNone(process.poll())
                                    return any(root.glob(f"{hold}.*.started"))
                                wait_for(held_started, f"held {hold} to start", interval=.005, deadline=deadline)
                                if fail_at == "held_ready":
                                    self.fail("injected failure at held_ready")
                                # Held authority, not scheduler speed, prevents
                                # isolated work during this observation.
                                observation_deadline = time.monotonic() + .1
                                while time.monotonic() < observation_deadline:
                                    self.assertFalse((root / "isolated.started").exists())
                                    time.sleep(.005)
                        finally:
                            # Successful observation releases the test gates.
                            # A failed observation retires the owned group below.
                            if sys.exception() is None:
                                for release in releases:
                                    os.write(release, b"r\n")
                        stdout, stderr = process.communicate(timeout=max(0, deadline - time.monotonic()))
                    except BaseException as failure:
                        failure.add_note(f"driver_pid={process.pid}")
                        # A timed-out shell may still own clock or mock peers
                        # holding our pipes. Retire the entire private group,
                        # then drain and reap before the fixture root disappears.
                        disposal_deadline = time.monotonic() + 5
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        except BaseException as cleanup:
                            failure.add_note(f"driver group retirement unconfirmed: {cleanup!r}")
                            try:
                                process.kill()
                            except BaseException as cleanup:
                                failure.add_note(f"driver kill failed: {cleanup!r}")
                        try:
                            process.wait(timeout=max(0, disposal_deadline - time.monotonic()))
                            failure.add_note(f"driver_pid={process.pid}, returncode={process.returncode}")
                        except BaseException as cleanup:
                            failure.add_note(f"driver reap failed: {cleanup!r}")
                        try:
                            stdout, stderr = process.communicate(timeout=max(0, disposal_deadline - time.monotonic()))
                            failure.add_note(f"stdout: {stdout!r}\nstderr: {stderr!r}")
                        except BaseException as cleanup:
                            failure.add_note(f"driver disposal failed: {cleanup!r}")
                        try:
                            self.wait_for_group_retirement(process.pid, disposal_deadline)
                            retired = True
                        except BaseException as cleanup:
                            failure.add_note(f"driver group retirement unconfirmed: {cleanup!r}")
                        failure.add_note(f"part={part!r}, failing fixture={fail!r}, overlap={overlap!r}")
                        try:
                            peers = root / "peer-pids"
                            failure.add_note("peer_pids=" + json.dumps(peers.read_text() if peers.exists() else ""))
                            failure.add_note(f"completed invocations: {invocations.read_text()!r}")
                        except BaseException as diagnostic:
                            failure.add_note(f"driver diagnostics unavailable: {diagnostic!r}")
                        raise
                    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            finally:
                dispose_all(*(lambda fd=fd: os.close(fd) for fd in releases))
            return result, invocations.read_text().splitlines()

    def records(self, result):
        return re.findall(r"^([a-z-]+) (?:passed|failed): exit=(\d+) elapsed=(\d+\.\d{3})s$",
                          result.stdout + result.stderr, re.MULTILINE)

    def test_slow_interpreter_startup_is_not_a_driver_failure(self):
        # At least 43 * .25 seconds of startup in this serial inventory exceeds
        # the old ten-second limit without any blocked or incorrect fixture.
        result, lines = self.run_part("all", "host_allocator_test.py", python_delay=.25)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual(lines[-1], "host_allocator_test.py release")
        self.assertEqual(self.records(result)[-1][:2], ("host-allocator", "42"))

    def test_driver_deadline_reaps_and_preserves_the_original_failure(self):
        for part, options, error, message, held in (
            ("all", {"python_delay": 2, "timeout": .001}, subprocess.TimeoutExpired, "", ()),
            ("parallel", {"hold": "dispatch_integration.py", "overlap": True,
                          "fail_at": "held_ready"}, AssertionError, "held_ready",
             ("dispatch_integration.py.release",)),
            ("callers", {"timing": True, "fail_at": "timed_ready"}, AssertionError, "timed_ready",
             ("human_cli_integration.py:callers.release", "preference_policy_integration.py.preferences")),
            ("callers", {"timing": True, "fail_at": "timed_recorded"}, AssertionError, "timed_recorded",
             ("human_cli_integration.py:callers.release",)),
        ):
            with self.subTest(part=part, message=message):
                with self.assertRaises(error) as rejected:
                    self.run_part(part, **options)
                if message:
                    self.assertEqual(str(rejected.exception), f"injected failure at {message}")
                notes = "\n".join(rejected.exception.__notes__)
                self.assertNotIn("driver disposal failed", notes)
                self.assertIn("completed invocations:", notes)
                self.assertIn("stdout:", notes)
                driver = re.search(r"driver_pid=(\d+), returncode=(-?\d+)", notes)
                self.assertIsNotNone(driver, notes)
                with self.assertRaises(ChildProcessError):
                    os.waitpid(int(driver[1]), os.WNOHANG)
                peers = dict(line.split() for line in json.loads(next(
                    note.removeprefix("peer_pids=") for note in rejected.exception.__notes__
                    if note.startswith("peer_pids=")
                )).splitlines())
                for identity in held:
                    self.assertIn(identity, peers)
                    # Grandchildren may briefly be zombies awaiting their OS
                    # reaper, but cannot remain live or hold the capture pipes.
                    def peer_state(identity=identity):
                        observed = subprocess.run(["ps", "-o", "stat=", "-p", peers[identity]],
                                                  capture_output=True, text=True)
                        self.assertIn(observed.returncode, (0, 1), observed.stderr)
                        self.assertFalse(observed.stderr)
                        return observed.stdout.strip()
                    wait_for(peer_state, f"held peer {identity} to retire", timeout=5, interval=.005,
                             ready=lambda state: not state or state.startswith("Z"))

    def test_disposal_and_diagnostic_faults_preserve_the_primary_failure(self):
        read_text = Path.read_text

        def diagnostic_failure(path, *args, **kwargs):
            if path.name == "peer-pids":
                raise OSError("injected diagnostic read failure")
            return read_text(path, *args, **kwargs)

        for fault in ("diagnostic", "retirement"):
            with self.subTest(fault=fault):
                try:
                    with patch.object(Path, "read_text", diagnostic_failure) if fault == "diagnostic" else patch(
                            "os.killpg", side_effect=PermissionError("injected group retirement failure")):
                        with self.assertRaisesRegex(AssertionError, "injected failure at held_ready") as rejected:
                            self.run_part("parallel", overlap=True, hold="dispatch_integration.py",
                                          fail_at="held_ready")
                    notes = "\n".join(rejected.exception.__notes__)
                    driver = re.search(r"driver_pid=(\d+), returncode=(-?\d+)", notes)
                    self.assertIsNotNone(driver, notes)
                    with self.assertRaises(ChildProcessError):
                        os.waitpid(int(driver[1]), os.WNOHANG)
                    self.assertIn("injected diagnostic read failure" if fault == "diagnostic"
                                  else "driver group retirement unconfirmed", notes)
                finally:
                    # Injected group failure leaves the held descendant until
                    # run_part closes its release FIFO; retirement is observed,
                    # never signaled, before the retained root is removed.
                    if fault == "retirement" and rejected.exception.__notes__:
                        pid = int(rejected.exception.__notes__[0].split("=")[1])
                        self.wait_for_group_retirement(pid, time.monotonic() + 5)
                        for note in rejected.exception.__notes__:
                            if note.startswith("retained driver root: "):
                                shutil.rmtree(note.removeprefix("retained driver root: "))

    def test_root_disposal_requires_the_whole_group_to_retire(self):
        run, killpg, rmtree = subprocess.run, os.killpg, shutil.rmtree
        mkdtemp = tempfile.mkdtemp
        for delivery in ("delayed", "lost"):
            with self.subTest(delivery=delivery):
                group = None
                root = None
                observed_live = False

                def make_root(*args, **kwargs):
                    nonlocal root
                    directory = mkdtemp(*args, **kwargs)
                    root = Path(directory)
                    return directory

                def live_members():
                    census = run(["ps", "-axo", "pgid=,stat="], capture_output=True,
                                 text=True, check=True, timeout=5)
                    return [row for row in census.stdout.splitlines()
                            if int(row.split()[0]) == group and not row.split()[1].startswith("Z")]

                def leader_only(pgid, sig):
                    nonlocal group
                    group = pgid
                    # The held descendant has private log captures. Leader
                    # reap and caller pipe EOF must not authorize root deletion.
                    peers = dict(line.split() for line in (root / "peer-pids").read_text().splitlines())
                    held = int(peers["dispatch_integration.py.release"])

                    # A census misses members forked while it ran, such as a
                    # peer that waits forever for a start the killed driver
                    # never makes (#638). Signal each census until the held
                    # descendant is the only live member; killed members
                    # fork no more.
                    def signal_others():
                        census = run(["ps", "-axo", "pid=,pgid=,stat="], capture_output=True,
                                     text=True, check=True, timeout=5)
                        others = [int(pid) for pid, member_group, state in
                                  (row.split() for row in census.stdout.splitlines())
                                  if int(member_group) == group and int(pid) != held
                                  and not state.startswith("Z")]
                        for pid in others:
                            try:
                                os.kill(pid, sig)
                            except ProcessLookupError:
                                pass
                        return others
                    wait_for(signal_others, f"driver group {group} to keep only its held descendant",
                             interval=.005, timeout=5, ready=lambda others: not others)

                def census_then_deliver(*args, **kwargs):
                    nonlocal observed_live
                    result = run(*args, **kwargs)
                    if group is not None and live_members():
                        observed_live = True
                        if delivery == "delayed":
                            killpg(group, signal.SIGKILL)
                    return result

                def delete_after_retirement(path, *args, **kwargs):
                    nonlocal root
                    root = Path(path)
                    self.assertFalse(live_members(), "root deleted while a descendant can still write")
                    return rmtree(path, *args, **kwargs)

                try:
                    with patch("tempfile.mkdtemp", side_effect=make_root), patch(
                            "os.killpg", side_effect=leader_only), patch(
                            "subprocess.run", side_effect=census_then_deliver), patch(
                            "shutil.rmtree", side_effect=delete_after_retirement):
                        with self.assertRaisesRegex(AssertionError, "^injected failure at held_ready$") as rejected:
                            self.run_part("parallel", overlap=True, hold="dispatch_integration.py",
                                          fail_at="held_ready")
                    self.assertTrue(observed_live, "the counterexample must contain a live descendant")
                    notes = rejected.exception.__notes__
                    self.assertTrue(any(note.startswith("stdout:") for note in notes), notes)
                    retained = [note.removeprefix("retained driver root: ") for note in notes
                                if note.startswith("retained driver root: ")]
                    if delivery == "lost":
                        self.assertEqual(len(retained), 1, notes)
                        root = Path(retained[0])
                        self.assertTrue(root.is_dir())
                        self.assertTrue(any("driver group retirement unconfirmed" in note for note in notes), notes)
                    else:
                        self.assertFalse(retained, notes)
                        self.assertIsNotNone(root)
                        self.assertFalse(root.exists())
                finally:
                    if group is not None:
                        # Deliver the lost signal now that nothing needs the
                        # held descendant. Closing its release FIFO is not
                        # enough: one that opens the FIFO after the last
                        # writer closed waits for a writer forever (#662).
                        try:
                            killpg(group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        self.wait_for_group_retirement(group, time.monotonic() + 5)
                    if root is not None and root.exists():
                        rmtree(root)

    def test_root_cleanup_failure_is_secondary_only_when_the_body_failed(self):
        rmtree = shutil.rmtree
        for failed in (False, True):
            with self.subTest(failed=failed):
                root = None

                def refuse_cleanup(path):
                    nonlocal root
                    root = Path(path)
                    raise OSError("injected root cleanup failure")

                try:
                    with patch("shutil.rmtree", side_effect=refuse_cleanup):
                        with self.assertRaisesRegex(
                                AssertionError if failed else OSError,
                                "injected failure at held_ready" if failed else "injected root cleanup failure") as rejected:
                            self.run_part("parallel", overlap=True, hold="dispatch_integration.py",
                                          fail_at="held_ready" if failed else "")
                    self.assertTrue(root.is_dir())
                    self.assertIn(f"retained driver root: {root}", rejected.exception.__notes__)
                finally:
                    if root is not None:
                        rmtree(root)

    def test_elapsed_belongs_to_invocation_not_inventory_wait(self):
        for part in ("callers", "parallel"):
            for fail in ("", "preference_policy_integration.py"):
                with self.subTest(part=part, fail=fail):
                    result, _ = self.run_part(part, fail=fail, timing=True)
                    self.assertEqual(result.returncode, int(bool(fail)), result.stdout + result.stderr)
                    records = {name: (status, elapsed) for name, status, elapsed in self.records(result)}
                    self.assertEqual(records["preference-policy"], ("42" if fail else "0", "3.000"))
                    self.assertEqual(records["human-cli"], ("0", "20.000"))

    def test_parts_are_disjoint_and_cover_the_unchanged_full_gate(self):
        expected = {
            "admission_integration.sh release", "dispatch_integration.py release",
            "bash_owner_integration.py release", "bash_integration.py release",
            "peer_integration.py release", "bash_environment_integration.py release",
            "sender_identity_integration.py release",
            "human_cli_integration.py release", "preference_policy_integration.py preferences",
            "request_wait_integration.py release",
            "bash_lifecycle_integration.py release", "bash_recovery_integration.py release",
            "codex_integration.py release", "control_integration.py release",
            "session_list_integration.py release", "conversation_page_integration.py release",
            "activity_integration.py release",
            "descriptor_capacity_integration.py release", "host_status_integration.py release",
            "host_launch_integration.py release", "host_stop_integration.py release",
            "admission_integration.sh debug", "host_process_test.py ",
            "host_allocator_test.py release", "launch_frame_integration.py release",
        }
        outputs = {}
        for part in ("all", "execution", "callers", "parallel"):
            result, lines = self.run_part(part)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(lines), len(set(lines)), lines)
            records = self.records(result)
            self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
            self.assertEqual(len({name for name, _, _ in records}), len(lines))
            self.assertTrue(all(status == "0" for _, status, _ in records))
            outputs[part] = set(lines)
        self.assertEqual(outputs["all"], expected)
        # The ordinary driver also owns the native binary; the full gate runs
        # that binary in the build graph instead. Independent human CLI groups
        # split; the unsplit serial invocation retains its original order.
        parallel_expected = expected - {"human_cli_integration.py release"} | {
            "human_cli_integration.py:callers release", "human_cli_integration.py:renderer release",
            "terminal_restoration_integration.py release", "canonical_failure_integration.py release",
        }
        self.assertEqual(outputs["parallel"], parallel_expected | {"native "})
        self.assertEqual(outputs["execution"] & outputs["callers"], set())
        self.assertEqual(outputs["execution"] | outputs["callers"], parallel_expected)
        self.assertIn("dispatch_integration.py release", outputs["execution"])
        self.assertIn("human_cli_integration.py:callers release", outputs["callers"])
        self.assertIn("human_cli_integration.py:renderer release", outputs["callers"])

    def test_callers_overlap_private_fixtures_then_drain_before_deadline_cases(self):
        for part in ("callers", "parallel"):
            result, _ = self.run_part(part, overlap=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_parallel_gate_drains_native_and_execution_peers(self):
        for peer in ("native", "admission_integration.sh", "dispatch_integration.py",
                     "bash_owner_integration.py", "bash_integration.py", "peer_integration.py",
                     "sender_identity_integration.py",
                     "bash_lifecycle_integration.py", "bash_recovery_integration.py",
                     "codex_integration.py", "control_integration.py", "descriptor_capacity_integration.py"):
            with self.subTest(peer=peer):
                result, _ = self.run_part("parallel", overlap=True, hold=peer)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failure_or_invalid_part_cannot_report_success(self):
        complete = {}
        for part in ("callers", "parallel"):
            result, lines = self.run_part(part)
            self.assertEqual(result.returncode, 0)
            complete[part] = set(lines)
        for fixture in ("human_cli_integration.py", "preference_policy_integration.py",
                        "session_list_integration.py", "conversation_page_integration.py",
                        "activity_integration.py",
                        "host_status_integration.py", "host_stop_integration.py",
                        "host_launch_integration.py", "host_process_test.py",
                        "host_allocator_test.py", "admission_integration.sh"):
            for part in ("callers", "parallel", "all"):
                result, lines = self.run_part(part, fixture)
                self.assertEqual(result.returncode, 42 if part == "all" else 1, (part, fixture))
                records = self.records(result)
                self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
                self.assertIn("42", [status for _, status, _ in records])
                if part == "all":
                    self.assertEqual(lines[-1].split()[0], fixture)
                else:
                    self.assertEqual(set(lines), complete[part])
        for part in ("callers", "parallel"):
            for fixture, record in (("human_cli_integration.py:renderer", "human-cli-renderer"),
                                    ("terminal_restoration_integration.py", "terminal-restoration"),
                                    ("canonical_failure_integration.py", "canonical-failure")):
                result, lines = self.run_part(part, fixture)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(set(lines), complete[part])
                self.assertIn((record, "42"), [(name, status) for name, status, _ in self.records(result)])
        for part in ("execution", "parallel", "all"):
            result, _ = self.run_part(part, "dispatch_integration.py")
            self.assertNotEqual(result.returncode, 0, part)
        result, _ = self.run_part("parallel", "native")
        self.assertNotEqual(result.returncode, 0)
        result, lines = self.run_part("not-a-part")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(lines, [])
        self.assertEqual(self.records(result), [])

    def test_failure_still_drains_a_held_peer_before_isolated_cases(self):
        for part in ("callers", "parallel"):
            for held in ("host_stop_integration.py", "human_cli_integration.py:renderer"):
                result, _ = self.run_part(part, fail="preference_policy_integration.py",
                                          overlap=True, hold=held)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                records = {name: status for name, status, _ in self.records(result)}
                self.assertEqual(records["preference-policy"], "42")
                self.assertEqual(records["host-stop"], "0")
                self.assertEqual(records["human-cli-renderer"], "0")
                self.assertEqual(records["host-launch"], "0")

    def test_clock_failure_preserves_fixture_results(self):
        for clock_error in ("start", "finish"):
            for part in ("all", "execution", "callers", "parallel"):
                fixture = "dispatch_integration.py" if part == "execution" else "preference_policy_integration.py"
                failures = ("", fixture, "host_launch_integration.py") if part in ("callers", "parallel") else ("", fixture)
                for fail in failures:
                    with self.subTest(clock_error=clock_error, part=part, fail=fail):
                        result, lines = self.run_part(part, fail=fail, clock_error=clock_error)
                        expected = (42 if part in ("all", "execution") else 1) if fail else 0
                        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                        records = re.findall(r"^([a-z-]+) (?:passed|failed): exit=(\d+) elapsed=unavailable$",
                                             result.stdout + result.stderr, re.MULTILINE)
                        self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
                        self.assertEqual({status for _, status in records}, {"0", "42"} if fail else {"0"})


if __name__ == "__main__":
    unittest.main()
