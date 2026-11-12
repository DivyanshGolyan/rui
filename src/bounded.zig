const std = @import("std");

/// Inline UTF-8 value storage, independent of protocol and resource owners.
/// Write an empty one as `.{ .len = 0 }`, also inside an enclosing literal:
/// a literal that names a field leaves `bytes` unwritten, while `.{}` or a
/// field's default value stores all `capacity` bytes in ReleaseSafe.
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
