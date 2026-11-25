const std = @import("std");

/// `refreshing` and `refreshing_unconfirmed` await a Current read after a Configure that may have reached the Host.
/// The second reports its unconfirmed receipt at once and keeps it once the read lands.
pub const Effect = enum { idle, configure, refreshing, refreshing_unconfirmed, copy, archive, saved, failed, unconfirmed };
pub const Kind = enum { edit, copy, archive };
pub const EditResult = enum { saved, failed, unconfirmed };
pub const Event = union(enum) {
    started: Kind,
    edit_done: EditResult,
    worker_done: struct { kind: enum { copy, archive }, ok: bool },
    receipt_observed,
    status_refreshed,
    archive_answered: enum { requested, failed },
    copy_failed,
};
pub const SaveState = enum { idle, pending, saved, failed, unconfirmed };
pub const Hold = packed struct { host: bool, upgrade: bool, opening: bool, command: bool, intent: bool, saving: bool };

pub fn step(effect: Effect, event: Event) Effect {
    return switch (event) {
        .started => |kind| switch (kind) {
            .edit => .configure,
            .copy => .copy,
            .archive => .archive,
        },
        .edit_done => |result| if (effect != .configure) effect else switch (result) {
            .saved => .refreshing,
            .failed => .failed,
            .unconfirmed => .refreshing_unconfirmed,
        },
        .worker_done => |done| switch (done.kind) {
            .copy => if (effect != .copy) effect else if (done.ok) .saved else .failed,
            .archive => effect,
        },
        .receipt_observed => switch (effect) {
            .idle, .saved, .failed, .unconfirmed => .refreshing,
            else => effect,
        },
        .status_refreshed => switch (effect) {
            .refreshing => .saved,
            .refreshing_unconfirmed => .unconfirmed,
            else => effect,
        },
        .archive_answered => |answer| if (effect != .archive) effect else switch (answer) {
            .requested => .saved,
            .failed => .failed,
        },
        .copy_failed => .failed,
    };
}

pub fn saveState(effect: Effect) SaveState {
    return switch (effect) {
        .idle => .idle,
        .configure, .refreshing, .copy, .archive => .pending,
        .saved => .saved,
        .failed => .failed,
        .refreshing_unconfirmed, .unconfirmed => .unconfirmed,
    };
}

/// A Configure completed that may have changed the Host, and no Current read taken after it has landed.
pub fn awaitingCurrent(effect: Effect) bool {
    return effect == .refreshing or effect == .refreshing_unconfirmed;
}

/// The footer cannot name the model and effort while a Configure is in flight or its Current read is awaited.
pub fn currentUnknown(effect: Effect) bool {
    return effect == .configure or awaitingCurrent(effect);
}

/// A save is in flight or its Current read is awaited; a new save would overwrite the effect that tracks it.
pub fn saving(effect: Effect) bool {
    return awaitingCurrent(effect) or effect == .configure or effect == .copy or effect == .archive;
}

pub fn maySave(hold: Hold) error{Busy}!void {
    if (hold.host or hold.upgrade or hold.opening or hold.command or hold.intent or hold.saving) return error.Busy;
}

test "chat info save transition table covers every effect and event" {
    // Columns follow Effect declaration order; rows encode the base frontend's decisions.
    const Row = struct { event: Event, expected: [9]Effect };
    const rows = [_]Row{
        .{ .event = .{ .started = .edit }, .expected = @splat(.configure) },
        .{ .event = .{ .started = .copy }, .expected = @splat(.copy) },
        .{ .event = .{ .started = .archive }, .expected = @splat(.archive) },
        .{ .event = .{ .edit_done = .saved }, .expected = .{ .idle, .refreshing, .refreshing, .refreshing_unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .edit_done = .failed }, .expected = .{ .idle, .failed, .refreshing, .refreshing_unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .edit_done = .unconfirmed }, .expected = .{ .idle, .refreshing_unconfirmed, .refreshing, .refreshing_unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .worker_done = .{ .kind = .copy, .ok = true } }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .saved, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .worker_done = .{ .kind = .copy, .ok = false } }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .failed, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .worker_done = .{ .kind = .archive, .ok = true } }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .worker_done = .{ .kind = .archive, .ok = false } }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .receipt_observed, .expected = .{ .refreshing, .configure, .refreshing, .refreshing_unconfirmed, .copy, .archive, .refreshing, .refreshing, .refreshing } },
        .{ .event = .status_refreshed, .expected = .{ .idle, .configure, .saved, .unconfirmed, .copy, .archive, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .archive_answered = .requested }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .copy, .saved, .saved, .failed, .unconfirmed } },
        .{ .event = .{ .archive_answered = .failed }, .expected = .{ .idle, .configure, .refreshing, .refreshing_unconfirmed, .copy, .failed, .saved, .failed, .unconfirmed } },
        .{ .event = .copy_failed, .expected = @splat(.failed) },
    };
    for (rows) |row| for (std.enums.values(Effect), 0..) |effect, i| {
        try std.testing.expectEqual(row.expected[i], step(effect, row.event));
    };
    const states = [_]SaveState{ .idle, .pending, .pending, .unconfirmed, .pending, .pending, .saved, .failed, .unconfirmed };
    const awaiting = [_]bool{ false, false, true, true, false, false, false, false, false };
    for (std.enums.values(Effect), 0..) |effect, i| {
        try std.testing.expectEqual(states[i], saveState(effect));
        try std.testing.expectEqual(awaiting[i], awaitingCurrent(effect));
        try std.testing.expectEqual(awaiting[i] or effect == .configure, currentUnknown(effect));
    }
}

test "chat info save admission covers all holds" {
    for (0..64) |bits| {
        const hold: Hold = @bitCast(@as(u6, @intCast(bits)));
        if (bits == 0) try maySave(hold) else try std.testing.expectError(error.Busy, maySave(hold));
    }
}
