const std = @import("std");
const Self = @This();

/// `line` shows an exact value inline, so it also quotes `"` and `\`;
/// `label` is one line of prose, such as a tool call's description, which
/// shows `"` as written since no escape it makes contains one; `multiline`
/// keeps line breaks and tabs.
pub const Mode = enum { line, label, multiline };

/// The most bytes one input byte becomes: an escaped byte is `\xNN`.
pub const max_bytes_per_byte = "\\x00".len;

/// A code point that must never reach a terminal raw: C0, DEL and C1
/// controls act on it, and bidi controls reorder the text the user reads.
pub fn isControl(scalar: u21) bool {
    return controlSpelling(scalar) != null;
}

/// A link the answer renderer shows by its text: OSC 8 carries its address,
/// so a terminal opens it on click and the address is not laid out.
pub const link_open = "\x1b]8;;";
pub const link_end = "\x1b\\";
pub const link_close = link_open ++ link_end;
/// The longest address a link carries; a longer one stays literal text.
pub const max_link_bytes = 2048;

/// An address a terminal may open: http or https with a host, every byte
/// printable ASCII, so it cannot end or extend the OSC 8 sequence it rides in.
pub fn linkTarget(uri: []const u8) bool {
    if (uri.len > max_link_bytes) return false;
    const rest = if (std.ascii.startsWithIgnoreCase(uri, "https://"))
        uri["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(uri, "http://"))
        uri["http://".len..]
    else
        return false;
    if (rest.len == 0 or rest[0] == '/') return false;
    for (uri) |byte| if (byte <= ' ' or byte >= 0x7f) return false;
    return true;
}

test "only a printable http or https address with a host is a link target" {
    for ([_][]const u8{ "https://github.com/a/b", "http://x", "HTTPS://Example.com/?q=(1)#f" }) |uri| try std.testing.expect(linkTarget(uri));
    for ([_][]const u8{ "", "https://", "http:///path", "ftp://x", "javascript:alert(1)", "src/a.zig", "https://a b", "https://a\x1b\\", "https://é", "https://a\x7f" }) |uri| try std.testing.expect(!linkTarget(uri));
    const longest = "https://" ++ @as([max_link_bytes - "https://".len]u8, @splat('a'));
    try std.testing.expect(linkTarget(longest));
    try std.testing.expect(!linkTarget(longest ++ "a"));
}

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

/// Canonical Session IDs contain only six lowercase Crockford characters.
pub fn writeShellSession(out: *std.Io.Writer, value: []const u8, comptime positional: bool) !void {
    try out.writeAll(if (positional) " " else " --session ");
    try out.writeAll(value);
}

test "Session shell selectors use the complete bare ID" {
    inline for (.{ true, false }) |positional| {
        for ([_][]const u8{ "k7m2qx", "09azvw" }) |id| {
            var storage: [64]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            try writeShellSession(&out, id, positional);
            const prefix = if (positional) " " else " --session ";
            try std.testing.expectEqualStrings(prefix, out.buffered()[0..prefix.len]);
            try std.testing.expectEqualStrings(id, out.buffered()[prefix.len..]);
        }
    }
}

fn feedByte(self: *Self, out: *std.Io.Writer, value: u8) !void {
    if (self.utf8_len == 0) {
        if (value < 0x80) {
            if (self.mode != .multiline) {
                switch (value) {
                    '\n' => return out.writeAll("\\n"),
                    '\t' => return out.writeAll("\\t"),
                    '\r' => return out.writeAll("\\r"),
                    else => {},
                }
            }
            if (self.mode != .multiline) {
                if (value == '"' and self.mode == .line) return out.writeAll("\\\"");
                if (value == '\\') return out.writeAll("\\\\");
            }
            if (!isControl(value) or
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
        if (isControl(scalar)) {
            try out.writeAll(escapedControl(scalar));
        } else try out.writeAll(slice);
        self.utf8_len = 0;
    }
}

/// Immutable literal spellings may be borrowed by Window cells through encode.
const byte_spellings = blk: {
    var result: [256][max_bytes_per_byte]u8 = undefined;
    const hex = "0123456789abcdef";
    for (0..256) |byte| result[byte] = .{ '\\', 'x', hex[byte / 16], hex[byte % 16] };
    break :blk result;
};

pub fn escapedByte(value: u8) []const u8 {
    return &byte_spellings[value];
}

const c1_spellings = blk: {
    var result: [32][6]u8 = undefined;
    const hex = "0123456789abcdef";
    for (0..32) |index| result[index] = .{ '\\', 'u', '0', '0', hex[(index + 0x80) / 16], hex[index % 16] };
    break :blk result;
};

/// Requires a control scalar; the spelling stays valid through frame encoding.
pub fn escapedControl(scalar: u21) []const u8 {
    return controlSpelling(scalar).?;
}

fn controlSpelling(scalar: u21) ?[]const u8 {
    if (scalar < 0x20 or scalar == 0x7f) return escapedByte(@intCast(scalar));
    if (scalar >= 0x80 and scalar <= 0x9f) return &c1_spellings[scalar - 0x80];
    inline for (.{ 0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069 }) |control| {
        if (scalar == control) return std.fmt.comptimePrint("\\u{x:0>4}", .{control});
    }
    return null;
}

fn escapeByte(self: *Self, out: *std.Io.Writer, value: u8) !void {
    _ = self;
    try out.writeAll(escapedByte(value));
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

test "a label shows its quotes as written and escapes the rest as a line does" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var text: Self = .{ .mode = .label };
    try text.feed(&output.writer, "Run grep \"a\\b\" \u{202e}\t\x1b");
    try text.finish(&output.writer);
    try std.testing.expectEqualStrings("Run grep \"a\\\\b\" \\u202e\\t\\x1b", output.written());
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

test "TerminalText complete control domain keeps immutable exact spellings and noncontrols literal" {
    var borrowed: [77][]const u8 = undefined;
    var expected: [77][6]u8 = undefined;
    var lengths: [77]usize = undefined;
    var scalars: [77]u21 = undefined;
    var count: usize = 0;
    // Independent accepted policy, including every neighboring noncontrol scalar.
    for (0..0x110000) |value| {
        const scalar: u21 = @intCast(value);
        const protected = value < 0x20 or (value >= 0x7f and value <= 0x9f) or
            value == 0x061c or value == 0x200e or value == 0x200f or
            (value >= 0x202a and value <= 0x202e) or (value >= 0x2066 and value <= 0x2069);
        errdefer std.debug.print("control policy at U+{x}\n", .{value});
        try std.testing.expectEqual(protected, isControl(scalar));
        if (!protected) continue;
        const spelling = if (value < 0x80)
            try std.fmt.bufPrint(&expected[count], "\\x{x:0>2}", .{value})
        else
            try std.fmt.bufPrint(&expected[count], "\\u{x:0>4}", .{value});
        lengths[count] = spelling.len;
        scalars[count] = scalar;
        borrowed[count] = escapedControl(scalar);
        try std.testing.expectEqualStrings(spelling, borrowed[count]);
        count += 1;
    }
    try std.testing.expectEqual(borrowed.len, count);
    // Later spellings and streaming writes cannot overwrite any earlier borrow.
    var bytes: [16]u8 = undefined;
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        var golden: [4]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&golden, "\\x{x:0>2}", .{value}), escapedByte(byte));
        var output = std.Io.Writer.fixed(&bytes);
        var text: Self = .{ .mode = .line };
        try text.feed(&output, &.{byte});
        try text.finish(&output);
    }
    for (borrowed, expected, lengths, scalars) |spelling, golden, len, scalar| {
        try std.testing.expectEqualStrings(golden[0..len], spelling);
        try std.testing.expect(spelling.ptr == escapedControl(scalar).ptr);
    }
}

test "TerminalText every accepted control preserves mode bytes across every UTF-8 feed split" {
    const ranges = [_][2]u21{
        .{ 0x00, 0x1f },     .{ 0x7f, 0x9f },     .{ 0x061c, 0x061c },
        .{ 0x200e, 0x200f }, .{ 0x202a, 0x202e }, .{ 0x2066, 0x2069 },
    };
    for (ranges) |range| {
        for (range[0]..range[1] + 1) |value| {
            const scalar: u21 = @intCast(value);
            var encoded: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(scalar, &encoded);
            inline for (.{ Mode.line, Mode.label, Mode.multiline }) |mode| {
                var golden: [6]u8 = undefined;
                const expected: []const u8 = if (mode == .multiline and (scalar == '\n' or scalar == '\t'))
                    encoded[0..len]
                else if (mode != .multiline and scalar == '\n')
                    "\\n"
                else if (mode != .multiline and scalar == '\t')
                    "\\t"
                else if (mode != .multiline and scalar == '\r')
                    "\\r"
                else if (scalar < 0x80)
                    try std.fmt.bufPrint(&golden, "\\x{x:0>2}", .{value})
                else
                    try std.fmt.bufPrint(&golden, "\\u{x:0>4}", .{value});
                for (0..len + 1) |split| {
                    var bytes: [8]u8 = undefined;
                    var output = std.Io.Writer.fixed(&bytes);
                    var text: Self = .{ .mode = mode };
                    try text.feed(&output, encoded[0..split]);
                    try text.feed(&output, encoded[split..len]);
                    try text.finish(&output);
                    try std.testing.expectEqualStrings(expected, output.buffered());
                }
            }
        }
    }
}

test "TerminalText line label and multiline keep their quote slash and whitespace contracts" {
    const input = "\"\\\n\t\r";
    inline for (.{
        .{ Mode.line, "\\\"\\\\\\n\\t\\r" },
        .{ Mode.label, "\"\\\\\\n\\t\\r" },
        .{ Mode.multiline, "\"\\\n\t\\x0d" },
    }) |case| {
        for (0..input.len + 1) |split| {
            var bytes: [32]u8 = undefined;
            var output = std.Io.Writer.fixed(&bytes);
            var text: Self = .{ .mode = case[0] };
            try text.feed(&output, input[0..split]);
            try text.feed(&output, input[split..]);
            try text.finish(&output);
            try std.testing.expectEqualStrings(case[1], output.buffered());
        }
    }
}
