const std = @import("std");
const Self = @This();

pub const Mode = enum { line, label, multiline };

pub const max_bytes_per_byte = "\\x00".len;

pub fn isControl(scalar: u21) bool {
    return scalar < 0x20 or scalar >= 0x7f and scalar <= 0x9f or
        scalar == 0x061c or scalar == 0x200e or scalar == 0x200f or
        scalar >= 0x202a and scalar <= 0x202e or
        scalar >= 0x2066 and scalar <= 0x2069;
}

pub const link_open = "\x1b]8;;";
pub const link_end = "\x1b\\";
pub const link_close = link_open ++ link_end;
pub const max_link_bytes = 2048;
pub const session_link = "rui-session:";

/// Returns the Session ID of a canonical `rui-session:` destination. This checks
/// form only; whether that Session exists in the current Store is decided when
/// the link is followed.
pub fn sessionTarget(uri: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, session_link)) return null;
    const id = uri[session_link.len..];
    return if (@import("session_id.zig").valid(id)) id else null;
}

pub const user_message_on = "\x1b[202m";
pub const user_message_off = "\x1b[203m";

pub const full_width_on = "\x1b[204m";
pub const full_width_off = "\x1b[205m";

pub const decoration_on = "\x1b[206m";
pub const decoration_off = "\x1b[207m";

pub const body_on = "\x1b[200m";
pub const body_off = "\x1b[201m";
pub fn writeBody(sink: anytype, bytes: []const u8) !void {
    if (comptime std.meta.hasMethod(@TypeOf(sink), "body")) {
        try sink.body(bytes);
    } else try sink.feed(bytes);
}

pub const clipboard_limit = 100_000 / 4 * 3;

pub const clipboard_too_large = "Too large for the clipboard · /copy file";

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

pub fn feed(self: *Self, out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| try self.feedByte(out, byte);
}

pub fn finish(self: *Self, out: *std.Io.Writer) !void {
    for (self.utf8[0..self.utf8_len]) |byte| try escapeByte(out, byte);
    self.utf8_len = 0;
}

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
                if (value == '"' and self.mode == .line) return out.writeAll("\\\"");
                if (value == '\\') return out.writeAll("\\\\");
            }
            if (!isControl(value) or
                self.mode == .multiline and (value == '\n' or value == '\t'))
            {
                return out.writeAll(&.{value});
            }
            return escapeByte(out, value);
        }
        self.utf8_need = std.unicode.utf8ByteSequenceLength(value) catch {
            try escapeByte(out, value);
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
            var escaped: [12]u8 = undefined;
            try out.writeAll(try std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{scalar}));
        } else try out.writeAll(slice);
        self.utf8_len = 0;
    }
}

fn escapeByte(out: *std.Io.Writer, value: u8) !void {
    var escaped: [max_bytes_per_byte]u8 = undefined;
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
