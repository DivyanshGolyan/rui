//! Decl-level name resolution without values (deep-modules U5). `resolvePath`
//! takes an identifier or a field-access chain to the item it names: an
//! identifier is looked up outward through the container chain (Zig forbids
//! shadowing, so the first hit wins), a `.name` step goes into the children of
//! the item before it, and `@import` of a .zig file names that file's item.
//! Aliases resolve to their targets within a hop budget, so a cycle is unknown.
//! `@import` of a named module resolves through the import table Sources keeps per file.

const std = @import("std");
const Ast = std.zig.Ast;
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;

/// An alias may pass through this many other aliases before the answer is unknown.
const max_hops = 16;

/// The item that the expression `node` names, evaluated in container `scope` of `file`.
pub fn resolvePath(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index) ?ItemId {
    return resolveNode(items, sources, scope, file, node, 0);
}

/// `item` itself unless it is an alias; then the item the alias chain ends at, or null on a cycle.
pub fn chaseAlias(items: *const Items.Items, sources: *const Sources, item: ItemId) ?ItemId {
    if (items.get(item).kind != .alias) return item;
    return resolveAlias(items, sources, item, 0);
}

fn resolveAlias(items: *const Items.Items, sources: *const Sources, alias: ItemId, hops: u32) ?ItemId {
    if (hops >= max_hops) return null;
    const decl = items.get(alias);
    const scope = decl.parent orelse return null;
    const value = decl.alias_of orelse return null;
    return resolveNode(items, sources, scope, decl.file, value, hops + 1);
}

fn settle(items: *const Items.Items, sources: *const Sources, found: ItemId, hops: u32) ?ItemId {
    if (items.get(found).kind != .alias) return found;
    return resolveAlias(items, sources, found, hops);
}

fn resolveNode(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index, hops: u32) ?ItemId {
    const ast = &sources.files[@backingInt(file)].ast;
    switch (ast.nodeTag(node)) {
        .identifier => {
            const found = lookupName(items, scope, ast.tokenSlice(ast.nodeMainToken(node))) orelse return null;
            return settle(items, sources, found, hops);
        },
        .field_access => {
            const base_node, const name_token = ast.nodeData(node).node_and_token;
            const base = resolveNode(items, sources, scope, file, base_node, hops) orelse return null;
            const found = Items.lookup(items, base, ast.tokenSlice(name_token)) orelse return null;
            return settle(items, sources, found, hops);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@This")) return scope;
            if (std.mem.eql(u8, name, "@import")) return importedFile(items, sources, file, node);
            return null;
        },
        else => return null,
    }
}

/// The child of the innermost container that has `name`. Fields are skipped:
/// Zig does not put a field in scope by its bare name.
fn lookupName(items: *const Items.Items, scope: ItemId, name: []const u8) ?ItemId {
    var current: ?ItemId = scope;
    while (current) |container| : (current = items.get(container).parent) {
        for (items.children[@backingInt(container)]) |child| {
            const item = items.get(child);
            if (item.kind != .field and std.mem.eql(u8, item.name, name)) return child;
        }
    }
    return null;
}

fn importedFile(items: *const Items.Items, sources: *const Sources, file: FileId, node: Ast.Node.Index) ?ItemId {
    const ast = &sources.files[@backingInt(file)].ast;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = ast.builtinCallParams(&buffer, node) orelse return null;
    if (args.len != 1 or ast.nodeTag(args[0]) != .string_literal) return null;
    const literal = ast.tokenSlice(ast.nodeMainToken(args[0]));
    const target = sources.importTarget(file, literal[1 .. literal.len - 1]) orelse return null;
    return items.files[@backingInt(target)];
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

const Loaded = struct { sources: Sources, items: Items.Items, main: FileId };

const modules = [_]Sources.NamedModule{.{ .name = "os", .path = "src/os/os.zig" }};

fn loadFixture(arena: Allocator, entries: []const Sources.Memory.Entry) !Loaded {
    const memory: Sources.Memory = .{ .entries = entries };
    var failure: Sources.Failure = .{};
    const sources = try Sources.load(arena, memory.reader(), "src/main.zig", &modules, &failure);
    const items = try Items.collect(arena, &sources);
    return .{ .sources = sources, .items = items, .main = sources.findFile("src/main.zig").? };
}

/// The item at a dotted path from `file`'s item; the empty path is the file item.
fn scopeAt(items: *const Items.Items, file: FileId, dotted: []const u8) ItemId {
    var current = items.files[@backingInt(file)];
    if (dotted.len == 0) return current;
    var parts = std.mem.splitScalar(u8, dotted, '.');
    while (parts.next()) |part| current = Items.lookup(items, current, part).?;
    return current;
}

/// The item's dotted path from its file's stem, for example `main.Outer.Holder`.
fn pathOf(arena: Allocator, items: *const Items.Items, id: ItemId) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var current: ?ItemId = id;
    while (current) |c| : (current = items.get(c).parent) try parts.append(arena, items.get(c).name);
    std.mem.reverse([]const u8, parts.items);
    return std.mem.join(arena, ".", parts.items);
}

/// The first node whose source text is `text`.
fn nodeWithSource(ast: *const Ast, text: []const u8) ?Ast.Node.Index {
    for (0..ast.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (std.mem.eql(u8, ast.getNodeSource(node), text)) return node;
    }
    return null;
}

const main_text =
    \\const std = @import("std");
    \\const b = @import("b.zig");
    \\const x = b;
    \\const Std = std.mem;
    \\pub const Outer = struct {
    \\    const Shared = struct {};
    \\    pub const Holder = struct {
    \\        const Inner = struct {};
    \\        const Self = @This();
    \\        const K = b.Key;
    \\        const Loop_a = Loop_b;
    \\        const Loop_b = Loop_a;
    \\        count: u8,
    \\        pub fn probes() void {
    \\            _ = Inner;
    \\            _ = Shared;
    \\            _ = Holder.Inner;
    \\            _ = Self;
    \\            _ = Self.Inner;
    \\            _ = @This();
    \\            _ = K;
    \\            _ = x.Thing;
    \\            _ = b.Thing;
    \\            _ = Loop_a;
    \\            _ = std.mem;
    \\            _ = Std;
    \\            _ = count;
    \\            _ = Thing;
    \\            _ = Holder.count;
    \\            _ = Inner.missing;
    \\            _ = @import("os");
    \\        }
    \\    };
    \\};
    \\
;

const b_text = "pub const Thing = struct {};\npub const Key = Thing;\n";

const Row = struct { scope: []const u8, expr: []const u8, expect: ?[]const u8 };

const rows = [_]Row{
    .{ .scope = "Outer.Holder", .expr = "Inner", .expect = "main.Outer.Holder.Inner" },
    .{ .scope = "Outer.Holder", .expr = "Shared", .expect = "main.Outer.Shared" },
    .{ .scope = "Outer", .expr = "Holder.Inner", .expect = "main.Outer.Holder.Inner" },
    .{ .scope = "Outer.Holder", .expr = "Holder.Inner", .expect = "main.Outer.Holder.Inner" },
    .{ .scope = "Outer.Holder", .expr = "Self", .expect = "main.Outer.Holder" },
    .{ .scope = "Outer.Holder", .expr = "Self.Inner", .expect = "main.Outer.Holder.Inner" },
    .{ .scope = "Outer.Holder", .expr = "@This()", .expect = "main.Outer.Holder" },
    .{ .scope = "Outer.Holder", .expr = "x.Thing", .expect = "b.Thing" },
    .{ .scope = "Outer.Holder", .expr = "b.Thing", .expect = "b.Thing" },
    .{ .scope = "Outer.Holder", .expr = "K", .expect = "b.Thing" },
    .{ .scope = "Outer.Holder", .expr = "Holder.count", .expect = "main.Outer.Holder.count" },
    .{ .scope = "Outer.Holder", .expr = "Loop_a", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "std.mem", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "Std", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "count", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "Thing", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "Inner.missing", .expect = null },
    .{ .scope = "Outer.Holder", .expr = "@import(\"os\")", .expect = "os" },
};

test "resolvePath finds names in scope, through imports and aliases, and says unknown otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try loadFixture(a, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/b.zig", .text = b_text },
        .{ .path = "src/os/os.zig", .text = "pub const Thing = struct {};\n" },
    });
    const items = &loaded.items;
    const sources = &loaded.sources;
    const ast = &sources.files[@backingInt(loaded.main)].ast;
    for (rows) |row| {
        errdefer std.debug.print("row: `{s}` in {s}\n", .{ row.expr, row.scope });
        const scope = scopeAt(items, loaded.main, row.scope);
        const node = nodeWithSource(ast, row.expr) orelse return error.TestNodeMissing;
        const got = resolvePath(items, sources, scope, loaded.main, node);
        if (row.expect) |expect| {
            const id = got orelse return error.TestExpectedItem;
            try testing.expectEqualStrings(expect, try pathOf(a, items, id));
        } else {
            try testing.expectEqual(@as(?ItemId, null), got);
        }
    }
}

test "chaseAlias follows re-exports and gives up on cycles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try loadFixture(a, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/b.zig", .text = b_text },
        .{ .path = "src/os/os.zig", .text = "pub const Thing = struct {};\n" },
    });
    const items = &loaded.items;
    const sources = &loaded.sources;
    const b_file = sources.findFile("src/b.zig").?;

    const key = scopeAt(items, loaded.main, "Outer.Holder.K");
    const thing = scopeAt(items, b_file, "Thing");
    try testing.expectEqual(@as(?ItemId, thing), chaseAlias(items, sources, key));
    try testing.expectEqual(@as(?ItemId, thing), chaseAlias(items, sources, thing));
    const loop = scopeAt(items, loaded.main, "Outer.Holder.Loop_a");
    try testing.expectEqual(@as(?ItemId, null), chaseAlias(items, sources, loop));
}
