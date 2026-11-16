"""Registry reading and operational build composition, without native test suites."""
from pathlib import Path
import shutil
import subprocess
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

    @unittest.skipUnless(shutil.which("zb") and shutil.which("zig"), "pinned Zig build tools unavailable")
    def test_operational_graph_and_group_removals_match_derived_membership(self):
        # Evaluate real Build.Step dependencies, without compiling/running tests.
        # Copy the actual build modules so mutations cannot race this checkout.
        shutil.copytree(build_files.ROOT / "build", self.root / "build", dirs_exist_ok=True)
        (self.root / "empty.zig").write_text('test "probe" {}')
        (self.root / "build.zig").write_text(r'''const std = @import("std");
const unit = @import("build/unit.zig");
const CiArtifacts = @import("build/ci.zig").CiArtifacts;
fn reaches(step: *std.Build.Step, wanted: *std.Build.Step) bool {
    if (step == wanted) return true;
    for (step.dependencies.items) |child| if (reaches(child, wanted)) return true;
    return false;
}
pub fn build(b: *std.Build) void {
    const ci: CiArtifacts = .{ .b = b, .directory = null };
    const ids = [_]unit.UnitRoot.Id{ .native, .store, .filtered };
    var compiles: [3]*std.Build.Step.Compile = undefined;
    var runs: unit.Runs = .initFill(null);
    for (ids, &compiles) |id, *compile| {
        compile.* = b.addTest(.{ .name = unit.root(id).name, .root_module = b.createModule(.{
            .root_source_file = b.path("empty.zig"), .target = b.graph.host, .optimize = .Debug,
        }) });
        if (id != .filtered) runs.set(id, &ci.run(compile.*).step);
    }
    const native = unit.nativeGroup(b, ci, &ids, &compiles, false);
    runs.set(.native_pair, &native.final.step);
    const h2 = b.step("probe-h2", "Probe marker");
    const pg = b.step("probe-pg", "Probe marker");
    runs.set(.h2, h2);
    runs.set(.pg, pg);
    for ([_][]const u8{ "test-native", "test-store", "test", "check", "check-full" }) |gate| {
        for ([_]unit.Part{ .all, .execution, .callers }) |part| {
            const destination = b.step(b.fmt("probe-{s}-{s}", .{ gate, @tagName(part) }), "Probe composition");
            unit.attach(gate, part, destination, &runs, .runs);
            std.debug.print("PROBE {s}/{s} native={d} store={d} h2={d} pg={d}\n", .{
                gate, @tagName(part), @intFromBool(reaches(destination, &compiles[0].step)),
                @intFromBool(reaches(destination, &compiles[1].step)),
                @intFromBool(reaches(destination, h2)), @intFromBool(reaches(destination, pg)),
            });
        }
    }
    std.debug.print("PROBE argv", .{});
    for (native.binaries) |compile| std.debug.print(" {s}", .{compile.name});
    std.debug.print("\n", .{});
    const filtered = unit.nativeGroup(b, ci, &ids, &compiles, true);
    std.debug.print("PROBE filtered {d} {s}\n", .{ filtered.binaries.len, filtered.binaries[0].name });
    const shell = b.step("probe-shell", "Probe shell placement");
    unit.attach("check", .all, shell, &runs, .shell);
    std.debug.print("PROBE shell native={d} store={d}\n", .{
        @intFromBool(reaches(shell, &compiles[0].step)), @intFromBool(reaches(shell, &compiles[1].step)),
    });
}
''')
        path = self.root / "build/unit.zig"
        original = path.read_text()
        variants = (
            (original, "native=1 store=1 h2=1 pg=1", "unit-native unit-store"),
            (original.replace('.gate = "check", .items = &.{ .native_pair, .h2, .pg }',
                              '.gate = "check", .items = &.{ .native_pair, .pg }'),
             "native=1 store=1 h2=0 pg=1", "unit-native unit-store"),
            (original.replace('.roots = &.{ .native, .store }', '.roots = &.{.native}'),
             "native=1 store=0 h2=1 pg=1", "unit-native"),
        )
        for source, check, argv in variants:
            with self.subTest(check=check):
                path.write_text(source)
                result = subprocess.run(["zb", "zig", "build", "-j1", "--list-steps"], cwd=self.root,
                                        capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = result.stdout + result.stderr
                self.assertIn("PROBE check/all " + check, output)
                self.assertIn("PROBE argv " + argv + "\n", output)
                self.assertIn("PROBE filtered 1 test\n", output)
                self.assertIn("PROBE test-store/all native=0 store=1", output)
                self.assertIn("PROBE test-native/all native=1 store=0", output)
                self.assertIn("PROBE check-full/callers native=0 store=0 h2=0 pg=0", output)
                self.assertIn("PROBE shell native=0 store=0", output)

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
