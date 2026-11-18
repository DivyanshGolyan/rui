const std = @import("std");

pub const Phase = enum(u8) { none, ready, first, open, saved, lost };
pub const State = struct { phase: Phase = .none, savepoint: bool = false };
pub const Control = enum { begin, commit, rollback, savepoint, release, rollback_to };
pub const Step = struct { control: ?Control, then: State };

pub const StartDecision = enum { start, assertion };
pub fn startDecision(s: State) StartDecision {
    return if (s.phase == .none and !s.savepoint) .start else .assertion;
}
pub fn start(s: State) State {
    std.debug.assert(startDecision(s) == .start);
    return .{ .phase = .ready, .savepoint = s.savepoint };
}
pub const BeginDecision = union(enum) { step: Step, savepoint_open: Step, unreachable_phase };
pub fn beginDecision(s: State) BeginDecision {
    return switch (s.phase) {
        .none => .{ .step = .{ .control = .begin, .then = s } },
        .ready => .{ .step = .{ .control = .begin, .then = .{ .phase = .first, .savepoint = s.savepoint } } },
        .open => if (s.savepoint)
            .{ .savepoint_open = .{ .control = .savepoint, .then = .{ .phase = .open, .savepoint = true } } }
        else
            .{ .step = .{ .control = .savepoint, .then = .{ .phase = .open, .savepoint = true } } },
        .first, .saved, .lost => .unreachable_phase,
    };
}
pub fn begin(s: State) Step {
    return switch (beginDecision(s)) {
        .step => |step| step,
        .savepoint_open => |step| blk: {
            std.debug.assert(!s.savepoint);
            break :blk step;
        },
        .unreachable_phase => unreachable,
    };
}
pub const CommitDecision = union(enum) { step: Step, unreachable_phase };
pub fn commitDecision(s: State, in_transaction: bool) CommitDecision {
    return switch (s.phase) {
        .first => .{ .step = .{ .control = null, .then = .{ .phase = if (in_transaction) .open else .saved, .savepoint = s.savepoint } } },
        .open => .{ .step = .{ .control = .release, .then = .{ .phase = .open } } },
        .none => .{ .step = .{ .control = .commit, .then = s } },
        .ready, .saved, .lost => .unreachable_phase,
    };
}
pub fn commit(s: State, in_transaction: bool) Step {
    return switch (commitDecision(s, in_transaction)) {
        .step => |step| step,
        .unreachable_phase => unreachable,
    };
}
pub const Rollback = struct {
    before: State,
    controls: [2]?Control,
    must_leave_transaction: bool,
    reload_identities: bool,
    ok: State,
    failed: State,
};
pub fn rollback(s: State, in_transaction: bool) error{CanonicalRollbackFailed}!Rollback {
    if (s.phase == .lost or (s.phase == .open and !in_transaction)) return error.CanonicalRollbackFailed;
    if (s.phase == .open) return .{
        .before = .{ .phase = .open },
        .controls = if (s.savepoint) .{ .rollback_to, .release } else .{ null, null },
        .must_leave_transaction = false,
        .reload_identities = true,
        .ok = .{ .phase = .open },
        .failed = .{ .phase = .lost },
    };
    return .{
        .before = s,
        .controls = .{ if (in_transaction) .rollback else null, null },
        .must_leave_transaction = in_transaction,
        .reload_identities = true,
        .ok = if (s.phase == .first) .{ .phase = .ready, .savepoint = s.savepoint } else s,
        .failed = if (s.phase == .first) .{ .phase = .lost, .savepoint = s.savepoint } else s,
    };
}
pub const Finish = enum { nothing, commit, rollback_failed };
pub const FinishDecision = union(enum) { result: Finish, unreachable_phase };
pub fn finishDecision(s: State) FinishDecision {
    return switch (s.phase) {
        .ready, .saved => .{ .result = .nothing },
        .open => .{ .result = .commit },
        .lost => .{ .result = .rollback_failed },
        .none, .first => .unreachable_phase,
    };
}
pub fn finish(s: State) Finish {
    return switch (finishDecision(s)) {
        .result => |result| result,
        .unreachable_phase => unreachable,
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

// These literal patterns transcribe the original Store shell at ebaf17d0d.
// begin in phases none and ready also asserts that no identities are taken
// and the identity second is zero. Those values are assumed here, since
// identity state is not an input to this product. Failure points which the
// operation never reaches have no effect.
// Exclusion means an assertion or unreachable in that shell, not an inferred
// constraint on combinations of phase, savepoint and transaction state.
test "SH-93 a batch's writes share one transaction and a lost rollback loses the batch" {
    const Event = enum { start, begin, commit, rollback, finish };
    const Failure = enum { none, injected, control1, control2, postcheck, reload };
    const Outcome = enum { ok, failed, excluded };
    const Trace = struct {
        outcome: Outcome = .ok,
        before: State,
        controls: [2]?Control = .{ null, null },
        reload: bool = false,
        after: State,
    };
    const After = enum { same, ready_keep, first_keep, open_keep, saved_keep, open_clear, open_set, lost_keep, lost_clear, none_clear };
    const Pattern = struct {
        phases: u8 = 63,
        sp: ?bool = null,
        tx: ?bool = null,
        event: Event,
        failures: u8 = 63,
        outcome: Outcome = .ok,
        before_clear: bool = false,
        controls: [2]?Control = .{ null, null },
        reload: bool = false,
        after: After = .same,
    };
    // Failure masks: none=1, injected=2, control1=4, control2=8,
    // postcheck=16, reload=32. Phase masks follow Phase declaration order.
    // These rows transcribe the original shell; masks only expand wildcards.
    const admitted = [_]Pattern{
        .{ .phases = 1, .sp = false, .event = .start, .after = .ready_keep },
        .{ .phases = 1, .event = .begin, .failures = 59, .controls = .{ .begin, null } },
        .{ .phases = 1, .event = .begin, .failures = 4, .outcome = .failed, .controls = .{ .begin, null } },
        .{ .phases = 2, .event = .begin, .failures = 59, .controls = .{ .begin, null }, .after = .first_keep },
        .{ .phases = 2, .event = .begin, .failures = 4, .outcome = .failed, .controls = .{ .begin, null } },
        .{ .phases = 8, .sp = false, .event = .begin, .failures = 59, .controls = .{ .savepoint, null }, .after = .open_set },
        .{ .phases = 8, .sp = false, .event = .begin, .failures = 4, .outcome = .failed, .controls = .{ .savepoint, null } },
        .{ .phases = 1, .event = .commit, .failures = 59, .controls = .{ .commit, null } },
        .{ .phases = 1, .event = .commit, .failures = 4, .outcome = .failed, .controls = .{ .commit, null } },
        .{ .phases = 4, .tx = true, .event = .commit, .after = .open_keep },
        .{ .phases = 4, .tx = false, .event = .commit, .after = .saved_keep },
        .{ .phases = 8, .event = .commit, .failures = 59, .controls = .{ .release, null }, .after = .open_clear },
        .{ .phases = 8, .event = .commit, .failures = 4, .outcome = .failed, .controls = .{ .release, null } },
        // none, ready and saved preserve state on every rollback outcome.
        .{ .phases = 19, .tx = false, .event = .rollback, .failures = 31, .reload = true },
        .{ .phases = 19, .tx = false, .event = .rollback, .failures = 32, .outcome = .failed, .reload = true },
        .{ .phases = 19, .tx = true, .event = .rollback, .failures = 9, .controls = .{ .rollback, null }, .reload = true },
        .{ .phases = 19, .tx = true, .event = .rollback, .failures = 2, .outcome = .failed },
        .{ .phases = 19, .tx = true, .event = .rollback, .failures = 20, .outcome = .failed, .controls = .{ .rollback, null } },
        .{ .phases = 19, .tx = true, .event = .rollback, .failures = 32, .outcome = .failed, .controls = .{ .rollback, null }, .reload = true },
        .{ .phases = 4, .tx = false, .event = .rollback, .failures = 31, .reload = true, .after = .ready_keep },
        .{ .phases = 4, .tx = false, .event = .rollback, .failures = 32, .outcome = .failed, .reload = true, .after = .lost_keep },
        .{ .phases = 4, .tx = true, .event = .rollback, .failures = 9, .controls = .{ .rollback, null }, .reload = true, .after = .ready_keep },
        .{ .phases = 4, .tx = true, .event = .rollback, .failures = 2, .outcome = .failed, .after = .lost_keep },
        .{ .phases = 4, .tx = true, .event = .rollback, .failures = 20, .outcome = .failed, .controls = .{ .rollback, null }, .after = .lost_keep },
        .{ .phases = 4, .tx = true, .event = .rollback, .failures = 32, .outcome = .failed, .controls = .{ .rollback, null }, .reload = true, .after = .lost_keep },
        .{ .phases = 8, .tx = false, .event = .rollback, .outcome = .failed, .before_clear = true, .after = .lost_clear },
        .{ .phases = 8, .sp = false, .tx = true, .event = .rollback, .failures = 31, .before_clear = true, .reload = true, .after = .open_clear },
        .{ .phases = 8, .sp = false, .tx = true, .event = .rollback, .failures = 32, .outcome = .failed, .before_clear = true, .reload = true, .after = .lost_clear },
        .{ .phases = 8, .sp = true, .tx = true, .event = .rollback, .failures = 17, .before_clear = true, .controls = .{ .rollback_to, .release }, .reload = true, .after = .open_clear },
        .{ .phases = 8, .sp = true, .tx = true, .event = .rollback, .failures = 2, .outcome = .failed, .before_clear = true, .after = .lost_clear },
        .{ .phases = 8, .sp = true, .tx = true, .event = .rollback, .failures = 4, .outcome = .failed, .before_clear = true, .controls = .{ .rollback_to, null }, .after = .lost_clear },
        .{ .phases = 8, .sp = true, .tx = true, .event = .rollback, .failures = 8, .outcome = .failed, .before_clear = true, .controls = .{ .rollback_to, .release }, .after = .lost_clear },
        .{ .phases = 8, .sp = true, .tx = true, .event = .rollback, .failures = 32, .outcome = .failed, .before_clear = true, .controls = .{ .rollback_to, .release }, .reload = true, .after = .lost_clear },
        .{ .phases = 32, .event = .rollback, .outcome = .failed },
        .{ .phases = 18, .sp = false, .event = .finish, .after = .none_clear },
        .{ .phases = 8, .sp = false, .event = .finish, .failures = 59, .controls = .{ .commit, null }, .after = .none_clear },
        .{ .phases = 8, .sp = false, .event = .finish, .failures = 4, .outcome = .failed, .controls = .{ .commit, null }, .after = .none_clear },
        .{ .phases = 32, .sp = false, .event = .finish, .outcome = .failed, .after = .none_clear },
    };
    const Excluded = struct { pattern: Pattern, function: []const u8 };
    const excluded = [_]Excluded{
        .{ .pattern = .{ .phases = 62, .event = .start }, .function = "startBatch" },
        .{ .pattern = .{ .phases = 1, .sp = true, .event = .start }, .function = "startBatch" },
        .{ .pattern = .{ .phases = 52, .event = .begin }, .function = "begin" },
        .{ .pattern = .{ .phases = 8, .sp = true, .event = .begin }, .function = "begin" },
        .{ .pattern = .{ .phases = 50, .event = .commit }, .function = "commit" },
        .{ .pattern = .{ .sp = true, .event = .finish }, .function = "finishBatch" },
        .{ .pattern = .{ .phases = 5, .sp = false, .event = .finish }, .function = "commitBatch" },
    };
    const Match = struct {
        fn matches(p: Pattern, state: State, tx: bool, event: Event, failure: Failure) bool {
            return p.phases & (@as(u8, 1) << @intCast(@backingInt(state.phase))) != 0 and
                (p.sp == null or p.sp.? == state.savepoint) and (p.tx == null or p.tx.? == tx) and
                p.event == event and p.failures & (@as(u8, 1) << @intCast(@backingInt(failure))) != 0;
        }
        fn afterState(spec: After, input: State) State {
            return switch (spec) {
                .same => input,
                .ready_keep => .{ .phase = .ready, .savepoint = input.savepoint },
                .first_keep => .{ .phase = .first, .savepoint = input.savepoint },
                .open_keep => .{ .phase = .open, .savepoint = input.savepoint },
                .saved_keep => .{ .phase = .saved, .savepoint = input.savepoint },
                .open_clear => .{ .phase = .open },
                .open_set => .{ .phase = .open, .savepoint = true },
                .lost_keep => .{ .phase = .lost, .savepoint = input.savepoint },
                .lost_clear => .{ .phase = .lost },
                .none_clear => .{},
            };
        }
    };
    for (std.meta.tags(Phase)) |phase| for ([_]bool{ false, true }) |savepoint| for ([_]bool{ false, true }) |tx| for (std.meta.tags(Event)) |event| for (std.meta.tags(Failure)) |failure| {
        const input: State = .{ .phase = phase, .savepoint = savepoint };
        var count: usize = 0;
        var expected: Trace = undefined;
        for (admitted) |pattern| if (Match.matches(pattern, input, tx, event, failure)) {
            count += 1;
            expected = .{ .outcome = pattern.outcome, .before = if (pattern.before_clear) .{ .phase = input.phase } else input, .controls = pattern.controls, .reload = pattern.reload, .after = Match.afterState(pattern.after, input) };
        };
        for (excluded) |entry| if (Match.matches(entry.pattern, input, tx, event, failure)) {
            count += 1;
            try std.testing.expect(entry.function.len != 0);
            expected = .{ .outcome = .excluded, .before = input, .after = input };
        };
        std.testing.expectEqual(@as(usize, 1), count) catch |err| {
            std.debug.print("SH-93 coverage phase={any} savepoint={} tx={} event={any} failure={any} matches={}\n", .{ phase, savepoint, tx, event, failure, count });
            return err;
        };
        const row = .{ .state = input };
        var got: Trace = .{ .before = row.state, .after = row.state };
        switch (event) {
            .start => switch (startDecision(row.state)) {
                .assertion => got.outcome = .excluded,
                .start => got.after = start(row.state),
            },
            .begin => switch (beginDecision(row.state)) {
                .unreachable_phase, .savepoint_open => got.outcome = .excluded,
                .step => |step| {
                    got.controls[0] = step.control;
                    if (step.control != null and failure == .control1) got.outcome = .failed else got.after = step.then;
                },
            },
            .commit => switch (commitDecision(row.state, tx)) {
                .unreachable_phase => got.outcome = .excluded,
                .step => |step| {
                    got.controls[0] = step.control;
                    if (step.control != null and failure == .control1) got.outcome = .failed else got.after = step.then;
                },
            },
            .rollback => {
                if (rollback(row.state, tx)) |plan| {
                    got.before = plan.before;
                    got.after = plan.before;
                    for (plan.controls, 0..) |maybe_control, control_index| {
                        const control = maybe_control orelse break;
                        if (failure == .injected) {
                            got.outcome = .failed;
                            break;
                        }
                        got.controls[control_index] = control;
                        if ((control_index == 0 and failure == .control1) or (control_index == 1 and failure == .control2)) {
                            got.outcome = .failed;
                            break;
                        }
                    }
                    if (got.outcome == .ok and plan.must_leave_transaction and failure == .postcheck) got.outcome = .failed;
                    if (got.outcome == .ok and plan.reload_identities) {
                        got.reload = true;
                        if (failure == .reload) got.outcome = .failed;
                    }
                    got.after = if (got.outcome == .ok) plan.ok else plan.failed;
                } else |_| {
                    got.outcome = .failed;
                    if (row.state.phase == .open) {
                        got.before = .{ .phase = .open };
                        got.after = .{ .phase = .lost };
                    }
                }
            },
            .finish => {
                // finishBatch asserts before commitBatch and resets the phase on exit.
                if (row.state.savepoint) {
                    got.outcome = .excluded;
                } else switch (finishDecision(row.state)) {
                    .unreachable_phase => got.outcome = .excluded,
                    .result => |result| {
                        got.after = .{};
                        switch (result) {
                            .nothing => {},
                            .rollback_failed => got.outcome = .failed,
                            .commit => {
                                got.controls[0] = .commit;
                                if (failure == .control1) got.outcome = .failed;
                            },
                        }
                    },
                }
            },
        }
        std.testing.expectEqualDeep(expected, got) catch |err| {
            std.debug.print("SH-93 phase={any} savepoint={} tx={} event={any} failure={any}\n", .{ phase, savepoint, tx, event, failure });
            return err;
        };
    };
}

// Whole-batch traces: each expected fragment below is a literal shell trace.
// The catalog concatenates those fragments and compares the aggregate once.
test "SH-93 multi-write control traces" {
    const Kind = enum { commit, rollback, fail_first, fail_second, fail_reload };
    const Fragment = struct { controls: []const Control, phase: Phase };
    const first_in = [_]Fragment{
        .{ .controls = &.{.begin}, .phase = .open },
        .{ .controls = &.{ .begin, .rollback }, .phase = .ready },
        .{ .controls = &.{ .begin, .rollback }, .phase = .lost },
        .{ .controls = &.{ .begin, .rollback }, .phase = .ready },
        .{ .controls = &.{ .begin, .rollback }, .phase = .lost },
    };
    const first_out = [_]Fragment{
        .{ .controls = &.{.begin}, .phase = .saved },
        .{ .controls = &.{ .begin, .rollback }, .phase = .ready },
        .{ .controls = &.{ .begin, .rollback }, .phase = .lost },
        .{ .controls = &.{ .begin, .rollback }, .phase = .ready },
        .{ .controls = &.{ .begin, .rollback }, .phase = .lost },
    };
    const later = [_]Fragment{
        .{ .controls = &.{ .savepoint, .release }, .phase = .open },
        .{ .controls = &.{ .savepoint, .rollback_to, .release }, .phase = .open },
        .{ .controls = &.{ .savepoint, .rollback_to }, .phase = .lost },
        .{ .controls = &.{ .savepoint, .rollback_to, .release }, .phase = .lost },
        .{ .controls = &.{ .savepoint, .rollback_to, .release }, .phase = .lost },
    };
    for ([_]bool{ false, true }) |first_tx| {
        var length: usize = 1;
        while (length <= 5) : (length += 1) {
            var count: usize = 1;
            for (0..length) |_| count *= 5;
            for (0..count) |encoded| {
                var choices = encoded;
                var state: State = .{ .phase = .ready };
                var expected_phase: Phase = .ready;
                var actual: [16]?Control = @splat(null);
                var expected: [16]?Control = @splat(null);
                var actual_len: usize = 0;
                var expected_len: usize = 0;
                var actual_states: [5]?State = @splat(null);
                var expected_states: [5]?State = @splat(null);
                for (0..length) |write_index| {
                    if (state.phase == .saved or state.phase == .lost) break;
                    const kind: Kind = @fromBackingInt(@intCast(choices % 5));
                    choices /= 5;
                    const first = state.phase == .ready;
                    const fragment = if (expected_phase == .ready)
                        (if (first_tx) first_in[@backingInt(kind)] else first_out[@backingInt(kind)])
                    else
                        later[@backingInt(kind)];
                    for (fragment.controls) |control| {
                        expected[expected_len] = control;
                        expected_len += 1;
                    }
                    expected_phase = fragment.phase;
                    const opened = begin(state);
                    actual[actual_len] = opened.control;
                    actual_len += 1;
                    if (kind == .commit) {
                        const step = commit(opened.then, if (first) first_tx else true);
                        if (step.control) |control| {
                            actual[actual_len] = control;
                            actual_len += 1;
                        }
                        state = step.then;
                    } else {
                        const plan = try rollback(opened.then, true);
                        var failed = false;
                        for (plan.controls, 0..) |control, control_index| {
                            const value = control orelse break;
                            actual[actual_len] = value;
                            actual_len += 1;
                            if ((kind == .fail_first and control_index == 0) or (kind == .fail_second and control_index == 1)) {
                                failed = true;
                                break;
                            }
                        }
                        if (kind == .fail_reload) failed = true;
                        state = if (failed) plan.failed else plan.ok;
                    }
                    expected_states[write_index] = .{ .phase = expected_phase };
                    actual_states[write_index] = state;
                }
                if (expected_phase == .open) {
                    expected[expected_len] = .commit;
                    expected_len += 1;
                }
                const result = finish(state);
                if (result == .commit) {
                    actual[actual_len] = .commit;
                    actual_len += 1;
                }
                if (expected_phase != state.phase or expected_len != actual_len) {
                    std.debug.print("SH-93 sequence first_tx={} length={} encoded={} expected_phase={any} actual_phase={any}\n", .{ first_tx, length, encoded, expected_phase, state.phase });
                    return error.TestUnexpectedResult;
                }
                std.testing.expectEqualDeep(expected_states, actual_states) catch |err| {
                    std.debug.print("SH-93 sequence states first_tx={} length={} encoded={}\n", .{ first_tx, length, encoded });
                    return err;
                };
                std.testing.expectEqualDeep(expected, actual) catch |err| {
                    std.debug.print("SH-93 sequence first_tx={} length={} encoded={}\n", .{ first_tx, length, encoded });
                    return err;
                };
            }
        }
    }
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
