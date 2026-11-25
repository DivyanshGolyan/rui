//! The newest release this TUI knows of. It reads at its first poll and then
//! again once a 50 to 70 minute gap has passed, and it feeds only the update
//! offer. An Upgrade run never reads it: a run checks the release itself.
//! `release_schedule` decides when to read and what to offer; this shell runs the reads.
const std = @import("std");
const upgrade = @import("upgrade.zig");
const release = @import("release_candidate.zig");
const release_schedule = @import("release_schedule.zig");
const upgrade_status = @import("upgrade_status.zig");
const ClientTask = @import("ClientTask.zig");
const test_poll = @import("test_poll");
const Self = @This();

init: std.process.Init = undefined,
allocator: std.mem.Allocator = undefined,
task: ClientTask = .{},
download: upgrade.Download = .{},
version: ?release.Version = null,
schedule: release_schedule.Schedule = .{},

/// Collects a finished read, then starts the next one when it is due. Returns
/// the offer the caller should show.
pub fn poll(self: *Self, init: std.process.Init, now_ms: u64) ?upgrade_status.Version {
    return self.pollWith(init, now_ms, work, gapMs);
}

/// Cancels and joins a read in flight; afterwards `poll` never starts another.
pub fn settle(self: *Self) void {
    if (self.task.thread != null) {
        self.task.cancel();
        _ = self.task.join() catch {};
        self.releaseRead();
    }
    self.schedule = release_schedule.next(self.schedule, .settled);
}

pub fn deinit(self: *Self) void {
    self.settle();
    self.* = .{};
}

const Gap = *const fn (std.Io) u64;

fn pollWith(self: *Self, init: std.process.Init, now_ms: u64, worker: ClientTask.Run, gap: Gap) ?upgrade_status.Version {
    if (self.task.thread != null and self.task.completed()) {
        const found = if (self.task.join()) |_| self.version else |_| null;
        self.releaseRead();
        self.schedule = release_schedule.next(self.schedule, .{ .read = .{
            .moment = .{ .now_ms = now_ms, .gap_ms = gap(init.io) },
            .running = running(),
            .found = if (found) |version| upgrade.versionOf(version) else null,
        } });
    }
    if (self.schedule.startsRead(now_ms)) {
        self.init = init;
        self.allocator = init.gpa;
        self.version = null;
        if (self.task.start(init.io, self, worker)) {
            self.schedule = release_schedule.next(self.schedule, .started);
        } else |_| {
            self.schedule = release_schedule.next(self.schedule, .{ .start_failed = .{ .now_ms = now_ms, .gap_ms = gap(init.io) } });
        }
    }
    return self.schedule.offer;
}

fn running() ?upgrade_status.Version {
    const version = release.Version.parse(@import("transport_options").version) catch return null;
    return upgrade.versionOf(version);
}

fn releaseRead(self: *Self) void {
    self.download.deinit(self.allocator);
    self.version = null;
}

fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.version = try upgrade.latestVersion(self.init, self.allocator, &task.cancellation, &self.download);
}

fn gapMs(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return release_schedule.gap(std.mem.readInt(u64, &bytes, .little));
}

fn hour(_: std.Io) u64 {
    return 60 * std.time.ms_per_min;
}

test "SH-151 settle stops a read in flight and the watch reads no more" {
    const Blocked = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn started(count: *const std.atomic.Value(usize)) bool {
            return count.load(.acquire) != 0;
        }
        fn run(_: *anyopaque, task: *ClientTask) !void {
            _ = calls.fetchAdd(1, .acq_rel);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &task.cancellation.stopped, test_poll.isSet);
            return error.Cancelled;
        }
    };
    const io = std.testing.io;
    var init: std.process.Init = undefined;
    init.io = io;
    init.gpa = std.testing.allocator;
    var watch: Self = .{};
    defer watch.deinit();
    const offer: upgrade_status.Version = .{ .schema = 999, .patch = 2 };
    watch.schedule.offer = offer;
    Blocked.calls.store(0, .release);

    try std.testing.expectEqual(@as(?upgrade_status.Version, offer), watch.pollWith(init, 0, Blocked.run, hour));
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &Blocked.calls, Blocked.started);
    watch.settle();
    try std.testing.expect(watch.task.thread == null and watch.schedule.settled);
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.schedule.offer);
    watch.settle();
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.pollWith(init, std.math.maxInt(u32), Blocked.run, hour));
    try std.testing.expectEqual(@as(usize, 1), Blocked.calls.load(.acquire));
    try std.testing.expect(watch.task.thread == null);
}
