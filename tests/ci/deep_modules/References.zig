//! The uses of items in production code (deep-modules U9): each name, path, field and
//! literal in a non-test declaration that resolves to an item gives one Reference. A field
//! reached through a value is classified by the expression that uses the place (`classify`).
//! A receiver of unknown type records nothing, so no reference is a guess. `TestCode` then
//! drops the references held by helpers that only tests run.

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
pub const placeStep = Places.placeStep;
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
    /// A field called through (`access == .call`): the method called on it, when it resolves.
    callee: ?ItemId = null,
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
    const locals = try bindLocals(arena, sources, items, &bodies);
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

/// The names each function item declares, by item: its own parameters and declarations, then
/// those of the functions nested in its body. `bodies` must be Bodies.collect of the same items.
pub fn bindLocals(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies) Allocator.Error![]Infer.Locals {
    const none = try arena.alloc([]const ?Types.TypeRef, items.list.len);
    @memset(none, &.{});
    const locals = try bindWith(arena, sources, items, bodies, none);
    // Only the functions whose anytype parameters now have a type bind again. Re-binding the
    // nested functions is idempotent where their holder is unchanged: a name bound twice keeps
    // its type when both bindings agree.
    const param_types = try anytypeTypes(arena, sources, items, bodies, locals);
    const rebound = try arena.alloc(bool, sources.files.len);
    @memset(rebound, false);
    for (items.list, 0..) |item, i| {
        if (item.kind != .function or !hasTyped(param_types[i])) continue;
        locals[i] = .{};
        rebound[@backingInt(item.file)] = true;
        try Infer.bindWithParams(arena, &locals[i], items, sources, nodeItem(i), bodies.nodes[i], param_types[i]);
    }
    for (rebound, 0..) |changed, i| {
        if (changed) try bindNestedFns(arena, sources, items, bodies, locals, @fromBackingInt(@intCast(i)));
    }
    return locals;
}

fn hasTyped(types: []const ?Types.TypeRef) bool {
    for (types) |t| if (t != null) return true;
    return false;
}

/// The locals of each function item with its anytype parameters given by `param_types` (by item, then index).
fn bindWith(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies, param_types: []const []const ?Types.TypeRef) Allocator.Error![]Infer.Locals {
    const locals = try arena.alloc(Infer.Locals, items.list.len);
    for (locals) |*slot| slot.* = .{};
    for (items.list, 0..) |item, i| {
        if (item.kind != .function) continue;
        try Infer.bindWithParams(arena, &locals[i], items, sources, nodeItem(i), bodies.nodes[i], param_types[i]);
    }
    for (sources.files, 0..) |_, i| try bindNestedFns(arena, sources, items, bodies, locals, @fromBackingInt(@intCast(i)));
    return locals;
}

/// The one type that a function's anytype parameter takes, when every production call passes
/// that type. It is derived only when the function is never used except as a called callee,
/// no production call the walk cannot resolve has its name, and every production call's argument
/// has the same known type. Otherwise the parameter stays unknown.
fn anytypeTypes(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies, locals: []const Infer.Locals) Allocator.Error![]const []const ?Types.TypeRef {
    const Agreed = struct {
        is_any: bool,
        state: enum { none, typed, conflict } = .none,
        t: TypeRef = Types.unknown,
    };
    const slots = try arena.alloc([]Agreed, items.list.len);
    for (slots, items.list) |*slot, item| {
        slot.* = &.{};
        if (item.kind != .function) continue;
        const tree = &sources.files[@backingInt(item.file)].ast;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, syntax.protoNode(tree, item.decl)) orelse continue;
        var list: std.ArrayList(Agreed) = .empty;
        var params = proto.iterate(tree);
        while (params.next()) |param| try list.append(arena, .{ .is_any = param.type_expr == null });
        slot.* = list.items;
    }

    // Only the names of functions with an anytype parameter matter; the walk checks calls by name first.
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (slots, items.list) |slot, item| {
        for (slot) |agreed| if (agreed.is_any) {
            try names.put(arena, item.name, {});
            break;
        };
    }

    // The production calls of those functions, and the names of calls the walk cannot resolve.
    const Site = struct { file: FileId, holder: ItemId, call: Ast.Node.Index, callee: ItemId };
    var sites: std.ArrayList(Site) = .empty;
    var unresolved: std.StringHashMapUnmanaged(void) = .empty;
    const callees = try arena.alloc([]bool, sources.files.len);
    for (sources.files, 0..) |*file, fi| {
        const file_id: FileId = @fromBackingInt(@intCast(fi));
        const tree = &file.ast;
        const is_callee = try arena.alloc(bool, tree.nodes.len);
        @memset(is_callee, false);
        callees[fi] = is_callee;
        var buffer: [1]Ast.Node.Index = undefined;
        for (0..tree.nodes.len) |ni| {
            const node = nodeAt(ni);
            const call = tree.fullCall(&buffer, node) orelse continue;
            is_callee[@backingInt(call.ast.fn_expr)] = true;
            const name = calleeName(tree, call.ast.fn_expr) orelse continue;
            if (!names.contains(name)) continue;
            const holder = bodies.holder(file_id, tree.firstToken(node)) orelse continue;
            const scope = items.get(holder).parent orelse holder;
            if (Infer.calleeOf(&locals[@backingInt(holder)], items, sources, scope, file_id, call.ast.fn_expr, Types.unknown)) |callee| {
                if (slots[@backingInt(callee)].len != 0) try sites.append(arena, .{ .file = file_id, .holder = holder, .call = node, .callee = callee });
            } else {
                try unresolved.put(arena, name, {});
            }
        }
    }

    // A function named anywhere but as a callee (a value, a field, an alias) may be called from code the walk cannot see.
    const escaped = try arena.alloc(bool, items.list.len);
    @memset(escaped, false);
    for (sources.files, 0..) |*file, fi| {
        const file_id: FileId = @fromBackingInt(@intCast(fi));
        const tree = &file.ast;
        for (0..tree.nodes.len) |ni| {
            const node = nodeAt(ni);
            if (callees[fi][ni]) continue;
            if (tree.nodeTag(node) != .identifier and tree.nodeTag(node) != .field_access) continue;
            const name = calleeName(tree, node) orelse continue;
            if (!names.contains(name)) continue;
            const scope = if (bodies.holder(file_id, tree.firstToken(node))) |holder| items.get(holder).parent orelse holder else items.files[fi];
            const item = Names.resolvePath(items, sources, scope, file_id, node) orelse continue;
            escaped[@backingInt(item)] = true;
        }
    }

    // The argument types of each production call to an unescaped function with anytype parameters.
    for (sites.items) |site| {
        const index = @backingInt(site.callee);
        if (escaped[index] or unresolved.contains(items.get(site.callee).name)) continue;
        const tree = &sources.files[@backingInt(site.file)].ast;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, site.call).?;
        const scope = items.get(site.holder).parent orelse site.holder;
        const at = &locals[@backingInt(site.holder)];
        const offset = receiverShift(items, sources, scope, site.file, call.ast.fn_expr, site.callee);
        for (call.ast.params, 0..) |arg, i| {
            const p = i + offset;
            if (p >= slots[index].len or !slots[index][p].is_any) continue;
            const agreed = &slots[index][p];
            if (agreed.state == .conflict) continue;
            const t = Infer.typeOf(at, items, sources, scope, site.file, arg, Types.unknown);
            if (t.container == null) {
                agreed.state = .conflict;
            } else if (agreed.state == .none) {
                agreed.state = .typed;
                agreed.t = t;
            } else if (!Values.sameType(agreed.t, t)) {
                agreed.state = .conflict;
            }
        }
    }

    const out = try arena.alloc([]const ?Types.TypeRef, items.list.len);
    for (slots, out) |slot, *list| {
        const types = try arena.alloc(?Types.TypeRef, slot.len);
        for (slot, types) |agreed, *t| {
            t.* = if (agreed.is_any and agreed.state == .typed) agreed.t else null;
        }
        list.* = types;
    }
    return out;
}

/// The name a callee expression is known by: an identifier, or the last name of a field access.
fn calleeName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => null,
    };
}

/// 1 when `callee` is a method called on a value (its `self` is the value), else 0. Mirrors `receiverOffset`.
fn receiverShift(items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, fn_expr: Ast.Node.Index, callee: ItemId) usize {
    const ast = &sources.files[@backingInt(file)].ast;
    if (ast.nodeTag(fn_expr) != .field_access or !items.get(callee).takesSelf()) return 0;
    const base = ast.nodeData(fn_expr).node_and_token[0];
    return if (Names.resolvePath(items, sources, scope, file, base) == null) 1 else 0;
}

/// Binds the functions nested in a function's body into the locals of the function that holds
/// them. Bodies gives a nested function's code to its holder, and the nested function has no item.
fn bindNestedFns(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies, locals: []Infer.Locals, file: FileId) Allocator.Error!void {
    const tree = &sources.files[@backingInt(file)].ast;
    var decls: std.ArrayList(Ast.Node.Index) = .empty;
    var holders: std.ArrayList(ItemId) = .empty;
    for (0..tree.nodes.len) |i| {
        const node = nodeAt(i);
        if (tree.nodeTag(node) != .fn_decl or bodies.function(file, node) != null) continue;
        const holder = bodies.holder(file, tree.firstToken(node)) orelse continue;
        if (items.get(holder).kind != .function or items.get(holder).decl == node) continue;
        try decls.append(arena, node);
        try holders.append(arena, holder);
    }
    if (decls.items.len == 0) return;
    const lists = try arena.alloc(std.ArrayList(Ast.Node.Index), decls.items.len);
    for (lists) |*list| list.* = .empty;
    for (0..tree.nodes.len) |i| {
        const node = nodeAt(i);
        if (bodies.function(file, node) != null) continue;
        const holder = bodies.holder(file, tree.firstToken(node)) orelse continue;
        if (items.get(holder).kind != .function) continue;
        // The innermost nested declaration that holds the node is the one whose code it is.
        var inner: ?usize = null;
        for (decls.items, 0..) |decl, k| {
            if (tree.firstToken(decl) > tree.firstToken(node) or tree.lastToken(decl) < tree.lastToken(node)) continue;
            if (inner == null or tree.firstToken(decl) > tree.firstToken(decls.items[inner.?])) inner = k;
        }
        if (inner) |k| try lists[k].append(arena, node);
    }
    for (decls.items, holders.items, lists) |decl, holder, list| {
        try Infer.bindNested(arena, &locals[@backingInt(holder)], items, sources, holder, decl, list.items);
    }
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
    /// The call that a field of a place is called through, at any depth of the place.
    called: std.AutoHashMapUnmanaged(Ast.Node.Index, Ast.Node.Index) = .empty,
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
                while (cur) |node| : (cur = placeStep(self.ast, place.access, node)) {
                    if (self.ast.nodeTag(node) != .field_access) continue;
                    try self.access.put(self.arena, node, place.access);
                    if (place.access == .call) try self.called.put(self.arena, node, nodeAt(i));
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
        if (self.ast.nodeTag(fn_expr) != .field_access or !self.items.get(callee).takesSelf()) return 0;
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
                const access = self.access.get(node) orelse .copy;
                try self.addCalled(refs, at, member, name, access, if (access == .call) self.calleeAt(at, node) else null);
            },
            .function => {
                self.stats.found += 1;
                try self.add(refs, at, member, name, .copy);
            },
            else => {},
        }
    }

    fn add(self: *Pass, refs: *std.ArrayList(Reference), at: Here, item: ItemId, token: Ast.TokenIndex, access: Access) Allocator.Error!void {
        try self.addCalled(refs, at, item, token, access, null);
    }

    fn addCalled(self: *Pass, refs: *std.ArrayList(Reference), at: Here, item: ItemId, token: Ast.TokenIndex, access: Access, callee: ?ItemId) Allocator.Error!void {
        try refs.append(self.arena, .{ .from = self.from, .holder = at.holder, .item = item, .file = self.file, .token = token, .access = access, .callee = callee });
    }

    /// The method called on the value `receiver` names, when that call resolves.
    fn calleeAt(self: *const Pass, at: Here, receiver: Ast.Node.Index) ?ItemId {
        const call_node = self.called.get(receiver) orelse return null;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.ast.fullCall(&buffer, call_node) orelse return null;
        return Infer.calleeOf(at.locals, self.items, self.sources, at.scope, self.file, call.ast.fn_expr, self.resultOf(call_node));
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
