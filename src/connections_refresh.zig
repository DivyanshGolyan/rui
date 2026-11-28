//! When the open Connections reference asks its owner for a newer Host reading, and when it redraws.
//! A plain-value core: the shell passes the clock and the readings it holds and applies what comes back.

const std = @import("std");

/// How long a reading is kept before the open reference asks again, in seconds.
pub const refresh_seconds = 5;

/// What the reference remembers: the second it last asked, or null before it ever opened.
pub const State = struct { asked_at: ?u64 = null };

pub const Event = union(enum) {
    /// The reference opened at this second.
    opened: u64,
    /// A tick arrived while the reference is open, at this second.
    tick: u64,
};

pub const Step = struct { state: State, ask: bool };

/// Opening always asks; a tick asks once the last ask is `refresh_seconds` old (and never before an opening). The shell sends ticks only while the reference is open.
pub fn step(state: State, event: Event) Step {
    switch (event) {
        .opened => |now| return .{ .state = .{ .asked_at = now }, .ask = true },
        .tick => |now| {
            const asked = state.asked_at orelse return .{ .state = state, .ask = false };
            if (now < asked +| refresh_seconds) return .{ .state = state, .ask = false };
            return .{ .state = .{ .asked_at = now }, .ask = true };
        },
    }
}

/// Whether a reading newer than the drawn one needs a redraw: each reading is the second it was taken, or null when the Host could not be read.
pub fn redraw(drawn: ?u64, held: ?u64) bool {
    return drawn != held;
}

test "SUI-188 the open Connections reference asks on opening and every five seconds after, never before opening, and redraws exactly when its reading changes" {
    // Over every state and second in a window: opening asks and starts the wait.
    var asked: ?u64 = null;
    while (true) : (asked = if (asked) |value| (if (value < 12) value + 1 else null) else 0) {
        const state: State = .{ .asked_at = asked };
        var now: u64 = 0;
        while (now <= 20) : (now += 1) {
            const opened = step(state, .{ .opened = now });
            try std.testing.expect(opened.ask);
            try std.testing.expectEqual(State{ .asked_at = now }, opened.state);
            const ticked = step(state, .{ .tick = now });
            // The expected outcome comes from the stated rule, not from the function.
            const due = if (asked) |value| now >= value + 5 else false;
            try std.testing.expectEqual(due, ticked.ask);
            try std.testing.expectEqual(if (due) State{ .asked_at = now } else state, ticked.state);
        }
        if (asked == null) break;
    }
    // A tick before any opening asks nothing, even far in the future.
    try std.testing.expect(!step(.{}, .{ .tick = std.math.maxInt(u64) }).ask);
    // An ask at the largest second never overflows.
    try std.testing.expect(!step(.{ .asked_at = std.math.maxInt(u64) }, .{ .tick = 0 }).ask);
    // Readings: unchanged ones never redraw; any change, including to or from an unreadable Host, does.
    const readings = [_]?u64{ null, 0, 5, 6 };
    for (readings) |drawn| for (readings) |held| try std.testing.expectEqual(drawn != held, redraw(drawn, held));
}
