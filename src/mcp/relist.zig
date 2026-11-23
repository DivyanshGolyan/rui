const std = @import("std");

pub const first_retry_ms: u64 = 1_000;
pub const max_retry_ms: u64 = 300_000;

pub const Outcome = enum { listed, failed, collision };
pub const Last = enum { never, listed, failed, collision };
pub const State = enum { idle, listing, waiting };

pub const Slot = struct {
    state: State = .idle,
    /// Generation of the latest ask. A caller that asked generation g knows its list has landed once `finished >= g`.
    asked: u64 = 0,
    /// The `asked` value captured when the current list began.
    started: u64 = 0,
    /// Every ask up to this generation is answered by a list that began after it.
    finished: u64 = 0,
    failures: u32 = 0,
    retry_at_ms: u64 = 0,
    last: Last = .never,

    /// Records an ask and returns its generation. An ask never waits out a retry backoff.
    pub fn want(self: *Slot) u64 {
        self.asked += 1;
        return self.asked;
    }

    /// True when a list should begin now.
    pub fn due(self: *const Slot, now_ms: u64) bool {
        return switch (self.state) {
            .idle => self.asked > self.finished,
            .listing => false,
            .waiting => self.asked > self.finished or now_ms >= self.retry_at_ms,
        };
    }

    /// Marks a list as begun. Precondition: due().
    pub fn begin(self: *Slot) void {
        self.state = .listing;
        self.started = self.asked;
    }

    /// Records how the list that began ended.
    pub fn end(self: *Slot, outcome: Outcome, now_ms: u64) void {
        self.finished = self.started;
        self.last = switch (outcome) {
            .listed => .listed,
            .failed => .failed,
            .collision => .collision,
        };
        switch (outcome) {
            .listed => {
                self.failures = 0;
                self.state = .idle;
            },
            .failed, .collision => {
                self.failures +|= 1;
                self.state = .waiting;
                self.retry_at_ms = now_ms +| retryDelay(self.failures);
            },
        }
    }

    /// The earliest time this slot needs service again, or null when it needs none until the next ask.
    pub fn wakeAt(self: *const Slot) ?u64 {
        return switch (self.state) {
            .waiting => if (self.asked > self.finished) 0 else self.retry_at_ms,
            .idle => if (self.asked > self.finished) 0 else null,
            .listing => null,
        };
    }
};

fn retryDelay(failures: u32) u64 {
    const doublings = failures - 1;
    if (doublings >= 32) return max_retry_ms;
    return @min(first_retry_ms << @intCast(doublings), max_retry_ms);
}

const Snap = struct {
    state: State,
    asked: u64,
    started: u64,
    finished: u64,
    failures: u32,
    retry_at_ms: u64,
    last: Last,
    due: bool,
    wake: ?u64,
};

fn snap(slot: *const Slot, now_ms: u64) Snap {
    return .{
        .state = slot.state,
        .asked = slot.asked,
        .started = slot.started,
        .finished = slot.finished,
        .failures = slot.failures,
        .retry_at_ms = slot.retry_at_ms,
        .last = slot.last,
        .due = slot.due(now_ms),
        .wake = slot.wakeAt(),
    };
}

fn expectSnap(slot: *const Slot, now_ms: u64, expected: Snap) !void {
    try std.testing.expectEqual(expected, snap(slot, now_ms));
}

test "re-list slots fold asks, answer each ask once and back off failures" {
    var s: Slot = .{};
    try expectSnap(&s, 0, .{ .state = .idle, .asked = 0, .started = 0, .finished = 0, .failures = 0, .retry_at_ms = 0, .last = .never, .due = false, .wake = null });

    // Fresh slot, one ask, then a list that folds an ask arriving while it runs.
    try std.testing.expectEqual(@as(u64, 1), s.want());
    try expectSnap(&s, 0, .{ .state = .idle, .asked = 1, .started = 0, .finished = 0, .failures = 0, .retry_at_ms = 0, .last = .never, .due = true, .wake = 0 });
    s.begin();
    try expectSnap(&s, 0, .{ .state = .listing, .asked = 1, .started = 1, .finished = 0, .failures = 0, .retry_at_ms = 0, .last = .never, .due = false, .wake = null });
    try std.testing.expectEqual(@as(u64, 2), s.want());
    try expectSnap(&s, 0, .{ .state = .listing, .asked = 2, .started = 1, .finished = 0, .failures = 0, .retry_at_ms = 0, .last = .never, .due = false, .wake = null });
    s.end(.listed, 5);
    try expectSnap(&s, 5, .{ .state = .idle, .asked = 2, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0 });
    s.begin();
    s.end(.listed, 6);
    try expectSnap(&s, 6, .{ .state = .idle, .asked = 2, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null });

    // Three asks while listing fold into exactly one more list.
    s.begin();
    _ = s.want();
    _ = s.want();
    try std.testing.expectEqual(@as(u64, 5), s.want());
    try expectSnap(&s, 6, .{ .state = .listing, .asked = 5, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null });
    s.end(.listed, 7);
    try expectSnap(&s, 7, .{ .state = .idle, .asked = 5, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0 });
    s.begin();
    s.end(.listed, 8);
    try expectSnap(&s, 8, .{ .state = .idle, .asked = 5, .started = 5, .finished = 5, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null });

    // First failure waits one second; the slot is not due before its retry time.
    _ = s.want();
    s.begin();
    s.end(.failed, 10);
    try expectSnap(&s, 9, .{ .state = .waiting, .asked = 6, .started = 6, .finished = 6, .failures = 1, .retry_at_ms = 1010, .last = .failed, .due = false, .wake = 1010 });
    try expectSnap(&s, 1010, .{ .state = .waiting, .asked = 6, .started = 6, .finished = 6, .failures = 1, .retry_at_ms = 1010, .last = .failed, .due = true, .wake = 1010 });

    // Delays double from one second and cap at 300 s; each retry waits out its full delay.
    var now: u64 = s.retry_at_ms;
    var failures: u32 = 2;
    while (failures <= 12) : (failures += 1) {
        try std.testing.expect(!s.due(now - 1));
        try std.testing.expect(s.due(now));
        s.begin();
        s.end(.failed, now);
        const delay = @min(first_retry_ms << @intCast(failures - 1), max_retry_ms);
        try std.testing.expectEqual(failures, s.failures);
        try std.testing.expectEqual(now + delay, s.retry_at_ms);
        now = s.retry_at_ms;
    }
    try expectSnap(&s, now - 1, .{ .state = .waiting, .asked = 6, .started = 6, .finished = 6, .failures = 12, .retry_at_ms = now, .last = .failed, .due = false, .wake = now });

    // A success clears the failure count.
    s.begin();
    s.end(.listed, now);
    try expectSnap(&s, now, .{ .state = .idle, .asked = 6, .started = 6, .finished = 6, .failures = 0, .retry_at_ms = now, .last = .listed, .due = false, .wake = null });

    // An ask during backoff is due at once and does not reset failures until a list succeeds.
    _ = s.want();
    s.begin();
    s.end(.failed, 20_000);
    try expectSnap(&s, 20_000, .{ .state = .waiting, .asked = 7, .started = 7, .finished = 7, .failures = 1, .retry_at_ms = 21_000, .last = .failed, .due = false, .wake = 21_000 });
    _ = s.want();
    try expectSnap(&s, 20_000, .{ .state = .waiting, .asked = 8, .started = 7, .finished = 7, .failures = 1, .retry_at_ms = 21_000, .last = .failed, .due = true, .wake = 0 });
    s.begin();
    s.end(.failed, 20_001);
    try expectSnap(&s, 20_001, .{ .state = .waiting, .asked = 8, .started = 8, .finished = 8, .failures = 2, .retry_at_ms = 22_001, .last = .failed, .due = false, .wake = 22_001 });

    // A collision backs off like a failure and reports itself as the last outcome.
    s.begin();
    s.end(.listed, 22_001);
    _ = s.want();
    s.begin();
    s.end(.collision, 30_000);
    try expectSnap(&s, 30_000, .{ .state = .waiting, .asked = 9, .started = 9, .finished = 9, .failures = 1, .retry_at_ms = 31_000, .last = .collision, .due = false, .wake = 31_000 });
    try expectSnap(&s, 31_000, .{ .state = .waiting, .asked = 9, .started = 9, .finished = 9, .failures = 1, .retry_at_ms = 31_000, .last = .collision, .due = true, .wake = 31_000 });

    // The failure count saturates instead of overflowing, and the delay stays at the cap.
    var saturated: Slot = .{ .failures = std.math.maxInt(u32) - 1 };
    _ = saturated.want();
    saturated.begin();
    saturated.end(.failed, 0);
    try expectSnap(&saturated, 0, .{ .state = .waiting, .asked = 1, .started = 1, .finished = 1, .failures = std.math.maxInt(u32), .retry_at_ms = max_retry_ms, .last = .failed, .due = false, .wake = max_retry_ms });
    _ = saturated.want();
    saturated.begin();
    saturated.end(.failed, 0);
    try expectSnap(&saturated, 0, .{ .state = .waiting, .asked = 2, .started = 2, .finished = 2, .failures = std.math.maxInt(u32), .retry_at_ms = max_retry_ms, .last = .failed, .due = false, .wake = max_retry_ms });
}
