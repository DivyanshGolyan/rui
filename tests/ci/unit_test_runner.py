#!/usr/bin/env python3
import json
import math
from pathlib import Path
import sys


def generate(source, times=None):
    needle = "builtin.test_functions"
    if needle not in source:
        raise ValueError("Zig's test runner changed: review unit root ownership")
    signature = "pub fn main(init: std.process.Init.Minimal) void {"
    if signature not in source:
        raise ValueError("Zig's test runner changed: review unit environment initialization")
    source = source.replace(signature,
                            "pub fn main(init: std.process.Init.Minimal) void {\n    unit_environ = init.environ;")
    timings = "\nconst store_test_times = [_]@import(\"unit_test_partition\").Timing{\n" + "".join(
        "    .{ .name = " + json.dumps(name, ensure_ascii=False) + ", .seconds = " + repr(seconds) + " },\n"
        for name, seconds in sorted((times or {}).items())) + "};\n"
    return source.replace(needle, "unitTests()").rstrip() + timings + r'''

var unit_environ: std.process.Environ = undefined;
var unit_tests: ?[]const std.builtin.TestFn = null;
fn unitTests() []const std.builtin.TestFn {
    if (unit_tests) |tests| return tests;
    const partition = @import("unit_test_partition");
    const root = @import("unit_test_options").root;
    const all = builtin.test_functions;
    const selected = std.heap.page_allocator.alloc(std.builtin.TestFn, all.len) catch @panic("OOM");
    var count: usize = 0;
    for (all) |test_fn| {
        if (@backingInt(partition.owner(test_fn.name)) != root) continue;
        selected[count] = test_fn;
        count += 1;
    }
    {
        var environ = unit_environ.createMap(std.heap.page_allocator) catch @panic("OOM");
        defer environ.deinit();
        if (environ.get("RUI_UNIT_EXCLUSIVE")) |_| {
            var exclusive_count: usize = 0;
            for (selected[0..count]) |test_fn| {
                if (!partition.exclusive(test_fn.name)) continue;
                selected[exclusive_count] = test_fn;
                exclusive_count += 1;
            }
            count = exclusive_count;
        }
        if (environ.get("RUI_UNIT_SHARD")) |text| {
            const shard = partition.Shard.parse(text) catch @panic("invalid RUI_UNIT_SHARD; expected i/K with 0 <= i < K");
            const names = std.heap.page_allocator.alloc([]const u8, count) catch @panic("OOM");
            defer std.heap.page_allocator.free(names);
            for (selected[0..count], names) |test_fn, *name| name.* = test_fn.name;
            const placement = partition.assign(std.heap.page_allocator, names, &store_test_times, shard.count) catch @panic("unit shard assignment failed");
            defer std.heap.page_allocator.free(placement);
            var shard_count: usize = 0;
            // Exclusive mutations, histories and Handler comparison finish before peers start.
            // Keep them in the same shard-zero process; the launcher observes the
            // first ordinary terminal marker to release the shared-engine gate.
            const ordered = std.heap.page_allocator.dupe(std.builtin.TestFn, selected[0..count]) catch @panic("OOM");
            defer std.heap.page_allocator.free(ordered);
            for ([_]bool{ true, false }) |first| {
                for (ordered, placement) |test_fn, owner| {
                    if (owner != shard.index) continue;
                    if (partition.exclusive(test_fn.name) != first) continue;
                    selected[shard_count] = test_fn;
                    shard_count += 1;
                }
            }
            count = shard_count;
        }
    }
    unit_tests = selected[0..count];
    return unit_tests.?;
}
'''


def generate_filtered(source):
    needle = "builtin.test_functions"
    if needle not in source:
        raise ValueError("Zig's test runner changed: review filtered test runs")
    return source.replace(needle, "filteredTests()").rstrip() + r'''

fn filteredTests() []const std.builtin.TestFn {
    const all = builtin.test_functions;
    for (all) |test_fn| {
        // Named tests are `module.test.name` or `module.decltest.name`;
        // anonymous discovery tests are `module.test_N`.
        if (std.mem.indexOf(u8, test_fn.name, ".test.") != null or
            std.mem.indexOf(u8, test_fn.name, ".decltest.") != null) return all;
    }
    std.debug.print("error: -Dtest-filter matched no named test in this step. Check the name and that this " ++
        "step's root imports the test's file; for check, filter the one step (test or test-logic) that owns it.\n", .{});
    std.process.exit(1);
}
'''


if __name__ == "__main__":
    arguments = sys.argv[1:]
    filtered = arguments[:1] == ["--filtered"]
    arguments = arguments[1:] if filtered else arguments
    source, output = map(Path, arguments[:2])
    times = json.loads(Path(arguments[2]).read_text()) if len(arguments) == 3 else {}
    if not isinstance(times, dict) or any(not isinstance(name, str) or not isinstance(seconds, (int, float))
                                          or not math.isfinite(seconds) or seconds < 0
                                          for name, seconds in times.items()):
        raise ValueError("test times must map names to finite nonnegative seconds")
    output.write_text(generate_filtered(source.read_text()) if filtered else generate(source.read_text(), times))
