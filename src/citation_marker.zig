//! Provider citation markers inside answer text.
//!
//! The ChatGPT route's models write a web citation into the answer as private-use scalars around
//! ASCII ids: U+E200 `cite` (U+E202 id)+ U+E201, for example
//! `\u{e200}cite\u{e202}turn0search0\u{e202}turn0search1\u{e201}`. The Session transcript keeps
//! that text exactly as the provider sent it, annotations included; the marker is a reference
//! the model addressed to a client, so a view that draws the answer leaves it out. Only a complete
//! marker is removed; any other text, including an unfinished marker, is drawn unchanged.
//! The filter works on bytes, so it needs no valid UTF-8 and cannot fail.

const std = @import("std");

const separator = "\xee\x88\x82";
const close = "\xee\x88\x81";
const lead = "\xee\x88\x80cite" ++ separator;

/// A marker holds at most this many bytes before its closer; a longer run stays text.
pub const max_held = 256;

const Step = enum { pass, keep, drop, reject };

/// What one byte does to the filter: the state it leaves behind and how the byte is handled.
const Move = struct { next: State, step: Step };
const reject_move: Move = .{ .next = .idle, .step = .reject };

const State = enum {
    idle,
    lead,
    id_start,
    id,
    mark_1,
    mark_2,

    /// The one decision table for a marker. `held` counts the marker bytes already scanned; a
    /// marker that reaches `max_held` bytes without its closer is rejected at its next byte.
    inline fn move(self: State, byte: u8, held: usize) Move {
        if (self != .idle and held == max_held) return reject_move;
        return switch (self) {
            .idle => if (byte != lead[0]) .{ .next = .idle, .step = .pass } else .{ .next = .lead, .step = .keep },
            .lead => if (byte != lead[held]) reject_move else .{ .next = if (held + 1 == lead.len) .id_start else .lead, .step = .keep },
            .id_start => if (!idByte(byte)) reject_move else .{ .next = .id, .step = .keep },
            .id => if (idByte(byte)) .{ .next = .id, .step = .keep } else if (byte != separator[0]) reject_move else .{ .next = .mark_1, .step = .keep },
            .mark_1 => if (byte != separator[1]) reject_move else .{ .next = .mark_2, .step = .keep },
            .mark_2 => if (byte == separator[2]) .{ .next = .id_start, .step = .keep } else if (byte != close[2]) reject_move else .{ .next = .idle, .step = .drop },
        };
    }
};

/// Removes complete markers from a stream of bytes. Create one per answer, `feed` every byte in
/// order, then `finish`. `out` has `put(byte: u8) !void` and receives the text that remains.
pub const Filter = struct {
    state: State = .idle,
    // Unresolved bytes are `buf[anchor..tail]`: the held marker prefix, then any bytes that a
    // rejected prefix sends back to be scanned again. `head` is the next one to scan.
    buf: [max_held + 1]u8 = undefined,
    anchor: usize = 0,
    head: usize = 0,
    tail: usize = 0,

    pub fn feed(self: *Filter, byte: u8, out: anytype) !void {
        self.buf[self.tail] = byte;
        self.tail += 1;
        try self.drain(out);
    }

    /// Ends the answer: whatever is still an unfinished marker is text.
    pub fn finish(self: *Filter, out: anytype) !void {
        while (self.state != .idle) {
            try self.reject(out);
            self.state = reject_move.next;
            try self.drain(out);
        }
    }

    fn drain(self: *Filter, out: anytype) !void {
        while (self.head < self.tail) {
            const byte = self.buf[self.head];
            switch (self.step(byte)) {
                .pass => {
                    try out.put(byte);
                    self.head += 1;
                    self.anchor = self.head;
                },
                .keep => self.head += 1,
                .drop => {
                    self.head += 1;
                    self.anchor = self.head;
                },
                .reject => try self.reject(out),
            }
        }
        if (self.state == .idle) {
            self.anchor = 0;
            self.head = 0;
            self.tail = 0;
        } else if (self.anchor != 0) {
            const held = self.tail - self.anchor;
            for (0..held) |at| self.buf[at] = self.buf[self.anchor + at];
            self.head -= self.anchor;
            self.tail = held;
            self.anchor = 0;
        }
    }

    /// The held prefix is not a marker: its first byte is text, and the rest are scanned again.
    fn reject(self: *Filter, out: anytype) !void {
        try out.put(self.buf[self.anchor]);
        self.anchor += 1;
        self.head = self.anchor;
    }

    /// Moves the state by one byte. While idle the anchor equals the head, so a marker that starts
    /// here is anchored at this byte without a write.
    fn step(self: *Filter, byte: u8) Step {
        const moved = self.state.move(byte, self.head - self.anchor);
        self.state = moved.next;
        return moved.step;
    }
};

fn idByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

const Collect = struct {
    items: [2 * max_held]u8 = undefined,
    len: usize = 0,

    pub fn put(self: *Collect, byte: u8) error{}!void {
        self.items[self.len] = byte;
        self.len += 1;
    }

    fn slice(self: *const Collect) []const u8 {
        return self.items[0..self.len];
    }
};

/// The independent oracle: the marker grammar matched at each position of the whole text, with no
/// streaming state; a marker, closer included, is at most `max_held` bytes.
fn oracle(text: []const u8, out: *Collect) void {
    var at: usize = 0;
    while (at < text.len) {
        if (markerEnd(text, at)) |end| {
            at = end;
            continue;
        }
        out.put(text[at]) catch unreachable;
        at += 1;
    }
}

fn markerEnd(text: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, text[start..], lead)) return null;
    var at = start + lead.len;
    while (true) {
        const id_start = at;
        while (at < text.len and idByte(text[at])) at += 1;
        if (at == id_start) return null;
        const rest = text[at..];
        if (std.mem.startsWith(u8, rest, close)) return if (at + close.len - start <= max_held) at + close.len else null;
        if (!std.mem.startsWith(u8, rest, separator)) return null;
        at += separator.len;
    }
}

fn run(text: []const u8, out: *Collect) void {
    var filter: Filter = .{};
    for (text) |byte| filter.feed(byte, out) catch unreachable;
    filter.finish(out) catch unreachable;
}

fn expectFiltered(input: []const u8, expected: []const u8) !void {
    var out: Collect = .{};
    run(input, &out);
    try std.testing.expectEqualStrings(expected, out.slice());
}

/// A fixed-seed splitmix64, so the generated cases are the same on every run.
const Random = struct {
    state: u64,

    fn below(self: *Random, limit: usize) usize {
        self.state +%= 0x9e3779b97f4a7c15;
        var mixed = self.state;
        mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
        mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
        return @intCast((mixed ^ (mixed >> 31)) % limit);
    }
};

test "SUI-167 a complete provider citation marker is removed from answer text and nothing else is" {
    const marker = "\u{e200}cite\u{e202}turn0search0\u{e202}turn0search1\u{e201}";
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "Rust is fast." ++ marker ++ " Zig too.", .expected = "Rust is fast. Zig too." },
        .{ .input = marker ++ marker, .expected = "" },
        .{ .input = "a\u{e200}cite\u{e202}x-y_1\u{e201}b", .expected = "ab" },
        // An unfinished or malformed marker is text.
        .{ .input = "a\u{e200}cite", .expected = "a\u{e200}cite" },
        .{ .input = "a\u{e200}cite\u{e202}turn0", .expected = "a\u{e200}cite\u{e202}turn0" },
        .{ .input = "a\u{e200}cite\u{e202}\u{e201}b", .expected = "a\u{e200}cite\u{e202}\u{e201}b" },
        .{ .input = "a\u{e200}cite\u{e201}b", .expected = "a\u{e200}cite\u{e201}b" },
        .{ .input = "a\u{e200}cite\u{e202}x y\u{e201}b", .expected = "a\u{e200}cite\u{e202}x y\u{e201}b" },
        .{ .input = "a\u{e200}cite\u{e202}x\u{e202}\u{e201}b", .expected = "a\u{e200}cite\u{e202}x\u{e202}\u{e201}b" },
        .{ .input = "a\u{e200}entity\u{e202}x\u{e201}b", .expected = "a\u{e200}entity\u{e202}x\u{e201}b" },
        .{ .input = "a\u{e200}citation\u{e202}x\u{e201}b", .expected = "a\u{e200}citation\u{e202}x\u{e201}b" },
        .{ .input = "a\u{e203}cite\u{e202}x\u{e201}b", .expected = "a\u{e203}cite\u{e202}x\u{e201}b" },
        .{ .input = "a\u{e200}cite\u{e202}\u{e9}\u{e201}b", .expected = "a\u{e200}cite\u{e202}\u{e9}\u{e201}b" },
        // Bytes that are not UTF-8 pass through, even inside a marker's prefix.
        .{ .input = "a\xff\xee\x88b\xee", .expected = "a\xff\xee\x88b\xee" },
        // A marker that starts inside an unfinished one is still removed.
        .{ .input = "a\u{e200}cite\u{e202}x" ++ marker ++ "b", .expected = "a\u{e200}cite\u{e202}xb" },
        .{ .input = "\u{e200}cite" ++ marker, .expected = "\u{e200}cite" },
    };
    for (cases) |case| try expectFiltered(case.input, case.expected);
}

test "SUI-167 a marker longer than the hold bound stays text" {
    const ids: [max_held - lead.len - close.len]u8 = @splat('x');
    try expectFiltered("a" ++ lead ++ ids ++ close ++ "b", "ab");
    const too_long = "a" ++ lead ++ ids ++ "x" ++ close ++ "b";
    try expectFiltered(too_long, too_long);
}

test "SUI-167 the stream filter agrees with the whole-text definition over generated text" {
    const alphabet = [_]u8{ 'c', 'i', 't', 'e', 'a', '7', '-', '_', ' ', 0xee, 0x88, 0x80, 0x81, 0x82, 0x83, 0xc3, 0xa9 };
    var random: Random = .{ .state = 0x6d61726b };
    var text: [160]u8 = undefined;
    for (0..4000) |_| {
        const length = random.below(text.len + 1);
        var at: usize = 0;
        while (at < length) {
            // Mostly the marker's own pieces, so complete and near-complete markers are common.
            const pick = random.below(10);
            const piece: []const u8 = if (pick < 4) lead else if (pick < 6) separator else if (pick < 8) close else &.{alphabet[random.below(alphabet.len)]};
            const count = @min(piece.len, length - at);
            @memcpy(text[at..][0..count], piece[0..count]);
            at += count;
        }
        var expected: Collect = .{};
        oracle(text[0..length], &expected);
        var actual: Collect = .{};
        run(text[0..length], &actual);
        try std.testing.expectEqualStrings(expected.slice(), actual.slice());
    }
}

test "SUI-200 the marker table takes each state to the state and step its bytes call for" {
    const Row = struct { from: State, byte: u8, held: usize, next: State, step: Step };
    const rows = [_]Row{
        // Idle: a byte that starts no marker passes; the marker's first byte starts one.
        .{ .from = .idle, .byte = 'a', .held = 0, .next = .idle, .step = .pass },
        .{ .from = .idle, .byte = lead[0], .held = 0, .next = .lead, .step = .keep },
        .{ .from = .idle, .byte = 'a', .held = max_held, .next = .idle, .step = .pass },
        // Lead: each byte must match the lead in order; its last byte moves to the id.
        .{ .from = .lead, .byte = lead[1], .held = 1, .next = .lead, .step = .keep },
        .{ .from = .lead, .byte = lead[9], .held = 9, .next = .id_start, .step = .keep },
        .{ .from = .lead, .byte = 'x', .held = 3, .next = .idle, .step = .reject },
        .{ .from = .lead, .byte = lead[1], .held = max_held, .next = .idle, .step = .reject },
        // Id start: one id byte is required.
        .{ .from = .id_start, .byte = 'x', .held = 10, .next = .id, .step = .keep },
        .{ .from = .id_start, .byte = '-', .held = 10, .next = .id, .step = .keep },
        .{ .from = .id_start, .byte = ' ', .held = 10, .next = .idle, .step = .reject },
        // Id: more id bytes stay; the separator starts the next id; anything else rejects.
        .{ .from = .id, .byte = '_', .held = 11, .next = .id, .step = .keep },
        .{ .from = .id, .byte = separator[0], .held = 12, .next = .mark_1, .step = .keep },
        .{ .from = .id, .byte = ' ', .held = 12, .next = .idle, .step = .reject },
        .{ .from = .id, .byte = 'x', .held = max_held, .next = .idle, .step = .reject },
        // Mark 1 and mark 2: the separator's bytes, then the closer or another separator.
        .{ .from = .mark_1, .byte = separator[1], .held = 13, .next = .mark_2, .step = .keep },
        .{ .from = .mark_1, .byte = 'x', .held = 13, .next = .idle, .step = .reject },
        .{ .from = .mark_2, .byte = separator[2], .held = 14, .next = .id_start, .step = .keep },
        .{ .from = .mark_2, .byte = close[2], .held = 14, .next = .idle, .step = .drop },
        .{ .from = .mark_2, .byte = 'x', .held = 14, .next = .idle, .step = .reject },
    };
    // Every state and every step is the subject of at least one row.
    for (std.enums.values(State)) |state| {
        var seen = false;
        for (rows) |row| seen = seen or row.from == state;
        try std.testing.expect(seen);
    }
    for (std.enums.values(Step)) |step| {
        var seen = false;
        for (rows) |row| seen = seen or row.step == step;
        try std.testing.expect(seen);
    }
    for (rows) |row| {
        const moved = row.from.move(row.byte, row.held);
        try std.testing.expectEqual(row.next, moved.next);
        try std.testing.expectEqual(row.step, moved.step);
    }
}
