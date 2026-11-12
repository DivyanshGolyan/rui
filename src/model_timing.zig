//! Live final-Attempt observations. The transport publishes boundaries;
//! the Store snapshots them only in the write that resolves an Operation.
const std = @import("std");

pub const Values = struct {
    latency_ms: ?u64 = null,
    first_event_ms: ?u64 = null,
};

/// Stable custody-owned storage, borrowed by a Transfer until its deinit.
/// Atomics cross the transport/Store threads; no resolution is written here.
pub const Attempt = struct {
    sent_at_ms: std.atomic.Value(i64) = .init(-1),
    first_event_ms: std.atomic.Value(i64) = .init(-1),

    pub fn reset(self: *Attempt) void {
        self.sent_at_ms.store(-1, .release);
        self.first_event_ms.store(-1, .release);
    }

    pub fn begin(self: *Attempt, now: std.Io.Timestamp) void {
        self.first_event_ms.store(-1, .release);
        self.sent_at_ms.store(now.toMilliseconds(), .release);
    }

    pub fn responseEvent(self: *Attempt, now: std.Io.Timestamp) void {
        if (self.elapsedMs(now)) |elapsed|
            _ = self.first_event_ms.cmpxchgStrong(-1, @intCast(elapsed), .release, .monotonic);
    }

    pub fn firstEventMs(self: *const Attempt) ?u64 {
        const value = self.first_event_ms.load(.acquire);
        return if (value < 0) null else @intCast(value);
    }

    pub fn elapsedMs(self: *const Attempt, now: std.Io.Timestamp) ?u64 {
        const sent = self.sent_at_ms.load(.acquire);
        return if (sent < 0) null else @intCast(@max(0, now.toMilliseconds() - sent));
    }

    pub fn snapshot(self: *const Attempt, now: std.Io.Timestamp) Values {
        return .{ .latency_ms = self.elapsedMs(now), .first_event_ms = self.firstEventMs() };
    }
};

/// The Host lends its bounded custody registry to the Store. An absent
/// source/Operation (prelaunch or recovery) has no observed boundaries.
pub const Source = struct {
    context: ?*anyopaque = null,
    read: ?*const fn (*anyopaque, u64, std.Io.Timestamp) Values = null,

    pub fn snapshot(self: Source, operation: u64, now: std.Io.Timestamp) Values {
        return if (self.read) |read| read(self.context.?, operation, now) else .{};
    }
};
