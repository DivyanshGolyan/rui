//! `field-leak` (deep-modules U14, deslop's leaks.rs): code that works on a field of a type
//! it is not part of. A type guards its fields when it keeps one to itself and has a method
//! with a `self` parameter, not a wrapper, that uses its fields. Then each of its fields that
//! code outside the type and its tangle writes, borrows, indexes or calls a method on, directly
//! or through a getter, is known outside it. Reading a value is no leak. Fields that hold
//! nothing play no part.

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

/// The uses of each field by code outside its type and tangle, by index into `graph.uses`.
const Outside = std.AutoArrayHashMapUnmanaged(ItemId, std.ArrayList(u32));

/// The field-leak diagnostics of `graph`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, graph: *const Graph.Graph, scope: ?NodeId) Allocator.Error![]const Diagnostic.Diagnostic {
    const fields = try fieldsByThing(arena, items, graph);
    var outside: Outside = .empty;
    const working = try arena.alloc(bool, graph.things.len);
    @memset(working, false);
    for (graph.uses, 0..) |usage, index| {
        if (items.get(usage.item).kind != .field) continue;
        const owner = graph.thing_of[@backingInt(usage.item)] orelse continue;
        const tangle = graph.tangle_of[@backingInt(owner)];
        const insider = if (usage.user) |user|
            user == owner or (tangle != null and graph.tangle_of[@backingInt(user)] == tangle)
        else
            false;
        if (!insider) {
            const slot = try outside.getOrPut(arena, usage.item);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(arena, @intCast(index));
        } else if (usage.user == owner and worksOnFields(items, refs, usage)) {
            working[@backingInt(owner)] = true;
        }
    }

    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    for (fields, working, 0..) |list, works, thing_index| {
        if (!works or !guards(list, &outside)) continue;
        const thing: ThingId = @fromBackingInt(@intCast(thing_index));
        const home = graph.things[thing_index].home;
        for (list) |field| {
            const uses = try leaking(arena, graph, outside.get(field) orelse continue);
            if (uses.len == 0) continue;
            if (!inScope(sources, scope, home) and !anyFromInScope(sources, refs, graph, uses, scope)) continue;
            const others = try otherFields(arena, items, graph, list, field, &outside);
            try found.append(arena, try diagnostic(arena, sources, items, refs, graph, thing, field, uses, others));
        }
    }
    return found.items;
}

/// Each thing's fields that hold something, in item order: the fields of a type that
/// is a thing of the graph, whose type's items are part of it.
fn fieldsByThing(arena: Allocator, items: *const Items.Items, graph: *const Graph.Graph) Allocator.Error![]const []const ItemId {
    const lists = try arena.alloc(std.ArrayList(ItemId), graph.things.len);
    @memset(lists, .empty);
    for (items.list, 0..) |item, index| {
        if (item.kind != .field or item.holds_nothing) continue;
        const parent = item.parent orelse continue;
        if (items.get(parent).kind != .type) continue;
        const thing = graph.thing_of[index] orelse continue;
        try lists[@backingInt(thing)].append(arena, @fromBackingInt(@intCast(index)));
    }
    const out = try arena.alloc([]const ItemId, lists.len);
    for (lists, out) |list, *slot| slot.* = list.items;
    return out;
}

/// Whether some field of `list` is kept: no code outside uses it at all.
fn guards(list: []const ItemId, outside: *const Outside) bool {
    for (list) |field| {
        if (!outside.contains(field)) return true;
    }
    return false;
}

/// Whether `usage` is by a method with a `self` parameter, which works on its type's fields.
fn worksOnFields(items: *const Items.Items, refs: []const References.Reference, usage: Graph.Use) bool {
    const holder = items.get(refs[usage.reference].holder);
    return holder.kind == .function and holder.takes_self;
}

/// The uses in `indexes` that are not plain reads of the field.
fn leaking(arena: Allocator, graph: *const Graph.Graph, indexes: std.ArrayList(u32)) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (indexes.items) |index| {
        if (!graph.uses[index].copies) try out.append(arena, index);
    }
    return out.items;
}

fn inScope(sources: *const Sources, scope: ?NodeId, node: NodeId) bool {
    const within = scope orelse return true;
    return sources.isWithin(node, within);
}

fn anyFromInScope(sources: *const Sources, refs: []const References.Reference, graph: *const Graph.Graph, uses: []const u32, scope: ?NodeId) bool {
    for (uses) |index| {
        if (inScope(sources, scope, refs[graph.uses[index].reference].from)) return true;
    }
    return false;
}

/// What a picture of a leak of `field` says of the other `fields` of its type: those also
/// known outside, and those it keeps.
fn otherFields(arena: Allocator, items: *const Items.Items, graph: *const Graph.Graph, fields: []const ItemId, field: ItemId, outside: *const Outside) Allocator.Error![]const []const u8 {
    var known: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    for (fields) |other| {
        if (other == field) continue;
        const name = items.get(other).name;
        const indexes = outside.get(other) orelse {
            try kept.append(arena, name);
            continue;
        };
        if ((try leaking(arena, graph, indexes)).len > 0) try known.append(arena, name);
    }
    var out: std.ArrayList([]const u8) = .empty;
    if (known.items.len > 0) try out.append(arena, try std.fmt.allocPrint(arena, "also known outside: {s}", .{try Circle.listed(arena, known.items)}));
    if (kept.items.len > 0) try out.append(arena, try std.fmt.allocPrint(arena, "kept: {s}", .{try Circle.listed(arena, kept.items)}));
    return out.items;
}

/// One use of a leaked field, at its place in the source.
const Site = struct { at: Diagnostic.Location, from: NodeId, note: []const u8, order: usize };

fn diagnostic(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, graph: *const Graph.Graph, thing: ThingId, field: ItemId, uses: []const u32, others: []const []const u8) Allocator.Error!Diagnostic.Diagnostic {
    const sites = try arena.alloc(Site, uses.len);
    for (uses, sites, 0..) |index, *slot, order| {
        const usage = graph.uses[index];
        const reference = refs[usage.reference];
        slot.* = .{
            .at = Circle.siteOf(sources, reference),
            .from = reference.from,
            .note = try note(arena, sources, items, usage, reference),
            .order = order,
        };
    }
    std.mem.sort(Site, sites, {}, lessSite);
    var distinct: std.ArrayList(Site) = .empty;
    for (sites) |site| {
        if (distinct.items.len > 0 and sameSite(distinct.items[distinct.items.len - 1].at, site.at)) continue;
        try distinct.append(arena, site);
    }

    var places: std.AutoArrayHashMapUnmanaged(NodeId, usize) = .empty;
    for (distinct.items) |site| {
        const found = try places.getOrPut(arena, site.from);
        if (!found.found_existing) found.value_ptr.* = 0;
        found.value_ptr.* += 1;
    }
    const tallies = try arena.alloc(Diagnostic.Tally, places.count());
    for (places.keys(), places.values(), tallies) |node, count, *slot| slot.* = .{ .count = count, .name = Circle.moduleLabel(sources, node) };
    std.mem.sort(Diagnostic.Tally, tallies, {}, lessTally);
    const module_count = tallies.len;

    var notes: std.ArrayList([]const u8) = .empty;
    for (distinct.items[0..@min(distinct.items.len, Diagnostic.held_in_mind)]) |site| try notes.append(arena, site.note);
    if (distinct.items.len > Diagnostic.held_in_mind) {
        const more = try Circle.counted(arena, distinct.items.len - Diagnostic.held_in_mind, "more place");
        try notes.append(arena, try std.fmt.allocPrint(arena, "and {s}", .{more}));
    }

    const owner = graph.things[@backingInt(thing)];
    const owner_name = try Circle.itemName(arena, items, owner.item);
    const field_name = items.get(field).name;
    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ Circle.moduleLabel(sources, owner.home), owner_name });
    const message = try std.fmt.allocPrint(arena, "`{s}.{s}` is known outside `{s}`: {s} in {s}", .{
        owner_name,
        field_name,
        owner_name,
        try Circle.counted(arena, distinct.items.len, "place"),
        try Circle.counted(arena, module_count, "module"),
    });
    return .{
        .lint = .@"field-leak",
        .key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ qualified, field_name }),
        .message = message,
        .location = distinct.items[0].at,
        .notes = notes.items,
        .picture = .{ .spread = .{
            .owner = qualified,
            .field = field_name,
            .modules = try modulesShown(arena, tallies),
            .others = others,
        } },
    };
}

/// The modules with their places, most first, the rest of them counted as one.
fn modulesShown(arena: Allocator, tallies: []const Diagnostic.Tally) Allocator.Error![]const Diagnostic.Tally {
    if (tallies.len <= Diagnostic.held_in_mind) return tallies;
    const shown = try arena.alloc(Diagnostic.Tally, Diagnostic.held_in_mind + 1);
    @memcpy(shown[0..Diagnostic.held_in_mind], tallies[0..Diagnostic.held_in_mind]);
    var count: usize = 0;
    for (tallies[Diagnostic.held_in_mind..]) |tally| count += tally.count;
    const more = try Circle.counted(arena, tallies.len - Diagnostic.held_in_mind, "more module");
    shown[Diagnostic.held_in_mind] = .{ .count = count, .name = try std.fmt.allocPrint(arena, "in {s}", .{more}) };
    return shown;
}

/// `src/Composer.zig:47:28: `Composer.draw` borrows `area`, through `getter``.
fn note(arena: Allocator, sources: *const Sources, items: *const Items.Items, usage: Graph.Use, reference: References.Reference) Allocator.Error![]const u8 {
    const holder = items.get(reference.holder);
    const holder_name = try std.fmt.allocPrint(arena, "{s}.{s}", .{ Circle.moduleLabel(sources, holder.home), try Circle.itemName(arena, items, reference.holder) });
    const verb = switch (reference.access) {
        .copy => "reads",
        .borrow => "borrows",
        .call => "calls a method of",
        .reach => "writes or indexes",
    };
    const through = if (usage.through) |wrapper|
        try std.fmt.allocPrint(arena, ", through `{s}`", .{try Circle.itemName(arena, items, wrapper)})
    else
        "";
    const at = Circle.siteOf(sources, reference);
    return std.fmt.allocPrint(arena, "{s}: `{s}` {s} `{s}`{s}", .{
        try Circle.clickable(arena, at),
        holder_name,
        verb,
        items.get(usage.item).name,
        through,
    });
}

fn lessSite(_: void, a: Site, b: Site) bool {
    const file = std.mem.order(u8, a.at.file, b.at.file);
    if (file != .eq) return file == .lt;
    if (a.at.line != b.at.line) return a.at.line < b.at.line;
    if (a.at.column != b.at.column) return a.at.column < b.at.column;
    return a.order < b.order;
}

fn sameSite(a: Diagnostic.Location, b: Diagnostic.Location) bool {
    return std.mem.eql(u8, a.file, b.file) and a.line == b.line and a.column == b.column;
}

fn lessTally(_: void, a: Diagnostic.Tally, b: Diagnostic.Tally) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}
