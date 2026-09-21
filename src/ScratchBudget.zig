const std = @import("std");
const ScratchBudget = @This();

used: *std.atomic.Value(u64),
limit: u64,
reclaim_context: ?*anyopaque = null,
reclaim_fn: ?*const fn (*anyopaque, u64, u64) bool = null,

pub fn narrowed(self: ScratchBudget, limit: u64) ScratchBudget {
    var result = self;
    result.limit = @min(result.limit, limit);
    return result;
}

pub fn reserve(self: ScratchBudget, amount: u64) bool {
    if (self.reserveWithoutReclaim(amount)) return true;
    const reclaim = self.reclaim_fn orelse return false;
    const context = self.reclaim_context orelse return false;
    return reclaim(context, amount, self.limit);
}

pub fn reserveWithoutReclaim(self: ScratchBudget, amount: u64) bool {
    if (amount > self.limit) return false;
    var current = self.used.load(.acquire);
    while (true) {
        const next = std.math.add(u64, current, amount) catch return false;
        if (next > self.limit) return false;
        current = self.used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
    }
}

pub fn reserveUpTo(self: ScratchBudget, maximum: u64) u64 {
    const reserved = self.reserveUpToWithoutReclaim(maximum);
    if (reserved != 0 or maximum == 0) return reserved;
    const reclaim = self.reclaim_fn orelse return 0;
    const context = self.reclaim_context orelse return 0;
    return if (reclaim(context, 1, self.limit)) 1 else 0;
}

pub fn reserveUpToWithoutReclaim(self: ScratchBudget, maximum: u64) u64 {
    var current = self.used.load(.acquire);
    while (current < self.limit and maximum != 0) {
        const amount = @min(maximum, self.limit - current);
        const next = current + amount;
        current = self.used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return amount;
    }
    return 0;
}

pub fn release(self: ScratchBudget, amount: u64) void {
    const prior = self.used.fetchSub(amount, .acq_rel);
    std.debug.assert(prior >= amount);
}

test "concurrent scratch reservations share one ceiling" {
    const Worker = struct {
        fn run(budget: ScratchBudget, accepted: *std.atomic.Value(u64)) void {
            if (budget.reserve(1)) _ = accepted.fetchAdd(1, .acq_rel);
        }
    };
    var used = std.atomic.Value(u64).init(0);
    var accepted = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 3 };
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ budget, &accepted });
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expectEqual(@as(u64, 3), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    budget.release(3);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "partial scratch reservation owns only available capacity" {
    var used = std.atomic.Value(u64).init(7);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expectEqual(@as(u64, 3), budget.reserveUpTo(16));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), budget.reserveUpTo(1));
    budget.release(3);
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
}

test "narrowing a scratch budget cannot widen its authority" {
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expectEqual(@as(u64, 10), budget.narrowed(11).limit);
    try std.testing.expectEqual(@as(u64, 9), budget.narrowed(9).limit);
    // A narrowed view limits only its own admission: unrelated usage may
    // already exceed the narrowed limit, so no invariant requires
    // used <= narrowed.limit.
    used.store(10, .release);
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    try std.testing.expect(!budget.narrowed(9).reserve(1));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
}

test "shared usage is baseline-relative and failed growth reserves nothing" {
    // Budget arithmetic only: reserve/release totals on an unrelated
    // baseline. The reserve-before-failed-write obligation is established
    // beside the real RequestWriter (see "request writer failure retains
    // the full reservation until the owner releases").
    // Unrelated reservation B = 41 stays unchanged through the lifecycle.
    // A writer reserves 5 bytes successfully, then reserves 7 more bytes
    // for a write that fails after charging: the outstanding contribution
    // is 12 reserved bytes, not 5 written bytes.
    var used = std.atomic.Value(u64).init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 100 };
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expect(budget.reserve(5));
    try std.testing.expectEqual(@as(u64, 46), used.load(.acquire));
    try std.testing.expect(budget.reserve(7));
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    // Rejected growth changes neither usage nor ownership.
    try std.testing.expect(!budget.reserve(48));
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    budget.release(12);
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
}
