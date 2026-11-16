//! UTF-8 boundaries and incremental validation.
const std = @import("std");

/// The longest prefix of `bytes` that is valid UTF-8. A valid prefix is
/// whole code points, so it ends at the start of the first one that does not
/// decode: one pass, and a cut at the end drops at most three bytes.
pub fn validPrefix(bytes: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var end: usize = 0;
    while (end < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[end]) catch break;
        if (length > bytes.len - end) break;
        _ = std.unicode.utf8Decode(bytes[end..][0..length]) catch break;
        end += length;
    }
    return bytes[0..end];
}

/// `bytes` without a code point cut at its end, or null when anything other
/// than such a cut (at most three bytes) is invalid.
pub fn wholePrefix(bytes: []const u8) ?[]const u8 {
    const valid = validPrefix(bytes);
    return if (bytes.len - valid.len > 3) null else valid;
}

/// `bytes` without a final code point that its end cuts short. Unlike
/// `wholePrefix` nothing else is checked: other invalid bytes stay. A lead
/// byte is at most three continuation bytes back, so at most four are read.
pub fn completePrefix(bytes: []const u8) []const u8 {
    var start = bytes.len;
    while (start != 0 and bytes.len - start < 4) {
        start -= 1;
        if (bytes[start] & 0xc0 != 0x80) break;
    }
    if (start == bytes.len) return bytes;
    const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes;
    return if (start + length > bytes.len) bytes[0..start] else bytes;
}

/// The start of the code point holding byte `at`, so a cut there keeps whole
/// code points. An `at` at or past the end is returned unchanged.
pub fn scalarStart(bytes: []const u8, at: usize) usize {
    var start = at;
    while (start > 0 and start < bytes.len and bytes[start] & 0xc0 == 0x80) start -= 1;
    return start;
}

pub const State = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    pub fn feed(self: *State, input: []const u8) !void {
        for (input) |byte| {
            if (self.used == 0) {
                if (byte < 0x80) continue;
                self.expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
            }
            self.bytes[self.used] = byte;
            self.used += 1;
            if (self.used == self.expected) {
                _ = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidUtf8;
                self.used = 0;
                self.expected = 0;
            }
        }
    }

    pub fn complete(self: *const State) bool {
        return self.used == 0;
    }
};

test "validPrefix keeps the longest valid prefix" {
    try std.testing.expectEqualStrings("", validPrefix(""));
    try std.testing.expectEqualStrings("ab", validPrefix("ab"));
    try std.testing.expectEqualStrings("a", validPrefix("a\xc3"));
    try std.testing.expectEqualStrings("a\xc3\xa9", validPrefix("a\xc3\xa9\xe2\x80"));
    try std.testing.expectEqualStrings("a", validPrefix("a\xffb"));
    try std.testing.expectEqualStrings("", validPrefix("\xff"));
}

test "validPrefix agrees with the longest validating prefix on every short input" {
    // Lead, continuation and refused bytes at each class boundary: ASCII,
    // continuations, overlong and surrogate leads, the four-byte limit.
    const alphabet = [_]u8{ 'a', 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc2, 0xe0, 0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xff };
    var bytes: [4]u8 = undefined;
    for (0..bytes.len + 1) |len| {
        var combination: usize = 0;
        while (combination < std.math.pow(usize, alphabet.len, len)) : (combination += 1) {
            var rest = combination;
            for (bytes[0..len]) |*byte| {
                byte.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            var longest = len;
            while (!std.unicode.utf8ValidateSlice(bytes[0..longest])) longest -= 1;
            try std.testing.expectEqual(longest, validPrefix(bytes[0..len]).len);
        }
    }
}

test "validPrefix steps back at most three bytes from a cut in valid text" {
    const scalars = "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80";
    const text = scalars ++ scalars ++ scalars;
    for (0..text.len + 1) |end| {
        const kept = validPrefix(text[0..end]).len;
        try std.testing.expect(end - kept <= 3);
        try std.testing.expectEqual(scalarStart(text, end), kept);
    }
    // An early invalid byte ends the prefix there, however long the tail.
    const tail: [4096]u8 = @splat('b');
    const long = "a\xff" ++ tail;
    try std.testing.expectEqualStrings("a", validPrefix(long));
}

test "wholePrefix drops only a cut final code point" {
    try std.testing.expectEqualStrings("a", wholePrefix("a").?);
    try std.testing.expectEqualStrings("a", wholePrefix("a\xf0\x9f\x98").?);
    try std.testing.expectEqualStrings("a", wholePrefix("a\xff\x80\x80").?);
    try std.testing.expectEqual(@as(?[]const u8, null), wholePrefix("a\xff\x80\x80\x80"));
}

test "completePrefix drops only a cut final code point and keeps other bytes" {
    try std.testing.expectEqualStrings("", completePrefix(""));
    try std.testing.expectEqualStrings("ab", completePrefix("ab"));
    try std.testing.expectEqualStrings("a", completePrefix("a\xc3"));
    try std.testing.expectEqualStrings("a", completePrefix("a\xf0\x9f\x98"));
    try std.testing.expectEqualStrings("a\xf0\x9f\x98\x80", completePrefix("a\xf0\x9f\x98\x80"));
    // Not a cut: a stray continuation, a run longer than any code point, an
    // invalid lead and invalid bytes before the end all stay.
    try std.testing.expectEqualStrings("a\x80", completePrefix("a\x80"));
    try std.testing.expectEqualStrings("\x80\x80\x80\x80\x80", completePrefix("\x80\x80\x80\x80\x80"));
    try std.testing.expectEqualStrings("a\xff", completePrefix("a\xff"));
    try std.testing.expectEqualStrings("\xffb", completePrefix("\xffb\xe2\x82"));
}

test "scalarStart steps back to a code point start" {
    const text = "a\xc3\xa9b";
    try std.testing.expectEqual(@as(usize, 0), scalarStart(text, 0));
    try std.testing.expectEqual(@as(usize, 1), scalarStart(text, 1));
    try std.testing.expectEqual(@as(usize, 1), scalarStart(text, 2));
    try std.testing.expectEqual(@as(usize, 3), scalarStart(text, 3));
    try std.testing.expectEqual(@as(usize, 4), scalarStart(text, 4));
    try std.testing.expectEqual(@as(usize, 9), scalarStart(text, 9));
}
