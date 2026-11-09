//! Where an Upgrade leaves a conversation: whether it holds Host requests,
//! whether the overview may run between frames, what the loop does next
//! and what it says. Values in, decisions out; the shell quiesces Client
//! work, runs the panel and reattaches.

const std = @import("std");

/// How the Upgrade panel closed: nothing installed, the selected Rui speaks
/// this Host's protocol, or it does not.
pub const Outcome = enum { unchanged, compatible, incompatible };

/// What the last Upgrade left: requests open, held until the conversation is
/// read again under the selected Rui, or blocked until /upgrade or a new
/// terminal.
pub const After = enum { open, reobserving, blocked };

/// What the loop does on this pass.
pub const Phase = enum {
    /// Settle Client work, then show the panel.
    quiescing,
    /// Redraw and wait; nothing reaches the Host.
    blocked,
    /// Read the conversation again before anything reaches the Host.
    reobserving,
    active,
};

pub const recovery = "! Host requests paused after Upgrade; draft and original retained. /upgrade or use the selected Rui in a new terminal.";
pub const closed = "Upgrade closed; draft and original retained. No work was resent.";

pub const Upgrade = struct {
    /// /upgrade was asked for and the panel has not yet closed.
    requested: bool = false,
    after: After = .open,

    /// Host requests wait while an Upgrade is asked for or not yet safe.
    pub fn held(self: Upgrade) bool {
        return self.requested or self.after != .open;
    }

    /// The overview runs between frames unless an Upgrade is asked for or
    /// blocked; while reobserving its listing goes on.
    pub fn lends(self: Upgrade) bool {
        return !self.requested and self.after != .blocked;
    }

    pub fn phase(self: Upgrade) Phase {
        if (self.requested) return .quiescing;
        return switch (self.after) {
            .blocked => .blocked,
            .reobserving => .reobserving,
            .open => .active,
        };
    }

    /// The panel closed: a compatible Rui reobserves, an incompatible one
    /// blocks, and an unchanged one leaves what an earlier Upgrade left.
    pub fn close(self: *Upgrade, outcome: Outcome) void {
        self.requested = false;
        switch (outcome) {
            .unchanged => {},
            .compatible => self.after = .reobserving,
            .incompatible => self.after = .blocked,
        }
    }

    /// Settling Client work or reattaching failed: blocked until /upgrade.
    pub fn fail(self: *Upgrade) void {
        self.requested = false;
        self.after = .blocked;
    }

    /// A read settled under the selected Rui. It does not lift a block.
    pub fn reobserved(self: *Upgrade) void {
        if (self.after == .reobserving) self.after = .open;
    }

    /// What the conversation says once the panel closes.
    pub fn notice(self: Upgrade) []const u8 {
        return if (self.after == .blocked) recovery else closed;
    }
};

test "an Upgrade holds Host requests from /upgrade until a read under the selected Rui settles" {
    var upgrade: Upgrade = .{};
    try std.testing.expect(!upgrade.held() and upgrade.lends() and upgrade.phase() == .active);
    upgrade.requested = true;
    try std.testing.expect(upgrade.held() and !upgrade.lends() and upgrade.phase() == .quiescing);
    upgrade.close(.compatible);
    try std.testing.expectEqual(Upgrade{ .after = .reobserving }, upgrade);
    try std.testing.expect(upgrade.held() and upgrade.lends() and upgrade.phase() == .reobserving);
    try std.testing.expectEqualStrings(closed, upgrade.notice());
    upgrade.reobserved();
    try std.testing.expectEqual(Upgrade{}, upgrade);
}

test "a block lasts until another Upgrade, and a settled read does not lift it" {
    var upgrade: Upgrade = .{ .requested = true };
    upgrade.close(.incompatible);
    try std.testing.expectEqual(Upgrade{ .after = .blocked }, upgrade);
    try std.testing.expect(upgrade.held() and !upgrade.lends() and upgrade.phase() == .blocked);
    try std.testing.expectEqualStrings(recovery, upgrade.notice());
    upgrade.reobserved();
    try std.testing.expectEqual(After.blocked, upgrade.after);
    // /upgrade again quiesces first, and an unchanged panel keeps the block.
    upgrade.requested = true;
    try std.testing.expectEqual(Phase.quiescing, upgrade.phase());
    upgrade.close(.unchanged);
    try std.testing.expectEqual(Upgrade{ .after = .blocked }, upgrade);
    upgrade.requested = true;
    upgrade.close(.compatible);
    try std.testing.expectEqual(After.reobserving, upgrade.after);
}

test "an unchanged panel leaves requests open or still reobserving, and a failure blocks" {
    var upgrade: Upgrade = .{ .requested = true };
    upgrade.close(.unchanged);
    try std.testing.expectEqual(Upgrade{}, upgrade);
    upgrade = .{ .requested = true, .after = .reobserving };
    try std.testing.expect(!upgrade.lends());
    upgrade.close(.unchanged);
    try std.testing.expectEqual(Upgrade{ .after = .reobserving }, upgrade);
    upgrade.fail();
    try std.testing.expectEqual(Upgrade{ .after = .blocked }, upgrade);
    upgrade = .{ .requested = true };
    upgrade.fail();
    try std.testing.expectEqual(Upgrade{ .after = .blocked }, upgrade);
}
