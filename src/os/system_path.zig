//! The OS's own system PATH, the one a login shell starts from.

const std = @import("std");
const os = @import("os.zig");

/// Linux has no system PATH file a login shell reads first, and this is the
/// fallback when macOS's files cannot be read or are too long.
pub const fixed = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// The longest system PATH kept; a longer one falls back to `fixed`.
pub const max_bytes = 4096;

const max_input_bytes = 16 * 1024;
const max_files = 64;

pub const Buffer = struct {
    path: [max_bytes]u8,
    input: [max_input_bytes]u8,
    names: [max_input_bytes]u8,
};

/// macOS: `/etc/paths`, then each file in `/etc/paths.d` in name order, as
/// `path_helper` builds it. Elsewhere, or when the files are unreadable or
/// too long, `fixed`.
pub fn read(io: std.Io, buffer: *Buffer) []const u8 {
    if (os.tag != .macos) return fixed;
    return readFiles(io, buffer) catch fixed;
}

fn readFiles(io: std.Io, buffer: *Buffer) ![]const u8 {
    var files: [1 + max_files][]const u8 = undefined;
    var input: []u8 = &buffer.input;
    files[0] = try readWhole(io, std.Io.Dir.cwd(), "/etc/paths", &input);
    var count: usize = 1;
    var directory = std.Io.Dir.cwd().openDir(io, "/etc/paths.d", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return merge(&buffer.path, files[0..count]) orelse error.SystemPathTooLong,
        else => return err,
    };
    defer directory.close(io);
    var names: [max_files][]const u8 = undefined;
    var name_count: usize = 0;
    var name_bytes: []u8 = &buffer.names;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (name_count == max_files or entry.name.len > name_bytes.len) return error.SystemPathTooLong;
        @memcpy(name_bytes[0..entry.name.len], entry.name);
        names[name_count] = name_bytes[0..entry.name.len];
        name_bytes = name_bytes[entry.name.len..];
        name_count += 1;
    }
    std.mem.sort([]const u8, names[0..name_count], {}, lessThan);
    for (names[0..name_count]) |name| {
        files[count] = try readWhole(io, directory, name, &input);
        count += 1;
    }
    return merge(&buffer.path, files[0..count]) orelse error.SystemPathTooLong;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Reads one whole file into the front of `remaining` and advances it. A file
/// that fills what remains may be longer, so it counts as too long.
fn readWhole(io: std.Io, directory: std.Io.Dir, path: []const u8, remaining: *[]u8) ![]const u8 {
    const bytes = try directory.readFile(io, path, remaining.*);
    if (bytes.len == remaining.len) return error.SystemPathTooLong;
    remaining.* = remaining.*[bytes.len..];
    return bytes;
}

/// Joins the files' lines with ':' in order, skipping blank lines and keeping
/// only the first copy of each entry. Null when the result is empty or does
/// not fit `buffer`.
pub fn merge(buffer: []u8, files: []const []const u8) ?[]const u8 {
    var length: usize = 0;
    for (files) |file| {
        var lines = std.mem.splitScalar(u8, file, '\n');
        while (lines.next()) |line| {
            const entry = std.mem.trim(u8, line, " \t\r");
            if (entry.len == 0 or contains(buffer[0..length], entry)) continue;
            const separator: usize = @intFromBool(length != 0);
            if (length + separator + entry.len > buffer.len) return null;
            if (separator != 0) buffer[length] = ':';
            @memcpy(buffer[length + separator ..][0..entry.len], entry);
            length += separator + entry.len;
        }
    }
    return if (length == 0) null else buffer[0..length];
}

fn contains(path: []const u8, entry: []const u8) bool {
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |existing| if (std.mem.eql(u8, existing, entry)) return true;
    return false;
}

test "merge keeps file order, skips blank lines and repeats, and refuses overflow" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/Library/Apple/usr/bin",
        merge(&buffer, &.{ "/usr/local/bin\n/usr/bin\n\n/bin\n", " /opt/homebrew/bin\r\n/usr/bin\n", "\n/Library/Apple/usr/bin" }).?,
    );
    try std.testing.expectEqualStrings("/a:/a/b", merge(&buffer, &.{ "/a\n/a/b\n/a\n", "/a/b" }).?);
    try std.testing.expectEqual(null, merge(&buffer, &.{ "\n \n", "" }));
    try std.testing.expectEqual(null, merge(&buffer, &.{}));
    var exact: [5]u8 = undefined;
    try std.testing.expectEqualStrings("/a:/b", merge(&exact, &.{"/a\n/b"}).?);
    try std.testing.expectEqual(null, merge(&exact, &.{"/a\n/bc"}));
    try std.testing.expectEqualStrings("/a", merge(&exact, &.{"/a\n/a\n/a"}).?);
}

test "read matches path_helper on macOS and the fixed list elsewhere" {
    const io = std.testing.io;
    const buffer = try std.testing.allocator.create(Buffer);
    defer std.testing.allocator.destroy(buffer);
    const path = read(io, buffer);
    if (os.tag != .macos) return std.testing.expectEqualStrings(fixed, path);
    // path_helper with an empty environment prints only the system files:
    // PATH="..."; export PATH;
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "/usr/libexec/path_helper", "-s" },
        .environ_map = &std.process.Environ.Map.init(std.testing.allocator),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const prefix = "PATH=\"";
    const start = std.mem.indexOf(u8, result.stdout, prefix) orelse return error.TestUnexpectedResult;
    const rest = result.stdout[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(rest[0..end], path);
}
