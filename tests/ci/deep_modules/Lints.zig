//! The deep-modules lints. Each lint is a pure function over the loaded sources, their
//! declarations and their references; `run` gathers them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sources = @import("Sources.zig");
const Items = @import("Items.zig");
const Diagnostic = @import("Diagnostic.zig");
const FieldLeak = @import("FieldLeak.zig");
const Graph = @import("Graph.zig");
const ModuleCycle = @import("ModuleCycle.zig");
const References = @import("References.zig");
const Shallow = @import("Shallow.zig");
const Tangle = @import("Tangle.zig");
const TestCode = @import("TestCode.zig");
const Wrappers = @import("Wrappers.zig");

/// Every lint's findings over `sources`, limited to `scope` when it is set, sorted by lint and then by key.
pub fn run(arena: Allocator, sources: *const Sources, items: *const Items.Items, scope: ?Sources.NodeId) Allocator.Error![]Diagnostic.Diagnostic {
    const refs = try TestCode.production(arena, sources, items, try References.collect(arena, sources, items));
    var wrappers = try Wrappers.find(arena, items, sources, refs);
    const graph = try Graph.build(arena, items, refs, &wrappers);
    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    try found.appendSlice(arena, try ModuleCycle.check(arena, sources, items, refs, scope));
    try found.appendSlice(arena, try Tangle.check(arena, sources, items, refs, &graph, scope));
    try found.appendSlice(arena, try FieldLeak.check(arena, sources, items, refs, &graph, scope));
    try found.appendSlice(arena, try Shallow.check(arena, sources, items, refs, &graph, &wrappers, scope));
    return sorted(arena, found.items);
}

/// A copy of `found` in the order reports and the allow file use: by lint, then by key.
pub fn sorted(arena: Allocator, found: []const Diagnostic.Diagnostic) Allocator.Error![]Diagnostic.Diagnostic {
    const copy = try arena.dupe(Diagnostic.Diagnostic, found);
    std.mem.sort(Diagnostic.Diagnostic, copy, {}, lessThan);
    return copy;
}

fn lessThan(_: void, a: Diagnostic.Diagnostic, b: Diagnostic.Diagnostic) bool {
    if (a.lint != b.lint) return @backingInt(a.lint) < @backingInt(b.lint);
    return std.mem.lessThan(u8, a.key, b.key);
}

const testing = std.testing;

fn diagnostic(lint: Diagnostic.Lint, key: []const u8) Diagnostic.Diagnostic {
    return .{ .lint = lint, .key = key, .message = "", .location = null, .notes = &.{}, .picture = .{ .lists = .{ .shown = 0, .hidden = 0, .lists = &.{} } } };
}

test "sorted orders by lint declaration order, then by key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = [_]Diagnostic.Diagnostic{
        diagnostic(.@"shallow-module", "store/wire"),
        diagnostic(.tangle, "Overview"),
        diagnostic(.@"module-cycle", "store,session_host"),
        diagnostic(.@"module-cycle", "a,b"),
    };
    const got = try sorted(arena, &found);
    try testing.expectEqual(found.len, got.len);
    const want = [_]struct { lint: Diagnostic.Lint, key: []const u8 }{
        .{ .lint = .@"module-cycle", .key = "a,b" },
        .{ .lint = .@"module-cycle", .key = "store,session_host" },
        .{ .lint = .tangle, .key = "Overview" },
        .{ .lint = .@"shallow-module", .key = "store/wire" },
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |expected, actual| {
        try testing.expectEqual(expected.lint, actual.lint);
        try testing.expectEqualStrings(expected.key, actual.key);
    }
}

test "sorted of nothing is nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try sorted(arena_state.allocator(), &.{})).len);
}
