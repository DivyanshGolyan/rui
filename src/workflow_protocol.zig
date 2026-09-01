const std = @import("std");

pub const version: u16 = 1;
pub const request_magic = "OPWE";
pub const outcome_magic = "OPWO";

pub const Limits = struct {
    pub const source_bytes: usize = 64 * 1024;
    pub const arguments_bytes: usize = 64 * 1024;
    pub const visible_output_bytes: usize = 512 * 1024;
    pub const input_frame_bytes: usize = 768 * 1024;
    pub const output_frame_bytes: usize = 512 * 1024;
    pub const bridge_arena_bytes: usize = 2 * 1024 * 1024;
    pub const engine_heap_bytes: usize = 16 * 1024 * 1024;
    pub const engine_stack_bytes: usize = 512 * 1024;
    pub const workflow_output_bytes: usize = 64 * 1024;
    pub const diagnostic_bytes: usize = 4 * 1024;
    pub const pending_agent_calls: usize = 256;
    pub const data_depth: usize = 32;
    pub const data_entries: usize = 4096;
    pub const microtasks: usize = 4_096;
    pub const cpu_milliseconds: u64 = 1_000;
    pub const cpu_seconds: u64 = 2;
    pub const wall_milliseconds: u64 = 5_000;
    pub const process_address_space_bytes: u64 = 64 * 1024 * 1024;
};

pub const DataTag = enum(u8) {
    null_value = 0,
    false_value = 1,
    true_value = 2,
    number = 3,
    string = 4,
    array = 5,
    object = 6,
};

pub const VisibleTag = enum(u8) {
    output = 0,
    failure = 1,
};

pub const OutcomeTag = enum(u8) {
    completed = 0,
    blocked = 1,
    failed = 2,
    deadlocked = 3,
    resource_exceeded = 4,
    protocol_failed = 5,
};

pub const ProtocolError = error{
    InvalidMagic,
    UnsupportedVersion,
    Truncated,
    TrailingBytes,
    InvalidTag,
    InvalidUtf8,
    LoneSurrogate,
    NonFiniteNumber,
    UnsafeInteger,
    ExcessiveDepth,
    ExcessiveEntries,
    ExcessiveBytes,
    DuplicateKey,
    OutOfMemory,
};

pub const EntryBudget = struct {
    used: usize = 0,

    pub fn add(self: *EntryBudget, count: usize) ProtocolError!void {
        self.used = std.math.add(usize, self.used, count) catch
            return error.ExcessiveEntries;
        if (self.used > Limits.data_entries) return error.ExcessiveEntries;
    }
};

pub const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Cursor {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: Cursor) usize {
        return self.bytes.len - self.index;
    }

    pub fn finish(self: Cursor) ProtocolError!void {
        if (self.index != self.bytes.len) return error.TrailingBytes;
    }

    pub fn readByte(self: *Cursor) ProtocolError!u8 {
        if (self.index == self.bytes.len) return error.Truncated;
        defer self.index += 1;
        return self.bytes[self.index];
    }

    pub fn readInt(self: *Cursor, comptime T: type) ProtocolError!T {
        const size = @sizeOf(T);
        if (self.remaining() < size) return error.Truncated;
        const result = std.mem.readInt(T, self.bytes[self.index..][0..size], .little);
        self.index += size;
        return result;
    }

    pub fn readBytes(self: *Cursor, len: usize) ProtocolError![]const u8 {
        if (len > self.remaining()) return error.Truncated;
        const result = self.bytes[self.index..][0..len];
        self.index += len;
        return result;
    }

    pub fn readLengthBytes(self: *Cursor, maximum: usize) ProtocolError![]const u8 {
        const len = try self.readInt(u32);
        if (len > maximum) return error.ExcessiveBytes;
        return self.readBytes(len);
    }

    pub fn readString(self: *Cursor, maximum: usize) ProtocolError![]const u8 {
        const result = try self.readLengthBytes(maximum);
        try validateScalarUtf8(result);
        return result;
    }

    pub fn skipValue(self: *Cursor, maximum_bytes: usize) ProtocolError![]const u8 {
        var budget = EntryBudget{};
        const start = self.index;
        try self.skipValueDepth(0, null, &budget);
        const result = self.bytes[start..self.index];
        if (result.len > maximum_bytes) return error.ExcessiveBytes;
        return result;
    }

    pub fn skipValueExact(
        self: *Cursor,
        maximum_bytes: usize,
        key_storage: [][]const u8,
    ) ProtocolError![]const u8 {
        var keys = KeyScratch{ .storage = key_storage };
        var budget = EntryBudget{};
        const start = self.index;
        try self.skipValueDepth(0, &keys, &budget);
        const result = self.bytes[start..self.index];
        if (result.len > maximum_bytes) return error.ExcessiveBytes;
        return result;
    }

    const KeyScratch = struct {
        storage: [][]const u8,
        used: usize = 0,
    };

    fn skipValueDepth(
        self: *Cursor,
        depth: usize,
        keys: ?*KeyScratch,
        budget: *EntryBudget,
    ) ProtocolError!void {
        if (depth > Limits.data_depth) return error.ExcessiveDepth;
        const tag = std.enums.fromInt(DataTag, try self.readByte()) orelse return error.InvalidTag;
        switch (tag) {
            .null_value, .false_value, .true_value => {},
            .number => {
                const bits = try self.readInt(u64);
                try validateNumber(@bitCast(bits));
            },
            .string => _ = try self.readString(Limits.output_frame_bytes),
            .array => {
                const count = try self.readInt(u32);
                try budget.add(count);
                for (0..count) |_| try self.skipValueDepth(depth + 1, keys, budget);
            },
            .object => {
                const count = try self.readInt(u32);
                try budget.add(count);
                const key_start = if (keys) |scratch| start: {
                    if (count > scratch.storage.len - scratch.used) return error.ExcessiveEntries;
                    const start = scratch.used;
                    scratch.used += count;
                    break :start start;
                } else 0;
                defer if (keys) |scratch| {
                    scratch.used = key_start;
                };
                for (0..count) |index| {
                    const key = try self.readString(Limits.output_frame_bytes);
                    if (keys) |scratch| {
                        scratch.storage[key_start + index] = key;
                    }
                    try self.skipValueDepth(depth + 1, keys, budget);
                }
                if (keys) |scratch| {
                    const object_keys = scratch.storage[key_start .. key_start + count];
                    std.mem.sort([]const u8, object_keys, {}, struct {
                        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                            return std.mem.lessThan(u8, lhs, rhs);
                        }
                    }.lessThan);
                    if (object_keys.len > 1) {
                        for (object_keys[1..], object_keys[0 .. object_keys.len - 1]) |current, previous| {
                            if (std.mem.eql(u8, current, previous)) return error.DuplicateKey;
                        }
                    }
                }
            },
        }
    }
};

pub const Builder = struct {
    bytes: []u8,
    index: usize = 0,

    pub fn init(bytes: []u8) Builder {
        return .{ .bytes = bytes };
    }

    pub fn written(self: Builder) []const u8 {
        return self.bytes[0..self.index];
    }

    pub fn writeByte(self: *Builder, value: u8) ProtocolError!void {
        if (self.index == self.bytes.len) return error.ExcessiveBytes;
        self.bytes[self.index] = value;
        self.index += 1;
    }

    pub fn writeInt(self: *Builder, comptime T: type, value: T) ProtocolError!void {
        const size = @sizeOf(T);
        if (self.bytes.len - self.index < size) return error.ExcessiveBytes;
        std.mem.writeInt(T, self.bytes[self.index..][0..size], value, .little);
        self.index += size;
    }

    pub fn writeBytes(self: *Builder, value: []const u8) ProtocolError!void {
        if (value.len > self.bytes.len - self.index) return error.ExcessiveBytes;
        @memcpy(self.bytes[self.index..][0..value.len], value);
        self.index += value.len;
    }

    pub fn writeLengthBytes(self: *Builder, value: []const u8) ProtocolError!void {
        if (value.len > std.math.maxInt(u32)) return error.ExcessiveBytes;
        try self.writeInt(u32, @intCast(value.len));
        try self.writeBytes(value);
    }

    pub fn writeString(self: *Builder, value: []const u8) ProtocolError!void {
        try validateScalarUtf8(value);
        try self.writeLengthBytes(value);
    }
};

pub fn writeHeader(builder: *Builder, magic: *const [4:0]u8) ProtocolError!void {
    try builder.writeBytes(magic[0..4]);
    try builder.writeInt(u16, version);
}

pub fn readHeader(cursor: *Cursor, magic: *const [4:0]u8) ProtocolError!void {
    if (!std.mem.eql(u8, try cursor.readBytes(4), magic[0..4])) return error.InvalidMagic;
    if (try cursor.readInt(u16) != version) return error.UnsupportedVersion;
}

pub fn validateNumber(value: f64) ProtocolError!void {
    if (!std.math.isFinite(value)) return error.NonFiniteNumber;
    if (@trunc(value) == value and @abs(value) > 9_007_199_254_740_991.0) {
        return error.UnsafeInteger;
    }
}

pub fn validateScalarUtf8(bytes: []const u8) ProtocolError!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.LoneSurrogate;
    }
}

test "protocol value validation is bounded and exact" {
    var bytes: [64]u8 = undefined;
    var builder = Builder.init(&bytes);
    try builder.writeByte(@intFromEnum(DataTag.object));
    try builder.writeInt(u32, 1);
    try builder.writeString("answer");
    try builder.writeByte(@intFromEnum(DataTag.number));
    try builder.writeInt(u64, @bitCast(@as(f64, -0.0)));

    var cursor = Cursor.init(builder.written());
    _ = try cursor.skipValue(64);
    try cursor.finish();
}

test "protocol rejects truncation, non-finite numbers, and trailing bytes" {
    var truncated = Cursor.init(&.{ @intFromEnum(DataTag.string), 4, 0, 0, 0, 'a' });
    try std.testing.expectError(error.Truncated, truncated.skipValue(64));

    var non_finite_bytes: [9]u8 = undefined;
    var builder = Builder.init(&non_finite_bytes);
    try builder.writeByte(@intFromEnum(DataTag.number));
    try builder.writeInt(u64, @bitCast(std.math.inf(f64)));
    var non_finite = Cursor.init(builder.written());
    try std.testing.expectError(error.NonFiniteNumber, non_finite.skipValue(64));

    var trailing = Cursor.init(&.{ @intFromEnum(DataTag.null_value), 0 });
    _ = try trailing.skipValue(64);
    try std.testing.expectError(error.TrailingBytes, trailing.finish());
}

test "exact protocol validation rejects duplicate object keys" {
    var bytes: [64]u8 = undefined;
    var builder = Builder.init(&bytes);
    try builder.writeByte(@intFromEnum(DataTag.object));
    try builder.writeInt(u32, 2);
    try builder.writeString("same");
    try builder.writeByte(@intFromEnum(DataTag.null_value));
    try builder.writeString("same");
    try builder.writeByte(@intFromEnum(DataTag.true_value));

    var key_storage: [Limits.data_entries][]const u8 = undefined;
    var cursor = Cursor.init(builder.written());
    try std.testing.expectError(
        error.DuplicateKey,
        cursor.skipValueExact(bytes.len, &key_storage),
    );
}

test "entry budget is cumulative within one value and resets between values" {
    var bytes: [32 * 1024]u8 = undefined;
    var builder = Builder.init(&bytes);
    try builder.writeByte(@intFromEnum(DataTag.array));
    try builder.writeInt(u32, 2049);
    for (0..2049) |_| {
        try builder.writeByte(@intFromEnum(DataTag.array));
        try builder.writeInt(u32, 1);
        try builder.writeByte(@intFromEnum(DataTag.null_value));
    }
    var excessive = Cursor.init(builder.written());
    try std.testing.expectError(
        error.ExcessiveEntries,
        excessive.skipValue(bytes.len),
    );

    builder.index = 0;
    for (0..2) |_| {
        try builder.writeByte(@intFromEnum(DataTag.array));
        try builder.writeInt(u32, 3000);
        for (0..3000) |_| try builder.writeByte(@intFromEnum(DataTag.null_value));
    }
    var independent = Cursor.init(builder.written());
    _ = try independent.skipValue(bytes.len);
    _ = try independent.skipValue(bytes.len);
    try independent.finish();
}
