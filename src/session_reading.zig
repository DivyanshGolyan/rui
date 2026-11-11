//! The conversation's one reader, decided over values its frontend read:
//! which read an idle reader starts, when the next scan is due, what a
//! settled read shows or says, and whether a page a read brings still shows.
//! `SessionFrontend` reads the clock, the screen and the input, and starts,
//! joins and shows what these decide.
const std = @import("std");
const departure = @import("session_departure.zig");
const ReadPhase = departure.ReadPhase;

/// How long after a read is applied the next scan waits.
pub const scan_interval_ns: i96 = 250_000_000;

/// When the next scan may start, once a read is applied at `now_ns`: at
/// once for a /status asked for during that read, which is the next read's.
pub fn scanDue(now_ns: i96, status_requested: bool) i96 {
    return if (status_requested) 0 else now_ns + scan_interval_ns;
}

/// How a joined read's failure counts: a pending inspection, or an Upgrade
/// asked for, supersedes a silent read it cancelled.
pub fn settleMode(upgrade_requested: bool, command_queued: bool) departure.Mode {
    return if (upgrade_requested or command_queued) .inspection else .active;
}

/// The inspection a read ran for, as settling needs it.
pub const Inspection = enum { copy, command, other };

/// What a completed read shows, by the phase it read.
pub const Shows = enum {
    /// Opens the Message page asked for.
    message,
    /// Lands a recall step on the draft.
    recalled,
    /// Appends the staged live output.
    staged,
    /// Sends the answer to /copy's target.
    copy,
    /// Shows the inspection or /details page.
    page,
};

pub fn shows(phase: ReadPhase, inspection: Inspection) Shows {
    return switch (phase) {
        .message => .message,
        .recall => .recalled,
        .activity, .permission => .staged,
        .inspection => if (inspection == .copy) .copy else .page,
        .details => .page,
    };
}

/// Whether a command's output is settled once its read ends: shown, or
/// never written by a read that did not complete. Exit then no longer
/// prints it.
pub fn commandSettled(completed: bool, phase: ReadPhase) bool {
    return !completed or phase == .inspection or phase == .details;
}

/// Whether the /status page reads its defaults again: a command run over
/// it, such as /setup, may have changed them.
pub fn defaultsChanged(phase: ReadPhase, inspection: Inspection, status_shown: bool) bool {
    return phase == .inspection and inspection == .command and status_shown;
}

/// What a read that failed while preparing says, when no diagnostic of its
/// own is waiting. `copy` stands for /copy's own words for its failure.
pub const Unavailable = union(enum) { say: []const u8, copy };

pub fn unavailable(phase: ReadPhase, inspection: Inspection) Unavailable {
    return switch (phase) {
        .details => .{ .say = "! Details unavailable; draft retained." },
        .message => .{ .say = "! Message unavailable; Ctrl-O to retry. Draft retained." },
        .recall => .{ .say = "! Sent message unavailable; draft retained." },
        .inspection => if (inspection == .copy) .copy else .{ .say = "! Inspection unavailable; draft retained." },
        else => .{ .say = "! Earlier messages unavailable; scroll up to retry. Draft retained." },
    };
}

/// /copy's failure: a file it could not write says so; anything else is
/// unavailable.
pub fn copyFailure(to_file: bool, err: anyerror) []const u8 {
    if (to_file) switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return "! This directory is not writable; draft retained.",
        else => {},
    };
    return "! Copy unavailable; draft retained.";
}

/// Where a page is asked from: live output or one transcript. No page is
/// asked from elsewhere.
pub const Place = enum { feed, elsewhere };

/// What a Message page was asked over: its place, the Messages sent so
/// far, and the generation of page requests.
pub const Asked = struct { place: Place, sent: u64, generation: u64 };

/// A Message page shows only over the unchanged place it was asked from,
/// before any send, dismissal or newer Ctrl-O.
pub fn messageShows(asked: Asked, now: Asked) bool {
    return asked.place != .elsewhere and std.meta.eql(asked, now);
}

/// A /details page shows only when no Message was sent since it was asked
/// for: the sent Message keeps the latest view.
pub fn detailsShows(asked_sent: u64, sent: u64) bool {
    return asked_sent == sent;
}

test "the next scan waits its interval after a read, except for a /status asked during it" {
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
    // Nothing asked from elsewhere shows, even over itself.
    const elsewhere: Asked = .{ .place = .elsewhere, .sent = 0, .generation = 0 };
    try std.testing.expect(!messageShows(elsewhere, elsewhere));
}

test "a /details page shows only before the next send" {
    try std.testing.expect(detailsShows(4, 4));
    try std.testing.expect(!detailsShows(4, 5));
}

test "a pending inspection or Upgrade supersedes the silent read it cancelled" {
    try std.testing.expectEqual(departure.Mode.active, settleMode(false, false));
    try std.testing.expectEqual(departure.Mode.inspection, settleMode(true, false));
    try std.testing.expectEqual(departure.Mode.inspection, settleMode(false, true));
}

test "a completed read shows what its phase read; only /copy's inspection copies" {
    const cases = [_]struct { ReadPhase, Inspection, Shows }{
        .{ .message, .copy, .message },
        .{ .recall, .other, .recalled },
        .{ .activity, .other, .staged },
        .{ .permission, .copy, .staged },
        .{ .inspection, .copy, .copy },
        .{ .inspection, .command, .page },
        .{ .details, .copy, .page },
    };
    for (cases) |case| try std.testing.expectEqual(case[2], shows(case[0], case[1]));
}

test "a command's output settles when its page shows or its read ends early, never with a live or older page" {
    for (std.enums.values(ReadPhase)) |phase| {
        try std.testing.expect(commandSettled(false, phase));
        try std.testing.expectEqual(phase == .inspection or phase == .details, commandSettled(true, phase));
    }
}

test "only a command run over the shown /status page rereads its defaults" {
    try std.testing.expect(defaultsChanged(.inspection, .command, true));
    try std.testing.expect(!defaultsChanged(.inspection, .command, false));
    try std.testing.expect(!defaultsChanged(.inspection, .copy, true));
    try std.testing.expect(!defaultsChanged(.details, .command, true));
}

test "a read that failed while preparing says which page is unavailable" {
    try std.testing.expectEqualStrings("! Details unavailable; draft retained.", unavailable(.details, .copy).say);
    try std.testing.expectEqualStrings("! Message unavailable; Ctrl-O to retry. Draft retained.", unavailable(.message, .other).say);
    try std.testing.expectEqualStrings("! Sent message unavailable; draft retained.", unavailable(.recall, .other).say);
    try std.testing.expectEqualStrings("! Inspection unavailable; draft retained.", unavailable(.inspection, .command).say);
    try std.testing.expect(unavailable(.inspection, .copy) == .copy);
    try std.testing.expectEqualStrings("! Earlier messages unavailable; scroll up to retry. Draft retained.", unavailable(.activity, .copy).say);
    try std.testing.expectEqualStrings("! This directory is not writable; draft retained.", copyFailure(true, error.ReadOnlyFileSystem));
    try std.testing.expectEqualStrings("! Copy unavailable; draft retained.", copyFailure(false, error.AccessDenied));
    try std.testing.expectEqualStrings("! Copy unavailable; draft retained.", copyFailure(true, error.BrokenPipe));
}
