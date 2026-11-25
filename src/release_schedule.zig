//! When the release watch reads, and which release a read leaves on offer.
//! Values only: `ReleaseWatch` starts, joins and cancels the reads it decides.
const std = @import("std");
const upgrade_status = @import("upgrade_status.zig");
const Version = upgrade_status.Version;

const minute_ms: u64 = 60 * 1000;
pub const shortest_gap_ms: u64 = 50 * minute_ms;
pub const longest_gap_ms: u64 = 70 * minute_ms;

pub const Schedule = struct {
    due_ms: ?u64 = null,
    reading: bool = false,
    settled: bool = false,
    offer: ?Version = null,

    /// Whether a read starts now: the first poll, then once the gap has passed,
    /// never while one runs or after settling.
    pub fn startsRead(self: Schedule, now_ms: u64) bool {
        if (self.reading or self.settled) return false;
        const due = self.due_ms orelse return true;
        return now_ms >= due;
    }
};

pub const Event = union(enum) {
    started,
    /// The read could not start; try again after the gap.
    start_failed: Moment,
    /// A read ended: `found` is null when it failed, `running` when this
    /// build's version does not parse (a source build is never offered anything).
    read: struct { moment: Moment, running: ?Version, found: ?Version },
    settled,
};

pub const Moment = struct { now_ms: u64, gap_ms: u64 };

pub fn next(schedule: Schedule, event: Event) Schedule {
    var result = schedule;
    switch (event) {
        .started => result.reading = true,
        .start_failed => |moment| result.due_ms = moment.now_ms + moment.gap_ms,
        .read => |read| {
            result.reading = false;
            result.due_ms = read.moment.now_ms + read.moment.gap_ms;
            // A failed read keeps the last offer: a network blip must not hide a known update.
            if (read.found) |found| result.offer = offerOf(read.running, found);
        },
        .settled => {
            result.reading = false;
            result.settled = true;
        },
    }
    return result;
}

/// The gap before the next read, drawn from 64 random bits.
pub fn gap(random: u64) u64 {
    return shortest_gap_ms + random % (longest_gap_ms - shortest_gap_ms + 1);
}

fn offerOf(running: ?Version, found: Version) ?Version {
    const build = running orelse return null;
    return if (build.order(found) == .lt) found else null;
}

test "SH-149 the watch reads at its first poll, again only once its gap has passed, and a failed read keeps the last offer" {
    const hour: u64 = 60 * minute_ms;
    const running: Version = .{ .schema = 80, .patch = 1 };
    const newer: Version = .{ .schema = 80, .patch = 2 };
    var schedule: Schedule = .{};
    try std.testing.expect(schedule.startsRead(0));
    schedule = next(schedule, .started);
    try std.testing.expect(!schedule.startsRead(0) and !schedule.startsRead(10 * hour));
    schedule = next(schedule, .{ .read = .{ .moment = .{ .now_ms = 5, .gap_ms = hour }, .running = running, .found = newer } });
    try std.testing.expectEqual(@as(?u64, 5 + hour), schedule.due_ms);
    try std.testing.expectEqual(@as(?Version, newer), schedule.offer);
    try std.testing.expect(!schedule.startsRead(5 + hour - 1));
    try std.testing.expect(schedule.startsRead(5 + hour));
    schedule = next(next(schedule, .started), .{ .read = .{ .moment = .{ .now_ms = 2 * hour, .gap_ms = hour }, .running = running, .found = null } });
    try std.testing.expectEqual(@as(?Version, newer), schedule.offer);
    try std.testing.expectEqual(@as(?u64, 3 * hour), schedule.due_ms);
    schedule = next(schedule, .{ .start_failed = .{ .now_ms = 3 * hour, .gap_ms = hour } });
    try std.testing.expect(!schedule.reading and !schedule.startsRead(4 * hour - 1) and schedule.startsRead(4 * hour));
    schedule = next(next(schedule, .started), .settled);
    try std.testing.expect(!schedule.reading and !schedule.startsRead(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(?Version, newer), schedule.offer);

    for ([_]u64{ 0, 1, longest_gap_ms - shortest_gap_ms, longest_gap_ms - shortest_gap_ms + 1, std.math.maxInt(u64) }) |random| {
        const drawn = gap(random);
        try std.testing.expect(drawn >= shortest_gap_ms and drawn <= longest_gap_ms);
    }
    try std.testing.expectEqual(shortest_gap_ms, gap(0));
    try std.testing.expectEqual(longest_gap_ms, gap(longest_gap_ms - shortest_gap_ms));
}

test "SH-150 only a release newer than this build is offered; equal, older or an unparsable build is not" {
    const v = struct {
        fn of(schema: u32, patch: u32) Version {
            return .{ .schema = schema, .patch = patch };
        }
    }.of;
    const moment: Moment = .{ .now_ms = 0, .gap_ms = 1 };
    for ([_]struct { ?Version, Version, bool }{
        .{ v(60, 1), v(60, 0), false },
        .{ v(60, 1), v(60, 1), false },
        .{ v(60, 1), v(60, 2), true },
        .{ v(60, 1), v(61, 0), true },
        .{ v(60, 1), v(59, 999), false },
        .{ null, v(60, 2), false },
    }) |case| {
        // An earlier offer is replaced by what this read found, even when that is nothing.
        const before: Schedule = .{ .reading = true, .offer = v(99, 0) };
        const after = next(before, .{ .read = .{ .moment = moment, .running = case[0], .found = case[1] } });
        try std.testing.expectEqual(if (case[2]) @as(?Version, case[1]) else null, after.offer);
    }
}
