//! `shallow-module` (deep-modules U15, deslop's shallow.rs): a module that shows more functions
//! than a reader holds in mind, at least as many as it hides, through a list that is too long:
//! more things, or more functions of one thing. Every file and directory under `src` is judged
//! except `src` itself. A thing's functions are its methods and the free functions that use it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circle = @import("Circle.zig");
const Diagnostic = @import("Diagnostic.zig");
const Graph = @import("Graph.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const NodeId = Sources.NodeId;
const ThingId = Graph.ThingId;

/// What a module hides per function it shows, at break-even: a module is shallow when it hides no more than it shows.
const break_even = 1;

/// The shallow-module diagnostics of `graph`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, graph: *const Graph.Graph, wrappers: *const Graph.WrapperMap, scope: ?NodeId) Allocator.Error![]const Diagnostic.Diagnostic {
    var total: std.AutoArrayHashMapUnmanaged(NodeId, usize) = .empty;
    for (0..items.list.len) |index| {
        const item: ItemId = @fromBackingInt(@intCast(index));
        if (!working(items, wrappers, item)) continue;
        const thing = graph.thing_of[index] orelse continue;
        var module: ?NodeId = graph.things[@backingInt(thing)].home;
        while (module) |node| : (module = sources.parent(node)) {
            if (node == Sources.top) break;
            const found = try total.getOrPut(arena, node);
            if (!found.found_existing) found.value_ptr.* = 0;
            found.value_ptr.* += 1;
        }
    }

    var shown: std.AutoArrayHashMapUnmanaged(NodeId, std.AutoArrayHashMapUnmanaged(ItemId, void)) = .empty;
    for (graph.uses) |usage| {
        if (!working(items, wrappers, usage.item)) continue;
        const thing = graph.thing_of[@backingInt(usage.item)] orelse continue;
        const user = if (usage.user) |user| graph.things[@backingInt(user)].home else refs[usage.reference].from;
        var module: ?NodeId = graph.things[@backingInt(thing)].home;
        while (module) |node| : (module = sources.parent(node)) {
            if (sources.isWithin(user, node)) break;
            if (node == Sources.top) continue;
            const found = try shown.getOrPut(arena, node);
            if (!found.found_existing) found.value_ptr.* = .empty;
            try found.value_ptr.put(arena, usage.item, {});
        }
    }

    const known = try typesKnown(arena, items, graph);
    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    for (1..sources.nodes.len) |index| {
        const module: NodeId = @fromBackingInt(@intCast(index));
        const shows = shown.get(module) orelse continue;
        const shown_count = shows.count();
        const total_count = total.get(module) orelse 0;
        const hidden = total_count -| shown_count;
        const lists = try listsOf(arena, items, graph, &known, sources, module, shows);
        const too_long = try tooLong(arena, lists);
        if (shown_count <= Diagnostic.held_in_mind or too_long.notes.len == 0 or hidden > shown_count * break_even) continue;
        if (scope) |within| if (!sources.isWithin(module, within)) continue;
        const name = sources.display(module);
        try found.append(arena, .{
            .lint = .@"shallow-module",
            .key = name,
            .message = try std.fmt.allocPrint(arena, "`{s}` is shallow: it shows {d} of its {s}", .{ name, shown_count, try Circle.counted(arena, total_count, "function") }),
            .location = location(sources, module),
            .notes = too_long.notes,
            .picture = .{ .lists = .{ .shown = shown_count, .hidden = hidden, .lists = too_long.long } },
        });
    }
    return found.items;
}

/// Whether `item` is a function that is not a wrapper: one that does work of its own.
fn working(items: *const Items.Items, wrappers: *const Graph.WrapperMap, item: ItemId) bool {
    return items.get(item).kind == .function and !wrappers.contains(item);
}

/// The types each free function's code uses, by the thing of each function that is a thing of its own.
fn typesKnown(arena: Allocator, items: *const Items.Items, graph: *const Graph.Graph) Allocator.Error!std.AutoArrayHashMapUnmanaged(ThingId, std.AutoArrayHashMapUnmanaged(ThingId, void)) {
    var known: std.AutoArrayHashMapUnmanaged(ThingId, std.AutoArrayHashMapUnmanaged(ThingId, void)) = .empty;
    for (graph.uses) |usage| {
        const user = usage.user orelse continue;
        const used = graph.thing_of[@backingInt(usage.item)] orelse continue;
        if (items.get(graph.things[@backingInt(user)].item).kind != .function) continue;
        if (items.get(graph.things[@backingInt(used)].item).kind != .type) continue;
        const found = try known.getOrPut(arena, user);
        if (!found.found_existing) found.value_ptr.* = .empty;
        try found.value_ptr.put(arena, used, {});
    }
    return known;
}

/// One list a reader learns a module by: a thing, and the names of its functions there.
const List = struct { thing: []const u8, functions: [][]const u8 };

/// The lists of what `module` shows, most functions first, then by thing's name. A method is on its type's
/// list; a free function is on the list of each type of `module` it knows, or on its own when it knows none.
fn listsOf(arena: Allocator, items: *const Items.Items, graph: *const Graph.Graph, known: *const std.AutoArrayHashMapUnmanaged(ThingId, std.AutoArrayHashMapUnmanaged(ThingId, void)), sources: *const Sources, module: NodeId, shown: std.AutoArrayHashMapUnmanaged(ItemId, void)) Allocator.Error![]List {
    var by_thing: std.AutoArrayHashMapUnmanaged(ThingId, std.ArrayList([]const u8)) = .empty;
    for (shown.keys()) |function| {
        const thing = graph.thing_of[@backingInt(function)] orelse continue;
        const name = items.get(function).name;
        var placed = false;
        if (graph.things[@backingInt(thing)].item == function) {
            if (known.get(thing)) |types| {
                for (types.keys()) |ty| {
                    if (!sources.isWithin(graph.things[@backingInt(ty)].home, module)) continue;
                    try addTo(arena, &by_thing, ty, name);
                    placed = true;
                }
            }
        }
        if (!placed) try addTo(arena, &by_thing, thing, name);
    }
    const lists = try arena.alloc(List, by_thing.count());
    for (by_thing.keys(), by_thing.values(), lists) |thing, functions, *slot| {
        std.mem.sort([]const u8, functions.items, {}, Circle.lessText);
        slot.* = .{ .thing = try Circle.itemName(arena, items, graph.things[@backingInt(thing)].item), .functions = functions.items };
    }
    std.mem.sort(List, lists, {}, lessList);
    return lists;
}

fn addTo(arena: Allocator, by_thing: *std.AutoArrayHashMapUnmanaged(ThingId, std.ArrayList([]const u8)), thing: ThingId, name: []const u8) Allocator.Error!void {
    const found = try by_thing.getOrPut(arena, thing);
    if (!found.found_existing) found.value_ptr.* = .empty;
    try found.value_ptr.append(arena, name);
}

fn lessList(_: void, a: List, b: List) bool {
    if (a.functions.len != b.functions.len) return a.functions.len > b.functions.len;
    return std.mem.lessThan(u8, a.thing, b.thing);
}

const TooLong = struct { notes: []const []const u8, long: []const Diagnostic.Tally };

/// A note for the list of things when it is too long, then for each thing whose functions are: each such list's
/// name and length, `things` for the list of things.
fn tooLong(arena: Allocator, lists: []const List) Allocator.Error!TooLong {
    var notes: std.ArrayList([]const u8) = .empty;
    var long: std.ArrayList(Diagnostic.Tally) = .empty;
    if (lists.len > Diagnostic.held_in_mind) {
        const names = try arena.alloc([]const u8, lists.len);
        for (lists, names) |list, *slot| slot.* = list.thing;
        try notes.append(arena, try std.fmt.allocPrint(arena, "shows {s}: {s}", .{ try Circle.counted(arena, lists.len, "thing"), try Circle.listed(arena, names) }));
        try long.append(arena, .{ .count = lists.len, .name = "things" });
    }
    for (lists) |list| {
        if (list.functions.len <= Diagnostic.held_in_mind) continue;
        try notes.append(arena, try std.fmt.allocPrint(arena, "`{s}` shows {s}: {s}", .{ list.thing, try Circle.counted(arena, list.functions.len, "function"), try Circle.listed(arena, list.functions) }));
        try long.append(arena, .{ .count = list.functions.len, .name = list.thing });
    }
    return .{ .notes = notes.items, .long = long.items };
}

/// The first line of `module`'s own file, when it has one.
fn location(sources: *const Sources, module: NodeId) ?Diagnostic.Location {
    const own = sources.nodes[@backingInt(module)].own_file orelse return null;
    return .{ .file = sources.files[@backingInt(own)].path, .line = 1, .column = 1 };
}

const testing = std.testing;
const Fixture = @import("Fixture.zig");
const Report = @import("Report.zig");
const Wrappers = @import("Wrappers.zig");

const main_text = "const store = @import(\"store.zig\");\nconst app = @import(\"app.zig\");\n";

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    var wrappers = try Wrappers.find(arena, &loaded.items, &loaded.sources, refs);
    const graph = try Graph.build(arena, &loaded.items, refs, &wrappers);
    return check(arena, &loaded.sources, &loaded.items, refs, &graph, &wrappers, null);
}

/// `store.zig` with a `Store` of `shown` methods, which `app.zig` calls, and `hidden` that nothing calls.
fn storeEntries(arena: Allocator, shown: usize, hidden: usize) ![]const Sources.Memory.Entry {
    var store: std.ArrayList(u8) = .empty;
    var app: std.ArrayList(u8) = .empty;
    try store.appendSlice(arena, "pub const Store = struct {\n    n: u8,\n");
    try app.appendSlice(arena, "const store = @import(\"store.zig\");\npub fn run(s: *store.Store) u8 {\n    var total: u8 = 0;\n");
    for (0..shown) |i| {
        try store.print(arena, "    pub fn m{d}(self: *Store) u8 {{\n        return self.n + {d};\n    }}\n", .{ i, i });
        try app.print(arena, "    total += s.m{d}();\n", .{i});
    }
    for (0..hidden) |i| try store.print(arena, "    fn h{d}(self: *Store) u8 {{\n        return self.n + {d};\n    }}\n", .{ i, i });
    try store.appendSlice(arena, "};\n");
    try app.appendSlice(arena, "    return total;\n}\n");
    return arena.dupe(Sources.Memory.Entry, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/store.zig", .text = store.items },
        .{ .path = "src/app.zig", .text = app.items },
    });
}

/// `store.zig` with `count` small types `T{i}`, each with one method, which `app.zig` calls.
fn typesEntries(arena: Allocator, count: usize) ![]const Sources.Memory.Entry {
    var store: std.ArrayList(u8) = .empty;
    var app: std.ArrayList(u8) = .empty;
    try app.appendSlice(arena, "const store = @import(\"store.zig\");\npub fn run(");
    for (0..count) |i| {
        try store.print(arena, "pub const T{d} = struct {{\n    n: u8,\n    pub fn m(self: *T{d}) u8 {{\n        return self.n + 1;\n    }}\n}};\n", .{ i, i });
        try app.print(arena, "{s}t{d}: *store.T{d}", .{ if (i == 0) "" else ", ", i, i });
    }
    try app.appendSlice(arena, ") u8 {\n    return 0");
    for (0..count) |i| try app.print(arena, " +% t{d}.m()", .{i});
    try app.appendSlice(arena, ";\n}\n");
    return arena.dupe(Sources.Memory.Entry, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/store.zig", .text = store.items },
        .{ .path = "src/app.zig", .text = app.items },
    });
}

fn shallowKeys(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const []const u8 {
    const got = try checked(arena, entries);
    const keys = try arena.alloc([]const u8, got.len);
    for (got, keys) |d, *slot| slot.* = d.key;
    return keys;
}

test "eight functions shown of thirteen, one type's list of eight, is shallow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try shallowKeys(a, try storeEntries(a, 8, 5));
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("store", keys[0]);
}

test "eight functions shown across eight small types is shallow, through the list of things" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, try typesEntries(a, 8));
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("store", got[0].key);
    try testing.expectEqual(@as(usize, 1), got[0].notes.len);
    try testing.expectEqualStrings("shows 8 things: T0, T1, T2, T3, T4, T5, T6, +1 more", got[0].notes[0]);
}

test "eight shown and nine hidden is not shallow, since a reader learns as much as it is told" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try shallowKeys(a, try storeEntries(a, 8, 9))).len);
}

test "seven functions shown is not shallow, whatever is hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try shallowKeys(a, try storeEntries(a, 7, 0))).len);
    try testing.expectEqual(@as(usize, 0), (try shallowKeys(a, try storeEntries(a, 7, 40))).len);
}

test "the report of a shallow module shows its functions shown and hidden against the line of seven" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, try storeEntries(a, 8, 5));
    var out: std.Io.Writer.Allocating = .init(a);
    try Report.render(&out.writer, got[0]);
    const want =
        \\error[shallow-module]: `store` is shallow: it shows 8 of its 13 functions
        \\  --> src/store.zig:1:1
        \\  = note: `Store` shows 8 functions: m0, m1, m2, m3, m4, m5, m6, +1 more
        \\                  7
        \\    shows  ███████│█ 8
        \\    hides  █████  │ 5
        \\    Store  ███████│█ 8
        \\
    ;
    try testing.expectEqualStrings(want, out.written());
}
