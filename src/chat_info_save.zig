const std = @import("std");

pub const Effect = enum { idle, configure, refreshing, copy, archive, saved, failed };
pub const Kind = enum { edit, copy, archive };
pub const Event = union(enum) {
    started: Kind,
    worker_done: struct { kind: Kind, ok: bool },
    status_refreshed,
    archive_answered: enum { requested, failed },
    copy_failed,
};
pub const SaveState = enum { idle, pending, saved, failed };
pub const Hold = packed struct { host: bool, upgrade: bool, opening: bool, command: bool, intent: bool };

pub fn step(effect: Effect, event: Event) Effect {
    return switch (event) {
        .started => |kind| switch (kind) {
            .edit => .configure,
            .copy => .copy,
            .archive => .archive,
        },
        .worker_done => |done| switch (done.kind) {
            .edit => if (effect != .configure) effect else if (done.ok) .refreshing else .failed,
            .copy => if (effect != .copy) effect else if (done.ok) .saved else .failed,
            .archive => effect,
        },
        .status_refreshed => if (effect == .refreshing) .saved else effect,
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
    };
}

pub fn maySave(hold: Hold) error{Busy}!void {
    if (hold.host or hold.upgrade or hold.opening or hold.command or hold.intent) return error.Busy;
}

test "chat info save transition table covers every effect and event" {
    // Columns follow Effect declaration order; rows encode the base frontend's decisions.
    const Row = struct { event: Event, expected: [7]Effect };
    const rows = [_]Row{
        .{ .event = .{ .started = .edit }, .expected = @splat(.configure) },
        .{ .event = .{ .started = .copy }, .expected = @splat(.copy) },
        .{ .event = .{ .started = .archive }, .expected = @splat(.archive) },
        .{ .event = .{ .worker_done = .{ .kind = .edit, .ok = true } }, .expected = .{ .idle, .refreshing, .refreshing, .copy, .archive, .saved, .failed } },
        .{ .event = .{ .worker_done = .{ .kind = .edit, .ok = false } }, .expected = .{ .idle, .failed, .refreshing, .copy, .archive, .saved, .failed } },
        .{ .event = .{ .worker_done = .{ .kind = .copy, .ok = true } }, .expected = .{ .idle, .configure, .refreshing, .saved, .archive, .saved, .failed } },
        .{ .event = .{ .worker_done = .{ .kind = .copy, .ok = false } }, .expected = .{ .idle, .configure, .refreshing, .failed, .archive, .saved, .failed } },
        .{ .event = .{ .worker_done = .{ .kind = .archive, .ok = true } }, .expected = .{ .idle, .configure, .refreshing, .copy, .archive, .saved, .failed } },
        .{ .event = .{ .worker_done = .{ .kind = .archive, .ok = false } }, .expected = .{ .idle, .configure, .refreshing, .copy, .archive, .saved, .failed } },
        .{ .event = .status_refreshed, .expected = .{ .idle, .configure, .saved, .copy, .archive, .saved, .failed } },
        .{ .event = .{ .archive_answered = .requested }, .expected = .{ .idle, .configure, .refreshing, .copy, .saved, .saved, .failed } },
        .{ .event = .{ .archive_answered = .failed }, .expected = .{ .idle, .configure, .refreshing, .copy, .failed, .saved, .failed } },
        .{ .event = .copy_failed, .expected = @splat(.failed) },
    };
    for (rows) |row| for (std.enums.values(Effect), 0..) |effect, i| {
        try std.testing.expectEqual(row.expected[i], step(effect, row.event));
    };
    const states = [_]SaveState{ .idle, .pending, .pending, .pending, .pending, .saved, .failed };
    for (std.enums.values(Effect), 0..) |effect, i| try std.testing.expectEqual(states[i], saveState(effect));
}

test "chat info save admission covers all holds" {
    for (0..32) |bits| {
        const hold: Hold = @bitCast(@as(u5, @intCast(bits)));
        if (bits == 0) try maySave(hold) else try std.testing.expectError(error.Busy, maySave(hold));
    }
}
