//! Tests for `field-leak` (deep-modules U14): one fixture per case, expected values written by hand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("Diagnostic.zig");
const FieldLeak = @import("FieldLeak.zig");
const Fixture = @import("Fixture.zig");
const Graph = @import("Graph.zig");
const References = @import("References.zig");
const Report = @import("Report.zig");
const Sources = @import("Sources.zig");
const Wrappers = @import("Wrappers.zig");

const testing = std.testing;

const main_text = "const q = @import(\"q.zig\");\nconst user = @import(\"user.zig\");\n";

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    var wrappers = try Wrappers.find(arena, &loaded.items, &loaded.sources, refs);
    const graph = try Graph.build(arena, &loaded.items, refs, &wrappers);
    return FieldLeak.check(arena, &loaded.sources, &loaded.items, refs, &graph, null);
}

fn expectKeys(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |expected, actual| try testing.expectEqualStrings(expected, actual);
}

fn keysOf(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const []const u8 {
    const got = try checked(arena, entries);
    const keys = try arena.alloc([]const u8, got.len);
    for (got, keys) |d, *slot| slot.* = d.key;
    return keys;
}

test "a field an outsider writes is known outside its type, which has a method that reads it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn bump(x: *q.Q) void {\n    x.items = 1;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 1), got.len);
    const d = got[0];
    try testing.expectEqualStrings("q.Q.items", d.key);
    try testing.expectEqualStrings("`Q.items` is known outside `Q`: 1 place in 1 module", d.message);
    try testing.expectEqualStrings("src/user.zig", d.location.?.file);
    try testing.expectEqual(@as(u32, 3), d.location.?.line);
    try testing.expectEqualStrings("src/user.zig:3:7: `user.bump` writes or indexes `items`", d.notes[0]);
    try testing.expectEqual(@as(usize, 1), d.notes.len);
    try testing.expectEqualStrings("q.Q", d.picture.spread.owner);
    try testing.expectEqualStrings("items", d.picture.spread.field);
    try testing.expectEqual(@as(usize, 1), d.picture.spread.modules.len);
    try testing.expectEqual(@as(usize, 1), d.picture.spread.modules[0].count);
    try testing.expectEqualStrings("user", d.picture.spread.modules[0].name);
    try testing.expectEqual(@as(usize, 1), d.picture.spread.others.len);
    try testing.expectEqualStrings("kept: head", d.picture.spread.others[0]);
}

test "a read of a field, and a borrow of plain data, are no leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const read = try keysOf(a, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn peek(x: *q.Q) u8 {\n    return x.items;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), read.len);
    const borrow = try keysOf(a, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Name = struct {\n    text: []const u8,\n    len: u8,\n    pub fn size(self: *Name) usize {\n        self.len += 1;\n        return self.text.len;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn view(n: *q.Name) []const u8 {\n    const p = &n.text;\n    return p.*;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), borrow.len);
}

test "a borrow of a struct field is a leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Inner = struct {\n    n: u8,\n};\npub const Q = struct {\n    inner: Inner,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.inner.n;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn lend(x: *q.Q) *q.Inner {\n    return &x.inner;\n}\n" },
    });
    try expectKeys(&.{"q.Q.inner"}, keys);
}

test "a field nothing outside writes is kept, so a type that keeps none guards nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn reset(x: *q.Q) void {\n    x.items = 0;\n    x.head = 0;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a type whose file works on a hidden field guards it, with or without a method that takes self" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn make(n: u8) Q {\n        var q: Q = undefined;\n        q.items = n;\n        q.head = n;\n        return q;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn bump(x: *q.Q) void {\n    x.items = 1;\n}\n" },
    });
    try expectKeys(&.{"q.Q.items"}, keys);
}

test "a free function in the owner's file that writes a field is no leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n};\npub fn settle(q: *Q) void {\n    q.items = 1;\n    q.head += 1;\n}\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a record whose unused field its file only reads guards nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *const Q) u8 {\n        return self.items + self.head;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn bump(x: *q.Q) void {\n    x.items = 1;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "an insider of the same tangle is no outsider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q, r: *R) u8 {\n        r.touch();\n        self.head += 1;\n        return self.items;\n    }\n};\npub const R = struct {\n    n: u8,\n    pub fn touch(self: *R) void {\n        self.n += 1;\n    }\n    pub fn pour(q: *Q) void {\n        q.items = 0;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a forwarder's caller never sees the fields it forwards to, so calling it is no leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Inner = struct {\n    n: u8,\n    pub fn count(self: *Inner) u8 {\n        return self.n;\n    }\n};\npub const Q = struct {\n    inner: Inner,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.head;\n    }\n    pub fn count(self: *Q) u8 {\n        return self.inner.count();\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn tally(x: *q.Q) u8 {\n    return x.count();\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a void field holds nothing, so an outsider's use of it is no leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    gap: void,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn touch(x: *q.Q) void {\n    _ = &x.gap;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a write through an anytype parameter is unknown, so it is no leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "pub fn set(x: anytype) void {\n    x.items = 1;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "a getter's caller that writes through what it lends is a leak of the field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = try keysOf(arena.allocator(), &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = "pub const Inner = struct {\n    n: u8,\n    pub fn bump(self: *Inner) void {\n        self.n += 1;\n    }\n};\npub const Q = struct {\n    inner: Inner,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.head;\n    }\n    pub fn innerRef(self: *Q) *Inner {\n        return &self.inner;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn poke(x: *q.Q) void {\n    x.innerRef().bump();\n}\n" },
    });
    try expectKeys(&.{"q.Q.inner"}, keys);
}

test "the report of a field two modules write, with its arms and the fields it keeps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try checked(a, &.{
        .{ .path = "src/main.zig", .text = "const q = @import(\"q.zig\");\nconst user = @import(\"user.zig\");\nconst other = @import(\"other.zig\");\n" },
        .{ .path = "src/q.zig", .text = "pub const Q = struct {\n    items: u8,\n    head: u8,\n    pub fn full(self: *Q) u8 {\n        self.head += 1;\n        return self.items;\n    }\n};\n" },
        .{ .path = "src/user.zig", .text = "const q = @import(\"q.zig\");\npub fn bump(x: *q.Q) void {\n    x.items = 1;\n}\n" },
        .{ .path = "src/other.zig", .text = "const q = @import(\"q.zig\");\npub fn reset(x: *q.Q) void {\n    x.items = 0;\n}\n" },
    });
    try testing.expectEqual(@as(usize, 1), got.len);
    var out: std.Io.Writer.Allocating = .init(a);
    try Report.render(&out.writer, got[0]);
    const want =
        \\error[field-leak]: `Q.items` is known outside `Q`: 2 places in 2 modules
        \\  --> src/other.zig:3:7
        \\  = note: src/other.zig:3:7: `other.reset` writes or indexes `items`
        \\  = note: src/user.zig:3:7: `user.bump` writes or indexes `items`
        \\    q.Q
        \\      items ◀━┳━ 1  other
        \\              ┗━ 1  user
        \\      kept: head
        \\
    ;
    try testing.expectEqualStrings(want, out.written());
}
