//! Bounded display text, independent of canonical history and terminal cells.
//! vaxis lays out and draws rows (`Window.print`); this module keeps retained
//! bytes, trusted styles and which row of which logical line a view starts at.
const std = @import("std");
const utf8_validation = @import("utf8_validation.zig");
const vaxis = @import("vaxis");
const gwidth = @import("terminal_width");
const unicode = @import("terminal_unicode");
const state_marks = @import("marks.zig");
const draft_layout = @import("draft_layout.zig");
const TerminalText = @import("TerminalText.zig");
const tool_fold = @import("tool_fold.zig");
const display_text = @import("display_text.zig");
pub const Document = Sized(capacity, true);
pub const Method = gwidth.Method;

pub const capacity = 256 * 1024;
pub const widest_cluster = display_text.widest_cluster;
pub const longest_cluster = display_text.longest_cluster;

/// A row of laid-out text: the logical line starting at origin-relative byte
/// `offset`, and the row within that line's wrapping.
pub const Position = @import("ViewportPosition.zig");

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

pub const representable = display_text.representable;

/// Shared answer/UI link boundary. Text and URI remain borrowed through the
/// draw; Vaxis carries the URI on the cells and emits the terminal's OSC 8.
/// Address validation and text styling stay with the caller.
pub fn linkedSegment(text: []const u8, style: vaxis.Style, uri: []const u8) vaxis.Cell.Segment {
    return .{ .text = text, .style = style, .link = .{ .uri = uri } };
}

/// Test builds count every `lineRows` measurement, so cost tests assert
/// how layout work grows without timing it. Release builds keep no counter.
pub var measured_lines: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {};

/// Rows used by a print that ended at `result`. A row is used once text
/// reaches it; an exact fill leaves the next row unused. Overflow means
/// that at least one more row remains, even when the last visible row filled.
fn rowsUsed(result: vaxis.Window.PrintResult) u16 {
    return if (result.col == 0 and result.row != 0 and !result.overflow) result.row else result.row +| 1;
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
    const state_glyphs = comptime glyphs: {
        var all: [state_marks.marks.values.len * 2][]const u8 = undefined;
        for (state_marks.marks.values, 0..) |mark, index| {
            all[index * 2] = mark.unicode;
            all[index * 2 + 1] = mark.ascii;
        }
        break :glyphs all;
    };
    for ([_][]const u8{ "›", "•", "◦", "!", "-", "$", "│" } ++ state_glyphs) |glyph| {
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

/// Feed foreground roles resolved by the caller's theme. Unthemed callers
/// leave every role at the terminal default.
pub const Colours = struct {
    quiet: vaxis.Color = .default,
    user: vaxis.Color = .default,
    attention: vaxis.Color = .default,
    failure: vaxis.Color = .default,
    /// One line-level selvedge band for code and tool output.
    band: vaxis.Color = .default,
    selection: vaxis.Color = .default,
};

/// Retained style byte, display-only: bits 0-2 bold, italic and underline,
/// bits 3-5 a foreground index, bit 6 user text and bit 7 its dim summary.
/// Bit 7 alone marks a sidenote, drawn in the right margin.
/// Slot 5 marks code: SGR 40 covers each complete body line, including its
/// newline, so even an empty line and an evicted prefix need no side storage.
/// Two foreground indexes no colour uses mark an OSC 8 link: its address,
/// kept in the text but never drawn, and right after it the text it links.
const foreground_mask: u8 = 0b111 << 3;
const code_index: u8 = 5;
const linked_index: u8 = 6;
const address_index: u8 = 7;

/// End link runs at a document seam while retaining the blank code-line role.
pub fn seamStyle(value: u8) u8 {
    return if (foregroundIndex(value) == code_index) code_index << 3 else 0;
}

fn foregroundIndex(value: u8) u8 {
    return (value & foreground_mask) >> 3;
}

// Only links underline, so a coloured, underlined label can retain its ink
// or quiet foreground without a second style byte. Other labels use slot 6.
fn isLinked(value: u8) bool {
    const index = foregroundIndex(value);
    return index == linked_index or (index >= 1 and index <= 4 and value & 4 != 0);
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
pub const CellStyle = struct {
    bold: bool = false,
    quiet: bool = false,
    italic: bool = false,
    underline: bool = false,
    foreground: ?enum { attention, quiet, failure, user } = null,
};
/// User text is quiet and italic with colour. Summaries and sidenotes are
/// quiet but upright; without colour, position alone sets user text apart.
pub fn cellStyle(value: u8, colour: bool) CellStyle {
    const index = foregroundIndex(value);
    const quiet = colour and value & (user_bit | summary_bit) != 0;
    return .{
        .bold = value & 1 != 0,
        .quiet = quiet,
        .italic = value & 2 != 0 or (quiet and value & summary_bit == 0),
        .underline = value & 4 != 0,
        .foreground = if (colour) switch (index) {
            1 => .attention,
            2 => .quiet,
            3 => .failure,
            4 => .user,
            else => null,
        } else null,
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
        /// The first row in view; null follows the latest rows.
        top: ?Position = null,
        width_method: gwidth.Method = .wcwidth,
        dirty: bool = true,
        /// Reserve the right margin for sidenotes at `sidenote_width` and wider.
        sidenotes: bool = false,
        /// An Action: each wrapped row of its description, command or stdin
        /// starts with `┆`, so no row of that text can pass for a field, nor
        /// a wrapped row for a new `│` line.
        quotes: bool = false,
        /// Counts clears: offsets from before one name other text.
        replacements: u32 = 0,

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
                            const colour_index: u8 = if (std.mem.eql(u8, code, "\x1b[33m")) 1 else if (std.mem.eql(u8, code, "\x1b[90m")) 2 else if (std.mem.eql(u8, code, "\x1b[91m")) 3 else if (std.mem.eql(u8, code, "\x1b[94m")) 4 else if (std.mem.eql(u8, code, "\x1b[40m")) code_index else unreachable;
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
        }

        /// The retained style of text appended now, with any link mark.
        fn cellValue(self: *const Self) u8 {
            const index: u8 = switch (self.link) {
                .none => return self.style,
                .address => address_index,
                .text => if (self.style & 4 != 0 and foregroundIndex(self.style) >= 1 and foregroundIndex(self.style) <= 4) return self.style else linked_index,
            };
            return (self.style & ~foreground_mask) | (index << 3);
        }

        /// The address of the link whose text holds `position`: the hidden
        /// run right before that text. Empty when the text is not a link or
        /// its address began before the retained text.
        fn address(self: *const Self, position: usize) []const u8 {
            if (!isLinked(self.styles[position])) return "";
            var end = position;
            while (end > 0 and isLinked(self.styles[end - 1])) end -= 1;
            var start = end;
            while (start > 0 and foregroundIndex(self.styles[start - 1]) == address_index) start -= 1;
            if (start == 0 and self.origin != 0) return "";
            return self.bytes[start..end];
        }

        /// A hidden link address: kept in the text, never drawn or copied.
        fn hidden(self: *const Self, position: usize) bool {
            return styled and foregroundIndex(self.styles[position]) == address_index;
        }

        /// The address the terminal gets for the text at `position`: a
        /// Session link opens inside Rui, so the terminal gets none.
        fn terminalLink(self: *const Self, position: usize) []const u8 {
            if (!styled) return "";
            const uri = self.address(position);
            return if (std.mem.startsWith(u8, uri, TerminalText.session_link)) "" else uri;
        }

        /// The Session a peer's name at `position` links to, by its ID.
        /// The slice is this text's: copy it before the text changes.
        pub fn sessionAt(self: *const Self, position: usize) ?[]const u8 {
            comptime std.debug.assert(styled);
            if (position >= self.text().len) return null;
            const uri = self.address(position);
            return if (std.mem.startsWith(u8, uri, TerminalText.session_link)) uri[TerminalText.session_link.len..] else null;
        }

        /// Where in the current text a cell laid out from it starts, or
        /// null for a cell that shows none of it: blank, indent, `…` or
        /// `┆`. A text cell's grapheme points into the text.
        pub fn cellOffset(self: *const Self, cell: vaxis.Cell) ?usize {
            const at = @intFromPtr(cell.char.grapheme.ptr);
            const base = @intFromPtr(&self.bytes);
            if (cell.char.grapheme.len == 0 or at < base or at >= base + self.text().len) return null;
            return at - base;
        }

        /// The text of `[from, to)` as the view shows it, for the clipboard:
        /// wrapping adds no bytes, so wrapped rows join as the text runs;
        /// right-margin times and hidden link addresses are left out, and a
        /// tab, shown as a space, copies as one. Null past `most` bytes.
        pub fn shownText(self: *const Self, gpa: std.mem.Allocator, from: usize, to: usize, most: usize) !?[]u8 {
            comptime std.debug.assert(styled);
            const end = @min(to, self.text().len);
            const start = @min(from, end);
            var length: usize = 0;
            for (start..end) |index| {
                if (!isSidenote(self.styles[index]) and !self.hidden(index)) length += 1;
            }
            if (length > most) return null;
            const out = try gpa.alloc(u8, length);
            length = 0;
            for (start..end) |index| {
                if (isSidenote(self.styles[index]) or self.hidden(index)) continue;
                out[length] = if (self.bytes[index] == '\t') ' ' else self.bytes[index];
                length += 1;
            }
            return out;
        }

        /// Whether a drawn cell's text at `position` belongs to the body:
        /// right-margin times are apart from the text a drag selects.
        pub fn selectable(self: *const Self, position: usize) bool {
            return position < self.text().len and !(styled and isSidenote(self.styles[position]));
        }

        pub fn clear(self: *Self) void {
            self.replacements +%= 1;
            self.length = 0;
            self.origin = 0;
            self.top = null;
            self.style = 0;
            self.control_length = 0;
            self.link = .none;
            self.dirty = true;
        }

        pub fn text(self: *const Self) []const u8 {
            return utf8_validation.completePrefix(self.bytes[0..self.length]);
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
                    var displayed: display_text.Cluster = .{ .raw = raw, .method = self.width_method };
                    while (displayed.next()) |piece| try self.appendText(piece.bytes);
                }
                if (styled and complete < length) self.style = styles[complete];
                try self.appendText(bytes[complete..length]);
                return;
            }
        }

        /// Tool identity uses the same retained, hidden address representation as
        /// internal Session links, with no new style bytes or closed output cache.
        const LineMarker = struct { marker: tool_fold.Marker, end: usize };

        fn lineMarker(self: *const Self, offset: usize) ?LineMarker {
            if (!styled or offset >= self.text().len or foregroundIndex(self.styles[offset]) != address_index) return null;
            var end = offset;
            while (end < self.text().len and foregroundIndex(self.styles[end]) == address_index) : (end += 1) {}
            return .{ .marker = tool_fold.Marker.of(self.bytes[offset..end]) orelse return null, .end = end };
        }

        fn markerAt(self: *const Self, offset: usize) ?tool_fold.Marker {
            return (self.lineMarker(offset) orelse return null).marker;
        }

        /// A tool row's heading line: the row Ctrl-O or a click folds.
        pub fn toolHeading(self: *const Self, offset: usize) bool {
            return self.markerAt(offset) == .heading;
        }

        /// Whether the heading line at `offset` has its output shown on the
        /// lines after it.
        fn headingOpen(self: *const Self, offset: usize) bool {
            return self.markerAt(self.nextLine(offset) orelse return false) == .output;
        }

        pub fn toolIsOpen(self: *const Self, offset: usize) bool {
            return self.toolHeading(offset) and self.headingOpen(offset);
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

        const Line = enum {
            plain,
            code,
            output,
            selected,

            fn style(kind: Line, colour: bool, base: vaxis.Style, colours: Colours) vaxis.Style {
                var result = base;
                if (!colour) return result;
                result.bg = switch (kind) {
                    .plain => base.bg,
                    .code, .output => colours.band,
                    .selected => colours.selection,
                };
                if (kind == .output) result.fg = colours.quiet;
                return result;
            }
        };

        /// A line's trusted marker owns its band, never an independent code
        /// painter or a retained list of byte offsets to repair after edits.
        fn lineKind(self: *const Self, offset: usize, mark: ?LineMarker) Line {
            if (mark) |value| switch (value.marker) {
                .output => return .output,
                .heading => if (self.headingOpen(offset)) return .selected,
            };
            if (styled and offset < self.length and foregroundIndex(self.styles[offset]) == code_index) return .code;
            return .plain;
        }

        /// Prints one logical line with its first row at window row `row`
        /// (negative rows are clipped), or only measures it. Returns its rows.
        /// Measuring and drawing segment identically, so they wrap identically.
        pub fn printLine(self: *const Self, window: vaxis.Window, row: i17, offset: usize, commit: bool, colour: bool, base: vaxis.Style, colours: Colours) u16 {
            const end = self.lineEnd(offset);
            const mark = self.lineMarker(offset);
            const content_start = if (mark) |value| value.end else offset;
            const kind = self.lineKind(offset, mark);
            const output = kind == .output;
            const plain = kind.style(colour, base, colours);
            // Every band (including selection) is painted here, over the
            // measured logical line's blank cells and wrapped rows alike.
            if (commit and colour and kind != .plain) {
                const used = self.printLine(window, row, offset, false, colour, base, colours);
                const first_row: i32 = @max(row, 0);
                const last_row: i32 = @min(@as(i32, row) + used, window.height);
                if (last_row > first_row) window.child(.{ .y_off = @intCast(first_row), .height = @intCast(last_row - first_row) }).fill(.{ .style = plain });
            }
            if (kind == .code) {
                const line = window.child(.{ .y_off = row });
                var leading: usize = offset;
                while (leading < end and (self.bytes[leading] == ' ' or self.bytes[leading] == '\t')) leading += 1;
                // Code's own indent, not prose/list hanging. Keep one cell
                // for progress even at the narrowest widths.
                const indent = @min(display_text.width(self.bytes[offset..leading], .{ .viewport = self.width_method }), line.width -| 1);
                if (commit) _ = self.printRange(line.child(.{ .width = indent, .height = 1 }), offset, leading, .word, false, true, colour, plain, colours);
                return rowsUsed(self.printRange(line.child(.{ .x_off = indent }), leading, end, .word, false, commit, colour, plain, colours));
            }
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
            // Tool output is bounded in screen rows too: long logical lines
            // keep their prefix and a visible ellipsis rather than wrapping
            // past the twenty-row fold budget.
            if (output) single = true;
            // A single row's text ends where its trailing sidenote begins.
            const shown = if (note) |range| (if (range.end == end) range.start else end) else end;
            const margin: u16 = if (styled and self.sidenotes and window.width >= sidenote_width) sidenote_margin else 0;
            const body = window.child(.{ .width = window.width - margin });
            if (commit and margin != 0) if (note) |range| {
                _ = self.printRange(window.child(.{ .x_off = window.width - sidenote_cells, .y_off = row, .width = sidenote_cells, .height = 1 }), range.start, range.end, .none, true, true, colour, plain, colours);
            };
            if (single) {
                if (commit) {
                    // Whole clusters measured by this view's width method:
                    // a wide last cluster never crosses the body's edge.
                    // A Session link's hidden address takes no cells.
                    const line = body.child(.{ .y_off = row, .height = 1 });
                    const text_bytes = self.bytes[offset..shown];
                    var whole: usize = 0;
                    var measured = unicode.graphemeIterator(text_bytes);
                    while (measured.next()) |cluster| {
                        if (!self.hidden(offset + cluster.start)) whole += gwidth.gwidth(cluster.bytes(text_bytes), self.width_method);
                    }
                    if (whole <= line.width) {
                        _ = self.printRange(line, offset, shown, .none, false, true, colour, plain, colours);
                    } else if (line.width != 0) {
                        var clusters = unicode.graphemeIterator(text_bytes);
                        var used: u16 = 0;
                        var cut = offset;
                        while (clusters.next()) |cluster| {
                            const width = if (self.hidden(offset + cluster.start)) 0 else gwidth.gwidth(cluster.bytes(text_bytes), self.width_method);
                            if (used + width > line.width - 1) break;
                            used += width;
                            cut = offset + cluster.start + cluster.len;
                        }
                        _ = self.printRange(line, offset, cut, .none, false, true, colour, plain, colours);
                        _ = line.child(.{ .x_off = used, .width = 1 }).print(&.{.{ .text = "…", .style = self.segmentStyle(offset, colour, plain, colours) }}, .{ .wrap = .none });
                    }
                }
                return 1;
            }
            const split = hanging(self.bytes[content_start..end], body.width, user);
            if (commit) _ = self.printRange(body.child(.{ .y_off = row, .height = 1 }), content_start, content_start + split.bytes, .none, false, true, colour, plain, colours);
            const rows = rowsUsed(self.printRange(body.child(.{ .x_off = split.cells, .y_off = row }), content_start + split.bytes, end, .word, false, commit, colour, plain, colours));
            if (commit and self.quotes and split.quoted) for (1..rows) |index| {
                const quote_mark = body.child(.{ .x_off = split.cells - 2, .y_off = row + @as(i17, @intCast(index)), .width = 1, .height = 1 });
                _ = quote_mark.printSegment(.{ .text = "┆", .style = self.segmentStyle(content_start + split.bytes - 2, colour, plain, colours) }, .{ .wrap = .none });
            };
            return rows;
        }

        /// Prints bytes as style runs, a bounded batch of segments at a time:
        /// sidenotes only, or the text's flow without them.
        fn printRange(self: *const Self, window: vaxis.Window, from: usize, end: usize, wrap: @FieldType(vaxis.PrintOptions, "wrap"), notes: bool, commit: bool, colour: bool, plain: vaxis.Style, colours: Colours) vaxis.Window.PrintResult {
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
                    segments[count] = linkedSegment(self.bytes[start..stop], self.segmentStyle(start, colour, plain, colours), self.terminalLink(start));
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

        fn segmentStyle(self: *const Self, position: usize, colour: bool, plain: vaxis.Style, colours: Colours) vaxis.Style {
            if (!styled) return plain;
            const value = cellStyle(self.styles[position], colour);
            return .{
                .bold = value.bold,
                .italic = value.italic,
                .ul_style = if (value.underline) .single else .off,
                .fg = if (value.foreground) |role| switch (role) {
                    .attention => colours.attention,
                    .quiet => colours.quiet,
                    .failure => colours.failure,
                    .user => colours.user,
                } else if (value.quiet) colours.quiet else plain.fg,
                .bg = plain.bg,
            };
        }

        pub fn lineRows(self: *const Self, layout: Layout, offset: usize) u16 {
            if (@import("builtin").is_test) measured_lines += 1;
            var screen: vaxis.Screen = undefined;
            return self.printLine(layout.measuring(&screen), 0, offset, false, false, .{}, .{});
        }

        /// Draws rows from `first` into `window`; returns the rows drawn and
        /// the first row left undrawn, or `Position.end` when none remain.
        pub fn draw(self: *const Self, window: vaxis.Window, from: Position, commit: bool, colour: bool, plain: vaxis.Style, colours: Colours) struct { rows: usize, next: Position } {
            if (self.text().len == 0) return .{ .rows = 0, .next = .end };
            var row: i32 = -@as(i32, from.row);
            var line: ?usize = from.offset;
            while (line) |offset| : (line = self.nextLine(offset)) {
                if (row >= window.height) return .{ .rows = window.height, .next = .{ .offset = offset } };
                const used = self.printLine(window, @intCast(row), offset, commit, colour, plain, colours);
                if (row + used > window.height) return .{ .rows = window.height, .next = .{ .offset = offset, .row = @intCast(window.height - row) } };
                row += used;
            }
            return .{ .rows = @intCast(row), .next = .end };
        }

        /// Rows from `from` down, in one forward pass that measures each line
        /// once: the nth `next` is `down(layout, from, n)` while `measure`
        /// from `from` still counts row n. A frame walks every row through
        /// this, not through repeated `down`, which would make it quadratic.
        pub fn rowsFrom(self: *const Self, layout: Layout, from: Position) Rows {
            return .{ .document = self, .layout = layout, .position = if (self.text().len == 0) null else self.clamp(layout, from) };
        }

        /// Borrows the document; any edit invalidates it.
        pub const Rows = struct {
            document: *const Self,
            layout: Layout,
            position: ?Position,
            /// The current line's rows, measured on its first row.
            used: ?u16 = null,

            /// The next row, or null below the text.
            pub fn next(self: *Rows) ?Position {
                const position = self.position orelse return null;
                const used = self.used orelse self.document.lineRows(self.layout, position.offset);
                self.used = used;
                if (position.row + 1 < used) {
                    self.position.?.row += 1;
                } else {
                    self.position = if (self.document.nextLine(position.offset)) |offset| .{ .offset = offset } else null;
                    self.used = null;
                }
                return position;
            }
        };

        /// Rows from `from` that fit `height`, without drawing.
        pub fn measure(self: *const Self, layout: Layout, from: Position, height: u16) struct { rows: usize, next: Position } {
            var screen: vaxis.Screen = undefined;
            var window = layout.measuring(&screen);
            window.height = height;
            const result = self.draw(window, from, false, false, .{}, .{});
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

        /// The collapsed block whose `┄` row is the logical line at `offset`,
        /// counted from the end as Ctrl-O names one (0 is the last), or null
        /// when that line is not a collapsed block's row. A click on the row
        /// opens that Message.
        pub fn summaryAt(self: *const Self, offset: usize) ?usize {
            if (offset >= self.text().len) return null;
            const found = self.collapsed(offset, self.lineEnd(offset)).last orelse return null;
            return self.collapsed(found + 1, self.text().len).count;
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
            if (trimmed) {
                self.control_length = 0;
                self.link = .none;
            }
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
            const drawn = view.draw(test_screen.window(24, 20), from, true, false, .{}, .{});
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

test "every state mark hangs continuation text in both scripts" {
    for (state_marks.marks.values) |mark| {
        for ([_][]const u8{ mark.unicode, mark.ascii }) |glyph| {
            var buffer: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&buffer, "{s} long description", .{glyph});
            const split = hanging(line, 16, false);
            try std.testing.expectEqual(glyph.len + 1, split.bytes);
            try std.testing.expectEqual(@as(u16, 2), split.cells);
            try std.testing.expectEqualStrings("long description", line[split.bytes..]);
        }
    }
}

test "vaxis wraps reading text at words with hanging indentation" {
    var view: Sized(256, false) = .{};
    try view.append("  The plain rui command isn't on PATH\n0123456789abcdef next\n› a longword\n  supercalifragilistic x\n⠹ one two three four\n中中中中中中中中Z\n  │ alpha beta gamma");
    try view.prepare();
    const layout: Layout = .{ .width = 16, .method = .unicode };
    var test_screen: TestScreen = undefined;
    const drawn = view.draw(test_screen.window(16, 14), .{}, true, false, .{}, .{});
    const expected = [_][]const u8{
        "  The plain rui",  "  command isn't", "  on PATH",
        "0123456789abcdef", "next",
        "› a longword",
        "  supercalifragi", "  listic x",
        "⠹ one two three",
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
    _ = styled.draw(test_screen.window(5, 2), .{}, true, false, .{}, .{});
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

test "a clipped final wrapped line leaves an unread row in plain and styled documents" {
    inline for (.{ false, true }) |styled| {
        var document: Sized(128, styled) = .{};
        try document.append(if (styled) "first\nsecond \x1b[1mthird\x1b[0m fourth" else "first\nsecond third fourth");
        var screen: TestScreen = undefined;
        for ([_]Position{ .{ .offset = 6 }, .{ .offset = 6, .row = 1 }, .{ .offset = 6, .row = 2 }, .end }, 1..) |expected, height| {
            const drawn = document.draw(screen.window(8, @intCast(height)), .{}, true, true, .{}, .{});
            try std.testing.expectEqual(expected, drawn.next);
        }
        const resumed = document.draw(screen.window(8, 1), .{ .offset = 6, .row = 1 }, true, true, .{}, .{});
        try std.testing.expectEqual(Position{ .offset = 6, .row = 2 }, resumed.next);
    }
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
    // One append per thousand chunks: each full-document append shifts the
    // retained bytes, so thirty thousand tiny appends cost seconds.
    const block = comptime block: {
        var bytes: [chunk.len * 1000]u8 = undefined;
        for (0..1000) |index| @memcpy(bytes[index * chunk.len ..][0..chunk.len], chunk);
        break :block bytes;
    };
    for (0..30) |_| try view.append(&block);
    try view.prepare();
    try std.testing.expect(view.length <= capacity);
    try std.testing.expect(view.origin != 0);
    try std.testing.expect(std.mem.endsWith(u8, view.text(), chunk));
}

test "trusted renderer styles survive fragmented output retention" {
    const input = "plain \x1b[1mbold\x1b[0m \x1b[3mital\x1b[94mcode\x1b[0m \x1b[94muser\x1b[39m!";
    for (0..input.len + 1) |split| {
        var view: Sized(32, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try std.testing.expectEqualStrings("plain bold italcode user!", view.text());
        try std.testing.expect(cellStyle(view.styles[6], true).bold);
        try std.testing.expect(!cellStyle(view.styles[10], true).bold);
        const nested = cellStyle(view.styles[15], true);
        try std.testing.expect(nested.italic and !nested.underline and nested.foreground == .user);
        try std.testing.expect(cellStyle(view.styles[20], true).foreground == .user);
        try std.testing.expect(cellStyle(view.styles[20], false).foreground == null);
        try view.append(" extra words that evict the prefix");
        try std.testing.expect(view.origin != 0);
        try std.testing.expectEqualStrings("xtra words that evict the prefix", view.text());
        for (view.styles[0..view.length]) |style_value| try std.testing.expectEqual(CellStyle{}, cellStyle(style_value, true));
    }
    // Drawn cells carry the retained style, including a coloured marker.
    var marked: Sized(32, true) = .{};
    try marked.append("\x1b[94m›\x1b[39m hi");
    var test_screen: TestScreen = undefined;
    const colours: Colours = .{ .user = .{ .rgb = .{ 31, 45, 107 } } };
    _ = marked.draw(test_screen.window(8, 1), .{}, true, true, .{}, colours);
    try std.testing.expectEqual(colours.user, test_screen.screen.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(vaxis.Color.default, test_screen.screen.readCell(2, 0).?.style.fg);
    for ([_]bool{ false, true }) |colour| {
        _ = marked.draw(test_screen.window(8, 1), .{}, true, colour, .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } }, colours);
        try std.testing.expectEqual(if (colour) colours.user else vaxis.Color{ .index = 255 }, test_screen.screen.readCell(0, 0).?.style.fg);
        try std.testing.expectEqual(vaxis.Color{ .index = 255 }, test_screen.screen.readCell(2, 0).?.style.fg);
        try std.testing.expectEqual(vaxis.Color{ .index = 19 }, test_screen.screen.readCell(0, 0).?.style.bg);
        try std.testing.expectEqual(vaxis.Color{ .index = 19 }, test_screen.screen.readCell(2, 0).?.style.bg);
    }
}

test "every foreground slot draws its supplied role colour or the plain foreground without colour" {
    const palettes = [_]Colours{
        .{
            .user = .{ .rgb = .{ 17, 34, 51 } },
            .quiet = .{ .rgb = .{ 68, 85, 102 } },
            .attention = .{ .rgb = .{ 119, 136, 153 } },
            .failure = .{ .rgb = .{ 170, 187, 204 } },
        },
        .{
            .user = .{ .index = 61 },
            .quiet = .{ .index = 102 },
            .attention = .{ .index = 143 },
            .failure = .{ .index = 184 },
        },
        .{},
    };
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    for (palettes) |colours| {
        // Independent expectations in the renderer's SGR vocabulary, not
        // the retained slots or the role decoder being tested.
        const codes = [_][]const u8{ "\x1b[94m", "\x1b[90m", "\x1b[33m", "\x1b[91m" };
        const expected = [_]vaxis.Color{ colours.user, colours.quiet, colours.attention, colours.failure };
        for (codes, expected) |code, foreground| for ([_]bool{ true, false }) |colour| {
            // Explicit foregrounds take precedence even in quiet user text
            // and summaries; neither changes the NO_COLOR foreground.
            for ([_][]const u8{ "", "\x1b[2m", "\x1b[2;8m" }) |prefix| {
                var view: Sized(16, true) = .{};
                try view.append(prefix);
                try view.append(code);
                try view.append("x\x1b[0m.");
                var screen: TestScreen = undefined;
                _ = view.draw(screen.window(4, 1), .{}, true, colour, plain, colours);
                try std.testing.expectEqual(if (colour) foreground else plain.fg, screen.screen.readCell(0, 0).?.style.fg);
                try std.testing.expectEqual(plain.fg, screen.screen.readCell(1, 0).?.style.fg);
                for (0..2) |column| try std.testing.expectEqual(plain.bg, screen.screen.readCell(@intCast(column), 0).?.style.bg);
            }
        };
    }
}

test "user text is quiet italic with colour and keeps its body column without it" {
    var view: Sized(128, true) = .{};
    try view.append("\x1b[94m›\x1b[39m \x1b[2mhi \x1b[39mthere\x1b[0m\n  \x1b[2;8m┄ 3 more lines\x1b[0m\nagent \x1b[3mx\x1b[0m");
    const at = struct {
        fn style(v: *const Sized(128, true), needle: []const u8, colour: bool) CellStyle {
            return cellStyle(v.styles[std.mem.indexOf(u8, v.text(), needle).?], colour);
        }
    };
    try std.testing.expectEqual(CellStyle{ .foreground = .user }, at.style(&view, "›", true));
    // A foreground reset never ends user text; only a full reset does.
    for ([_][]const u8{ "hi", "there" }) |word| {
        try std.testing.expectEqual(CellStyle{ .quiet = true, .italic = true }, at.style(&view, word, true));
        try std.testing.expectEqual(CellStyle{}, at.style(&view, word, false));
    }
    try std.testing.expectEqual(CellStyle{ .quiet = true }, at.style(&view, "┄", true));
    try std.testing.expectEqual(CellStyle{}, at.style(&view, "┄", false));
    try std.testing.expectEqual(CellStyle{}, at.style(&view, "agent", true));
    try std.testing.expectEqual(CellStyle{ .italic = true }, at.style(&view, "x", false));
    var test_screen: TestScreen = undefined;
    _ = view.draw(test_screen.window(20, 3), .{}, true, true, .{}, .{ .quiet = .{ .index = 59 } });
    const cell = test_screen.screen.readCell(2, 0).?.style;
    try std.testing.expect(!cell.dim and cell.italic and cell.fg == .index and cell.fg.index == 59);

    // At 12 columns ten leading spaces exceed half the width: agent text
    // falls back to column 0, user text continues at its body column.
    const body = "          abc defgh ijk";
    var storage: [64]u8 = undefined;
    for ([_]bool{ true, false }) |colour| {
        for ([_]bool{ true, false }) |user| {
            var line: Sized(64, true) = .{};
            if (user) try line.append("\x1b[2m");
            try line.append(body);
            const drawn = line.draw(test_screen.window(12, 4), .{}, true, colour, .{}, .{});
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
        const drawn = view.draw(test_screen.window(case.width, 4), .{}, true, true, .{}, .{});
        try std.testing.expectEqual(case.rows.len, drawn.rows);
        try std.testing.expectEqual(case.rows.len, view.measure(.{ .width = case.width, .method = .unicode }, .{}, 99).rows);
        for (case.rows, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    }
    view.sidenotes = true;
    _ = view.draw(test_screen.window(64, 4), .{}, true, true, .{}, .{ .quiet = .{ .index = 59 } });
    const note = test_screen.screen.readCell(59, 0).?.style;
    try std.testing.expect(!note.dim and !note.italic and note.fg == .index and note.fg.index == 59);
    _ = view.draw(test_screen.window(64, 4), .{}, true, false, .{}, .{});
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
        const drawn = view.draw(test_screen.window(case.width, 2), .{}, true, false, .{}, .{});
        try std.testing.expectEqual(@as(u16, 2), drawn.rows);
        try std.testing.expectEqual(@as(u16, 2), view.measure(.{ .width = case.width, .method = .unicode }, .{}, 99).rows);
        for (case.rows, 0..) |text, index| try std.testing.expectEqualStrings(text, test_screen.row(@intCast(index), &storage));
    }
    // Upright: the line is quiet with colour, never italic.
    _ = view.draw(test_screen.window(80, 2), .{}, true, true, .{}, .{ .quiet = .{ .index = 59 } });
    const style = test_screen.screen.readCell(0, 0).?.style;
    try std.testing.expect(!style.dim and !style.italic and style.fg == .index and style.fg.index == 59);
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
    // A click names the clicked row's block, counted from the end; any
    // other row names none.
    const rows = struct {
        fn start(bytes: []const u8, needle: []const u8) usize {
            const at = std.mem.indexOf(u8, bytes, needle).?;
            return if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n')) |newline| newline + 1 else 0;
        }
    };
    try std.testing.expectEqual(@as(?usize, 1), blocks.summaryAt(rows.start(text, "┄ 2")));
    try std.testing.expectEqual(@as(?usize, 0), blocks.summaryAt(rows.start(text, "┄ 3")));
    for ([_][]const u8{ "← Received", "→ Messaged", "┄ typed" }) |other| try std.testing.expectEqual(@as(?usize, null), blocks.summaryAt(rows.start(text, other)));
    try std.testing.expectEqual(@as(?usize, null), blocks.summaryAt(text.len));
}

test "a peer's name links to its Session inside Rui, never through the terminal" {
    const name = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "\x1b[4mReview the WAL" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m";
    var view: Sized(512, true) = .{ .sidenotes = true };
    try view.append("\x1b[2;8m→ Messaged " ++ name ++ "\x1b[8m08:00\x1b[0m\n");
    try view.prepare();
    var test_screen: TestScreen = undefined;
    var storage: [256]u8 = undefined;
    // The hidden ID takes no cell: the row reads, fits and clips as the
    // name alone, with its time in the margin.
    _ = view.draw(test_screen.window(60, 1), .{}, true, true, .{}, .{});
    try std.testing.expectEqualStrings("→ Messaged Review the WAL" ++ @as([55 - 25]u8, @splat(' ')) ++ "08:00", test_screen.row(0, &storage));
    _ = view.draw(test_screen.window(20, 1), .{}, true, true, .{}, .{});
    try std.testing.expectEqualStrings("→ Messaged Review t…", test_screen.row(0, &storage));
    _ = view.draw(test_screen.window(25, 1), .{}, true, true, .{}, .{ .quiet = .{ .index = 59 } });
    try std.testing.expectEqualStrings("→ Messaged Review the WAL", test_screen.row(0, &storage));
    // Only the name is underlined, the row stays quiet, and no cell carries
    // an OSC 8 address.
    for (0..25) |column| {
        const cell = test_screen.screen.readCell(@intCast(column), 0).?;
        try std.testing.expectEqualStrings("", cell.link.uri);
        try std.testing.expectEqual(column >= 11, cell.style.ul_style == .single);
        try std.testing.expectEqual(vaxis.Color{ .index = 59 }, cell.style.fg);
    }
    const text = view.text();
    const at = std.mem.indexOf(u8, text, "Review").?;
    try std.testing.expectEqualStrings("k7m2qx", view.sessionAt(at).?);
    try std.testing.expectEqualStrings("k7m2qx", view.sessionAt(at + "Review the WA".len).?);
    try std.testing.expectEqual(@as(?[]const u8, null), view.sessionAt(at - 1));
    try std.testing.expectEqual(@as(?[]const u8, null), view.sessionAt(at + "Review the WAL".len));
    // An answer's web link still reaches the terminal.
    var answer: Sized(256, true) = .{};
    try answer.append(TerminalText.link_open ++ "https://r.dev" ++ TerminalText.link_end ++ "docs" ++ TerminalText.link_close);
    try expectLinks(&answer, .{}, 8, &.{ "https://r.dev", "https://r.dev", "https://r.dev", "https://r.dev", "-" });
    try std.testing.expectEqual(@as(?[]const u8, null), answer.sessionAt(0));
}

test "shown text joins wrapped rows and leaves out margin times and link addresses" {
    const name = TerminalText.link_open ++ TerminalText.session_link ++ "k7m2qx" ++ TerminalText.link_end ++ "\x1b[4mPlan" ++ TerminalText.link_close ++ "\x1b[0m\x1b[2;8m";
    var view: Sized(512, true) = .{ .sidenotes = true };
    try view.append("› \x1b[2mfix\tthe flaky store test please\x1b[8m14:20\x1b[0m\n\x1b[2;8m← Received message from " ++ name ++ "\x1b[8m08:00\x1b[0m\nlast");
    try view.prepare();
    // Laid out at 16 columns the first line wraps; its bytes don't.
    try std.testing.expect(view.lineRows(.{ .width = 16, .method = .unicode }, 0) > 1);
    const text = view.text();
    const copied = (try view.shownText(std.testing.allocator, 0, text.len, 1000)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("› fix the flaky store test please\n← Received message from Plan\nlast", copied);
    // From inside a line to inside a later one.
    const from = std.mem.indexOf(u8, text, "store").?;
    const to = std.mem.indexOf(u8, text, "ast").?;
    const part = (try view.shownText(std.testing.allocator, from, to, 1000)).?;
    defer std.testing.allocator.free(part);
    try std.testing.expectEqualStrings("store test please\n← Received message from Plan\nl", part);
    // The limit counts copied bytes, not hidden ones.
    const exact = (try view.shownText(std.testing.allocator, from, to, part.len)).?;
    std.testing.allocator.free(exact);
    try std.testing.expectEqual(@as(?[]u8, null), try view.shownText(std.testing.allocator, from, to, part.len - 1));
    try std.testing.expect(!view.selectable(std.mem.indexOf(u8, text, "14:20").?));
    try std.testing.expect(view.selectable(from));
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
        _ = view.draw(window, .{}, true, false, .{}, .{});
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
    try std.testing.expect(cellStyle(view.styles[0], true).foreground == .quiet);
    try std.testing.expect(cellStyle(view.styles[6], true).foreground == null);
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

/// Each drawn cell's link address in one row, `-` for a cell with none.
fn expectLinks(view: anytype, from: Position, width: u16, expected: []const []const u8) !void {
    var test_screen: TestScreen = undefined;
    _ = view.draw(test_screen.window(width, 1), from, true, true, .{}, .{});
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
        _ = view.draw(test_screen.window(20, 1), .{}, true, true, .{}, .{});
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
    try std.testing.expect(!try view.prepend(&older, .{ .width = 16, .method = .unicode }, 2));
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
        _ = view.draw(screen.window(80, 1), .{}, true, true, .{}, .{});
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

test "code bands cover blank and wrapped rows at every width and append split without retained metadata" {
    // SGR 40 is a real terminal background and the viewport's code role.
    // The newline itself carries it: a completely empty code line still
    // has a style byte, but no added text byte or per-line allocation.
    const input = "before\n\x1b[40mabcdefghijkl\n\x1b[0m\x1b[40m\n\x1b[0m\x1b[40mz\n\x1b[0mafter\n";
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    const colours: Colours = .{ .band = .{ .rgb = .{ 28, 29, 35 } } };
    for (0..input.len + 1) |split| {
        var view: Sized(64, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try view.prepare();
        try std.testing.expectEqualStrings("before\nabcdefghijkl\n\nz\nafter\n", view.text());
        try std.testing.expectEqual(@sizeOf(@TypeOf(view.bytes)), @sizeOf(@TypeOf(view.styles)));
        for (1..17) |width_value| {
            const width: u16 = @intCast(width_value);
            const wrapped: u16 = @intCast((12 + width_value - 1) / width_value);
            for ([_]bool{ false, true }) |colour| {
                // Start on every continuation row, including a negative
                // logical row origin: the band must stop before prose.
                for (0..wrapped) |skip| {
                    var screen: TestScreen = undefined;
                    const window = screen.window(width, 12);
                    window.fill(.{ .style = plain });
                    _ = view.draw(window, .{ .offset = 7, .row = @intCast(skip) }, true, colour, plain, colours);
                    const band_rows = wrapped - skip + 2;
                    for (0..12) |row| for (0..width) |column| {
                        const cell = screen.screen.readCell(@intCast(column), @intCast(row)).?;
                        try std.testing.expectEqual(if (colour and row < band_rows) colours.band else plain.bg, cell.style.bg);
                        if (view.cellOffset(cell) != null) {
                            try std.testing.expectEqual(plain.fg, cell.style.fg);
                            try std.testing.expect(cell.style.ul_style == .off);
                        }
                    };
                }
            }
        }
    }
    // Evict into a code line, then prepend it to another page: the retained
    // style alone still carries the band, with no line-marker repair pass.
    var old: Sized(32, true) = .{};
    try old.append("\x1b[40m0123456789012345678901234567890123456789\n\x1b[0m");
    try old.prepare();
    try std.testing.expect(old.origin != 0);
    var newer: Sized(32, true) = .{};
    try newer.append("after\n");
    _ = try newer.prepend(&old, .{ .width = 16, .method = .unicode }, 4);
    var screen: TestScreen = undefined;
    _ = newer.draw(screen.window(16, 4), .{}, true, true, plain, colours);
    try std.testing.expectEqual(colours.band, screen.screen.readCell(15, 0).?.style.bg);
}

test "rendered table headers restore quiet around inline styles and only linked text underlines" {
    const input = "| **Head** `code` *em* [link](https://x.dev) tail | N |\n| --- | --- |\n| plain | z |\n";
    for ([_]bool{ false, true }) |colour| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: @import("AnswerRenderer.zig") = .{ .out = &output.writer, .colour = colour };
        for (input) |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        var view: Sized(512, true) = .{};
        for (output.written()) |byte| try view.append(&.{byte});
        try view.prepare();
        const words = [_][]const u8{ "Head", "code", "em", "link", "tail", "plain" };
        for (words, 0..) |word, index| {
            const at = std.mem.indexOf(u8, view.text(), word).?;
            const value = cellStyle(view.styles[at], colour);
            try std.testing.expectEqual(index == 0, value.bold);
            try std.testing.expectEqual(index == 2, value.italic);
            try std.testing.expectEqual(index == 3, value.underline);
            const expected: @TypeOf(value.foreground) = if (!colour or index == 5) null else if (index == 1) .user else .quiet;
            try std.testing.expectEqual(expected, value.foreground);
        }
        const shown = (try view.shownText(std.testing.allocator, 0, view.length, 512)).?;
        defer std.testing.allocator.free(shown);
        try std.testing.expectEqualStrings("  Head code em link tail  N\n  plain                   z\n", shown);
    }
}

test "rendered fences carry blank and wrapped bands through the real renderer viewport boundary" {
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    const colours: Colours = .{ .band = .{ .index = 61 } };
    for ([_]bool{ false, true }) |colour| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: @import("AnswerRenderer.zig") = .{ .out = &output.writer, .colour = colour, .destination = .{ .viewport = .wcwidth } };
        for ("```zig\nabcdefghijkl\n\nz\n```\nafter\n") |byte| try renderer.feed(&.{byte});
        try renderer.finish();
        var view: Sized(128, true) = .{};
        for (output.written()) |byte| try view.append(&.{byte});
        try view.prepare();
        try std.testing.expectEqualStrings(if (colour) "abcdefghijkl\n\nz\nafter\n" else "  abcdefghijkl\n  \n  z\nafter\n", view.text());
        for (1..17) |width_value| {
            var screen: TestScreen = undefined;
            const window = screen.window(@intCast(width_value), 12);
            window.fill(.{ .style = plain });
            _ = view.draw(window, .{}, true, colour, plain, colours);
            const band_rows = (12 + width_value - 1) / width_value + 2;
            for (0..12) |row| for (0..width_value) |column| {
                const cell = screen.screen.readCell(@intCast(column), @intCast(row)).?;
                try std.testing.expectEqual(if (colour and row < band_rows) colours.band else plain.bg, cell.style.bg);
            };
        }
    }
}

test "one link keeps its address across plain quiet and ink labels without storing another style byte" {
    const uri = "https://x.dev/a";
    const input = "!" ++ TerminalText.link_open ++ uri ++ TerminalText.link_end ++ "\x1b[4mp\x1b[90mq\x1b[94mc\x1b[0mn" ++ TerminalText.link_close ++ ".";
    for (0..input.len + 1) |split| {
        var view: Sized(128, true) = .{};
        try view.append(input[0..split]);
        try view.append(input[split..]);
        try view.prepare();
        try expectLinks(&view, .{}, 8, &.{ "-", uri, uri, uri, uri, "-" });
        const text = std.mem.indexOf(u8, view.text(), "pqcn").?;
        try std.testing.expect(cellStyle(view.styles[text + 1], true).foreground == .quiet);
        try std.testing.expect(cellStyle(view.styles[text + 2], true).foreground == .user);
        // Losing any part of the retained address makes every style of
        // its label unlinked, rather than pointing to a truncated target.
        view.discardFront(3);
        try expectLinks(&view, .{}, 8, &.{ "-", "-", "-", "-", "-" });
    }
}

test "wrapped code keeps its own indent across widths clipping and scripts without line metadata" {
    const Renderer = @import("AnswerRenderer.zig");
    const content = "abcdefghijkl";
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    const colours: Colours = .{ .band = .{ .rgb = .{ 28, 29, 35 } } };
    for ([_][]const u8{ "", " ", "    ", "\t\t", "                                " }) |prefix| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var renderer: Renderer = .{ .out = &output.writer, .destination = .{ .viewport = .unicode } };
        try renderer.feed("```\n");
        try renderer.feed(prefix);
        try renderer.feed(content ++ "\n\n```\nafter\n");
        try renderer.finish();
        for (0..output.written().len + 1) |split| {
            var view: Sized(256, true) = .{};
            try view.append(output.written()[0..split]);
            try view.append(output.written()[split..]);
            try view.prepare();
            try std.testing.expectEqual(@sizeOf(@TypeOf(view.bytes)), @sizeOf(@TypeOf(view.styles)));
            for (1..21) |width_value| {
                const width: u16 = @intCast(width_value);
                const indent = @min(if (std.mem.indexOfScalar(u8, prefix, '\t') != null) prefix.len * 8 else prefix.len, width - 1);
                const body_width = width - indent;
                const wrapped = (content.len + body_width - 1) / body_width;
                for ([_]bool{ false, true }) |colour| for (0..wrapped) |skip| {
                    var screen: TestScreen = undefined;
                    const window = screen.window(width, 14);
                    window.fill(.{ .style = plain });
                    const drawn = view.draw(window, .{ .row = @intCast(skip) }, true, colour, plain, colours);
                    const measured = view.measure(.{ .width = width, .method = .unicode }, .{ .row = @intCast(skip) }, 14);
                    try std.testing.expectEqual(measured.rows, drawn.rows);
                    for (0..wrapped - skip) |row| {
                        for (0..indent) |col| try std.testing.expectEqualStrings(" ", screen.screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
                        const from = (row + skip) * body_width;
                        for (0..@min(body_width, content.len - from)) |col| {
                            try std.testing.expectEqualStrings(content[from + col ..][0..1], screen.screen.readCell(@intCast(col + indent), @intCast(row)).?.char.grapheme);
                        }
                    }
                    for (0..wrapped - skip + 1) |row| for (0..width) |col| {
                        try std.testing.expectEqual(if (colour) colours.band else plain.bg, screen.screen.readCell(@intCast(col), @intCast(row)).?.style.bg);
                    };
                    try std.testing.expectEqual(plain.bg, screen.screen.readCell(0, @intCast(wrapped - skip + 1)).?.style.bg);
                };
            }
        }
    }
}

test "one line band owner covers adjacent code, selected tool, output and plain rows" {
    const Sink = struct {
        bytes: [1024]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var input: Sink = .{};
    try input.feed("before\n\x1b[40m  abcdefghijkl\n\x1b[0m\x1b[40m\n\x1b[0m");
    try input.feed(tool_fold.heading_marker ++ "✓ A\n" ++ tool_fold.output_marker ++ "    out\n" ++ tool_fold.output_marker ++ "    err\n" ++ tool_fold.more_marker ++ "    … 2 more lines\n");
    try input.feed(tool_fold.heading_marker ++ "✓ B\nafter\n");
    const plain: vaxis.Style = .{ .fg = .{ .index = 255 }, .bg = .{ .index = 19 } };
    const colours: Colours = .{ .band = .{ .index = 61 }, .selection = .{ .index = 62 }, .quiet = .{ .index = 63 } };
    for (0..input.length + 1) |split| {
        var view: Sized(1024, true) = .{};
        try view.append(input.bytes[0..split]);
        try view.append(input.bytes[split..input.length]);
        try view.prepare();
        for (8..18) |width_value| {
            const width: u16 = @intCast(width_value);
            const code_rows = (12 + width_value - 3) / (width_value - 2);
            const selected = 2 + code_rows;
            const plain_start = selected + 4;
            for ([_]bool{ false, true }) |colour| {
                var screen: TestScreen = undefined;
                const window = screen.window(width, 14);
                window.fill(.{ .style = plain });
                _ = view.draw(window, .{}, true, colour, plain, colours);
                for (0..14) |row| for (0..width) |column| {
                    const cell = screen.screen.readCell(@intCast(column), @intCast(row)).?;
                    const band = row > 0 and row < plain_start;
                    const expected = if (!colour or !band) plain.bg else if (row == selected) colours.selection else colours.band;
                    try std.testing.expectEqual(expected, cell.style.bg);
                    if (view.cellOffset(cell) != null) {
                        const quiet = colour and (row > selected and row <= selected + 3);
                        try std.testing.expectEqual(if (quiet) colours.quiet else plain.fg, cell.style.fg);
                    }
                };
                // Neither open nor closed headings gain a second mark or indent.
                try std.testing.expectEqualStrings("✓", screen.screen.readCell(0, @intCast(selected)).?.char.grapheme);
                try std.testing.expectEqualStrings("✓", screen.screen.readCell(0, @intCast(plain_start)).?.char.grapheme);
            }
        }
    }
}

test "Document rows answer down within measure for every row from every first row" {
    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{ .sidenotes = true };
    try document.append("› a long user line that wraps \x1b[8m14:20\x1b[0m\n\n" ++ tool_fold.heading_marker ++ "$ Bash done\n  wide 漢字漢字漢字 cells wrap\n\x1b[2;8m┄ 9 more lines\x1b[0m\nlast");
    try document.prepare();
    for ([_]u16{ 1, 3, 7, 16, 80 }) |width| {
        const layout: Layout = .{ .width = width, .method = .unicode };
        const total = document.measure(layout, .{}, std.math.maxInt(u16)).rows;
        var from: ?Position = .{};
        while (from) |start| : (from = if (document.measure(layout, start, 2).rows == 2) document.down(layout, start, 1) else null) {
            var rows = document.rowsFrom(layout, start);
            for (0..total + 2) |row| {
                const expected = if (document.measure(layout, start, @intCast(row + 1)).rows > row) document.down(layout, start, row) else null;
                try std.testing.expectEqual(expected, rows.next());
            }
        }
    }
    // A tall document from its top, and an empty one.
    const tall = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(tall);
    tall.* = .{};
    for (0..300) |line| try tall.append(if (line % 4 == 0) "words that wrap at five\n" else "x\n");
    try tall.prepare();
    const narrow: Layout = .{ .width = 5, .method = .unicode };
    const total = tall.measure(narrow, .{}, std.math.maxInt(u16)).rows;
    // 75 five-row lines and 225 one-row lines.
    try std.testing.expectEqual(@as(usize, 600), total);
    var rows = tall.rowsFrom(narrow, .{});
    for (0..total) |row| try std.testing.expectEqual(tall.down(narrow, .{}, row), rows.next().?);
    try std.testing.expectEqual(@as(?Position, null), rows.next());
    tall.* = .{};
    var none = tall.rowsFrom(narrow, .{});
    try std.testing.expectEqual(@as(?Position, null), none.next());
}
