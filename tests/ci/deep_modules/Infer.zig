//! Value types inside a function body (deep-modules U7 and U8). `bind` gives each
//! name a function declares its TypeRef: parameters, locals and captures. `typeOf`
//! gives an expression the type that the syntax and the declarations show. Any
//! other expression, including `if` and `switch` expressions, `anytype`, `@field`
//! and std types, is `Types.unknown`, so a lint never acts on a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Captures = @import("Captures.zig");
const Items = @import("Items.zig");
const Names = @import("Names.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const Values = @import("Values.zig");
const syntax = @import("ItemSyntax.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;
const TypeRef = Types.TypeRef;

/// The names a function body declares, with their types. Zig forbids shadowing, so
/// one map per function is enough. Sibling blocks may reuse a name, so a name bound
/// twice keeps its type only when both bindings agree; otherwise it is unknown.
pub const Locals = struct {
    names: std.StringHashMapUnmanaged(TypeRef) = .empty,

    /// The type of `name` in this function, or null when the name is not a local.
    pub fn get(self: *const Locals, name: []const u8) ?TypeRef {
        return self.names.get(name);
    }

    fn put(self: *Locals, arena: Allocator, name: []const u8, t: TypeRef) Allocator.Error!void {
        const old = self.names.get(name) orelse return self.names.put(arena, name, t);
        if (!Values.sameType(old, t)) try self.names.put(arena, name, Types.unknown);
    }
};

/// Gives each name that `function` declares a type: its parameters, then its
/// declarations and captures in source order. `nodes` are the function's own nodes
/// (Bodies.nodes). `locals` must start empty.
pub fn bind(arena: Allocator, locals: *Locals, items: *const Items.Items, sources: *const Sources, function: ItemId, nodes: []const Ast.Node.Index) Allocator.Error!void {
    return bindWithParams(arena, locals, items, sources, function, nodes, &.{});
}

/// `bind`, with the types of the anytype parameters given by `param_types`, by parameter index.
/// A null entry, or an index past the end, leaves that parameter unknown.
pub fn bindWithParams(arena: Allocator, locals: *Locals, items: *const Items.Items, sources: *const Sources, function: ItemId, nodes: []const Ast.Node.Index, param_types: []const ?TypeRef) Allocator.Error!void {
    const item = items.get(function);
    if (item.kind != .function) return;
    const tree = &sources.files[@backingInt(item.file)].ast;
    const env: Env = .{ .locals = locals, .items = items, .sources = sources, .scope = item.parent orelse return, .file = item.file };
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, syntax.protoNode(tree, item.decl)) orelse return;
    var params = proto.iterate(tree);
    var index: usize = 0;
    while (params.next()) |param| : (index += 1) {
        const name_token = param.name_token orelse continue;
        const t = if (param.type_expr) |type_node|
            Types.ofTypeExpr(items, sources, env.scope, env.file, type_node)
        else if (index < param_types.len) (param_types[index] orelse Types.unknown) else Types.unknown;
        try locals.put(arena, tree.tokenSlice(name_token), Values.known(t));
    }
    for (try Captures.collect(arena, tree, nodes)) |site| try env.bindSite(arena, locals, site);
}

/// Binds the parameters and declarations of a function nested in `holder`'s body (a
/// function inside a function, or inside an anonymous struct of one). Bodies gives its code
/// to `holder`, so its names share `holder`'s map: Zig forbids shadowing, and a name bound
/// twice keeps its type only when both bindings agree. `decl` is the nested fn_decl and
/// `nodes` the nodes of its declaration.
pub fn bindNested(arena: Allocator, locals: *Locals, items: *const Items.Items, sources: *const Sources, holder: ItemId, decl: Ast.Node.Index, nodes: []const Ast.Node.Index) Allocator.Error!void {
    const item = items.get(holder);
    const env: Env = .{ .locals = locals, .items = items, .sources = sources, .scope = item.parent orelse return, .file = item.file };
    const tree = env.ast();
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buffer, syntax.protoNode(tree, decl))) |proto| {
        var params = proto.iterate(tree);
        while (params.next()) |param| {
            const name_token = param.name_token orelse continue;
            const t = if (param.type_expr) |type_node| Types.ofTypeExpr(items, sources, env.scope, env.file, type_node) else Types.unknown;
            try locals.put(arena, tree.tokenSlice(name_token), Values.known(t));
        }
    }
    for (try Captures.collect(arena, tree, nodes)) |site| try env.bindSite(arena, locals, site);
}

/// Adds one branch's type to the type that the branches agree on; false when it is unknown or differs.
fn joinBranch(out: *?TypeRef, t: TypeRef) bool {
    if (t.container == null) return false;
    if (out.*) |prev| return Values.sameType(prev, t);
    out.* = t;
    return true;
}

/// The type of the expression `node` in `file`, inside container `scope`, with the
/// locals of its function. `result` is the type the context expects, which types
/// `.{...}`, `.decl(...)` and `@ptrCast`; pass `Types.unknown` when there is none.
pub fn typeOf(locals: *const Locals, items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index, result: TypeRef) TypeRef {
    const env: Env = .{ .locals = locals, .items = items, .sources = sources, .scope = scope, .file = file };
    return env.value(node, result);
}

/// The function item that `node` names as a callee, in `scope` of `file`, with the locals
/// of its function. `result` is the type the call's value is expected to have (see typeOf).
pub fn calleeOf(locals: *const Locals, items: *const Items.Items, sources: *const Sources, scope: ItemId, file: FileId, node: Ast.Node.Index, result: TypeRef) ?ItemId {
    const env: Env = .{ .locals = locals, .items = items, .sources = sources, .scope = scope, .file = file };
    return env.callee(node, result);
}

/// What an expression is typed in: its function's locals, and the container and file
/// whose names it refers to.
const Env = struct {
    locals: *const Locals,
    items: *const Items.Items,
    sources: *const Sources,
    scope: ItemId,
    file: FileId,

    fn ast(env: Env) *const Ast {
        return &env.sources.files[@backingInt(env.file)].ast;
    }

    fn value(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        return Values.known(env.infer(node, result));
    }

    fn infer(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const tree = env.ast();
        const data = tree.nodeData(node);
        return switch (tree.nodeTag(node)) {
            .identifier => env.identifier(node),
            .grouped_expression => env.value(data.node_and_token[0], result),
            .field_access => env.fieldAccess(node),
            .unwrap_optional => Types.unwrap(env.value(data.node_and_token[0], Types.unknown)),
            .deref => Values.pointee(env.value(data.node, Types.unknown)),
            .address_of => Types.wrap(.pointer, env.value(data.node, Values.pointee(result))),
            .@"try" => Types.payload(env.value(data.node, Types.unknown)),
            .@"catch" => Types.payload(env.value(data.node_and_node[0], Types.unknown)),
            .@"orelse" => Types.unwrap(env.value(data.node_and_node[0], Types.unknown)),
            .array_access => Types.element(Values.sequenceOf(env.value(data.node_and_node[0], Types.unknown))),
            .slice_open, .slice, .slice_sentinel => env.slice(node),
            .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot, .array_init_dot_comma, .array_init, .array_init_comma => env.literal(node, result),
            .call_one, .call_one_comma, .call, .call_comma => env.call(node, result),
            .if_simple, .@"if" => env.ifExpr(node, result),
            .@"switch", .switch_comma => env.switchExpr(node, result),
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => env.builtin(node, result),
            .enum_literal => env.declLiteral(node, result),
            else => Types.unknown,
        };
    }

    /// A local, else the declaration the name refers to.
    fn identifier(env: Env, node: Ast.Node.Index) TypeRef {
        const tree = env.ast();
        if (env.locals.get(tree.tokenSlice(tree.nodeMainToken(node)))) |t| return t;
        const item = Names.resolvePath(env.items, env.sources, env.scope, env.file, node) orelse return Types.unknown;
        return Values.declType(env.items, env.sources, item);
    }

    /// A field of a value, or a declaration reached through names when the head is not a local.
    fn fieldAccess(env: Env, node: Ast.Node.Index) TypeRef {
        const tree = env.ast();
        const base, const name_token = tree.nodeData(node).node_and_token;
        if (!env.headIsLocal(node)) {
            if (Names.resolvePath(env.items, env.sources, env.scope, env.file, node)) |item| return Values.declType(env.items, env.sources, item);
        }
        const owner = Values.instanceOwner(env.value(base, Types.unknown)) orelse return Types.unknown;
        const field = Items.lookup(env.items, owner, tree.tokenSlice(name_token)) orelse return Types.unknown;
        if (env.items.get(field).kind != .field) return Types.unknown;
        return Types.fieldType(env.items, env.sources, field);
    }

    fn headIsLocal(env: Env, node: Ast.Node.Index) bool {
        const tree = env.ast();
        var head = node;
        while (tree.nodeTag(head) == .field_access) head = tree.nodeData(head).node_and_token[0];
        if (tree.nodeTag(head) != .identifier) return false;
        return env.locals.get(tree.tokenSlice(tree.nodeMainToken(head))) != null;
    }

    fn slice(env: Env, node: Ast.Node.Index) TypeRef {
        const sliced = env.ast().fullSlice(node) orelse return Types.unknown;
        const seq = Values.sequenceOf(env.value(sliced.ast.sliced, Types.unknown));
        if (seq.layers.len == 0 or seq.layers.slice()[0] != .sequence) return Types.unknown;
        return seq;
    }

    /// `T{...}` is T; `.{...}` takes the type the context expects.
    fn literal(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const tree = env.ast();
        var struct_buffer: [2]Ast.Node.Index = undefined;
        var array_buffer: [2]Ast.Node.Index = undefined;
        const explicit: ?Ast.Node.Index = if (tree.fullStructInit(&struct_buffer, node)) |lit|
            lit.ast.type_expr.unwrap()
        else if (tree.fullArrayInit(&array_buffer, node)) |lit|
            lit.ast.type_expr.unwrap()
        else
            null;
        if (explicit) |type_node| return Types.ofTypeExpr(env.items, env.sources, env.scope, env.file, type_node);
        return Values.stripWrappers(result);
    }

    /// `f(...)`, `T.f(...)`, `value.m(...)` and `.m(...)`: the callee's declared return type.
    fn call(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        var buffer: [1]Ast.Node.Index = undefined;
        const call_node = env.ast().fullCall(&buffer, node) orelse return Types.unknown;
        const function = env.callee(call_node.ast.fn_expr, result) orelse return Types.unknown;
        return Types.returnType(env.items, env.sources, function);
    }

    /// The function item that a callee names.
    fn callee(env: Env, node: Ast.Node.Index, result: TypeRef) ?ItemId {
        const tree = env.ast();
        switch (tree.nodeTag(node)) {
            .identifier => {
                if (env.locals.get(tree.tokenSlice(tree.nodeMainToken(node))) != null) return null;
                const item = Names.resolvePath(env.items, env.sources, env.scope, env.file, node) orelse return null;
                return Values.asFunction(env.items, item);
            },
            .field_access => {
                const base, const name_token = tree.nodeData(node).node_and_token;
                if (!env.headIsLocal(node)) {
                    if (Names.resolvePath(env.items, env.sources, env.scope, env.file, node)) |item| return Values.asFunction(env.items, item);
                }
                const owner = Values.instanceOwner(env.value(base, Types.unknown)) orelse return null;
                return Values.method(env.items, owner, tree.tokenSlice(name_token));
            },
            .enum_literal => {
                const owner = Values.literalOwner(result) orelse return null;
                return Values.method(env.items, owner, tree.tokenSlice(tree.nodeMainToken(node)));
            },
            else => return null,
        }
    }

    /// `.name` with a known result type: the declaration `name` of that type.
    fn declLiteral(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const tree = env.ast();
        const owner = Values.literalOwner(result) orelse return Types.unknown;
        const found = Items.lookup(env.items, owner, tree.tokenSlice(tree.nodeMainToken(node))) orelse return Types.unknown;
        return Values.declType(env.items, env.sources, found);
    }

    /// `if (c) a else b` is the type that both branches have. A branch that does not
    /// return a value (`unreachable`, `return`, `break`, `continue`, `@panic`) is left out.
    fn ifExpr(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const info = env.ast().fullIf(node) orelse return Types.unknown;
        const else_node = info.ast.else_expr.unwrap() orelse return Types.unknown;
        var out: ?TypeRef = null;
        for ([_]Ast.Node.Index{ info.ast.then_expr, else_node }) |branch| {
            if (env.exits(branch)) continue;
            if (!joinBranch(&out, env.value(branch, result))) return Types.unknown;
        }
        return out orelse Types.unknown;
    }

    /// A `switch` is the type that every prong with a value has, as `ifExpr` gives it.
    fn switchExpr(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const tree = env.ast();
        const info = tree.fullSwitch(node) orelse return Types.unknown;
        var out: ?TypeRef = null;
        for (info.ast.cases) |case| {
            const target = (tree.fullSwitchCase(case) orelse return Types.unknown).ast.target_expr;
            if (env.exits(target)) continue;
            if (!joinBranch(&out, env.value(target, result))) return Types.unknown;
        }
        return out orelse Types.unknown;
    }

    fn exits(env: Env, node: Ast.Node.Index) bool {
        const tree = env.ast();
        return switch (tree.nodeTag(node)) {
            .unreachable_literal, .@"return", .@"break", .@"continue" => true,
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@panic"),
            else => false,
        };
    }

    /// `@as(T, e)` is T; `@ptrCast` and `@alignCast` take the type the context expects.
    fn builtin(env: Env, node: Ast.Node.Index, result: TypeRef) TypeRef {
        const tree = env.ast();
        var buffer: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buffer, node) orelse return Types.unknown;
        const name = tree.tokenSlice(tree.nodeMainToken(node));
        if (std.mem.eql(u8, name, "@as") and args.len == 2) return Types.ofTypeExpr(env.items, env.sources, env.scope, env.file, args[0]);
        if (std.mem.eql(u8, name, "@ptrCast") or std.mem.eql(u8, name, "@alignCast")) return result;
        return Types.unknown;
    }

    /// The captures of one site, typed from its subject.
    fn bindSite(env: Env, arena: Allocator, locals: *Locals, site: Captures.Site) Allocator.Error!void {
        const tree = env.ast();
        switch (site.role) {
            .var_decl => {
                const decl = tree.fullVarDecl(site.node) orelse return;
                const name = tree.tokenSlice(decl.ast.mut_token + 1);
                const t = if (decl.ast.type_node.unwrap()) |type_node|
                    Types.ofTypeExpr(env.items, env.sources, env.scope, env.file, type_node)
                else if (decl.ast.init_node.unwrap()) |init|
                    env.value(init, Types.unknown)
                else
                    Types.unknown;
                try locals.put(arena, name, Values.known(t));
            },
            .optional_capture => try bindCapture(arena, locals, tree, site.order, Types.unwrap(env.value(site.subject.?, Types.unknown))),
            .error_capture => try locals.put(arena, tree.tokenSlice(site.order), Types.unknown),
            .for_captures => try env.bindFor(arena, locals, site),
            .switch_capture => try env.bindSwitch(arena, locals, site),
        }
    }

    /// `for (a, b) |x, y|`: each capture is the element of its input; an index capture is unknown.
    fn bindFor(env: Env, arena: Allocator, locals: *Locals, site: Captures.Site) Allocator.Error!void {
        const tree = env.ast();
        const inputs = tree.fullFor(site.node).?.ast.inputs;
        var token = site.order;
        var index: usize = 0;
        while (tree.tokenTag(token) != .pipe) : (index += 1) {
            const is_pointer = tree.tokenTag(token) == .asterisk;
            if (is_pointer) token += 1;
            const name = tree.tokenSlice(token);
            token += 1;
            var t = Types.unknown;
            if (index < inputs.len) {
                t = Types.element(Values.sequenceOf(env.value(inputs[index], Types.unknown)));
                if (is_pointer) t = Types.wrap(.pointer, t);
            }
            try locals.put(arena, name, Values.known(t));
            if (tree.tokenTag(token) != .comma) break;
            token += 1;
        }
    }

    /// `switch (u) { .tag => |p| }`: the payload of the variant when `u` is a known union.
    fn bindSwitch(env: Env, arena: Allocator, locals: *Locals, site: Captures.Site) Allocator.Error!void {
        const tree = env.ast();
        const values = tree.fullSwitchCase(site.node).?.ast.values;
        var t = Types.unknown;
        if (values.len == 1 and tree.nodeTag(values[0]) == .enum_literal) {
            if (Values.instanceOwner(env.value(site.subject.?, Types.unknown))) |owner| {
                t = Captures.variantType(env.items, env.sources, owner, tree.tokenSlice(tree.nodeMainToken(values[0])));
            }
        }
        try bindCapture(arena, locals, tree, site.order, t);
    }
};

/// The capture at `token` (`x` or `*x`) takes `t`; `*x` takes a pointer to it.
fn bindCapture(arena: Allocator, locals: *Locals, tree: *const Ast, token: Ast.TokenIndex, t: TypeRef) Allocator.Error!void {
    if (tree.tokenTag(token) == .asterisk) {
        return locals.put(arena, tree.tokenSlice(token + 1), Values.known(Types.wrap(.pointer, t)));
    }
    return locals.put(arena, tree.tokenSlice(token), Values.known(t));
}
