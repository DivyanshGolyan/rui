"""The build-owned unit registry stays readable without running Zig."""
from pathlib import Path
import tempfile
import unittest

import build_files


class UnitRootRegistryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("build/unit.zig", "src/unit_test_partition.zig", "build.zig"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text((build_files.ROOT / name).read_text())

    def change(self, name, before, after):
        path = self.root / name
        source = path.read_text()
        self.assertIn(before, source)
        path.write_text(source.replace(before, after))

    def test_every_executable_keeps_its_installed_identity_and_filtered_owner(self):
        rows = build_files.unit_roots(self.root)
        binaries = {row["name"] + "-" + Path(row["source"]).stem: row["target"] for row in rows}
        self.assertEqual(binaries, {
            "unit-native-tests": "test-native",
            "unit-store-tests": "test-store",
            "test-tests": "test",
            "deadline-witness-tests": "test-full",
            "test-logic_tests": "test-logic-only",
            "parser-fuzz-parser_fuzz_tests": "fuzz-parsers",
            "parser-fuzz-llvm-parser_fuzz_tests": "fuzz-parsers",
            "test-h2": "test-h2",
            "test-pg": "test-pg",
            "rui-mysql-wire-test-mysql_wire_test": "mysql-wire-integration",
        })
        self.assertEqual(len(rows), len(binaries))
        available = build_files.steps(self.root)
        self.assertLessEqual({row["target"] for row in rows}, set(available))
        self.assertTrue(all("full-callers" not in row["owners"] for row in rows))
        owners = {row["name"]: row["owners"] for row in rows if row["name"].startswith("parser-fuzz")}
        self.assertEqual(owners["parser-fuzz"], ["test-logic"])
        self.assertEqual(owners["parser-fuzz-llvm"], ["fuzz-parsers"])

    def test_namespace_constraints_come_from_runner_owner(self):
        def partitions():
            return {row["partition"]: row for row in build_files.unit_roots(self.root) if "partition" in row}
        self.assertEqual(partitions()["store"]["prefix"], "store.")
        self.assertEqual(partitions()["native"]["exclude_prefix"], "store.")
        self.change("src/unit_test_partition.zig", '"store."', '"renamed."')
        self.assertEqual(partitions()["store"]["prefix"], "renamed.")
        self.assertEqual(partitions()["native"]["exclude_prefix"], "renamed.")

    def test_filtered_aggregate_and_deadline_are_explicit(self):
        rows = build_files.unit_roots(self.root)
        filtered = [row for row in rows if row.get("filtered_only")]
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["target"], "test")
        self.assertNotIn("partition", filtered[0])
        deadline = next(row for row in rows if row["target"] == "test-full")
        self.assertEqual(deadline["filter"], "Host processing wait does not consume response transfer inactivity")
        self.assertNotIn("check", deadline["owners"])

    def test_changed_runner_grammar_is_refused(self):
        self.change("src/unit_test_partition.zig", "std.mem.startsWith", "std.mem.endsWith")
        with self.assertRaisesRegex(ValueError, "unsupported unit partition owner"):
            build_files.unit_roots(self.root)

    def test_unowned_partition_is_refused(self):
        self.change("build/unit.zig", '.partition = "store"', '.partition = "third"')
        with self.assertRaisesRegex(ValueError, "partition has no runner owner"):
            build_files.unit_roots(self.root)

    def test_changed_row_syntax_and_duplicate_id_are_refused(self):
        path = self.root / "build/unit.zig"
        original = path.read_text()
        for before, after, message in (
            ('.name = "unit-store"', '.name = computed_name', "unsupported unit-root row"),
            ('.id = .store,', '.id = .native,', "duplicate unit-root id"),
            ('pub const roots = [_]UnitRoot{', 'pub const roots = computed_roots;', "missing unit-root registry"),
        ):
            with self.subTest(change=before):
                path.write_text(original.replace(before, after))
                with self.assertRaisesRegex(ValueError, message):
                    build_files.unit_roots(self.root)

    def test_constructor_names_and_sources_read_the_registry(self):
        unit_source = (self.root / "build/unit.zig").read_text().split("pub fn add(", 1)[1]
        self.assertIn(".name = definition.name", unit_source)
        self.assertIn("b.path(definition.source)", unit_source)
        self.assertIn(".filters = if (definition.filtered_only)", unit_source)
        self.assertIn("root(.deadline).filter.?", unit_source)
        for path in ("src/tests.zig", "src/logic_tests.zig", "src/parser_fuzz_tests.zig"):
            self.assertNotIn('b.path("' + path + '")', unit_source)
        top = build_files.source(self.root)
        for root in ("h2", "pg", "mysql"):
            self.assertIn(f"unit_module.root(.{root})", top)
            self.assertIn(f".name = {root}_root.name", top)
            self.assertIn(f"b.path({root}_root.source)", top)


if __name__ == "__main__":
    unittest.main()
