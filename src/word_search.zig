//! Bounded streaming byte search. Only ASCII case is folded. Snippets replace
//! malformed bytes with '?' (one byte each), preserving stored byte offsets.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

pub fn fold(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

pub const Hit = struct {
    snippet: Bounded(160) = .{},
    offset: usize = 0,
    length: usize = 0,
    raw_offset: usize = 0,
};

pub const Matcher = struct {
    query: [256]u8 = undefined,
    query_len: usize = 0,
    carry: [256]u8 = undefined,
    carry_len: usize = 0,
    raw: [512]u8 = undefined,
    total: usize = 0,
    count: usize = 0,
    hits: [3]Hit = .{ .{}, .{}, .{} },
    starts: [3]usize = undefined,
    done: [3]bool = .{ false, false, false },

    /// The shell validates query UTF-8; byte queries are useful to test the engine.
    pub fn init(self: *Matcher, query: []const u8) void {
        std.debug.assert(query.len > 0 and query.len <= 256);
        self.* = .{};
        self.query_len = query.len;
        for (query, 0..) |b, i| self.query[i] = fold(b);
    }

    pub fn feed(self: *Matcher, bytes: []const u8) void {
        for (bytes) |b| {
            self.raw[self.total % self.raw.len] = b;
            self.total += 1;
            self.carry[self.carry_len] = fold(b);
            self.carry_len += 1;
            if (self.carry_len == self.query_len) {
                if (self.count < 3 and std.mem.eql(u8, self.carry[0..self.carry_len], self.query[0..self.query_len])) {
                    const pos = self.total - self.query_len;
                    self.hits[self.count].raw_offset = pos;
                    // Long queries are matched in full but only their visible
                    // prefix is highlighted inside the 160-byte snippet.
                    self.starts[self.count] = pos - @min(pos, if (self.query_len <= 120) @as(usize, 40) else 0);
                    self.count += 1;
                }
                std.mem.copyForwards(u8, self.carry[0 .. self.query_len - 1], self.carry[1..self.query_len]);
                self.carry_len -= 1;
            }
            for (0..self.count) |i| {
                if (!self.done[i] and self.total >= self.starts[i] + 160) self.cut(i);
            }
        }
    }

    pub fn finish(self: *Matcher) void {
        for (0..self.count) |i| if (!self.done[i]) self.cut(i);
    }

    fn cut(self: *Matcher, index: usize) void {
        var bytes: [160]u8 = undefined;
        var start = self.starts[index];
        const end = @min(self.total, start + 160);
        // A leading continuation belongs to a character outside the snippet.
        while (start < end and self.raw[start % 512] & 0xc0 == 0x80) : (start += 1) {}
        var n: usize = 0;
        var p = start;
        while (p < end) {
            const b = self.raw[p % 512];
            const size = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (p + size > end) break;
            for (0..size) |j| bytes[n + j] = self.raw[(p + j) % 512];
            if (std.unicode.utf8ValidateSlice(bytes[n .. n + size])) {
                n += size;
                p += size;
            } else {
                bytes[n] = '?';
                n += 1;
                p += 1;
            }
        }
        const hit = &self.hits[index];
        hit.snippet.set(bytes[0..n]) catch unreachable;
        hit.offset = @min(n, hit.raw_offset -| start);
        hit.length = @min(n - hit.offset, self.query_len -| (start -| hit.raw_offset));
        self.done[index] = true;
    }
};

test "word search every split and overlap" {
    const data = "é aaAA café tail";
    for (0..data.len + 1) |split| {
        var m: Matcher = undefined;
        m.init("aa");
        m.feed(data[0..split]);
        m.feed(data[split..]);
        m.finish();
        try std.testing.expectEqual(@as(usize, 3), m.count);
        for (m.hits, 0..) |hit, i| {
            try std.testing.expectEqual(@as(usize, 3) + i, hit.raw_offset);
            try std.testing.expectEqualStrings(data, hit.snippet.slice());
        }
    }
    try std.testing.expectEqual(@as(u8, 'z'), fold('Z'));
    try std.testing.expectEqual(@as(u8, 0xc3), fold(0xc3));
}

fn random(state: *u64, bound: usize) usize {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @intCast((state.* >> 32) % bound);
}

test "word search 20000 carry reference trials" {
    var state: u64 = 7;
    const alphabet = "abAB \xc3\xa9";
    var data: [200]u8 = undefined;
    var query: [8]u8 = undefined;
    for (0..20000) |_| {
        const len = random(&state, 201);
        const qlen = 1 + random(&state, 8);
        const chunk = 1 + random(&state, 16);
        for (data[0..len]) |*b| b.* = alphabet[random(&state, alphabet.len)];
        for (query[0..qlen]) |*b| b.* = alphabet[random(&state, alphabet.len)];
        var expected: [3]usize = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i + qlen <= len and count < 3) : (i += 1) {
            var equal = true;
            for (query[0..qlen], 0..) |b, j| if (fold(b) != fold(data[i + j])) {
                equal = false;
            };
            if (equal) {
                expected[count] = i;
                count += 1;
            }
        }
        var m: Matcher = undefined;
        m.init(query[0..qlen]);
        i = 0;
        while (i < len) : (i += @min(chunk, len - i)) m.feed(data[i..@min(len, i + chunk)]);
        m.finish();
        try std.testing.expectEqual(count, m.count);
        for (0..count) |j| {
            try std.testing.expectEqual(expected[j], m.hits[j].raw_offset);
            try std.testing.expect(std.unicode.utf8ValidateSlice(m.hits[j].snippet.slice()));
        }
    }
}

test "word search UTF8 windows snippet boundaries and long queries" {
    var data: [600]u8 = undefined;
    for (0..300) |i| {
        data[i * 2] = 0xc3;
        data[i * 2 + 1] = 0xa9;
    }
    data[200] = 'X';
    data[201] = 'Y';
    for (0..data.len + 1) |split| {
        var m: Matcher = undefined;
        m.init("xy");
        m.feed(data[0..split]);
        m.feed(data[split..]);
        m.finish();
        try std.testing.expectEqual(@as(usize, 1), m.count);
        const hit = &m.hits[0];
        try std.testing.expect(std.unicode.utf8ValidateSlice(hit.snippet.slice()));
        try std.testing.expectEqualStrings("XY", hit.snippet.slice()[hit.offset..][0..hit.length]);
        try std.testing.expect(hit.snippet.len <= 160);
    }
    var query: [256]u8 = @splat('a');
    var m: Matcher = undefined;
    m.init(&query);
    for (&query) |*b| m.feed(b[0..1]);
    m.finish();
    try std.testing.expectEqual(@as(usize, 1), m.count);
    try std.testing.expectEqual(@as(usize, 160), m.hits[0].length);
    m.init("x");
    m.feed("\xffx\xc3");
    m.finish();
    try std.testing.expectEqualStrings("?x", m.hits[0].snippet.slice());
}
