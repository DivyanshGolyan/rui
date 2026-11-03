//! One option value as `/configure`, `/setup` and a new Session's start
//! options read it back.
const std = @import("std");

/// Bare when it reads back as itself, else in double quotes with `"` and `\`
/// escaped.
pub fn write(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    if (value.len != 0 and std.mem.indexOfAny(u8, value, " \"\\") == null) return writer.writeAll(value);
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

test "a value is bare unless a space, quote or backslash needs quoting" {
    var bytes: [64]u8 = undefined;
    for ([_][2][]const u8{
        .{ "lane", "lane" },
        .{ "", "\"\"" },
        .{ "lane four", "\"lane four\"" },
        .{ "a\"b\\", "\"a\\\"b\\\\\"" },
    }) |case| {
        var out = std.Io.Writer.fixed(&bytes);
        try write(&out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.buffered());
    }
}
