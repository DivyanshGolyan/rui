//! The OpenAI API key a Host presents as `authorization: Bearer KEY`: one
//! owner-only file, read once when a Host starts.
const std = @import("std");
const codex_credentials = @import("codex_credentials.zig");

/// The longest key Rui accepts. OpenAI keys are about 170 bytes.
pub const max_key_bytes = 1024;

/// The environment variable that names the OpenAI key file in place of
/// `HOME/.config/rui/openai.key`.
pub const path_variable = "RUI_OPENAI_KEY_FILE";

/// One key, held for a Host's life in its caller's storage.
pub const Key = struct {
    bytes: [max_key_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn wipe(self: *Key) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
};

/// Visible ASCII only, so the key is a valid header value as it stands.
pub fn valid(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

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

/// The key at `file`, or null when there is none. A file that holds
/// anything but one key, with at most one trailing newline, is an error.
pub fn read(file: []const u8, key: *Key) !?void {
    var buffer: [max_key_bytes + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const bytes = try codex_credentials.readPrivate(file, &buffer) orelse return null;
    const trimmed = trimNewline(bytes);
    if (!valid(trimmed)) return error.InvalidApiKey;
    @memcpy(key.bytes[0..trimmed.len], trimmed);
    key.len = trimmed.len;
}

/// Whether a key file is saved, checked without reading the key.
pub fn present(file: []const u8) !bool {
    return codex_credentials.privatePresent(file);
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

test "a key is visible ASCII within its bound, and a pasted line keeps only the key" {
    try std.testing.expect(valid("sk-proj-abc_DEF-123"));
    for ([_][]const u8{ "", "sk abc", "sk\tabc", "sk\x7f", "sk\xc3\xa9" }) |bad| try std.testing.expect(!valid(bad));
    try std.testing.expect(valid(&@as([max_key_bytes]u8, @splat('k'))));
    try std.testing.expect(!valid(&@as([max_key_bytes + 1]u8, @splat('k'))));
    try std.testing.expectEqualStrings("sk-1", trimNewline("sk-1\n"));
    try std.testing.expectEqualStrings("sk-1", trimNewline("sk-1\r\n"));
    try std.testing.expectEqualStrings("sk-1\n", trimNewline("sk-1\n\n"));
}

test "an installed key reads back, an absent one is null, and an open file is refused" {
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
    try std.testing.expectEqual(@as(?void, null), try read(file, &key));
    try std.testing.expect(!try present(file));
    try install(file, "sk-test-1");
    try std.testing.expect(try present(file));
    try std.testing.expect(try read(file, &key) != null);
    try std.testing.expectEqualStrings("sk-test-1", key.slice());
    try std.testing.expectError(error.InvalidApiKey, install(file, "two words"));
    try private.setFilePermissions(io, "openai.key", .fromMode(0o644), .{});
    try std.testing.expectError(error.InsecureCredentialFile, read(file, &key));
    try std.testing.expectError(error.InsecureCredentialFile, present(file));
}
