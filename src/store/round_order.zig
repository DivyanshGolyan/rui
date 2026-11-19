const std = @import("std");

pub const Kind = enum { always, branch, paged, raw };
pub const Commit = enum { none, transaction, single };
pub const Next = enum { done, commit };
pub const CommitError = enum { none, declined, other };
pub const Ending = enum { answer, abandon_then_answer, commit, declined_abandon_then_answer, fail };

// Indices refer to declared rounds; the caller supplies valid indices.
pub fn follows(kinds: []const Kind, last: ?u8, next: u8) bool {
    const before = last orelse return true;
    if (next == before) return kinds[next] == .paged or kinds[next] == .raw;
    return next > before;
}

// runRound checks this independently of the selected access.
pub inline fn opened(begin: ?u8, last: ?u8) bool {
    const first = begin orelse return false;
    const next: u8 = if (last) |previous| previous + 1 else 0;
    return next >= first;
}

// Access is chosen before the step names its next round. Preserve the early
// return for begin=0, including when last+1 would overflow in opened().
pub inline fn inside(commit: Commit, begin: ?u8, last: ?u8) bool {
    if (commit == .none) return false;
    if (begin != null and begin.? == 0) return true;
    return opened(begin, last);
}

pub fn budget(kinds: []const Kind, commit: Commit) usize {
    var count: usize = @intFromBool(commit != .none);
    for (kinds) |kind| count += @intFromBool(kind == .always);
    return count;
}

// A commit for a read-only transition is uninhabited in transition.Next.
// Commit errors do not exist when the step finishes with done.
pub fn ending(commit: Commit, next: Next, commit_error: CommitError) Ending {
    if (next == .done) return if (commit == .none) .answer else .abandon_then_answer;
    std.debug.assert(commit != .none);
    return switch (commit_error) {
        .none => .commit,
        .declined => .declined_abandon_then_answer,
        .other => .fail,
    };
}

test "SH-97 round ordering and budget over all declarations" {
    const kinds_by_digit = [_]Kind{ .always, .branch, .paged, .raw };
    // Rows: no last, then last 0..3; columns: next 0..3.
    const later = [5][4]bool{
        .{ true, true, true, true },
        .{ false, true, true, true },
        .{ false, false, true, true },
        .{ false, false, false, true },
        .{ false, false, false, false },
    };
    const repeats = [4]bool{ false, false, true, true };
    const always_counts = [16]usize{ 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 };
    const commits = [_]Commit{ .none, .transaction, .single };
    const commit_counts = [_]usize{ 0, 1, 1 };
    var kinds: [4]Kind = undefined;
    for (1..5) |len| {
        var total: usize = 1;
        for (0..len) |_| total *= 4;
        for (0..total) |declaration| {
            var digits = declaration;
            var always_mask: usize = 0;
            for (0..len) |i| {
                const digit = digits % 4;
                digits /= 4;
                kinds[i] = kinds_by_digit[digit];
                if (digit == 0) always_mask |= @as(usize, 1) << @intCast(i);
            }
            for (0..len + 1) |row| for (0..len) |column| {
                const last: ?u8 = if (row == 0) null else @intCast(row - 1);
                const expected = if (row != 0 and row - 1 == column)
                    repeats[@backingInt(kinds[column])]
                else
                    later[row][column];
                try std.testing.expectEqual(expected, follows(kinds[0..len], last, @intCast(column)));
            };
            for (commits, commit_counts) |commit, additional| {
                try std.testing.expectEqual(always_counts[always_mask] + additional, budget(kinds[0..len], commit));
            }
        }
    }
}

test "SH-97 transaction boundary and admitted states" {
    // Rows begin: none, 0..3; columns last: none, 0..3.
    const expected = [5][5]bool{
        .{ false, false, false, false, false },
        .{ true, true, true, true, true },
        .{ false, true, true, true, true },
        .{ false, false, true, true, true },
        .{ false, false, false, true, true },
    };
    const commits = [_]Commit{ .none, .transaction, .single };
    for (1..5) |len| for (0..len + 1) |begin_row| for (0..len + 1) |last_col| {
        const begin: ?u8 = if (begin_row == 0) null else @intCast(begin_row - 1);
        const last: ?u8 = if (last_col == 0) null else @intCast(last_col - 1);
        for (commits) |commit| {
            if (commit == .none and begin != null) continue;
            try std.testing.expectEqual(if (commit == .none) false else expected[begin_row][last_col], inside(commit, begin, last));
        }
    };
    try std.testing.expect(inside(.transaction, 0, 255));
    try std.testing.expect(inside(.single, 0, 255));
}

test "SH-97 ending decisions for admitted combinations" {
    const commits = [_]Commit{ .none, .transaction, .single };
    const done = [_]Ending{ .answer, .abandon_then_answer, .abandon_then_answer };
    const errors = [_]CommitError{ .none, .declined, .other };
    const expected = [_]Ending{ .commit, .declined_abandon_then_answer, .fail };
    for (commits, done) |commit, result| {
        // A done step does not attempt a commit, so no commit error exists.
        try std.testing.expectEqual(result, ending(commit, .done, .none));
        // .none + .commit is uninhabited and deliberately not called.
        if (commit != .none) for (errors, expected) |err, want| {
            try std.testing.expectEqual(want, ending(commit, .commit, err));
        };
    }
}

test "SH-97 admission and pre-effect assertion products" {
    const all = [4]bool{ true, true, true, true };
    const one_out = [4]bool{ true, false, false, false };
    const one_in = [4]bool{ false, true, true, true };
    const two_out = [4]bool{ true, true, false, false };
    const two_in = [4]bool{ false, false, true, true };
    const three_out = [4]bool{ true, true, true, false };
    const three_in = [4]bool{ false, false, false, true };
    // begin rows none,0..3; last rows none,0..3; columns requested round 0..3.
    // false means the original runRound assertion rejects that request.
    const assertion_holds = [5][5][4]bool{
        .{ all, all, all, all, all },
        .{ all, all, all, all, all },
        .{ one_out, one_in, one_in, one_in, one_in },
        .{ two_out, two_out, two_in, two_in, two_in },
        .{ three_out, three_out, three_out, three_in, three_in },
    };
    // Rows are begin none,0..3 and columns are the mask of .always rounds.
    // These classify declarations rejected by check; they give no result for them.
    const admitted_prefix = [5][16]bool{
        .{ true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true },
        .{ true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true },
        .{ false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true },
        .{ false, false, false, true, false, false, false, true, false, false, false, true, false, false, false, true },
        .{ false, false, false, false, false, false, false, true, false, false, false, false, false, false, false, true },
    };
    const admitted_commit = [3][5]bool{
        .{ true, false, false, false, false },
        .{ true, true, true, true, true },
        .{ true, true, true, true, true },
    };
    const commits = [_]Commit{ .none, .transaction, .single };
    const kinds_by_digit = [_]Kind{ .always, .branch, .paged, .raw };
    // Evaluate only declarations admitted by check and pairs admitted by
    // follows. These value checks do not observe the actual shell panic.
    for (1..5) |len| {
        var declarations: usize = 1;
        for (0..len) |_| declarations *= 4;
        for (0..declarations) |declaration| {
            var digits = declaration;
            var kinds: [4]Kind = undefined;
            var always_mask: usize = 0;
            for (0..len) |i| {
                kinds[i] = kinds_by_digit[digits % 4];
                if (kinds[i] == .always) always_mask |= @as(usize, 1) << @intCast(i);
                digits /= 4;
            }
            for (0..len + 1) |begin_row| {
                const begin: ?u8 = if (begin_row == 0) null else @intCast(begin_row - 1);
                var valid_prefix = true;
                for (0..(if (begin) |b| @as(usize, b) else 0)) |i| {
                    if (kinds[i] != .always) valid_prefix = false;
                }
                for (commits, 0..) |commit, commit_index| {
                    const admitted = valid_prefix and (commit != .none or begin == null);
                    try std.testing.expectEqual(admitted_prefix[begin_row][always_mask] and admitted_commit[commit_index][begin_row], admitted);
                    if (!admitted) continue;
                    for (0..len + 1) |last_row| for (0..len) |next| {
                        const last: ?u8 = if (last_row == 0) null else @intCast(last_row - 1);
                        if (last) |previous| {
                            if (next < previous) continue;
                            if (next == previous and kinds[next] != .paged and kinds[next] != .raw) continue;
                        }
                        const requested_inside = if (begin) |b| next >= b else false;
                        const was_opened = opened(begin, last);
                        try std.testing.expectEqual(assertion_holds[begin_row][last_row][next], requested_inside == was_opened);
                    };
                }
            }
        }
    }
}
