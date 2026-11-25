//! The saved call label: the text a tool call is saved under, and the one line it is shown as. Saving repairs and
//! bounds the text, so every stored label is valid UTF-8 within max_bytes; reading turns it into one tidy line.
//! Both steps walk the bytes through the same Walker, so the saved text and the shown line agree on what a byte means.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub const max_bytes = 200;
pub const fallback_words = "Tool call";

const replacement = "\xef\xbf\xbd";
const replacement_scalar: u21 = 0xfffd;

pub const SavedLabel = struct {
    text: Bounded(max_bytes) = .{},

    /// The label saved for `bytes`: repaired, then cut to at most max_bytes at a scalar boundary.
    /// Null when no words are left, so the caller can use its tool's fixed words instead.
    pub fn of(bytes: []const u8) ?SavedLabel {
        const label = fromColumn(bytes);
        return if (readWords(max_bytes, label.raw()) == null) null else label;
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
    const cases = comptime [_]struct { saved: []const u8, words: ?[]const u8, short: ?[]const u8 = null }{
        .{ .saved = "read src/main.zig", .words = "read src/main.zig" },
        .{ .saved = "  read   src/main.zig\n", .words = "read src/main.zig" },
        .{ .saved = "Run tests\nthen lint", .words = "Run tests then lint" },
        .{ .saved = "\tgrep\r\n\u{2028}pattern\u{2029}", .words = "grep pattern" },
        .{ .saved = "a\u{85}b\u{a0}c\u{3000}\u{3000}d", .words = "a b c d" },
        .{ .saved = "a\x00b", .words = "a\u{fffd}b" },
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
        try std.testing.expectEqual(case.words == null, SavedLabel.of(case.saved) == null);

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
