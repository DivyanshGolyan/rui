const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const openssl = @import("tls_client").c;
const h2 = @import("h2.zig");
const policy = @import("policy.zig");
const dial_policy = @import("dial_policy.zig");
const Record = @import("Stream.zig");
const Engine = @import("Engine.zig");
const Origin = @import("Origin.zig");
const Resolver = @import("Resolver.zig");
const tls = @import("tls.zig");
const proxy = @import("proxy.zig");
const sec_trust = @import("sec_trust.zig");
const socket_os = @import("os").socket;
const Clock = @import("Clock.zig");
const Faults = @import("testing/Faults.zig");
const Waker = @import("os").Waker;
const Connection = @This();

pub const State = enum(u8) { free = 0, resolving, connecting, tunneling, handshaking, verifying, awaiting_settings, ready, draining };

pub const Scratch = struct {
    pub const max_chunks = 256;
    read_buffer: [h2.read_buffer_bytes]u8,
    chunks: [max_chunks]Chunk,
    chunk_count: u16,
    iovecs: [max_chunks]std.posix.iovec_const,

    pub const Chunk = struct { record: ?*Record, bytes: []const u8 };
};

pub const Streams = struct {
    context: *anyopaque,
    head: *const fn (context: *anyopaque, record: *Record, head: h2.Head) h2.Verdict,
    deliver: *const fn (context: *anyopaque, record: *Record, iovecs: []std.posix.iovec_const, total: usize) ?policy.Cause,
    retireBody: *const fn (context: *anyopaque, record: *Record) void,
    settle: *const fn (context: *anyopaque, record: *Record, settle: policy.Settle) void,
};

pub const Env = struct {
    allocator: std.mem.Allocator,
    clock: *const Clock,
    waker: *Waker,
    callbacks: *c.nghttp2_session_callbacks,
    session_options: *c.nghttp2_option,
    scratch: *Scratch,
    tls: *?tls.Context,
    connect_timeout_ns: u64,
    stream_capacity: u32,
    streams: Streams,
    faults: if (builtin.is_test) ?*Faults else void = if (builtin.is_test) null else {},
};

engine: *Engine,
env: *const Env,
index: u32,
state: State,
origin: u8,
origin_state: *Origin = undefined,
carried_any: bool,
received_any: bool,
read_capped: bool,
protocol_failure: bool,
local_failure: bool,
poll_slot: u32,
revents: i16,
socket: std.posix.fd_t,
earlier: std.posix.fd_t,
earlier_revents: i16,
next_attempt_ns: u64,
tunnel_sent: u16,
tunnel_request_len: u16,
tunnel_answer: proxy.Answer,
ssl: ?*openssl.SSL,
uses_lookup: bool,
address_index: u8,
tls_wants_write: bool,
verification: if (sec_trust.enabled) ?*sec_trust.Job else void,
session: ?*c.nghttp2_session,
serial: u64,
streams: u32,
peer_max_streams: u32,
goaway_last_stream_id: ?u32,
closing_stream_id: i32,
/// Bytes from the last mem_send not yet accepted by the socket. A view
/// into nghttp2's frame buffer, valid until the next mem_send.
unsent: []const u8,
setup_deadline_ns: u64,
last_inbound_ns: u64,
ping_sent_ns: ?u64,
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

pub fn vacant(engine: *Engine, env: *const Env, index: u32) Connection {
    return .{
        .engine = engine,
        .env = env,
        .index = index,
        .state = .free,
        .origin = 0,
        .carried_any = false,
        .received_any = false,
        .read_capped = false,
        .protocol_failure = false,
        .local_failure = false,
        .poll_slot = 0,
        .revents = 0,
        .socket = -1,
        .earlier = -1,
        .earlier_revents = 0,
        .next_attempt_ns = 0,
        .tunnel_sent = 0,
        .tunnel_request_len = 0,
        .tunnel_answer = .{},
        .ssl = null,
        .uses_lookup = false,
        .address_index = 0,
        .tls_wants_write = false,
        .verification = if (sec_trust.enabled) null else {},
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

pub fn settingUp(self: *const Connection) bool {
    return switch (self.state) {
        .resolving, .connecting, .tunneling, .handshaking, .verifying, .awaiting_settings => true,
        .free, .ready, .draining => false,
    };
}

/// OpenSSL holds decrypted bytes not yet read, which poll cannot see. A
/// partial record does not count: it waits for the socket like any read.
pub fn tlsPending(self: *const Connection) bool {
    const ssl = self.ssl orelse return false;
    return self.session != null and openssl.SSL_pending(ssl) > 0;
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
        .free, .resolving, .verifying => null,
        .connecting => std.c.POLL.OUT,
        .tunneling => if (self.tunnel_sent < self.tunnel_request_len) std.c.POLL.OUT else std.c.POLL.IN,
        .handshaking => if (self.tls_wants_write) std.c.POLL.OUT else std.c.POLL.IN,
        .awaiting_settings, .ready, .draining => blk: {
            const write = self.tls_wants_write or self.unsent.len > 0 or c.nghttp2_session_want_write(self.session) != 0;
            break :blk if (write) std.c.POLL.IN | std.c.POLL.OUT else std.c.POLL.IN;
        },
    };
}

pub fn open(self: *Connection, origin: *Origin, origin_index: u8, serial: u64) void {
    std.debug.assert(self.state == .free);
    const engine = self.engine;
    self.origin = origin_index;
    self.origin_state = origin;
    self.serial = serial;
    self.setup_deadline_ns = self.env.clock.now() +| self.env.connect_timeout_ns;
    if (origin.target.literal != null) return self.advanceAttempts(false, self.env.clock.now());
    self.state = .resolving;
    if (!origin.lookup.acquire(self.env.waker, origin.target)) return engine.setupFailed(self, .local_failure);
    self.uses_lookup = true;
}

pub fn finishLookup(self: *Connection) void {
    const lookup = self.origin_state.lookup.result() orelse return;
    if (lookup.found().len == 0) return self.engine.setupFailed(self, .resolve_failed);
    self.advanceAttempts(false, self.env.clock.now());
}

fn stopUsingLookup(self: *Connection) void {
    if (!self.uses_lookup) return;
    self.uses_lookup = false;
    self.origin_state.lookup.release();
}

pub fn advanceConnect(self: *Connection, time: u64) void {
    var failed = false;
    if (self.earlier >= 0 and self.earlier_revents != 0) {
        if (connectSucceeded(self.earlier)) {
            std.mem.swap(std.posix.fd_t, &self.socket, &self.earlier);
            return self.connected();
        }
        self.dropEarlier();
        failed = true;
    }
    if (self.revents != 0) {
        if (connectSucceeded(self.socket)) return self.connected();
        self.dropNewest();
        failed = true;
    }
    self.advanceAttempts(failed, time);
}

pub fn earlierAttempt(self: *const Connection) ?std.posix.fd_t {
    return if (self.state == .connecting and self.earlier >= 0) self.earlier else null;
}

pub fn setupDeadline(self: *const Connection) u64 {
    if (self.next_attempt_ns == 0) return self.setup_deadline_ns;
    return @min(self.next_attempt_ns, self.setup_deadline_ns);
}

fn advanceAttempts(self: *Connection, failed: bool, time: u64) void {
    self.state = .connecting;
    var failure = failed;
    while (true) {
        switch (dial_policy.nextAttempt(.{
            .in_flight = @as(u8, @intFromBool(self.socket >= 0)) + @intFromBool(self.earlier >= 0),
            .more_addresses = self.origin_state.address(self.address_index) != null,
            .failed = failure,
            .delay_passed = self.next_attempt_ns != 0 and time >= self.next_attempt_ns,
        })) {
            .wait => return,
            .fail => return self.engine.setupFailed(self, .connect_failed),
            .replace_oldest => self.dropEarlier(),
            .start => {},
        }
        switch (self.attempt(time)) {
            .connected => return self.connected(),
            .in_flight => return,
            .refused => failure = true,
            .local_failure => return self.engine.setupFailed(self, .local_failure),
        }
    }
}

fn attempt(self: *Connection, time: u64) enum { connected, in_flight, refused, local_failure } {
    std.debug.assert(self.earlier < 0);
    const address = self.origin_state.address(self.address_index).?;
    self.address_index += 1;
    self.next_attempt_ns = if (self.origin_state.address(self.address_index) != null) time +| dial_policy.attempt_delay_ns else 0;
    const fd = std.c.socket(address.family, std.c.SOCK.STREAM, 0);
    if (fd < 0) return .local_failure;
    self.earlier = self.socket;
    self.socket = fd;
    if (!socket_os.configure(fd, true)) return .local_failure;
    while (true) {
        switch (std.posix.errno(std.c.connect(fd, @ptrCast(&address.storage), address.length))) {
            .SUCCESS => return .connected,
            .INTR => continue,
            .INPROGRESS => return .in_flight,
            else => {
                self.dropNewest();
                return .refused;
            },
        }
    }
}

fn dropEarlier(self: *Connection) void {
    if (self.earlier >= 0) closeSocket(self.earlier);
    self.earlier = -1;
}

fn dropNewest(self: *Connection) void {
    closeSocket(self.socket);
    self.socket = self.earlier;
    self.earlier = -1;
}

fn connectSucceeded(fd: std.posix.fd_t) bool {
    var result: c_int = 0;
    var result_len: std.c.socklen_t = @sizeOf(c_int);
    return std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &result, &result_len) == 0 and result == 0;
}

fn closeSocket(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn connected(self: *Connection) void {
    self.dropEarlier();
    self.next_attempt_ns = 0;
    self.stopUsingLookup();
    const origin = self.origin_state;
    if (origin.scheme == .http) return self.startSession();
    if (origin.via != null) return self.startTunnel();
    self.startTls();
}

fn startTunnel(self: *Connection) void {
    var request: [proxy.max_request_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &request);
    self.tunnel_request_len = @intCast(self.tunnelRequest(&request).len);
    self.tunnel_sent = 0;
    self.tunnel_answer = .{};
    self.state = .tunneling;
    self.continueTunnel();
}

fn tunnelRequest(self: *const Connection, buffer: *[proxy.max_request_bytes]u8) []const u8 {
    const origin = self.origin_state;
    return proxy.connectRequest(buffer, origin.host, origin.port, origin.via.?.credentials);
}

pub fn continueTunnel(self: *Connection) void {
    if (self.tunnel_sent < self.tunnel_request_len) {
        var request: [proxy.max_request_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &request);
        switch (self.writeSome(self.tunnelRequest(&request)[self.tunnel_sent..])) {
            .bytes => |count| self.tunnel_sent += @intCast(count),
            .again => return,
            .closed => return self.engine.setupFailed(self, .proxy_failed),
        }
        if (self.tunnel_sent < self.tunnel_request_len) return;
    }
    var buffer: [512]u8 = undefined;
    while (true) {
        const count = switch (self.readSome(&buffer)) {
            .bytes => |count| count,
            .again => return,
            .closed => return self.engine.setupFailed(self, .proxy_failed),
        };
        switch (self.tunnel_answer.feed(buffer[0..count])) {
            .more => {},
            .malformed => return self.engine.setupFailed(self, .proxy_failed),
            .done => |answer| {
                if (dial_policy.tunnelRefusal(answer.status)) |cause| return self.engine.setupFailed(self, cause);
                if (answer.used != count) return self.engine.setupFailed(self, .proxy_failed);
                return self.startTls();
            },
        }
    }
}

fn startTls(self: *Connection) void {
    const origin = self.origin_state;
    const context = &self.env.tls.*.?;
    self.ssl = context.newSession(self.socket, origin.server_name, if (origin.literal != null) .ip_literal else .dns_name) orelse
        return self.engine.setupFailed(self, .local_failure);
    self.state = .handshaking;
    self.continueHandshake();
}

pub fn continueHandshake(self: *Connection) void {
    switch (tls.handshake(self.ssl.?)) {
        .done => {
            self.tls_wants_write = false;
            if (sec_trust.enabled and self.env.tls.*.?.deferred) return self.startVerification();
            self.startTrustedSession();
        },
        .want_read => self.tls_wants_write = false,
        .want_write => self.tls_wants_write = true,
        .failed => |cause| self.engine.setupFailed(self, cause),
    }
}

fn startVerification(self: *Connection) void {
    std.debug.assert(self.verification == null);
    const server_name = self.origin_state.server_name;
    self.verification = sec_trust.Verification.start(self.env.waker, self.ssl.?, server_name) orelse
        return self.engine.setupFailed(self, .local_failure);
    self.state = .verifying;
}

pub fn finishVerification(self: *Connection) void {
    if (!sec_trust.enabled) unreachable else {
        const verdict = (self.verification.?.result() orelse return).verdict;
        self.releaseVerification();
        switch (verdict) {
            .trusted => self.startTrustedSession(),
            .untrusted => self.engine.setupFailed(self, .untrusted_peer),
            .failed => self.engine.setupFailed(self, .local_failure),
        }
    }
}

fn startTrustedSession(self: *Connection) void {
    if (!tls.choseH2(self.ssl.?)) return self.engine.setupFailed(self, .h2_refused);
    self.startSession();
}

/// Our SETTINGS refuse push, grant each stream `stream_window_bytes` and
/// advertise a header list limit of `max_field_block_bytes`. RFC 9113
/// counts 32 bytes more per field than `onHeader`'s check, so a peer that
/// keeps to it never trips that check. The
/// connection window is set once the peer's stream limit is known.
fn startSession(self: *Connection) void {
    const engine = self.engine;
    var session: ?*c.nghttp2_session = null;
    if (c.nghttp2_session_client_new3(&session, self.env.callbacks, self, self.env.session_options, null) != 0)
        return engine.setupFailed(self, .local_failure);
    self.session = session;
    const settings = [_]c.nghttp2_settings_entry{
        .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_PUSH, .value = 0 },
        .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = h2.stream_window_bytes },
        .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = h2.max_field_block_bytes },
    };
    if (c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &settings, settings.len) != 0)
        return engine.setupFailed(self, .local_failure);
    self.state = .awaiting_settings;
    self.send();
}

fn becomeReady(self: *Connection) void {
    const time = self.env.clock.now();
    self.state = .ready;
    self.idle_since_ns = time;
    self.last_inbound_ns = time;
}

fn sizeWindow(self: *Connection) void {
    const carried: u64 = @min(self.peer_max_streams, self.env.stream_capacity);
    const window: i32 = @intCast(@min(@as(u64, h2.stream_window_bytes) * @max(carried, 1), std.math.maxInt(i32)));
    self.check(c.nghttp2_session_set_local_window_size(self.session, c.NGHTTP2_FLAG_NONE, 0, window));
}

pub fn submit(self: *Connection, record: *Record, origin: *const Origin, path: []const u8) ?i32 {
    std.debug.assert(self.hasRoom());
    var nva: [h2.max_fields + 6]c.nghttp2_nv = undefined;
    const borrowed: u8 = c.NGHTTP2_NV_FLAG_NO_COPY_NAME | c.NGHTTP2_NV_FLAG_NO_COPY_VALUE;
    nva[0] = nv(":method", if (record.flags.get) "GET" else "POST", borrowed);
    nva[1] = nv(":scheme", switch (origin.scheme) {
        .http => "http",
        .https => "https",
    }, borrowed);
    nva[2] = nv(":authority", origin.authority, borrowed);
    nva[3] = nv(":path", path, borrowed);
    var count: usize = 4;
    var length_text: [20]u8 = undefined;
    // A GET has no content, so it sends no length (RFC 9110 8.6). nghttp2
    // copies this value at submit.
    if (!record.flags.get) {
        nva[count] = nv("content-length", std.fmt.bufPrint(&length_text, "{d}", .{record.body_length}) catch unreachable, c.NGHTTP2_NV_FLAG_NO_COPY_NAME);
        count += 1;
    }
    // No content coding is decoded here, so none is accepted (RFC 9110
    // 12.5.3: a request without accept-encoding accepts any).
    nva[count] = nv("accept-encoding", "identity", borrowed);
    count += 1;
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

pub fn detach(self: *Connection, record: *Record) void {
    const stream_id = record.route.open.stream_id;
    if (stream_id != self.closing_stream_id) {
        self.check(c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, stream_id, c.NGHTTP2_CANCEL));
    }
    _ = c.nghttp2_session_set_stream_user_data(self.session, stream_id, null);
    if (self.head.record == record) self.head.record = null;
}

pub fn endOpen(self: *Connection, record: *Record, cause: policy.Cause) void {
    self.detach(record);
    self.settle(record, .{ .end = cause });
}

fn settle(self: *Connection, record: *Record, outcome: policy.Settle) void {
    const port = self.env.streams;
    port.settle(port.context, record, outcome);
}

pub fn consume(self: *Connection, stream_id: i32, bytes: usize) void {
    self.check(c.nghttp2_session_consume(self.session, stream_id, bytes));
}

pub fn consumeConnection(self: *Connection, bytes: usize) void {
    self.check(c.nghttp2_session_consume_connection(self.session, bytes));
}

fn flush(self: *Connection, only: ?*Record) void {
    const scratch = self.env.scratch;
    defer if (only == null) {
        scratch.chunk_count = 0;
    };
    const chunks = scratch.chunks[0..scratch.chunk_count];
    for (chunks, 0..) |*first, start| {
        const record = first.record orelse continue;
        if (only != null and only != record) continue;
        var total: usize = 0;
        var iovec_count: usize = 0;
        for (chunks[start..]) |*chunk| {
            if (chunk.record != record) continue;
            scratch.iovecs[iovec_count] = .{ .base = chunk.bytes.ptr, .len = chunk.bytes.len };
            iovec_count += 1;
            total += chunk.bytes.len;
            chunk.record = null;
        }
        const stream_id = record.route.open.stream_id;
        if (record.state != .open) {
            self.consume(stream_id, total);
            continue;
        }
        const streams_port = self.env.streams;
        if (streams_port.deliver(streams_port.context, record, scratch.iovecs[0..iovec_count], total)) |cause| {
            self.consumeConnection(total);
            self.endOpen(record, cause);
            continue;
        }
        self.consume(stream_id, total);
    }
}

fn gather(self: *Connection, record: *Record, bytes: []const u8) void {
    const scratch = self.env.scratch;
    if (scratch.chunk_count == Scratch.max_chunks) self.flush(null);
    scratch.chunks[scratch.chunk_count] = .{ .record = record, .bytes = bytes };
    scratch.chunk_count += 1;
}

fn check(self: *Connection, result: c_int) void {
    if (result != 0) self.local_failure = true;
}

pub fn ping(self: *Connection, time: u64) void {
    if (c.nghttp2_submit_ping(self.session, c.NGHTTP2_FLAG_NONE, null) == 0) self.ping_sent_ns = time;
}

pub const ReadOutcome = enum { drained, capped, closed };

pub fn receive(self: *Connection) ReadOutcome {
    const engine = self.engine;
    const buffer = &self.env.scratch.read_buffer;
    var total: usize = 0;
    self.tls_wants_write = false;
    while (total < h2.read_allowance_bytes) {
        const bytes = switch (self.readSome(buffer)) {
            .bytes => |count| buffer[0..count],
            .again => return .drained,
            .closed => {
                self.fail(.connection_lost);
                return .closed;
            },
        };
        self.last_inbound_ns = self.env.clock.now();
        self.ping_sent_ns = null;
        if (!self.received_any and self.state == .awaiting_settings and self.ssl == null) {
            self.received_any = true;
            // An HTTP/1 server answers the preface with a status line; an
            // HTTP/2 one starts with a SETTINGS frame, whose first byte is 0.
            if (std.mem.startsWith(u8, "HTTP/", bytes[0..@min(bytes.len, 5)])) {
                engine.setupFailed(self, .h2_refused);
                return .closed;
            }
        }
        const decoded = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
        self.flush(null);
        if (decoded < 0) {
            self.protocol_failure = true;
            self.fail(.protocol_error);
            return .closed;
        }
        if (self.local_failure) {
            self.fail(.local_failure);
            return .closed;
        }
        total += bytes.len;
    }
    return .capped;
}

pub fn send(self: *Connection) void {
    if (self.local_failure) return self.fail(.local_failure);
    while (true) {
        if (self.unsent.len == 0) {
            var data: [*c]const u8 = undefined;
            const packed_len = c.nghttp2_session_mem_send2(self.session, &data);
            if (packed_len < 0) return self.fail(.protocol_error);
            if (packed_len == 0) break;
            self.unsent = data[0..@intCast(packed_len)];
        }
        switch (self.writeSome(self.unsent)) {
            .bytes => |count| self.unsent = self.unsent[count..],
            .again => return,
            .closed => return self.fail(.connection_lost),
        }
    }
    if (c.nghttp2_session_want_read(self.session) == 0 and c.nghttp2_session_want_write(self.session) == 0)
        self.fail(if (self.protocol_failure) .protocol_error else .connection_lost);
}

const Transfer = union(enum) { bytes: usize, again, closed };

fn readSome(self: *Connection, buffer: []u8) Transfer {
    if (!builtin.is_test) return self.readSocket(buffer);
    return self.withFaults(.read, buffer, readSocket);
}

fn writeSome(self: *Connection, bytes: []const u8) Transfer {
    if (!builtin.is_test) return self.writeSocket(bytes);
    return self.withFaults(.write, bytes, writeSocket);
}

fn withFaults(self: *Connection, comptime direction: Faults.Direction, bytes: anytype, transfer: fn (*Connection, @TypeOf(bytes)) Transfer) Transfer {
    const faults = self.env.faults orelse return transfer(self, bytes);
    const allowed = switch (faults.admit(self.serial, direction, bytes.len, self.ssl != null)) {
        .pass => |count| count,
        .again => return .again,
        .closed => return .closed,
    };
    const result = transfer(self, bytes[0..allowed]);
    if (result == .bytes) faults.moved(self.serial, direction, result.bytes);
    return result;
}

fn readSocket(self: *Connection, buffer: []u8) Transfer {
    if (self.ssl) |ssl| return switch (tls.read(ssl, buffer)) {
        .bytes => |count| .{ .bytes = count },
        .want_read => .again,
        .want_write => blk: {
            self.tls_wants_write = true;
            break :blk .again;
        },
        .closed => .closed,
    };
    while (true) {
        const read = std.c.recv(self.socket, buffer.ptr, buffer.len, 0);
        if (read > 0) return .{ .bytes = @intCast(read) };
        if (read == 0) return .closed;
        switch (std.posix.errno(read)) {
            .AGAIN => return .again,
            .INTR => continue,
            else => return .closed,
        }
    }
}

fn writeSocket(self: *Connection, bytes: []const u8) Transfer {
    if (self.ssl) |ssl| return switch (tls.write(ssl, bytes)) {
        .bytes => |count| .{ .bytes = count },
        .want_read, .want_write => .again,
        .closed => .closed,
    };
    while (true) {
        const sent = std.c.send(self.socket, bytes.ptr, bytes.len, socket_os.send_flags);
        if (sent >= 0) return .{ .bytes = @intCast(sent) };
        switch (std.posix.errno(sent)) {
            .AGAIN => return .again,
            .INTR => continue,
            else => return .closed,
        }
    }
}

fn fail(self: *Connection, cause: policy.Cause) void {
    switch (self.state) {
        .free => {},
        .ready, .draining => self.lose(cause),
        else => self.engine.setupFailed(self, if (cause == .connection_lost) .connect_failed else cause),
    }
}

pub fn lose(self: *Connection, cause: policy.Cause) void {
    const engine = self.engine;
    const effective = if (self.protocol_failure and cause == .connection_lost) .protocol_error else cause;
    var next = engine.timers.head;
    while (next) |record| {
        next = record.next;
        if (record.state != .open or record.route.open.connection != self.index + 1) continue;
        const stream_id: u32 = @intCast(record.route.open.stream_id);
        self.settle(record, policy.connectionLost(effective, stream_id, self.goaway_last_stream_id, record.facts()));
    }
    self.close(.abrupt);
}

pub fn close(self: *Connection, mode: enum { goaway, abrupt }) void {
    if (self.session) |session| {
        if (mode == .goaway and (self.state == .ready or self.state == .draining)) {
            // GOAWAY may only follow whole frames, and a blocked TLS write
            // must be retried with the same bytes, so a connection with
            // bytes still unsent just closes.
            if (self.unsent.len == 0 and c.nghttp2_session_terminate_session(session, c.NGHTTP2_NO_ERROR) == 0) {
                var data: [*c]const u8 = undefined;
                const packed_len = c.nghttp2_session_mem_send2(session, &data);
                const goaway_sent = packed_len > 0 and switch (self.writeSome(data[0..@intCast(packed_len)])) {
                    .bytes => |count| count == packed_len,
                    .again, .closed => false,
                };
                if (goaway_sent) if (self.ssl) |ssl| {
                    _ = openssl.SSL_shutdown(ssl);
                };
            }
        }
        c.nghttp2_session_del(session);
    }
    if (self.ssl) |ssl| openssl.SSL_free(ssl);
    self.stopUsingLookup();
    if (self.socket >= 0) closeSocket(self.socket);
    self.dropEarlier();
    self.releaseHead();
    self.head.fields.deinit(self.env.allocator);
    self.head.refs.deinit(self.env.allocator);
    const verification = self.verification;
    self.* = .vacant(self.engine, self.env, self.index);
    self.verification = verification;
}

pub fn available(self: *Connection) bool {
    if (self.state != .free) return false;
    if (sec_trust.enabled) if (self.verification) |verification| {
        if (verification.result() == null) return false;
        self.releaseVerification();
    };
    return true;
}

pub fn releaseVerification(self: *Connection) void {
    if (!sec_trust.enabled) return;
    if (self.verification) |verification| verification.release();
    self.verification = null;
}

fn releaseHead(self: *Connection) void {
    for (self.head.refs.items) |ref| c.nghttp2_rcbuf_decref(ref);
    self.head.refs.clearRetainingCapacity();
    self.head.fields.clearRetainingCapacity();
    self.head.record = null;
}

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
            if (record.flags.response_started) self.retireBody(record);
        },
        c.NGHTTP2_GOAWAY => if (frame.*.goaway.error_code != c.NGHTTP2_NO_ERROR) {
            self.protocol_failure = true;
        },
        else => {},
    }
    return 0;
}

fn responseStarted(self: *Connection, record: *Record) void {
    if (record.flags.response_started) return;
    record.flags.response_started = true;
    record.releaseFields(self.env.allocator);
    if (record.flags.body_done) self.retireBody(record);
}

fn retireBody(self: *Connection, record: *Record) void {
    const streams_port = self.env.streams;
    streams_port.retireBody(streams_port.context, record);
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
        self.head.status = std.fmt.parseInt(u16, value, 10) catch 0;
        return 0;
    }
    if (name.len > 0 and name[0] == ':') return 0;
    self.head.bytes += name.len + value.len;
    const allocator = self.env.allocator;
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
            self.origin_state.learned_max_streams = self.peer_max_streams;
            if (self.state == .awaiting_settings) self.becomeReady();
            self.sizeWindow();
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
        for (self.head.fields.items) |field| {
            if (std.mem.eql(u8, field.name, "content-encoding") and !policy.identityOnly(field.value))
                return self.endOpen(record, .encoded_response);
        }
    }
    const streams_port = self.env.streams;
    const verdict = streams_port.head(streams_port.context, record, .{
        .kind = kind,
        .status = if (kind == .trailers) 0 else status,
        .fields = self.head.fields.items,
    });
    if (verdict == .refuse) self.endOpen(record, .rejected_headers);
}

fn onDataChunk(_: ?*c.nghttp2_session, _: u8, stream_id: i32, data: [*c]const u8, length: usize, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    const record = self.recordOf(stream_id) orelse {
        self.consume(stream_id, length);
        return 0;
    };
    self.responseStarted(record);
    self.gather(record, data[0..length]);
    return 0;
}

fn onStreamClose(_: ?*c.nghttp2_session, stream_id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
    const self = of(user_data);
    self.streams -= 1;
    if (self.streams == 0) self.idle_since_ns = self.env.clock.now();
    const closing = self.recordOf(stream_id) orelse return 0;
    self.closing_stream_id = stream_id;
    defer self.closing_stream_id = 0;
    self.flush(closing);
    const record = self.recordOf(stream_id) orelse return 0;
    _ = c.nghttp2_session_set_stream_user_data(self.session, stream_id, null);
    if (self.head.record == record) self.releaseHead();
    self.settle(record, policy.streamClosed(@fromBackingInt(@intCast(error_code)), record.facts()));
    return 0;
}

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
