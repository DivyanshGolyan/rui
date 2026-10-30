//! Session work: what one Session is doing now, derived from its own rows.
//!
//! The Store reads a fixed set of facts under one lock, none of which grows
//! with history, and `derive` turns them into one `WorkState`. Session list
//! rows, activity pages, Current and Message progress all report this one
//! value, so no two readers can disagree. Nothing here is stored: there is no
//! phase column, and every `since` is a commit time the owning row already
//! saved.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const turn_policy = @import("turn_policy.zig");
const transport_policy = @import("transport_policy.zig");

/// The saved code bound (`turn.outcome_code`, `model_operation.last_failure_code`).
pub const max_code_bytes = 96;
/// The saved Tool Call description bound (`model_tool_call.description`).
pub const max_description_bytes = 100;

/// The closed set that frontends, scripts and agents switch on.
pub const Kind = enum { idle, pending, working, retrying, bash, approval, stopping, finished, failed, stopped };

/// Why a Session's latest work stopped.
pub const StopCause = enum {
    /// A Session stop selected the Turn or excluded queued input.
    stop,
    /// A Model Interruption cancelled the Turn.
    interruption,
};

/// One value per Session. Every variant carries `since`: the Host Unix second
/// the Session entered this state, read from the row whose commit made it so.
pub const WorkState = union(Kind) {
    /// No Turn, nothing queued and no stop excluded input.
    idle: Since,
    /// Eligible but not admitted: queued input, a continuation, approved Bash
    /// awaiting a slot, or a retry whose due time has passed.
    pending: Since,
    /// A model Attempt is admitted and unresolved.
    working: Since,
    /// The model Operation waits for a future retry time. `attempt` is the
    /// ordinal of the Attempt that failed; `cause` its failure code.
    retrying: Retrying,
    /// At least one Bash Action is running. `description` is the oldest
    /// running call's saved description; `approvals` counts sibling Actions
    /// awaiting a Permission Decision.
    bash: Bash,
    /// Every unresolved Action awaits a Permission Decision.
    approval: Since,
    /// A stop selected the active Turn and a running Bash Attempt is settling.
    stopping: Since,
    finished: Since,
    /// `resets_at` is the saved quota reset time, for quota codes only.
    failed: Failed,
    stopped: Stopped,

    pub const Since = struct { since: u64 };
    pub const Retrying = struct { since: u64, due_at_ms: u64, cause: Bounded(max_code_bytes), attempt: u64 };
    pub const Bash = struct { since: u64, description: ?Bounded(max_description_bytes), running: u64, approvals: u64 };
    pub const Failed = struct { since: u64, code: Bounded(max_code_bytes), resets_at: ?u64 };
    pub const Stopped = struct { since: u64, cause: StopCause };

    /// Work under way, as a pending Message's progress reports it
    /// (ARCHITECTURE.md, "Work state and wait conditions"): a retry due in
    /// the future is `in_flight`, a past-due one and approved Bash awaiting
    /// a slot are `runnable`.
    pub const Progress = enum { runnable, in_flight, waiting_for_permission };

    /// Null when no work is under way: idle, or the latest Turn ended.
    pub fn progress(self: WorkState) ?Progress {
        return switch (self) {
            .pending => .runnable,
            .working, .retrying, .bash, .stopping => .in_flight,
            .approval => .waiting_for_permission,
            .idle, .finished, .failed, .stopped => null,
        };
    }

    pub fn since(self: WorkState) u64 {
        return switch (self) {
            inline else => |value| value.since,
        };
    }

    /// The one time rule. A retry falling due commits nothing, so a reader
    /// holding an older value applies this to see it as `pending` from its
    /// due second, never before the retry was scheduled.
    pub fn asOf(self: WorkState, now_ms: u64) WorkState {
        return switch (self) {
            .retrying => |retry| if (retry.due_at_ms <= now_ms) .{ .pending = .{ .since = @max(retry.since, retry.due_at_ms / 1000) } } else self,
            else => self,
        };
    }
};

/// What the Store read for one Session, as plain values. Slices borrow the
/// reader's statements for the duration of `derive`.
pub const Inputs = struct {
    now_ms: u64,
    /// `session.created_at`.
    created_at: u64,
    /// The Session's latest Turn and its current Operation, if any.
    latest: ?Turn = null,
    /// Without an active Turn: `admitted_at` of the oldest eligible queued
    /// Message. Ignored beside an active Turn.
    oldest_pending_at: ?u64 = null,
    /// Without an active Turn: the newest admission a stop excluded, with the
    /// earliest stop that excluded it. Ignored beside an active Turn.
    excluded: ?Excluded = null,

    pub const Excluded = struct { admission: u64, stop_position: u64, stop_at: u64 };

    pub const Turn = struct {
        turn_id: u64,
        /// The current Operation's ID; `op` is its state.
        operation_id: u64,
        /// The newest admission this Turn bound as input.
        input_cutoff: u64,
        /// `stopped_at` of the earliest stop that selected this Turn.
        stopped_at: ?u64 = null,
        terminal: ?Terminal = null,
        op: Op,
        /// Every Action the current Operation proposed, aggregated. Read for
        /// an active Turn only.
        actions: Actions = .{},
    };

    pub const Terminal = struct {
        outcome: enum { completed, cancelled, failed },
        /// The saved outcome code.
        code: []const u8,
        at: u64,
        position: u64,
        /// The failed Operation's saved diagnostic, when it is small enough
        /// to be a quota record. Unreadable bytes give no reset time.
        diagnostic: ?[]const u8 = null,
    };

    /// The current Operation, in the three states its CHECK allows.
    pub const Op = union(enum) {
        in_flight: struct { attempt_at: u64 },
        waiting: struct { scheduled_at: u64, due_at_ms: u64, cause: []const u8, attempt: u64 },
        /// `resolution` is null for a failure code.
        resolved: struct { resolution: ?turn_policy.Resolution, at: u64 },
    };

    pub const Actions = struct {
        total: u64 = 0,
        unresolved: u64 = 0,
        /// Unresolved and not authorized: awaiting a Permission Decision.
        awaiting: u64 = 0,
        first_awaiting: ?u64 = null,
        /// Unresolved with a launched Attempt.
        running: u64 = 0,
        oldest_running: ?Running = null,
        /// The latest decision or resolution in the group, 0 when none.
        latest_change_at: u64 = 0,

        pub const Running = struct { at: u64, description: ?[]const u8 };
    };
};

/// The derived state and the identities that locate it: the latest Turn and
/// its Operation, and the earliest Action awaiting permission.
pub const Work = struct {
    state: WorkState,
    turn: ?u64 = null,
    operation: ?u64 = null,
    first_action: ?u64 = null,
};

/// Applies the Session work table in ARCHITECTURE.md ("Work state and wait
/// conditions"), checked in order.
///
/// Inputs no writer produces return `error.CorruptStore`, and the reader
/// fences as it does for other contradictions.
pub fn derive(inputs: Inputs) error{CorruptStore}!Work {
    const latest = inputs.latest orelse return .{ .state = settled(inputs, null) orelse .{ .idle = .{ .since = inputs.created_at } } };
    const actions = latest.actions;
    if (actions.unresolved > actions.total or actions.awaiting + actions.running > actions.unresolved or
        (actions.awaiting == 0) != (actions.first_awaiting == null) or
        (actions.running == 0) != (actions.oldest_running == null)) return error.CorruptStore;
    // Only an active Turn's tool proposals own Actions.
    const proposed = latest.op == .resolved and latest.op.resolved.resolution == .tool_proposals;
    if (actions.total != 0 and (latest.terminal != null or !proposed)) return error.CorruptStore;
    var work: Work = .{ .state = undefined, .turn = latest.turn_id, .operation = latest.operation_id, .first_action = actions.first_awaiting };
    if (latest.terminal) |terminal| {
        if (latest.op != .resolved) return error.CorruptStore;
        work.state = settled(inputs, terminal) orelse switch (terminal.outcome) {
            .completed => .{ .finished = .{ .since = terminal.at } },
            .cancelled => .{ .stopped = .{ .since = terminal.at, .cause = if (latest.stopped_at != null) .stop else .interruption } },
            .failed => .{ .failed = .{ .since = terminal.at, .code = try bounded(max_code_bytes, terminal.code), .resets_at = quotaResetsAt(terminal.code, terminal.diagnostic) } },
        };
        return work;
    }
    if (latest.stopped_at) |at| {
        work.state = .{ .stopping = .{ .since = at } };
        return work;
    }
    work.state = switch (latest.op) {
        .in_flight => |attempt| .{ .working = .{ .since = attempt.attempt_at } },
        .waiting => |retry| (WorkState{ .retrying = .{
            .since = retry.scheduled_at,
            .due_at_ms = retry.due_at_ms,
            .cause = try bounded(max_code_bytes, retry.cause),
            .attempt = retry.attempt,
        } }).asOf(inputs.now_ms),
        .resolved => |resolved| state: {
            // A failure code closes its Turn in the same transaction.
            const resolution = resolved.resolution orelse return error.CorruptStore;
            if (resolution != .tool_proposals) break :state .{ .pending = .{ .since = resolved.at } };
            if (actions.oldest_running) |running| break :state .{ .bash = .{
                .since = running.at,
                .description = if (running.description) |text| try bounded(max_description_bytes, text) else null,
                .running = actions.running,
                .approvals = actions.awaiting,
            } };
            const since = @max(resolved.at, actions.latest_change_at);
            break :state if (actions.unresolved != 0 and actions.awaiting == actions.unresolved)
                .{ .approval = .{ .since = since } }
            else
                .{ .pending = .{ .since = since } };
        },
    };
    return work;
}

/// Queued or stop-excluded input decides a Session with no active Turn
/// before its latest outcome does.
fn settled(inputs: Inputs, terminal: ?Inputs.Terminal) ?WorkState {
    if (inputs.oldest_pending_at) |at| return .{ .pending = .{ .since = @max(at, if (terminal) |t| t.at else 0) } };
    const excluded = inputs.excluded orelse return null;
    if (inputs.latest) |latest| {
        // A Turn binds every eligible queued Message at its start, and an
        // outcome after the stop is the newer fact.
        if (excluded.admission <= latest.input_cutoff) return null;
        if (terminal) |t| if (excluded.stop_position < t.position) return null;
    }
    return .{ .stopped = .{ .since = excluded.stop_at, .cause = .stop } };
}

/// A quota failure's saved reset time; null for any other code or an
/// unreadable record.
pub fn quotaResetsAt(code: []const u8, diagnostic: ?[]const u8) ?u64 {
    const bytes = diagnostic orelse return null;
    const quota = transport_policy.Quota.parse(bytes) orelse return null;
    if (!std.mem.eql(u8, quota.failureCode(), code)) return null;
    return quota.resets_at;
}

fn bounded(comptime capacity: usize, text: []const u8) error{CorruptStore}!Bounded(capacity) {
    var value: Bounded(capacity) = .{};
    value.set(text) catch return error.CorruptStore;
    return value;
}

fn activeTurn(op: Inputs.Op, actions: Inputs.Actions) Inputs.Turn {
    return .{ .turn_id = 7, .operation_id = 19, .input_cutoff = 5, .op = op, .actions = actions };
}

fn proposals(at: u64) Inputs.Op {
    return .{ .resolved = .{ .resolution = .tool_proposals, .at = at } };
}

fn endedTurn(outcome: @FieldType(Inputs.Terminal, "outcome"), code: []const u8) Inputs.Turn {
    return .{
        .turn_id = 7,
        .operation_id = 19,
        .input_cutoff = 5,
        .terminal = .{ .outcome = outcome, .code = code, .at = 500, .position = 40 },
        .op = .{ .resolved = .{ .resolution = if (outcome == .completed) .answer else null, .at = 499 } },
    };
}

fn expectState(expected: WorkState, inputs: Inputs) !void {
    const actual = (try derive(inputs)).state;
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    try std.testing.expectEqual(expected.since(), actual.since());
    switch (expected) {
        .retrying => |retry| {
            try std.testing.expectEqual(retry.due_at_ms, actual.retrying.due_at_ms);
            try std.testing.expectEqualStrings(retry.cause.slice(), actual.retrying.cause.slice());
            try std.testing.expectEqual(retry.attempt, actual.retrying.attempt);
        },
        .bash => |bash| {
            try std.testing.expectEqual(bash.running, actual.bash.running);
            try std.testing.expectEqual(bash.approvals, actual.bash.approvals);
            try std.testing.expectEqual(bash.description == null, actual.bash.description == null);
            if (bash.description) |text| try std.testing.expectEqualStrings(text.slice(), actual.bash.description.?.slice());
        },
        .failed => |failed| {
            try std.testing.expectEqualStrings(failed.code.slice(), actual.failed.code.slice());
            try std.testing.expectEqual(failed.resets_at, actual.failed.resets_at);
        },
        .stopped => |stopped| try std.testing.expectEqual(stopped.cause, actual.stopped.cause),
        else => {},
    }
}

fn fixed(comptime capacity: usize, value: []const u8) Bounded(capacity) {
    return bounded(capacity, value) catch unreachable;
}

test "a Session with no Turn is idle, pending or stopped by its queue" {
    try expectState(.{ .idle = .{ .since = 100 } }, .{ .now_ms = 0, .created_at = 100 });
    try expectState(.{ .pending = .{ .since = 120 } }, .{ .now_ms = 0, .created_at = 100, .oldest_pending_at = 120 });
    try expectState(.{ .stopped = .{ .since = 130, .cause = .stop } }, .{
        .now_ms = 0,
        .created_at = 100,
        .excluded = .{ .admission = 1, .stop_position = 2, .stop_at = 130 },
    });
    // Eligible input outranks an earlier stop's exclusion.
    try expectState(.{ .pending = .{ .since = 140 } }, .{
        .now_ms = 0,
        .created_at = 100,
        .oldest_pending_at = 140,
        .excluded = .{ .admission = 1, .stop_position = 2, .stop_at = 130 },
    });
    const work = try derive(.{ .now_ms = 0, .created_at = 100 });
    try std.testing.expect(work.turn == null and work.operation == null and work.first_action == null);
}

test "an active Turn reports its Operation's state from the row that set it" {
    try expectState(.{ .working = .{ .since = 300 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(.{ .in_flight = .{ .attempt_at = 300 } }, .{}) });
    const waiting: Inputs.Op = .{ .waiting = .{ .scheduled_at = 310, .due_at_ms = 320_500, .cause = "provider_temporary_http_429", .attempt = 2 } };
    try expectState(.{ .retrying = .{ .since = 310, .due_at_ms = 320_500, .cause = fixed(max_code_bytes, "provider_temporary_http_429"), .attempt = 2 } }, .{
        .now_ms = 320_499,
        .created_at = 1,
        .latest = activeTurn(waiting, .{}),
    });
    // A past-due retry waits for a slot, from its due second.
    try expectState(.{ .pending = .{ .since = 320 } }, .{ .now_ms = 320_500, .created_at = 1, .latest = activeTurn(waiting, .{}) });
    // A due time set before the scheduling second cannot predate the state.
    const early: Inputs.Op = .{ .waiting = .{ .scheduled_at = 310, .due_at_ms = 1, .cause = "provider_temporary_http_429", .attempt = 2 } };
    try expectState(.{ .pending = .{ .since = 310 } }, .{ .now_ms = 2, .created_at = 1, .latest = activeTurn(early, .{}) });
    for ([_]turn_policy.Resolution{ .answer, .compacted, .interrupted, .context_overflow }) |resolution| {
        try expectState(.{ .pending = .{ .since = 330 } }, .{
            .now_ms = 0,
            .created_at = 1,
            .latest = activeTurn(.{ .resolved = .{ .resolution = resolution, .at = 330 } }, .{}),
        });
    }
    const work = try derive(.{ .now_ms = 0, .created_at = 1, .latest = activeTurn(.{ .in_flight = .{ .attempt_at = 300 } }, .{}) });
    try std.testing.expectEqual(@as(?u64, 7), work.turn);
    try std.testing.expectEqual(@as(?u64, 19), work.operation);
}

test "a proposal group is Bash, approval or pending by its Actions" {
    const running: Inputs.Actions = .{
        .total = 4,
        .unresolved = 3,
        .awaiting = 1,
        .first_awaiting = 41,
        .running = 2,
        .oldest_running = .{ .at = 350, .description = "Run the resize tests" },
        .latest_change_at = 360,
    };
    try expectState(.{ .bash = .{ .since = 350, .description = fixed(max_description_bytes, "Run the resize tests"), .running = 2, .approvals = 1 } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = activeTurn(proposals(340), running),
    });
    try std.testing.expectEqual(@as(?u64, 41), (try derive(.{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), running) })).first_action);
    var undescribed = running;
    undescribed.oldest_running.?.description = null;
    try expectState(.{ .bash = .{ .since = 350, .description = null, .running = 2, .approvals = 1 } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = activeTurn(proposals(340), undescribed),
    });

    // Every unresolved Action awaits permission: since the group last changed.
    const awaiting: Inputs.Actions = .{ .total = 2, .unresolved = 2, .awaiting = 2, .first_awaiting = 41 };
    try expectState(.{ .approval = .{ .since = 340 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), awaiting) });
    var after_sibling = awaiting;
    after_sibling.total = 3;
    after_sibling.latest_change_at = 380;
    try expectState(.{ .approval = .{ .since = 380 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), after_sibling) });

    // Approved Bash awaiting a slot, a settled group awaiting continuation,
    // or proposals that were all rejected and own no Action.
    const approved: Inputs.Actions = .{ .total = 2, .unresolved = 2, .awaiting = 1, .first_awaiting = 42, .latest_change_at = 390 };
    try expectState(.{ .pending = .{ .since = 390 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), approved) });
    const settled_group: Inputs.Actions = .{ .total = 2, .latest_change_at = 395 };
    try expectState(.{ .pending = .{ .since = 395 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), settled_group) });
    try expectState(.{ .pending = .{ .since = 340 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), .{}) });
}

test "a stop that selected the active Turn outranks its Operation" {
    var turn = activeTurn(proposals(340), .{
        .total = 2,
        .unresolved = 1,
        .running = 1,
        .oldest_running = .{ .at = 350, .description = null },
        .latest_change_at = 350,
    });
    turn.stopped_at = 400;
    try expectState(.{ .stopping = .{ .since = 400 } }, .{ .now_ms = 0, .created_at = 1, .latest = turn });
}

test "a settled Session reports its latest outcome unless input came after it" {
    try expectState(.{ .finished = .{ .since = 500 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed") });
    try expectState(.{ .stopped = .{ .since = 500, .cause = .interruption } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.cancelled, "cancelled") });
    var stopped = endedTurn(.cancelled, "cancelled");
    stopped.stopped_at = 450;
    try expectState(.{ .stopped = .{ .since = 500, .cause = .stop } }, .{ .now_ms = 0, .created_at = 1, .latest = stopped });
    try expectState(.{ .failed = .{ .since = 500, .code = fixed(max_code_bytes, "retry_exhausted"), .resets_at = null } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = endedTurn(.failed, "retry_exhausted"),
    });

    // Queued input after the outcome makes the Session pending again.
    try expectState(.{ .pending = .{ .since = 510 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending_at = 510 });
    try expectState(.{ .pending = .{ .since = 500 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending_at = 490 });

    // A stop after the outcome that excluded newer input stops the Session.
    try expectState(.{ .stopped = .{ .since = 520, .cause = .stop } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = endedTurn(.completed, "completed"),
        .excluded = .{ .admission = 6, .stop_position = 41, .stop_at = 520 },
    });
    // Input the Turn already bound, or a stop older than the outcome, does not.
    try expectState(.{ .finished = .{ .since = 500 } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = endedTurn(.completed, "completed"),
        .excluded = .{ .admission = 5, .stop_position = 41, .stop_at = 520 },
    });
    try expectState(.{ .stopped = .{ .since = 500, .cause = .stop } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = stopped,
        .excluded = .{ .admission = 6, .stop_position = 39, .stop_at = 450 },
    });
}

test "a quota failure carries its saved reset time and nothing else does" {
    var turn = endedTurn(.failed, "provider_usage_limit_reached");
    turn.terminal.?.diagnostic = "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":1792940000}";
    try expectState(.{ .failed = .{ .since = 500, .code = fixed(max_code_bytes, "provider_usage_limit_reached"), .resets_at = 1792940000 } }, .{ .now_ms = 0, .created_at = 1, .latest = turn });
    for ([_][]const u8{
        "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":null}",
        "{\"provider_code\":\"insufficient_quota\",\"resets_at\":1792940000}",
        "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":1792940000} ",
        "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":01}",
        "not json",
    }) |diagnostic| {
        turn.terminal.?.diagnostic = diagnostic;
        try std.testing.expectEqual(@as(?u64, null), (try derive(.{ .now_ms = 0, .created_at = 1, .latest = turn })).state.failed.resets_at);
    }
    try std.testing.expectEqual(@as(?u64, null), quotaResetsAt("provider_http_401", "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":5}"));
}

test "inputs no writer produces are corrupt" {
    const unresolved: Inputs.Op = .{ .in_flight = .{ .attempt_at = 300 } };
    const group: Inputs.Actions = .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41 };
    var ended_with_group = endedTurn(.cancelled, "cancelled");
    ended_with_group.actions = .{ .total = 1 };
    for ([_]Inputs.Turn{
        // Actions beside an unresolved or non-proposal Operation, or a Turn
        // that already ended.
        activeTurn(unresolved, group),
        activeTurn(.{ .resolved = .{ .resolution = .answer, .at = 330 } }, group),
        ended_with_group,
        // A failure code on an active Turn.
        activeTurn(.{ .resolved = .{ .resolution = null, .at = 330 } }, .{}),
        // Counts that disagree with themselves.
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 2 }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1 }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41, .running = 1, .oldest_running = .{ .at = 1, .description = null } }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .running = 1 }),
        // A terminal Turn whose Operation never resolved.
        .{ .turn_id = 7, .operation_id = 19, .input_cutoff = 5, .terminal = .{ .outcome = .completed, .code = "completed", .at = 500, .position = 40 }, .op = unresolved },
        // A saved code beyond its bound.
        activeTurn(.{ .waiting = .{ .scheduled_at = 1, .due_at_ms = 2, .cause = &@as([max_code_bytes + 1]u8, @splat('x')), .attempt = 1 } }, .{}),
    }) |turn| {
        try std.testing.expectError(error.CorruptStore, derive(.{ .now_ms = 0, .created_at = 1, .latest = turn }));
    }
}

test "progress follows the work table" {
    const expected = std.enums.EnumArray(Kind, ?WorkState.Progress).init(.{
        .idle = null,
        .pending = .runnable,
        .working = .in_flight,
        .retrying = .in_flight,
        .bash = .in_flight,
        .approval = .waiting_for_permission,
        .stopping = .in_flight,
        .finished = null,
        .failed = null,
        .stopped = null,
    });
    inline for (comptime std.enums.values(Kind)) |kind| {
        const state = @unionInit(WorkState, @tagName(kind), switch (kind) {
            .retrying => .{ .since = 1, .due_at_ms = 5_000, .cause = .{}, .attempt = 1 },
            .bash => .{ .since = 1, .description = null, .running = 1, .approvals = 0 },
            .failed => .{ .since = 1, .code = .{}, .resets_at = null },
            .stopped => .{ .since = 1, .cause = .stop },
            else => .{ .since = 1 },
        });
        try std.testing.expectEqual(expected.get(kind), state.progress());
        try std.testing.expectEqual(@as(u64, 1), state.since());
        // Only a due retry changes with time.
        try std.testing.expectEqual(kind == .retrying, std.meta.activeTag(state.asOf(5_000)) != kind);
        try std.testing.expectEqual(kind, std.meta.activeTag(state.asOf(4_999)));
    }
}
