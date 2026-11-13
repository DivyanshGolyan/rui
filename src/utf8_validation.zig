//! UTF-8 boundaries and incremental validation.
const std = @import("std");

/// The longest prefix of `bytes` that is valid UTF-8. The empty prefix is
/// always valid, so the result never underflows.
pub fn validPrefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (!std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

/// `bytes` without a code point cut at its end, or null when anything other
/// than such a cut (at most three bytes) is invalid.
pub fn wholePrefix(bytes: []const u8) ?[]const u8 {
    const valid = validPrefix(bytes);
    return if (bytes.len - valid.len > 3) null else valid;
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

test "wholePrefix drops only a cut final code point" {
    try std.testing.expectEqualStrings("a", wholePrefix("a").?);
    try std.testing.expectEqualStrings("a", wholePrefix("a\xf0\x9f\x98").?);
    try std.testing.expectEqualStrings("a", wholePrefix("a\xff\x80\x80").?);
    try std.testing.expectEqual(@as(?[]const u8, null), wholePrefix("a\xff\x80\x80\x80"));
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
