//! JSON strings and integers that never reach std's float parser. std reads
//! an integer through parseFloat unless it is spelled as one, and a
//! `[]const u8` also accepts an array of byte numbers read that way, so every
//! typed parse carried the 23 KB `convertSlow` frame onto Host stacks.
const std = @import("std");

/// A JSON string. It borrows the input, or the parse allocator for a string
/// with escapes.
pub const Text = struct {
    slice: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Text {
        return switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            inline .string, .allocated_string => |slice| .{ .slice = slice },
            else => error.UnexpectedToken,
        };
    }
};

/// A JSON number whose value is an integer, as std accepts one: `17`, `1.7e1`
/// and `17.0` parse; `1.75` is an error.
pub fn Int(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return switch (try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)) {
                .number => |slice| .{ .value = try integral(T, slice) },
                .allocated_number => |slice| {
                    defer allocator.free(slice);
                    return .{ .value = try integral(T, slice) };
                },
                else => error.UnexpectedToken,
            };
        }
    };
}

/// Reads a JSON number token as an exact integer by shifting its decimal
/// digits, so no binary float is ever formed.
fn integral(comptime T: type, token: []const u8) !T {
    const e = std.mem.indexOfAny(u8, token, "eE") orelse token.len;
    const exponent: i64 = if (e == token.len) 0 else try std.fmt.parseInt(i64, token[e + 1 ..], 10);
    const mantissa = token[0..e];
    const negative = mantissa.len != 0 and mantissa[0] == '-';
    const unsigned = mantissa[@intFromBool(negative)..];
    const dot = std.mem.indexOfScalar(u8, unsigned, '.') orelse unsigned.len;
    const whole = unsigned[0..dot];
    const fraction = if (dot == unsigned.len) "" else unsigned[dot + 1 ..];
    // Digits after the decimal point once the exponent is applied must be zero.
    const shift = exponent - @as(i64, @intCast(fraction.len));
    var value: T = 0;
    for ([_][]const u8{ whole, fraction }) |part| for (part) |digit| {
        value = try std.math.mul(T, value, 10);
        value = if (negative) try std.math.sub(T, value, digit - '0') else try std.math.add(T, value, digit - '0');
    };
    if (value == 0) return 0;
    if (shift >= 0) {
        var i: i64 = 0;
        while (i < shift) : (i += 1) value = try std.math.mul(T, value, 10);
        return value;
    }
    var i: i64 = 0;
    while (i < -shift) : (i += 1) {
        if (@rem(value, 10) != 0) return error.InvalidNumber;
        value = @divTrunc(value, 10);
    }
    return value;
}

test "integers parse without a float spelling and text without byte arrays" {
    const Fields = struct { number: ?Int(i64) = null, text: ?Text = null };
    const parsed = try std.json.parseFromSlice(Fields, std.testing.allocator, "{\"number\":-42,\"text\":\"a\\nb\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -42), parsed.value.number.?.value);
    try std.testing.expectEqualStrings("a\nb", parsed.value.text.?.slice);
    for ([_][]const u8{ "{\"number\":17}", "{\"number\":17.0}", "{\"number\":1.7e1}", "{\"number\":170E-1}", "{\"number\":0.17e2}" }) |json| {
        const integral_value = try std.json.parseFromSlice(Fields, std.testing.allocator, json, .{});
        defer integral_value.deinit();
        try std.testing.expectEqual(@as(i64, 17), integral_value.value.number.?.value);
    }
    const zero = try std.json.parseFromSlice(Fields, std.testing.allocator, "{\"number\":0e-999999999}", .{});
    defer zero.deinit();
    try std.testing.expectEqual(@as(i64, 0), zero.value.number.?.value);
    for ([_][]const u8{ "{\"number\":4.5}", "{\"number\":45e-1}", "{\"number\":\"4\"}", "{\"number\":9223372036854775808}", "{\"text\":[97]}", "{\"text\":4}" }) |json| {
        if (std.json.parseFromSlice(Fields, std.testing.allocator, json, .{})) |unexpected| {
            unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
