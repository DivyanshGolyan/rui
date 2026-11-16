//! Live final-Attempt observations. The transport publishes boundaries;
//! the Store saves them in the write ending an attempt (resolution or retry).
const std = @import("std");

pub const Values = struct {
    latency_ms: ?u64 = null,
    first_event_ms: ?u64 = null,
};

/// Stable custody-owned storage, borrowed by a Transfer until its deinit.
/// Atomics cross the transport/Store threads; no durable timing is owned here.
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
        return latencyMs(self.sent_at_ms.load(.acquire), now.toMilliseconds());
    }

    /// Milliseconds from `sent` to `cutoff_ms`, never negative; null when
    /// the request was not sent. Callers load `sent` in their own order.
    fn latencyMs(sent: i64, cutoff_ms: i64) ?u64 {
        return if (sent < 0) null else @intCast(@max(0, cutoff_ms - sent));
    }

    /// Read the published boundaries before sampling their cutoff. The event's
    /// acquire pairs with publication after `begin`, so a known event also has
    /// a known send. A callback during the clock read cannot amend this value.
    pub fn snapshot(self: *const Attempt, io: std.Io) Values {
        const first_event_ms = self.firstEventMs();
        const sent = self.sent_at_ms.load(.acquire);
        const cutoff = std.Io.Clock.awake.now(io).toMilliseconds();
        return .{
            .latency_ms = latencyMs(sent, cutoff),
            .first_event_ms = first_event_ms,
        };
    }
};

/// The Host lends live attempt observations to the attempt-ending writer.
/// Backoff uses the pair already saved on the row, not this volatile source.
pub const Source = struct {
    context: ?*anyopaque = null,
    read: ?*const fn (*anyopaque, u64, std.Io) Values = null,

    pub fn snapshot(self: Source, operation: u64, io: std.Io) Values {
        return if (self.read) |read| read(self.context.?, operation, io) else .{};
    }
};
