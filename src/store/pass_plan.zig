const std = @import("std");

pub const Mode = enum { read, survey, write, settlement, single };
pub fn capacity(mode: Mode) u8 {
    return switch (mode) {
        .read, .single => 8,
        .survey => 24,
        .write => 12,
        .settlement => 20,
    };
}
pub fn flushBefore(queued: u8, cap: u8, prepared_already_queued: bool, fits: bool) bool {
    return prepared_already_queued or !fits or queued == cap;
}
pub const Expect = union(enum) { exact: u64, at_most: u64, counted };
pub const Verdict = enum { ok, otherwise, corrupt };
pub fn verdict(expect: Expect, changed: u64, stated: u64) Verdict {
    return switch (expect) {
        .exact => |rows| if (changed == rows) .ok else .otherwise,
        .at_most => |rows| if (changed <= rows) .ok else .corrupt,
        .counted => if (changed == stated) .ok else .otherwise,
    };
}
pub const Class = enum { none, ordinary, fencing };
pub const Source = enum { statement, finish, reset };
// Finding F3: all Store pass and recovery paths share this fencing list.
pub fn fences(err: anyerror) bool {
    return err == error.StoreConnectionLost or err == error.CommitOutcomeUnknown or err == error.OwnershipLost;
}
pub fn surviving(statement: Class, tail_failed: bool, finish: Class, reset: Class) ?Source {
    var result: ?Source = if (statement == .none) null else .statement;
    if (finish == .fencing or (finish == .ordinary and result == null and !tail_failed)) result = .finish;
    if (reset == .fencing or (reset == .ordinary and result == null)) result = .reset;
    return result;
}

// Expected values are transcribed from access.zig before its shell uses this core.
test "SH-95 a pass is sent when it is full, repeats a statement or would not fit" {
    const modes = [_]struct { mode: Mode, cap: u8 }{
        .{ .mode = .read, .cap = 8 },   .{ .mode = .survey, .cap = 24 },
        .{ .mode = .write, .cap = 12 }, .{ .mode = .settlement, .cap = 20 },
        .{ .mode = .single, .cap = 8 },
    };
    const expected = [2][2][2]bool{ .{ .{ true, false }, .{ true, true } }, .{ .{ true, true }, .{ true, true } } };
    for (modes) |row| {
        try std.testing.expectEqual(row.cap, capacity(row.mode));
        for (0..row.cap + 1) |count| for ([_]bool{ false, true }) |repeat| for ([_]bool{ false, true }) |fits| {
            try std.testing.expectEqual(expected[@intFromBool(count == row.cap)][@intFromBool(repeat)][@intFromBool(fits)], flushBefore(@intCast(count), row.cap, repeat, fits));
        };
    }
}

test "SH-96 a write must change the rows it states, and a fencing failure outranks an ordinary one" {
    const exact = [4][4]Verdict{
        .{ .ok, .otherwise, .otherwise, .otherwise }, .{ .otherwise, .ok, .otherwise, .otherwise },
        .{ .otherwise, .otherwise, .ok, .otherwise }, .{ .otherwise, .otherwise, .otherwise, .ok },
    };
    const at_most = [4][4]Verdict{
        .{ .ok, .corrupt, .corrupt, .corrupt }, .{ .ok, .ok, .corrupt, .corrupt },
        .{ .ok, .ok, .ok, .corrupt },           .{ .ok, .ok, .ok, .ok },
    };
    for (0..4) |rows| for (0..4) |changed| for (0..4) |stated| {
        try std.testing.expectEqual(exact[rows][changed], verdict(.{ .exact = rows }, changed, stated));
        try std.testing.expectEqual(at_most[rows][changed], verdict(.{ .at_most = rows }, changed, stated));
        try std.testing.expectEqual(exact[stated][changed], verdict(.counted, changed, stated));
    };
    const N: ?Source = null;
    const S: ?Source = .statement;
    const F: ?Source = .finish;
    const R: ?Source = .reset;
    // Each class dimension is none, ordinary, fencing. A failed tail is
    // reached only when the statement class is none, so it has no other rows.
    const without_tail = [3][3][3]?Source{
        .{ .{ N, R, R }, .{ F, F, R }, .{ F, F, R } },
        .{ .{ S, S, R }, .{ S, S, R }, .{ F, F, R } },
        .{ .{ S, S, R }, .{ S, S, R }, .{ F, F, R } },
    };
    const with_tail = [3][3]?Source{
        .{ N, R, R }, .{ N, R, R }, .{ F, F, R },
    };
    const classes = [_]Class{ .none, .ordinary, .fencing };
    var admitted: usize = 0;
    var excluded: usize = 0;
    for ([_]bool{ false, true }) |tail| for (classes, 0..) |statement, s| for (classes, 0..) |finish, f| for (classes, 0..) |reset, r| {
        // passWith only steps the tail when no statement has failed.
        if (tail and statement != .none) {
            excluded += 1;
            continue;
        }
        admitted += 1;
        try std.testing.expectEqual(if (tail) with_tail[f][r] else without_tail[s][f][r], surviving(statement, tail, finish, reset));
    };
    try std.testing.expectEqual(@as(usize, 36), admitted);
    try std.testing.expectEqual(@as(usize, 18), excluded);
    try std.testing.expect(fences(error.StoreConnectionLost));
    try std.testing.expect(fences(error.CommitOutcomeUnknown));
    try std.testing.expect(fences(error.OwnershipLost));
    try std.testing.expect(!fences(error.StatementFailed));
}
