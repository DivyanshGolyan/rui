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
//! Nothing is stored per line: `shape` counts lines in one pass, and `fit`
//! walks only up to the shown ones.
const std = @import("std");

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
pub const Line = struct { start: usize, end: usize, cells: u16 };

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
    /// The full line a caret past its end follows on a row of its own;
    /// `lines` counts that row.
    caret_follows_line: ?usize = null,
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

/// Walks pieces into lines. `sink.line` receives each line in order with the
/// caret's column when byte `cursor` is on it, and returns whether to go on.
fn walk(pieces: anytype, width: u16, cursor: usize, sink: anytype) void {
    std.debug.assert(width > 0);
    var source = pieces;
    var offset: usize = 0;
    var start: usize = 0;
    var end: usize = 0;
    var cells: u16 = 0;
    // Cells of spaces hanging past the edge.
    var hanging: u16 = 0;
    var caret: ?u16 = null;
    // Where the line may break: after its last space, and, for a word too
    // wide for any line, after the word's last joint. The line then ends at
    // `end` with `cells`, and `columns` counts hanging spaces too.
    const Break = struct { at: usize, end: usize, cells: u16, columns: u16 };
    var soft: ?Break = null;
    var joint: ?Break = null;
    while (source.next()) |piece| {
        defer offset += piece.len;
        if (piece.kind != .newline and cells > 0 and @as(u32, cells) + hanging + piece.cells > width) {
            if (piece.kind == .space) {
                if (offset == cursor) caret = cells + hanging;
                hanging += piece.cells;
                soft = .{ .at = offset + piece.len, .end = end, .cells = cells, .columns = cells + hanging };
                continue;
            }
            // A joint breaks only a word still too wide after the space.
            inline for (.{ false, true }) |at_joint| if (!at_joint or @as(u32, cells) + piece.cells > width) {
                if (if (at_joint) joint else soft) |point| if (point.at > start) {
                    if (!sink.line(.{ .start = start, .end = point.end, .cells = point.cells }, if (cursor < point.at) caret else null)) return;
                    if (cursor < point.at) caret = null else if (caret) |column| caret = column - point.columns;
                    start = point.at;
                    cells -= point.cells;
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
            // The word after the break can still be too wide with this
            // piece: it then breaks here, at a cluster.
            if (cells > 0 and @as(u32, cells) + piece.cells > width) {
                if (!sink.line(.{ .start = start, .end = offset, .cells = cells }, caret)) return;
                caret = null;
                start = offset;
                cells = 0;
                joint = null;
            }
        }
        if (offset == cursor) caret = cells + hanging;
        if (piece.kind == .newline) {
            if (!sink.line(.{ .start = start, .end = end, .cells = cells }, caret)) return;
            caret = null;
            start = offset + piece.len;
            end = start;
            cells = 0;
            hanging = 0;
            soft = null;
            joint = null;
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
    if (offset == cursor) caret = cells + hanging;
    _ = sink.line(.{ .start = start, .end = end, .cells = cells }, caret);
}

/// Counts the lines of `pieces` at `width` cells, finds the line and column
/// of the caret at byte `cursor`, and the line that holds byte `anchor`. A
/// cursor on a soft break belongs to the line it starts.
pub fn shape(pieces: anytype, width: u16, cursor: usize, anchor: usize) Shape {
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
    walk(pieces, width, cursor, &counter);
    std.debug.assert(counter.found);
    var result = counter.result;
    result.lines = counter.count;
    if (result.caret_column >= width) {
        result.caret_follows_line = result.caret_line;
        result.caret_line += 1;
        result.caret_column = 0;
        result.lines += 1;
        if (result.anchor_line > result.caret_follows_line.?) result.anchor_line += 1;
    }
    return result;
}

/// Shows at most `limit` lines of a draft with `value`: fills `out` with
/// them, top to bottom, and returns which they are. The caller keeps
/// `out[0].start` as the next frame's anchor.
pub fn fit(pieces: anytype, width: u16, cursor: usize, value: Shape, limit: u16, out: *[max_rows]Line) View {
    const shown = view(value, @min(limit, max_rows));
    const count = collect(pieces, width, value, cursor, shown.first, out[0..shown.rows]);
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
fn collect(pieces: anytype, width: u16, value: Shape, cursor: usize, first: usize, out: []Line) usize {
    const Collector = struct {
        first: usize,
        after: ?usize,
        out: []Line,
        index: usize = 0,
        filled: usize = 0,

        fn line(self: *@This(), walked: Line, _: ?u16) bool {
            self.put(walked);
            if (self.after == self.index - 1) self.put(.{ .start = walked.end, .end = walked.end, .cells = 0 });
            return self.index < self.first + self.out.len;
        }

        fn put(self: *@This(), walked: Line) void {
            defer self.index += 1;
            if (self.index < self.first or self.index - self.first >= self.out.len) return;
            self.out[self.index - self.first] = walked;
            self.filled += 1;
        }
    };
    var collector: Collector = .{ .first = first, .after = value.caret_follows_line, .out = out };
    walk(pieces, width, cursor, &collector);
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
    const whole = shape(Bytes{ .bytes = text }, width, 0, 0);
    const count = collect(Bytes{ .bytes = text }, width, whole, 0, 0, &storage);
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
    const before = shape(Bytes{ .bytes = "abcd ef" }, 4, 4, 0);
    try std.testing.expectEqual(Shape{ .lines = 3, .caret_line = 1, .caret_column = 0, .caret_follows_line = 0 }, before);
    const after = shape(Bytes{ .bytes = "abcd ef" }, 4, 5, 0);
    try std.testing.expectEqual(Shape{ .lines = 2, .caret_line = 1, .caret_column = 0 }, after);
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
        const got = shape(Bytes{ .bytes = text }, 10, case.cursor, 0);
        try std.testing.expectEqual(@as(usize, 3), got.lines);
        try std.testing.expectEqual(case.line, got.caret_line);
        try std.testing.expectEqual(case.column, got.caret_column);
    }
}

test "a caret after a line that fills the width gets a row of its own" {
    var storage: [8]Line = undefined;
    for ([_][]const u8{ "abcdef", "abcdef\nx" }) |text| {
        const got = shape(Bytes{ .bytes = text }, 6, 6, 0);
        try std.testing.expectEqual(@as(usize, 1), got.caret_line);
        try std.testing.expectEqual(@as(u16, 0), got.caret_column);
        const count = collect(Bytes{ .bytes = text }, 6, got, 6, 0, &storage);
        try std.testing.expectEqual(got.lines, count);
        try std.testing.expectEqual(@as(usize, 6), storage[1].start);
        try std.testing.expectEqual(@as(usize, 6), storage[1].end);
    }
    // Short of the width, the caret stays on its line.
    const short = shape(Bytes{ .bytes = "abcde" }, 6, 5, 0);
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
    const wide = shape(Bytes{ .bytes = text }, 9, text.len, 8);
    try std.testing.expectEqual(@as(usize, 1), wide.anchor_line);
    // At width 5 "three" is the third line, and still shown first.
    const narrow = shape(Bytes{ .bytes = text }, 5, 8, 8);
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
    const whole = shape(Bytes{ .bytes = text }, 4, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), collect(Counted{ .inner = .{ .bytes = text }, .calls = &calls }, 4, whole, 0, 0, &storage));
    try std.testing.expect(calls < 8);
}

test "every cursor of every draft lands in the view, on its own bytes, at every width, limit and anchor" {
    const texts = [_][]const u8{ "", "a", "abc def ghi", "abcdefghijkl", "a\n\nb c d e f g h", "word  word\n  x", "abcdef\nabcdef", "      ", "aW Wb WWW a", "abcd efgh ij", "a/b.cd-efg/h ij/k", "W/WW.W a/" };
    var storage: [64]Line = undefined;
    var whole_storage: [64]Line = undefined;
    for (texts) |text| for (2..9) |w| for (1..4) |limit| for (0..text.len + 1) |cursor| {
        const width: u16 = @intCast(w);
        const bare = shape(Bytes{ .bytes = text }, width, cursor, 0);
        try std.testing.expect(bare.caret_column < width);
        const whole = collect(Bytes{ .bytes = text }, width, bare, cursor, 0, &whole_storage);
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
        if (bare.caret_follows_line == null) {
            const line = whole_storage[bare.caret_line];
            try std.testing.expect(line.start <= cursor and cursor <= line.end);
            try std.testing.expectEqual(cellsOf(text[line.start..cursor]), bare.caret_column);
        } else try std.testing.expectEqual(bare.caret_follows_line.? + 1, bare.caret_line);
        for (0..whole) |previous| {
            if (bare.caret_follows_line) |after| if (previous == after + 1) continue;
            const got = shape(Bytes{ .bytes = text }, width, cursor, whole_storage[previous].start);
            try std.testing.expectEqual(previous, got.anchor_line);
            const shown = view(got, @intCast(limit));
            try std.testing.expect(shown.first <= got.caret_line and got.caret_line < shown.first + shown.rows);
            // The view stays where it was while the caret is in it.
            if (previous + shown.rows <= got.lines and previous <= got.caret_line and got.caret_line < previous + shown.rows)
                try std.testing.expectEqual(previous, shown.first);
            const count = collect(Bytes{ .bytes = text }, width, got, cursor, shown.first, storage[0..shown.rows]);
            try std.testing.expectEqual(@as(usize, shown.rows), count);
            try std.testing.expectEqualSlices(Line, whole_storage[shown.first..][0..shown.rows], storage[0..shown.rows]);
        }
    };
}
