//! A tool's name, and the bounds of a `tools` list of names.
const std = @import("std");

/// A tool name: 1-64 bytes of [A-Za-z0-9_-] (OpenAI's function name limit).
pub const max_bytes = 64;

/// The most names one `tools` list holds, and their bytes together (D214).
pub const max_tools = 128;
pub const max_list_name_bytes = 4096;

/// A `tools` list's names, one space apart.
pub const max_names_bytes = max_list_name_bytes + max_tools - 1;

/// A JSON list of validated tool names, including brackets, quotes and commas.
pub const max_names_json_bytes = 2 + max_list_name_bytes + 2 * max_tools + max_tools - 1;

/// Whether `name` is a tool name: 1-64 bytes of [A-Za-z0-9_-].
pub fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > max_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}
