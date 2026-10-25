//! One HTTP/2 connection: its socket and nghttp2 session. Internal.
//!
//!   free -> connecting -> awaiting_settings -> ready -> draining -> free
//!                         (preface and our     (streams  (GOAWAY seen:
//!                          SETTINGS sent)       submitted) no submits)
//!
//! "No request bytes before the launch handoff" and the zero-bytes evidence
//! both rest on one invariant: a stream is submitted only on a `ready`
//! connection, `ready` needs the peer's SETTINGS, and nghttp2 packs a
//! stream's HEADERS only after its submit. A connection that fails before
//! `ready` carried no request byte.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const h2 = @import("h2.zig");
const policy = @import("policy.zig");
const Record = @import("Stream.zig");
const Engine = @import("Engine.zig");
const Connection = @This();

pub const State = enum(u8) { free = 0, connecting, awaiting_settings, ready, draining };

engine: *Engine,
index: u32,
state: State,
origin: u8,
/// Set at the first submit, so that stream is the one that opened it.
carried_any: bool,
/// Inbound bytes arrived; the first ones tell an HTTP/1 answer apart.
received_any: bool,
/// This drive's read stopped at the allowance with bytes maybe unread.
read_capped: bool,
/// The session ended through a protocol error on either side.
protocol_failure: bool,
/// Index into the Engine's poll array for the current pass, 0 for none.
poll_slot: u32,
revents: i16,
socket: std.posix.fd_t,
session: ?*c.nghttp2_session,
serial: u64,
/// Streams submitted here that nghttp2 has not closed yet.
streams: u32,
/// The peer's SETTINGS_MAX_CONCURRENT_STREAMS.
peer_max_streams: u32,
/// From GOAWAY: streams above it were never processed.
goaway_last_stream_id: ?u32,
/// The stream whose close callback is running; a detach of it sends no
/// RST_STREAM, since it is already closing.
closing_stream_id: i32,
/// Bytes from the last mem_send not yet accepted by the socket. A view
/// into nghttp2's frame buffer, valid until the next mem_send.
unsent: []const u8,
setup_deadline_ns: u64,
last_inbound_ns: u64,
ping_sent_ns: ?u64,
/// When the connection last became empty; null while it carries streams.
idle_since_ns: ?u64,
/// The header block being decoded. HTTP/2 allows no other frame inside
/// HEADERS + CONTINUATION, so a connection has at most one. Fields point
/// into nghttp2 rcbufs held by `refs`, released at the end of the block.
head: Head,

pub const Head = struct {
    record: ?*Record = null,
    status: u16 = 0,
    bytes: usize = 0,
    fields: std.ArrayList(h2.Field) = .empty,
    refs: std.ArrayList(*c.nghttp2_rcbuf) = .empty,
};

pub fn free(engine: *Engine, index: u32) Connection {
    return .{
        .engine = engine,
        .index = index,
        .state = .free,
        .origin = 0,
        .carried_any = false,
        .received_any = false,
        .read_capped = false,
        .protocol_failure = false,
        .poll_slot = 0,
        .revents = 0,
        .socket = -1,
        .session = null,
        .serial = 0,
        .streams = 0,
        .peer_max_streams = 0,
        .goaway_last_stream_id = null,
        .closing_stream_id = 0,
        .unsent = &.{},
        .setup_deadline_ns = 0,
        .last_inbound_ns = 0,
        .ping_sent_ns = null,
        .idle_since_ns = null,
        .head = .{},
    };
}

pub fn hasSession(self: *const Connection) bool {
    return self.session != null;
}

pub fn hasRoom(self: *const Connection) bool {
    return self.state == .ready and self.streams < self.peer_max_streams;
}

pub fn view(self: *const Connection) policy.ConnectionView {
    return .{
        .ready = self.state == .ready or self.state == .draining,
        .draining = self.state == .draining,
        .streams = self.streams,
        .peer_max_streams = self.peer_max_streams,
    };
}

pub fn pollEvents(self: *const Connection) ?i16 {
    return switch (self.state) {
        .free => null,
        .connecting => std.c.POLL.OUT,
        .awaiting_settings, .ready, .draining => blk: {
            const write = self.unsent.len > 0 or c.nghttp2_session_want_write(self.session) != 0;
            break :blk if (write) std.c.POLL.IN | std.c.POLL.OUT else std.c.POLL.IN;
        },
    };
}

// ------------------------------------------------------------------ setup

/// free -> connecting. Only loopback literals reach here until TLS lands.
pub fn open(self: *Connection, origin_index: u8, serial: u64) void {
    std.debug.assert(self.state == .free);
    const engine = self.engine;
    const origin = &engine.origins[origin_index];
    self.origin = origin_index;
    self.serial = serial;
    self.state = .connecting;
    self.setup_deadline_ns = engine.now() +| engine.options.connect_timeout_ns;

    var storage: std.c.sockaddr.in6 = undefined;
    const family: c_uint, const length: std.c.socklen_t = if (std.mem.eql(u8, origin.host, "::1")) blk: {
        storage = std.mem.zeroes(std.c.sockaddr.in6);
        storage.family = std.c.AF.INET6;
        storage.port = std.mem.nativeToBig(u16, origin.port);
        storage.addr[15] = 1;
        break :blk .{ std.c.AF.INET6, @sizeOf(std.c.sockaddr.in6) };
    } else blk: {
        std.debug.assert(std.mem.eql(u8, origin.host, "127.0.0.1"));
        const v4: *std.c.sockaddr.in = @ptrCast(&storage);
        v4.* = std.mem.zeroes(std.c.sockaddr.in);
        v4.family = std.c.AF.INET;
        v4.port = std.mem.nativeToBig(u16, origin.port);
        v4.addr = std.mem.nativeToBig(u32, 0x7f00_0001);
        break :blk .{ std.c.AF.INET, @sizeOf(std.c.sockaddr.in) };
    };
    if (@hasField(std.c.sockaddr.in6, "len")) storage.len = @intCast(length);

    const fd = std.c.socket(family, std.c.SOCK.STREAM, 0);
    if (fd < 0) return engine.setupFailed(self, .local_failure);
    self.socket = fd;
    if (!configureSocket(fd)) return engine.setupFailed(self, .local_failure);
    while (true) {
        switch (std.posix.errno(std.c.connect(fd, @ptrCast(&storage), length))) {
            .SUCCESS => return self.startSession(),
            .INTR => continue,
            .INPROGRESS => return,
            else => return engine.setupFailed(self, .connect_failed),
        }
    }
}

fn configureSocket(fd: std.posix.fd_t) bool {
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

pub fn finishConnect(self: *Connection) void {
    var result: c_int = 0;
    var result_len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(self.socket, std.c.SOL.SOCKET, std.c.SO.ERROR, &result, &result_len) != 0 or result != 0)
        return self.engine.setupFailed(self, .connect_failed);
    self.startSession();
}

/// Our SETTINGS refuse push and grant each stream `stream_window_bytes`;
/// the connection window is set once the peer's stream limit is known.
fn startSession(self: *Connection) void {
    const engine = self.engine;
    var session: ?*c.nghttp2_session = null;
    if (c.nghttp2_session_client_new3(&session, engine.callbacks, self, engine.session_options, null) != 0)
        return engine.setupFailed(self, .local_failure);
    self.session = session;
    const settings = [_]c.nghttp2_settings_entry{
        .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_PUSH, .value = 0 },
        .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = h2.stream_window_bytes },
    };
    if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings, settings.len) != 0)
        return engine.setupFailed(self, .local_failure);
    self.state = .awaiting_settings;
    self.send();
}

fn becomeReady(self: *Connection) void {
    const engine = self.engine;
    const time = engine.now();
    self.state = .ready;
    self.idle_since_ns = time;
    self.last_inbound_ns = time;
    // Enough for every stream this connection may carry to have its full
    // window outstanding, so the connection never throttles one stream.
    const carried: u64 = @min(self.peer_max_streams, engine.options.stream_capacity);
    const window: i32 = @intCast(@min(@as(u64, h2.stream_window_bytes) * @max(carried, 1), std.math.maxInt(i32)));
    _ = c.nghttp2_session_set_local_window_size(self.session, c.NGHTTP2_FLAG_NONE, 0, window);
}

// ------------------------------------------------------------- streaming

/// Packs nothing yet: HEADERS are serialized by the next `send`. Returns
/// the stream id, or null when nghttp2 refused the submit.
pub fn submit(self: *Connection, record: *Record, origin: *const Engine.Origin, path: []const u8) ?i32 {
    std.debug.assert(self.hasRoom());
    var nva: [h2.max_fields + 5]c.nghttp2_nv = undefined;
    // Names and values outlive the HEADERS frame: the origin and path are
    // the endpoint's, the fields are the record's block, kept while a
    // resend is possible.
    const borrowed: u8 = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE;
    nva[0] = nv(":method", "POST", borrowed);
    nva[1] = nv(":scheme", switch (origin.scheme) {
        .http => "http",
        .https => "https",
    }, borrowed);
    nva[2] = nv(":authority", origin.authority, borrowed);
    nva[3] = nv(":path", path, borrowed);
    var length_text: [20]u8 = undefined;
    // nghttp2 copies this value at submit.
    nva[4] = nv("content-length", std.fmt.bufPrint(&length_text, "{d}", .{record.body_length}) catch unreachable, c.NGHTTP2_NV_FLAG_NO_COPY_NAME);
    var count: usize = 5;
    var entries = record.fieldEntries();
    while (entries.next()) |entry| : (count += 1) {
        nva[count] = nv(entry.name, entry.value, borrowed | if (entry.sensitive) @as(u8, c.NGHTTP2_NV_FLAG_NO_INDEX) else 0);
    }
    const provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = record }, .read_callback = readBody };
    const stream_id = c.nghttp2_submit_request2(
        self.session,
        null,
        &nva,
        count,
        if (record.body_length > 0) &provider else null,
        record,
    );
    return if (stream_id > 0) stream_id else null;
}

pub fn adopt(self: *Connection, record: *Record, stream_id: i32) void {
    record.route = .{ .open = .{ .stream_id = stream_id, .connection = self.index + 1 } };
    record.state = .open;
    if (!self.carried_any) record.flags.opened_connection = true;
    self.carried_any = true;
    self.streams += 1;
    self.idle_since_ns = null;
}

fn nv(name: []const u8, value: []const u8, flags: u8) c.nghttp2_nv {
    return .{
        .name = @constCast(name.ptr),
        .value = @constCast(value.ptr),
        .namelen = name.len,
        .valuelen = value.len,
        .flags = flags,
    };
}

/// Unhooks an open stream from nghttp2: any later frame for it is dropped
/// and its DATA returns connection credit only. RST_STREAM(CANCEL) goes
/// out with the next send unless the stream is already closing.
pub fn detach(self: *Connection, record: *Record) void {
    const stream_id = record.route.open.stream_id;
    if (stream_id != self.closing_stream_id) {
        _ = c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, stream_id, c.NGHTTP2_CANCEL);
    }
    _ = c.nghttp2_session_set_stream_user_data(self.session, stream_id, null);
    if (self.head.record == record) self.head.record = null;
}

/// A local cause ends an open stream now, and resets it.
pub fn endOpen(self: *Connection, record: *Record, cause: policy.Cause) void {
    self.detach(record);
    self.engine.endStream(record, cause);
}

/// Returns `bytes` of credit to the stream and the connection. For a stream
/// nghttp2 already closed, only the connection's.
pub fn consume(self: *Connection, stream_id: i32, bytes: usize) void {
    _ = c.nghttp2_session_consume(self.session, stream_id, bytes);
}

pub fn ping(self: *Connection, time: u64) void {
    if (c.nghttp2_submit_ping(self.session, c.NGHTTP2_FLAG_NONE, null) == 0) self.ping_sent_ns = time;
}

pub const ReadOutcome = enum { drained, capped, closed };

/// Reads and decodes until the socket would block or the allowance is
/// spent. Each read is flushed to the sinks before the next one reuses the
/// buffer.
pub fn receive(self: *Connection) ReadOutcome {
    const engine = self.engine;
    const buffer = &engine.scratch.read_buffer;
    var total: usize = 0;
    while (total < h2.read_allowance_bytes) {
        const read = std.c.recv(self.socket, buffer, buffer.len, 0);
        if (read < 0) switch (std.posix.errno(read)) {
            .AGAIN => return .drained,
            .INTR => continue,
            else => {
                self.fail(.connection_lost);
                return .closed;
            },
        };
        if (read == 0) {
            self.fail(.connection_lost);
            return .closed;
        }
        const bytes = buffer[0..@intCast(read)];
        self.last_inbound_ns = engine.now();
        self.ping_sent_ns = null;
        if (!self.received_any and self.state == .awaiting_settings) {
            self.received_any = true;
            // An HTTP/1 server answers the preface with a status line; an
            // HTTP/2 one starts with a SETTINGS frame, whose first byte is 0.
            if (std.mem.startsWith(u8, "HTTP/", bytes[0..@min(bytes.len, 5)])) {
                engine.setupFailed(self, .h2_refused);
                return .closed;
            }
        }
        const decoded = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
        engine.flush(self);
        if (decoded < 0) {
            self.protocol_failure = true;
            self.fail(.protocol_error);
            return .closed;
        }
        total += bytes.len;
    }
    return .capped;
}

/// Writes what nghttp2 has packed until it has nothing or the socket would
/// block. nghttp2 coalesces all pending frames into each buffer.
pub fn send(self: *Connection) void {
    while (true) {
        if (self.unsent.len == 0) {
            var data: [*c]const u8 = undefined;
            const packed_len = c.nghttp2_session_mem_send2(self.session, &data);
            if (packed_len < 0) return self.fail(.protocol_error);
            if (packed_len == 0) break;
            self.unsent = data[0..@intCast(packed_len)];
        }
        const sent = std.c.send(self.socket, self.unsent.ptr, self.unsent.len, if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
        if (sent < 0) switch (std.posix.errno(sent)) {
            .AGAIN => return,
            .INTR => continue,
            else => return self.fail(.connection_lost),
        };
        self.unsent = self.unsent[@intCast(sent)..];
    }
    // nghttp2 wants neither: the session ended (GOAWAY sent or received).
    if (c.nghttp2_session_want_read(self.session) == 0 and c.nghttp2_session_want_write(self.session) == 0)
        self.fail(if (self.protocol_failure) .protocol_error else .connection_lost);
}

fn fail(self: *Connection, cause: policy.Cause) void {
    switch (self.state) {
        .free => {},
        .connecting, .awaiting_settings => self.engine.setupFailed(self, if (cause == .connection_lost) .connect_failed else cause),
        .ready, .draining => self.lose(cause),
    }
}

/// The connection is gone and nghttp2 runs no more callbacks, so its open
/// streams are found in the timer list (a rare event; no list is kept per
/// connection) and each settled by policy.connectionLost.
pub fn lose(self: *Connection, cause: policy.Cause) void {
    const engine = self.engine;
    const effective = if (self.protocol_failure and cause == .connection_lost) .protocol_error else cause;
    var next = engine.timers.head;
    while (next) |record| {
        next = record.next;
        if (record.state != .open or record.route.open.connection != self.index + 1) continue;
        const stream_id: u32 = @intCast(record.route.open.stream_id);
        switch (policy.connectionLost(effective, stream_id, self.goaway_last_stream_id, record.facts())) {
            .end => |end| engine.endStream(record, end),
            .replay => engine.requeue(record, true),
            .reroute => engine.requeue(record, false),
        }
    }
    self.close(.abrupt);
}

/// `.goaway` first sends GOAWAY(NO_ERROR) without blocking; only for a
/// connection with no streams.
pub fn close(self: *Connection, mode: enum { goaway, abrupt }) void {
    if (self.session) |session| {
        if (mode == .goaway and (self.state == .ready or self.state == .draining)) {
            if (c.nghttp2_session_terminate_session(session, c.NGHTTP2_NO_ERROR) == 0) {
                var data: [*c]const u8 = undefined;
                if (self.unsent.len > 0) _ = std.c.send(self.socket, self.unsent.ptr, self.unsent.len, 0);
                const packed_len = c.nghttp2_session_mem_send2(session, &data);
                if (packed_len > 0) _ = std.c.send(self.socket, data, @intCast(packed_len), if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
            }
        }
        c.nghttp2_session_del(session);
    }
    if (self.socket >= 0) _ = std.c.close(self.socket);
    self.releaseHead();
    self.head.fields.deinit(self.engine.allocator);
    self.head.refs.deinit(self.engine.allocator);
    self.* = .free(self.engine, self.index);
}

fn releaseHead(self: *Connection) void {
    for (self.head.refs.items) |ref| c.nghttp2_rcbuf_decref(ref);
    self.head.refs.clearRetainingCapacity();
    self.head.fields.clearRetainingCapacity();
    self.head.record = null;
}

// ------------------------------------------------------- nghttp2 callbacks

pub fn setCallbacks(callbacks: *c.nghttp2_session_callbacks) void {
    c.nghttp2_session_callbacks_set_before_frame_send_callback(callbacks, beforeFrameSend);
    c.nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, onFrameSend);
    c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBeginHeaders);
    c.nghttp2_session_callbacks_set_on_header_callback2(callbacks, onHeader);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);
    c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onDataChunk);
    c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onStreamClose);
}

fn of(user_data: ?*anyopaque) *Connection {
    return @ptrCast(@alignCast(user_data.?));
}

fn recordOf(self: *Connection, stream_id: i32) ?*Record {
    return @ptrCast(@alignCast(c.nghttp2_session_get_stream_user_data(self.session, stream_id)));
}

/// The only place `request_sent` is set: the HEADERS are being packed, so
/// from here on "nothing was sent" can no longer be claimed.
fn beforeFrameSend(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
    const record = self.recordOf(frame.*.hd.stream_id) orelse return 0;
    record.flags.request_sent = true;
    return 0;
}

fn onFrameSend(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    switch (frame.*.hd.type) {
        c.NGHTTP2_HEADERS, c.NGHTTP2_DATA => {
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM == 0) return 0;
            const record = self.recordOf(frame.*.hd.stream_id) orelse return 0;
            record.flags.body_done = true;
            if (record.flags.response_started) self.engine.retireBody(record);
        },
        c.NGHTTP2_GOAWAY => if (frame.*.goaway.error_code != c.NGHTTP2_NO_ERROR) {
            self.protocol_failure = true;
        },
        else => {},
    }
    return 0;
}

/// The server's first response frame proves it processed the request, so
/// no resend can follow: the field block (credentials) goes now.
fn responseStarted(self: *Connection, record: *Record) void {
    if (record.flags.response_started) return;
    record.flags.response_started = true;
    record.releaseFields(self.engine.allocator);
    if (record.flags.body_done) self.engine.retireBody(record);
}

fn onBeginHeaders(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    self.releaseHead();
    if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
    const record = self.recordOf(frame.*.hd.stream_id) orelse return 0;
    self.responseStarted(record);
    self.head.record = record;
    self.head.status = 0;
    self.head.bytes = 0;
    return 0;
}

fn onHeader(
    _: ?*c.nghttp2_session,
    _: [*c]const c.nghttp2_frame,
    name_buffer: ?*c.nghttp2_rcbuf,
    value_buffer: ?*c.nghttp2_rcbuf,
    _: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const self = of(user_data);
    const record = self.head.record orelse return 0;
    const name = bytesOf(name_buffer.?);
    const value = bytesOf(value_buffer.?);
    if (std.mem.eql(u8, name, ":status")) {
        // nghttp2's messaging checks already require three digits.
        self.head.status = std.fmt.parseInt(u16, value, 10) catch 0;
        return 0;
    }
    if (name.len > 0 and name[0] == ':') return 0;
    self.head.bytes += name.len + value.len;
    const allocator = self.engine.allocator;
    if (self.head.bytes > h2.max_field_block_bytes) {
        self.releaseHead();
        self.endOpen(record, .rejected_headers);
        return 0;
    }
    self.head.fields.ensureUnusedCapacity(allocator, 1) catch return self.headFailed(record);
    self.head.refs.ensureUnusedCapacity(allocator, 2) catch return self.headFailed(record);
    c.nghttp2_rcbuf_incref(name_buffer);
    c.nghttp2_rcbuf_incref(value_buffer);
    self.head.refs.appendAssumeCapacity(name_buffer.?);
    self.head.refs.appendAssumeCapacity(value_buffer.?);
    self.head.fields.appendAssumeCapacity(.{ .name = name, .value = value });
    return 0;
}

fn headFailed(self: *Connection, record: *Record) c_int {
    self.releaseHead();
    self.endOpen(record, .local_failure);
    return 0;
}

fn bytesOf(buffer: *c.nghttp2_rcbuf) []const u8 {
    const vec = c.nghttp2_rcbuf_get_buf(buffer);
    return vec.base[0..vec.len];
}

fn onFrameRecv(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    switch (frame.*.hd.type) {
        c.NGHTTP2_SETTINGS => {
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_ACK != 0) return 0;
            self.peer_max_streams = c.nghttp2_session_get_remote_settings(self.session, c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS);
            self.engine.origins[self.origin].learned_max_streams = self.peer_max_streams;
            if (self.state == .awaiting_settings) self.becomeReady();
        },
        c.NGHTTP2_GOAWAY => {
            // nghttp2 closes the streams above `last_stream_id` as
            // REFUSED_STREAM; those at or below it run to their end.
            if (self.state == .ready) self.state = .draining;
            self.goaway_last_stream_id = @intCast(frame.*.goaway.last_stream_id);
            if (frame.*.goaway.error_code != c.NGHTTP2_NO_ERROR) self.protocol_failure = true;
        },
        c.NGHTTP2_HEADERS => {
            const record = self.recordOf(frame.*.hd.stream_id) orelse return 0;
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) record.flags.end_stream_seen = true;
            if (self.head.record == record) self.emitHead(record);
        },
        c.NGHTTP2_DATA => {
            const record = self.recordOf(frame.*.hd.stream_id) orelse return 0;
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) record.flags.end_stream_seen = true;
        },
        else => {},
    }
    return 0;
}

fn emitHead(self: *Connection, record: *Record) void {
    defer self.releaseHead();
    const status = self.head.status;
    const kind: @FieldType(h2.Head, "kind") = if (record.flags.final_seen)
        .trailers
    else if (status >= 100 and status < 200)
        .interim
    else
        .final;
    if (kind == .final) {
        record.status = status;
        record.flags.final_seen = true;
    }
    const verdict = self.engine.observe(record, .{ .head = .{
        .kind = kind,
        .status = if (kind == .trailers) 0 else status,
        .fields = self.head.fields.items,
    } });
    if (verdict == .refuse) self.endOpen(record, .rejected_headers);
}

fn onDataChunk(_: ?*c.nghttp2_session, _: u8, stream_id: i32, data: [*c]const u8, length: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    const record = self.recordOf(stream_id) orelse {
        self.consume(stream_id, length);
        return 0;
    };
    self.responseStarted(record);
    self.engine.gather(self, record, data[0..length]);
    return 0;
}

/// Closes fire inside both mem_recv and mem_send. The stream's last DATA
/// reaches its sink first, then policy.streamClosed settles it.
fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    const engine = self.engine;
    self.streams -= 1;
    if (self.streams == 0) self.idle_since_ns = engine.now();
    if (self.recordOf(stream_id) == null) return 0;
    self.closing_stream_id = stream_id;
    defer self.closing_stream_id = 0;
    engine.flush(self);
    const record = self.recordOf(stream_id) orelse return 0;
    _ = c.nghttp2_session_set_stream_user_data(self.session, stream_id, null);
    if (self.head.record == record) self.releaseHead();
    switch (policy.streamClosed(@fromBackingInt(@intCast(error_code)), record.facts())) {
        .end => |cause| engine.endStream(record, cause),
        .replay => engine.requeue(record, true),
        .reroute => engine.requeue(record, false),
    }
    return 0;
}

/// Reads the request body into nghttp2's frame buffer: from the caller's
/// bytes, or by positional read from the caller's file.
fn readBody(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    buffer: [*c]u8,
    length: usize,
    data_flags: [*c]u32,
    source: [*c]c.nghttp2_data_source,
    _: ?*anyopaque,
) callconv(.c) c.nghttp2_ssize {
    const record: *Record = @ptrCast(@alignCast(source.*.ptr.?));
    // A detached stream is about to be reset; send nothing more for it.
    if (c.nghttp2_session_get_stream_user_data(session, stream_id) != @as(?*anyopaque, record)) return c.NGHTTP2_ERR_DEFERRED;
    const wanted: usize = @intCast(@min(length, record.body_length - record.body_offset));
    if (record.flags.body_is_bytes) {
        const bytes: [*]const u8 = @ptrFromInt(record.body_source);
        @memcpy(buffer[0..wanted], bytes[@intCast(record.body_offset)..][0..wanted]);
    } else {
        var filled: usize = 0;
        while (filled < wanted) {
            const read = std.c.pread(@intCast(record.body_source), buffer + filled, wanted - filled, @intCast(record.body_offset + filled));
            if (read < 0 and std.posix.errno(read) == .INTR) continue;
            if (read <= 0) {
                // nghttp2 resets the stream; its close settles it with this cause.
                record.cause = .body_failed;
                return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            }
            filled += @intCast(read);
        }
    }
    record.body_offset += wanted;
    if (record.body_offset == record.body_length) data_flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
    return @intCast(wanted);
}
