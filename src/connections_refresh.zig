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
            if (now >= asked and now - asked < refresh_seconds) return .{ .state = state, .ask = false };
            return .{ .state = .{ .asked_at = now }, .ask = true };
        },
    }
}

/// Whether a reading newer than the drawn one needs a redraw: each reading is the second it was taken, or null when the Host could not be read.
pub fn redraw(drawn: ?u64, held: ?u64) bool {
    return drawn != held;
}

test "SUI-188 the open Connections reference asks on opening and every five seconds after, never before opening, and redraws exactly when its reading changes" {
    // Every state: never opened, and opened at each second of a window, including the largest second.
    const opened_at = [_]?u64{ null, 0, 1, 4, 5, 6, 10, 100, std.math.maxInt(u64) - 3, std.math.maxInt(u64) };
    const clocks = [_]u64{ 0, 1, 3, 4, 5, 6, 9, 10, 11, 15, 100, 104, 105, 106, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };
    for (opened_at) |asked| for (clocks) |now| {
        const state: State = .{ .asked_at = asked };
        // Opening always asks and starts the wait at that second, whatever came before.
        const opened = step(state, .{ .opened = now });
        try std.testing.expect(opened.ask);
        try std.testing.expectEqual(State{ .asked_at = now }, opened.state);
        // A tick asks exactly when an opening came at least five seconds earlier (a clock that went backward asks again so the wait cannot stall,
        // and a second near the top of the range never overflows); asking restarts the wait, not asking changes nothing.
        const due = if (asked) |value| now < value or now - value >= 5 else false;
        const ticked = step(state, .{ .tick = now });
        try std.testing.expectEqual(due, ticked.ask);
        try std.testing.expectEqual(if (due) State{ .asked_at = now } else state, ticked.state);
    };
    // The wait chains: opened at 10, ticks at 14 (no), 15 (asks), 19 (no), 20 (asks).
    var state: State = step(.{}, .{ .opened = 10 }).state;
    for ([_]struct { u64, bool }{ .{ 14, false }, .{ 15, true }, .{ 19, false }, .{ 20, true } }) |tick| {
        const next = step(state, .{ .tick = tick[0] });
        try std.testing.expectEqual(tick[1], next.ask);
        state = next.state;
    }
    // Readings: unchanged ones never redraw; any change, including to or from an unreadable Host, does.
    const readings = [_]?u64{ null, 0, 5, 6 };
    for (readings) |drawn| for (readings) |held| try std.testing.expectEqual(drawn != held, redraw(drawn, held));
}
