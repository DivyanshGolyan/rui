const std = @import("std");
const protocol = @import("protocol.zig");

/// Values own their bytes; callers may retain this value after closing the file.
pub const Values = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    /// Desktop notifications while the terminal is out of focus.
    notifications: bool = true,
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
    if (!std.fs.path.isAbsolute(home) or !std.unicode.utf8ValidateSlice(home)) return error.InvalidHome;
    for (home) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidHome;
}
