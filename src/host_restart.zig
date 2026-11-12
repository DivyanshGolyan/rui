//! Whether the overview starts its Host by itself after the Host went away:
//! once per run, only after a crash, and only where `r` could start it too.
//! The overview reads the Host, the stop record and its own launch state,
//! and applies the decision; this core holds no fact of its own besides the
//! allowance it hands back.
const std = @import("std");

/// How the last Host of a Store ended, as its stop record says. The Host
/// leaves the record when someone asks it to stop and removes it at every
/// start (`platform.StoreLease`).
pub const LastStop = enum {
    /// Someone asked the last Host to stop: `host-stop` or its launcher.
    asked,
    /// The last Host ended without being asked: a crash or a kill.
    unasked,
    /// The record could not be read, so neither is known.
    unknown,
};

/// One Host read, as far as a restart is concerned.
pub const Seen = union(enum) {
    /// Ready, or not read yet: the screen opened on a ready Host.
    up,
    /// The Store lease is free.
    stopped: LastStop,
    /// A Host holds the Store unanswered, answers in another Rui version,
    /// or the Store cannot be read: no start can help, so nothing crashed.
    held,
};

/// The overview's one automatic start per run.
pub const Allowance = enum { unspent, spent };

pub const Input = struct {
    previous: Seen,
    next: Seen,
    allowance: Allowance,
    /// An Upgrade owns the Host's swap and reobservation.
    upgrade_holds: bool,
    /// What `r` needs besides a stopped Host and no Upgrade: no start queued
    /// or running, and no last failure a start cannot mend.
    start_available: bool,
};

pub const Decision = struct {
    start: bool,
    allowance: Allowance,
};

pub fn decide(input: Input) Decision {
    const unchanged: Decision = .{ .start = false, .allowance = input.allowance };
    // Only the change to stopped is a crash; rereading the same stop, as
    // after a failed start, is not another one.
    if (input.previous == .stopped or input.next != .stopped) return unchanged;
    switch (input.next.stopped) {
        .unasked => {},
        // An unreadable record cannot tell a crash from a stop someone
        // asked for. Starting a Host the person stopped is the worse
        // mistake, so only a record known to be absent restarts.
        .asked, .unknown => return unchanged,
    }
    if (input.allowance == .spent or input.upgrade_holds or !input.start_available) return unchanged;
    return .{ .start = true, .allowance = .spent };
}

const all_seen = [_]Seen{ .up, .{ .stopped = .asked }, .{ .stopped = .unasked }, .{ .stopped = .unknown }, .held };

test "every input: a start only on the change to an unasked stop, with the allowance unspent, no Upgrade and r available" {
    for (all_seen) |previous| for (all_seen) |next| for (std.enums.values(Allowance)) |allowance| for ([_]bool{ false, true }) |upgrade_holds| for ([_]bool{ false, true }) |start_available| {
        const decision = decide(.{ .previous = previous, .next = next, .allowance = allowance, .upgrade_holds = upgrade_holds, .start_available = start_available });
        // Spelled out from the contract case by case, not from `decide`.
        const crashed = switch (next) {
            .stopped => |stop| stop == .unasked,
            .up, .held => false,
        };
        const changed = switch (previous) {
            .stopped => false,
            .up, .held => true,
        };
        const expected = crashed and changed and allowance == .unspent and !upgrade_holds and start_available;
        try std.testing.expectEqual(expected, decision.start);
        try std.testing.expectEqual(if (expected) Allowance.spent else allowance, decision.allowance);
    };
}

/// Folds reads through `decide` as the overview applies them, counting
/// the starts it asks for.
const Run = struct {
    seen: Seen = .up,
    allowance: Allowance = .unspent,
    upgrade_holds: bool = false,
    start_available: bool = true,
    starts: usize = 0,

    fn read(run: *Run, next: Seen) void {
        const decision = decide(.{ .previous = run.seen, .next = next, .allowance = run.allowance, .upgrade_holds = run.upgrade_holds, .start_available = run.start_available });
        run.seen = next;
        run.allowance = decision.allowance;
        if (decision.start) run.starts += 1;
    }
};

test "repeated reads of one stop start at most once, whatever the record says" {
    for ([_]LastStop{ .asked, .unasked, .unknown }) |stop| {
        var run: Run = .{};
        for (0..4) |_| run.read(.{ .stopped = stop });
        try std.testing.expectEqual(@as(usize, if (stop == .unasked) 1 else 0), run.starts);
    }
}

test "an automatic start that fails leaves the stop to r, and a later crash too" {
    var run: Run = .{};
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
    // The start failed: its own read sees the same stop.
    run.read(.{ .stopped = .unasked });
    run.read(.{ .stopped = .unasked });
    // r started it; it crashed again.
    run.read(.up);
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
    try std.testing.expectEqual(Allowance.spent, run.allowance);
}

test "a manual start's failure spends nothing: a later crash still starts once" {
    var run: Run = .{};
    run.read(.{ .stopped = .asked });
    // r's start failed with a cause a start can mend, then succeeded.
    run.read(.{ .stopped = .asked });
    run.read(.up);
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
    // A failure no start can mend offers no r, so nothing starts by itself.
    var unmendable: Run = .{ .start_available = false };
    unmendable.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 0), unmendable.starts);
    try std.testing.expectEqual(Allowance.unspent, unmendable.allowance);
}

test "Upgrade custody holds every start; once it leaves, the next owner's stop decides" {
    var run: Run = .{ .upgrade_holds = true };
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 0), run.starts);
    // Custody ends: the overview forgets the swap-time read and reads again.
    run.upgrade_holds = false;
    run.read(.held);
    run.read(.{ .stopped = .asked }); // The Upgrade asked the old Host to stop.
    try std.testing.expectEqual(@as(usize, 0), run.starts);
    run.read(.held);
    run.read(.{ .stopped = .unasked }); // Its new Host crashed.
    try std.testing.expectEqual(@as(usize, 1), run.starts);
}

test "held states never start, and a stop after one is a change" {
    var run: Run = .{};
    run.read(.held);
    run.read(.held);
    try std.testing.expectEqual(@as(usize, 0), run.starts);
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
}
