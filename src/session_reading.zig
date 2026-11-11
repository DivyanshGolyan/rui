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

/// What an idle reader knows when nothing was asked of it.
pub const Idle = struct {
    now_ns: i96,
    scan_due_ns: i96,
    /// The opening read has not been applied.
    opening: bool,
    /// Older pages or listed Messages remain above the transcript.
    older_remain: bool,
    /// The last older load failed; the next scroll retries it.
    older_failed: bool,
    /// The transcript shows its top row.
    at_top: bool,
    /// An Action's choice holds the input.
    choice_open: bool,
    /// The latest applied page names a first Action.
    action_named: bool,
    /// A Message or decision is still submitted or retained.
    submission: bool,
};

pub const Background = enum {
    /// Older history, at the transcript's top.
    history,
    /// The live scan, once due.
    activity,
    /// The read that prepares an Action no choice shows yet.
    permission,
};

/// The read an idle reader starts unasked: older history while the
/// transcript's top is on screen, else the scan once due, else the
/// permission read for a named Action once nothing else waits on input.
/// Before the opening read is applied, only the scan starts.
pub fn background(idle: Idle) ?Background {
    if (!idle.opening and idle.older_remain and !idle.older_failed and idle.at_top) return .history;
    if (idle.now_ns >= idle.scan_due_ns) return .activity;
    if (!idle.opening and idle.action_named and !idle.choice_open and !idle.submission) return .permission;
    return null;
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
    /// Prepends the older page to the transcript it was read for.
    older,
    /// Opens the Message page asked for.
    message,
    /// Lands a recall step on the draft.
    recalled,
    /// Appends the staged live output.
    staged,
    /// Sends the answer to /copy's target.
    copy,
    /// Shows the inspection page.
    page,
};

pub fn shows(phase: ReadPhase, inspection: Inspection) Shows {
    return switch (phase) {
        .history => .older,
        .message, .tool => .message,
        .recall => .recalled,
        .activity, .permission => .staged,
        .inspection => if (inspection == .copy) .copy else .page,
    };
}

/// Whether a command's output is settled once its read ends: shown, or
/// never written by a read that did not complete. Exit then no longer
/// prints it.
pub fn commandSettled(completed: bool, phase: ReadPhase) bool {
    return !completed or phase == .inspection;
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
        .message => .{ .say = "! Message unavailable; Ctrl-O to retry. Draft retained." },
        .tool => .{ .say = "! Tool output unavailable; Ctrl-O to retry. Draft retained." },
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
pub const Place = union(enum) { live, transcript: u64, elsewhere };

/// What a Message page was asked over: its place, the Messages sent so
/// far, and the generation of page requests.
pub const Asked = struct { place: Place, sent: u64, generation: u64 };

/// A Message page shows only over the unchanged place it was asked from,
/// before any send, dismissal or newer Ctrl-O.
pub fn messageShows(asked: Asked, now: Asked) bool {
    return asked.place != .elsewhere and std.meta.eql(asked, now);
}

test "the next scan waits its interval after a read, except for a /status asked during it" {
    try std.testing.expectEqual(@as(i96, 1_250_000_000), scanDue(1_000_000_000, false));
    try std.testing.expectEqual(@as(i96, 0), scanDue(1_000_000_000, true));
}

test "older history comes first at the transcript's top; the scan when due; a named Action's read only once input is quiet" {
    const quiet: Idle = .{ .now_ns = 10, .scan_due_ns = 20, .opening = false, .older_remain = false, .older_failed = false, .at_top = false, .choice_open = false, .action_named = false, .submission = false };
    try std.testing.expectEqual(@as(?Background, null), background(quiet));
    var idle = quiet;
    idle.older_remain = true;
    idle.at_top = true;
    idle.now_ns = 20;
    try std.testing.expectEqual(@as(?Background, .history), background(idle));
    // A failed load waits for the next scroll; the due scan goes instead.
    idle.older_failed = true;
    try std.testing.expectEqual(@as(?Background, .activity), background(idle));
    // Before the opening read is applied, only the scan starts.
    idle = quiet;
    idle.opening = true;
    idle.older_remain = true;
    idle.at_top = true;
    idle.action_named = true;
    try std.testing.expectEqual(@as(?Background, null), background(idle));
    idle.now_ns = 20;
    try std.testing.expectEqual(@as(?Background, .activity), background(idle));
    // A named Action is read between scans, unless its choice already
    // shows or a submission waits.
    idle = quiet;
    idle.action_named = true;
    try std.testing.expectEqual(@as(?Background, .permission), background(idle));
    inline for (.{ "choice_open", "submission" }) |held| {
        var waiting = idle;
        @field(waiting, held) = true;
        try std.testing.expectEqual(@as(?Background, null), background(waiting));
    }
}

test "a Message page shows only over the place, sends and requests it was asked over" {
    const asked: Asked = .{ .place = .{ .transcript = 2 }, .sent = 3, .generation = 7 };
    try std.testing.expect(messageShows(asked, asked));
    const changes = [_]Asked{
        .{ .place = .{ .transcript = 1 }, .sent = 3, .generation = 7 },
        .{ .place = .live, .sent = 3, .generation = 7 },
        .{ .place = .elsewhere, .sent = 3, .generation = 7 },
        .{ .place = .{ .transcript = 2 }, .sent = 4, .generation = 7 },
        .{ .place = .{ .transcript = 2 }, .sent = 3, .generation = 8 },
    };
    for (changes) |now| try std.testing.expect(!messageShows(asked, now));
    const live: Asked = .{ .place = .live, .sent = 0, .generation = 0 };
    try std.testing.expect(messageShows(live, live));
    // Nothing asked from elsewhere shows, even over itself.
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
        .{ .history, .copy, .older },
        .{ .message, .copy, .message },
        .{ .tool, .other, .message },
        .{ .recall, .other, .recalled },
        .{ .activity, .other, .staged },
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

test "only a command run over the shown /status page rereads its defaults" {
    try std.testing.expect(defaultsChanged(.inspection, .command, true));
    try std.testing.expect(!defaultsChanged(.inspection, .command, false));
    try std.testing.expect(!defaultsChanged(.inspection, .copy, true));
    try std.testing.expect(!defaultsChanged(.history, .command, true));
}

test "a read that failed while preparing says which page is unavailable" {
    try std.testing.expectEqualStrings("! Message unavailable; Ctrl-O to retry. Draft retained.", unavailable(.message, .other).say);
    try std.testing.expectEqualStrings("! Tool output unavailable; Ctrl-O to retry. Draft retained.", unavailable(.tool, .other).say);
    try std.testing.expectEqualStrings("! Sent message unavailable; draft retained.", unavailable(.recall, .other).say);
    try std.testing.expectEqualStrings("! Inspection unavailable; draft retained.", unavailable(.inspection, .command).say);
    try std.testing.expect(unavailable(.inspection, .copy) == .copy);
    try std.testing.expectEqualStrings("! Earlier messages unavailable; scroll up to retry. Draft retained.", unavailable(.history, .copy).say);
    try std.testing.expectEqualStrings("! This directory is not writable; draft retained.", copyFailure(true, error.ReadOnlyFileSystem));
    try std.testing.expectEqualStrings("! Copy unavailable; draft retained.", copyFailure(false, error.AccessDenied));
    try std.testing.expectEqualStrings("! Copy unavailable; draft retained.", copyFailure(true, error.BrokenPipe));
}
