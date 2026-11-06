//! Independent layout contracts against configureVaxis's exact patched module.
//! Fixed stack grids; no TTY, filesystem, network or input-sized allocation.
const std = @import("std");
const vaxis = @import("vaxis");
const unicode = @import("terminal_unicode");
const testing = std.testing;
const saturated_word: [65535]u8 = @splat('a');

fn print(segments: []const vaxis.Segment, width: u16, height: u16, opts: vaxis.PrintOptions, cells: *[128]vaxis.Cell) vaxis.Window.PrintResult {
    var screen: vaxis.Screen = .{
        .width = width,
        .height = height,
        .width_method = .unicode,
        .buf = cells[0 .. @as(usize, width) * height],
    };
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };
    return win.print(segments, opts);
}

fn paintAndMeasure(segments: []const vaxis.Segment, width: u16, height: u16, options: vaxis.PrintOptions, cells: *[128]vaxis.Cell) !vaxis.Window.PrintResult {
    @memset(cells, .{});
    var opts = options;
    opts.commit = true;
    const painted = print(segments, width, height, opts, cells);
    var untouched: [128]vaxis.Cell = @splat(.{ .char = .{ .grapheme = "?", .width = 1 } });
    opts.commit = false;
    const measured = print(segments, width, height, opts, &untouched);
    try testing.expectEqualDeep(painted, measured);
    for (untouched) |cell| try testing.expectEqualStrings("?", cell.char.grapheme);
    return painted;
}

test "layout: a continued oversized word wraps only at grapheme edges" {
    const segments: []const vaxis.Segment = &.{
        .{ .text = "ab", .style = .{ .bold = true } },
        .{ .text = "c" },
        .{ .text = "de", .link = .{ .uri = "contract:word" } },
    };
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(segments, 4, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 1, .row = 1, .overflow = false }, result);
    for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |glyph, i| {
        try testing.expectEqualStrings(glyph, cells[i].char.grapheme);
    }
    try testing.expect(cells[0].style.bold);
    try testing.expect(!cells[2].style.bold);
    try testing.expectEqualStrings("contract:word", cells[3].link.uri);
    try testing.expectEqualStrings("contract:word", cells[4].link.uri);
}

test "layout: fitting styled word moves whole and wide graphemes stay whole" {
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{ .{ .text = "  a" }, .{ .text = "界", .style = .{ .bold = true } }, .{ .text = "b" } }, 5, 3, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 4, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings(" ", cells[2].char.grapheme);
    try testing.expectEqualStrings("a", cells[5].char.grapheme);
    try testing.expectEqualStrings("界", cells[6].char.grapheme);
    try testing.expectEqual(@as(u8, 2), cells[6].char.width);
    try testing.expect(cells[6].style.bold);
    try testing.expectEqualStrings("b", cells[8].char.grapheme);
}

test "layout: all grapheme-boundary style partitions preserve layout" {
    // Every partition, not only one cut or the original h/e/l/l/o fixture.
    // Grapheme clusters (including CRLF, combining marks and ZWJ) stay intact:
    // arbitrary mid-UTF8 or mid-grapheme segment cuts are not this API contract.
    const corpus = [_][]const u8{
        "abcde",        "ab cde",             "  abcde",     "a     b", "ab\nc d", "ab\rc d",
        "a\r\nbc",
        "a界bcde",
        "éab界 c",
        "👩‍💻ab cd",
        "a\t b",        "ab\nc",              "> \u{0301}X",
        "a \u{0301}界",
        "a \u{0301} b", " \u{0301} \u{0308}",
    };
    for (corpus) |text| {
        var boundaries: [16]usize = undefined;
        var count: usize = 0;
        var it = unicode.graphemeIterator(text);
        while (it.next()) |grapheme| {
            boundaries[count] = grapheme.start + grapheme.len;
            count += 1;
        }
        const partitions = @as(usize, 1) << @as(u6, @intCast(count - 1));
        for ([_]u16{ 1, 2, 3, 4, 5, 7, 8 }) |width| {
            for ([_]u16{ 1, 2, 8 }) |height| {
                for ([_]u16{ 0, width - 1 }) |offset| {
                    inline for (.{ .word, .grapheme, .none }) |mode| {
                        const opts: vaxis.PrintOptions = .{ .wrap = mode, .col_offset = offset };
                        var expected: [128]vaxis.Cell = undefined;
                        const wanted = try paintAndMeasure(&.{.{ .text = text }}, width, height, opts, &expected);
                        for (0..partitions) |mask| {
                            var segments: [32]vaxis.Segment = undefined;
                            var n: usize = 0;
                            var start: usize = 0;
                            for (boundaries[0..count], 0..) |end, i| {
                                if (i + 1 != count and mask & (@as(usize, 1) << @as(u6, @intCast(i))) == 0) continue;
                                segments[n] = .{ .text = "" };
                                n += 1;
                                segments[n] = .{ .text = text[start..end], .style = .{ .bold = n % 4 == 1 }, .link = .{ .uri = "contract:partition" } };
                                n += 1;
                                start = end;
                            }
                            var actual: [128]vaxis.Cell = undefined;
                            const got = try paintAndMeasure(segments[0..n], width, height, opts, &actual);
                            if (!std.meta.eql(wanted, got)) {
                                std.debug.print("text={s} width={d} height={d} offset={d} mode={s} partition={d}\n", .{ text, width, height, offset, @tagName(mode), mask });
                            }
                            try testing.expectEqualDeep(wanted, got);
                            for (expected, actual) |a, b| {
                                try testing.expectEqualStrings(a.char.grapheme, b.char.grapheme);
                                try testing.expectEqual(a.char.width, b.char.width);
                                try testing.expectEqual(a.wrapped, b.wrapped);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "layout: soft wrapping suppresses one whitespace run across styles" {
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{ .{ .text = "a  " }, .{ .text = "   b", .style = .{ .bold = true } } }, 2, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 1, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings("a", cells[0].char.grapheme);
    try testing.expectEqualStrings("b", cells[2].char.grapheme);
}

test "layout: an unterminated final line does not consume another hard break" {
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{.{ .text = "a\nb" }}, 4, 4, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 1, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings("b", cells[4].char.grapheme);
}

test "layout: clipping a word does not consume its pending hard break" {
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{.{ .text = "ab\nc" }}, 1, 1, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 0, .row = 1, .overflow = true }, result);
    try testing.expectEqualStrings("a", cells[0].char.grapheme);
}

test "layout: saturated word width with a nonzero column remains bounded" {
    // Compile-time input, fixed stack grid: no allocation proportional to text.
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{ .{ .text = saturated_word[0..1] }, .{ .text = saturated_word[1..] } }, 4, 2, .{ .wrap = .word, .col_offset = 1 }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 0, .row = 2, .overflow = true }, result);
}

// Lazy style runs: no full span array or per-call mutable continuation mirror.
const StyledSource = struct {
    text: []const u8,
    at: usize = 0,
    empty: bool = true,

    pub fn next(self: *StyledSource) ?vaxis.Segment {
        if (self.at == self.text.len) return null;
        if (self.empty) {
            self.empty = false;
            return .{ .text = "" };
        }
        var iterator = unicode.graphemeIterator(self.text[self.at..]);
        const grapheme = iterator.next().?;
        const start = self.at;
        self.at += grapheme.len;
        self.empty = true;
        return .{ .text = self.text[start..self.at], .style = .{ .bold = start % 2 == 0 }, .link = .{ .uri = "contract:iterator" } };
    }
};

fn iteratorPrint(source: anytype, width: u16, height: u16, opts: vaxis.PrintOptions, cells: *[128]vaxis.Cell) vaxis.Window.PrintResult {
    var screen: vaxis.Screen = .{ .width = width, .height = height, .width_method = .unicode, .buf = cells[0 .. @as(usize, width) * height] };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
    return win.printIterator(source, opts);
}

test "layout: replayable source spans the old 32-run print-call boundary" {
    const text: [50]u8 = @splat('x');
    var cells: [128]vaxis.Cell = @splat(.{});
    const result = iteratorPrint(StyledSource{ .text = &text }, 40, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 10, .row = 1, .overflow = false }, result);
    // Independent expected cells: fill 40 first, then 10; do not move suffix18.
    for (cells[0..50]) |cell| try testing.expectEqualStrings("x", cell.char.grapheme);
    for (cells[50..80]) |cell| try testing.expectEqualStrings(" ", cell.char.grapheme);
}

test "layout: future runs classify a prefixed oversized word before moving it" {
    const word: [50]u8 = @splat('x');
    const text = "p " ++ word;
    var cells: [128]vaxis.Cell = @splat(.{});
    const result = iteratorPrint(StyledSource{ .text = text }, 40, 2, .{ .wrap = .word, .col_offset = 8 }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 20, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings("p", cells[8].char.grapheme);
    for (cells[10..60]) |cell| try testing.expectEqualStrings("x", cell.char.grapheme);
}

test "layout: iterator and slice agree through 64 runs empties offsets and clipping" {
    const word: [70]u8 = @splat('x');
    const texts = [_][]const u8{ &word, "p " ++ word, "a     b\nc d", "a界é👩‍💻 z" };
    for (texts) |text| {
        var array: [160]vaxis.Segment = undefined;
        var source: StyledSource = .{ .text = text };
        var count: usize = 0;
        while (source.next()) |segment| {
            array[count] = segment;
            count += 1;
        }
        for ([_]u16{ 1, 4, 8, 40 }) |width| {
            for ([_]u16{ 1, 2, 3 }) |height| {
                inline for (.{ .word, .grapheme, .none }) |mode| {
                    for ([_]u16{ 0, width - 1 }) |offset| {
                        var expected: [128]vaxis.Cell = @splat(.{});
                        const opts: vaxis.PrintOptions = .{ .wrap = mode, .col_offset = offset, .row_offset = height - 1 };
                        const wanted = try paintAndMeasure(array[0..count], width, height, opts, &expected);
                        var actual: [128]vaxis.Cell = @splat(.{});
                        const got = iteratorPrint(StyledSource{ .text = text }, width, height, opts, &actual);
                        try testing.expectEqualDeep(wanted, got);
                        try testing.expectEqualDeep(expected, actual);
                        var untouched: [128]vaxis.Cell = @splat(.{ .char = .{ .grapheme = "?", .width = 1 } });
                        const measured = iteratorPrint(StyledSource{ .text = text }, width, height, .{ .wrap = mode, .col_offset = offset, .row_offset = height - 1, .commit = false }, &untouched);
                        try testing.expectEqualDeep(wanted, measured);
                        for (untouched) |cell| try testing.expectEqualStrings("?", cell.char.grapheme);
                    }
                }
            }
        }
    }
}

test "layout: fit classification does not saturate at the u16 window width" {
    const word: [65536]u8 = @splat('x');
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 65535, .height = 3, .screen = &screen };
    const result = win.print(&.{.{ .text = &word }}, .{ .wrap = .word, .col_offset = 1, .commit = false });
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 2, .row = 1, .overflow = false }, result);
}

const BoundedProbeSource = struct {
    at: usize = 0,

    pub fn next(self: *BoundedProbeSource) ?vaxis.Segment {
        if (self.at == 100) return null;
        // A width4/height1 print needs <=5 runs for fit classification and
        // clipping. An eager whole-suffix scan is a meaningful failure here.
        std.debug.assert(self.at < 8);
        self.at += 1;
        return .{ .text = "x" };
    }
};

test "layout: word lookahead stops after oversized classification" {
    var cells: [128]vaxis.Cell = @splat(.{});
    const result = iteratorPrint(BoundedProbeSource{}, 4, 1, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 0, .row = 1, .overflow = true }, result);
    for (cells[0..4]) |cell| try testing.expectEqualStrings("x", cell.char.grapheme);
}

test "layout: wide glyph crossing the maximum column moves whole" {
    const prefix: [65534]u8 = @splat('x');
    const text = prefix ++ "界";
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 65535, .height = 3, .screen = &screen };
    inline for (.{ .word, .grapheme }) |mode| {
        const result = win.print(&.{.{ .text = text }}, .{ .wrap = mode, .commit = false });
        try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 2, .row = 1, .overflow = false }, result);
    }
}

test "layout: word printing retains a space plus combining mark as one cell" {
    const source = "> \u{0301}X";
    const segment: vaxis.Segment = .{ .text = source, .style = .{ .bold = true }, .link = .{ .uri = "contract:space-cluster", .params = "id=quote" } };
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{segment}, 6, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 3, .row = 0, .overflow = false }, result);
    try testing.expectEqualStrings(">", cells[0].char.grapheme);
    try testing.expectEqualStrings(" \u{0301}", cells[1].char.grapheme);
    try testing.expectEqualStrings("X", cells[2].char.grapheme);
    try testing.expectEqual(@as(u8, 1), cells[1].char.width);
    try testing.expect(cells[1].style.bold);
    try testing.expectEqualStrings("contract:space-cluster", cells[1].link.uri);
    try testing.expectEqualStrings("id=quote", cells[1].link.params);
    try testing.expectEqualStrings("> \u{0301}X", source);
}

test "layout: replayable word source retains complete styled space clusters" {
    const source = "> \u{0301}X";
    inline for (.{ .word, .grapheme, .none }) |mode| {
        var cells: [128]vaxis.Cell = @splat(.{});
        const result = iteratorPrint(StyledSource{ .text = source }, 6, 2, .{ .wrap = mode }, &cells);
        try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 3, .row = 0, .overflow = false }, result);
        try testing.expectEqualStrings(">", cells[0].char.grapheme);
        try testing.expectEqualStrings(" \u{0301}", cells[1].char.grapheme);
        try testing.expectEqualStrings("X", cells[2].char.grapheme);
        try testing.expect(!cells[1].style.bold);
        try testing.expectEqualStrings("contract:iterator", cells[1].link.uri);
        var untouched: [128]vaxis.Cell = @splat(.{ .char = .{ .grapheme = "?", .width = 1 } });
        const measured = iteratorPrint(StyledSource{ .text = source }, 6, 2, .{ .wrap = mode, .commit = false }, &untouched);
        try testing.expectEqualDeep(result, measured);
        for (untouched) |cell| try testing.expectEqualStrings("?", cell.char.grapheme);
    }
}

test "layout: fit lookahead does not split a styled space cluster from its word" {
    const source = "a \u{0301}X";
    const segments: []const vaxis.Segment = &.{ .{ .text = "a" }, .{ .text = " \u{0301}", .style = .{ .bold = true }, .link = .{ .uri = "contract:fit" } }, .{ .text = "X" } };
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(segments, 4, 2, .{ .wrap = .word, .col_offset = 2 }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 3, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings(" ", cells[2].char.grapheme);
    try testing.expectEqualStrings("a", cells[4].char.grapheme);
    try testing.expectEqualStrings(" \u{0301}", cells[5].char.grapheme);
    try testing.expectEqualStrings("X", cells[6].char.grapheme);
    try testing.expect(cells[5].style.bold);
    try testing.expectEqualStrings("contract:fit", cells[5].link.uri);
    @memset(&cells, .{});
    const lazy = iteratorPrint(StyledSource{ .text = source }, 4, 2, .{ .wrap = .word, .col_offset = 2 }, &cells);
    try testing.expectEqualDeep(result, lazy);
    try testing.expectEqualStrings("a", cells[4].char.grapheme);
    try testing.expectEqualStrings(" \u{0301}", cells[5].char.grapheme);
    try testing.expectEqualStrings("X", cells[6].char.grapheme);
}

test "layout: styled space cluster survives an oversized word and wide edge" {
    const source = "a \u{0301}界";
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{ .{ .text = "a" }, .{ .text = " \u{0301}", .link = .{ .uri = "contract:edge" } }, .{ .text = "界", .style = .{ .bold = true } } }, 3, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 2, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings("a", cells[0].char.grapheme);
    try testing.expectEqualStrings(" \u{0301}", cells[1].char.grapheme);
    try testing.expectEqualStrings(" ", cells[2].char.grapheme);
    try testing.expectEqualStrings("界", cells[3].char.grapheme);
    try testing.expectEqual(@as(u8, 2), cells[3].char.width);
    try testing.expect(cells[3].style.bold);
    try testing.expectEqualStrings("contract:edge", cells[1].link.uri);
    @memset(&cells, .{});
    const lazy = iteratorPrint(StyledSource{ .text = source }, 3, 2, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(result, lazy);
    try testing.expectEqualStrings(" \u{0301}", cells[1].char.grapheme);
    try testing.expectEqualStrings("界", cells[3].char.grapheme);
}

test "layout: ordinary ASCII tab space and CRLF keep their existing cells" {
    const source = "A\tB\r\nC D";
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{.{ .text = source }}, 12, 3, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 3, .row = 1, .overflow = false }, result);
    try testing.expectEqualStrings("A", cells[0].char.grapheme);
    for (cells[1..9]) |cell| try testing.expectEqualStrings(" ", cell.char.grapheme);
    try testing.expectEqualStrings("B", cells[9].char.grapheme);
    try testing.expectEqualStrings("C", cells[12].char.grapheme);
    try testing.expectEqualStrings(" ", cells[13].char.grapheme);
    try testing.expectEqualStrings("D", cells[14].char.grapheme);
    @memset(&cells, .{});
    const lazy = iteratorPrint(StyledSource{ .text = source }, 12, 3, .{ .wrap = .word }, &cells);
    try testing.expectEqualDeep(result, lazy);
    try testing.expectEqualStrings("B", cells[9].char.grapheme);
    try testing.expectEqualStrings("C", cells[12].char.grapheme);
    try testing.expectEqualStrings("D", cells[14].char.grapheme);
}

test "layout: CRLF remains one hard delimiter during styled fit lookahead" {
    const source = "a\r\nb";
    var cells: [128]vaxis.Cell = undefined;
    const result = try paintAndMeasure(&.{ .{ .text = "a" }, .{ .text = "\r\n" }, .{ .text = "b" } }, 4, 3, .{ .wrap = .word, .col_offset = 3 }, &cells);
    try testing.expectEqualDeep(vaxis.Window.PrintResult{ .col = 1, .row = 2, .overflow = false }, result);
    try testing.expectEqualStrings("a", cells[3].char.grapheme);
    try testing.expectEqualStrings(" ", cells[4].char.grapheme);
    try testing.expectEqualStrings("b", cells[8].char.grapheme);
    @memset(&cells, .{});
    const lazy = iteratorPrint(StyledSource{ .text = source }, 4, 3, .{ .wrap = .word, .col_offset = 3 }, &cells);
    try testing.expectEqualDeep(result, lazy);
    try testing.expectEqualStrings("a", cells[3].char.grapheme);
    try testing.expectEqualStrings("b", cells[8].char.grapheme);
}

// A deliberately tiny fixture oracle, NOT a terminal emulator: fixed 16x2 cells,
// ASCII, one literal joined emoji with independently stipulated physical advance
// TWO, and only the encoder controls exercised below. Unknown bytes fail closed.
const joined = "👩‍💻";
const PhysicalCell = struct {
    glyph: u21 = ' ',
    bg: u8 = 255,
    bold: bool = false,
    uri: [48]u8 = @splat(0),
    params: [24]u8 = @splat(0),
};
const PhysicalRow = struct {
    cells: [32]PhysicalCell = @splat(.{}),
    row: usize = 0,
    col: usize = 0,
    pending_wrap: bool = false,
    pen: PhysicalCell = .{},

    fn put(self: *@This(), glyph: u21, width: usize) !void {
        if (self.pending_wrap) {
            self.row += 1;
            self.col = 0;
            self.pending_wrap = false;
        }
        try testing.expect(self.row < 2 and self.col + width <= 16);
        for (0..width) |offset| {
            self.cells[self.row * 16 + self.col + offset] = self.pen;
            self.cells[self.row * 16 + self.col + offset].glyph = if (offset == 0) glyph else 0;
        }
        self.col += width;
        if (self.col == 16) {
            self.col = 15;
            self.pending_wrap = true;
        }
    }

    fn apply(self: *@This(), bytes: []const u8) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            if (std.mem.startsWith(u8, bytes[at..], joined)) {
                try self.put(0x1f469, 2); // Independent physical fact for THIS fixture only.
                at += joined.len;
            } else if (std.mem.startsWith(u8, bytes[at..], "\x1b[")) {
                const start = at + 2;
                var end = start;
                while (end < bytes.len and (bytes[end] < 0x40 or bytes[end] > 0x7e)) : (end += 1) {}
                try testing.expect(end < bytes.len);
                const args = bytes[start..end];
                switch (bytes[end]) {
                    'H' => {
                        var parts = std.mem.splitScalar(u8, args, ';');
                        const r = parts.next().?;
                        const c = parts.next() orelse "";
                        self.row = (if (r.len == 0) @as(usize, 1) else try std.fmt.parseInt(usize, r, 10)) - 1;
                        self.col = (if (c.len == 0) @as(usize, 1) else try std.fmt.parseInt(usize, c, 10)) - 1;
                        try testing.expect(self.row < 2 and self.col < 16);
                        self.pending_wrap = false;
                    },
                    'm' => {
                        var parts = std.mem.splitScalar(u8, args, ';');
                        while (parts.next()) |part| {
                            const n = if (part.len == 0) 0 else try std.fmt.parseInt(u16, part, 10);
                            switch (n) {
                                0 => {
                                    self.pen.bg = 255;
                                    self.pen.bold = false;
                                },
                                1 => self.pen.bold = true,
                                22 => self.pen.bold = false,
                                40...47 => self.pen.bg = @intCast(n - 40),
                                49 => self.pen.bg = 255,
                                else => return error.UnsupportedFixtureSgr,
                            }
                        }
                    },
                    'h', 'l' => try testing.expect(std.mem.eql(u8, args, "?2026") or std.mem.eql(u8, args, "?25")),
                    else => return error.UnsupportedFixtureCsi,
                }
                at = end + 1;
            } else if (std.mem.startsWith(u8, bytes[at..], "\x1b]8;")) {
                const start = at + 4;
                const end = std.mem.indexOfPos(u8, bytes, start, "\x1b\\") orelse return error.UnterminatedFixtureOsc;
                const sep = std.mem.indexOfScalarPos(u8, bytes, start, ';') orelse return error.InvalidFixtureOsc;
                try testing.expect(sep < end and sep - start < self.pen.params.len and end - sep - 1 < self.pen.uri.len);
                self.pen.params = @splat(0);
                self.pen.uri = @splat(0);
                @memcpy(self.pen.params[0 .. sep - start], bytes[start..sep]);
                @memcpy(self.pen.uri[0 .. end - sep - 1], bytes[sep + 1 .. end]);
                at = end + 2;
            } else {
                try testing.expect(bytes[at] >= 0x20 and bytes[at] < 0x7f);
                try self.put(bytes[at], 1);
                at += 1;
            }
        }
    }

    fn expectRow(self: *const @This(), row: usize, glyphs: [16]u21) !void {
        for (glyphs, 0..) |glyph, col| try testing.expectEqual(glyph, self.cells[row * 16 + col].glyph);
    }
};

const RenderFixture = struct {
    env: std.process.Environ.Map = undefined,
    vx: vaxis.Vaxis = undefined,
    bytes: std.Io.Writer.Allocating = undefined,

    fn init(self: *@This()) !void {
        self.env = try testing.environ.createMap(testing.allocator);
        errdefer self.env.deinit();
        self.bytes = .init(testing.allocator);
        errdefer self.bytes.deinit();
        self.vx = try vaxis.Vaxis.init(testing.io, testing.allocator, &self.env, .{});
        errdefer self.vx.deinit(testing.allocator, &self.bytes.writer);
        self.vx.state.alt_screen = true;
        self.vx.caps.unicode = .wcwidth;
        try self.vx.resize(testing.allocator, &self.bytes.writer, .{ .rows = 2, .cols = 16, .x_pixel = 0, .y_pixel = 0 });
        self.vx.screen.width_method = .wcwidth;
        self.bytes.clearRetainingCapacity();
    }

    fn deinit(self: *@This()) void {
        self.vx.deinit(testing.allocator, &self.bytes.writer);
        self.bytes.deinit();
        self.env.deinit();
    }

    fn render(self: *@This()) ![]const u8 {
        self.bytes.clearRetainingCapacity();
        try self.vx.render(&self.bytes.writer);
        return self.bytes.written();
    }

    fn paint(self: *@This(), row: u16, inferred: bool) void {
        self.vx.window().clear();
        const screen = &self.vx.screen;
        screen.writeCell(0, row, .{ .char = .{ .grapheme = "L", .width = 1 } });
        screen.writeCell(1, row, .{ .char = .{ .grapheme = ":", .width = 1 } });
        screen.writeCell(2, row, .{ .char = .{ .grapheme = joined, .width = if (inferred) 0 else 4 }, .style = .{ .bg = .{ .index = 1 }, .bold = true }, .link = .{ .uri = "contract:cluster", .params = "id=cluster" } });
        screen.writeCell(6, row, .{ .char = .{ .grapheme = "N", .width = 1 }, .style = .{ .bg = .{ .index = 5 } }, .link = .{ .uri = "contract:neighbor", .params = "id=neighbor" } });
        for ("23 end", 0..) |_, i| {
            const chars = [_][]const u8{ "2", "3", " ", "e", "n", "d" };
            screen.writeCell(@intCast(10 + i), row, .{ .char = .{ .grapheme = chars[i], .width = 1 } });
        }
    }
};

const physical_golden: [16]u21 = .{ 'L', ':', 0x1f469, 0, ' ', ' ', 'N', ' ', ' ', ' ', '2', '3', ' ', 'e', 'n', 'd' };

test "render contract: bounded joined fallback clears old suffix and repositions following diff" {
    for ([_]bool{ false, true }) |inferred| {
        var fixture: RenderFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var terminal: PhysicalRow = .{};
        const old = "abcdefghijklmnopqrstuvwxyzABCDEF";
        for (old, 0..) |_, i| fixture.vx.screen.writeCell(@intCast(i % 16), @intCast(i / 16), .{ .char = .{ .grapheme = old[i..][0..1], .width = 1 }, .style = .{ .bg = .{ .index = 4 } }, .link = .{ .uri = "contract:old", .params = "id=old" } });
        try terminal.apply(try fixture.render());
        fixture.vx.screen.cursor_vis = true;
        fixture.vx.screen.cursor = .{ .row = 1, .col = 14 };
        for ([_]u16{ 0, 1 }) |row| {
            fixture.paint(row, inferred);
            const encoded = try fixture.render();
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, encoded, joined));
            try terminal.apply(encoded);
            try terminal.expectRow(row, physical_golden);
            try terminal.expectRow(1 - row, @splat(' '));
            for (2..6) |col| {
                const cell = terminal.cells[@as(usize, row) * 16 + col];
                try testing.expectEqual(@as(u8, 1), cell.bg);
                try testing.expect(cell.bold);
                try testing.expectEqualStrings("contract:cluster", std.mem.sliceTo(&cell.uri, 0));
                try testing.expectEqualStrings("id=cluster", std.mem.sliceTo(&cell.params, 0));
            }
            const neighbor = terminal.cells[@as(usize, row) * 16 + 6];
            try testing.expectEqual(@as(u8, 5), neighbor.bg);
            try testing.expect(!neighbor.bold);
            try testing.expectEqualStrings("contract:neighbor", std.mem.sliceTo(&neighbor.uri, 0));
            try testing.expectEqualStrings("id=neighbor", std.mem.sliceTo(&neighbor.params, 0));
            try testing.expectEqualStrings(joined, fixture.vx.screen.readCell(2, row).?.char.grapheme);
            try testing.expectEqual(@as(u8, if (inferred) 0 else 4), fixture.vx.screen.readCell(2, row).?.char.width);
            try testing.expectEqual(@as(usize, 1), terminal.row);
            try testing.expectEqual(@as(usize, 14), terminal.col);
            try testing.expectEqual(@as(usize, 0), (try fixture.render()).len);
        }
    }
}

test "render contract: joined fallback at row edge never positions outside owned row" {
    var fixture: RenderFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var terminal: PhysicalRow = .{};
    for (0..16) |col| fixture.vx.screen.writeCell(@intCast(col), 0, .{ .char = .{ .grapheme = "x", .width = 1 } });
    try terminal.apply(try fixture.render());
    fixture.vx.window().clear();
    fixture.vx.screen.writeCell(12, 0, .{ .char = .{ .grapheme = joined, .width = 4 } });
    fixture.vx.screen.writeCell(0, 1, .{ .char = .{ .grapheme = "Z", .width = 1 } });
    try terminal.apply(try fixture.render());
    try terminal.expectRow(0, .{ ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', 0x1f469, 0, ' ', ' ' });
    try terminal.expectRow(1, .{ 'Z', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' });
    try testing.expectEqual(@as(usize, 0), (try fixture.render()).len);
}

test "render contract: excluded width lanes retain exact encoder bytes" {
    const Case = struct {
        text: []const u8 = joined,
        width: u8 = 4,
        col: u16 = 1,
        method: @TypeOf(@as(vaxis.Vaxis, undefined).caps.unicode) = .wcwidth,
        explicit: bool = false,
        scaled: bool = false,
        alt: bool = true,
        scale: vaxis.Cell.Scale = .{},
        image: bool = false,
        encoded: []const u8,
    };
    const begin = "\x1b[?2026h\x1b[?25l\x1b[H\x1b[m\x1b[1;2H";
    const end = "\x1b[?2026l";
    // Hand-written complete byte goldens: excluded lanes get NO clearing or
    // extra CUP. Their pre-existing layout/encoding contracts are unchanged.
    const cases = [_]Case{
        .{ .text = "A", .width = 1, .encoded = begin ++ "AN" ++ end },
        .{ .text = "界", .width = 2, .encoded = begin ++ "界N" ++ end },
        .{ .text = "❤️", .width = 1, .encoded = begin ++ "❤️N" ++ end },
        .{ .text = "a\u{200d}", .width = 1, .encoded = begin ++ "a\u{200d}N" ++ end }, // ZWJ but no width gap
        .{ .method = .no_zwj, .encoded = begin ++ joined ++ "N" ++ end },
        .{ .width = 3, .encoded = begin ++ joined ++ "N" ++ end }, // arbitrary override
        .{ .width = 2, .method = .unicode, .encoded = begin ++ joined ++ "N" ++ end },
        .{ .text = "A" ++ joined, .width = 5, .encoded = begin ++ "A" ++ joined ++ "N" ++ end }, // not one cluster
        .{ .scale = .{ .numerator = 2 }, .encoded = begin ++ joined ++ "N" ++ end },
        .{ .scale = .{ .denominator = 2 }, .scaled = true, .encoded = begin ++ "\x1b]66;s=1:w=4:n=1:d=2:v=0;" ++ joined ++ "\x1b\\N" ++ end },
        .{ .image = true, .encoded = begin ++ "\x1b_Ga=p,i=7,C=1\x1b\\" ++ joined ++ "N" ++ end },
        .{ .explicit = true, .encoded = begin ++ "\x1b]66;w=4;" ++ joined ++ "\x1b\\N" ++ end },
        .{ .alt = false, .encoded = "\x1b[?2026h\x1b[?25l\r\x1b[m\x1b[1C" ++ joined ++ "N" ++ end },
        .{ .col = 14, .encoded = "\x1b[?2026h\x1b[?25l\x1b[H\x1b[m\x1b[1;15H" ++ joined ++ end }, // unowned row overflow
    };
    for (cases) |case| {
        var fixture: RenderFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        _ = try fixture.render(); // establish a default retained frame
        fixture.vx.state.alt_screen = case.alt;
        fixture.vx.state.cursor = .{};
        fixture.vx.caps.explicit_width = case.explicit;
        fixture.vx.caps.scaled_text = case.scaled;
        fixture.vx.caps.unicode = case.method;
        fixture.vx.screen.writeCell(case.col, 0, .{
            .char = .{ .grapheme = case.text, .width = case.width },
            .scale = case.scale,
            .image = if (case.image) .{ .img_id = 7, .options = .{} } else null,
        });
        if (@as(u32, case.col) + case.width < 16) fixture.vx.screen.writeCell(case.col + case.width, 0, .{ .char = .{ .grapheme = "N", .width = 1 } });
        try testing.expectEqualStrings(case.encoded, try fixture.render());
    }
}
