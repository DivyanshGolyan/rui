import subprocess
import unittest
from pathlib import Path

from execution_turn_mutations import assertion_failed, mutants, replace_once


class MutationRunnerTests(unittest.TestCase):
    def test_all_mutations_have_exact_source_anchors(self):
        source = (Path(__file__).resolve().parents[1] / "src" / "execution_turn.zig").read_text()
        variants = mutants(source)
        self.assertEqual(len(variants), 6)
        self.assertEqual(len(set(variants.values())), 6)
        for variant in variants.values():
            self.assertNotEqual(variant, source)

    def test_missing_anchor_is_an_error(self):
        with self.assertRaises(ValueError):
            replace_once("other text", "needle", "replacement")

    def test_duplicate_anchor_is_an_error(self):
        with self.assertRaises(ValueError):
            replace_once("needle needle", "needle", "replacement")

    def test_assertion_failure_is_a_killed_mutation(self):
        result = subprocess.CompletedProcess([], 1, "", "1/6 turn.test.order...FAIL (TestExpectedEqual)\n")
        self.assertTrue(assertion_failed(result))

    def test_compiler_failure_is_not_a_killed_mutation(self):
        result = subprocess.CompletedProcess([], 1, "", "error: expected type 'usize', found 'void'\n")
        self.assertFalse(assertion_failed(result))

    def test_success_is_not_a_killed_mutation(self):
        result = subprocess.CompletedProcess([], 0, "", "All 6 tests passed.\n")
        self.assertFalse(assertion_failed(result))


if __name__ == "__main__":
    unittest.main()
