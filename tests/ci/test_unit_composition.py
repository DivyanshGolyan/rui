"""Opt-in operational Zig graph probes; no native test suite is executed.

Run outside zb; each child graph evaluation acquires build admission once:
RUI_TEST_UNIT_COMPOSITION=1 PYTHONPATH=tests/ci python3 -B -m unittest test_unit_composition
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import build_files


@unittest.skipUnless(os.environ.get("RUI_TEST_UNIT_COMPOSITION") == "1", "set RUI_TEST_UNIT_COMPOSITION=1 for graph probes")
class UnitCompositionGraphTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        shutil.copy2(build_files.ROOT / "src/unit_test_partition.zig", self.root / "src/unit_test_partition.zig")

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


if __name__ == "__main__":
    unittest.main()
