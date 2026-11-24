//! Shared rules for the values Infer.zig types: the container a value's members
//! belong to, the wrapper layers a literal or an operator strips, and the type a
//! declaration named as a value has. Every rule returns unknown rather than a guess.

const std = @import("std");
const Ast = std.zig.Ast;
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const ItemId = Items.ItemId;
const Layer = Types.Layer;
const TypeRef = Types.TypeRef;

/// The type of a constant named as a value: its annotation, or the T of its `T{...}` initializer.
pub fn declType(items: *const Items.Items, sources: *const Sources, id: ItemId) TypeRef {
    const item = items.get(id);
    if (item.kind != .constant) return Types.unknown;
    const scope = item.parent orelse return Types.unknown;
    if (item.type_expr) |type_node| return Types.ofTypeExpr(items, sources, scope, item.file, type_node);
    const tree = &sources.files[@backingInt(item.file)].ast;
    const decl = tree.fullVarDecl(item.decl) orelse return Types.unknown;
    const init = decl.ast.init_node.unwrap() orelse return Types.unknown;
    var buffer: [2]Ast.Node.Index = undefined;
    const type_node = (tree.fullStructInit(&buffer, init) orelse return Types.unknown).ast.type_expr.unwrap() orelse return Types.unknown;
    return Types.ofTypeExpr(items, sources, scope, item.file, type_node);
}

/// `id` when it is a function, else null.
pub fn asFunction(items: *const Items.Items, id: ItemId) ?ItemId {
    return if (items.get(id).kind == .function) id else null;
}

/// The function `name` declared in `owner`, or null.
pub fn method(items: *const Items.Items, owner: ItemId, name: []const u8) ?ItemId {
    const found = Items.lookup(items, owner, name) orelse return null;
    return asFunction(items, found);
}

/// The container that a value's members belong to, after one pointer. Null when the
/// value has other layers (optional, sequence) or no known container.
pub fn instanceOwner(t: TypeRef) ?ItemId {
    const value = if (t.layers.len > 0 and t.layers.slice()[0] == .pointer) Types.deref(t) else t;
    if (value.layers.len != 0) return null;
    return value.container;
}

/// The container a `.name` literal resolves in: the result type with optional and error wrappers removed.
pub fn literalOwner(result: TypeRef) ?ItemId {
    const t = stripWrappers(result);
    return if (t.layers.len == 0) t.container else null;
}

/// `t` without its leading optional and error-union layers.
pub fn stripWrappers(t: TypeRef) TypeRef {
    var out = t;
    while (out.layers.len > 0) {
        out = switch (out.layers.slice()[0]) {
            .optional => Types.unwrap(out),
            .error_union => Types.payload(out),
            else => return out,
        };
    }
    return out;
}

/// The value a pointer points to; unknown when `t` is not a pointer.
pub fn pointee(t: TypeRef) TypeRef {
    if (t.layers.len == 0 or t.layers.slice()[0] != .pointer) return Types.unknown;
    return Types.deref(t);
}

/// A pointer to an array or slice indexes the array or slice it points to.
pub fn sequenceOf(t: TypeRef) TypeRef {
    const layers = t.layers.slice();
    if (layers.len > 1 and layers[0] == .pointer and layers[1] == .sequence) return Types.deref(t);
    return t;
}

/// A type whose container is unknown is unknown, whatever layers it has.
pub fn known(t: TypeRef) TypeRef {
    return if (t.container == null) Types.unknown else t;
}

/// Whether two types name the same container with the same layers.
pub fn sameType(a: TypeRef, b: TypeRef) bool {
    return a.container == b.container and std.mem.eql(Layer, a.layers.slice(), b.layers.slice());
}
