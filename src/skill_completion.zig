const std = @import("std");

pub const Candidate = struct { start: usize, end: usize, prefix: []const u8 };

fn nameByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
}

fn whitespace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

// This deliberately recognizes backtick runs, not Markdown as a whole.
fn inCode(text: []const u8, end: usize) bool {
    var run: usize = 0;
    var i: usize = 0;
    while (i < end) {
        if (text[i] == '\\' and i + 1 < end) {
            i += 2;
            continue;
        }
        if (text[i] != '`') {
            i += 1;
            continue;
        }
        const start = i;
        while (i < end and text[i] == '`') : (i += 1) {}
        const length = i - start;
        if (run == 0) {
            run = length;
        } else if (run == length or (run >= 3 and length >= run)) {
            run = 0;
        }
    }
    return run != 0;
}

pub fn candidate(text: []const u8, cursor: usize) ?Candidate {
    if (cursor > text.len or (cursor < text.len and text[cursor] & 0xc0 == 0x80)) return null;
    var start = cursor;
    while (start > 0 and nameByte(text[start - 1])) : (start -= 1) {}
    if (start == 0 or text[start - 1] != '/') return null;
    start -= 1;
    if (start > 0 and !whitespace(text[start - 1])) return null;
    if (inCode(text, start)) return null;

    var end = cursor;
    while (end < text.len and nameByte(text[end])) : (end += 1) {}
    if (end < text.len and !whitespace(text[end])) {
        switch (text[end]) {
            ',', ';', ':', '!', '?', ')', ']' => {},
            '.' => if (end + 1 < text.len and !whitespace(text[end + 1])) return null,
            else => return null,
        }
    }
    return .{ .start = start, .end = end, .prefix = text[start + 1 .. cursor] };
}

fn expect(text: []const u8, cursor: usize, start: usize, end: usize, prefix: []const u8) !void {
    const result = candidate(text, cursor) orelse return error.MissingCandidate;
    try std.testing.expectEqual(start, result.start);
    try std.testing.expectEqual(end, result.end);
    try std.testing.expectEqualStrings(prefix, result.prefix);
}

test "completion range and cursor positions" {
    const text = "hi /skill-name, next";
    const prefixes = [_][]const u8{ "", "s", "sk", "ski", "skil", "skill", "skill-", "skill-n", "skill-na", "skill-nam", "skill-name" };
    for (prefixes, 4..) |prefix, cursor| try expect(text, cursor, 3, 14, prefix);
    try std.testing.expect(candidate(text, 3) == null);
    try std.testing.expect(candidate(text, 15) == null);
    try std.testing.expect(candidate(text, text.len + 1) == null);
    try expect("é /abc", 5, 3, 7, "a");
    try std.testing.expect(candidate("é /abc", 1) == null);
    try expect("/exact", 6, 0, 6, "exact");
    try expect("/", 1, 0, 1, "");
    try expect("say /foo!", 8, 4, 8, "foo");
    try expect("quoted prose /foo)", 17, 13, 17, "foo");
}

test "punctuation paths and code" {
    for ([_][]const u8{ ",", ";", ":", "!", "?", ")", "]", ".", ". next" }) |suffix| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "/foo{s}", .{suffix});
        try expect(text, 4, 0, 4, "foo");
    }
    // A dot is sentence punctuation only at end or before whitespace.
    for ([_][]const u8{ "/foo.txt", "/foo/bar", "https://foo", "//foo", "\\/foo", "x/foo", "`/foo`", "`` `/foo` ``", "```\n/foo\n```", "```\n/foo\n````", "before `/foo", "/foo_bar" }) |text| {
        const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse unreachable;
        try std.testing.expect(candidate(text, slash + 1) == null);
    }
    try expect("`code` /foo", 11, 7, 11, "foo");
    try expect("```\ncode\n```` /foo", 18, 14, 18, "foo");
    for (0.."/foo/bar".len + 1) |cursor| try std.testing.expect(candidate("/foo/bar", cursor) == null);
}
