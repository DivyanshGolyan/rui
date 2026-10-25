//! The Client's representation and its one control loop. Rui sees only the
//! opaque `h2.Client` bytes.
//!
//! One owner per piece of state:
//! - `timers` orders every launched stream (pending or open) by its last
//!   activity; every stream shares one interval, so the head is due first;
//! - an `Origin` owns its queue of pending streams and its learned limit;
//! - a `Connection` owns its socket and nghttp2 session, and carries its
//!   open streams as nghttp2 stream user data;
//! - `finished` owns ended streams until `nextFinished` hands them back.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const h2 = @import("h2.zig");
const policy = @import("policy.zig");
const Record = @import("Stream.zig");
const Connection = @import("Connection.zig");
const Waker = @import("Waker.zig");
const tls = @import("tls.zig");
const Engine = @This();

allocator: std.mem.Allocator,
io: std.Io,
options: h2.Options,
callbacks: *c.nghttp2_session_callbacks,
session_options: *c.nghttp2_option,
origins: [h2.max_endpoints]Origin,
origin_count: u8,
endpoints: [h2.max_endpoints]Endpoint,
endpoint_count: u8,
/// Never moved: open streams name theirs by index + 1.
connections: []Connection,
/// One entry per connection, rebuilt for each routing decision.
views: []policy.ConnectionView,
/// The waker first, then one entry per connection.
pollfds: []std.c.pollfd,
timers: Record.List,
finished: Record.List,
finished_count: usize,
scratch: *Scratch,
/// Set only while `drive` runs.
receiver: ?Receiver,
/// Time spent blocked writing to sinks, excluded from provider time. While
/// a write blocks nothing else progresses, so one offset shifts every
/// deadline equally and keeps the timer list ordered.
stall_ns: u64,
connection_serial: u64,
waker: Waker,
/// Built by the first `https://` endpoint, so a cleartext-only Client
/// loads no trust store.
tls_context: ?tls.Context,

pub const size = @sizeOf(Engine);
pub const alignment = @alignOf(Engine);

pub const Receiver = struct {
    context: *anyopaque,
    observe: *const fn (*anyopaque, *h2.Stream, h2.Event) h2.Verdict,
};

pub const Origin = struct {
    scheme: h2.Scheme,
    /// Slices of the first endpoint's owned URL with this origin.
    host: []const u8,
    authority: []const u8,
    port: u16,
    /// From the first SETTINGS seen on this origin; until then at most one
    /// connection is set up at a time.
    learned_max_streams: ?u32,
    pending: Record.Queue,
};

pub const Endpoint = struct {
    /// Owned exact-length copy of the URL.
    url: []u8,
    origin: u8,
    /// Slice of `url`.
    path: []const u8,
};

/// The read buffer and the DATA chunks decoded from it, so each stream gets
/// one write per socket read. Chunks point into `read_buffer`, which is
/// not overwritten until the next read.
pub const Scratch = struct {
    pub const max_chunks = 256;
    read_buffer: [h2.read_buffer_bytes]u8,
    chunks: [max_chunks]Chunk,
    chunk_count: u16,
    iovecs: [max_chunks]std.posix.iovec_const,

    pub const Chunk = struct { record: ?*Record, bytes: []const u8 };
};

pub fn of(client: *h2.Client) *Engine {
    return @ptrCast(client);
}

pub fn ofConst(client: *const h2.Client) *const Engine {
    return @ptrCast(client);
}

pub fn init(self: *Engine, allocator: std.mem.Allocator, io: std.Io, options: h2.Options) h2.InitError!void {
    std.debug.assert(options.stream_capacity > 0 and options.inactivity_ns > 0 and options.connect_timeout_ns > 0);
    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
    errdefer c.nghttp2_session_callbacks_del(callbacks);
    Connection.setCallbacks(callbacks.?);
    var session_options: ?*c.nghttp2_option = null;
    if (c.nghttp2_option_new(&session_options) != 0) return error.OutOfMemory;
    errdefer c.nghttp2_option_del(session_options);
    // The stream window reopens only once its bytes are on the sink.
    c.nghttp2_option_set_no_auto_window_update(session_options, 1);

    const capacity = options.stream_capacity;
    const connections = try allocator.alloc(Connection, capacity);
    errdefer allocator.free(connections);
    const views = try allocator.alloc(policy.ConnectionView, capacity);
    errdefer allocator.free(views);
    const pollfds = try allocator.alloc(std.c.pollfd, capacity + 1);
    errdefer allocator.free(pollfds);
    const scratch = try allocator.create(Scratch);
    errdefer allocator.destroy(scratch);
    scratch.chunk_count = 0;
    var waker = try Waker.init();
    errdefer waker.deinit();

    self.* = .{
        .allocator = allocator,
        .io = io,
        .options = options,
        .callbacks = callbacks.?,
        .session_options = session_options.?,
        .origins = undefined,
        .origin_count = 0,
        .endpoints = undefined,
        .endpoint_count = 0,
        .connections = connections,
        .views = views,
        .pollfds = pollfds,
        .timers = .{},
        .finished = .{},
        .finished_count = 0,
        .scratch = scratch,
        .receiver = null,
        .stall_ns = 0,
        .connection_serial = 0,
        .waker = waker,
        .tls_context = null,
    };
    for (connections, 0..) |*connection, index| connection.* = .free(self, @intCast(index));
}

pub fn deinit(self: *Engine) void {
    std.debug.assert(self.receiver == null);
    std.debug.assert(self.timers.head == null and self.finished.head == null);
    for (self.connections) |*connection| {
        if (connection.state != .free) connection.close(.goaway);
    }
    for (self.endpoints[0..self.endpoint_count]) |endpoint| self.allocator.free(endpoint.url);
    if (self.tls_context) |*context| context.deinit();
    self.allocator.destroy(self.scratch);
    self.allocator.free(self.pollfds);
    self.allocator.free(self.views);
    self.allocator.free(self.connections);
    c.nghttp2_option_del(self.session_options);
    c.nghttp2_session_callbacks_del(self.callbacks);
    self.waker.deinit();
    self.* = undefined;
}

pub fn addEndpoint(self: *Engine, url: []const u8) h2.EndpointError!h2.Endpoint {
    std.debug.assert(self.receiver == null);
    _ = try h2.parseUrl(url);
    if (self.endpoint_count == h2.max_endpoints) return error.TooManyEndpoints;
    const owned = try self.allocator.dupe(u8, url);
    errdefer self.allocator.free(owned);
    const parsed = h2.parseUrl(owned) catch unreachable;
    if (parsed.scheme == .https and self.tls_context == null) self.tls_context = try tls.Context.init(self.options.trust);
    const origin_index: u8 = for (self.origins[0..self.origin_count], 0..) |origin, index| {
        if (origin.scheme == parsed.scheme and origin.port == parsed.port and std.mem.eql(u8, origin.host, parsed.host))
            break @intCast(index);
    } else blk: {
        self.origins[self.origin_count] = .{
            .scheme = parsed.scheme,
            .host = parsed.host,
            .authority = parsed.authority,
            .port = parsed.port,
            .learned_max_streams = null,
            .pending = .{},
        };
        self.origin_count += 1;
        break :blk self.origin_count - 1;
    };
    self.endpoints[self.endpoint_count] = .{ .url = owned, .origin = origin_index, .path = parsed.path };
    self.endpoint_count += 1;
    return @fromBackingInt(@intCast(self.endpoint_count - 1));
}

// ------------------------------------------------------------------ streams

pub fn prepare(self: *Engine, record: *Record, request: h2.Request) h2.PrepareError!void {
    std.debug.assert(self.receiver == null);
    std.debug.assert(record.state == .idle);
    if (@backingInt(request.endpoint) >= self.endpoint_count) return error.InvalidRequest;
    if (request.fields.len > h2.max_fields) return error.InvalidRequest;
    var block_len: usize = 0;
    for (request.fields) |field| {
        if (!validFieldName(field.name) or !validFieldValue(field.value)) return error.InvalidRequest;
        block_len += Record.FieldBlock.header_bytes + field.name.len + field.value.len;
    }
    if (block_len > h2.max_field_block_bytes) return error.InvalidRequest;
    const block = try self.allocator.alloc(u8, block_len);
    var written: usize = 0;
    for (request.fields) |field| {
        written += Record.FieldBlock.put(block[written..], .{ .name = field.name, .value = field.value, .sensitive = field.sensitive });
    }
    record.* = std.mem.zeroes(Record);
    record.fields = if (block_len == 0) blk: {
        self.allocator.free(block);
        break :blk null;
    } else block.ptr;
    record.fields_len = @intCast(block_len);
    record.endpoint = @backingInt(request.endpoint);
    switch (request.body) {
        .file => |file| {
            record.body_source = @intCast(file.handle);
            record.body_length = file.length;
        },
        .bytes => |bytes| {
            record.flags.body_is_bytes = true;
            record.body_source = @intFromPtr(bytes.ptr);
            record.body_length = bytes.len;
        },
    }
    switch (request.sink) {
        .file => |fd| record.sink_target = @intCast(fd),
        .buffer => |buffer| {
            record.flags.sink_is_buffer = true;
            record.sink_target = @intFromPtr(buffer.ptr);
            record.sink_capacity = @intCast(buffer.len);
        },
    }
    record.state = .prepared;
}

/// Lowercase tokens; pseudo-headers and the fields the client owns or
/// HTTP/2 forbids are refused.
fn validFieldName(name: []const u8) bool {
    if (name.len == 0 or name.len > std.math.maxInt(u16)) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    for ([_][]const u8{ "content-length", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "host" }) |owned| {
        if (std.mem.eql(u8, name, owned)) return false;
    }
    return true;
}

fn validFieldValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

pub fn launch(self: *Engine, record: *Record) void {
    std.debug.assert(self.receiver == null);
    std.debug.assert(record.state == .prepared);
    record.state = .pending;
    record.last_activity_ns = self.now();
    self.timers.pushTail(record);
    self.origins[self.endpoints[record.endpoint].origin].pending.pushTail(record);
}

pub fn cancel(self: *Engine, record: *Record) void {
    std.debug.assert(self.receiver == null);
    switch (record.state) {
        .idle => unreachable,
        .prepared => {},
        .pending => {
            self.originOf(record).pending.remove(record);
            self.timers.remove(record);
        },
        .open => {
            self.connectionOf(record).detach(record);
            self.timers.remove(record);
        },
        .finished => {
            self.finished.remove(record);
            self.finished_count -= 1;
        },
        .collected, .cancelled => return,
    }
    record.releaseFields(self.allocator);
    record.state = .cancelled;
}

pub fn nextFinished(self: *Engine) ?*h2.Stream {
    std.debug.assert(self.receiver == null);
    const record = self.finished.popHead() orelse return null;
    self.finished_count -= 1;
    record.state = .collected;
    return record.public();
}

/// Ends a pending or open stream. An open one must already be detached
/// from nghttp2 or closing there, so no callback reaches it again.
pub fn endStream(self: *Engine, record: *Record, cause: policy.Cause) void {
    std.debug.assert(record.state == .pending or record.state == .open);
    if (record.state == .pending) self.originOf(record).pending.remove(record);
    self.timers.remove(record);
    self.retireBody(record);
    record.releaseFields(self.allocator);
    record.cause = cause;
    record.state = .finished;
    self.finished.pushTail(record);
    self.finished_count += 1;
}

/// The stream goes back to the head of its origin's queue, to be sent again
/// from byte 0 on whichever connection has room.
pub fn requeue(self: *Engine, record: *Record, replay: bool) void {
    std.debug.assert(record.state == .open and !record.flags.response_started);
    if (replay) record.flags.replays += 1;
    record.state = .pending;
    record.body_offset = 0;
    record.flags.body_done = false;
    self.originOf(record).pending.pushHead(record);
}

/// Emits `body_retired` once, and never after a cancel.
pub fn retireBody(self: *Engine, record: *Record) void {
    if (record.flags.body_retired) return;
    record.flags.body_retired = true;
    _ = self.observe(record, .body_retired);
}

pub fn observe(self: *Engine, record: *Record, event: h2.Event) h2.Verdict {
    const receiver = self.receiver.?;
    return receiver.observe(receiver.context, record.public(), event);
}

pub fn originOf(self: *Engine, record: *const Record) *Origin {
    return &self.origins[self.endpoints[record.endpoint].origin];
}

fn connectionOf(self: *Engine, record: *const Record) *Connection {
    return &self.connections[record.route.open.connection - 1];
}

/// Provider time: the awake clock less the time blocked on sinks.
pub fn now(self: *const Engine) u64 {
    const awake: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    return awake - self.stall_ns;
}

// --------------------------------------------------------------------- drive

/// The order is the design; each step is one function.
pub fn drive(self: *Engine, receiver: Receiver) h2.DriveError!void {
    std.debug.assert(self.receiver == null);
    self.receiver = receiver;
    defer self.receiver = null;

    try self.pollReadiness();
    self.advanceSetups();
    self.readAll();
    self.expireInactive();
    self.submitPending();
    self.sendAll();
    self.checkLiveness();
}

/// poll(0) over every socket, so each step below acts only on ready ones.
fn pollReadiness(self: *Engine) h2.DriveError!void {
    const count = self.fillPollfds();
    if (count == 0) return;
    while (true) {
        const result = std.c.poll(self.pollfds[1..].ptr, @intCast(count), 0);
        if (result >= 0) break;
        if (std.posix.errno(result) != .INTR) return error.PollFailed;
    }
    for (self.connections) |*connection| {
        if (connection.poll_slot != 0) connection.revents = self.pollfds[connection.poll_slot].revents;
    }
}

/// Fills `pollfds` after the waker slot with every connection that has a
/// socket and returns the number of connection entries.
fn fillPollfds(self: *Engine) usize {
    var count: usize = 0;
    for (self.connections) |*connection| {
        connection.revents = 0;
        connection.poll_slot = 0;
        const events = connection.pollEvents() orelse continue;
        count += 1;
        self.pollfds[count] = .{ .fd = connection.socket, .events = events, .revents = 0 };
        connection.poll_slot = @intCast(count);
    }
    return count;
}

fn advanceSetups(self: *Engine) void {
    const time = self.now();
    for (self.connections) |*connection| {
        if (!connection.settingUp()) continue;
        switch (connection.state) {
            .resolving => connection.finishLookup(),
            .connecting => if (connection.revents != 0) connection.finishConnect(),
            .handshaking => if (connection.revents != 0) connection.continueHandshake(),
            else => {},
        }
        if (connection.settingUp() and time >= connection.setup_deadline_ns)
            self.setupFailed(connection, .connect_timeout);
    }
}

/// A connection failed before it was ready, so it carried no stream. Its
/// origin's pending streams end only when nothing else can carry them.
pub fn setupFailed(self: *Engine, connection: *Connection, cause: policy.Cause) void {
    const origin_index = connection.origin;
    connection.close(.abrupt);
    var setting_up: u32 = 0;
    var ready_with_room: u32 = 0;
    for (self.connections) |*other| {
        if (other.origin != origin_index) continue;
        if (other.settingUp()) setting_up += 1;
        ready_with_room += @intFromBool(other.hasRoom());
    }
    if (policy.pendingAfterSetupFailure(setting_up, ready_with_room) == .wait) return;
    const origin = &self.origins[origin_index];
    while (origin.pending.head) |record| self.endStream(record, cause);
}

/// Marks each connection that stopped at its read allowance.
fn readAll(self: *Engine) void {
    for (self.connections) |*connection| {
        connection.read_capped = false;
        if (!connection.hasSession() or (connection.revents == 0 and !connection.tlsPending())) continue;
        if (connection.receive() == .capped) connection.read_capped = true;
    }
}

fn submitPending(self: *Engine) void {
    for (self.origins[0..self.origin_count], 0..) |*origin, origin_index| {
        while (origin.pending.head) |record| {
            const connection = &self.connections[self.route(@intCast(origin_index)) orelse break];
            const stream_id = connection.submit(record, origin, self.endpoints[record.endpoint].path) orelse {
                self.endStream(record, .local_failure);
                continue;
            };
            _ = origin.pending.popHead();
            connection.adopt(record, stream_id);
        }
        var setting_up: u32 = 0;
        for (self.connections) |*connection| {
            if (connection.origin == origin_index and connection.settingUp()) setting_up += 1;
        }
        var opening = policy.connectionsToOpen(origin.pending.len, setting_up, origin.learned_max_streams);
        while (opening > 0 and origin.pending.len > 0) : (opening -= 1) {
            const connection = self.freeConnection() orelse break;
            self.connection_serial += 1;
            connection.open(@intCast(origin_index), self.connection_serial);
        }
    }
}

fn route(self: *Engine, origin_index: u8) ?usize {
    for (self.connections, self.views) |*connection, *view| {
        view.* = if (connection.origin == origin_index) connection.view() else .{ .ready = false, .draining = false, .streams = 0, .peer_max_streams = 0 };
    }
    return policy.route(self.views);
}

/// A free table entry, closing an empty connection when the table is full.
/// With one entry per stream of capacity, a full table that still needs a
/// connection always holds an empty one.
fn freeConnection(self: *Engine) ?*Connection {
    for (self.connections) |*connection| {
        if (connection.state == .free) return connection;
    }
    for (self.connections) |*connection| {
        if ((connection.state == .ready or connection.state == .draining) and connection.streams == 0) {
            connection.close(.goaway);
            return connection;
        }
    }
    return null;
}

fn sendAll(self: *Engine) void {
    for (self.connections) |*connection| {
        if (connection.hasSession()) connection.send();
    }
}

fn checkLiveness(self: *Engine) void {
    const time = self.now();
    for (self.connections) |*connection| {
        if (connection.state != .ready and connection.state != .draining) continue;
        if (connection.state == .draining and connection.streams == 0) {
            connection.close(.abrupt);
            continue;
        }
        switch (policy.liveness(self.livenessFacts(connection, time), self.options.liveness)) {
            .none => {},
            .ping => connection.ping(time),
            .dead => connection.lose(.peer_silent),
            .close => connection.close(.goaway),
        }
    }
}

fn livenessFacts(self: *Engine, connection: *const Connection, time: u64) policy.LivenessFacts {
    var only_idle = true;
    for (self.connections[0..connection.index]) |*other| {
        if (other.origin == connection.origin and other.state == .ready and other.streams == 0) only_idle = false;
    }
    return .{
        .now_ns = time,
        .last_inbound_ns = connection.last_inbound_ns,
        .ping_sent_ns = connection.ping_sent_ns,
        .streams = connection.streams,
        .idle_since_ns = connection.idle_since_ns,
        .is_only_idle = only_idle,
    };
}

/// Before submitting, so an overdue pending stream never sends a byte. An
/// open stream on a connection that stopped at its read allowance waits:
/// its bytes may be unread.
fn expireInactive(self: *Engine) void {
    const time = self.now();
    var next = self.timers.head;
    while (next) |record| {
        if (time -| record.last_activity_ns < self.options.inactivity_ns) break;
        next = record.next;
        if (record.state == .open) {
            const connection = self.connectionOf(record);
            if (connection.read_capped) continue;
            connection.detach(record);
        }
        self.endStream(record, .inactive);
    }
}

/// The batch write: for each stream, everything this read decoded for it
/// in one write, then its window reopens for exactly what was written.
pub fn flush(self: *Engine, connection: *Connection) void {
    const scratch = self.scratch;
    defer scratch.chunk_count = 0;
    const chunks = scratch.chunks[0..scratch.chunk_count];
    for (chunks, 0..) |*first, start| {
        const record = first.record orelse continue;
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
        // A stream ended during this decode only returns connection credit.
        if (record.state != .open) {
            connection.consume(stream_id, total);
            continue;
        }
        if (self.observe(record, .{ .body = total }) == .refuse) {
            connection.consume(stream_id, total);
            connection.endOpen(record, .sink_refused);
            continue;
        }
        if (!self.writeSink(record, scratch.iovecs[0..iovec_count], total)) {
            connection.consume(stream_id, total);
            connection.endOpen(record, if (record.flags.sink_is_buffer) .sink_refused else .sink_failed);
            continue;
        }
        record.sink_written += total;
        record.last_activity_ns = self.now();
        self.timers.moveToTail(record);
        connection.consume(stream_id, total);
    }
}

fn writeSink(self: *Engine, record: *Record, iovecs: []std.posix.iovec_const, total: usize) bool {
    if (record.flags.sink_is_buffer) {
        if (record.sink_capacity - record.sink_written < total) return false;
        var at: [*]u8 = @ptrFromInt(record.sink_target + record.sink_written);
        for (iovecs) |iovec| {
            @memcpy(at[0..iovec.len], iovec.base[0..iovec.len]);
            at += iovec.len;
        }
        return true;
    }
    const before: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    defer self.stall_ns += @as(u64, @intCast(std.Io.Clock.awake.now(self.io).nanoseconds)) - before;
    const fd: std.posix.fd_t = @intCast(record.sink_target);
    var remaining = iovecs;
    var offset = record.sink_written;
    while (remaining.len > 0) {
        const count = @min(remaining.len, 1024);
        const written = std.c.pwritev(fd, remaining.ptr, @intCast(count), @intCast(offset));
        if (written < 0) {
            if (std.posix.errno(written) == .INTR) continue;
            return false;
        }
        if (written == 0) return false;
        var advanced: usize = @intCast(written);
        offset += advanced;
        while (remaining.len > 0 and advanced >= remaining[0].len) {
            advanced -= remaining[0].len;
            remaining = remaining[1..];
        }
        if (advanced > 0) {
            remaining[0].base += advanced;
            remaining[0].len -= advanced;
        }
    }
    return true;
}

/// Called from the DATA chunk callback.
pub fn gather(self: *Engine, connection: *Connection, record: *Record, bytes: []const u8) void {
    const scratch = self.scratch;
    if (scratch.chunk_count == Scratch.max_chunks) self.flush(connection);
    scratch.chunks[scratch.chunk_count] = .{ .record = record, .bytes = bytes };
    scratch.chunk_count += 1;
}

// ---------------------------------------------------------------------- wait

pub fn wait(self: *Engine, timeout_ms: u32) h2.DriveError!void {
    std.debug.assert(self.receiver == null);
    const count = self.fillPollfds();
    self.pollfds[0] = .{ .fd = self.waker.read_fd, .events = std.c.POLL.IN, .revents = 0 };
    var timeout = timeout_ms;
    for (self.connections) |*connection| {
        if (connection.tlsPending()) timeout = 0;
    }
    if (self.nextDeadline()) |deadline| {
        const time = self.now();
        const until = std.math.divCeil(u64, deadline -| time, std.time.ns_per_ms) catch unreachable;
        timeout = @intCast(@min(timeout, until));
    }
    const result = std.c.poll(self.pollfds.ptr, @intCast(count + 1), @intCast(timeout));
    if (result < 0 and std.posix.errno(result) != .INTR) return error.PollFailed;
    if (result > 0 and self.pollfds[0].revents != 0) self.waker.drain();
}

fn nextDeadline(self: *Engine) ?u64 {
    const time = self.now();
    var earliest: ?u64 = if (self.timers.head) |head| head.last_activity_ns +| self.options.inactivity_ns else null;
    for (self.connections) |*connection| {
        const deadline: ?u64 = switch (connection.state) {
            .free => null,
            .resolving, .connecting, .handshaking, .awaiting_settings => connection.setup_deadline_ns,
            .ready, .draining => policy.livenessDeadline(self.livenessFacts(connection, time), self.options.liveness),
        };
        if (deadline) |value| earliest = if (earliest) |current| @min(current, value) else value;
    }
    return earliest;
}
