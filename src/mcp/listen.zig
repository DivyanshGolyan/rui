//! The pure core of one server's `subscriptions/listen` stream: whether it is
//! open, when it may reopen, and whether the shell must list the server again
//! after each event. It reads no wire and no clock; the shell passes `now_ms`
//! and `seed`, holds a stream only while `holdsStream` is true, and wakes the
//! line at `wakeAt`.

const std = @import("std");
const relist = @import("relist.zig");

pub const State = enum { closed, opening, open, unsupported };

/// A stream that stayed acknowledged this long restarts reconnect backoff at its first step.
pub const stable_ms: u64 = 60_000;

/// An opening stream not acknowledged this long after `begin` times out and backs off.
pub const ack_deadline_ms: u64 = 10_000;

const method_not_found: i64 = -32601;

/// What the stream reader saw, in domain terms. A subscription id of null means the notice named none.
pub const Event = union(enum) {
    /// The ack; `tools` is whether its filter kept `toolsListChanged`.
    acknowledged: struct { subscription: ?u64, tools: bool },
    /// `notifications/tools/list_changed`.
    tools_changed: ?u64,
    /// Any other notification on the stream.
    ignored,
    /// The completion result that ends the stream gracefully.
    ended: ?u64,
    /// The stream was refused: an HTTP error status, or a JSON-RPC error answering the listen request.
    refused: Refusal,
    /// The transport closed or failed, an event was over-long or malformed, or the open failed.
    dropped,
    /// The shell reached `wakeAt` while opening: no acknowledgment came by the ack deadline.
    timed_out,
};

pub const Refusal = struct { status: ?u16, rpc_code: ?i64 };

pub const Line = struct {
    state: State = .closed,
    /// JSON-RPC id of the current (or most recent) subscribe request, which is also its subscriptionId.
    /// Bumped by `begin`.
    opens: u64 = 0,
    /// Consecutive streams that ended before being stable.
    failures: u32 = 0,
    /// Closed only: earliest reopen.
    retry_at_ms: u64 = 0,
    /// Opening only: when the subscribe request times out without an acknowledgment.
    ack_due_ms: u64 = 0,
    /// Set when the stream is acknowledged; read to decide whether a drop counts as stable.
    acked_at_ms: u64 = 0,

    /// True when a closed line may open now.
    pub fn due(self: *const Line, now_ms: u64) bool {
        return self.state == .closed and now_ms >= self.retry_at_ms;
    }

    /// Closed -> opening. Returns the JSON-RPC id the subscribe request must carry. Precondition: closed.
    pub fn begin(self: *Line, now_ms: u64) u64 {
        std.debug.assert(self.state == .closed);
        self.state = .opening;
        self.opens += 1;
        self.ack_due_ms = now_ms +| ack_deadline_ms;
        return self.opens;
    }

    /// True while the shell holds a stream: opening or open. The shell closes its stream whenever this is false.
    pub fn holdsStream(self: *const Line) bool {
        return self.state == .opening or self.state == .open;
    }

    /// Applies one event to a line that holds a stream and returns whether the shell must list the server
    /// again. Events for a closed or unsupported line are a shell bug: the shell holds no stream then.
    pub fn step(self: *Line, event: Event, now_ms: u64, seed: u64) bool {
        std.debug.assert(self.holdsStream());
        switch (event) {
            .ignored => return false,
            .acknowledged => |ack| {
                // Every later ack is ignored, whatever its subscription. An ack naming another
                // subscription while opening is a failed open.
                if (self.state == .open) return false;
                if (foreign(ack.subscription, self.opens)) {
                    self.backoff(now_ms, seed);
                    return false;
                }
                if (!ack.tools) {
                    self.state = .unsupported;
                    return false;
                }
                // Every ack asks: a reconnect may have missed changes, and the first ack closes the
                // gap between startup's list and the subscription.
                self.state = .open;
                self.acked_at_ms = now_ms;
                return true;
            },
            .tools_changed => |subscription| return self.state == .open and !foreign(subscription, self.opens),
            .refused => |refusal| {
                if (self.state == .opening and unsupportedRefusal(refusal)) {
                    self.state = .unsupported;
                    return false;
                }
                self.backoff(now_ms, seed);
                return false;
            },
            .ended => |subscription| {
                if (foreign(subscription, self.opens)) return false;
                self.backoff(now_ms, seed);
                return false;
            },
            .dropped => {
                self.backoff(now_ms, seed);
                return false;
            },
            .timed_out => {
                if (self.state == .opening) self.backoff(now_ms, seed);
                return false;
            },
        }
    }

    /// Unsupported -> closed with no failures, due at once. Every other state is unchanged, so it is idempotent.
    pub fn reprobe(self: *Line) void {
        if (self.state != .unsupported) return;
        self.state = .closed;
        self.failures = 0;
        self.retry_at_ms = 0;
    }

    /// When the shell next steps this line without an event: a closed line's reopen time, an opening
    /// line's ack deadline. Null for open and unsupported lines, whose streams are read as they come.
    pub fn wakeAt(self: *const Line) ?u64 {
        return switch (self.state) {
            .closed => self.retry_at_ms,
            .opening => self.ack_due_ms,
            .open, .unsupported => null,
        };
    }

    fn backoff(self: *Line, now_ms: u64, seed: u64) void {
        const stable = self.state == .open and now_ms -| self.acked_at_ms >= stable_ms;
        self.failures = if (stable) 1 else self.failures +| 1;
        self.retry_at_ms = now_ms +| relist.jittered(relist.retryDelay(self.failures), seed);
        self.state = .closed;
    }
};

/// A notice that names a subscription other than the current one. An unnamed notice counts as the stream's own.
fn foreign(named: ?u64, opens: u64) bool {
    const found = named orelse return false;
    return found != opens;
}

/// A refusal that says the server does not offer subscriptions at all.
fn unsupportedRefusal(refusal: Refusal) bool {
    if (refusal.rpc_code == method_not_found) return true;
    const status = refusal.status orelse return false;
    return status == 404 or status == 405 or status == 501;
}

const all_states = [_]State{ .closed, .opening, .open, .unsupported };

/// The states that hold a stream, in table order.
const holding_states = [_]State{ .opening, .open };

/// Every event the table covers, with the subscription id it carries, as a reader would parse it.
const events = [_]Event{
    .{ .acknowledged = .{ .subscription = 1, .tools = true } }, // 0
    .{ .acknowledged = .{ .subscription = 1, .tools = false } }, // 1
    .{ .acknowledged = .{ .subscription = null, .tools = true } }, // 2
    .{ .acknowledged = .{ .subscription = 9, .tools = true } }, // 3 foreign
    .{ .tools_changed = 1 }, // 4
    .{ .tools_changed = null }, // 5
    .{ .tools_changed = 9 }, // 6 foreign
    .ignored, // 7
    .{ .ended = 1 }, // 8
    .{ .ended = 9 }, // 9 foreign
    .{ .refused = .{ .status = 404, .rpc_code = null } }, // 10
    .{ .refused = .{ .status = 405, .rpc_code = null } }, // 11
    .{ .refused = .{ .status = 501, .rpc_code = null } }, // 12
    .{ .refused = .{ .status = null, .rpc_code = -32601 } }, // 13
    .{ .refused = .{ .status = 401, .rpc_code = null } }, // 14
    .{ .refused = .{ .status = 503, .rpc_code = null } }, // 15
    .{ .refused = .{ .status = null, .rpc_code = -32000 } }, // 16
    .dropped, // 17
    .timed_out, // 18
};

/// What a step from one holding state does to a line whose subscribe request was id 1.
const Row = struct { state: State, ask: bool = false, backoff: bool = false };

/// Hand-written from the rules in the catalog, one row per holding state, one column per event above.
const table = [_][events.len]Row{
    // opening: an ack with the filter opens; an ack without it, or a 404/405/501/-32601 refusal, is unsupported;
    // a foreign ack, an own ended or refused, a drop and a timeout back off; other foreign or unnamed-but-foreign notices are ignored.
    .{
        .{ .state = .open, .ask = true },
        .{ .state = .unsupported },
        .{ .state = .open, .ask = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .closed, .backoff = true },
        .{ .state = .opening },
        .{ .state = .unsupported },
        .{ .state = .unsupported },
        .{ .state = .unsupported },
        .{ .state = .unsupported },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
    },
    // open: every ack is ignored; list_changed asks unless foreign; a refusal of any kind, a drop and an own
    // ended back off; a timeout is ignored.
    .{
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open, .ask = true },
        .{ .state = .open, .ask = true },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .closed, .backoff = true },
        .{ .state = .open },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .closed, .backoff = true },
        .{ .state = .open },
    },
};

fn lineIn(state: State) Line {
    return switch (state) {
        .closed => .{ .state = .closed, .opens = 1 },
        .opening => .{ .state = .opening, .opens = 1 },
        .open => .{ .state = .open, .opens = 1, .acked_at_ms = 0 },
        .unsupported => .{ .state = .unsupported, .opens = 1 },
    };
}

fn expectBackoff(line: *const Line, now_ms: u64, failures: u32) !void {
    try std.testing.expectEqual(failures, line.failures);
    const base = @min(@as(u64, 1_000) << @intCast(failures - 1), 300_000);
    const spread = @min(base / 10, 30_000);
    try std.testing.expect(line.retry_at_ms >= now_ms + base);
    try std.testing.expect(line.retry_at_ms <= now_ms + base + spread);
}

test "EXR-71 a listen stream moves through every holding state x event as its rules say" {
    const now: u64 = 1_000;
    for (holding_states, 0..) |state, row| {
        for (events, 0..) |event, column| {
            var line = lineIn(state);
            const want = table[row][column];
            const ask = line.step(event, now, 7);
            errdefer std.debug.print("state {s} event {d}\n", .{ @tagName(state), column });
            try std.testing.expectEqual(want.state, line.state);
            try std.testing.expectEqual(want.ask, ask);
            if (want.backoff) try expectBackoff(&line, now, 1) else {
                try std.testing.expectEqual(@as(u32, 0), line.failures);
            }
        }
    }
}

test "EXR-72 a reconnect is delayed by backoff with jitter, never zero, and a stable stream restarts at one second" {
    var seed: u64 = 0x9E37;
    var line: Line = .{};
    var now: u64 = 0;
    var failures: u32 = 0;
    for (0..40) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        _ = line.begin(now);
        // Each drop is a refused stream attempt, so failures count up and the delay doubles to its cap.
        _ = line.step(.dropped, now, seed);
        failures += 1;
        const base = @min(@as(u64, 1_000) << @intCast(@min(failures, 32) - 1), 300_000);
        const delay = line.retry_at_ms - now;
        try std.testing.expect(delay > 0);
        try std.testing.expect(delay >= base);
        try std.testing.expect(delay <= base + @min(base / 10, 30_000));
        try std.testing.expectEqual(failures, line.failures);
        now = line.retry_at_ms;
    }

    // A stream acked for a full stable_ms before it drops restarts at its first step.
    var acked: Line = .{ .state = .open, .opens = 3, .failures = 9, .acked_at_ms = 0 };
    _ = acked.step(.dropped, stable_ms, 5);
    try expectBackoff(&acked, stable_ms, 1);

    // Just short of stable_ms it counts as a failure.
    var unstable: Line = .{ .state = .open, .opens = 3, .failures = 9, .acked_at_ms = 0 };
    _ = unstable.step(.dropped, stable_ms - 1, 5);
    try std.testing.expectEqual(@as(u32, 10), unstable.failures);
}

test "EXR-73 an unsupported listen stream stays off until reprobe, then may open again" {
    var line: Line = .{ .state = .unsupported, .opens = 4, .failures = 6, .retry_at_ms = 77 };
    for ([_]u64{ 0, 77, std.math.maxInt(u64) }) |now| {
        try std.testing.expect(!line.due(now));
        try std.testing.expectEqual(@as(?u64, null), line.wakeAt());
    }
    try std.testing.expect(!line.holdsStream());

    line.reprobe();
    try std.testing.expectEqual(State.closed, line.state);
    try std.testing.expectEqual(@as(u32, 0), line.failures);
    try std.testing.expect(line.due(0));
    try std.testing.expectEqual(@as(?u64, 0), line.wakeAt());

    // reprobe is idempotent from every state: nothing else moves.
    for (all_states) |state| {
        var other = lineIn(state);
        other.failures = 3;
        other.retry_at_ms = 500;
        const before = other;
        other.reprobe();
        if (state != .unsupported) try std.testing.expectEqualDeep(before, other);
        const once = other;
        other.reprobe();
        try std.testing.expectEqualDeep(once, other);
    }
}

test "EXR-74 a closed line's wakeAt is its reopen time, and it is due only then" {
    var line: Line = .{};
    try std.testing.expectEqual(@as(?u64, 0), line.wakeAt());
    try std.testing.expect(line.due(0));
    _ = line.begin(0);
    try std.testing.expect(!line.due(std.math.maxInt(u64)));
    _ = line.step(.dropped, 1_000, 2);
    const at = line.retry_at_ms;
    try std.testing.expectEqual(@as(?u64, at), line.wakeAt());
    try std.testing.expect(!line.due(at - 1));
    try std.testing.expect(line.due(at));
}

test "EXR-75 a notice naming another subscription on an open stream changes nothing, and an unnamed one counts" {
    var line: Line = .{ .state = .open, .opens = 2, .acked_at_ms = 0 };
    try std.testing.expectEqual(false, line.step(.{ .tools_changed = 1 }, 5, 1));
    try std.testing.expectEqual(false, line.step(.{ .ended = 1 }, 5, 1));
    try std.testing.expectEqual(State.open, line.state);
    try std.testing.expectEqual(true, line.step(.{ .tools_changed = null }, 5, 1));
    try std.testing.expectEqual(true, line.step(.{ .tools_changed = 2 }, 5, 1));
}

test "EXR-79 every backoff cell counts one failure or restarts at one, and its retry lies within the jitter bounds" {
    const cells = [_]struct { event: Event, opening: bool }{
        .{ .event = .dropped, .opening = true },
        .{ .event = .{ .ended = 1 }, .opening = true },
        .{ .event = .{ .refused = .{ .status = 401, .rpc_code = null } }, .opening = true },
        .{ .event = .{ .refused = .{ .status = 503, .rpc_code = null } }, .opening = true },
        .{ .event = .{ .refused = .{ .status = null, .rpc_code = -32000 } }, .opening = true },
        .{ .event = .timed_out, .opening = true },
        .{ .event = .{ .acknowledged = .{ .subscription = 9, .tools = true } }, .opening = true },
        .{ .event = .dropped, .opening = false },
        .{ .event = .{ .ended = 1 }, .opening = false },
        .{ .event = .{ .refused = .{ .status = 401, .rpc_code = null } }, .opening = false },
        .{ .event = .{ .refused = .{ .status = 503, .rpc_code = null } }, .opening = false },
        .{ .event = .{ .refused = .{ .status = null, .rpc_code = -32000 } }, .opening = false },
    };
    // Each start: an opening line, an open line unstable at this step, and an open line stable at this step.
    const starts = [_]struct { state: State, acked_at_ms: u64, at_ms: u64 }{
        .{ .state = .opening, .acked_at_ms = 0, .at_ms = 1_000 },
        .{ .state = .open, .acked_at_ms = 0, .at_ms = stable_ms - 1 },
        .{ .state = .open, .acked_at_ms = 0, .at_ms = stable_ms },
    };
    for (cells) |cell| for (starts, 0..) |start, index| {
        // Only an opening line can see an opening-only cell; a stable open line counts as one failure reset.
        if (cell.opening and start.state == .open) continue;
        if (!cell.opening and start.state == .opening) continue;
        for ([_]u32{ 0, 3 }) |before| {
            var line: Line = .{ .state = start.state, .opens = 1, .acked_at_ms = start.acked_at_ms, .failures = before };
            const stable = start.state == .open and start.at_ms -| start.acked_at_ms >= stable_ms;
            errdefer std.debug.print("cell {s} start {d} failures {d}\n", .{ @tagName(cell.event), index, before });
            try std.testing.expect(!line.step(cell.event, start.at_ms, 11));
            try std.testing.expectEqual(State.closed, line.state);
            const want: u32 = if (stable) 1 else before + 1;
            try expectBackoff(&line, start.at_ms, want);
        }
    };
}

test "EXR-80 an opening line times out at its ack deadline and backs off, and wakeAt reports that deadline" {
    var line: Line = .{};
    _ = line.begin(1_000);
    try std.testing.expectEqual(@as(?u64, 1_000 + ack_deadline_ms), line.wakeAt());
    try std.testing.expect(!line.due(1_000 + ack_deadline_ms));

    // The shell calls step(.timed_out) at the deadline; an unacknowledged line backs off like a drop.
    try std.testing.expect(!line.step(.timed_out, 1_000 + ack_deadline_ms, 3));
    try std.testing.expectEqual(State.closed, line.state);
    try expectBackoff(&line, 1_000 + ack_deadline_ms, 1);
    try std.testing.expectEqual(@as(?u64, line.retry_at_ms), line.wakeAt());

    // An ack inside the deadline opens the line, and its wake time is then none.
    var acked: Line = .{};
    _ = acked.begin(0);
    try std.testing.expect(acked.step(.{ .acknowledged = .{ .subscription = 1, .tools = true } }, ack_deadline_ms - 1, 3));
    try std.testing.expectEqual(@as(?u64, null), acked.wakeAt());
}

test "EXR-81 a listen line holds its stream exactly while it is opening or open" {
    const holds = [_]bool{ false, true, true, false };
    for (all_states, holds) |state, want| {
        const line = lineIn(state);
        try std.testing.expectEqual(want, line.holdsStream());
    }
}
