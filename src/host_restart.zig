const std = @import("std");

pub const LastStop = enum {
    asked,
    unasked,
    unknown,
};

pub const Seen = union(enum) {
    up,
    stopped: LastStop,
    held,
};

pub const Allowance = enum { unspent, spent };

pub const Input = struct {
    previous: Seen,
    next: Seen,
    allowance: Allowance,
    upgrade_holds: bool,
    start_available: bool,
};

pub const Decision = struct {
    start: bool,
    allowance: Allowance,
};

pub fn decide(input: Input) Decision {
    const unchanged: Decision = .{ .start = false, .allowance = input.allowance };
    if (input.previous == .stopped or input.next != .stopped) return unchanged;
    switch (input.next.stopped) {
        .unasked => {},
        .asked, .unknown => return unchanged,
    }
    if (input.allowance == .spent or input.upgrade_holds or !input.start_available) return unchanged;
    return .{ .start = true, .allowance = .spent };
}

const all_seen = [_]Seen{ .up, .{ .stopped = .asked }, .{ .stopped = .unasked }, .{ .stopped = .unknown }, .held };

test "every input: a start only on the change to an unasked stop, with the allowance unspent, no Upgrade and r available" {
    for (all_seen) |previous| for (all_seen) |next| for (std.enums.values(Allowance)) |allowance| for ([_]bool{ false, true }) |upgrade_holds| for ([_]bool{ false, true }) |start_available| {
        const decision = decide(.{ .previous = previous, .next = next, .allowance = allowance, .upgrade_holds = upgrade_holds, .start_available = start_available });
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
    run.read(.{ .stopped = .unasked });
    run.read(.{ .stopped = .unasked });
    run.read(.up);
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
    try std.testing.expectEqual(Allowance.spent, run.allowance);
}

test "a manual start's failure spends nothing: a later crash still starts once" {
    var run: Run = .{};
    run.read(.{ .stopped = .asked });
    run.read(.{ .stopped = .asked });
    run.read(.up);
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 1), run.starts);
    var unmendable: Run = .{ .start_available = false };
    unmendable.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 0), unmendable.starts);
    try std.testing.expectEqual(Allowance.unspent, unmendable.allowance);
}

test "Upgrade custody holds every start; once it leaves, the next owner's stop decides" {
    var run: Run = .{ .upgrade_holds = true };
    run.read(.{ .stopped = .unasked });
    try std.testing.expectEqual(@as(usize, 0), run.starts);
    run.upgrade_holds = false;
    run.read(.held);
    run.read(.{ .stopped = .asked });
    try std.testing.expectEqual(@as(usize, 0), run.starts);
    run.read(.held);
    run.read(.{ .stopped = .unasked });
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
