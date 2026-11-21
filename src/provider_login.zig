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

pub const ProfileReceipt = struct { id: credentials.ProfileId, publication: credentials.ProfilePublication };

fn generateProfileId(io: std.Io) !credentials.ProfileId {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    return .{ .bytes = std.fmt.bytesToHex(random, .lower) };
}

fn profileDestination(init: std.process.Init, id: credentials.ProfileId, buffer: []u8) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    try createConfigDirectory(init.io, home);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try location.profileDirectory(init.environ_map, &directory_buffer);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, directory, .{ .permissions = .fromMode(0o700) });
    dir.close(init.io);
    return location.profile(init.environ_map, id, buffer);
}

pub fn codex(init: std.process.Init, comptime exchange: anytype, display: anytype, cancelled: *const fn () bool, publish: *const fn () bool) !ProfileReceipt {
    const id = try generateProfileId(init.io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try profileDestination(init, id, &path_buffer);
    if (cancelled()) return error.LoginInterrupted;
    const mapped = try pages.Mapped(auth.Login).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&room.tokens));
    try exchange(init.io, display, cancelled, &room.tokens);
    defer room.record.wipe();
    try auth.loginRecord(&room.tokens, auth.nowSeconds(init.io), &room.record, &room.work.claims);
    if (!publish()) return error.LoginInterrupted;
    return .{ .id = id, .publication = try credentials.createProfile(path, id, &room.record, &room.work.credentials) };
}

pub fn chatgpt(init: std.process.Init, issuer: plan_login.Issuer, display: anytype, paste: plan_login.Paste, cancelled: *const fn () bool, publish: *const fn () bool) !ProfileReceipt {
    const id = try generateProfileId(init.io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try profileDestination(init, id, &path_buffer);
    const home = init.environ_map.get("HOME") orelse return error.HomeRequired;
    var host_id_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const host_id_path = try std.fmt.bufPrint(&host_id_buffer, "{s}/.config/rui/host-id", .{home});
    if (cancelled()) return error.LoginInterrupted;
    const mapped = try pages.Mapped(auth.Login).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer room.record.wipe();
    const Publish = struct {
        path: []const u8,
        id: credentials.ProfileId,
        scratch: *credentials.Scratch,
        gate: *const fn () bool,
        publication: ?credentials.ProfilePublication = null,
        fn install(self: *@This(), record: *credentials.Record) !void {
            if (!self.gate()) return error.LoginInterrupted;
            self.publication = try credentials.createProfile(self.path, self.id, record, self.scratch);
        }
    };
    var published: Publish = .{ .path = path, .id = id, .scratch = &room.work.credentials, .gate = publish };
    try plan_login.login(init.io, .{
        .credential_path = path,
        .host_id_path = host_id_path,
        .issuer = issuer,
        .opener = if (issuer == .fixture) null else os.linkOpener(init.environ_map),
    }, display, paste, cancelled, &room.record, &published, Publish.install);
    return .{ .id = id, .publication = published.publication orelse return error.ProfilePublicationMissing };
}

pub fn key(init: std.process.Init, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try location.default(init.environ_map, .openai, &buffer);
    if (init.environ_map.get(location.variable(.openai)) == null) try createConfigDirectory(init.io, init.environ_map.get("HOME").?);
    try api_key.install(path, bytes);
}
