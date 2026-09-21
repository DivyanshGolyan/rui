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
                self.unicode_value = self.unicode_value * 16 + (hexDigit(byte) orelse return error.InvalidJsonEscape);
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
                        _ = hexDigit(byte) orelse return error.InvalidJsonEscape;
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

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
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

fn runJsonCase(input: []const u8, boundaries: []const u64, byte_allowance: usize, expected: []const u8) !void {
    var cursor = JsonCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    const bound = input.len + expected.len + 64;
    while (true) {
        steps += 1;
        try std.testing.expect(steps <= bound + 16);
        var left = byte_allowance;
        try std.testing.expect(left != 0);
        const done = try cursor.advance(source, &sink, &left);
        try std.testing.expect(left <= byte_allowance);
        if (done) break;
        try std.testing.expect(left == 0 or steps <= bound + 16);
        if (steps > bound + 16) return error.TooManySteps;
    }
    try std.testing.expectEqualStrings(expected, sink.output.items);
}

fn runJsonSchedules(input: []const u8, expected: []const u8) !void {
    // Every single split position plus unsplit and one-byte windows.
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == input.len) &.{} else boundary_storage[0..];
        for ([_]usize{ 1, 2, 3, 5, 6, 7 }) |allowance| {
            try runJsonCase(input, boundaries, allowance, expected);
        }
    }
    // One-byte windows over the whole input.
    var all: [256]u64 = undefined;
    const n: usize = @min(input.len, all.len);
    for (0..n) |index| all[index] = @intCast(index + 1);
    for ([_]usize{ 1, 2, 64 }) |allowance| {
        try runJsonCase(input, all[0..n], allowance, expected);
    }
}

fn runRawCase(input: []const u8, boundaries: []const u64, byte_allowance: usize) !void {
    var cursor = RawCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    const bound = 2 * input.len + 16;
    while (true) {
        steps += 1;
        try std.testing.expect(steps <= bound);
        var left = byte_allowance;
        const done = try cursor.advance(source, &sink, &left);
        try std.testing.expect(left <= byte_allowance);
        if (done) break;
    }
    try std.testing.expectEqualStrings(input, sink.output.items);
}

fn runReplayCase(input: []const u8, boundaries: []const u64, byte_allowance: usize, item_allowance: usize, expected: []const u8) !void {
    var cursor = ReplayCursor{};
    const source = PartitionedSource{ .bytes = input, .boundaries = boundaries };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var steps: usize = 0;
    const bound = 4 * (input.len + expected.len) + 64;
    var total_work: usize = 0;
    while (true) {
        steps += 1;
        try std.testing.expect(steps <= bound);
        var bytes_left = byte_allowance;
        var items_left = item_allowance;
        const progress = try cursor.advance(source, &sink, &bytes_left, &items_left);
        try std.testing.expect(bytes_left <= byte_allowance);
        try std.testing.expect(items_left <= item_allowance);
        total_work += (byte_allowance - bytes_left) + (item_allowance - items_left);
        try std.testing.expect(sink.output.items.len <= expected.len + 16);
        if (progress == .done) break;
    }
    try std.testing.expectEqualStrings(expected, sink.output.items);
    try std.testing.expect(total_work > 0 or expected.len == 2);
}

fn runReplaySchedules(input: []const u8, expected: []const u8) !void {
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == input.len) &.{} else boundary_storage[0..];
        for ([_]usize{ 1, 2, 3, 7 }) |byte_allowance| {
            for ([_]usize{ 1, 2, 64 }) |item_allowance| {
                try runReplayCase(input, boundaries, byte_allowance, item_allowance, expected);
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
    try runJsonSchedules("", "");
    try runJsonSchedules("abc", "abc");
    try runJsonSchedules("a\"b\\c", "a\\\"b\\\\c");
    try runJsonSchedules("\x08\x0c\n\r\t", "\\b\\f\\n\\r\\t");
    try runJsonSchedules("\x01\x0b\x1f", "\\u0001\\u000b\\u001f");
    // Plain run ending immediately before an escape.
    try runJsonSchedules("abc\"def", "abc\\\"def");
    // Two-, three- and four-byte UTF-8 sequences are preserved byte-wise.
    try runJsonSchedules("é☃𝄞", "é☃𝄞");
    try runJsonSchedules("xé\"y", "xé\\\"y");
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
    for ([_]usize{ window_bytes - 1, window_bytes, window_bytes + 1 }) |split| {
        const boundary = [_]u64{@intCast(split)};
        for ([_]usize{ 1, 2, 6, 7, 4096, 16384 }) |allowance| {
            try runJsonCase(&input, &boundary, allowance, expected);
        }
    }
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
    for ([_]usize{ 1, 5, 64, 16384 }) |allowance| {
        try runJsonCase(&big, &cuts, allowance, big_expected);
    }
}

test "request encoding raw copies nested schema exactly" {
    const schema = "{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}},\"nested\":[1,{\"a\":\"b\\\"c\"}]}";
    try runRawCase("", &.{}, 1);
    try runRawCase(schema, &.{}, 1);
    try runRawCase(schema, &.{}, 7);
    var i: usize = 0;
    while (i <= schema.len) : (i += 1) {
        var boundary_storage: [1]u64 = .{@intCast(i)};
        const boundaries: []const u64 = if (i == schema.len) &.{} else boundary_storage[0..];
        try runRawCase(schema, boundaries, 1);
        try runRawCase(schema, boundaries, 2);
    }
    var window_input: [window_bytes + 1]u8 = undefined;
    @memset(&window_input, 'x');
    for ([_]usize{ window_bytes - 1, window_bytes, window_bytes + 1 }) |split| {
        const boundary = [_]u64{@intCast(split)};
        try runRawCase(&window_input, &boundary, 1);
        try runRawCase(&window_input, &boundary, 4096);
    }
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
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"created_by\":\"drop\",\"extension\":{\"created_by\":\"keep\"}}",
        "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"extension\":{\"created_by\":\"keep\"}}",
    );
    try runReplaySchedules(
        "{\"created_by\":\"drop\",\"type\":\"reasoning\"}",
        "{\"type\":\"reasoning\"}",
    );
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"created_by\":\"drop\"}",
        "{\"type\":\"reasoning\"}",
    );
    try runReplaySchedules(
        "{\"created_by\":\"only\"}",
        "{}",
    );
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"extension\":{\"created_by\":\"keep\"}}",
        "{\"type\":\"reasoning\",\"extension\":{\"created_by\":\"keep\"}}",
    );
    // Escaped spelling of the key still omits the field.
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"cre\\u0061ted_by\":\"drop\",\"id\":\"keep\"}",
        "{\"type\":\"reasoning\",\"id\":\"keep\"}",
    );
    // Similar nonmatching names remain.
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"created_byx\":\"keep\",\"created_b\":\"keep\"}",
        "{\"type\":\"reasoning\",\"created_byx\":\"keep\",\"created_b\":\"keep\"}",
    );
}

test "request encoding replay preserves nested values and escapes" {
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"nested\":{\"a\":[1,2,{\"b\":null}]},\"created_by\":\"drop\"}",
        "{\"type\":\"reasoning\",\"nested\":{\"a\":[1,2,{\"b\":null}]}}",
    );
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"text\":\"a\\\"b\\\\c\",\"created_by\":\"drop\"}",
        "{\"type\":\"reasoning\",\"text\":\"a\\\"b\\\\c\"}",
    );
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"text\":\"a\\u00e9\\uD83D\\uDE00\",\"created_by\":\"drop\"}",
        "{\"type\":\"reasoning\",\"text\":\"a\\u00e9\\uD83D\\uDE00\"}",
    );
    try runReplaySchedules(
        " { \"type\" : \"reasoning\" , \"created_by\" : \"drop\" , \"id\" : 1 } ",
        "{\"type\" : \"reasoning\",\"id\" : 1}",
    );
    try runReplaySchedules(
        "{\"type\":\"reasoning\",\"a\":1}",
        "{\"type\":\"reasoning\",\"a\":1}",
    );
}

test "request encoding replay invalidates scan window after retained copy" {
    // Multiple retained fields force scan-ahead, copy through the shared
    // buffer, then resume scanning from the saved source cursor.
    const input = "{\"id\":\"first-retained\",\"created_by\":\"drop\",\"second\":\"kept-value\",\"third\":{\"nested\":[1,2,3]}}";
    const expected = "{\"id\":\"first-retained\",\"second\":\"kept-value\",\"third\":{\"nested\":[1,2,3]}}";
    const cuts = [_]u64{ 3, 8, 15, 31, 63 };
    for ([_]usize{ 1, 2, 3, 7 }) |byte_allowance| {
        for ([_]usize{ 1, 2, 64 }) |item_allowance| {
            try runReplayCase(input, &cuts, byte_allowance, item_allowance, expected);
        }
    }
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
    const large_cuts = [_]u64{ 1, 4095, 4096, 4097, 8192 };
    for ([_]usize{ 1, 7, 4096, 16384 }) |byte_allowance| {
        try runReplayCase(large_input, &large_cuts, byte_allowance, 64, large_expected);
    }
}

test "request encoding replay short reads fail" {
    var cursor = ReplayCursor{};
    const source = ShortReadSource{ .bytes = "{\"type\":\"reasoning\"}" };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var bytes_left: usize = 64;
    var items_left: usize = 64;
    const result = cursor.advance(source, &sink, &bytes_left, &items_left);
    if (result) |_| {} else |err| {
        try std.testing.expect(err == error.ShortCanonicalRead or err == error.UnexpectedJsonEnd);
    }
}

test "request encoding replay item allowance forces yields" {
    const input = "{\"a\":1,\"b\":2,\"c\":3}";
    const expected = "{\"a\":1,\"b\":2,\"c\":3}";
    var cursor = ReplayCursor{};
    const source = MemorySource{ .bytes = input };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var yields: usize = 0;
    while (true) {
        var bytes_left: usize = 16384;
        var items_left: usize = 1;
        const progress = try cursor.advance(source, &sink, &bytes_left, &items_left);
        if (progress == .done) break;
        yields += 1;
        try std.testing.expect(yields < 16);
    }
    try std.testing.expectEqualStrings(expected, sink.output.items);
    try std.testing.expect(yields >= 3);
}
