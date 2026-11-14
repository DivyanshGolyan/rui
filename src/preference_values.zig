const std = @import("std");
const model_capability = @import("model_capability.zig");
const protocol = @import("protocol.zig");

/// Values own their bytes; callers may retain this value after closing the file.
pub const Values = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    /// Desktop notifications while the terminal is out of focus.
    notifications: bool = true,
    /// The effort new Sessions start at when their model offers it; null
    /// leaves each model at its own default.
    reasoning_effort: ?model_capability.ReasoningEffort = null,
    /// Null leaves new Sessions at Rui's permission default.
    permission_mode: ?@import("cli_value.zig").PermissionMode = null,
};

pub fn directoryPath(home: []const u8, buffer: []u8) ![]const u8 {
    try validateHome(home);
    return std.fmt.bufPrint(buffer, directory_format, .{home}) catch error.PreferencePathTooLong;
}

/// directoryPath's checks, for a writer that opens the directory relative to
/// `home` and needs no path buffer.
pub fn validateDirectoryPath(home: []const u8) !void {
    try validateHome(home);
    if (std.fmt.count(directory_format, .{home}) > std.Io.Dir.max_path_bytes) return error.PreferencePathTooLong;
}

const directory_format = "{s}/.config/rui";

pub fn defaultStore(home: []const u8, buffer: []u8) ![]const u8 {
    try validateHome(home);
    return std.fmt.bufPrint(buffer, "{s}/.local/share/rui/store", .{home}) catch error.PreferencePathTooLong;
}

fn validateHome(home: []const u8) !void {
    if (!validAbsoluteText(home)) return error.InvalidHome;
}

/// A saved path's shape: absolute, UTF-8 and free of control bytes.
pub fn validAbsoluteText(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
