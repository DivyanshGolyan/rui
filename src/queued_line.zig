//! Messages a person or script sent that wait behind the work, as live output
//! read them, and the dimmed row right above the input that shows the newest:
//! `› also check the history scratch cache          queued`. Live output shows
//! such a Message once it is taken: as its conversation row once applied, or
//! labelled at the stop that excluded it. This core keeps admission
//! identities and fits the row; its shell reads pages and the newest
//! Message's first line.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_line = @import("session_line.zig");

pub const Method = session_line.Method;

/// The newest queued Message's first line, terminal-safe.
pub const Line = Bounded(session_line.max_line_bytes);

/// The Messages without a sender that live output read admitted, not
/// applied, and has not shown: those with admission IDs in `[low, high]`.
/// Selection and a stop's exclusion both take admission-order prefixes, so
/// they are a contiguous span and need no list; a Message from another
/// Session inside the span is not counted.
pub const Span = struct { low: u64, high: u64 };

pub const Queue = struct {
    count: u64 = 0,
    low: u64 = 0,
    high: u64 = 0,
    /// A Session position at or before the lowest one's Admission, where a
    /// stop's search for them starts.
    from: u64 = 0,
    /// The newest one's Admission position.
    newest: u64 = 0,
    /// Whether the row shows them (see `settle`).
    shown: bool = false,

    /// Live output read this Admission at `position`, not applied.
    pub fn admit(self: *Queue, admission: u64, position: u64) void {
        std.debug.assert(admission > self.high and position > self.newest);
        if (self.count == 0) self.* = .{ .low = admission, .from = position };
        self.count += 1;
        self.high = admission;
        self.newest = position;
    }

    /// Live output shows this Message now: as its row, or at the stop that
    /// excluded it. Returns whether it waited here. `next` is a position at
    /// or before every later one's Admission, where a stop's search resumes:
    /// a row's own, since an input boundary selects every Message admitted
    /// before it, or the one after an excluded Admission.
    pub fn take(self: *Queue, admission: u64, next: u64) bool {
        if (self.count == 0 or admission < self.low or admission > self.high) return false;
        self.count -= 1;
        self.low = admission + 1;
        self.from = @max(self.from, next);
        if (self.count == 0) self.* = .{};
        return true;
    }

    /// The admission IDs a stop with this cutoff excludes, if any.
    pub fn excluded(self: *const Queue, cutoff: u64) ?Span {
        if (self.count == 0 or cutoff < self.low) return null;
        return .{ .low = self.low, .high = @min(cutoff, self.high) };
    }

    /// A live read ended with this queue. `held` says whether the work it
    /// read holds queued input, and `before` is the newest Message the read
    /// before it left waiting, or 0. Work that does not hold its queue takes
    /// a Message at once, so the row shows the newest only while the work
    /// holds it or once it has waited through a whole poll; until then
    /// the person sees their send as `Sent`. A sooner read would show it
    /// before such work has had time to take it.
    pub fn settle(self: *Queue, held: bool, before: u64) void {
        self.shown = self.count != 0 and (held or self.high == before);
    }

    /// The newest Message the read before this one left waiting, or 0.
    pub fn waiting(self: *const Queue) u64 {
        return if (self.count == 0) 0 else self.high;
    }

    /// Whether this admission waits here unshown: its send still reads
    /// `Sent`.
    pub fn hides(self: *const Queue, admission: u64) bool {
        return !self.shown and self.count != 0 and self.low <= admission and admission <= self.high;
    }
};

/// What the row shows: the newest Message's first line, and how many wait.
pub const Waiting = struct { line: []const u8, count: u64 };

/// The row: the newest Message cut to fit, then how many wait, right-aligned
/// at `column`.
pub const Row = struct { text: []const u8, label: []const u8, column: usize };

const mark = "› ";
pub const text_capacity = mark.len + session_line.max_line_bytes + session_line.ellipsis.len;
pub const label_capacity = std.fmt.count("{d} queued", .{std.math.maxInt(u64)});

/// Fits the row to `width` cells. The label always shows, shortened to
/// `queued` when the count does not fit; the Message keeps one cell before
/// it and shows only when its mark and one more cell fit.
pub fn row(text: *[text_capacity]u8, label: *[label_capacity]u8, line: []const u8, count: u64, width: usize, method: Method) Row {
    std.debug.assert(count != 0 and line.len <= session_line.max_line_bytes);
    const counted = if (count == 1) "queued" else std.fmt.bufPrint(label, "{d} queued", .{count}) catch unreachable;
    const shown = if (session_line.cells(counted, method) <= width) counted else "queued";
    const label_cells = session_line.cells(shown, method);
    var out = std.Io.Writer.fixed(text);
    const room = width -| label_cells -| 1;
    if (room >= session_line.cells(mark, method) + 1) {
        out.writeAll(mark) catch unreachable;
        const left = room - session_line.cells(mark, method);
        if (session_line.cells(line, method) <= left) {
            out.writeAll(line) catch unreachable;
        } else {
            const kept = session_line.fit(line, left - session_line.cells(session_line.ellipsis, method), method);
            out.writeAll(line[0..kept.len]) catch unreachable;
            out.writeAll(session_line.ellipsis) catch unreachable;
        }
    }
    return .{ .text = out.buffered(), .label = shown, .column = width -| label_cells };
}

test "the queue counts the Messages live output read and has not shown, by admission ID" {
    var queue: Queue = .{};
    try std.testing.expectEqual(@as(?Span, null), queue.excluded(99));
    queue.admit(10, 40);
    queue.admit(12, 44);
    // A Message from another Session, admitted 11, is inside the span but
    // never counted.
    queue.admit(14, 47);
    try std.testing.expectEqual(@as(u64, 3), queue.count);
    try std.testing.expectEqual(@as(u64, 47), queue.newest);
    try std.testing.expectEqual(@as(u64, 40), queue.from);
    // Rows take them in admission order; one from before the span is not
    // here. A stop's search resumes at the row, which every Message still
    // waiting followed.
    try std.testing.expect(!queue.take(9, 41));
    try std.testing.expectEqual(@as(u64, 40), queue.from);
    try std.testing.expect(queue.take(10, 45));
    try std.testing.expectEqual(@as(u64, 2), queue.count);
    try std.testing.expectEqual(@as(u64, 11), queue.low);
    try std.testing.expectEqual(@as(u64, 45), queue.from);
    // A stop takes the prefix at or below its cutoff; a later one stays.
    try std.testing.expectEqual(@as(?Span, null), queue.excluded(10));
    try std.testing.expectEqual(Span{ .low = 11, .high = 13 }, queue.excluded(13).?);
    try std.testing.expectEqual(Span{ .low = 11, .high = 14 }, queue.excluded(90).?);
    try std.testing.expect(queue.take(12, 46));
    try std.testing.expectEqual(@as(u64, 46), queue.from);
    try std.testing.expect(!queue.take(15, 50));
    try std.testing.expect(queue.take(14, 48));
    try std.testing.expectEqual(@as(u64, 0), queue.count);
    try std.testing.expectEqual(@as(?Span, null), queue.excluded(90));
    // Empty again: the next Message starts a new span where it was admitted.
    queue.admit(20, 60);
    try std.testing.expectEqual(@as(u64, 20), queue.low);
    try std.testing.expectEqual(@as(u64, 60), queue.from);
}

test "the row shows a queued Message only once the work holds it or it waited a whole poll" {
    var queue: Queue = .{};
    // An idle or pending Session takes a Message at once: its row would
    // only flash, so it hides, and the send still reads Sent.
    queue.admit(4, 9);
    queue.settle(false, 0);
    try std.testing.expect(!queue.shown and queue.hides(4));
    // Still waiting at the next read: it shows.
    var before = queue.waiting();
    queue.settle(false, before);
    try std.testing.expect(queue.shown and !queue.hides(4));
    // A newer Message while the work does not hold the queue hides the row
    // again for one read.
    before = queue.waiting();
    queue.admit(6, 12);
    queue.settle(false, before);
    try std.testing.expect(!queue.shown and queue.hides(6) and queue.hides(4));
    try std.testing.expect(!queue.hides(3) and !queue.hides(7));
    // Work that holds the queue shows it at once.
    before = queue.waiting();
    queue.admit(8, 15);
    queue.settle(true, before);
    try std.testing.expect(queue.shown and !queue.hides(8));
    // Taken, nothing shows or hides.
    for ([_]u64{ 4, 6, 8 }, [_]u64{ 16, 17, 18 }) |admission, at| try std.testing.expect(queue.take(admission, at));
    queue.settle(true, 8);
    try std.testing.expect(!queue.shown and !queue.hides(8));
    try std.testing.expectEqual(@as(u64, 0), queue.waiting());
}

test "the queued row keeps its label and cuts the Message before it" {
    var text: [text_capacity]u8 = undefined;
    var label: [label_capacity]u8 = undefined;
    const Case = struct { line: []const u8, count: u64, width: usize, text: []const u8, label: []const u8 };
    for ([_]Case{
        .{ .line = "also check the history scratch cache", .count = 1, .width = 80, .text = "› also check the history scratch cache", .label = "queued" },
        .{ .line = "also check the history scratch cache", .count = 3, .width = 80, .text = "› also check the history scratch cache", .label = "3 queued" },
        // 30 columns: 8 for the label, one before it, 21 for the Message.
        .{ .line = "also check the history scratch cache", .count = 3, .width = 30, .text = "› also check the his…", .label = "3 queued" },
        .{ .line = "中文中文中文中文", .count = 1, .width = 16, .text = "› 中文中…", .label = "queued" },
        // Too narrow for the mark and a cell: the label alone.
        .{ .line = "anything", .count = 12, .width = 11, .text = "", .label = "12 queued" },
        .{ .line = "anything", .count = 12, .width = 8, .text = "", .label = "queued" },
        .{ .line = "", .count = 1, .width = 80, .text = "› ", .label = "queued" },
    }) |case| {
        const fitted = row(&text, &label, case.line, case.count, case.width, .unicode);
        try std.testing.expectEqualStrings(case.text, fitted.text);
        try std.testing.expectEqualStrings(case.label, fitted.label);
        try std.testing.expectEqual(case.width - session_line.cells(case.label, .unicode), fitted.column);
    }
    // At every width the Message, a gap and the label fit.
    for (8..120) |width| for ([_]u64{ 1, 9, 12345 }) |count| {
        const fitted = row(&text, &label, "a long Message with wide 中文 clusters and more words than fit", count, width, .unicode);
        const used = session_line.cells(fitted.text, .unicode);
        try std.testing.expect(used == 0 or used + 1 <= fitted.column);
        try std.testing.expectEqual(width, fitted.column + session_line.cells(fitted.label, .unicode));
    };
}
