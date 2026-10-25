//! An HTTP/2 server for the client's own tests: nghttp2's server session on
//! a loopback listener, h2c by prior knowledge. Single-threaded and
//! nonblocking: a test pumps it between client drives, so every exchange is
//! deterministic and nothing races.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const Peer = @This();

allocator: std.mem.Allocator,
options: Options,
listener: std.posix.fd_t,
port: u16,
callbacks: *c.nghttp2_session_callbacks,
session_options: *c.nghttp2_option,
connections: std.ArrayList(*Connection),
/// Every request stream in arrival order.
streams: std.ArrayList(*Stream),
seen: Seen,
url_buffer: [64]u8,
url_len: usize,

pub const Options = struct {
    max_concurrent_streams: u32 = 100,
    /// Answer the preface as an HTTP/1.1 server would.
    speak_http11: bool = false,
    /// Leave PINGs unanswered.
    ignore_ping: bool = false,
    /// Largest DATA payload the peer sends; 0 for nghttp2's default.
    data_chunk_bytes: usize = 0,
    /// Runs when a request has fully arrived; null answers 200 "ok".
    on_request: ?*const fn (*Peer, *Stream) void = null,
    context: ?*anyopaque = null,
};

pub const Seen = struct {
    connections: u32 = 0,
    rst_received: u32 = 0,
    pings_received: u32 = 0,
    /// The largest credit the client ever had open to the peer on one stream.
    max_stream_window: i32 = 0,
};

pub const Connection = struct {
    peer: *Peer,
    socket: std.posix.fd_t,
    session: ?*c.nghttp2_session,
    closed: bool,
    received_any: bool,
};

pub const Stream = struct {
    connection: *Connection,
    id: i32,
    index: u32,
    path: std.ArrayList(u8),
    authorization: std.ArrayList(u8),
    body: std.ArrayList(u8),
    complete: bool,
    closed: bool,
    close_code: u32,
    response: []const u8,
    response_offset: usize,
    trailers: bool,
    /// The response head went out; its body never will.
    withhold_body: bool,
};

pub fn start(allocator: std.mem.Allocator, options: Options) !*Peer {
    const self = try allocator.create(Peer);
    errdefer allocator.destroy(self);
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SystemResources;
    errdefer _ = std.c.close(fd);
    try nonblocking(fd);
    var address = std.mem.zeroes(std.c.sockaddr.in);
    address.family = std.c.AF.INET;
    address.addr = std.mem.nativeToBig(u32, 0x7f00_0001);
    if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 16) != 0) return error.ListenFailed;
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.BindFailed;

    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
    c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
    c.nghttp2_session_callbacks_set_on_header_callback2(callbacks, onHeader);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
    c.nghttp2_session_callbacks_set_data_source_read_length_callback2(callbacks, readLength);
    var session_options: ?*c.nghttp2_option = null;
    if (c.nghttp2_option_new(&session_options) != 0) return error.OutOfMemory;
    if (options.ignore_ping) c.nghttp2_option_set_no_auto_ping_ack(session_options, 1);

    self.* = .{
        .allocator = allocator,
        .options = options,
        .listener = fd,
        .port = std.mem.bigToNative(u16, address.port),
        .callbacks = callbacks.?,
        .session_options = session_options.?,
        .connections = .empty,
        .streams = .empty,
        .seen = .{},
        .url_buffer = undefined,
        .url_len = 0,
    };
    self.url_len = (try std.fmt.bufPrint(&self.url_buffer, "http://127.0.0.1:{d}/v1/responses", .{self.port})).len;
    return self;
}

pub fn url(self: *const Peer) []const u8 {
    return self.url_buffer[0..self.url_len];
}

pub fn stop(self: *Peer) void {
    for (self.connections.items) |connection| {
        self.closeConnection(connection);
        self.allocator.destroy(connection);
    }
    self.connections.deinit(self.allocator);
    for (self.streams.items) |stream| {
        stream.path.deinit(self.allocator);
        stream.authorization.deinit(self.allocator);
        stream.body.deinit(self.allocator);
        self.allocator.destroy(stream);
    }
    self.streams.deinit(self.allocator);
    c.nghttp2_option_del(self.session_options);
    c.nghttp2_session_callbacks_del(self.callbacks);
    _ = std.c.close(self.listener);
    self.allocator.destroy(self);
}

/// Accepts, reads, decodes and writes everything ready, without blocking.
pub fn pump(self: *Peer) !void {
    while (true) {
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) break;
        try nonblocking(fd);
        const connection = try self.allocator.create(Connection);
        connection.* = .{ .peer = self, .socket = fd, .session = null, .closed = false, .received_any = false };
        try self.connections.append(self.allocator, connection);
        self.seen.connections += 1;
        if (!self.options.speak_http11) {
            var session: ?*c.nghttp2_session = null;
            if (c.nghttp2_session_server_new3(&session, self.callbacks, connection, self.session_options, null) != 0) return error.OutOfMemory;
            connection.session = session;
            const settings = [_]c.nghttp2_settings_entry{
                .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = self.options.max_concurrent_streams },
            };
            _ = c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings, settings.len);
        }
    }
    for (self.connections.items) |connection| {
        if (connection.closed) continue;
        var buffer: [16 * 1024]u8 = undefined;
        while (!connection.closed) {
            const read = std.c.recv(connection.socket, &buffer, buffer.len, 0);
            if (read < 0) break;
            if (read == 0) {
                self.closeConnection(connection);
                break;
            }
            if (connection.session == null) {
                // An HTTP/1.1 server's answer to the HTTP/2 preface.
                const answer = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n";
                _ = std.c.send(connection.socket, answer, answer.len, 0);
                self.closeConnection(connection);
                break;
            }
            if (c.nghttp2_session_mem_recv2(connection.session, &buffer, @intCast(read)) < 0) {
                self.closeConnection(connection);
                break;
            }
        }
        if (!connection.closed and connection.session != null) self.flush(connection);
    }
}

fn flush(self: *Peer, connection: *Connection) void {
    while (true) {
        var data: [*c]const u8 = undefined;
        const length = c.nghttp2_session_mem_send2(connection.session, &data);
        if (length <= 0) break;
        // Loopback with small test payloads: a blocking-free full write.
        var sent: usize = 0;
        while (sent < length) {
            const result = std.c.send(connection.socket, data + sent, @as(usize, @intCast(length)) - sent, 0);
            if (result <= 0) {
                if (result < 0 and std.posix.errno(result) == .AGAIN) {
                    var poll = [_]std.c.pollfd{.{ .fd = connection.socket, .events = std.c.POLL.OUT, .revents = 0 }};
                    _ = std.c.poll(&poll, 1, 100);
                    continue;
                }
                return self.closeConnection(connection);
            }
            sent += @intCast(result);
        }
    }
    for (self.streams.items) |stream| {
        if (stream.connection != connection or stream.closed) continue;
        const window = c.nghttp2_session_get_stream_remote_window_size(connection.session, stream.id);
        self.seen.max_stream_window = @max(self.seen.max_stream_window, window);
    }
}

pub fn closeConnection(self: *Peer, connection: *Connection) void {
    _ = self;
    if (connection.closed) return;
    connection.closed = true;
    if (connection.session) |session| c.nghttp2_session_del(session);
    connection.session = null;
    _ = std.c.close(connection.socket);
}

// ------------------------------------------------------------------ actions

pub fn respond(self: *Peer, stream: *Stream, status: u16, body: []const u8) void {
    self.respondWith(stream, status, body, false);
}

/// Responds, then sends a trailer block after the body.
pub fn respondWith(self: *Peer, stream: *Stream, status: u16, body: []const u8, trailers: bool) void {
    _ = self;
    var status_text: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&status_text, "{d}", .{status}) catch unreachable;
    const headers = [_]c.nghttp2_nv{
        nv(":status", &status_text),
        nv("content-type", "text/event-stream"),
    };
    stream.response = body;
    stream.response_offset = 0;
    stream.trailers = trailers;
    const provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = stream }, .read_callback = readResponse };
    _ = c.nghttp2_submit_response2(stream.connection.session, stream.id, &headers, headers.len, if (body.len > 0 or trailers) &provider else null);
}

/// Sends the response head and then nothing more on the stream.
pub fn respondHeadOnly(self: *Peer, stream: *Stream, status: u16) void {
    stream.withhold_body = true;
    self.respondWith(stream, status, "", true);
}

pub fn reset(self: *Peer, stream: *Stream, code: u32) void {
    _ = self;
    _ = c.nghttp2_submit_rst_stream(stream.connection.session, c.NGHTTP2_FLAG_NONE, stream.id, code);
}

pub fn goaway(self: *Peer, connection: *Connection, last_stream_id: i32, code: u32) void {
    _ = self;
    _ = c.nghttp2_submit_goaway(connection.session, c.NGHTTP2_FLAG_NONE, last_stream_id, code, null, 0);
}

fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{ .name = @constCast(name.ptr), .value = @constCast(value.ptr), .namelen = name.len, .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
}

fn nonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
}

// ------------------------------------------------------------------ callbacks

fn connectionOf(user_data: ?*anyopaque) *Connection {
    return @ptrCast(@alignCast(user_data.?));
}

fn streamOf(session: ?*c.nghttp2_session, stream_id: i32) ?*Stream {
    return @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(session, stream_id)));
}

fn onBeginHeaders(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    if (frame.*.hd.type != c.NGHTTP2_HEADERS or frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const connection = connectionOf(user_data);
    const peer = connection.peer;
    const stream = peer.allocator.create(Stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    stream.* = .{
        .connection = connection,
        .id = frame.*.hd.stream_id,
        .index = @intCast(peer.streams.items.len),
        .path = .empty,
        .authorization = .empty,
        .body = .empty,
        .complete = false,
        .closed = false,
        .close_code = 0,
        .response = &.{},
        .response_offset = 0,
        .trailers = false,
        .withhold_body = false,
    };
    peer.streams.append(peer.allocator, stream) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    _ = c.nghttp2_session_set_stream_user_data(session, stream.id, stream);
    return 0;
}

fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: ?*c.nghttp2_rcbuf, value: ?*c.nghttp2_rcbuf, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, frame.*.hd.stream_id) orelse return 0;
    const allocator = connectionOf(user_data).peer.allocator;
    const name_vec = c.nghttp2_rcbuf_get_buf(name);
    const value_vec = c.nghttp2_rcbuf_get_buf(value);
    const field = name_vec.base[0..name_vec.len];
    const target = if (std.mem.eql(u8, field, ":path")) &stream.path else if (std.mem.eql(u8, field, "authorization")) &stream.authorization else return 0;
    target.appendSlice(allocator, value_vec.base[0..value_vec.len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onDataChunk(session: ?*c.nghttp2_session, _: u8, stream_id: i32, data: [*c]const u8, length: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, stream_id) orelse return 0;
    stream.body.appendSlice(connectionOf(user_data).peer.allocator, data[0..length]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    return 0;
}

fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const peer = connectionOf(user_data).peer;
    switch (frame.*.hd.type) {
        c.NGHTTP2_RST_STREAM => peer.seen.rst_received += 1,
        c.NGHTTP2_PING => if (frame.*.hd.flags & c.NGHTTP2_FLAG_ACK == 0) {
            peer.seen.pings_received += 1;
        },
        c.NGHTTP2_HEADERS, c.NGHTTP2_DATA => if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
            const stream = streamOf(session, frame.*.hd.stream_id) orelse return 0;
            stream.complete = true;
            if (peer.options.on_request) |handler| handler(peer, stream) else peer.respond(stream, 200, "ok");
        },
        else => {},
    }
    return 0;
}

fn onStreamClose(session: ?*c.nghttp2_session, stream_id: i32, code: u32, _: ?*anyopaque) callconv(.c) c_int {
    const stream = streamOf(session, stream_id) orelse return 0;
    stream.closed = true;
    stream.close_code = code;
    return 0;
}

fn readLength(_: ?*c.nghttp2_session, _: u8, _: i32, _: i32, _: i32, max_payload: u32, user_data: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
    const chunk = connectionOf(user_data).peer.options.data_chunk_bytes;
    return @intCast(if (chunk == 0) max_payload else @min(chunk, max_payload));
}

fn readResponse(session: ?*c.nghttp2_session, _: i32, buffer: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
    const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
    if (stream.withhold_body) return c.NGHTTP2_ERR_DEFERRED;
    const count = @min(length, stream.response.len - stream.response_offset);
    @memcpy(buffer[0..count], stream.response[stream.response_offset..][0..count]);
    stream.response_offset += count;
    if (stream.response_offset == stream.response.len) {
        flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        if (stream.trailers) {
            flags.* |= c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
            const trailer = [_]c.nghttp2_nv{nv("x-trailer", "done")};
            _ = c.nghttp2_submit_trailer(session, stream.id, &trailer, trailer.len);
        }
    }
    return @intCast(count);
}
