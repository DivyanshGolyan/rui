//! Test code (deep-modules): the functions that only tests run. `References` skips `test`
//! declarations, but not the helpers and fixtures tests are built from. A function is test
//! code when its body names `std.testing` (directly or through a `testing` alias), or when
//! every reference to it comes from test code. A function nobody references stays
//! production: the lint cannot tell an entry point or a call through an unknown receiver
//! from dead code, and an unknown is never a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Items = @import("Items.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");

/// `refs` without the references that test code holds.
pub fn production(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference) Allocator.Error![]const References.Reference {
    const marked = try mark(arena, sources, items, refs);
    var kept: std.ArrayList(References.Reference) = .empty;
    for (refs) |reference| {
        if (!marked[@backingInt(reference.holder)]) try kept.append(arena, reference);
    }
    return kept.items;
}

/// By ItemId: whether the item is a function of test code.
fn mark(arena: Allocator, sources: *const Sources, items: *const Items.Items, refs: []const References.Reference) Allocator.Error![]bool {
    const marked = try arena.alloc(bool, items.list.len);
    @memset(marked, false);
    for (items.list, marked) |item, *flag| {
        if (item.kind != .function) continue;
        const ast = &sources.files[@backingInt(item.file)].ast;
        var token = ast.firstToken(item.decl);
        const last = ast.lastToken(item.decl);
        while (token <= last) : (token += 1) {
            if (ast.tokenTag(token) == .identifier and std.mem.eql(u8, ast.tokenSlice(token), "testing")) {
                flag.* = true;
                break;
            }
        }
    }
    const from_test = try arena.alloc(u32, items.list.len);
    const from_code = try arena.alloc(u32, items.list.len);
    var changed = true;
    while (changed) {
        changed = false;
        @memset(from_test, 0);
        @memset(from_code, 0);
        for (refs) |reference| {
            if (items.get(reference.item).kind != .function or reference.holder == reference.item) continue;
            if (marked[@backingInt(reference.holder)]) from_test[@backingInt(reference.item)] += 1 else from_code[@backingInt(reference.item)] += 1;
        }
        for (marked, from_code, from_test) |*flag, code, tests| {
            if (!flag.* and code == 0 and tests > 0) {
                flag.* = true;
                changed = true;
            }
        }
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

test "a helper that names std.testing is test code, and so is a function only it calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 0), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}

test "a function a production function also calls, or nobody calls, stays production" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn stage(x: *q.Q) !void {\n    try std.testing.expect(true);\n    set(x);\n}\npub fn run(x: *q.Q) void {\n    set(x);\n}\nfn set(x: *q.Q) void {\n    x.items = 1;\n}\n"));
    try testing.expectEqual(@as(usize, 1), try leaks(a, header ++ "pub fn orphan(x: *q.Q) void {\n    x.items = 1;\n}\n"));
}
