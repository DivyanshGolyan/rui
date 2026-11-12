//! `rui auth login chatgpt` and `rui auth logout chatgpt`: the shell around
//! the plan sign-in's messages (`chatgpt_plan_wire.zig`).
//!
//! Login listens on loopback for the browser's callback and, at the same
//! time, reads a callback address pasted on stdin, so a machine without a
//! browser or whose browser cannot reach the listener signs in by pasting;
//! the first answer that is this attempt's wins. Every decision about what
//! arrived, and every message sent, is the wire module's; the record is
//! published by the caller through the credential custody owner
//! (`codex_credentials.zig`). Logout revokes the refresh token and signs the
//! record out under that owner's lock, keeping the issued client id for the
//! next sign-in; the host id file is never touched after it is made.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("chatgpt_plan_wire.zig");
const policy = @import("codex_credential_policy.zig");
const credentials = @import("codex_credentials.zig");
const codex_auth = @import("codex_auth.zig");
const pages = @import("os/pages.zig");

/// The port the redirect names when it is free; any free port also works.
pub const preferred_port: u16 = 1455;
/// How long a login waits for the browser or a paste.
const wait_ns: i96 = 30 * std.time.ns_per_min;
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

/// The login's storage: the saved record it reads, the attempt, what
/// arrived and the exchange. The command maps it for the call and wipes it.
const Room = struct {
    saved: credentials.Scratch = undefined,
    attempt: wire.Attempt = undefined,
    callback: wire.Callback = undefined,
    link: [8 * 1024]u8 = undefined,
    shown: [8 * 1024]u8 = undefined,
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
/// outcome only after that. A failure the user can act on is printed here
/// and returned as `error.Reported`.
pub fn login(io: std.Io, options: Options, cancelled: *const fn () bool, record: *policy.Record, context: anytype, publish: anytype) !void {
    var host_id: [wire.host_id_len]u8 = undefined;
    hostId(io, options.host_id_path, &host_id) catch |err| {
        if (err == error.InvalidHostId) {
            std.debug.print("rui: {s} does not hold a host id Rui wrote; move it aside and sign in again.\n", .{options.host_id_path});
            return error.Reported;
        }
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
    std.debug.print(
        \\Sign in with ChatGPT. Open this link in a browser where you are already signed in to ChatGPT:
        \\
        \\{s}
        \\
        \\If the page says "Your session has ended", sign in to ChatGPT, then open the link again.
        \\If the browser ends on a page that cannot load, copy its address and paste it here, then press Enter.
        \\Waiting for the browser (Ctrl+C cancels)...
        \\
    , .{link});
    if (options.opener) |command| openBrowser(io, command, link);

    const arrived = try waitForCallback(io, room, if (listener) |*server| server else null, cancelled);
    const browser: ?*Connection = if (arrived) |index| &room.connections[index] else null;
    errdefer if (browser) |connection| connection.answer(io, wire.page_failed);
    const grant = switch (room.callback) {
        .granted => |*grant| grant,
        .refused => |*code| {
            std.debug.print("rui: ChatGPT did not grant the sign-in ({s}). Nothing was saved.\n", .{code.slice()});
            return error.Reported;
        },
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
        std.debug.print("rui: could not reach ChatGPT's sign-in service ({s}). Nothing was saved; run rui auth login chatgpt again.\n", .{@errorName(err)});
        return error.Reported;
    };
    wire.loginRecord(&room.attempt, grant, status, room.response.bytes[0..room.response.len], codex_auth.nowSeconds(io), record, &room.scratch) catch |err| {
        std.debug.print("rui: {s} Nothing was saved.\n", .{exchangeFailure(err)});
        return error.Reported;
    };
    try publish(context, record);
    if (browser) |connection| connection.answer(io, wire.page_signed_in);
}

fn exchangeFailure(err: anyerror) []const u8 {
    return switch (err) {
        error.PlanScopeMissing => "You signed in, but ChatGPT did not let Rui use your plan. Allow it on the ChatGPT page, then run rui auth login chatgpt again.",
        error.TokenExchangeRejected => "ChatGPT refused the sign-in code. Run rui auth login chatgpt again for a new link.",
        error.IdTokenIssuerMismatch, error.IdTokenAudienceMismatch, error.IdTokenExpired, error.IdTokenNonceMismatch => "ChatGPT's answer was not for this sign-in.",
        else => "ChatGPT's answer could not be read.",
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

/// Waits until the listener or a paste delivers this attempt's callback into
/// `room.callback`. Returns the connection that delivered it, to answer once
/// the sign-in ends, or null for a paste.
fn waitForCallback(io: std.Io, room: *Room, listener: ?*std.Io.net.Server, cancelled: *const fn () bool) !?usize {
    const stdin = std.Io.File.stdin().handle;
    var stdin_open = true;
    const started = std.Io.Clock.Timestamp.now(io, .boot);
    const Source = union(enum) { listener, stdin, connection: usize };
    while (true) {
        if (cancelled()) return error.LoginInterrupted;
        if (started.durationTo(std.Io.Clock.Timestamp.now(io, .boot)).raw.nanoseconds >= wait_ns) {
            std.debug.print("rui: no sign-in answer arrived in 30 minutes. Nothing was saved; run rui auth login chatgpt again.\n", .{});
            return error.Reported;
        }
        var fds: [2 + max_connections]std.posix.pollfd = undefined;
        var sources: [fds.len]Source = undefined;
        var count: usize = 0;
        if (listener) |server| {
            fds[count] = .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .listener;
            count += 1;
        }
        if (stdin_open) {
            fds[count] = .{ .fd = stdin, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .stdin;
            count += 1;
        }
        for (&room.connections, 0..) |*connection, index| if (connection.stream) |stream| {
            fds[count] = .{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 };
            sources[count] = .{ .connection = index };
            count += 1;
        };
        if (count == 0) {
            std.debug.print("rui: input ended and Rui could not listen for the browser, so no sign-in answer can arrive. Nothing was saved.\n", .{});
            return error.Reported;
        }
        // Wakes to notice Ctrl+C and the deadline.
        if (try std.posix.poll(fds[0..count], 250) == 0) continue;
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
                .stdin => {
                    const read = std.posix.read(stdin, room.paste[room.paste_len..]) catch 0;
                    if (read == 0) stdin_open = false;
                    room.paste_len += read;
                    const pasted = takePastedLines(room, !stdin_open) catch |err| return callbackFailure(err);
                    if (pasted.delivered) return null;
                    if (pasted.strays != 0) std.debug.print("rui: that is not the address the browser ended on. Paste the whole address, which starts with http://127.0.0.1:{d}/auth/callback\n", .{room.attempt.port});
                },
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
                        return callbackFailure(err);
                    }
                },
            }
        }
    }
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

fn callbackFailure(err: anyerror) anyerror {
    std.debug.print("rui: {s} Nothing was saved; run rui auth login chatgpt again.\n", .{switch (err) {
        error.StateMismatch => "That answer is not from this sign-in.",
        error.ClientIdMismatch => "ChatGPT answered for another app registration than the one Rui saved.",
        error.MissingClientId => "ChatGPT's answer did not name Rui's app registration.",
        else => "The sign-in answer was incomplete or damaged.",
    }});
    return error.Reported;
}

/// How a logout ended.
pub const Logout = enum {
    /// There was no sign-in to end; nothing changed.
    not_signed_in,
    /// The issuer confirmed the revocation, and the tokens are gone.
    revoked,
    /// The tokens are gone, but the issuer did not confirm the revocation.
    unconfirmed,
};

const Revoke = struct {
    credentials: credentials.Scratch = undefined,
    url: [1024]u8 = undefined,
    form: [32 * 1024]u8 = undefined,
    response: codex_auth.Response = undefined,
};

/// Revokes the refresh token, best effort, then removes the tokens and keeps
/// the issued client id (`credentials.signOut`).
pub fn logout(io: std.Io, credential_path: []const u8, issuer: Issuer) !Logout {
    const mapped = try pages.Mapped(Revoke).map();
    defer mapped.unmap();
    const room = mapped.value;
    defer std.crypto.secureZero(u8, std.mem.asBytes(room));
    const Context = struct {
        io: std.Io,
        issuer: Issuer,
        room: *Revoke,
        outcome: Logout = .unconfirmed,

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
    if (!try credentials.signOut(credential_path, &room.credentials, &context, Context.revoke)) return .not_signed_in;
    return context.outcome;
}

/// The command that opens a link in a browser here, if there is a browser to
/// open: macOS always has one; elsewhere only a graphical session does.
pub fn opener(environ: *const std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag.isDarwin()) return "open";
    if (environ.get("DISPLAY") != null or environ.get("WAYLAND_DISPLAY") != null) return "xdg-open";
    return null;
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
