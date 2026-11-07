//! Where a draft's visual lines break, where its caret sits, and which of
//! its lines the input shows. The overview and the conversation both lay out
//! their input here, so a draft wraps and scrolls the same way on each.
//!
//! The caller supplies the draft as pieces: whole clusters measured exactly
//! as its painter draws them, sorted by `kindOf`. Lines break after the last
//! space that fits. A word wider than the line, such as a URL or a path,
//! breaks after its last joint that fits (`/`, `.`, `-` and the like), and
//! at a cluster only when it has none. Spaces that reach past the edge hang
//! there: they end the line, take no cell, and never start the next one.
//! Original raw syntax and display pieces share byte coordinates. A local
//! Markdown context permits quote gutters only outside opaque fenced code.
//! `shape` counts rows; `fit` stops at the last shown row, after preflighting
//! any quoted logical line for the whole-line wide-cluster fallback.
const std = @import("std");
const prefix = @import("markdown_prefix.zig");
const Quote = prefix.Quote;

/// A newline breaks hard; a line may break after a space, and a word too
/// wide for its line after a joint.
pub const Kind = enum { newline, space, joint, other };

/// The kind of one cluster, as both screens sort their pieces.
pub fn kindOf(cluster: []const u8) Kind {
    if (cluster.len != 1) return .other;
    return switch (cluster[0]) {
        '\n' => .newline,
        ' ' => .space,
        '/', '\\', '.', '-', '_', '?', '&', '=', '#', ',', ';' => .joint,
        else => .other,
    };
}

/// One measured cluster: `len` source bytes drawn in `cells` cells.
pub const Piece = struct { len: usize, cells: u16, kind: Kind };

/// A visual line: draft bytes `start..end` drawn in `cells` cells. A newline
/// or hanging spaces that end it lie between its `end` and the next `start`.
pub const Line = struct {
    start: usize,
    end: usize,
    cells: u16,
    continuation: ?Quote.Continuation = null,

    pub fn prefixCells(self: Line) u16 {
        return if (self.continuation) |value| value.cells else 0;
    }

    /// Shared synthetic ASCII only; slices are static through frame encoding.
    /// First rows have no synthetic prefix and retain every original marker.
    pub fn gutter(self: Line) [3][]const u8 {
        const value = self.continuation orelse return .{ "", "", "" };
        const spaces = "                   ";
        const markers = ">>>>>>>>";
        return .{ spaces[0..value.indent], markers[0..value.depth], spaces[0 .. value.cells - value.indent - value.depth] };
    }
};

/// The most rows an input ever shows.
pub const max_rows = 10;

/// The most input rows a terminal `height` rows tall gives a draft: ten,
/// or a third of the screen when that is less, and at least one.
pub fn cap(height: u16) u16 {
    return @max(1, @min(max_rows, height / 3));
}

/// Every line of a draft, where the caret falls, and which line holds the
/// byte the previous frame showed first.
pub const Shape = struct {
    lines: usize,
    caret_line: usize,
    caret_column: u16,
    anchor_line: usize = 0,
};

/// The rows the input shows: lines `first..first + rows`, with the counts
/// a reader needs to know more is hidden.
pub const View = struct {
    first: usize,
    rows: u16,
    hidden_above: usize,
    hidden_below: usize,
};

/// One row emitter owns both source rows and an exact-edge caret's empty row.
/// Gutter cells are presentation only: neither source offsets nor cursor move.
fn Rows(comptime Sink: type) type {
    return struct {
        sink: Sink,
        width: u16,

        fn line(self: @This(), value: Line, caret: ?u16, following: ?Quote.Continuation) bool {
            if (caret) |column| {
                if (@as(u32, column) + value.prefixCells() >= self.width) {
                    if (!self.sink.line(value, null)) return false;
                    const next: Line = .{ .start = value.end, .end = value.end, .cells = 0, .continuation = following };
                    return self.sink.line(next, next.prefixCells());
                }
                return self.sink.line(value, column + value.prefixCells());
            }
            return self.sink.line(value, null);
        }
    };
}

/// Decide once per ORIGINAL logical line. The measured cursor is copied only
/// for the whole-line wide-cluster fallback, not once per visual row. Context
/// and measurements are local to this traversal; no editor state is retained.
fn logical(raw: []const u8, pieces: anytype, width: u16, context: *prefix.Context) ?Quote.Continuation {
    const head = raw[0..@min(raw.len, prefix.head_limit)];
    const newline = std.mem.indexOfScalar(u8, head, '\n');
    const ending: prefix.HeadEnding = if (newline != null) .line_feed else if (raw.len < prefix.head_limit) .canonical_eof else .limit_cut;
    const decision = context.step(head[0 .. newline orelse head.len], ending).resolved;
    context.* = decision.next;
    const quote = decision.projection.quote orelse return null;
    const continuation = quote.continuation(width) orelse return null;
    const available = width - continuation.cells;
    var source = pieces;
    while (source.next()) |piece| {
        if (piece.kind == .newline) break;
        if (piece.cells > available) return null;
    }
    return continuation;
}

/// Walks measured source pieces into rows. Raw and pieces use identical byte
/// coordinates/newlines, but raw retains tabs that display pieces may normalize.
fn walk(raw: []const u8, pieces: anytype, width: u16, cursor: usize, sink: anytype) void {
    std.debug.assert(width > 0);
    var source = pieces;
    var context: prefix.Context = .plain;
    var following = logical(raw, source, width, &context);
    var continuation: ?Quote.Continuation = null;
    const rows: Rows(@TypeOf(sink)) = .{ .sink = sink, .width = width };
    var offset: usize = 0;
    var start: usize = 0;
    var logical_start: usize = 0;
    var end: usize = 0;
    var cells: u16 = 0;
    var hanging: u16 = 0;
    var caret: ?u16 = null;
    const Break = struct { at: usize, end: usize, cells: u16, columns: u16 };
    var soft: ?Break = null;
    var joint: ?Break = null;
    while (source.next()) |piece| {
        std.debug.assert(offset + piece.len <= raw.len);
        defer offset += piece.len;
        const prefix_cells: u16 = if (continuation) |value| value.cells else 0;
        if (piece.kind != .newline and cells > 0 and @as(u32, cells) + hanging + piece.cells > width - prefix_cells) {
            if (piece.kind == .space) {
                if (offset == cursor) caret = cells +| hanging;
                hanging +|= piece.cells;
                soft = .{ .at = offset + piece.len, .end = end, .cells = cells, .columns = cells +| hanging };
                continue;
            }
            // A joint breaks only a word still too wide after the space.
            inline for (.{ false, true }) |at_joint| if (!at_joint or @as(u32, cells) + piece.cells > width - (if (continuation) |value| @as(u16, value.cells) else 0)) {
                if (if (at_joint) joint else soft) |point| if (point.at > start and point.at > logical_start + (if (following) |value| @as(usize, value.cells) else 0)) {
                    if (!rows.line(.{ .start = start, .end = point.end, .cells = point.cells, .continuation = continuation }, if (cursor < point.at) caret else null, following)) return;
                    if (cursor < point.at) caret = null else if (caret) |column| caret = column - point.columns;
                    start = point.at;
                    cells -= point.cells;
                    continuation = following;
                    hanging = 0;
                    if (joint) |*inside| {
                        if (inside.at > point.at) {
                            inside.cells -= point.cells;
                            inside.columns -= point.columns;
                        } else joint = null;
                    }
                    soft = null;
                };
            };
            if (cells > 0 and @as(u32, cells) + piece.cells > width - (if (continuation) |value| @as(u16, value.cells) else 0)) {
                if (!rows.line(.{ .start = start, .end = offset, .cells = cells, .continuation = continuation }, caret, following)) return;
                caret = null;
                start = offset;
                cells = 0;
                continuation = following;
                joint = null;
            }
        }
        if (offset == cursor) caret = cells +| hanging;
        if (piece.kind == .newline) {
            std.debug.assert(std.mem.eql(u8, raw[offset..][0..piece.len], "\n"));
            if (!rows.line(.{ .start = start, .end = end, .cells = cells, .continuation = continuation }, caret, following)) return;
            caret = null;
            start = offset + piece.len;
            logical_start = start;
            end = start;
            cells = 0;
            hanging = 0;
            soft = null;
            joint = null;
            continuation = null;
            following = logical(raw[start..], source, width, &context);
            continue;
        }
        cells += piece.cells;
        end = offset + piece.len;
        switch (piece.kind) {
            .space => {
                soft = .{ .at = end, .end = end, .cells = cells, .columns = cells };
                joint = null;
            },
            .joint => joint = .{ .at = end, .end = end, .cells = cells, .columns = cells },
            .newline, .other => {},
        }
    }
    std.debug.assert(offset == raw.len);
    if (offset == cursor) caret = cells +| hanging;
    _ = rows.line(.{ .start = start, .end = end, .cells = cells, .continuation = continuation }, caret, following);
}

/// Counts the lines of `pieces` at `width` cells, finds the line and column
/// of the caret at byte `cursor`, and the line that holds byte `anchor`. A
/// cursor on a soft break belongs to the line it starts.
pub fn shape(raw: []const u8, pieces: anytype, width: u16, cursor: usize, anchor: usize) Shape {
    const Counter = struct {
        count: usize = 0,
        anchor: usize,
        found: bool = false,
        result: Shape = .{ .lines = 0, .caret_line = 0, .caret_column = 0 },

        fn line(self: *@This(), value: Line, caret: ?u16) bool {
            defer self.count += 1;
            if (value.start <= self.anchor) self.result.anchor_line = self.count;
            if (caret) |column| {
                std.debug.assert(!self.found);
                self.found = true;
                self.result.caret_line = self.count;
                self.result.caret_column = column;
            }
            return true;
        }
    };
    var counter: Counter = .{ .anchor = anchor };
    walk(raw, pieces, width, cursor, &counter);
    std.debug.assert(counter.found);
    var result = counter.result;
    result.lines = counter.count;
    return result;
}

/// Shows at most `limit` lines of a draft with `value`: fills `out` with
/// them, top to bottom, and returns which they are. The caller keeps
/// `out[0].start` as the next frame's anchor.
pub fn fit(raw: []const u8, pieces: anytype, width: u16, cursor: usize, value: Shape, limit: u16, out: *[max_rows]Line) View {
    const shown = view(value, @min(limit, max_rows));
    const count = collect(raw, pieces, width, cursor, shown.first, out[0..shown.rows]);
    std.debug.assert(count == shown.rows);
    return shown;
}

/// The rows to show of a draft with `shape`, at most `limit`, keeping the
/// caret in view and otherwise starting at the anchor line.
fn view(value: Shape, limit: u16) View {
    std.debug.assert(limit > 0);
    const rows: u16 = @intCast(@min(value.lines, limit));
    var first = @min(value.anchor_line, value.lines - rows);
    if (value.caret_line < first) first = value.caret_line;
    if (value.caret_line >= first + rows) first = value.caret_line + 1 - rows;
    return .{ .first = first, .rows = rows, .hidden_above = first, .hidden_below = value.lines - first - rows };
}

/// Fills `out` with lines `first..first + out.len` of `pieces`, the caret's
/// own row included as an empty line, and stops walking there. Returns how
/// many it filled.
fn collect(raw: []const u8, pieces: anytype, width: u16, cursor: usize, first: usize, out: []Line) usize {
    const Collector = struct {
        first: usize,
        out: []Line,
        index: usize = 0,
        filled: usize = 0,

        fn line(self: *@This(), walked: Line, _: ?u16) bool {
            self.put(walked);
            return self.index < self.first + self.out.len;
        }

        fn put(self: *@This(), walked: Line) void {
            defer self.index += 1;
            if (self.index < self.first or self.index - self.first >= self.out.len) return;
            self.out[self.index - self.first] = walked;
            self.filled += 1;
        }
    };
    var collector: Collector = .{ .first = first, .out = out };
    walk(raw, pieces, width, cursor, &collector);
    return collector.filled;
}

/// The arrows and separator a rule label draws with.
pub const Marks = struct { up: []const u8, down: []const u8, dot: []const u8 };

/// The label a rule over the input carries: how many draft lines `value`
/// hides above or below, or "" when it hides none.
pub fn label(buffer: *[64]u8, value: View, marks: Marks) []const u8 {
    const above = value.hidden_above;
    const below = value.hidden_below;
    return (if (above == 0 and below == 0) "" else if (below == 0)
        std.fmt.bufPrint(buffer, " {s} {d} more {s} ", .{ marks.up, above, if (above == 1) "line" else "lines" })
    else if (above == 0)
        std.fmt.bufPrint(buffer, " {s} {d} more {s} ", .{ marks.down, below, if (below == 1) "line" else "lines" })
    else
        std.fmt.bufPrint(buffer, " {s} {d} {s} {s} {d} more lines ", .{ marks.up, above, marks.dot, marks.down, below })) catch unreachable;
}

/// Where a label `label_cells` wide starts in a rule `cells` wide: centred,
/// with at least two rule cells on each side, or null when it does not fit.
pub fn labelColumn(label_cells: usize, cells: usize) ?usize {
    if (label_cells == 0 or label_cells + 4 > cells) return null;
    return (cells - label_cells) / 2;
}

/// Pieces of plain bytes for tests: `W` takes two cells and every other
/// byte one, `\n` breaks and ` ` is a space.
const Bytes = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *Bytes) ?Piece {
        if (self.at == self.bytes.len) return null;
        const byte = self.bytes[self.at];
        self.at += 1;
        return .{ .len = 1, .cells = if (byte == 'W') 2 else 1, .kind = kindOf(self.bytes[self.at - 1 ..][0..1]) };
    }
};

fn cellsOf(text: []const u8) u16 {
    var cells: u16 = 0;
    for (text) |byte| cells += if (byte == 'W') 2 else 1;
    return cells;
}

fn expectLines(text: []const u8, width: u16, expected: []const []const u8) !void {
    var storage: [32]Line = undefined;
    const whole = shape(text, Bytes{ .bytes = text }, width, 0, 0);
    const count = collect(text, Bytes{ .bytes = text }, width, 0, 0, &storage);
    try std.testing.expectEqual(whole.lines, count);
    try std.testing.expectEqual(expected.len, count);
    for (expected, storage[0..count]) |want, line| try std.testing.expectEqualStrings(want, text[line.start..line.end]);
}

test "lines break after the last space that fits" {
    try expectLines("the quick brown fox", 10, &.{ "the quick ", "brown fox" });
    try expectLines("abc def", 7, &.{"abc def"});
    try expectLines("abc def", 6, &.{ "abc ", "def" });
}

test "a word wider than the line breaks after its last joint, else at a cluster" {
    try expectLines("abcdefghij", 4, &.{ "abcd", "efgh", "ij" });
    try expectLines("ab abcdefghij", 4, &.{ "ab ", "abcd", "efgh", "ij" });
    try expectLines("https://example.com/a/b ok", 8, &.{ "https://", "example.", "com/a/b ", "ok" });
    try expectLines("see https://example.com/a/very/long/path end", 16, &.{ "see ", "https://example.", "com/a/very/long/", "path end" });
    try expectLines("src/draft_layout.zig", 12, &.{ "src/draft_", "layout.zig" });
    // A word that fits a line of its own moves whole, joints and all.
    try expectLines("ab a/b/c", 5, &.{ "ab ", "a/b/c" });
}

test "the rule label names what the view hides and centres where it fits" {
    var buffer: [64]u8 = undefined;
    const marks: Marks = .{ .up = "^", .down = "v", .dot = "-" };
    const cases = [_]struct { above: usize, below: usize, text: []const u8 }{
        .{ .above = 0, .below = 0, .text = "" },
        .{ .above = 1, .below = 0, .text = " ^ 1 more line " },
        .{ .above = 3, .below = 0, .text = " ^ 3 more lines " },
        .{ .above = 0, .below = 1, .text = " v 1 more line " },
        .{ .above = 4, .below = 1, .text = " ^ 4 - v 1 more lines " },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.text, label(&buffer, .{ .first = case.above, .rows = 1, .hidden_above = case.above, .hidden_below = case.below }, marks));
    try std.testing.expectEqual(@as(?usize, 12), labelColumn(16, 40));
    try std.testing.expectEqual(@as(?usize, 2), labelColumn(16, 20));
    try std.testing.expectEqual(@as(?usize, null), labelColumn(16, 19));
    try std.testing.expectEqual(@as(?usize, null), labelColumn(0, 40));
}

test "newlines break hard and keep empty lines" {
    try expectLines("a\n\nb", 10, &.{ "a", "", "b" });
    try expectLines("a\n", 10, &.{ "a", "" });
    try expectLines("", 10, &.{""});
}

test "spaces past the edge hang there and never start a line" {
    try expectLines("abcd ef", 4, &.{ "abcd", "ef" });
    try expectLines("abcd efgh", 4, &.{ "abcd", "efgh" });
    try expectLines("the quick", 3, &.{ "the", "qui", "ck" });
    try expectLines("the quick brown fox", 9, &.{ "the quick", "brown fox" });
    try expectLines("ab    cd", 4, &.{ "ab  ", "cd" });
    // The caret after a word that fills the line, before or after its
    // space, waits on a row of its own; after the space the next word is
    // where typing continues.
    const before = shape("abcd ef", Bytes{ .bytes = "abcd ef" }, 4, 4, 0);
    try std.testing.expectEqual(Shape{ .lines = 3, .caret_line = 1, .caret_column = 0 }, before);
    const after = shape("abcd ef", Bytes{ .bytes = "abcd ef" }, 4, 5, 0);
    try std.testing.expectEqual(Shape{ .lines = 2, .caret_line = 1, .caret_column = 0 }, after);
}

test "a draft of the editor's full capacity in spaces lays out without overflow" {
    const spaces: [65536]u8 = @splat(' ');
    var storage: [max_rows]Line = undefined;
    for ([_]usize{ 0, 5, 9, 10, 11, 30000, spaces.len }) |cursor| {
        const got = shape(&spaces, Bytes{ .bytes = &spaces }, 10, cursor, 0);
        // Ten spaces fill the line; the rest hang past its edge.
        try std.testing.expectEqual(@as(usize, if (cursor >= 10) 2 else 1), got.lines);
        try std.testing.expectEqual(@as(u16, if (cursor >= 10) 0 else @intCast(cursor)), got.caret_column);
        const shown = fit(&spaces, Bytes{ .bytes = &spaces }, 10, cursor, got, 10, &storage);
        try std.testing.expectEqual(got.lines, shown.rows);
    }
}

test "wide clusters never split and never overflow" {
    try expectLines("aWWW", 4, &.{ "aW", "WW" });
    try expectLines("aW W", 4, &.{ "aW ", "W" });
}

test "the caret follows its byte across soft and hard breaks" {
    const text = "the quick brown\nfox";
    const cases = [_]struct { cursor: usize, line: usize, column: u16 }{
        .{ .cursor = 0, .line = 0, .column = 0 },
        .{ .cursor = 9, .line = 0, .column = 9 },
        // On the soft break after "quick ": the line it starts.
        .{ .cursor = 10, .line = 1, .column = 0 },
        .{ .cursor = 15, .line = 1, .column = 5 },
        .{ .cursor = 16, .line = 2, .column = 0 },
        .{ .cursor = 19, .line = 2, .column = 3 },
    };
    for (cases) |case| {
        const got = shape(text, Bytes{ .bytes = text }, 10, case.cursor, 0);
        try std.testing.expectEqual(@as(usize, 3), got.lines);
        try std.testing.expectEqual(case.line, got.caret_line);
        try std.testing.expectEqual(case.column, got.caret_column);
    }
}

test "a caret after a line that fills the width gets a row of its own" {
    var storage: [8]Line = undefined;
    for ([_][]const u8{ "abcdef", "abcdef\nx" }) |text| {
        const got = shape(text, Bytes{ .bytes = text }, 6, 6, 0);
        try std.testing.expectEqual(@as(usize, 1), got.caret_line);
        try std.testing.expectEqual(@as(u16, 0), got.caret_column);
        const count = collect(text, Bytes{ .bytes = text }, 6, 6, 0, &storage);
        try std.testing.expectEqual(got.lines, count);
        try std.testing.expectEqual(@as(usize, 6), storage[1].start);
        try std.testing.expectEqual(@as(usize, 6), storage[1].end);
    }
    // Short of the width, the caret stays on its line.
    const short = shape("abcde", Bytes{ .bytes = "abcde" }, 6, 5, 0);
    try std.testing.expectEqual(@as(usize, 1), short.lines);
    try std.testing.expectEqual(@as(u16, 5), short.caret_column);
}

test "the cap is ten rows, a third of a short screen, and at least one" {
    const cases = [_][2]u16{ .{ 2, 1 }, .{ 3, 1 }, .{ 8, 2 }, .{ 24, 8 }, .{ 30, 10 }, .{ 60, 10 } };
    for (cases) |case| try std.testing.expectEqual(case[1], cap(case[0]));
}

test "the view keeps the caret in sight and moves as little as it can" {
    const tall: Shape = .{ .lines = 20, .caret_line = 19, .caret_column = 0 };
    try std.testing.expectEqual(View{ .first = 10, .rows = 10, .hidden_above = 10, .hidden_below = 0 }, view(tall, 10));
    var at = tall;
    at.anchor_line = 10;
    // Moving up inside the shown rows keeps them.
    at.caret_line = 12;
    try std.testing.expectEqual(@as(usize, 10), view(at, 10).first);
    // Moving above them scrolls by one.
    at.caret_line = 9;
    try std.testing.expectEqual(View{ .first = 9, .rows = 10, .hidden_above = 9, .hidden_below = 1 }, view(at, 10));
    // A short draft shows whole, whatever was first before.
    const short: Shape = .{ .lines = 3, .caret_line = 2, .caret_column = 0, .anchor_line = 2 };
    try std.testing.expectEqual(View{ .first = 0, .rows = 3, .hidden_above = 0, .hidden_below = 0 }, view(short, 10));
}

test "the anchor byte keeps its line first across a narrower width" {
    const text = "one two three four five six";
    // At width 9 the lines start at bytes 0, 8, 19; "three" starts at 8.
    const wide = shape(text, Bytes{ .bytes = text }, 9, text.len, 8);
    try std.testing.expectEqual(@as(usize, 1), wide.anchor_line);
    // At width 5 "three" is the third line, and still shown first.
    const narrow = shape(text, Bytes{ .bytes = text }, 5, 8, 8);
    try std.testing.expectEqual(@as(usize, 2), narrow.anchor_line);
    try std.testing.expectEqual(@as(usize, 2), view(narrow, 2).first);
}

test "collect stops walking once the shown lines are filled" {
    const Counted = struct {
        inner: Bytes,
        calls: *usize,
        fn next(self: *@This()) ?Piece {
            self.calls.* += 1;
            return self.inner.next();
        }
    };
    const lines: [2000]u8 = @splat('\n');
    const text: []const u8 = &lines;
    var calls: usize = 0;
    var storage: [2]Line = undefined;
    try std.testing.expectEqual(@as(usize, 2), collect(text, Counted{ .inner = .{ .bytes = text }, .calls = &calls }, 4, 0, 0, &storage));
    try std.testing.expect(calls < 8);
}

test "every cursor of every draft lands in the view, on its own bytes, at every width, limit and anchor" {
    const texts = [_][]const u8{ "", "a", "abc def ghi", "abcdefghijkl", "a\n\nb c d e f g h", "word  word\n  x", "abcdef\nabcdef", "      ", "aW Wb WWW a", "abcd efgh ij", "a/b.cd-efg/h ij/k", "W/WW.W a/" };
    var storage: [64]Line = undefined;
    var whole_storage: [64]Line = undefined;
    for (texts) |text| for (2..9) |w| for (1..4) |limit| for (0..text.len + 1) |cursor| {
        const width: u16 = @intCast(w);
        const bare = shape(text, Bytes{ .bytes = text }, width, cursor, 0);
        try std.testing.expect(bare.caret_column < width);
        const whole = collect(text, Bytes{ .bytes = text }, width, cursor, 0, &whole_storage);
        try std.testing.expectEqual(bare.lines, whole);
        // Every byte is on exactly one line, except the newlines and the
        // hanging spaces between them.
        var covered: usize = 0;
        for (whole_storage[0..whole]) |line| {
            try std.testing.expect(line.cells <= width);
            try std.testing.expectEqual(cellsOf(text[line.start..line.end]), line.cells);
            try std.testing.expect(line.start >= covered);
            for (text[covered..line.start]) |byte| try std.testing.expect(byte == '\n' or byte == ' ');
            covered = @max(covered, line.end);
        }
        for (text[covered..]) |byte| try std.testing.expect(byte == '\n' or byte == ' ');
        // The caret sits on the line that holds its byte, after the cells
        // before it; past a full line it waits on a row of its own.
        const caret_row = whole_storage[bare.caret_line];
        if (cursor <= caret_row.end) {
            try std.testing.expect(caret_row.start <= cursor);
            try std.testing.expectEqual(cellsOf(text[caret_row.start..cursor]), bare.caret_column);
        } else {
            try std.testing.expect(bare.caret_line > 0);
            try std.testing.expectEqual(caret_row.start, caret_row.end);
            try std.testing.expectEqual(@as(u16, 0), bare.caret_column);
            try std.testing.expectEqual(width, whole_storage[bare.caret_line - 1].cells);
            for (text[caret_row.end..cursor]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
        }
        for (0..whole) |previous| {
            const got = shape(text, Bytes{ .bytes = text }, width, cursor, whole_storage[previous].start);
            try std.testing.expectEqual(previous, got.anchor_line);
            const shown = view(got, @intCast(limit));
            try std.testing.expect(shown.first <= got.caret_line and got.caret_line < shown.first + shown.rows);
            // The view stays where it was while the caret is in it.
            if (previous + shown.rows <= got.lines and previous <= got.caret_line and got.caret_line < previous + shown.rows)
                try std.testing.expectEqual(previous, shown.first);
            const count = collect(text, Bytes{ .bytes = text }, width, cursor, shown.first, storage[0..shown.rows]);
            try std.testing.expectEqual(@as(usize, shown.rows), count);
            try std.testing.expectEqualSlices(Line, whole_storage[shown.first..][0..shown.rows], storage[0..shown.rows]);
        }
    };
}

fn quoteLines(raw: []const u8, shown: []const u8, width: u16, cursor: usize, out: []Line) usize {
    return collect(raw, Bytes{ .bytes = shown }, width, cursor, 0, out);
}

test "quote draft exact source rows and every caret preserve literal first markers" {
    const raw = "> alpha beta gamma";
    var storage: [max_rows]Line = undefined;
    const count = quoteLines(raw, raw, 10, raw.len, &storage);
    try std.testing.expectEqual(@as(usize, 3), count);
    const expected = [_]Line{
        .{ .start = 0, .end = 8, .cells = 8 },
        .{ .start = 8, .end = 13, .cells = 5, .continuation = .{ .cells = 2, .depth = 1, .indent = 0 } },
        .{ .start = 13, .end = 18, .cells = 5, .continuation = .{ .cells = 2, .depth = 1, .indent = 0 } },
    };
    try std.testing.expectEqualSlices(Line, &expected, storage[0..count]);
    try std.testing.expectEqualStrings("> alpha ", raw[storage[0].start..storage[0].end]);
    for (0..raw.len + 1) |cursor| {
        const result = shape(raw, Bytes{ .bytes = raw }, 10, cursor, 0);
        const row: usize = if (cursor < 8) 0 else if (cursor < 13) 1 else 2;
        const column: u16 = @intCast(if (row == 0) cursor else 2 + cursor - expected[row].start);
        try std.testing.expectEqual(row, result.caret_line);
        try std.testing.expectEqual(column, result.caret_column);
        try std.testing.expectEqual(@as(usize, 3), result.lines);
    }
    // Prefix spaces cannot strand the first marker row above a long body word.
    try std.testing.expectEqual(@as(usize, 3), quoteLines("> abcdefghijk", "> abcdefghijk", 6, 0, &storage));
    try std.testing.expectEqualStrings("> abcd", "> abcdefghijk"[storage[0].start..storage[0].end]);
    try std.testing.expectEqualStrings("efgh", "> abcdefghijk"[storage[1].start..storage[1].end]);
    try std.testing.expectEqualStrings("ijk", "> abcdefghijk"[storage[2].start..storage[2].end]);
}

test "quote draft exact edge caret row inherits gutter and hard newline resets" {
    var storage: [max_rows]Line = undefined;
    for ([_][]const u8{ "> abcd", "> abcd\nx" }) |raw| {
        const result = shape(raw, Bytes{ .bytes = raw }, 6, 6, 0);
        try std.testing.expectEqual(@as(usize, 1), result.caret_line);
        try std.testing.expectEqual(@as(u16, 2), result.caret_column);
        const count = quoteLines(raw, raw, 6, 6, &storage);
        try std.testing.expectEqual(result.lines, count);
        try std.testing.expectEqual(Line{ .start = 6, .end = 6, .cells = 0, .continuation = .{ .cells = 2, .depth = 1, .indent = 0 } }, storage[1]);
    }
    const raw = "> abcd\nx";
    const after = shape(raw, Bytes{ .bytes = raw }, 6, 7, 0);
    try std.testing.expectEqual(@as(usize, 1), after.caret_line);
    try std.testing.expectEqual(@as(u16, 0), after.caret_column);
    try std.testing.expectEqual(@as(usize, 2), quoteLines(raw, raw, 6, 7, &storage));
    try std.testing.expect(storage[1].continuation == null);
}

test "quote draft original tabs cannot become syntax through display normalization" {
    var storage: [max_rows]Line = undefined;
    for ([_][]const u8{ "\t> alpha beta gamma", ">\talpha beta gamma" }, [_][]const u8{ " > alpha beta gamma", "> alpha beta gamma" }) |raw, display| {
        const count = quoteLines(raw, display, 10, 0, &storage);
        try std.testing.expect(count > 1);
        for (storage[0..count]) |line| try std.testing.expect(line.continuation == null);
    }
    const raw = "> \talpha beta gamma";
    const shown = ">  alpha beta gamma";
    const count = quoteLines(raw, shown, 10, 0, &storage);
    try std.testing.expect(storage[1].continuation != null);
    try std.testing.expectEqual(@as(u16, 2), storage[1].prefixCells());
    var covered: usize = 0;
    var copy: [raw.len]u8 = undefined;
    for (storage[0..count]) |line| {
        @memcpy(copy[covered..line.end], raw[covered..line.end]);
        covered = line.end;
    }
    @memcpy(copy[covered..], raw[covered..]);
    try std.testing.expectEqualStrings(raw, &copy);
}

test "quote draft opacity is shared for top level and exact outer fenced code" {
    var storage: [64]Line = undefined;
    const raw = "````\n```\n> alpha beta gamma\n````\n> alpha beta gamma";
    const count = quoteLines(raw, raw, 10, 0, &storage);
    const outside = std.mem.lastIndexOf(u8, raw, "> alpha").?;
    var saw_after = false;
    for (storage[0..count]) |line| {
        if (line.start < outside) try std.testing.expect(line.continuation == null);
        if (line.start > outside) {
            try std.testing.expect(line.continuation != null);
            saw_after = true;
        }
    }
    try std.testing.expect(saw_after);
    const quoted = "> ~~~\n> > alpha beta gamma\n> ~~~\t\n> > actual nested quote";
    const rows = quoteLines(quoted, quoted, 12, 0, &storage);
    const code_start = std.mem.indexOf(u8, quoted, "> > alpha").?;
    const close = std.mem.indexOf(u8, quoted, "> ~~~\t").?;
    const actual = std.mem.indexOf(u8, quoted, "> > actual").?;
    var saw_code = false;
    var saw_nested = false;
    for (storage[0..rows]) |line| if (line.continuation) |value| {
        if (line.start > code_start and line.start < close) {
            try std.testing.expectEqual(@as(u4, 1), value.depth);
            saw_code = true;
        }
        if (line.start > actual) {
            try std.testing.expectEqual(@as(u4, 2), value.depth);
            saw_nested = true;
        }
    };
    try std.testing.expect(saw_code and saw_nested);
}

test "quote draft narrow and whole logical wide cluster fallback is literal" {
    const Wide = struct {
        inner: Bytes,
        pub fn next(self: *@This()) ?Piece {
            var piece = self.inner.next() orelse return null;
            if (piece.cells == 2) piece.cells = 4;
            return piece;
        }
    };
    const raw = "> abcd W abcdefghijkl";
    var storage: [max_rows]Line = undefined;
    const count = collect(raw, Wide{ .inner = .{ .bytes = raw } }, 5, 0, 0, &storage);
    for (storage[0..count]) |line| try std.testing.expect(line.continuation == null);
    for (1..5) |width| {
        const shown = quoteLines("> abcdef", "> abcdef", @intCast(width), 0, &storage);
        for (storage[0..shown]) |line| try std.testing.expectEqual(width >= 4 and line.start > 0, line.continuation != null);
    }
    const nested = "   > > alpha beta gamma";
    for (1..10) |width| {
        const rows = quoteLines(nested, nested, @intCast(width), 0, &storage);
        for (storage[0..rows]) |line| if (line.continuation) |value| {
            try std.testing.expect(width >= @as(usize, value.cells) + 2);
            const parts = line.gutter();
            try std.testing.expectEqualStrings("   ", parts[0]);
            try std.testing.expectEqualStrings(">>", parts[1]);
            try std.testing.expectEqual(@as(usize, value.cells), parts[0].len + parts[1].len + parts[2].len);
        };
    }
    std.debug.print("draft sizes Line={d} Shape={d} shown10={d} bytes\n", .{ @sizeOf(Line), @sizeOf(Shape), @sizeOf([max_rows]Line) });
    try std.testing.expect(@sizeOf(Line) <= 24);
}

test "quote draft width and source oracle spans every ASCII caret anchor and wrap" {
    const samples = [_][]const u8{
        "> alpha beta gamma",                                 "> abcd efghijklmnopqrst end",      "> ",                  ">",                 ">> ",
        "   > > abc defghijkl end\n> next line",              "> > > abcdefghijklmnopqrstuvwxyz", "> a       b       c", "> abcd\n\n> efghi", ">  abcdefghijklmnopqrst ",
        "```\n> literal code here\n```\n> actual prose here",
    };
    var storage: [128]Line = undefined;
    for (samples) |raw| for (1..22) |columns| for (0..raw.len + 1) |cursor| {
        const width: u16 = @intCast(columns);
        const count = quoteLines(raw, raw, width, cursor, &storage);
        const value = shape(raw, Bytes{ .bytes = raw }, width, cursor, 0);
        try std.testing.expectEqual(count, value.lines);
        var previous: usize = 0;
        for (storage[0..count]) |line| {
            try std.testing.expect(line.start >= previous and line.end >= line.start);
            for (raw[previous..line.start]) |byte| try std.testing.expect(byte == ' ' or byte == '\n');
            try std.testing.expect(line.cells + line.prefixCells() <= width);
            previous = line.end;
        }
        for (raw[previous..]) |byte| try std.testing.expect(byte == ' ' or byte == '\n');
        const caret = storage[value.caret_line];
        try std.testing.expect(value.caret_column < width);
        if (cursor <= caret.end) try std.testing.expectEqual(cursor - caret.start + caret.prefixCells(), value.caret_column);
        for (storage[0..count], 0..) |line, index| {
            const anchored = shape(raw, Bytes{ .bytes = raw }, width, cursor, line.start);
            // A shared boundary belongs to the last emitted row at that byte.
            var expected = index;
            while (expected + 1 < count and storage[expected + 1].start == line.start) expected += 1;
            try std.testing.expectEqual(expected, anchored.anchor_line);
        }
    };
}
