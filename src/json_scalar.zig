const std = @import("std");

pub const Text = struct {
    slice: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Text {
        return switch (try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?)) {
            inline .string, .allocated_string => |slice| .{ .slice = slice },
            else => error.UnexpectedToken,
        };
    }
};

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
                .string => |slice| .{ .value = try integral(T, slice) },
                .allocated_string => |slice| {
                    defer allocator.free(slice);
                    return .{ .value = try integral(T, slice) };
                },
                else => error.UnexpectedToken,
            };
        }
    };
}

fn integral(comptime T: type, token: []const u8) !T {
    if (!numberSpelling(token)) return error.InvalidNumber;
    const e = std.mem.indexOfAny(u8, token, "eE") orelse token.len;
    const negative = token[0] == '-';
    const mantissa = token[@intFromBool(negative)..e];
    if (std.mem.indexOfNone(u8, mantissa, "0.") == null) return 0;
    const exponent: i64 = if (e == token.len) 0 else try std.fmt.parseInt(i64, token[e + 1 ..], 10);
    const dot = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    const fraction = if (dot == mantissa.len) "" else mantissa[dot + 1 ..];
    const whole_digits = std.mem.trimEnd(u8, mantissa[0..dot], "0");
    const fraction_digits = std.mem.trimEnd(u8, fraction, "0");
    const zeros: i64 = @intCast(if (fraction_digits.len == 0) dot - whole_digits.len else 0);
    const shift = try std.math.sub(i64, try std.math.add(i64, exponent, zeros), @intCast(fraction_digits.len));
    var value: T = 0;
    for ([_][]const u8{ if (fraction_digits.len == 0) whole_digits else mantissa[0..dot], fraction_digits }) |part| for (part) |digit| {
        value = try std.math.mul(T, value, 10);
        value = if (negative) try std.math.sub(T, value, digit - '0') else try std.math.add(T, value, digit - '0');
    };
    if (shift < 0) return error.InvalidNumber;
    var i: i64 = 0;
    while (i < shift) : (i += 1) value = try std.math.mul(T, value, 10);
    return value;
}

fn numberSpelling(token: []const u8) bool {
    var i: usize = @intFromBool(token.len != 0 and token[0] == '-');
    const whole = digitRun(token, i);
    if (whole == 0 or (whole > 1 and token[i] == '0')) return false;
    i += whole;
    if (i < token.len and token[i] == '.') {
        const fraction = digitRun(token, i + 1);
        if (fraction == 0) return false;
        i += 1 + fraction;
    }
    if (i < token.len and (token[i] == 'e' or token[i] == 'E')) {
        i += 1;
        if (i < token.len and (token[i] == '+' or token[i] == '-')) i += 1;
        const exponent = digitRun(token, i);
        if (exponent == 0) return false;
        i += exponent;
    }
    return i == token.len;
}

fn digitRun(token: []const u8, start: usize) usize {
    var end = start;
    while (end < token.len and std.ascii.isDigit(token[end])) end += 1;
    return end - start;
}

test "integers parse without a float spelling and text without byte arrays" {
    const Fields = struct { number: ?Int(i64) = null, text: ?Text = null };
    const parsed = try std.json.parseFromSlice(Fields, std.testing.allocator, "{\"number\":-42,\"text\":\"a\\nb\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -42), parsed.value.number.?.value);
    try std.testing.expectEqualStrings("a\nb", parsed.value.text.?.slice);
    for ([_][]const u8{ "{\"number\":17}", "{\"number\":17.0}", "{\"number\":1.7e1}", "{\"number\":170E-1}", "{\"number\":0.17e2}", "{\"number\":1.700000000000000000000000e1}", "{\"number\":17000000000000000000000e-21}", "{\"number\":\"17\"}", "{\"number\":\"1.7e1\"}" }) |json| {
        const integral_value = try std.json.parseFromSlice(Fields, std.testing.allocator, json, .{});
        defer integral_value.deinit();
        try std.testing.expectEqual(@as(i64, 17), integral_value.value.number.?.value);
    }
    const zero = try std.json.parseFromSlice(Fields, std.testing.allocator, "{\"number\":-0.0e99999999999999999999}", .{});
    defer zero.deinit();
    try std.testing.expectEqual(@as(i64, 0), zero.value.number.?.value);
    for ([_][]const u8{ "{\"number\":4.5}", "{\"number\":45e-1}", "{\"number\":1e-9223372036854775808}", "{\"number\":1.5e-9223372036854775807}", "{\"number\":1e9223372036854775807}", "{\"number\":\"4.5\"}", "{\"number\":\"x\"}", "{\"number\":\"\"}", "{\"number\":\"01\"}", "{\"number\":\"1e\"}", "{\"number\":9223372036854775808}", "{\"text\":[97]}", "{\"text\":4}" }) |json| {
        if (std.json.parseFromSlice(Fields, std.testing.allocator, json, .{})) |unexpected| {
            unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
