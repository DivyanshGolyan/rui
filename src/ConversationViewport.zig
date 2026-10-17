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
            try self.layoutInput(columns);
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
        pub fn layoutInput(self: *Self, columns: u16) !void {
            std.debug.assert(columns != 0);
            if (!self.dirty and self.columns == columns) return;
            self.columns = columns;
            self.row_count = 0;
            self.addRow(0);
            var column: u16 = 0;
            const bytes = self.text();
            var iter = unicode.graphemeIterator(bytes);
            while (iter.next()) |grapheme| {
                const cluster = grapheme.bytes(bytes);
                if (std.mem.eql(u8, cluster, "\n")) {
                    self.addRow(grapheme.start + grapheme.len);
                    column = 0;
                    continue;
                }
                var width = try self.advance(cluster, column);
                if (column != 0 and @as(u32, column) + width > columns) {
                    self.addRow(grapheme.start);
                    column = 0;
                    width = try self.advance(cluster, column);
                }
                column += width;
            }
            if (column == columns) self.addRow(bytes.len);
            self.dirty = false;
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
            const prefix = self.bytes[self.offset(self.rowAt(position))..position];
            var clusters = unicode.graphemeIterator(prefix);
            var column: u16 = 0;
            while (clusters.next()) |cluster| column += try self.advance(cluster.bytes(prefix), column);
            return column;
        }

        fn addRow(self: *Self, position: usize) void {
            self.rows[self.row_count] = @intCast(position);
            self.row_count += 1;
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

        pub fn browse(self: *Self, down: bool, height: usize, first_unseen: ?usize) void {
            const current = self.first(height);
            const row = if (down) @min(current + height, self.displayRows() -| height) else current -| height;
            // Key repeat may deliver many page events before a frame. Never
            // skip unread Action rows; only delivered frames advance this cap.
            self.top = if (down) @min(row, first_unseen orelse row) else row;
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
