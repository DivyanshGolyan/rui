//! The places that a use of a field makes (deep-modules U9): what an assignment, an `&`,
//! an index, a slice or a method call does with the field it reaches. A place is the
//! suffixes `.f`, `.*` and `.?` applied to a root; an index or a slice is its own context.
//! Pure over the AST, so the classification is table-tested on its own.

const std = @import("std");
const Ast = std.zig.Ast;

/// What the code does with a field it reaches: copies it, borrows it, calls a method on it,
/// assigns it (or something inside it), or indexes or slices it.
pub const Access = enum { copy, borrow, call, assign, reach };

/// The place a context node uses, and what the context does with it. `roots` are the
/// expressions whose suffixes are the place (`x.f` has the root `x.f`).
pub const Place = struct { roots: []const Ast.Node.Index, access: Access };

/// How `field` (a field access node) is used by `context` (an assignment, `&`, index,
/// slice or method call): the context's access when `field` is in its place, else copy.
/// A place runs through the suffixes `.f`, `.*` and `.?`; an index or a slice is a
/// context of its own, so it ends the place.
pub fn classify(ast: *const Ast, context: Ast.Node.Index, field: Ast.Node.Index) Access {
    var buffer: [1]Ast.Node.Index = undefined;
    const place = placeOf(ast, context, &buffer) orelse return .copy;
    for (place.roots) |root| {
        var cur: ?Ast.Node.Index = root;
        while (cur) |node| : (cur = placeStep(ast, place.access, node)) {
            if (node == field) return place.access;
        }
    }
    return .copy;
}

/// The place that `node` uses as a context, or null when it uses none.
pub fn placeOf(ast: *const Ast, node: Ast.Node.Index, buffer: *[1]Ast.Node.Index) ?Place {
    switch (ast.nodeTag(node)) {
        .assign_destructure => return .{ .roots = ast.assignDestructure(node).ast.variables, .access = .assign },
        .address_of => {
            buffer[0] = ast.nodeData(node).node;
            return .{ .roots = buffer[0..1], .access = .borrow };
        },
        .array_access => {
            buffer[0] = ast.nodeData(node).node_and_node[0];
            return .{ .roots = buffer[0..1], .access = .reach };
        },
        .slice_open, .slice, .slice_sentinel => {
            buffer[0] = (ast.fullSlice(node) orelse return null).ast.sliced;
            return .{ .roots = buffer[0..1], .access = .reach };
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = ast.fullCall(&call_buffer, node) orelse return null;
            if (ast.nodeTag(call.ast.fn_expr) != .field_access) return null;
            buffer[0] = ast.nodeData(call.ast.fn_expr).node_and_token[0];
            return .{ .roots = buffer[0..1], .access = .call };
        },
        else => {
            if (!isAssign(ast.nodeTag(node))) return null;
            buffer[0] = ast.nodeData(node).node_and_node[0];
            return .{ .roots = buffer[0..1], .access = .assign };
        },
    }
}

/// The next expression down a place: its suffix base, and for an assignment also an index,
/// since `x.f[i] = v` assigns something inside `x.f`.
pub fn placeStep(ast: *const Ast, access: Access, node: Ast.Node.Index) ?Ast.Node.Index {
    if (access == .assign and ast.nodeTag(node) == .array_access) return ast.nodeData(node).node_and_node[0];
    return suffixBase(ast, node);
}

/// The expression a place suffix is applied to, or null when `node` is not a suffix.
pub fn suffixBase(ast: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    return switch (ast.nodeTag(node)) {
        .field_access, .unwrap_optional => ast.nodeData(node).node_and_token[0],
        .deref => ast.nodeData(node).node,
        else => null,
    };
}

pub fn isAssign(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => true,
        else => false,
    };
}

pub fn isStructInit(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma => true,
        else => false,
    };
}
