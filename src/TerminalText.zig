const std = @import("std");
const Self = @This();

pub const Mode = enum { line, multiline };

mode: Mode,
utf8: [4]u8 = undefined,
utf8_len: usize = 0,
utf8_need: usize = 0,

/// Write untrusted text without terminal controls. A line also quotes bytes
/// that would make an exact command or field ambiguous when displayed inline.
pub fn feed(self: *Self, out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| try self.feedByte(out, byte);
}

pub fn finish(self: *Self, out: *std.Io.Writer) !void {
    for (self.utf8[0..self.utf8_len]) |byte| try self.escapeByte(out, byte);
    self.utf8_len = 0;
}

fn feedByte(self: *Self, out: *std.Io.Writer, value: u8) !void {
    if (self.utf8_len == 0) {
        if (value < 0x80) {
            if (self.mode == .line) {
                switch (value) {
                    '\n' => return out.writeAll("\\n"),
                    '\t' => return out.writeAll("\\t"),
                    '\r' => return out.writeAll("\\r"),
                    else => {},
                }
            }
            if (self.mode == .line) {
                if (value == '"') return out.writeAll("\\\"");
                if (value == '\\') return out.writeAll("\\\\");
            }
            if (value >= 0x20 and value != 0x7f or
                self.mode == .multiline and (value == '\n' or value == '\t'))
            {
                return out.writeAll(&.{value});
            }
            return self.escapeByte(out, value);
        }
        self.utf8_need = std.unicode.utf8ByteSequenceLength(value) catch {
            try self.escapeByte(out, value);
            return;
        };
    } else if (value & 0xc0 != 0x80) {
        try self.finish(out);
        return self.feedByte(out, value);
    }
    self.utf8[self.utf8_len] = value;
    self.utf8_len += 1;
    if (self.utf8_len == self.utf8_need) {
        const slice = self.utf8[0..self.utf8_len];
        const scalar = std.unicode.utf8Decode(slice) catch {
            return self.finish(out);
        };
        if (scalar >= 0x80 and scalar <= 0x9f or scalar == 0x061c or
            scalar >= 0x202a and scalar <= 0x202e or
            scalar >= 0x2066 and scalar <= 0x2069 or
            scalar == 0x200e or scalar == 0x200f)
        {
            var escaped: [12]u8 = undefined;
            try out.writeAll(try std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{scalar}));
        } else try out.writeAll(slice);
        self.utf8_len = 0;
    }
}

fn escapeByte(self: *Self, out: *std.Io.Writer, value: u8) !void {
    _ = self;
    var escaped: [4]u8 = undefined;
    try out.writeAll(try std.fmt.bufPrint(&escaped, "\\x{x:0>2}", .{value}));
}

test "natural Unicode stays readable while controls and ambiguous command bytes remain visible" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var text: Self = .{ .mode = .line };
    const input = "Don’t café \"quoted\" \\u202e" ++ "\xe2\x80\xae\n\t\x1b\xff";
    for (input) |value| try text.feed(&output.writer, &.{value});
    try text.finish(&output.writer);
    try std.testing.expectEqualStrings("Don’t café " ++ "\\\"quoted\\\" " ++ "\\\\u202e\\u202e\\n\\t\\x1b\\xff", output.written());
}
