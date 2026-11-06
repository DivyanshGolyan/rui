#!/usr/bin/env python3
"""Adapt the installed Zig runner, rather than maintaining a fork of its protocol."""
from pathlib import Path
import sys


def generate(source):
    # Compiler filters reduce sema/codegen but always include anonymous discovery
    # tests, and match substrings rather than prefixes. Give the runner the exact
    # owned subset, including those discovery tests, in BOTH CLI and server mode.
    needle = "builtin.test_functions"
    if needle not in source:
        raise ValueError("Zig's test runner changed: review unit root ownership")
    return source.replace(needle, "unitTests()").rstrip() + r'''

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
    unit_tests = selected[0..count];
    return unit_tests.?;
}
'''


if __name__ == "__main__":
    source, output = map(Path, sys.argv[1:])
    output.write_text(generate(source.read_text()))
