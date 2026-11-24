//! The table test for Infer.zig (deep-modules U7 and U8). Each row is a source
//! file with exactly one `probe(expr)` call. The row's function is bound, and the
//! expected type is that of `expr`. The expected values are written by hand from
//! the Zig forms; no row is computed by the code under test.

const std = @import("std");
const Ast = std.zig.Ast;
const Infer = @import("Infer.zig");
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const Types = @import("Types.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;
const Layer = Types.Layer;
const testing = std.testing;

const Row = struct {
    /// The whole file; its one `probe(...)` call holds the expression under test.
    text: []const u8,
    /// The container of the expected type, by its name at file level, or null when unknown.
    expect: ?[]const u8,
    layers: []const Layer = &.{},
    /// The type the context expects at `probe`'s argument: a file-level container.
    result: ?[]const u8 = null,
};

const base =
    \\const std = @import("std");
    \\pub fn probe(value: anytype) void { _ = value; }
    \\pub const Foo = struct { x: u8, pub fn initText(n: u8) Foo { return .{ .x = n }; } pub fn selfPtr(self: *Foo) *Foo { return self; } };
    \\pub const Bar = struct { y: u8 };
    \\pub const Holder = struct { const Self = @This(); foo: Foo, ptr: ?*Foo, editors: [4]Foo, pub fn make() Self { return undefined; } };
    \\pub fn make() Foo { return undefined; }
    \\pub fn maybe() ?Foo { return null; }
    \\pub fn fallible() !Foo { return undefined; }
    \\
;

const rows = [_]Row{
    // Parameters, self, annotated locals, and literals.
    .{ .text = base ++ "pub fn g(a: *Foo) void { probe(a); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub const Cell = struct { n: u8, pub fn read(self: *const Cell) void { probe(self); } };\n", .expect = "Cell", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g(raw: *anyopaque) void { const self: *Foo = @ptrCast(raw); probe(self); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g() void { const x: *Foo = make(); probe(x); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g() void { const x = Foo{ .x = 1 }; probe(x); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g() void { probe(@as(Foo, undefined)); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(raw: *anyopaque) void { const x = @ptrCast(raw); probe(x); }\n", .expect = null },
    .{ .text = base ++ "const k = Foo{ .x = 1 };\npub fn g() void { probe(k); }\n", .expect = "Foo" },
    .{ .text = base ++ "const K: *Foo = undefined;\npub fn g() void { probe(K); }\n", .expect = "Foo", .layers = &.{.pointer} },
    // Calls, methods, Self, and the address-of and dereference forms.
    .{ .text = base ++ "pub fn g() void { probe(make()); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(f: *Foo) void { probe(f.selfPtr()); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g() void { probe(Holder.make()); }\n", .expect = "Holder" },
    .{ .text = base ++ "pub fn g() void { probe(Foo.initText(1)); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g() void { var x: Foo = undefined; probe(&x); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g(p: *Foo) void { probe(p.*); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(o: ?*Foo) void { probe(o.?); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g() !void { probe(try fallible()); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g() void { probe(fallible() catch unreachable); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g() void { probe(maybe() orelse unreachable); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(list: []Foo) void { probe(list[0]); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(list: []Foo) void { probe(list[0..1]); }\n", .expect = "Foo", .layers = &.{.sequence} },
    .{ .text = base ++ "pub fn g(self: *Holder, i: usize) void { probe(&self.editors[i]); }\n", .expect = "Foo", .layers = &.{.pointer} },
    // Field chains.
    .{ .text = base ++ "pub fn g(h: *Holder) void { probe(h.foo); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(h: *Holder) void { probe(h.ptr); }\n", .expect = "Foo", .layers = &.{ .optional, .pointer } },
    .{ .text = base ++ "pub fn g(h: *Holder) void { probe(h.foo.x); }\n", .expect = null },
    // Decl literals and struct literals take the result type.
    .{ .text = base ++ "pub fn g() void { probe(.initText(1)); }\n", .expect = "Foo", .result = "Foo" },
    .{ .text = base ++ "pub fn g() void { probe(.make()); }\n", .expect = "Holder", .result = "Holder" },
    .{ .text = base ++ "pub fn g() void { probe(.{ .x = 1 }); }\n", .expect = "Foo", .result = "Foo" },
    .{ .text = base ++ "pub fn g() void { probe(.initText(1)); }\n", .expect = null },
    // Generic type-returning functions.
    .{ .text = base ++ "pub fn Ring(comptime T: type) type { return struct { item: T, len: usize }; }\npub const Cell = struct { ring: Ring(u8) };\npub fn g(c: *Cell) void { probe(c.ring); }\n", .expect = "Ring" },
    .{ .text = base ++ "pub fn Ring(comptime T: type) type { return struct { item: T, len: usize }; }\npub const Cell = struct { ring: Ring(u8) };\npub fn g(c: *Cell) void { probe(c.ring.len); }\n", .expect = null },
    // Unknown never becomes a guess.
    .{ .text = base ++ "pub fn g(x: anytype) void { probe(x); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(c: bool, a: Foo, b: Foo) void { probe(if (c) a else b); }\n", .expect = null },
    .{ .text = base ++ "pub fn g() void { const list: std.ArrayList(u8) = .empty; probe(list); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(f: Foo) void { probe(@field(f, \"x\")); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(v: anytype) void { probe(v.get()); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(f: Foo) void { probe(f.missing); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(c: u8) void { probe(switch (c) { 0 => Foo{ .x = 0 }, else => Foo{ .x = 1 } }); }\n", .expect = null },
    .{ .text = base ++ "pub fn g(c: bool) void { if (c) { const x: *Foo = undefined; _ = x; } else { const x: Bar = undefined; probe(x); } }\n", .expect = null },
    // Captures of if, while, for and switch.
    .{ .text = base ++ "pub fn g(opt: ?Foo) void { if (opt) |x| { probe(x); } }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(opt: ?*Foo) void { if (opt) |x| { probe(x); } }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g(opt: ?Foo) void { if (opt) |*x| { probe(x); } }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub const Iter = struct { pub fn next(self: *Iter) ?Foo { return null; } };\npub fn g(it: *Iter) void { while (it.next()) |x| { probe(x); } }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(s: []Foo) void { for (s) |x| probe(x); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(s: []Foo) void { for (s) |*x| probe(x); }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g(a: []Foo, b: []Bar) void { for (a, b) |x, y| probe(x); }\n", .expect = "Foo" },
    .{ .text = base ++ "pub fn g(a: []Foo, b: []Bar) void { for (a, b) |x, y| probe(y); }\n", .expect = "Bar" },
    .{ .text = base ++ "pub fn g(s: []Foo) void { for (s, 0..) |x, i| probe(i); }\n", .expect = null },
    .{ .text = base ++ "pub const U = union(enum) { tag: Foo, other: u8 };\npub fn g(u: U) void { switch (u) { .tag => |p| probe(p), else => {} } }\n", .expect = "Foo" },
    .{ .text = base ++ "pub const U = union(enum) { tag: Foo, other: u8 };\npub fn g(u: *U) void { switch (u.*) { .tag => |*p| probe(p), else => {} } }\n", .expect = "Foo", .layers = &.{.pointer} },
    .{ .text = base ++ "pub fn g(r: anyerror!Foo) void { if (r) |v| { _ = v; } else |e| { probe(e); } }\n", .expect = null },
    .{ .text = base ++ "pub fn g() void { const r = fallible() catch |e| { probe(e); return; }; _ = r; }\n", .expect = null },
};

const Probe = struct { token: Ast.TokenIndex, arg: Ast.Node.Index };

/// The first `probe(arg)` call in the file, with its first token and its argument.
fn probeCall(tree: *const Ast) ?Probe {
    var buffer: [1]Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .call_one, .call_one_comma, .call, .call_comma => {},
            else => continue,
        }
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr)), "probe")) continue;
        return .{ .token = tree.firstToken(node), .arg = call.ast.params[0] };
    }
    return null;
}

/// The function item whose declaration spans `token`.
fn enclosingFunction(items: *const Items.Items, tree: *const Ast, file: FileId, token: Ast.TokenIndex) ?ItemId {
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        if (token < tree.firstToken(node) or token > tree.lastToken(node)) continue;
        for (items.list, 0..) |item, j| {
            if (item.kind == .function and item.file == file and item.decl == node) return @fromBackingInt(@intCast(j));
        }
    }
    return null;
}

/// The file-level item named `name`.
fn fileItem(items: *const Items.Items, file: FileId, name: []const u8) ItemId {
    return Items.lookup(items, items.files[@backingInt(file)], name).?;
}

/// The item's dotted path inside its file, for example `Holder.Inner`.
fn pathOf(arena: std.mem.Allocator, items: *const Items.Items, id: ItemId) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var current: ?ItemId = id;
    while (current) |c| : (current = items.get(c).parent) {
        if (items.get(c).parent == null) break;
        try parts.append(arena, items.get(c).name);
    }
    std.mem.reverse([]const u8, parts.items);
    return std.mem.join(arena, ".", parts.items);
}

test "typeOf and bind give each form its type, and unknown otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (rows) |row| {
        errdefer std.debug.print("row:\n{s}\n", .{row.text});
        const memory: Sources.Memory = .{ .entries = &.{.{ .path = "src/main.zig", .text = row.text }} };
        var failure: Sources.Failure = .{};
        const sources = try Sources.load(a, memory.reader(), "src/main.zig", &.{}, &failure);
        const items = try Items.collect(a, &sources);
        const file = sources.findFile("src/main.zig").?;
        const tree = &sources.files[@backingInt(file)].ast;
        const probe = probeCall(tree) orelse return error.TestNoProbe;
        const function = enclosingFunction(&items, tree, file, probe.token) orelse return error.TestNoFunction;
        var locals: Infer.Locals = .{};
        try Infer.bind(a, &locals, &items, &sources, function);
        const scope = items.get(function).parent.?;
        const result: Types.TypeRef = if (row.result) |name| .{ .container = fileItem(&items, file, name) } else Types.unknown;
        const got = Infer.typeOf(&locals, &items, &sources, scope, file, probe.arg, result);
        if (row.expect) |expect| {
            const id = got.container orelse return error.TestExpectedContainer;
            try testing.expectEqualStrings(expect, try pathOf(a, &items, id));
        } else {
            try testing.expectEqual(@as(?ItemId, null), got.container);
        }
        try testing.expectEqualSlices(Layer, row.layers, got.layers.slice());
    }
}
