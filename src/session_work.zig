const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const turn_policy = @import("turn_policy.zig");
const transport_policy = @import("transport_policy.zig");
const retry_policy = @import("retry_policy.zig");

pub const max_code_bytes = 96;
pub const max_description_bytes = @import("tool_presentation.zig").max_description_bytes;

pub const max_retried_attempt = retry_policy.maximum_attempts - 1;

pub const Kind = enum { idle, pending, working, retrying, bash, approval, stopping, finished, failed, stopped };

pub const StopCause = enum {
    stop,
    interruption,
};

pub const WorkState = union(Kind) {
    idle: Since,
    pending: Since,
    working: Since,
    retrying: Retrying,
    bash: Bash,
    approval: Since,
    stopping: Since,
    finished: Since,
    failed: Failed,
    stopped: Stopped,

    pub const Since = struct { since: u64, compaction: bool = false };
    pub const Retrying = struct { since: u64, due_at_ms: u64, cause: Bounded(max_code_bytes), attempt: u64 };
    pub const Bash = struct { since: u64, call: ?u64, description: ?Bounded(max_description_bytes), running: u64, approvals: u64 };
    pub const Failed = struct { since: u64, code: Bounded(max_code_bytes), resets_at: ?u64 };
    pub const Stopped = struct { since: u64, cause: StopCause };

    pub const Progress = enum { runnable, in_flight, waiting_for_permission };

    pub fn progress(self: WorkState) ?Progress {
        return switch (self) {
            .pending => .runnable,
            .working, .retrying, .bash, .stopping => .in_flight,
            .approval => .waiting_for_permission,
            .idle, .finished, .failed, .stopped => null,
        };
    }

    pub fn holdsQueue(self: WorkState) bool {
        const progress_ = self.progress() orelse return false;
        return progress_ != .runnable;
    }

    pub fn since(self: WorkState) u64 {
        return switch (self) {
            inline else => |value| value.since,
        };
    }

    pub fn asOf(self: WorkState, now_ms: u64) WorkState {
        return switch (self) {
            .retrying => |retry| if (retry.due_at_ms <= now_ms) .{ .pending = .{ .since = @max(retry.since, retry.due_at_ms / 1000) } } else self,
            else => self,
        };
    }
};

pub const Inputs = struct {
    now_ms: u64,
    created_at: u64,
    latest: ?Turn = null,
    first_action: ?u64 = null,
    oldest_pending: ?Pending = null,
    excluded: ?Excluded = null,

    owed_since: ?u64 = null,

    pub const Pending = struct { at: u64, position: u64 };
    pub const Excluded = struct { admission: u64, stop_position: u64, stop_at: u64 };

    pub const Turn = struct {
        turn_id: u64,
        operation_id: u64,
        input_cutoff: u64,
        compaction: bool = false,
        stopped_at: ?u64 = null,
        interruptible: bool = false,
        stop_remaining: bool = false,
        terminal: ?Terminal = null,
        op: Op,
        actions: Inputs.Actions = .{},
    };

    pub const Terminal = struct {
        outcome: enum { completed, cancelled, failed },
        code: []const u8,
        at: u64,
        position: u64,
        resets_at: ?u64 = null,
    };

    pub const Op = union(enum) {
        in_flight: struct { attempt_at: u64 },
        waiting: struct { scheduled_at: u64, due_at_ms: u64, cause: []const u8, attempt: u64 },
        resolved: struct { resolution: ?turn_policy.Resolution, at: u64 },
    };

    pub const Actions = struct {
        total: u64 = 0,
        unresolved: u64 = 0,
        awaiting: u64 = 0,
        first_awaiting: ?u64 = null,
        running: u64 = 0,
        oldest_running: ?Running = null,
        latest_resolution_at: ?u64 = null,
        latest_decision_at: ?u64 = null,

        pub const Running = struct { at: u64, call: u64, description: ?[]const u8 };
    };
};

pub const Work = struct {
    state: WorkState,
    turn: ?u64 = null,
    operation: ?u64 = null,
    first_action: ?u64 = null,
    actions: Actions = .{},
    served_attention: ?Attention = null,
    served_group: ?Group = null,
};

pub const Actions = struct {
    stop: bool = false,
    interrupt: ?struct { turn: u64, operation: u64 } = null,
    decide: ?u64 = null,
};

pub const Attention = struct {
    kind: enum { approval, failed, finished },
    turn: u64,
    step: u64,
};

/// Matches the client classification at base 3e389620a3a6b83e314e02657c9e6a95e67488e8.
pub fn attention(work: Work) ?Attention {
    const turn = work.turn orelse 0;
    return switch (work.state) {
        .approval => .{ .kind = .approval, .turn = turn, .step = work.first_action orelse 0 },
        .bash => |bash| if (bash.approvals != 0) .{ .kind = .approval, .turn = turn, .step = work.first_action orelse 0 } else null,
        .failed => .{ .kind = .failed, .turn = turn, .step = std.math.maxInt(u64) },
        .finished => .{ .kind = .finished, .turn = turn, .step = std.math.maxInt(u64) },
        else => null,
    };
}

pub const Group = enum { needs_you, working, queued, done };

/// Classifies the state as derived at the Host's observation time.
pub fn group(work: Work) Group {
    return switch (work.state) {
        .approval => .needs_you,
        .bash => |bash| if (bash.approvals != 0) .needs_you else .working,
        .working, .retrying, .stopping => .working,
        .pending => .queued,
        .idle, .finished, .failed, .stopped => .done,
    };
}

pub fn derive(inputs: Inputs) error{CorruptStore}!Work {
    var work = try deriveOwn(inputs);
    if (work.state.progress() == null) {
        if (inputs.owed_since) |at| work.state = .{ .working = .{ .since = @max(work.state.since(), at) } };
    }
    const current = if (inputs.latest) |turn| turn.terminal == null and turn.stopped_at == null else false;
    work.actions.stop = current or inputs.oldest_pending != null or inputs.owed_since != null or if (inputs.latest) |turn| turn.stop_remaining else false;
    if (inputs.latest) |turn| {
        if (current and turn.interruptible and turn.op == .in_flight) work.actions.interrupt = .{ .turn = turn.turn_id, .operation = turn.operation_id };
    }
    work.actions.decide = inputs.first_action;
    return work;
}

fn deriveOwn(inputs: Inputs) error{CorruptStore}!Work {
    const latest = inputs.latest orelse {
        if (inputs.first_action != null) return error.CorruptStore;
        return .{ .state = settled(inputs, null) orelse .{ .idle = .{ .since = inputs.created_at } } };
    };
    const actions = latest.actions;
    if (actions.unresolved > actions.total or actions.awaiting + actions.running > actions.unresolved or
        (actions.awaiting == 0) != (actions.first_awaiting == null) or
        (actions.running == 0) != (actions.oldest_running == null) or
        (actions.unresolved == actions.total) != (actions.latest_resolution_at == null)) return error.CorruptStore;
    const proposed = latest.op == .resolved and latest.op.resolved.resolution == .tool_proposals;
    if (actions.total != 0 and (latest.terminal != null or !proposed)) return error.CorruptStore;
    var work: Work = .{ .state = undefined, .turn = latest.turn_id, .operation = latest.operation_id, .first_action = inputs.first_action };
    if (latest.terminal) |terminal| {
        if (latest.op != .resolved) return error.CorruptStore;
        work.state = settled(inputs, terminal) orelse switch (terminal.outcome) {
            .completed => .{ .finished = .{ .since = terminal.at } },
            .cancelled => .{ .stopped = .{ .since = terminal.at, .cause = if (latest.stopped_at != null) .stop else .interruption } },
            .failed => .{ .failed = .{ .since = terminal.at, .code = try bounded(max_code_bytes, terminal.code), .resets_at = terminal.resets_at } },
        };
        return work;
    }
    if (latest.stopped_at) |at| {
        work.state = .{ .stopping = .{ .since = at } };
        return work;
    }
    work.state = switch (latest.op) {
        .in_flight => |attempt| .{ .working = .{ .since = attempt.attempt_at, .compaction = latest.compaction } },
        .waiting => |retry| if (retry.attempt == 0 or retry.attempt > max_retried_attempt) return error.CorruptStore else (WorkState{ .retrying = .{
            .since = retry.scheduled_at,
            .due_at_ms = retry.due_at_ms,
            .cause = try bounded(max_code_bytes, retry.cause),
            .attempt = retry.attempt,
        } }).asOf(inputs.now_ms),
        .resolved => |resolved| state: {
            const resolution = resolved.resolution orelse return error.CorruptStore;
            if (resolution != .tool_proposals) break :state .{ .pending = .{ .since = resolved.at } };
            if (actions.oldest_running) |running| break :state .{ .bash = .{
                .since = running.at,
                .call = running.call,
                .description = if (running.description) |text| try bounded(max_description_bytes, text) else null,
                .running = actions.running,
                .approvals = actions.awaiting,
            } };
            const since = if (actions.latest_resolution_at) |resolved_at|
                if (actions.latest_decision_at) |decided_at| @max(resolved_at, decided_at) else resolved_at
            else
                actions.latest_decision_at orelse resolved.at;
            break :state if (actions.unresolved != 0 and actions.awaiting == actions.unresolved)
                .{ .approval = .{ .since = since } }
            else
                .{ .pending = .{ .since = since } };
        },
    };
    return work;
}

fn settled(inputs: Inputs, terminal: ?Inputs.Terminal) ?WorkState {
    if (inputs.oldest_pending) |pending| {
        const behind = if (terminal) |t| pending.position < t.position else false;
        return .{ .pending = .{ .since = if (behind) terminal.?.at else pending.at } };
    }
    const excluded = inputs.excluded orelse return null;
    if (inputs.latest) |latest| {
        if (excluded.admission <= latest.input_cutoff) return null;
        if (terminal) |t| if (excluded.stop_position < t.position) return null;
    }
    return .{ .stopped = .{ .since = excluded.stop_at, .cause = .stop } };
}

pub fn quotaResetsAt(code: []const u8, diagnostic: ?[]const u8) ?u64 {
    const bytes = diagnostic orelse return null;
    const quota = transport_policy.Quota.parse(bytes) orelse return null;
    if (!std.mem.eql(u8, quota.failureCode(), code)) return null;
    return quota.resets_at;
}

fn bounded(comptime capacity: usize, text: []const u8) error{CorruptStore}!Bounded(capacity) {
    return Bounded(capacity).from(text) catch error.CorruptStore;
}

fn activeTurn(op: Inputs.Op, actions: Inputs.Actions) Inputs.Turn {
    return .{ .turn_id = 7, .operation_id = 19, .input_cutoff = 5, .op = op, .actions = actions, .interruptible = op == .in_flight };
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
            try std.testing.expectEqual(bash.call, actual.bash.call);
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
    try expectState(.{ .pending = .{ .since = 120 } }, .{ .now_ms = 0, .created_at = 100, .oldest_pending = .{ .at = 120, .position = 3 } });
    try expectState(.{ .stopped = .{ .since = 130, .cause = .stop } }, .{
        .now_ms = 0,
        .created_at = 100,
        .excluded = .{ .admission = 1, .stop_position = 2, .stop_at = 130 },
    });
    try expectState(.{ .pending = .{ .since = 140 } }, .{
        .now_ms = 0,
        .created_at = 100,
        .oldest_pending = .{ .at = 140, .position = 3 },
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
    try expectState(.{ .pending = .{ .since = 320 } }, .{ .now_ms = 320_500, .created_at = 1, .latest = activeTurn(waiting, .{}) });
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
        .oldest_running = .{ .at = 350, .call = 2, .description = "Run the resize tests" },
        .latest_resolution_at = 360,
    };
    try expectState(.{ .bash = .{ .since = 350, .call = 2, .description = fixed(max_description_bytes, "Run the resize tests"), .running = 2, .approvals = 1 } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = activeTurn(proposals(340), running),
    });
    try std.testing.expectEqual(@as(?u64, 41), (try derive(.{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), running), .first_action = 41 })).first_action);
    var undescribed = running;
    undescribed.oldest_running.?.description = null;
    try expectState(.{ .bash = .{ .since = 350, .call = 2, .description = null, .running = 2, .approvals = 1 } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = activeTurn(proposals(340), undescribed),
    });

    const awaiting: Inputs.Actions = .{ .total = 2, .unresolved = 2, .awaiting = 2, .first_awaiting = 41 };
    try expectState(.{ .approval = .{ .since = 340 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), awaiting) });
    var after_sibling = awaiting;
    after_sibling.total = 3;
    after_sibling.latest_resolution_at = 380;
    try expectState(.{ .approval = .{ .since = 380 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), after_sibling) });

    const approved: Inputs.Actions = .{ .total = 2, .unresolved = 2, .awaiting = 1, .first_awaiting = 42, .latest_decision_at = 390 };
    try expectState(.{ .pending = .{ .since = 390 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), approved) });
    const settled_group: Inputs.Actions = .{ .total = 2, .latest_resolution_at = 395 };
    try expectState(.{ .pending = .{ .since = 395 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), settled_group) });
    try expectState(.{ .pending = .{ .since = 340 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), .{}) });
    var allowed_after_sibling = approved;
    allowed_after_sibling.total = 3;
    allowed_after_sibling.latest_resolution_at = 380;
    try expectState(.{ .pending = .{ .since = 390 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), allowed_after_sibling) });
}

test "the newer fact dates work, even when the clock stepped back" {
    const after_sibling: Inputs.Actions = .{ .total = 2, .unresolved = 1, .awaiting = 1, .first_awaiting = 41, .latest_resolution_at = 300 };
    try expectState(.{ .approval = .{ .since = 300 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), after_sibling) });
    const allowed: Inputs.Actions = .{ .total = 2, .unresolved = 2, .awaiting = 1, .first_awaiting = 42, .latest_decision_at = 330 };
    try expectState(.{ .pending = .{ .since = 330 } }, .{ .now_ms = 0, .created_at = 1, .latest = activeTurn(proposals(340), allowed) });
    try expectState(.{ .pending = .{ .since = 500 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending = .{ .at = 600, .position = 39 } });
    try expectState(.{ .pending = .{ .since = 450 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending = .{ .at = 450, .position = 41 } });
}

test "a stop that selected the active Turn outranks its Operation" {
    var turn = activeTurn(proposals(340), .{
        .total = 2,
        .unresolved = 1,
        .running = 1,
        .oldest_running = .{ .at = 350, .call = 0, .description = null },
        .latest_resolution_at = 350,
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

    try expectState(.{ .pending = .{ .since = 510 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending = .{ .at = 510, .position = 41 } });
    try expectState(.{ .pending = .{ .since = 500 } }, .{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .oldest_pending = .{ .at = 490, .position = 39 } });

    try expectState(.{ .stopped = .{ .since = 520, .cause = .stop } }, .{
        .now_ms = 0,
        .created_at = 1,
        .latest = endedTurn(.completed, "completed"),
        .excluded = .{ .admission = 6, .stop_position = 41, .stop_at = 520 },
    });
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
    var turn = endedTurn(.failed, "provider_quota");
    turn.terminal.?.resets_at = quotaResetsAt("provider_quota", "{\"refusal\":\"quota\",\"resets_at\":1792940000}");
    try expectState(.{ .failed = .{ .since = 500, .code = fixed(max_code_bytes, "provider_quota"), .resets_at = 1792940000 } }, .{ .now_ms = 0, .created_at = 1, .latest = turn });
    for ([_][]const u8{
        "{\"refusal\":\"quota\",\"resets_at\":null}",
        "{\"refusal\":\"plan\",\"resets_at\":1792940000}",
        "{\"refusal\":\"quota\",\"resets_at\":1792940000} ",
        "{\"refusal\":\"quota\",\"resets_at\":01}",
        "not json",
    }) |diagnostic| {
        turn.terminal.?.resets_at = quotaResetsAt("provider_quota", diagnostic);
        try std.testing.expectEqual(@as(?u64, null), (try derive(.{ .now_ms = 0, .created_at = 1, .latest = turn })).state.failed.resets_at);
    }
    try std.testing.expectEqual(@as(?u64, null), quotaResetsAt("provider_http_401", "{\"refusal\":\"quota\",\"resets_at\":5}"));
}

test "inputs no writer produces are corrupt" {
    const unresolved: Inputs.Op = .{ .in_flight = .{ .attempt_at = 300 } };
    const action_group: Inputs.Actions = .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41 };
    var ended_with_group = endedTurn(.cancelled, "cancelled");
    ended_with_group.actions = .{ .total = 1, .latest_resolution_at = 1 };
    for ([_]Inputs.Turn{
        activeTurn(unresolved, action_group),
        activeTurn(.{ .resolved = .{ .resolution = .answer, .at = 330 } }, action_group),
        ended_with_group,
        activeTurn(.{ .resolved = .{ .resolution = null, .at = 330 } }, .{}),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 2 }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1 }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41, .running = 1, .oldest_running = .{ .at = 1, .call = 0, .description = null } }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .running = 1 }),
        activeTurn(proposals(340), .{ .total = 1 }),
        activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41, .latest_resolution_at = 1 }),
        .{ .turn_id = 7, .operation_id = 19, .input_cutoff = 5, .terminal = .{ .outcome = .completed, .code = "completed", .at = 500, .position = 40 }, .op = unresolved },
        activeTurn(.{ .waiting = .{ .scheduled_at = 1, .due_at_ms = 2, .cause = "c", .attempt = max_retried_attempt + 1 } }, .{}),
        activeTurn(.{ .waiting = .{ .scheduled_at = 1, .due_at_ms = 2, .cause = "c", .attempt = 0 } }, .{}),
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
            .bash => .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 0 },
            .failed => .{ .since = 1, .code = .{}, .resets_at = null },
            .stopped => .{ .since = 1, .cause = .stop },
            else => .{ .since = 1 },
        });
        try std.testing.expectEqual(expected.get(kind), state.progress());
        try std.testing.expectEqual(switch (kind) {
            .working, .retrying, .bash, .approval, .stopping => true,
            .idle, .pending, .finished, .failed, .stopped => false,
        }, state.holdsQueue());
        try std.testing.expectEqual(@as(u64, 1), state.since());
        try std.testing.expectEqual(kind == .retrying, std.meta.activeTag(state.asOf(5_000)) != kind);
        try std.testing.expectEqual(kind, std.meta.activeTag(state.asOf(4_999)));
    }
}

test "saved MCP call lines survive pending, running and completed Actions at every boundary" {
    for ([_]usize{ 100, 101, 200 }) |length| {
        for ([_]bool{ false, true }) |multibyte| {
            var description: [@import("tool_presentation.zig").max_description_bytes]u8 = @splat('x');
            if (multibyte) {
                for (0..length / 2) |i| @memcpy(description[i * 2 ..][0..2], "é");
            }
            const text = description[0..length];
            const pending: Inputs.Actions = .{ .total = 1, .unresolved = 1 };
            try expectState(.{ .pending = .{ .since = 340 } }, .{
                .now_ms = 0,
                .created_at = 1,
                .latest = activeTurn(proposals(340), pending),
            });
            var running = pending;
            running.running = 1;
            running.oldest_running = .{ .at = 350, .call = 0, .description = text };
            const work = try derive(.{
                .now_ms = 0,
                .created_at = 1,
                .latest = activeTurn(proposals(340), running),
            });
            try std.testing.expect(work.state == .bash);
            try std.testing.expectEqualStrings(text, work.state.bash.description.?.slice());
            try std.testing.expectEqual(@as(u64, 350), work.state.bash.since);
            try std.testing.expectEqual(@as(?u64, 0), work.state.bash.call);
            try std.testing.expectEqual(@as(u64, 1), work.state.bash.running);
            try std.testing.expectEqual(@as(u64, 0), work.state.bash.approvals);
            const completed: Inputs.Actions = .{ .total = 1, .latest_resolution_at = 360 };
            try expectState(.{ .pending = .{ .since = 360 } }, .{
                .now_ms = 0,
                .created_at = 1,
                .latest = activeTurn(proposals(340), completed),
            });
        }
    }
}

test "Session approval target belongs to Session inputs through continuation terminal and decisions" {
    const continuation = activeTurn(.{ .in_flight = .{ .attempt_at = 300 } }, .{});
    const ended = endedTurn(.completed, "completed");
    const foreground = activeTurn(proposals(340), .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 52 });
    for ([_]Inputs.Turn{ continuation, ended, foreground }) |turn| {
        const state_only = try derive(.{ .created_at = 1, .now_ms = 0, .latest = turn });
        const background = try derive(.{ .created_at = 1, .now_ms = 0, .latest = turn, .first_action = 41 });
        try std.testing.expectEqual(@as(?u64, 41), background.first_action);
        try std.testing.expectEqual(state_only.state, background.state);
        try std.testing.expectEqual(@as(?u64, null), state_only.first_action);
    }
    const allowed = try derive(.{ .created_at = 1, .now_ms = 0, .latest = foreground, .first_action = 52 });
    try std.testing.expectEqual(@as(?u64, 52), allowed.first_action);
    const denied = try derive(.{ .created_at = 1, .now_ms = 0, .latest = ended, .first_action = null });
    try std.testing.expectEqual(@as(?u64, null), denied.first_action);
    var stopped = foreground;
    stopped.stopped_at = 400;
    const selected_stop = try derive(.{ .created_at = 1, .now_ms = 0, .latest = stopped, .first_action = null });
    try std.testing.expectEqual(@as(?u64, null), selected_stop.first_action);
    try std.testing.expect(selected_stop.state == .stopping);
    try std.testing.expectError(error.CorruptStore, derive(.{ .created_at = 1, .now_ms = 0, .first_action = 41 }));
}

test "attention and group match base client classification across work states" {
    // Expectations transcribed from attention.Attention.of and overview_view.orderClass
    // at 3e389620a3a6b83e314e02657c9e6a95e67488e8, with no viewer open stop.
    const Case = struct { state: WorkState, attention_kind: ?@FieldType(Attention, "kind"), group: Group };
    const cases = [_]Case{
        .{ .state = .{ .idle = .{ .since = 1 } }, .attention_kind = null, .group = .done },
        .{ .state = .{ .pending = .{ .since = 1 } }, .attention_kind = null, .group = .queued },
        .{ .state = .{ .working = .{ .since = 1 } }, .attention_kind = null, .group = .working },
        .{ .state = .{ .retrying = .{ .since = 1, .due_at_ms = 9999, .cause = try bounded(max_code_bytes, "retry"), .attempt = 1 } }, .attention_kind = null, .group = .working },
        .{ .state = .{ .bash = .{ .since = 1, .call = 1, .description = null, .running = 1, .approvals = 0 } }, .attention_kind = null, .group = .working },
        .{ .state = .{ .bash = .{ .since = 1, .call = 1, .description = null, .running = 1, .approvals = 1 } }, .attention_kind = .approval, .group = .needs_you },
        .{ .state = .{ .approval = .{ .since = 1 } }, .attention_kind = .approval, .group = .needs_you },
        .{ .state = .{ .stopping = .{ .since = 1 } }, .attention_kind = null, .group = .working },
        .{ .state = .{ .finished = .{ .since = 1 } }, .attention_kind = .finished, .group = .done },
        .{ .state = .{ .failed = .{ .since = 1, .code = try bounded(max_code_bytes, "failed"), .resets_at = null } }, .attention_kind = .failed, .group = .done },
        .{ .state = .{ .stopped = .{ .since = 1, .cause = .stop } }, .attention_kind = null, .group = .done },
    };
    for (cases) |case| for (0..8) |mask| {
        const work: Work = .{ .state = case.state, .turn = if (mask & 1 != 0) 7 else null, .operation = if (mask & 2 != 0) 19 else null, .first_action = if (mask & 4 != 0) 41 else null };
        try std.testing.expectEqual(case.group, group(work));
        const got = attention(work);
        if (case.attention_kind) |kind| {
            try std.testing.expect(got != null);
            try std.testing.expectEqual(kind, got.?.kind);
            try std.testing.expectEqual(work.turn orelse 0, got.?.turn);
            try std.testing.expectEqual(if (kind == .approval) work.first_action orelse 0 else std.math.maxInt(u64), got.?.step);
        } else try std.testing.expect(got == null);
    };
}

test "work loses whether a model operation is current" {
    const in_flight = try derive(.{ .now_ms = 0, .created_at = 1, .latest = activeTurn(.{ .in_flight = .{ .attempt_at = 500 } }, .{}) });
    const owed = try derive(.{ .now_ms = 0, .created_at = 1, .latest = endedTurn(.completed, "completed"), .owed_since = 500 });
    try std.testing.expectEqualDeep(in_flight.state, owed.state);
    try std.testing.expectEqual(in_flight.turn, owed.turn);
    try std.testing.expectEqual(in_flight.operation, owed.operation);
    try std.testing.expect(in_flight.actions.interrupt != null);
    try std.testing.expect(owed.actions.interrupt == null);
    try std.testing.expect(in_flight.actions.stop and owed.actions.stop);
}

test "actions derive from work inputs" {
    const pending = Inputs.Pending{ .at = 600, .position = 60 };
    for (0..64) |mask| {
        const queued: ?Inputs.Pending = if (mask & 1 != 0) pending else null;
        const owed: ?u64 = if (mask & 2 != 0) 600 else null;
        const decision: ?u64 = if (mask & 4 != 0) 41 else null;
        const turns = [_]?Inputs.Turn{
            null,
            activeTurn(.{ .in_flight = .{ .attempt_at = 300 } }, .{}),
            activeTurn(.{ .waiting = .{ .scheduled_at = 300, .due_at_ms = 5000, .cause = "retry", .attempt = 1 } }, .{}),
            activeTurn(.{ .resolved = .{ .resolution = .answer, .at = 300 } }, .{}),
            endedTurn(.completed, "completed"),
            endedTurn(.failed, "failed"),
            endedTurn(.cancelled, "cancelled"),
        };
        for (turns, 0..) |initial, index| {
            var turn = initial;
            if (turn) |*t| {
                if (mask & 8 != 0) t.stopped_at = 450;
                if (mask & 16 != 0) t.interruptible = false;
                t.stop_remaining = mask & 32 != 0;
            }
            // first_action requires a latest Turn, even when it refers to an older Action.
            if (turn == null and decision != null) continue;
            const work = try derive(.{ .now_ms = 0, .created_at = 1, .latest = turn, .oldest_pending = queued, .owed_since = owed, .first_action = decision });
            try std.testing.expectEqual((index >= 1 and index <= 3 and mask & 8 == 0) or queued != null or owed != null or (turn != null and mask & 32 != 0), work.actions.stop);
            try std.testing.expectEqual(index == 1 and mask & 8 == 0 and mask & 16 == 0, work.actions.interrupt != null);
            if (work.actions.interrupt) |target| {
                try std.testing.expectEqual(@as(u64, 7), target.turn);
                try std.testing.expectEqual(@as(u64, 19), target.operation);
            }
            try std.testing.expectEqual(decision, work.actions.decide);
        }
    }
}

test "actions cover proposal and stopping combinations" {
    for (0..16) |mask| {
        const queued: ?Inputs.Pending = if (mask & 1 != 0) .{ .at = 600, .position = 60 } else null;
        const decision: ?u64 = if (mask & 2 != 0) 41 else null;
        const stopped = mask & 4 != 0;
        const owed: ?u64 = if (mask & 8 != 0) 600 else null;
        const action_sets = [_]Inputs.Actions{
            .{},
            .{ .total = 1, .unresolved = 1, .awaiting = 1, .first_awaiting = 41 },
            .{ .total = 1, .unresolved = 1, .running = 1, .oldest_running = .{ .at = 400, .call = 1, .description = null } },
            .{ .total = 2, .unresolved = 2, .awaiting = 1, .first_awaiting = 41, .running = 1, .oldest_running = .{ .at = 400, .call = 1, .description = null } },
        };
        for (action_sets) |set| {
            var turn = activeTurn(proposals(340), set);
            if (stopped) turn.stopped_at = 500;
            const work = try derive(.{ .created_at = 1, .now_ms = 0, .latest = turn, .oldest_pending = queued, .owed_since = owed, .first_action = decision });
            try std.testing.expectEqual(!stopped or queued != null or owed != null, work.actions.stop);
            try std.testing.expect(work.actions.interrupt == null);
            try std.testing.expectEqual(decision, work.actions.decide);
        }
    }
}

test "in-flight compaction remains working with its purpose" {
    var latest = activeTurn(.{ .in_flight = .{ .attempt_at = 123 } }, .{});
    const normal = try derive(.{ .now_ms = 124000, .created_at = 1, .latest = latest });
    try std.testing.expect(!normal.state.working.compaction);
    latest.compaction = true;
    const compacting = try derive(.{ .now_ms = 124000, .created_at = 1, .latest = latest });
    try std.testing.expect(compacting.state.working.compaction);
    try std.testing.expectEqual(WorkState.Progress.in_flight, compacting.state.progress().?);
}
