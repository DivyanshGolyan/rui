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
        "abcde",   "ab cde", "  abcde", "a     b", "ab\nc d", "ab\rc d",
        "a\r\nbc",
        "a界bcde",
        "éab界 c",
        "👩‍💻ab cd",
        "a\t b",   "ab\nc",
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
