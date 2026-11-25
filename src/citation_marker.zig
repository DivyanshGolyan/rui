//! Provider citation markers inside message text.
//!
//! The ChatGPT route's models write a web citation into the answer as private-use
//! scalars around ASCII ids: U+E200 `cite` (U+E202 id)+ U+E201, for example
//! `\u{e200}cite\u{e202}turn0search0\u{e202}turn0search1\u{e201}`. The marker is the provider's
//! wire encoding of a source reference, not words, so decoding message text removes it once and
//! every reader of the text (the Conversation, `/copy`, replay, the CLI) sees the answer without it.
//! Only a complete marker is removed; any other text, including an unfinished marker, stays.

const std = @import("std");

const open: u21 = 0xe200;
const close: u21 = 0xe201;
const separator: u21 = 0xe202;
const lead = [_]u21{ open, 'c', 'i', 't', 'e', separator };

/// A marker holds at most this many scalars before its closer; a longer run stays text.
pub const max_held = 512;

const State = enum { idle, lead, id_start, id };
const Step = enum { pass, keep, drop, reject };

/// Removes complete markers from a stream of decoded scalars. Create one per text part, `feed`
/// every scalar in order, then `finish`. `out` has `put(scalar: u21) !void` and receives the
/// text that remains.
pub const Filter = struct {
    state: State = .idle,
    // Unresolved scalars are `buf[anchor..tail]`: the held marker prefix, then any scalars that a
    // rejected prefix sends back to be scanned again. `head` is the next one to scan.
    buf: [max_held + 1]u21 = undefined,
    anchor: usize = 0,
    head: usize = 0,
    tail: usize = 0,
    sequence: [4]u8 = undefined,
    sequence_len: u3 = 0,

    pub fn feed(self: *Filter, scalar: u21, out: anytype) !void {
        self.buf[self.tail] = scalar;
        self.tail += 1;
        try self.drain(out);
    }

    /// Feeds one byte of valid UTF-8; the scalar is fed when its last byte arrives.
    pub fn feedByte(self: *Filter, byte: u8, out: anytype) !void {
        if (self.sequence_len == 0 and byte < 0x80) return self.feed(byte, out);
        if (self.sequence_len == 0) _ = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
        self.sequence[self.sequence_len] = byte;
        self.sequence_len += 1;
        const needed = std.unicode.utf8ByteSequenceLength(self.sequence[0]) catch unreachable;
        if (self.sequence_len < needed) return;
        self.sequence_len = 0;
        try self.feed(std.unicode.utf8Decode(self.sequence[0..needed]) catch return error.InvalidUtf8, out);
    }

    /// Ends the part: whatever is still an unfinished marker is text.
    pub fn finish(self: *Filter, out: anytype) !void {
        if (self.sequence_len != 0) return error.InvalidUtf8;
        while (self.state != .idle) {
            try self.reject(out);
            try self.drain(out);
        }
    }

    fn drain(self: *Filter, out: anytype) !void {
        while (self.head < self.tail) {
            const scalar = self.buf[self.head];
            switch (self.step(scalar)) {
                .pass => {
                    try out.put(scalar);
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

    /// The held prefix is not a marker: its first scalar is text, and the rest are scanned again.
    fn reject(self: *Filter, out: anytype) !void {
        try out.put(self.buf[self.anchor]);
        self.anchor += 1;
        self.head = self.anchor;
        self.state = .idle;
    }

    fn step(self: *Filter, scalar: u21) Step {
        const held = self.head - self.anchor;
        if (self.state != .idle and held == max_held) return .reject;
        switch (self.state) {
            .idle => {
                if (scalar != open) return .pass;
                self.anchor = self.head;
                self.state = .lead;
                return .keep;
            },
            .lead => {
                if (scalar != lead[held]) return .reject;
                if (held + 1 == lead.len) self.state = .id_start;
                return .keep;
            },
            .id_start => {
                if (!idScalar(scalar)) return .reject;
                self.state = .id;
                return .keep;
            },
            .id => {
                if (idScalar(scalar)) return .keep;
                if (scalar == separator) {
                    self.state = .id_start;
                    return .keep;
                }
                if (scalar != close) return .reject;
                self.state = .idle;
                return .drop;
            },
        }
    }
};

fn idScalar(scalar: u21) bool {
    return scalar < 0x80 and (std.ascii.isAlphanumeric(@intCast(scalar)) or scalar == '_' or scalar == '-');
}

const Collect = struct {
    items: [max_held + 128]u21 = undefined,
    len: usize = 0,

    pub fn put(self: *Collect, scalar: u21) error{}!void {
        self.items[self.len] = scalar;
        self.len += 1;
    }

    fn slice(self: *const Collect) []const u21 {
        return self.items[0..self.len];
    }
};

/// The independent oracle: the marker grammar matched at each position of the whole text, with no
/// streaming state; a marker, closer included, is at most `max_held` scalars.
fn oracle(text: []const u21, out: *Collect) error{}!void {
    var at: usize = 0;
    while (at < text.len) {
        if (markerEnd(text, at)) |end| {
            at = end;
            continue;
        }
        try out.put(text[at]);
        at += 1;
    }
}

fn markerEnd(text: []const u21, start: usize) ?usize {
    if (start + lead.len > text.len) return null;
    for (lead, 0..) |expected, offset| if (text[start + offset] != expected) return null;
    var at = start + lead.len;
    while (true) {
        const id_start = at;
        while (at < text.len and idScalar(text[at])) at += 1;
        if (at == id_start or at >= text.len) return null;
        if (at - start >= max_held) return null;
        switch (text[at]) {
            close => return at + 1,
            separator => at += 1,
            else => return null,
        }
    }
}

fn run(text: []const u21, out: *Collect) !void {
    var filter: Filter = .{};
    for (text) |scalar| try filter.feed(scalar, out);
    try filter.finish(out);
}

fn expectFiltered(input: []const u21, expected: []const u21) !void {
    var out: Collect = .{};
    try run(input, &out);
    try std.testing.expectEqualSlices(u21, expected, out.slice());
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

fn scalars(comptime text: []const u8) []const u21 {
    const result = comptime blk: {
        @setEvalBranchQuota(20_000);
        var buffer: [text.len]u21 = undefined;
        var count: usize = 0;
        var view = std.unicode.Utf8View.initComptime(text).iterator();
        while (view.nextCodepoint()) |scalar| : (count += 1) buffer[count] = scalar;
        const final: [count]u21 = buffer[0..count].*;
        break :blk final;
    };
    return &result;
}

test "CM-66 a complete provider citation marker is removed from message text and nothing else is" {
    const marker = "\u{e200}cite\u{e202}turn0search0\u{e202}turn0search1\u{e201}";
    const cases = [_]struct { input: []const u21, expected: []const u21 }{
        .{ .input = scalars("Rust is fast." ++ marker ++ " Zig too."), .expected = scalars("Rust is fast. Zig too.") },
        .{ .input = scalars(marker ++ marker), .expected = scalars("") },
        .{ .input = scalars("a\u{e200}cite\u{e202}x-y_1\u{e201}b"), .expected = scalars("ab") },
        // An unfinished or malformed marker is text.
        .{ .input = scalars("a\u{e200}cite"), .expected = scalars("a\u{e200}cite") },
        .{ .input = scalars("a\u{e200}cite\u{e202}turn0"), .expected = scalars("a\u{e200}cite\u{e202}turn0") },
        .{ .input = scalars("a\u{e200}cite\u{e202}\u{e201}b"), .expected = scalars("a\u{e200}cite\u{e202}\u{e201}b") },
        .{ .input = scalars("a\u{e200}cite\u{e201}b"), .expected = scalars("a\u{e200}cite\u{e201}b") },
        .{ .input = scalars("a\u{e200}cite\u{e202}x y\u{e201}b"), .expected = scalars("a\u{e200}cite\u{e202}x y\u{e201}b") },
        .{ .input = scalars("a\u{e200}cite\u{e202}x\u{e202}\u{e201}b"), .expected = scalars("a\u{e200}cite\u{e202}x\u{e202}\u{e201}b") },
        .{ .input = scalars("a\u{e200}entity\u{e202}x\u{e201}b"), .expected = scalars("a\u{e200}entity\u{e202}x\u{e201}b") },
        .{ .input = scalars("a\u{e200}citation\u{e202}x\u{e201}b"), .expected = scalars("a\u{e200}citation\u{e202}x\u{e201}b") },
        .{ .input = scalars("a\u{e203}cite\u{e202}x\u{e201}b"), .expected = scalars("a\u{e203}cite\u{e202}x\u{e201}b") },
        .{ .input = scalars("a\u{e200}cite\u{e202}é\u{e201}b"), .expected = scalars("a\u{e200}cite\u{e202}é\u{e201}b") },
        // A marker that starts inside an unfinished one is still removed.
        .{ .input = scalars("a\u{e200}cite\u{e202}x" ++ marker ++ "b"), .expected = scalars("a\u{e200}cite\u{e202}xb") },
        .{ .input = scalars("\u{e200}cite" ++ marker), .expected = scalars("\u{e200}cite") },
    };
    for (cases) |case| try expectFiltered(case.input, case.expected);
}

test "CM-66 a marker longer than the hold bound stays text" {
    const ids: [max_held - 1 - lead.len]u8 = @splat('x');
    const fits = scalars("a\u{e200}cite\u{e202}" ++ ids ++ "\u{e201}b");
    try expectFiltered(fits, scalars("ab"));
    const too_long = scalars("a\u{e200}cite\u{e202}" ++ ids ++ "x\u{e201}b");
    try expectFiltered(too_long, too_long);
}

test "CM-66 the stream filter agrees with the whole-text definition over generated text" {
    const alphabet = [_]u21{ open, close, separator, 'c', 'i', 't', 'e', 'a', '7', '-', '_', ' ', 0xe203, 0xe9, 0x1f600 };
    var random: Random = .{ .state = 0x6d61726b };
    var text: [96]u21 = undefined;
    for (0..4000) |_| {
        const length = random.below(text.len + 1);
        for (text[0..length]) |*scalar| {
            // Mostly the marker's own pieces, so complete and near-complete markers are common.
            const pick = random.below(10);
            scalar.* = if (pick < 6) lead[random.below(lead.len)] else if (pick < 8) close else alphabet[random.below(alphabet.len)];
        }
        var expected: Collect = .{};
        try oracle(text[0..length], &expected);
        var actual: Collect = .{};
        try run(text[0..length], &actual);
        try std.testing.expectEqualSlices(u21, expected.slice(), actual.slice());
    }
}

test "CM-66 bytes of UTF-8 filter as their scalars and an invalid sequence is refused" {
    const input = "caf\u{e9} \u{1f600}\u{e200}cite\u{e202}t1\u{e201}!";
    var out: Collect = .{};
    var filter: Filter = .{};
    for (input) |byte| try filter.feedByte(byte, &out);
    try filter.finish(&out);
    try std.testing.expectEqualSlices(u21, scalars("caf\u{e9} \u{1f600}!"), out.slice());

    var cut: Filter = .{};
    var ignored: Collect = .{};
    try cut.feedByte(0xee, &ignored);
    try std.testing.expectError(error.InvalidUtf8, cut.finish(&ignored));
    var lone: Filter = .{};
    try std.testing.expectError(error.InvalidUtf8, lone.feedByte(0xff, &ignored));
}
