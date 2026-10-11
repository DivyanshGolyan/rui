const std = @import("std");
const stderr = @import("stderr.zig");
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

/// Bash ANSI-C quoting preserves NUL-free argv values without terminal controls.
pub fn writeShellWord(out: *std.Io.Writer, value: []const u8) !void {
    try out.writeAll("$'");
    for (value) |byte| switch (byte) {
        '\'' => try out.writeAll("\\'"),
        '\\' => try out.writeAll("\\\\"),
        32...38, 40...91, 93...126 => try out.writeByte(byte),
        else => try out.print("\\{o:0>3}", .{byte}),
    };
    try out.writeByte('\'');
}

/// Opaque Sessions may contain NUL, which no shell can transmit in argv.
pub fn writeShellSession(out: *std.Io.Writer, value: []const u8, comptime positional: bool) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) {
        try out.print(" --session-hex {x}", .{value});
    } else {
        try out.writeAll(if (positional) " -- " else " --session ");
        try writeShellWord(out, value);
    }
}

test "opaque Session shell selectors preserve NUL position and maximum length" {
    inline for (.{ true, false }) |positional| {
        for ([_]struct { value: []const u8, hex: []const u8 }{
            .{ .value = "\x00", .hex = "00" },
            .{ .value = "\x00A", .hex = "0041" },
            .{ .value = "A\x00Z", .hex = "41005a" },
            .{ .value = "A\x00", .hex = "4100" },
            .{ .value = "\x00" ** 128, .hex = "00" ** 128 },
        }) |case| {
            var storage: [288]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            try writeShellSession(&out, case.value, positional);
            try std.testing.expectEqualStrings(" --session-hex ", out.buffered()[0..15]);
            try std.testing.expectEqualStrings(case.hex, out.buffered()[15..]);
        }
        var storage: [64]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try writeShellSession(&out, "--last", positional);
        try std.testing.expectEqualStrings(if (positional) " -- $'--last'" else " --session $'--last'", out.buffered());
    }
}

/// Optional fatal guidance cannot retain a restored caller on stderr credit.
/// One bounded write is best-effort; its failure never replaces the real error.
pub fn diagnostic(comptime format: []const u8, args: anytype) void {
    // The preceding transcript may end mid-line, including a partial command.
    stderr.print("\n" ++ format, args);
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

test "TerminalText line bytes are independent of chunk boundaries and incomplete UTF-8 stays visible" {
    const cases = .{
        .{ "Aé🙂Z\x00\x1f\x7f\xc2\x85\xe2\x81\xa6", "Aé🙂Z\\x00\\x1f\\x7f\\u0085\\u2066" },
        .{ "\xe2\x82X\xf0\x80\x80\x80\xc3", "\\xe2\\x82X\\xf0\\x80\\x80\\x80\\xc3" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var output = std.Io.Writer.Allocating.init(std.testing.allocator);
            defer output.deinit();
            var text: Self = .{ .mode = .line };
            try text.feed(&output.writer, case[0][0..split]);
            try text.feed(&output.writer, case[0][split..]);
            try text.finish(&output.writer);
            try text.finish(&output.writer);
            try std.testing.expectEqualStrings(case[1], output.written());
        }
    }
}

test "TerminalText propagates output failure during feed and incomplete-byte finish" {
    var bytes: [3]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var text: Self = .{ .mode = .line };
    try std.testing.expectError(error.WriteFailed, text.feed(&output, "\x1b"));

    output = std.Io.Writer.fixed(&bytes);
    text = .{ .mode = .line };
    try text.feed(&output, "\xe2");
    try std.testing.expectError(error.WriteFailed, text.finish(&output));
}
