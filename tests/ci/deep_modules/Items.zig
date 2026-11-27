//! Declarations of the reached files (deep-modules U4): types, namespaces,
//! functions, constants, struct fields and aliases, with the facts a lint reads
//! from the syntax alone: the receiver mode and field plainness. Test declarations
//! are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Sources = @import("Sources.zig");
const syntax = @import("ItemSyntax.zig");
const FileId = Sources.FileId;
const NodeId = Sources.NodeId;

pub const ItemId = enum(u32) { _ };
/// `type` has fields or variants; `namespace` has neither.
pub const Kind = enum { type, namespace, function, constant, field, alias };
pub const Plain = syntax.Plain;

pub const Item = struct {
    kind: Kind,
    name: []const u8,
    file: FileId,
    /// The AST declaration (var, fn, container field, or the root of a file).
    decl: Ast.Node.Index,
    /// The enclosing container item; null for a file's own item.
    parent: ?ItemId,
    home: NodeId,
    /// A function whose first parameter names the enclosing type: how it takes it.
    receiver: Receiver,
    /// A field of type void, u0 or an empty struct.
    holds_nothing: bool,
    plain: Plain,
    /// Fields: the field type. Containers: the container. Functions: the return type.
    type_expr: ?Ast.Node.Index,
    /// Aliases: the initializer.
    alias_of: ?Ast.Node.Index,

    pub fn takesSelf(self: Item) bool {
        return self.receiver != .none;
    }

    /// Whether a call of this function cannot change what it is called on.
    pub fn readsReceiver(self: Item) bool {
        return self.receiver == .value or self.receiver == .const_pointer;
    }
};

pub const Items = struct {
    list: []Item,
    /// The file item of each file, by FileId.
    files: []const ItemId,
    /// Children of each item, by ItemId.
    children: []const []ItemId,

    pub fn get(self: *const Items, id: ItemId) *const Item {
        return &self.list[@backingInt(id)];
    }
};

/// The child of `container` with this name, or null.
pub fn lookup(items: *const Items, container: ItemId, name: []const u8) ?ItemId {
    for (items.children[@backingInt(container)]) |child| {
        if (std.mem.eql(u8, items.list[@backingInt(child)].name, name)) return child;
    }
    return null;
}

/// Records the declarations of every file in `sources`.
pub fn collect(arena: Allocator, sources: *const Sources) Allocator.Error!Items {
    var walker: Walker = .{ .arena = arena };
    const files = try arena.alloc(ItemId, sources.files.len);
    for (sources.files, 0..) |*file, i| {
        const ctx: Ctx = .{ .ast = &file.ast, .file = @fromBackingInt(@intCast(i)), .home = file.node };
        files[i] = try walker.container(ctx, Sources.stem(file.path), null, .root, .root, file.ast.rootDecls(), true);
    }
    const list = try walker.items.toOwnedSlice(arena);
    const items: Items = .{ .list = list, .files = files, .children = try buildChildren(arena, list) };
    for (list) |*item| {
        if (item.kind != .function) continue;
        const owner = item.parent orelse continue;
        item.receiver = receiverOf(&sources.files[@backingInt(item.file)].ast, &items, owner, item.decl);
    }
    return items;
}

fn buildChildren(arena: Allocator, list: []const Item) Allocator.Error![]const []ItemId {
    const counts = try arena.alloc(usize, list.len);
    @memset(counts, 0);
    for (list) |item| {
        if (item.parent) |parent| counts[@backingInt(parent)] += 1;
    }
    const children = try arena.alloc([]ItemId, list.len);
    for (children, counts) |*slot, count| slot.* = try arena.alloc(ItemId, count);
    @memset(counts, 0);
    for (list, 0..) |item, i| {
        const parent = @backingInt(item.parent orelse continue);
        children[parent][counts[parent]] = @fromBackingInt(@intCast(i));
        counts[parent] += 1;
    }
    return children;
}

const Ctx = struct { ast: *const Ast, file: FileId, home: NodeId };

const Walker = struct {
    arena: Allocator,
    items: std.ArrayList(Item) = .empty,

    fn add(self: *Walker, item: Item) Allocator.Error!ItemId {
        const id: ItemId = @fromBackingInt(@intCast(self.items.items.len));
        try self.items.append(self.arena, item);
        return id;
    }

    fn base(ctx: Ctx, kind: Kind, name: []const u8, decl: Ast.Node.Index, parent: ?ItemId) Item {
        return .{ .kind = kind, .name = name, .file = ctx.file, .decl = decl, .parent = parent, .home = ctx.home, .receiver = .none, .holds_nothing = false, .plain = .no, .type_expr = null, .alias_of = null };
    }

    /// A container item, then its members. `decl` is the declaring node; `node` the container itself.
    fn container(self: *Walker, ctx: Ctx, name: []const u8, parent: ?ItemId, decl: Ast.Node.Index, node: Ast.Node.Index, body: []const Ast.Node.Index, is_struct: bool) Allocator.Error!ItemId {
        var item = base(ctx, if (syntax.hasFields(ctx.ast, body)) .type else .namespace, name, decl, parent);
        item.type_expr = node;
        const id = try self.add(item);
        try self.members(ctx, id, body, is_struct);
        return id;
    }

    fn members(self: *Walker, ctx: Ctx, owner: ItemId, nodes: []const Ast.Node.Index, is_struct: bool) Allocator.Error!void {
        for (nodes) |node| switch (ctx.ast.nodeTag(node)) {
            .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => try self.function(ctx, owner, node),
            .global_var_decl, .simple_var_decl, .aligned_var_decl => try self.variable(ctx, owner, node),
            .container_field_init, .container_field_align, .container_field => if (is_struct) try self.field(ctx, owner, node),
            else => {},
        };
    }

    fn function(self: *Walker, ctx: Ctx, owner: ItemId, node: Ast.Node.Index) Allocator.Error!void {
        const data = ctx.ast.nodeData(node);
        const is_decl = ctx.ast.nodeTag(node) == .fn_decl;
        const body: ?Ast.Node.Index = if (is_decl) data.node_and_node[1] else null;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = ctx.ast.fullFnProto(&buffer, syntax.protoNode(ctx.ast, node)) orelse return;
        const name = ctx.ast.tokenSlice(proto.name_token orelse return);
        if (syntax.typeReturningContainer(ctx.ast, proto, body)) |container_node| {
            var container_buffer: [2]Ast.Node.Index = undefined;
            const found = syntax.containerIn(ctx.ast, &container_buffer, container_node).?;
            _ = try self.container(ctx, name, owner, node, container_node, found.members, found.is_struct);
            return;
        }
        var item = base(ctx, .function, name, node, owner);
        item.type_expr = proto.ast.return_type.unwrap();
        _ = try self.add(item);
    }

    fn variable(self: *Walker, ctx: Ctx, owner: ItemId, node: Ast.Node.Index) Allocator.Error!void {
        const decl = ctx.ast.fullVarDecl(node) orelse return;
        const name = ctx.ast.tokenSlice(decl.ast.mut_token + 1);
        if (decl.ast.init_node.unwrap()) |value| {
            var container_buffer: [2]Ast.Node.Index = undefined;
            if (syntax.containerIn(ctx.ast, &container_buffer, value)) |found| {
                _ = try self.container(ctx, name, owner, node, value, found.members, found.is_struct);
                return;
            }
            if (decl.ast.type_node.unwrap() == null and syntax.isAlias(ctx.ast, value)) {
                var item = base(ctx, .alias, name, node, owner);
                item.alias_of = value;
                _ = try self.add(item);
                return;
            }
        }
        var item = base(ctx, .constant, name, node, owner);
        item.type_expr = decl.ast.type_node.unwrap();
        _ = try self.add(item);
    }

    fn field(self: *Walker, ctx: Ctx, owner: ItemId, node: Ast.Node.Index) Allocator.Error!void {
        const container_field = ctx.ast.fullContainerField(node) orelse return;
        var item = base(ctx, .field, ctx.ast.tokenSlice(container_field.ast.main_token), node, owner);
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            item.type_expr = type_node;
            item.plain = syntax.plainOf(ctx.ast, type_node);
        }
        item.holds_nothing = item.plain == .nothing;
        _ = try self.add(item);
    }
};

fn isSelfName(ast: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return ast.nodeTag(node) == .identifier and std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), name);
}

/// How a method takes its `self`. A `value` or `const_pointer` receiver cannot change what it is called on.
pub const Receiver = enum { none, value, const_pointer, pointer };

/// The first parameter's type, after one pointer, names the enclosing type `owner`.
fn receiverOf(ast: *const Ast, items: *const Items, owner_id: ItemId, decl: Ast.Node.Index) Receiver {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buffer, syntax.protoNode(ast, decl)) orelse return .none;
    var params = proto.iterate(ast);
    const first = params.next() orelse return .none;
    const type_node = first.type_expr orelse return .none;
    const owner = items.get(owner_id).*;
    var target = type_node;
    var mode: Receiver = .value;
    if (ast.fullPtrType(type_node)) |pointer| {
        if (pointer.size != .one) return .none;
        target = pointer.ast.child_type;
        mode = if (pointer.const_token != null) .const_pointer else .pointer;
    }
    if (syntax.isBuiltinNamed(ast, target, "@This")) return mode;
    if (ast.nodeTag(target) != .identifier) return .none;
    if (std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(target)), owner.name)) return mode;
    const alias_id = lookup(items, owner_id, ast.tokenSlice(ast.nodeMainToken(target))) orelse return .none;
    const alias = items.get(alias_id).*;
    if (alias.kind != .alias) return .none;
    const value = alias.alias_of orelse return .none;
    return if (syntax.isBuiltinNamed(ast, value, "@This") or isSelfName(ast, value, owner.name)) mode else .none;
}

const testing = std.testing;

const thing_source =
    \\const std = @import("std");
    \\const Pair = @import("Pair.zig");
    \\pub const Alias = std.mem;
    \\pub const limit = 10;
    \\pub var state: u32 = 0;
    \\pub const typed: u32 = undefined;
    \\pub const undef = undefined;
    \\pub const Holder = struct {
    \\    const Self = @This();
    \\    count: usize,
    \\    name: []const u8,
    \\    opt: ?u32,
    \\    arr: [4]u8,
    \\    flag: bool,
    \\    ptr: *u8,
    \\    kind: Kind,
    \\    ids: []Kind,
    \\    handle: *const Self,
    \\    unit: void,
    \\    zero: u0,
    \\    empty: struct {},
    \\    const Kind = enum { a, b };
    \\    pub fn make(n: usize) Self { return undefined; }
    \\    pub fn get(self: *const Self) usize { return self.count; }
    \\    pub fn owned(self: Self) void { _ = self; }
    \\    pub fn viaThis(self: *@This()) void { _ = self; }
    \\    pub fn other(o: *Pair) void { _ = o; }
    \\};
    \\pub const ns = struct { pub fn helper(x: u8) u8 { return x; } };
    \\fn Ring(comptime T: type) type {
    \\    return struct {
    \\        item: T,
    \\        len: usize,
    \\        pub fn push(self: *@This()) void { _ = self; }
    \\    };
    \\}
    \\test "ignored" { const hidden = struct { x: u8 }; _ = hidden; }
    \\
;

const pair_source = "a: u8,\nb: u8,\npub fn sum(self: Pair) u8 {\n    return self.a + self.b;\n}\n";

const Row = struct { path: []const u8, kind: Kind, plain: Plain = .no, receiver: Receiver = .none, holds_nothing: bool = false };

const thing_rows = [_]Row{
    .{ .path = "std", .kind = .alias },
    .{ .path = "Pair", .kind = .alias },
    .{ .path = "Alias", .kind = .alias },
    .{ .path = "limit", .kind = .constant },
    .{ .path = "state", .kind = .constant },
    .{ .path = "typed", .kind = .constant },
    .{ .path = "undef", .kind = .constant },
    .{ .path = "Holder", .kind = .type },
    .{ .path = "Holder.Self", .kind = .alias },
    .{ .path = "Holder.count", .kind = .field, .plain = .scalar },
    .{ .path = "Holder.name", .kind = .field, .plain = .data },
    .{ .path = "Holder.opt", .kind = .field, .plain = .data },
    .{ .path = "Holder.arr", .kind = .field, .plain = .data },
    .{ .path = "Holder.flag", .kind = .field, .plain = .scalar },
    .{ .path = "Holder.ptr", .kind = .field },
    .{ .path = "Holder.kind", .kind = .field },
    .{ .path = "Holder.ids", .kind = .field },
    .{ .path = "Holder.handle", .kind = .field },
    .{ .path = "Holder.unit", .kind = .field, .plain = .nothing, .holds_nothing = true },
    .{ .path = "Holder.zero", .kind = .field, .plain = .nothing, .holds_nothing = true },
    .{ .path = "Holder.empty", .kind = .field, .plain = .nothing, .holds_nothing = true },
    .{ .path = "Holder.Kind", .kind = .type },
    .{ .path = "Holder.make", .kind = .function },
    .{ .path = "Holder.get", .kind = .function, .receiver = .const_pointer },
    .{ .path = "Holder.owned", .kind = .function, .receiver = .value },
    .{ .path = "Holder.viaThis", .kind = .function, .receiver = .pointer },
    .{ .path = "Holder.other", .kind = .function },
    .{ .path = "ns", .kind = .namespace },
    .{ .path = "ns.helper", .kind = .function },
    .{ .path = "Ring", .kind = .type },
    .{ .path = "Ring.item", .kind = .field },
    .{ .path = "Ring.len", .kind = .field, .plain = .scalar },
    .{ .path = "Ring.push", .kind = .function, .receiver = .pointer },
};

fn itemAt(items: *const Items, file: ItemId, dotted: []const u8) ItemId {
    var current = file;
    var parts = std.mem.splitScalar(u8, dotted, '.');
    while (parts.next()) |part| current = lookup(items, current, part).?;
    return current;
}

fn expectRow(items: *const Items, file: ItemId, row: Row) !void {
    const item = items.get(itemAt(items, file, row.path)).*;
    errdefer std.debug.print("row: {s}\n", .{row.path});
    try testing.expectEqual(row.kind, item.kind);
    try testing.expectEqual(row.plain, item.plain);
    try testing.expectEqual(row.receiver, item.receiver);
    try testing.expectEqual(row.holds_nothing, item.holds_nothing);
}

test "per-declaration table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const memory: Sources.Memory = .{ .entries = &.{
        .{ .path = "src/cli.zig", .text = "const Thing = @import(\"Thing.zig\");\nconst Pair = @import(\"Pair.zig\");\nconst util = @import(\"util.zig\");\n" },
        .{ .path = "src/Thing.zig", .text = thing_source },
        .{ .path = "src/Pair.zig", .text = pair_source },
        .{ .path = "src/util.zig", .text = "pub fn helper() void {}\n" },
    } };
    var failure: Sources.Failure = .{};
    const sources = try Sources.load(arena.allocator(), memory.reader(), "src/cli.zig", &.{}, &failure);
    const items = try collect(arena.allocator(), &sources);

    const thing = items.files[@backingInt(sources.findFile("src/Thing.zig").?)];
    for (thing_rows) |row| try expectRow(&items, thing, row);
    try testing.expectEqual(Kind.namespace, items.get(thing).kind);
    try testing.expectEqual(sources.files[@backingInt(sources.findFile("src/Thing.zig").?)].node, items.get(itemAt(&items, thing, "Holder.count")).home);
    try testing.expect(lookup(&items, thing, "hidden") == null);
    try testing.expect(lookup(&items, thing, "missing") == null);

    const ast = &sources.files[@backingInt(sources.findFile("src/Thing.zig").?)].ast;
    try testing.expectEqualStrings("[]const u8", ast.getNodeSource(items.get(itemAt(&items, thing, "Holder.name")).type_expr.?));
    try testing.expectEqualStrings("std.mem", ast.getNodeSource(items.get(itemAt(&items, thing, "Alias")).alias_of.?));
    const ring = itemAt(&items, thing, "Ring");
    try testing.expectEqual(Ast.Node.Tag.fn_decl, ast.nodeTag(items.get(ring).decl));

    const pair = items.files[@backingInt(sources.findFile("src/Pair.zig").?)];
    try testing.expectEqual(Kind.type, items.get(pair).kind);
    try expectRow(&items, pair, .{ .path = "a", .kind = .field, .plain = .scalar });
    try expectRow(&items, pair, .{ .path = "b", .kind = .field, .plain = .scalar });
    try expectRow(&items, pair, .{ .path = "sum", .kind = .function, .receiver = .value });

    const util = items.files[@backingInt(sources.findFile("src/util.zig").?)];
    try testing.expectEqual(Kind.namespace, items.get(util).kind);
    try expectRow(&items, util, .{ .path = "helper", .kind = .function });
}
