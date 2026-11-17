const std = @import("std");

/// A tool name: 1-64 bytes of [A-Za-z0-9_-] (OpenAI's function name limit).
pub const max_bytes = 64;

pub const max_tools = 128;
pub const max_offered_tools = max_tools + 1;
pub const max_list_name_bytes = 4096;

pub const max_names_bytes = max_list_name_bytes + max_tools - 1;
pub const max_offered_names_bytes = max_names_bytes + 1 + "stop_action".len;

pub const max_offered_list_name_bytes = max_list_name_bytes + "stop_action".len;

pub const max_names_json_bytes = 2 + max_list_name_bytes + 2 * max_tools + max_tools - 1;
pub const max_offered_names_json_bytes = 2 + max_offered_list_name_bytes + 2 * max_offered_tools + max_offered_tools - 1;

pub fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

pub fn writeNamesJson(writer: *std.Io.Writer, names: []const []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[");
    for (names, 0..) |name, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writer.writeAll(name);
        try writer.writeAll("\"");
    }
    try writer.writeAll("]");
}
