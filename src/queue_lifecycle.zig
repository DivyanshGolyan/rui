const std = @import("std");

pub const Key = [36]u8;
pub const Queue = struct { count: u64, oldest: u64, newest: u64, position: u64, line_matches: bool };
pub const Phase = enum { local, represented, terminal };
pub const Message = struct {
    key: Key,
    before_newest: ?u64,
    admission: ?u64 = null,
    position: ?u64 = null,
    phase: Phase = .local,
};
pub const State = struct { message: ?Message = null };
pub const Event = union(enum) {
    begin: struct { key: Key, before: ?Queue },
    reserved: struct { before: Key, key: Key },
    receipt: struct { key: Key, admission: ?u64 },
    pending: struct { key: Key, position: u64, page_all: bool, adopted: bool, queue: ?Queue = null },
    applied: Key,
    excluded: Key,
    discard: Key,
};
pub const Transition = struct { state: State, matched: bool = false, await_adoption: bool = false, accounted: bool = false, stopped: bool = false };

fn same(a: Key, b: Key) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn step(previous: State, event: Event) Transition {
    var result: Transition = .{ .state = previous };
    if (event == .begin) {
        result.state.message = .{ .key = event.begin.key, .before_newest = if (event.begin.before) |queue| queue.newest else null };
        return result;
    }
    const message = if (result.state.message) |*value| value else return result;
    switch (event) {
        .begin => unreachable,
        .reserved => |value| if (same(message.key, value.before) and message.phase == .local) {
            message.key = value.key;
        },
        .discard => |key| if (same(message.key, key) and message.phase != .terminal) {
            result.matched = true;
            result.state.message = null;
        },
        .receipt => |value| if (same(message.key, value.key)) {
            result.matched = true;
            message.admission = value.admission;
        },
        .pending => |value| if (same(message.key, value.key) and message.phase != .terminal) {
            result.matched = true;
            message.position = value.position;
            result.await_adoption = value.page_all and !value.adopted;
            const represented = if (value.queue) |queue| value.page_all and value.adopted and queue.count != 0 and queue.line_matches and
                value.position >= queue.oldest and value.position <= queue.position else false;
            if (represented and message.phase == .local) {
                message.phase = .represented;
                result.accounted = true;
            }
        },
        .applied, .excluded => |key| if (same(message.key, key)) {
            result.matched = true;
            if (message.phase == .local) result.accounted = true;
            if (event == .excluded and message.phase != .terminal) result.stopped = true;
            message.phase = .terminal;
        },
    }
    return result;
}

pub const Durable = union(enum) { none, line, summary: u64 };
pub const Presentation = struct { durable: Durable, local: bool, held: bool };

/// Queue facts are the current caller-owned snapshot; this value retains no Host roster.
pub fn view(state: State, queue: ?Queue, has_ticket: bool, at_latest: bool) Presentation {
    const message = state.message;
    const held = has_ticket and message != null and message.?.phase == .local;
    var result: Presentation = .{ .durable = .none, .local = held and at_latest, .held = held };
    const current = queue orelse return result;
    if (current.count == 0) return result;
    if (!current.line_matches) return result;
    if (!result.local) {
        result.durable = .line;
        return result;
    }
    const local = message.?;
    const identical = (local.admission != null and local.admission.? == current.newest) or
        (local.position != null and local.position.? == current.position);
    if (identical) {
        result.local = false;
        result.durable = .line;
    } else if (local.before_newest == current.newest or (local.admission != null and local.admission.? != current.newest)) {
        result.durable = .line;
    } else {
        result.durable = .{ .summary = current.count };
    }
    return result;
}

pub fn accounted(state: State, key: Key) bool {
    const message = state.message orelse return false;
    return same(message.key, key) and message.phase != .local;
}

pub fn lastKey(state: State) ?Key {
    return if (state.message) |message| message.key else null;
}

test "SUI-161 local queue lifecycle accounts only matching represented identities" {
    const a: Key = @splat('A');
    const b: Key = @splat('B');
    const old: Queue = .{ .count = 1, .oldest = 10, .newest = 3, .position = 10, .line_matches = true };
    const own: Queue = .{ .count = 2, .oldest = 10, .newest = 7, .position = 20, .line_matches = true };
    for ([_]bool{ false, true }) |receipt_first| {
        var state = step(.{}, .{ .begin = .{ .key = a, .before = old } }).state;
        try std.testing.expect(view(state, old, true, true).local);
        try std.testing.expect(view(state, old, true, true).durable == .line);
        const unknown = view(state, own, true, true);
        try std.testing.expect(unknown.local);
        try std.testing.expectEqual(@as(u64, 2), unknown.durable.summary);
        if (receipt_first) state = step(state, .{ .receipt = .{ .key = a, .admission = 7 } }).state;
        var result = step(state, .{ .pending = .{ .key = b, .position = 20, .page_all = true, .adopted = true, .queue = own } });
        try std.testing.expect(!result.accounted);
        result = step(result.state, .{ .pending = .{ .key = a, .position = 20, .page_all = true, .adopted = false, .queue = own } });
        try std.testing.expect(!result.accounted);
        try std.testing.expect(!view(result.state, own, true, true).local);
        result = step(result.state, .{ .pending = .{ .key = a, .position = 20, .page_all = true, .adopted = true, .queue = own } });
        try std.testing.expect(result.accounted and accounted(result.state, a));
        result = step(result.state, .{ .pending = .{ .key = a, .position = 20, .page_all = true, .adopted = true, .queue = own } });
        try std.testing.expect(!result.accounted);
        if (!receipt_first) result = step(result.state, .{ .receipt = .{ .key = a, .admission = 7 } });
        result = step(result.state, .{ .applied = a });
        try std.testing.expect(!result.accounted and !result.stopped);
        const applied = view(result.state, null, false, true);
        try std.testing.expect(!applied.local and !applied.held);
        result = step(result.state, .{ .pending = .{ .key = a, .position = 20, .page_all = true, .adopted = true, .queue = own } });
        try std.testing.expect(!result.accounted and result.state.message.?.phase == .terminal);
        const next = step(result.state, .{ .begin = .{ .key = b, .before = own } }).state;
        const beside = view(next, own, true, true);
        try std.testing.expect(beside.local);
        try std.testing.expect(beside.durable == .line);
    }
    const pending_cases = [_]struct { page_all: bool, adopted: bool, count: u64, line: bool, position: u64, accounted: bool }{
        .{ .page_all = false, .adopted = true, .count = 2, .line = true, .position = 10, .accounted = false },
        .{ .page_all = true, .adopted = false, .count = 2, .line = true, .position = 10, .accounted = false },
        .{ .page_all = true, .adopted = true, .count = 0, .line = true, .position = 10, .accounted = false },
        .{ .page_all = true, .adopted = true, .count = 2, .line = false, .position = 10, .accounted = false },
        .{ .page_all = true, .adopted = true, .count = 2, .line = true, .position = 9, .accounted = false },
        .{ .page_all = true, .adopted = true, .count = 2, .line = true, .position = 10, .accounted = true },
        .{ .page_all = true, .adopted = true, .count = 2, .line = true, .position = 15, .accounted = true },
        .{ .page_all = true, .adopted = true, .count = 2, .line = true, .position = 20, .accounted = true },
        .{ .page_all = true, .adopted = true, .count = 2, .line = true, .position = 21, .accounted = false },
    };
    for (pending_cases) |case| {
        const before = step(.{}, .{ .begin = .{ .key = a, .before = null } }).state;
        const queue: Queue = .{ .count = case.count, .oldest = 10, .newest = 7, .position = 20, .line_matches = case.line };
        const result = step(before, .{ .pending = .{ .key = a, .position = case.position, .page_all = case.page_all, .adopted = case.adopted, .queue = queue } });
        try std.testing.expectEqual(case.accounted, result.accounted);
        try std.testing.expectEqual(case.accounted, accounted(result.state, a));
        const frame = view(result.state, queue, true, true);
        if (!case.line or case.count == 0) try std.testing.expect(frame.local and frame.durable == .none);
        if (case.accounted) try std.testing.expect(!frame.local and frame.durable == .line);
    }
    for ([_]bool{ false, true }) |at_latest| for ([_]bool{ false, true }) |has_ticket| {
        const state = step(.{}, .{ .begin = .{ .key = a, .before = old } }).state;
        const shown = view(state, old, has_ticket, at_latest);
        try std.testing.expectEqual(has_ticket and at_latest, shown.local);
        try std.testing.expectEqual(has_ticket, shown.held);
        try std.testing.expect(shown.durable == .line);
    };
    {
        var state = step(.{}, .{ .begin = .{ .key = a, .before = old } }).state;
        const wrong = step(state, .{ .receipt = .{ .key = b, .admission = 7 } });
        try std.testing.expect(!wrong.matched and wrong.state.message.?.admission == null);
        state = step(wrong.state, .{ .receipt = .{ .key = a, .admission = 7 } }).state;
        const unrelated = step(state, .{ .discard = b });
        try std.testing.expect(!unrelated.matched and unrelated.state.message != null);
        const discarded = step(unrelated.state, .{ .discard = a });
        try std.testing.expect(discarded.matched and discarded.state.message == null);
        try std.testing.expect(!view(discarded.state, old, false, true).local);
    }
    var first = step(.{}, .{ .begin = .{ .key = a, .before = null } }).state;
    try std.testing.expect(!view(first, null, true, false).local);
    var stopped = step(first, .{ .excluded = a });
    try std.testing.expect(stopped.accounted and stopped.stopped);
    stopped = step(stopped.state, .{ .excluded = a });
    try std.testing.expect(!stopped.accounted and !stopped.stopped);
    first = stopped.state;
    try std.testing.expect(!view(first, null, true, true).local);
}
