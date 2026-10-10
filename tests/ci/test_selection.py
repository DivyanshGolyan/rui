import re
from pathlib import Path
import unittest

from select_tests import select


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

    def test_preference_target_is_used_when_owner_wires_it(self):
        result = select(["src/preferences.zig"], "review", AVAILABLE | {"preference-policy-integration"})
        self.assertEqual(result["targets"], ["admission-debug-integration", "check", "preference-policy-integration"])

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


if __name__ == "__main__":
    unittest.main()
