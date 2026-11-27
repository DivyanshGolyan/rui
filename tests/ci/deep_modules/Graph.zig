//! Who knows what (deep-modules U11, deslop's graph): a thing is a type with everything
//! written for it, a free function, or a free constant that is not an alias. A use is a
//! reference from production code to an item of a thing, seen through wrappers: a use of
//! a forwarder is a use of what is behind it, and a wrapper's own references are no use.
//! Things that know each other in a circle are a tangle.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Components = @import("Components.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const Wrappers = @import("Wrappers.zig");
const ItemId = Items.ItemId;

pub const ThingId = enum(u32) { _ };
pub const TangleId = enum(u32) { _ };

/// The type, function or constant a thing is named by, and the module it is defined in,
/// which is also the home of its fields and methods.
pub const Thing = struct { item: ItemId, home: Sources.NodeId };

/// An item that a reference uses, past wrappers.
pub const Use = struct {
    /// The reference, by its place in the references.
    reference: u32,
    /// The thing whose code holds the reference.
    user: ?ThingId,
    /// What is used, past wrappers.
    item: ItemId,
    /// The wrapper the reference names, if it names one.
    through: ?ItemId,
    /// For a field: the user only reads its value.
    copies: bool,
};

pub const Graph = struct {
    things: []const Thing,
    /// By ItemId: the thing each item is part of.
    thing_of: []const ?ThingId,
    uses: []const Use,
    /// Each set of two or more things that know each other in a circle.
    tangles: []const []const ThingId,
    /// By ThingId: the tangle each thing is in.
    tangle_of: []const ?TangleId,
};

pub const WrapperMap = std.AutoHashMapUnmanaged(ItemId, Wrappers.Wrapper);

/// The most wrappers followed in one chain. A chain of forwarders that calls itself has no end.
const max_hops = 64;

/// The things, uses and tangles of a program whose references and wrappers are given.
pub fn build(arena: Allocator, items: *const Items.Items, references: []const References.Reference, wrappers: *const WrapperMap) Allocator.Error!Graph {
    const assigned = try assignThings(arena, items);
    const uses = try collectUses(arena, items, references, wrappers, assigned.thing_of);
    const tangled = try tangleOf(arena, assigned.things.len, uses, assigned.thing_of);
    return .{
        .things = assigned.things,
        .thing_of = assigned.thing_of,
        .uses = uses,
        .tangles = tangled.tangles,
        .tangle_of = tangled.tangle_of,
    };
}

/// The thing that `id` is part of, or null when it is no thing's part. A type is a thing
/// itself, and a function, constant or field belongs to the type around it. A free function
/// or constant under a namespace is a thing of its own. Aliases and namespaces are no thing.
fn rootOf(items: *const Items.Items, id: ItemId) ?ItemId {
    var current = id;
    while (true) {
        const item = items.get(current);
        switch (item.kind) {
            .type => return current,
            .alias, .namespace => return null,
            .function, .constant, .field => {},
        }
        const parent = item.parent orelse return current;
        if (items.get(parent).kind != .type) return current;
        current = parent;
    }
}

const Assigned = struct { things: []const Thing, thing_of: []const ?ThingId };

fn assignThings(arena: Allocator, items: *const Items.Items) Allocator.Error!Assigned {
    const thing_of = try arena.alloc(?ThingId, items.list.len);
    const thing_at = try arena.alloc(?ThingId, items.list.len);
    @memset(thing_at, null);
    var things: std.ArrayList(Thing) = .empty;
    for (thing_of, 0..) |*slot, index| {
        const root = rootOf(items, @fromBackingInt(@intCast(index))) orelse {
            slot.* = null;
            continue;
        };
        const at = &thing_at[@backingInt(root)];
        if (at.* == null) {
            at.* = @fromBackingInt(@intCast(things.items.len));
            try things.append(arena, .{ .item = root, .home = items.get(root).home });
        }
        slot.* = at.*;
    }
    return .{ .things = things.items, .thing_of = thing_of };
}

/// One item that a reference reaches, and whether the reference only reads it.
const Hop = struct { item: ItemId, copies: bool };

fn collectUses(arena: Allocator, items: *const Items.Items, references: []const References.Reference, wrappers: *const WrapperMap, thing_of: []const ?ThingId) Allocator.Error![]const Use {
    var uses: std.ArrayList(Use) = .empty;
    var hops: std.ArrayList(Hop) = .empty;
    for (references, 0..) |reference, index| {
        if (wrappers.contains(reference.holder)) continue;
        const user = thing_of[@backingInt(reference.holder)];
        const through: ?ItemId = if (wrappers.contains(reference.item)) reference.item else null;
        const copies = copiesOf(items, wrappers, reference);
        hops.clearRetainingCapacity();
        try behind(arena, wrappers, reference, copies, &hops);
        for (hops.items) |hop| {
            if (thing_of[@backingInt(hop.item)] == null) continue;
            try uses.append(arena, .{
                .reference = @intCast(index),
                .user = user,
                .item = hop.item,
                .through = through,
                .copies = hop.copies,
            });
        }
    }
    return uses.items;
}

/// What `reference` uses, and whether it only reads each: the item it names, or what is
/// behind that when it is a wrapper. A forwarder's callers never see its fields, so those
/// are only read. What an accessor lends is read only where the code only reads it.
fn behind(arena: Allocator, wrappers: *const WrapperMap, reference: References.Reference, copies: bool, out: *std.ArrayList(Hop)) Allocator.Error!void {
    var at = reference.item;
    for (0..max_hops) |_| {
        const wrapper = wrappers.get(at) orelse {
            try out.append(arena, .{ .item = at, .copies = at == reference.item and copies });
            return;
        };
        switch (wrapper) {
            .forwarder => |forward| {
                for (forward.fields) |field| try out.append(arena, .{ .item = field, .copies = true });
                at = forward.target;
            },
            .accessor => |access| {
                for (access.lent) |field| try out.append(arena, .{ .item = field, .copies = copies });
                for (access.copied) |field| try out.append(arena, .{ .item = field, .copies = true });
                return;
            },
        }
    }
    try out.append(arena, .{ .item = at, .copies = false });
}

/// Whether a reference only reads what it reaches: a copy of a field, a borrow of plain
/// data, a method call on a number, or a call of a method that takes its receiver by value or
/// by const pointer. A call of an accessor that lends to read counts
/// what it lends, directly or through forwarders.
fn copiesOf(items: *const Items.Items, wrappers: *const WrapperMap, reference: References.Reference) bool {
    if (items.get(reference.item).kind == .field) return onlyReads(items, reference.access, &.{reference.item}, reference.callee);
    var called = reference.item;
    for (0..max_hops) |_| {
        const wrapper = wrappers.get(called) orelse break;
        switch (wrapper) {
            .forwarder => |forward| called = forward.target,
            .accessor => break,
        }
    }
    const wrapper = wrappers.get(called) orelse return false;
    return switch (wrapper) {
        .accessor => |access| access.to_read and access.lent.len > 0 and onlyReads(items, reference.access, access.lent, null),
        .forwarder => false,
    };
}

fn onlyReads(items: *const Items.Items, access: References.Access, fields: []const ItemId, callee: ?ItemId) bool {
    if (access == .reach or access == .assign) return false;
    for (fields) |field| {
        const plain = items.get(field).plain;
        const reads = switch (access) {
            .copy => true,
            .borrow => plain != .no,
            .call => plain == .scalar or (callee != null and items.get(callee.?).readsReceiver()),
            .reach, .assign => false,
        };
        if (!reads) return false;
    }
    return true;
}

const Tangles = struct { tangles: []const []const ThingId, tangle_of: []const ?TangleId };

fn tangleOf(arena: Allocator, thing_count: usize, uses: []const Use, thing_of: []const ?ThingId) Allocator.Error!Tangles {
    const knows = try arena.alloc(std.ArrayList(u32), thing_count);
    for (knows) |*list| list.* = .empty;
    for (uses) |usage| {
        const user = usage.user orelse continue;
        const used = thing_of[@backingInt(usage.item)] orelse continue;
        if (user == used) continue;
        try knows[@backingInt(user)].append(arena, @backingInt(used));
    }
    const edges = try arena.alloc([]const u32, thing_count);
    for (knows, edges) |list, *slot| slot.* = list.items;
    const found = try Components.circles(arena, edges);

    const tangles = try arena.alloc([]const ThingId, found.len);
    const tangle_of = try arena.alloc(?TangleId, thing_count);
    @memset(tangle_of, null);
    for (found, tangles, 0..) |members, *slot, index| {
        const list = try arena.alloc(ThingId, members.len);
        for (members, list) |member, *thing| thing.* = @fromBackingInt(member);
        slot.* = list;
        for (list) |thing| tangle_of[@backingInt(thing)] = @fromBackingInt(@intCast(index));
    }
    return .{ .tangles = tangles, .tangle_of = tangle_of };
}

const testing = std.testing;
const Fixture = @import("Fixture.zig");

fn thingOf(graph: Graph, item: ItemId) ?ThingId {
    return graph.thing_of[@backingInt(item)];
}

test "a method is part of its type, a nested type is a thing of its own, a namespace is none of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try Fixture.load(a, &.{.{ .path = "src/main.zig", .text =
        \\pub const Holder = struct {
        \\    n: u8,
        \\    pub const Kind = struct { k: u8 };
        \\    pub const limit = 3;
        \\    pub fn get(self: *Holder) u8 { return self.n; }
        \\};
        \\pub const ns = struct { pub fn helper() u8 { return 1; } };
        \\pub const alias = Holder;
        \\pub const flag = true;
        \\
    }}, "src/main.zig");
    const refs = try References.collect(a, &loaded.sources, &loaded.items);
    var wrappers: WrapperMap = .empty;
    const graph = try build(a, &loaded.items, refs, &wrappers);

    try testing.expectEqual(@as(usize, 4), graph.things.len);
    const holder = loaded.item("src/main.zig", "Holder");
    const kind = loaded.item("src/main.zig", "Holder.Kind");
    try testing.expectEqual(holder, graph.things[0].item);
    try testing.expectEqual(kind, graph.things[1].item);
    try testing.expectEqual(loaded.item("src/main.zig", "ns.helper"), graph.things[2].item);
    try testing.expectEqual(loaded.item("src/main.zig", "flag"), graph.things[3].item);

    try testing.expectEqual(thingOf(graph, holder), thingOf(graph, loaded.item("src/main.zig", "Holder.get")));
    try testing.expectEqual(thingOf(graph, holder), thingOf(graph, loaded.item("src/main.zig", "Holder.limit")));
    try testing.expectEqual(thingOf(graph, kind), thingOf(graph, loaded.item("src/main.zig", "Holder.Kind.k")));
    try testing.expectEqual(@as(?ThingId, null), thingOf(graph, loaded.item("src/main.zig", "ns")));
    try testing.expectEqual(@as(?ThingId, null), thingOf(graph, loaded.item("src/main.zig", "alias")));
    try testing.expectEqual(@as(usize, 0), graph.tangles.len);
}

test "a use of a forwarder is a use of what is behind it, and the forwarder's own body is no use" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try Fixture.load(a, &.{.{ .path = "src/main.zig", .text =
        \\const Queue = struct {
        \\    inner: Inner,
        \\    pub fn items(self: *Queue) u8 { return self.inner.size(); }
        \\};
        \\const Inner = struct {
        \\    n: u8,
        \\    pub fn size(self: *Inner) u8 { return self.n; }
        \\};
        \\pub fn report(q: *Queue) u8 { return q.items(); }
        \\
    }}, "src/main.zig");
    const refs = try References.collect(a, &loaded.sources, &loaded.items);
    var wrappers = try Wrappers.find(a, &loaded.items, &loaded.sources, refs);
    const graph = try build(a, &loaded.items, refs, &wrappers);

    const items = loaded.item("src/main.zig", "Queue.items");
    const inner = loaded.item("src/main.zig", "Queue.inner");
    const n = loaded.item("src/main.zig", "Inner.n");
    const report = loaded.item("src/main.zig", "report");
    const queue = graph.thing_of[@backingInt(inner)];
    var forwarded: usize = 0;
    var from_queue: usize = 0;
    for (graph.uses) |usage| {
        if (usage.through) |through| {
            try testing.expectEqual(items, through);
            try testing.expect(usage.copies);
            try testing.expectEqual(graph.thing_of[@backingInt(report)], usage.user);
            try testing.expect(usage.item == inner or usage.item == n);
            forwarded += 1;
        }
        if (usage.user == queue) {
            // Only the field type `inner: Inner` is a use by Queue; the wrapper's body is no use.
            try testing.expectEqual(@as(?ItemId, null), usage.through);
            try testing.expectEqual(loaded.item("src/main.zig", "Inner"), usage.item);
            from_queue += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), forwarded);
    try testing.expectEqual(@as(usize, 1), from_queue);
}
