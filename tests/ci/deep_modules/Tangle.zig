//! `tangle` (deep-modules U13, deslop's tangles.rs): things that know each other in a
//! circle, written in more than one module, or more of them than a reader holds in mind.
//! Where a tangle is written is its members' homes and the modules of the references that
//! tie it, so an item moved to another file with its references is still the same tangle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circle = @import("Circle.zig");
const Diagnostic = @import("Diagnostic.zig");
const Graph = @import("Graph.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const NodeId = Sources.NodeId;
const ThingId = Graph.ThingId;

/// The ties of one tangle, by the two things they tie, and the modules that write them.
const Written = struct {
    modules: std.AutoArrayHashMapUnmanaged(NodeId, void) = .empty,
    ties: std.AutoArrayHashMapUnmanaged(Pair, Circle.Tie) = .empty,
};

const Pair = struct { user: ThingId, used: ThingId };

/// The tangle diagnostics of `graph`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, graph: *const Graph.Graph, scope: ?NodeId) Allocator.Error![]const Diagnostic.Diagnostic {
    const written = try arena.alloc(Written, graph.tangles.len);
    for (written, graph.tangles) |*slot, members| {
        slot.* = .{};
        for (members) |member| try slot.modules.put(arena, graph.things[@backingInt(member)].home, {});
    }
    for (graph.uses) |usage| {
        const user = usage.user orelse continue;
        const used = graph.thing_of[@backingInt(usage.item)] orelse continue;
        if (user == used) continue;
        const tangle = graph.tangle_of[@backingInt(user)] orelse continue;
        if (graph.tangle_of[@backingInt(used)] != tangle) continue;
        const reference = refs[usage.reference];
        const slot = &written[@backingInt(tangle)];
        try slot.modules.put(arena, reference.from, {});
        const found = try slot.ties.getOrPut(arena, .{ .user = user, .used = used });
        if (!found.found_existing) found.value_ptr.* = .{};
        try found.value_ptr.add(arena, usage.item, reference.holder, Circle.siteOf(sources, reference), reference.from);
    }

    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    for (written, graph.tangles) |*slot, members| {
        if (!concerned(sources, graph, members, scope)) continue;
        if (slot.modules.count() <= 1 and members.len <= Diagnostic.held_in_mind) continue;
        try found.append(arena, try diagnostic(arena, sources, items, graph, members, slot));
    }
    return found.items;
}

fn concerned(sources: *const Sources, graph: *const Graph.Graph, members: []const ThingId, scope: ?NodeId) bool {
    const within = scope orelse return true;
    for (members) |member| {
        if (sources.isWithin(graph.things[@backingInt(member)].home, within)) return true;
    }
    return false;
}

fn diagnostic(arena: Allocator, sources: *const Sources, items: *const Items.Items, graph: *const Graph.Graph, members: []const ThingId, written: *const Written) Allocator.Error!Diagnostic.Diagnostic {
    const names = try arena.alloc([]const u8, members.len);
    for (members, names) |member, *slot| slot.* = try fullName(arena, sources, items, graph, member);
    std.mem.sort([]const u8, names, {}, Circle.lessText);

    var labels: std.ArrayList([]const u8) = .empty;
    for (written.modules.keys()) |module| try labels.append(arena, Circle.moduleLabel(sources, module));
    std.mem.sort([]const u8, labels.items, {}, Circle.lessText);

    const keys = written.ties.keys();
    const values = written.ties.values();
    const named = try arena.alloc(Circle.Named, keys.len);
    for (keys, values, named) |pair, *tie, *slot| {
        slot.* = .{
            .user = try fullName(arena, sources, items, graph, pair.user),
            .used = try fullName(arena, sources, items, graph, pair.used),
            .tie = tie,
        };
    }
    const report = try Circle.report(arena, items, "knows", "thing", members.len, named);

    var notes: std.ArrayList([]const u8) = .empty;
    try notes.append(arena, try std.fmt.allocPrint(arena, "members: {s}", .{try Circle.listed(arena, names)}));
    if (labels.items.len > 1) {
        try notes.append(arena, try std.fmt.allocPrint(arena, "written in: {s}", .{try Circle.listed(arena, labels.items)}));
    }
    try notes.appendSlice(arena, report.notes);

    const message = if (labels.items.len == 1)
        try std.fmt.allocPrint(arena, "{d} things know each other in a circle, all in `{s}`", .{ members.len, labels.items[0] })
    else
        try std.fmt.allocPrint(arena, "{d} things know each other in a circle, across {s}", .{ members.len, try Circle.counted(arena, labels.items.len, "module") });
    return .{
        .lint = .tangle,
        .key = try std.mem.join(arena, ",", names),
        .message = message,
        .location = report.location,
        .notes = notes.items,
        .picture = report.picture,
    };
}

/// `Thing.Holder`: a thing's module, then its name there.
fn fullName(arena: Allocator, sources: *const Sources, items: *const Items.Items, graph: *const Graph.Graph, thing: ThingId) Allocator.Error![]const u8 {
    const found = graph.things[@backingInt(thing)];
    const name = try Circle.itemName(arena, items, found.item);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ Circle.moduleLabel(sources, found.home), name });
}

const testing = std.testing;
const Fixture = @import("Fixture.zig");
const Wrappers = @import("Wrappers.zig");

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    var wrappers = try Wrappers.find(arena, &loaded.items, &loaded.sources, refs);
    const graph = try Graph.build(arena, &loaded.items, refs, &wrappers);
    return check(arena, &loaded.sources, &loaded.items, refs, &graph, null);
}

test "two things that know each other, written in two files, are a tangle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try checked(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n" },
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub const A = struct {\n    n: u8,\n    pub fn fetch(other: *b.B) u8 { return other.m; }\n};\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub const B = struct {\n    m: u8,\n    pub fn make(x: *a.A) u8 { return x.n; }\n};\n" },
    });
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("a.A,b.B", got[0].key);
    try testing.expectEqualStrings("2 things know each other in a circle, across 2 modules", got[0].message);
    try testing.expectEqualStrings("written in: a, b", got[0].notes[1]);
}

test "two things that know each other, written in one file, are no tangle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try checked(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\n" },
        .{ .path = "src/a.zig", .text = "pub const A = struct {\n    n: u8,\n    pub fn fetch(other: *B) u8 { return other.m; }\n};\npub const B = struct {\n    m: u8,\n    pub fn make(x: *A) u8 { return x.n; }\n};\n" },
    });
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "eight things in a circle in one file are a tangle, too many to hold in mind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..8) |index| {
        try text.print(a, "pub const T{d} = struct {{\n    n: u8,\n    pub fn link(other: *T{d}) u8 {{ return other.n; }}\n}};\n", .{ index, (index + 1) % 8 });
    }
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\n" },
        .{ .path = "src/a.zig", .text = text.items },
    });
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("a.T0,a.T1,a.T2,a.T3,a.T4,a.T5,a.T6,a.T7", got[0].key);
    try testing.expectEqualStrings("8 things know each other in a circle, all in `a`", got[0].message);
}

test "a wrapper's own references are no ties, so a forwarder does not close a circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `peek` only forwards to `B.value` through `combine`; its parameter names `B`. Without
    // the wrapper rule, `A` would know `B` and `B` knows `A`: a tangle written in two files.
    const got = try checked(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n" },
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub const Inner = struct {\n    n: u8,\n    pub fn combine(self: *Inner, other: anytype) u8 { _ = other; return self.n; }\n};\npub const A = struct {\n    inner: Inner,\n    pub fn peek(self: *A, other: *b.B) u8 { return self.inner.combine(other); }\n};\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub const B = struct {\n    m: u8,\n    pub fn make(x: *a.A) u8 { return x.inner.n; }\n};\n" },
    });
    try testing.expectEqual(@as(usize, 0), got.len);
}
