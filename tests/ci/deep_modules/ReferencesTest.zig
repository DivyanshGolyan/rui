//! The tests for References.zig (deep-modules U9): the access classification as one table,
//! and fixtures that collect must read as written. Expected values are written by hand.

const std = @import("std");
const Ast = std.zig.Ast;
const Fixture = @import("Fixture.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const Access = References.Access;
const testing = std.testing;

const holder_source =
    \\const Holder = struct { f: u8, g: u8 };
    \\fn g(x: Holder, v: u8, i: usize, a: usize, b: usize, f: anytype) void {
    \\    {STMT}
    \\}
    \\
;

const Row = struct { stmt: []const u8, expect: Access };

/// Each statement puts `x.f` (or `x.f.g`) in one place. A context that uses no place gives copy.
const rows = [_]Row{
    .{ .stmt = "x.f = v;", .expect = .reach },
    .{ .stmt = "x.f += 1;", .expect = .reach },
    .{ .stmt = "x.f.g = v;", .expect = .reach },
    .{ .stmt = "_ = x.f[i];", .expect = .reach },
    .{ .stmt = "_ = x.f[a..b];", .expect = .reach },
    .{ .stmt = "_ = &x.f;", .expect = .borrow },
    .{ .stmt = "_ = &x.f.g;", .expect = .borrow },
    .{ .stmt = "x.f.m();", .expect = .call },
    .{ .stmt = "x.f.g.m();", .expect = .call },
    .{ .stmt = "_ = x.f;", .expect = .copy },
    .{ .stmt = "_ = x.f.g;", .expect = .copy },
    .{ .stmt = "f(x.f);", .expect = .copy },
    .{ .stmt = "x.f.* = v;", .expect = .reach },
};

/// The access of the `x.f` access in the statement, taken from the first context that gives it a place.
fn accessIn(tree: *const Ast, field: Ast.Node.Index) Access {
    for (0..tree.nodes.len) |i| {
        const context: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const access = References.classify(tree, context, field);
        if (access != .copy) return access;
    }
    return .copy;
}

/// The `x.f` node: the first field access on `x` whose name is `f`.
fn fieldNode(tree: *const Ast) ?Ast.Node.Index {
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .field_access) continue;
        const base, const name = tree.nodeData(node).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(name), "f")) continue;
        if (tree.nodeTag(base) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(base)), "x")) return node;
    }
    return null;
}

test "classify gives each place form its access, and copy when the place is only read" {
    for (rows) |row| {
        errdefer std.debug.print("statement: {s}\n", .{row.stmt});
        const replaced = try std.mem.replaceOwned(u8, testing.allocator, holder_source, "{STMT}", row.stmt);
        defer testing.allocator.free(replaced);
        const with_stmt = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{replaced}, 0);
        defer testing.allocator.free(with_stmt);
        var tree = try Ast.parse(testing.allocator, with_stmt, .{});
        defer tree.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), tree.errors.len);
        const field = fieldNode(&tree) orelse return error.TestNoField;
        try testing.expectEqual(row.expect, accessIn(&tree, field));
    }
}

const main_source =
    \\const a = @import("a.zig");
    \\pub const Probe = struct { q: u8 };
    \\pub const Cell = struct {
    \\    n: u8,
    \\    list: [4]u8,
    \\    pub fn bump(self: *Cell) void { self.n += 1; }
    \\    pub fn read(self: *const Cell) u8 { return self.n; }
    \\};
    \\pub fn g(c: *Cell, t: a.Thing) void { c.bump(); _ = t; }
    \\pub fn h(v: anytype) void { _ = v.count; v.bump(); }
    \\pub fn idx(c: *Cell) void { c.list[0] = 1; }
    \\pub fn ptr(c: *Cell) *u8 { return &c.n; }
    \\pub fn lit() Cell { return .{ .n = 1, .list = undefined }; }
    \\pub fn decl() void { const c: Cell = .{ .n = 2, .list = undefined }; _ = c; }
    \\test "t" { var p: Probe = undefined; _ = p.q; }
    \\
;

const a_source = "pub const Thing = struct { n: u8 };\n";

fn load(arena: std.mem.Allocator) !Fixture.Loaded {
    return Fixture.load(arena, &.{
        .{ .path = "src/main.zig", .text = main_source },
        .{ .path = "src/a.zig", .text = a_source },
    }, "src/main.zig");
}

fn accessOf(refs: []const References.Reference, item: ItemId, holder: ItemId) ?Access {
    for (refs) |ref| {
        if (ref.item == item and ref.holder == holder) return ref.access;
    }
    return null;
}

test "collect finds decls across files, methods on typed params, field writes through self, and literal fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try load(a);
    const refs = try References.collect(a, &loaded.sources, &loaded.items);

    const thing = loaded.item("src/a.zig", "Thing");
    const bump = loaded.item("src/main.zig", "Cell.bump");
    const n = loaded.item("src/main.zig", "Cell.n");
    const list = loaded.item("src/main.zig", "Cell.list");
    const cell = loaded.item("src/main.zig", "Cell");

    // A decl reached through an import alias: `a.Thing` in g's parameter type.
    try testing.expectEqual(Access.copy, accessOf(refs, thing, loaded.item("src/main.zig", "g")).?);
    // A method call on a typed parameter: `c.bump()`.
    try testing.expectEqual(Access.copy, accessOf(refs, bump, loaded.item("src/main.zig", "g")).?);
    // A field write through self: `self.n += 1` in bump.
    try testing.expectEqual(Access.reach, accessOf(refs, n, bump).?);
    // A read of self's field: `return self.n` in read.
    try testing.expectEqual(Access.copy, accessOf(refs, n, loaded.item("src/main.zig", "Cell.read")).?);
    // An index write through a typed param: `c.list[0] = 1` in idx.
    try testing.expectEqual(Access.reach, accessOf(refs, list, loaded.item("src/main.zig", "idx")).?);
    // A borrow: `return &c.n` in ptr.
    try testing.expectEqual(Access.borrow, accessOf(refs, n, loaded.item("src/main.zig", "ptr")).?);
    // Struct literal field names with a known result type, from the return type and a var annotation.
    try testing.expectEqual(Access.copy, accessOf(refs, n, loaded.item("src/main.zig", "lit")).?);
    try testing.expectEqual(Access.copy, accessOf(refs, list, loaded.item("src/main.zig", "decl")).?);
    // The annotated type name itself is a reference.
    try testing.expectEqual(Access.copy, accessOf(refs, cell, loaded.item("src/main.zig", "decl")).?);
}

test "references in test blocks and receivers of unknown type record nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try load(a);
    const refs = try References.collect(a, &loaded.sources, &loaded.items);

    const probe = loaded.item("src/main.zig", "Probe");
    const probe_q = loaded.item("src/main.zig", "Probe.q");
    for (refs) |ref| {
        try testing.expect(ref.item != probe);
        try testing.expect(ref.item != probe_q);
    }
    // `v.count` and `v.bump()` on an anytype parameter: nothing is recorded in h.
    const h = loaded.item("src/main.zig", "h");
    for (refs) |ref| try testing.expect(ref.holder != h);
}

test "a reference is held by the innermost item and comes from its file's module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try load(a);
    const refs = try References.collect(a, &loaded.sources, &loaded.items);

    const bump = loaded.item("src/main.zig", "Cell.bump");
    for (refs) |ref| {
        if (ref.item != loaded.item("src/main.zig", "Cell.n") or ref.holder != bump) continue;
        try testing.expectEqual(loaded.file("src/main.zig"), ref.file);
        try testing.expectEqual(loaded.sources.files[@backingInt(ref.file)].node, ref.from);
        return;
    }
    return error.TestNoReference;
}
