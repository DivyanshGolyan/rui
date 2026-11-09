//! The conversation's one reader, decided over values its frontend read:
//! which read an idle reader starts, when the next scan is due, whether a
//! joined read settles now, and whether a page a read brings still shows.
//! `SessionFrontend` reads the clock, the screen and the input, and starts,
//! joins and shows what these decide.
const std = @import("std");

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
    /// The decoder holds part of a key sequence.
    decoder_pending: bool,
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
    if (!idle.opening and idle.action_named and !idle.choice_open and !idle.submission and !idle.decoder_pending) return .permission;
    return null;
}

/// Whether a joined read settles now. It may hide or withdraw the Action,
/// so a sequence the choice is decoding finishes there first and keeps its
/// meaning.
pub fn settles(completed: bool, at_choice: bool, decoder_pending: bool) bool {
    return completed and !(at_choice and decoder_pending);
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

/// A /details page shows only when no Message was sent since it was asked
/// for: the sent Message keeps the latest view.
pub fn detailsShows(asked_sent: u64, sent: u64) bool {
    return asked_sent == sent;
}

test "the next scan waits its interval after a read, except for a /status asked during it" {
    try std.testing.expectEqual(@as(i96, 1_250_000_000), scanDue(1_000_000_000, false));
    try std.testing.expectEqual(@as(i96, 0), scanDue(1_000_000_000, true));
}

test "older history comes first at the transcript's top; the scan when due; a named Action's read only once input is quiet" {
    const quiet: Idle = .{ .now_ns = 10, .scan_due_ns = 20, .opening = false, .older_remain = false, .older_failed = false, .at_top = false, .choice_open = false, .action_named = false, .submission = false, .decoder_pending = false };
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
    // shows, a submission waits, or a key sequence is being decoded.
    idle = quiet;
    idle.action_named = true;
    try std.testing.expectEqual(@as(?Background, .permission), background(idle));
    inline for (.{ "choice_open", "submission", "decoder_pending" }) |held| {
        var waiting = idle;
        @field(waiting, held) = true;
        try std.testing.expectEqual(@as(?Background, null), background(waiting));
    }
}

test "a joined read settles unless the choice is decoding a key sequence" {
    for ([_]bool{ false, true }) |completed| for ([_]bool{ false, true }) |at_choice| for ([_]bool{ false, true }) |pending| {
        try std.testing.expectEqual(completed and !(at_choice and pending), settles(completed, at_choice, pending));
    };
    try std.testing.expect(!settles(true, true, true));
    try std.testing.expect(settles(true, false, true));
    try std.testing.expect(settles(true, true, false));
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

test "a /details page shows only before the next send" {
    try std.testing.expect(detailsShows(4, 4));
    try std.testing.expect(!detailsShows(4, 5));
}
