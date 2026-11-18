const std = @import("std");

pub const Values = @import("preference_document.zig").Values;

pub fn directoryPath(home: []const u8, buffer: []u8) ![]const u8 {
    try validateHome(home);
    return std.fmt.bufPrint(buffer, directory_format, .{home}) catch error.PreferencePathTooLong;
}

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

pub const validAbsoluteText = @import("preference_document.zig").validAbsoluteText;
