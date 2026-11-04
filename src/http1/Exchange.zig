//! One HTTP/1.1 request and its response on one nonblocking loopback
//! connection. The owner polls `fd` for `events()` alongside its other work
//! and calls `advance` when it is ready; nothing here blocks, sleeps or runs
//! on its own, so the existing Reactor drives it with no new thread (D66).
//!
//! The connection carries exactly one request (`Connection: close`), so
//! `deinit` closing it is also the cancel an MCP server watches for (D65).
//! `requestSent` is the evidence a caller needs to tell "failed, not run"
//! from "outcome unknown" (D146): it is false only while no request byte has
//! left this process.
//!
//! Lifetime: an Exchange is about 16 KiB and has one address; its owner
//! initializes it in place and keeps it there until `deinit`. The request
//! bytes are borrowed until the response head arrives or `deinit`; every
//! slice an event carries is borrowed until the next `advance`.
const std = @import("std");
const builtin = @import("builtin");
const Parser = @import("Parser.zig");
const request = @import("request.zig");

const Exchange = @This();

/// Unread response bytes. A head must fit here whole.
pub const buffer_bytes = Parser.max_head_bytes;

pub const Error = Parser.Error || error{
    /// No socket could be made or set up; nothing was sent.
    LocalFailure,
    /// The server refused or dropped the connection before it was
    /// established; nothing was sent.
    ConnectFailed,
    /// The connection broke after it was established.
    ConnectionLost,
};

pub const Event = union(enum) {
    /// Nothing more until `fd` is ready for `events()`.
    waiting,
    head: Parser.Head,
    body: []const u8,
    /// The response is complete; the exchange is done.
    end,
};

const State = enum { connecting, sending, receiving, done };

fd: std.posix.fd_t,
state: State,
pending: []const u8,
sent: usize,
parser: Parser,
start: usize,
end: usize,
buffer: [buffer_bytes]u8 = undefined,

/// Opens the connection and starts the request. `bytes` is the whole
/// request, head and body, as `request.writePost` and the body make it.
pub fn init(self: *Exchange, target: request.Target, bytes: []const u8) error{ LocalFailure, ConnectFailed }!void {
    self.* = .{ .fd = -1, .state = .connecting, .pending = bytes, .sent = 0, .parser = .{}, .start = 0, .end = 0 };
    var storage: std.c.sockaddr.in6 = std.mem.zeroes(std.c.sockaddr.in6);
    var length: std.c.socklen_t = undefined;
    const family: c_uint = switch (target.family) {
        .ipv4 => family: {
            const v4: *std.c.sockaddr.in = @ptrCast(&storage);
            v4.family = std.c.AF.INET;
            v4.port = std.mem.nativeToBig(u16, target.port);
            v4.addr = @bitCast(target.address[0..4].*);
            if (@hasField(std.c.sockaddr.in, "len")) v4.len = @sizeOf(std.c.sockaddr.in);
            length = @sizeOf(std.c.sockaddr.in);
            break :family std.c.AF.INET;
        },
        .ipv6 => family: {
            storage.family = std.c.AF.INET6;
            storage.port = std.mem.nativeToBig(u16, target.port);
            storage.addr = target.address;
            if (@hasField(std.c.sockaddr.in6, "len")) storage.len = @sizeOf(std.c.sockaddr.in6);
            length = @sizeOf(std.c.sockaddr.in6);
            break :family std.c.AF.INET6;
        },
    };
    const fd = std.c.socket(family, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.LocalFailure;
    self.fd = fd;
    errdefer self.deinit();
    if (!configure(fd)) return error.LocalFailure;
    while (true) switch (std.posix.errno(std.c.connect(fd, @ptrCast(&storage), length))) {
        .SUCCESS => {
            self.state = .sending;
            return;
        },
        .INTR => continue,
        .INPROGRESS => return,
        .NOBUFS, .NOMEM, .MFILE, .NFILE, .ADDRNOTAVAIL => return error.LocalFailure,
        else => return error.ConnectFailed,
    };
}

/// Closes the connection, which cancels the request if it is still open.
pub fn deinit(self: *Exchange) void {
    // A failed close leaves nothing to retry: the descriptor is released
    // either way, and no write of ours awaits its result.
    if (self.fd >= 0) _ = std.c.close(self.fd);
    self.fd = -1;
    self.state = .done;
}

/// The poll events `advance` waits for; none once the exchange is done.
pub fn events(self: *const Exchange) i16 {
    return switch (self.state) {
        .connecting, .sending => std.c.POLL.OUT,
        .receiving => std.c.POLL.IN,
        .done => 0,
    };
}

pub fn requestSent(self: *const Exchange) bool {
    return self.sent != 0;
}

/// Does all work the socket allows now and returns the first event. Call
/// again after any event but `.waiting` and `.end` without polling first.
pub fn advance(self: *Exchange) Error!Event {
    while (true) switch (self.state) {
        .connecting => {
            var result: c_int = 0;
            var result_len: std.c.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(self.fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &result, &result_len) != 0) return error.LocalFailure;
            if (result != 0) return error.ConnectFailed;
            // No error yet is not success: a peer name exists only once the
            // connection is established.
            var peer: std.c.sockaddr.in6 = undefined;
            var peer_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in6);
            switch (std.posix.errno(std.c.getpeername(self.fd, @ptrCast(&peer), &peer_len))) {
                .SUCCESS => self.state = .sending,
                .NOTCONN => return .waiting,
                else => return error.LocalFailure,
            }
        },
        .sending => {
            if (self.sent == self.pending.len) {
                self.state = .receiving;
                continue;
            }
            const rest = self.pending[self.sent..];
            const sent = std.c.send(self.fd, rest.ptr, rest.len, send_flags);
            switch (std.posix.errno(sent)) {
                .SUCCESS => self.sent += @intCast(sent),
                .INTR => {},
                .AGAIN => return .waiting,
                else => return if (self.sent == 0) error.ConnectFailed else error.ConnectionLost,
            }
        },
        .receiving => {
            // The parser runs even on no bytes: a body that has just ended
            // reports its end without another read.
            const step = try self.parser.next(self.buffer[self.start..self.end]);
            self.start += step.used;
            switch (step.event) {
                .more => if (step.used != 0) continue,
                .head => |head| {
                    self.pending = &.{};
                    return .{ .head = head };
                },
                .body => |bytes| return .{ .body = bytes },
                .end => return self.finished(),
            }
            if (self.start != 0) {
                const held = self.end - self.start;
                std.mem.copyForwards(u8, self.buffer[0..held], self.buffer[self.start..self.end]);
                self.start = 0;
                self.end = held;
            }
            // The parser asks for more only while a head or line is
            // incomplete, both bounded below the buffer.
            std.debug.assert(self.end < self.buffer.len);
            const read = std.c.recv(self.fd, self.buffer[self.end..].ptr, self.buffer.len - self.end, 0);
            switch (std.posix.errno(read)) {
                .SUCCESS => {
                    if (read == 0) {
                        _ = try self.parser.finish();
                        return self.finished();
                    }
                    self.end += @intCast(read);
                },
                .INTR => {},
                .AGAIN => return .waiting,
                else => return error.ConnectionLost,
            }
        },
        .done => return .end,
    };
}

fn finished(self: *Exchange) Event {
    self.deinit();
    return .end;
}

const send_flags: c_int = if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;

fn configure(fd: std.posix.fd_t) bool {
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return false;
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return false;
    const one: c_int = 1;
    if (std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &one, @sizeOf(c_int)) != 0) return false;
    if (builtin.os.tag.isDarwin()) {
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) != 0) return false;
    }
    return true;
}

// Tests run a real loopback server on a thread. The server reads the whole
// request before it answers, so what it saw is recorded before the client
// can finish.

const TestServer = struct {
    listener: std.posix.fd_t,
    port: u16,
    thread: ?std.Thread = null,
    /// What to write after reading the request head; null closes at once.
    reply: ?[]const []const u8,
    seen: [1024]u8 = undefined,
    seen_len: usize = 0,

    fn start(self: *TestServer) !void {
        self.listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (self.listener < 0) return error.SocketFailed;
        var address: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
        address.family = std.c.AF.INET;
        address.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
        if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
        if (std.c.bind(self.listener, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
        if (std.c.listen(self.listener, 1) != 0) return error.ListenFailed;
        var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(self.listener, @ptrCast(&address), &length) != 0) return error.NameFailed;
        self.port = std.mem.bigToNative(u16, address.port);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Waits for the server to finish, after which `seen` is complete.
    fn join(self: *TestServer) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn serve(self: *TestServer) void {
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        const replies = self.reply orelse return;
        // Read until the head and its declared body are in.
        while (std.mem.indexOf(u8, self.seen[0..self.seen_len], "\r\n\r\n") == null or !self.bodyIn()) {
            const read = std.c.recv(fd, self.seen[self.seen_len..].ptr, self.seen.len - self.seen_len, 0);
            if (read <= 0) return;
            self.seen_len += @intCast(read);
        }
        for (replies) |part| {
            var written: usize = 0;
            while (written < part.len) {
                const sent = std.c.send(fd, part[written..].ptr, part.len - written, send_flags);
                if (sent <= 0) return;
                written += @intCast(sent);
            }
        }
    }

    fn bodyIn(self: *const TestServer) bool {
        const seen = self.seen[0..self.seen_len];
        const head_end = (std.mem.indexOf(u8, seen, "\r\n\r\n") orelse return false) + 4;
        const marker = "Content-Length: ";
        const at = (std.mem.indexOf(u8, seen[0..head_end], marker) orelse return true) + marker.len;
        const line_end = std.mem.indexOfPos(u8, seen, at, "\r\n").?;
        const length = std.fmt.parseInt(usize, seen[at..line_end], 10) catch return true;
        return seen.len >= head_end + length;
    }

    fn stop(self: *TestServer) void {
        self.join();
        _ = std.c.close(self.listener);
    }
};

const Outcome = struct {
    status: u16 = 0,
    body: [256]u8 = undefined,
    body_len: usize = 0,
    sent: bool = false,
};

/// Drives `exchange` to its end the way an owner would: poll, then advance.
fn drive(exchange: *Exchange, out: *Outcome) Error!void {
    defer out.sent = exchange.requestSent();
    while (true) {
        switch (try exchange.advance()) {
            .waiting => {
                var poll_fd = [_]std.c.pollfd{.{ .fd = exchange.fd, .events = exchange.events(), .revents = 0 }};
                // Bounded so a broken test fails instead of hanging.
                if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
            },
            .head => |head| out.status = head.status,
            .body => |bytes| {
                @memcpy(out.body[out.body_len..][0..bytes.len], bytes);
                out.body_len += bytes.len;
            },
            .end => return,
        }
    }
}

fn post(server: *TestServer, body: []const u8, out: *Outcome) !void {
    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{server.port});
    const target = try request.parseTarget(url);
    var bytes: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try request.writePost(&writer, target, &.{.{ .name = "Content-Type", .value = "application/json" }}, body.len);
    try writer.writeAll(body);
    const exchange = try std.testing.allocator.create(Exchange);
    defer std.testing.allocator.destroy(exchange);
    try exchange.init(target, writer.buffered());
    defer exchange.deinit();
    try drive(exchange, out);
}

test "a request gets its framed response over loopback" {
    const replies = [_][]const []const u8{
        &.{"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"},
        &.{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "6\r\n{\"ok\":\r\n", "5\r\ntrue}\r\n0\r\n\r\n" },
        &.{ "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", "{\"ok\":true}" },
    };
    for (replies) |reply| {
        var server: TestServer = .{ .listener = -1, .port = 0, .reply = reply };
        try server.start();
        defer server.stop();
        var out: Outcome = .{};
        try post(&server, "{\"q\":1}", &out);
        try std.testing.expectEqual(@as(u16, 200), out.status);
        try std.testing.expectEqualStrings("{\"ok\":true}", out.body[0..out.body_len]);
        try std.testing.expect(out.sent);
        server.join();
        const seen = server.seen[0..server.seen_len];
        try std.testing.expect(std.mem.startsWith(u8, seen, "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:"));
        try std.testing.expect(std.mem.endsWith(u8, seen, "Connection: close\r\n\r\n{\"q\":1}"));
    }
}

test "a refused connection sends nothing" {
    // A port bound but not listening refuses, and stays ours meanwhile.
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var address: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
    address.family = std.c.AF.INET;
    address.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
    if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)));
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(fd, @ptrCast(&address), &length));
    var server: TestServer = .{ .listener = -1, .port = std.mem.bigToNative(u16, address.port), .reply = null };
    var out: Outcome = .{};
    try std.testing.expectError(error.ConnectFailed, post(&server, "{}", &out));
    try std.testing.expect(!out.sent);
}

test "a response cut short after the request left is a lost outcome" {
    var server: TestServer = .{ .listener = -1, .port = 0, .reply = &.{"HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\npartial"} };
    try server.start();
    defer server.stop();
    var out: Outcome = .{};
    try std.testing.expectError(error.TruncatedResponse, post(&server, "{}", &out));
    try std.testing.expect(out.sent);
    try std.testing.expectEqualStrings("partial", out.body[0..out.body_len]);
}

test "a malformed response is refused, not read as a body" {
    var server: TestServer = .{ .listener = -1, .port = 0, .reply = &.{"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"} };
    try server.start();
    defer server.stop();
    var out: Outcome = .{};
    try std.testing.expectError(error.InvalidFraming, post(&server, "{}", &out));
}
