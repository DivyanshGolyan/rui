//! What a pointer over the Transcript's laid-out rows means in retained
//! text: which bytes a drag selects, what a click opens, and what a release
//! copies. Values only; the Transcript tracks the pointer and draws.
const std = @import("std");
const vaxis = @import("vaxis");
const viewport = @import("ConversationViewport.zig");
const TerminalText = @import("TerminalText.zig");
const Document = viewport.Document;

/// A cell's place in the retained text, in absolute offsets (the document's
/// origin plus the byte), so scrolling and eviction never move it. A cell
/// showing text spans its cluster; any other cell is the point between the
/// text before and after it.
pub const Spot = struct {
    start: u64,
    end: u64,

    pub fn point(at: u64) Spot {
        return .{ .start = at, .end = at };
    }
};

/// The text between two spots, whichever comes first.
pub const Range = struct {
    from: u64,
    to: u64,

    pub fn of(anchor: Spot, head: Spot) Range {
        return .{ .from = @min(anchor.start, head.start), .to = @max(anchor.end, head.end) };
    }

    fn covers(self: Range, spot: Spot) bool {
        return if (spot.start == spot.end) self.from <= spot.start and spot.start < self.to else spot.start < self.to and spot.end > self.from;
    }
};

/// One row laid out from the document's current text. `line` is its logical
/// line's offset in that text, or null for a row below the text.
pub const Row = struct {
    document: *const Document,
    cells: []const vaxis.Cell,
    line: ?usize,

    /// The spot under column `col`. Before the row's text it is the text's
    /// start; past its last cell, the text's end; on a row with no body text
    /// (empty, or only a margin time), its line's start.
    pub fn spot(self: Row, col: i32) Spot {
        const end = self.document.origin + self.document.text().len;
        const line = self.line orelse return Spot.point(end);
        var spots: Spots = .init(self);
        const boundary = spots.boundary orelse return Spot.point(self.document.origin + line);
        var column: i32 = 0;
        var found: Spot = Spot.point(boundary);
        while (spots.next()) |value| : (column += 1) {
            found = value;
            if (column >= col) return found;
        }
        return Spot.point(found.end);
    }

    /// Sets `columns[i]` for each column whose spot `range` covers.
    pub fn covered(self: Row, range: Range, columns: []bool) void {
        var spots: Spots = .init(self);
        if (spots.boundary == null) spots.boundary = self.document.origin + (self.line orelse self.document.text().len);
        for (columns) |*column| column.* = range.covers(spots.next().?);
    }
};

/// Each cell's spot along a row, left to right.
const Spots = struct {
    row: Row,
    /// The spot of cells before any text, and after the last.
    boundary: ?u64,
    covered: usize = 0,
    cover: Spot = undefined,
    column: usize = 0,

    fn init(row: Row) Spots {
        var spots: Spots = .{ .row = row, .boundary = null };
        for (row.cells) |cell| {
            if (source(row.document, cell)) |at| {
                spots.boundary = at;
                break;
            }
        }
        return spots;
    }

    fn next(self: *Spots) ?Spot {
        if (self.column == self.row.cells.len) return null;
        defer self.column += 1;
        const cell = self.row.cells[self.column];
        if (source(self.row.document, cell)) |at| {
            self.cover = .{ .start = at, .end = at + cell.char.grapheme.len };
            self.covered = self.column + @max(cell.char.width, 1);
            self.boundary = self.cover.end;
            return self.cover;
        }
        if (self.column < self.covered) return self.cover;
        return Spot.point(self.boundary orelse return null);
    }
};

/// Where a cell's cluster starts, as an absolute offset, or null for a cell
/// that shows no body text: blank, indent, margin time, `…` or `┆`. Laid
/// out from the current text, a text cell's grapheme points into it.
fn source(document: *const Document, cell: vaxis.Cell) ?u64 {
    const address = @intFromPtr(cell.char.grapheme.ptr);
    const base = @intFromPtr(&document.bytes);
    if (cell.char.grapheme.len == 0 or address < base or address >= base + document.text().len) return null;
    const offset = address - base;
    if (!document.selectable(offset)) return null;
    return document.origin + offset;
}

/// An absolute offset in the current text, or null once it has left it.
pub fn relative(document: *const Document, at: u64) ?usize {
    if (at < document.origin) return null;
    const offset = at - document.origin;
    return if (offset <= document.text().len) @intCast(offset) else null;
}

/// An absolute offset clamped to the current text: evicted text is its start.
fn retained(document: *const Document, at: u64) usize {
    if (at <= document.origin) return 0;
    return @intCast(@min(at - document.origin, document.text().len));
}

/// A click on a peer's name opens its Session; any other click is on its row.
pub fn opens(document: *const Document, spot: Spot) ?[]const u8 {
    if (spot.start == spot.end) return null;
    return document.sessionAt(relative(document, spot.start) orelse return null);
}

pub const Copy = union(enum) {
    /// The range shows no text.
    nothing,
    /// More than the clipboard takes: nothing is copied.
    too_large,
    /// The bytes to copy, the caller's to free, and how many lines they hold.
    text: struct { bytes: []u8, lines: usize },
};

/// What releasing a drag over `range` copies: the text as shown, at most
/// the clipboard limit. Text that has left the document is skipped.
pub fn copy(gpa: std.mem.Allocator, document: *const Document, range: Range) !Copy {
    const from = retained(document, range.from);
    const to = retained(document, range.to);
    if (from >= to) return .nothing;
    const bytes = try document.shownText(gpa, from, to, TerminalText.clipboard_limit) orelse return .too_large;
    if (bytes.len == 0) {
        gpa.free(bytes);
        return .nothing;
    }
    var lines: usize = 1 + std.mem.count(u8, bytes, "\n");
    if (bytes[bytes.len - 1] == '\n') lines -= 1;
    return .{ .text = .{ .bytes = bytes, .lines = lines } };
}

/// What the status bar says after a copy, or null when it says nothing.
pub fn notice(result: Copy, buffer: *[64]u8) ?[]const u8 {
    return switch (result) {
        .nothing => null,
        .too_large => "Too large for the clipboard · /copy file",
        .text => |text| std.fmt.bufPrint(buffer, "Copied {d} line{s}", .{ text.lines, if (text.lines == 1) "" else "s" }) catch unreachable,
    };
}

/// Lays out `count` rows from `first` at `width` columns, as the Transcript
/// draws them, and returns the cells.
fn layOut(document: *const Document, first: viewport.Position, width: u16, count: u16, cells: []vaxis.Cell) void {
    @memset(cells, .{});
    var screen: vaxis.Screen = .{ .width = width, .height = count, .width_method = .unicode, .buf = cells };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = count, .screen = &screen };
    _ = document.draw(window, first, true, false, .{}, .default);
}

test "a row's columns map to the clusters they show, indents and wide cells included" {
    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    // At 10 columns "• 雪 fall fast" wraps: "• 雪 fall" then a hanging "  fast".
    // Spaces are drawn from no text byte: each is the point after the text
    // before it.
    try document.append("• 雪 fall fast\n\nend");
    try document.prepare();
    var cells: [10 * 4]vaxis.Cell = undefined;
    layOut(document, .{}, 10, 4, &cells);
    const text = document.text();
    const snow = std.mem.indexOf(u8, text, "雪").?;
    const fast = std.mem.indexOf(u8, text, "fast").?;
    const first: Row = .{ .document = document, .cells = cells[0..10], .line = 0 };
    // Both cells of the wide cluster span it.
    try std.testing.expectEqual(Spot{ .start = snow, .end = snow + "雪".len }, first.spot(2));
    try std.testing.expectEqual(Spot{ .start = snow, .end = snow + "雪".len }, first.spot(3));
    // Past the row's text: the point after its last cluster.
    try std.testing.expectEqual(Spot.point(fast - 1), first.spot(20));
    // The hanging indent is the point before the row's first text.
    const wrapped: Row = .{ .document = document, .cells = cells[10..20], .line = 0 };
    try std.testing.expectEqual(Spot.point(fast), wrapped.spot(0));
    try std.testing.expectEqual(Spot{ .start = fast, .end = fast + 1 }, wrapped.spot(2));
    // An empty line is its start; below the text, the text's end.
    const empty: Row = .{ .document = document, .cells = cells[20..30], .line = fast + "fast\n".len };
    try std.testing.expectEqual(Spot.point(fast + "fast\n".len), empty.spot(4));
    const below: Row = .{ .document = document, .cells = cells[30..40], .line = null };
    try std.testing.expectEqual(Spot.point(text.len), below.spot(0));
    // From the bullet's text to "f" of "fast": its cells and the indent between.
    var columns: [10]bool = undefined;
    const range = Range.of(first.spot(2), wrapped.spot(2));
    first.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, true, true, true, true, true, true, true }, &columns);
    wrapped.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, false, false, false, false, false, false }, &columns);
    empty.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &@as([10]bool, @splat(false)), &columns);
}

test "a release copies the shown text with its line count, within the clipboard limit" {
    const gpa = std.testing.allocator;
    const document = try gpa.create(Document);
    defer gpa.destroy(document);
    document.* = .{};
    try document.append("one\ntwo\nthree\n");
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { from: u64, to: u64, text: []const u8, notice: []const u8 }{
        .{ .from = 0, .to = 3, .text = "one", .notice = "Copied 1 line" },
        // A selection ending at a newline copies it but adds no line.
        .{ .from = 0, .to = 4, .text = "one\n", .notice = "Copied 1 line" },
        .{ .from = 2, .to = 9, .text = "e\ntwo\nt", .notice = "Copied 3 lines" },
    };
    for (cases) |case| {
        const result = try copy(gpa, document, .{ .from = case.from, .to = case.to });
        defer gpa.free(result.text.bytes);
        try std.testing.expectEqualStrings(case.text, result.text.bytes);
        try std.testing.expectEqualStrings(case.notice, notice(result, &buffer).?);
    }
    try std.testing.expectEqual(Copy.nothing, try copy(gpa, document, .{ .from = 5, .to = 5 }));
    try std.testing.expectEqual(@as(?[]const u8, null), notice(.nothing, &buffer));
    // Text evicted under a held drag is skipped: a range wholly before the
    // retained text copies nothing, and one across its start copies the rest.
    document.discardFront(8);
    try std.testing.expectEqual(Copy.nothing, try copy(gpa, document, .{ .from = 0, .to = 4 }));
    const across = try copy(gpa, document, .{ .from = 2, .to = 10 });
    defer gpa.free(across.text.bytes);
    try std.testing.expectEqualStrings("th", across.text.bytes);
    // Exactly the limit copies; one byte more copies nothing.
    document.clear();
    for (0..TerminalText.clipboard_limit / 1000) |_| try document.append(&@as([1000]u8, @splat('x')));
    try document.append("y");
    const whole = try copy(gpa, document, .{ .from = 0, .to = TerminalText.clipboard_limit });
    defer gpa.free(whole.text.bytes);
    try std.testing.expectEqual(TerminalText.clipboard_limit, whole.text.bytes.len);
    const over = try copy(gpa, document, .{ .from = 0, .to = TerminalText.clipboard_limit + 1 });
    try std.testing.expectEqual(Copy.too_large, over);
    try std.testing.expectEqualStrings("Too large for the clipboard · /copy file", notice(over, &buffer).?);
}

test "only a click on a peer's name opens its Session" {
    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("\x1b[2;8m← Received message from " ++ TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\n");
    const at = std.mem.indexOf(u8, document.text(), "Plan").?;
    try std.testing.expectEqualStrings("k7m2qx", opens(document, .{ .start = at + 3, .end = at + 4 }).?);
    // The point after the name, and the text before it, open nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), opens(document, Spot.point(at)));
    try std.testing.expectEqual(@as(?[]const u8, null), opens(document, .{ .start = at - 1, .end = at }));
}
