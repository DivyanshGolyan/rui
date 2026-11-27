//! Tests for `hand-set-flag`: one fixture per case, expected values written by hand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("Diagnostic.zig");
const Fixture = @import("Fixture.zig");
const HandSetFlag = @import("HandSetFlag.zig");
const References = @import("References.zig");
const Sources = @import("Sources.zig");
const TestCode = @import("TestCode.zig");

const testing = std.testing;

const main_text = "const q = @import(\"q.zig\");\nconst user = @import(\"user.zig\");\n";

fn checked(arena: Allocator, entries: []const Sources.Memory.Entry) ![]const Diagnostic.Diagnostic {
    const loaded = try Fixture.load(arena, entries, "src/main.zig");
    const all = try References.collect(arena, &loaded.sources, &loaded.items);
    const refs = try TestCode.production(arena, &loaded.sources, &loaded.items, all);
    return HandSetFlag.check(arena, &loaded.sources, &loaded.items, refs, null);
}

/// Each function ends in a second statement, so that none is itself a one-line setter.
/// `q.zig` with `Q` (`members` inside its braces) and `in_q` free functions that run `stmt` on a `Q`, and `user.zig` with `in_user` of them plus `extra`.
fn fixture(arena: Allocator, members: []const u8, stmt: []const u8, in_q: usize, in_user: usize, extra: []const u8) ![]const Sources.Memory.Entry {
    var q: std.ArrayList(u8) = .empty;
    try q.print(arena, "pub const Q = struct {{\n{s}}};\n", .{members});
    for (0..in_q) |i| try q.print(arena, "pub fn w{d}(x: *Q) void {{\n    {s}\n    _ = x;\n}}\n", .{ i, stmt });
    var user: std.ArrayList(u8) = .empty;
    try user.appendSlice(arena, "const std = @import(\"std\");\nconst q = @import(\"q.zig\");\n");
    for (0..in_user) |i| try user.print(arena, "pub fn u{d}(x: *q.Q) void {{\n    {s}\n    _ = x;\n}}\n", .{ i, stmt });
    try user.appendSlice(arena, extra);
    return arena.dupe(Sources.Memory.Entry, &.{
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/q.zig", .text = q.items },
        .{ .path = "src/user.zig", .text = user.items },
    });
}

const flag = "    dirty: bool = false,\n";
const bits = "    bits: u8 = 0,\n";

fn count(arena: Allocator, entries: []const Sources.Memory.Entry) !usize {
    return (try checked(arena, entries)).len;
}

test "one function that sets a flag is a decision, two are a braid, and the report names both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, flag, "x.dirty = true;", 0, 1, "")));
    const got = try checked(a, try fixture(a, flag, "x.dirty = true;", 0, 2, ""));
    try testing.expectEqual(@as(usize, 1), got.len);
    const d = got[0];
    try testing.expectEqual(Diagnostic.Lint.@"hand-set-flag", d.lint);
    try testing.expectEqualStrings("q.Q.dirty", d.key);
    try testing.expectEqualStrings("`Q.dirty` is set by hand in 2 functions", d.message);
    try testing.expectEqual(@as(usize, 2), d.notes.len);
    try testing.expectEqualStrings("src/user.zig:4:7: `user.u0` sets `dirty`", d.notes[0]);
    try testing.expectEqualStrings("src/user.zig:8:7: `user.u1` sets `dirty`", d.notes[1]);
    try testing.expectEqual(@as(usize, 2), d.picture.spread.modules[0].count);
}

test "setting true or oring bits counts, and every other assignment does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, bits, "x.bits |= 4;", 0, 2, "")));
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, flag, "if (!x.dirty) x.dirty = true;", 0, 2, "")));
    for ([_][]const u8{ "x.dirty = false;", "x.dirty = !x.dirty;", "x.dirty = x.dirty or true;" }) |stmt| {
        try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, flag, stmt, 0, 3, "")));
    }
    for ([_][]const u8{ "x.bits = 1;", "x.bits += 1;", "x.bits &= 1;", "x.bits = x.bits | 1;" }) |stmt| {
        try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, bits, stmt, 0, 3, "")));
    }
}

test "only the field that is set counts, not what is inside it or beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = "    inner: struct { dirty: bool = false } = .{},\n    flags: [2]bool = .{ false, false },\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, inner, "x.inner.dirty = true;", 0, 3, "")));
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, inner, "x.flags[0] = true;", 0, 3, "")));
}

test "a function counts once however often it sets, and setters in every file count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, flag, "x.dirty = true;\n    x.dirty = true;", 0, 1, "")));
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, flag, "x.dirty = true;", 1, 1, "")));
}

test "a function that only sets the flag is no writer: its callers are" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = flag ++ "    pub fn mark(self: *Q) void {\n        self.dirty = true;\n    }\n";
    // One caller of the setter is one decision.
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, members, "x.mark();", 0, 1, "")));
    // Two callers are two copies of the rule, and the note says through what.
    const got = try checked(a, try fixture(a, members, "x.mark();", 0, 2, ""));
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("src/user.zig:4:7: `user.u0` sets `dirty`, through `Q.mark`", got[0].notes[0]);
    // A caller and a direct writer are two.
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, members, "x.mark();", 0, 1, "pub fn direct(x: *q.Q) void {\n    x.dirty = true;\n    _ = x;\n}\n")));
    // A setter that does more is a function like any other: it counts itself, and its callers do not.
    const busy = flag ++ bits ++ "    pub fn mark(self: *Q) void {\n        self.dirty = true;\n        self.bits = 0;\n    }\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, busy, "x.mark();", 0, 2, "")));
    try testing.expectEqual(@as(usize, 1), try count(a, try fixture(a, busy, "x.mark();", 0, 1, "pub fn direct(x: *q.Q) void {\n    x.dirty = true;\n    _ = x;\n}\n")));
}

test "test code holds no setters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declared = "test \"t\" {\n    var v: q.Q = .{};\n    v.dirty = true;\n}\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, flag, "x.dirty = true;", 0, 1, declared)));
    const helper = "pub fn rig(x: *q.Q) !void {\n    try std.testing.expect(true);\n    x.dirty = true;\n}\n";
    try testing.expectEqual(@as(usize, 0), try count(a, try fixture(a, flag, "x.dirty = true;", 0, 1, helper)));
}
