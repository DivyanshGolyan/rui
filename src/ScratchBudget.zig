const std = @import("std");
const ScratchBudget = @This();

used: *std.atomic.Value(u64),
limit: u64,
reclaim_context: ?*anyopaque = null,
reclaim_fn: ?*const fn (*anyopaque, u64, u64) bool = null,
credit: ?*Credit = null,

/// Producer-owned reservation consumed by a capture's ordinary allocations.
/// The owner serializes reserve, allocate and releaseUnused and keeps this
/// object alive until the capture makes its last allocation. Release of a
/// capture's consumed bytes does not access the credit.
pub const Credit = struct {
    base: ScratchBudget,
    unused: u64 = 0,

    pub fn init(base: ScratchBudget) Credit {
        std.debug.assert(base.credit == null);
        return .{ .base = base };
    }

    pub fn reserve(self: *Credit, amount: u64) bool {
        const next = std.math.add(u64, self.unused, amount) catch return false;
        if (!self.base.allocate(amount)) return false;
        self.unused = next;
        return true;
    }

    pub fn budget(self: *Credit) ScratchBudget {
        var result = self.base;
        result.credit = self;
        return result;
    }

    pub fn releaseUnused(self: *Credit) void {
        const amount = self.unused;
        self.unused = 0;
        self.base.release(amount);
    }
};

pub fn narrowed(self: ScratchBudget, limit: u64) ScratchBudget {
    var result = self;
    result.limit = @min(result.limit, limit);
    return result;
}

pub fn allocate(self: ScratchBudget, amount: u64) bool {
    if (self.credit != null) return self.consumeCredit(amount, true);
    return self.charge(amount) or self.reclaim(amount);
}

fn consumeCredit(self: ScratchBudget, amount: u64, allow_reclaim: bool) bool {
    const credit = self.credit.?;
    const base = credit.base.narrowed(self.limit);
    const covered = @min(amount, credit.unused);
    const remainder = amount - covered;
    // Covered credit is already charged. Allocating zero still allows the
    // reclaimer to bring shared usage under a narrowed ceiling.
    if (!(if (allow_reclaim) base.allocate(remainder) else base.charge(remainder))) return false;
    credit.unused -= covered;
    return true;
}

fn reclaim(self: ScratchBudget, amount: u64) bool {
    const reclaim_fn = self.reclaim_fn orelse return false;
    const context = self.reclaim_context orelse return false;
    return reclaim_fn(context, amount, self.limit);
}

pub fn charge(self: ScratchBudget, amount: u64) bool {
    if (self.credit != null) return self.consumeCredit(amount, false);
    if (amount > self.limit) return false;
    var current = self.used.load(.acquire);
    while (true) {
        const next = std.math.add(u64, current, amount) catch return false;
        if (next > self.limit) return false;
        current = self.used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
    }
}

pub fn allocateUpTo(self: ScratchBudget, maximum: u64) u64 {
    const reserved = self.chargeUpTo(maximum);
    if (reserved != 0 or maximum == 0) return reserved;
    if (self.credit != null) return if (self.allocate(1)) 1 else 0;
    return if (self.reclaim(1)) 1 else 0;
}

pub fn chargeUpTo(self: ScratchBudget, maximum: u64) u64 {
    if (self.credit) |credit| {
        if (self.used.load(.acquire) > self.limit) return 0;
        const covered = @min(maximum, credit.unused);
        const additional = credit.base.narrowed(self.limit).chargeUpTo(maximum - covered);
        credit.unused -= covered;
        return covered + additional;
    }
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
            if (budget.charge(1)) _ = accepted.fetchAdd(1, .acq_rel);
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
    try std.testing.expectEqual(@as(u64, 3), budget.chargeUpTo(16));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), budget.chargeUpTo(1));
    budget.release(3);
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
}

test "narrowing a scratch budget cannot widen its authority" {
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expectEqual(@as(u64, 10), budget.narrowed(11).limit);
    try std.testing.expectEqual(@as(u64, 9), budget.narrowed(9).limit);
    used.store(10, .release);
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    try std.testing.expect(!budget.narrowed(9).charge(1));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
}

test "shared usage is baseline-relative and failed growth reserves nothing" {
    var used = std.atomic.Value(u64).init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 100 };
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expect(budget.charge(5));
    try std.testing.expectEqual(@as(u64, 46), used.load(.acquire));
    try std.testing.expect(budget.charge(7));
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    try std.testing.expect(!budget.charge(48));
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    budget.release(12);
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
}

test "only allocation may reclaim and partial allocation preserves charged progress" {
    const Reclaimer = struct {
        used: std.atomic.Value(u64) = .init(9),
        calls: usize = 0,

        fn reclaim(context: *anyopaque, amount: u64, limit: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            _ = self.used.fetchSub(4, .acq_rel);
            return (ScratchBudget{ .used = &self.used, .limit = limit }).charge(amount);
        }
    };
    var owner: Reclaimer = .{};
    const budget: ScratchBudget = .{
        .used = &owner.used,
        .limit = 10,
        .reclaim_context = &owner,
        .reclaim_fn = Reclaimer.reclaim,
    };
    try std.testing.expect(!budget.charge(2));
    try std.testing.expectEqual(@as(u64, 9), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    try std.testing.expect(budget.allocate(3));
    try std.testing.expectEqual(@as(u64, 8), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(u64, 2), budget.allocateUpTo(7));
    try std.testing.expectEqual(@as(u64, 10), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), budget.chargeUpTo(7));
    try std.testing.expectEqual(@as(u64, 0), budget.allocateUpTo(0));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(u64, 1), budget.allocateUpTo(7));
    try std.testing.expectEqual(@as(u64, 7), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), owner.calls);
}

test "capture credit transfers reserved bytes and refunds only unused ownership" {
    var used = std.atomic.Value(u64).init(2);
    const base = ScratchBudget{ .used = &used, .limit = 12 };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(6));
    try std.testing.expectEqual(@as(u64, 8), used.load(.acquire));
    const capture = credit.budget();
    try std.testing.expect(capture.allocate(4));
    try std.testing.expectEqual(@as(u64, 8), used.load(.acquire));
    try std.testing.expect(capture.allocate(4));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    credit.releaseUnused();
    credit.releaseUnused();
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    capture.release(8);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
}

test "capture credit retains reservation on failed allocation and respects narrowing" {
    var used = std.atomic.Value(u64).init(0);
    const base = ScratchBudget{ .used = &used, .limit = 5 };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(4));
    const capture = credit.budget();
    try std.testing.expect(!capture.narrowed(3).allocate(1));
    try std.testing.expect(!capture.allocate(6));
    try std.testing.expectEqual(@as(u64, 4), credit.unused);
    try std.testing.expectEqual(@as(u64, 4), used.load(.acquire));
    try std.testing.expect(capture.allocate(2));
    credit.releaseUnused();
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    capture.release(2);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "capture credit calls base reclaim without recursion" {
    const Owner = struct {
        used: std.atomic.Value(u64) = .init(4),
        calls: usize = 0,
        fn reclaim(context: *anyopaque, amount: u64, limit: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            _ = self.used.fetchSub(2, .acq_rel);
            return (ScratchBudget{ .used = &self.used, .limit = limit }).charge(amount);
        }
    };
    var owner: Owner = .{};
    const base = ScratchBudget{ .used = &owner.used, .limit = 5, .reclaim_context = &owner, .reclaim_fn = Owner.reclaim };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(2));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expect(credit.budget().allocate(3));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    credit.releaseUnused();
    credit.budget().release(3);
    try std.testing.expectEqual(@as(u64, 2), owner.used.load(.acquire));
}

test "credit-backed charge and partial operations consume prepaid capacity" {
    var used = std.atomic.Value(u64).init(0);
    const base = ScratchBudget{ .used = &used, .limit = 5 };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(5));
    const budget = credit.budget();
    try std.testing.expect(!budget.charge(6));
    try std.testing.expectEqual(@as(u64, 5), credit.unused);
    try std.testing.expect(budget.charge(1));
    try std.testing.expectEqual(@as(u64, 2), budget.chargeUpTo(2));
    try std.testing.expectEqual(@as(u64, 2), budget.allocateUpTo(3));
    try std.testing.expectEqual(@as(u64, 5), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), credit.unused);
    try std.testing.expectEqual(@as(u64, 0), budget.allocateUpTo(1));
    budget.release(5);
    credit.releaseUnused();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "narrowed partial credit honors limit and preserves unused credit" {
    var used = std.atomic.Value(u64).init(0);
    const base = ScratchBudget{ .used = &used, .limit = 8 };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(5));
    const narrow = credit.budget().narrowed(4);
    try std.testing.expectEqual(@as(u64, 0), narrow.chargeUpTo(2));
    try std.testing.expectEqual(@as(u64, 0), narrow.allocateUpTo(2));
    try std.testing.expect(!narrow.charge(1));
    try std.testing.expectEqual(@as(u64, 5), credit.unused);
    credit.releaseUnused();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "credit reserves capacity against competing shared allocations" {
    var used = std.atomic.Value(u64).init(0);
    const base = ScratchBudget{ .used = &used, .limit = 10 };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(7));
    try std.testing.expect(base.allocate(3));
    try std.testing.expect(!base.allocate(1));
    try std.testing.expect(credit.budget().allocate(6));
    try std.testing.expectEqual(@as(u64, 10), used.load(.acquire));
    credit.releaseUnused();
    try std.testing.expectEqual(@as(u64, 9), used.load(.acquire));
    base.release(3);
    credit.budget().release(6);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "narrowed credit reclaims excess shared usage without charging credit twice" {
    const Owner = struct {
        used: std.atomic.Value(u64) = .init(0),
        calls: usize = 0,
        fn reclaim(context: *anyopaque, amount: u64, limit: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            _ = self.used.fetchSub(3, .acq_rel);
            return (ScratchBudget{ .used = &self.used, .limit = limit }).charge(amount);
        }
    };
    var owner: Owner = .{};
    const base = ScratchBudget{ .used = &owner.used, .limit = 10, .reclaim_context = &owner, .reclaim_fn = Owner.reclaim };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(4));
    try std.testing.expect(base.charge(4));
    const narrow = credit.budget().narrowed(5);
    try std.testing.expect(narrow.allocate(3));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(u64, 5), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), credit.unused);
    credit.releaseUnused();
    narrow.release(3);
    base.release(1);
    try std.testing.expectEqual(@as(u64, 0), owner.used.load(.acquire));
}

test "narrowed partial allocation reclaims before consuming credit" {
    const Owner = struct {
        used: std.atomic.Value(u64) = .init(0),
        calls: usize = 0,
        fn reclaim(context: *anyopaque, amount: u64, limit: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            _ = self.used.fetchSub(3, .acq_rel);
            return (ScratchBudget{ .used = &self.used, .limit = limit }).charge(amount);
        }
    };
    var owner: Owner = .{};
    const base = ScratchBudget{ .used = &owner.used, .limit = 10, .reclaim_context = &owner, .reclaim_fn = Owner.reclaim };
    var credit = Credit.init(base);
    try std.testing.expect(credit.reserve(4));
    try std.testing.expect(base.charge(4));
    const narrow = credit.budget().narrowed(5);
    try std.testing.expectEqual(@as(u64, 1), narrow.allocateUpTo(3));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    try std.testing.expectEqual(@as(u64, 5), owner.used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), credit.unused);
    credit.releaseUnused();
    narrow.release(1);
    base.release(1);
    try std.testing.expectEqual(@as(u64, 0), owner.used.load(.acquire));
}
