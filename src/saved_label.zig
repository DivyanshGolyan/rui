//! The saved call label: the text a tool call is saved under, and the one line it is shown as. Saving repairs and
//! bounds the text, so every stored label is valid UTF-8 within max_bytes; reading turns it into one tidy line.
//! Both steps walk the bytes through the same Walker, so the saved text and the shown line agree on what a byte means.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub const max_bytes = 200;
pub const max_label_bytes = 100;
pub const fallback_words = "Tool call";

const replacement = "\xef\xbf\xbd";
const replacement_scalar: u21 = 0xfffd;

pub const SavedLabel = struct {
    text: Bounded(max_bytes) = .{},

    /// The label saved for `bytes`: repaired, then cut to at most max_bytes at a scalar boundary.
    /// Null when the text has no words at all (empty or only separators), so the caller can use its tool's fixed words
    /// instead; judged before the cut, so a long run of spaces ahead of a word does not make the label blank.
    pub fn of(bytes: []const u8) ?SavedLabel {
        if (readWords(max_bytes, bytes) == null) return null;
        return fromColumn(bytes);
    }

    /// The label held by a column. Total: any bytes read back, repaired and cut the same way as `of`.
    pub fn fromColumn(column: []const u8) SavedLabel {
        var label: SavedLabel = .{};
        var walker: Walker = .{ .bytes = column };
        while (walker.next()) |piece| {
            if (label.text.len + piece.text.len > max_bytes) break;
            append(&label.text, piece.text);
        }
        return label;
    }

    pub fn raw(self: *const SavedLabel) []const u8 {
        return self.text.slice();
    }

    /// The one line this label is shown as, at most `max` bytes, or null when no words are left.
    pub fn words(self: *const SavedLabel, comptime max: usize) ?Bounded(max) {
        return readWords(max, self.raw());
    }
};

/// A saved call label read as one tidy line of words, or fallback_words when it has none. Total.
/// Every reader of the saved column goes through this, so a stored label reads the same on every surface.
pub fn callWords(saved: []const u8) Bounded(max_bytes) {
    return readWords(max_bytes, saved) orelse Bounded(max_bytes).from(fallback_words) catch unreachable;
}

/// `bytes` as one tidy line of at most `max` bytes: repaired, line separators and space runs collapsed to one
/// space, leading and trailing spaces trimmed, and cut at a scalar boundary. Null when no words are left.
pub fn readWords(comptime max: usize, bytes: []const u8) ?Bounded(max) {
    var line: Bounded(max) = .{};
    var pending_space = false;
    var walker: Walker = .{ .bytes = bytes };
    while (walker.next()) |piece| {
        if (isSpace(piece.scalar)) {
            // A space is written only before the next word, so a space left at the end is never written.
            pending_space = line.len != 0;
            continue;
        }
        const gap: usize = if (pending_space) 1 else 0;
        if (line.len + gap + piece.text.len > max) break;
        if (pending_space) append(&line, " ");
        append(&line, piece.text);
        pending_space = false;
    }
    return if (line.len == 0) null else line;
}

/// One repaired scalar of the input: the bytes written for it, its code point, and how far it advances.
const Piece = struct {
    text: []const u8,
    scalar: u21,
};

/// Walks the input one repaired scalar at a time. Each byte that is not part of a valid scalar, and NUL, becomes
/// U+FFFD and advances the walk by exactly one byte.
const Walker = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *Walker) ?Piece {
        if (self.at == self.bytes.len) return null;
        const rest = self.bytes[self.at..];
        const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch return self.invalid();
        if (length > rest.len) return self.invalid();
        const scalar = std.unicode.utf8Decode(rest[0..length]) catch return self.invalid();
        if (scalar == 0) return self.invalid();
        self.at += length;
        return .{ .text = rest[0..length], .scalar = scalar };
    }

    fn invalid(self: *Walker) Piece {
        self.at += 1;
        return .{ .text = replacement, .scalar = replacement_scalar };
    }
};

fn append(bounded: anytype, text: []const u8) void {
    @memcpy(bounded.bytes[bounded.len..][0..text.len], text);
    bounded.len += text.len;
}

/// Line separators and the space characters that a line's words are separated by.
fn isSpace(scalar: u21) bool {
    return switch (scalar) {
        '\n', '\r', '\t', 0x0b, 0x0c, ' ', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn repeat(comptime unit: []const u8, comptime times: usize) *const [unit.len * times]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(10_000);
        var out: [unit.len * times]u8 = undefined;
        for (0..times) |index| @memcpy(out[index * unit.len ..][0..unit.len], unit);
        break :blk out;
    };
    return &done;
}

test "TPR-3 a saved label reads as one tidy line and is never invalid" {
    const cases = comptime [_]struct { saved: []const u8, words: ?[]const u8, short: ?[]const u8 = null, stored: ?[]const u8 = null }{
        .{ .saved = "read src/main.zig", .words = "read src/main.zig" },
        .{ .saved = "  read   src/main.zig\n", .words = "read src/main.zig", .stored = "  read   src/main.zig\n" },
        .{ .saved = "Run tests\nthen lint", .words = "Run tests then lint", .stored = "Run tests\nthen lint" },
        .{ .saved = "\tgrep\r\n\u{2028}pattern\u{2029}", .words = "grep pattern" },
        .{ .saved = "a\u{85}b\u{a0}c\u{3000}\u{3000}d", .words = "a b c d" },
        .{ .saved = "a\x00b", .words = "a\u{fffd}b", .stored = "a\u{fffd}b" },
        .{ .saved = "\xf0\x9f\x98\x80 ok", .words = "\u{1f600} ok", .stored = "\xf0\x9f\x98\x80 ok" },
        .{ .saved = "\xc0\x80\xed\xa0\x80\xf5", .words = "\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}" },
        .{ .saved = "\xf0\x9f\x98", .words = "\u{fffd}\u{fffd}\u{fffd}" },
        .{ .saved = "\xff\xfe", .words = "\u{fffd}\u{fffd}" },
        .{ .saved = "\xe2\x82", .words = "\u{fffd}\u{fffd}" },
        .{ .saved = "x\xc3\xa9\x80y", .words = "x\u{e9}\u{fffd}y" },
        .{ .saved = " \t\n ", .words = null },
        .{ .saved = "", .words = null },
        .{ .saved = repeat("x", 99) ++ " yyy", .words = repeat("x", 99) ++ " yyy", .short = repeat("x", 99) },
        .{ .saved = repeat("x", 199) ++ " yyy", .words = repeat("x", 199), .short = repeat("x", 100) },
        .{ .saved = repeat("x", 300), .words = repeat("x", 200), .short = repeat("x", 100) },
        .{ .saved = repeat("x", 199) ++ "\u{e9}", .words = repeat("x", 199), .short = repeat("x", 100) },
        .{ .saved = repeat("x", 99) ++ "\u{20ac}", .words = repeat("x", 99) ++ "\u{20ac}", .short = repeat("x", 99) },
        .{ .saved = repeat("a ", 150), .words = repeat("a ", 99) ++ "a", .short = repeat("a ", 49) ++ "a" },
    };
    for (cases) |case| {
        const label = SavedLabel.fromColumn(case.saved);
        const stored = label.raw();
        try std.testing.expect(std.unicode.utf8ValidateSlice(stored));
        try std.testing.expect(stored.len <= max_bytes);
        if (case.stored) |expected| try std.testing.expectEqualStrings(expected, stored);
        try std.testing.expectEqual(case.words == null, SavedLabel.of(case.saved) == null);
        try std.testing.expectEqualStrings(stored, SavedLabel.fromColumn(stored).raw());

        inline for (.{ max_bytes, 100 }) |max| {
            const expected = if (max == 100) (case.short orelse case.words) else case.words;
            const shown_line = label.words(max);
            try std.testing.expectEqual(expected == null, shown_line == null);
            if (shown_line) |line| {
                const shown = line.slice();
                try std.testing.expectEqualStrings(expected.?, shown);
                try std.testing.expect(std.unicode.utf8ValidateSlice(shown));
                try std.testing.expect(shown.len <= max);
                try std.testing.expect(shown[0] != ' ' and shown[shown.len - 1] != ' ');
                try std.testing.expect(std.mem.indexOf(u8, shown, "  ") == null);
                try std.testing.expect(std.mem.indexOfAny(u8, shown, "\n\r\t\x0b\x0c") == null);
                try std.testing.expect(std.mem.indexOf(u8, shown, "\xc2\x85") == null);
                try std.testing.expect(std.mem.indexOf(u8, shown, "\xe2\x80\xa8") == null);
                try std.testing.expect(std.mem.indexOf(u8, shown, "\xe2\x80\xa9") == null);

                const again = readWords(max, shown) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(shown, again.slice());
            }
        }
    }
}

test "TPR-3 a label with words is kept even when spaces ahead of them are cut" {
    try std.testing.expect(SavedLabel.of(repeat(" ", 250) ++ "x") != null);
    try std.testing.expect(SavedLabel.of(repeat(" ", 250)) == null);
}

test "TPR-3 every short byte string saves valid, stable and reads as one tidy idempotent line" {
    const alphabet = [_]u8{ 0x00, ' ', '\n', 'a', 0x80, 0xc2, 0x85, 0xc3, 0xa9, 0xe2, 0xf0, 0xff };
    var input: [3]u8 = undefined;
    for (1..input.len + 1) |length| {
        var code: usize = 0;
        while (code < std.math.pow(usize, alphabet.len, length)) : (code += 1) {
            var rest = code;
            for (input[0..length]) |*byte| {
                byte.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            const label = SavedLabel.fromColumn(input[0..length]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(label.raw()));
            try std.testing.expectEqualStrings(label.raw(), SavedLabel.fromColumn(label.raw()).raw());
            inline for (.{ 1, 3, 4, 100 }) |max| {
                const line = readWords(max, input[0..length]);
                try std.testing.expectEqual(line != null, label.words(max) != null);
                if (line) |words| {
                    try std.testing.expect(words.len <= max and std.unicode.utf8ValidateSlice(words.slice()));
                    const again = readWords(max, words.slice()) orelse return error.TestUnexpectedResult;
                    try std.testing.expectEqualStrings(words.slice(), again.slice());
                }
            }
        }
    }
}

/// A stored Session Label as every reader shows it: its words as one tidy line of at most `max_label_bytes`, or null when it has none.
/// Total; the door (`tool_presentation.validLabel`) is where a bad Label is refused, so every read of the stored column goes through here.
pub fn labelWords(stored: ?Bounded(max_label_bytes)) ?Bounded(max_label_bytes) {
    const label = stored orelse return null;
    return readWords(max_label_bytes, label.slice());
}

test "TPR-3 a saved Session Label reads as one line of at most 100 bytes or none" {
    const exact: [max_label_bytes]u8 = @splat('x');
    const long: [150]u8 = @splat('x');
    const words = struct {
        fn of(bytes: []const u8) ?Bounded(max_label_bytes) {
            return labelWords(Bounded(max_label_bytes).from(bytes[0..@min(bytes.len, max_label_bytes)]) catch unreachable);
        }
    }.of;
    try std.testing.expectEqualStrings("Review PR 412", words("Review PR 412").?.slice());
    try std.testing.expectEqualStrings("two lines", words("two\nlines").?.slice());
    try std.testing.expect(words(" ") == null);
    try std.testing.expect(words("") == null);
    try std.testing.expect(labelWords(null) == null);
    try std.testing.expectEqualStrings(&exact, words(&long).?.slice());
}
