const std = @import("std");
const ScratchBudget = @This();

used: *std.atomic.Value(u64),
limit: u64,
reclaim_context: ?*anyopaque = null,
reclaim_fn: ?*const fn (*anyopaque, u64, u64) bool = null,

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
