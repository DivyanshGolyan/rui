//! Which item holds each token and node of a file (deep-modules U9 support). One sweep
//! per file gives every token its innermost enclosing declaration: an item (function,
//! constant, type or field), or a nested function, which is not an item and passes its
//! code on to the item it sits in. Test declarations hold nothing. Infer and Captures
//! then scan one function's own nodes instead of every node of the file.

const Bodies = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Fixture = @import("Fixture.zig");
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const ItemId = Items.ItemId;
const FileId = Sources.FileId;

const none = std.math.maxInt(u32);

/// Per item: the nodes of its file whose own code is that function (header and body,
/// without nested declarations), in node order. Empty for other kinds.
nodes: []const []const Ast.Node.Index,
/// Per file and token: the item that holds the token, or `none` inside a test.
holders: []const []const u32,
/// Per file and node: the function item whose own code holds the node, or `none`.
functions: []const []const u32,

/// The item whose code holds `token` of `file`; null inside a test declaration.
pub fn holder(self: *const Bodies, file: FileId, token: Ast.TokenIndex) ?ItemId {
    return toItem(self.holders[@backingInt(file)][token]);
}

/// The function item whose own code holds `node` of `file`; null for a nested function's
/// code, for a test, and for code outside any function.
pub fn function(self: *const Bodies, file: FileId, node: Ast.Node.Index) ?ItemId {
    return toItem(self.functions[@backingInt(file)][@backingInt(node)]);
}

fn toItem(id: u32) ?ItemId {
    return if (id == none) null else @fromBackingInt(id);
}

/// A declaration's span, and what it holds: an item (`item`), a nested function (`none`),
/// or a test (`test_decl`). `decl` is the node the span belongs to.
const Frame = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    decl: Ast.Node.Index,
    item: u32,
    test_decl: bool,
};

/// Every file's tokens and nodes are assigned in one sweep each, so the cost is linear in
/// the file's size times its nesting depth, not in functions times nodes.
pub fn collect(arena: Allocator, sources: *const Sources, items: *const Items.Items) Allocator.Error!Bodies {
    const per_file = try arena.alloc(std.ArrayList(ItemId), sources.files.len);
    for (per_file) |*list| list.* = .empty;
    for (items.list, 0..) |item, i| try per_file[@backingInt(item.file)].append(arena, @fromBackingInt(@intCast(i)));

    const lists = try arena.alloc(std.ArrayList(Ast.Node.Index), items.list.len);
    for (lists) |*list| list.* = .empty;
    const holders = try arena.alloc([]const u32, sources.files.len);
    const functions = try arena.alloc([]const u32, sources.files.len);
    for (sources.files, 0..) |*file, i| {
        const swept = try sweep(arena, items, &file.ast, per_file[i].items, lists);
        holders[i] = swept.holders;
        functions[i] = swept.functions;
    }
    const nodes = try arena.alloc([]const Ast.Node.Index, items.list.len);
    for (lists, nodes) |*list, *slot| slot.* = list.items;
    return .{ .nodes = nodes, .holders = holders, .functions = functions };
}

const Sweep = struct { holders: []const u32, functions: []const u32 };

/// One file's sweep. Frames are sorted outermost first, so a token's last writer is its
/// innermost frame. `lists` gets each function node, in node order.
fn sweep(arena: Allocator, items: *const Items.Items, ast: *const Ast, file_items: []const ItemId, lists: []std.ArrayList(Ast.Node.Index)) Allocator.Error!Sweep {
    const token_count = ast.tokens.len;
    var frames: std.ArrayList(Frame) = .empty;
    var declared: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
    for (file_items) |id| {
        const item = items.get(id);
        try declared.put(arena, item.decl, {});
        const is_file = item.parent == null;
        try frames.append(arena, .{
            .first = if (is_file) 0 else ast.firstToken(item.decl),
            .last = if (is_file) @intCast(token_count - 1) else ast.lastToken(item.decl),
            .decl = item.decl,
            .item = @backingInt(id),
            .test_decl = false,
        });
    }
    for (0..ast.nodes.len) |i| {
        const node = nodeAt(i);
        const tag = ast.nodeTag(node);
        if (tag != .fn_decl and tag != .test_decl) continue;
        if (declared.contains(node)) continue;
        try frames.append(arena, .{
            .first = ast.firstToken(node),
            .last = ast.lastToken(node),
            .decl = node,
            .item = none,
            .test_decl = tag == .test_decl,
        });
    }
    std.mem.sort(Frame, frames.items, {}, frameBefore);

    const owner = try arena.alloc(u32, token_count);
    @memset(owner, 0);
    const holds = try arena.alloc(u32, frames.items.len);
    for (frames.items, 0..) |frame, i| {
        const parent = owner[frame.first];
        holds[i] = if (frame.test_decl) none else if (frame.item != none) frame.item else holds[parent];
        @memset(owner[frame.first .. frame.last + 1], @as(u32, @intCast(i)));
    }

    const holders = try arena.alloc(u32, token_count);
    for (owner, holders) |frame_index, *slot| slot.* = holds[frame_index];

    const functions = try arena.alloc(u32, ast.nodes.len);
    for (0..ast.nodes.len) |i| {
        const node = nodeAt(i);
        const frame = frames.items[owner[ast.firstToken(node)]];
        const is_function = frame.item != none and items.list[frame.item].kind == .function and frame.decl != node;
        functions[i] = if (is_function) frame.item else none;
        if (is_function) try lists[frame.item].append(arena, node);
    }
    return .{ .holders = holders, .functions = functions };
}

fn frameBefore(_: void, a: Frame, b: Frame) bool {
    if (a.first != b.first) return a.first < b.first;
    return a.last > b.last;
}

fn nodeAt(i: usize) Ast.Node.Index {
    return @fromBackingInt(@intCast(i));
}

const testing = std.testing;

const fixture =
    \\pub fn outer() u8 {
    \\    const v: u8 = 1;
    \\    const g = struct { fn nested() u8 { return 2; } }.nested;
    \\    return v + g();
    \\}
    \\test "t" {
    \\    _ = 3;
    \\}
    \\
;

fn tokenWith(ast: *const Ast, text: []const u8) Ast.TokenIndex {
    for (0..ast.tokens.len) |i| {
        if (std.mem.eql(u8, ast.tokenSlice(@intCast(i)), text)) return @intCast(i);
    }
    unreachable;
}

test "each token is held by its innermost item; tests hold nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try Fixture.load(a, &.{.{ .path = "src/main.zig", .text = fixture }}, "src/main.zig");
    const bodies = try collect(a, &loaded.sources, &loaded.items);
    const file = loaded.file("src/main.zig");
    const ast = &loaded.sources.files[@backingInt(file)].ast;
    const outer = loaded.item("src/main.zig", "outer");

    try testing.expectEqual(outer, bodies.holder(file, tokenWith(ast, "1")).?);
    try testing.expectEqual(outer, bodies.holder(file, tokenWith(ast, "2")).?);
    try testing.expectEqual(@as(?ItemId, null), bodies.holder(file, tokenWith(ast, "3")));
}

test "a function's nodes exclude the nested function and include its locals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try Fixture.load(a, &.{.{ .path = "src/main.zig", .text = fixture }}, "src/main.zig");
    const bodies = try collect(a, &loaded.sources, &loaded.items);
    const file = loaded.file("src/main.zig");
    const ast = &loaded.sources.files[@backingInt(file)].ast;
    const outer = loaded.item("src/main.zig", "outer");
    var locals: usize = 0;
    for (bodies.nodes[@backingInt(outer)]) |node| {
        try testing.expect(ast.nodeTag(node) != .fn_decl);
        switch (ast.nodeTag(node)) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => locals += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), locals);
}
