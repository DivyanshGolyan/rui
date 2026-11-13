//! `rui auth login chatgpt` and `rui auth logout chatgpt`: the shell around
//! the plan sign-in's messages (`chatgpt_plan_wire.zig`).
//!
//! Login listens on loopback for the browser's callback and, at the same
//! time, reads a callback address pasted into the caller's paste source, so
//! a machine without a browser or whose browser cannot reach the listener
//! signs in by pasting; the first answer that is this attempt's wins. What
//! the person is shown is decided here as a `Shown` value and rendered by
//! the caller. Every decision about what arrived, and every message sent,
//! is the wire module's; the record is
//! published by the caller through the credential custody owner
//! (`codex_credentials.zig`). Logout ends both ChatGPT logins under that
//! owner's lock: it revokes the browser sign-in's refresh token and signs its
//! record out, keeping the issued client id for the next sign-in, and signs
//! the device-code record out locally; the host id file is never touched
//! after it is made.
const std = @import("std");
const wire = @import("chatgpt_plan_wire.zig");
const policy = @import("codex_credential_policy.zig");
const credentials = @import("codex_credentials.zig");
const codex_auth = @import("codex_auth.zig");
const pages = @import("os/pages.zig");

/// The port the redirect names when it is free; any free port also works.
pub const preferred_port: u16 = 1455;
/// How long a login waits for the browser or a paste.
pub const wait_minutes = 30;
/// The longest link `Shown.link` carries.
pub const max_link_bytes = 8 * 1024;
const wait_ns: i96 = wait_minutes * std.time.ns_per_min;
/// How often the wait wakes to notice cancellation, the deadline and a
/// paste source without a descriptor.
const wake_ms = 250;
/// Browsers open spare connections that may stay silent; this many are read
/// at once, and a further one is closed unread.
const max_connections = 8;
/// Revocation tries this many times while the issuer answers with a server
/// failure or cannot be reached.
const revoke_attempts = 3;

/// Where the plan's issuer is: OpenAI's, or a test-only loopback that
/// answers as it at BASE/oauth/authorize, BASE/oauth/token and
/// BASE/oauth/revoke, BASE being the Responses fixture's base.
pub const Issuer = union(enum) {
    openai,
    fixture: []const u8,

    fn fixtureUrl(base: []const u8, comptime path: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}" ++ path, .{base});
    }
};

pub const Options = struct {
    /// The plan credential file, which also holds the issued client id.
    credential_path: []const u8,
    /// The host id file, made before the first sign-in and kept for good.
    host_id_path: []const u8,
    issuer: Issuer = .openai,
    /// The command that opens a link in a browser, when there is one.
    opener: ?[]const u8 = null,
};

/// What the login shows, in the order it happens: the link once, a stray
/// paste any number of times, then a failure when the login ends with
/// nothing saved. Success, cancellation and other errors are the login's
/// return. Every slice is borrowed for the call only.
pub const Shown = union(enum) {
    /// Open this link in a browser where ChatGPT is signed in; the login
    /// now waits for the browser or a paste, for `wait_minutes`.
    link: []const u8,
    /// Pasted lines that were no callback address arrived; this attempt's
    /// starts with http://127.0.0.1:PORT/auth/callback.
    stray_paste: u16,
    failed: Failure,
};

/// Why a login ended with nothing saved.
pub const Failure = union(enum) {
    /// The host id file at this path holds no host id Rui wrote.
    invalid_host_id: []const u8,
    /// ChatGPT refused the sign-in with this OAuth error code.
    refused: []const u8,
    /// No answer arrived within `wait_minutes`.
    timed_out,
    /// The paste source ended and there is no listener, so nothing can answer.
    no_answer_source,
    /// The answer that arrived was not this sign-in's grant.
    callback: CallbackFailure,
    /// The token exchange could not reach ChatGPT's sign-in service; the
    /// transport's cause, by name, as shown before this was a value.
    unreachable_service: []const u8,
    /// ChatGPT's token answer made no record.
    exchange: ExchangeFailure,
};

pub const CallbackFailure = enum { state_mismatch, client_id_mismatch, missing_client_id, damaged };
pub const ExchangeFailure = enum { plan_scope_missing, code_refused, not_for_this_sign_in, unreadable };

/// Where a pasted callback address arrives. With `fd`, the login polls it
/// beside the listener and calls `read` when it is readable; without one,
/// it calls `read` on every wake, each `wake_ms`.
pub const Paste = struct {
    fd: ?std.posix.fd_t = null,
    /// Moves pasted bytes into `buffer`: their count, 0 once the source has
    /// ended for good, or null when nothing is waiting.
    read: *const fn (buffer: []u8) ?usize,
};

/// The login's storage: the saved record it reads, the attempt, what
/// arrived and the exchange. The command maps it for the call and wipes it.
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

    /// Answers with `page` and closes. A browser gone already changes nothing.
    fn answer(self: *Connection, io: std.Io, page: []const u8) void {
        if (self.stream) |stream| {
            var writer = stream.writer(io, &.{});
            writer.interface.writeAll(page) catch {};
        }
        self.close(io);
    }
};

/// Signs in, then hands the checked record to `publish(context, record)`,
/// which installs it through the credential owner. The browser is told the
/// outcome only after that. Each `Shown` goes to `display(shown) !void` on
/// the calling thread; a failure the user can act on is shown as `.failed`
/// and returned as `error.Reported`. `cancelled` is checked at each wake and
/// during the exchange.
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

    // An earlier sign-in, signed in or out, names the client the issuer
    // registered; a record without one is no plan sign-in.
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
    if (options.opener) |command| openBrowser(io, command, link);

    const arrived = try waitForCallback(io, room, if (listener) |*server| server else null, paste, cancelled, display, wait_ns);
    const browser: ?*Connection = if (arrived) |index| &room.connections[index] else null;
    errdefer if (browser) |connection| connection.answer(io, wire.page_failed);
    const grant = switch (room.callback) {
        .granted => |*grant| grant,
        .refused => |*code| return fail(display, .{ .refused = code.slice() }),
    };
    // A fixture issues only the fixture client, so a real registration never
    // lands in a test's record.
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

/// Shows `failure` and ends the login as reported, or with the display's
/// own error when it could not show it.
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

/// The host id at `path`, made now when there is none. One that exists is
/// never replaced, whoever made it.
fn hostId(io: std.Io, path: []const u8, host_id: *[wire.host_id_len]u8) !void {
    var buffer: [wire.host_id_len + 2]u8 = undefined;
    if (try credentials.readPrivate(path, &buffer) == null) {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(io, &random);
        const made = wire.formatHostId(&random) ++ [_]u8{'\n'};
        // Another login may have made it meanwhile; then that one stands.
        _ = try credentials.createPrivate(path, &made, &buffer);
    }
    const bytes = try credentials.readPrivate(path, &buffer) orelse return error.InvalidHostId;
    const text = if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
    try wire.validateHostId(text);
    @memcpy(host_id, text);
}

/// Listens on loopback at the preferred port, else any free one; null when
/// neither can be had, and then only a paste can answer.
fn listen(io: std.Io) ?std.Io.net.Server {
    for ([_]u16{ preferred_port, 0 }) |port| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        if (address.listen(io, .{})) |server| return server else |_| {}
    }
    return null;
}

/// Starts the browser on `link` and does not wait for it: the user can
/// always open the printed link instead.
fn openBrowser(io: std.Io, command: []const u8, link: []const u8) void {
    const argv = [_][]const u8{ command, link };
    _ = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
}

/// Waits up to `wait` until the listener or a paste delivers this attempt's
/// callback into `room.callback`. Returns the connection that delivered it,
/// to answer once the sign-in ends, or null for a paste.
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
        // A paste source without a descriptor is read on every wake.
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
        // Wakes to notice cancellation and the deadline.
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

/// Reads what the paste source holds and takes its whole lines: true once
/// they delivered this attempt's callback. Stray lines are shown, and a
/// callback address that is not this attempt's ends the login.
fn readPaste(room: *Room, paste: Paste, open: *bool, display: anytype) !bool {
    const read = paste.read(room.paste[room.paste_len..]) orelse return false;
    if (read == 0) open.* = false;
    room.paste_len += read;
    const pasted = takePastedLines(room, !open.*) catch |err| return fail(display, .{ .callback = callbackFailure(err) });
    if (pasted.delivered) return true;
    if (pasted.strays != 0) try display(Shown{ .stray_paste = room.attempt.port });
    return false;
}

/// What the pasted lines read so far held: this attempt's callback, and how
/// many nonblank lines before it were no callback address at all.
const Pasted = struct { delivered: bool = false, strays: usize = 0 };

/// Reads each whole pasted line, and the rest of the input once it has
/// ended, until one is this attempt's callback. A callback address that is
/// not this attempt's is an error.
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

/// Reads `received` as this attempt's callback: true when it is one, false
/// when it is no callback address at all, which leaves the wait going.
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

/// How `rui auth logout chatgpt` left the browser sign-in.
pub const Browser = enum {
    /// There was no sign-in to end; nothing changed.
    absent,
    /// The issuer confirmed the revocation, and the tokens are gone.
    revoked,
    /// The tokens are gone, but the issuer did not confirm the revocation.
    unconfirmed,
    /// Rui could not find the record: its path is unset or not absolute.
    unlocated,
    /// Rui could not read or sign out the record, which stays as it was.
    failed,
};

/// How `rui auth logout chatgpt` left the device-code sign-in. Rui has no
/// revocation for it, so ending it only removes its tokens.
pub const DeviceCode = enum {
    /// There was no sign-in to end; nothing changed.
    absent,
    /// The tokens are gone.
    removed,
    /// Rui could not find the record: its path is unset or not absolute.
    unlocated,
    /// Rui could not read or sign out the record, which stays as it was.
    failed,
};

/// How a logout left each ChatGPT login, settled once both were tried.
pub const Logout = struct { browser: Browser, device_code: DeviceCode };

const Revoke = struct {
    credentials: credentials.Scratch = undefined,
    url: [1024]u8 = undefined,
    form: [32 * 1024]u8 = undefined,
    response: codex_auth.Response = undefined,
};

/// Ends both ChatGPT logins, each under its own credential lock through
/// `credentials.signOut`: the browser sign-in at `browser_path` revokes its
/// refresh token, best effort, then removes the tokens and keeps the issued
/// client id; the device-code one at `device_code_path` only removes its
/// tokens. A null path is one Rui could not find. Each login has its own
/// path and room, so nothing that fails for one keeps the other from ending.
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
        // No private directory: never signed in.
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

/// The device-code sign-in has no revocation Rui knows of: nothing is sent.
fn keepDeviceCode(_: void, _: *const policy.Record) !void {}

fn revokeBrowser(io: std.Io, credential_path: []const u8, issuer: Issuer, room: *Revoke) !Browser {
    const Context = struct {
        io: std.Io,
        issuer: Issuer,
        room: *Revoke,
        outcome: Browser = .unconfirmed,

        fn revoke(self: *@This(), current: *const policy.Record) !void {
            // Only a record issued to the fixture client reaches a fixture.
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
    var context: Context = .{ .io = io, .issuer = issuer, .room = room };
    if (!try credentials.signOut(credential_path, &room.credentials, &context, Context.revoke)) return .absent;
    return context.outcome;
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
    // The device-code record as status reads it, and what logout makes of
    // it; the browser path is never revoked, so no issuer is reached.
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
            // A login Rui cannot find is that login's own outcome; the other
            // is still ended, and the unfound one is untouched.
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
                // Nothing changed.
                .absent, .failed, .unlocated => if (case[0]) |before| try std.testing.expectEqualStrings(before, after.?) else try std.testing.expectEqual(@as(?[]const u8, null), after),
                // Signed out at the next generation: nothing selects it, and status reads no sign-in.
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

    // A blank line and a stray word are not callbacks; the answer after them is.
    room.paste_len = 0;
    const typed = "\n  \nhello\n" ++ answer ++ "\r\n";
    @memcpy(room.paste[0..typed.len], typed);
    room.paste_len = typed.len;
    try std.testing.expectEqual(Pasted{ .delivered = true, .strays = 1 }, try takePastedLines(room, false));
    try std.testing.expectEqualStrings("oaiapp_x", room.callback.granted.client_id.slice());

    // An answer without its newline waits for one, or for the input to end.
    @memcpy(room.paste[0..answer.len], answer);
    room.paste_len = answer.len;
    try std.testing.expectEqual(Pasted{}, try takePastedLines(room, false));
    try std.testing.expectEqual(answer.len, room.paste_len);
    try std.testing.expectEqual(Pasted{ .delivered = true }, try takePastedLines(room, true));

    // Lines that are no callback are consumed and counted.
    const strays = "one\ntwo\n";
    @memcpy(room.paste[0..strays.len], strays);
    room.paste_len = strays.len;
    try std.testing.expectEqual(Pasted{ .strays = 2 }, try takePastedLines(room, false));
    try std.testing.expectEqual(@as(usize, 0), room.paste_len);

    // Another attempt's answer ends the wait.
    const stale = "http://127.0.0.1:1455/auth/callback?code=c&state=AAAA&client_id=oaiapp_x\n";
    @memcpy(room.paste[0..stale.len], stale);
    room.paste_len = stale.len;
    try std.testing.expectError(error.StateMismatch, takePastedLines(room, false));
}

/// A caller of one test login: it records each `Shown` as a line, pastes
/// what `script` writes for the shown link's state and port, and cancels
/// once the link shows when asked to.
const FakeCaller = struct {
    const Script = *const fn (writer: *std.Io.Writer, state: []const u8, port: []const u8) std.Io.Writer.Error!void;
    var texts: [8][96]u8 = undefined;
    var lens: [8]usize = undefined;
    var count: usize = 0;
    var script: ?Script = null;
    /// Whether the paste source ends once the script's bytes are read.
    var ends: bool = false;
    var cancel_on_link: bool = false;
    var linked: bool = false;
    var port: u16 = 0;
    var bytes: [4096]u8 = undefined;
    var len: usize = 0;
    var at: usize = 0;
    /// The paste source's pipe when it has a descriptor.
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

    /// Writes the script's paste for the link's state and port, into the
    /// pipe when there is one.
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
        // One line at a time, so the lines arrive over several wakes.
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

/// Runs one login against a private directory, through `FakeCaller` with a
/// paste source with or without a descriptor.
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
    // Read a line at a time, the stray line is shown before the answer.
    FakeCaller.reset(Script.write, false, false);
    try std.testing.expectError(error.Reported, testLogin(.openai, false, null));
    try expectShown(&.{ "link", "stray paste, this port", "refused access_denied" });
    // Read in one piece from a descriptor, the answer behind it ends the
    // wait before strays read with it are shown.
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

    // An ended paste source and no listener leave nothing to wait for.
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
