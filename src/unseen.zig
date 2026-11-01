//! "New since you looked": where a conversation opens, and what one visit
//! has seen of it, in Session positions. The Store keeps each Session's
//! read-through position. The opening places the rule after it, and a row
//! counts as seen only once a frame drew it.
const std = @import("std");

/// The rule, dim, on a line of its own above the first unseen item.
pub const rule = "── new since you looked ──\n";

/// What a run of items, newest first as pages return them, says about the
/// rule.
pub const Place = enum {
    /// The rule goes before this run's first item after the read-through
    /// position, if one shows.
    here,
    /// Every item here is unseen and older pages hold more: the rule is earlier.
    older,
    /// No position was ever read, or the run is empty.
    none,
};

/// `oldest` is the run's oldest item position, null when it is empty;
/// `more` says older items precede it.
pub fn place(read_through: ?u64, oldest: ?u64, more: bool) Place {
    const read = read_through orelse return .none;
    const first = oldest orelse return .none;
    return if (more and first > read) .older else .here;
}

/// Where the opening put the rule in live output.
pub const Rule = union(enum) {
    /// No row after the read-through position shows, or none was ever read.
    none,
    /// At this live offset.
    at: u64,
    /// Above the opening's rows, which are all unseen.
    older,
};

/// What one visit has seen of a conversation.
pub const Seen = struct {
    /// The read-through position the Store holds as far as this visit
    /// knows: what the opening read, then what leaving took to record.
    recorded: ?u64 = null,
    /// Every row through this position has shown.
    through: ?u64 = null,
    /// A caught-up latest frame that shows this live offset shows every row
    /// after `through`. Null while rows between them never showed.
    live_from: ?u64 = null,
    /// The opening's end, and the live offset its rows end at.
    end: u64 = 0,
    end_offset: u64 = 0,

    pub fn open(read_through: ?u64, end: u64, placed: Rule, end_offset: u64) Seen {
        return .{ .recorded = read_through, .through = read_through, .end = end, .end_offset = end_offset, .live_from = switch (placed) {
            .none => end_offset,
            .at => |at| at,
            .older => null,
        } };
    }

    /// Whether the conversation opens on the rows after the read-through
    /// position instead of the latest view, which does not show them all.
    /// `shown`: the latest view shows `live_from`.
    pub fn opensTranscript(self: Seen, shown: bool) bool {
        return self.live_from == null or !shown;
    }

    /// A caught-up latest frame showed live output through position `end`,
    /// which ends at live offset `live_end`. `shown`: it showed `live_from`.
    pub fn live(self: *Seen, shown: bool, end: u64, live_end: u64) void {
        if (self.live_from == null or !shown) return;
        self.advance(end);
        self.live_from = live_end;
    }

    /// A frame showed the end of the transcript of rows after the
    /// read-through position, which runs through `through`.
    pub fn transcript(self: *Seen, through: u64) void {
        self.advance(through);
        // Its rows reached the opening's end, where live output continues.
        if (through >= self.end) self.live_from = @max(self.live_from orelse 0, self.end_offset);
    }

    fn advance(self: *Seen, to: u64) void {
        self.through = @max(self.through orelse 0, to);
    }

    /// The position for leaving to record, once; null when the Store
    /// already holds it.
    pub fn take(self: *Seen) ?u64 {
        const through = self.through orelse return null;
        if (self.recorded) |recorded| if (through <= recorded) return null;
        self.recorded = through;
        return through;
    }
};

test "the rule is in a run that reaches a read item or the conversation's start, else earlier" {
    const Case = struct { read_through: ?u64, oldest: ?u64, more: bool, expected: Place };
    for ([_]Case{
        .{ .read_through = null, .oldest = 3, .more = false, .expected = .none },
        .{ .read_through = null, .oldest = 3, .more = true, .expected = .none },
        .{ .read_through = 4, .oldest = null, .more = false, .expected = .none },
        .{ .read_through = 4, .oldest = 4, .more = true, .expected = .here },
        .{ .read_through = 4, .oldest = 2, .more = true, .expected = .here },
        // The run starts the conversation, so nothing earlier can hold it.
        .{ .read_through = 4, .oldest = 9, .more = false, .expected = .here },
        .{ .read_through = 4, .oldest = 5, .more = true, .expected = .older },
    }) |case| try std.testing.expectEqual(case.expected, place(case.read_through, case.oldest, case.more));
}

test "a reopened conversation lands on the rule; nothing new, or never read, opens at the latest view" {
    // The rule is in live output: the latest view either shows it or not.
    const placed = Seen.open(4, 9, .{ .at = 100 }, 300);
    try std.testing.expect(!placed.opensTranscript(true));
    try std.testing.expect(placed.opensTranscript(false));
    // Unseen rows above the opening's own.
    try std.testing.expect(Seen.open(4, 9, .older, 300).opensTranscript(true));
    // Nothing after the read-through position shows.
    var nothing = Seen.open(9, 9, .none, 300);
    try std.testing.expect(!nothing.opensTranscript(true));
    nothing.live(true, 9, 300);
    try std.testing.expectEqual(@as(?u64, null), nothing.take());
    // Never read: the first latest view counts, and leaving records it.
    var never = Seen.open(null, 9, .none, 300);
    try std.testing.expect(!never.opensTranscript(true));
    try std.testing.expectEqual(@as(?u64, null), never.take());
    never.live(true, 9, 300);
    try std.testing.expectEqual(@as(?u64, 9), never.take());
}

test "only rows a frame drew count as seen, and leaving takes each advance once" {
    // A latest view that does not reach the rule shows none of the rows above it.
    var hidden = Seen.open(4, 9, .{ .at = 100 }, 300);
    hidden.live(false, 9, 300);
    try std.testing.expectEqual(@as(?u64, null), hidden.take());
    hidden.live(true, 9, 300);
    try std.testing.expectEqual(@as(?u64, 9), hidden.take());
    try std.testing.expectEqual(@as(?u64, null), hidden.take());
    // Rows older than the opening: live output counts only once the
    // transcript of them reaches the opening's end.
    var older = Seen.open(4, 9, .older, 300);
    older.live(true, 9, 300);
    try std.testing.expectEqual(@as(?u64, null), older.take());
    older.transcript(6);
    older.live(true, 9, 300);
    try std.testing.expectEqual(@as(?u64, 6), older.take());
    older.transcript(9);
    // A frame that starts below the opening's end skipped newer rows.
    older.live(false, 12, 400);
    try std.testing.expectEqual(@as(?u64, 9), older.take());
    older.live(true, 12, 400);
    try std.testing.expectEqual(@as(?u64, 12), older.take());
    // Each later frame continues from where the last one ended.
    older.live(true, 15, 500);
    try std.testing.expectEqual(@as(?u64, 500), older.live_from);
    try std.testing.expectEqual(@as(?u64, 15), older.take());
    // A transcript reaching the end again never moves the live offset back.
    older.transcript(9);
    try std.testing.expectEqual(@as(?u64, 500), older.live_from);
}
