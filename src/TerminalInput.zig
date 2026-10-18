//! One parser owner. Returned text is borrowed only until the next feed;
//! callers consume it immediately, before parsing or overwriting either buffer.
const std = @import("std");
const vaxis = @import("vaxis");
const Self = @This();

pub const Pending = enum { none, escape, incomplete };
parser: vaxis.Parser = .{},
bytes: [4096]u8 = undefined,
used: usize = 0,
paste: bool = false,
/// A mode report consumed by the latest feed, valid until the next feed.
report: ?Report = null,

pub const Report = union(enum) {
    width: vaxis.gwidth.Method,
    /// The terminal reports alternate scroll (mode 1007) present but reset.
    alternate_scroll_reset,
};

pub fn pending(self: *const Self) Pending {
    if (self.paste) return .incomplete;
    if (self.used == 0) return .none;
    return if (self.used == 1 and self.bytes[0] == 0x1b) .escape else .incomplete;
}

/// Returns true when the expired input was a lone Escape key.
pub fn expire(self: *Self) !bool {
    switch (self.pending()) {
        .none => return false,
        .escape => {
            self.used = 0;
            return true;
        },
        .incomplete => return error.IncompleteTerminalInput,
    }
}

pub fn feed(self: *Self, byte: u8) !?vaxis.Event {
    self.report = null;
    // Cancellation is observable even during an incomplete terminal response.
    // Inside marked paste it is data and the editor rejects the control byte.
    if (!self.paste and (byte == 3 or byte == 4 or byte == '\r' or byte == '\n') and self.used != 0) {
        const escape = self.bytes[0] == 0x1b;
        self.used = 0;
        if (!escape and byte != 3 and byte != 4) return error.InvalidTerminalInput;
    }
    if (self.used == self.bytes.len) return error.TerminalSequenceTooLong;
    self.bytes[self.used] = byte;
    self.used += 1;
    if (self.used == 1 and byte == 0x1b) return null;
    // Marked paste is literal data, not encoded keys or terminal responses.
    // Let Vaxis consume only its exact end delimiter; rejecting a different
    // ESC prefix must retain paste custody until that delimiter or expiry.
    if (self.paste and self.bytes[0] == 0x1b and !std.mem.startsWith(u8, "\x1b[201~", self.bytes[0..self.used])) {
        self.used = 0;
        return error.InvalidTerminalInput;
    }
    // The upstream ground parser expects a complete UTF-8 scalar. Framing this
    // scalar is not a second escape/key decoder; Vaxis owns that interpretation.
    if (self.bytes[0] >= 0x80) {
        const needed = std.unicode.utf8ByteSequenceLength(self.bytes[0]) catch {
            self.used = 0;
            return error.InvalidTerminalInput;
        };
        if (self.used < needed) return null;
        _ = std.unicode.utf8Decode(self.bytes[0..needed]) catch {
            self.used = 0;
            return error.InvalidTerminalInput;
        };
    }
    // Vaxis's cap_unicode event discards DECRPM's set/reset distinction. Keep
    // the observed facts here; never enable mode 2027 merely for support, and
    // enable mode 1007 only where the terminal reports it reset.
    const bytes = self.bytes[0..self.used];
    if (!self.paste and bytes.len == 11 and std.mem.endsWith(u8, bytes, "$y") and bytes[8] >= '0' and bytes[8] <= '4') {
        const status = bytes[8];
        if (std.mem.startsWith(u8, bytes, "\x1b[?2027;")) {
            self.report = .{ .width = if (status == '1' or status == '3') .unicode else .wcwidth };
            self.used = 0;
            return null;
        }
        if (std.mem.startsWith(u8, bytes, "\x1b[?1007;")) {
            if (status == '2') self.report = .alternate_scroll_reset;
            self.used = 0;
            return null;
        }
    }
    const result = self.parser.parse(self.bytes[0..self.used], null) catch {
        self.used = 0;
        return error.InvalidTerminalInput;
    };
    if (result.n == 0) return null;
    // Byte-at-a-time ingress cannot leave a second event behind this one.
    std.debug.assert(result.n == self.used);
    self.used = 0;
    if (result.event) |event| switch (event) {
        .paste_start => self.paste = true,
        .paste_end => self.paste = false,
        else => {},
    };
    return result.event;
}

test "terminal input owns fragmentation and paste provenance without an event queue" {
    var input: Self = .{};
    for ("\x1b[200~") |byte| _ = try input.feed(byte);
    try std.testing.expect(input.paste);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expect((try input.feed(0xc3)) == null);
    const event = (try input.feed(0xa9)).?;
    var owned: [2]u8 = undefined;
    @memcpy(&owned, event.key_press.text.?);
    _ = try input.feed('Z');
    try std.testing.expectEqualStrings("é", &owned);
    for ("\x1b[201~") |byte| _ = try input.feed(byte);
    try std.testing.expectEqual(Pending.none, input.pending());
    _ = try input.feed(0x1b);
    try std.testing.expectEqual(Pending.escape, input.pending());
    try std.testing.expect(try input.expire());
    try std.testing.expectEqual(Pending.none, input.pending());
}

test "terminal input consumes kitty text before parser scratch can be reused" {
    var input: Self = .{};
    var owned: [4]u8 = undefined;
    for ("\x1b[97;1;128512u") |byte| if (try input.feed(byte)) |event| {
        @memcpy(&owned, event.key_press.text.?);
    };
    for ("\x1b[98;1;90u") |byte| _ = try input.feed(byte);
    try std.testing.expectEqualStrings("😀", &owned);
}

test "terminal width reports distinguish enabled mode from mere support" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "\x1b[?2027;{d}$y", .{status});
        for (response[0 .. response.len - 1]) |byte| {
            _ = try input.feed(byte);
            try std.testing.expect(input.report == null);
        }
        _ = try input.feed(response[response.len - 1]);
        try std.testing.expectEqual(@as(vaxis.gwidth.Method, if (status == 1 or status == 3) .unicode else .wcwidth), input.report.?.width);
        _ = try input.feed('x');
        try std.testing.expect(input.report == null);
    }
}

test "alternate scroll is reported only when present and reset" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        for (try std.fmt.bufPrint(&buffer, "\x1b[?1007;{d}$y", .{status})) |byte| try std.testing.expect(try input.feed(byte) == null);
        try std.testing.expectEqual(status == 2, input.report != null and input.report.? == .alternate_scroll_reset);
        try std.testing.expectEqual(Pending.none, input.pending());
    }
}

test "fragmented APC and oversized associated text preserve the following key" {
    var input: Self = .{};
    for ("\x1b_Greply\x1b") |byte| try std.testing.expect((try input.feed(byte)) == null);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expectEqual(@as(?vaxis.Event, .cap_kitty_graphics), try input.feed('\\'));
    try std.testing.expectEqualStrings("Z", (try input.feed('Z')).?.key_press.text.?);
    for ([_]u8{ 'u', 'A', '~' }) |final| {
        for (0..3) |boundary| {
            var bytes: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try out.writeAll("\x1b[5;1;");
            for (0..31) |_| try out.writeAll("128512:");
            try out.writeAll(if (boundary == 2) "97:97:97:233" else "128512");
            if (boundary == 1) try out.writeAll(":97");
            try out.writeByte(final);
            for (out.buffered()[0 .. out.end - 1]) |byte| try std.testing.expect((try input.feed(byte)) == null);
            const event = try input.feed(final);
            if (boundary == 0) {
                const text = event.?.key_press.text.?;
                try std.testing.expectEqual(@as(usize, 128), text.len);
                for (0..32) |index| try std.testing.expectEqualStrings("😀", text[index * 4 ..][0..4]);
            } else try std.testing.expect(event == null);
            try std.testing.expectEqualStrings("Q", (try input.feed('Q')).?.key_press.text.?);
        }
    }
}
