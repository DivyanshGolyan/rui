//! `module-cycle` (deep-modules U12, deslop's cycles.rs): sibling modules that use each
//! other in a circle, so there is no order to read them in. A module uses a sibling when
//! code written in it or inside it names an item written in the sibling or inside it. What
//! a module and the modules inside it use of each other makes no circle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circle = @import("Circle.zig");
const Components = @import("Components.zig");
const Diagnostic = @import("Diagnostic.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const NodeId = Sources.NodeId;

/// The sibling pair under `parent`: the child that holds the user and the child that holds the used item.
const Key = struct { parent: NodeId, user: NodeId, used: NodeId };

const Entry = struct { key: Key, tie: *const Circle.Tie };

/// The module-cycle diagnostics of `refs`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, scope: ?NodeId) Allocator.Error![]const Diagnostic.Diagnostic {
    var ties: std.AutoArrayHashMapUnmanaged(Key, Circle.Tie) = .empty;
    for (refs) |reference| {
        const item = items.get(reference.item);
        if (item.parent == null) continue; // a file: it is a module, not an item a module uses
        const split = sources.commonParent(reference.from, item.home) orelse continue;
        const key: Key = .{ .parent = split.parent, .user = split.a, .used = split.b };
        const found = try ties.getOrPut(arena, key);
        if (!found.found_existing) found.value_ptr.* = .{};
        try found.value_ptr.add(arena, reference.item, reference.holder, Circle.siteOf(sources, reference), split.a);
    }

    const entries = try arena.alloc(Entry, ties.count());
    for (entries, ties.keys(), ties.values()) |*entry, key, *tie| entry.* = .{ .key = key, .tie = tie };
    std.mem.sort(Entry, entries, {}, lessEntry);

    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    var begin: usize = 0;
    while (begin < entries.len) {
        var end = begin + 1;
        while (end < entries.len and entries[end].key.parent == entries[begin].key.parent) end += 1;
        try checkChildren(arena, sources, items, entries[begin..end], scope, &found);
        begin = end;
    }
    return found.items;
}

/// The circles among the children of one parent, given the ties between them, sorted by key.
fn checkChildren(arena: Allocator, sources: *const Sources, items: *const Items.Items, group: []const Entry, scope: ?NodeId, found: *std.ArrayList(Diagnostic.Diagnostic)) Allocator.Error!void {
    var children: std.ArrayList(NodeId) = .empty;
    for (group) |entry| {
        if (!contains(children.items, entry.key.user)) try children.append(arena, entry.key.user);
        if (!contains(children.items, entry.key.used)) try children.append(arena, entry.key.used);
    }
    std.mem.sort(NodeId, children.items, {}, lessNode);

    const out = try arena.alloc(std.ArrayList(u32), children.items.len);
    for (out) |*list| list.* = .empty;
    for (group) |entry| {
        const user = std.mem.indexOfScalar(NodeId, children.items, entry.key.user).?;
        const used = std.mem.indexOfScalar(NodeId, children.items, entry.key.used).?;
        try out[user].append(arena, @intCast(used));
    }
    const edges = try arena.alloc([]const u32, out.len);
    for (out, edges) |list, *slot| slot.* = list.items;

    for (try Components.circles(arena, edges)) |circle| {
        const members = try arena.alloc(NodeId, circle.len);
        for (circle, members) |at, *slot| slot.* = children.items[at];
        if (!anyInScope(sources, members, scope)) continue;
        try found.append(arena, try diagnostic(arena, sources, items, group, members));
    }
}

fn diagnostic(arena: Allocator, sources: *const Sources, items: *const Items.Items, group: []const Entry, members: []const NodeId) Allocator.Error!Diagnostic.Diagnostic {
    const paths = try arena.alloc([]const u8, members.len);
    const names = try arena.alloc([]const u8, members.len);
    for (members, paths, names) |member, *path, *name| {
        path.* = sources.display(member);
        name.* = nodeName(sources, member);
    }
    std.mem.sort([]const u8, paths, {}, Circle.lessText);
    std.mem.sort([]const u8, names, {}, Circle.lessText);

    var inside: std.ArrayList(Circle.Named) = .empty;
    for (group) |entry| {
        if (!contains(members, entry.key.user) or !contains(members, entry.key.used)) continue;
        try inside.append(arena, .{ .user = nodeName(sources, entry.key.user), .used = nodeName(sources, entry.key.used), .tie = entry.tie });
    }
    const report = try Circle.report(arena, items, "uses", "module", members.len, inside.items);

    var notes: std.ArrayList([]const u8) = .empty;
    try notes.append(arena, try std.fmt.allocPrint(arena, "members: {s}", .{try Circle.listed(arena, names)}));
    try notes.appendSlice(arena, report.notes);
    const parent = group[0].key.parent;
    const count = try Circle.counted(arena, members.len, "module");
    return .{
        .lint = .@"module-cycle",
        .key = try std.mem.join(arena, ",", paths),
        .message = try std.fmt.allocPrint(arena, "{s} in `{s}` use each other in a circle", .{ count, Circle.moduleLabel(sources, parent) }),
        .location = report.location,
        .notes = notes.items,
        .picture = report.picture,
    };
}

fn nodeName(sources: *const Sources, node: NodeId) []const u8 {
    return sources.nodes[@backingInt(node)].name;
}

fn contains(members: []const NodeId, node: NodeId) bool {
    return std.mem.indexOfScalar(NodeId, members, node) != null;
}

fn anyInScope(sources: *const Sources, members: []const NodeId, scope: ?NodeId) bool {
    const within = scope orelse return true;
    for (members) |member| {
        if (sources.isWithin(member, within)) return true;
    }
    return false;
}

fn lessNode(_: void, a: NodeId, b: NodeId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    const pa = @backingInt(a.key.parent);
    const pb = @backingInt(b.key.parent);
    if (pa != pb) return pa < pb;
    const ua = @backingInt(a.key.user);
    const ub = @backingInt(b.key.user);
    if (ua != ub) return ua < ub;
    return @backingInt(a.key.used) < @backingInt(b.key.used);
}

const testing = std.testing;
const Fixture = @import("Fixture.zig");
const Report = @import("Report.zig");

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    return check(arena, &loaded.sources, &loaded.items, refs, null);
}

fn expectKeys(want: []const []const u8, got: []const Diagnostic.Diagnostic) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |key, reported| try testing.expectEqualStrings(key, reported.key);
}

const main_imports_ab = Sources.Memory.Entry{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\nconst b = @import(\"b.zig\");\n" };

test "two sibling files that use each other through declarations are a circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn make() u8 { return b.value(); }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub fn value() u8 { return a.make(); }\n" },
    });
    try expectKeys(&.{"a,b"}, got);
    try testing.expectEqualStrings("2 modules in `src` use each other in a circle", got[0].message);
}

test "a method called on a value of a sibling's type is a use, so the files are a circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn run(w: *b.Widget) u8 { return w.spin(); }\npub fn helper() u8 { return 1; }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub const Widget = struct {\n    n: u8,\n    pub fn spin(self: *Widget) u8 { return self.n; }\n    pub fn back() u8 { return a.helper(); }\n};\n" },
    });
    try expectKeys(&.{"a,b"}, got);
}

test "a method on a value of unknown type is no use, so there is no circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "pub fn run(w: anytype) u8 { return w.spin(); }\npub fn helper() u8 { return 1; }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub const Widget = struct {\n    n: u8,\n    pub fn spin(self: *Widget) u8 { return self.n; }\n    pub fn back() u8 { return a.helper(); }\n};\n" },
    });
    try expectKeys(&.{}, got);
}

test "a parent file and the child files of its directory are one node, so they make no circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = "const store = @import(\"store.zig\");\n" },
        .{ .path = "src/store.zig", .text = "const x = @import(\"store/x.zig\");\npub fn open() u8 { return x.value(); }\n" },
        .{ .path = "src/store/x.zig", .text = "const s = @import(\"../store.zig\");\npub fn value() u8 { return s.open(); }\n" },
    });
    try expectKeys(&.{}, got);
}

test "an import that nothing uses is no edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn make() u8 { return 1; }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub fn value() u8 { return a.make(); }\n" },
    });
    try expectKeys(&.{}, got);
}

test "an import that only a test block uses is no edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn make() u8 { return 1; }\ntest { _ = b.value(); }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub fn value() u8 { return a.make(); }\n" },
    });
    try expectKeys(&.{}, got);
}

test "a use of a re-export is an edge to the file that defines the item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = "const a = @import(\"a.zig\");\nconst facade = @import(\"facade.zig\");\nconst keys = @import(\"keys.zig\");\n" },
        .{ .path = "src/a.zig", .text = "const facade = @import(\"facade.zig\");\npub fn make() u8 { return facade.Key.limit; }\n" },
        .{ .path = "src/facade.zig", .text = "pub const Key = @import(\"keys.zig\").Key;\n" },
        .{ .path = "src/keys.zig", .text = "const a = @import(\"a.zig\");\npub const Key = struct {\n    pub const limit = 3;\n    pub fn check() u8 { return a.make(); }\n};\n" },
    });
    try expectKeys(&.{"a,keys"}, got);
}

test "a three-module circle is reported once, with its members sorted in the key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = "const c = @import(\"c.zig\");\nconst b = @import(\"b.zig\");\nconst a = @import(\"a.zig\");\n" },
        .{ .path = "src/c.zig", .text = "const a = @import(\"a.zig\");\npub fn fc() u8 { return a.fa(); }\n" },
        .{ .path = "src/b.zig", .text = "const c = @import(\"c.zig\");\npub fn fb() u8 { return c.fc(); }\n" },
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn fa() u8 { return b.fb(); }\n" },
    });
    try expectKeys(&.{"a,b,c"}, got);
    try testing.expectEqualStrings("members: a, b, c", got[0].notes[0]);
}

test "the golden report of a two-module circle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        main_imports_ab,
        .{ .path = "src/a.zig", .text = "const b = @import(\"b.zig\");\npub fn make() u8 { return b.value(); }\n" },
        .{ .path = "src/b.zig", .text = "const a = @import(\"a.zig\");\npub fn value() u8 { return a.make(); }\n" },
    });
    var out: std.Io.Writer.Allocating = .init(a);
    try Report.render(&out.writer, got[0]);
    const want =
        \\error[module-cycle]: 2 modules in `src` use each other in a circle
        \\  --> src/a.zig:2:29
        \\  = note: members: a, b
        \\  = note: src/a.zig:2:29: `a` uses `b` by 1 item: value
        \\  = note: src/b.zig:2:30: `b` uses `a` by 1 item: make
        \\    ┌─▶ a
        \\    │     ┃ a.zig:2  make uses value
        \\    │     ▼
        \\    │   b
        \\    │     │ b.zig:2  value uses make
        \\    └─────┘
        \\
    ;
    try testing.expectEqualStrings(want, out.written());
}
