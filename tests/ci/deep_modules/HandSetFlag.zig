//! `hand-set-flag`: a field that two or more production functions set to a fixed value, whatever
//! it held (`x.f = true`, `x.f |= bits`). Each of those functions reports "something happened" by
//! hand, so the rule for when it happens is copied into all of them, and a function that forgets is
//! a stale screen or a missed wake. A function whose whole body is such an assignment (`fn
//! markDirty(self) void { self.dirty = true; }`) is no writer itself: its callers are. A
//! structural property, not a count: one setter is a decision, two copies of it are a braid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circle = @import("Circle.zig");
const Diagnostic = @import("Diagnostic.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const NodeId = Sources.NodeId;

/// The reference that sets a field, by index into the references, for each function that does.
const Setters = std.AutoArrayHashMapUnmanaged(ItemId, u32);

/// The hand-set-flag diagnostics of `refs`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, scope: ?NodeId) Allocator.Error![]const Diagnostic.Diagnostic {
    // A function whose whole body sets one field is a setter of it, not a writer.
    var setter_of: std.AutoHashMapUnmanaged(ItemId, ItemId) = .empty;
    for (refs) |reference| {
        if (!reference.sets or !isFlag(items, reference.item)) continue;
        if (wholeBody(sources, items, reference.holder)) try setter_of.put(arena, reference.holder, reference.item);
    }

    var writers: std.AutoArrayHashMapUnmanaged(ItemId, Setters) = .empty;
    for (refs, 0..) |reference, index| {
        const field: ItemId = if (reference.sets and isFlag(items, reference.item)) blk: {
            if (setter_of.contains(reference.holder)) continue;
            break :blk reference.item;
        } else if (setter_of.get(reference.item)) |field| field else continue;
        if (items.get(reference.holder).kind != .function) continue;
        const slot = try writers.getOrPut(arena, field);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        const by_holder = try slot.value_ptr.getOrPut(arena, reference.holder);
        if (!by_holder.found_existing or earlier(sources, refs[index], refs[by_holder.value_ptr.*])) by_holder.value_ptr.* = @intCast(index);
    }

    var found: std.ArrayList(Diagnostic.Diagnostic) = .empty;
    for (writers.keys(), writers.values()) |field, by_holder| {
        if (by_holder.count() < 2) continue;
        const owner = items.get(items.get(field).parent.?);
        if (!inScope(sources, scope, owner.home) and !anyFromInScope(sources, refs, by_holder.values(), scope)) continue;
        try found.append(arena, try diagnostic(arena, sources, items, refs, setter_of, field, by_holder.values()));
    }
    return found.items;
}

/// Whether `field` is a field of a type that holds something.
fn isFlag(items: *const Items.Items, field: ItemId) bool {
    const item = items.get(field);
    if (item.kind != .field or item.holds_nothing) return false;
    const parent = item.parent orelse return false;
    return items.get(parent).kind == .type;
}

/// Whether the body of `function` is exactly one assignment.
fn wholeBody(sources: *const Sources, items: *const Items.Items, function: ItemId) bool {
    const item = items.get(function);
    if (item.kind != .function) return false;
    const tree = &sources.files[@backingInt(item.file)].ast;
    if (tree.nodeTag(item.decl) != .fn_decl) return false;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, tree.nodeData(item.decl).node_and_node[1]) orelse return false;
    return statements.len == 1 and (tree.nodeTag(statements[0]) == .assign or tree.nodeTag(statements[0]) == .assign_bit_or);
}

fn earlier(sources: *const Sources, a: References.Reference, b: References.Reference) bool {
    return lessLocation(Circle.siteOf(sources, a), Circle.siteOf(sources, b));
}

fn lessLocation(a: Diagnostic.Location, b: Diagnostic.Location) bool {
    const file = std.mem.order(u8, a.file, b.file);
    if (file != .eq) return file == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

fn inScope(sources: *const Sources, scope: ?NodeId, node: NodeId) bool {
    const within = scope orelse return true;
    return sources.isWithin(node, within);
}

fn anyFromInScope(sources: *const Sources, refs: []const References.Reference, uses: []const u32, scope: ?NodeId) bool {
    for (uses) |index| {
        if (inScope(sources, scope, refs[index].from)) return true;
    }
    return false;
}

const Site = struct { at: Diagnostic.Location, from: NodeId, note: []const u8 };

fn lessSite(_: void, a: Site, b: Site) bool {
    return lessLocation(a.at, b.at);
}

fn lessTally(_: void, a: Diagnostic.Tally, b: Diagnostic.Tally) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn diagnostic(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, setter_of: std.AutoHashMapUnmanaged(ItemId, ItemId), field: ItemId, uses: []const u32) Allocator.Error!Diagnostic.Diagnostic {
    const field_name = items.get(field).name;
    const sites = try arena.alloc(Site, uses.len);
    for (uses, sites) |index, *slot| {
        const reference = refs[index];
        const holder = items.get(reference.holder);
        const through = if (setter_of.contains(reference.item))
            try std.fmt.allocPrint(arena, ", through `{s}`", .{try Circle.itemName(arena, items, reference.item)})
        else
            "";
        const at = Circle.siteOf(sources, reference);
        slot.* = .{
            .at = at,
            .from = reference.from,
            .note = try std.fmt.allocPrint(arena, "{s}: `{s}.{s}` sets `{s}`{s}", .{
                try Circle.clickable(arena, at),
                Circle.moduleLabel(sources, holder.home),
                try Circle.itemName(arena, items, reference.holder),
                field_name,
                through,
            }),
        };
    }
    std.mem.sort(Site, sites, {}, lessSite);

    var places: std.AutoArrayHashMapUnmanaged(NodeId, usize) = .empty;
    for (sites) |site| {
        const found = try places.getOrPut(arena, site.from);
        if (!found.found_existing) found.value_ptr.* = 0;
        found.value_ptr.* += 1;
    }
    const tallies = try arena.alloc(Diagnostic.Tally, places.count());
    for (places.keys(), places.values(), tallies) |node, count, *slot| slot.* = .{ .count = count, .name = Circle.moduleLabel(sources, node) };
    std.mem.sort(Diagnostic.Tally, tallies, {}, lessTally);

    var notes: std.ArrayList([]const u8) = .empty;
    for (sites[0..@min(sites.len, Diagnostic.held_in_mind)]) |site| try notes.append(arena, site.note);
    if (sites.len > Diagnostic.held_in_mind) {
        const more = try Circle.counted(arena, sites.len - Diagnostic.held_in_mind, "more function");
        try notes.append(arena, try std.fmt.allocPrint(arena, "and {s}", .{more}));
    }

    const owner_id = items.get(field).parent.?;
    const owner_name = try Circle.itemName(arena, items, owner_id);
    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ Circle.moduleLabel(sources, items.get(owner_id).home), owner_name });
    return .{
        .lint = .@"hand-set-flag",
        .key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ qualified, field_name }),
        .message = try std.fmt.allocPrint(arena, "`{s}.{s}` is set by hand in {s}", .{ owner_name, field_name, try Circle.counted(arena, sites.len, "function") }),
        .location = sites[0].at,
        .notes = notes.items,
        .picture = .{ .spread = .{
            .owner = qualified,
            .field = field_name,
            .modules = try modulesShown(arena, tallies),
            .others = &.{},
        } },
    };
}

/// The modules with their functions, most first, the rest of them counted as one.
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
