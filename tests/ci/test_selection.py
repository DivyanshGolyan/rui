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
        self.assertEqual(select(["build.zig"], "review", AVAILABLE)["targets"],
                         ["admission-debug-integration", "check-full", "evaluator-churn", "test-full"])

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
            ["test", "dispatch-integration", "transport-h2-integration"],
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


class FullCheckPartitionTest(unittest.TestCase):
    def run_part(self, part, fail=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Exercise the shell gate's public commands without launching product
            # fixtures. This checks membership and failure propagation, not timing.
            command = '#!/bin/sh\nprintf "%s %s\\n" "$(basename "$1")" "$2"\n' \
                      'if [ "$(basename "$1")" = "$FAIL_FIXTURE" ]; then exit 42; fi\n'
            for name in ("python3", "sh"):
                (root / name).write_text(command)
                (root / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FAIL_FIXTURE=fail)
            return subprocess.run([
                "/bin/sh", "tests/integration/check.sh", "release", "debug", "status",
                "sessions", "proposal", "activity", "preferences", part,
            ], env=env, text=True, capture_output=True)

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
            lines = result.stdout.splitlines()[1:]  # Actual-platform announcement.
            self.assertEqual(len(lines), len(set(lines)), lines)
            outputs[part] = set(lines)
        self.assertEqual(outputs["all"], expected)
        self.assertEqual(outputs["execution"] & outputs["callers"], set())
        self.assertEqual(outputs["execution"] | outputs["callers"], expected)
        self.assertIn("dispatch_integration.py release", outputs["execution"])
        self.assertIn("human_cli_integration.py release", outputs["callers"])

    def test_failure_or_invalid_part_cannot_report_success(self):
        self.assertEqual(self.run_part("callers", "activity_integration.py").returncode, 42)
        self.assertEqual(self.run_part("not-a-part").returncode, 2)


if __name__ == "__main__":
    unittest.main()
