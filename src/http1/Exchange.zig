const std = @import("std");
const Parser = @import("Parser.zig");
const request = @import("request.zig");
const socket_os = @import("../os/socket.zig");

const Exchange = @This();

pub const buffer_bytes = Parser.max_head_bytes;

pub const Error = Parser.Error || error{
    LocalFailure,
    ConnectFailed,
    ConnectionLost,
};

pub const Event = union(enum) {
    waiting,
    head: Parser.Head,
    body: []const u8,
    end,
};

const State = enum { connecting, open, done };

fd: std.posix.fd_t,
state: State,
pending: []const u8,
sent: usize,
parser: Parser,
start: usize,
end: usize,
buffer: [buffer_bytes]u8 = undefined,

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
    if (!socket_os.configure(fd, true)) return error.LocalFailure;
    while (true) switch (std.posix.errno(std.c.connect(fd, @ptrCast(&storage), length))) {
        .SUCCESS => {
            self.state = .open;
            return;
        },
        .INTR => continue,
        .INPROGRESS => return,
        .NOBUFS, .NOMEM, .MFILE, .NFILE, .ADDRNOTAVAIL => return error.LocalFailure,
        else => return error.ConnectFailed,
    };
}

pub fn deinit(self: *Exchange) void {
    if (self.fd >= 0) _ = std.c.close(self.fd);
    self.fd = -1;
    self.state = .done;
}

pub fn events(self: *const Exchange) i16 {
    return switch (self.state) {
        .connecting => std.c.POLL.OUT,
        .open => if (self.pending.len != 0) std.c.POLL.IN | std.c.POLL.OUT else std.c.POLL.IN,
        .done => 0,
    };
}

pub fn requestSent(self: *const Exchange) bool {
    return self.sent != 0;
}

pub fn advance(self: *Exchange) Error!Event {
    while (true) switch (self.state) {
        .connecting => {
            switch (socket_os.connectStatus(self.fd)) {
                .connected => self.state = .open,
                .pending => return .waiting,
                .refused => return error.ConnectFailed,
                .failed => return error.LocalFailure,
            }
        },
        .open => {
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
            const sent = try self.send();
            const received = try self.receive();
            switch (received) {
                .bytes => {},
                .closed => {
                    _ = try self.parser.finish();
                    return self.finished();
                },
                .none => if (!sent) return .waiting,
            }
        },
        .done => return .end,
    };
}

fn send(self: *Exchange) Error!bool {
    if (self.pending.len == 0) return false;
    while (true) {
        const sent = std.c.send(self.fd, self.pending.ptr, self.pending.len, socket_os.send_flags);
        switch (std.posix.errno(sent)) {
            .SUCCESS => {
                self.sent += @intCast(sent);
                self.pending = self.pending[@intCast(sent)..];
                return true;
            },
            .INTR => continue,
            .AGAIN => return false,
            else => {
                if (self.sent == 0) return error.ConnectFailed;
                self.pending = &.{};
                return false;
            },
        }
    }
}

const Received = enum { bytes, closed, none };

fn receive(self: *Exchange) Error!Received {
    if (self.start != 0) {
        const held = self.end - self.start;
        std.mem.copyForwards(u8, self.buffer[0..held], self.buffer[self.start..self.end]);
        self.start = 0;
        self.end = held;
    }
    std.debug.assert(self.end < self.buffer.len);
    while (true) {
        const read = std.c.recv(self.fd, self.buffer[self.end..].ptr, self.buffer.len - self.end, 0);
        switch (std.posix.errno(read)) {
            .SUCCESS => {
                if (read == 0) return .closed;
                self.end += @intCast(read);
                return .bytes;
            },
            .INTR => continue,
            .AGAIN => return .none,
            else => return error.ConnectionLost,
        }
    }
}

fn finished(self: *Exchange) Event {
    self.deinit();
    return .end;
}

const TestServer = struct {
    listener: std.posix.fd_t,
    port: u16,
    thread: ?std.Thread = null,
    reply: ?[]const []const u8,
    seen: [1024]u8 = undefined,
    seen_len: usize = 0,
    answer_early: bool = false,
    drain_released: std.Io.Event = .unset,

    fn start(self: *TestServer) !void {
        // std's backlog is ample: Darwin refuses a connect beyond a full
        // backlog, where Linux queues it.
        const server = try (try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(std.testing.io, .{});
        self.listener = server.socket.handle;
        self.port = server.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn join(self: *TestServer) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn serve(self: *TestServer) void {
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        const replies = self.reply orelse return;
        while (std.mem.indexOf(u8, self.seen[0..self.seen_len], "\r\n\r\n") == null or (!self.answer_early and !self.bodyIn())) {
            const read = std.c.recv(fd, self.seen[self.seen_len..].ptr, self.seen.len - self.seen_len, 0);
            if (read <= 0) return;
            self.seen_len += @intCast(read);
        }
        for (replies) |part| {
            var written: usize = 0;
            while (written < part.len) {
                const sent = std.c.send(fd, part[written..].ptr, part.len - written, socket_os.send_flags);
                if (sent <= 0) return;
                written += @intCast(sent);
            }
        }
        if (!self.answer_early) return;
        self.drain_released.waitUncancelable(std.testing.io);
        var drain: [4096]u8 = undefined;
        while (std.c.recv(fd, &drain, drain.len, 0) > 0) {}
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
        self.drain_released.set(std.testing.io);
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

fn drive(exchange: *Exchange, out: *Outcome) Error!void {
    defer out.sent = exchange.requestSent();
    while (true) {
        switch (try exchange.advance()) {
            .waiting => {
                var poll_fd = [_]std.c.pollfd{.{ .fd = exchange.fd, .events = exchange.events(), .revents = 0 }};
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
    var server: TestServer = .{ .listener = -1, .port = try @import("../socket_fixture.zig").refusedPort(), .reply = null };
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

test "an answer that arrives while the request is still uploading is read" {
    var server: TestServer = .{ .listener = -1, .port = 0, .answer_early = true, .reply = &.{"HTTP/1.1 413 Content Too Large\r\nContent-Length: 8\r\n\r\ntoo big!"} };
    try server.start();
    defer server.stop();
    var url_buffer: [64]u8 = undefined;
    const target = try request.parseTarget(try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{server.port}));
    const body_len = 16 * 1024 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, 512 + body_len);
    defer std.testing.allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try request.writePost(&writer, target, &.{}, body_len);
    const head_len = writer.buffered().len;
    @memset(bytes[head_len..][0..body_len], 'x');
    const exchange = try std.testing.allocator.create(Exchange);
    defer std.testing.allocator.destroy(exchange);
    try exchange.init(target, bytes[0 .. head_len + body_len]);
    defer exchange.deinit();
    var out: Outcome = .{};
    try drive(exchange, &out);
    try std.testing.expectEqual(@as(u16, 413), out.status);
    try std.testing.expectEqualStrings("too big!", out.body[0..out.body_len]);
    try std.testing.expect(out.sent);
    try std.testing.expect(exchange.sent < head_len + body_len);
}

test "a malformed response is refused, not read as a body" {
    var server: TestServer = .{ .listener = -1, .port = 0, .reply = &.{"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"} };
    try server.start();
    defer server.stop();
    var out: Outcome = .{};
    try std.testing.expectError(error.InvalidFraming, post(&server, "{}", &out));
}
