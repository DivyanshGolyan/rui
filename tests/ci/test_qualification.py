"""Qualification owns the matrix aliases consumed by red reproduction."""
import unittest

from qualification import matrix_targets, shards


class MatrixIdentityTest(unittest.TestCase):
    def test_full_parts_preserve_actual_gate_and_part(self):
        self.assertEqual(matrix_targets("full-execution"), (("check-full", "execution"),))
        self.assertEqual(matrix_targets("full-callers"), (("check-full", "callers"),))
        self.assertEqual(matrix_targets("check-full"), (("check-full", "all"),))
        self.assertEqual(matrix_targets(""), ())

    def test_every_unit_gate_round_trips_standalone_and_packed(self):
        gates = ("test", "test-native", "test-store", "test-full", "test-logic", "test-logic-only",
                 "fuzz-parsers", "test-h2", "test-pg", "mysql-wire-integration", "check", "check-full")
        for gate in gates:
            for targets in ([gate], [gate, "test-logic", "test-h2", "test-store"]):
                with self.subTest(targets=targets):
                    rows = shards(list(dict.fromkeys(targets)), mysql_suites=set())["include"]
                    for row in rows:
                        self.assertEqual(matrix_targets(row["name"]),
                                         tuple((target, row["part"]) for target in row["targets"]))

    def test_packed_aliases_are_interpreted_by_qualification(self):
        self.assertEqual(matrix_targets("test-native+full-execution+test-logic"),
                         (("test-native", "all"), ("check-full", "execution"), ("test-logic", "all")))
        self.assertEqual(matrix_targets("unknown"), (("unknown", "all"),))

    def test_both_platforms_use_the_same_full_part_names(self):
        for platform in ("linux", "macos"):
            with self.subTest(platform=platform):
                rows = shards(["check-full"], platform, mysql_suites=set())["include"]
                self.assertEqual([(row["name"], row["targets"], row["part"]) for row in rows],
                                 [("full-execution", ["check-full"], "execution"),
                                  ("full-callers", ["check-full"], "callers")])


if __name__ == "__main__":
    unittest.main()
