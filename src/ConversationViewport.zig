//! Bounded display text, independent of canonical history and terminal cells.
//! vaxis lays out and draws rows (`Window.print`); this module keeps retained
//! bytes, trusted styles and which row of which logical line a view starts at.
const std = @import("std");
const vaxis = @import("vaxis");
const gwidth = @import("terminal_width");
const unicode = @import("terminal_unicode");
const draft_layout = @import("draft_layout.zig");
const TerminalText = @import("TerminalText.zig");
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

/// The draft as the input draws it, for `draft_layout`: whole clusters
/// measured as the terminal measures them. The screen has already shown
/// tabs as one space and refused clusters the terminal cannot draw.
pub const DraftPieces = struct {
    bytes: []const u8,
    method: gwidth.Method,
    at: usize = 0,

    pub fn next(self: *DraftPieces) ?draft_layout.Piece {
        if (self.at == self.bytes.len) return null;
        var clusters = unicode.graphemeIterator(self.bytes[self.at..]);
        const cluster = clusters.next().?.bytes(self.bytes[self.at..]);
        self.at += cluster.len;
        const kind = draft_layout.kindOf(cluster);
        return .{ .len = cluster.len, .cells = if (kind == .newline) 0 else gwidth.gwidth(cluster, self.method), .kind = kind };
    }
};

/// Leading spaces and a list or role marker stay in the first row;
/// continuation rows start under the text after them, up to half the width.
/// A user line never hangs left of its body column: position alone must
/// distinguish user text where the terminal shows no attributes. `quoted`:
/// the marker begins an Action's description (`?`), its command (`$`) or a
/// later line of it or its stdin (`│`).
fn hanging(line: []const u8, width: u16, user: bool) struct { bytes: usize, cells: u16, quoted: bool = false } {
    var bytes: usize = 0;
    while (bytes < line.len and line[bytes] == ' ') bytes += 1;
    var cells: usize = bytes;
    var quoted = false;
    for ([_][]const u8{ "›", "•", "◦", "✓", "!", "?", "-", "*", "$", "│" }) |glyph| {
        if (std.mem.startsWith(u8, line[bytes..], glyph) and std.mem.startsWith(u8, line[bytes + glyph.len ..], " ")) {
            bytes += glyph.len + 1;
            cells += 2;
            quoted = std.mem.eql(u8, glyph, "?") or std.mem.eql(u8, glyph, "$") or std.mem.eql(u8, glyph, "│");
            break;
        }
    }
    if (cells * 2 > width) {
        if (user and width >= 4 and std.mem.startsWith(u8, line, "  ")) return .{ .bytes = 2, .cells = 2 };
        return .{ .bytes = 0, .cells = 0 };
    }
    return .{ .bytes = bytes, .cells = @intCast(cells), .quoted = quoted };
}

/// Retained style byte, display-only: bits 0-2 bold, italic and underline,
/// bits 3-5 a foreground index, bit 6 user text and bit 7 its dim summary.
/// Bit 7 alone marks a sidenote, drawn in the right margin.
/// Two foreground indexes no colour uses mark an OSC 8 link: its address,
/// kept in the text but never drawn, and right after it the text it links.
const foregrounds = [_]u8{ 3, 8, 9, 12 };
const foreground_mask: u8 = 0b111 << 3;
const linked_index: u8 = 6;
const address_index: u8 = 7;

fn foregroundIndex(value: u8) u8 {
    return (value & foreground_mask) >> 3;
}
const user_bit: u8 = 1 << 6;
const summary_bit: u8 = 1 << 7;
/// From this width a document with sidenotes keeps a right margin, and the
/// first sidenote of a line shows at its first row; narrower, none shows.
pub const sidenote_width = 60;
const sidenote_margin = 7;
const sidenote_cells = 5;

fn isSidenote(value: u8) bool {
    return value & (user_bit | summary_bit) == summary_bit;
}
pub const CellStyle = struct { bold: bool = false, dim: bool = false, italic: bool = false, underline: bool = false, foreground: ?u8 = null };
/// User text is dim and italic only with colour; without it, position alone
/// sets it apart. Its summary and sidenotes are dim but never italic.
pub fn cellStyle(value: u8, colour: bool) CellStyle {
    const index = foregroundIndex(value);
    const quiet = colour and value & (user_bit | summary_bit) != 0;
    return .{
        .bold = value & 1 != 0,
        .dim = quiet,
        .italic = value & 2 != 0 or (quiet and value & summary_bit == 0),
        .underline = value & 4 != 0,
        .foreground = if (colour and index != 0 and index <= foregrounds.len) foregrounds[index - 1] else null,
    };
}

/// Collapsed blocks' summaries in a range of text: see `collapsed`.
pub const Summaries = struct { count: usize = 0, last: ?usize = null };

pub fn Sized(comptime limit: usize, comptime styled: bool) type {
    return struct {
        const Self = @This();
        bytes: [limit]u8 = undefined,
        styles: [if (styled) limit else 0]u8 = undefined,
        style: u8 = 0,
        control: [8]u8 = undefined,
        control_length: usize = 0,
        /// Where the OSC 8 link being received is: its address or its text.
        link: enum { none, address, text } = .none,
        address_length: usize = 0,
        length: usize = 0,
        origin: u64 = 0,
        width_method: gwidth.Method = .wcwidth,
        dirty: bool = true,
        generation: u64 = 0,
        /// Reserve the right margin for sidenotes at `sidenote_width` and wider.
        sidenotes: bool = false,
        /// An Action: each wrapped row of its description, command or stdin
        /// starts with `┆`, so no row of that text can pass for a field, nor
        /// a wrapped row for a new `│` line.
        quotes: bool = false,

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
                        if (std.mem.eql(u8, code, "\x1b[0m")) self.style = 0 else if (std.mem.eql(u8, code, "\x1b[1m")) self.style |= 1 else if (std.mem.eql(u8, code, "\x1b[3m")) self.style |= 2 else if (std.mem.eql(u8, code, "\x1b[4m")) self.style |= 4 else if (std.mem.eql(u8, code, "\x1b[2m")) self.style |= user_bit else if (std.mem.eql(u8, code, "\x1b[2;8m")) self.style |= user_bit | summary_bit else if (std.mem.eql(u8, code, "\x1b[8m")) self.style = (self.style & ~user_bit) | summary_bit else if (std.mem.eql(u8, code, "\x1b[39m")) self.style &= ~foreground_mask else {
                            const colour_index: u8 = if (std.mem.eql(u8, code, "\x1b[33m")) 1 else if (std.mem.eql(u8, code, "\x1b[90m")) 2 else if (std.mem.eql(u8, code, "\x1b[91m")) 3 else if (std.mem.eql(u8, code, "\x1b[94m")) 4 else unreachable;
                            self.style = (self.style & ~foreground_mask) | (colour_index << 3);
                        }
                        self.control_length = 0;
                    } else if (std.mem.eql(u8, self.control[0..self.control_length], TerminalText.link_open)) {
                        // An address follows, empty for the closing sequence.
                        self.link = .address;
                        self.address_length = 0;
                        self.control_length = 0;
                    } else if (std.mem.eql(u8, self.control[0..self.control_length], TerminalText.link_end)) {
                        std.debug.assert(self.link == .address);
                        self.link = if (self.address_length == 0) .none else .text;
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
                if (styled) @memset(self.styles[self.length..][0..count], self.cellValue());
                if (self.link == .address) self.address_length += count;
                self.length += count;
                position += count;
            }
            // Input windows can split UTF-8. Keep the suffix until the next append;
            // indexing below only visits complete scalars.
            self.dirty = true;
            self.generation +%= 1;
        }

        /// The retained style of text appended now, with any link mark.
        fn cellValue(self: *const Self) u8 {
            const index: u8 = switch (self.link) {
                .none => return self.style,
                .address => address_index,
                .text => linked_index,
            };
            return (self.style & ~foreground_mask) | (index << 3);
        }

        /// The address of the link whose text holds `position`: the hidden
        /// run right before that text. Empty when the text is not a link or
        /// its address began before the retained text.
        fn address(self: *const Self, position: usize) []const u8 {
            if (foregroundIndex(self.styles[position]) != linked_index) return "";
            var end = position;
            while (end > 0 and foregroundIndex(self.styles[end - 1]) == linked_index) end -= 1;
            var start = end;
            while (start > 0 and foregroundIndex(self.styles[start - 1]) == address_index) start -= 1;
            if (start == 0 and self.origin != 0) return "";
            return self.bytes[start..end];
        }

        pub fn clear(self: *Self) void {
            self.length = 0;
            self.origin = 0;
            self.style = 0;
            self.control_length = 0;
            self.link = .none;
            self.dirty = true;
            self.generation +%= 1;
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
                // Retained styles already carry their link marks.
                const saved_link = self.link;
                const saved_address = self.address_length;
                self.link = .none;
                defer {
                    self.link = saved_link;
                    self.address_length = saved_address;
                }
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
            var user = false;
            // A line of summary text alone (a peer Message's line) keeps one
            // row, ending in `…` when it does not fit.
            var single = styled and end != offset;
            var note: ?struct { start: usize, end: usize } = null;
            if (styled) for (self.styles[offset..end], offset..) |value, index| {
                if (value & user_bit != 0) user = true;
                if (!isSidenote(value)) {
                    if (value & (user_bit | summary_bit) != user_bit | summary_bit) single = false;
                    continue;
                }
                if (note == null) note = .{ .start = index, .end = index + 1 } else if (note.?.end == index) note.?.end += 1;
            };
            // A single row's text ends where its trailing sidenote begins.
            const shown = if (note) |range| (if (range.end == end) range.start else end) else end;
            const margin: u16 = if (styled and self.sidenotes and window.width >= sidenote_width) sidenote_margin else 0;
            const body = window.child(.{ .width = window.width - margin });
            if (commit and margin != 0) if (note) |range| {
                _ = self.printRange(window.child(.{ .x_off = window.width - sidenote_cells, .y_off = row, .width = sidenote_cells, .height = 1 }), range.start, range.end, .none, true, true, colour, plain);
            };
            if (single) {
                if (commit) {
                    // Whole clusters measured by this view's width method:
                    // a wide last cluster never crosses the body's edge.
                    const line = body.child(.{ .y_off = row, .height = 1 });
                    const text_bytes = self.bytes[offset..shown];
                    if (gwidth.gwidth(text_bytes, self.width_method) <= line.width) {
                        _ = self.printRange(line, offset, shown, .none, false, true, colour, plain);
                    } else if (line.width != 0) {
                        var clusters = unicode.graphemeIterator(text_bytes);
                        var used: u16 = 0;
                        var cut = offset;
                        while (clusters.next()) |cluster| {
                            const width = gwidth.gwidth(cluster.bytes(text_bytes), self.width_method);
                            if (used + width > line.width - 1) break;
                            used += width;
                            cut = offset + cluster.start + cluster.len;
                        }
                        _ = self.printRange(line, offset, cut, .none, false, true, colour, plain);
                        _ = line.child(.{ .x_off = used, .width = 1 }).print(&.{.{ .text = "…", .style = self.segmentStyle(offset, colour, plain) }}, .{ .wrap = .none });
                    }
                }
                return 1;
            }
            const split = hanging(self.bytes[offset..end], body.width, user);
            if (commit) _ = self.printRange(body.child(.{ .y_off = row, .height = 1 }), offset, offset + split.bytes, .none, false, true, colour, plain);
            const rows = rowsUsed(self.printRange(body.child(.{ .x_off = split.cells, .y_off = row }), offset + split.bytes, end, .word, false, commit, colour, plain));
            if (commit and self.quotes and split.quoted) for (1..rows) |index| {
                const mark = body.child(.{ .x_off = split.cells - 2, .y_off = row + @as(i17, @intCast(index)), .width = 1, .height = 1 });
                _ = mark.printSegment(.{ .text = "┆", .style = self.segmentStyle(offset + split.bytes - 2, colour, plain) }, .{ .wrap = .none });
            };
            return rows;
        }

        /// Prints bytes as style runs, a bounded batch of segments at a time:
        /// sidenotes only, or the text's flow without them.
        fn printRange(self: *const Self, window: vaxis.Window, from: usize, end: usize, wrap: @FieldType(vaxis.PrintOptions, "wrap"), notes: bool, commit: bool, colour: bool, plain: vaxis.Style) vaxis.Window.PrintResult {
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
                const shown = !styled or (isSidenote(self.styles[start]) == notes and foregroundIndex(self.styles[start]) != address_index);
                if (shown) {
                    segments[count] = .{ .text = self.bytes[start..stop], .style = self.segmentStyle(start, colour, plain), .link = .{ .uri = if (styled) self.address(start) else "" } };
                    count += 1;
                }
                start = stop;
                if (count != 0 and (count == segments.len or start == end)) {
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

        /// Number of laid-out rows; no navigation state belongs to text.
        pub fn rowCount(self: *const Self, layout: Layout) usize {
            if (self.text().len == 0) return 0;
            var total: usize = 0;
            var line: ?usize = 0;
            while (line) |offset| : (line = self.nextLine(offset)) total += self.lineRows(layout, offset);
            return total;
        }

        pub fn positionAtRow(self: *const Self, layout: Layout, row: usize) Position {
            if (self.text().len == 0) return .end;
            var remaining = row;
            var line: ?usize = 0;
            while (line) |offset| : (line = self.nextLine(offset)) {
                const used = self.lineRows(layout, offset);
                if (remaining < used) return .{ .offset = offset, .row = @intCast(remaining) };
                remaining -= used;
            }
            return .end;
        }

        pub fn rowOf(self: *const Self, layout: Layout, position: Position) usize {
            if (self.text().len == 0) return 0;
            var row: usize = 0;
            var line: ?usize = 0;
            while (line) |offset| : (line = self.nextLine(offset)) {
                const used = self.lineRows(layout, offset);
                if (offset >= position.offset) return row + @min(position.row, used - 1);
                row += used;
            }
            return row;
        }

        /// Where each collapsed block's summary starts within text bytes
        /// `[from, to)`: a user block's `┄` row, drawn dim and quiet. Returns
        /// their count, and the last one's offset.
        pub fn collapsed(self: *const Self, from: usize, to: usize) Summaries {
            comptime std.debug.assert(styled);
            const run = user_bit | summary_bit;
            const bytes = self.text();
            var result: Summaries = .{};
            var index = from;
            const end = @min(to, bytes.len);
            while (std.mem.indexOfPos(u8, bytes[0..end], index, "┄")) |found| : (index = found + 1) {
                if (self.styles[found] & run != run) continue;
                if (found != 0 and self.styles[found - 1] & run == run) continue;
                result.count += 1;
                result.last = found;
            }
            return result;
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
            self.dirty = true;
            self.generation +%= 1;
        }

        /// Copies a normalized contiguous suffix without parsing it again or
        /// evicting the anchor. Styles include hidden link addresses. Returns
        /// the bytes admitted; a partial copy ends at a whole logical line.
        pub fn appendRetained(self: *Self, source: *const Self, start: usize) usize {
            std.debug.assert(styled and start <= source.length);
            const suffix = source.length - start;
            var count = @min(suffix, limit - self.length);
            if (count < suffix) count = if (std.mem.lastIndexOfScalar(u8, source.bytes[start..][0..count], '\n')) |line| line + 1 else 0;
            @memcpy(self.bytes[self.length..][0..count], source.bytes[start..][0..count]);
            @memcpy(self.styles[self.length..][0..count], source.styles[start..][0..count]);
            self.length += count;
            self.dirty = true;
            self.generation +%= 1;
            return count;
        }

        /// Places complete older text before retained text. Newer bytes
        /// beyond capacity leave from the end at a line
        /// boundary; returns whether any did.
        pub fn prepend(self: *Self, older: anytype) !bool {
            std.debug.assert(older.control_length == 0 and older.length <= limit);
            try self.prepare();
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
            if (trimmed) {
                self.control_length = 0;
                self.link = .none;
            }
            self.origin = older.origin;
            self.dirty = true;
            self.generation +%= 1;
            try self.prepare();
            return trimmed;
        }
    };
}

/// Immutable layout projection. Byte positions remain source/consent
/// coordinates; ScrollView is the only stored navigation coordinate.
pub const TextRows = struct {
    text: *const Document,
    layout: Layout,
    total: usize,

    pub fn init(text: *const Document, layout: Layout) TextRows {
        return .{ .text = text, .layout = layout, .total = text.rowCount(layout) };
    }
    pub fn row(self: TextRows, at: Position) usize {
        if (at.offset <= self.text.length / 2) return self.text.rowOf(self.layout, at);
        var end = self.text.length + @intFromBool(self.text.length != 0 and self.text.bytes[self.text.length - 1] != '\n');
        var remaining = self.total;
        while (self.text.previousLine(end)) |offset| {
            const used = self.text.lineRows(self.layout, offset);
            remaining -= used;
            if (offset <= at.offset) return if (at.offset >= self.text.length) self.total else remaining + @min(at.row, used - 1);
            end = offset;
        }
        return 0;
    }
    pub fn position(self: TextRows, at: usize) Position {
        if (at >= self.total) return .end;
        if (at <= self.total / 2) return self.text.positionAtRow(self.layout, at);
        var end = self.text.length + @intFromBool(self.text.bytes[self.text.length - 1] != '\n');
        var remaining = self.total;
        while (self.text.previousLine(end)) |offset| {
            remaining -= self.text.lineRows(self.layout, offset);
            if (remaining <= at) return .{ .offset = offset, .row = @intCast(at - remaining) };
            end = offset;
        }
        unreachable;
    }

    pub fn paint(self: TextRows, scroll: *vaxis.widgets.ScrollView, parent: vaxis.Window, colour: bool) void {
        if (self.total == 0) return;
        const bounds = scroll.bounds(parent);
        const first = self.position(bounds.y1);
        if (first.order(.end) == .eq) return;
        var row_: usize = bounds.y1 - first.row;
        var line: ?usize = first.offset;
        while (line) |offset| : (line = self.text.nextLine(offset)) {
            if (row_ >= bounds.y2) break;
            const used = self.text.lineRows(self.layout, offset);
            if (row_ + used > bounds.y1) {
                const delta: i17 = if (row_ >= bounds.y1) @intCast(row_ - bounds.y1) else -@as(i17, @intCast(bounds.y1 - row_));
                const window = parent.child(.{ .y_off = delta, .width = @intCast(bounds.x2 - bounds.x1) });
                _ = self.text.printLine(window, 0, offset, true, colour, .{});
            }
            row_ += used;
        }
    }
};

pub const Pane = struct {
    text: Document = .{},
    scroll: vaxis.widgets.ScrollView = .{},
    // Only transcripts have trailing canvas: preserve a logical first row
    // when text prepends or geometry grows, never create overscroll on Down.
    blank_tail: usize = 0,
    // Measured full-buffer census was 7–18 ms per clock frame at 240 KiB.
    // Cache one scalar total, never rows, cells, or a second scroll position.
    census: ?struct { generation: u64, layout: Layout, sidenotes: bool, quotes: bool, total: usize } = null,

    pub fn projection(self: *Pane, layout: Layout) TextRows {
        if (self.census) |known| {
            if (known.generation == self.text.generation and std.meta.eql(known.layout, layout) and known.sidenotes == self.text.sidenotes and known.quotes == self.text.quotes)
                return .{ .text = &self.text, .layout = layout, .total = known.total };
        }
        const rows = TextRows.init(&self.text, layout);
        self.census = .{ .generation = self.text.generation, .layout = layout, .sidenotes = self.text.sidenotes, .quotes = self.text.quotes, .total = rows.total };
        return rows;
    }
    pub fn anchor(self: *Pane, layout: Layout) Position {
        return self.projection(layout).position(self.scroll.scroll.y);
    }
    pub fn restore(self: *Pane, layout: Layout, at: Position, height: usize, pin: bool) void {
        const rows = self.projection(layout);
        self.scroll.scroll.y = @min(rows.row(at), rows.total -| 1);
        self.blank_tail = if (pin) (self.scroll.scroll.y +| height) -| rows.total else 0;
    }
    pub fn move(self: *Pane, layout: Layout, down: bool, count: usize, height: usize, unseen: ?Position) void {
        const rows = self.projection(layout);
        if (down) {
            self.scroll.scroll.y +|= count;
            if (unseen) |at| self.scroll.scroll.y = @min(self.scroll.scroll.y, rows.row(at));
        } else {
            self.scroll.scroll.y -|= count;
            self.blank_tail = @min(self.blank_tail, (self.scroll.scroll.y +| height) -| rows.total);
        }
        self.scroll.scroll.restrictTo(0, (rows.total +| self.blank_tail) -| height);
    }
};

const TestScreen = struct {
    screen: vaxis.Screen,
    cells: [40 * 14]vaxis.Cell = @splat(.{}),

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

test "an Action's wrapped description, command and stdin rows carry a wrap mark, so none passes for a field or a new line" {
    const pad: [30]u8 = @splat(' ');
    const text = "? Probe" ++ pad ++ "$ rm -rf x\n  $ echo a" ++ pad ++ "Time limit: 1 min\n  │ x" ++ pad ++ "stdin:\n  Time limit: 5 s\n";
    const command = std.mem.indexOf(u8, text, "\n  $").? + 1;
    for ([_]bool{ false, true }) |quotes| {
        errdefer std.debug.print("quotes={}\n", .{quotes});
        var view: Sized(256, false) = .{ .quotes = quotes };
        try view.append(text);
        try view.prepare();
        var test_screen: TestScreen = undefined;
        // From the command's second row too, so its first row is above the window.
        for ([_]Position{ .{}, .{ .offset = command, .row = 1 } }) |from| {
            const drawn = view.draw(test_screen.window(24, 20), from, true, false, .{});
            var storage: [128]u8 = undefined;
            var spoofs: usize = 0;
            for (0..drawn.rows) |index| {
                const row = test_screen.row(@intCast(index), &storage);
                if (std.mem.indexOf(u8, row, "Time limit: 1 min") == null and std.mem.indexOf(u8, row, "stdin:") == null) continue;
                spoofs += 1;
                try std.testing.expect(std.mem.startsWith(u8, row, if (quotes) "  ┆ " else "    "));
            }
            try std.testing.expectEqual(@as(usize, 2), spoofs);
            // The description's wrapped row cannot pass for the command.
            if (from.offset == 0) try std.testing.expectEqualStrings(if (quotes) "┆ $ rm -rf x" else "  $ rm -rf x", test_screen.row(1, &storage));
            // The field itself carries no mark.
            var field = false;
            for (0..drawn.rows) |index| field = field or std.mem.eql(u8, test_screen.row(@intCast(index), &storage), "  Time limit: 5 s");
            try std.testing.expect(field);
        }
    }
}

test "vaxis wraps reading text at words with hanging indentation" {
    var view: Sized(256, false) = .{};
    try view.append("  The plain rui command isn't on PATH\n0123456789abcdef next\n› a longword\n  supercalifragilistic x\n• one two three four\n中中中中中中中中Z\n  │ alpha beta gamma");
    try view.prepare();
    const layout: Layout = .{ .width = 16, .method = .unicode };
    var test_screen: TestScreen = undefined;
    const drawn = view.draw(test_screen.window(16, 14), .{}, true, false, .{});
    const expected = [_][]const u8{
        "  The plain rui",  "  command isn't", "  on PATH",
        "0123456789abcdef", "next",
        "› a longword",
        "  supercalifragi", "  listic x",
        "• one two three",
        "  four",
        "中中中中中中中中",
        "Z",
        // An Action's content mark hangs like a list marker.
        "  │ alpha beta",
        "    gamma",
    };
    try std.testing.expectEqual(@as(usize, 14), drawn.rows);
    try std.testing.expectEqual(Position.end, drawn.next);
    var storage: [64]u8 = undefined;
    for (expected, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    try std.testing.expectEqual(@as(usize, 14), view.measure(layout, .{}, 99).rows);
    // A word keeps its punctuation across a style change.
    var styled: Sized(64, true) = .{};
    try styled.append("ab \x1b[4mcd\x1b[0m.");
    _ = styled.draw(test_screen.window(5, 2), .{}, true, false, .{});
    try std.testing.expectEqualStrings("cd.", test_screen.row(1, &storage));
    // A wide cluster that would cross the edge starts the next row.
    var wide: Sized(64, false) = .{};
    try wide.append("abc中");
    try std.testing.expectEqual(@as(u16, 2), wide.lineRows(.{ .width = 4, .method = .unicode }, 0));
    // A draft's wide cluster moves whole to the next row.
    const whole = draft_layout.shape(DraftPieces{ .bytes = "abcd中", .method = .unicode }, 5, 7, 0);
    try std.testing.expectEqual(@as(usize, 2), whole.lines);
    try std.testing.expectEqual(@as(u16, 2), whole.caret_column);
}

test "row projection preserves source positions and wraps without navigation state" {
    var view: Sized(256, false) = .{};
    try view.append("one two three four five six\nseven\neight\n");
    const layout: Layout = .{ .width = 10, .method = .unicode };
    try std.testing.expectEqual(@as(usize, 5), view.rowCount(layout));
    for ([_]Position{ .{}, .{ .row = 1 }, .{ .row = 2 }, .{ .offset = 28 }, .{ .offset = 34 } }, 0..) |at, row| {
        try std.testing.expectEqual(at, view.positionAtRow(layout, row));
        try std.testing.expectEqual(row, view.rowOf(layout, at));
    }
    try std.testing.expectEqual(Position.end, view.positionAtRow(layout, 5));
    try std.testing.expectEqual(@as(usize, 0), view.rowOf(.{ .width = 40, .method = .unicode }, .{ .row = 2 }));
    var empty: Sized(16, false) = .{};
    try std.testing.expectEqual(@as(usize, 0), empty.rowCount(layout));
    try std.testing.expectEqual(Position.end, empty.positionAtRow(layout, 0));
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

test "a sidenote shows in the right margin of its line's first row from 60 columns" {
    const ys: [56]u8 = @splat('y');
    const xs: [60]u8 = @splat('x');
    var view: Sized(256, true) = .{ .sidenotes = true };
    try view.append("\x1b[94m›\x1b[39m \x1b[8m14:05\x1b[0m\x1b[2m" ++ ys ++ "\x1b[0m\n" ++ xs);
    var test_screen: TestScreen = undefined;
    var storage: [96]u8 = undefined;
    const Case = struct { width: u16, sidenotes: bool, rows: []const []const u8 };
    for ([_]Case{
        // Every row leaves the margin, not only rows with a sidenote.
        .{ .width = 64, .sidenotes = true, .rows = &.{ "› " ++ ys[0..55] ++ "  14:05", "  y", xs[0..57], "xxx" } },
        .{ .width = 60, .sidenotes = true, .rows = &.{ "› " ++ ys[0..51] ++ "  14:05", "  yyyyy", xs[0..53], "xxxxxxx" } },
        .{ .width = 59, .sidenotes = true, .rows = &.{ "› " ++ ys, xs[0..59], "x" } },
        .{ .width = 64, .sidenotes = false, .rows = &.{ "› " ++ ys, &xs } },
    }) |case| {
        view.sidenotes = case.sidenotes;
        const drawn = view.draw(test_screen.window(case.width, 4), .{}, true, true, .{});
        try std.testing.expectEqual(case.rows.len, drawn.rows);
        try std.testing.expectEqual(case.rows.len, view.measure(.{ .width = case.width, .method = .unicode }, .{}, 99).rows);
        for (case.rows, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    }
    view.sidenotes = true;
    _ = view.draw(test_screen.window(64, 4), .{}, true, true, .{});
    const note = test_screen.screen.readCell(59, 0).?.style;
    try std.testing.expect(note.dim and !note.italic);
    _ = view.draw(test_screen.window(64, 4), .{}, true, false, .{});
    try std.testing.expectEqual(vaxis.Style{}, test_screen.screen.readCell(59, 0).?.style);
}

test "a peer line keeps one row with its time in the right margin, as a user block's" {
    const line = "← 9f8e7d · Please review…";
    const outbound = "→ 9f8e7d · " ++ @as([40]u8, @splat('x'));
    var view: Sized(256, true) = .{ .sidenotes = true };
    try view.append("\x1b[2;8m" ++ line ++ "\x1b[8m08:00\x1b[0m\n\x1b[2;8m" ++ outbound ++ "\x1b[0m");
    var test_screen: TestScreen = undefined;
    var storage: [256]u8 = undefined;
    const Case = struct { width: u16, rows: [2][]const u8 };
    // `line` is 25 columns; the time takes the last five.
    for ([_]Case{
        .{ .width = 80, .rows = .{ line ++ @as([75 - 25]u8, @splat(' ')) ++ "08:00", outbound } },
        .{ .width = 64, .rows = .{ line ++ @as([59 - 25]u8, @splat(' ')) ++ "08:00", outbound } },
        // From 60 the margin shows; at 50 the 51-column outbound line clips.
        .{ .width = 60, .rows = .{ line ++ @as([55 - 25]u8, @splat(' ')) ++ "08:00", outbound } },
        .{ .width = 50, .rows = .{ line, "→ 9f8e7d · " ++ @as([38]u8, @splat('x')) ++ "…" } },
        // Below 60 no margin shows, and a long line ends in `…` on its one row.
        .{ .width = 40, .rows = .{ line, "→ 9f8e7d · " ++ @as([28]u8, @splat('x')) ++ "…" } },
    }) |case| {
        const drawn = view.draw(test_screen.window(case.width, 2), .{}, true, false, .{});
        try std.testing.expectEqual(@as(u16, 2), drawn.rows);
        try std.testing.expectEqual(@as(u16, 2), view.measure(.{ .width = case.width, .method = .unicode }, .{}, 99).rows);
        for (case.rows, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    }
    // Upright: the line is dim with colour, never italic.
    _ = view.draw(test_screen.window(80, 2), .{}, true, true, .{});
    const style = test_screen.screen.readCell(0, 0).?.style;
    try std.testing.expect(style.dim and !style.italic);
    // Only a `┄` row is a collapsed block for Ctrl-O: never a peer line, even
    // one whose name ends in `…`, nor a `┄` within a peer's name.
    var blocks: Sized(512, true) = .{};
    try blocks.append("\x1b[2;8m← Received message from x ┄ y\x1b[8m08:00\x1b[0m\n" ++
        "\x1b[2;8m→ Messaged Plan…\x1b[8m08:00\x1b[0m\n" ++
        "› \x1b[2m┄ typed\x1b[0m\n" ++
        "  \x1b[2;8m┄ 2 more lines\x1b[0m\n" ++
        "  \x1b[2;8m┄ 3 more lines\x1b[0m\n");
    const text = blocks.text();
    const found = blocks.collapsed(0, text.len);
    try std.testing.expectEqual(@as(usize, 2), found.count);
    try std.testing.expectEqual(std.mem.indexOf(u8, text, "┄ 3").?, found.last.?);
    try std.testing.expectEqual(@as(usize, 1), blocks.collapsed(std.mem.indexOf(u8, text, "┄ 2").? + 1, text.len).count);
}

test "a peer line's wide last cluster yields to the ellipsis instead of crossing the edge" {
    // 39 cells of text, then a two-cell cluster that would end at 41.
    const kept = "→ 9f8e7d · " ++ @as([28]u8, @splat('x'));
    var test_screen: TestScreen = undefined;
    var storage: [256]u8 = undefined;
    for ([_]gwidth.Method{ .unicode, .wcwidth }) |method| {
        var view: Sized(256, true) = .{ .sidenotes = true, .width_method = method };
        try view.append("\x1b[2;8m" ++ kept ++ "雪\x1b[0m");
        const window = test_screen.window(40, 1);
        test_screen.screen.width_method = method;
        _ = view.draw(window, .{}, true, false, .{});
        try std.testing.expectEqualStrings(kept ++ "…", test_screen.row(0, &storage));
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
    var view: Sized(64, true) = .{};
    try view.append("live 1\nlive 2\nlive 3\n");
    var older: Sized(64, true) = .{};
    try older.append("\x1b[90mold A\x1b[39m\nold B\n");
    try std.testing.expect(!try view.prepend(&older));
    try std.testing.expectEqualStrings("old A\nold B\nlive 1\nlive 2\nlive 3\n", view.text());
    const first: Position = .{ .offset = older.length + 7 };
    try std.testing.expectEqualStrings("live 2", view.bytes[first.offset..view.lineEnd(first.offset)]);
    try std.testing.expectEqual(@as(?u8, 8), cellStyle(view.styles[0], true).foreground);
    try std.testing.expectEqual(@as(?u8, null), cellStyle(view.styles[6], true).foreground);
    // Capacity: keep the older page whole and drop newest lines, line-aligned.
    var full: Sized(64, true) = .{};
    for (0..8) |index| {
        var line: [8]u8 = undefined;
        try full.append(try std.fmt.bufPrint(&line, "new {d}\n", .{index}));
    }
    var page: Sized(64, true) = .{};
    for (0..5) |index| {
        var line: [8]u8 = undefined;
        try page.append(try std.fmt.bufPrint(&line, "old {d}\n", .{index}));
    }
    try std.testing.expect(try full.prepend(&page));
    try std.testing.expect(full.length <= 64);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, full.text(), "\n"));
    const kept: Position = .{ .offset = page.length };
    try std.testing.expectEqualStrings("new 0", full.bytes[kept.offset..full.lineEnd(kept.offset)]);
    // Discarding the front keeps later text and offsets absolute.
    full.discardFront(full.origin + 6);
    try std.testing.expect(std.mem.startsWith(u8, full.text(), "old 1\n"));
    try std.testing.expectEqual(@as(u64, 6), full.origin);
}

/// Each drawn cell's link address in one row, `-` for a cell with none.
fn expectLinks(view: anytype, from: Position, width: u16, expected: []const []const u8) !void {
    var test_screen: TestScreen = undefined;
    _ = view.draw(test_screen.window(width, 1), from, true, true, .{});
    for (expected, 0..) |uri, column| {
        const cell = test_screen.screen.readCell(@intCast(column), 0).?;
        errdefer std.debug.print("column={d} grapheme={s} uri={s}\n", .{ column, cell.char.grapheme, cell.link.uri });
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, uri, "-")) "" else uri, cell.link.uri);
    }
}

fn linkBytes(comptime address_text: []const u8, comptime text: []const u8) []const u8 {
    return TerminalText.link_open ++ address_text ++ TerminalText.link_end ++ text ++ TerminalText.link_close;
}

test "a link's text carries its hidden address to the cells, however its bytes arrive" {
    const a = "https://g.dev/a";
    const b = "https://b.dev";
    const input = "See " ++ comptime linkBytes(a, "\x1b[4mg.\x1b[0m\x1b[3mdev\x1b[0m") ++ ". " ++ linkBytes(a, "x") ++ linkBytes(b, "y") ++ "!";
    for (0..input.len + 1) |split| {
        var view: Sized(256, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try view.prepare();
        // The address takes no cell: the row reads as the text alone.
        var test_screen: TestScreen = undefined;
        _ = view.draw(test_screen.window(20, 1), .{}, true, true, .{});
        var row: [64]u8 = undefined;
        try std.testing.expectEqualStrings("See g.dev. xy!", std.mem.trimEnd(u8, test_screen.row(0, &row), " "));
        try expectLinks(&view, .{}, 20, &.{ "-", "-", "-", "-", a, a, a, a, a, "-", "-", a, b, "-" });
        const shown = test_screen.screen.readCell(4, 0).?.style;
        try std.testing.expect(shown.ul_style == .single and shown.fg == .default);
    }
}

test "a link keeps its address through wrapping, escaping, older pages and eviction" {
    const a = "https://a.dev";
    // Wrapped rows of one link all open it.
    var wrapped: Sized(256, true) = .{};
    try wrapped.append(comptime linkBytes(a, "one two three"));
    try expectLinks(&wrapped, .{ .offset = 0, .row = 1 }, 8, &.{ a, a, a, a, a });
    // Escaped text before and inside a link moves with it.
    var escaped: Sized(256, true) = .{};
    try escaped.append("\u{200b}" ++ comptime linkBytes(a, "b\u{200b}c") ++ "d" ++ TerminalText.link_open ++ a ++ TerminalText.link_end ++ "e");
    try escaped.prepare();
    const before: []const []const u8 = &.{ "-", "-", "-", "-", "-", "-", "-", "-" };
    const inside: []const []const u8 = &.{ a, a, a, a, a, a, a, a, a, a };
    try expectLinks(&escaped, .{}, 24, before ++ inside ++ &[_][]const u8{ "-", a });
    try escaped.append("f" ++ TerminalText.link_close ++ "g");
    try escaped.prepare();
    try expectLinks(&escaped, .{}, 24, before ++ inside ++ &[_][]const u8{ "-", a, a, "-" });
    // An older page placed before keeps both pages' links on their text.
    const b = "https://b.dev";
    var view: Sized(256, true) = .{};
    try view.append("See " ++ comptime linkBytes(a, "docs") ++ "\n");
    var older: Sized(64, true) = .{};
    try older.append(comptime linkBytes(b, "old") ++ " page\n");
    try std.testing.expect(!try view.prepend(&older));
    try expectLinks(&view, .{}, 16, &.{ b, b, b, "-", "-" });
    try expectLinks(&view, .{ .offset = view.nextLine(0).? }, 16, &.{ "-", "-", "-", "-", a, a, a, a, "-" });
    // Eviction that cuts into an address leaves its text unlinked, never
    // linked to part of an address.
    var evicted: Sized(32, true) = .{};
    try evicted.append(comptime linkBytes("https://abcdefghij.dev", "link") ++ " and more words");
    try std.testing.expect(evicted.origin != 0);
    try expectLinks(&evicted, .{}, 16, &.{ "-", "-", "-", "-" });
}

test "rendered local path cells carry the file URI but the sentence semicolon does not" {
    const prefix = "The report is at ";
    const path = "~/code/personal/rui-implicit-state-machines.md";
    const input = prefix ++ path ++ ";";
    const uri = "file:///home/test/code/personal/rui-implicit-state-machines.md";
    for (0..input.len + 1) |split| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: @import("AnswerRenderer.zig") = .{ .out = &output.writer, .home = "/home/test" };
        try renderer.feed(input[0..split]);
        for (input[split..]) |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        var view: Sized(512, true) = .{};
        try view.append(output.written());
        try view.prepare();
        var screen: TestScreen = undefined;
        _ = view.draw(screen.window(80, 1), .{}, true, true, .{});
        var row: [128]u8 = undefined;
        try std.testing.expectEqualStrings(input, std.mem.trimEnd(u8, screen.row(0, &row), " "));
        for (0..input.len) |column| {
            const cell = screen.screen.readCell(@intCast(column), 0).?;
            const in_path = column >= prefix.len and column < prefix.len + path.len;
            try std.testing.expectEqualStrings(if (in_path) uri else "", cell.link.uri);
            try std.testing.expectEqual(in_path, cell.style.ul_style == .single);
        }
    }
}

test "row projection cost at retained capacity" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    const layout: Layout = .{ .width = 79, .method = .unicode };
    for ([_][]const u8{ "short line\n", "abcdefghijklmnopqrstuvwxyz", "\x1b[90m中 é 🐄\x1b[39m\n", (comptime linkBytes("https://example.test", "linked text")) ++ "\n" }, 0..) |line, index| {
        pane.* = .{};
        while (pane.text.length < 240 * 1024) try pane.text.append(line);
        try pane.text.prepare();
        const start = std.Io.Clock.awake.now(std.testing.io);
        for (0..10) |_| {
            var offset = pane.text.length;
            for (0..21) |_| {
                const previous = pane.text.previousLine(offset) orelse break;
                offset = previous;
                std.mem.doNotOptimizeAway(pane.text.lineRows(layout, offset));
                if (offset == 0) break;
            }
        }
        const cold = std.Io.Clock.awake.now(std.testing.io);
        _ = pane.projection(layout);
        const middle = std.Io.Clock.awake.now(std.testing.io);
        for (0..10) |_| {
            const rows = pane.projection(layout);
            std.mem.doNotOptimizeAway(rows.position(rows.total -| 21));
        }
        const end = std.Io.Clock.awake.now(std.testing.io);
        std.debug.print("row cost case{d}: tail={d}ns cold={d}ns projection={d}ns /10\n", .{ index, cold.nanoseconds - start.nanoseconds, middle.nanoseconds - cold.nanoseconds, end.nanoseconds - middle.nanoseconds });
    }
}

test "the library row owner preserves a pinned short canvas without downward overscroll" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.* = .{};
    const layout: Layout = .{ .width = 19, .method = .unicode };
    for (0..10) |_| try pane.text.append("line\n");
    try pane.text.prepare();
    pane.restore(layout, .{ .offset = 15 }, 10, true);
    try std.testing.expectEqual(@as(usize, 3), pane.scroll.scroll.y);
    try std.testing.expectEqual(@as(usize, 3), pane.blank_tail);
    pane.move(layout, true, 100, 10, null);
    try std.testing.expectEqual(@as(usize, 3), pane.scroll.scroll.y);
    pane.move(layout, false, 1, 10, null);
    try std.testing.expectEqual(@as(usize, 2), pane.scroll.scroll.y);
    try std.testing.expectEqual(@as(usize, 2), pane.blank_tail);
    pane.move(layout, true, 100, 10, null);
    try std.testing.expectEqual(@as(usize, 2), pane.scroll.scroll.y);
    const anchor = pane.anchor(layout);
    try pane.text.append("new\nnew\nnew\n");
    try pane.text.prepare();
    pane.restore(layout, anchor, 10, true);
    try std.testing.expectEqual(@as(usize, 2), pane.scroll.scroll.y);
    try std.testing.expectEqual(@as(usize, 0), pane.blank_tail);
    pane.move(layout, true, 1, 10, null);
    try std.testing.expectEqual(@as(usize, 3), pane.scroll.scroll.y);
}

test "row projection cache follows every text edit and complete layout key" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.* = .{};
    try pane.text.append("alpha beta gamma\nline\n");
    try pane.text.prepare();
    for ([_]u16{ 8, 79, 8 }) |width| {
        const layout: Layout = .{ .width = width, .method = .unicode };
        for ([_]bool{ true, false }) |sidenotes| {
            pane.text.sidenotes = sidenotes;
            pane.text.quotes = !sidenotes;
            const rows = pane.projection(layout);
            try std.testing.expectEqual(pane.text.rowCount(layout), rows.total);
            for (0..rows.total) |row| {
                try std.testing.expectEqual(pane.text.positionAtRow(layout, row), rows.position(row));
                try std.testing.expectEqual(row, rows.row(rows.position(row)));
            }
        }
    }
    const layout: Layout = .{ .width = 79, .method = .wcwidth };
    try pane.text.append("new\n");
    try pane.text.prepare();
    try std.testing.expectEqual(@as(usize, 3), pane.projection(layout).total);
    var older: Sized(64, true) = .{};
    try older.append("older\n");
    _ = try pane.text.prepend(&older);
    try std.testing.expectEqual(@as(usize, 4), pane.projection(layout).total);
    pane.text.discardFront(pane.text.origin + 6);
    try std.testing.expectEqual(@as(usize, 3), pane.projection(layout).total);
    pane.text.clear();
    try std.testing.expectEqual(@as(usize, 0), pane.projection(layout).total);
}

test "normalized suffix copying preserves styles and complete linked collapsed summaries" {
    var source: Sized(256, true) = .{};
    try source.append("prefix\n\x1b[90mquiet\x1b[39m " ++ comptime linkBytes("https://example.test", "docs") ++ "\n");
    try source.prepare();
    var copy: Sized(256, true) = .{};
    try copy.append("prefix\n");
    try std.testing.expectEqual(source.length - 7, copy.appendRetained(&source, 7));
    try std.testing.expectEqualSlices(u8, source.text(), copy.text());
    try std.testing.expectEqualSlices(u8, source.styles[0..source.length], copy.styles[0..copy.length]);
    try expectLinks(&copy, .{ .offset = 7 }, 20, &.{ "-", "-", "-", "-", "-", "-", "https://example.test", "https://example.test", "https://example.test", "https://example.test" });
    // A bounded copy stops at a complete logical line, never mid-address or
    // mid-summary. The remaining source bytes stay identifiable by endpoint.
    var small_source: Sized(32, true) = .{};
    try small_source.append("a\nb\nlonger than available\n");
    var bounded: Sized(32, true) = .{};
    try bounded.append("already kept bytes\n");
    const copied = bounded.appendRetained(&small_source, 0);
    try std.testing.expectEqual(@as(usize, 4), copied);
    try std.testing.expect(std.mem.endsWith(u8, bounded.text(), "a\nb\n"));
}

test "ScrollView translated printing keeps wrapped link cells and hanging indentation" {
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.* = .{};
    try pane.text.append("• " ++ comptime linkBytes("https://example.test", "alpha beta gamma delta epsilon zeta") ++ "\n");
    try pane.text.prepare();
    const layout: Layout = .{ .width = 12, .method = .unicode };
    var screen: TestScreen = undefined;
    const window = screen.window(13, 3);
    pane.scroll.scroll.y = 1;
    const rows = pane.projection(layout);
    pane.scroll.draw(window, .{ .cols = layout.width, .rows = rows.total });
    rows.paint(&pane.scroll, window, false);
    try std.testing.expectEqual(@as(usize, 1), pane.scroll.scroll.y);
    try std.testing.expectEqualStrings(" ", screen.screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("https://example.test", screen.screen.readCell(2, 0).?.link.uri);
    try std.testing.expectEqualStrings("d", screen.screen.readCell(2, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("▐", screen.screen.readCell(12, 0).?.char.grapheme);
}
