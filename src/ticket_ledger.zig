const std = @import("std");

/// Where an Effect's answer lands. One slot per kind of Effect whose answer can
/// arrive after the Model it was issued from has moved on.
pub const Slot = enum { clipboard_paste };

/// What the answer is allowed to do once the slot has moved on.
pub const Class = enum {
    /// A read of something that may have changed; a stale answer is dropped.
    read,
    /// A change the person asked for; it settles exactly once even when stale,
    /// and only where its result is shown may move.
    mutation,
    /// A fact already committed elsewhere; it applies whatever the slot says.
    committed,
};

pub const Verdict = enum { apply, drop, settle_stale };

/// Stamped on an Effect when it leaves the core, and carried back by its answer.
pub const Ticket = struct { slot: Slot, epoch: u64 };

/// One current epoch per slot. An epoch moves only when the thing an answer was
/// asked about is replaced (the paste target changed, the Host restarted), so a
/// ticket with an older epoch names something that no longer exists.
pub const Ledger = struct {
    epochs: [std.enums.values(Slot).len]u64 = @splat(0),

    /// The ticket for a new Effect in this slot.
    pub fn issue(self: *const Ledger, slot: Slot) Ticket {
        return .{ .slot = slot, .epoch = self.epochs[@backingInt(slot)] };
    }

    /// The slot's subject was replaced: every earlier ticket is now stale.
    pub fn supersede(self: *Ledger, slot: Slot) void {
        self.epochs[@backingInt(slot)] +%= 1;
    }

    pub fn admit(self: *const Ledger, ticket: Ticket, class: Class) Verdict {
        if (ticket.epoch == self.epochs[@backingInt(ticket.slot)]) return .apply;
        return switch (class) {
            .read => .drop,
            .mutation => .settle_stale,
            .committed => .apply,
        };
    }
};

test "SUI-200 an answer is judged once by its class: stale reads drop, mutations settle, commits apply, over every slot, epoch relation and wrap" {
    const epochs = [_]u64{ 0, 1, 2, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };
    for (std.enums.values(Slot)) |slot| {
        for (epochs) |current| for (epochs) |stamped| for (std.enums.values(Class)) |class| {
            var ledger: Ledger = .{};
            ledger.epochs[@backingInt(slot)] = current;
            const expected: Verdict = if (stamped == current or class == .committed)
                .apply
            else switch (class) {
                .read => .drop,
                .mutation => .settle_stale,
                .committed => unreachable,
            };
            try std.testing.expectEqual(expected, ledger.admit(.{ .slot = slot, .epoch = stamped }, class));
        };

        var ledger: Ledger = .{};
        const first = ledger.issue(slot);
        try std.testing.expectEqual(Verdict.apply, ledger.admit(first, .read));
        ledger.supersede(slot);
        try std.testing.expectEqual(Verdict.drop, ledger.admit(first, .read));
        try std.testing.expectEqual(Verdict.settle_stale, ledger.admit(first, .mutation));
        try std.testing.expectEqual(Verdict.apply, ledger.admit(ledger.issue(slot), .read));
        ledger.epochs[@backingInt(slot)] = std.math.maxInt(u64);
        const last = ledger.issue(slot);
        ledger.supersede(slot);
        try std.testing.expectEqual(@as(u64, 0), ledger.issue(slot).epoch);
        try std.testing.expectEqual(Verdict.drop, ledger.admit(last, .read));
    }
}
