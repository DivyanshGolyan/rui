const std = @import("std");
const names = @import("tool_name.zig");
const field = @import("wire_field.zig");

pub const Names = struct {
    value: @import("bounded.zig").Bounded(names.max_names_bytes) = .{},
    pub const max_json_bytes = names.max_names_json_bytes;
    pub const openapi_tools = true;

    pub fn writeJson(self: Names, out: *std.Io.Writer) !void {
        try out.writeByte('[');
        var iter = std.mem.splitScalar(u8, self.value.slice(), ',');
        var first = true;
        while (iter.next()) |name| {
            if (name.len == 0) continue;
            if (!first) try out.writeByte(',');
            first = false;
            try std.json.Stringify.value(name, .{}, out);
        }
        try out.writeByte(']');
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Names {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var result: Names = .{};
        var count: usize = 0;
        while (try source.peekNextTokenType() != .array_end) {
            if (count == names.max_tools) return error.LengthMismatch;
            const name = try std.json.innerParse(field.JsonString(names.max_bytes), allocator, source, options);
            if (!names.valid(name.slice())) return error.InvalidCharacter;
            const extra = name.slice().len + @intFromBool(count != 0);
            if (result.value.len + extra > names.max_names_bytes) return error.LengthMismatch;
            if (count != 0) {
                result.value.bytes[result.value.len] = ',';
                result.value.len += 1;
            }
            @memcpy(result.value.bytes[result.value.len..][0..name.slice().len], name.slice());
            result.value.len += name.slice().len;
            count += 1;
        }
        _ = try source.next();
        return result;
    }
};

test "receipt tool names round trip and reject invalid or oversized lists" {
    const parsed = try std.json.parseFromSlice(Names, std.testing.allocator, "[\"bash\",\"find_tools\"]", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bash,find_tools", parsed.value.value.slice());
    var bytes: [names.max_names_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try parsed.value.writeJson(&writer);
    try std.testing.expectEqualStrings("[\"bash\",\"find_tools\"]", writer.buffered());
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Names, std.testing.allocator, "[\"bad name\"]", .{}));
}
