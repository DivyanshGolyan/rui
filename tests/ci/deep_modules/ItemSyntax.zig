//! Syntax-only facts about declarations (deep-modules U4): how a field's type is
//! plain, whether an initializer is an alias, and which functions return a
//! container. Pure over the AST; Items.zig decides what to record.

const std = @import("std");
const Ast = std.zig.Ast;

/// What a field holds: a scalar, plain data (bytes, slices, arrays and optionals of those), nothing, or anything else.
pub const Plain = enum { scalar, data, nothing, no };

pub const Container = struct { members: []const Ast.Node.Index, is_struct: bool };

pub fn containerIn(ast: *const Ast, buffer: *[2]Ast.Node.Index, node: Ast.Node.Index) ?Container {
    const decl = ast.fullContainerDecl(buffer, node) orelse return null;
    return .{ .members = decl.ast.members, .is_struct = ast.tokenTag(decl.ast.main_token) == .keyword_struct };
}

pub fn hasFields(ast: *const Ast, members: []const Ast.Node.Index) bool {
    for (members) |node| switch (ast.nodeTag(node)) {
        .container_field_init, .container_field_align, .container_field => return true,
        else => {},
    };
    return false;
}

pub fn isBuiltinNamed(ast: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    return switch (ast.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), name),
        else => false,
    };
}

/// An identifier other than a literal value, `@import(..)`, or a field chain on one of them.
fn purePath(ast: *const Ast, node: Ast.Node.Index) bool {
    return switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ast.tokenSlice(ast.nodeMainToken(node));
            return !std.mem.eql(u8, name, "true") and !std.mem.eql(u8, name, "false") and !std.mem.eql(u8, name, "null") and !std.mem.eql(u8, name, "undefined");
        },
        .field_access => purePath(ast, ast.nodeData(node).node_and_token[0]),
        else => isBuiltinNamed(ast, node, "@import"),
    };
}

pub fn isAlias(ast: *const Ast, node: Ast.Node.Index) bool {
    return purePath(ast, node) or isBuiltinNamed(ast, node, "@This");
}

pub fn protoNode(ast: *const Ast, decl: Ast.Node.Index) Ast.Node.Index {
    return if (ast.nodeTag(decl) == .fn_decl) ast.nodeData(decl).node_and_node[0] else decl;
}

/// A `fn F(...) type` whose body returns a container: that container is the type.
pub fn typeReturningContainer(ast: *const Ast, proto: Ast.full.FnProto, body: ?Ast.Node.Index) ?Ast.Node.Index {
    const return_type = proto.ast.return_type.unwrap() orelse return null;
    if (ast.nodeTag(return_type) != .identifier or !std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(return_type)), "type")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = ast.blockStatements(&buffer, body orelse return null) orelse return null;
    for (statements) |statement| {
        if (ast.nodeTag(statement) != .@"return") continue;
        const value = ast.nodeData(statement).opt_node.unwrap() orelse continue;
        var container_buffer: [2]Ast.Node.Index = undefined;
        if (ast.fullContainerDecl(&container_buffer, value) != null) return value;
    }
    return null;
}

fn dataOf(inner: Plain) Plain {
    return if (inner == .scalar or inner == .data) .data else .no;
}

fn scalarName(name: []const u8) Plain {
    if (std.mem.eql(u8, name, "void")) return .nothing;
    if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize") or std.mem.eql(u8, name, "comptime_int")) return .scalar;
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i' and name[0] != 'f')) return .no;
    for (name[1..]) |c| {
        if (!std.ascii.isDigit(c)) return .no;
    }
    if (name[0] == 'f') return .scalar;
    return if (std.mem.eql(u8, name, "u0") or std.mem.eql(u8, name, "i0")) .nothing else .scalar;
}

/// Plainness of a field's type expression, from its syntax alone.
pub fn plainOf(ast: *const Ast, node: Ast.Node.Index) Plain {
    switch (ast.nodeTag(node)) {
        .identifier => return scalarName(ast.tokenSlice(ast.nodeMainToken(node))),
        .optional_type => return dataOf(plainOf(ast, ast.nodeData(node).node)),
        .array_type, .array_type_sentinel => return dataOf(plainOf(ast, ast.fullArrayType(node).?.ast.elem_type)),
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type => {
            const pointer = ast.fullPtrType(node).?;
            if (pointer.size != .slice) return .no;
            return dataOf(plainOf(ast, pointer.ast.child_type));
        },
        .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => {
            var buffer: [2]Ast.Node.Index = undefined;
            const decl = ast.fullContainerDecl(&buffer, node).?;
            const empty_struct = decl.ast.members.len == 0 and ast.tokenTag(decl.ast.main_token) == .keyword_struct;
            return if (empty_struct) .nothing else .no;
        },
        else => return .no,
    }
}
