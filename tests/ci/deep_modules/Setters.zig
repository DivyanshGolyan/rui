//! `hand-set-flag` and `scattered-transition`: a field that two or more production functions
//! assign a value that ignores what it held. A flag is set to a fixed value (`x.f = true`,
//! `x.f |= bits`); a state is an enum or tagged union literal (`x.f = .closed`) in a field that
//! the type's own file branches on (`switch`, `==`, `!=`). Each of those functions decides by hand
//! when it happens, so the rule is copied into all of them, and one that forgets is a stale screen,
//! a missed wake or a transition the others never check. A function whose whole body is such an
//! assignment (`fn markDirty(self) void { self.dirty = true; }`) is no writer itself: its callers
//! are. A structural property, not a count: one writer is a decision, two copies are a braid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circle = @import("Circle.zig");
const Diagnostic = @import("Diagnostic.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const ItemId = Items.ItemId;
const NodeId = Sources.NodeId;

/// The reference that sets a field, by index into the references, for each function that does.
const Setters = std.AutoArrayHashMapUnmanaged(ItemId, u32);

pub const Kind = enum {
    flag,
    state,

    fn lint(kind: Kind) Diagnostic.Lint {
        return switch (kind) {
            .flag => .@"hand-set-flag",
            .state => .@"scattered-transition",
        };
    }

    fn sets(kind: Kind) References.Sets {
        return switch (kind) {
            .flag => .fixed,
            .state => .state,
        };
    }

    fn message(kind: Kind) []const u8 {
        return switch (kind) {
            .flag => "is set by hand in",
            .state => "is a state assigned in",
        };
    }

    fn verb(kind: Kind) []const u8 {
        return switch (kind) {
            .flag => "sets",
            .state => "moves",
        };
    }
};

/// The fields that the code of their own file branches on.
fn branchedOn(arena: Allocator, items: *const Items.Items, refs: []const References.Reference) Allocator.Error!std.AutoHashMapUnmanaged(ItemId, void) {
    var out: std.AutoHashMapUnmanaged(ItemId, void) = .empty;
    for (refs) |reference| {
        if (reference.branches and items.get(reference.holder).file == items.get(reference.item).file) try out.put(arena, reference.item, {});
    }
    return out;
}

/// The diagnostics of `kind` in `refs`, limited to `scope` when it is set.
pub fn check(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, scope: ?NodeId, kind: Kind) Allocator.Error![]const Diagnostic.Diagnostic {
    const branched = if (kind == .state) try branchedOn(arena, items, refs) else std.AutoHashMapUnmanaged(ItemId, void).empty;
    // A function whose whole body sets one field is a setter of it, not a writer.
    var setter_of: std.AutoHashMapUnmanaged(ItemId, ItemId) = .empty;
    for (refs) |reference| {
        if (reference.sets != kind.sets() or !isTarget(sources, items, branched, kind, reference.item)) continue;
        if (wholeBody(sources, items, reference.holder)) try setter_of.put(arena, reference.holder, reference.item);
    }

    var writers: std.AutoArrayHashMapUnmanaged(ItemId, Setters) = .empty;
    for (refs, 0..) |reference, index| {
        const field: ItemId = if (reference.sets == kind.sets() and isTarget(sources, items, branched, kind, reference.item)) blk: {
            if (setter_of.contains(reference.holder)) continue;
            break :blk reference.item;
        } else if (setter_of.get(reference.item)) |field| blk: {
            if (!isCall(sources, reference)) continue;
            break :blk field;
        } else continue;
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
        try found.append(arena, try diagnostic(arena, sources, items, refs, setter_of, kind, field, by_holder.values()));
    }
    return found.items;
}

/// Whether the name of `reference` is called: followed by an opening parenthesis, as in `x.mark()` and `Q.mark(x)`, and not passed or returned as a value.
fn isCall(sources: *const Sources, reference: References.Reference) bool {
    const tree = &sources.files[@backingInt(reference.file)].ast;
    return reference.token + 1 < tree.tokens.len and tree.tokenTag(reference.token + 1) == .l_paren;
}

/// Whether `field` is a flag or state of `kind`: a flag is any field that holds something, a
/// state one that its own file branches on.
fn isTarget(sources: *const Sources, items: *const Items.Items, branched: std.AutoHashMapUnmanaged(ItemId, void), kind: Kind, field: ItemId) bool {
    return isFlag(items, field) and (kind == .flag or (branched.contains(field) and isStateType(sources, items, field)));
}

/// Whether the declared type of `field` is an enum or a union, or an optional of one: an
/// initializer such as `.{ .a = 1 }` also builds a plain struct, so the type decides.
fn isStateType(sources: *const Sources, items: *const Items.Items, field: ItemId) bool {
    const item = items.get(field);
    const ast = &sources.files[@backingInt(item.file)].ast;
    var node = item.type_expr orelse return false;
    while (ast.nodeTag(node) == .optional_type) node = ast.nodeData(node).node;
    if (isEnumOrUnion(ast, node)) return true;
    const t = Types.fieldType(items, sources, field);
    for (t.layers.slice()) |layer| {
        if (layer != .optional) return false;
    }
    const container = items.get(t.container orelse return false);
    if (container.kind != .type) return false;
    const container_ast = &sources.files[@backingInt(container.file)].ast;
    const decl = container_ast.fullVarDecl(container.decl) orelse return false;
    return isEnumOrUnion(container_ast, decl.ast.init_node.unwrap() orelse return false);
}

fn isEnumOrUnion(ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (ast.nodeTag(node)) {
        .tagged_union, .tagged_union_trailing, .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => true,
        .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => switch (ast.tokenTag(ast.nodeMainToken(node))) {
            .keyword_enum, .keyword_union => true,
            else => false,
        },
        else => false,
    };
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

fn diagnostic(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference, setter_of: std.AutoHashMapUnmanaged(ItemId, ItemId), kind: Kind, field: ItemId, uses: []const u32) Allocator.Error!Diagnostic.Diagnostic {
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
            .note = try std.fmt.allocPrint(arena, "{s}: `{s}.{s}` {s} `{s}`{s}", .{
                try Circle.clickable(arena, at),
                Circle.moduleLabel(sources, holder.home),
                try Circle.itemName(arena, items, reference.holder),
                kind.verb(),
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
        .lint = kind.lint(),
        .key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ qualified, field_name }),
        .message = try std.fmt.allocPrint(arena, "`{s}.{s}` {s} {s}", .{ owner_name, field_name, kind.message(), try Circle.counted(arena, sites.len, "function") }),
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
