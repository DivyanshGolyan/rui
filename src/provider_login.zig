const std = @import("std");
const api_key = @import("api_key.zig");
const auth = @import("codex_auth.zig");
const credentials = @import("codex_credentials.zig");
const os = @import("os");
const pages = @import("os/pages.zig");
const plan_login = @import("chatgpt_plan_login.zig");
const location = @import("credential_location.zig");

pub fn createConfigDirectory(io: std.Io, home: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/.config/rui", .{home});
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
    dir.close(io);
}

pub fn codex(init: std.process.Init, comptime exchange: anytype, display: anytype, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.default(init.environ_map, .codex, &path_buffer);
    if (init.environ_map.get(location.variable(.codex)) == null) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
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
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.tokens));
    try exchange(init.io, display, cancelled, &room.tokens);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.record));
    try auth.loginRecord(&room.tokens, auth.nowSeconds(init.io), &room.record, &room.work.claims);
    if (!publish()) return error.LoginInterrupted;
    try credentials.install(path, &room.record, null, &room.work.credentials);
}

pub fn chatgpt(init: std.process.Init, issuer: plan_login.Issuer, display: anytype, paste: plan_login.Paste, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.default(init.environ_map, .chatgpt, &path_buffer);
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
        .opener = if (issuer == .fixture) null else os.linkOpener(init.environ_map),
    }, display, paste, cancelled, &room.record, Publish{ .path = path, .scratch = &room.work.credentials, .gate = publish }, Publish.install);
}

pub fn key(init: std.process.Init, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.default(init.environ_map, .openai, &buffer);
    if (init.environ_map.get(location.variable(.openai)) == null) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
    try api_key.install(path, bytes);
}
