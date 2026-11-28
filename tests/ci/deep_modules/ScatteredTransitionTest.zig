//! Tests for `scattered-transition`, the owner of catalog invariant CI-104: one fixture per case, expected values written by hand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("Diagnostic.zig");
const Fixture = @import("Fixture.zig");
const References = @import("References.zig");
const Setters = @import("Setters.zig");
const Sources = @import("Sources.zig");
const TestCode = @import("TestCode.zig");

const testing = std.testing;

const main_text = "const q = @import(\"q.zig\");\nconst user = @import(\"user.zig\");\n";

fn count(arena: Allocator, entries: []const Sources.Memory.Entry) !usize {
    return (try checked(arena, entries)).len;
}

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const all = try References.collect(arena, &loaded.sources, &loaded.items);
    const refs = try TestCode.production(arena, &loaded.sources, &loaded.items, all);
    return Setters.check(arena, &loaded.sources, &loaded.items, refs, null, .state);
}

/// `q.zig` with `Q` (`members` inside its braces), and `user.zig` with `in_user` functions that run `stmt` on a `Q`, then `extra`.
/// Each function ends in a second statement, so that none is itself a one-line setter.
fn fixture(arena: Allocator, members: []const u8, stmt: []const u8, in_user: usize, extra: []const u8) ![]const Sources.Memory.Entry {
    var user: std.ArrayList(u8) = .empty;
    try user.appendSlice(arena, "const std = @import(\"std\");\nconst q = @import(\"q.zig\");\n");
    for (0..in_user) |i| try user.print(arena, "pub fn u{d}(x: *q.Q) void {{\n    {s}\n    _ = x;\n}}\n", .{ i, stmt });
    try user.appendSlice(arena, extra);
    return arena.dupe(Sources.Memory.Entry, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = try std.fmt.allocPrint(arena, "pub const Q = struct {{\n{s}}};\n", .{members}) },
        .{ .path = "src/user.zig", .text = user.items },
    });
}

const field = "    state: enum { open, closed } = .open,\n";
const switched = field ++ "    pub fn live(self: Q) bool {\n        return switch (self.state) {\n            .open => true,\n            .closed => false,\n        };\n    }\n";
const compared = field ++ "    pub fn live(self: Q) bool {\n        return self.state != .closed;\n    }\n";

test "a state that two functions assign is a scattered transition, and the report names both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, switched, "x.state = .closed;", 1, "")));
    const got = try checked(a, try fixture(a, switched, "x.state = .closed;", 2, ""));
    try testing.expectEqual(@as(usize, 1), got.len);
    const d = got[0];
    try testing.expectEqual(Diagnostic.Lint.@"scattered-transition", d.lint);
    try testing.expectEqualStrings("q.Q.state", d.key);
    try testing.expectEqualStrings("`Q.state` is a state assigned in 2 functions", d.message);
    try testing.expectEqual(@as(usize, 2), d.notes.len);
    try testing.expectEqualStrings("src/user.zig:4:7: `user.u0` moves `state`", d.notes[0]);
    try testing.expectEqualStrings("src/user.zig:8:7: `user.u1` moves `state`", d.notes[1]);
}

test "a comparison is a branch, and a field nothing branches on is a setting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, compared, "x.state = .closed;", 2, "")));
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, field, "x.state = .closed;", 3, "")));
}

test "only the type's own file branching makes a field a state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const elsewhere = "pub fn live(x: q.Q) bool {\n    return x.state == .closed;\n}\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, field, "x.state = .closed;", 3, elsewhere)));
}

test "a tagged union literal is a transition, and a copied or computed value is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const union_field = "    state: union(enum) { open, sent: u8 } = .open,\n    pub fn live(self: Q) bool {\n        return switch (self.state) {\n            .open => true,\n            .sent => false,\n        };\n    }\n";
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, union_field, "x.state = .{ .sent = 1 };", 2, "")));
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, union_field, "x.state = .open;", 2, "")));
    for ([_][]const u8{ "x.state = x.state;", "x.state = next(x);" }) |stmt| {
        try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, union_field, stmt, 3, "fn next(x: *q.Q) @TypeOf(x.state) {\n    _ = x;\n    return .open;\n}\n")));
    }
}

test "a plain struct or an optional record is no state, whatever literal it is assigned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const record = "    const Rec = struct { n: u8 = 0 };\n    sent: ?Rec = null,\n    pub fn done(self: Q) bool {\n        return self.sent == null;\n    }\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, record, "x.sent = .{ .n = 1 };", 3, "")));
    const named = "    const Kind = enum { open, closed };\n    kind: ?Kind = null,\n    pub fn done(self: Q) bool {\n        return self.kind == null;\n    }\n";
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, named, "x.kind = .closed;", 2, "")));
}

test "a function that only assigns the state is no writer: its callers are" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = switched ++ "    pub fn close(self: *Q) void {\n        self.state = .closed;\n    }\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, members, "x.close();", 1, "")));
    const got = try checked(a, try fixture(a, members, "x.close();", 2, ""));
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("src/user.zig:4:7: `user.u0` moves `state`, through `Q.close`", got[0].notes[0]);
}

test "a flag is not a state, and the state lint leaves it to hand-set-flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = "    dirty: bool = false,\n    pub fn clean(self: Q) bool {\n        return self.dirty == false;\n    }\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, members, "x.dirty = true;", 3, "")));
}

test "test code holds no transitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declared = "test \"t\" {\n    var v: q.Q = .{};\n    v.state = .closed;\n}\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, switched, "x.state = .closed;", 1, declared)));
}
