//! Bounded display text, independent of canonical history and terminal cells.
//! vaxis lays out and draws rows (`Window.print`); this module keeps retained
//! bytes, trusted styles and which row of which logical line a view starts at.
const std = @import("std");
const vaxis = @import("vaxis");
const gwidth = @import("terminal_width");
const unicode = @import("terminal_unicode");
pub const Document = Sized(capacity, true);
pub const Method = gwidth.Method;

pub const capacity = 256 * 1024;
/// Clusters wider than the narrowest supported terminal are shown escaped.
pub const widest_cluster = 8;
/// Longer clusters (for example thousands of combining marks) are shown
/// escaped too: every frame that draws a cell writes its whole cluster.
pub const longest_cluster = 64;

/// A row of laid-out text: the logical line starting at origin-relative byte
/// `offset`, and the row within that line's wrapping.
pub const Position = struct {
    offset: usize = 0,
    row: u16 = 0,
    /// Past every row; a view that has shown this far has shown everything.
    pub const end: Position = .{ .offset = std.math.maxInt(usize) };

    pub fn order(a: Position, b: Position) std.math.Order {
        const lines = std.math.order(a.offset, b.offset);
        return if (lines != .eq) lines else std.math.order(a.row, b.row);
    }

    pub fn min(a: Position, b: Position) Position {
        return if (a.order(b) == .gt) b else a;
    }
};

/// The width and width method vaxis lays text out with.
pub const Layout = struct {
    width: u16,
    method: gwidth.Method,

    /// A window that only measures: print with `commit = false` never writes.
    fn measuring(self: Layout, screen: *vaxis.Screen) vaxis.Window {
        screen.* = .{ .width = self.width, .height = std.math.maxInt(u16), .width_method = self.method };
        return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = self.width, .height = std.math.maxInt(u16), .screen = screen };
    }
};

pub fn representable(cluster: []const u8, method: gwidth.Method) bool {
    if (std.mem.eql(u8, cluster, "\n") or std.mem.eql(u8, cluster, "\t")) return true;
    if (cluster.len > longest_cluster) return false;
    const cells = gwidth.gwidth(cluster, method);
    return cells != 0 and cells <= widest_cluster;
}

/// Rows used by a print that ended at `result`. A row is used once text
/// reaches it; an exact fill leaves the next row unused.
fn rowsUsed(result: vaxis.Window.PrintResult) u16 {
    return if (result.col == 0 and result.row != 0) result.row else result.row +| 1;
}

/// The draft's caret cell when vaxis prints `prefix` with grapheme wrapping.
pub fn caret(layout: Layout, prefix: []const u8) struct { row: u16, col: u16 } {
    var screen: vaxis.Screen = undefined;
    const result = layout.measuring(&screen).print(&.{.{ .text = prefix }}, .{ .wrap = .grapheme, .commit = false });
    return .{ .row = result.row, .col = result.col };
}

/// Draft rows, including an empty row after a final newline or exact fill.
pub fn draftRows(layout: Layout, draft: []const u8) u16 {
    return caret(layout, draft).row +| 1;
}

/// Leading spaces and a list or role marker stay in the first row;
/// continuation rows start under the text after them, up to half the width.
/// A user line never hangs left of its body column: position alone must
/// distinguish user text where the terminal shows no attributes.
fn hanging(line: []const u8, width: u16, user: bool) struct { bytes: usize, cells: u16 } {
    var bytes: usize = 0;
    while (bytes < line.len and line[bytes] == ' ') bytes += 1;
    var cells: usize = bytes;
    for ([_][]const u8{ "›", "•", "◦", "✓", "!", "?", "-", "*", "$" }) |glyph| {
        if (std.mem.startsWith(u8, line[bytes..], glyph) and std.mem.startsWith(u8, line[bytes + glyph.len ..], " ")) {
            bytes += glyph.len + 1;
            cells += 2;
            break;
        }
    }
    if (cells * 2 > width) {
        if (user and width >= 4 and std.mem.startsWith(u8, line, "  ")) return .{ .bytes = 2, .cells = 2 };
        return .{ .bytes = 0, .cells = 0 };
    }
    return .{ .bytes = bytes, .cells = @intCast(cells) };
}

/// Retained style byte, display-only: bits 0-2 bold, italic and underline,
/// bits 3-5 a foreground index, bit 6 user text and bit 7 its dim summary.
const foregrounds = [_]u8{ 3, 8, 9, 12 };
const foreground_mask: u8 = 0b111 << 3;
const user_bit: u8 = 1 << 6;
const summary_bit: u8 = 1 << 7;
pub const CellStyle = struct { bold: bool = false, dim: bool = false, italic: bool = false, underline: bool = false, foreground: ?u8 = null };
/// User text is dim and italic only with colour; without it, position alone
/// sets it apart. Its summary is dim but never italic.
pub fn cellStyle(value: u8, colour: bool) CellStyle {
    const index = (value & foreground_mask) >> 3;
    const user = colour and value & user_bit != 0;
    const summary = value & summary_bit != 0;
    return .{
        .bold = value & 1 != 0,
        .dim = user,
        .italic = value & 2 != 0 or (user and !summary),
        .underline = value & 4 != 0,
        .foreground = if (colour and index != 0) foregrounds[index - 1] else null,
    };
}

pub fn Sized(comptime limit: usize, comptime styled: bool) type {
    return struct {
        const Self = @This();
        bytes: [limit]u8 = undefined,
        styles: [if (styled) limit else 0]u8 = undefined,
        style: u8 = 0,
        control: [8]u8 = undefined,
        control_length: usize = 0,
        length: usize = 0,
        origin: u64 = 0,
        /// The first row in view; null follows the latest rows.
        top: ?Position = null,
        width_method: gwidth.Method = .wcwidth,
        dirty: bool = true,

        pub fn append(self: *Self, input: []const u8) !void {
            if (!styled) return self.appendText(input);
            // Only presentation-owned SGR reaches this sink. Source controls have
            // already been escaped; no cursor, OSC or terminal-emulator state exists.
            var start: usize = 0;
            for (input, 0..) |byte, index| {
                if (self.control_length != 0 or byte == 0x1b) {
                    try self.appendText(input[start..index]);
                    std.debug.assert(self.control_length < self.control.len);
                    self.control[self.control_length] = byte;
                    self.control_length += 1;
                    if (byte == 'm') {
                        const code = self.control[0..self.control_length];
                        if (std.mem.eql(u8, code, "\x1b[0m")) self.style = 0 else if (std.mem.eql(u8, code, "\x1b[1m")) self.style |= 1 else if (std.mem.eql(u8, code, "\x1b[3m")) self.style |= 2 else if (std.mem.eql(u8, code, "\x1b[4m")) self.style |= 4 else if (std.mem.eql(u8, code, "\x1b[2m")) self.style |= user_bit else if (std.mem.eql(u8, code, "\x1b[2;8m")) self.style |= user_bit | summary_bit else if (std.mem.eql(u8, code, "\x1b[39m")) self.style &= ~foreground_mask else {
                            const colour_index: u8 = if (std.mem.eql(u8, code, "\x1b[33m")) 1 else if (std.mem.eql(u8, code, "\x1b[90m")) 2 else if (std.mem.eql(u8, code, "\x1b[91m")) 3 else if (std.mem.eql(u8, code, "\x1b[94m")) 4 else unreachable;
                            self.style = (self.style & ~foreground_mask) | (colour_index << 3);
                        }
                        self.control_length = 0;
                    }
                    start = index + 1;
                }
            }
            try self.appendText(input[start..]);
        }

        fn appendText(self: *Self, input: []const u8) !void {
            var position: usize = 0;
            while (position < input.len) {
                if (self.length == limit) {
                    const wanted = @min(input.len - position, limit);
                    var discard: usize = 0;
                    var clusters = unicode.graphemeIterator(self.text());
                    while (clusters.next()) |cluster| {
                        discard = cluster.start;
                        if (discard >= wanted) break;
                    }
                    // Keep the last cluster and incomplete scalar: the next
                    // window can extend them with combining, RI or ZWJ bytes.
                    if (discard == 0) return error.DisplayGraphemeTooLarge;
                    std.mem.copyForwards(u8, &self.bytes, self.bytes[discard..self.length]);
                    if (styled) std.mem.copyForwards(u8, &self.styles, self.styles[discard..self.length]);
                    self.length -= discard;
                    self.origin += discard;
                }
                const count = @min(input.len - position, limit - self.length);
                @memcpy(self.bytes[self.length..][0..count], input[position..][0..count]);
                if (styled) @memset(self.styles[self.length..][0..count], self.style);
                self.length += count;
                position += count;
            }
            // Input windows can split UTF-8. Keep the suffix until the next append;
            // indexing below only visits complete scalars.
            self.dirty = true;
        }

        pub fn clear(self: *Self) void {
            self.length = 0;
            self.origin = 0;
            self.top = null;
            self.style = 0;
            self.control_length = 0;
            self.dirty = true;
        }

        pub fn text(self: *const Self) []const u8 {
            var end = self.length;
            if (end != 0) {
                var start = end - 1;
                while (start > 0 and self.bytes[start] & 0xc0 == 0x80) start -= 1;
                const n = std.unicode.utf8ByteSequenceLength(self.bytes[start]) catch 1;
                if (end - start < n) end = start;
            }
            return self.bytes[0..end];
        }

        /// Output has no canonical byte offsets: escape standalone invisible
        /// and oversized clusters in this display copy, never in saved content
        /// or input.
        pub fn prepare(self: *Self) !void {
            if (self.dirty) try self.escape();
            self.dirty = false;
        }

        fn escape(self: *Self) !void {
            var search = unicode.graphemeIterator(self.text());
            while (search.next()) |cluster| {
                const raw_cluster = cluster.bytes(self.text());
                if (std.mem.eql(u8, raw_cluster, "\n") or std.mem.eql(u8, raw_cluster, "\t") or representable(raw_cluster, self.width_method)) continue;
                const length = self.length;
                var bytes: [limit]u8 = undefined;
                var styles: [if (styled) limit else 0]u8 = undefined;
                @memcpy(bytes[0..length], self.bytes[0..length]);
                if (styled) @memcpy(styles[0..length], self.styles[0..length]);
                const complete = self.text().len;
                const saved_style = self.style;
                defer self.style = saved_style;
                self.length = 0;
                var clusters = unicode.graphemeIterator(bytes[0..complete]);
                while (clusters.next()) |value| {
                    if (styled) self.style = styles[value.start];
                    const raw = value.bytes(bytes[0..complete]);
                    if (std.mem.eql(u8, raw, "\n") or std.mem.eql(u8, raw, "\t") or representable(raw, self.width_method)) {
                        try self.appendText(raw);
                    } else {
                        // A run of one scalar is shown once with its count.
                        var scalars = (try std.unicode.Utf8View.init(raw)).iterator();
                        var run: ?u21 = null;
                        var count: usize = 0;
                        while (true) {
                            const point = scalars.nextCodepoint();
                            if (run != null and point == run) {
                                count += 1;
                                continue;
                            }
                            if (run) |previous| {
                                var escaped: [40]u8 = undefined;
                                try self.appendText(if (count == 1) try std.fmt.bufPrint(&escaped, "\\u{{{x}}}", .{previous}) else try std.fmt.bufPrint(&escaped, "\\u{{{x}}}×{d}", .{ previous, count }));
                            }
                            run = point orelse break;
                            count = 1;
                        }
                    }
                }
                if (styled and complete < length) self.style = styles[complete];
                try self.appendText(bytes[complete..length]);
                return;
            }
        }

        /// Where the line starting at `offset` ends (its newline or the text end).
        pub fn lineEnd(self: *const Self, offset: usize) usize {
            const bytes = self.text();
            return std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
        }

        pub fn nextLine(self: *const Self, offset: usize) ?usize {
            const next = self.lineEnd(offset) + 1;
            return if (next < self.text().len) next else null;
        }

        pub fn previousLine(self: *const Self, offset: usize) ?usize {
            if (offset == 0) return null;
            return if (std.mem.lastIndexOfScalar(u8, self.bytes[0 .. offset - 1], '\n')) |line| line + 1 else 0;
        }

        /// Prints one logical line with its first row at window row `row`
        /// (negative rows are clipped), or only measures it. Returns its rows.
        /// Measuring and drawing segment identically, so they wrap identically.
        pub fn printLine(self: *const Self, window: vaxis.Window, row: i17, offset: usize, commit: bool, colour: bool, plain: vaxis.Style) u16 {
            const end = self.lineEnd(offset);
            const user = styled and for (self.styles[offset..end]) |value| {
                if (value & user_bit != 0) break true;
            } else false;
            const split = hanging(self.bytes[offset..end], window.width, user);
            if (commit) _ = self.printRange(window.child(.{ .y_off = row, .height = 1 }), offset, offset + split.bytes, .none, true, colour, plain);
            return rowsUsed(self.printRange(window.child(.{ .x_off = split.cells, .y_off = row }), offset + split.bytes, end, .word, commit, colour, plain));
        }

        /// Prints bytes as style runs, a bounded batch of segments at a time.
        fn printRange(self: *const Self, window: vaxis.Window, from: usize, end: usize, wrap: @FieldType(vaxis.PrintOptions, "wrap"), commit: bool, colour: bool, plain: vaxis.Style) vaxis.Window.PrintResult {
            var segments: [32]vaxis.Segment = undefined;
            var count: usize = 0;
            var result: vaxis.Window.PrintResult = .{ .row = 0, .col = 0, .overflow = false };
            var start = from;
            while (start < end) {
                var stop = end;
                if (styled) {
                    stop = start + 1;
                    while (stop < end and self.styles[stop] == self.styles[start]) stop += 1;
                }
                segments[count] = .{ .text = self.bytes[start..stop], .style = self.segmentStyle(start, colour, plain) };
                count += 1;
                start = stop;
                if (count == segments.len or start == end) {
                    result = window.print(segments[0..count], .{ .wrap = wrap, .row_offset = result.row, .col_offset = result.col, .commit = commit });
                    count = 0;
                    if (result.overflow) break;
                }
            }
            return result;
        }

        fn segmentStyle(self: *const Self, position: usize, colour: bool, plain: vaxis.Style) vaxis.Style {
            if (!styled) return plain;
            const value = cellStyle(self.styles[position], colour);
            return .{ .bold = value.bold, .dim = value.dim, .italic = value.italic, .ul_style = if (value.underline) .single else .off, .fg = if (value.foreground) |index| .{ .index = index } else .default };
        }

        pub fn lineRows(self: *const Self, layout: Layout, offset: usize) u16 {
            var screen: vaxis.Screen = undefined;
            return self.printLine(layout.measuring(&screen), 0, offset, false, false, .{});
        }

        /// Draws rows from `first` into `window`; returns the rows drawn and
        /// the first row left undrawn, or `Position.end` when none remain.
        pub fn draw(self: *const Self, window: vaxis.Window, from: Position, commit: bool, colour: bool, plain: vaxis.Style) struct { rows: usize, next: Position } {
            if (self.text().len == 0) return .{ .rows = 0, .next = .end };
            var row: i32 = -@as(i32, from.row);
            var line: ?usize = from.offset;
            while (line) |offset| : (line = self.nextLine(offset)) {
                if (row >= window.height) return .{ .rows = window.height, .next = .{ .offset = offset } };
                const used = self.printLine(window, @intCast(row), offset, commit, colour, plain);
                if (row + used > window.height) return .{ .rows = window.height, .next = .{ .offset = offset, .row = @intCast(window.height - row) } };
                row += used;
            }
            return .{ .rows = @intCast(row), .next = .end };
        }

        /// Rows from `from` that fit `height`, without drawing.
        pub fn measure(self: *const Self, layout: Layout, from: Position, height: u16) struct { rows: usize, next: Position } {
            var screen: vaxis.Screen = undefined;
            var window = layout.measuring(&screen);
            window.height = height;
            const result = self.draw(window, from, false, false, .{});
            return .{ .rows = result.rows, .next = result.next };
        }

        /// Keeps a position inside the current text and wrapping.
        pub fn clamp(self: *const Self, layout: Layout, position: Position) Position {
            if (position.offset >= self.text().len) return self.lastRow(layout);
            return .{ .offset = position.offset, .row = @min(position.row, self.lineRows(layout, position.offset) - 1) };
        }

        fn lastRow(self: *const Self, layout: Layout) Position {
            const bytes = self.text();
            if (bytes.len == 0) return .{};
            const last = self.previousLine(if (bytes[bytes.len - 1] == '\n') bytes.len else bytes.len + 1) orelse 0;
            return .{ .offset = last, .row = self.lineRows(layout, last) - 1 };
        }

        pub fn down(self: *const Self, layout: Layout, from: Position, moves: usize) Position {
            var position = self.clamp(layout, from);
            var remaining = moves;
            while (remaining != 0) {
                const used = self.lineRows(layout, position.offset);
                if (remaining < used - position.row) {
                    position.row += @intCast(remaining);
                    break;
                }
                remaining -= used - position.row;
                position = .{ .offset = self.nextLine(position.offset) orelse return .{ .offset = position.offset, .row = used - 1 } };
            }
            return position;
        }

        pub fn up(self: *const Self, layout: Layout, from: Position, moves: usize) Position {
            var position = self.clamp(layout, from);
            var remaining = moves;
            while (remaining > position.row) {
                remaining -= position.row + 1;
                const previous = self.previousLine(position.offset) orelse return .{ .offset = position.offset };
                position = .{ .offset = previous, .row = self.lineRows(layout, previous) - 1 };
            }
            position.row -= @intCast(remaining);
            return position;
        }

        /// The first row that shows the last `height` rows.
        pub fn bottom(self: *const Self, layout: Layout, height: usize) Position {
            return self.up(layout, self.lastRow(layout), height -| 1);
        }

        pub fn first(self: *const Self, layout: Layout, height: usize) Position {
            const last = self.bottom(layout, height);
            return if (self.top) |top| self.clamp(layout, top).min(last) else last;
        }

        /// Moves by `rows` (a page is the view height). Key repeat may deliver
        /// many events before a frame: never skip unread Action rows; only
        /// delivered frames advance that cap.
        pub fn browse(self: *Self, layout: Layout, down_: bool, rows_: usize, height: usize, first_unseen: ?Position) void {
            const current = self.first(layout, height);
            if (!down_) {
                self.top = self.up(layout, current, rows_);
                return;
            }
            const moved = self.down(layout, current, rows_).min(self.bottom(layout, height));
            self.top = if (first_unseen) |unseen| moved.min(unseen) else moved;
        }

        pub fn atTop(self: *const Self, layout: Layout, height: usize) bool {
            return self.first(layout, height).order(.{}) == .eq;
        }

        pub fn atBottom(self: *const Self, layout: Layout, height: usize) bool {
            return self.first(layout, height).order(self.bottom(layout, height)) != .lt;
        }

        /// Drops retained bytes before `position` (an absolute offset that
        /// starts a line), as eviction would. Positions are origin-relative.
        pub fn discardFront(self: *Self, position: u64) void {
            if (position <= self.origin) return;
            const count: usize = @intCast(@min(position - self.origin, self.length));
            std.mem.copyForwards(u8, &self.bytes, self.bytes[count..self.length]);
            if (styled) std.mem.copyForwards(u8, &self.styles, self.styles[count..self.length]);
            self.length -= count;
            self.origin += count;
            self.top = null;
            self.dirty = true;
        }

        /// Places complete older text before this text, keeping the same rows
        /// in view. Newer bytes beyond capacity leave from the end at a line
        /// boundary; returns whether any did.
        pub fn prepend(self: *Self, older: anytype, layout: Layout, height: usize) !bool {
            std.debug.assert(older.control_length == 0 and older.length <= limit);
            try self.prepare();
            const anchor = self.first(layout, height);
            var keep = self.text().len;
            if (older.length + keep > limit) {
                keep = limit - older.length;
                keep = if (std.mem.lastIndexOfScalar(u8, self.bytes[0..keep], '\n')) |line| line + 1 else 0;
            }
            const trimmed = keep != self.text().len or self.control_length != 0;
            std.mem.copyBackwards(u8, self.bytes[older.length..][0..keep], self.bytes[0..keep]);
            @memcpy(self.bytes[0..older.length], older.bytes[0..older.length]);
            if (styled) {
                std.mem.copyBackwards(u8, self.styles[older.length..][0..keep], self.styles[0..keep]);
                @memcpy(self.styles[0..older.length], older.styles[0..older.length]);
            }
            self.length = older.length + keep;
            if (trimmed) self.control_length = 0;
            self.origin = older.origin;
            self.dirty = true;
            try self.prepare();
            // Older text ends at a line boundary, so its lines precede ours.
            self.top = .{ .offset = anchor.offset + older.length, .row = anchor.row };
            return trimmed;
        }
    };
}

const TestScreen = struct {
    screen: vaxis.Screen,
    cells: [40 * 12]vaxis.Cell = @splat(.{}),

    fn window(self: *TestScreen, width: u16, height: u16) vaxis.Window {
        @memset(&self.cells, .{});
        self.screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = self.cells[0 .. @as(usize, width) * height] };
        return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &self.screen };
    }

    fn row(self: *TestScreen, index: u16, storage: []u8) []const u8 {
        var length: usize = 0;
        var column: u16 = 0;
        while (column < self.screen.width) {
            const cell = self.screen.readCell(column, index).?;
            @memcpy(storage[length..][0..cell.char.grapheme.len], cell.char.grapheme);
            length += cell.char.grapheme.len;
            column += @max(1, cell.char.width);
        }
        return std.mem.trimEnd(u8, storage[0..length], " ");
    }
};

test "vaxis wraps reading text at words with hanging indentation" {
    var view: Sized(256, false) = .{};
    try view.append("  The plain rui command isn't on PATH\n0123456789abcdef next\n› a longword\n  supercalifragilistic x\n• one two three four\n中中中中中中中中Z");
    try view.prepare();
    const layout: Layout = .{ .width = 16, .method = .unicode };
    var test_screen: TestScreen = undefined;
    const drawn = view.draw(test_screen.window(16, 12), .{}, true, false, .{});
    const expected = [_][]const u8{
        "  The plain rui",  "  command isn't", "  on PATH",
        "0123456789abcdef", "next",
        "› a longword",
        "  supercalifragi", "  listic x",
        "• one two three",
        "  four",
        "中中中中中中中中",
        "Z",
    };
    try std.testing.expectEqual(@as(usize, 12), drawn.rows);
    try std.testing.expectEqual(Position.end, drawn.next);
    var storage: [64]u8 = undefined;
    for (expected, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    try std.testing.expectEqual(@as(usize, 12), view.measure(layout, .{}, 99).rows);
    // A word keeps its punctuation across a style change.
    var styled: Sized(64, true) = .{};
    try styled.append("ab \x1b[4mcd\x1b[0m.");
    _ = styled.draw(test_screen.window(5, 2), .{}, true, false, .{});
    try std.testing.expectEqualStrings("cd.", test_screen.row(1, &storage));
    // A wide cluster that would cross the edge starts the next row.
    var wide: Sized(64, false) = .{};
    try wide.append("abc中");
    try std.testing.expectEqual(@as(u16, 2), wide.lineRows(.{ .width = 4, .method = .unicode }, 0));
    // Draft rows wrap at cells; the caret follows a wrapped wide cluster.
    const draft: Layout = .{ .width = 5, .method = .unicode };
    try std.testing.expectEqual(@as(u16, 2), draftRows(draft, "abcd中"));
    try std.testing.expectEqual(@as(u16, 2), caret(draft, "abcd中").col);
    try std.testing.expectEqual(@as(u16, 2), draftRows(draft, "abcde"));
    try std.testing.expectEqual(@as(u16, 2), draftRows(draft, "ab\n"));
}

test "positions move by laid-out rows and never skip the first unseen row" {
    var view: Sized(256, false) = .{};
    try view.append("one two three four five six\nseven\neight\n");
    const layout: Layout = .{ .width = 10, .method = .unicode };
    // Rows: "one two" "three four" "five six" | "seven" | "eight".
    try std.testing.expectEqual(@as(u16, 3), view.lineRows(layout, 0));
    try std.testing.expectEqual(Position{ .offset = 0, .row = 2 }, view.bottom(layout, 3));
    try std.testing.expectEqual(Position{ .offset = 28, .row = 0 }, view.down(layout, .{}, 3));
    try std.testing.expectEqual(Position{ .offset = 34, .row = 0 }, view.down(layout, .{}, 99));
    try std.testing.expectEqual(Position{ .offset = 0, .row = 1 }, view.up(layout, .{ .offset = 34 }, 3));
    try std.testing.expectEqual(Position{}, view.up(layout, .{ .offset = 34 }, 99));
    view.top = .{};
    view.browse(layout, true, 9, 2, .{ .offset = 0, .row = 2 });
    try std.testing.expectEqual(Position{ .offset = 0, .row = 2 }, view.first(layout, 2));
    view.browse(layout, true, 9, 2, null);
    try std.testing.expect(view.atBottom(layout, 2));
    try std.testing.expectEqual(Position{ .offset = 28 }, view.first(layout, 2));
    view.browse(layout, false, 9, 2, null);
    try std.testing.expect(view.atTop(layout, 2));
    // A wider terminal keeps the line and clamps its row.
    view.top = .{ .offset = 0, .row = 2 };
    try std.testing.expectEqual(Position{}, view.first(.{ .width = 40, .method = .unicode }, 1));
    var empty: Sized(16, false) = .{};
    try std.testing.expectEqual(@as(usize, 0), empty.measure(layout, .{}, 9).rows);
    try std.testing.expect(empty.atTop(layout, 2) and empty.atBottom(layout, 2));
}

test "viewport retention is finite and split Unicode is not rendered early" {
    const view = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(view);
    view.* = .{};
    try view.append("A\xf0\x9f");
    try std.testing.expectEqualStrings("A", view.text());
    try view.append("\x98\x80Z");
    try std.testing.expectEqualStrings("A😀Z", view.text());
    const chunk = "0123456789\n";
    for (0..30_000) |_| try view.append(chunk);
    try view.prepare();
    try std.testing.expect(view.length <= capacity);
    try std.testing.expect(view.origin != 0);
    try std.testing.expect(std.mem.endsWith(u8, view.text(), chunk));
}

test "trusted renderer styles survive fragmented output retention" {
    const input = "plain \x1b[1mbold\x1b[0m \x1b[3mital\x1b[4mcode\x1b[0m \x1b[94muser\x1b[39m!";
    for (0..input.len + 1) |split| {
        var view: Sized(32, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try std.testing.expectEqualStrings("plain bold italcode user!", view.text());
        try std.testing.expect(cellStyle(view.styles[6], true).bold);
        try std.testing.expect(!cellStyle(view.styles[10], true).bold);
        const nested = cellStyle(view.styles[15], true);
        try std.testing.expect(nested.italic and nested.underline);
        try std.testing.expectEqual(@as(?u8, 12), cellStyle(view.styles[20], true).foreground);
        try std.testing.expectEqual(@as(?u8, null), cellStyle(view.styles[20], false).foreground);
        try view.append(" extra words that evict the prefix");
        try std.testing.expect(view.origin != 0);
        try std.testing.expectEqualStrings("xtra words that evict the prefix", view.text());
        for (view.styles[0..view.length]) |style_value| try std.testing.expectEqual(CellStyle{}, cellStyle(style_value, true));
    }
    // Drawn cells carry the retained style, including a coloured marker.
    var marked: Sized(32, true) = .{};
    try marked.append("\x1b[94m›\x1b[39m hi");
    var test_screen: TestScreen = undefined;
    _ = marked.draw(test_screen.window(8, 1), .{}, true, true, .{});
    try std.testing.expectEqual(vaxis.Color{ .index = 12 }, test_screen.screen.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(vaxis.Color.default, test_screen.screen.readCell(2, 0).?.style.fg);
}

test "user text is dim italic with colour and keeps its body column without it" {
    var view: Sized(128, true) = .{};
    try view.append("\x1b[94m›\x1b[39m \x1b[2mhi \x1b[39mthere\x1b[0m\n  \x1b[2;8m┄ 3 more lines\x1b[0m\nagent \x1b[3mx\x1b[0m");
    const at = struct {
        fn style(v: *const Sized(128, true), needle: []const u8, colour: bool) CellStyle {
            return cellStyle(v.styles[std.mem.indexOf(u8, v.text(), needle).?], colour);
        }
    };
    try std.testing.expectEqual(CellStyle{ .foreground = 12 }, at.style(&view, "›", true));
    // A foreground reset never ends user text; only a full reset does.
    for ([_][]const u8{ "hi", "there" }) |word| {
        try std.testing.expectEqual(CellStyle{ .dim = true, .italic = true }, at.style(&view, word, true));
        try std.testing.expectEqual(CellStyle{}, at.style(&view, word, false));
    }
    try std.testing.expectEqual(CellStyle{ .dim = true }, at.style(&view, "┄", true));
    try std.testing.expectEqual(CellStyle{}, at.style(&view, "┄", false));
    try std.testing.expectEqual(CellStyle{}, at.style(&view, "agent", true));
    try std.testing.expectEqual(CellStyle{ .italic = true }, at.style(&view, "x", false));
    var test_screen: TestScreen = undefined;
    _ = view.draw(test_screen.window(20, 3), .{}, true, true, .{});
    const cell = test_screen.screen.readCell(2, 0).?.style;
    try std.testing.expect(cell.dim and cell.italic and cell.fg == .default);

    // At 12 columns ten leading spaces exceed half the width: agent text
    // falls back to column 0, user text continues at its body column.
    const body = "          abc defgh ijk";
    var storage: [64]u8 = undefined;
    for ([_]bool{ true, false }) |colour| {
        for ([_]bool{ true, false }) |user| {
            var line: Sized(64, true) = .{};
            if (user) try line.append("\x1b[2m");
            try line.append(body);
            const drawn = line.draw(test_screen.window(12, 4), .{}, true, colour, .{});
            try std.testing.expectEqual(@as(usize, 3), drawn.rows);
            const column: usize = if (user) 2 else 0;
            for (1..drawn.rows) |row| {
                const text = test_screen.row(@intCast(row), &storage);
                try std.testing.expectEqual(column, std.mem.indexOfNone(u8, text, " ").?);
            }
        }
    }
    // Below four columns the floor would leave no room for text.
    var narrow: Sized(64, true) = .{};
    try narrow.append("\x1b[2m   abc defg\x1b[0m\n   abc defg");
    const tiny: Layout = .{ .width = 3, .method = .unicode };
    try std.testing.expectEqual(narrow.lineRows(tiny, 12), narrow.lineRows(tiny, 0));
}

test "retention never starts inside an extended grapheme across append windows" {
    const cases = .{
        .{ "é0123456789ABCD", "0123456789ABCD" },
        .{ "🇺🇸🇨🇦Z", "🇨🇦Z" },
        .{ "A🧑‍🌾UVWXYZ", "UVWXYZ" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var view: Sized(16, true) = .{};
            try view.append(case[0][0..split]);
            try view.append(case[0][split..]);
            try std.testing.expectEqualStrings(case[1], view.text());
        }
    }
}

test "invisible and oversized output clusters become visible escapes" {
    const cases = .{
        .{ "hello\u{200b}world", "hello\\u{200b}world" },
        .{ "\u{feff}line", "\\u{feff}line" },
        .{ "co\u{ad}operate", "co\\u{ad}operate" },
        .{ "a\u{2060}b", "a\\u{2060}b" },
        .{ "x\n\u{301}y", "x\n\\u{301}y" },
        .{ "e\u{301}", "e\u{301}" },
        .{ "b" ++ "\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}!", "\\u{62}\\u{301}×32!" },
        .{ "🧑‍🧑‍🧑‍🧑‍🧑", "\\u{1f9d1}\\u{200d}\\u{1f9d1}\\u{200d}\\u{1f9d1}\\u{200d}\\u{1f9d1}\\u{200d}\\u{1f9d1}" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var view: Sized(256, true) = .{};
            try view.append(case[0][0..split]);
            try view.prepare();
            try view.append(case[0][split..]);
            try view.prepare();
            try std.testing.expectEqualStrings(case[1], view.text());
        }
    }
    try std.testing.expect(representable("🧑‍🧑‍🧑‍🧑‍🧑", .unicode));
    // "e" and 31 combining acute accents fill 63 bytes; one more passes 64.
    var marks: [1 + 2 * 32]u8 = undefined;
    marks[0] = 'e';
    for (0..32) |index| @memcpy(marks[1 + 2 * index ..][0..2], "\u{301}");
    try std.testing.expect(representable(marks[0..63], .unicode));
    try std.testing.expect(!representable(marks[0..65], .unicode));
}

test "older text prepends above the rows in view and trims newer text at capacity" {
    const layout: Layout = .{ .width = 20, .method = .unicode };
    var view: Sized(64, true) = .{};
    try view.append("live 1\nlive 2\nlive 3\n");
    view.top = .{ .offset = 7 }; // "live 2" is the first row in view.
    var older: Sized(64, true) = .{};
    try older.append("\x1b[90mold A\x1b[39m\nold B\n");
    try std.testing.expect(!try view.prepend(&older, layout, 2));
    try std.testing.expectEqualStrings("old A\nold B\nlive 1\nlive 2\nlive 3\n", view.text());
    const first = view.first(layout, 2);
    try std.testing.expectEqualStrings("live 2", view.bytes[first.offset..view.lineEnd(first.offset)]);
    try std.testing.expectEqual(@as(?u8, 8), cellStyle(view.styles[0], true).foreground);
    try std.testing.expectEqual(@as(?u8, null), cellStyle(view.styles[6], true).foreground);
    // Capacity: keep the older page whole and drop newest lines, line-aligned.
    var full: Sized(64, true) = .{};
    for (0..8) |index| {
        var line: [8]u8 = undefined;
        try full.append(try std.fmt.bufPrint(&line, "new {d}\n", .{index}));
    }
    full.top = .{};
    var page: Sized(64, true) = .{};
    for (0..5) |index| {
        var line: [8]u8 = undefined;
        try page.append(try std.fmt.bufPrint(&line, "old {d}\n", .{index}));
    }
    try std.testing.expect(try full.prepend(&page, layout, 2));
    try std.testing.expect(full.length <= 64);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, full.text(), "\n"));
    const kept = full.first(layout, 2);
    try std.testing.expectEqualStrings("new 0", full.bytes[kept.offset..full.lineEnd(kept.offset)]);
    // Discarding the front keeps later text and offsets absolute.
    full.discardFront(full.origin + 6);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 1\n"));
    try std.testing.expectEqual(@as(u64, 6), full.origin);
}
