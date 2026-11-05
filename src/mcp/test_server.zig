//! A scripted loopback HTTP server for tests. It takes one connection for
//! `reply` and one more for each of `more`, reads a whole request on each
//! and sends that reply. `seen` holds the latest request.
const std = @import("std");

const Script = @This();

listener: std.posix.fd_t = -1,
port: u16 = 0,
thread: ?std.Thread = null,
reply: []const u8,
more: []const []const u8 = &.{},
/// Wait for client cancellation instead of replying; observations publish before exit.
hold_reply: bool = false,
request_received: std.atomic.Value(bool) = .init(false),
connection_closed: std.atomic.Value(bool) = .init(false),
seen: [4096]u8 = undefined,
seen_len: usize = 0,

pub fn start(self: *Script) !void {
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
    self.thread = try std.Thread.spawn(.{}, serveAll, .{self});
}

fn serveAll(self: *Script) void {
    self.serve(self.reply);
    for (self.more) |reply| self.serve(reply);
}

fn serve(self: *Script, reply: []const u8) void {
    const fd_ = std.c.accept(self.listener, null, null);
    if (fd_ < 0) return;
    defer _ = std.c.close(fd_);
    self.seen_len = 0;
    while (!self.requestIn()) {
        const read = std.c.recv(fd_, self.seen[self.seen_len..].ptr, self.seen.len - self.seen_len, 0);
        if (read <= 0) return;
        self.seen_len += @intCast(read);
    }
    self.request_received.store(true, .release);
    if (self.hold_reply) {
        var byte: [1]u8 = undefined;
        const received = std.c.recv(fd_, &byte, byte.len, 0);
        self.connection_closed.store(received == 0, .release);
        return;
    }
    var written: usize = 0;
    while (written < reply.len) {
        const sent = std.c.send(fd_, reply[written..].ptr, reply.len - written, 0);
        if (sent <= 0) return;
        written += @intCast(sent);
    }
}

fn requestIn(self: *const Script) bool {
    const seen = self.seen[0..self.seen_len];
    const head_end = (std.mem.indexOf(u8, seen, "\r\n\r\n") orelse return false) + 4;
    const marker = "Content-Length: ";
    const at = std.mem.indexOf(u8, seen[0..head_end], marker).? + marker.len;
    const line_end = std.mem.indexOfPos(u8, seen, at, "\r\n").?;
    return seen.len >= head_end + (std.fmt.parseInt(usize, seen[at..line_end], 10) catch unreachable);
}

pub fn stop(self: *Script) void {
    if (self.thread) |thread| thread.join();
    _ = std.c.close(self.listener);
}

/// An `application/json` reply carrying `body`.
pub fn jsonReply(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}
