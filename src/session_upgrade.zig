//! The Upgrade, as the overview and a conversation both read it: the run
//! /upgrade started, what the last run left Host requests, and from those
//! alone whether requests wait, whose Esc is, and what a conversation's
//! loop does next. Values in, decisions out; the overview owns the one
//! value, its worker says where the run stands, and a conversation reads it.

const std = @import("std");
const upgrade_status = @import("upgrade_status.zig");

/// How a run ended: nothing installed, the selected Rui speaks this Host's
/// protocol, or it does not.
pub const Outcome = upgrade_status.Outcome;

/// What the last Upgrade left: requests open, held until the listing is
/// read again under the selected Rui, or blocked until /upgrade or a new
/// terminal.
pub const After = enum { open, reobserving, blocked };

/// What a conversation's loop does on this pass.
pub const Phase = enum {
    /// Settle Client work so the run can start, then wait for its end.
    quiescing,
    /// Redraw and wait; nothing reaches the Host.
    blocked,
    /// Read the conversation again before anything reaches the Host.
    reobserving,
    active,
};

pub const recovery = "! Host requests paused after Upgrade; draft and original retained. /upgrade or use the selected Rui in a new terminal.";
/// What a conversation's status row says while it reads itself again.
pub const rereading = "Reading this Session again after the Upgrade…";

/// What a conversation says of a Host request a hold refused.
pub fn refusal(phase: Phase) []const u8 {
    return switch (phase) {
        .quiescing => "! Upgrade running; nothing sent. Draft and original retained.",
        .reobserving => "! Reading this Session again after the Upgrade; nothing sent. Draft and original retained.",
        .blocked => recovery,
        .active => unreachable, // Nothing holds.
    };
}

pub const Upgrade = struct {
    /// The run /upgrade started, as its worker last said it stands; null
    /// before the first.
    run: ?upgrade_status.Run = null,
    after: After = .open,

    /// The run has not ended: its worker runs once Client work has settled.
    pub fn going(self: Upgrade) bool {
        return if (self.run) |run| run.going() else false;
    }

    /// Host requests wait: a run goes on, or the last one left them held.
    pub fn held(self: Upgrade) bool {
        return self.going() or self.after != .open;
    }

    /// Esc is the run's: it can still change nothing.
    pub fn takesEscape(self: Upgrade) bool {
        return if (self.run) |run| run.takesEscape() else false;
    }

    /// /upgrade checks at once. False while a run goes on, which keeps its
    /// progress and its Esc.
    pub fn start(self: *Upgrade) bool {
        if (self.going()) return false;
        self.run = .checking;
        return true;
    }

    /// The worker said where the run stands. Its end leaves Host requests
    /// what its outcome says: an unchanged one keeps a block, and unless
    /// blocked the listing is read again first.
    pub fn stand(self: *Upgrade, run: upgrade_status.Run) void {
        std.debug.assert(self.going());
        self.run = run;
        if (run == .ended) self.after = switch (run.ended.outcome) {
            .unchanged => if (self.after == .blocked) .blocked else .reobserving,
            .compatible => .reobserving,
            .incompatible => .blocked,
        };
    }

    /// A conversation could not settle its Client work for the run, or
    /// read itself again after it: blocked until /upgrade.
    pub fn block(self: *Upgrade) void {
        self.after = .blocked;
    }

    /// The listing was read under the selected Rui. It does not lift a block.
    pub fn reobserved(self: *Upgrade) void {
        if (self.after == .reobserving) self.after = .open;
    }

    /// A conversation's pass. `stale` says its own reading of the Session
    /// predates a run, so it reads again whatever the listing has done.
    pub fn phase(self: Upgrade, stale: bool) Phase {
        if (self.going()) return .quiescing;
        return switch (self.after) {
            .blocked => .blocked,
            .reobserving => .reobserving,
            .open => if (stale) .reobserving else .active,
        };
    }
};

const ended_unchanged: upgrade_status.Run = .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } };
const ended_compatible: upgrade_status.Run = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 61, .patch = 0 }, .restarted = true } }, .outcome = .compatible } };
const ended_incompatible: upgrade_status.Run = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 61, .patch = 0 } }, .outcome = .incompatible } };

test "an Upgrade holds Host requests from /upgrade until the listing is read under the selected Rui" {
    var upgrade: Upgrade = .{};
    try std.testing.expect(!upgrade.held() and !upgrade.takesEscape() and upgrade.phase(false) == .active);
    try std.testing.expect(upgrade.start());
    try std.testing.expect(upgrade.held() and upgrade.takesEscape() and upgrade.phase(false) == .quiescing);
    // The run going on keeps its progress: another /upgrade starts nothing.
    upgrade.stand(.{ .installing = .{ .found = .{ .version = .{ .schema = 61, .patch = 0 }, .host = .none }, .step = .publishing } });
    try std.testing.expect(!upgrade.start() and upgrade.run.? == .installing and !upgrade.takesEscape());
    upgrade.stand(ended_compatible);
    try std.testing.expect(upgrade.held() and !upgrade.going() and upgrade.phase(false) == .reobserving);
    upgrade.reobserved();
    try std.testing.expect(!upgrade.held());
    // A conversation whose reading predates the run reads again all the same.
    try std.testing.expectEqual(Phase.reobserving, upgrade.phase(true));
    try std.testing.expectEqual(Phase.active, upgrade.phase(false));
}

test "a block lasts until another Upgrade, and a listing does not lift it" {
    var upgrade: Upgrade = .{};
    _ = upgrade.start();
    upgrade.stand(ended_incompatible);
    try std.testing.expect(upgrade.held() and upgrade.phase(false) == .blocked and upgrade.phase(true) == .blocked);
    upgrade.reobserved();
    try std.testing.expectEqual(After.blocked, upgrade.after);
    // /upgrade again quiesces first, and an unchanged run keeps the block.
    try std.testing.expect(upgrade.start());
    try std.testing.expectEqual(Phase.quiescing, upgrade.phase(false));
    upgrade.stand(ended_unchanged);
    try std.testing.expectEqual(After.blocked, upgrade.after);
    _ = upgrade.start();
    upgrade.stand(ended_compatible);
    try std.testing.expectEqual(After.reobserving, upgrade.after);
}

test "an unchanged run reads the listing again, and a conversation's failure blocks" {
    var upgrade: Upgrade = .{};
    _ = upgrade.start();
    upgrade.stand(ended_unchanged);
    try std.testing.expectEqual(After.reobserving, upgrade.after);
    upgrade.reobserved();
    try std.testing.expectEqual(After.open, upgrade.after);
    // A block made while the run goes on outlasts its unchanged end.
    _ = upgrade.start();
    upgrade.block();
    try std.testing.expectEqual(Phase.quiescing, upgrade.phase(true));
    upgrade.stand(ended_unchanged);
    try std.testing.expectEqual(Phase.blocked, upgrade.phase(true));
}
