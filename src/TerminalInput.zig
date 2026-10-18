//! The one terminal byte stream of an invocation. Draft and choice editors
//! receive its decoded events; resetting an editor never resets this parser,
//! its paste provenance or a partially received sequence. Returned text is
//! borrowed only until the next feed or next; consume it immediately.
const std = @import("std");
const vaxis = @import("vaxis");
const Self = @This();

pub const Pending = enum { none, escape, incomplete };
parser: vaxis.Parser = .{},
bytes: [4096]u8 = undefined,
used: usize = 0,
/// Bytes of `bytes` that the returned event consumed; the rest is a retained
/// suffix that `next` decodes once the caller has consumed that event.
consumed: usize = 0,
paste: bool = false,

pub const Report = union(enum) {
    width: vaxis.gwidth.Method,
    /// The terminal reports alternate scroll (mode 1007) present but reset.
    alternate_scroll_reset,
};

/// One decoded unit. Terminal replies are reports, never editor input.
pub const Decoded = union(enum) {
    none,
    /// Malformed input; `line_end` marks an unpasted CR or LF that ends it.
    invalid: struct { line_end: bool },
    report: Report,
    /// `pasted` is the paste provenance when this event began.
    event: struct { event: vaxis.Event, pasted: bool },
};

pub fn pending(self: *const Self) Pending {
    if (self.paste) return .incomplete;
    const used = self.used - self.consumed;
    if (used == 0) return .none;
    return if (used == 1 and self.bytes[self.consumed] == 0x1b) .escape else .incomplete;
}

/// Returns true when the expired input was a lone Escape key.
pub fn expire(self: *Self) !bool {
    switch (self.pending()) {
        .none => return false,
        .escape => {
            self.used = 0;
            self.consumed = 0;
            return true;
        },
        .incomplete => return error.IncompleteTerminalInput,
    }
}

pub fn feed(self: *Self, byte: u8) Decoded {
    self.retire();
    const line_end = !self.paste and (byte == '\r' or byte == '\n');
    // Cancellation is observable even during an incomplete terminal response.
    // Inside marked paste it is data and the editor rejects the control byte.
    if (!self.paste and (byte == 3 or byte == 4 or line_end) and self.used != 0) {
        const escape = self.bytes[0] == 0x1b;
        self.used = 0;
        if (!escape and byte != 3 and byte != 4) return .{ .invalid = .{ .line_end = true } };
    }
    if (self.used == self.bytes.len) {
        self.used = 0;
        return .{ .invalid = .{ .line_end = line_end } };
    }
    self.bytes[self.used] = byte;
    self.used += 1;
    return self.decode(line_end);
}

/// The next event in a suffix the previous event left unconsumed, if any.
/// Callers drain this after each feed, in order, before the next feed.
pub fn next(self: *Self) Decoded {
    if (self.consumed == 0) return .none;
    self.retire();
    return self.decode(false);
}

fn retire(self: *Self) void {
    if (self.consumed == 0) return;
    std.mem.copyForwards(u8, self.bytes[0 .. self.used - self.consumed], self.bytes[self.consumed..self.used]);
    self.used -= self.consumed;
    self.consumed = 0;
}

fn invalid(self: *Self, line_end: bool) Decoded {
    self.used = 0;
    return .{ .invalid = .{ .line_end = line_end } };
}

fn decode(self: *Self, line_end: bool) Decoded {
    while (self.used != 0) {
        const bytes = self.bytes[0..self.used];
        if (bytes.len == 1 and bytes[0] == 0x1b) return .none;
        // Marked paste is literal data, not encoded keys or terminal responses.
        // Let Vaxis consume only its exact end delimiter; rejecting a different
        // ESC prefix must retain paste custody until that delimiter or expiry.
        if (self.paste and bytes[0] == 0x1b and !std.mem.startsWith(u8, "\x1b[201~", bytes)) return self.invalid(line_end);
        // The upstream ground parser expects a complete UTF-8 scalar. Framing this
        // scalar is not a second escape/key decoder; Vaxis owns that interpretation.
        if (bytes[0] >= 0x80) {
            const needed = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return self.invalid(line_end);
            if (bytes.len < needed) return .none;
            _ = std.unicode.utf8Decode(bytes[0..needed]) catch return self.invalid(line_end);
        }
        // An X10 mouse report is ESC [ M plus three payload bytes. The parser
        // needs all six at once; given only the prefix it would consume the
        // prefix and leave the payload as typed text. Payload bytes are 32+.
        if (!self.paste and std.mem.startsWith(u8, bytes, "\x1b[M")) {
            if (bytes.len < 6) return .none;
            for (bytes[3..6]) |payload| if (payload < 32) return self.invalid(line_end);
        }
        // Vaxis's cap_unicode event discards DECRPM's set/reset distinction. Keep
        // the observed facts here; never enable mode 2027 merely for support, and
        // enable mode 1007 only where the terminal reports it reset.
        if (!self.paste and bytes.len == 11 and std.mem.endsWith(u8, bytes, "$y") and bytes[8] >= '0' and bytes[8] <= '4') {
            const status = bytes[8];
            if (std.mem.startsWith(u8, bytes, "\x1b[?2027;")) {
                self.used = 0;
                return .{ .report = .{ .width = if (status == '1' or status == '3') .unicode else .wcwidth } };
            }
            if (std.mem.startsWith(u8, bytes, "\x1b[?1007;")) {
                self.used = 0;
                return if (status == '2') .{ .report = .alternate_scroll_reset } else .none;
            }
        }
        const pasted = self.paste;
        const result = self.parser.parse(bytes, null) catch return self.invalid(line_end);
        if (result.n == 0) return .none;
        // Byte-at-a-time ingress cannot leave a second event behind this one.
        std.debug.assert(result.n == self.used);
        self.used = 0;
        const event = result.event orelse return .none;
        switch (event) {
            .paste_start => self.paste = true,
            .paste_end => self.paste = false,
            else => {},
        }
        return .{ .event = .{ .event = event, .pasted = pasted } };
    }
    return .none;
}

fn testEvent(decoded: Decoded) ?vaxis.Event {
    return switch (decoded) {
        .event => |value| value.event,
        .none => null,
        else => unreachable,
    };
}

test "terminal input owns fragmentation and paste provenance without an event queue" {
    var input: Self = .{};
    for ("\x1b[200~") |byte| _ = input.feed(byte);
    try std.testing.expect(input.paste);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expect(input.feed(0xc3) == .none);
    const decoded = input.feed(0xa9).event;
    try std.testing.expect(decoded.pasted);
    var owned: [2]u8 = undefined;
    @memcpy(&owned, decoded.event.key_press.text.?);
    _ = input.feed('Z');
    try std.testing.expectEqualStrings("é", &owned);
    for ("\x1b[201~") |byte| _ = input.feed(byte);
    try std.testing.expectEqual(Pending.none, input.pending());
    _ = input.feed(0x1b);
    try std.testing.expectEqual(Pending.escape, input.pending());
    try std.testing.expect(try input.expire());
    try std.testing.expectEqual(Pending.none, input.pending());
}

test "terminal input consumes kitty text before parser scratch can be reused" {
    var input: Self = .{};
    var owned: [4]u8 = undefined;
    for ("\x1b[97;1;128512u") |byte| if (testEvent(input.feed(byte))) |event| {
        @memcpy(&owned, event.key_press.text.?);
    };
    for ("\x1b[98;1;90u") |byte| _ = input.feed(byte);
    try std.testing.expectEqualStrings("😀", &owned);
}

test "terminal width reports distinguish enabled mode from mere support" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "\x1b[?2027;{d}$y", .{status});
        for (response[0 .. response.len - 1]) |byte| try std.testing.expect(input.feed(byte) == .none);
        try std.testing.expectEqual(@as(vaxis.gwidth.Method, if (status == 1 or status == 3) .unicode else .wcwidth), input.feed(response[response.len - 1]).report.width);
        try std.testing.expectEqualStrings("x", testEvent(input.feed('x')).?.key_press.text.?);
    }
}

test "alternate scroll is reported only when present and reset" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "\x1b[?1007;{d}$y", .{status});
        for (response[0 .. response.len - 1]) |byte| try std.testing.expect(input.feed(byte) == .none);
        const decoded = input.feed(response[response.len - 1]);
        try std.testing.expectEqual(status == 2, decoded == .report and decoded.report == .alternate_scroll_reset);
        try std.testing.expectEqual(status != 2, decoded == .none);
        try std.testing.expectEqual(Pending.none, input.pending());
    }
}

test "fragmented X10 mouse reports are consumed whole, never as typed text" {
    // ESC [ M plus three payload bytes: the payload " is" must not become text.
    var stream: Self = .{};
    var mice: usize = 0;
    var text: [8]u8 = undefined;
    var length: usize = 0;
    for ("\x1b[M is/exit") |byte| if (testEvent(stream.feed(byte))) |event| switch (event) {
        .mouse => mice += 1,
        .key_press => |key| {
            @memcpy(text[length..][0..key.text.?.len], key.text.?);
            length += key.text.?.len;
        },
        else => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 1), mice);
    try std.testing.expectEqualStrings("/exit", text[0..length]);
    // A malformed payload is invalid input, not an underflowing coordinate.
    var bad: Self = .{};
    for ("\x1b[M") |byte| try std.testing.expect(bad.feed(byte) == .none);
    _ = bad.feed(' ');
    _ = bad.feed(1);
    try std.testing.expectEqual(Decoded{ .invalid = .{ .line_end = false } }, bad.feed('!'));
    try std.testing.expectEqual(Pending.none, bad.pending());
}

test "fragmented APC and oversized associated text preserve the following key" {
    var input: Self = .{};
    for ("\x1b_Greply\x1b") |byte| try std.testing.expect(input.feed(byte) == .none);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expectEqual(@as(?vaxis.Event, .cap_kitty_graphics), testEvent(input.feed('\\')));
    try std.testing.expectEqualStrings("Z", testEvent(input.feed('Z')).?.key_press.text.?);
    for ([_]u8{ 'u', 'A', '~' }) |final| {
        for (0..3) |boundary| {
            var bytes: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try out.writeAll("\x1b[5;1;");
            for (0..31) |_| try out.writeAll("128512:");
            try out.writeAll(if (boundary == 2) "97:97:97:233" else "128512");
            if (boundary == 1) try out.writeAll(":97");
            try out.writeByte(final);
            for (out.buffered()[0 .. out.end - 1]) |byte| try std.testing.expect(input.feed(byte) == .none);
            const event = testEvent(input.feed(final));
            if (boundary == 0) {
                const text = event.?.key_press.text.?;
                try std.testing.expectEqual(@as(usize, 128), text.len);
                for (0..32) |index| try std.testing.expectEqualStrings("😀", text[index * 4 ..][0..4]);
            } else try std.testing.expect(event == null);
            try std.testing.expectEqualStrings("Q", testEvent(input.feed('Q')).?.key_press.text.?);
        }
    }
}
