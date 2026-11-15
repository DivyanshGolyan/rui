const std = @import("std");

pub const max_bytes = 4096;
pub const Request = struct { action: u64, offset: u64 = 0 };
pub fn parse(arena: std.mem.Allocator, bytes: []const u8, read: bool) error{ OutOfMemory, InvalidArguments }!Request {
    if (bytes.len > max_bytes) return error.InvalidArguments;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    if (value != .object) return error.InvalidArguments;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        if (!std.mem.eql(u8, field.key_ptr.*, "action") and !(read and std.mem.eql(u8, field.key_ptr.*, "offset"))) return error.InvalidArguments;
    }
    return .{ .action = try number(value.object.get("action") orelse return error.InvalidArguments, false), .offset = if (value.object.get("offset")) |offset| try number(offset, true) else 0 };
}

fn number(value: std.json.Value, zero: bool) error{InvalidArguments}!u64 {
    if (value != .string or value.string.len == 0 or (value.string.len > 1 and value.string[0] == '0')) return error.InvalidArguments;
    for (value.string) |byte| if (byte < '0' or byte > '9') return error.InvalidArguments;
    const n = std.fmt.parseInt(u64, value.string, 10) catch return error.InvalidArguments;
    if ((!zero and n == 0) or n > std.math.maxInt(i64)) return error.InvalidArguments;
    return n;
}

test "Action tools accept only an own-Session identity and bounded read cursor" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Request{ .action = 42, .offset = 7 }, try parse(arena.allocator(), "{\"action\":\"42\",\"offset\":\"7\"}", true));
    for ([_][]const u8{ "{\"action\":\"0\"}", "{\"action\":\"01\"}", "{\"action\":1}", "{\"action\":\"1\",\"session\":\"abcdef\"}", "{\"action\":\"1\",\"action\":\"2\"}" }) |bytes| try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), bytes, true));
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), "{\"action\":\"42\",\"offset\":\"0\"}", false));
}
