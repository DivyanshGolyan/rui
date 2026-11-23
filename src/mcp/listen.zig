//! The pure core of one server's `subscriptions/listen` stream: whether it is
//! open, when it may reopen, and what the shell must do after each event. It
//! reads no wire and no clock; the shell passes `now_ms` and `seed` and applies
//! the returned `Effect`.

const std = @import("std");
const relist = @import("relist.zig");

pub const State = enum { closed, opening, open, unsupported };

/// A stream that stayed acknowledged this long restarts reconnect backoff at its first step.
pub const stable_ms: u64 = 60_000;

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
};

pub const Refusal = struct { status: ?u16, rpc_code: ?i64 };

/// What the shell does after a step. `ask`: list this server again. `close`: free the stream cell.
/// Opening is not an effect: the shell opens a closed line once `due` (see `Line.begin`).
pub const Effect = struct { ask: bool = false, close: bool = false };

pub const Line = struct {
    state: State = .closed,
    /// JSON-RPC id of the current (or most recent) subscribe request, which is also its subscriptionId.
    /// Bumped by `begin`.
    opens: u64 = 0,
    /// Consecutive streams that ended before being stable.
    failures: u32 = 0,
    /// Closed only: earliest reopen.
    retry_at_ms: u64 = 0,
    /// Set when the stream is acknowledged; read to decide whether a drop counts as stable.
    acked_at_ms: u64 = 0,

    /// True when a closed line may open now.
    pub fn due(self: *const Line, now_ms: u64) bool {
        return self.state == .closed and now_ms >= self.retry_at_ms;
    }

    /// Closed -> opening. Returns the JSON-RPC id the subscribe request must carry. Precondition: closed.
    pub fn begin(self: *Line) u64 {
        std.debug.assert(self.state == .closed);
        self.state = .opening;
        self.opens += 1;
        return self.opens;
    }

    /// Applies one event. Notices naming another subscription are ignored. Events in
    /// closed or unsupported lines are ignored too; the shell holds no cell then.
    pub fn step(self: *Line, event: Event, now_ms: u64, seed: u64) Effect {
        if (self.state == .closed or self.state == .unsupported) return .{};
        if (foreign(event, self.opens)) return .{};
        switch (event) {
            .ignored => return .{},
            .acknowledged => |ack| {
                if (self.state != .opening) return .{};
                if (!ack.tools) {
                    self.state = .unsupported;
                    return .{ .close = true };
                }
                // Every ack asks: a reconnect may have missed changes, and the first ack closes the
                // gap between startup's list and the subscription.
                self.state = .open;
                self.acked_at_ms = now_ms;
                return .{ .ask = true };
            },
            .tools_changed => return if (self.state == .open) .{ .ask = true } else .{},
            .refused => |refusal| {
                if (self.state == .opening and unsupportedRefusal(refusal)) {
                    self.state = .unsupported;
                    return .{ .close = true };
                }
                return self.backoff(now_ms, seed);
            },
            .ended, .dropped => return self.backoff(now_ms, seed),
        }
    }

    /// Unsupported -> closed with no failures, due at once. Every other state is unchanged, so it is idempotent.
    pub fn reprobe(self: *Line) void {
        if (self.state != .unsupported) return;
        self.state = .closed;
        self.failures = 0;
        self.retry_at_ms = 0;
    }

    /// The reopen time of a closed line; null in every other state (open streams are read every pass).
    pub fn wakeAt(self: *const Line) ?u64 {
        return if (self.state == .closed) self.retry_at_ms else null;
    }

    fn backoff(self: *Line, now_ms: u64, seed: u64) Effect {
        const stable = self.state == .open and now_ms -| self.acked_at_ms >= stable_ms;
        self.failures = if (stable) 1 else self.failures +| 1;
        self.retry_at_ms = now_ms +| relist.jittered(relist.retryDelay(self.failures), seed);
        self.state = .closed;
        return .{ .close = true };
    }
};

/// A notice that names a subscription other than the current one.
fn foreign(event: Event, opens: u64) bool {
    const named: ?u64 = switch (event) {
        .acknowledged => |ack| ack.subscription,
        .tools_changed => |subscription| subscription,
        .ended => |subscription| subscription,
        else => null,
    };
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
};

/// What a step from one state does to a line whose subscribe request was id 1.
const Row = struct { state: State, ask: bool = false, close: bool = false, backoff: bool = false };

/// Hand-written from the rules in the catalog, one row per state, one column per event above.
const table = [_][events.len]Row{
    // closed: nothing reaches a cell, so every event is ignored.
    @splat(Row{ .state = .closed }),
    // opening: an ack with the filter opens; an ack without it, or a 404/405/501/-32601 refusal, is unsupported;
    // a foreign or unnamed-but-foreign notice is ignored; the rest back off.
    .{
        .{ .state = .open, .ask = true },
        .{ .state = .unsupported, .close = true },
        .{ .state = .open, .ask = true },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .opening },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .opening },
        .{ .state = .unsupported, .close = true },
        .{ .state = .unsupported, .close = true },
        .{ .state = .unsupported, .close = true },
        .{ .state = .unsupported, .close = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
    },
    // open: every ack after the first is ignored; list_changed asks; a refusal of any kind backs off.
    .{
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .open, .ask = true },
        .{ .state = .open, .ask = true },
        .{ .state = .open },
        .{ .state = .open },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .open },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
        .{ .state = .closed, .close = true, .backoff = true },
    },
    // unsupported: stays until reprobe.
    @splat(Row{ .state = .unsupported }),
};

fn lineIn(state: State) Line {
    return switch (state) {
        .closed => .{ .state = .closed, .opens = 1 },
        .opening => .{ .state = .opening, .opens = 1 },
        .open => .{ .state = .open, .opens = 1, .acked_at_ms = 0 },
        .unsupported => .{ .state = .unsupported, .opens = 1 },
    };
}

fn expectBackoff(line: *const Line, now_ms: u64, failures: u32, seed: u64) !void {
    try std.testing.expectEqual(failures, line.failures);
    const base = @min(@as(u64, 1_000) << @intCast(failures - 1), 300_000);
    const spread = @min(base / 10, 30_000);
    try std.testing.expect(line.retry_at_ms >= now_ms + base);
    try std.testing.expect(line.retry_at_ms <= now_ms + base + spread);
    _ = seed;
}

test "EXR-71 a listen stream moves through every state x event as its rules say" {
    const now: u64 = 1_000;
    for (all_states, 0..) |state, row| {
        for (events, 0..) |event, column| {
            var line = lineIn(state);
            const want = table[row][column];
            const effect = line.step(event, now, 7);
            errdefer std.debug.print("state {s} event {d}\n", .{ @tagName(state), column });
            try std.testing.expectEqual(want.state, line.state);
            try std.testing.expectEqual(want.ask, effect.ask);
            try std.testing.expectEqual(want.close, effect.close);
            if (want.backoff) try expectBackoff(&line, now, 1, 7) else {
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
        _ = line.begin();
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
    try std.testing.expectEqual(@as(u32, 1), acked.failures);
    try expectBackoff(&acked, stable_ms, 1, 5);

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
    _ = line.step(.{ .acknowledged = .{ .subscription = 5, .tools = true } }, 10, 1);
    try std.testing.expectEqual(State.unsupported, line.state);

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
    _ = line.begin();
    try std.testing.expectEqual(@as(?u64, null), line.wakeAt());
    _ = line.step(.dropped, 1_000, 2);
    const at = line.retry_at_ms;
    try std.testing.expectEqual(@as(?u64, at), line.wakeAt());
    try std.testing.expect(!line.due(at - 1));
    try std.testing.expect(line.due(at));
}

test "EXR-75 a notice naming another subscription changes nothing, and an unnamed one counts" {
    var line: Line = .{ .state = .open, .opens = 2, .acked_at_ms = 0 };
    try std.testing.expectEqual(Effect{}, line.step(.{ .tools_changed = 1 }, 5, 1));
    try std.testing.expectEqual(Effect{}, line.step(.{ .ended = 1 }, 5, 1));
    try std.testing.expectEqual(State.open, line.state);
    try std.testing.expectEqual(Effect{ .ask = true }, line.step(.{ .tools_changed = null }, 5, 1));
    try std.testing.expectEqual(Effect{ .ask = true }, line.step(.{ .tools_changed = 2 }, 5, 1));
}
