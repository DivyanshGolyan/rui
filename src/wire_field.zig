//! JSON field values the Host's reply decoders read: bounded strings and
//! arrays, closed enums, omittable fields and decimal IDs. Values only; the decoders in
//! protocol_reply.zig and client.zig own the reply shapes.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;

/// A JSON string of at most `limit` UTF-8 bytes, held inline.
pub fn JsonString(comptime limit: usize) type {
    return struct {
        value: Bounded(limit) = .{},

        pub fn slice(self: *const @This()) []const u8 {
            return self.value.slice();
        }

        pub fn eql(self: *const @This(), value: []const u8) bool {
            return self.value.eql(value);
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value.slice());
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
            if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            defer if (token == .allocated_string) allocator.free(token.allocated_string);
            var result: @This() = .{};
            result.value.set(switch (token) {
                .string, .allocated_string => |value| value,
                else => unreachable,
            }) catch return error.InvalidCharacter;
            return result;
        }
    };
}

/// A JSON array of at most `capacity` `T`s, held inline. A longer array is
/// refused, never cut.
pub fn JsonArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        values: [capacity]T = undefined,
        count: usize = 0,

        pub fn slice(self: *const @This()) []const T {
            return self.values[0..self.count];
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            if (try source.next() != .array_begin) return error.UnexpectedToken;
            var result: @This() = .{};
            while (try source.peekNextTokenType() != .array_end) {
                if (result.count == capacity) return error.LengthMismatch;
                result.values[result.count] = try std.json.innerParse(T, allocator, source, options);
                result.count += 1;
            }
            _ = try source.next();
            return result;
        }
    };
}

/// A JSON string naming one of `T`'s tags.
pub fn JsonEnum(comptime T: type) type {
    const limit = comptime blk: {
        var longest: usize = 0;
        for (@typeInfo(T).@"enum".field_names) |name| longest = @max(longest, name.len);
        break :blk longest;
    };
    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(@tagName(self.value));
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const string = try JsonString(limit).jsonParse(allocator, source, options);
            return .{ .value = std.meta.stringToEnum(T, string.slice()) orelse return error.InvalidEnumTag };
        }
    };
}

// The containing field's default represents omission. A present field must
// parse as T, not ?T: JSON null cannot stand in for an absent outcome/diagnostic.
pub fn OmittableJson(comptime T: type) type {
    return struct {
        value: ?T = null,

        pub fn isPresent(self: @This()) bool {
            return self.value != null;
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return .{ .value = try std.json.innerParse(T, allocator, source, options) };
        }
    };
}

/// A canonical decimal u64 sent as a string: digits only, no leading zero,
/// and zero only when `allow_zero`.
pub fn decimalId(value: JsonString(20), allow_zero: bool) !u64 {
    const bytes = value.slice();
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidResponse;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
    const id = std.fmt.parseInt(u64, bytes, 10) catch return error.InvalidResponse;
    if (!allow_zero and id == 0) return error.InvalidResponse;
    return id;
}

fn decimal(text: []const u8, allow_zero: bool) !u64 {
    var value: JsonString(20) = .{};
    try value.value.set(text);
    return decimalId(value, allow_zero);
}

test "a decimal ID is canonical digits within u64, and zero only where allowed" {
    try std.testing.expectEqual(@as(u64, 7), try decimal("7", false));
    try std.testing.expectEqual(@as(u64, 0), try decimal("0", true));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try decimal("18446744073709551615", false));
    try std.testing.expectError(error.InvalidResponse, decimal("0", false));
    // parseInt alone would accept each of these.
    for ([_][]const u8{ "", "00", "07", "+7", "1_0", "-0", " 7", "7 ", "0x7", "18446744073709551616", "99999999999999999999" }) |text|
        try std.testing.expectError(error.InvalidResponse, decimal(text, true));
}

fn parse(comptime T: type, source: []const u8) !T {
    var storage: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    return std.json.parseFromSliceLeaky(T, fixed.allocator(), source, .{});
}

test "a JSON string field holds at most its limit, decoded, and only from a string" {
    const Field = struct { name: JsonString(4) };
    // The limit counts decoded bytes: six escaped source bytes are two.
    try std.testing.expectEqualStrings("a\"µ", (try parse(Field, "{\"name\":\"a\\\"\\u00b5\"}")).name.slice());
    try std.testing.expectEqualStrings("abcd", (try parse(Field, "{\"name\":\"abcd\"}")).name.slice());
    try std.testing.expect((try parse(Field, "{\"name\":\"ab\"}")).name.eql("ab"));
    try std.testing.expect(std.meta.isError(parse(Field, "{\"name\":\"abcde\"}")));
    try std.testing.expect(std.meta.isError(parse(Field, "{\"name\":7}")));
    try std.testing.expect(std.meta.isError(parse(Field, "{\"name\":null}")));
}

test "a JSON enum field names a tag, up to the longest tag's length" {
    const Mode = enum { on, standby };
    const Field = struct { mode: JsonEnum(Mode) };
    try std.testing.expectEqual(Mode.standby, (try parse(Field, "{\"mode\":\"standby\"}")).mode.value);
    try std.testing.expectEqual(Mode.on, (try parse(Field, "{\"mode\":\"on\"}")).mode.value);
    for ([_][]const u8{ "{\"mode\":\"off\"}", "{\"mode\":\"standbyx\"}", "{\"mode\":\"ON\"}", "{\"mode\":1}" }) |source|
        try std.testing.expect(std.meta.isError(parse(Field, source)));
}

test "an omittable field is absent only when omitted, never when null" {
    const Field = struct { code: OmittableJson(JsonString(8)) = .{} };
    try std.testing.expect(!(try parse(Field, "{}")).code.isPresent());
    const present = try parse(Field, "{\"code\":\"busy\"}");
    try std.testing.expect(present.code.isPresent() and present.code.value.?.eql("busy"));
    try std.testing.expect(std.meta.isError(parse(Field, "{\"code\":null}")));
}
