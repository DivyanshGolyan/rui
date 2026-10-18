const std = @import("std");

/// Inline UTF-8 value storage, independent of protocol and resource owners.
pub fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn set(self: *@This(), value: []const u8) !void {
            if (value.len > capacity) return error.ValueTooLong;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn eql(self: *const @This(), value: []const u8) bool {
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}
