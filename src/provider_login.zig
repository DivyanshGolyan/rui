//! Shared credential installation for the explicit CLI and sign-in screen.
//! Presentation and the independent provider-default outcome stay with callers.
const std = @import("std");
const api_key = @import("api_key.zig");
const auth = @import("codex_auth.zig");
const credentials = @import("codex_credentials.zig");
const pages = @import("os/pages.zig");

pub fn createConfigDirectory(io: std.Io, home: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/.config/rui", .{home});
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
    dir.close(io);
}

pub fn codexPath(init: std.process.Init, buffer: []u8, create: bool) ![]const u8 {
    if (init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE")) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    if (create) try createConfigDirectory(init.io, home);
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/codex.json", .{home});
}

pub fn codex(init: std.process.Init, comptime exchange: anytype, display: anytype, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try codexPath(init, &path_buffer, true);
    if (cancelled()) return error.LoginInterrupted;
    const mapped = try pages.Mapped(auth.Login).map();
    defer mapped.unmap();
    const room = mapped.value;
    {
        const snapshot = &room.work.credentials.current;
        defer std.crypto.secureZero(u8, std.mem.asBytes(snapshot));
        _ = try credentials.readSnapshotInto(path, snapshot, &room.work.credentials);
    }
    if (cancelled()) return error.LoginInterrupted;
    // Exchange may fail after writing part of a token, so wipe on every exit.
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.tokens));
    try exchange(init.io, display, cancelled, &room.tokens);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.record));
    try auth.loginRecord(&room.tokens, auth.nowSeconds(init.io), &room.record, &room.work.claims);
    if (!publish()) return error.LoginInterrupted;
    try credentials.install(path, &room.record, null, &room.work.credentials);
}

pub fn key(init: std.process.Init, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try api_key.path(init.environ_map, &buffer);
    if (init.environ_map.get(api_key.path_variable) == null) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
    try api_key.install(path, bytes);
}
