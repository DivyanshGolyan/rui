//! Test code (deep-modules): the functions that only tests run. `References` skips `test`
//! declarations, but not the helpers and fixtures tests are built from. A function is test
//! code when its body names `std.testing` (directly or through a `testing` alias), or when
//! every place that spells its name is test code. Names are counted, not references: a call
//! through a receiver of unknown type has no reference but still spells the name. A function
//! nobody names stays production: the lint cannot tell an entry point from dead code, and an
//! unknown is never a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bodies = @import("Bodies.zig");
const Items = @import("Items.zig");
const syntax = @import("ItemSyntax.zig");
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

/// By ItemId: whether the item is a function of test code. Test evidence is a function that
/// uses `std.testing`, and every name a `test` declaration spells; test code is what that
/// evidence reaches by spelling names, minus what production code reaches. Production code is
/// every function the evidence does not reach, and any function that a declaration other than a
/// function names. So a group of helpers that name each other, or themselves, is decided as a
/// whole: with a test caller and no production caller it is test code, and with no caller at all
/// it stays production, because the lint cannot tell dead code from an entry point.
fn mark(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies) Allocator.Error![]bool {
    const count = items.list.len;
    const seeds = try arena.alloc(bool, count);
    @memset(seeds, false);
    for (items.list, seeds, 0..) |item, *flag, index| {
        if (item.kind != .function) continue;
        const ast = &sources.files[@backingInt(item.file)].ast;
        if (namesStdTesting(ast, items, bodies, item, @fromBackingInt(@intCast(index)))) flag.* = true;
    }
    const uses = try nameUses(arena, sources, items, bodies);

    // The names each item's own code spells, and the functions of each name.
    const spelled = try arena.alloc(std.ArrayList([]const u8), count);
    @memset(spelled, .empty);
    var test_names: std.ArrayList([]const u8) = .empty;
    var other_names: std.ArrayList([]const u8) = .empty;
    var names = uses.iterator();
    while (names.next()) |entry| {
        for (entry.value_ptr.items) |held| {
            const holder = held orelse {
                try test_names.append(arena, entry.key_ptr.*);
                continue;
            };
            try spelled[@backingInt(holder)].append(arena, entry.key_ptr.*);
            if (items.get(holder).kind != .function) try other_names.append(arena, entry.key_ptr.*);
        }
    }
    var named: std.StringHashMapUnmanaged(std.ArrayList(Items.ItemId)) = .empty;
    for (items.list, 0..) |item, index| {
        if (item.kind != .function) continue;
        const slot = try named.getOrPutValue(arena, item.name, .empty);
        try slot.value_ptr.append(arena, @fromBackingInt(@intCast(index)));
    }

    // Test evidence, and what it reaches.
    const reached_by_tests = try arena.alloc(bool, count);
    @memset(reached_by_tests, false);
    var queue: std.ArrayList(Items.ItemId) = .empty;
    try spread(arena, &named, test_names.items, seeds, reached_by_tests, &queue);
    for (seeds, 0..) |seed, index| {
        if (seed) try queue.append(arena, @fromBackingInt(@intCast(index)));
    }
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        try spread(arena, &named, spelled[@backingInt(queue.items[next])].items, seeds, reached_by_tests, &queue);
    }

    // Production: everything the tests do not reach, and what it reaches.
    const reached_by_code = try arena.alloc(bool, count);
    @memset(reached_by_code, false);
    queue.clearRetainingCapacity();
    for (items.list, 0..) |item, index| {
        if (item.kind != .function or seeds[index] or reached_by_tests[index]) continue;
        reached_by_code[index] = true;
        try queue.append(arena, @fromBackingInt(@intCast(index)));
    }
    try spread(arena, &named, other_names.items, seeds, reached_by_code, &queue);
    next = 0;
    while (next < queue.items.len) : (next += 1) {
        try spread(arena, &named, spelled[@backingInt(queue.items[next])].items, seeds, reached_by_code, &queue);
    }

    const marked = try arena.alloc(bool, count);
    for (items.list, marked, 0..) |item, *flag, index| flag.* = item.kind == .function and (seeds[index] or !reached_by_code[index]);
    return marked;
}

/// Marks the functions of every name in `spelled` that are not a seed and not yet marked, and queues them.
fn spread(arena: Allocator, named: *const std.StringHashMapUnmanaged(std.ArrayList(Items.ItemId)), spelled: []const []const u8, seeds: []const bool, marks: []bool, queue: *std.ArrayList(Items.ItemId)) Allocator.Error!void {
    for (spelled) |name| {
        for ((named.get(name) orelse continue).items) |target| {
            if (seeds[@backingInt(target)] or marks[@backingInt(target)]) continue;
            marks[@backingInt(target)] = true;
            try queue.append(arena, target);
        }
    }
}

const Uses = std.StringHashMapUnmanaged(std.ArrayList(?Items.ItemId));

/// Every token that spells a function's name, outside the declaration of that name, with the
/// item that holds it (null inside a test declaration). A call through a receiver whose type
/// is unknown has no reference, but it still spells the name: so the callers of a function are
/// never fewer than the places that name it, and a function named from production code, however
/// it is reached, is production.
fn nameUses(arena: Allocator, sources: *const Sources, items: *const Items.Items, bodies: *const Bodies) Allocator.Error!Uses {
    var uses: Uses = .empty;
    var declared: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (items.list) |item| {
        if (item.kind != .function) continue;
        _ = try uses.getOrPutValue(arena, item.name, .empty);
        const ast = &sources.files[@backingInt(item.file)].ast;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = ast.fullFnProto(&buffer, syntax.protoNode(ast, item.decl)) orelse continue;
        const name_token = proto.name_token orelse continue;
        try declared.put(arena, (@as(u64, @backingInt(item.file)) << 32) | name_token, {});
    }
    for (sources.files, 0..) |*file, file_index| {
        const ast = &file.ast;
        const file_id: Sources.FileId = @fromBackingInt(@intCast(file_index));
        for (0..ast.tokens.len) |index| {
            const token: std.zig.Ast.TokenIndex = @intCast(index);
            if (ast.tokenTag(token) != .identifier) continue;
            const list = uses.getPtr(ast.tokenSlice(token)) orelse continue;
            if (declared.contains((@as(u64, file_index) << 32) | token)) continue;
            try list.append(arena, bodies.holder(file_id, token));
        }
    }
    return uses;
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

test "a helper that names std.testing is test code, and so is a function only it calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
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

test "a function only a test declaration calls is test code, and so is what it calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "fn set(x: *q.Q) void {\n    x.items = 1;\n}\nfn outer(x: *q.Q) void {\n    set(x);\n}\ntest \"t\" {\n    var v: q.Q = undefined;\n    outer(&v);\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "fn set(x: *q.Q) void {\n    x.items = 1;\n}\npub fn run(x: *q.Q) void {\n    set(x);\n}\ntest \"t\" {\n    var v: q.Q = undefined;\n    set(&v);\n}\n"));
}

test "helpers that only name each other or themselves are decided as a group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = "fn ping(x: *q.Q, n: u8) void {\n    x.items = n;\n    if (n > 0) pong(x, n - 1);\n}\nfn pong(x: *q.Q, n: u8) void {\n    if (n > 0) ping(x, n - 1);\n}\n";
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ pair ++ "test \"t\" {\n    var v: q.Q = undefined;\n    ping(&v, 2);\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ pair ++ "pub fn run(x: *q.Q) void {\n    pong(x, 1);\n}\ntest \"t\" {\n    var v: q.Q = undefined;\n    ping(&v, 2);\n}\n"));
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "fn again(x: *q.Q, n: u8) void {\n    x.items = n;\n    if (n > 0) again(x, n - 1);\n}\ntest \"t\" {\n    var v: q.Q = undefined;\n    again(&v, 2);\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ pair));
}

test "a function a production function names through an unknown receiver stays production" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\npub fn run(setter: anytype, x: *q.Q) void {\n    setter.set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}

test "a function a production function also calls, or nobody calls, stays production" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\npub fn run(x: *q.Q) void {\n    set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn orphan(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}
