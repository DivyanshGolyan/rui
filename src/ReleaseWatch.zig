//! The newest release this TUI knows of. It reads at its first poll and then
//! again once a 50 to 70 minute gap has passed, and it feeds only the update
//! offer. An Upgrade run never reads it: a run checks the release itself.
const std = @import("std");
const upgrade = @import("upgrade.zig");
const release = @import("release_candidate.zig");
const upgrade_status = @import("upgrade_status.zig");
const ClientTask = @import("ClientTask.zig");
const test_poll = @import("test_poll");
const Self = @This();

const minute_ms = std.time.ms_per_min;
const min_gap_ms: u64 = 50 * minute_ms;
const jitter_ms: u64 = 20 * minute_ms;

init: std.process.Init = undefined,
allocator: std.mem.Allocator = undefined,
task: ClientTask = .{},
download: upgrade.Download = .{},
version: ?release.Version = null,
available: ?upgrade_status.Version = null,
due_ms: ?u64 = null,
settled: bool = false,

/// Collects a finished read, then starts the next one when it is due. Returns
/// the offer the caller should show.
pub fn poll(self: *Self, init: std.process.Init, now_ms: u64) ?upgrade_status.Version {
    return self.pollWith(init, now_ms, work, gapMs);
}

/// Cancels and joins a read in flight; afterwards `poll` never starts another.
pub fn settle(self: *Self) void {
    self.settled = true;
    if (self.task.thread == null) return;
    self.task.cancel();
    _ = self.task.join() catch {};
    self.releaseRead();
}

pub fn deinit(self: *Self) void {
    self.settle();
    self.* = .{};
}

const Gap = *const fn (std.Io) u64;

fn pollWith(self: *Self, init: std.process.Init, now_ms: u64, worker: ClientTask.Run, gap: Gap) ?upgrade_status.Version {
    if (self.task.thread != null and self.task.completed()) self.collect(now_ms, gap(init.io));
    if (self.task.thread == null and !self.settled and self.due(now_ms)) self.startRead(init, now_ms, worker, gap);
    return self.available;
}

fn due(self: *const Self, now_ms: u64) bool {
    const at = self.due_ms orelse return true;
    return now_ms >= at;
}

fn collect(self: *Self, now_ms: u64, gap_ms: u64) void {
    const succeeded = if (self.task.join()) |_| true else |_| false;
    if (succeeded) if (self.version) |found| {
        self.available = newerRelease(@import("transport_options").version, found);
    };
    self.releaseRead();
    self.due_ms = now_ms + gap_ms;
}

fn startRead(self: *Self, init: std.process.Init, now_ms: u64, worker: ClientTask.Run, gap: Gap) void {
    self.init = init;
    self.allocator = init.gpa;
    self.version = null;
    self.task.start(init.io, self, worker) catch {
        self.due_ms = now_ms + gap(init.io);
    };
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
    return gapFrom(bytes);
}

fn gapFrom(bytes: [8]u8) u64 {
    return min_gap_ms + std.mem.readInt(u64, &bytes, .little) % (jitter_ms + 1);
}

fn newerRelease(running_text: []const u8, candidate: release.Version) ?upgrade_status.Version {
    const running = release.Version.parse(running_text) catch return null;
    return if (running.order(candidate) == .lt) upgrade.versionOf(candidate) else null;
}

const Hour = struct {
    const gap_ms: u64 = 60 * minute_ms;
    fn gap(_: std.Io) u64 {
        return gap_ms;
    }
};

fn bytesOf(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return bytes;
}

test "SH-143 the watch reads at its first poll, again only once its gap has passed, and a failed read keeps the last offer" {
    for (0..10_000) |step| {
        const gap = gapFrom(bytesOf(@as(u64, step) *% 0x9E3779B97F4A7C15));
        try std.testing.expect(gap >= 50 * minute_ms and gap <= 70 * minute_ms);
    }
    try std.testing.expectEqual(50 * minute_ms, gapFrom(bytesOf(0)));
    try std.testing.expectEqual(70 * minute_ms, gapFrom(bytesOf(jitter_ms)));

    const Fake = struct {
        var calls: usize = 0;
        var failing = false;
        fn run(raw: *anyopaque, _: *ClientTask) !void {
            const watch: *Self = @ptrCast(@alignCast(raw));
            calls += 1;
            if (failing) return error.ReleaseDownloadFailed;
            watch.version = .{ .schema = 999, .patch = 2 };
        }
    };
    const io = std.testing.io;
    var init: std.process.Init = undefined;
    init.io = io;
    init.gpa = std.testing.allocator;
    const gap = Hour.gap_ms;
    var watch: Self = .{};
    defer watch.deinit();
    Fake.calls = 0;

    try std.testing.expectEqual(@as(?upgrade_status.Version, null), watch.pollWith(init, 0, Fake.run, Hour.gap));
    try std.testing.expect(watch.task.thread != null);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &watch.task, ClientTask.completed);
    _ = watch.pollWith(init, 0, Fake.run, Hour.gap);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expectEqual(@as(?u64, gap), watch.due_ms);
    try std.testing.expectEqualDeep(newerRelease(@import("transport_options").version, .{ .schema = 999, .patch = 2 }), watch.available);

    const offer: upgrade_status.Version = .{ .schema = 999, .patch = 2 };
    watch.available = offer;
    _ = watch.pollWith(init, gap - 1, Fake.run, Hour.gap);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    try std.testing.expectEqual(@as(?u64, gap), watch.due_ms);

    Fake.failing = true;
    _ = watch.pollWith(init, gap, Fake.run, Hour.gap);
    try std.testing.expect(watch.task.thread != null);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &watch.task, ClientTask.completed);
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.pollWith(init, gap, Fake.run, Hour.gap));
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);
    try std.testing.expectEqual(@as(?u64, 2 * gap), watch.due_ms);
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.pollWith(init, 2 * gap - 1, Fake.run, Hour.gap));
    try std.testing.expectEqual(@as(usize, 2), Fake.calls);

    Fake.failing = false;
    _ = watch.pollWith(init, 2 * gap, Fake.run, Hour.gap);
    try std.testing.expect(watch.task.thread != null);
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &watch.task, ClientTask.completed);
    _ = watch.pollWith(init, 2 * gap, Fake.run, Hour.gap);
    try std.testing.expectEqual(@as(usize, 3), Fake.calls);
    try std.testing.expectEqualDeep(newerRelease(@import("transport_options").version, .{ .schema = 999, .patch = 2 }), watch.available);
    try std.testing.expectEqual(@as(?u64, 3 * gap), watch.due_ms);
}

test "SH-144 only a release newer than this build is offered; equal, older or an unparsable build is not" {
    const candidate: release.Version = .{ .schema = 60, .patch = 1 };
    for ([_]struct { []const u8, release.Version, bool }{
        .{ "0.60.1", .{ .schema = 60, .patch = 0 }, false },
        .{ "0.60.1", .{ .schema = 60, .patch = 1 }, false },
        .{ "0.60.1", .{ .schema = 60, .patch = 2 }, true },
        .{ "0.60.1", .{ .schema = 61, .patch = 0 }, true },
        .{ "0.60.1", .{ .schema = 59, .patch = 999 }, false },
        .{ "source", .{ .schema = 60, .patch = 2 }, false },
        .{ "unreleased", .{ .schema = 60, .patch = 2 }, false },
    }) |case| {
        const offered = newerRelease(case[0], case[1]);
        try std.testing.expectEqual(case[2], offered != null);
        if (offered) |found| try std.testing.expectEqualDeep(upgrade.versionOf(case[1]), found);
    }
    try std.testing.expect(newerRelease("0.60.1", candidate) == null);
}

test "SH-145 settle stops a read in flight and the watch reads no more" {
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
    watch.available = offer;
    Blocked.calls.store(0, .release);

    try std.testing.expectEqual(@as(?upgrade_status.Version, offer), watch.pollWith(init, 0, Blocked.run, Hour.gap));
    try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(10)), &Blocked.calls, Blocked.started);
    watch.settle();
    try std.testing.expect(watch.task.thread == null and watch.settled);
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.available);
    watch.settle();
    try std.testing.expectEqualDeep(@as(?upgrade_status.Version, offer), watch.pollWith(init, std.math.maxInt(u32), Blocked.run, Hour.gap));
    try std.testing.expectEqual(@as(usize, 1), Blocked.calls.load(.acquire));
    try std.testing.expect(watch.task.thread == null);
}
