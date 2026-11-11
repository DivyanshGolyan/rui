//! How long a launcher waits for the Host it started to report ready. A
//! Host announces a Store migration on its startup channel before it backs
//! the Store up, and announces the migration's end; the backup is as large
//! as the Store, so no deadline runs between the two. Readiness otherwise
//! gets ten seconds from launch, or from the migration's end.
const std = @import("std");

pub const migrating_tag = "[store_migrating]\n";
pub const migrated_tag = "[store_migrated]\n";
pub const readiness_ns: i96 = 10_000_000_000;

phase: union(enum) {
    starting: i96,
    migrating,
    migrated: i96,
},

const Self = @This();

pub fn init(launched: i96) Self {
    return .{ .phase = .{ .starting = launched + readiness_ns } };
}

/// Takes all startup output read so far and the time it was read.
pub fn observe(self: *Self, output: []const u8, now: i96) void {
    if (std.mem.indexOf(u8, output, migrated_tag) != null) {
        if (self.phase != .migrated) self.phase = .{ .migrated = now + readiness_ns };
    } else if (std.mem.indexOf(u8, output, migrating_tag) != null) self.phase = .migrating;
}

/// The deadline for a readiness probe begun at `now`; while the Host
/// migrates, one ordinary probe's worth past `now`.
pub fn until(self: Self, now: i96) i96 {
    return switch (self.phase) {
        .starting, .migrated => |deadline| deadline,
        .migrating => now + readiness_ns,
    };
}

pub fn expired(self: Self, now: i96) bool {
    return now >= self.until(now);
}

/// How much of the startup output to show while the Host still starts: through
/// the migration announcement, so the wait it explains is not silent.
pub fn shownWhileStarting(output: []const u8) usize {
    const at = std.mem.indexOf(u8, output, migrating_tag) orelse return 0;
    return at + migrating_tag.len;
}

test "readiness gets ten seconds from launch without a migration" {
    var wait = init(100);
    wait.observe("rui: some notice\n", 5);
    try std.testing.expectEqual(@as(i96, 100 + readiness_ns), wait.until(5));
    try std.testing.expect(!wait.expired(100 + readiness_ns - 1));
    try std.testing.expect(wait.expired(100 + readiness_ns));
}

test "no deadline runs while the Host migrates, and ten seconds follow its end" {
    var wait = init(0);
    const announced = "rui: backing up and migrating " ++ migrating_tag;
    wait.observe(announced, readiness_ns - 1);
    const late: i96 = 60 * readiness_ns;
    try std.testing.expect(!wait.expired(late));
    try std.testing.expectEqual(late + readiness_ns, wait.until(late));
    // Rereading the same output, or the end arriving later, keeps the first end time.
    wait.observe(announced, late);
    try std.testing.expect(!wait.expired(late + 1));
    wait.observe(announced ++ "rui: migrated " ++ migrated_tag, late);
    wait.observe(announced ++ "rui: migrated " ++ migrated_tag, late + 5);
    try std.testing.expectEqual(late + readiness_ns, wait.until(late + 5));
    try std.testing.expect(wait.expired(late + readiness_ns));
}

test "a migration that begins and ends within one read still gets ten seconds" {
    var wait = init(0);
    const now: i96 = 4 * readiness_ns;
    wait.observe("a " ++ migrating_tag ++ "b " ++ migrated_tag, now);
    try std.testing.expect(!wait.expired(now));
    try std.testing.expectEqual(now + readiness_ns, wait.until(now));
}

test "only output through the migration announcement shows while starting" {
    try std.testing.expectEqual(@as(usize, 0), shownWhileStarting("rui: other notice\n"));
    const announced = "rui: migrating " ++ migrating_tag;
    try std.testing.expectEqual(announced.len, shownWhileStarting(announced ++ "rui: migrated " ++ migrated_tag));
}
