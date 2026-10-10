import json
import re
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from select_tests import execution_batches, select, setup_requirements


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))


class SelectionTest(unittest.TestCase):
    def test_development_does_not_claim_native_acceptance(self):
        result = select(["src/bash_platform.c", "src/store.zig"], "development", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])
        self.assertFalse(result["native_required"])
        self.assertFalse(result["acceptance_reused"])

    def test_portable_owner_does_not_require_full_suite(self):
        result = select(["src/request_encoding.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])
        self.assertFalse(result["native_required"])

    def test_logic_root_selects_its_executable_root(self):
        result = select(["src/logic_tests.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])

    def test_composed_gates_do_not_cover_the_separate_logic_root(self):
        for logic in ("src/logic_tests.zig", "src/AnswerRenderer.zig",
                      "src/request_encoding.zig", "src/execution_turn.zig"):
            for composed in ("src/server.zig", "src/store.zig", "build.zig"):
                with self.subTest(logic=logic, composed=composed):
                    result = select([logic, composed], "review", AVAILABLE)
                    self.assertIn("test-logic", result["targets"])
                    self.assertTrue(set(result["targets"]) & {"check", "check-full"})

    def test_docs_are_not_runtime_acceptance(self):
        self.assertEqual(select(["VERIFICATION.md"], "review", AVAILABLE)["targets"], [])

    def test_shared_state_and_unknown_code_fail_closed(self):
        for path in ("src/store.zig", "src/future_owner.zig", "tests/integration/future_case.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["check"])
            self.assertTrue(result["native_required"])

    def test_store_sql_keeps_native_owner_without_unrelated_mac_suite(self):
        result = select(["src/store.zig"], "review", AVAILABLE)
        self.assertEqual(result["native_targets"], ["test"])
        combined = select(["src/store.zig", "src/server.zig"], "review", AVAILABLE)
        self.assertEqual(combined["native_targets"], ["admission-debug-integration", "check"])

    def test_bash_keeps_real_custody_and_recovery_checks(self):
        result = select(["src/bash_platform.c"], "review", AVAILABLE)
        self.assertIn("bash-lifecycle-integration", result["targets"])
        self.assertIn("bash-recovery-integration", result["targets"])
        self.assertTrue(result["native_required"])

    def test_union_deduplicates_only_checks_owned_by_broad_gate(self):
        result = select(["src/store.zig", "src/codex_credentials.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["check", "codex-credential-integration", "codex-h2-integration"])
        self.assertEqual(result["native_targets"], ["codex-credential-integration", "codex-h2-integration", "codex-integration", "test"])

    def test_build_changes_keep_long_and_debug_checks(self):
        result = select(["build.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration", "check-full", "evaluator-churn",
                             "test-full", "current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertIn("login-signal-integration", result["targets"])
        self.assertNotIn("login-signal-integration", result["native_targets"])

    def test_transport_inputs_keep_both_native_h2_owners(self):
        for path in ("src/build_transport.sh", "src/curl-post-retry.patch", "build.zig.zon"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn("transport-h2-integration", result[family])
                self.assertIn("codex-h2-integration", result[family])

    def test_bootstrap_action_is_not_cheap_ci_policy(self):
        result = select([".github/actions/setup/action.yml"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"check-full", "admission-debug-integration", "test-full",
                             "evaluator-churn", "transport-h2-integration",
                             "codex-h2-integration"} <= set(result[family]))

    def test_shared_driver_keeps_parallel_and_full_modes(self):
        for paths in (["tests/integration/check.sh"],
                      ["tests/integration/check.sh", "build.zig"],
                      ["tests/integration/check.sh", "src/server.zig"]):
            result = select(paths, "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertTrue({"check", "check-full"} <= set(result[family]))

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
        result = select(["tests/integration/dispatch_integration.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertEqual(execution_batches(["current-facts-integration", "server-delivery-integration"]),
                         [["current-facts-integration"], ["server-delivery-integration"]])

    def test_standalone_helper_routes_add_without_losing_existing_consumers(self):
        for path, owner in (("host_process.py", "check"),
                            ("control_integration.py", "control-integration"),
                            ("canonical_failure_integration.py", "canonical-failure-integration")):
            result = select([f"tests/integration/{path}"], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn(owner, result[family])

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
                     "tests/ci/select_tests.py", "tests/ci/run_selected.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["test-logic"])
            self.assertEqual(result["native_targets"], ["test-logic"])

    def test_missing_required_target_is_an_error_not_a_skip(self):
        with self.assertRaisesRegex(ValueError, "absent"):
            select(["src/bash.zig"], "review", AVAILABLE - {"bash-recovery-integration"})

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

    def test_existing_fixture_target_and_new_fixture_fallback(self):
        result = select(["tests/integration/host_stop_integration.py"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["host-stop-integration"])

    def test_h2_fixture_and_companion_keep_their_owning_target(self):
        for path in ("tests/integration/transport_h2_integration.py",
                     "tests/integration/transport_h2_integration_test.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["transport-h2-integration"])
            self.assertEqual(result["native_targets"], ["transport-h2-integration"])

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
        for path in ("src/server.zig", "tests/integration/admission_integration.sh"):
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

    def test_setup_installs_only_selected_fixture_dependencies(self):
        self.assertEqual(setup_requirements(["test-logic"]), {"go": False, "h2": False})
        self.assertEqual(setup_requirements(["check-full"]), {"go": False, "h2": False})
        self.assertEqual(setup_requirements(["measurement-check"]), {"go": True, "h2": False})
        for target in ("transport-h2-integration", "codex-h2-integration"):
            self.assertEqual(setup_requirements([target, "measurement-check"]),
                             {"go": True, "h2": True})

    def test_batches_share_builds_but_isolate_timing_witnesses(self):
        targets = ["test", "dispatch-integration", "transport-h2-integration",
                   "test-full", "evaluator-churn", "admission-debug-integration",
                   "host-launch-integration", "check-full", "workflow-check",
                   "evaluator-host-integration"]
        self.assertEqual(execution_batches(targets), [
            ["workflow-check", "evaluator-host-integration"],
            ["test", "dispatch-integration"],
            ["transport-h2-integration"],
            ["test-full"], ["evaluator-churn"], ["admission-debug-integration"],
            ["host-launch-integration"], ["check-full"],
        ])
        self.assertEqual(execution_batches([]), [])

    def test_cache_proof_tracks_cache_policy_not_every_runtime_edit(self):
        for path in ("build.zig", ".github/actions/setup/action.yml", "tests/ci/cache_execution.py"):
            self.assertTrue(select([path], "review", AVAILABLE)["cache_execution_checks"])
        self.assertFalse(select(["src/store.zig"], "review", AVAILABLE)["cache_execution_checks"])

    def test_isolated_full_check_parts_keep_other_selected_work_once(self):
        targets = ["admission-debug-integration", "check-full", "evaluator-churn", "test-full"]
        self.assertEqual(execution_batches(targets, "execution"),
                         [["check-full", "-Dcheck-part=execution"]])
        self.assertEqual(execution_batches(targets, "callers"), [
            ["admission-debug-integration"], ["check-full", "-Dcheck-part=callers"],
            ["evaluator-churn"], ["test-full"],
        ])
        with self.assertRaises(ValueError):
            execution_batches(["test-logic"], "execution")

    def test_unreachable_push_base_falls_back_without_hiding_review_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "user.name=Selector test", "-c", "user.email=test@example.invalid",
                     *args], cwd=directory, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-b", "main")
            root = Path(directory)
            (root / "build.zig").write_text(Path("build.zig").read_text())
            git("add", "build.zig")
            git("commit", "-m", "base")
            git("checkout", "-b", "candidate")
            (root / "src").mkdir()
            (root / "src/request_encoding.zig").write_text("// changed owner\n")
            git("add", ".")
            git("commit", "-m", "candidate")
            command = ["python3", str(Path("tests/ci/select_tests.py").resolve()),
                       "--base", "1" * 40, "--phase", "development"]
            missing = subprocess.run(command, cwd=directory, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            for base in ("1" * 40, "0" * 40):
                command[command.index("--base") + 1] = base
                fallback = subprocess.run(command + ["--fallback-base", "main"],
                                          cwd=directory, capture_output=True, text=True)
                self.assertEqual(fallback.returncode, 0, fallback.stderr)
                selected = json.loads(fallback.stdout)
                self.assertEqual(selected["targets"], ["test-logic"])
                self.assertEqual(selected["base"], git("rev-parse", "main"))


class FullCheckPartitionTest(unittest.TestCase):
    def run_part(self, part, fail="", overlap=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Exercise the shell gate's public commands without launching product
            # fixtures. This checks membership and failure propagation, not timing.
            command = '''#!/bin/sh
fixture=$(basename "$1")
if [ "$CHECK_OVERLAP" = 1 ]; then
    touch "$GATE_DIR/$fixture.started"
    if [ "$fixture" = human_cli_integration.py ]; then
        n=0
        while [ ! -e "$GATE_DIR/activity_integration.py.started" ]; do
            n=$((n + 1))
            if [ "$n" -ge 200 ]; then exit 43; fi
            sleep 0.01
        done
    fi
    case "$fixture" in
        host_launch_integration.py|host_process_test.py|host_allocator_test.py|admission_integration.sh)
            for peer in human_cli_integration.py preference_policy_integration.py \\
                session_list_integration.py conversation_page_integration.py \\
                proposal_integration.py activity_integration.py \\
                host_status_integration.py host_stop_integration.py; do
                if [ ! -e "$GATE_DIR/$peer.done" ]; then exit 44; fi
            done ;;
    esac
    touch "$GATE_DIR/$fixture.done"
fi
printf "%s %s\\n" "$fixture" "$2"
if [ "$fixture" = "$FAIL_FIXTURE" ]; then exit 42; fi
'''
            for name in ("python3", "sh"):
                (root / name).write_text(command)
                (root / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FAIL_FIXTURE=fail,
                       CHECK_OVERLAP=str(int(overlap)), GATE_DIR=str(root))
            return subprocess.run([
                "/bin/sh", "tests/integration/check.sh", "release", "debug", "status",
                "sessions", "proposal", "activity", "preferences", part,
            ], env=env, text=True, capture_output=True, timeout=10)

    def test_parts_are_disjoint_and_cover_the_unchanged_full_gate(self):
        expected = {
            "admission_integration.sh release", "dispatch_integration.py release",
            "bash_owner_integration.py release", "bash_integration.py release",
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
        for part in ("all", "execution", "callers"):
            result = self.run_part(part)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = [line for line in result.stdout.splitlines()[1:]
                     if not line.endswith(" passed")]
            self.assertEqual(len(lines), len(set(lines)), lines)
            outputs[part] = set(lines)
        self.assertEqual(outputs["all"], expected)
        self.assertEqual(outputs["execution"] & outputs["callers"], set())
        self.assertEqual(outputs["execution"] | outputs["callers"], expected)
        self.assertIn("dispatch_integration.py release", outputs["execution"])
        self.assertIn("human_cli_integration.py release", outputs["callers"])

    def test_callers_overlap_private_fixtures_then_drain_before_deadline_cases(self):
        result = self.run_part("callers", overlap=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failure_or_invalid_part_cannot_report_success(self):
        for fixture in ("human_cli_integration.py", "preference_policy_integration.py",
                        "session_list_integration.py", "conversation_page_integration.py",
                        "proposal_integration.py", "activity_integration.py",
                        "host_status_integration.py", "host_stop_integration.py",
                        "host_launch_integration.py", "host_process_test.py",
                        "host_allocator_test.py", "admission_integration.sh"):
            self.assertNotEqual(self.run_part("callers", fixture).returncode, 0, fixture)
        self.assertEqual(self.run_part("not-a-part").returncode, 2)


if __name__ == "__main__":
    unittest.main()
