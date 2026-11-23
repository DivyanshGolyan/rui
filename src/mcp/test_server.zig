const std = @import("std");

const Script = @This();

listener: std.posix.fd_t = -1,
port: u16 = 0,
thread: ?std.Thread = null,
reply: []const u8,
more: []const []const u8 = &.{},
hold_reply: bool = false,
/// Answers `subscriptions/listen` requests. Without it those requests take the ordinary replies.
listening: ?*Listening = null,
request_received: std.atomic.Value(bool) = .init(false),
/// Requests answered so far, counted before the reply is sent.
requests: std.atomic.Value(usize) = .init(0),
connection_closed: std.atomic.Value(bool) = .init(false),
stopping: std.atomic.Value(bool) = .init(false),
seen: [4096]u8 = undefined,
seen_len: usize = 0,

/// A `subscriptions/listen` stream the test holds open. On accept the serve loop writes the opening
/// (an acknowledgment, or an HTTP refusal) and keeps the socket; the test then pushes, finishes or
/// drops the stream from its own thread while ordinary requests are still answered.
pub const Listening = struct {
    pub const Opening = union(enum) {
        /// Acknowledges the subscription, its filter keeping `toolsListChanged` when `tools` is set,
        /// then holds the stream open.
        acknowledge: struct { tools: bool },
        /// Answers the subscribe request with this HTTP status and no stream.
        status: u16,
    };

    opening: Opening = .{ .acknowledge = .{ .tools = true } },
    /// The subscription's id, which is its request's JSON-RPC id. Written before `fd` is published.
    id: u64 = 0,
    fd: std.atomic.Value(std.posix.fd_t) = .init(-1),

    /// Called by the serve loop with the accepted socket. Returns true when the stream is held.
    fn open(self: *Listening, socket: std.posix.fd_t, id: u64) bool {
        switch (self.opening) {
            .acknowledge => |ack| {
                var event: [1024]u8 = undefined;
                const text = std.fmt.bufPrint(&event, "data: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\"," ++
                    "\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}}," ++
                    "\"notifications\":{s}}}}}\n\n", .{ id, if (ack.tools) "{\"toolsListChanged\":true}" else "{}" }) catch unreachable;
                if (!sendAll(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")) return false;
                self.id = id;
                self.fd.store(socket, .release);
                if (!sendChunk(socket, text)) return false;
                return true;
            },
            .status => |status| {
                var head: [128]u8 = undefined;
                const text = std.fmt.bufPrint(&head, "HTTP/1.1 {d} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch unreachable;
                _ = sendAll(socket, text);
                return false;
            },
        }
    }

    /// Pushes one SSE event (its text, `data: ...` and its blank line) on the held stream.
    pub fn push(self: *Listening, event: []const u8) void {
        const socket = self.fd.load(.acquire);
        if (socket < 0) return;
        _ = sendChunk(socket, event);
    }

    /// Ends the stream the way a server does on purpose: the completion result, then the chunked end.
    pub fn finish(self: *Listening) void {
        var event: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&event, "data: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\"," ++
            "\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}}}}}}\n\n", .{ self.id, self.id }) catch unreachable;
        self.push(text);
        const socket = self.fd.load(.acquire);
        if (socket < 0) return;
        _ = sendAll(socket, "0\r\n\r\n");
        self.close();
    }

    /// Drops the connection with no result and no chunked end: an abrupt close.
    pub fn drop(self: *Listening) void {
        self.close();
    }

    /// Closes the held socket if it is still open.
    pub fn close(self: *Listening) void {
        const socket = self.fd.swap(-1, .acq_rel);
        if (socket >= 0) _ = std.c.close(socket);
    }
};

pub fn start(self: *Script) !void {
    // std's backlog is ample: Darwin refuses a connect beyond a full
    // backlog, where Linux queues it.
    const server = try (try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(std.testing.io, .{});
    self.listener = server.socket.handle;
    self.port = server.socket.address.getPort();
    self.thread = try std.Thread.spawn(.{}, serveAll, .{self});
}

/// Serves connections in order. Each ordinary request takes the next scripted reply; a held
/// subscription takes none, so ordinary requests are still answered while it stays open.
fn serveAll(self: *Script) void {
    var answered: usize = 0;
    while (answered <= self.more.len) {
        if (answered > 0 and self.stopping.load(.acquire)) return;
        const reply = if (answered == 0) self.reply else self.more[answered - 1];
        if (self.serve(reply)) answered += 1;
    }
}

/// Serves one connection. Returns false when it was a subscription that the listening stream holds.
fn serve(self: *Script, reply: []const u8) bool {
    const fd_ = std.c.accept(self.listener, null, null);
    if (fd_ < 0) return true;
    var held = false;
    defer if (!held) {
        _ = std.c.close(fd_);
    };
    self.seen_len = 0;
    while (!self.requestIn()) {
        const read = std.c.recv(fd_, self.seen[self.seen_len..].ptr, self.seen.len - self.seen_len, 0);
        if (read <= 0) return true;
        self.seen_len += @intCast(read);
    }
    self.request_received.store(true, .release);
    _ = self.requests.fetchAdd(1, .acq_rel);
    if (self.listening) |listening| if (isSubscribe(self.seen[0..self.seen_len])) {
        held = listening.open(fd_, subscribeId(self.seen[0..self.seen_len]));
        return false;
    };
    if (self.hold_reply) {
        var byte: [1]u8 = undefined;
        const received = std.c.recv(fd_, &byte, byte.len, 0);
        self.connection_closed.store(received == 0, .release);
        return true;
    }
    _ = sendAll(fd_, reply);
    return true;
}

fn isSubscribe(seen: []const u8) bool {
    return std.mem.indexOf(u8, seen, "\r\nMcp-Method: subscriptions/listen\r\n") != null;
}

/// The JSON-RPC id of the request in `seen`, which the subscription is named by.
fn subscribeId(seen: []const u8) u64 {
    const key = "\"id\":";
    const at = (std.mem.indexOf(u8, seen, key) orelse return 0) + key.len;
    var end = at;
    while (end < seen.len and std.ascii.isDigit(seen[end])) end += 1;
    return std.fmt.parseInt(u64, seen[at..end], 10) catch 0;
}

fn sendAll(socket: std.posix.fd_t, bytes: []const u8) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const sent = std.c.send(socket, bytes[written..].ptr, bytes.len - written, 0);
        if (sent <= 0) return false;
        written += @intCast(sent);
    }
    return true;
}

/// Writes one whole chunk with a single send. The serve thread writes the acknowledgment while the test thread
/// pushes, so a chunk written in pieces could have another chunk land between its data and its closing CRLF.
fn sendChunk(socket: std.posix.fd_t, bytes: []const u8) bool {
    var chunk: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&chunk, "{x}\r\n{s}\r\n", .{ bytes.len, bytes }) catch unreachable;
    return sendAll(socket, text);
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
    // Also release a scripted future accept when an assertion aborts a test.
    // A connection wakes it on every kernel; shutdown of the listener wakes
    // it only on Linux, and Darwin's accept would block forever.
    self.stopping.store(true, .release);
    var address = std.Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable;
    address.setPort(self.port);
    if (address.connect(std.testing.io, .{ .mode = .stream })) |stream| stream.close(std.testing.io) else |_| {}
    if (self.thread) |thread| thread.join();
    if (self.listening) |listening| listening.close();
    _ = std.c.close(self.listener);
}

pub fn jsonReply(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) ++ body;
}
