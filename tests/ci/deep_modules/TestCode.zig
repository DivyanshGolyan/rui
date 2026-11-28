//! Test code (deep-modules): the functions that only tests run. `References` skips `test`
//! declarations, but not the helpers and fixtures tests are built from. A function is test
//! code when its body names `std.testing` (directly or through a `testing` alias), and no
//! other function is: a rule that reads one function's own tokens cannot be fooled by
//! names, receivers or recursion. A helper that such a function calls stays production,
//! and so does any function nobody uses, because the lint cannot tell an entry point from
//! dead code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bodies = @import("Bodies.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");

/// `refs` without the references that test code holds.
pub fn production(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference) Allocator.Error![]const References.Reference {
    const bodies = try Bodies.collect(arena, sources, items);
    const marked = try mark(arena, sources, items, &bodies);
    var kept: std.ArrayList(References.Reference) = .empty;
    for (refs) |reference| {
        if (!marked[@backingInt(reference.holder)]) try kept.append(arena, reference);
    }
    return kept.items;
}

/// Whether the body of `function` uses `std.testing`: the path itself, or the file's alias
/// `const testing = std.testing`. A parameter, field or declaration that happens to be named
/// `testing` is not that, and neither is a `test` declaration nested in the function: only the
/// tokens `Bodies` gives to the function count.
fn namesStdTesting(ast: *const std.zig.Ast, items: *const Items.Items, bodies: *const Bodies, function: Items.Item, id: Items.ItemId) bool {
    const aliased = fileAliasesTesting(ast, items, function);
    var token = ast.firstToken(function.decl);
    const last = ast.lastToken(function.decl);
    while (token <= last) : (token += 1) {
        if (ast.tokenTag(token) != .identifier or !std.mem.eql(u8, ast.tokenSlice(token), "testing")) continue;
        if (bodies.holder(function.file, token) != id) continue;
        if (token >= 2 and ast.tokenTag(token - 1) == .period) {
            if (ast.tokenTag(token - 2) == .identifier and std.mem.eql(u8, ast.tokenSlice(token - 2), "std")) return true;
            continue;
        }
        const declared = token + 1 <= last and ast.tokenTag(token + 1) == .colon;
        const named = token >= 1 and (ast.tokenTag(token - 1) == .keyword_fn or ast.tokenTag(token - 1) == .keyword_const or ast.tokenTag(token - 1) == .keyword_var);
        if (aliased and !declared and !named) return true;
    }
    return false;
}

fn fileAliasesTesting(ast: *const std.zig.Ast, items: *const Items.Items, function: Items.Item) bool {
    const file_item = items.files[@backingInt(function.file)];
    const found = Items.lookup(items, file_item, "testing") orelse return false;
    const alias = items.get(found);
    if (alias.kind != .alias) return false;
    return std.mem.eql(u8, ast.getNodeSource(alias.alias_of orelse return false), "std.testing");
}

/// By ItemId: whether the item is a function that uses `std.testing`.
fn mark(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies) Allocator.Error![]bool {
    const marked = try arena.alloc(bool, items.list.len);
    for (items.list, marked, 0..) |item, *flag, index| {
        flag.* = false;
        if (item.kind != .function) continue;
        const ast = &sources.files[@backingInt(item.file)].ast;
        flag.* = namesStdTesting(ast, items, bodies, item, @fromBackingInt(@intCast(index)));
    }
    return marked;
}

const testing = std.testing;
const FieldLeak = @import("FieldLeak.zig");
const Fixture = @import("Fixture.zig");
const Graph = @import("Graph.zig");
const Wrappers = @import("Wrappers.zig");

const q_text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n";

fn leaks(arena: Allocator, user: []const u8) !usize {
    const loaded = try Fixture.load(arena, &.{
        .{ .path = "src/main.zig", .text = "const q = @import(\"q.zig\");\nconst user = @import(\"user.zig\");\n" },
        .{ .path = "src/q.zig", .text = q_text },
        .{ .path = "src/user.zig", .text = user },
    }, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    const kept = try production(arena, &loaded.sources, &loaded.items, refs);
    var wrappers = try Wrappers.find(arena, &loaded.items, &loaded.sources, kept);
    const graph = try Graph.build(arena, &loaded.items, kept, &wrappers);
    return (try FieldLeak.check(arena, &loaded.sources, &loaded.items, kept, &graph, null)).len;
}

const header = "const std = @import(\"std\");\nconst q = @import(\"q.zig\");\n";

test "a helper that names std.testing is test code, and what it calls is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}

test "a parameter, field or function named testing is not std.testing, an aliased one is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn run(testing: bool, x: *q.Q) void {\n    if (testing) x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn run(x: *q.Q, o: anytype) void {\n    if (o.testing) x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "const testing = std.testing;\npub fn stage(x: *q.Q) !void {\n    try testing.expect(true);\n    x.items = 1;\n}\n"));
}

test "a test declaration nested in a production function does not make it test code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn run(x: *q.Q) void {\n    const Local = struct {\n        test \"check\" {\n            try std.testing.expect(true);\n        }\n    };\n    _ = Local;\n    x.items = 1;\n}\n"));
}

test "a helper a test declaration calls, and a function nobody calls, stay production" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "fn set(x: *q.Q) void {\n    x.items = 1;\n}\ntest \"t\" {\n    var v: q.Q = undefined;\n    set(&v);\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn orphan(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}
