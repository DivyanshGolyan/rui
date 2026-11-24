//! The uses of items in production code (deep-modules U9): each name, path, field and
//! literal in a non-test declaration that resolves to an item gives one Reference. A field
//! reached through a value is classified by the expression that uses the place (`classify`).
//! A receiver of unknown type records nothing, so no reference is a guess.

const References = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Bodies = @import("Bodies.zig");
const Infer = @import("Infer.zig");
const Places = @import("Places.zig");
const Items = @import("Items.zig");
const Names = @import("Names.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const Values = @import("Values.zig");
const syntax = @import("ItemSyntax.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;
const TypeRef = Types.TypeRef;

pub const Access = Places.Access;
pub const classify = Places.classify;
pub const Place = Places.Place;
pub const placeOf = Places.placeOf;
pub const suffixBase = Places.suffixBase;
const isStructInit = Places.isStructInit;

pub const Reference = struct {
    /// The module of the code that holds the name.
    from: Sources.NodeId,
    /// The innermost item whose code holds the name.
    holder: ItemId,
    item: ItemId,
    file: FileId,
    token: Ast.TokenIndex,
    access: Access,
};

/// What `collectWithStats` met: production receivers (values whose field or method is
/// named), how many had a known type, and how many of those named a field or method.
pub const Stats = struct { receivers: u32 = 0, typed: u32 = 0, found: u32 = 0 };

pub fn collect(arena: Allocator, sources: *const Sources, items: *const Items.Items) Allocator.Error![]Reference {
    var stats: Stats = .{};
    return collectWithStats(arena, sources, items, &stats);
}

pub fn collectWithStats(arena: Allocator, sources: *const Sources, items: *const Items.Items, stats: *Stats) Allocator.Error![]Reference {
    const bodies = try Bodies.collect(arena, sources, items);
    const locals = try arena.alloc(Infer.Locals, items.list.len);
    for (locals) |*slot| slot.* = .{};
    for (items.list, 0..) |item, i| {
        if (item.kind != .function) continue;
        try Infer.bind(arena, &locals[i], items, sources, nodeItem(i), bodies.nodes[i]);
    }
    var refs: std.ArrayList(Reference) = .empty;
    for (sources.files, 0..) |*file, i| {
        var pass: Pass = .{
            .arena = arena,
            .items = items,
            .sources = sources,
            .bodies = &bodies,
            .locals = locals,
            .file = @fromBackingInt(@intCast(i)),
            .from = file.node,
            .ast = &file.ast,
            .stats = stats,
        };
        try pass.run(&refs);
    }
    return refs.items;
}

/// The fixed-point rounds for expected types: one round per level of literal nesting.
const max_rounds = 8;

fn nodeAt(i: usize) Ast.Node.Index {
    return @fromBackingInt(@intCast(i));
}

fn nodeItem(i: usize) ItemId {
    return @fromBackingInt(@intCast(i));
}

/// Where a name is used: the item holding it, the scope its names resolve in, and its locals.
const Here = struct { holder: ItemId, scope: ItemId, locals: *const Infer.Locals };

/// One file: how its context nodes use places and expect types, then which items each
/// name reaches. The context pass runs to a fixed point, so an expected type can flow
/// through nested literals in any node order.
const Pass = struct {
    arena: Allocator,
    items: *const Items.Items,
    sources: *const Sources,
    bodies: *const Bodies,
    locals: []const Infer.Locals,
    file: FileId,
    from: Sources.NodeId,
    ast: *const Ast,
    stats: *Stats,
    access: std.AutoHashMapUnmanaged(Ast.Node.Index, Access) = .empty,
    expected: std.AutoHashMapUnmanaged(Ast.Node.Index, TypeRef) = .empty,

    fn run(self: *Pass, refs: *std.ArrayList(Reference)) Allocator.Error!void {
        try self.markAccess();
        for (0..max_rounds) |_| {
            var changed = false;
            for (0..self.ast.nodes.len) |i| {
                if (try self.expect(nodeAt(i))) changed = true;
            }
            if (!changed) break;
        }
        try self.emit(refs);
    }

    /// Records the access of every field in a context's place.
    fn markAccess(self: *Pass) Allocator.Error!void {
        for (0..self.ast.nodes.len) |i| {
            var buffer: [1]Ast.Node.Index = undefined;
            const place = placeOf(self.ast, nodeAt(i), &buffer) orelse continue;
            for (place.roots) |root| {
                var cur: ?Ast.Node.Index = root;
                while (cur) |node| : (cur = suffixBase(self.ast, node)) {
                    if (self.ast.nodeTag(node) == .field_access) try self.access.put(self.arena, node, place.access);
                }
            }
        }
    }

    fn here(self: *const Pass, node: Ast.Node.Index) ?Here {
        const holder = self.bodies.holder(self.file, self.ast.firstToken(node)) orelse return null;
        return .{
            .holder = holder,
            .scope = self.items.get(holder).parent orelse holder,
            .locals = &self.locals[@backingInt(holder)],
        };
    }

    fn resultOf(self: *const Pass, node: Ast.Node.Index) TypeRef {
        return self.expected.get(node) orelse Types.unknown;
    }

    /// Gives `node` the expected type `t`; true when that changed the map.
    fn setExpected(self: *Pass, node: Ast.Node.Index, t: TypeRef) Allocator.Error!bool {
        if (t.container == null) return false;
        if (self.expected.get(node)) |old| {
            if (Values.sameType(old, t)) return false;
        }
        try self.expected.put(self.arena, node, t);
        return true;
    }

    /// Gives the operands of a context node their expected types.
    fn expect(self: *Pass, node: Ast.Node.Index) Allocator.Error!bool {
        const at = self.here(node) orelse return false;
        switch (self.ast.nodeTag(node)) {
            .local_var_decl, .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = self.ast.fullVarDecl(node) orelse return false;
                const type_node = decl.ast.type_node.unwrap() orelse return false;
                const init = decl.ast.init_node.unwrap() orelse return false;
                return self.setExpected(init, Types.ofTypeExpr(self.items, self.sources, at.scope, self.file, type_node));
            },
            .@"return" => {
                const operand = self.ast.nodeData(node).opt_node.unwrap() orelse return false;
                if (self.bodies.function(self.file, node) != at.holder) return false;
                return self.setExpected(operand, Types.returnType(self.items, self.sources, at.holder));
            },
            .assign => {
                const lhs, const rhs = self.ast.nodeData(node).node_and_node;
                const t = Infer.typeOf(at.locals, self.items, self.sources, at.scope, self.file, lhs, Types.unknown);
                if (t.layers.len != 0) return false;
                return self.setExpected(rhs, t);
            },
            .call_one, .call_one_comma, .call, .call_comma => return self.expectArguments(at, node),
            else => {
                if (!isStructInit(self.ast.nodeTag(node))) return false;
                return self.expectFields(at, node);
            },
        }
    }

    fn expectArguments(self: *Pass, at: Here, node: Ast.Node.Index) Allocator.Error!bool {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.ast.fullCall(&buffer, node) orelse return false;
        var changed = false;
        if (self.ast.nodeTag(call.ast.fn_expr) == .enum_literal) {
            if (self.expected.get(node)) |t| changed = (try self.setExpected(call.ast.fn_expr, t)) or changed;
        }
        const callee = Infer.calleeOf(at.locals, self.items, self.sources, at.scope, self.file, call.ast.fn_expr, self.resultOf(node)) orelse return changed;
        const offset = self.receiverOffset(at, call.ast.fn_expr, callee);
        for (call.ast.params, 0..) |arg, i| {
            const t = paramType(self.items, self.sources, callee, i + offset) orelse continue;
            changed = (try self.setExpected(arg, t)) or changed;
        }
        return changed;
    }

    /// 1 when a method is called on a value (its `self` is the value), else 0.
    fn receiverOffset(self: *const Pass, at: Here, fn_expr: Ast.Node.Index, callee: ItemId) usize {
        if (self.ast.nodeTag(fn_expr) != .field_access or !self.items.get(callee).takes_self) return 0;
        const base = self.ast.nodeData(fn_expr).node_and_token[0];
        return if (Names.resolvePath(self.items, self.sources, at.scope, self.file, base) == null) 1 else 0;
    }

    fn expectFields(self: *Pass, at: Here, node: Ast.Node.Index) Allocator.Error!bool {
        const owner = self.literalOwner(at, node) orelse return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const lit = self.ast.fullStructInit(&buffer, node) orelse return false;
        var changed = false;
        for (lit.ast.fields) |value| {
            const field = self.fieldNamed(owner, value) orelse continue;
            changed = (try self.setExpected(value, Types.fieldType(self.items, self.sources, field))) or changed;
        }
        return changed;
    }

    /// The container that a literal's fields belong to, from its type or its expected type.
    fn literalOwner(self: *const Pass, at: Here, node: Ast.Node.Index) ?ItemId {
        return Values.literalOwner(Infer.typeOf(at.locals, self.items, self.sources, at.scope, self.file, node, self.resultOf(node)));
    }

    /// The field that `.name = value` in a struct literal names, by the token before `=`.
    fn fieldNamed(self: *const Pass, owner: ItemId, value: Ast.Node.Index) ?ItemId {
        const name = self.ast.firstToken(value) - 2;
        const field = Items.lookup(self.items, owner, self.ast.tokenSlice(name)) orelse return null;
        return if (self.items.get(field).kind == .field) field else null;
    }

    fn emit(self: *Pass, refs: *std.ArrayList(Reference)) Allocator.Error!void {
        for (0..self.ast.nodes.len) |i| {
            const node = nodeAt(i);
            const at = self.here(node) orelse continue;
            switch (self.ast.nodeTag(node)) {
                .identifier => {
                    if (Names.resolvePath(self.items, self.sources, at.scope, self.file, node)) |item| {
                        try self.add(refs, at, item, self.ast.nodeMainToken(node), .copy);
                    }
                },
                .field_access => try self.fieldUse(refs, at, node),
                .enum_literal => {
                    const owner = Values.literalOwner(self.resultOf(node)) orelse continue;
                    const found = Items.lookup(self.items, owner, self.ast.tokenSlice(self.ast.nodeMainToken(node))) orelse continue;
                    try self.add(refs, at, found, self.ast.nodeMainToken(node), .copy);
                },
                else => {
                    if (!isStructInit(self.ast.nodeTag(node))) continue;
                    const owner = self.literalOwner(at, node) orelse continue;
                    var buffer: [2]Ast.Node.Index = undefined;
                    const lit = self.ast.fullStructInit(&buffer, node) orelse continue;
                    for (lit.ast.fields) |value| {
                        const field = self.fieldNamed(owner, value) orelse continue;
                        try self.add(refs, at, field, self.ast.firstToken(value) - 2, .copy);
                    }
                },
            }
        }
    }

    /// `base.name`: a path to a declaration, or a field or method of a value of known type.
    fn fieldUse(self: *Pass, refs: *std.ArrayList(Reference), at: Here, node: Ast.Node.Index) Allocator.Error!void {
        const base, const name = self.ast.nodeData(node).node_and_token;
        if (Names.resolvePath(self.items, self.sources, at.scope, self.file, node)) |item| {
            return self.add(refs, at, item, name, .copy);
        }
        self.stats.receivers += 1;
        const t = Infer.typeOf(at.locals, self.items, self.sources, at.scope, self.file, base, Types.unknown);
        const owner = Values.instanceOwner(t) orelse return;
        self.stats.typed += 1;
        const member = Items.lookup(self.items, owner, self.ast.tokenSlice(name)) orelse return;
        switch (self.items.get(member).kind) {
            .field => {
                self.stats.found += 1;
                try self.add(refs, at, member, name, self.access.get(node) orelse .copy);
            },
            .function => {
                self.stats.found += 1;
                try self.add(refs, at, member, name, .copy);
            },
            else => {},
        }
    }

    fn add(self: *Pass, refs: *std.ArrayList(Reference), at: Here, item: ItemId, token: Ast.TokenIndex, access: Access) Allocator.Error!void {
        try refs.append(self.arena, .{ .from = self.from, .holder = at.holder, .item = item, .file = self.file, .token = token, .access = access });
    }
};

/// The type of parameter `index` of `function`, in the function's container scope; null
/// when the parameter has no type expression (anytype) or `function` is not a function.
fn paramType(items: *const Items.Items, sources: *const Sources, function: ItemId, index: usize) ?TypeRef {
    const item = items.get(function);
    if (item.kind != .function) return null;
    const tree = &sources.files[@backingInt(item.file)].ast;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, syntax.protoNode(tree, item.decl)) orelse return null;
    var params = proto.iterate(tree);
    var i: usize = 0;
    while (params.next()) |param| : (i += 1) {
        if (i != index) continue;
        const type_node = param.type_expr orelse return null;
        return Types.ofTypeExpr(items, sources, item.parent orelse return null, item.file, type_node);
    }
    return null;
}
