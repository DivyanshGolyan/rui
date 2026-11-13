//! Shared credential installation for the explicit CLI and sign-in screen.
//! Presentation and the independent provider-default outcome stay with callers.
const std = @import("std");
const api_key = @import("api_key.zig");
const auth = @import("codex_auth.zig");
const credentials = @import("codex_credentials.zig");
const os = @import("os/os.zig");
const pages = @import("os/pages.zig");
const plan_login = @import("chatgpt_plan_login.zig");
const Provider = @import("provider_name.zig").Provider;

pub fn createConfigDirectory(io: std.Io, home: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/.config/rui", .{home});
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
    dir.close(io);
}

/// The variable naming a sign-in provider's credential file, as
/// RUI_CODEX_CREDENTIAL_FILE for Codex.
pub fn credentialVariable(comptime provider: Provider) []const u8 {
    comptime var upper: [@tagName(provider).len]u8 = undefined;
    inline for (@tagName(provider), &upper) |byte, *to| to.* = comptime std.ascii.toUpper(byte);
    const final = upper;
    return "RUI_" ++ &final ++ "_CREDENTIAL_FILE";
}

/// A sign-in provider's credential file: HOME/.config/rui/LABEL.json unless
/// its variable (`credentialVariable`) names an absolute path.
pub fn credentialPath(init: std.process.Init, comptime provider: Provider, buffer: []u8, create: bool) ![]const u8 {
    if (init.environ_map.get(comptime credentialVariable(provider))) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    if (create) try createConfigDirectory(init.io, home);
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/" ++ @tagName(provider) ++ ".json", .{home});
}

pub fn codex(init: std.process.Init, comptime exchange: anytype, display: anytype, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, .codex, &path_buffer, true);
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

/// The ChatGPT plan sign-in: a browser or pasted answer from `issuer`,
/// installed through the same custody as a Codex login once `publish` wins
/// the caller's cancellation gate. The caller renders each `plan_login.Shown`
/// through `display` and supplies the pasted address through `paste`. The
/// host id lives beside the credential directory at HOME/.config/rui/host-id.
pub fn chatgpt(init: std.process.Init, issuer: plan_login.Issuer, display: anytype, paste: plan_login.Paste, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, .chatgpt, &path_buffer, true);
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    try createConfigDirectory(init.io, home);
    var host_id_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const host_id_path = try std.fmt.bufPrint(&host_id_buffer, "{s}/.config/rui/host-id", .{home});
    if (cancelled()) return error.LoginInterrupted;
    const mapped = try pages.Mapped(auth.Login).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.record));
    const Publish = struct {
        path: []const u8,
        scratch: *credentials.Scratch,
        gate: *const fn () bool,

        fn install(self: @This(), record: *credentials.Record) !void {
            if (!self.gate()) return error.LoginInterrupted;
            try credentials.install(self.path, record, null, self.scratch);
        }
    };
    try plan_login.login(init.io, .{
        .credential_path = path,
        .host_id_path = host_id_path,
        .issuer = issuer,
        // A test's issuer is a loopback; no browser goes there.
        .opener = if (issuer == .fixture) null else os.linkOpener(init.environ_map),
    }, display, paste, cancelled, &room.record, Publish{ .path = path, .scratch = &room.work.credentials, .gate = publish }, Publish.install);
}

pub fn key(init: std.process.Init, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try api_key.path(init.environ_map, &buffer);
    if (init.environ_map.get(api_key.path_variable) == null) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
    try api_key.install(path, bytes);
}
