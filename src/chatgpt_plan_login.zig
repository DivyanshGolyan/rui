const std = @import("std");
const wire = @import("chatgpt_plan_wire.zig");
const policy = @import("codex_credential_policy.zig");
const credentials = @import("codex_credentials.zig");
const codex_auth = @import("codex_auth.zig");
const os = @import("os");
const pages = @import("os/pages.zig");

pub const preferred_port: u16 = 1455;
pub const wait_minutes = 30;
pub const max_link_bytes = 8 * 1024;
const wait_ns: i96 = wait_minutes * std.time.ns_per_min;
const wake_ms = 250;
const max_connections = 8;
const revoke_attempts = 3;

pub const Issuer = union(enum) {
    openai,
    fixture: []const u8,

    fn fixtureUrl(base: []const u8, comptime path: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}" ++ path, .{base});
    }
};

pub const Options = struct {
    credential_path: []const u8,
    host_id_path: []const u8,
    issuer: Issuer = .openai,
    opener: ?os.LinkOpener = null,
};

pub const Shown = union(enum) {
    link: []const u8,
    stray_paste: u16,
    failed: Failure,
};

pub const Failure = union(enum) {
    invalid_host_id: []const u8,
    refused: []const u8,
    timed_out,
    no_answer_source,
    callback: CallbackFailure,
    unreachable_service: []const u8,
    exchange: ExchangeFailure,
};

pub const CallbackFailure = enum { state_mismatch, client_id_mismatch, missing_client_id, damaged };
pub const ExchangeFailure = enum { plan_scope_missing, code_refused, not_for_this_sign_in, unreadable };

pub const Paste = struct {
    fd: ?std.posix.fd_t = null,
    read: *const fn (buffer: []u8) ?usize,
};

const Room = struct {
    saved: credentials.Scratch = undefined,
    attempt: wire.Attempt = undefined,
    callback: wire.Callback = undefined,
    link: [max_link_bytes]u8 = undefined,
    shown: [max_link_bytes]u8 = undefined,
    url: [1024]u8 = undefined,
    form: [32 * 1024]u8 = undefined,
    response: codex_auth.Response = undefined,
    scratch: wire.Scratch = undefined,
    connections: [max_connections]Connection = undefined,
    paste: [wire.max_request_line_bytes]u8 = undefined,
    paste_len: usize = 0,
};

const Connection = struct {
    stream: ?std.Io.net.Stream = null,
    bytes: [wire.max_request_line_bytes]u8 = undefined,
    len: usize = 0,

    fn close(self: *Connection, io: std.Io) void {
        if (self.stream) |stream| stream.close(io);
        self.stream = null;
        self.len = 0;
    }

    fn answer(self: *Connection, io: std.Io, page: []const u8) void {
        if (self.stream) |stream| {
            var writer = stream.writer(io, &.{});
            writer.interface.writeAll(page) catch {};
        }
        self.close(io);
    }
};

pub fn login(io: std.Io, options: Options, display: anytype, paste: Paste, cancelled: *const fn () bool, record: *policy.Record, context: anytype, publish: anytype) !void {
    var host_id: [wire.host_id_len]u8 = undefined;
    hostId(io, options.host_id_path, &host_id) catch |err| {
        if (err == error.InvalidHostId) return fail(display, .{ .invalid_host_id = options.host_id_path });
        return err;
    };
    const mapped = try pages.Mapped(Room).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(room));
    room.paste_len = 0;
    for (&room.connections) |*connection| {
        connection.stream = null;
        connection.len = 0;
    }
    defer for (&room.connections) |*connection| connection.close(io);

    const saved = &room.saved.current;
    const returning = try credentials.readSnapshotInto(options.credential_path, saved, &room.saved) and saved.client_id.len != 0;

    var listener = listen(io);
    defer if (listener) |*server| server.deinit(io);
    const port = if (listener) |server| server.socket.address.getPort() else preferred_port;

    var random: [wire.random_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &random);
    try std.Io.randomSecure(io, &random);
    const issued = try wire.authorize(&random, port, &host_id, if (returning) saved else null, &room.attempt, &room.link);
    const link = switch (options.issuer) {
        .openai => issued,
        .fixture => |base| try std.fmt.bufPrint(&room.shown, "{s}/oauth/authorize{s}", .{ base, issued[wire.authorize_url.len..] }),
    };
    try display(Shown{ .link = link });
    if (options.opener) |opener| opener.open(io, link) catch {};

    const arrived = try waitForCallback(io, room, if (listener) |*server| server else null, paste, cancelled, display, wait_ns);
    const browser: ?*Connection = if (arrived) |index| &room.connections[index] else null;
    errdefer if (browser) |connection| connection.answer(io, wire.page_failed);
    const grant = switch (room.callback) {
        .granted => |*grant| grant,
        .refused => |*code| return fail(display, .{ .refused = code.slice() }),
    };
    if (options.issuer == .fixture and !std.mem.eql(u8, grant.client_id.slice(), policy.fixture_client_id))
        return error.FixtureRequiresSyntheticCredential;

    var request = try wire.exchangeRequest(&room.attempt, grant, &room.form);
    switch (options.issuer) {
        .openai => {},
        .fixture => |base| request.url = try Issuer.fixtureUrl(base, "/oauth/token", &room.url),
    }
    const status = codex_auth.post(io, request, &room.response, cancelled) catch |err| {
        if (err == error.LoginInterrupted) return err;
        return fail(display, .{ .unreachable_service = @errorName(err) });
    };
    wire.loginRecord(&room.attempt, grant, status, room.response.bytes[0..room.response.len], codex_auth.nowSeconds(io), record, &room.scratch) catch |err|
        return fail(display, .{ .exchange = exchangeFailure(err) });
    try publish(context, record);
    if (browser) |connection| connection.answer(io, wire.page_signed_in);
}

fn fail(display: anytype, failure: Failure) anyerror {
    display(Shown{ .failed = failure }) catch |err| return err;
    return error.Reported;
}

fn exchangeFailure(err: anyerror) ExchangeFailure {
    return switch (err) {
        error.PlanScopeMissing => .plan_scope_missing,
        error.TokenExchangeRejected => .code_refused,
        error.IdTokenIssuerMismatch, error.IdTokenAudienceMismatch, error.IdTokenExpired, error.IdTokenNonceMismatch => .not_for_this_sign_in,
        else => .unreadable,
    };
}

fn hostId(io: std.Io, path: []const u8, host_id: *[wire.host_id_len]u8) !void {
    var buffer: [wire.host_id_len + 2]u8 = undefined;
    if (try credentials.readPrivate(path, &buffer) == null) {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(io, &random);
        const made = wire.formatHostId(&random) ++ [_]u8{'\n'};
        _ = try credentials.createPrivate(path, &made, &buffer);
    }
    const bytes = try credentials.readPrivate(path, &buffer) orelse return error.InvalidHostId;
    const text = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    try wire.validateHostId(text);
    @memcpy(host_id, text);
}

fn listen(io: std.Io) ?std.Io.net.Server {
    for ([_]u16{ preferred_port, 0 }) |port| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        if (address.listen(io, .{})) |server| return server else |_| {}
    }
    return null;
}

fn waitForCallback(io: std.Io, room: *Room, listener: ?*std.Io.net.Server, paste: Paste, cancelled: *const fn () bool, display: anytype, wait: i96) !?usize {
    var paste_open = true;
    const started = std.Io.Clock.Timestamp.now(io, .boot);
    const Source = union(enum) { listener, paste, connection: usize };
    while (true) {
        if (cancelled()) return error.LoginInterrupted;
        if (started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds >= wait)
            return fail(display, .timed_out);
        var fds: [2 + max_connections]std.posix.pollfd = undefined;
        var sources: [fds.len]Source = undefined;
        var count: usize = 0;
        if (listener) |server| {
            fds[count] = .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .listener;
            count += 1;
        }
        const unpolled_paste = paste_open and paste.fd == null;
        if (paste_open) if (paste.fd) |fd| {
            fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .paste;
            count += 1;
        };
        for (&room.connections, 0..) |*connection, index| if (connection.stream) |stream| {
            fds[count] = .{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .{ .connection = index };
            count += 1;
        };
        if (count == 0 and !unpolled_paste) return fail(display, .no_answer_source);
        const ready = try std.posix.poll(fds[0..count], wake_ms);
        if (unpolled_paste and try readPaste(room, paste, &paste_open, display)) return null;
        if (ready == 0) continue;
        for (fds[0..count], sources[0..count]) |fd, source| {
            if (fd.revents == 0) continue;
            switch (source) {
                .listener => {
                    const stream = listener.?.accept(io) catch continue;
                    for (&room.connections) |*connection| {
                        if (connection.stream == null) {
                            connection.stream = stream;
                            connection.len = 0;
                            break;
                        }
                    } else stream.close(io);
                },
                .paste => if (try readPaste(room, paste, &paste_open, display)) return null,
                .connection => |index| {
                    const connection = &room.connections[index];
                    const read = std.posix.read(fd.fd, connection.bytes[connection.len..]) catch 0;
                    if (read == 0) {
                        connection.close(io);
                        continue;
                    }
                    connection.len += read;
                    const target = wire.requestTarget(connection.bytes[0..connection.len]) catch {
                        connection.answer(io, wire.page_not_found);
                        continue;
                    } orelse continue;
                    if (deliver(room, target)) |delivered| {
                        if (delivered) return index;
                        connection.answer(io, wire.page_not_found);
                    } else |err| {
                        connection.answer(io, wire.page_failed);
                        return fail(display, .{ .callback = callbackFailure(err) });
                    }
                },
            }
        }
    }
}

fn readPaste(room: *Room, paste: Paste, open: *bool, display: anytype) !bool {
    const read = paste.read(room.paste[room.paste_len..]) orelse return false;
    if (read == 0) open.* = false;
    room.paste_len += read;
    const pasted = takePastedLines(room, !open.*) catch |err| return fail(display, .{ .callback = callbackFailure(err) });
    if (pasted.delivered) return true;
    if (pasted.strays != 0) try display(Shown{ .stray_paste = room.attempt.port });
    return false;
}

const Pasted = struct { delivered: bool = false, strays: usize = 0 };

fn takePastedLines(room: *Room, ended: bool) !Pasted {
    var pasted: Pasted = .{};
    while (room.paste_len != 0) {
        const end = std.mem.indexOfScalar(u8, room.paste[0..room.paste_len], '\n') orelse
            if (ended or room.paste_len == room.paste.len) room.paste_len else return pasted;
        const line = std.mem.trim(u8, room.paste[0..end], " \t\r");
        if (line.len != 0) {
            if (try deliver(room, line)) {
                pasted.delivered = true;
                return pasted;
            }
            pasted.strays += 1;
        }
        const consumed = @min(end + 1, room.paste_len);
        std.crypto.secureZero(u8, room.paste[0..consumed]);
        std.mem.copyForwards(u8, room.paste[0 .. room.paste_len - consumed], room.paste[consumed..room.paste_len]);
        room.paste_len -= consumed;
    }
    return pasted;
}

fn deliver(room: *Room, received: []const u8) !bool {
    wire.parseCallback(&room.attempt, received, &room.callback) catch |err| switch (err) {
        error.NotCallbackAddress => return false,
        else => return err,
    };
    return true;
}

fn callbackFailure(err: anyerror) CallbackFailure {
    return switch (err) {
        error.StateMismatch => .state_mismatch,
        error.ClientIdMismatch => .client_id_mismatch,
        error.MissingClientId => .missing_client_id,
        else => .damaged,
    };
}

pub const Browser = enum {
    absent,
    revoked,
    unconfirmed,
    unlocated,
    failed,
};

pub const DeviceCode = enum {
    absent,
    removed,
    unlocated,
    failed,
};

pub const Logout = struct { browser: Browser, device_code: DeviceCode };

const Revoke = struct {
    credentials: credentials.Scratch = undefined,
    url: [1024]u8 = undefined,
    form: [32 * 1024]u8 = undefined,
    response: codex_auth.Response = undefined,
};

pub fn logout(io: std.Io, browser_path: ?[]const u8, device_code_path: ?[]const u8, issuer: Issuer) Logout {
    return .{
        .browser = if (browser_path) |path| endBrowser(io, path, issuer) else .unlocated,
        .device_code = if (device_code_path) |path| endDeviceCode(path) else .unlocated,
    };
}

fn endBrowser(io: std.Io, path: []const u8, issuer: Issuer) Browser {
    const mapped = pages.Mapped(Revoke).map() catch return .failed;
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(room));
    return revokeBrowser(io, path, issuer, room) catch |err| switch (err) {
        error.FileNotFound => .absent,
        else => .failed,
    };
}

fn endDeviceCode(path: []const u8) DeviceCode {
    const mapped = pages.Mapped(credentials.Scratch).map() catch return .failed;
    defer mapped.unmap();
    const scratch = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(scratch));
    const ended = credentials.signOut(path, scratch, {}, keepDeviceCode) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .failed,
    };
    return if (ended) .removed else .absent;
}

fn keepDeviceCode(_: void, _: *const policy.Record) !void {}

const RevokeContext = struct {
    io: std.Io,
    issuer: Issuer,
    room: *Revoke,
    outcome: Browser = .unconfirmed,

    fn revoke(self: *@This(), current: *const policy.Record) !void {
        if (current.client_id.len == 0) return;
        if (self.issuer == .fixture) try policy.requireFixtureClient(current);
        var request = wire.revokeRequest(current, &self.room.form) catch return;
        switch (self.issuer) {
            .openai => {},
            .fixture => |base| request.url = try Issuer.fixtureUrl(base, "/oauth/revoke", &self.room.url),
        }
        for (0..revoke_attempts) |attempt| {
            if (attempt != 0) self.io.sleep(.fromSeconds(@intCast(attempt)), .awake) catch {};
            const status = codex_auth.post(self.io, request, &self.room.response, null) catch continue;
            switch (wire.revocation(status)) {
                .revoked => {
                    self.outcome = .revoked;
                    return;
                },
                .retry => continue,
                .refused => return,
            }
        }
    }
};

fn revokeBrowser(io: std.Io, credential_path: []const u8, issuer: Issuer, room: *Revoke) !Browser {
    var context: RevokeContext = .{ .io = io, .issuer = issuer, .room = room };
    if (!try credentials.signOut(credential_path, &room.credentials, &context, RevokeContext.revoke)) return .absent;
    return context.outcome;
}

pub const ProfileLogout = struct { local: credentials.ProfileLogout, remote: Browser };

pub fn logoutProfile(io: std.Io, path: []const u8, id: credentials.ProfileId, issuer: Issuer) !ProfileLogout {
    const mapped = try pages.Mapped(Revoke).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(room));
    var context: RevokeContext = .{ .io = io, .issuer = issuer, .room = room };
    const local = try credentials.signOutProfile(path, id, &room.credentials, &context, RevokeContext.revoke);
    return .{ .local = local, .remote = context.outcome };
}

test "logout ends the device-code sign-in in each state it can be in, beside a browser one that is absent or unreadable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700) });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var browser_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const browser_path = try std.fmt.bufPrint(&browser_buffer, "{s}/private/chatgpt.json", .{root[0..root_len]});
    var device_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const device_path = try std.fmt.bufPrint(&device_buffer, "{s}/private/codex.json", .{root[0..root_len]});
    const ready = "version=3\ngeneration=1\naccount_id=" ++ policy.fixture_account_id ++ "\nfedramp=0\nid_token=" ++ policy.fixture_id_token ++
        "\naccess_token=" ++ policy.fixture_access_token ++ "\nrefresh_token=synthetic-refresh\nexpires_at=4102444800\nrefreshed_at=100\nstate=";
    const signed_out = "version=3\ngeneration=2\naccount_id=" ++ policy.fixture_account_id ++
        "\nfedramp=0\nid_token=\naccess_token=\nrefresh_token=\nexpires_at=0\nrefreshed_at=100\nstate=signed_out\n";
    const unreadable = "not a credential\n";
    for ([_]struct { ?[]const u8, DeviceCode }{
        .{ null, .absent }, // missing: no file
        .{ signed_out, .absent }, // missing: already signed out
        .{ ready ++ "ready\n", .removed }, // configured, and renewal_due by the clock alone
        .{ ready ++ "refresh_pending\n", .removed }, // refresh_required
        .{ unreadable, .failed }, // credential_error
    }) |case| {
        for ([_]struct { ?[]const u8, Browser }{ .{ null, .absent }, .{ unreadable, .failed } }) |browser| {
            tmp.dir.deleteFile(io, "private/codex.json") catch {};
            tmp.dir.deleteFile(io, "private/chatgpt.json") catch {};
            if (case[0]) |bytes| try tmp.dir.writeFile(io, .{ .sub_path = "private/codex.json", .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
            if (browser[0]) |bytes| try tmp.dir.writeFile(io, .{ .sub_path = "private/chatgpt.json", .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
            try std.testing.expectEqual(Logout{ .browser = browser[1], .device_code = case[1] }, logout(io, browser_path, device_path, .{ .fixture = "http://127.0.0.1:9" }));
            if (case[1] == .removed) {
                try tmp.dir.writeFile(io, .{ .sub_path = "private/codex.json", .data = case[0].?, .flags = .{ .permissions = .fromMode(0o600) } });
                try std.testing.expectEqual(Logout{ .browser = .unlocated, .device_code = .removed }, logout(io, null, device_path, .{ .fixture = "http://127.0.0.1:9" }));
                try tmp.dir.writeFile(io, .{ .sub_path = "private/codex.json", .data = case[0].?, .flags = .{ .permissions = .fromMode(0o600) } });
                try std.testing.expectEqual(Logout{ .browser = browser[1], .device_code = .unlocated }, logout(io, browser_path, null, .{ .fixture = "http://127.0.0.1:9" }));
                try tmp.dir.writeFile(io, .{ .sub_path = "private/codex.json", .data = case[0].?, .flags = .{ .permissions = .fromMode(0o600) } });
                try std.testing.expectEqual(Logout{ .browser = browser[1], .device_code = case[1] }, logout(io, browser_path, device_path, .{ .fixture = "http://127.0.0.1:9" }));
            }
            var bytes: [policy.max_file_bytes]u8 = undefined;
            const after: ?[]const u8 = tmp.dir.readFile(io, "private/codex.json", &bytes) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            switch (case[1]) {
                .absent, .failed, .unlocated => if (case[0]) |before| try std.testing.expectEqualStrings(before, after.?) else try std.testing.expectEqual(@as(?[]const u8, null), after),
                .removed => {
                    try std.testing.expectEqualStrings("version=3\ngeneration=2\naccount_id=" ++ policy.fixture_account_id ++
                        "\nfedramp=0\nid_token=\naccess_token=\nrefresh_token=\nexpires_at=0\nrefreshed_at=100\nstate=signed_out\n", after.?);
                    try std.testing.expectEqual(policy.LocalStatus.missing, try codex_auth.localStatus(device_path, 0));
                },
            }
        }
    }
}

test "pasted lines are read whole, and a line that is no callback leaves the wait going" {
    const mapped = try pages.Mapped(Room).map();
    defer mapped.unmap();
    const room = mapped.value;
    var url: [4096]u8 = undefined;
    var random: [wire.random_bytes]u8 = @splat(0);
    _ = try wire.authorize(&random, 1455, "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f", null, &room.attempt, &url);
    const state = room.attempt.state;
    const answer = "http://127.0.0.1:1455/auth/callback?code=c&state=" ++ state ++ "&client_id=oaiapp_x";

    room.paste_len = 0;
    const typed = "\n  \nhello\n" ++ answer ++ "\r\n";
    @memcpy(room.paste[0..typed.len], typed);
    room.paste_len = typed.len;
    try std.testing.expectEqual(Pasted{ .delivered = true, .strays = 1 }, try takePastedLines(room, false));
    try std.testing.expectEqualStrings("oaiapp_x", room.callback.granted.client_id.slice());

    @memcpy(room.paste[0..answer.len], answer);
    room.paste_len = answer.len;
    try std.testing.expectEqual(Pasted{}, try takePastedLines(room, false));
    try std.testing.expectEqual(answer.len, room.paste_len);
    try std.testing.expectEqual(Pasted{ .delivered = true }, try takePastedLines(room, true));

    const strays = "one\ntwo\n";
    @memcpy(room.paste[0..strays.len], strays);
    room.paste_len = strays.len;
    try std.testing.expectEqual(Pasted{ .strays = 2 }, try takePastedLines(room, false));
    try std.testing.expectEqual(@as(usize, 0), room.paste_len);

    const stale = "http://127.0.0.1:1455/auth/callback?code=c&state=AAAA&client_id=oaiapp_x\n";
    @memcpy(room.paste[0..stale.len], stale);
    room.paste_len = stale.len;
    try std.testing.expectError(error.StateMismatch, takePastedLines(room, false));
}

const FakeCaller = struct {
    const Script = *const fn (writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void;
    var texts: [8][96]u8 = undefined;
    var lens: [8]usize = undefined;
    var count: usize = 0;
    var script: ?Script = null;
    var ends: bool = false;
    var cancel_on_link: bool = false;
    var linked: bool = false;
    var port: u16 = 0;
    var bytes: [4096]u8 = undefined;
    var len: usize = 0;
    var at: usize = 0;
    var pipe: ?[2]std.c.fd_t = null;

    fn reset(paste_script: ?Script, paste_ends: bool, cancel: bool) void {
        count = 0;
        script = paste_script;
        ends = paste_ends;
        cancel_on_link = cancel;
        linked = false;
        port = 0;
        len = 0;
        at = 0;
        pipe = null;
    }

    fn shown() []const []const u8 {
        const Lines = struct {
            var slices: [8][]const u8 = undefined;
        };
        for (0..count) |index| Lines.slices[index] = texts[index][0..lens[index]];
        return Lines.slices[0..count];
    }

    fn display(value: Shown) !void {
        var writer = std.Io.Writer.fixed(&texts[count]);
        switch (value) {
            .link => |link| {
                try writer.writeAll("link");
                linked = true;
                try pasteFor(link);
            },
            .stray_paste => |stray_port| try writer.print("stray paste, {s}", .{if (stray_port == port) "this port" else "another port"}),
            .failed => |failure| switch (failure) {
                .refused => |code| try writer.print("refused {s}", .{code}),
                .callback => |cause| try writer.print("callback {t}", .{cause}),
                .exchange => |cause| try writer.print("exchange {t}", .{cause}),
                .unreachable_service => |cause| try writer.print("unreachable_service {s}", .{cause}),
                else => try writer.print("{t}", .{failure}),
            },
        }
        lens[count] = writer.end;
        count += 1;
    }

    fn pasteFor(link: []const u8) !void {
        const state_at = (std.mem.indexOf(u8, link, "&state=") orelse return error.TestUnexpectedResult) + "&state=".len;
        const state = link[state_at .. std.mem.indexOfScalarPos(u8, link, state_at, '&') orelse link.len];
        const port_at = (std.mem.indexOf(u8, link, "127.0.0.1%3A") orelse return error.TestUnexpectedResult) + "127.0.0.1%3A".len;
        var port_end = port_at;
        while (port_end < link.len and std.ascii.isDigit(link[port_end])) port_end += 1;
        port = try std.fmt.parseInt(u16, link[port_at..port_end], 10);
        var writer = std.Io.Writer.fixed(&bytes);
        if (script) |write| try write(&writer, state, link[port_at..port_end]);
        len = writer.end;
        if (pipe) |fds| {
            if (std.c.write(fds[1], &bytes, len) != len) return error.TestUnexpectedResult;
            if (ends) {
                _ = std.c.close(fds[1]);
                pipe.?[1] = -1;
            }
        }
    }

    fn read(buffer: []u8) ?usize {
        if (pipe) |fds| return std.posix.read(fds[0], buffer) catch 0;
        if (at == len) return if (linked and ends) 0 else null;
        const end = if (std.mem.indexOfScalarPos(u8, bytes[0..len], at, '\n')) |newline| newline + 1 else len;
        const moved = @min(end - at, buffer.len);
        @memcpy(buffer[0..moved], bytes[at..][0..moved]);
        at += moved;
        return moved;
    }

    fn cancelled() bool {
        return cancel_on_link and linked;
    }

    fn publish(_: void, _: *policy.Record) !void {
        return error.TestUnexpectedResult;
    }
};

fn testLogin(issuer: Issuer, polled: bool, host_id: ?[]const u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(io);
    if (host_id) |bytes| try private.writeFile(io, .{ .sub_path = "host-id", .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var host_id_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fds: [2]std.c.fd_t = undefined;
    if (polled) {
        if (std.c.pipe(&fds) != 0) return error.TestPipeFailed;
        FakeCaller.pipe = fds;
    }
    defer if (polled) {
        _ = std.c.close(fds[0]);
        if (FakeCaller.pipe.?[1] != -1) _ = std.c.close(fds[1]);
    };
    var record: policy.Record = undefined;
    return login(io, .{
        .credential_path = try std.fmt.bufPrint(&credential_buffer, "{s}/private/chatgpt.json", .{root[0..root_len]}),
        .host_id_path = try std.fmt.bufPrint(&host_id_buffer, "{s}/private/host-id", .{root[0..root_len]}),
        .issuer = issuer,
    }, FakeCaller.display, .{ .fd = if (polled) fds[0] else null, .read = FakeCaller.read }, FakeCaller.cancelled, &record, {}, FakeCaller.publish);
}

fn expectShown(expected: []const []const u8) !void {
    const shown = FakeCaller.shown();
    try std.testing.expectEqual(expected.len, shown.len);
    for (expected, shown) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a login shows its link, then each stray paste, then the refusal a paste carried, from either paste source" {
    const Script = struct {
        fn write(writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void {
            try writer.print("hello\n\nhttp://127.0.0.1:{s}/auth/callback?state={s}&error=access_denied\n", .{ port, state });
        }
    };
    FakeCaller.reset(Script.write, false, false);
    try std.testing.expectError(error.Reported, testLogin(.openai, false, null));
    try expectShown(&.{ "link", "stray paste, this port", "refused access_denied" });
    FakeCaller.reset(Script.write, false, false);
    try std.testing.expectError(error.Reported, testLogin(.openai, true, null));
    try expectShown(&.{ "link", "refused access_denied" });
}

test "a login cancelled while it waits returns interrupted after showing only its link" {
    FakeCaller.reset(null, false, true);
    try std.testing.expectError(error.LoginInterrupted, testLogin(.openai, false, null));
    try expectShown(&.{"link"});
}

test "a pasted answer that is not this sign-in's grant ends the login by its cause" {
    const Scripts = struct {
        fn stale(writer: *std.Io.Writer, _: []const u8, port: []const u8) std.Io.Writer.Error!void {
            try writer.print("http://127.0.0.1:{s}/auth/callback?code=c&state=AAAA&client_id=oaiapp_x\n", .{port});
        }
        fn unnamed(writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void {
            try writer.print("http://127.0.0.1:{s}/auth/callback?code=c&state={s}\n", .{ port, state });
        }
        fn codeless(writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void {
            try writer.print("http://127.0.0.1:{s}/auth/callback?state={s}&client_id=oaiapp_x\n", .{ port, state });
        }
    };
    for ([_]struct { FakeCaller.Script, []const u8 }{
        .{ Scripts.stale, "callback state_mismatch" },
        .{ Scripts.unnamed, "callback missing_client_id" },
        .{ Scripts.codeless, "callback damaged" },
    }) |case| {
        FakeCaller.reset(case[0], false, false);
        try std.testing.expectError(error.Reported, testLogin(.openai, false, null));
        try expectShown(&.{ "link", case[1] });
    }
}

test "a granted paste whose token service cannot be reached shows that and saves nothing" {
    const Script = struct {
        fn write(writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void {
            try writer.print("http://127.0.0.1:{s}/auth/callback?code=c&state={s}&client_id=" ++ policy.fixture_client_id ++ "\n", .{ port, state });
        }
    };
    var base: [64]u8 = undefined;
    const issuer: Issuer = .{ .fixture = try std.fmt.bufPrint(&base, "http://127.0.0.1:{d}", .{try @import("socket_fixture.zig").refusedPort()}) };
    FakeCaller.reset(Script.write, false, false);
    try std.testing.expectError(error.Reported, testLogin(issuer, false, null));
    try expectShown(&.{ "link", "unreachable_service TransportFailed" });
}

test "a host id file Rui did not write ends the login before any link" {
    FakeCaller.reset(null, false, false);
    try std.testing.expectError(error.Reported, testLogin(.openai, false, "not a host id\n"));
    try expectShown(&.{"invalid_host_id"});
}

test "the wait ends shown when its time is up or no source is left to answer" {
    const mapped = try pages.Mapped(Room).map();
    defer mapped.unmap();
    const room = mapped.value;
    var url: [4096]u8 = undefined;
    var random: [wire.random_bytes]u8 = @splat(0);
    _ = try wire.authorize(&random, 1455, "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f", null, &room.attempt, &url);
    for (&room.connections) |*connection| connection.* = .{};

    FakeCaller.reset(null, false, false);
    room.paste_len = 0;
    try std.testing.expectError(error.Reported, waitForCallback(std.testing.io, room, null, .{ .read = FakeCaller.read }, FakeCaller.cancelled, FakeCaller.display, 0));
    try expectShown(&.{"timed_out"});

    FakeCaller.reset(null, true, false);
    FakeCaller.linked = true;
    room.paste_len = 0;
    try std.testing.expectError(error.Reported, waitForCallback(std.testing.io, room, null, .{ .read = FakeCaller.read }, FakeCaller.cancelled, FakeCaller.display, wait_ns));
    try expectShown(&.{"no_answer_source"});
}

test "each callback and exchange error maps to the failure the person is shown" {
    for ([_]struct { anyerror, CallbackFailure }{
        .{ error.StateMismatch, .state_mismatch },
        .{ error.ClientIdMismatch, .client_id_mismatch },
        .{ error.MissingClientId, .missing_client_id },
        .{ error.MissingCode, .damaged },
        .{ error.InvalidCallback, .damaged },
    }) |case| try std.testing.expectEqual(case[1], callbackFailure(case[0]));
    for ([_]struct { anyerror, ExchangeFailure }{
        .{ error.PlanScopeMissing, .plan_scope_missing },
        .{ error.TokenExchangeRejected, .code_refused },
        .{ error.IdTokenIssuerMismatch, .not_for_this_sign_in },
        .{ error.IdTokenAudienceMismatch, .not_for_this_sign_in },
        .{ error.IdTokenExpired, .not_for_this_sign_in },
        .{ error.IdTokenNonceMismatch, .not_for_this_sign_in },
        .{ error.InvalidTokenResponse, .unreadable },
    }) |case| try std.testing.expectEqual(case[1], exchangeFailure(case[0]));
}
