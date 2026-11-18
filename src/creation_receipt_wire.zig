const std = @import("std");
const names = @import("tool_name.zig");
const field = @import("wire_field.zig");

pub const NamesJson = struct {
    value: []const u8,
    pub const max_json_bytes = names.max_names_json_bytes;
    pub const openapi_tools = true;

    pub fn writeJson(self: NamesJson, out: *std.Io.Writer) !void {
        try out.writeByte('[');
        var iter = std.mem.splitScalar(u8, self.value, ',');
        var first = true;
        while (iter.next()) |name| {
            if (name.len == 0) continue;
            if (!first) try out.writeByte(',');
            first = false;
            try std.json.Stringify.value(name, .{}, out);
        }
        try out.writeByte(']');
    }
};

pub const Names = struct {
    value: @import("bounded.zig").Bounded(names.max_names_bytes) = .{},

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Names {
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var result: Names = .{};
        var count: usize = 0;
        var total_name_bytes: usize = 0;
        while (try source.peekNextTokenType() != .array_end) {
            if (count == names.max_tools) return error.LengthMismatch;
            const name = try std.json.innerParse(field.JsonString(names.max_bytes), allocator, source, options);
            if (!names.valid(name.slice())) return error.InvalidCharacter;
            total_name_bytes += name.slice().len;
            if (total_name_bytes > names.max_list_name_bytes) return error.LengthMismatch;
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

fn checkReceiptNamesRoundTrip() !void {
    const parsed = try std.json.parseFromSlice(Names, std.testing.allocator, "[\"bash\",\"find_tools\"]", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bash,find_tools", parsed.value.value.slice());
    var bytes: [names.max_names_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try (NamesJson{ .value = parsed.value.value.slice() }).writeJson(&writer);
    try std.testing.expectEqualStrings("[\"bash\",\"find_tools\"]", writer.buffered());
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Names, std.testing.allocator, "[\"bad name\"]", .{}));
    const empty = try std.json.parseFromSlice(Names, std.testing.allocator, "[]", .{});
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.value.value.slice());
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Names, std.testing.allocator, "{}", .{}));
    for ([_]bool{ false, true }) |over_limit| {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();
        try json.writer.writeByte('[');
        for (0..names.max_tools + @as(usize, @intFromBool(over_limit))) |index| {
            if (index != 0) try json.writer.writeByte(',');
            try json.writer.writeAll("\"bash\"");
        }
        try json.writer.writeByte(']');
        if (over_limit) {
            try std.testing.expectError(error.LengthMismatch, std.json.parseFromSlice(Names, std.testing.allocator, json.written(), .{}));
        } else {
            const parsed_limit = try std.json.parseFromSlice(Names, std.testing.allocator, json.written(), .{});
            defer parsed_limit.deinit();
            try std.testing.expectEqual(names.max_tools * "bash".len + names.max_tools - 1, parsed_limit.value.value.len);
        }
    }
}

fn checkReceiptNamesLimit() !void {
    for ([_]bool{ false, true }) |over_limit| {
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();
        try json.writer.writeByte('[');
        const name: [names.max_bytes]u8 = @splat('a');
        for (0..names.max_list_name_bytes / names.max_bytes) |index| {
            if (index != 0) try json.writer.writeByte(',');
            try std.json.Stringify.value(&name, .{}, &json.writer);
        }
        if (over_limit) try json.writer.writeAll(",\"a\"");
        try json.writer.writeByte(']');
        if (over_limit) {
            try std.testing.expectError(error.LengthMismatch, std.json.parseFromSlice(Names, std.testing.allocator, json.written(), .{}));
        } else {
            const parsed = try std.json.parseFromSlice(Names, std.testing.allocator, json.written(), .{});
            defer parsed.deinit();
            try std.testing.expectEqual(names.max_list_name_bytes + names.max_list_name_bytes / names.max_bytes - 1, parsed.value.value.len);
        }
    }
}

test "CLI-22 receipt tool list grammar" {
    try checkReceiptNamesRoundTrip();
    try checkReceiptNamesLimit();
}
