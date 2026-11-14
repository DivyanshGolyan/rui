//! The OpenAI API key a Host presents as `authorization: Bearer KEY`: one
//! owner-only file, read once when a Host starts.
const std = @import("std");
const codex_credentials = @import("codex_credentials.zig");

pub const max_key_bytes = @import("secret_value.zig").max_key_bytes;

/// The environment variable that names the OpenAI key file in place of
/// `HOME/.config/rui/openai.key`.
pub const path_variable = "RUI_OPENAI_KEY_FILE";

pub const Key = @import("secret_value.zig").Key;
pub const valid = @import("secret_value.zig").valid;

/// The key file's absolute path: `RUI_OPENAI_KEY_FILE`, else under HOME.
pub fn path(environ: *const std.process.Environ.Map, buffer: []u8) ![]const u8 {
    if (environ.get(path_variable)) |named| {
        if (!std.fs.path.isAbsolute(named)) return error.InvalidCredentialPath;
        return named;
    }
    const home = environ.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/openai.key", .{home});
}

/// Loads the key at `file` into `key`: false when there is none. A file that
/// holds anything but one key, with at most one trailing newline, is an error.
pub fn read(file: []const u8, key: *Key) !bool {
    var buffer: [max_key_bytes + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const bytes = try codex_credentials.readPrivate(file, &buffer) orelse return false;
    const trimmed = trimNewline(bytes);
    if (!valid(trimmed)) return error.InvalidApiKey;
    @memcpy(key.bytes[0..trimmed.len], trimmed);
    key.len = trimmed.len;
    return true;
}

/// Whether `file` holds a usable key, by the same reading a Host does at
/// startup; the key read to check it is wiped.
pub fn present(file: []const u8) !bool {
    var key: Key = .{ .len = 0 };
    defer key.wipe();
    return try read(file, &key);
}

/// Replaces the key at `file`; its directory must already be private.
pub fn install(file: []const u8, key: []const u8) !void {
    if (!valid(key)) return error.InvalidApiKey;
    var buffer: [max_key_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    @memcpy(buffer[0..key.len], key);
    buffer[key.len] = '\n';
    try codex_credentials.publishPrivate(file, buffer[0 .. key.len + 1]);
}

/// One trailing "\n" or "\r\n" is how a pasted line ends, not key bytes.
pub fn trimNewline(bytes: []const u8) []const u8 {
    const without_lf = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    return if (std.mem.endsWith(u8, without_lf, "\r")) without_lf[0 .. without_lf.len - 1] else without_lf;
}

test "a pasted line keeps only the key" {
    try std.testing.expectEqualStrings("sk-1", trimNewline("sk-1\n"));
    try std.testing.expectEqualStrings("sk-1", trimNewline("sk-1\r\n"));
    try std.testing.expectEqualStrings("sk-1\n", trimNewline("sk-1\n\n"));
}

test "an installed key reads back, an absent one is not there, and an open file is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    defer private.close(io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/private/openai.key", .{root});
    var key: Key = .{ .len = 0 };
    try std.testing.expect(!try read(file, &key));
    try std.testing.expect(!try present(file));
    try install(file, "sk-test-1");
    try std.testing.expect(try present(file));
    try std.testing.expect(try read(file, &key));
    try std.testing.expectEqualStrings("sk-test-1", key.slice());
    try std.testing.expectError(error.InvalidApiKey, install(file, "two words"));
    // Readiness reads the key as a Host would: a private file holding no key is not one.
    try private.writeFile(io, .{ .sub_path = "openai.key", .data = "two words\n" });
    try std.testing.expectError(error.InvalidApiKey, present(file));
    try install(file, "sk-test-1");
    try private.setFilePermissions(io, "openai.key", .fromMode(0o644), .{});
    try std.testing.expectError(error.InsecureCredentialFile, read(file, &key));
    try std.testing.expectError(error.InsecureCredentialFile, present(file));
}

test "overlapping installs each publish a whole key" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    defer private.close(io);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buffer, "{s}/private/openai.key", .{root});
    const keys = [_][]const u8{ "sk-" ++ @as([max_key_bytes - 3]u8, @splat('a')), "sk-" ++ @as([max_key_bytes - 3]u8, @splat('b')) };
    const Installer = struct {
        fn run(destination: []const u8, key: []const u8, failed: *?anyerror) void {
            for (0..50) |_| install(destination, key) catch |err| {
                failed.* = err;
                return;
            };
        }
    };
    var failures: [keys.len]?anyerror = @splat(null);
    var threads: [keys.len]std.Thread = undefined;
    for (&threads, keys, &failures) |*thread, key, *failed| thread.* = try std.Thread.spawn(.{}, Installer.run, .{ file, key, failed });
    for (threads) |thread| thread.join();
    for (failures) |failed| try std.testing.expectEqual(@as(?anyerror, null), failed);
    var key: Key = .{ .len = 0 };
    try std.testing.expect(try read(file, &key));
    try std.testing.expect(std.mem.eql(u8, key.slice(), keys[0]) or std.mem.eql(u8, key.slice(), keys[1]));
}
