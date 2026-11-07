//! Pure bounded raw table-row syntax, shared by future capture and layout callers.
//! No caller is enabled here. Block/fence/quote eligibility stays in AnswerRenderer;
//! balanced code only protects separators, never expands inline-format support.
const std = @import("std");

pub const max_columns = 8;
pub const max_source_bytes = 4096;

/// Raw excludes LF but retains CR. Only line_feed proves a terminal CR is CRLF.
/// pending includes retention cuts; canonical_eof requires actual sealed source.
pub const Ending = enum { pending, line_feed, canonical_eof };
pub const Range = struct { start: u16, end: u16 };
pub const Row = struct {
    cells: [max_columns]Range = undefined,
    count: u4 = 0,
    /// Includes optional outer pipes, but not escaped or code-span pipes.
    has_pipe: bool = false,
};
pub const Result = union(enum) { need_more, literal, row: Row };
pub const Alignment = enum { left, center, right };
pub const Columns = struct {
    count: u4,
    alignment: [max_columns]Alignment = undefined,
};
pub const Header = union(enum) { need_more, literal, columns: Columns };

/// Offsets borrow no slices and address exactly the supplied raw bytes. Only
/// ASCII space/tab cell edges are omitted; callers retain the complete source.
/// expected_columns, when supplied, must be 1..8. No partial row is returned on
/// ragged, unbalanced, malformed or over-limit input. Pipes in links are ordinary
/// separators unless escaped or code-protected; this is not an inline parser.
/// Unused ranges are undefined.
pub fn parse(raw: []const u8, ending: Ending, expected_columns: ?u4) Result {
    if (expected_columns) |count| std.debug.assert(count >= 1 and count <= max_columns);
    if (raw.len > max_source_bytes) return .literal;
    if (sourceLength(raw, ending) > max_source_bytes) return .literal;
    if (ending == .pending) return .need_more;

    var end = raw.len;
    if (ending == .line_feed and end > 0 and raw[end - 1] == '\r') end -= 1;
    var at: usize = 0;
    while (at < end and space(raw[at])) : (at += 1) {}
    while (end > at and space(raw[end - 1])) : (end -= 1) {}
    if (at == end) return .literal;

    var row: Row = .{ .count = 0, .has_pipe = false };
    if (raw[at] == '|') {
        row.has_pipe = true;
        at += 1;
        if (at == end) return .literal; // A lone pipe has no cell; || has one.
    }
    var start = at;
    var ticks: usize = 0;
    while (at < end) {
        switch (raw[at]) {
            '\n' => return .literal,
            '\\' => if (ticks == 0) {
                at += 1;
                if (at < end) {
                    if (raw[at] == '\n') return .literal;
                    at += 1;
                }
                continue;
            },
            '`' => {
                const run = at;
                while (at < end and raw[at] == '`') : (at += 1) {}
                const length = at - run;
                if (ticks == 0) ticks = length else if (ticks == length) ticks = 0;
                continue;
            },
            '|' => if (ticks == 0) {
                row.has_pipe = true;
                if (!cell(&row, raw, start, at)) return .literal;
                start = at + 1;
            },
            else => {},
        }
        at += 1;
    }
    if (ticks != 0) return .literal;
    // A structural final pipe completed the last cell, not a phantom extra one.
    if (start < end and !cell(&row, raw, start, end)) return .literal;
    if (expected_columns) |count| if (row.count != count) return .literal;
    return .{ .row = row };
}

/// Validate an already-eligible raw pair, not its surrounding block context.
/// raw_header MUST have a real LF before the delimiter (neither slice includes
/// LF). Source credit includes that LF and the delimiter's proved LF, if any.
/// At least one structural pipe across the pair is required, so paragraph+---
/// is not a table. A complete delimiter at canonical EOF can seal a header-only
/// table; a chunk or retained boundary cannot. Unused alignments are undefined.
pub fn header(raw_header: []const u8, raw_delimiter: []const u8, ending: Ending) Header {
    if (raw_header.len >= max_source_bytes or raw_delimiter.len > max_source_bytes) return .literal;
    if (sourceLength(raw_header, .line_feed) + sourceLength(raw_delimiter, ending) > max_source_bytes) return .literal;
    if (ending == .pending) return .need_more;
    const first = switch (parse(raw_header, .line_feed, null)) {
        .row => |row| row,
        .literal => return .literal,
        .need_more => unreachable,
    };
    const delimiter = switch (parse(raw_delimiter, ending, first.count)) {
        .row => |row| row,
        .literal => return .literal,
        .need_more => unreachable,
    };
    if (!first.has_pipe and !delimiter.has_pipe) return .literal;
    var columns: Columns = .{ .count = first.count };
    for (delimiter.cells[0..delimiter.count], 0..) |range, index| {
        var text = raw_delimiter[range.start..range.end];
        const left = text.len > 0 and text[0] == ':';
        if (left) text = text[1..];
        const right = text.len > 0 and text[text.len - 1] == ':';
        if (right) text = text[0 .. text.len - 1];
        if (text.len < 3) return .literal;
        for (text) |byte| if (byte != '-') return .literal;
        columns.alignment[index] = if (left and right) .center else if (right) .right else .left;
    }
    return .{ .columns = columns };
}

fn sourceLength(raw: []const u8, ending: Ending) usize {
    // Callers check raw.len before addition; no unbounded length arithmetic.
    std.debug.assert(raw.len <= max_source_bytes);
    return raw.len + @intFromBool(ending == .line_feed);
}

fn space(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn cell(row: *Row, raw: []const u8, first: usize, last: usize) bool {
    if (row.count == max_columns) return false;
    var start = first;
    var end = last;
    while (start < end and space(raw[start])) : (start += 1) {}
    while (end > start and space(raw[end - 1])) : (end -= 1) {}
    row.cells[row.count] = .{ .start = @intCast(start), .end = @intCast(end) };
    row.count += 1;
    return true;
}

fn expectCells(raw: []const u8, ending: Ending, expected: []const []const u8, pipe: bool) !void {
    const result = parse(raw, ending, null);
    try std.testing.expectEqual(.row, std.meta.activeTag(result));
    const row = result.row;
    try std.testing.expectEqual(expected.len, row.count);
    try std.testing.expectEqual(pipe, row.has_pipe);
    var previous: usize = 0;
    for (row.cells[0..row.count], expected) |range, text| {
        try std.testing.expect(range.start >= previous and range.end <= raw.len);
        try std.testing.expectEqualStrings(text, raw[range.start..range.end]);
        previous = range.end;
    }
}

test "table row optional edges and explicit empty cells have no phantom columns" {
    const cases = [_]struct { raw: []const u8, cells: []const []const u8, pipe: bool = true }{
        .{ .raw = "a | b", .cells = &.{ "a", "b" } },
        .{ .raw = "|a|b|", .cells = &.{ "a", "b" } },
        .{ .raw = " a | b | ", .cells = &.{ "a", "b" } },
        .{ .raw = " | a | b", .cells = &.{ "a", "b" } },
        .{ .raw = "a||b", .cells = &.{ "a", "", "b" } },
        .{ .raw = "|a||b|", .cells = &.{ "a", "", "b" } },
        .{ .raw = "a||", .cells = &.{ "a", "" } },
        .{ .raw = "||", .cells = &.{""} },
        .{ .raw = "|||", .cells = &.{ "", "" } },
        .{ .raw = " | \t | ", .cells = &.{""} },
        .{ .raw = "a|", .cells = &.{"a"} },
        .{ .raw = "|a", .cells = &.{"a"} },
        .{ .raw = " plain ", .cells = &.{"plain"}, .pipe = false },
    };
    for (cases) |case| try expectCells(case.raw, .canonical_eof, case.cells, case.pipe);
    for ([_][]const u8{ "", " \t ", "|", " | " }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(parse(raw, .canonical_eof, null)));
    }
}

test "table row outside backslash parity protects raw pipes without unescaping" {
    try expectCells("a\\|b|c", .line_feed, &.{ "a\\|b", "c" }, true);
    try expectCells("a\\\\|b", .line_feed, &.{ "a\\\\", "b" }, true);
    try expectCells("a\\\\\\|b|c", .line_feed, &.{ "a\\\\\\|b", "c" }, true);
    try expectCells("a\\\\\\\\|b", .line_feed, &.{ "a\\\\\\\\", "b" }, true);
    try expectCells("\\|", .canonical_eof, &.{"\\|"}, false);
    try expectCells("\\`a|b", .canonical_eof, &.{ "\\`a", "b" }, true);
    try expectCells("a|tail\\", .canonical_eof, &.{ "a", "tail\\" }, true);
    try expectCells("| [a|b](https://x) | c |", .line_feed, &.{ "[a", "b](https://x)", "c" }, true);
    try expectCells("| [a\\|b](https://x) | c |", .line_feed, &.{ "[a\\|b](https://x)", "c" }, true);
}

test "table row exact balanced tick runs protect code pipes with literal backslashes" {
    try expectCells("`a|b`|c", .line_feed, &.{ "`a|b`", "c" }, true);
    try expectCells("``a`|b``|c", .line_feed, &.{ "``a`|b``", "c" }, true);
    try expectCells("`a\\`|b", .line_feed, &.{ "`a\\`", "b" }, true);
    try expectCells("``a\\|b``|c", .line_feed, &.{ "``a\\|b``", "c" }, true);
    for ([_][]const u8{ "`a|b", "a|`b|c", "``a`|b`|c", "```", "``" }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(parse(raw, .canonical_eof, null)));
    }
    // All runs are read monotonically once; mismatched runs never suffix-search.
    var raw: [128]u8 = undefined;
    for (1..33) |ticks| {
        @memset(raw[0..ticks], '`');
        @memcpy(raw[ticks..][0..3], "a|b");
        @memset(raw[ticks + 3 ..][0..ticks], '`');
        @memcpy(raw[ticks * 2 + 3 ..][0..2], "|z");
        const text = raw[0 .. ticks * 2 + 5];
        const row = parse(text, .canonical_eof, null).row;
        try std.testing.expectEqual(@as(u4, 2), row.count);
        try std.testing.expectEqual(@as(u16, @intCast(ticks * 2 + 3)), row.cells[0].end);
        try std.testing.expectEqualStrings("z", text[row.cells[1].start..row.cells[1].end]);
    }
}

test "table row pending windows never acquire completion at any split" {
    for ([_][]const u8{ "| a | b |", "a\\|b|c", "``a|b``|c", "|", "||", "a|b\r" }) |raw| {
        for (0..raw.len + 1) |split| {
            try std.testing.expectEqual(.need_more, std.meta.activeTag(parse(raw[0..split], .pending, null)));
        }
    }
    try std.testing.expectEqual(.row, std.meta.activeTag(parse("||", .canonical_eof, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse("|", .canonical_eof, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse("`unfinished|code", .canonical_eof, null)));
}

test "table row real CRLF and canonical EOF have distinct raw syntax boundaries" {
    try expectCells("| a | b |\r", .line_feed, &.{ "a", "b" }, true);
    try expectCells("a | b\r", .line_feed, &.{ "a", "b" }, true);
    try expectCells("a | b\r", .canonical_eof, &.{ "a", "b\r" }, true);
    try expectCells("a\r | b", .line_feed, &.{ "a\r", "b" }, true);
    try expectCells("a | b\r\r", .line_feed, &.{ "a", "b\r" }, true);
    for ([_][]const u8{ "a\n|b", "a\\\n|b", "`a\n|b`" }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(parse(raw, .canonical_eof, null)));
    }
}

test "table row source byte cap includes actual LF and never treats a cut as EOF" {
    var raw: [max_source_bytes + 1]u8 = @splat('x');
    try std.testing.expectEqual(.row, std.meta.activeTag(parse(raw[0 .. max_source_bytes - 1], .line_feed, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse(raw[0..max_source_bytes], .line_feed, null)));
    try std.testing.expectEqual(.row, std.meta.activeTag(parse(raw[0..max_source_bytes], .canonical_eof, null)));
    try std.testing.expectEqual(.need_more, std.meta.activeTag(parse(raw[0..max_source_bytes], .pending, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse(&raw, .pending, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse(&raw, .canonical_eof, null)));
    raw[max_source_bytes - 2] = '\r';
    const row = parse(raw[0 .. max_source_bytes - 1], .line_feed, null).row;
    try std.testing.expectEqual(@as(u16, max_source_bytes - 2), row.cells[0].end);
    // Raw CRLF bytes have not been normalized or overwritten.
    try std.testing.expectEqual(@as(u8, '\r'), raw[max_source_bytes - 2]);
    @memset(&raw, '`');
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse(raw[0..max_source_bytes], .canonical_eof, null)));
}

test "table row arity limit and ragged rows reject the complete row" {
    const eight = "|a|b|c|d|e|f|g|h|";
    try std.testing.expectEqual(@as(u4, 8), parse(eight, .line_feed, 8).row.count);
    try std.testing.expectEqual(@as(u4, 8), header(eight, "---|---|---|---|---|---|---|---", .line_feed).columns.count);
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("a|b|c|d|e|f|g|h|i", "---|---|---|---|---|---|---|---|---", .line_feed)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse("|a|b|c|d|e|f|g|h|i|", .line_feed, null)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(parse("||||||||||", .line_feed, null)));
    try std.testing.expectEqual(@as(u4, 8), parse("|||||||||", .line_feed, 8).row.count);
    for (1..9) |expected| {
        const count: u4 = @intCast(expected);
        const expected_tag: std.meta.Tag(Result) = if (count == 8) .row else .literal;
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(parse(eight, .canonical_eof, count)));
    }
}

test "table header alignment is lexical and needs structural pipe evidence across the pair" {
    const columns = header("plain | left | center | right", "--- | :--- | :---: | ---:", .line_feed).columns;
    try std.testing.expectEqual(@as(u4, 4), columns.count);
    try std.testing.expectEqualSlices(Alignment, &.{ .left, .left, .center, .right }, columns.alignment[0..columns.count]);
    try std.testing.expectEqual(@as(u4, 1), header("heading", "| --- |", .canonical_eof).columns.count);
    try std.testing.expectEqual(@as(u4, 1), header("|heading|", "---", .canonical_eof).columns.count);
    try std.testing.expectEqual(@as(u4, 1), header("||", "|---|", .canonical_eof).columns.count);
    for ([_][]const u8{ "paragraph", "escaped\\|pipe", "`code|pipe`" }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(header(raw, "---", .line_feed)));
    }
}

test "table header delimiter grammar rejects malformed ragged and unsupported rows wholly" {
    for ([_][]const u8{ "--|---", ":--|---", "---|--:", "---|::---", "---|-x-", "---||---", "---|`---`", "---|", "---|---\r" }) |delimiter| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(header("a|b", delimiter, .canonical_eof)));
    }
    try std.testing.expectEqual(Alignment.right, header("a|b", "---|---: ", .canonical_eof).columns.alignment[1]);
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("|", "|---|", .line_feed)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("a|b|c", "---|---", .line_feed)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("`a|b", "---|---", .line_feed)));
}

test "table header endings use proved CRLF or EOF and pending delimiter remains raw" {
    const delimiter = "| :--- | ---: |\r";
    for (0..delimiter.len + 1) |split| {
        try std.testing.expectEqual(.need_more, std.meta.activeTag(header("| a | b |\r", delimiter[0..split], .pending)));
    }
    const columns = header("| a | b |\r", delimiter, .line_feed).columns;
    try std.testing.expectEqualSlices(Alignment, &.{ .left, .right }, columns.alignment[0..columns.count]);
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("a|b", delimiter, .canonical_eof)));
    try std.testing.expectEqual(.columns, std.meta.activeTag(header("a|b", "---|---", .canonical_eof)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header("a|b", "---|--", .canonical_eof)));
}

test "table header source credit bounds the combined candidate before any admission" {
    const raw: [max_source_bytes]u8 = @splat('h');
    const delimiter = "|---|";
    const exact = max_source_bytes - 1 - delimiter.len - 1;
    try std.testing.expectEqual(.columns, std.meta.activeTag(header(raw[0..exact], delimiter, .line_feed)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header(raw[0 .. exact + 1], delimiter, .line_feed)));
    try std.testing.expectEqual(.columns, std.meta.activeTag(header(raw[0 .. exact + 1], delimiter, .canonical_eof)));
    try std.testing.expectEqual(.need_more, std.meta.activeTag(header(raw[0 .. exact + 1], delimiter, .pending)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header(raw[0 .. exact + 2], delimiter, .pending)));
    try std.testing.expectEqual(.literal, std.meta.activeTag(header(&raw, delimiter, .canonical_eof)));
}

test "table row offsets preserve raw controls Unicode escapes and every source byte" {
    const raw = " | 👩‍🚀 é | a\\|b | \x1b[31m\xff\x07 | ";
    try expectCells(raw, .line_feed, &.{ "👩‍🚀 é", "a\\|b", "\x1b[31m\xff\x07" }, true);
    const row = parse(raw, .line_feed, 3).row;
    // Reconstruct source from independently checked ranges plus every gap. No
    // normalized/unescaped view is permitted to become copy/source authority.
    var copy: [raw.len]u8 = undefined;
    var start: usize = 0;
    for (row.cells[0..row.count]) |range| {
        @memcpy(copy[start..range.start], raw[start..range.start]);
        @memcpy(copy[range.start..range.end], raw[range.start..range.end]);
        start = range.end;
    }
    @memcpy(copy[start..], raw[start..]);
    try std.testing.expectEqualStrings(raw, &copy);
    try std.testing.expect(@sizeOf(Row) <= 40 and @sizeOf(Columns) <= 16);
}
