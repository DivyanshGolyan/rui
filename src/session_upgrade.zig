const std = @import("std");
const upgrade_status = @import("upgrade_status.zig");
const state_marks = @import("marks.zig");

pub const Outcome = upgrade_status.Outcome;

pub const After = enum { open, reobserving, blocked };

pub const Phase = enum {
    quiescing,
    blocked,
    reobserving,
    active,
};

pub const recovery_words = "This window can't continue after the update. Open rui in a new terminal.";
pub const rereading = "Reading this chat…";

pub fn refusal(phase: Phase) state_marks.Say {
    return switch (phase) {
        .quiescing => .attention("Updating; nothing sent."),
        .reobserving => .attention("Reading this chat after the update; nothing sent."),
        .blocked => .attention(recovery_words),
        .active => unreachable,
    };
}

/// An incompatible window cannot continue, so it relaunches whatever guidance remains
/// (the guidance is written first); a compatible one leaves its screen for guidance.
pub fn relaunch(outcome: Outcome, has_guidance: bool) bool {
    return switch (outcome) {
        .unchanged => false,
        .incompatible => true,
        .compatible => !has_guidance,
    };
}

pub const Upgrade = struct {
    available: ?upgrade_status.Version = null,
    run: ?upgrade_status.Run = null,
    after: After = .open,

    pub fn going(self: Upgrade) bool {
        return if (self.run) |run| run.going() else false;
    }

    pub fn held(self: Upgrade) bool {
        return self.going() or self.after != .open;
    }

    pub fn takesEscape(self: Upgrade) bool {
        return if (self.run) |run| run.takesEscape() else false;
    }

    pub fn start(self: *Upgrade) bool {
        if (self.going()) return false;
        self.run = .checking;
        return true;
    }

    pub fn stand(self: *Upgrade, run: upgrade_status.Run) void {
        std.debug.assert(self.going());
        self.run = run;
        if (run == .ended) self.after = switch (run.ended.outcome) {
            .unchanged => if (self.after == .blocked) .blocked else .reobserving,
            .compatible => .reobserving,
            .incompatible => .blocked,
        };
    }

    pub fn block(self: *Upgrade) void {
        self.after = .blocked;
    }

    pub fn reobserved(self: *Upgrade) void {
        if (self.after == .reobserving) self.after = .open;
    }

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

test "an Upgrade holds Host requests from its start until the listing is read under the selected Rui" {
    var upgrade: Upgrade = .{};
    try std.testing.expect(!upgrade.held() and !upgrade.takesEscape() and upgrade.phase(false) == .active);
    try std.testing.expect(upgrade.start());
    try std.testing.expect(upgrade.held() and upgrade.takesEscape() and upgrade.phase(false) == .quiescing);
    upgrade.stand(.{ .installing = .{ .found = .{ .host = .none }, .step = .publishing } });
    try std.testing.expect(!upgrade.start() and upgrade.run.? == .installing and !upgrade.takesEscape());
    upgrade.stand(ended_compatible);
    try std.testing.expect(upgrade.held() and !upgrade.going() and upgrade.phase(false) == .reobserving);
    upgrade.reobserved();
    try std.testing.expect(!upgrade.held());
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
    _ = upgrade.start();
    upgrade.block();
    try std.testing.expectEqual(Phase.quiescing, upgrade.phase(true));
    upgrade.stand(ended_unchanged);
    try std.testing.expectEqual(Phase.blocked, upgrade.phase(true));
}

test "an incompatible outcome always relaunches and a compatible one only without guidance" {
    for (std.enums.values(Outcome)) |outcome| {
        for ([_]bool{ false, true }) |guidance| {
            try std.testing.expectEqual(outcome == .incompatible or (outcome == .compatible and !guidance), relaunch(outcome, guidance));
        }
    }
}
