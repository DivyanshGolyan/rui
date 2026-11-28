//! Wrappers (deep-modules U10): functions whose whole body only passes a call or a field
//! on. A forwarder is `return target(params...)` or `return self.f.m(params...)`, with the
//! parameters in order. An accessor is `return self.f`, `return &self.f` or `self.f = p`.
//! The shape is read from the AST; each name resolves through the References that
//! `collect` already made, so a name means what it means everywhere else in the lint.

const Wrappers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Items = @import("Items.zig");
const Names = @import("Names.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const syntax = @import("ItemSyntax.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;

pub const Wrapper = union(enum) {
    /// A call to `target` with the parameters in order. `fields` are the fields of self
    /// that the call goes through (`self.f.m(...)` has `f`); none for a plain call.
    forwarder: struct { target: ItemId, fields: []const ItemId },
    /// A method that hands out or writes fields of self. `lent` are the fields it lends
    /// by reference or writes; `copied` are the fields it returns by value. `to_read` says
    /// the lent pointer is const, so a caller can only read through it.
    accessor: struct { lent: []const ItemId, copied: []const ItemId, to_read: bool },
};

/// Every wrapper among `items`' functions, keyed by function.
pub fn find(arena: Allocator, items: *const Items.Items, sources: *const Sources, refs: []const References.Reference) Allocator.Error!std.AutoHashMapUnmanaged(ItemId, Wrapper) {
    var named: std.AutoHashMapUnmanaged(u64, ItemId) = .empty;
    for (refs) |ref| try named.put(arena, tokenKey(ref.file, ref.token), ref.item);
    const cx: Ctx = .{ .arena = arena, .items = items, .sources = sources, .by_token = named };
    var found: std.AutoHashMapUnmanaged(ItemId, Wrapper) = .empty;
    for (items.list, 0..) |item, i| {
        if (item.kind != .function) continue;
        const id: ItemId = @fromBackingInt(@intCast(i));
        if (try cx.wrapperOf(id)) |wrapper| try found.put(arena, id, wrapper);
    }
    return found;
}

fn tokenKey(file: FileId, token: Ast.TokenIndex) u64 {
    return (@as(u64, @backingInt(file)) << 32) | token;
}

/// The function's parameter names, in order, and its return type expression.
const Signature = struct { names: []const Ast.TokenIndex, return_type: ?Ast.Node.Index };

const Ctx = struct {
    arena: Allocator,
    items: *const Items.Items,
    sources: *const Sources,
    /// The item each name token resolves to, from the References.
    by_token: std.AutoHashMapUnmanaged(u64, ItemId),

    fn wrapperOf(cx: Ctx, id: ItemId) Allocator.Error!?Wrapper {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        if (tree.nodeTag(item.decl) != .fn_decl) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, tree.nodeData(item.decl).node_and_node[1]) orelse return null;
        if (statements.len != 1) return null;
        const sig = (try cx.signature(id)) orelse return null;
        const statement = statements[0];
        return switch (tree.nodeTag(statement)) {
            .@"return" => blk: {
                const value = tree.nodeData(statement).opt_node.unwrap() orelse break :blk null;
                if (try cx.forwarder(id, value, sig)) |wrapper| break :blk wrapper;
                break :blk try cx.handsOut(id, value, sig);
            },
            .assign => try cx.setter(id, statement, sig),
            else => null,
        };
    }

    fn signature(cx: Ctx, id: ItemId) Allocator.Error!?Signature {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, syntax.protoNode(tree, item.decl)) orelse return null;
        var names: std.ArrayList(Ast.TokenIndex) = .empty;
        var params = proto.iterate(tree);
        while (params.next()) |param| try names.append(cx.arena, param.name_token orelse return null);
        return .{ .names = names.items, .return_type = proto.ast.return_type.unwrap() };
    }

    fn named(cx: Ctx, file: FileId, token: Ast.TokenIndex) ?ItemId {
        return cx.by_token.get(tokenKey(file, token));
    }

    fn isFunction(cx: Ctx, id: ItemId) bool {
        return cx.items.get(id).kind == .function;
    }

    /// `return target(params...)` or `return self.f.m(params...)`.
    fn forwarder(cx: Ctx, id: ItemId, value: Ast.Node.Index, sig: Signature) Allocator.Error!?Wrapper {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, value) orelse return null;
        const callee = call.ast.fn_expr;
        switch (tree.nodeTag(callee)) {
            .identifier => {
                const target = cx.named(item.file, tree.nodeMainToken(callee)) orelse return null;
                if (!cx.isFunction(target) or !argsAre(tree, call.ast.params, sig.names)) return null;
                return .{ .forwarder = .{ .target = target, .fields = &.{} } };
            },
            .field_access => {
                const base, const method = tree.nodeData(callee).node_and_token;
                const target = cx.named(item.file, method) orelse return null;
                if (!cx.isFunction(target)) return null;
                if (cx.selfField(id, base)) |field| {
                    if (!item.takesSelf() or !argsAre(tree, call.ast.params, sig.names[1..])) return null;
                    return .{ .forwarder = .{ .target = target, .fields = try cx.arena.dupe(ItemId, &.{field}) } };
                }
                if (Names.resolvePath(cx.items, cx.sources, item.parent orelse return null, item.file, base) == null) return null;
                if (!argsAre(tree, call.ast.params, sig.names)) return null;
                return .{ .forwarder = .{ .target = target, .fields = &.{} } };
            },
            else => return null,
        }
    }

    /// `return self.f` (a copy) or `return &self.f` (a borrow).
    fn handsOut(cx: Ctx, id: ItemId, value: Ast.Node.Index, sig: Signature) Allocator.Error!?Wrapper {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        if (tree.nodeTag(value) == .address_of) {
            const field = cx.selfField(id, tree.nodeData(value).node) orelse return null;
            return .{ .accessor = .{
                .lent = try cx.arena.dupe(ItemId, &.{field}),
                .copied = &.{},
                .to_read = returnsConst(tree, sig),
            } };
        }
        const field = cx.selfField(id, value) orelse return null;
        return .{ .accessor = .{ .lent = &.{}, .copied = try cx.arena.dupe(ItemId, &.{field}), .to_read = false } };
    }

    /// `self.f = p`, with `p` another parameter.
    fn setter(cx: Ctx, id: ItemId, statement: Ast.Node.Index, sig: Signature) Allocator.Error!?Wrapper {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        if (tree.nodeTag(statement) != .assign) return null;
        const lhs, const rhs = tree.nodeData(statement).node_and_node;
        const field = cx.selfField(id, lhs) orelse return null;
        if (tree.nodeTag(rhs) != .identifier or sig.names.len < 2) return null;
        const value_name = tree.tokenSlice(tree.nodeMainToken(rhs));
        for (sig.names[1..]) |name| {
            if (std.mem.eql(u8, tree.tokenSlice(name), value_name)) {
                return .{ .accessor = .{ .lent = try cx.arena.dupe(ItemId, &.{field}), .copied = &.{}, .to_read = false } };
            }
        }
        return null;
    }

    /// The field of self that `node` names as `self.f`, when `id` takes self.
    fn selfField(cx: Ctx, id: ItemId, node: Ast.Node.Index) ?ItemId {
        const item = cx.items.get(id);
        if (!item.takesSelf()) return null;
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        if (tree.nodeTag(node) != .field_access) return null;
        const base, const name = tree.nodeData(node).node_and_token;
        if (tree.nodeTag(base) != .identifier) return null;
        const self_name = cx.selfToken(id) orelse return null;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(base)), tree.tokenSlice(self_name))) return null;
        const field = cx.named(item.file, name) orelse return null;
        return if (cx.items.get(field).kind == .field) field else null;
    }

    fn selfToken(cx: Ctx, id: ItemId) ?Ast.TokenIndex {
        const item = cx.items.get(id);
        const tree = &cx.sources.files[@backingInt(item.file)].ast;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, syntax.protoNode(tree, item.decl)) orelse return null;
        var params = proto.iterate(tree);
        const first = params.next() orelse return null;
        return first.name_token;
    }
};

/// Whether the return type names a const, so a pointer it returns is read-only.
fn returnsConst(tree: *const Ast, sig: Signature) bool {
    const return_type = sig.return_type orelse return false;
    for (tree.firstToken(return_type)..tree.lastToken(return_type) + 1) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_const) return true;
    }
    return false;
}

/// Whether the call arguments are exactly the names, in order: each is an identifier with that name.
fn argsAre(tree: *const Ast, args: []const Ast.Node.Index, names: []const Ast.TokenIndex) bool {
    if (args.len != names.len) return false;
    for (args, names) |arg, name| {
        if (tree.nodeTag(arg) != .identifier) return false;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), tree.tokenSlice(name))) return false;
    }
    return true;
}
