//! One HTTP/2 connection: its socket and nghttp2 session. Internal.
//!
//!   free -> [resolving] -> connecting -> [handshaking] -> [verifying] -> awaiting_settings
//!        (DNS names)   (addresses       (https)         (macOS system  (preface and our
//!                       raced, RFC 8305) trust)         SETTINGS sent)
//!   -> ready -> draining -> free
//!      (streams  (GOAWAY seen:
//!       submitted) no submits)
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
const Resolver = @import("Resolver.zig");
const tls = @import("tls.zig");
const sec_trust = @import("sec_trust.zig");
const Connection = @This();

pub const State = enum(u8) { free = 0, resolving, connecting, handshaking, verifying, awaiting_settings, ready, draining };

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
/// An nghttp2 call that adjusts credit or queues a reset failed (out of
/// memory). Streams would stall, so the connection fails at the next
/// receive or send, outside nghttp2's callbacks.
local_failure: bool,
/// Index into the Engine's poll array for the current pass, 0 for none.
poll_slot: u32,
revents: i16,
socket: std.posix.fd_t,
/// While connecting, `socket` is the newest attempt and this the one
/// before it, still in flight; -1 otherwise. Polled in the slot after
/// `poll_slot`.
earlier: std.posix.fd_t,
earlier_revents: i16,
/// While connecting, when the next address's attempt is due; 0 when no
/// address is left.
next_attempt_ns: u64,
/// For an https origin, from the TCP connect on.
ssl: ?*c.SSL,
/// Counted among its origin's lookup users until a connect succeeds.
uses_lookup: bool,
/// The next address to try.
address_index: u8,
/// The handshake, or a read, waits for the socket to take bytes.
tls_wants_write: bool,
/// SecTrust's evaluation of the peer while `verifying`, kept past `close`
/// until its thread returns: a slot runs at most one evaluation, so a
/// stalled trustd holds at most one thread per table entry. Nothing off
/// macOS.
verification: if (sec_trust.enabled) ?*sec_trust.Job else void,
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
        .local_failure = false,
        .poll_slot = 0,
        .revents = 0,
        .socket = -1,
        .earlier = -1,
        .earlier_revents = 0,
        .next_attempt_ns = 0,
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
        .resolving, .connecting, .handshaking, .verifying, .awaiting_settings => true,
        .free, .ready, .draining => false,
    };
}

/// OpenSSL holds decrypted bytes not yet read, which poll cannot see. A
/// partial record does not count: it waits for the socket like any read.
pub fn tlsPending(self: *const Connection) bool {
    const ssl = self.ssl orelse return false;
    return self.session != null and c.SSL_pending(ssl) > 0;
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
        // Nothing is read or written until SecTrust answers.
        .free, .resolving, .verifying => null,
        .connecting => std.c.POLL.OUT,
        .handshaking => if (self.tls_wants_write) std.c.POLL.OUT else std.c.POLL.IN,
        .awaiting_settings, .ready, .draining => blk: {
            const write = self.tls_wants_write or self.unsent.len > 0 or c.nghttp2_session_want_write(self.session) != 0;
            break :blk if (write) std.c.POLL.IN | std.c.POLL.OUT else std.c.POLL.IN;
        },
    };
}

// ------------------------------------------------------------------ setup

/// free -> resolving for a DNS name, else straight to connecting.
pub fn open(self: *Connection, origin_index: u8, serial: u64) void {
    std.debug.assert(self.state == .free);
    const engine = self.engine;
    const origin = &engine.origins[origin_index];
    self.origin = origin_index;
    self.serial = serial;
    self.setup_deadline_ns = engine.now() +| engine.options.connect_timeout_ns;
    if (origin.literal != null) return self.advanceAttempts(false, engine.now());
    self.state = .resolving;
    // Setups of one origin share its lookup; a finished one nobody uses is
    // stale, so a new setup looks the name up again.
    if (origin.lookup) |lookup| if (origin.lookup_users == 0 and lookup.result() != null) {
        lookup.release();
        origin.lookup = null;
    };
    if (origin.lookup == null) origin.lookup = Resolver.start(&engine.waker, origin.host, origin.port) orelse
        return engine.setupFailed(self, .local_failure);
    origin.lookup_users += 1;
    self.uses_lookup = true;
}

/// resolving -> connecting, once the lookup finished.
pub fn finishLookup(self: *Connection) void {
    const lookup = self.engine.origins[self.origin].lookup.?.result() orelse return;
    if (lookup.found().len == 0) return self.engine.setupFailed(self, .resolve_failed);
    self.advanceAttempts(false, self.engine.now());
}

fn addressAt(self: *Connection, index: u8) ?Resolver.Address {
    const origin = &self.engine.origins[self.origin];
    if (origin.literal) |literal| return if (index == 0) literal else null;
    const addresses = origin.lookup.?.result().?.found();
    return if (index < addresses.len) addresses[index] else null;
}

/// The last user of a finished lookup frees it. A running one stays with
/// the origin for the next setup, so a stalled resolver never piles up
/// threads: at most one lookup runs per origin.
fn stopUsingLookup(self: *Connection) void {
    if (!self.uses_lookup) return;
    self.uses_lookup = false;
    const origin = &self.engine.origins[self.origin];
    origin.lookup_users -= 1;
    const lookup = origin.lookup.?;
    if (origin.lookup_users == 0 and lookup.result() != null) {
        lookup.release();
        origin.lookup = null;
    }
}

/// While connecting: ends attempts the socket answered, then starts the
/// next address's as `policy.nextAttempt` decides.
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

/// The earlier attempt's socket while connecting, polled beside `socket`.
pub fn earlierAttempt(self: *const Connection) ?std.posix.fd_t {
    return if (self.state == .connecting and self.earlier >= 0) self.earlier else null;
}

/// The setup deadline, or the next attempt's if that comes first.
pub fn setupDeadline(self: *const Connection) u64 {
    if (self.next_attempt_ns == 0) return self.setup_deadline_ns;
    return @min(self.next_attempt_ns, self.setup_deadline_ns);
}

fn advanceAttempts(self: *Connection, failed: bool, time: u64) void {
    self.state = .connecting;
    var failure = failed;
    while (true) {
        switch (policy.nextAttempt(.{
            .in_flight = @as(u8, @intFromBool(self.socket >= 0)) + @intFromBool(self.earlier >= 0),
            .more_addresses = self.addressAt(self.address_index) != null,
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

/// Connects a new socket to the next address as `socket`, the attempt
/// before it becoming `earlier`.
fn attempt(self: *Connection, time: u64) enum { connected, in_flight, refused, local_failure } {
    std.debug.assert(self.earlier < 0);
    const address = self.addressAt(self.address_index).?;
    self.address_index += 1;
    self.next_attempt_ns = if (self.addressAt(self.address_index) != null) time +| policy.attempt_delay_ns else 0;
    const fd = std.c.socket(address.family, std.c.SOCK.STREAM, 0);
    if (fd < 0) return .local_failure;
    self.earlier = self.socket;
    self.socket = fd;
    if (!configureSocket(fd)) return .local_failure;
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

/// A failed close leaves nothing to retry or report: the descriptor is
/// released either way, and no write of ours is awaiting its result.
fn closeSocket(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
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

/// `socket` connected: the race and the addresses are done with; https
/// goes on to its handshake.
fn connected(self: *Connection) void {
    self.dropEarlier();
    self.next_attempt_ns = 0;
    self.stopUsingLookup();
    const origin = &self.engine.origins[self.origin];
    if (origin.scheme == .http) return self.startSession();
    const context = &self.engine.tls_context.?;
    self.ssl = context.newSession(self.socket, origin.server_name, if (origin.literal != null) .ip_literal else .dns_name) orelse
        return self.engine.setupFailed(self, .local_failure);
    self.state = .handshaking;
    self.continueHandshake();
}

/// handshaking -> awaiting_settings once the peer is verified and chose
/// h2, through verifying when SecTrust has the verdict.
pub fn continueHandshake(self: *Connection) void {
    switch (tls.handshake(self.ssl.?)) {
        .done => {
            self.tls_wants_write = false;
            if (sec_trust.enabled and self.engine.tls_context.?.deferred) return self.startVerification();
            self.startTrustedSession();
        },
        .want_read => self.tls_wants_write = false,
        .want_write => self.tls_wants_write = true,
        .failed => |cause| self.engine.setupFailed(self, cause),
    }
}

fn startVerification(self: *Connection) void {
    std.debug.assert(self.verification == null);
    const server_name = self.engine.origins[self.origin].server_name;
    self.verification = sec_trust.Verification.start(&self.engine.waker, self.ssl.?, server_name) orelse
        return self.engine.setupFailed(self, .local_failure);
    self.state = .verifying;
}

/// verifying -> awaiting_settings once SecTrust trusts the peer.
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

/// A verified TLS session becomes an h2 session if the peer chose h2.
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
    if (c.nghttp2_session_client_new3(&session, engine.callbacks, self, engine.session_options, null) != 0)
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
    const engine = self.engine;
    const time = engine.now();
    self.state = .ready;
    self.idle_since_ns = time;
    self.last_inbound_ns = time;
}

/// Enough for every stream this connection may carry to have its full
/// window outstanding, so the connection never throttles one stream. Set
/// again whenever the peer's SETTINGS change its stream limit.
fn sizeWindow(self: *Connection) void {
    const carried: u64 = @min(self.peer_max_streams, self.engine.options.stream_capacity);
    const window: i32 = @intCast(@min(@as(u64, h2.stream_window_bytes) * @max(carried, 1), std.math.maxInt(i32)));
    self.check(c.nghttp2_session_set_local_window_size(self.session, c.NGHTTP2_FLAG_NONE, 0, window));
}

// ------------------------------------------------------------- streaming

/// Packs nothing yet: HEADERS are serialized by the next `send`. Returns
/// the stream id, or null when nghttp2 refused the submit.
pub fn submit(self: *Connection, record: *Record, origin: *const Engine.Origin, path: []const u8) ?i32 {
    std.debug.assert(self.hasRoom());
    var nva: [h2.max_fields + 6]c.nghttp2_nv = undefined;
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
    // No content coding is decoded here, so none is accepted (RFC 9110
    // 12.5.3: a request without accept-encoding accepts any).
    nva[5] = nv("accept-encoding", "identity", borrowed);
    var count: usize = 6;
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
        self.check(c.nghttp2_submit_rst_stream(self.session, c.NGHTTP2_FLAG_NONE, stream_id, c.NGHTTP2_CANCEL));
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
    self.check(c.nghttp2_session_consume(self.session, stream_id, bytes));
}

/// Returns credit to the connection only, for bytes a stream will never
/// take: that stream's window stays shut.
pub fn consumeConnection(self: *Connection, bytes: usize) void {
    self.check(c.nghttp2_session_consume_connection(self.session, bytes));
}

fn check(self: *Connection, result: c_int) void {
    if (result != 0) self.local_failure = true;
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
        self.last_inbound_ns = engine.now();
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
        engine.flush(self, null);
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

/// Writes what nghttp2 has packed until it has nothing or the socket would
/// block. nghttp2 coalesces all pending frames into each buffer.
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
    // nghttp2 wants neither: the session ended (GOAWAY sent or received).
    if (c.nghttp2_session_want_read(self.session) == 0 and c.nghttp2_session_want_write(self.session) == 0)
        self.fail(if (self.protocol_failure) .protocol_error else .connection_lost);
}

const Transfer = union(enum) { bytes: usize, again, closed };

/// One socket read, through TLS for https. Never zero bytes.
fn readSome(self: *Connection, buffer: []u8) Transfer {
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

/// One socket write, through TLS for https. A TLS write that needs a read
/// first waits for readability, which every session state polls for.
fn writeSome(self: *Connection, bytes: []const u8) Transfer {
    if (self.ssl) |ssl| return switch (tls.write(ssl, bytes)) {
        .bytes => |count| .{ .bytes = count },
        .want_read, .want_write => .again,
        .closed => .closed,
    };
    while (true) {
        const sent = std.c.send(self.socket, bytes.ptr, bytes.len, tls.send_flags);
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
                // close_notify, best effort and without waiting for the peer's.
                if (goaway_sent) if (self.ssl) |ssl| {
                    _ = c.SSL_shutdown(ssl);
                };
            }
        }
        c.nghttp2_session_del(session);
    }
    if (self.ssl) |ssl| c.SSL_free(ssl);
    self.stopUsingLookup();
    if (self.socket >= 0) closeSocket(self.socket);
    self.dropEarlier();
    self.releaseHead();
    self.head.fields.deinit(self.engine.allocator);
    self.head.refs.deinit(self.engine.allocator);
    const verification = self.verification;
    self.* = .free(self.engine, self.index);
    self.verification = verification;
}

/// Free, with no evaluation still running from an earlier setup.
pub fn available(self: *Connection) bool {
    if (self.state != .free) return false;
    if (sec_trust.enabled) if (self.verification) |verification| {
        if (verification.result() == null) return false;
        self.releaseVerification();
    };
    return true;
}

/// Lets go of any evaluation; a running one finishes on its own thread.
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
/// no resend can follow: the field block, and any credential copied into
/// it, goes now.
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
    const closing = self.recordOf(stream_id) orelse return 0;
    self.closing_stream_id = stream_id;
    defer self.closing_stream_id = 0;
    engine.flush(self, closing);
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
