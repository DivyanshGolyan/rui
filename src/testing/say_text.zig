//! Test helpers that compare a notice as the footer draws it: its sign for attention, then its words.
const std = @import("std");
const Say = @import("../marks.zig").Say;

/// `expected` is the line as the footer draws it, sign included, spelled out or given as a Say.
pub fn expect(expected: anytype, said: Say) !void {
    var want_buffer: [2048]u8 = undefined;
    var shown_buffer: [2048]u8 = undefined;
    const want: []const u8 = if (@TypeOf(expected) == Say) try drawn(&want_buffer, expected) else expected;
    try std.testing.expectEqualStrings(want, try drawn(&shown_buffer, said));
}

fn drawn(buffer: []u8, said: Say) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ said.sign(), said.words }) catch error.TestNoticeTooLong;
}

pub fn expectOptional(expected: ?[]const u8, said: ?Say) !void {
    try std.testing.expectEqual(expected == null, said == null);
    if (expected) |text| try expect(text, said.?);
}

test "a notice is compared as drawn: attention carries its sign and quiet carries none" {
    try expect("! Busy", Say.attention("Busy"));
    try expect("Busy", Say.quiet("Busy"));
    try expectOptional(null, null);
}
