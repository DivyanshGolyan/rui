//! The binding sites of one function body (deep-modules U8): the variable
//! declarations and the captures of `if`, `while`, `for` and `switch`, in source
//! order. A nested function's body is left out, since its names are its own.
//! Infer.zig gives each site its type; `variantType` reads a union's payload.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const ItemId = Items.ItemId;

/// `error_capture` is any name bound to an error or to nothing typed: `else |e|` and `catch |e|`.
pub const Role = enum { var_decl, optional_capture, error_capture, for_captures, switch_capture };

/// `order` is the token that sorts the site: the `const`/`var` of a declaration,
/// or the first token after the `|` of a capture. `node` is the declaration, the
/// loop, or the switch prong. `subject` is the expression the captures are read
/// from: the condition of `if`/`while`, or the switched value.
pub const Site = struct {
    order: Ast.TokenIndex,
    node: Ast.Node.Index,
    subject: ?Ast.Node.Index,
    role: Role,
};

const Span = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

fn within(token: Ast.TokenIndex, span: Span) bool {
    return token >= span.first and token <= span.last;
}

fn inAny(spans: []const Span, token: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (within(token, span)) return true;
    }
    return false;
}

fn before(_: void, a: Site, b: Site) bool {
    return a.order < b.order;
}

/// The sites in the body of `decl` (a fn_decl or fn_proto node), in source order.
pub fn collect(arena: Allocator, ast: *const Ast, decl: Ast.Node.Index) Allocator.Error![]const Site {
    const body: Span = .{ .first = ast.firstToken(decl), .last = ast.lastToken(decl) };
    var found: std.ArrayList(Site) = .empty;
    var nested: std.ArrayList(Span) = .empty;
    for (0..ast.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (ast.nodeTag(node)) {
            .fn_decl => if (node != decl) {
                const span: Span = .{ .first = ast.firstToken(node), .last = ast.lastToken(node) };
                if (within(span.first, body)) try nested.append(arena, span);
            },
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = ast.fullVarDecl(node) orelse continue;
                try found.append(arena, .{ .order = var_decl.ast.mut_token, .node = node, .subject = null, .role = .var_decl });
            },
            .if_simple, .@"if" => {
                const info = ast.fullIf(node).?;
                if (info.payload_token) |token| try found.append(arena, .{ .order = token, .node = node, .subject = info.ast.cond_expr, .role = .optional_capture });
                if (info.error_token) |token| try found.append(arena, .{ .order = token, .node = node, .subject = null, .role = .error_capture });
            },
            .while_simple, .while_cont, .@"while" => {
                const info = ast.fullWhile(node).?;
                if (info.payload_token) |token| try found.append(arena, .{ .order = token, .node = node, .subject = info.ast.cond_expr, .role = .optional_capture });
                if (info.error_token) |token| try found.append(arena, .{ .order = token, .node = node, .subject = null, .role = .error_capture });
            },
            .for_simple, .@"for" => {
                const info = ast.fullFor(node).?;
                try found.append(arena, .{ .order = info.payload_token, .node = node, .subject = null, .role = .for_captures });
            },
            .@"catch" => {
                // `catch |e|`: the error is unknown, but the name is still a local.
                const bar = ast.nodeMainToken(node) + 1;
                if (ast.tokenTag(bar) == .pipe) try found.append(arena, .{ .order = bar + 1, .node = node, .subject = null, .role = .error_capture });
            },
            .@"switch", .switch_comma => {
                const info = ast.fullSwitch(node).?;
                for (info.ast.cases) |case| {
                    const token = (ast.fullSwitchCase(case) orelse continue).payload_token orelse continue;
                    try found.append(arena, .{ .order = token, .node = case, .subject = info.ast.condition, .role = .switch_capture });
                }
            },
            else => {},
        }
    }
    var sites: std.ArrayList(Site) = .empty;
    for (found.items) |site| {
        if (!within(site.order, body) or inAny(nested.items, site.order)) continue;
        try sites.append(arena, site);
    }
    std.mem.sort(Site, sites.items, {}, before);
    return sites.toOwnedSlice(arena);
}

/// The payload type of the variant `tag` of the union container `owner`, or unknown
/// when `owner` is not a union or the variant has no payload.
pub fn variantType(items: *const Items.Items, sources: *const Sources, owner: ItemId, tag: []const u8) Types.TypeRef {
    const container = items.get(owner);
    const node = container.type_expr orelse return Types.unknown;
    const ast = &sources.files[@backingInt(container.file)].ast;
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = ast.fullContainerDecl(&buffer, node) orelse return Types.unknown;
    if (ast.tokenTag(decl.ast.main_token) != .keyword_union) return Types.unknown;
    for (decl.ast.members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(field.ast.main_token), tag)) continue;
        const type_node = field.ast.type_expr.unwrap() orelse return Types.unknown;
        return Types.ofTypeExpr(items, sources, owner, container.file, type_node);
    }
    return Types.unknown;
}
