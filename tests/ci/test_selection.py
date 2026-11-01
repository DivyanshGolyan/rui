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

from select_tests import CACHE_POLICY, RENDERER_HARNESSES, execution_batches, select, setup_requirements
from qualification import NATIVE, RESOURCES, qualification, shards

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
from host_process import dispose_all, wait_for


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))


class SelectionTest(unittest.TestCase):
    def test_development_does_not_claim_native_acceptance(self):
        result = select(["src/bash_platform.c", "src/store.zig"], "development", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])
        self.assertFalse(result["native_required"])

    def test_portable_owner_does_not_require_full_suite(self):
        result = select(["src/request_encoding.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["stack-frames", "test-logic"])
        self.assertFalse(result["native_required"])

    def test_host_frame_inputs_select_the_linux_frame_gate(self):
        for path in ("src/request_encoding.zig", "src/h2/Engine.zig", "src/bash_platform.c", "build.zig",
                     "tests/ci/stack_frames.json", "tests/ci/stack_frames.py"):
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                self.assertIn("stack-frames", result["targets"])
                self.assertNotIn("stack-frames", result["native_targets"])
        # check runs the gate itself; renderer owners never reach a Host stack.
        store = select(["src/store.zig"], "review", AVAILABLE)["targets"]
        self.assertIn("check", store)
        self.assertNotIn("stack-frames", store)
        self.assertNotIn("stack-frames", select(["src/SessionFrontend.zig"], "review", AVAILABLE)["targets"])

    def test_logic_root_selects_its_executable_root(self):
        for path in ("src/logic_tests.zig", "src/core_boundary.zig"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["stack-frames", "test-logic"])

    def test_shared_context_text_keeps_all_request_oracle_consumers(self):
        consumers = {
            "src/model_instructions.txt": ["src/model_adapter.zig", "tests/integration/model_fixture.py",
                                           "tests/qualification/measurement/client.go"],
            "src/peer_message.txt": ["src/model_adapter.zig", "tests/integration/peer_integration.py"],
        }
        for path, sources in consumers.items():
            owners = select(sources, "review", AVAILABLE)
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertEqual(result[family], owners[family], path)

    def test_every_functional_core_selects_the_boundary_check(self):
        source = (Path(__file__).resolve().parents[2] / "src" / "logic_tests.zig").read_text()
        listed = source.split("const cores = .{", 1)[1].split("\n};", 1)[0]
        cores = re.findall(r'\.\{ "([^"]+\.zig)", @import', listed)
        self.assertIn("BashLifecycle.zig", cores)
        for core in cores:
            with self.subTest(core=core):
                self.assertIn("test-logic", select([f"src/{core}"], "review", AVAILABLE)["targets"])

    def test_http2_client_selects_its_own_tests(self):
        result = select(["src/h2/Engine.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["stack-frames", "test-h2"])
        result = select(["src/h2/policy.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["stack-frames", "test-h2", "test-logic"])

    def test_portable_roots_keep_their_native_owner_checks(self):
        for path in ("src/SessionInput.zig", "src/tools.zig"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertEqual(result[family], ["check", "test-logic"])

    def test_response_timing_keeps_native_timeout_consumers(self):
        result = select(["src/ResponseTiming.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertEqual(result[family], ["admission-debug-integration", "check", "test-full", "test-logic"])
        self.assertTrue(result["native_required"])

    def test_test_full_runs_beside_a_full_native_suite(self):
        # test-full holds only the real-time witness; check or check-full runs the rest.
        for path in ("src/client.zig", "src/ResponseTiming.zig", "build.zig", "build.zig.zon",
                     "install.sh", ".github/actions/setup/action.yml"):
            with self.subTest(path=path):
                targets = set(select([path], "review", AVAILABLE)["targets"])
                self.assertIn("test-full", targets)
                self.assertTrue(targets & {"check", "check-full"})
        self.assertIn("check-full", NATIVE)

    def test_frontend_alone_selects_logic_and_pty_callers_not_check(self):
        pty = ["canonical-failure-integration", "terminal-restoration-integration"]
        for path, expected in (
                # src/tests.zig, not the logic root, runs these owners' unit tests.
                ("src/SessionFrontend.zig", ["admission-debug-integration", *pty, "test", "test-logic"]),
                ("src/SessionTerminal.zig", ["admission-debug-integration", *pty, "test", "test-logic"]),
                ("src/ClientTask.zig", ["admission-debug-integration", *pty, "test", "test-logic"]),
                ("src/ConversationViewport.zig", [*pty, "test-logic"]),
                ("src/TerminalEditor.zig", ["admission-debug-integration", *pty, "test-logic"]),
                ("src/TerminalText.zig", ["admission-debug-integration", *pty, "test-logic"]),
                ("src/session_sequence_model_test.zig", ["test-logic"])):
            with self.subTest(path=path):
                result = select([path, "README.md"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertEqual(result[family], expected)
        result = select(["src/SessionScreen.zig", "src/TerminalFrame.zig", "src/AnswerRenderer.zig"],
                        "review", AVAILABLE)
        self.assertNotIn("check", result["targets"] + result["native_targets"])

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

    def test_strict_path_beside_frontend_keeps_check(self):
        # execution_turn.zig is strict but alone selects only its logic root.
        self.assertEqual(select(["src/execution_turn.zig"], "review", AVAILABLE)["targets"], ["stack-frames", "test-logic"])
        for strict_path in ("src/execution_turn.zig", "src/store.zig", "src/server.zig",
                            "tests/integration/bash_integration.py", "src/store_recovery.zig"):
            for frontend in ("src/SessionFrontend.zig", "src/ConversationViewport.zig",
                             "src/TerminalText.zig", "src/AnswerRenderer.zig",
                             "src/session_sequence_model_test.zig"):
                with self.subTest(strict=strict_path, frontend=frontend):
                    result = select([frontend, strict_path], "review", AVAILABLE)
                    for family in ("targets", "native_targets"):
                        self.assertIn("check", result[family])
        for strict_path in ("build.zig", "install.sh"):
            with self.subTest(strict=strict_path):
                result = select(["src/SessionTerminal.zig", strict_path], "review", AVAILABLE)
                self.assertIn("check-full", result["targets"])

    def test_frontend_beside_other_executable_change_keeps_check(self):
        for frontend in ("src/SessionFrontend.zig", "src/TerminalText.zig", "src/ConversationViewport.zig",
                         "src/session_sequence_model_test.zig"):
            for other in ("src/provider.zig", "src/request_encoding.zig", "tests/ci/select_tests.py"):
                with self.subTest(frontend=frontend, other=other):
                    result = select([frontend, other], "review", AVAILABLE)
                    for family in ("targets", "native_targets"):
                        self.assertIn("check", result[family])
        # Renderer and documentation together are still renderer-only.
        for paths in (["src/SessionFrontend.zig", "src/TerminalText.zig", "README.md", "docs/x.md"],
                      ["src/AnswerRenderer.zig", "src/ConversationViewport.zig", "research/notes.md"]):
            with self.subTest(paths=paths):
                result = select(paths, "review", AVAILABLE)
                self.assertNotIn("check", result["targets"] + result["native_targets"])
        # AnswerRenderer never selected check; its ordinary union stays as before.
        self.assertEqual(select(["src/AnswerRenderer.zig", "src/request_encoding.zig"], "review",
                                AVAILABLE)["targets"], ["stack-frames", "test-logic"])

    def test_composed_gates_do_not_cover_the_separate_logic_root(self):
        for logic in ("src/logic_tests.zig", "src/AnswerRenderer.zig",
                      "src/request_encoding.zig", "src/execution_turn.zig",
                      "src/ResponseTiming.zig"):
            for composed in ("src/server.zig", "src/store.zig", "build.zig"):
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
        script = dedent(job.split('run: |\n', 1)[1])
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
        for targets, plan, policy, build, native, private, expected, typecheck, split, unit in cases:
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
                                                 'SPLIT': split, 'UNIT_RESULT': unit})
                    actual = 'success' if result.returncode == 0 else 'failure'
                self.assertEqual(actual, expected)

    def test_linux_producer_splits_only_beside_other_compiles(self):
        from qualification import split_linux
        self.assertTrue(split_linux(["check"]))
        self.assertTrue(split_linux(["test", "test-logic"]))
        self.assertFalse(split_linux(["test"]))
        self.assertFalse(split_linux(["test-logic", "admission-debug-integration"]))

    def test_shared_state_and_unknown_code_fail_closed(self):
        for path in ("src/future_owner.zig", "tests/integration/future_case.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["check"])
            self.assertTrue(result["native_required"])

    def test_store_sql_keeps_native_owner_without_unrelated_mac_suite(self):
        # Both systems also run the bounded Debug failure-provenance subset;
        # neither composed gate executes the Debug artifact through it.
        result = select(["src/store.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["check", "dispatch-debug-integration"])
        self.assertEqual(result["native_targets"], ["dispatch-debug-integration", "test"])
        self.assertTrue(result["native_required"])
        combined = select(["src/store.zig", "src/server.zig"], "review", AVAILABLE)
        self.assertEqual(combined["native_targets"], ["admission-debug-integration", "check",
                                                     "codex-h2-integration", "dispatch-debug-integration",
                                                     "transport-h2-integration"])
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
            native = ["bash-integration", "bash-lifecycle-integration", "bash-owner-integration",
                      "bash-recovery-integration", "test", "test-logic"]
            self.assertEqual(result["native_targets"], native, path)
            self.assertEqual(result["targets"], sorted(native + ["stack-frames"]), path)

    def test_codex_credential_values_keep_portable_and_native_owner_checks(self):
        for path in ("src/codex_credential_policy.zig", "src/codex_token_wire.zig"):
            result = select([path], "review", AVAILABLE)
            native = ["codex-credential-integration", "codex-h2-integration", "codex-integration", "test", "test-logic"]
            self.assertEqual(result["native_targets"], native)
            self.assertEqual(result["targets"], sorted(native + ["stack-frames"]))

    def test_union_deduplicates_only_checks_owned_by_broad_gate(self):
        result = select(["src/store.zig", "src/codex_credentials.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["check", "codex-credential-integration", "codex-h2-integration",
                                             "dispatch-debug-integration"])
        self.assertEqual(result["native_targets"], ["codex-credential-integration", "codex-h2-integration", "codex-integration",
                                                    "dispatch-debug-integration", "test"])

    def test_build_changes_keep_long_and_debug_checks(self):
        result = select(["build.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration",
                             "test-full", "current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        # Mac check-full belongs to the daily macOS workflow, not Selected.
        self.assertIn("check-full", result["targets"])
        self.assertNotIn("check-full", result["native_targets"])
        self.assertIn("login-signal-integration", result["targets"])
        self.assertNotIn("login-signal-integration", result["native_targets"])

    def test_transport_inputs_keep_both_native_h2_owners(self):
        for path in ("src/build_transport.sh", "build.zig.zon",
                     "tests/integration/codex_h2_integration.py", "tests/integration/codex_integration.py",
                     "tests/integration/transport_h2_integration.py", "tests/integration/transport_h2_integration_test.py"):
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
            self.assertNotIn("check-full", result["native_targets"])
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

    def test_model_scenarios_do_not_select_shared_fixture_consumers(self):
        result = select(["tests/integration/dispatch_integration.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertEqual(result[family], ["dispatch-debug-integration", "dispatch-integration"])

    def test_standalone_helper_routes_add_without_losing_existing_consumers(self):
        for path, owner in (("host_process.py", "check"),
                            ("control_integration.py", "check"),
                            ("canonical_failure_integration.py", "canonical-failure-integration")):
            result = select([f"tests/integration/{path}"], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn(owner, result[family])

    def test_shared_fixture_helpers_keep_composed_and_separate_consumers(self):
        for name in ("control_integration.py", "model_fixture.py", "host_process.py"):
            path = f"tests/integration/{name}"
            standalone = {"codex-h2-integration", "transport-h2-integration", "server-delivery-integration"}
            if name != "control_integration.py":
                standalone.add("current-facts-integration")
            for composed, paths in (("check", [path]), ("check-full", [path, "build.zig"])):
                with self.subTest(name=name, composed=composed):
                    result = select(paths, "review", AVAILABLE)
                    self.assertTrue({composed, *standalone} <= set(result["targets"]))
                    native = standalone | ({composed} - {"check-full"})
                    self.assertTrue(native <= set(result["native_targets"]))
                    for family in ("targets", "native_targets"):
                        self.assertNotIn("control-integration", result[family])

    def test_canonical_failure_is_covered_by_the_composed_human_cli_gate(self):
        path = "tests/integration/canonical_failure_integration.py"
        alone = select([path], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertIn("canonical-failure-integration", alone[family])
            self.assertNotIn("check", alone[family])
        for composed in ("src/server.zig", "build.zig"):
            combined = select([path, composed], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertNotIn("canonical-failure-integration", combined[family])
                self.assertIn("current-facts-integration", combined[family])

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
        self.assertEqual(len(filters), 2)
        for block in filters:
            harnesses = {p for p in re.findall(r"'([^']+)'", block) if p.startswith("tests/integration/")}
            # The restoration fixture is also a blocking gate, so it keeps its own selection.
            self.assertEqual(harnesses - {"tests/integration/terminal_restoration_integration.py"},
                             set(RENDERER_HARNESSES))
        for path in ("tests/integration/input_equivalence.py", "tests/integration/session_sequence_model.py",
                     "tests/integration/session_sequence_model_test.py", "tests/integration/terminal_input_replay.py"):
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
            "src/new_session_selection.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/preference_values.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/provider_selection.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/model_capability.zig": ["dispatch-integration", "test", "test-logic", "transport-h2-integration"],
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                self.assertEqual(result["native_targets"], expected)
                # check runs stack-frames itself; Linux selects it beside narrower owners.
                frames = [] if "check" in expected else ["stack-frames"]
                self.assertEqual(result["targets"], sorted(expected + frames))
                combined = select([path, "src/server.zig"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("test-logic", combined[family])
                    self.assertIn("check", combined[family])

    def test_preference_owner_and_fixture_use_canonical_membership(self):
        result = select(["src/preferences.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["admission-debug-integration", "check"])
        self.assertEqual(result["native_targets"], ["admission-debug-integration", "check"])
        for path in ("tests/integration/preference_policy_integration.py",
                     "tests/integration/preference_policy.zig"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["preference-policy-integration"])
            self.assertEqual(result["native_targets"], ["preference-policy-integration"])
            combined = select([path, "src/protocol.zig"], "review", AVAILABLE)
            self.assertEqual(combined["targets"], ["check"])
            self.assertEqual(combined["native_targets"], ["check"])

    def test_installer_report_runs_the_fixture_that_pins_its_json_reader(self):
        result = select(["release/publish.sh"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["host-status-integration"])
        self.assertEqual(result["native_targets"], ["host-status-integration"])
        self.assertTrue(result["mac_required"])

    def test_existing_fixture_target_and_new_fixture_fallback(self):
        result = select(["tests/integration/host_stop_integration.py"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["host-stop-integration"])

    def test_h2_fixture_and_companion_keep_both_owning_targets(self):
        for path in ("tests/integration/transport_h2_integration.py",
                     "tests/integration/transport_h2_integration_test.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["codex-h2-integration", "transport-h2-integration"])
            self.assertEqual(result["native_targets"], ["codex-h2-integration", "transport-h2-integration"])

    def test_public_read_fixture_and_client_select_owner_once(self):
        for owner in ("proposal", "activity"):
            for suffix in ("_integration.py", "_client.zig"):
                path = f"tests/integration/{owner}{suffix}"
                result = select([path], "review", AVAILABLE)
                self.assertEqual(result["targets"], [f"{owner}-integration"])
                self.assertEqual(result["native_targets"], [f"{owner}-integration"])
                combined = select([path, "src/protocol.zig"], "review", AVAILABLE)
                self.assertEqual(combined["targets"], ["check"])
                self.assertEqual(combined["native_targets"], ["check"])

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

    def test_setup_installs_fixture_packages_for_any_target(self):
        self.assertEqual(setup_requirements([]), {"go": False, "python": False})
        self.assertEqual(setup_requirements(["test-logic"]), {"go": False, "python": True})
        self.assertEqual(setup_requirements(["measurement-check"]), {"go": True, "python": True})
        imported = set()
        for fixture in (Path(__file__).parents[1] / "integration").glob("*.py"):
            imported |= set(re.findall(r"(?m)^\s*(?:import|from) (h2|pyte|wcwidth)\b", fixture.read_text()))
        pinned = {line.split("==")[0] for line in (Path(__file__).parents[1] / "integration/requirements.txt").read_text().split()}
        self.assertLessEqual(imported, pinned)

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
                self.assertEqual(workflow.count('persist-credentials: false'),
                                 workflow.count('uses: actions/checkout@'))
                if name == 'qualify-macos.yml':
                    self.assertIn('workflow_call:', workflow)
                # A save the token refuses only warns; restore-only setup is quiet.
                self.assertEqual(workflow.count("publish-caches: 'false'"),
                                 workflow.count('uses: ./.github/actions/setup'))
        for path in Path('.github/workflows').glob('*.yml'):
            if path.name not in ('qualify-macos.yml', 'previous-release-upgrade.yml', 'release.yml'):
                self.assertNotIn('publish-caches', path.read_text(), f'{path.name} must keep publishing')
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
        for path in ("src/store.zig", ".github/workflows/auto-land.yml", ".github/workflows/renderer-contracts.yml"):
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

    def test_wip_pushes_qualify_the_complete_candidate_even_after_an_empty_commit(self):
        workflow = Path('.github/workflows/check.yml').read_text()
        prefix = dedent(re.search(
            r'(?s)        run: \|\n(          set -euo pipefail\n.*?)'
            r'          python3 tests/ci/select_tests.py', workflow)[1])
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(
                    ['git', '-c', 'user.name=Selector test', '-c', 'user.email=test@example.invalid',
                     *args], cwd=directory, text=True, stderr=subprocess.DEVNULL).strip()
            git('init', '-b', 'main')
            root = Path(directory)
            (root / 'build.zig').write_text(Path('build.zig').read_text())
            git('add', '.')
            git('commit', '-m', 'base')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            base = git('rev-parse', 'HEAD')
            git('checkout', '-b', 'wip/ci-1')
            (root / 'src').mkdir()
            (root / 'src/request_encoding.zig').write_text('// changed owner\n')
            git('add', '.')
            git('commit', '-m', 'candidate')
            before = git('rev-parse', 'HEAD')
            git('commit', '--allow-empty', '-m', 'same-tree proof')
            with patch.dict(os.environ, BASE=before, EVENT_NAME='push', REF_NAME='wip/ci-1'):
                result = subprocess.run(['bash', '-c', prefix + 'printf "%s" "$BASE"'],
                                        cwd=directory, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, base)
            selected = subprocess.check_output([
                sys.executable, str(Path('tests/ci/select_tests.py').resolve()),
                '--base', result.stdout, '--phase', 'review'], cwd=directory, text=True)
            self.assertEqual(json.loads(selected)['targets'], ['stack-frames', 'test-logic'])
            # A dispatched qualification keeps its explicit base even when main already
            # contains part of the stack, so a landed strict constituent stays selected.
            with patch.dict(os.environ, BASE='1' * 40, EVENT_NAME='workflow_dispatch', REF_NAME='wip/ci-1'):
                result = subprocess.run(['bash', '-c', prefix + 'printf "%s" "$BASE"'],
                                        cwd=directory, capture_output=True, text=True, check=True)
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
                proposal_integration.py.release activity_integration.py.release
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
            arguments = (["parallel", str(root / "native"), "status", "sessions", "proposal", "activity", "preferences", "notice"]
                         if part == "parallel" else
                         ["status", "sessions", "proposal", "activity", "preferences", part, "notice"])
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
            "bash_lifecycle_integration.py release", "bash_recovery_integration.py release",
            "codex_integration.py release", "control_integration.py release",
            "session_list_integration.py release", "conversation_page_integration.py release",
            "proposal_integration.py release", "activity_integration.py release",
            "descriptor_capacity_integration.py release", "host_status_integration.py release",
            "host_launch_integration.py release", "host_stop_integration.py release",
            "admission_integration.sh debug", "host_process_test.py ",
            "host_allocator_test.py release",
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
                        "proposal_integration.py", "activity_integration.py",
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
