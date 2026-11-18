const std = @import("std");

pub const Phase = enum(u8) { none, ready, first, open, saved, lost };
pub const State = struct { phase: Phase = .none, savepoint: bool = false };
pub const Control = enum { begin, commit, rollback, savepoint, release, rollback_to };
pub const Step = struct { control: ?Control, then: State };

pub fn start(s: State) State {
    std.debug.assert(s.phase == .none and !s.savepoint);
    return .{ .phase = .ready };
}
pub fn begin(s: State) Step {
    return switch (s.phase) {
        .none => .{ .control = .begin, .then = s },
        .ready => .{ .control = .begin, .then = .{ .phase = .first, .savepoint = s.savepoint } },
        .open => blk: {
            std.debug.assert(!s.savepoint);
            break :blk .{ .control = .savepoint, .then = .{ .phase = .open, .savepoint = true } };
        },
        .first, .saved, .lost => unreachable,
    };
}
pub fn commit(s: State, in_transaction: bool) Step {
    return switch (s.phase) {
        .first => .{ .control = null, .then = .{ .phase = if (in_transaction) .open else .saved, .savepoint = s.savepoint } },
        .open => .{ .control = .release, .then = .{ .phase = .open } },
        .none => .{ .control = .commit, .then = s },
        .ready, .saved, .lost => unreachable,
    };
}
pub const Rollback = struct {
    controls: [2]?Control,
    must_leave_transaction: bool,
    reload_identities: bool,
    ok: State,
    failed: State,
};
pub fn rollback(s: State, in_transaction: bool) error{CanonicalRollbackFailed}!Rollback {
    if (s.phase == .lost or (s.phase == .open and !in_transaction)) return error.CanonicalRollbackFailed;
    if (s.phase == .open) return .{
        .controls = if (s.savepoint) .{ .rollback_to, .release } else .{ null, null },
        .must_leave_transaction = false,
        .reload_identities = true,
        .ok = .{ .phase = .open },
        .failed = .{ .phase = .lost },
    };
    return .{
        .controls = .{ if (in_transaction) .rollback else null, null },
        .must_leave_transaction = in_transaction,
        .reload_identities = true,
        .ok = if (s.phase == .first) .{ .phase = .ready, .savepoint = s.savepoint } else s,
        .failed = if (s.phase == .first) .{ .phase = .lost, .savepoint = s.savepoint } else s,
    };
}
pub const Finish = enum { nothing, commit, rollback_failed };
pub fn finish(s: State) Finish {
    return switch (s.phase) {
        .ready, .saved => .nothing,
        .open => .commit,
        .lost => .rollback_failed,
        .none, .first => unreachable,
    };
}
pub fn closed(s: State) bool {
    return s.phase == .saved;
}
pub fn admits(s: State) bool {
    return s.phase != .lost;
}
pub fn commitsWithWrites(s: State, engine_armed: bool, write_waiting: bool) bool {
    return engine_armed and s.phase == .first and !write_waiting;
}
pub fn defersAnnouncement(s: State) bool {
    return s.phase != .none;
}

// Literal observations of Store.zig before the extraction. The table includes
// the state left after a failed rollback control or identity reload.
test "SH-93 a batch's writes share one transaction and a lost rollback loses the batch" {
    try std.testing.expectEqualDeep(State{ .phase = .ready }, start(.{}));
    try std.testing.expectEqualDeep(Step{ .control = .begin, .then = .{} }, begin(.{}));
    try std.testing.expectEqualDeep(Step{ .control = .commit, .then = .{} }, commit(.{}, true));
    // Every sequence of up to five commits, rollbacks and failed rollbacks.
    // Controls and resulting states are literal observations of the old shell.
    for ([_]bool{ false, true }) |first_tx| {
        var length: usize = 1;
        while (length <= 5) : (length += 1) {
            var count: usize = 1;
            for (0..length) |_| count *= 5;
            for (0..count) |encoded| {
                var events = encoded;
                var state: State = .{ .phase = .ready };
                for (0..length) |_| {
                    if (state.phase == .saved or state.phase == .lost) break;
                    const is_first = state.phase == .ready;
                    const expected_begin: Step = if (is_first)
                        .{ .control = .begin, .then = .{ .phase = .first } }
                    else
                        .{ .control = .savepoint, .then = .{ .phase = .open, .savepoint = true } };
                    const opened = begin(state);
                    try std.testing.expectEqualDeep(expected_begin, opened);
                    const event = events % 5;
                    events /= 5;
                    if (event == 0) {
                        const expected_commit: Step = if (is_first)
                            .{ .control = null, .then = .{ .phase = if (first_tx) .open else .saved } }
                        else
                            .{ .control = .release, .then = .{ .phase = .open } };
                        const result = commit(opened.then, first_tx);
                        try std.testing.expectEqualDeep(expected_commit, result);
                        state = result.then;
                    } else {
                        const result = try rollback(opened.then, true);
                        const expected_controls: [2]?Control = if (is_first) .{ .rollback, null } else .{ .rollback_to, .release };
                        try std.testing.expectEqualDeep(expected_controls, result.controls);
                        try std.testing.expectEqualDeep(State{ .phase = if (is_first) .ready else .open }, result.ok);
                        try std.testing.expectEqualDeep(State{ .phase = .lost }, result.failed);
                        // Literal control prefixes when each effect fails. A first
                        // write has one rollback; a later write has two controls.
                        const first_prefixes = [_][2]?Control{
                            .{ .rollback, null }, .{ .rollback, null }, .{ .rollback, null },
                        };
                        const open_prefixes = [_][2]?Control{
                            .{ .rollback_to, null }, .{ .rollback_to, .release }, .{ .rollback_to, .release },
                        };
                        if (event > 1) {
                            const fail_at = event - 2;
                            var seen: [2]?Control = .{ null, null };
                            for (result.controls, 0..) |maybe_control, index| {
                                const control = maybe_control orelse break;
                                seen[index] = control;
                                if (index == fail_at) break;
                            }
                            const expected = if (is_first) first_prefixes[fail_at] else open_prefixes[fail_at];
                            try std.testing.expectEqualDeep(expected, seen);
                        }
                        state = if (event == 1) result.ok else result.failed;
                    }
                }
                const expected_finish: Finish = switch (state.phase) {
                    .ready, .saved => .nothing,
                    .open => .commit,
                    .lost => .rollback_failed,
                    else => unreachable,
                };
                try std.testing.expectEqual(expected_finish, finish(state));
            }
        }
    }
    const begin_rows = [_]struct { input: State, output: Step }{
        .{ .input = .{}, .output = .{ .control = .begin, .then = .{} } },
        .{ .input = .{ .savepoint = true }, .output = .{ .control = .begin, .then = .{ .savepoint = true } } },
        .{ .input = .{ .phase = .ready }, .output = .{ .control = .begin, .then = .{ .phase = .first } } },
        .{ .input = .{ .phase = .ready, .savepoint = true }, .output = .{ .control = .begin, .then = .{ .phase = .first, .savepoint = true } } },
        .{ .input = .{ .phase = .open }, .output = .{ .control = .savepoint, .then = .{ .phase = .open, .savepoint = true } } },
    };
    for (begin_rows) |row| try std.testing.expectEqualDeep(row.output, begin(row.input));
    const commit_rows = [_]struct { input: State, tx: bool, output: Step }{
        .{ .input = .{}, .tx = false, .output = .{ .control = .commit, .then = .{} } },
        .{ .input = .{ .savepoint = true }, .tx = true, .output = .{ .control = .commit, .then = .{ .savepoint = true } } },
        .{ .input = .{ .phase = .first }, .tx = true, .output = .{ .control = null, .then = .{ .phase = .open } } },
        .{ .input = .{ .phase = .first }, .tx = false, .output = .{ .control = null, .then = .{ .phase = .saved } } },
        .{ .input = .{ .phase = .first, .savepoint = true }, .tx = true, .output = .{ .control = null, .then = .{ .phase = .open, .savepoint = true } } },
        .{ .input = .{ .phase = .first, .savepoint = true }, .tx = false, .output = .{ .control = null, .then = .{ .phase = .saved, .savepoint = true } } },
        .{ .input = .{ .phase = .open }, .tx = false, .output = .{ .control = .release, .then = .{ .phase = .open } } },
        .{ .input = .{ .phase = .open, .savepoint = true }, .tx = true, .output = .{ .control = .release, .then = .{ .phase = .open } } },
    };
    for (commit_rows) |row| try std.testing.expectEqualDeep(row.output, commit(row.input, row.tx));
    const finish_rows = [_]struct { phase: Phase, expected: Finish }{
        .{ .phase = .ready, .expected = .nothing },
        .{ .phase = .open, .expected = .commit },
        .{ .phase = .saved, .expected = .nothing },
        .{ .phase = .lost, .expected = .rollback_failed },
    };
    for (finish_rows) |row| for ([_]bool{ false, true }) |savepoint| {
        try std.testing.expectEqual(row.expected, finish(.{ .phase = row.phase, .savepoint = savepoint }));
    };
    // Full state product for rollback, including unreachable combinations.
    // The old switch rejected lost, and open without a live transaction.
    const phases = [_]struct { phase: Phase, ok: Phase, failed: Phase, is_open: bool, rejected: bool }{
        .{ .phase = .none, .ok = .none, .failed = .none, .is_open = false, .rejected = false },
        .{ .phase = .ready, .ok = .ready, .failed = .ready, .is_open = false, .rejected = false },
        .{ .phase = .first, .ok = .ready, .failed = .lost, .is_open = false, .rejected = false },
        .{ .phase = .open, .ok = .open, .failed = .lost, .is_open = true, .rejected = false },
        .{ .phase = .saved, .ok = .saved, .failed = .saved, .is_open = false, .rejected = false },
        .{ .phase = .lost, .ok = .lost, .failed = .lost, .is_open = false, .rejected = true },
    };
    for (phases) |row| for ([_]bool{ false, true }) |savepoint| for ([_]bool{ false, true }) |tx| {
        const state: State = .{ .phase = row.phase, .savepoint = savepoint };
        if (row.rejected or (row.is_open and !tx)) {
            try std.testing.expectError(error.CanonicalRollbackFailed, rollback(state, tx));
        } else {
            const plan = try rollback(state, tx);
            const controls: [2]?Control = if (row.is_open)
                (if (savepoint) .{ .rollback_to, .release } else .{ null, null })
            else
                .{ if (tx) .rollback else null, null };
            try std.testing.expectEqualDeep(controls, plan.controls);
            try std.testing.expectEqual(tx and !row.is_open, plan.must_leave_transaction);
            try std.testing.expect(plan.reload_identities);
            try std.testing.expectEqualDeep(State{ .phase = row.ok, .savepoint = savepoint and !row.is_open }, plan.ok);
            try std.testing.expectEqualDeep(State{ .phase = row.failed, .savepoint = savepoint and !row.is_open }, plan.failed);
        }
    };
    const cases = [_]struct { phase: Phase, savepoint: bool, tx: bool, controls: [2]?Control, leave: bool, ok: State, failed: State }{
        .{ .phase = .none, .savepoint = false, .tx = false, .controls = .{ null, null }, .leave = false, .ok = .{}, .failed = .{} },
        .{ .phase = .none, .savepoint = false, .tx = true, .controls = .{ .rollback, null }, .leave = true, .ok = .{}, .failed = .{} },
        .{ .phase = .ready, .savepoint = false, .tx = false, .controls = .{ null, null }, .leave = false, .ok = .{ .phase = .ready }, .failed = .{ .phase = .ready } },
        .{ .phase = .ready, .savepoint = false, .tx = true, .controls = .{ .rollback, null }, .leave = true, .ok = .{ .phase = .ready }, .failed = .{ .phase = .ready } },
        .{ .phase = .first, .savepoint = false, .tx = false, .controls = .{ null, null }, .leave = false, .ok = .{ .phase = .ready }, .failed = .{ .phase = .lost } },
        .{ .phase = .first, .savepoint = false, .tx = true, .controls = .{ .rollback, null }, .leave = true, .ok = .{ .phase = .ready }, .failed = .{ .phase = .lost } },
        .{ .phase = .open, .savepoint = false, .tx = true, .controls = .{ null, null }, .leave = false, .ok = .{ .phase = .open }, .failed = .{ .phase = .lost } },
        .{ .phase = .open, .savepoint = true, .tx = true, .controls = .{ .rollback_to, .release }, .leave = false, .ok = .{ .phase = .open }, .failed = .{ .phase = .lost } },
        .{ .phase = .saved, .savepoint = false, .tx = false, .controls = .{ null, null }, .leave = false, .ok = .{ .phase = .saved }, .failed = .{ .phase = .saved } },
        .{ .phase = .saved, .savepoint = false, .tx = true, .controls = .{ .rollback, null }, .leave = true, .ok = .{ .phase = .saved }, .failed = .{ .phase = .saved } },
    };
    for (cases) |case| {
        const result = try rollback(.{ .phase = case.phase, .savepoint = case.savepoint }, case.tx);
        try std.testing.expectEqualDeep(case.controls, result.controls);
        try std.testing.expectEqual(case.leave, result.must_leave_transaction);
        try std.testing.expect(result.reload_identities);
        try std.testing.expectEqualDeep(case.ok, result.ok);
        try std.testing.expectEqualDeep(case.failed, result.failed);
    }
    try std.testing.expectError(error.CanonicalRollbackFailed, rollback(.{ .phase = .open }, false));
    try std.testing.expectError(error.CanonicalRollbackFailed, rollback(.{ .phase = .lost }, true));
}

test "SH-94 a lone write commits with its message and a batch announces after its commit" {
    const cases = [_]struct { phase: Phase, closed: bool, admits: bool, defer_announcement: bool, commits_armed: bool }{
        .{ .phase = .none, .closed = false, .admits = true, .defer_announcement = false, .commits_armed = false },
        .{ .phase = .ready, .closed = false, .admits = true, .defer_announcement = true, .commits_armed = false },
        .{ .phase = .first, .closed = false, .admits = true, .defer_announcement = true, .commits_armed = true },
        .{ .phase = .open, .closed = false, .admits = true, .defer_announcement = true, .commits_armed = false },
        .{ .phase = .saved, .closed = true, .admits = true, .defer_announcement = true, .commits_armed = false },
        .{ .phase = .lost, .closed = false, .admits = false, .defer_announcement = true, .commits_armed = false },
    };
    for (cases) |case| {
        const s: State = .{ .phase = case.phase };
        try std.testing.expectEqual(case.closed, closed(s));
        try std.testing.expectEqual(case.admits, admits(s));
        try std.testing.expectEqual(case.defer_announcement, defersAnnouncement(s));
        for ([_]bool{ false, true }) |armed| for ([_]bool{ false, true }) |waiting| {
            try std.testing.expectEqual(case.commits_armed and armed and !waiting, commitsWithWrites(s, armed, waiting));
        };
    }
}
