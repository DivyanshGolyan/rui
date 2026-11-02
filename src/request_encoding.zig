const std = @import("std");
const protocol = @import("protocol.zig");

pub const window_bytes = protocol.content_window_bytes;

// A cursor source supplies immutable positional bytes. It must provide:
//   fn contentLength(self: @This()) u64
//   fn readContent(self: @This(), offset: u64, destination: []u8) !usize
//   fn maxWindow(self: @This(), offset: u64, wanted: usize) usize
// `maxWindow` clips the requested refill size before the read happens; it
// must return `wanted` unchanged for native content and a positive value
// bounded by the next absolute partition boundary for test content. It must
// never turn an unexpectedly short canonical read into success: the cursor
// still requires the read to return exactly the clipped length.
// A sink provides `fn write(self: *@This(), bytes: []const u8) !void` which
// accepts the complete supplied slice on success.

pub const MemorySource = struct {
    bytes: []const u8,

    pub fn contentLength(self: MemorySource) u64 {
        return self.bytes.len;
    }

    pub fn readContent(self: MemorySource, offset: u64, destination: []u8) !usize {
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.RangeOutOfBounds;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return destination.len;
    }

    pub fn maxWindow(self: MemorySource, offset: u64, wanted: usize) usize {
        _ = self;
        _ = offset;
        return wanted;
    }
};

pub const PartitionedSource = struct {
    bytes: []const u8,
    boundaries: []const u64 = &.{},

    pub fn contentLength(self: PartitionedSource) u64 {
        return self.bytes.len;
    }

    pub fn maxWindow(self: PartitionedSource, offset: u64, wanted: usize) usize {
        if (wanted == 0) return 0;
        var clipped = wanted;
        for (self.boundaries) |boundary| {
            if (boundary <= offset) continue;
            const remaining: u64 = boundary - offset;
            if (remaining < clipped) clipped = @intCast(remaining);
            break;
        }
        if (clipped == 0) return wanted;
        return clipped;
    }

    pub fn readContent(self: PartitionedSource, offset: u64, destination: []u8) !usize {
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.RangeOutOfBounds;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return destination.len;
    }
};

pub const ShortReadSource = struct {
    bytes: []const u8,

    pub fn contentLength(self: ShortReadSource) u64 {
        return self.bytes.len;
    }

    pub fn maxWindow(self: ShortReadSource, offset: u64, wanted: usize) usize {
        _ = self;
        _ = offset;
        return wanted;
    }

    pub fn readContent(self: ShortReadSource, offset: u64, destination: []u8) !usize {
        const start: usize = @intCast(offset);
        if (destination.len == 0) return 0;
        if (start >= self.bytes.len) return 0;
        const available = self.bytes.len - start;
        const count = @min(destination.len - 1, available);
        @memcpy(destination[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

// This is an encoding operation, not another payload owner. The caller's
// borrowed window remains valid until the synchronous write returns.
pub fn writePlainJsonRun(writer: anytype, bytes: []const u8, bytes_left: *usize) !usize {
    const limit = @min(bytes.len, bytes_left.* / 2);
    var count: usize = 0;
    while (count < limit) : (count += 1) {
        const byte = bytes[count];
        if (byte < 0x20 or byte == '"' or byte == '\\') break;
    }
    if (count == 0) return 0;
    try writer.write(bytes[0..count]);
    bytes_left.* -= count * 2;
    return count;
}

pub const FixedCursor = struct {
    offset: usize = 0,

    pub fn advance(self: *FixedCursor, bytes: []const u8, writer: anytype, bytes_left: *usize) !bool {
        const count = @min(bytes_left.*, bytes.len - self.offset);
        if (count == 0) return false;
        try writer.write(bytes[self.offset..][0..count]);
        self.offset += count;
        bytes_left.* -= count;
        return self.offset == bytes.len;
    }
};

pub const JsonCursor = struct {
    offset: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [window_bytes]u8 = undefined,
    // Escape string contents twice when presenting a JSON literal inside
    // another JSON string. Its enclosing quotes belong to the caller.
    nested_string: bool = false,
    encoded: [7]u8 = undefined,
    encoded_length: u3 = 0,
    encoded_offset: u3 = 0,

    pub fn advance(self: *JsonCursor, source: anytype, writer: anytype, bytes_left: *usize) !bool {
        while (bytes_left.* != 0) {
            if (self.encoded_offset != self.encoded_length) {
                const count = @min(bytes_left.*, self.encoded_length - self.encoded_offset);
                try writer.write(self.encoded[self.encoded_offset..][0..count]);
                self.encoded_offset += @intCast(count);
                bytes_left.* -= count;
                continue;
            }
            const length = source.contentLength();
            if (self.offset == length) return true;
            if (self.offset < self.buffer_start or self.offset >= self.buffer_start + self.buffer_length) {
                self.buffer_start = self.offset;
                var wanted: usize = @intCast(@min(length - self.offset, @min(self.buffer.len, bytes_left.*)));
                wanted = source.maxWindow(self.offset, wanted);
                if (wanted == 0) return false;
                const count = try source.readContent(self.offset, self.buffer[0..wanted]);
                if (count != wanted) return error.ShortCanonicalRead;
                self.buffer_length = count;
            }
            const available = self.buffer[@intCast(self.offset - self.buffer_start)..self.buffer_length];
            // A source scan and its emitted bytes each consume allowance.
            // Ordinary text stays a borrowed run, not one OS write per byte.
            const run = try writePlainJsonRun(writer, available, bytes_left);
            if (run != 0) {
                self.offset += run;
                continue;
            }
            const byte = available[0];
            self.offset += 1;
            bytes_left.* -= 1;
            var single: [6]u8 = undefined;
            const encoded = switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x0c => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...0x07, 0x0b, 0x0e...0x1f => blk: {
                    const hex = "0123456789abcdef";
                    single = .{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };
                    break :blk single[0..];
                },
                else => blk: {
                    // A one-byte allowance can consume a source byte now
                    // and emit it on the next advance, without overshoot.
                    single[0] = byte;
                    break :blk single[0..1];
                },
            };
            if (self.nested_string) {
                var escaped: std.Io.Writer = .fixed(&self.encoded);
                // The longest twice-escaped byte is \\u00xx (seven bytes).
                std.json.Stringify.encodeJsonStringChars(encoded, .{}, &escaped) catch unreachable;
                self.encoded_length = @intCast(escaped.end);
            } else {
                @memcpy(self.encoded[0..encoded.len], encoded);
                self.encoded_length = @intCast(encoded.len);
            }
            self.encoded_offset = 0;
        }
        return false;
    }
};

pub const RawCursor = struct {
    offset: u64 = 0,
    buffer_length: usize = 0,
    buffer_offset: usize = 0,
    buffer: [window_bytes]u8 = undefined,

    pub fn advance(self: *RawCursor, source: anytype, writer: anytype, bytes_left: *usize) !bool {
        if (self.buffer_offset != self.buffer_length) {
            const count = @min(bytes_left.*, self.buffer_length - self.buffer_offset);
            if (count == 0) return false;
            try writer.write(self.buffer[self.buffer_offset..][0..count]);
            self.buffer_offset += count;
            bytes_left.* -= count;
            if (self.buffer_offset != self.buffer_length) return false;
        }
        const length = source.contentLength();
        if (self.offset != length) {
            var wanted: usize = @intCast(@min(length - self.offset, @min(self.buffer.len, bytes_left.*)));
            wanted = source.maxWindow(self.offset, wanted);
            if (wanted == 0) return false;
            const count = try source.readContent(self.offset, self.buffer[0..wanted]);
            if (count != wanted) return error.ShortCanonicalRead;
            self.offset += count;
            self.buffer_length = count;
            self.buffer_offset = 0;
            bytes_left.* -= count;
            return false;
        }
        return true;
    }
};

const TestSink = struct {
    output: std.ArrayList(u8) = .empty,
    calls: usize = 0,

    fn init(allocator: std.mem.Allocator) TestSink {
        _ = allocator;
        return .{};
    }

    fn deinit(self: *TestSink) void {
        self.output.deinit(std.testing.allocator);
    }

    pub fn write(self: *TestSink, bytes: []const u8) !void {
        self.calls += 1;
        try self.output.appendSlice(std.testing.allocator, bytes);
    }
};

fn failCtx(case: []const u8, input_len: usize, boundaries: []const u64, byte_seq: []const usize, item_seq: []const usize, step: usize) void {
    std.debug.print("request encoding failure: case={s} input_len={d} boundaries={any} byte_seq={any} item_seq={any} step={d}\n", .{ case, input_len, boundaries, byte_seq, item_seq, step });
}

/// Deterministic partition boundaries from an independent seed. Partitions
/// and allowance sequences must use different seeds so the two dimensions
/// cannot accidentally correlate.
fn seededBoundaries(seed: u64, length: usize, buf: []u64) []u64 {
    if (length < 2 or buf.len == 0) return &.{};
    var state = seed | 1;
    var n: usize = 0;
    var guard: usize = 0;
    while (n < buf.len and guard < buf.len * 16 + 64) : (guard += 1) {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const candidate: u64 = @intCast(1 + (state >> 33) % @as(u64, @intCast(length)));
        var dup = false;
        for (buf[0..n]) |b| if (b == candidate) {
            dup = true;
            break;
        };
        if (dup) continue;
        var at = n;
        while (at > 0 and buf[at - 1] > candidate) : (at -= 1) buf[at] = buf[at - 1];
        buf[at] = candidate;
        n += 1;
    }
    return buf[0..n];
}

fn seededAllowances(seed: u64, buf: []usize, max: usize) []usize {
    std.debug.assert(max >= 1);
    var state = seed | 1;
    for (buf) |*slot| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        slot.* = 1 + (state >> 33) % max;
    }
    return buf;
}

fn runJsonCase(case: []const u8, input: []const u8, boundaries: []const u64, byte_seq: []const usize, expected: []const u8, expected_work: usize) !void {
    var cursor = JsonCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    var total: usize = 0;
    const bound = input.len + expected.len + 64;
    while (true) {
        steps += 1;
        if (steps > bound + 16) {
            failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
            return error.TooManySteps;
        }
        const allowance = byte_seq[(steps - 1) % byte_seq.len];
        try std.testing.expect(allowance != 0);
        var left = allowance;
        const done = try cursor.advance(source, &sink, &left);
        total += allowance - left;
        if (!done and left == allowance) {
            failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
            std.debug.print("zero-progress stall at offset={d}\n", .{cursor.offset});
            return error.ZeroProgressStall;
        }
        if (done) break;
    }
    if (!std.mem.eql(u8, expected, sink.output.items) or total != expected_work) {
        failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
        std.debug.print("offset={d} encoded={d}/{d} emitted={d}/{d} work={d}/{d} first_diff=", .{
            cursor.offset,
            cursor.encoded_offset,
            cursor.encoded_length,
            sink.output.items.len,
            expected.len,
            total,
            expected_work,
        });
        const common = @min(sink.output.items.len, expected.len);
        var diff: usize = 0;
        while (diff < common and sink.output.items[diff] == expected[diff]) : (diff += 1) {}
        std.debug.print("{d}\n", .{diff});
        try std.testing.expectEqualStrings(expected, sink.output.items);
        try std.testing.expectEqual(expected_work, total);
    }
}

fn runJsonSchedules(case: []const u8, input: []const u8, expected: []const u8, expected_work: usize) !void {
    // Every single split position plus unsplit input, each under constant,
    // alternating and sawtooth allowance sequences.
    const seqs = [_][]const usize{ &.{1}, &.{2}, &.{3}, &.{5}, &.{6}, &.{7}, &.{ 1, 7 }, &.{ 3, 1, 2 } };
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == input.len) &.{} else boundary_storage[0..];
        for (seqs) |seq| try runJsonCase(case, input, boundaries, seq, expected, expected_work);
    }
    // One-byte windows over the whole input.
    var all: [256]u64 = undefined;
    const n: usize = @min(input.len, all.len);
    for (0..n) |index| all[index] = @intCast(index + 1);
    for ([_][]const usize{ &.{1}, &.{ 2, 64 } }) |seq| try runJsonCase(case, input, all[0..n], seq, expected, expected_work);
}

fn runRawCase(case: []const u8, input: []const u8, boundaries: []const u64, byte_seq: []const usize) !void {
    var cursor = RawCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    var total: usize = 0;
    const bound = 2 * input.len + 16;
    while (true) {
        steps += 1;
        if (steps > bound) {
            failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
            return error.TooManySteps;
        }
        const allowance = byte_seq[(steps - 1) % byte_seq.len];
        try std.testing.expect(allowance != 0);
        var left = allowance;
        const done = try cursor.advance(source, &sink, &left);
        total += allowance - left;
        if (!done and left == allowance) {
            failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
            std.debug.print("zero-progress stall at offset={d}\n", .{cursor.offset});
            return error.ZeroProgressStall;
        }
        if (done) break;
    }
    if (!std.mem.eql(u8, input, sink.output.items) or total != 2 * input.len) {
        failCtx(case, input.len, boundaries, byte_seq, &.{}, steps);
        std.debug.print("offset={d} emitted={d}/{d} work={d}/{d}\n", .{ cursor.offset, sink.output.items.len, input.len, total, 2 * input.len });
        try std.testing.expectEqualStrings(input, sink.output.items);
        // Every source byte is read once and emitted once.
        try std.testing.expectEqual(2 * input.len, total);
    }
}

test "request encoding fixed bytes respect one-byte allowances" {
    const bytes = "{\"model\":\"";
    for ([_]usize{ 1, 2, 7, 64 }) |allowance| {
        var cursor = FixedCursor{};
        var sink = TestSink.init(std.testing.allocator);
        defer sink.deinit();
        var steps: usize = 0;
        while (true) {
            steps += 1;
            try std.testing.expect(steps <= bytes.len + 2);
            var left = allowance;
            const done = try cursor.advance(bytes, &sink, &left);
            try std.testing.expect(left <= allowance);
            if (done) break;
        }
        try std.testing.expectEqualStrings(bytes, sink.output.items);
        try std.testing.expect(steps == (bytes.len + allowance - 1) / allowance);
    }
}

test "request encoding json escapes across partitions and allowances" {
    // Work oracle: each source byte costs one scan debit plus its emitted
    // length (plain 1, short escape 2, \u00xx escape 6).
    try runJsonSchedules("json empty", "", "", 0);
    try runJsonSchedules("json plain", "abc", "abc", 6);
    try runJsonSchedules("json escapes", "a\"b\\c", "a\\\"b\\\\c", 12);
    try runJsonSchedules("json short escapes", "\x08\x0c\n\r\t", "\\b\\f\\n\\r\\t", 15);
    try runJsonSchedules("json control escapes", "\x01\x0b\x1f", "\\u0001\\u000b\\u001f", 21);
    // Plain run ending immediately before an escape.
    try runJsonSchedules("json run before escape", "abc\"def", "abc\\\"def", 15);
    // Two-, three- and four-byte UTF-8 sequences are preserved byte-wise.
    try runJsonSchedules("json utf8", "é☃𝄞", "é☃𝄞", 18);
    try runJsonSchedules("json utf8 escape", "xé\"y", "xé\\\"y", 11);
}

test "request encoding json pending escape emits under one-byte allowance" {
    var cursor = JsonCursor{};
    const source = MemorySource{ .bytes = "\"" };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var first: usize = 1;
    try std.testing.expect(!try cursor.advance(source, &sink, &first));
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 0), sink.output.items.len);
    var second: usize = 1;
    try std.testing.expect(!try cursor.advance(source, &sink, &second));
    try std.testing.expectEqual(@as(usize, 0), second);
    try std.testing.expectEqualStrings("\\", sink.output.items);
    var third: usize = 1;
    try std.testing.expect(!try cursor.advance(source, &sink, &third));
    try std.testing.expectEqualStrings("\\\"", sink.output.items);
    var fourth: usize = 4;
    try std.testing.expect(try cursor.advance(source, &sink, &fourth));
    try std.testing.expectEqualStrings("\\\"", sink.output.items);
}

test "request encoding json short canonical reads fail" {
    var cursor = JsonCursor{};
    const source = ShortReadSource{ .bytes = "abcdef" };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var left: usize = 64;
    try std.testing.expectError(error.ShortCanonicalRead, cursor.advance(source, &sink, &left));
}

test "request encoding json output failure cannot report completion" {
    const LimitedSink = struct {
        remaining: usize,
        pub fn write(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.remaining) return error.OutputUnavailable;
            self.remaining -= bytes.len;
        }
    };
    // Both a small final tail and failure after a complete output window.
    const inputs = .{ "é\n", &@as([window_bytes + 1]u8, @splat('x')) };
    inline for (inputs, 0..) |input, index| {
        var cursor: JsonCursor = .{};
        const source: MemorySource = .{ .bytes = input };
        var sink: LimitedSink = .{ .remaining = if (index == 0) 0 else window_bytes };
        var left: usize = 16384;
        try std.testing.expectError(error.OutputUnavailable, cursor.advance(source, &sink, &left));
    }
}

test "request encoding json window boundaries preserve bytes" {
    var input: [window_bytes + 2]u8 = undefined;
    @memset(&input, 'a');
    input[window_bytes - 1] = '"';
    input[window_bytes] = 'b';
    input[window_bytes + 1] = '\\';
    var expected_buf: [window_bytes + 8]u8 = undefined;
    var stream = std.Io.Writer.fixed(&expected_buf);
    var count: usize = 0;
    while (count < window_bytes - 1) : (count += 1) try stream.writeByte('a');
    try stream.writeAll("\\\"b\\\\");
    const expected = stream.buffered();
    // (W-1) plain bytes at 2 each plus escapings of `"`, `b`, `\\`.
    const expected_work: usize = 2 * (window_bytes - 1) + 3 + 2 + 3;
    const seqs = [_][]const usize{ &.{1}, &.{ 2, 6 }, &.{7}, &.{4096}, &.{16384}, &.{ 1, 7000 }, &.{ 3, 2, 1 } };
    for ([_]usize{ window_bytes - 1, window_bytes, window_bytes + 1 }) |split| {
        const boundary = [_]u64{@intCast(split)};
        for (seqs) |seq| try runJsonCase("json window split", &input, &boundary, seq, expected, expected_work);
    }
    // Independently seeded multi-boundary partitions and allowance
    // sequences around the window size and production allowance.
    var seed_buf: [8]u64 = undefined;
    const seeded = seededBoundaries(0x1ec0de01, input.len, &seed_buf);
    var allowance_buf: [6]usize = undefined;
    const seeded_seq = seededAllowances(0xb1e5502, &allowance_buf, 16384);
    try runJsonCase("json window seeded", &input, seeded, seeded_seq, expected, expected_work);
    try runJsonCase("json window seeded small", &input, seeded, &.{ 2, 1 }, expected, expected_work);
    // Multiple windows with a large deterministic payload.
    var big: [window_bytes * 2 + 17]u8 = undefined;
    for (&big, 0..) |*byte, index| byte.* = @intCast(0x61 + (index % 26));
    big[10] = '\n';
    big[window_bytes] = '"';
    var big_expected_buf: [window_bytes * 2 + 32]u8 = undefined;
    var big_stream = std.Io.Writer.fixed(&big_expected_buf);
    for (big[0..10]) |byte| try big_stream.writeByte(byte);
    try big_stream.writeAll("\\n");
    for (big[11..window_bytes]) |byte| try big_stream.writeByte(byte);
    try big_stream.writeAll("\\\"");
    for (big[window_bytes + 1 ..]) |byte| try big_stream.writeByte(byte);
    const big_expected = big_stream.buffered();
    const cuts = [_]u64{ 3, 8, 15, window_bytes - 1, window_bytes, window_bytes + 1, big.len };
    // Two escapings among otherwise plain bytes.
    const big_work: usize = 2 * (big.len - 2) + 3 + 3;
    const big_seqs = [_][]const usize{ &.{1}, &.{5}, &.{64}, &.{16384}, &.{ 7, 1 }, &.{ 4, 2, 9 } };
    for (big_seqs) |seq| try runJsonCase("json big cuts", &big, &cuts, seq, big_expected, big_work);
    var big_seed_buf: [10]u64 = undefined;
    const big_seeded = seededBoundaries(0x9e3779b9, big.len, &big_seed_buf);
    var big_allowance_buf: [5]usize = undefined;
    const big_seeded_seq = seededAllowances(0x85ebca6b, &big_allowance_buf, 16384);
    try runJsonCase("json big seeded", &big, big_seeded, big_seeded_seq, big_expected, big_work);

    // Repeated escapes cross both encoded chunk and source-window boundaries;
    // expectations are independent literal JSON, not this encoder's output.
    const mixed = &@as([700 * "é中🙂\n\\\"/\x01".len]u8, @bitCast(@as([700]["é中🙂\n\\\"/\x01".len]u8, @splat("é中🙂\n\\\"/\x01".*))));
    const mixed_expected = &@as([700 * "é中🙂\\n\\\\\\\"/\\u0001".len]u8, @bitCast(@as([700]["é中🙂\\n\\\\\\\"/\\u0001".len]u8, @splat("é中🙂\\n\\\\\\\"/\\u0001".*))));
    const mixed_cuts = [_]u64{ 1, 4, window_bytes - 1, window_bytes, window_bytes + 1, mixed.len - 1 };
    for ([_][]const usize{ &.{1}, &.{ 2, 7 }, &.{4095}, &.{4096}, &.{4097}, &.{16384} }) |seq| {
        try runJsonCase("json repeated escape windows", mixed, &mixed_cuts, seq, mixed_expected, mixed.len + mixed_expected.len);
    }
}

test "request encoding raw copies nested schema exactly" {
    const schema = "{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}},\"nested\":[1,{\"a\":\"b\\\"c\"}]}";
    const raw_seqs = [_][]const usize{ &.{1}, &.{7}, &.{ 1, 9 }, &.{ 3, 1, 4 } };
    try runRawCase("raw empty", "", &.{}, &.{1});
    for (raw_seqs) |seq| try runRawCase("raw schema unsplit", schema, &.{}, seq);
    var i: usize = 0;
    while (i <= schema.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == schema.len) &.{} else boundary_storage[0..];
        for (raw_seqs) |seq| try runRawCase("raw schema split", schema, boundaries, seq);
    }
    var window_input: [window_bytes + 1]u8 = undefined;
    @memset(&window_input, 'x');
    for ([_]usize{ window_bytes - 1, window_bytes, window_bytes + 1 }) |split| {
        const boundary = [_]u64{@intCast(split)};
        for (raw_seqs) |seq| try runRawCase("raw window split", &window_input, &boundary, seq);
    }
    var raw_seed_buf: [6]u64 = undefined;
    const raw_seeded = seededBoundaries(0x27d4eb2f, window_input.len, &raw_seed_buf);
    var raw_allowance_buf: [4]usize = undefined;
    try runRawCase("raw window seeded", &window_input, raw_seeded, seededAllowances(0x165667b1, &raw_allowance_buf, 16384));
    var cursor = RawCursor{};
    const source = ShortReadSource{ .bytes = "abcdef" };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var left: usize = 64;
    try std.testing.expectError(error.ShortCanonicalRead, cursor.advance(source, &sink, &left));
}

test "request encoding plain runs batch writes and conserve allowance" {
    const Sink = struct {
        calls: usize = 0,
        bytes: usize = 0,
        pub fn write(self: *@This(), value: []const u8) !void {
            self.calls += 1;
            self.bytes += value.len;
        }
    };
    const text = &@as([256 * 1024]u8, @splat('x'));
    var sink: Sink = .{};
    var position: usize = 0;
    const production_allowance = 16 * 1024;
    while (position != text.len) {
        var allowance: usize = production_allowance;
        const count = try writePlainJsonRun(&sink, text[position..], &allowance);
        try std.testing.expect(count != 0);
        try std.testing.expectEqual(production_allowance, allowance + 2 * count);
        position += count;
    }
    try std.testing.expectEqual(text.len, sink.bytes);
    try std.testing.expectEqual(@as(usize, 32), sink.calls);
}

/// cursor rereads retained bytes during the copy pass.
const ShortCopySource = struct {
    bytes: []const u8,
    high: u64 = 0,

    pub fn contentLength(self: *ShortCopySource) u64 {
        return self.bytes.len;
    }

    pub fn maxWindow(self: *ShortCopySource, offset: u64, wanted: usize) usize {
        _ = self;
        _ = offset;
        return wanted;
    }

    pub fn readContent(self: *ShortCopySource, offset: u64, destination: []u8) !usize {
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.RangeOutOfBounds;
        if (offset < self.high) {
            const short = destination.len -| 1;
            @memcpy(destination[0..short], self.bytes[start..][0..short]);
            return short;
        }
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        self.high = @max(self.high, offset + destination.len);
        return destination.len;
    }
};
