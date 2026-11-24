//! Type expressions as layers around a container (deep-modules U6). A `TypeRef`
//! names the container item a type denotes (null when unknown or outside the
//! program) and the wrappers around it, outermost first: `?*Foo` is
//! `[optional, pointer]` around Foo. `ofTypeExpr` reads a type expression;
//! `returnType` and `fieldType` read a declaration's type. `deref`, `element`,
//! `unwrap` and `payload` peel one layer and are unknown when the outermost
//! layer is another kind. Field access on a TypeRef needs its layers peeled first.

const std = @import("std");
const Ast = std.zig.Ast;
const Items = @import("Items.zig");
const Names = @import("Names.zig");
const syntax = @import("ItemSyntax.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;

pub const Layer = enum { pointer, optional, sequence, error_union };

/// Types with more layers than this are unknown.
pub const max_layers = 4;

pub const Layers = struct {
    len: u8 = 0,
    buf: [max_layers]Layer = undefined,

    pub fn slice(self: *const Layers) []const Layer {
        return self.buf[0..self.len];
    }
};

pub const TypeRef = struct { container: ?ItemId, layers: Layers = .{} };

pub const unknown: TypeRef = .{ .container = null };

/// The type of a type expression `node`, written in container `scope` of `file`.
pub fn ofTypeExpr(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index) TypeRef {
    const ast = &sources.files[@backingInt(file)].ast;
    switch (ast.nodeTag(node)) {
        .optional_type => return wrap(.optional, ofTypeExpr(items, sources, scope, file, ast.nodeData(node).node)),
        .array_type, .array_type_sentinel => {
            const array = ast.fullArrayType(node) orelse return unknown;
            return wrap(.sequence, ofTypeExpr(items, sources, scope, file, array.ast.elem_type));
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            const pointer = ast.fullPtrType(node) orelse return unknown;
            const layer: Layer = if (pointer.size == .one) .pointer else .sequence;
            return wrap(layer, ofTypeExpr(items, sources, scope, file, pointer.ast.child_type));
        },
        .error_union => {
            const payload_node = ast.nodeData(node).node_and_node[1];
            return wrap(.error_union, ofTypeExpr(items, sources, scope, file, payload_node));
        },
        .call_one, .call_one_comma, .call, .call_comma => return generic(items, sources, scope, file, node),
        else => return named(items, sources, scope, file, node),
    }
}

/// The declared return type of `function`, with the layer of a bare `!` return type.
pub fn returnType(items: *const Items.Items, sources: *const Sources, function: ItemId) TypeRef {
    const decl = items.get(function);
    if (decl.kind != .function) return unknown;
    const node = decl.type_expr orelse return unknown;
    const scope = decl.parent orelse return unknown;
    const ast = &sources.files[@backingInt(decl.file)].ast;
    const inner = ofTypeExpr(items, sources, scope, decl.file, node);
    const first = ast.firstToken(node);
    if (first > 0 and ast.tokenTag(first - 1) == .bang) return wrap(.error_union, inner);
    return inner;
}

/// The declared type of the struct field `field`.
pub fn fieldType(items: *const Items.Items, sources: *const Sources, field: ItemId) TypeRef {
    const decl = items.get(field);
    if (decl.kind != .field) return unknown;
    const node = decl.type_expr orelse return unknown;
    const scope = decl.parent orelse return unknown;
    return ofTypeExpr(items, sources, scope, decl.file, node);
}

/// One pointer off, for `.field`. A value with no layers is its own access base.
pub fn deref(t: TypeRef) TypeRef {
    if (t.layers.len == 0) return t;
    return peel(t, .pointer);
}

/// The element of a slice, array or many-item pointer.
pub fn element(t: TypeRef) TypeRef {
    return peel(t, .sequence);
}

/// The child of an optional, as `.?`, `orelse` and an `if` capture give it.
pub fn unwrap(t: TypeRef) TypeRef {
    return peel(t, .optional);
}

/// The success type of an error union.
pub fn payload(t: TypeRef) TypeRef {
    return peel(t, .error_union);
}

fn peel(t: TypeRef, layer: Layer) TypeRef {
    if (t.layers.len == 0 or t.layers.buf[0] != layer) return unknown;
    var out = t;
    std.mem.copyForwards(Layer, out.layers.buf[0 .. out.layers.len - 1], out.layers.buf[1..out.layers.len]);
    out.layers.len -= 1;
    return out;
}

/// `inner` with `layer` added outermost. Unknown when the layers would overflow.
pub fn wrap(layer: Layer, inner: TypeRef) TypeRef {
    if (inner.layers.len == max_layers) return unknown;
    var out = inner;
    var i: usize = out.layers.len;
    while (i > 0) : (i -= 1) out.layers.buf[i] = out.layers.buf[i - 1];
    out.layers.buf[0] = layer;
    out.layers.len += 1;
    return out;
}

fn isContainer(kind: Items.Kind) bool {
    return kind == .type or kind == .namespace;
}

fn named(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index) TypeRef {
    const target = Names.resolvePath(items, sources, scope, file, node) orelse return unknown;
    if (!isContainer(items.get(target).kind)) return unknown;
    return .{ .container = target };
}

/// `Ring(u8)`: the container that a type-returning function `Ring` returns.
fn generic(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index) TypeRef {
    const ast = &sources.files[@backingInt(file)].ast;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = ast.fullCall(&buffer, node) orelse return unknown;
    const callee = Names.resolvePath(items, sources, scope, file, call.ast.fn_expr) orelse return unknown;
    const decl = items.get(callee);
    if (!isContainer(decl.kind)) return unknown;
    const owner = &sources.files[@backingInt(decl.file)].ast;
    if (owner.nodeTag(decl.decl) != .fn_decl) return unknown;
    return .{ .container = callee };
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

const fixture =
    \\const std = @import("std");
    \\const Foo = struct { x: u8 };
    \\const Err = error{Boom};
    \\pub fn Ring(comptime T: type) type {
    \\    return struct { item: T };
    \\}
    \\pub const Holder = struct {
    \\    const Self = @This();
    \\    ptr: ?*Foo,
    \\    items: []Foo,
    \\    plain: u8,
    \\    pub fn self_ptr() *Self {}
    \\    pub fn const_ptr() *const Foo {}
    \\    pub fn opt_ptr() ?*Foo {}
    \\    pub fn slice() []Foo {}
    \\    pub fn array() [4]Foo {}
    \\    pub fn many() [*]Foo {}
    \\    pub fn bang() !Foo {}
    \\    pub fn bang_opt() !?Foo {}
    \\    pub fn err_opt() Err!?Foo {}
    \\    pub fn deep() ????Foo {}
    \\    pub fn deeper() ?????Foo {}
    \\    pub fn ring() Ring(u8) {}
    \\    pub fn std_list() std.ArrayList(u8) {}
    \\    pub fn any(x: anytype) u8 { _ = x; }
    \\    pub fn plain() u8 {}
    \\};
    \\
;

fn loadFixture(arena: Allocator) !struct { sources: Sources, items: Items.Items, main: FileId } {
    const memory: Sources.Memory = .{ .entries = &.{.{ .path = "src/main.zig", .text = fixture }} };
    var failure: Sources.Failure = .{};
    const sources = try Sources.load(arena, memory.reader(), "src/main.zig", &.{}, &failure);
    const items = try Items.collect(arena, &sources);
    return .{ .sources = sources, .items = items, .main = sources.findFile("src/main.zig").? };
}

fn ref(container: ?ItemId, layers: []const Layer) TypeRef {
    var out: TypeRef = .{ .container = container };
    for (layers, 0..) |layer, i| out.layers.buf[i] = layer;
    out.layers.len = @intCast(layers.len);
    return out;
}

fn expectRef(expected: TypeRef, got: TypeRef) !void {
    try testing.expectEqual(expected.container, got.container);
    try testing.expectEqualSlices(Layer, expected.layers.slice(), got.layers.slice());
}

const Row = struct { fun: []const u8, container: ?[]const u8, layers: []const Layer };

const return_rows = [_]Row{
    .{ .fun = "self_ptr", .container = "Holder", .layers = &.{.pointer} },
    .{ .fun = "const_ptr", .container = "Foo", .layers = &.{.pointer} },
    .{ .fun = "opt_ptr", .container = "Foo", .layers = &.{ .optional, .pointer } },
    .{ .fun = "slice", .container = "Foo", .layers = &.{.sequence} },
    .{ .fun = "array", .container = "Foo", .layers = &.{.sequence} },
    .{ .fun = "many", .container = "Foo", .layers = &.{.sequence} },
    .{ .fun = "bang", .container = "Foo", .layers = &.{.error_union} },
    .{ .fun = "bang_opt", .container = "Foo", .layers = &.{ .error_union, .optional } },
    .{ .fun = "err_opt", .container = "Foo", .layers = &.{ .error_union, .optional } },
    .{ .fun = "deep", .container = "Foo", .layers = &.{ .optional, .optional, .optional, .optional } },
    .{ .fun = "deeper", .container = null, .layers = &.{} },
    .{ .fun = "ring", .container = "Ring", .layers = &.{} },
    .{ .fun = "std_list", .container = null, .layers = &.{} },
    .{ .fun = "any", .container = null, .layers = &.{} },
    .{ .fun = "plain", .container = null, .layers = &.{} },
};

test "returnType reads each type-expression form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loadFixture(arena.allocator());
    const items = &loaded.items;
    const sources = &loaded.sources;
    const holder = Items.lookup(items, items.files[@backingInt(loaded.main)], "Holder").?;
    for (return_rows) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.fun});
        const got = returnType(items, sources, Items.lookup(items, holder, row.fun).?);
        const expect_container: ?ItemId = if (row.container) |name| Items.lookup(items, items.files[@backingInt(loaded.main)], name).? else null;
        try testing.expectEqual(expect_container, got.container);
        try testing.expectEqualSlices(Layer, row.layers, got.layers.slice());
    }
}

test "fieldType reads declared field types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loadFixture(arena.allocator());
    const items = &loaded.items;
    const sources = &loaded.sources;
    const holder = Items.lookup(items, items.files[@backingInt(loaded.main)], "Holder").?;
    const foo = Items.lookup(items, items.files[@backingInt(loaded.main)], "Foo").?;
    const ptr = fieldType(items, sources, Items.lookup(items, holder, "ptr").?);
    try expectRef(ref(foo, &.{ .optional, .pointer }), ptr);
    try expectRef(ref(foo, &.{.sequence}), fieldType(items, sources, Items.lookup(items, holder, "items").?));
    try expectRef(unknown, fieldType(items, sources, Items.lookup(items, holder, "plain").?));
    try expectRef(ref(foo, &.{}), deref(unwrap(ptr)));
}

test "layer operations peel the outermost layer or give unknown" {
    const foo: ItemId = @fromBackingInt(3);
    try expectRef(ref(foo, &.{}), deref(ref(foo, &.{})));
    try expectRef(ref(foo, &.{}), deref(ref(foo, &.{.pointer})));
    try expectRef(ref(foo, &.{.pointer}), deref(ref(foo, &.{ .pointer, .pointer })));
    try expectRef(unknown, deref(ref(foo, &.{ .optional, .pointer })));
    try expectRef(unknown, deref(ref(foo, &.{.sequence})));
    try expectRef(ref(foo, &.{}), element(ref(foo, &.{.sequence})));
    try expectRef(unknown, element(ref(foo, &.{.pointer})));
    try expectRef(ref(foo, &.{.pointer}), unwrap(ref(foo, &.{ .optional, .pointer })));
    try expectRef(unknown, unwrap(ref(foo, &.{.pointer})));
    try expectRef(ref(foo, &.{.optional}), payload(ref(foo, &.{ .error_union, .optional })));
    try expectRef(unknown, payload(ref(foo, &.{.optional})));
}

test "an anytype parameter has no type node, so no type is read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loadFixture(arena.allocator());
    const items = &loaded.items;
    const sources = &loaded.sources;
    const holder = Items.lookup(items, items.files[@backingInt(loaded.main)], "Holder").?;
    const any = items.get(Items.lookup(items, holder, "any").?);
    const ast = &sources.files[@backingInt(any.file)].ast;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buffer, syntax.protoNode(ast, any.decl)).?;
    var params = proto.iterate(ast);
    const first = params.next().?;
    try testing.expectEqual(@as(?Ast.Node.Index, null), first.type_expr);
}
