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
    encoded: [6]u8 = undefined,
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
            const encoded = switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x0c => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...0x07, 0x0b, 0x0e...0x1f => {
                    const hex = "0123456789abcdef";
                    self.encoded = .{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };
                    self.encoded_length = 6;
                    self.encoded_offset = 0;
                    continue;
                },
                else => {
                    // A one-byte allowance can consume a source byte now
                    // and emit it on the next advance, without overshoot.
                    self.encoded[0] = byte;
                    self.encoded_length = 1;
                    self.encoded_offset = 0;
                    continue;
                },
            };
            @memcpy(self.encoded[0..encoded.len], encoded);
            self.encoded_length = @intCast(encoded.len);
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

pub const ReplayProgress = enum { pending, done };

/// Incrementally rebuilds one trusted canonical provider item while omitting
/// only the top-level `created_by` field. Source scans and retained-field
/// copies both consume the caller's byte allowance.
pub const ReplayCursor = struct {
    phase: Phase = .open,
    position: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [window_bytes]u8 = undefined,
    field_start: u64 = 0,
    field_end: u64 = 0,
    copy_position: u64 = 0,
    copy_buffer_length: usize = 0,
    copy_buffer_offset: usize = 0,
    emitted: bool = false,
    omit_field: bool = false,
    key_matches: bool = true,
    key_index: usize = 0,
    unicode_value: u21 = 0,
    unicode_digits: u3 = 0,
    value_depth: usize = 0,
    value_in_string: bool = false,
    value_escape: bool = false,
    value_unicode_digits: u3 = 0,
    root_string: bool = false,
    primitive: bool = false,
    delimiter: enum { more, end } = .end,

    const Phase = enum {
        open,
        object_start,
        field_start,
        key,
        key_escape,
        key_unicode,
        colon,
        value_start,
        value,
        after_value,
        copy_comma,
        copy_field,
        source_end,
        close,
        done,
    };

    pub fn advance(
        self: *ReplayCursor,
        source: anytype,
        writer: anytype,
        bytes_left: *usize,
        items_left: *usize,
    ) !ReplayProgress {
        const created_by = "created_by";
        while (bytes_left.* != 0 and items_left.* != 0) switch (self.phase) {
            .open => {
                try writer.write("{");
                bytes_left.* -= 1;
                self.phase = .object_start;
            },
            .object_start => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (isSpace(byte)) continue;
                if (byte != '{') return error.UnexpectedJsonDelimiter;
                self.phase = .field_start;
            },
            .field_start => {
                const byte = try self.peek(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (isSpace(byte)) {
                    _ = try self.take(source, bytes_left);
                    continue;
                }
                if (byte == '}') {
                    _ = try self.take(source, bytes_left);
                    self.phase = .source_end;
                    continue;
                }
                if (byte != '"') return error.UnexpectedJsonDelimiter;
                items_left.* -= 1;
                self.field_start = self.position;
                self.key_matches = true;
                self.key_index = 0;
                _ = try self.take(source, bytes_left);
                self.phase = .key;
            },
            .key => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                switch (byte) {
                    '"' => {
                        self.omit_field = self.key_matches and self.key_index == created_by.len;
                        self.phase = .colon;
                    },
                    '\\' => self.phase = .key_escape,
                    0...0x1f => return error.InvalidJsonString,
                    else => self.matchKeyByte(byte),
                }
            },
            .key_escape => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                switch (byte) {
                    '"', '\\', '/' => {
                        self.matchKeyByte(byte);
                        self.phase = .key;
                    },
                    'b' => {
                        self.matchKeyByte(0x08);
                        self.phase = .key;
                    },
                    'f' => {
                        self.matchKeyByte(0x0c);
                        self.phase = .key;
                    },
                    'n' => {
                        self.matchKeyByte('\n');
                        self.phase = .key;
                    },
                    'r' => {
                        self.matchKeyByte('\r');
                        self.phase = .key;
                    },
                    't' => {
                        self.matchKeyByte('\t');
                        self.phase = .key;
                    },
                    'u' => {
                        self.unicode_value = 0;
                        self.unicode_digits = 0;
                        self.phase = .key_unicode;
                    },
                    else => return error.InvalidJsonEscape,
                }
            },
            .key_unicode => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                self.unicode_value = self.unicode_value * 16 + (std.fmt.charToDigit(byte, 16) catch return error.InvalidJsonEscape);
                self.unicode_digits += 1;
                if (self.unicode_digits == 4) {
                    if (self.unicode_value <= std.math.maxInt(u8)) {
                        self.matchKeyByte(@intCast(self.unicode_value));
                    } else self.key_matches = false;
                    self.phase = .key;
                }
            },
            .colon => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (isSpace(byte)) continue;
                if (byte != ':') return error.UnexpectedJsonDelimiter;
                self.phase = .value_start;
            },
            .value_start => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (isSpace(byte)) continue;
                self.value_depth = 0;
                self.value_in_string = false;
                self.value_escape = false;
                self.value_unicode_digits = 0;
                self.root_string = false;
                self.primitive = false;
                switch (byte) {
                    '{', '[' => self.value_depth = 1,
                    '"' => {
                        self.value_in_string = true;
                        self.root_string = true;
                    },
                    '}', ']' => return error.UnexpectedJsonDelimiter,
                    else => self.primitive = true,
                }
                self.field_end = self.position;
                self.phase = .value;
            },
            .value => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (self.value_in_string) {
                    if (self.value_unicode_digits != 0) {
                        _ = std.fmt.charToDigit(byte, 16) catch return error.InvalidJsonEscape;
                        self.value_unicode_digits -= 1;
                    } else if (self.value_escape) {
                        self.value_escape = false;
                        if (byte == 'u') self.value_unicode_digits = 4;
                    } else if (byte == '\\') {
                        self.value_escape = true;
                    } else if (byte == '"') {
                        self.value_in_string = false;
                        if (self.root_string) {
                            self.field_end = self.position;
                            self.phase = .after_value;
                        }
                    } else if (byte <= 0x1f) return error.InvalidJsonString;
                    continue;
                }
                if (self.primitive) {
                    if (byte == ',' or byte == '}') {
                        self.delimiter = if (byte == ',') .more else .end;
                        self.prepareCopy();
                    } else if (isSpace(byte)) {
                        self.phase = .after_value;
                    } else self.field_end = self.position;
                    continue;
                }
                switch (byte) {
                    '"' => self.value_in_string = true,
                    '{', '[' => self.value_depth += 1,
                    '}', ']' => {
                        if (self.value_depth == 0) return error.UnexpectedJsonDelimiter;
                        self.value_depth -= 1;
                        if (self.value_depth == 0) {
                            self.field_end = self.position;
                            self.phase = .after_value;
                        }
                    },
                    else => {},
                }
            },
            .after_value => {
                const byte = try self.take(source, bytes_left) orelse return error.UnexpectedJsonEnd;
                if (isSpace(byte)) continue;
                if (byte != ',' and byte != '}') return error.UnexpectedJsonDelimiter;
                self.delimiter = if (byte == ',') .more else .end;
                self.prepareCopy();
            },
            .copy_comma => {
                try writer.write(",");
                bytes_left.* -= 1;
                self.phase = .copy_field;
            },
            .copy_field => {
                if (self.copy_buffer_offset != self.copy_buffer_length) {
                    const count = @min(bytes_left.*, self.copy_buffer_length - self.copy_buffer_offset);
                    try writer.write(self.buffer[self.copy_buffer_offset..][0..count]);
                    self.copy_buffer_offset += count;
                    bytes_left.* -= count;
                    continue;
                }
                const remaining = self.field_end - self.copy_position;
                if (remaining == 0) {
                    self.emitted = true;
                    self.finishField();
                    continue;
                }
                var wanted: usize = @intCast(@min(remaining, @min(bytes_left.*, self.buffer.len)));
                wanted = source.maxWindow(self.copy_position, wanted);
                if (wanted == 0) return .pending;
                const count = try source.readContent(self.copy_position, self.buffer[0..wanted]);
                if (count != wanted) return error.ShortCanonicalRead;
                self.copy_position += count;
                self.copy_buffer_length = count;
                self.copy_buffer_offset = 0;
                // Copying reuses the scan window's storage. Invalidate its
                // range before the parser resumes at the saved source cursor.
                self.buffer_start = self.position;
                self.buffer_length = 0;
                bytes_left.* -= count;
            },
            .source_end => {
                const byte = try self.peek(source, bytes_left) orelse {
                    self.phase = .close;
                    continue;
                };
                if (!isSpace(byte)) return error.TrailingJson;
                _ = try self.take(source, bytes_left);
            },
            .close => {
                try writer.write("}");
                bytes_left.* -= 1;
                self.phase = .done;
            },
            .done => return .done,
        };
        return if (self.phase == .done) .done else .pending;
    }

    fn prepareCopy(self: *ReplayCursor) void {
        if (self.omit_field) {
            self.finishField();
            return;
        }
        self.copy_position = self.field_start;
        self.copy_buffer_length = 0;
        self.copy_buffer_offset = 0;
        self.phase = if (self.emitted) .copy_comma else .copy_field;
    }

    fn finishField(self: *ReplayCursor) void {
        self.phase = if (self.delimiter == .more) .field_start else .source_end;
    }

    fn matchKeyByte(self: *ReplayCursor, byte: u8) void {
        const created_by = "created_by";
        if (self.key_matches and (self.key_index >= created_by.len or created_by[self.key_index] != byte)) {
            self.key_matches = false;
        }
        self.key_index += 1;
    }

    fn peek(self: *ReplayCursor, source: anytype, bytes_left: *usize) !?u8 {
        if (self.position >= source.contentLength()) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            if (bytes_left.* == 0) return null;
            self.buffer_start = self.position;
            var wanted: usize = @intCast(@min(source.contentLength() - self.position, @min(self.buffer.len, bytes_left.*)));
            wanted = source.maxWindow(self.position, wanted);
            if (wanted == 0) return null;
            const count = try source.readContent(self.position, self.buffer[0..wanted]);
            if (count != wanted) return error.ShortCanonicalRead;
            self.buffer_length = count;
        }
        return self.buffer[@intCast(self.position - self.buffer_start)];
    }

    fn take(self: *ReplayCursor, source: anytype, bytes_left: *usize) !?u8 {
        if (bytes_left.* == 0) return null;
        const byte = try self.peek(source, bytes_left) orelse return null;
        self.position += 1;
        bytes_left.* -= 1;
        return byte;
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

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

const ReplayExpect = struct {
    expected: []const u8,
    // Independently authored retained top-level field bytes. The byte
    // oracle is input length (one scan debit per source byte) plus twice
    // the retained bytes (copy read plus copy emit) plus framing.
    retained_bytes: usize,
    retained_count: usize,
    // Top-level input fields; each consumes exactly one item allowance.
    input_fields: usize,
};

fn replayWork(input_len: usize, expect: ReplayExpect) usize {
    const commas: usize = if (expect.retained_count == 0) 0 else expect.retained_count - 1;
    return input_len + 2 * expect.retained_bytes + 2 + commas;
}

fn runReplayCase(case: []const u8, input: []const u8, boundaries: []const u64, byte_seq: []const usize, item_seq: []const usize, expect: ReplayExpect) !void {
    var cursor = ReplayCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    const bound = 4 * (input.len + expect.expected.len) + 64;
    var total_bytes: usize = 0;
    var total_items: usize = 0;
    while (true) {
        steps += 1;
        if (steps > bound) {
            failCtx(case, input.len, boundaries, byte_seq, item_seq, steps);
            return error.TooManySteps;
        }
        const byte_allowance = byte_seq[(steps - 1) % byte_seq.len];
        const item_allowance = item_seq[(steps - 1) % item_seq.len];
        try std.testing.expect(byte_allowance != 0 and item_allowance != 0);
        var bytes_left = byte_allowance;
        var items_left = item_allowance;
        const progress = try cursor.advance(source, &sink, &bytes_left, &items_left);
        total_bytes += byte_allowance - bytes_left;
        total_items += item_allowance - items_left;
        try std.testing.expect(sink.output.items.len <= expect.expected.len + 16);
        if (progress == .pending and bytes_left == byte_allowance) {
            failCtx(case, input.len, boundaries, byte_seq, item_seq, steps);
            std.debug.print("zero-progress stall phase={s} position={d}\n", .{ @tagName(cursor.phase), cursor.position });
            return error.ZeroProgressStall;
        }
        if (progress == .done) break;
    }
    const expected_work = replayWork(input.len, expect);
    if (!std.mem.eql(u8, expect.expected, sink.output.items) or total_bytes != expected_work or total_items != expect.input_fields) {
        failCtx(case, input.len, boundaries, byte_seq, item_seq, steps);
        std.debug.print("phase={s} position={d} emitted={d}/{d} work={d}/{d} items={d}/{d}\n", .{
            @tagName(cursor.phase),
            cursor.position,
            sink.output.items.len,
            expect.expected.len,
            total_bytes,
            expected_work,
            total_items,
            expect.input_fields,
        });
        try std.testing.expectEqualStrings(expect.expected, sink.output.items);
        try std.testing.expectEqual(expected_work, total_bytes);
        try std.testing.expectEqual(expect.input_fields, total_items);
    }
}

fn runReplaySchedules(case: []const u8, input: []const u8, expect: ReplayExpect) !void {
    // Every single split position under all byte/item sequence pairings.
    const byte_seqs = [_][]const usize{ &.{1}, &.{2}, &.{3}, &.{7}, &.{ 1, 7 }, &.{ 5, 2, 9 } };
    const item_seqs = [_][]const usize{ &.{1}, &.{2}, &.{64}, &.{ 2, 1 }, &.{ 3, 64, 1 } };
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == input.len) &.{} else boundary_storage[0..];
        for (byte_seqs) |byte_seq| {
            for (item_seqs) |item_seq| {
                try runReplayCase(case, input, boundaries, byte_seq, item_seq, expect);
            }
        }
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
    const text = "x" ** (256 * 1024);
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

test "request encoding replay omits only top-level created_by" {
    // Retained byte counts name each kept field; the run will confirm them.
    try runReplaySchedules("replay golden", "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"created_by\":\"drop\",\"extension\":{\"created_by\":\"keep\"}}", .{
        .expected = "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"extension\":{\"created_by\":\"keep\"}}",
        .retained_bytes = 18 + 28 + 33,
        .retained_count = 3,
        .input_fields = 4,
    });
    try runReplaySchedules("replay created_by first", "{\"created_by\":\"drop\",\"type\":\"reasoning\"}", .{
        .expected = "{\"type\":\"reasoning\"}",
        .retained_bytes = 18,
        .retained_count = 1,
        .input_fields = 2,
    });
    try runReplaySchedules("replay created_by last", "{\"type\":\"reasoning\",\"created_by\":\"drop\"}", .{
        .expected = "{\"type\":\"reasoning\"}",
        .retained_bytes = 18,
        .retained_count = 1,
        .input_fields = 2,
    });
    try runReplaySchedules("replay only created_by", "{\"created_by\":\"only\"}", .{
        .expected = "{}",
        .retained_bytes = 0,
        .retained_count = 0,
        .input_fields = 1,
    });
    try runReplaySchedules("replay nested keep", "{\"type\":\"reasoning\",\"extension\":{\"created_by\":\"keep\"}}", .{
        .expected = "{\"type\":\"reasoning\",\"extension\":{\"created_by\":\"keep\"}}",
        .retained_bytes = 18 + 33,
        .retained_count = 2,
        .input_fields = 2,
    });
    // Escaped spelling of the key still omits the field.
    try runReplaySchedules("replay escaped key", "{\"type\":\"reasoning\",\"cre\\u0061ted_by\":\"drop\",\"id\":\"keep\"}", .{
        .expected = "{\"type\":\"reasoning\",\"id\":\"keep\"}",
        .retained_bytes = 18 + 11,
        .retained_count = 2,
        .input_fields = 3,
    });
    // Similar nonmatching names remain.
    try runReplaySchedules("replay similar names", "{\"type\":\"reasoning\",\"created_byx\":\"keep\",\"created_b\":\"keep\"}", .{
        .expected = "{\"type\":\"reasoning\",\"created_byx\":\"keep\",\"created_b\":\"keep\"}",
        .retained_bytes = 18 + 20 + 18,
        .retained_count = 3,
        .input_fields = 3,
    });
}

test "request encoding replay preserves nested values and escapes" {
    try runReplaySchedules("replay nested", "{\"type\":\"reasoning\",\"nested\":{\"a\":[1,2,{\"b\":null}]},\"created_by\":\"drop\"}", .{
        .expected = "{\"type\":\"reasoning\",\"nested\":{\"a\":[1,2,{\"b\":null}]}}",
        .retained_bytes = 18 + 31,
        .retained_count = 2,
        .input_fields = 3,
    });
    try runReplaySchedules("replay escapes", "{\"type\":\"reasoning\",\"text\":\"a\\\"b\\\\c\",\"created_by\":\"drop\"}", .{
        .expected = "{\"type\":\"reasoning\",\"text\":\"a\\\"b\\\\c\"}",
        .retained_bytes = 18 + 16,
        .retained_count = 2,
        .input_fields = 3,
    });
    try runReplaySchedules("replay unicode", "{\"type\":\"reasoning\",\"text\":\"a\\u00e9\\uD83D\\uDE00\",\"created_by\":\"drop\"}", .{
        .expected = "{\"type\":\"reasoning\",\"text\":\"a\\u00e9\\uD83D\\uDE00\"}",
        .retained_bytes = 18 + 28,
        .retained_count = 2,
        .input_fields = 3,
    });
    try runReplaySchedules("replay whitespace", " { \"type\" : \"reasoning\" , \"created_by\" : \"drop\" , \"id\" : 1 } ", .{
        .expected = "{\"type\" : \"reasoning\",\"id\" : 1}",
        .retained_bytes = 20 + 8,
        .retained_count = 2,
        .input_fields = 3,
    });
    try runReplaySchedules("replay primitives", "{\"type\":\"reasoning\",\"a\":1}", .{
        .expected = "{\"type\":\"reasoning\",\"a\":1}",
        .retained_bytes = 18 + 5,
        .retained_count = 2,
        .input_fields = 2,
    });
}

test "request encoding replay invalidates scan window after retained copy" {
    // Multiple retained fields force scan-ahead, copy through the shared
    // buffer, then resume scanning from the saved source cursor.
    const input = "{\"id\":\"first-retained\",\"created_by\":\"drop\",\"second\":\"kept-value\",\"third\":{\"nested\":[1,2,3]}}";
    const expect: ReplayExpect = .{
        .expected = "{\"id\":\"first-retained\",\"second\":\"kept-value\",\"third\":{\"nested\":[1,2,3]}}",
        .retained_bytes = 21 + 21 + 26,
        .retained_count = 3,
        .input_fields = 4,
    };
    const cuts = [_]u64{ 3, 8, 15, 31, 63 };
    const cut_byte_seqs = [_][]const usize{ &.{1}, &.{ 2, 3 }, &.{7}, &.{ 4, 1 } };
    const cut_item_seqs = [_][]const usize{ &.{1}, &.{2}, &.{64}, &.{ 3, 1 } };
    for (cut_byte_seqs, 0..) |byte_seq, k| {
        try runReplayCase("replay invalidation cuts", input, &cuts, byte_seq, cut_item_seqs[k % cut_item_seqs.len], expect);
    }
    var seed_buf: [7]u64 = undefined;
    const seeded = seededBoundaries(0x51ed2701, input.len, &seed_buf);
    var allowance_buf: [4]usize = undefined;
    try runReplayCase(
        "replay invalidation seeded",
        input,
        seeded,
        seededAllowances(0x0ddc0ffe, &allowance_buf, 64),
        &.{3},
        expect,
    );
    var retained: [8192]u8 = undefined;
    @memset(&retained, 'r');
    var discarded: [8192]u8 = undefined;
    @memset(&discarded, 'd');
    var buf: [256 + 8192 * 2 + 64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try stream.writeAll("{\"type\":\"reasoning\",\"kept\":\"");
    try stream.writeAll(&retained);
    try stream.writeAll("\",\"created_by\":\"");
    try stream.writeAll(&discarded);
    try stream.writeAll("\"}");
    const large_input = stream.buffered();
    var expected_buf: [256 + 8192 + 64]u8 = undefined;
    var expected_stream = std.Io.Writer.fixed(&expected_buf);
    try expected_stream.writeAll("{\"type\":\"reasoning\",\"kept\":\"");
    try expected_stream.writeAll(&retained);
    try expected_stream.writeAll("\"}");
    const large_expected = expected_stream.buffered();
    const large_expect: ReplayExpect = .{
        .expected = large_expected,
        // `"type":"reasoning"` plus `"kept":"<8192 retained bytes>"`.
        .retained_bytes = 18 + 7 + 1 + 8192 + 1,
        .retained_count = 2,
        .input_fields = 3,
    };
    const large_cuts = [_]u64{ 1, 4095, 4096, 4097, 8192 };
    const large_byte_seqs = [_][]const usize{ &.{1}, &.{7}, &.{4096}, &.{16384}, &.{ 100, 7 }, &.{ 3, 5000, 1 } };
    for (large_byte_seqs) |byte_seq| {
        try runReplayCase("replay large cuts", large_input, &large_cuts, byte_seq, &.{64}, large_expect);
    }
    var large_seed_buf: [9]u64 = undefined;
    const large_seeded = seededBoundaries(0x2eedb207, large_input.len, &large_seed_buf);
    var large_allowance_buf: [5]usize = undefined;
    // A large discarded field must charge its scan debits: removing them
    // changes the byte oracle without changing the output bytes.
    try runReplayCase(
        "replay large seeded",
        large_input,
        large_seeded,
        seededAllowances(0x6d79616c, &large_allowance_buf, 16384),
        &.{ 7, 64 },
        large_expect,
    );
}

/// Serves full reads while scanning forward but short reads when the
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

test "request encoding replay short reads fail" {
    // A short scan refill must fail at the exact-read boundary.
    {
        var cursor = ReplayCursor{};
        const source = ShortReadSource{ .bytes = "{\"type\":\"reasoning\"}" };
        var sink = TestSink.init(std.testing.allocator);
        defer sink.deinit();
        var bytes_left: usize = 64;
        var items_left: usize = 64;
        try std.testing.expectError(error.ShortCanonicalRead, cursor.advance(source, &sink, &bytes_left, &items_left));
    }
    // A short reread during the retained-field copy pass must fail there
    // too; failing the first refill does not exercise the later read site.
    {
        var cursor = ReplayCursor{};
        var source = ShortCopySource{ .bytes = "{\"type\":\"reasoning\",\"id\":\"keep\"}" };
        var sink = TestSink.init(std.testing.allocator);
        defer sink.deinit();
        var bytes_left: usize = 16384;
        var items_left: usize = 64;
        try std.testing.expectError(error.ShortCanonicalRead, cursor.advance(&source, &sink, &bytes_left, &items_left));
    }
}

test "request encoding replay item allowance forces yields" {
    const input = "{\"a\":1,\"b\":2,\"c\":3}";
    const expect: ReplayExpect = .{
        .expected = "{\"a\":1,\"b\":2,\"c\":3}",
        .retained_bytes = 5 + 5 + 5,
        .retained_count = 3,
        .input_fields = 3,
    };
    var cursor = ReplayCursor{};
    const source = MemorySource{ .bytes = input };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var yields: usize = 0;
    var total_bytes: usize = 0;
    var total_items: usize = 0;
    while (true) {
        var bytes_left: usize = 16384;
        var items_left: usize = 1;
        const progress = try cursor.advance(source, &sink, &bytes_left, &items_left);
        total_bytes += 16384 - bytes_left;
        total_items += 1 - items_left;
        if (progress == .done) break;
        yields += 1;
        try std.testing.expect(yields < 16);
    }
    try std.testing.expectEqualStrings(expect.expected, sink.output.items);
    try std.testing.expect(yields >= 3);
    try std.testing.expectEqual(replayWork(input.len, expect), total_bytes);
    try std.testing.expectEqual(expect.input_fields, total_items);
}
