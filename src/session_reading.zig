const std = @import("std");
const say_text = @import("testing/say_text.zig");
const departure = @import("session_departure.zig");
const ReadPhase = departure.ReadPhase;
const Say = @import("marks.zig").Say;

pub const scan_interval_ns: i96 = 250_000_000;

pub fn scanDue(now_ns: i96, status_requested: bool) i96 {
    return if (status_requested) 0 else now_ns + scan_interval_ns;
}

pub fn settleMode(upgrade_requested: bool, command_queued: bool) departure.Mode {
    return if (upgrade_requested or command_queued) .inspection else .active;
}

pub const Inspection = enum { copy, command, other };

pub const Shows = enum {
    message,
    recalled,
    retried,
    staged,
    copy,
    page,
    tool,
};

pub fn shows(phase: ReadPhase, inspection: Inspection) Shows {
    return switch (phase) {
        .message => .message,
        .tool => .tool,
        .recall => .recalled,
        .retry => .retried,
        .activity, .fill, .permission => .staged,
        .inspection => if (inspection == .copy) .copy else .page,
    };
}

pub fn commandSettled(completed: bool, phase: ReadPhase) bool {
    return !completed or phase == .inspection;
}

pub const Unavailable = union(enum) { say: Say, copy };

pub fn unavailable(phase: ReadPhase, inspection: Inspection) Unavailable {
    return switch (phase) {
        .activity, .fill, .permission => .{ .say = .attention("Messages unavailable; scroll to retry.") },
        .message => .{ .say = .attention("Message unavailable.") },
        .tool => .{ .say = .attention("Tool output unavailable.") },
        .recall => .{ .say = .attention("Sent message unavailable.") },
        .retry => .{ .say = .attention("Retry unavailable; nothing sent.") },
        .inspection => if (inspection == .copy) .copy else .{ .say = .attention("Inspection unavailable.") },
    };
}

pub fn copyFailure(to_file: bool, err: anyerror) Say {
    if (to_file) switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return .attention("This directory is not writable."),
        else => {},
    };
    return copy_unavailable;
}

pub const copy_unavailable = Say.attention("Copy unavailable.");

pub const Place = enum { feed, elsewhere };

pub const Asked = struct { place: Place, sent: u64, generation: u64 };

pub fn messageShows(asked: Asked, now: Asked) bool {
    return asked.place != .elsewhere and std.meta.eql(asked, now);
}

test "the next scan waits its interval after a read, except for a chat-info capture asked during it" {
    try std.testing.expectEqual(@as(i96, 1_250_000_000), scanDue(1_000_000_000, false));
    try std.testing.expectEqual(@as(i96, 0), scanDue(1_000_000_000, true));
}

test "a Message page shows only over the place, sends and requests it was asked over" {
    const asked: Asked = .{ .place = .feed, .sent = 3, .generation = 7 };
    try std.testing.expect(messageShows(asked, asked));
    const changes = [_]Asked{
        .{ .place = .elsewhere, .sent = 3, .generation = 7 },
        .{ .place = .elsewhere, .sent = 3, .generation = 7 },
        .{ .place = .feed, .sent = 4, .generation = 7 },
        .{ .place = .feed, .sent = 3, .generation = 8 },
    };
    for (changes) |now| try std.testing.expect(!messageShows(asked, now));
    const live: Asked = .{ .place = .feed, .sent = 0, .generation = 0 };
    try std.testing.expect(messageShows(live, live));
    const elsewhere: Asked = .{ .place = .elsewhere, .sent = 0, .generation = 0 };
    try std.testing.expect(!messageShows(elsewhere, elsewhere));
}

test "a pending inspection or Upgrade supersedes the silent read it cancelled" {
    try std.testing.expectEqual(departure.Mode.active, settleMode(false, false));
    try std.testing.expectEqual(departure.Mode.inspection, settleMode(true, false));
    try std.testing.expectEqual(departure.Mode.inspection, settleMode(false, true));
}

test "a completed read shows what its phase read; only /copy's inspection copies" {
    const cases = [_]struct { ReadPhase, Inspection, Shows }{
        .{ .message, .copy, .message },
        .{ .tool, .other, .tool },
        .{ .recall, .other, .recalled },
        .{ .retry, .other, .retried },
        .{ .activity, .other, .staged },
        .{ .fill, .other, .staged },
        .{ .permission, .copy, .staged },
        .{ .inspection, .copy, .copy },
        .{ .inspection, .command, .page },
    };
    for (cases) |case| try std.testing.expectEqual(case[2], shows(case[0], case[1]));
}

test "a command's output settles when its page shows or its read ends early, never with a live or older page" {
    for (std.enums.values(ReadPhase)) |phase| {
        try std.testing.expect(commandSettled(false, phase));
        try std.testing.expectEqual(phase == .inspection, commandSettled(true, phase));
    }
}

test "a read that failed while preparing says which page is unavailable" {
    try say_text.expect("! Message unavailable.", unavailable(.message, .other).say);
    try say_text.expect("! Tool output unavailable.", unavailable(.tool, .other).say);
    try say_text.expect("! Sent message unavailable.", unavailable(.recall, .other).say);
    try say_text.expect("! Retry unavailable; nothing sent.", unavailable(.retry, .other).say);
    try say_text.expect("! Inspection unavailable.", unavailable(.inspection, .command).say);
    try std.testing.expect(unavailable(.inspection, .copy) == .copy);
    try say_text.expect("! Messages unavailable; scroll to retry.", unavailable(.fill, .copy).say);
    try say_text.expect("! This directory is not writable.", copyFailure(true, error.ReadOnlyFileSystem));
    try say_text.expect("! Copy unavailable.", copyFailure(false, error.AccessDenied));
    try say_text.expect("! Copy unavailable.", copyFailure(true, error.BrokenPipe));
}
