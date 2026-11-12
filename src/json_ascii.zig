//! Terminal-safe JSON text: one writer that re-spells every DEL and
//! non-ASCII code point of valid JSON text as a `\u` escape. In JSON such
//! bytes occur only inside strings, so the decoded value is unchanged while a
//! terminal receives printable ASCII, whitespace and structure only. Bidi
//! controls, C1 controls and DEL in names, Action proposals or Host replies
//! cannot then reorder or hide surrounding output.
const std = @import("std");

pub const Escaping = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    pending: [4]u8 = undefined,
    pending_len: u3 = 0,
    invalid: bool = false,

    /// The returned value must stay in place while `writer` is used.
    pub fn init(out: *std.Io.Writer, buffer: []u8) Escaping {
        return .{ .out = out, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flush } } };
    }

    /// Flush through to `out` and reject a truncated or invalid sequence.
    pub fn finish(self: *Escaping) !void {
        self.writer.flush() catch |err| if (!self.invalid) return err;
        if (self.invalid or self.pending_len != 0) return error.InvalidUtf8;
    }

    /// Flushing reaches `out` too, so callers keep ordinary flush points.
    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.Io.Writer.defaultFlush(w);
        const self: *Escaping = @alignCast(@fieldParentPtr("writer", w));
        try self.out.flush();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Escaping = @alignCast(@fieldParentPtr("writer", w));
        try self.feed(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.feed(slice);
            n += slice.len;
        }
        for (0..splat) |_| try self.feed(data[data.len - 1]);
        return n + splat * data[data.len - 1].len;
    }

    fn feed(self: *Escaping, bytes: []const u8) std.Io.Writer.Error!void {
        var plain: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (self.pending_len == 0 and byte < 0x7f) continue;
            try self.out.writeAll(bytes[plain..index]);
            plain = index + 1;
            if (self.pending_len == 0 and byte == 0x7f) {
                try self.out.writeAll("\\u007f");
                continue;
            }
            self.pending[self.pending_len] = byte;
            self.pending_len += 1;
            const width = sequenceLength(self.pending[0]) orelse return self.fail();
            if (self.pending_len > 1 and byte & 0xc0 != 0x80) return self.fail();
            if (self.pending_len < width) continue;
            const codepoint = decode(self.pending[0..width]) orelse return self.fail();
            self.pending_len = 0;
            try writeCodepoint(self.out, codepoint);
        }
        try self.out.writeAll(bytes[plain..]);
    }

    fn fail(self: *Escaping) error{WriteFailed} {
        self.invalid = true;
        return error.WriteFailed;
    }
};

fn sequenceLength(lead: u8) ?u3 {
    return switch (lead) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => null,
    };
}

/// Shortest-form scalar values only: no overlong spelling or surrogate.
fn decode(bytes: []const u8) ?u21 {
    var value: u21 = bytes[0] & (@as(u8, 0x7f) >> @intCast(bytes.len));
    for (bytes[1..]) |byte| value = (value << 6) | (byte & 0x3f);
    const minimum: u21 = switch (bytes.len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (value < minimum or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return null;
    return value;
}

fn writeCodepoint(out: *std.Io.Writer, codepoint: u21) !void {
    if (codepoint < 0x10000) return out.print("\\u{x:0>4}", .{codepoint});
    const offset = codepoint - 0x10000;
    try out.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff) });
}

fn escaped(input: []const []const u8, output: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(output);
    var buffer: [3]u8 = undefined;
    var escaping = Escaping.init(&out, &buffer);
    for (input) |piece| escaping.writer.writeAll(piece) catch |err| if (!escaping.invalid) return err;
    try escaping.finish();
    return out.buffered();
}

test "dangerous code points leave as ASCII escapes and decode to the same value" {
    // RLO, CSI (C1), DEL, ESC as already escaped by JSON, a 4-byte scalar
    // split across every window, and ASCII structure that must pass through.
    const value = "a\u{202e}b\u{9b}c\x7fd\x1b雪😀";
    var json: [128]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json);
    try std.json.Stringify.value(.{ .value = value }, .{}, &json_writer);
    const source = json_writer.buffered();
    var output: [256]u8 = undefined;
    for (1..source.len) |split| {
        const result = try escaped(&.{ source[0..split], source[split..] }, &output);
        try std.testing.expectEqualStrings(
            "{\"value\":\"a\\u202eb\\u009bc\\u007fd\\u001b\\u96ea\\ud83d\\ude00\"}",
            result,
        );
        for (result) |byte| try std.testing.expect(byte >= 0x20 and byte < 0x7f);
        const decoded = try std.json.parseFromSlice(struct { value: []const u8 }, std.testing.allocator, result, .{});
        defer decoded.deinit();
        try std.testing.expectEqualStrings(value, decoded.value.value);
    }
}

test "truncated, overlong, surrogate and stray continuation bytes are refused" {
    var output: [64]u8 = undefined;
    for ([_][]const u8{ "\"\xe2\x80", "\"\xc0\xaf\"", "\"\xed\xa0\x80\"", "\"\x80\"", "\"\xe2\x41\x41\"", "\"\xf4\x90\x80\x80\"" }) |source| {
        try std.testing.expectError(error.InvalidUtf8, escaped(&.{source}, &output));
    }
}
