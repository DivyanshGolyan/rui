//! A CONNECT proxy for tests, on a thread of its own. It answers each
//! tunnel request with `Options.status` and, for a 2xx, relays bytes
//! between the client and `Options.target_port` on 127.0.0.1, whatever
//! host the request named. It records a request before it answers it, so
//! a test that reads the record after the client returned sees it whole.
const std = @import("std");
const builtin = @import("builtin");
const tls = @import("../tls.zig");
const Proxy = @This();

pub const Options = struct {
    status: u16 = 200,
    target_port: u16 = 0,
    /// Bytes sent right after the answer, before any relaying.
    after_answer: []const u8 = "",
};

allocator: std.mem.Allocator,
options: Options,
listener: std.posix.fd_t,
port: u16,
thread: std.Thread,
stopping: std.atomic.Value(bool) = .init(false),
/// Requests answered so far; `first_request` holds the first one's bytes.
requests: std.atomic.Value(u32) = .init(0),
first_request: [1024]u8 = undefined,
first_request_len: usize = 0,

pub fn start(allocator: std.mem.Allocator, options: Options) !*Proxy {
    const self = try allocator.create(Proxy);
    errdefer allocator.destroy(self);
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    errdefer _ = std.c.close(fd);
    var address = loopback(0);
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 16) != 0) return error.ListenFailed;
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.BindFailed;
    self.* = .{
        .allocator = allocator,
        .options = options,
        .listener = fd,
        .port = std.mem.bigToNative(u16, address.port),
        .thread = undefined,
    };
    self.thread = try std.Thread.spawn(.{}, run, .{self});
    return self;
}

pub fn stop(self: *Proxy) void {
    self.stopping.store(true, .release);
    self.thread.join();
    _ = std.c.close(self.listener);
    self.allocator.destroy(self);
}

/// `http://127.0.0.1:port`, with `user_info@` when it is not empty.
pub fn url(self: *const Proxy, buffer: []u8, user_info: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://{s}{s}127.0.0.1:{d}", .{ user_info, if (user_info.len > 0) "@" else "", self.port });
}

/// The first request's bytes, once `requests` counts one.
pub fn firstRequest(self: *const Proxy) ?[]const u8 {
    if (self.requests.load(.acquire) == 0) return null;
    return self.first_request[0..self.first_request_len];
}

fn loopback(port: u16) std.c.sockaddr.in {
    var address = std.mem.zeroes(std.c.sockaddr.in);
    address.family = std.c.AF.INET;
    address.addr = std.mem.nativeToBig(u32, 0x7f00_0001);
    address.port = std.mem.nativeToBig(u16, port);
    if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
    return address;
}

fn run(self: *Proxy) void {
    while (!self.stopping.load(.acquire)) {
        if (!ready(self.listener, std.c.POLL.IN)) continue;
        const client = std.c.accept(self.listener, null, null);
        if (client < 0) continue;
        defer _ = std.c.close(client);
        quiet(client);
        self.serve(client);
    }
}

/// Waits briefly for `fd`, so `stop` is never blocked for long.
fn ready(fd: std.posix.fd_t, events: i16) bool {
    var poll = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    return std.c.poll(&poll, 1, 20) > 0;
}

fn serve(self: *Proxy, client: std.posix.fd_t) void {
    var request: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, request[0..len], "\r\n\r\n") == null) {
        if (self.stopping.load(.acquire) or len == request.len) return;
        if (!ready(client, std.c.POLL.IN)) continue;
        const read = std.c.recv(client, request[len..].ptr, request.len - len, 0);
        if (read <= 0) return;
        len += @intCast(read);
    }
    if (self.requests.load(.monotonic) == 0) {
        @memcpy(self.first_request[0..len], request[0..len]);
        self.first_request_len = len;
    }
    _ = self.requests.fetchAdd(1, .release);

    // One send, so the answer and any bytes after it arrive together.
    var answer: [256]u8 = undefined;
    const challenge = if (self.options.status == 407) "Proxy-Authenticate: Basic realm=\"test\"\r\n" else "";
    const head = std.fmt.bufPrint(&answer, "HTTP/1.1 {d} Test\r\n{s}\r\n{s}", .{ self.options.status, challenge, self.options.after_answer }) catch unreachable;
    if (!sendAll(client, head)) return;
    if (self.options.status < 200 or self.options.status > 299) return;

    const target = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (target < 0) return;
    defer _ = std.c.close(target);
    quiet(target);
    const address = loopback(self.options.target_port);
    if (std.c.connect(target, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return;
    self.relay(client, target);
}

/// Copies bytes both ways until either side closes or the proxy stops.
fn relay(self: *Proxy, a: std.posix.fd_t, b: std.posix.fd_t) void {
    var buffer: [16 * 1024]u8 = undefined;
    while (!self.stopping.load(.acquire)) {
        var polls = [_]std.c.pollfd{
            .{ .fd = a, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = b, .events = std.c.POLL.IN, .revents = 0 },
        };
        if (std.c.poll(&polls, 2, 20) <= 0) continue;
        for (polls, [_]std.posix.fd_t{ b, a }) |poll, to| {
            if (poll.revents == 0) continue;
            const read = std.c.recv(poll.fd, &buffer, buffer.len, 0);
            if (read <= 0 or !sendAll(to, buffer[0..@intCast(read)])) return;
        }
    }
}

/// A side that went away must not SIGPIPE the test process.
fn quiet(fd: std.posix.fd_t) void {
    if (!builtin.os.tag.isDarwin()) return;
    const one: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
}

fn sendAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const count = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, tls.send_flags);
        if (count <= 0) return false;
        sent += @intCast(count);
    }
    return true;
}
