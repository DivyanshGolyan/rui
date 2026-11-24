const std = @import("std");
const vaxis = @import("vaxis");
const viewport = @import("ConversationViewport.zig");
const TerminalText = @import("TerminalText.zig");
const Document = viewport.Document;

pub const Spot = struct {
    start: u64,
    end: u64,

    pub fn point(at: u64) Spot {
        return .{ .start = at, .end = at };
    }
};

pub const Range = struct {
    from: u64,
    to: u64,

    pub fn of(anchor: Spot, head: Spot) Range {
        return .{ .from = @min(anchor.start, head.start), .to = @max(anchor.end, head.end) };
    }

    fn covers(self: Range, spot: Spot) bool {
        return if (spot.start == spot.end) self.from < spot.start and spot.start < self.to else spot.start < self.to and spot.end > self.from;
    }
};

pub const Row = RowFor(Document);

// Selection composes with an existing reverse-video band in either theme.
pub fn highlight(cells: []vaxis.Cell, columns: []const bool) void {
    std.debug.assert(cells.len == columns.len);
    for (cells, columns) |*cell, selected| if (selected) {
        cell.style.reverse = !cell.style.reverse;
    };
}

pub fn RowFor(comptime Doc: type) type {
    return struct {
        const Self = @This();
        document: *const Doc,
        cells: []const vaxis.Cell,
        line: ?usize,

        pub fn spot(self: Self, col: i32) Spot {
            const end = self.document.origin + self.document.text().len;
            if (self.line == null) return Spot.point(end);
            var spots: Spots = .init(self);
            var column: i32 = 0;
            var found: Spot = Spot.point(spots.boundary);
            while (spots.next()) |value| : (column += 1) {
                found = value.spot;
                if (column >= col) return found;
            }
            return Spot.point(found.end);
        }

        pub fn covered(self: Self, range: Range, columns: []bool) void {
            var spots: Spots = .init(self);
            for (columns) |*column| {
                const hit = spots.next().?;
                column.* = hit.paint and range.covers(hit.spot);
            }
        }

        const Hit = struct { spot: Spot, paint: bool = true };

        const Spots = struct {
            row: Self,
            boundary: u64,
            covered: usize = 0,
            cover: Hit = undefined,
            column: usize = 0,
            decorated_prefix: usize = 0,

            fn init(row: Self) Spots {
                const document = row.document;
                var result: Spots = .{
                    .row = row,
                    .boundary = document.origin + (row.line orelse document.text().len),
                };
                for (row.cells, 0..) |cell, column| {
                    const offset = document.cellOffset(cell) orelse continue;
                    if (document.inlineDecoration(offset)) {
                        result.decorated_prefix = column;
                        break;
                    }
                }
                for (row.cells) |cell| {
                    const offset = document.cellOffset(cell) orelse continue;
                    if (document.selectable(offset)) {
                        result.boundary = document.origin + offset;
                        break;
                    }
                }
                return result;
            }

            fn next(self: *Spots) ?Hit {
                if (self.column == self.row.cells.len) return null;
                defer self.column += 1;
                const cell = self.row.cells[self.column];
                const document = self.row.document;
                if (document.cellOffset(cell)) |offset| {
                    self.covered = self.column + @max(cell.char.width, 1);
                    if (document.selectable(offset)) {
                        const at = document.origin + offset;
                        self.cover = .{ .spot = .{ .start = at, .end = at + cell.char.grapheme.len } };
                        self.boundary = self.cover.spot.end;
                    } else {
                        const boundary = if (document.inlineDecoration(offset)) document.origin + offset else self.boundary;
                        self.cover = .{ .spot = Spot.point(boundary), .paint = false };
                    }
                    return self.cover;
                }
                if (self.column < self.covered) return self.cover;
                return .{ .spot = Spot.point(self.boundary), .paint = self.column >= self.decorated_prefix };
            }
        };
    };
}

pub fn relative(document: anytype, at: u64) ?usize {
    if (at < document.origin) return null;
    const offset = at - document.origin;
    return if (offset <= document.text().len) @intCast(offset) else null;
}

fn retained(document: anytype, at: u64) usize {
    if (at <= document.origin) return 0;
    return @intCast(@min(at - document.origin, document.text().len));
}

pub fn opens(document: anytype, spot: Spot) ?[]const u8 {
    if (spot.start == spot.end) return null;
    return document.sessionAt(relative(document, spot.start) orelse return null);
}

pub const PeerSpan = struct { start: u16, end: u16 };
pub fn peers(document: anytype, cells: []const vaxis.Cell, arena: std.mem.Allocator) ![]const PeerSpan {
    var spans: std.ArrayList(PeerSpan) = .empty;
    var col: usize = 0;
    while (col < cells.len) {
        const id = peerAt(document, cells[col]) orelse {
            col += 1;
            continue;
        };
        const start = col;
        col = @min(cells.len, col + @max(cells[col].char.width, 1));
        while (col < cells.len) {
            const next = peerAt(document, cells[col]) orelse break;
            if (!std.mem.eql(u8, id, next)) break;
            col = @min(cells.len, col + @max(cells[col].char.width, 1));
        }
        try spans.append(arena, .{ .start = @intCast(start), .end = @intCast(col) });
    }
    return spans.items;
}

fn peerAt(document: anytype, cell: vaxis.Cell) ?[]const u8 {
    return document.sessionAt(document.cellOffset(cell) orelse return null);
}

pub const Copy = union(enum) {
    nothing,
    too_large,
    text: struct { bytes: []u8, lines: usize },
};

pub fn copy(gpa: std.mem.Allocator, document: anytype, range: Range) !Copy {
    return extract(gpa, document, range, null);
}

pub fn copyBody(gpa: std.mem.Allocator, window: anytype, range: Range) !Copy {
    return extract(gpa, &window.document, range, @import("feed_window.zig").Window.QuoteFilter{ .window = window });
}

fn extract(gpa: std.mem.Allocator, document: anytype, range: Range, filter: anytype) !Copy {
    const from = retained(document, range.from);
    const to = retained(document, range.to);
    if (from >= to) return .nothing;
    const bytes = (if (@TypeOf(filter) == @TypeOf(null)) try document.shownText(gpa, from, to, TerminalText.clipboard_limit) else try document.shownTextWhere(gpa, from, to, TerminalText.clipboard_limit, filter)) orelse return .too_large;
    if (bytes.len == 0) {
        gpa.free(bytes);
        return .nothing;
    }
    var lines: usize = 1 + std.mem.count(u8, bytes, "\n");
    if (bytes[bytes.len - 1] == '\n') lines -= 1;
    return .{ .text = .{ .bytes = bytes, .lines = lines } };
}

pub fn notice(result: Copy, buffer: *[64]u8) ?[]const u8 {
    return switch (result) {
        .nothing => null,
        .too_large => TerminalText.clipboard_too_large,
        .text => |text| std.fmt.bufPrint(buffer, "Copied {d} line{s}", .{ text.lines, if (text.lines == 1) "" else "s" }) catch unreachable,
    };
}

fn layOut(document: anytype, first: viewport.Position, width: u16, count: u16, cells: []vaxis.Cell) void {
    @memset(cells, .{});
    var screen: vaxis.Screen = .{ .width = width, .height = count, .width_method = .unicode, .buf = cells };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = count, .screen = &screen };
    _ = document.draw(window, first, true, false, .{}, .{});
}

fn rowColumnsMap() !void {
    const document = try std.testing.allocator.create(Document);
    defer std.testing.allocator.destroy(document);
    document.* = .{};
    try document.append("◝ 雪 fall fast\n\nend");
    try document.prepare();
    var cells: [10 * 4]vaxis.Cell = undefined;
    layOut(document, .{}, 10, 4, &cells);
    const text = document.text();
    const snow = std.mem.indexOf(u8, text, "雪").?;
    const fast = std.mem.indexOf(u8, text, "fast").?;
    const first: Row = .{ .document = document, .cells = cells[0..10], .line = 0 };
    try std.testing.expectEqual(Spot{ .start = snow, .end = snow + "雪".len }, first.spot(2));
    try std.testing.expectEqual(Spot{ .start = snow, .end = snow + "雪".len }, first.spot(3));
    try std.testing.expectEqual(Spot.point(fast - 1), first.spot(20));
    const wrapped: Row = .{ .document = document, .cells = cells[10..20], .line = 0 };
    try std.testing.expectEqual(Spot.point(fast), wrapped.spot(0));
    try std.testing.expectEqual(Spot{ .start = fast, .end = fast + 1 }, wrapped.spot(2));
    const empty: Row = .{ .document = document, .cells = cells[20..30], .line = fast + "fast\n".len };
    try std.testing.expectEqual(Spot.point(fast + "fast\n".len), empty.spot(4));
    const below: Row = .{ .document = document, .cells = cells[30..40], .line = null };
    try std.testing.expectEqual(Spot.point(text.len), below.spot(0));
    var columns: [10]bool = undefined;
    const range = Range.of(first.spot(2), wrapped.spot(2));
    first.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, true, true, true, true, true, true, true }, &columns);
    wrapped.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, false, false, false, false, false, false }, &columns);
    empty.covered(range, &columns);
    try std.testing.expectEqualSlices(bool, &@as([10]bool, @splat(false)), &columns);
}

test "SUI-145 transcript projection leaves generated gutters and preserves authored blank rows" {
    try rowColumnsMap();
    const testing = std.testing;
    const DocumentType = viewport.Sized(256, true);
    var document: DocumentType = .{};
    const marker = TerminalText.decoration_on ++ "› " ++ TerminalText.decoration_off;
    try document.append(TerminalText.user_message_on ++ marker ++ "UserAlpha\n\nAnswerBeta" ++ TerminalText.user_message_off);
    try document.prepare();
    const SelectionRow = RowFor(@TypeOf(document));
    const width: u16 = 46;
    const height: u16 = 8;
    const layout: viewport.Layout = .{ .width = width, .method = .unicode };
    var cells: [46 * 8]vaxis.Cell = @splat(.{});
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = &cells };
    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    _ = document.draw(window, .{}, true, false, .{}, .{});
    const blank_line = document.lineEnd(0) + 1;
    var rows = document.rowsFrom(layout, .{});
    const all: Range = .{ .from = document.origin, .to = document.origin + document.text().len };
    var saw_marker = false;
    var saw_blank = false;
    var columns: [46]bool = undefined;
    for (0..height) |row_index| {
        const position = rows.next() orelse break;
        const row_cells = cells[row_index * width ..][0..width];
        const row: SelectionRow = .{ .document = &document, .cells = row_cells, .line = document.selectionLine(layout, position) };
        row.covered(all, &columns);
        if (position.offset == 0 and std.mem.indexOf(u8, document.text(), "UserAlpha") != null) {
            var marker_column: ?usize = null;
            for (row_cells, 0..) |cell, column| if (std.mem.eql(u8, cell.char.grapheme, "›")) {
                marker_column = column;
                break;
            };
            if (marker_column) |column| {
                saw_marker = true;
                try testing.expect(column >= 2);
                const marker_at = document.cellOffset(row_cells[column]) orelse return error.MissingMarkerOffset;
                const space_at = document.cellOffset(row_cells[column + 1]) orelse return error.MissingMarkerSpaceOffset;
                try testing.expect(document.inlineDecoration(marker_at));
                try testing.expect(!document.selectable(marker_at));
                try testing.expect(document.inlineDecoration(space_at));
                try testing.expect(!document.selectable(space_at));
                const decorated_space = row.spot(@intCast(column + 1));
                try testing.expectEqual(Spot.point(document.origin + space_at), decorated_space);
                try testing.expect(all.covers(decorated_space));
                try testing.expect(!columns[column + 1]);
                for (columns[0 .. column + 2]) |selected| try testing.expect(!selected);
            }
        }
        if (position.offset == blank_line) {
            saw_blank = true;
            const blank_boundary = row.spot(0);
            try testing.expectEqual(Spot.point(document.origin + blank_line), blank_boundary);
            try testing.expect(all.covers(blank_boundary));
            try testing.expect(columns[0]);
        }
    }
    try testing.expect(saw_marker and saw_blank);
    const range: Range = .{ .from = 4, .to = 9 };
    try testing.expect(!range.covers(Spot.point(4)));
    try testing.expect(range.covers(Spot.point(5)));
    try testing.expect(range.covers(Spot.point(8)));
    try testing.expect(!range.covers(Spot.point(9)));
    try testing.expect(range.covers(.{ .start = 3, .end = 5 }));
    try testing.expect(range.covers(.{ .start = 8, .end = 10 }));
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
    document.discardFront(8);
    try std.testing.expectEqual(Copy.nothing, try copy(gpa, document, .{ .from = 0, .to = 4 }));
    const across = try copy(gpa, document, .{ .from = 2, .to = 10 });
    defer gpa.free(across.text.bytes);
    try std.testing.expectEqualStrings("th", across.text.bytes);
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
    try std.testing.expectEqual(@as(?[]const u8, null), opens(document, Spot.point(at)));
    try std.testing.expectEqual(@as(?[]const u8, null), opens(document, .{ .start = at - 1, .end = at }));
}

test "copying code across wrapped and blank band rows contains only code text" {
    const gpa = std.testing.allocator;
    const document = try gpa.create(Document);
    defer gpa.destroy(document);
    document.* = .{};
    const text = "abcdefghijkl\n\nz\n";
    const stream = "\x1b[40mabcdefghijkl\n\x1b[0m\x1b[40m\n\x1b[0m\x1b[40mz\n\x1b[0m";
    for (stream) |byte| try document.append(&.{byte});
    try document.prepare();
    try std.testing.expectEqualStrings(text, document.text());
    for (1..17) |width_value| {
        const width: u16 = @intCast(width_value);
        const rows: usize = (12 + width_value - 1) / width_value + 2;
        const cells = try gpa.alloc(vaxis.Cell, width_value * rows);
        defer gpa.free(cells);
        layOut(document, .{}, width, @intCast(rows), cells);
        const first: Row = .{ .document = document, .cells = cells[0..width], .line = 0 };
        const last: Row = .{ .document = document, .cells = cells[(rows - 1) * width ..], .line = text.len - 2 };
        const result = try copy(gpa, document, Range.of(first.spot(0), last.spot(0)));
        defer gpa.free(result.text.bytes);
        try std.testing.expectEqualStrings("abcdefghijkl\n\nz", result.text.bytes);
        try std.testing.expectEqual(@as(usize, 3), result.text.lines);
        const whole = try copy(gpa, document, .{ .from = 0, .to = document.text().len });
        defer gpa.free(whole.text.bytes);
        try std.testing.expectEqualStrings(text, whole.text.bytes);
    }
}

test "selection contrasts with sent bands and padding at both widths" {
    const testing = std.testing;
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |colour| for ([_]bool{ false, true }) |wrapped| {
        var document: viewport.Sized(1024, true) = .{ .sidenotes = true };
        try document.append(TerminalText.user_message_on ++ "› ");
        const count: usize = if (!wrapped) 5 else if (width == 46) 75 else 265;
        for (0..count) |_| try document.append("x");
        try document.append("\n" ++ TerminalText.user_message_off);
        try document.prepare();
        const layout: viewport.Layout = .{ .width = width, .method = .unicode };
        const height = document.lineRows(layout, 0);
        try testing.expectEqual(@as(u16, if (!wrapped) 3 else if (width == 46) 5 else 6), height);
        var cells: [140 * 6]vaxis.Cell = @splat(.{});
        var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = cells[0 .. @as(usize, width) * height] };
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        const colours: viewport.Colours = .{ .user_band = .{ .index = 2 }, .no_depth = !colour };
        _ = document.draw(window, .{}, true, true, .{}, colours);
        var positions = document.rowsFrom(layout, .{});
        const all: Range = .{ .from = document.origin, .to = document.origin + document.text().len };
        var columns: [140]bool = undefined;
        for (0..height) |row_index| {
            const position = positions.next().?;
            const row_cells = cells[row_index * width ..][0..width];
            const row: RowFor(@TypeOf(document)) = .{ .document = &document, .cells = row_cells, .line = document.selectionLine(layout, position) };
            row.covered(all, columns[0..width]);
            const old = row_cells[0].style.reverse;
            try testing.expectEqual(!colour, old);
            if (position.row == 0) {
                try testing.expectEqual(@as(?usize, null), document.cellOffset(row_cells[0]));
                try testing.expectEqual(@as(?usize, null), document.cellOffset(row_cells[4]));
                const cap_point = row.spot(0);
                try testing.expectEqual(Spot.point(document.origin), cap_point);
                try testing.expect(!all.covers(cap_point));
                try testing.expect(!columns[0] and !columns[4]);
            } else if (position.row == 1) {
                try testing.expectEqual(@as(?usize, null), document.cellOffset(row_cells[0]));
                const first_body_cell = document.cellOffset(row_cells[4]) orelse return error.MissingFirstBodyCell;
                try testing.expectEqual(@as(usize, "› ".len), first_body_cell);
                try testing.expect(document.selectable(first_body_cell));
                const inset_point = row.spot(0);
                try testing.expectEqual(Spot.point(document.origin), inset_point);
                try testing.expect(!all.covers(inset_point));
                try testing.expect(all.covers(row.spot(4)));
                try testing.expect(!columns[0] and columns[4]);
            } else {
                const interior_point = row.spot(0);
                try testing.expect(interior_point.start > all.from and interior_point.start < all.to);
                try testing.expect(all.covers(interior_point));
                try testing.expect(columns[0] and columns[4]);
            }
            var reverse_before: [140]bool = undefined;
            for (row_cells, 0..) |cell, column| reverse_before[column] = cell.style.reverse;
            columns[1] = false;
            highlight(row_cells, columns[0..width]);
            for (row_cells, 0..) |cell, column| {
                const expected = if (columns[column]) !reverse_before[column] else reverse_before[column];
                try testing.expectEqual(expected, cell.style.reverse);
            }
        }
    };
}

fn testBandCopy() !void {
    const testing = std.testing;
    for ([_]u16{ 46, 140 }) |width| for ([_]u8{ 0, 1, 2 }) |depth| for ([_]bool{ false, true }) |unicode_caps| {
        const method: vaxis.gwidth.Method = if (unicode_caps) .unicode else .wcwidth;
        var document: viewport.Sized(1024, true) = .{ .sidenotes = true, .width_method = method };
        const marker = TerminalText.decoration_on ++ "› " ++ TerminalText.decoration_off;
        try document.append(TerminalText.user_message_on ++ marker ++ "\x1b[8m14:20\x1b[0mshort\n" ++ TerminalText.user_message_off ++
            TerminalText.user_message_on ++ marker);
        const count: usize = if (width == 46) 75 else 265;
        for (0..count) |_| try document.append("x");
        try document.append("\n" ++ TerminalText.user_message_off);
        try document.prepare();
        const layout: viewport.Layout = .{ .width = width, .method = method };
        var cells: [140 * 12]vaxis.Cell = @splat(.{});
        var screen: vaxis.Screen = .{ .width = width, .height = 12, .width_method = method, .buf = cells[0 .. @as(usize, width) * 12] };
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 12, .screen = &screen };
        const band: vaxis.Color = if (depth == 1) .{ .index = 8 } else .{ .rgb = .{ 10, 20, 30 } };
        const ground: vaxis.Style = .{ .bg = .{ .index = 1 } };
        window.fill(.{ .style = ground });
        _ = document.draw(window, .{}, true, true, ground, .{ .user_band = band, .no_depth = depth == 0 });
        const content_row: RowFor(@TypeOf(document)) = .{ .document = &document, .cells = cells[width..][0..width], .line = 0 };
        const cap_row: RowFor(@TypeOf(document)) = .{ .document = &document, .cells = cells[2 * @as(usize, width) ..][0..width], .line = document.selectionLine(layout, .{ .row = 2 }) };
        var covered: [140]bool = undefined;
        content_row.covered(.{ .from = 0, .to = document.text().len }, covered[0..width]);
        try testing.expectEqualSlices(bool, &.{ false, false, true }, covered[2..5]);
        try testing.expectEqualSlices(bool, &@as([5]bool, @splat(false)), covered[width - 7 .. width - 2]);
        const result = try copy(testing.allocator, &document, .of(content_row.spot(2), cap_row.spot(width)));
        try testing.expect(result == .text);
        defer testing.allocator.free(result.text.bytes);
        try testing.expectEqualStrings("short", result.text.bytes);

        const whole = try copy(testing.allocator, &document, .{ .from = 0, .to = document.text().len });
        defer testing.allocator.free(whole.text.bytes);
        const expected = if (width == 46) "short\n" ++ @as([75]u8, @splat('x')) ++ "\n" else "short\n" ++ @as([265]u8, @splat('x')) ++ "\n";
        try testing.expectEqualStrings(expected, whole.text.bytes);
    };
}

test "SUI-34 user message bands retain padded rows and selectable source text" {
    try viewport.testBandPadding();
    try testBandCopy();
}
