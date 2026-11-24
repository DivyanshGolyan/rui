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

    def test_linux_keeps_full_part_names_and_macos_runs_check_full_in_one_row(self):
        rows = shards(["check-full"], "linux", mysql_suites=set())["include"]
        self.assertEqual([(row["name"], row["targets"], row["part"]) for row in rows],
                         [("full-execution", ["check-full"], "execution"),
                          ("full-callers", ["check-full"], "callers")])
        rows = shards(["check-full"], "macos", mysql_suites=set())["include"]
        self.assertEqual([(row["name"], row["targets"], row["part"]) for row in rows],
                         [("native", ["check-full"], "all")])

    def test_macos_emits_one_native_row_beside_resource_rows(self):
        targets = ["check-full", "test-logic", "admission-debug-integration", "measure-repeat-work"]
        rows = shards(targets, "macos", mysql_suites=set())["include"]
        self.assertEqual([(row["name"], row["targets"], row["part"]) for row in rows],
                         [("native", ["check-full", "test-logic", "admission-debug-integration"], "all"),
                          ("measure-repeat-work", ["measure-repeat-work"], "all")])
        self.assertEqual(sum(1 for row in rows if not row["resource"]), 1)
        self.assertEqual(matrix_targets("native"), (("native", "all"),))

if __name__ == "__main__":
    unittest.main()
