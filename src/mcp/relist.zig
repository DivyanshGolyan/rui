const std = @import("std");

pub const first_retry_ms: u64 = 1_000;
pub const max_retry_ms: u64 = 300_000;
/// A server's ttlMs shorter than this is raised to it, so a server cannot drive a list per second.
pub const ttl_floor_ms: u64 = 60_000;
/// The most a ttl deadline is pushed back by jitter.
pub const max_jitter_ms: u64 = 30_000;

/// What a list that landed says about its freshness. `ttl_ms` is the smallest positive ttlMs over its
/// pages, or null when no page carried a positive integer one (absent, 0, negative, non-integer or out of range): no timer.
pub const Listed = struct { ttl_ms: ?u64, seed: u64 };
pub const Outcome = union(enum) { listed: Listed, failed };
pub const Last = enum { never, listed, failed };
pub const State = enum { idle, listing, waiting };

/// One server's status as intake threads read it (published by the owner, see server_mcp_relist.zig).
pub const Status = struct {
    state: State,
    last: Last,
    /// Generation of the latest list that has landed (see `Slot.finished`).
    finished: u64,
    /// MCP tool records this server owns in the set last published.
    tools: u32,
    /// Tools the server listed that were left out of the offered set (see offered.zig).
    left_out: u32,
};

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
    /// Awake-clock ms at which the kept list goes stale and a list is due without an ask. Null: no timer.
    /// Set only by `end(.listed)`; cleared by `begin` and by `end(.failed)`, where backoff owns the retry.
    stale_at_ms: ?u64 = null,

    /// Records an ask and returns its generation. An ask never waits out a retry backoff.
    pub fn want(self: *Slot) u64 {
        self.asked += 1;
        return self.asked;
    }

    /// True when a list should begin now.
    pub fn due(self: *const Slot, now_ms: u64) bool {
        return switch (self.state) {
            .idle => self.asked > self.finished or self.isStale(now_ms),
            .listing => false,
            .waiting => self.asked > self.finished or now_ms >= self.retry_at_ms,
        };
    }

    /// What happened to a slot: a list began, or the list that began ended with `outcome` at `now_ms`.
    pub const Event = union(enum) {
        begin,
        end: struct { outcome: Outcome, now_ms: u64 },
    };

    /// Marks a list as begun. Precondition: due().
    pub fn begin(self: *Slot) void {
        self.apply(.begin);
    }

    /// Records how the list that began ended.
    pub fn end(self: *Slot, outcome: Outcome, now_ms: u64) void {
        self.apply(.{ .end = .{ .outcome = outcome, .now_ms = now_ms } });
    }

    /// The one decision table for a slot: the next `state` and every field that moves with it.
    /// Each event leads to the same state from every state, so no event is refused.
    pub fn apply(self: *Slot, event: Event) void {
        switch (event) {
            .begin => {
                self.state = .listing;
                self.started = self.asked;
                self.stale_at_ms = null;
            },
            .end => |ending| {
                self.finished = self.started;
                self.last = switch (ending.outcome) {
                    .listed => .listed,
                    .failed => .failed,
                };
                switch (ending.outcome) {
                    .listed => |listed| {
                        self.failures = 0;
                        self.state = .idle;
                        self.stale_at_ms = staleAt(ending.now_ms, listed.ttl_ms, listed.seed);
                    },
                    .failed => {
                        self.failures +|= 1;
                        self.state = .waiting;
                        self.stale_at_ms = null;
                        self.retry_at_ms = ending.now_ms +| retryDelay(self.failures);
                    },
                }
            },
        }
    }

    /// The earliest time this slot needs service again, or null when it needs none until the next ask.
    pub fn wakeAt(self: *const Slot) ?u64 {
        return switch (self.state) {
            .waiting => if (self.asked > self.finished) 0 else self.retry_at_ms,
            .idle => if (self.asked > self.finished) 0 else self.stale_at_ms,
            .listing => null,
        };
    }

    fn isStale(self: *const Slot, now_ms: u64) bool {
        const at = self.stale_at_ms orelse return false;
        return now_ms >= at;
    }
};

/// The time a list that landed at `now_ms` goes stale: `max(ttl, ttl_floor_ms)` later, plus the jitter
/// `jittered` adds. Null when the list carried no positive ttl.
pub fn staleAt(now_ms: u64, ttl_ms: ?u64, seed: u64) ?u64 {
    const ttl = ttl_ms orelse return null;
    if (ttl == 0) return null;
    return now_ms +| jittered(@max(ttl, ttl_floor_ms), seed);
}

/// Spreads `delay_ms` by up to a tenth of it, at most `max_jitter_ms`, chosen from `seed`. Saturates.
pub fn jittered(delay_ms: u64, seed: u64) u64 {
    const spread = @min(delay_ms / 10, max_jitter_ms);
    return delay_ms +| splitmix64(seed) % (spread + 1);
}

/// The seed of one list's jitter: deterministic in the Host's seed, the server's index, the list's generation
/// (`Slot.started`) and the awake-clock ms it landed at. The generation alone repeats across ttl cycles that
/// no ask folds into, so the landing time is what makes each cycle draw its own offset.
pub fn mix(host_seed: u64, index: usize, generation: u64, landed_ms: u64) u64 {
    return splitmix64(splitmix64(splitmix64(host_seed ^ splitmix64(index)) ^ generation) ^ landed_ms);
}

fn splitmix64(input: u64) u64 {
    var z = input +% 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// The one backoff formula: 1 s doubling per failure, capped at 300 s. `failures` is at least 1.
pub fn retryDelay(failures: u32) u64 {
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
    stale_at_ms: ?u64 = null,
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
        .stale_at_ms = slot.stale_at_ms,
    };
}

fn expectSnap(slot: *const Slot, now_ms: u64, expected: Snap) !void {
    try std.testing.expectEqual(expected, snap(slot, now_ms));
}

const listed_plain: Outcome = .{ .listed = .{ .ttl_ms = null, .seed = 0 } };

const Base = enum { fresh, listing, waiting };

/// A slot with one ask (generation 1) in each base state, reached only through the public verbs.
fn reach(base: Base) Slot {
    var s: Slot = .{};
    _ = s.want();
    switch (base) {
        .fresh => {},
        .listing => s.begin(),
        .waiting => {
            s.begin();
            s.end(.failed, 100);
        },
    }
    return s;
}

test "EXR-104 a re-list slot moves through every state x event as its rules say" {
    const now_ms: u64 = 5_000;
    const Row = struct {
        from: Base,
        event: Slot.Event,
        state: State,
        last: Last,
        started: u64,
        finished: u64,
        failures: u32,
        retry_at_ms: u64,
        stale_at_ms: ?u64,
    };
    // Every base has asked once (asked stays 1). A failed end at now_ms backs off by retryDelay(failures
    // after the end); a listed end without a ttl sets no timer. `waiting` reaches failures 1 at 100 ms,
    // so its retry_at_ms before any event is 1100.
    const rows = [_]Row{
        .{ .from = .fresh, .event = .begin, .state = .listing, .last = .never, .started = 1, .finished = 0, .failures = 0, .retry_at_ms = 0, .stale_at_ms = null },
        .{ .from = .fresh, .event = .{ .end = .{ .outcome = listed_plain, .now_ms = now_ms } }, .state = .idle, .last = .listed, .started = 0, .finished = 0, .failures = 0, .retry_at_ms = 0, .stale_at_ms = null },
        .{ .from = .fresh, .event = .{ .end = .{ .outcome = .failed, .now_ms = now_ms } }, .state = .waiting, .last = .failed, .started = 0, .finished = 0, .failures = 1, .retry_at_ms = 6_000, .stale_at_ms = null },
        .{ .from = .listing, .event = .begin, .state = .listing, .last = .never, .started = 1, .finished = 0, .failures = 0, .retry_at_ms = 0, .stale_at_ms = null },
        .{ .from = .listing, .event = .{ .end = .{ .outcome = listed_plain, .now_ms = now_ms } }, .state = .idle, .last = .listed, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 0, .stale_at_ms = null },
        .{ .from = .listing, .event = .{ .end = .{ .outcome = .failed, .now_ms = now_ms } }, .state = .waiting, .last = .failed, .started = 1, .finished = 1, .failures = 1, .retry_at_ms = 6_000, .stale_at_ms = null },
        .{ .from = .waiting, .event = .begin, .state = .listing, .last = .failed, .started = 1, .finished = 1, .failures = 1, .retry_at_ms = 1_100, .stale_at_ms = null },
        .{ .from = .waiting, .event = .{ .end = .{ .outcome = listed_plain, .now_ms = now_ms } }, .state = .idle, .last = .listed, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 1_100, .stale_at_ms = null },
        .{ .from = .waiting, .event = .{ .end = .{ .outcome = .failed, .now_ms = now_ms } }, .state = .waiting, .last = .failed, .started = 1, .finished = 1, .failures = 2, .retry_at_ms = 7_000, .stale_at_ms = null },
    };
    for (rows) |row| {
        var s = reach(row.from);
        s.apply(row.event);
        errdefer std.debug.print("from {s} event {s}\n", .{ @tagName(row.from), @tagName(row.event) });
        try std.testing.expectEqual(row.state, s.state);
        try std.testing.expectEqual(row.last, s.last);
        try std.testing.expectEqual(@as(u64, 1), s.asked);
        try std.testing.expectEqual(row.started, s.started);
        try std.testing.expectEqual(row.finished, s.finished);
        try std.testing.expectEqual(row.failures, s.failures);
        try std.testing.expectEqual(row.retry_at_ms, s.retry_at_ms);
        try std.testing.expectEqual(row.stale_at_ms, s.stale_at_ms);
    }
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
    s.end(listed_plain, 5);
    try expectSnap(&s, 5, .{ .state = .idle, .asked = 2, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0 });
    s.begin();
    s.end(listed_plain, 6);
    try expectSnap(&s, 6, .{ .state = .idle, .asked = 2, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null });

    // Three asks while listing fold into exactly one more list.
    s.begin();
    _ = s.want();
    _ = s.want();
    try std.testing.expectEqual(@as(u64, 5), s.want());
    try expectSnap(&s, 6, .{ .state = .listing, .asked = 5, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null });
    s.end(listed_plain, 7);
    try expectSnap(&s, 7, .{ .state = .idle, .asked = 5, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0 });
    s.begin();
    s.end(listed_plain, 8);
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
    s.end(listed_plain, now);
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

    s.begin();
    s.end(listed_plain, 22_001);

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

test "re-list slots carry the ttl deadline through asks, folds, failures and successes" {
    var s: Slot = .{};
    _ = s.want();
    s.begin();
    s.end(listedWith(120_000), 0);
    const first = s.stale_at_ms.?;
    try std.testing.expect(first >= 120_000 and first <= 132_000);
    // An ask while idle with a deadline set is due at once; the deadline stays until the list begins.
    try expectSnap(&s, 0, .{ .state = .idle, .asked = 1, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = first, .stale_at_ms = first });
    _ = s.want();
    try expectSnap(&s, 0, .{ .state = .idle, .asked = 2, .started = 1, .finished = 1, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0, .stale_at_ms = first });

    // A fold during a list that the deadline started: beginning clears the deadline, and the ask made mid-list folds into one more list.
    s.begin();
    _ = s.want();
    try expectSnap(&s, 0, .{ .state = .listing, .asked = 3, .started = 2, .finished = 1, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = null, .stale_at_ms = null });
    s.end(listedWith(120_000), 50_000);
    const second = s.stale_at_ms.?;
    try std.testing.expect(second >= 170_000 and second <= 182_000);
    try expectSnap(&s, 50_000, .{ .state = .idle, .asked = 3, .started = 2, .finished = 2, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = true, .wake = 0, .stale_at_ms = second });
    s.begin();
    s.end(listedWith(120_000), 60_000);
    const third = s.stale_at_ms.?;
    try expectSnap(&s, 60_000, .{ .state = .idle, .asked = 3, .started = 3, .finished = 3, .failures = 0, .retry_at_ms = 0, .last = .listed, .due = false, .wake = third, .stale_at_ms = third });
    try std.testing.expect(!s.due(third - 1));
    try std.testing.expect(s.due(third));

    // A failed list clears the deadline and backoff owns the retry; the retry is due at its time and not before.
    _ = s.want();
    s.begin();
    s.end(.failed, 200_000);
    try expectSnap(&s, 200_000, .{ .state = .waiting, .asked = 4, .started = 4, .finished = 4, .failures = 1, .retry_at_ms = 201_000, .last = .failed, .due = false, .wake = 201_000, .stale_at_ms = null });
    try expectSnap(&s, 201_000, .{ .state = .waiting, .asked = 4, .started = 4, .finished = 4, .failures = 1, .retry_at_ms = 201_000, .last = .failed, .due = true, .wake = 201_000, .stale_at_ms = null });

    // The retry lands: the failure count clears and a new deadline is set from the landing time.
    s.begin();
    s.end(listedWith(120_000), 201_000);
    const fourth = s.stale_at_ms.?;
    try expectSnap(&s, 201_000, .{ .state = .idle, .asked = 4, .started = 4, .finished = 4, .failures = 0, .retry_at_ms = 201_000, .last = .listed, .due = false, .wake = fourth, .stale_at_ms = fourth });

    // A begun list that ends as a failure (the shell does this when Pending.start returns null or a publish fails)
    // leaves no deadline, so backoff owns the retry.
    _ = s.want();
    s.begin();
    s.end(.failed, 300_000);
    try expectSnap(&s, 300_000, .{ .state = .waiting, .asked = 5, .started = 5, .finished = 5, .failures = 1, .retry_at_ms = 301_000, .last = .failed, .due = false, .wake = 301_000, .stale_at_ms = null });
}

fn listedWith(ttl_ms: ?u64) Outcome {
    return .{ .listed = .{ .ttl_ms = ttl_ms, .seed = 7 } };
}

fn landAt(slot: *Slot, outcome: Outcome, now_ms: u64) void {
    _ = slot.want();
    slot.begin();
    slot.end(outcome, now_ms);
}

test "EXR-70 a list with a ttl goes stale at its deadline; a list without one never does" {
    const huge = std.math.maxInt(u64);
    const cases = [_]struct { ttl: ?u64, base: u64 }{
        .{ .ttl = null, .base = 0 },
        .{ .ttl = 0, .base = 0 },
        .{ .ttl = 1, .base = ttl_floor_ms },
        .{ .ttl = ttl_floor_ms - 1, .base = ttl_floor_ms },
        .{ .ttl = 120_000, .base = 120_000 },
        .{ .ttl = huge, .base = huge },
    };
    for (cases) |case| {
        var slot: Slot = .{};
        landAt(&slot, listedWith(case.ttl), 1_000);
        if (case.base == 0) {
            try std.testing.expectEqual(@as(?u64, null), slot.stale_at_ms);
            try std.testing.expectEqual(@as(?u64, null), slot.wakeAt());
            try std.testing.expect(!slot.due(huge));
            continue;
        }
        const at = slot.stale_at_ms.?;
        const spread = @min(case.base / 10, max_jitter_ms);
        // Within [landed + base, landed + base + spread], saturating at the top of u64.
        try std.testing.expect(at >= @min(1_000 +| case.base, huge));
        try std.testing.expect(at <= @min(1_000 +| case.base +| spread, huge));
        try std.testing.expectEqual(@as(?u64, at), slot.wakeAt());
        if (at > 0) {
            try std.testing.expect(!slot.due(at - 1));
        }
        try std.testing.expect(slot.due(at));
        try std.testing.expect(slot.due(huge));
    }
}

test "EXR-70 a stale list is due at its deadline, not before, and a failed or begun list clears the timer" {
    var slot: Slot = .{};
    landAt(&slot, listedWith(120_000), 0);
    const at = slot.stale_at_ms.?;
    try std.testing.expect(!slot.due(at - 1));
    try std.testing.expect(slot.due(at));
    try std.testing.expectEqual(@as(?u64, at), slot.wakeAt());

    // A stale list that begins again clears its timer until the next list lands.
    slot.begin();
    try std.testing.expectEqual(@as(?u64, null), slot.stale_at_ms);
    slot.end(listedWith(120_000), at);
    const again = slot.stale_at_ms.?;
    try std.testing.expect(again > at);

    // A failed list clears the timer: backoff owns the retry.
    _ = slot.want();
    slot.begin();
    slot.end(.failed, again);
    try std.testing.expectEqual(@as(?u64, null), slot.stale_at_ms);
    try std.testing.expectEqual(@as(?u64, again + first_retry_ms), slot.wakeAt());
}

test "EXR-70 a stale deadline saturates at the top of u64" {
    var slot: Slot = .{};
    landAt(&slot, listedWith(std.math.maxInt(u64)), std.math.maxInt(u64));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), slot.stale_at_ms);
    try std.testing.expect(!slot.due(std.math.maxInt(u64) - 1));
    try std.testing.expect(slot.due(std.math.maxInt(u64)));
}

test "EXR-70 staleAt stays within its bounds for every seed and is deterministic per seed" {
    var seed: u64 = 1;
    var jittered_once = false;
    for (0..2_000) |_| {
        seed = splitmix64(seed);
        const ttl = seed % 1_000_000_000 + 1;
        const now = splitmix64(seed) % 1_000_000_000_000;
        const base = @max(ttl, ttl_floor_ms);
        const spread = @min(base / 10, max_jitter_ms);
        const at = staleAt(now, ttl, seed).?;
        try std.testing.expect(at >= now + base);
        try std.testing.expect(at <= now + base + spread);
        try std.testing.expectEqual(at, staleAt(now, ttl, seed).?);
        jittered_once = jittered_once or at > now + base;
    }
    try std.testing.expect(jittered_once);
    try std.testing.expectEqual(@as(?u64, null), staleAt(0, null, 1));
    try std.testing.expectEqual(@as(?u64, null), staleAt(0, 0, 1));
}

test "EXR-70 mix and jittered are deterministic and differ across their inputs" {
    try std.testing.expectEqual(mix(9, 2, 3, 40), mix(9, 2, 3, 40));
    try std.testing.expect(mix(9, 2, 3, 40) != mix(9, 3, 3, 40));
    try std.testing.expect(mix(9, 2, 3, 40) != mix(9, 2, 4, 40));
    try std.testing.expect(mix(9, 2, 3, 40) != mix(10, 2, 3, 40));
    try std.testing.expect(mix(9, 2, 3, 40) != mix(9, 2, 3, 41));
    try std.testing.expect(jittered(100_000, 5) <= 110_000);
    try std.testing.expect(jittered(100_000, 5) >= 100_000);
}
