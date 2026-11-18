const std = @import("std");

pub const Phase = enum(u8) { none, ready, first, open, saved, lost };
pub const State = struct { phase: Phase = .none, savepoint: bool = false };
pub const Control = enum { begin, commit, rollback, savepoint, release, rollback_to };
pub const Step = struct {
    before: State,
    control: ?Control,
    then: State,
    failed: State,
    verify_identities: bool = false,
    reset_identities: bool = false,
};
pub fn apply(phase: *Phase, savepoint: *bool, state: State) void {
    phase.* = state.phase;
    savepoint.* = state.savepoint;
}
pub const StartDecision = enum { start, assertion };
pub fn startDecision(s: State) StartDecision {
    return if (s.phase == .none and !s.savepoint) .start else .assertion;
}
pub fn start(s: State) Step {
    std.debug.assert(startDecision(s) == .start);
    return .{ .before = s, .control = null, .then = .{ .phase = .ready, .savepoint = s.savepoint }, .failed = s };
}
pub const BeginDecision = union(enum) { step: Step, savepoint_open: Step, unreachable_phase };
pub fn beginDecision(s: State) BeginDecision {
    return switch (s.phase) {
        .none => .{ .step = .{ .before = s, .control = .begin, .then = s, .failed = s, .verify_identities = true } },
        .ready => .{ .step = .{ .before = s, .control = .begin, .then = .{ .phase = .first, .savepoint = s.savepoint }, .failed = s, .verify_identities = true } },
        .open => if (s.savepoint)
            .{ .savepoint_open = .{ .before = s, .control = .savepoint, .then = .{ .phase = .open, .savepoint = true }, .failed = s } }
        else
            .{ .step = .{ .before = s, .control = .savepoint, .then = .{ .phase = .open, .savepoint = true }, .failed = s } },
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
pub fn commitNeedsTransaction(s: State) bool {
    return s.phase == .first;
}
pub fn commitDecision(s: State, in_transaction: bool) CommitDecision {
    return switch (s.phase) {
        .first => .{ .step = .{ .before = s, .control = null, .then = .{ .phase = if (in_transaction) .open else .saved, .savepoint = s.savepoint }, .failed = s } },
        .open => .{ .step = .{ .before = s, .control = .release, .then = .{ .phase = .open }, .failed = s } },
        .none => .{ .step = .{ .before = s, .control = .commit, .then = s, .failed = s, .reset_identities = true } },
        .ready, .saved, .lost => .unreachable_phase,
    };
}
pub fn commit(s: State, in_transaction: bool) Step {
    return switch (commitDecision(s, in_transaction)) {
        .step => |step| step,
        .unreachable_phase => unreachable,
    };
}
pub const RollbackPreparation = struct { before: State, probe_transaction: bool };
pub fn prepareRollback(s: State) RollbackPreparation {
    return .{ .before = if (s.phase == .open) .{ .phase = .open } else s, .probe_transaction = s.phase != .lost };
}
pub const Rollback = struct {
    before: State,
    controls: [2]?Control,
    must_leave_transaction: bool,
    reload_identities: bool,
    ok: State,
    failed: State,
    rejected: bool,
    reset_second: bool,
};
pub fn rollback(s: State, in_transaction: bool) Rollback {
    if (s.phase == .lost or (s.phase == .open and !in_transaction)) {
        const before = prepareRollback(s).before;
        const after: State = if (s.phase == .lost) s else .{ .phase = .lost };
        return .{ .before = before, .controls = .{ null, null }, .must_leave_transaction = false, .reload_identities = false, .ok = after, .failed = after, .rejected = true, .reset_second = false };
    }
    if (s.phase == .open) return .{
        .before = .{ .phase = .open },
        .controls = if (s.savepoint) .{ .rollback_to, .release } else .{ null, null },
        .must_leave_transaction = false,
        .reload_identities = true,
        .ok = .{ .phase = .open },
        .failed = .{ .phase = .lost },
        .rejected = false,
        .reset_second = false,
    };
    return .{
        .before = s,
        .controls = .{ if (in_transaction) .rollback else null, null },
        .must_leave_transaction = in_transaction,
        .reload_identities = true,
        .ok = if (s.phase == .first) .{ .phase = .ready, .savepoint = s.savepoint } else s,
        .failed = if (s.phase == .first) .{ .phase = .lost, .savepoint = s.savepoint } else s,
        .rejected = false,
        .reset_second = true,
    };
}
pub const Finish = enum { nothing, commit, rollback_failed };
pub const FinishPlan = struct { before: State, result: Finish, then: State, failed: State };
pub const FinishDecision = union(enum) { result: FinishPlan, unreachable_phase };
pub fn finishReset(s: State) State {
    return .{ .phase = .none, .savepoint = s.savepoint };
}
pub fn finishDecision(s: State) FinishDecision {
    const result: Finish = switch (s.phase) {
        .ready, .saved => .nothing,
        .open => .commit,
        .lost => .rollback_failed,
        .none, .first => return .unreachable_phase,
    };
    const after = finishReset(s);
    return .{ .result = .{ .before = s, .result = result, .then = after, .failed = after } };
}
pub fn finish(s: State) FinishPlan {
    return switch (finishDecision(s)) {
        .result => |result| result,
        .unreachable_phase => unreachable,
    };
}
pub fn executeStep(host: anytype, step: Step) @TypeOf(host.control(.begin)) {
    if (step.verify_identities) host.verifyIdentities();
    host.apply(step.before);
    if (step.control) |control| host.control(control) catch |err| {
        host.apply(step.failed);
        return err;
    };
    host.apply(step.then);
    if (step.reset_identities) host.resetIdentities();
}
pub fn executeStart(host: anytype, s: State) @TypeOf(host.control(.begin)) {
    try executeStep(host, start(s));
}
pub fn executeBegin(host: anytype, s: State) @TypeOf(host.control(.begin)) {
    try executeStep(host, begin(s));
}
pub fn executeCommit(host: anytype, s: State) @TypeOf(host.control(.begin)) {
    const in_transaction = if (commitNeedsTransaction(s)) host.inTransaction() else false;
    try executeStep(host, commit(s, in_transaction));
}
pub fn executeRollback(host: anytype, s: State, fault: bool) error{CanonicalRollbackFailed}!void {
    const prep = prepareRollback(s);
    host.apply(prep.before);
    const in_transaction = if (prep.probe_transaction) host.inTransaction() else false;
    const plan = rollback(s, in_transaction);
    if (plan.rejected) {
        host.apply(plan.failed);
        return error.CanonicalRollbackFailed;
    }
    errdefer host.apply(plan.failed);
    for (plan.controls) |maybe_control| {
        const control = maybe_control orelse break;
        if (fault) return error.CanonicalRollbackFailed;
        host.control(control) catch return error.CanonicalRollbackFailed;
    }
    if (plan.must_leave_transaction and host.inTransaction()) return error.CanonicalRollbackFailed;
    if (plan.reset_second) host.resetSecond();
    if (plan.reload_identities) host.reload() catch return error.CanonicalRollbackFailed;
    host.apply(plan.ok);
}
pub fn executeFinish(host: anytype, plan: FinishPlan) bool {
    host.apply(plan.before);
    // Announcements may update other state. The old deferred cleanup reset
    // only the phase, so derive the whole final state at cleanup time.
    defer host.apply(finishReset(host.currentState()));
    switch (plan.result) {
        .nothing => {},
        .commit => host.finishCommit() catch |err| {
            host.finishFailure(err);
            return false;
        },
        .rollback_failed => {
            host.finishFailure(error.CanonicalRollbackFailed);
            return false;
        },
    }
    host.announce();
    return true;
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

const TestFailure = enum { none, injected, control1, control2, postcheck, reload };
const TestEvent = enum { apply, verify, control, probe, reset_second, reset_identities, reload, finish_failure, announce };
const TestHost = struct {
    state: State,
    events: [16]?TestEvent = @splat(null),
    event_count: usize = 0,
    before: ?State = null,
    controls: [2]?Control = .{ null, null },
    control_states: [2]?State = .{ null, null },
    probe_states: [2]?State = .{ null, null },
    control_count: usize = 0,
    reload_called: bool = false,
    reload_state: ?State = null,
    resets_at_reload: usize = 0,
    failure: TestFailure = .none,
    transaction: bool = false,
    probes: usize = 0,
    resets: usize = 0,
    announcements: usize = 0,
    finish_failures: usize = 0,
    announce_state: ?State = null,
    failure_state: ?State = null,
    announce_changes_to: ?State = null,
    failure_changes_to: ?State = null,
    verified: usize = 0,
    identities_reset: usize = 0,
    fn note(self: *@This(), event: TestEvent) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
    fn currentState(self: *@This()) State {
        return self.state;
    }
    fn apply(self: *@This(), state: State) void {
        self.note(.apply);
        applyState(&self.state.phase, &self.state.savepoint, state);
        if (self.before == null) self.before = self.state;
    }
    fn control(self: *@This(), value: Control) error{Injected}!void {
        self.note(.control);
        self.controls[self.control_count] = value;
        self.control_states[self.control_count] = self.state;
        self.control_count += 1;
        if ((self.control_count == 1 and self.failure == .control1) or (self.control_count == 2 and self.failure == .control2)) return error.Injected;
    }
    fn inTransaction(self: *@This()) bool {
        self.note(.probe);
        self.probe_states[self.probes] = self.state;
        self.probes += 1;
        return if (self.probes == 1) self.transaction else self.failure == .postcheck;
    }
    fn verifyIdentities(self: *@This()) void {
        self.note(.verify);
        std.debug.assert(self.before == null);
        self.verified += 1;
    }
    fn resetIdentities(self: *@This()) void {
        self.note(.reset_identities);
        std.debug.assert(self.before != null);
        self.identities_reset += 1;
    }
    fn resetSecond(self: *@This()) void {
        self.note(.reset_second);
        self.resets += 1;
    }
    fn reload(self: *@This()) error{Injected}!void {
        self.note(.reload);
        self.reload_called = true;
        self.reload_state = self.state;
        self.resets_at_reload = self.resets;
        if (self.failure == .reload) return error.Injected;
    }
    fn finishCommit(self: *@This()) error{Injected}!void {
        try self.control(.commit);
    }
    fn finishFailure(self: *@This(), _: anyerror) void {
        self.note(.finish_failure);
        self.finish_failures += 1;
        self.failure_state = self.state;
        if (self.failure_changes_to) |state| self.state = state;
    }
    fn announce(self: *@This()) void {
        self.note(.announce);
        self.announcements += 1;
        self.announce_state = self.state;
        if (self.announce_changes_to) |state| self.state = state;
    }
};
const applyState = apply;

// These literal patterns transcribe the original Store shell at ebaf17d0d.
// begin in phases none and ready also asserts that no identities are taken
// and the identity second is zero. Those values are assumed here, since
// identity state is not an input to this product. Failure points which the
// operation never reaches have no effect.
// Exclusion means an assertion or unreachable in that shell, not an inferred
// constraint on combinations of phase, savepoint and transaction state.
test "SH-93 a batch's writes share one transaction and a lost rollback loses the batch" {
    const Event = enum { start, begin, commit, rollback, finish };
    const Failure = TestFailure;
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
        var host: TestHost = .{ .state = row.state, .failure = failure, .transaction = tx };
        switch (event) {
            .start => switch (startDecision(row.state)) {
                .assertion => got.outcome = .excluded,
                .start => executeStart(&host, row.state) catch {
                    got.outcome = .failed;
                },
            },
            .begin => switch (beginDecision(row.state)) {
                .unreachable_phase, .savepoint_open => got.outcome = .excluded,
                .step => executeBegin(&host, row.state) catch {
                    got.outcome = .failed;
                },
            },
            .commit => switch (commitDecision(row.state, tx)) {
                .unreachable_phase => got.outcome = .excluded,
                .step => executeCommit(&host, row.state) catch {
                    got.outcome = .failed;
                },
            },
            .rollback => executeRollback(&host, row.state, failure == .injected) catch {
                got.outcome = .failed;
            },
            .finish => {
                if (row.state.savepoint) {
                    got.outcome = .excluded;
                } else switch (finishDecision(row.state)) {
                    .unreachable_phase => got.outcome = .excluded,
                    .result => |plan| if (!executeFinish(&host, plan)) {
                        got.outcome = .failed;
                    },
                }
            },
        }
        got.before = host.before orelse row.state;
        got.after = host.state;
        got.controls = host.controls;
        got.reload = host.reload_called;
        for (host.control_states[0..host.control_count]) |state_at_control| {
            try std.testing.expectEqualDeep(expected.before, state_at_control.?);
        }
        for (host.probe_states[0..host.probes]) |state_at_probe| {
            try std.testing.expectEqualDeep(expected.before, state_at_probe.?);
        }
        if (host.reload_state) |state_at_reload| {
            try std.testing.expectEqualDeep(expected.before, state_at_reload);
            try std.testing.expectEqual(host.resets, host.resets_at_reload);
        }
        if (event == .commit and got.outcome != .excluded) {
            try std.testing.expectEqual(@as(usize, if (phase == .first) 1 else 0), host.probes);
        }
        if (event == .rollback) {
            const postcheck_reached = phase != .lost and phase != .open and tx and failure != .injected and failure != .control1;
            const probes: usize = if (phase == .lost) 0 else if (postcheck_reached) 2 else 1;
            try std.testing.expectEqual(probes, host.probes);
            const reset = phase != .lost and phase != .open and (!tx or (failure != .injected and failure != .control1 and failure != .postcheck));
            try std.testing.expectEqual(@as(usize, if (reset) 1 else 0), host.resets);
        }
        if (event == .finish and got.outcome != .excluded) {
            if (host.announce_state) |state| try std.testing.expectEqualDeep(expected.before, state);
            if (host.failure_state) |state| try std.testing.expectEqualDeep(expected.before, state);
            try std.testing.expectEqual(@as(usize, if (got.outcome == .ok) 1 else 0), host.announcements);
            try std.testing.expectEqual(@as(usize, if (got.outcome == .failed) 1 else 0), host.finish_failures);
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
                    var host: TestHost = .{ .state = state };
                    try executeBegin(&host, state);
                    for (host.controls[0..host.control_count]) |control| {
                        actual[actual_len] = control;
                        actual_len += 1;
                    }
                    state = host.state;
                    host = .{ .state = state, .transaction = true, .failure = switch (kind) {
                        .fail_first => .control1,
                        .fail_second => .control2,
                        .fail_reload => .reload,
                        else => .none,
                    } };
                    if (kind == .commit) {
                        host.transaction = if (first) first_tx else true;
                        try executeCommit(&host, state);
                    } else {
                        executeRollback(&host, state, false) catch {};
                    }
                    for (host.controls[0..host.control_count]) |control| {
                        actual[actual_len] = control;
                        actual_len += 1;
                    }
                    state = host.state;
                    expected_states[write_index] = .{ .phase = expected_phase };
                    actual_states[write_index] = state;
                }
                if (expected_phase == .open) {
                    expected[expected_len] = .commit;
                    expected_len += 1;
                }
                const final_phase = state.phase;
                var finish_host: TestHost = .{ .state = state };
                _ = executeFinish(&finish_host, finish(state));
                for (finish_host.controls[0..finish_host.control_count]) |control| {
                    actual[actual_len] = control;
                    actual_len += 1;
                }
                if (expected_phase != final_phase or expected_len != actual_len) {
                    std.debug.print("SH-93 sequence first_tx={} length={} encoded={} expected_phase={any} actual_phase={any}\n", .{ first_tx, length, encoded, expected_phase, final_phase });
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

// Literal effect order from the pre-extraction Store shell. Apply records
// include the executor's whole-state writes around the original effects.
test "SH-93 executor effect order" {
    const Event = enum { begin, commit, rollback, finish };
    const Row = struct { event: Event, state: State, tx: bool = false, failure: TestFailure = .none, events: []const TestEvent };
    const rows = [_]Row{
        .{ .event = .begin, .state = .{ .phase = .ready }, .events = &.{ .verify, .apply, .control, .apply } },
        .{ .event = .commit, .state = .{ .phase = .first }, .tx = true, .events = &.{ .probe, .apply, .apply } },
        .{ .event = .commit, .state = .{}, .events = &.{ .apply, .control, .apply, .reset_identities } },
        .{ .event = .rollback, .state = .{ .phase = .open, .savepoint = true }, .tx = true, .events = &.{ .apply, .probe, .control, .control, .reload, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .open, .savepoint = true }, .tx = true, .failure = .control1, .events = &.{ .apply, .probe, .control, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .open, .savepoint = true }, .tx = true, .failure = .control2, .events = &.{ .apply, .probe, .control, .control, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .lost }, .events = &.{ .apply, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .first }, .tx = true, .events = &.{ .apply, .probe, .control, .probe, .reset_second, .reload, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .first }, .tx = true, .failure = .postcheck, .events = &.{ .apply, .probe, .control, .probe, .apply } },
        .{ .event = .rollback, .state = .{ .phase = .first }, .tx = true, .failure = .reload, .events = &.{ .apply, .probe, .control, .probe, .reset_second, .reload, .apply } },
        .{ .event = .rollback, .state = .{}, .events = &.{ .apply, .probe, .reset_second, .reload, .apply } },
        .{ .event = .finish, .state = .{ .phase = .open }, .events = &.{ .apply, .control, .announce, .apply } },
        .{ .event = .finish, .state = .{ .phase = .open }, .failure = .control1, .events = &.{ .apply, .control, .finish_failure, .apply } },
    };
    for (rows) |row| {
        var host: TestHost = .{ .state = row.state, .transaction = row.tx, .failure = row.failure };
        switch (row.event) {
            .begin => try executeBegin(&host, row.state),
            .commit => try executeCommit(&host, row.state),
            .rollback => executeRollback(&host, row.state, false) catch {},
            .finish => _ = executeFinish(&host, finish(row.state)),
        }
        var events: [16]TestEvent = undefined;
        for (host.events[0..host.event_count], 0..) |event, i| events[i] = event.?;
        try std.testing.expectEqualSlices(TestEvent, row.events, events[0..host.event_count]);
    }
}

test "SH-93 executor probe reset and finish effects" {
    // The original finish defer resets only the phase after callbacks/fencing.
    var callback_host: TestHost = .{ .state = .{ .phase = .open }, .announce_changes_to = .{ .phase = .first, .savepoint = true } };
    try std.testing.expect(executeFinish(&callback_host, finish(callback_host.state)));
    try std.testing.expectEqualDeep(State{ .savepoint = true }, callback_host.state);
    var failure_host: TestHost = .{ .state = .{ .phase = .open }, .failure = .control1, .failure_changes_to = .{ .phase = .first, .savepoint = true } };
    try std.testing.expect(!executeFinish(&failure_host, finish(failure_host.state)));
    try std.testing.expectEqualDeep(State{ .savepoint = true }, failure_host.state);
    var begin_host: TestHost = .{ .state = .{ .phase = .ready } };
    try executeBegin(&begin_host, begin_host.state);
    try std.testing.expectEqual(@as(usize, 1), begin_host.verified);
    try std.testing.expectEqual(@as(usize, 0), begin_host.identities_reset);
    var commit_host: TestHost = .{ .state = .{} };
    try executeCommit(&commit_host, commit_host.state);
    try std.testing.expectEqual(@as(usize, 1), commit_host.identities_reset);
    var commit_error: TestHost = .{ .state = .{}, .failure = .control1 };
    try std.testing.expectError(error.Injected, executeCommit(&commit_error, commit_error.state));
    try std.testing.expectEqual(@as(usize, 0), commit_error.identities_reset);
    var lost: TestHost = .{ .state = .{ .phase = .lost, .savepoint = true }, .transaction = true };
    try std.testing.expectError(error.CanonicalRollbackFailed, executeRollback(&lost, lost.state, false));
    try std.testing.expectEqual(@as(usize, 0), lost.probes);
    try std.testing.expectEqualDeep(State{ .phase = .lost, .savepoint = true }, lost.state);
    var rejected: TestHost = .{ .state = .{ .phase = .open, .savepoint = true } };
    try std.testing.expectError(error.CanonicalRollbackFailed, executeRollback(&rejected, rejected.state, false));
    try std.testing.expectEqual(@as(usize, 1), rejected.probes);
    try std.testing.expectEqualDeep(State{ .phase = .open }, rejected.before.?);
    try std.testing.expectEqualDeep(State{ .phase = .lost }, rejected.state);
    var restored: TestHost = .{ .state = .{ .phase = .first }, .transaction = true };
    try executeRollback(&restored, restored.state, false);
    try std.testing.expectEqual(@as(usize, 2), restored.probes);
    try std.testing.expectEqual(@as(usize, 1), restored.resets);
    try std.testing.expect(restored.reload_called);
    var failed: TestHost = .{ .state = .{ .phase = .first }, .transaction = true, .failure = .postcheck };
    try std.testing.expectError(error.CanonicalRollbackFailed, executeRollback(&failed, failed.state, false));
    try std.testing.expectEqual(@as(usize, 0), failed.resets);
    try std.testing.expect(!failed.reload_called);
    var done: TestHost = .{ .state = .{ .phase = .open } };
    try std.testing.expect(executeFinish(&done, finish(done.state)));
    try std.testing.expectEqual(@as(usize, 1), done.announcements);
    try std.testing.expectEqualDeep(State{}, done.state);
    var commit_failed: TestHost = .{ .state = .{ .phase = .open }, .failure = .control1 };
    try std.testing.expect(!executeFinish(&commit_failed, finish(commit_failed.state)));
    try std.testing.expectEqual(@as(usize, 1), commit_failed.finish_failures);
    try std.testing.expectEqual(@as(usize, 0), commit_failed.announcements);
    try std.testing.expectEqualDeep(State{}, commit_failed.state);
}

test "SH-93 plan outputs and probe decisions" {
    for (std.meta.tags(Phase)) |phase| for ([_]bool{ false, true }) |sp| for ([_]bool{ false, true }) |tx| {
        const s: State = .{ .phase = phase, .savepoint = sp };
        try std.testing.expectEqual(phase == .first, commitNeedsTransaction(s));
        const before: State = if (phase == .open) .{ .phase = .open } else s;
        try std.testing.expectEqualDeep(RollbackPreparation{ .before = before, .probe_transaction = phase != .lost }, prepareRollback(s));
        const rejected = phase == .lost or (phase == .open and !tx);
        const expected: Rollback = if (rejected) .{
            .before = before,
            .controls = .{ null, null },
            .must_leave_transaction = false,
            .reload_identities = false,
            .ok = if (phase == .lost) s else .{ .phase = .lost },
            .failed = if (phase == .lost) s else .{ .phase = .lost },
            .rejected = true,
            .reset_second = false,
        } else if (phase == .open) .{
            .before = before,
            .controls = if (sp) .{ .rollback_to, .release } else .{ null, null },
            .must_leave_transaction = false,
            .reload_identities = true,
            .ok = .{ .phase = .open },
            .failed = .{ .phase = .lost },
            .rejected = false,
            .reset_second = false,
        } else .{
            .before = s,
            .controls = .{ if (tx) .rollback else null, null },
            .must_leave_transaction = tx,
            .reload_identities = true,
            .ok = if (phase == .first) .{ .phase = .ready, .savepoint = sp } else s,
            .failed = if (phase == .first) .{ .phase = .lost, .savepoint = sp } else s,
            .rejected = false,
            .reset_second = true,
        };
        try std.testing.expectEqualDeep(expected, rollback(s, tx));
        switch (beginDecision(s)) {
            .step, .savepoint_open => |step| {
                const next: State = switch (phase) {
                    .none => s,
                    .ready => .{ .phase = .first, .savepoint = sp },
                    .open => .{ .phase = .open, .savepoint = true },
                    else => unreachable,
                };
                try std.testing.expectEqualDeep(Step{ .before = s, .control = if (phase == .open) .savepoint else .begin, .then = next, .failed = s, .verify_identities = phase == .none or phase == .ready }, step);
            },
            .unreachable_phase => try std.testing.expect(phase == .first or phase == .saved or phase == .lost),
        }
        switch (commitDecision(s, tx)) {
            .step => |step| {
                const next: State = switch (phase) {
                    .none => s,
                    .first => .{ .phase = if (tx) .open else .saved, .savepoint = sp },
                    .open => .{ .phase = .open },
                    else => unreachable,
                };
                const control: ?Control = switch (phase) {
                    .none => .commit,
                    .first => null,
                    .open => .release,
                    else => unreachable,
                };
                try std.testing.expectEqualDeep(Step{ .before = s, .control = control, .then = next, .failed = s, .reset_identities = phase == .none }, step);
            },
            .unreachable_phase => try std.testing.expect(phase == .ready or phase == .saved or phase == .lost),
        }
        switch (finishDecision(s)) {
            .result => |plan| {
                const result: Finish = switch (phase) {
                    .ready, .saved => .nothing,
                    .open => .commit,
                    .lost => .rollback_failed,
                    else => unreachable,
                };
                const after: State = .{ .phase = .none, .savepoint = sp };
                try std.testing.expectEqualDeep(FinishPlan{ .before = s, .result = result, .then = after, .failed = after }, plan);
            },
            .unreachable_phase => try std.testing.expect(phase == .none or phase == .first),
        }
        if (startDecision(s) == .start) {
            try std.testing.expectEqualDeep(Step{ .before = s, .control = null, .then = .{ .phase = .ready, .savepoint = sp }, .failed = s }, start(s));
        } else try std.testing.expect(phase != .none or sp);
    };
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
