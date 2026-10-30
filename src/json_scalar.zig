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

/// A JSON number spelled as an integer; a fraction or exponent is an error.
pub fn Int(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return switch (try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)) {
                .number => |slice| .{ .value = try std.fmt.parseInt(T, slice, 10) },
                .allocated_number => |slice| {
                    defer allocator.free(slice);
                    return .{ .value = try std.fmt.parseInt(T, slice, 10) };
                },
                else => error.UnexpectedToken,
            };
        }
    };
}

test "integers parse without a float spelling and text without byte arrays" {
    const Fields = struct { number: ?Int(i64) = null, text: ?Text = null };
    const parsed = try std.json.parseFromSlice(Fields, std.testing.allocator, "{\"number\":-42,\"text\":\"a\\nb\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, -42), parsed.value.number.?.value);
    try std.testing.expectEqualStrings("a\nb", parsed.value.text.?.slice);
    for ([_][]const u8{ "{\"number\":4.0}", "{\"number\":4e0}", "{\"number\":\"4\"}", "{\"number\":9223372036854775808}", "{\"text\":[97]}", "{\"text\":4}" }) |json| {
        if (std.json.parseFromSlice(Fields, std.testing.allocator, json, .{})) |unexpected| {
            unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
