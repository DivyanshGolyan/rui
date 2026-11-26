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

/// A name has one file for both ways in, so a live sign-in of the other kind there would be
/// overwritten without its grant ever being revoked: refuse until it is signed out.
fn refuseOtherKind(snapshot: *const credentials.Record, browser: bool) !void {
    if (snapshot.state != .ready) return;
    if ((snapshot.client_id.slice().len != 0) != browser) return error.SignInKindMismatch;
}

pub fn codex(init: std.process.Init, record: location.Record, comptime exchange: anytype, display: anytype, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.recordFile(init.environ_map, record, &path_buffer);
    if (!location.recordFileNamed(init.environ_map, record)) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
    if (cancelled()) return error.LoginInterrupted;
    const mapped = try pages.Mapped(auth.Login).map();
    defer mapped.unmap();
    const room = mapped.value;
    {
        const snapshot = &room.work.credentials.current;
        defer std.crypto.secureZero(u8, std.mem.asBytes(snapshot));
        if (try credentials.readSnapshotInto(path, snapshot, &room.work.credentials)) try refuseOtherKind(snapshot, false);
    }
    if (cancelled()) return error.LoginInterrupted;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.tokens));
    try exchange(init.io, display, cancelled, &room.tokens);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.record));
    try auth.loginRecord(&room.tokens, auth.nowSeconds(init.io), &room.record, &room.work.claims);
    if (!publish()) return error.LoginInterrupted;
    try credentials.install(path, &room.record, null, &room.work.credentials);
}

pub fn chatgpt(init: std.process.Init, owner: location.Record, issuer: plan_login.Issuer, display: anytype, paste: plan_login.Paste, cancelled: *const fn () bool, publish: *const fn () bool) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.recordFile(init.environ_map, owner, &path_buffer);
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
    {
        const snapshot = &room.work.credentials.current;
        defer std.crypto.secureZero(u8, std.mem.asBytes(snapshot));
        if (try credentials.readSnapshotInto(path, snapshot, &room.work.credentials)) try refuseOtherKind(snapshot, true);
    }
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

test "a name holds one kind of sign-in: a ready record of the other kind is refused in both orders, any other state is replaced" {
    var record: credentials.Record = .{ .generation = 1, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = 0 };
    for ([_]bool{ false, true }) |is_browser| {
        record.client_id.wipe();
        if (is_browser) try record.client_id.set("client");
        for ([_]@import("codex_credential_policy.zig").State{ .ready, .refresh_pending, .signed_out }) |state| {
            record.state = state;
            for ([_]bool{ false, true }) |browser| {
                const refused = state == .ready and browser != is_browser;
                if (refused) {
                    try std.testing.expectError(error.SignInKindMismatch, refuseOtherKind(&record, browser));
                } else try refuseOtherKind(&record, browser);
            }
        }
    }
}
