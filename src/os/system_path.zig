//! The OS's own system PATH, the one a login shell starts from.

const std = @import("std");
const os = @import("os.zig");
const path_list = @import("../path_list.zig");
const stderr = @import("../stderr.zig");

/// Linux has no system PATH file a login shell reads first, and this is
/// macOS's fallback when its files do not fit.
pub const fixed = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// The longest system PATH kept; a longer one falls back to `fixed`.
pub const max_bytes = 4096;

const max_name_bytes = 2048;
const max_names = 64;

/// Scratch for one `read`; nothing outside macOS needs any.
pub const Buffer = if (os.tag == .macos) struct {
    line: [max_bytes]u8,
    names: [max_name_bytes]u8,
} else struct {};

/// Writes the system PATH into `out` and returns it. On macOS this is
/// path_helper's: `/etc/paths`, then each regular file in `/etc/paths.d` in
/// its name order, one entry per line, first copy kept. A file it cannot
/// open is skipped with a note on stderr, as path_helper warns. Elsewhere,
/// or when the result does not fit, `fixed`.
pub fn read(io: std.Io, buffer: *Buffer, out: *[max_bytes]u8) error{Canceled}![]const u8 {
    if (os.tag != .macos) return copyFixed(out);
    var etc = std.Io.Dir.cwd().openDir(io, "/etc", .{}) catch |err| return fallback(err, out);
    defer etc.close(io);
    return readFrom(io, etc, buffer, out);
}

/// `read` with `etc` in place of /etc, as path_helper's PATH_HELPER_ROOT.
fn readFrom(io: std.Io, etc: std.Io.Dir, buffer: *Buffer, out: *[max_bytes]u8) error{Canceled}![]const u8 {
    const length = readFiles(io, etc, buffer, out) catch |err| return fallback(err, out);
    return if (length == 0) copyFixed(out) else out[0..length];
}

fn fallback(err: anyerror, out: *[max_bytes]u8) error{Canceled}![]const u8 {
    if (err == error.Canceled) return error.Canceled;
    stderr.print("rui: system PATH not read ({s}); Bash uses {s}\n", .{ @errorName(err), fixed });
    return copyFixed(out);
}

fn copyFixed(out: *[max_bytes]u8) []const u8 {
    @memcpy(out[0..fixed.len], fixed);
    return out[0..fixed.len];
}

fn readFiles(io: std.Io, etc: std.Io.Dir, buffer: *Buffer, out: *[max_bytes]u8) !usize {
    var length = try appendFile(io, etc, "paths", buffer, out, 0);
    var directory = etc.openDir(io, "paths.d", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return length,
        else => return err,
    };
    defer directory.close(io);
    var names: [max_names][]const u8 = undefined;
    var count: usize = 0;
    var name_bytes: []u8 = &buffer.names;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        // path_helper reads regular files one level deep; it never follows a link.
        if (entry.kind != .file) continue;
        if (count == max_names or entry.name.len > name_bytes.len) return error.SystemPathTooLong;
        @memcpy(name_bytes[0..entry.name.len], entry.name);
        names[count] = name_bytes[0..entry.name.len];
        name_bytes = name_bytes[entry.name.len..];
        count += 1;
    }
    std.mem.sort([]const u8, names[0..count], {}, path_list.nameLessThan);
    for (names[0..count]) |name| length = try appendFile(io, directory, name, buffer, out, length);
    return length;
}

/// Appends each line of one regular file. A file that cannot be opened is
/// skipped, and one that fails mid-read keeps the lines before the failure,
/// as path_helper's fgetln loop does.
fn appendFile(io: std.Io, directory: std.Io.Dir, path: []const u8, buffer: *Buffer, out: *[max_bytes]u8, length: usize) !usize {
    const kind = (directory.statFile(io, path, .{ .follow_symlinks = false }) catch |err| return skip(path, err, length)).kind;
    if (kind != .file) return length;
    var file = directory.openFile(io, path, .{}) catch |err| return skip(path, err, length);
    defer file.close(io);
    var reader = file.reader(io, &buffer.line);
    var result = length;
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.SystemPathTooLong,
            error.ReadFailed => return skip(path, reader.err.?, result),
        } orelse return result;
        result = path_list.append(out, result, line) orelse return error.SystemPathTooLong;
    }
}

fn skip(path: []const u8, err: anyerror, length: usize) error{Canceled}!usize {
    if (err == error.Canceled) return error.Canceled;
    if (err != error.FileNotFound) stderr.print("rui: system PATH skips {s} ({s})\n", .{ path, @errorName(err) });
    return length;
}

test "read matches path_helper on macOS and the fixed list elsewhere" {
    const io = std.testing.io;
    const scratch = try std.testing.allocator.create(Buffer);
    defer std.testing.allocator.destroy(scratch);
    var out: [max_bytes]u8 = undefined;
    const path = try read(io, scratch, &out);
    if (os.tag != .macos) return std.testing.expectEqualStrings(fixed, path);
    var expected: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(try pathHelper(io, null, &expected), path);
}

test "read matches path_helper over name order, raw lines, links and subdirectories" {
    if (os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "etc/paths.d/sub");
    const files = [_][2][]const u8{
        .{ "etc/paths", "/usr/bin\n/bin\n  /spaced\n/usr/bin\n/dollar$x\n\n/cr\r\n/last" },
        .{ "etc/paths.d/10-late", "/late\n" },
        .{ "etc/paths.d/2-early", "/early\n/bin\n" },
        .{ "etc/paths.d/.hidden", "/hidden\n" },
        .{ "etc/paths.d/homebrew", "/opt/homebrew/bin\n" },
        .{ "etc/paths.d/sub/x", "/sub\n" },
    };
    for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    try tmp.dir.symLink(io, "10-late", "etc/paths.d/zz-link", .{});
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var etc = try tmp.dir.openDir(io, "etc", .{});
    defer etc.close(io);
    const scratch = try std.testing.allocator.create(Buffer);
    defer std.testing.allocator.destroy(scratch);
    var out: [max_bytes]u8 = undefined;
    var expected: [max_bytes]u8 = undefined;
    const want = try pathHelper(io, root, &expected);
    try std.testing.expectEqualStrings("/usr/bin:/bin:  /spaced:/dollar$x:/cr\r:/last:/hidden:/early:/late:/opt/homebrew/bin", want);
    try std.testing.expectEqualStrings(want, try readFrom(io, etc, scratch, &out));
}

/// path_helper's PATH with an empty environment, its ", ' and $ escapes
/// undone. `root` is its PATH_HELPER_ROOT.
fn pathHelper(io: std.Io, root: ?[]const u8, out: *[max_bytes]u8) ![]const u8 {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    if (root) |value| try environment.put("PATH_HELPER_ROOT", value);
    const result = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ "/usr/libexec/path_helper", "-s" }, .environ_map = &environment });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    const prefix = "PATH=\"";
    const suffix = "\"; export PATH;\n";
    if (!std.mem.startsWith(u8, result.stdout, prefix) or !std.mem.endsWith(u8, result.stdout, suffix)) return error.TestUnexpectedResult;
    const escaped = result.stdout[prefix.len .. result.stdout.len - suffix.len];
    var length: usize = 0;
    var index: usize = 0;
    while (index < escaped.len) : (index += 1) {
        if (escaped[index] == '\\' and index + 1 < escaped.len) index += 1;
        out[length] = escaped[index];
        length += 1;
    }
    return out[0..length];
}
