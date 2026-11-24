const std = @import("std");
const c = @import("h2_c");
const h2 = @import("h2.zig");
const policy = @import("policy.zig");
const dial_policy = @import("dial_policy.zig");
const liveness = @import("liveness.zig");
const Record = @import("Stream.zig");
const Connection = @import("Connection.zig");
const Clock = @import("Clock.zig");
const Origin = @import("Origin.zig");
const Waker = @import("os").Waker;
const tls = @import("tls.zig");
const Engine = @This();

allocator: std.mem.Allocator,
options: h2.Options,
callbacks: *c.nghttp2_session_callbacks,
session_options: *c.nghttp2_option,
origins: [h2.max_endpoints]Origin = undefined,
pending: [h2.max_endpoints]Record.Queue = undefined,
origin_count: u8,
endpoints: [h2.max_endpoints]Endpoint = undefined,
endpoint_count: u8,
connections: []Connection,
connections_len: u32,
views: []policy.ConnectionView,
pollfds: []std.c.pollfd,
timers: Record.List,
finished: Record.List,
finished_count: usize,
scratch: *Connection.Scratch,
receiver: ?Receiver,
clock: Clock,
connection_serial: u64,
waker: Waker,
tls_context: ?tls.Context,
proxy_route: ?Origin.Route,
env: Connection.Env,

pub const size = @sizeOf(Engine);
pub const alignment = @alignOf(Engine);

pub const Receiver = struct {
    context: *anyopaque,
    observe: *const fn (*anyopaque, *Record, h2.Event) h2.Verdict,
};

pub const Endpoint = struct {
    url: []u8,
    origin: u8,
    path: []const u8,
};

pub fn init(self: *Engine, allocator: std.mem.Allocator, io: std.Io, options: h2.Options) h2.InitError!void {
    std.debug.assert(options.stream_capacity > 0 and options.inactivity_ns > 0 and options.connect_timeout_ns > 0);
    var proxy_route: ?Origin.Route = if (options.proxy) |settings| try Origin.Route.init(allocator, settings) else null;
    errdefer if (proxy_route) |*value| value.deinit(allocator);
    var callbacks: ?*c.nghttp2_session_callbacks = null;
    if (c.nghttp2_session_callbacks_new(&callbacks) != 0) return error.OutOfMemory;
    errdefer c.nghttp2_session_callbacks_del(callbacks);
    Connection.setCallbacks(callbacks.?);
    var session_options: ?*c.nghttp2_option = null;
    if (c.nghttp2_option_new(&session_options) != 0) return error.OutOfMemory;
    errdefer c.nghttp2_option_del(session_options);
    c.nghttp2_option_set_no_auto_window_update(session_options, 1);

    const capacity = options.stream_capacity;
    const connections = try allocUnwritten(allocator, Connection, capacity);
    errdefer freeUnwritten(allocator, Connection, connections);
    const views = try allocUnwritten(allocator, policy.ConnectionView, capacity);
    errdefer freeUnwritten(allocator, policy.ConnectionView, views);
    const pollfds = try allocUnwritten(allocator, std.c.pollfd, dial_policy.max_attempts * capacity + 1);
    errdefer freeUnwritten(allocator, std.c.pollfd, pollfds);
    const scratch = &(try allocUnwritten(allocator, Connection.Scratch, 1))[0];
    errdefer freeUnwritten(allocator, Connection.Scratch, scratch[0..1]);
    scratch.chunk_count = 0;
    var waker = try Waker.init();
    errdefer waker.deinit();

    self.* = .{
        .allocator = allocator,
        .options = blk: {
            var kept = options;
            kept.proxy = null;
            break :blk kept;
        },
        .callbacks = callbacks.?,
        .session_options = session_options.?,
        .origin_count = 0,
        .endpoint_count = 0,
        .connections = connections,
        .connections_len = 0,
        .views = views,
        .pollfds = pollfds,
        .timers = .{},
        .finished = .{},
        .finished_count = 0,
        .scratch = scratch,
        .receiver = null,
        .clock = Clock.init(io),
        .connection_serial = 0,
        .waker = waker,
        .tls_context = null,
        .proxy_route = proxy_route,
        .env = undefined,
    };
    self.env = .{
        .allocator = allocator,
        .clock = &self.clock,
        .waker = &self.waker,
        .callbacks = self.callbacks,
        .session_options = self.session_options,
        .scratch = self.scratch,
        .tls = &self.tls_context,
        .connect_timeout_ns = options.connect_timeout_ns,
        .stream_capacity = options.stream_capacity,
        .streams = .{
            .context = self,
            .head = streamsHead,
            .deliver = streamsDeliver,
            .retireBody = streamsRetireBody,
            .settle = streamsSettle,
        },
        .origins = &self.origins,
    };
}

fn streamsHead(context: *anyopaque, record: *Record, head: h2.Head) h2.Verdict {
    const self: *Engine = @ptrCast(@alignCast(context));
    return self.observe(record, .{ .head = head });
}

fn streamsDeliver(context: *anyopaque, record: *Record, iovecs: []std.posix.iovec_const, total: usize) ?policy.Cause {
    const self: *Engine = @ptrCast(@alignCast(context));
    if (self.observe(record, .{ .body = total }) == .refuse) return .sink_refused;
    if (!self.writeSink(record, iovecs, total)) return if (record.flags.sink_is_buffer) .sink_refused else .sink_failed;
    record.sink_written += total;
    record.last_activity_ns = self.clock.now();
    self.timers.moveToTail(record);
    return null;
}

fn streamsRetireBody(context: *anyopaque, record: *Record) void {
    const self: *Engine = @ptrCast(@alignCast(context));
    self.retireBody(record);
}

fn streamsSettle(context: *anyopaque, record: *Record, outcome: policy.Settle) void {
    const self: *Engine = @ptrCast(@alignCast(context));
    self.settle(record, outcome);
}

fn settle(self: *Engine, record: *Record, outcome: policy.Settle) void {
    switch (outcome) {
        .end => |cause| self.endStream(record, cause),
        .replay => self.requeue(record, true),
        .reroute => self.requeue(record, false),
    }
}

fn active(self: *Engine) []Connection {
    return self.connections[0..self.connections_len];
}

fn trimTable(self: *Engine) void {
    while (self.connections_len > 0 and self.connections[self.connections_len - 1].available())
        self.connections_len -= 1;
}

/// Allocator.alloc, create and free fill the memory with `undefined`
/// (0xAA) in safe builds, which writes, and so makes resident, every page
/// of a table sized for the worst case: 566 pages at 10,000 entries in
/// the test below. The raw calls skip that fill. Whether untouched pages
/// stay unbacked is then the allocator's: true of the page allocator and
/// of libc malloc at these sizes.
fn allocUnwritten(allocator: std.mem.Allocator, comptime T: type, count: usize) error{OutOfMemory}![]T {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
    const memory = allocator.rawAlloc(bytes, .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const items: [*]T = @ptrCast(@alignCast(memory));
    return items[0..count];
}

fn freeUnwritten(allocator: std.mem.Allocator, comptime T: type, items: []T) void {
    allocator.rawFree(std.mem.sliceAsBytes(items), .of(T), @returnAddress());
}

pub fn deinit(self: *Engine) void {
    std.debug.assert(self.receiver == null);
    std.debug.assert(self.timers.head == null and self.finished.head == null);
    for (self.active()) |*connection| {
        if (connection.state != .free) connection.close(.goaway);
        connection.releaseVerification();
    }
    for (self.origins[0..self.origin_count]) |*origin| origin.lookup.deinit();
    for (self.endpoints[0..self.endpoint_count]) |endpoint| self.allocator.free(endpoint.url);
    if (self.tls_context) |*context| context.deinit();
    if (self.proxy_route) |*via| via.deinit(self.allocator);
    freeUnwritten(self.allocator, Connection.Scratch, self.scratch[0..1]);
    freeUnwritten(self.allocator, std.c.pollfd, self.pollfds);
    freeUnwritten(self.allocator, policy.ConnectionView, self.views);
    freeUnwritten(self.allocator, Connection, self.connections);
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
        self.origins[self.origin_count] = Origin.init(parsed, if (self.proxy_route) |*via| via else null);
        self.pending[self.origin_count] = .{};
        self.origin_count += 1;
        break :blk self.origin_count - 1;
    };
    self.endpoints[self.endpoint_count] = .{ .url = owned, .origin = origin_index, .path = parsed.path };
    self.endpoint_count += 1;
    return @fromBackingInt(@intCast(self.endpoint_count - 1));
}

pub fn prepare(self: *Engine, record: *Record, request: h2.Request) h2.PrepareError!void {
    std.debug.assert(self.receiver == null);
    std.debug.assert(record.state == .idle);
    if (@backingInt(request.endpoint) >= self.endpoint_count) return error.InvalidRequest;
    if (request.fields.len > h2.max_fields) return error.InvalidRequest;
    if (request.method == .get and switch (request.body) {
        .file => |file| file.length != 0,
        .bytes => |bytes| bytes.len != 0,
    }) return error.InvalidRequest;
    if (request.sink == .buffer and request.sink.buffer.len > std.math.maxInt(u32)) return error.InvalidRequest;
    var copied_len: usize = 0;
    var block_len: usize = 0;
    for (request.fields) |field| {
        if (!validFieldName(field.name) or !validFieldValue(field.value)) return error.InvalidRequest;
        copied_len += Record.FieldBlock.entryBytes(.{ .name = field.name, .value = field.value });
        block_len += Record.FieldBlock.entryBytes(field);
    }
    if (copied_len > h2.max_field_block_bytes) return error.InvalidRequest;
    const block = try self.allocator.alloc(u8, block_len);
    var written: usize = 0;
    for (request.fields) |field| {
        written += Record.FieldBlock.put(block[written..], field);
    }
    record.* = std.mem.zeroes(Record);
    record.fields = if (block_len == 0) blk: {
        self.allocator.free(block);
        break :blk null;
    } else block.ptr;
    record.fields_len = @intCast(block_len);
    record.endpoint = @backingInt(request.endpoint);
    record.flags.get = request.method == .get;
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

fn validFieldName(name: []const u8) bool {
    if (name.len == 0 or name.len > std.math.maxInt(u16)) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    for (h2.owned_fields) |owned| {
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
    record.last_activity_ns = self.clock.now();
    self.timers.pushTail(record);
    self.pendingOf(record).pushTail(record);
}

pub fn cancel(self: *Engine, record: *Record) void {
    std.debug.assert(self.receiver == null);
    switch (record.state) {
        .idle => unreachable,
        .prepared => {},
        .pending => {
            self.pendingOf(record).remove(record);
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

pub fn nextFinished(self: *Engine) ?*Record {
    std.debug.assert(self.receiver == null);
    const record = self.finished.popHead() orelse return null;
    self.finished_count -= 1;
    record.state = .collected;
    return record;
}

fn endStream(self: *Engine, record: *Record, cause: policy.Cause) void {
    std.debug.assert(record.state == .pending or record.state == .open);
    if (record.state == .pending) self.pendingOf(record).remove(record);
    self.timers.remove(record);
    self.retireBody(record);
    record.releaseFields(self.allocator);
    record.cause = cause;
    record.state = .finished;
    self.finished.pushTail(record);
    self.finished_count += 1;
}

fn requeue(self: *Engine, record: *Record, replay: bool) void {
    std.debug.assert(record.state == .open and !record.flags.response_started);
    if (replay) record.flags.replays += 1;
    record.state = .pending;
    record.body_offset = 0;
    record.flags.body_done = false;
    self.pendingOf(record).putBack(record);
}

fn retireBody(self: *Engine, record: *Record) void {
    if (record.flags.body_retired) return;
    record.flags.body_retired = true;
    _ = self.observe(record, .body_retired);
}

fn observe(self: *Engine, record: *Record, event: h2.Event) h2.Verdict {
    const receiver = self.receiver.?;
    return receiver.observe(receiver.context, record, event);
}

fn pendingOf(self: *Engine, record: *const Record) *Record.Queue {
    return &self.pending[self.endpoints[record.endpoint].origin];
}

fn connectionOf(self: *Engine, record: *const Record) *Connection {
    return &self.connections[record.route.open.connection - 1];
}

pub fn wake(self: *Engine) void {
    self.waker.wake();
}

pub fn finishedCount(self: *const Engine) usize {
    return self.finished_count;
}

pub fn hasConnections(self: *const Engine) bool {
    return self.connections_len > 0;
}

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
    self.trimTable();
}

fn pollReadiness(self: *Engine) h2.DriveError!void {
    const count = self.fillPollfds();
    if (count == 0) return;
    while (true) {
        const result = std.c.poll(self.pollfds[1..].ptr, @intCast(count), 0);
        if (result >= 0) break;
        if (std.posix.errno(result) != .INTR) return error.PollFailed;
    }
    for (self.active()) |*connection| connection.collect(self.pollfds);
}

fn fillPollfds(self: *Engine) usize {
    var count: usize = 0;
    for (self.active()) |*connection| count = connection.register(self.pollfds, count);
    return count;
}

fn advanceSetups(self: *Engine) void {
    const time = self.clock.now();
    for (self.active()) |*connection| {
        if (!connection.settingUp()) continue;
        switch (connection.state) {
            .resolving => self.settleFailure(connection, connection.finishLookup()),
            .connecting => self.settleFailure(connection, connection.advanceConnect(time)),
            .tunneling => if (connection.revents != 0) self.settleFailure(connection, connection.continueTunnel()),
            .handshaking => if (connection.revents != 0) self.settleFailure(connection, connection.continueHandshake()),
            .verifying => self.settleFailure(connection, connection.finishVerification()),
            else => {},
        }
        if (connection.settingUp() and time >= connection.setup_deadline_ns)
            self.setupFailed(connection, .connect_timeout);
    }
}

fn settleFailure(self: *Engine, connection: *Connection, failure: ?Connection.Failure) void {
    const applied = failure orelse return;
    switch (applied) {
        .setup => |cause| self.setupFailed(connection, cause),
        .lost => |lost| self.lose(connection, lost),
    }
}

fn lose(self: *Engine, connection: *Connection, lost: Connection.Lost) void {
    var next = self.timers.head;
    while (next) |record| {
        next = record.next;
        if (record.state != .open or record.route.open.connection != connection.index + 1) continue;
        const stream_id: u32 = @intCast(record.route.open.stream_id);
        self.settle(record, policy.connectionLost(lost.cause, stream_id, lost.goaway_last_stream_id, record.facts()));
    }
    connection.close(.abrupt);
}

fn setupFailed(self: *Engine, connection: *Connection, cause: policy.Cause) void {
    const origin_index = connection.origin;
    connection.close(.abrupt);
    var setting_up: u32 = 0;
    var ready_with_room: u32 = 0;
    for (self.active()) |*other| {
        if (other.origin != origin_index) continue;
        if (other.settingUp()) setting_up += 1;
        ready_with_room += @intFromBool(other.hasRoom());
    }
    if (policy.pendingAfterSetupFailure(setting_up, ready_with_room) == .wait) return;
    const pending = &self.pending[origin_index];
    while (pending.head) |record| self.endStream(record, cause);
}

fn readAll(self: *Engine) void {
    for (self.active()) |*connection| self.settleFailure(connection, connection.readReady());
}

fn submitPending(self: *Engine) void {
    for (self.pending[0..self.origin_count], 0..) |*pending, origin_index| {
        const origin = &self.origins[origin_index];
        while (pending.head) |record| {
            const connection = &self.connections[self.route(@intCast(origin_index)) orelse break];
            const stream_id = connection.submit(record, origin, self.endpoints[record.endpoint].path) orelse {
                self.endStream(record, .local_failure);
                continue;
            };
            _ = pending.popHead();
            connection.adopt(record, stream_id);
        }
        var setting_up: u32 = 0;
        for (self.active()) |*connection| {
            if (connection.origin == origin_index and connection.settingUp()) setting_up += 1;
        }
        var opening = policy.connectionsToOpen(pending.len, setting_up, origin.learned_max_streams);
        while (opening > 0 and pending.len > 0) : (opening -= 1) {
            const connection = self.freeConnection() orelse break;
            self.connection_serial += 1;
            self.settleFailure(connection, connection.open(@intCast(origin_index), self.connection_serial));
        }
    }
}

fn route(self: *Engine, origin_index: u8) ?usize {
    const views = self.views[0..self.connections_len];
    for (self.active(), views) |*connection, *view| {
        view.* = if (connection.origin == origin_index) connection.view() else .{ .ready = false, .draining = false, .streams = 0, .peer_max_streams = 0 };
    }
    return policy.route(views);
}

fn freeConnection(self: *Engine) ?*Connection {
    for (self.active()) |*connection| {
        if (connection.available()) return connection;
    }
    if (self.connections_len < self.connections.len) {
        const connection = &self.connections[self.connections_len];
        connection.* = .vacant(&self.env, self.connections_len);
        self.connections_len += 1;
        return connection;
    }
    for (self.active()) |*connection| {
        if ((connection.state == .ready or connection.state == .draining) and connection.streams == 0) {
            connection.close(.goaway);
            return connection;
        }
    }
    return null;
}

pub fn retireConnections(self: *Engine, endpoint: h2.Endpoint) void {
    std.debug.assert(self.receiver == null);
    const origin = self.endpoints[@backingInt(endpoint)].origin;
    for (self.active()) |*connection| {
        if (connection.origin != origin) continue;
        switch (connection.state) {
            .ready, .draining => connection.retire(),
            .free => {},
            else => {
                if (self.pending[origin].len == 0) connection.close(.abrupt);
            },
        }
    }
    self.trimTable();
}

fn sendAll(self: *Engine) void {
    for (self.active()) |*connection| {
        if (connection.hasSession()) self.settleFailure(connection, connection.send());
    }
}

fn checkLiveness(self: *Engine) void {
    const time = self.clock.now();
    for (self.active()) |*connection| {
        if (connection.state != .ready and connection.state != .draining) continue;
        if (connection.state == .draining and connection.streams == 0) {
            connection.close(.abrupt);
            continue;
        }
        switch (self.options.liveness.action(self.livenessFacts(connection, time))) {
            .none => {},
            .ping => connection.ping(time),
            .dead => self.lose(connection, connection.lost(.peer_silent)),
            .close => connection.close(.goaway),
        }
    }
}

fn livenessFacts(self: *Engine, connection: *const Connection, time: u64) liveness.Facts {
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

fn expireInactive(self: *Engine) void {
    const time = self.clock.now();
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
    const before = self.clock.awake();
    defer self.clock.charge(before);
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

pub fn wait(self: *Engine, timeout_ms: u32) h2.DriveError!void {
    return self.armWait(timeout_ms).block();
}

pub const Armed = struct {
    pollfds: []std.c.pollfd,
    timeout_ms: u32,
    waker: *Waker,

    pub fn block(self: Armed) h2.DriveError!void {
        const result = std.c.poll(self.pollfds.ptr, @intCast(self.pollfds.len), @intCast(@min(self.timeout_ms, std.math.maxInt(c_int))));
        if (result < 0 and std.posix.errno(result) != .INTR) return error.PollFailed;
        if (result > 0 and self.pollfds[0].revents != 0) self.waker.drain();
    }
};

pub fn armWait(self: *Engine, timeout_ms: u32) Armed {
    std.debug.assert(self.receiver == null);
    const count = self.fillPollfds();
    self.pollfds[0] = .{ .fd = self.waker.read_fd, .events = std.c.POLL.IN, .revents = 0 };
    var timeout = timeout_ms;
    for (self.active()) |*connection| {
        if (connection.tlsPending()) timeout = 0;
    }
    if (self.nextDeadline()) |deadline| {
        const time = self.clock.now();
        const until = std.math.divCeil(u64, deadline -| time, std.time.ns_per_ms) catch unreachable;
        timeout = @intCast(@min(timeout, until));
    }
    return .{ .pollfds = self.pollfds[0 .. count + 1], .timeout_ms = timeout, .waker = &self.waker };
}

fn nextDeadline(self: *Engine) ?u64 {
    const time = self.clock.now();
    var earliest: ?u64 = if (self.timers.head) |head| head.last_activity_ns +| self.options.inactivity_ns else null;
    for (self.active()) |*connection| {
        const deadline: ?u64 = switch (connection.state) {
            .free => null,
            .ready, .draining => self.options.liveness.deadline(self.livenessFacts(connection, time)),
            else => connection.setupDeadline(),
        };
        if (deadline) |value| earliest = if (earliest) |current| @min(current, value) else value;
    }
    return earliest;
}
