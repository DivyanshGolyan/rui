"""Read the build-owned registry without invoking Zig or build admission."""
from pathlib import Path
import importlib.util
import os
import tempfile
import unittest
from unittest.mock import patch

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
        self.assertTrue(all(all(part != "callers" for _, part in row["owners"]) for row in rows))
        owners = {row["name"]: row["owners"] for row in rows if row["name"].startswith("parser-fuzz")}
        self.assertEqual(owners["parser-fuzz"], [("test-logic", "all")])
        self.assertEqual(owners["parser-fuzz-llvm"], [("fuzz-parsers", "all")])

    def test_target_and_source_discovery_need_no_runner_namespace_file(self):
        expected_rows = build_files.unit_root_rows(self.root)
        expected_targets = build_files.steps(self.root)
        (self.root / "src/unit_test_partition.zig").unlink()
        self.assertEqual(build_files.unit_root_rows(self.root), expected_rows)
        self.assertEqual(build_files.steps(self.root), expected_targets)
        self.assertIn("src/parser_fuzz_tests.zig", {row["source"] for row in expected_rows})
        self.assertTrue(all("prefix" not in row and "exclude_prefix" not in row for row in expected_rows))
        with self.assertRaises(FileNotFoundError):
            build_files.unit_roots(self.root)

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
        self.assertNotIn(("check", "all"), deadline["owners"])

    def test_changed_runner_grammar_is_refused_only_by_namespace_enrichment(self):
        expected_rows = build_files.unit_root_rows(self.root)
        expected_targets = build_files.steps(self.root)
        self.change("src/unit_test_partition.zig", "std.mem.startsWith", "std.mem.endsWith")
        self.assertEqual(build_files.unit_root_rows(self.root), expected_rows)
        self.assertEqual(build_files.steps(self.root), expected_targets)
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
            ('pub const roots = [_]UnitRoot{', 'pub const roots = computed_roots;', "missing roots registry"),
        ):
            with self.subTest(change=before):
                path.write_text(original.replace(before, after))
                with self.assertRaisesRegex(ValueError, message):
                    build_files.unit_roots(self.root)

    def test_membership_is_derived_from_composition_and_group_edits(self):
        def memberships():
            return {row["name"] + "-" + Path(row["source"]).stem: set(row["owners"])
                    for row in build_files.unit_root_rows(self.root)}
        before = memberships()
        self.assertEqual(before["unit-store-tests"], {
            ("test-store", "all"), ("test", "all"), ("check", "all"),
            ("check-full", "all"), ("check-full", "execution"),
        })
        self.change("build/unit.zig", '.gate = "check", .items = &.{ .native_pair, .h2, .pg }',
                    '.gate = "check", .items = &.{ .h2, .pg }')
        changed = memberships()
        self.assertNotIn(("check", "all"), changed["unit-native-tests"])
        self.assertNotIn(("check", "all"), changed["unit-store-tests"])
        self.assertIn(("check", "all"), changed["test-h2"])
        self.change("build/unit.zig", '.roots = &.{ .native, .store }', '.roots = &.{.native}')
        changed = memberships()
        self.assertNotIn(("test", "all"), changed["unit-store-tests"])
        self.assertIn(("test-store", "all"), changed["unit-store-tests"])
        self.assertIn(("test", "all"), changed["unit-native-tests"])

    def test_unknown_composition_and_group_syntax_is_refused(self):
        path = self.root / "build/unit.zig"
        original = path.read_text()
        for before, after in (
            ('.gate = "check", .items = &.{ .native_pair, .h2, .pg }', '.gate = "check", .items = &.{.unknown}'),
            ('.roots = &.{ .native, .store }', '.roots = computed_roots'),
            ('.parts = &.{ .all, .execution }', '.parts = &.{.unknown}'),
        ):
            with self.subTest(change=before):
                path.write_text(original.replace(before, after))
                with self.assertRaises(ValueError):
                    build_files.unit_root_rows(self.root)

    def test_graph_probe_is_skipped_by_default_even_when_tools_exist(self):
        path = Path(__file__).with_name("test_unit_composition.py")
        spec = importlib.util.spec_from_file_location("unit_composition_default_probe", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {"RUI_TEST_UNIT_COMPOSITION": ""}), \
                patch("shutil.which", return_value="/available/tool"), \
                patch("subprocess.run", side_effect=AssertionError("default graph probe invoked a process")):
            spec.loader.exec_module(module)
            suite = unittest.defaultTestLoader.loadTestsFromModule(module)
            result = unittest.TestResult()
            suite.run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(len(result.skipped), 1)
        self.assertFalse(result.errors or result.failures)

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
