//! The one terminal byte stream of an invocation. Draft and choice editors
//! receive its decoded events; resetting an editor never resets this parser,
//! its paste provenance or a partially received sequence. Returned text is
//! borrowed only until the next feed or next; consume it immediately. Its
//! readers own terminal reads; this stream owns when pending input expires.
const std = @import("std");
const vaxis = @import("vaxis");
const Self = @This();

pub const Pending = enum { none, escape, incomplete };
/// Inactivity limits after the last byte. A bare ESC may be the Escape key
/// itself; other incomplete input is a sequence, scalar or marked paste that
/// the terminal is still sending.
const escape_limit: i96 = 80 * std.time.ns_per_ms;
const incomplete_limit: i96 = 2 * std.time.ns_per_s;

parser: vaxis.Parser = .{},
/// Monotonic time at which the reader observed the last fed byte.
observed_at: i96 = 0,
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
    const rest = self.bytes[self.consumed..self.used];
    return if (std.mem.eql(u8, rest, "\x1b") or std.mem.eql(u8, rest, "\x1b\x1b")) .escape else .incomplete;
}

/// A reader's next step at monotonic time `now`, waiting at most `budget`
/// milliseconds (negative: without limit). Pending input expires as soon as
/// its deadline passes, before another byte is read: an Esc left alone past
/// its limit stays Esc even when the next key is already queued behind it.
pub const Wait = union(enum) { expire, poll: i32 };

pub fn wait(self: *const Self, now: i96, budget: i32) Wait {
    const limit = switch (self.pending()) {
        .none => return .{ .poll = budget },
        .escape => escape_limit,
        .incomplete => incomplete_limit,
    };
    const remaining = self.observed_at + limit - now;
    if (remaining <= 0) return .expire;
    // Round up: a poll that returns early would only wait again.
    const milliseconds: i32 = @intCast(@min(@divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    return .{ .poll = if (budget < 0) milliseconds else @min(budget, milliseconds) };
}

/// Called when `wait` says so. Returns true when the expired input was a lone
/// Escape key; anything else incomplete ends the caller's input.
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

/// One byte the reader observed at monotonic time `at`.
pub fn feed(self: *Self, byte: u8, at: i96) Decoded {
    self.observed_at = at;
    self.retire();
    const line_end = !self.paste and (byte == '\r' or byte == '\n');
    // Cancellation is observable even during an incomplete terminal response.
    // Inside marked paste it is data and the editor rejects the control byte.
    // A lone ESC before a line end is Alt-Enter: one chord for the editor to
    // judge, never a pending prefix to discard before an ordinary Enter.
    if (!self.paste and (byte == 3 or byte == 4 or line_end) and self.used != 0 and !(line_end and self.pending() == .escape)) {
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

/// Malformed input without a trustworthy end: discard every pending byte.
fn invalid(self: *Self, line_end: bool) Decoded {
    self.used = 0;
    return .{ .invalid = .{ .line_end = line_end } };
}

/// A malformed frame of `n` bytes: reject it and decode what follows it.
fn invalidFrame(self: *Self, n: usize, line_end: bool) Decoded {
    if (n == self.used) self.used = 0 else self.consumed = n;
    return .{ .invalid = .{ .line_end = line_end } };
}

/// ESC before a key that starts no sequence is Alt on that key, decoded as
/// it would be alone: ESC ^H is Alt-Backspace and ESC é one Alt chord, never
/// a raw byte or a split scalar. ESC ESC is Esc, and the second ESC begins
/// whatever follows, so an Esc just before a paste or an arrow keeps it whole.
fn alt(self: *Self, bytes: []const u8, line_end: bool) Decoded {
    var key: vaxis.Key = .{ .codepoint = vaxis.Key.escape };
    var n: usize = 1;
    if (bytes[1] == 0x1b) {
        if (bytes.len == 2) return .none;
    } else {
        if (bytes[1] >= 0x80) {
            const needed = std.unicode.utf8ByteSequenceLength(bytes[1]) catch return self.invalid(line_end);
            if (bytes.len < 1 + needed) return .none;
            _ = std.unicode.utf8Decode(bytes[1 .. 1 + needed]) catch return self.invalid(line_end);
        }
        const result = self.parser.parse(bytes[1..], null) catch return self.invalid(line_end);
        key = switch (result.event orelse return self.invalid(line_end)) {
            .key_press => |value| value,
            else => return self.invalid(line_end),
        };
        // The terminal keeps ICRNL, so LF is Enter: ESC CR arrives as ESC LF.
        if (key.matchExact('j', .{ .ctrl = true })) key = .{ .codepoint = vaxis.Key.enter };
        key.mods.alt = true;
        key.text = null;
        n += result.n;
    }
    if (n == self.used) self.used = 0 else self.consumed = n;
    return .{ .event = .{ .event = .{ .key_press = key }, .pasted = false } };
}

fn decode(self: *Self, line_end: bool) Decoded {
    while (self.used != 0) {
        const bytes = self.bytes[0..self.used];
        if (bytes.len == 1 and bytes[0] == 0x1b) return .none;
        // Marked paste is literal data, not encoded keys or terminal responses.
        // Let Vaxis consume only its exact end delimiter. Any other ESC rejects
        // the paste, which keeps custody until that delimiter or expiry; the
        // bytes after this ESC may begin it, as in ESC ESC [201~.
        if (self.paste and bytes[0] == 0x1b and !std.mem.startsWith(u8, "\x1b[201~", bytes)) return self.invalidFrame(1, line_end);
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
        if (!self.paste and bytes[0] == 0x1b and bytes.len >= 2 and std.mem.indexOfScalar(u8, "OPX[]^_", bytes[1]) == null) {
            return self.alt(bytes, line_end);
        }
        const pasted = self.paste;
        const result = self.parser.parse(bytes, null) catch return self.invalid(line_end);
        if (result.n == 0) return .none;
        // A malformed key the user pressed rejects the attempt. Ignoring it
        // would let text typed around it, such as a choice, stand as entered.
        if (result.invalid) return self.invalidFrame(result.n, line_end);
        const event = result.event orelse {
            // A consumed reply or an interrupted sequence's prefix (an OSC cut
            // by a new ESC). Keep the unconsumed suffix and decode it now.
            std.mem.copyForwards(u8, self.bytes[0 .. self.used - result.n], self.bytes[result.n..self.used]);
            self.used -= result.n;
            continue;
        };
        // The event's text may borrow these bytes: retire them only on the
        // next feed or next, after the caller consumed it.
        if (result.n == self.used) self.used = 0 else self.consumed = result.n;
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
    for ("\x1b[200~") |byte| _ = input.feed(byte, 0);
    try std.testing.expect(input.paste);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expect(input.feed(0xc3, 0) == .none);
    const decoded = input.feed(0xa9, 0).event;
    try std.testing.expect(decoded.pasted);
    var owned: [2]u8 = undefined;
    @memcpy(&owned, decoded.event.key_press.text.?);
    _ = input.feed('Z', 0);
    try std.testing.expectEqualStrings("é", &owned);
    for ("\x1b[201~") |byte| _ = input.feed(byte, 0);
    try std.testing.expectEqual(Pending.none, input.pending());
    _ = input.feed(0x1b, 0);
    try std.testing.expectEqual(Pending.escape, input.pending());
    try std.testing.expect(try input.expire());
    try std.testing.expectEqual(Pending.none, input.pending());
}

test "a held ESC ESC expires as one Esc" {
    var input: Self = .{};
    try std.testing.expect(input.feed(0x1b, 0) == .none);
    try std.testing.expect(input.feed(0x1b, 0) == .none);
    try std.testing.expectEqual(Pending.escape, input.pending());
    try std.testing.expect(try input.expire());
    try std.testing.expectEqual(Pending.none, input.pending());
}

test "terminal input consumes kitty text before parser scratch can be reused" {
    var input: Self = .{};
    var owned: [4]u8 = undefined;
    for ("\x1b[97;1;128512u") |byte| if (testEvent(input.feed(byte, 0))) |event| {
        @memcpy(&owned, event.key_press.text.?);
    };
    for ("\x1b[98;1;90u") |byte| _ = input.feed(byte, 0);
    try std.testing.expectEqualStrings("😀", &owned);
}

test "terminal width reports distinguish enabled mode from mere support" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "\x1b[?2027;{d}$y", .{status});
        for (response[0 .. response.len - 1]) |byte| try std.testing.expect(input.feed(byte, 0) == .none);
        try std.testing.expectEqual(@as(vaxis.gwidth.Method, if (status == 1 or status == 3) .unicode else .wcwidth), input.feed(response[response.len - 1], 0).report.width);
        try std.testing.expectEqualStrings("x", testEvent(input.feed('x', 0)).?.key_press.text.?);
    }
}

test "alternate scroll is reported only when present and reset" {
    for (0..5) |status| {
        var input: Self = .{};
        var buffer: [32]u8 = undefined;
        const response = try std.fmt.bufPrint(&buffer, "\x1b[?1007;{d}$y", .{status});
        for (response[0 .. response.len - 1]) |byte| try std.testing.expect(input.feed(byte, 0) == .none);
        const decoded = input.feed(response[response.len - 1], 0);
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
    for ("\x1b[M is/exit") |byte| if (testEvent(stream.feed(byte, 0))) |event| switch (event) {
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
    for ("\x1b[M") |byte| try std.testing.expect(bad.feed(byte, 0) == .none);
    _ = bad.feed(' ', 0);
    _ = bad.feed(1, 0);
    try std.testing.expectEqual(Decoded{ .invalid = .{ .line_end = false } }, bad.feed('!', 0));
    try std.testing.expectEqual(Pending.none, bad.pending());
}

test "an interrupted OSC keeps the following sequence and key" {
    // The parser consumes only the unterminated OSC prefix when a new ESC
    // begins; the suffix is the next key, decoded in the same feed or by next.
    for ([_]struct { bytes: []const u8, key: u21, alt: bool }{
        .{ .bytes = "\x1b]0;title\x1b[A", .key = vaxis.Key.up, .alt = false },
        .{ .bytes = "\x1b]0;title\x1bx", .key = 'x', .alt = true },
    }) |case| {
        var input: Self = .{};
        var found: ?vaxis.Key = null;
        for (case.bytes) |byte| {
            var decoded = input.feed(byte, 0);
            while (decoded != .none) : (decoded = input.next()) {
                try std.testing.expect(found == null);
                found = decoded.event.event.key_press;
            }
        }
        try std.testing.expect(found.?.matches(case.key, .{ .alt = case.alt }));
        try std.testing.expectEqual(Pending.none, input.pending());
        try std.testing.expectEqualStrings("q", testEvent(input.feed('q', 0)).?.key_press.text.?);
    }
}

test "fragmented APC and oversized associated text keep the following key" {
    var input: Self = .{};
    for ("\x1b_Greply\x1b") |byte| try std.testing.expect(input.feed(byte, 0) == .none);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expectEqual(@as(?vaxis.Event, .cap_kitty_graphics), testEvent(input.feed('\\', 0)));
    try std.testing.expectEqualStrings("Z", testEvent(input.feed('Z', 0)).?.key_press.text.?);
    for ([_]u8{ 'u', 'A', '~' }) |final| {
        for (0..3) |boundary| {
            var bytes: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&bytes);
            try out.writeAll("\x1b[1;1;");
            for (0..31) |_| try out.writeAll("128512:");
            try out.writeAll(if (boundary == 2) "97:97:97:233" else "128512");
            if (boundary == 1) try out.writeAll(":97");
            try out.writeByte(final);
            for (out.buffered()[0 .. out.end - 1]) |byte| try std.testing.expect(input.feed(byte, 0) == .none);
            const decoded = input.feed(final, 0);
            if (boundary == 0) {
                const text = testEvent(decoded).?.key_press.text.?;
                try std.testing.expectEqual(@as(usize, 128), text.len);
                for (0..32) |index| try std.testing.expectEqualStrings("😀", text[index * 4 ..][0..4]);
            } else try std.testing.expectEqual(Decoded{ .invalid = .{ .line_end = false } }, decoded);
            try std.testing.expectEqualStrings("Q", testEvent(input.feed('Q', 0)).?.key_press.text.?);
        }
    }
}

test "malformed keyboard values fail closed on every supported route; unknown keys stay ignored" {
    // Each malformed sequence is consumed whole, so the next byte is a key.
    for ([_][]const u8{
        // Kitty CSI u: modifier outside 1..256, event type outside 1..3,
        // signs, extra fields, scalars outside Unicode, malformed text.
        "\x1b[97;0u",      "\x1b[97;257u",       "\x1b[97;65536u",     "\x1b[97;+1u",
        "\x1b[97;1:0u",    "\x1b[97;1:4u",       "\x1b[97;1:3:1u",     "\x1b[97;1;97;1u",
        "\x1b[1114112u",   "\x1b[55296u",        "\x1b[97:=;1u",       "\x1b[97:65:1114112u",
        "\x1b[97::98:99u", "\x1b[97;1;1114112u", "\x1b[97;1;u",        "\x1b[97;1;98:u",
        "\x1b[13;0u",      "\x1b[114;999u",
        // CSI letter and CSI tilde keys with the same fields.
             "\x1b[1;0A",          "\x1b[1;257A",
        "\x1b[1;2:4A",     "\x1b[1;1;1114112A",  "\x1b[1;1;97;1A",     "\x1b[5;0~",
        "\x1b[5;257~",     "\x1b[5;1:9~",        "\x1b[5;1;55296~",
        // The key number field: signed, alternate or other than 1 on a letter key.
           "\x1b[+11;1~",
        "\x1b[1:999;1P",   "\x1b[2;5A",          "\x1b[+27;1;13~",
        // xterm modifyOtherKeys: modifier 1..16 and a Unicode scalar code.
            "\x1b[27;0;97~",
        "\x1b[27;17;97~",  "\x1b[27;2~",         "\x1b[27;2;1114112~",
    }) |sequence| {
        errdefer std.debug.print("sequence {any}\n", .{sequence});
        var input: Self = .{};
        for (sequence[0 .. sequence.len - 1]) |byte| try std.testing.expect(input.feed(byte, 0) == .none);
        try std.testing.expectEqual(Decoded{ .invalid = .{ .line_end = false } }, input.feed(sequence[sequence.len - 1], 0));
        try std.testing.expectEqual(Pending.none, input.pending());
        try std.testing.expectEqualStrings("Q", testEvent(input.feed('Q', 0)).?.key_press.text.?);
    }
    const all: vaxis.Key.Modifiers = @bitCast(@as(u8, 255));
    for ([_]struct { bytes: []const u8, key: u21, mods: vaxis.Key.Modifiers, release: bool = false }{
        // The protocol's whole range and its defaults remain keys.
        .{ .bytes = "\x1b[97;256u", .key = 'a', .mods = all },
        .{ .bytes = "\x1b[97;255u", .key = 'a', .mods = @bitCast(@as(u8, 254)) },
        .{ .bytes = "\x1b[97;1u", .key = 'a', .mods = .{} },
        .{ .bytes = "\x1b[97;u", .key = 'a', .mods = .{} },
        .{ .bytes = "\x1b[97;5:u", .key = 'a', .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[97;5:2u", .key = 'a', .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[97;5:3u", .key = 'a', .mods = .{ .ctrl = true }, .release = true },
        .{ .bytes = "\x1b[97:65:97;2u", .key = 'a', .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[97::97;5u", .key = 'a', .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[1;256A", .key = vaxis.Key.up, .mods = all },
        .{ .bytes = "\x1b[;5A", .key = vaxis.Key.up, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[1;5R", .key = vaxis.Key.f3, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[5;256~", .key = vaxis.Key.page_up, .mods = all },
        .{ .bytes = "\x1b[27;1;97~", .key = 'a', .mods = .{} },
        .{ .bytes = "\x1b[27;16;97~", .key = 'a', .mods = @bitCast(@as(u8, 15)) },
    }) |case| {
        errdefer std.debug.print("sequence {any}\n", .{case.bytes});
        var input: Self = .{};
        var found: ?vaxis.Event = null;
        for (case.bytes) |byte| if (testEvent(input.feed(byte, 0))) |event| {
            found = event;
        };
        const key = if (case.release) found.?.key_release else found.?.key_press;
        try std.testing.expectEqual(case.key, key.codepoint);
        try std.testing.expectEqual(case.mods, key.mods);
    }
    // Keys this parser does not know, private reports and an unrequested
    // cursor position report are still ignored, keeping what follows.
    // A private marker means not a key on every route, so one terminal
    // setting (xterm modifyCursorKeys/modifyFunctionKeys 3) is ignored alike.
    for ([_][]const u8{ "\x1b[123;4~", "\x1b[27~", "\x1b[99999~", "\x1b[?1~", "\x1b[>5;5~", "\x1b[>1;5A", "\x1b[?1;0;256S", "\x1b[>1;2u", "\x1b[=1u", "\x1b[<1u", "\x1b[5;10R", "\x1b[?5;10;1R" }) |sequence| {
        var input: Self = .{};
        for (sequence) |byte| try std.testing.expect(input.feed(byte, 0) == .none);
        try std.testing.expectEqualStrings("Q", testEvent(input.feed('Q', 0)).?.key_press.text.?);
    }
}

test "an ESC inside marked paste rejects it, and an end marker right after still ends it" {
    for ([_][]const u8{ "\x1b\x1b[201~", "\x1b\x1b\x1b[201~", "\x1bx\x1b[201~", "\x1b[20\x1b[201~" }) |tail| {
        errdefer std.debug.print("tail {any}\n", .{tail});
        var input: Self = .{};
        var rejected = false;
        var ended = false;
        for ("\x1b[200~left") |byte| _ = input.feed(byte, 0);
        for (tail) |byte| {
            var decoded = input.feed(byte, 0);
            while (decoded != .none) : (decoded = input.next()) switch (decoded) {
                .invalid => |value| {
                    try std.testing.expect(!value.line_end and !ended);
                    rejected = true;
                },
                .event => |value| switch (value.event) {
                    .paste_end => ended = true,
                    // Text between them is still pasted data, never keys.
                    else => try std.testing.expect(value.pasted and !ended),
                },
                else => unreachable,
            };
        }
        try std.testing.expect(rejected and ended);
        try std.testing.expectEqual(Pending.none, input.pending());
        // The next typed key is the user's again.
        const after = input.feed('Z', 0).event;
        try std.testing.expect(!after.pasted);
        try std.testing.expectEqualStrings("Z", after.event.key_press.text.?);
    }
}

test "pending input expires at its inactivity limit after the last byte, before more is read" {
    var input: Self = .{};
    // Nothing pending: only the caller's budget limits a wait.
    try std.testing.expectEqual(Wait{ .poll = -1 }, input.wait(5, -1));
    try std.testing.expectEqual(Wait{ .poll = 16 }, input.wait(5, 16));
    const start: i96 = 1_000 * std.time.ns_per_s;
    _ = input.feed(0x1b, start);
    try std.testing.expectEqual(Wait{ .poll = 80 }, input.wait(start, -1));
    try std.testing.expectEqual(Wait{ .poll = 16 }, input.wait(start, 16));
    try std.testing.expectEqual(Wait{ .poll = 0 }, input.wait(start, 0));
    // Rounded up, never polling short of the deadline and then waiting again.
    try std.testing.expectEqual(Wait{ .poll = 1 }, input.wait(start + 80 * std.time.ns_per_ms - 1, -1));
    try std.testing.expectEqual(Wait{ .poll = 2 }, input.wait(start + 78 * std.time.ns_per_ms + 1, 16));
    try std.testing.expectEqual(Wait.expire, input.wait(start + 80 * std.time.ns_per_ms, 16));
    // A byte that keeps the input incomplete restarts the clock with the
    // longer limit; an empty open paste stays pending under it too.
    _ = input.feed('[', start + 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(Pending.incomplete, input.pending());
    try std.testing.expectEqual(Wait{ .poll = 2000 }, input.wait(start + 50 * std.time.ns_per_ms, -1));
    try std.testing.expectEqual(Wait.expire, input.wait(start + 2050 * std.time.ns_per_ms, -1));
    for ("200~") |byte| _ = input.feed(byte, start + 3 * std.time.ns_per_s);
    try std.testing.expect(input.paste);
    try std.testing.expectEqual(Wait{ .poll = 1000 }, input.wait(start + 4 * std.time.ns_per_s, -1));
    try std.testing.expectEqual(Wait.expire, input.wait(start + 5 * std.time.ns_per_s, -1));
    try std.testing.expectError(error.IncompleteTerminalInput, input.expire());
}
