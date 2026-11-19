"""Coverage-owner properties and promotion's normalization boundary."""
from itertools import chain, combinations
import unittest

from ci_plan import plan
from docs_only import ChangeKind
from select_tests import CHECK_COVERS, FIXTURE_COVERS, UNIT_ROOTS, covers, normalize


def powerset(items):
    items = sorted(items)
    return (set(subset) for size in range(len(items) + 1) for subset in combinations(items, size))


class CoverageTest(unittest.TestCase):
    def test_normalization_properties(self):
        # Exhaust the interacting broad/unit/fixture rules, then vary every
        # other CHECK_COVERS member both alone and at the check-promotion edge.
        # The literal 34-target powerset has 17,179,869,184 subsets.
        interacting = ({"test", "test-native", "test-store", "check", "check-full", "stack-frames"}
                       | FIXTURE_COVERS.keys() | set().union(*FIXTURE_COVERS.values()) | {"unrelated-target"})
        ordinary = CHECK_COVERS - interacting
        contexts = [set(), ordinary]
        contexts += [{target} for target in sorted(ordinary)]
        contexts += [ordinary - {target} for target in sorted(ordinary)]
        alphabet = interacting | ordinary
        never_covered = {target for target in alphabet if not covers(target, alphabet - {target})}
        for core in powerset(interacting):
            for context in contexts:
                selected = core | context
                before = set(selected)
                result = normalize(selected)
                self.assertEqual(selected, before)
                self.assertEqual(normalize(result), result, selected)
                self.assertTrue(all(covers(target, result) for target in selected), (selected, result))
                self.assertLessEqual(selected & never_covered, result, selected)

    def test_normalization_golden_cases(self):
        # Expected outcomes taken from select() at main 9b57aa17.
        cases = (
            (set(), set()),
            ({"test-native", "test-store"}, {"test"}),
            ({"test", "test-native", "test-store"}, {"test"}),
            ({"human-cli-integration", "canonical-failure-integration", "terminal-restoration-integration"},
             {"human-cli-integration"}),
            ({"check", "stack-frames", "test"}, {"check"}),
            ({"check-full", "check", "stack-frames", "test"}, {"check-full", "stack-frames"}),
            ({"check-full", "stack-frames"}, {"check-full", "stack-frames"}),
            ({"unrelated-target", "test-native"}, {"unrelated-target", "test-native"}),
        )
        for selected, expected in cases:
            with self.subTest(selected=selected):
                self.assertEqual(normalize(selected), expected)

    def test_every_check_promotion_member_and_fixture_substitution(self):
        required = CHECK_COVERS - UNIT_ROOTS.keys() - {"test"}
        self.assertEqual(normalize(required), {"check"})
        for target in required - set().union(*FIXTURE_COVERS.values()):
            with self.subTest(missing=target):
                self.assertNotIn("check", normalize(required - {target}))
        for broad, cases in FIXTURE_COVERS.items():
            self.assertEqual(normalize((required - cases) | {broad}), {"check"})

    def test_coverage_distinguishes_full_check_and_stack_frames(self):
        self.assertTrue(covers("check", {"check-full"}))
        self.assertTrue(covers("stack-frames", {"check"}))
        self.assertFalse(covers("stack-frames", {"check-full"}))
        self.assertFalse(covers("test-native", {"test-store"}))
        for target in chain(CHECK_COVERS, FIXTURE_COVERS, ("unrelated-target",)):
            self.assertTrue(covers(target, {target}))
            self.assertFalse(covers(target, set()))

    def test_promotion_restores_mysql_after_normalization_and_keeps_stack_frames(self):
        selected = dict(targets=["check", "stack-frames", "host-status-integration"],
                        native_targets=["check", "test-native"], native_required=True,
                        mac_required=True, upgrade_required=False, server_targets=[],
                        cache_execution_checks=False, typecheck_macos=False, linux_memory_checks=False,
                        manual_checks=[], retry=True, mysql_suites=["host-status-integration"], policy_skips=[])
        result = plan(selected, event_name="workflow_dispatch", draft=False, promotion=True,
                      change_kind=ChangeKind.NORMAL)
        core = {"check-full", "test-logic", "admission-debug-integration"}
        self.assertEqual(result.outputs["targets"], ["admission-debug-integration", "check-full", "host-status-integration",
                                                     "mysql-wire-integration", "rsql-table", "stack-frames", "test-logic"])
        self.assertEqual(result.outputs["native_targets"], sorted(core))
        self.assertEqual(selected["targets"], ["check", "stack-frames", "host-status-integration"])


if __name__ == "__main__":
    unittest.main()
