//! Bounded display text, independent of canonical history and terminal cells.
//! Browsing uses physical rows and may reset on resize. Draft caret lookup is
//! separate and always derives from the unchanged draft bytes.
const std = @import("std");
const gwidth = @import("terminal_width");
const unicode = @import("terminal_unicode");
pub const Document = Sized(capacity, true);

pub const capacity = 256 * 1024;
pub const CellStyle = struct { bold: bool = false, italic: bool = false, underline: bool = false, foreground: ?u8 = null };
pub fn cellStyle(value: u8, colour: bool) CellStyle {
    return .{ .bold = value & 1 != 0, .italic = value & 2 != 0, .underline = value & 4 != 0, .foreground = if (colour and value >> 3 != 0) (value >> 3) - 1 else null };
}

pub fn Sized(comptime limit: usize, comptime styled: bool) type {
    return struct {
        const Self = @This();
        // Every retained byte may be a newline. This index cannot evict an earlier
        // caret or browsing anchor while its source bytes are still retained.
        const row_capacity = limit + 1;
        bytes: [limit]u8 = undefined,
        styles: [if (styled) limit else 0]u8 = undefined,
        style: u8 = 0,
        control: [8]u8 = undefined,
        control_length: usize = 0,
        length: usize = 0,
        origin: u64 = 0,
        top: ?usize = null,
        rows: [row_capacity]u32 = undefined,
        // Continuation rows of an indented line start at its text column.
        indents: [row_capacity]u8 = undefined,
        row_count: usize = 0,
        columns: u16 = 0,
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
                        if (std.mem.eql(u8, code, "\x1b[0m")) self.style = 0 else if (std.mem.eql(u8, code, "\x1b[1m")) self.style |= 1 else if (std.mem.eql(u8, code, "\x1b[3m")) self.style |= 2 else if (std.mem.eql(u8, code, "\x1b[4m")) self.style |= 4 else if (std.mem.eql(u8, code, "\x1b[39m")) self.style &= 7 else {
                            const foreground: u8 = if (std.mem.eql(u8, code, "\x1b[33m")) 3 else if (std.mem.eql(u8, code, "\x1b[90m")) 8 else if (std.mem.eql(u8, code, "\x1b[91m")) 9 else if (std.mem.eql(u8, code, "\x1b[94m")) 12 else unreachable;
                            self.style = (self.style & 7) | ((foreground + 1) << 3);
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
        /// clusters in this display copy, never in saved content or input.
        pub fn layout(self: *Self, columns: u16) !void {
            if (self.dirty) try self.escapeZeroWidth();
            try self.wrap(columns, true);
        }

        fn escapeZeroWidth(self: *Self) !void {
            var search = unicode.graphemeIterator(self.text());
            while (search.next()) |cluster| {
                const raw_cluster = cluster.bytes(self.text());
                if (std.mem.eql(u8, raw_cluster, "\n") or std.mem.eql(u8, raw_cluster, "\t") or gwidth.gwidth(raw_cluster, self.width_method) != 0) continue;
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
                    if (std.mem.eql(u8, raw, "\n") or std.mem.eql(u8, raw, "\t") or gwidth.gwidth(raw, self.width_method) != 0) {
                        try self.appendText(raw);
                    } else {
                        var scalars = (try std.unicode.Utf8View.init(raw)).iterator();
                        while (scalars.nextCodepoint()) |point| {
                            var escaped: [10]u8 = undefined;
                            try self.appendText(try std.fmt.bufPrint(&escaped, "\\u{{{x}}}", .{point}));
                        }
                    }
                }
                if (styled and complete < length) self.style = styles[complete];
                try self.appendText(bytes[complete..length]);
                return;
            }
        }

        /// Composer offsets refer to original input bytes, not escaped output.
        /// Draft rows break at cells so the caret maps to exactly one place.
        pub fn layoutInput(self: *Self, columns: u16) !void {
            try self.wrap(columns, false);
        }

        /// Reading text breaks rows after spaces where a word would not fit,
        /// hard-breaking only words wider than the row. Continuation rows keep
        /// the line's leading indentation, up to half the width.
        fn wrap(self: *Self, columns: u16, words: bool) !void {
            std.debug.assert(columns != 0);
            if (!self.dirty and self.columns == columns) return;
            self.columns = columns;
            self.row_count = 0;
            self.addRow(0, 0);
            const bytes = self.text();
            var column: u16 = 0;
            var line_indent: u16 = 0; // Of the current logical line.
            var leading = true;
            var row_start: usize = 0;
            var row_indent: u16 = 0;
            var space_end: ?usize = null; // A break opportunity in this row.
            var iter = unicode.graphemeIterator(bytes);
            while (iter.next()) |grapheme| {
                const cluster = grapheme.bytes(bytes);
                if (std.mem.eql(u8, cluster, "\n")) {
                    row_start = grapheme.start + grapheme.len;
                    self.addRow(row_start, 0);
                    column = 0;
                    line_indent = 0;
                    row_indent = 0;
                    leading = true;
                    space_end = null;
                    continue;
                }
                const space = std.mem.eql(u8, cluster, " ");
                if (leading and space and words) {
                    line_indent += 1;
                } else if (leading and words and marker(cluster) and std.mem.startsWith(u8, bytes[grapheme.start + grapheme.len ..], " ")) {
                    // "› ", "• ", "- " and similar: continue under the text.
                    line_indent += 2;
                    leading = false;
                } else leading = false;
                var width = try self.advance(cluster, column);
                if (column != row_indent and @as(u32, column) + width > columns) {
                    row_indent = if (@as(u32, line_indent) * 2 <= columns) line_indent else 0;
                    if (words and space) {
                        // A space at the edge ends the row; it is not drawn.
                        row_start = grapheme.start + grapheme.len;
                        self.addRow(row_start, row_indent);
                        column = row_indent;
                        space_end = null;
                        continue;
                    }
                    // Carry the unfinished word when it and this cluster fit
                    // the next row; otherwise hard-break before this cluster.
                    row_start = grapheme.start;
                    column = row_indent;
                    if (space_end) |word| {
                        var carried_column = row_indent;
                        var carried = unicode.graphemeIterator(bytes[word..grapheme.start]);
                        while (carried.next()) |part| carried_column += try self.advance(part.bytes(bytes[word..grapheme.start]), carried_column);
                        if (@as(u32, carried_column) + (try self.advance(cluster, carried_column)) <= columns) {
                            row_start = word;
                            column = carried_column;
                        }
                    }
                    if (row_start == grapheme.start and @as(u32, column) + (try self.advance(cluster, column)) > columns) {
                        row_indent = 0;
                        column = 0;
                    }
                    self.addRow(row_start, row_indent);
                    space_end = null;
                    width = try self.advance(cluster, column);
                }
                column += width;
                if (words and space and !leading) space_end = grapheme.start + grapheme.len;
            }
            if (column == columns) self.addRow(bytes.len, 0);
            self.dirty = false;
        }

        fn marker(cluster: []const u8) bool {
            for ([_][]const u8{ "›", "•", "◦", "✓", "!", "?", "-", "*", "$" }) |glyph| if (std.mem.eql(u8, cluster, glyph)) return true;
            return false;
        }

        // Layout, cells and caret use exactly the same measured advance.
        // Vaxis cells cannot represent zero-width or oversized clusters. Refuse
        // those rather than inventing widths or clipping semantic input.
        pub fn advance(self: *const Self, cluster: []const u8, column: u16) !u16 {
            if (std.mem.eql(u8, cluster, "\t")) return @min(8 - column % 8, self.columns);
            const cells = gwidth.gwidth(cluster, self.width_method);
            if (cells == 0 or cells > self.columns or cells > 255) return error.UnrepresentableTerminalGrapheme;
            return cells;
        }

        pub fn columnAt(self: *const Self, position: usize) !u16 {
            const row = self.rowAt(position);
            const prefix = self.bytes[self.offset(row)..position];
            var clusters = unicode.graphemeIterator(prefix);
            var column: u16 = self.indents[row];
            while (clusters.next()) |cluster| column += try self.advance(cluster.bytes(prefix), column);
            return column;
        }

        fn addRow(self: *Self, position: usize, row_indent: u16) void {
            self.rows[self.row_count] = @intCast(position);
            self.indents[self.row_count] = @intCast(row_indent);
            self.row_count += 1;
        }

        pub fn indent(self: *const Self, row: usize) u16 {
            return self.indents[row];
        }

        pub fn offset(self: *const Self, row: usize) usize {
            return self.rows[row];
        }

        pub fn rowText(self: *const Self, row: usize) []const u8 {
            const start = self.offset(row);
            const end = if (row + 1 < self.row_count) self.offset(row + 1) else self.text().len;
            return std.mem.trimEnd(u8, self.bytes[start..end], "\n");
        }

        pub fn displayRows(self: *const Self) usize {
            return self.row_count - @intFromBool(self.row_count > 1 and self.rowText(self.row_count - 1).len == 0);
        }

        pub fn first(self: *const Self, height: usize) usize {
            const rows = self.displayRows();
            return @min(self.top orelse rows -| height, rows -| 1);
        }

        pub fn rowAt(self: *const Self, position: usize) usize {
            var row: usize = 0;
            while (row + 1 < self.row_count and self.offset(row + 1) <= position) row += 1;
            return row;
        }

        /// Moves by `rows` (a page is the view height). Key repeat may deliver
        /// many events before a frame: never skip unread Action rows; only
        /// delivered frames advance that cap.
        pub fn browse(self: *Self, down: bool, rows: usize, height: usize, first_unseen: ?usize) void {
            const current = self.first(height);
            const row = if (down) @min(current + rows, self.displayRows() -| height) else current -| rows;
            self.top = if (down) @min(row, first_unseen orelse row) else row;
        }

        pub fn atTop(self: *const Self, height: usize) bool {
            return self.first(height) == 0;
        }

        pub fn atBottom(self: *const Self, height: usize) bool {
            return self.first(height) >= self.displayRows() -| height;
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
        pub fn prepend(self: *Self, older: anytype, columns: u16, height: usize) !bool {
            std.debug.assert(older.control_length == 0 and older.length <= limit);
            try self.layout(columns);
            const anchor = self.first(height);
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
            try self.layout(columns);
            // Older text ends at a line boundary, so its rows precede ours.
            self.top = self.rowAt(older.length) + anchor;
            return trimmed;
        }
    };
}

test "viewport reflow preserves text and draft caret" {
    const view = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(view);
    view.* = .{};
    try view.append("alpha beta gamma\nA中é🧑‍🌾Z\nlast");
    try view.layout(9);
    try std.testing.expectEqualStrings("A中é🧑‍🌾Z", view.rowText(view.rowAt(17)));
    try view.layout(40);
    try std.testing.expectEqualStrings("A中é🧑‍🌾Z", view.rowText(view.rowAt(17)));
    try std.testing.expectEqualStrings("alpha beta gamma\nA中é🧑‍🌾Z\nlast", view.text());
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
    try view.layout(80);
    try std.testing.expect(view.length <= capacity and view.row_count <= capacity + 1);
    try std.testing.expect(view.origin != 0);
    try std.testing.expect(std.mem.endsWith(u8, view.text(), chunk));
}

test "viewport widths follow the observed terminal and tabs reflow from their new column" {
    const view = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(view);
    view.* = .{};
    try view.append("A🧑‍🌾Z");
    try view.layout(5);
    try std.testing.expectEqualStrings("A🧑‍🌾", view.rowText(0));
    try std.testing.expectEqualStrings("Z", view.rowText(1));
    view.width_method = .unicode;
    view.dirty = true;
    try view.layout(5);
    try std.testing.expectEqualStrings("A🧑‍🌾Z", view.rowText(0));
    view.clear();
    try view.append("abcde\tZ");
    try view.layout(6);
    try std.testing.expectEqualStrings("abcde", view.rowText(0));
    try std.testing.expectEqualStrings("\t", view.rowText(1));
    try std.testing.expectEqualStrings("Z", view.rowText(2));
}

test "trusted renderer styles survive fragmented output retention and reflow" {
    const input = "plain \x1b[1mbold\x1b[0m \x1b[3mital\x1b[4mcode\x1b[0m \x1b[94muser\x1b[39m!";
    for (0..input.len + 1) |split| {
        var view: Sized(32, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try view.layout(9);
        try std.testing.expectEqualStrings("plain bold italcode user!", view.text());
        try std.testing.expect(cellStyle(view.styles[6], true).bold);
        try std.testing.expect(!cellStyle(view.styles[10], true).bold);
        const nested = cellStyle(view.styles[15], true);
        try std.testing.expect(nested.italic and nested.underline);
        try std.testing.expectEqual(@as(?u8, 12), cellStyle(view.styles[20], true).foreground);
        try std.testing.expectEqual(@as(?u8, null), cellStyle(view.styles[20], false).foreground);
        try view.append(" extra words that evict the prefix");
        try view.layout(5);
        try std.testing.expect(view.origin != 0);
        try std.testing.expectEqualStrings("xtra words that evict the prefix", view.text());
        for (view.styles[0..view.length]) |style_value| try std.testing.expectEqual(CellStyle{}, cellStyle(style_value, true));
    }
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

test "output zero-width clusters become visible escapes without changing joined accents" {
    const cases = .{
        .{ "hello\u{200b}world", "hello\\u{200b}world" },
        .{ "\u{feff}line", "\\u{feff}line" },
        .{ "co\u{ad}operate", "co\\u{ad}operate" },
        .{ "a\u{2060}b", "a\\u{2060}b" },
        .{ "x\n\u{301}y", "x\n\\u{301}y" },
        .{ "e\u{301}", "e\u{301}" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var view: Sized(128, true) = .{};
            try view.append(case[0][0..split]);
            try view.layout(8);
            try view.append(case[0][split..]);
            try view.layout(8);
            try std.testing.expectEqualStrings(case[1], view.text());
        }
    }
}

test "geometry refuses unrepresentable clusters instead of inventing cell widths" {
    var view: Sized(32, false) = .{};
    try view.append("́Z");
    try std.testing.expectError(error.UnrepresentableTerminalGrapheme, view.layoutInput(8));
    view.clear();
    try view.append("中Z");
    try std.testing.expectError(error.UnrepresentableTerminalGrapheme, view.layout(1));
    try view.layout(3);
    try std.testing.expectEqual(@as(u16, 2), try view.columnAt(3));
    view.clear();
    try view.append("abcde\tZ");
    try view.layout(6);
    try std.testing.expectEqual(@as(u16, 0), try view.columnAt(6));
    try std.testing.expectEqual(@as(u16, 1), try view.columnAt(7));
}

test "a long joined cluster fails by display contract before width arithmetic can overflow" {
    const view = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(view);
    const cluster = try std.testing.allocator.alloc(u8, "🧑‍".len * 32_768);
    defer std.testing.allocator.free(cluster);
    for (0..32_768) |index| @memcpy(cluster[index * "🧑‍".len ..][0.."🧑‍".len], "🧑‍");
    view.* = .{};
    try view.append(cluster[0 .. 127 * "🧑‍".len]);
    try view.layout(255);
    try std.testing.expectEqual(@as(u16, 254), try view.columnAt(view.length));
    try view.append("🧑‍");
    try std.testing.expectError(error.UnrepresentableTerminalGrapheme, view.layout(255));
    view.clear();
    try view.append(cluster);
    try std.testing.expectError(error.UnrepresentableTerminalGrapheme, view.layout(8));
    view.width_method = .unicode;
    try view.layout(8);
    try std.testing.expectEqual(@as(u16, 2), try view.columnAt(view.length));
}

test "reading text wraps at words and keeps hanging indentation" {
    var view: Sized(256, false) = .{};
    try view.append("  The plain rui command isn't on PATH\n0123456789abcdef next\n› a longword\n  supercalifragilistic x\n    deeper indented words here\n• one two three four");
    try view.layout(16);
    const expected = [_]struct { []const u8, u16 }{
        .{ "  The plain rui ", 0 }, .{ "command isn't ", 2 }, .{ "on PATH", 2 },
        .{ "0123456789abcdef ", 0 }, .{ "next", 0 },
        .{ "› a longword", 0 },
        .{ "  supercalifragi", 0 }, .{ "listic x", 2 },
        .{ "    deeper ", 0 }, .{ "indented ", 4 }, .{ "words here", 4 },
        .{ "• one two three ", 0 }, .{ "four", 2 },
    };
    try std.testing.expectEqual(expected.len, view.displayRows());
    for (expected, 0..) |row, index| {
        try std.testing.expectEqualStrings(row[0], view.rowText(index));
        try std.testing.expectEqual(row[1], view.indent(index));
    }
    // Every row fits, counting its indentation; only a space that ended the
    // row at the edge may lie beyond it, and it is not drawn.
    for (0..view.displayRows()) |row| {
        var column = view.indent(row);
        const text = std.mem.trimEnd(u8, view.rowText(row), " ");
        var clusters = unicode.graphemeIterator(text);
        while (clusters.next()) |cluster| column += try view.advance(cluster.bytes(text), column);
        try std.testing.expect(column <= 16);
    }
    // Draft rows still break at cells, so the caret maps to one place.
    var draft: Sized(64, false) = .{};
    try draft.append("abc defgh");
    try draft.layoutInput(5);
    try std.testing.expectEqualStrings("abc d", draft.rowText(0));
    try std.testing.expectEqual(@as(u16, 1), try draft.columnAt(6));
    // An indent too wide for half the row is dropped rather than squeezing.
    var narrow: Sized(64, false) = .{};
    try narrow.append("      wide indent text");
    try narrow.layout(8);
    try std.testing.expectEqual(@as(u16, 0), narrow.indent(1));
}

test "older text prepends above the rows in view and trims newer text at capacity" {
    var view: Sized(64, true) = .{};
    try view.append("live 1\nlive 2\nlive 3\n");
    try view.layout(20);
    view.top = 1; // "live 2" is the first row in view.
    var older: Sized(64, true) = .{};
    try older.append("\x1b[90mold A\x1b[39m\nold B\n");
    try older.layout(20);
    try std.testing.expect(!try view.prepend(&older, 20, 2));
    try std.testing.expectEqualStrings("old Aold Blive 1live 2live 3", blk: {
        var joined: [64]u8 = undefined;
        var used: usize = 0;
        for (0..view.displayRows()) |row| {
            const text = view.rowText(row);
            @memcpy(joined[used..][0..text.len], text);
            used += text.len;
        }
        break :blk joined[0..used];
    });
    try std.testing.expectEqualStrings("live 2", view.rowText(view.first(2)));
    try std.testing.expectEqual(@as(?u8, 8), cellStyle(view.styles[0], true).foreground);
    try std.testing.expectEqual(@as(?u8, null), cellStyle(view.styles[view.offset(2)], true).foreground);
    // Capacity: keep the older page whole and drop newest lines, line-aligned.
    var full: Sized(64, true) = .{};
    for (0..8) |index| {
        var line: [8]u8 = undefined;
        try full.append(try std.fmt.bufPrint(&line, "new {d}\n", .{index}));
    }
    try full.layout(20);
    full.top = 0;
    var page: Sized(64, true) = .{};
    for (0..5) |index| {
        var line: [8]u8 = undefined;
        try page.append(try std.fmt.bufPrint(&line, "old {d}\n", .{index}));
    }
    try page.layout(20);
    try std.testing.expect(try full.prepend(&page, 20, 2));
    try std.testing.expect(full.length <= 64);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, full.text(), "\n"));
    try std.testing.expectEqualStrings("new 0", full.rowText(full.first(2)));
    // Discarding the front keeps later text and offsets absolute.
    full.discardFront(full.origin + 6);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 1\n"));
    try std.testing.expectEqual(@as(u64, 6), full.origin);
}
