const std = @import("std");
const departure = @import("session_departure.zig");
const ReadPhase = departure.ReadPhase;

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

pub const Unavailable = union(enum) { say: []const u8, copy };

pub fn unavailable(phase: ReadPhase, inspection: Inspection) Unavailable {
    return switch (phase) {
        .activity, .fill, .permission => .{ .say = "! Messages unavailable; scroll to retry." },
        .message => .{ .say = "! Message unavailable." },
        .tool => .{ .say = "! Tool output unavailable." },
        .recall => .{ .say = "! Sent message unavailable." },
        .retry => .{ .say = "! Retry unavailable; nothing sent." },
        .inspection => if (inspection == .copy) .copy else .{ .say = "! Inspection unavailable." },
    };
}

pub fn copyFailure(to_file: bool, err: anyerror) []const u8 {
    if (to_file) switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return "! This directory is not writable.",
        else => {},
    };
    return "! Copy unavailable.";
}

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
    try std.testing.expectEqualStrings("! Message unavailable.", unavailable(.message, .other).say);
    try std.testing.expectEqualStrings("! Tool output unavailable.", unavailable(.tool, .other).say);
    try std.testing.expectEqualStrings("! Sent message unavailable.", unavailable(.recall, .other).say);
    try std.testing.expectEqualStrings("! Retry unavailable; nothing sent.", unavailable(.retry, .other).say);
    try std.testing.expectEqualStrings("! Inspection unavailable.", unavailable(.inspection, .command).say);
    try std.testing.expect(unavailable(.inspection, .copy) == .copy);
    try std.testing.expectEqualStrings("! Messages unavailable; scroll to retry.", unavailable(.fill, .copy).say);
    try std.testing.expectEqualStrings("! This directory is not writable.", copyFailure(true, error.ReadOnlyFileSystem));
    try std.testing.expectEqualStrings("! Copy unavailable.", copyFailure(false, error.AccessDenied));
    try std.testing.expectEqualStrings("! Copy unavailable.", copyFailure(true, error.BrokenPipe));
}
