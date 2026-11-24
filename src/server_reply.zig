//! What a reply says and how its bytes leave the socket. `Answer` is the value a
//! request's answer is shaped into; `Reply` sends one Answer over one connection, and
//! `ControlTiming` traces a control reply's Store timing once it is fully sent.

const std = @import("std");
const os = @import("os");
const socket_os = os.socket;
const command_spec = @import("command_spec.zig");
const TestObservation = @import("TestObservation.zig");
const protocol = @import("protocol.zig");
const host_reply = @import("host_reply.zig");
const store_module = @import("store.zig");
const server_host = @import("server_host.zig");
const wire_request = @import("wire_request.zig");
const Hooks = server_host.Hooks;
const Probes = server_host.Probes;
const nowNs = server_host.nowNs;

pub const Answer = union(enum) {
    /// Nothing is sent: a deliberate drop, or a reply whose allocation failed.
    none,
    rendered: struct { status: u16, bytes: []u8 },
    report: struct { status: u16, content_type: []const u8, value: store_module.SessionReport },
    content: struct { location: store_module.ContentLocation, start: u64, stream: bool, public: bool },

    pub const Sizing = enum { reserved, growing };

    /// Renders one JSON body. `reserved` sizes the body up front and answers `.none` when that
    /// allocation fails; `growing` lets the body grow, so its allocation failures propagate.
    pub fn json(allocator: std.mem.Allocator, status: u16, max_bytes: usize, sizing: Sizing, comptime render: anytype, args: anytype) !Answer {
        // A writer reports its allocation failure only as a failed write, so the probe records it and keeps
        // it apart from a body that is too large.
        var probe: AllocationProbe = .{ .child = allocator };
        var body: std.Io.Writer.Allocating = switch (sizing) {
            .reserved => std.Io.Writer.Allocating.initCapacity(probe.allocator(), max_bytes) catch return .none,
            .growing => .init(probe.allocator()),
        };
        defer body.deinit();
        @call(.auto, render, .{protocol.JsonOut{ .writer = &body.writer }} ++ args) catch |err| return if (probe.failed) error.OutOfMemory else err;
        if (body.written().len > max_bytes) return error.BufferTooLarge;
        const bytes = body.toOwnedSlice() catch return .none;
        return .{ .rendered = .{ .status = status, .bytes = bytes } };
    }

    const AllocationProbe = struct {
        child: std.mem.Allocator,
        failed: bool = false,

        fn allocator(self: *AllocationProbe) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
            const bytes = self.child.rawAlloc(len, alignment, ret);
            if (bytes == null) self.failed = true;
            return bytes;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *AllocationProbe = @ptrCast(@alignCast(ptr));
            self.child.rawFree(bytes, alignment, ret);
        }
    };
};

/// Hooks a started reply carries: a test gate that holds delivery, and the control timing to trace on completion.
pub const After = struct {
    hold: ?Hooks.Hold = null,
    timing: ?ControlTiming = null,
};

/// What the exchange does with its reply next, judged at one instant.
pub const Next = union(enum) {
    /// Nothing to send, or the deadline has passed.
    retire,
    /// A content window must be read from the Store first.
    fill,
    /// Write now; the reply expires at this deadline.
    write: i128,
    /// Look again no later than this instant.
    wait: i128,
};

pub const Reply = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    header: [320]u8 = undefined,
    header_length: usize = 0,
    header_sent: usize = 0,
    window: [protocol.content_window_bytes]u8 = undefined,
    window_length: usize = 0,
    window_sent: usize = 0,
    offset: u64 = 0,
    end: u64 = 0,
    body: union(enum) {
        none,
        json: []u8,
        report: store_module.SessionReport,
        content: struct { reader: store_module.ContentReader = undefined, public: bool },
    } = .none,
    absolute_deadline: ?i128 = null,
    inactivity_deadline: i128 = 0,
    timing: ?ControlTiming = null,
    gate: ?std.posix.fd_t = null,
    not_before_ns: i128 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, absolute_deadline: ?i128) Reply {
        return .{ .io = io, .allocator = allocator, .absolute_deadline = absolute_deadline };
    }

    /// Installs `answer` and its hooks. Returns whether a delivery gate holds the reply.
    pub fn start(self: *Reply, answer: Answer, after: After) !bool {
        try self.install(answer);
        if (after.timing) |timing| self.timing = timing;
        if (after.hold) |hold| return self.holdDelivery(hold);
        return false;
    }

    /// What the exchange does with this reply at `now`.
    pub fn next(self: *Reply, now: i128) Next {
        if (self.body == .none or now >= self.deadline()) return .retire;
        if (!(self.deliveryReady() catch false)) {
            return .{ .wait = @min(self.deadline(), if (self.gate != null) now + 20 * std.time.ns_per_ms else self.not_before_ns) };
        }
        if (self.needsFill()) return .fill;
        return .{ .write = self.deadline() };
    }

    /// Sends what the socket accepts now. Returns true once the whole reply is sent, which traces control timing.
    pub fn advance(self: *Reply, fd: std.posix.fd_t) !bool {
        const complete = try self.sendAvailable(fd);
        if (complete) {
            if (self.timing) |*timing| timing.replyComplete();
        }
        return complete;
    }

    /// Reads the next content window from the Store.
    pub fn fill(self: *Reply) !void {
        const wanted: usize = @intCast(@min(self.end - self.offset, self.window.len));
        const count = switch (self.body) {
            .content => |*value| if (value.public)
                try value.reader.readRange(self.offset, self.window[0..@max(wanted, 1)])
            else
                try value.reader.read(self.offset, self.window[0..wanted]),
            .report => |*value| try value.read(self.offset, self.window[0..wanted]),
            .none, .json => unreachable,
        };
        if (count != wanted) return error.ShortCanonicalRead;
        self.window_length = count;
        self.window_sent = 0;
        self.renew();
    }

    /// Whether the body is read from the Store, so its owner must release it on the Intake thread.
    pub fn holdsStoreRead(self: *const Reply) bool {
        return switch (self.body) {
            .none, .json => false,
            .report, .content => true,
        };
    }

    pub fn deinit(self: *Reply) void {
        if (self.gate) |gate| _ = std.c.close(gate);
        switch (self.body) {
            .none => {},
            .json => |bytes| self.allocator.free(bytes),
            .report => |*report| report.deinit(),
            .content => |*content| content.reader.close(),
        }
        self.* = .{ .io = self.io, .allocator = self.allocator, .absolute_deadline = self.absolute_deadline };
    }

    fn install(self: *Reply, answer: Answer) !void {
        switch (answer) {
            .none => {},
            .rendered => |value| {
                std.debug.assert(self.body == .none);
                self.prepareHeader(value.status, "application/json", value.bytes.len) catch {
                    self.allocator.free(value.bytes);
                    return;
                };
                self.body = .{ .json = value.bytes };
                self.end = value.bytes.len;
            },
            .report => |value| {
                std.debug.assert(self.body == .none);
                self.body = .{ .report = value.value };
                self.end = value.value.length;
                try self.prepareHeader(value.status, value.content_type, value.value.length);
            },
            .content => |value| {
                std.debug.assert(self.body == .none);
                try self.setContent(value.location, value.start, value.stream, value.public);
            },
        }
    }

    fn holdDelivery(self: *Reply, hold: Hooks.Hold) !bool {
        self.not_before_ns = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + @as(i128, hold.delay_ms) * std.time.ns_per_ms;
        if (hold.gate_path) |value| {
            self.gate = std.posix.openat(std.posix.AT.FDCWD, value, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
        }
        return self.gate != null;
    }

    fn deliveryReady(self: *Reply) !bool {
        if (std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds < self.not_before_ns) return false;
        if (self.gate) |gate| {
            var byte: [1]u8 = undefined;
            const count = std.c.read(gate, &byte, 1);
            if (count < 0) switch (std.posix.errno(count)) {
                .AGAIN, .INTR => return false,
                else => return error.DeliveryGateReadFailed,
            };
            _ = std.c.close(gate);
            self.gate = null;
        }
        return true;
    }

    fn prepareHeader(self: *Reply, status: u16, content_type: []const u8, length: u64) !void {
        const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ status, httpReason(status), content_type, length });
        self.header_length = header.len;
        self.renew();
    }

    fn setContent(self: *Reply, location: store_module.ContentLocation, from: u64, stream: bool, public: bool) !void {
        self.body = .{ .content = .{ .public = public } };
        self.body.content.reader.open(location);
        self.offset = from;
        const length = if (stream) location.reference.length - from else @min(location.reference.length - from, protocol.content_window_bytes);
        self.end = from + length;
        if (public) {
            try self.fill();
            const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ length, location.reference.length, self.end });
            self.header_length = header.len;
            self.renew();
        } else try self.prepareHeader(200, "text/plain; charset=utf-8", length);
    }

    fn renew(self: *Reply) void {
        self.inactivity_deadline = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + 60 * std.time.ns_per_s;
    }

    fn deadline(self: *const Reply) i128 {
        return self.absolute_deadline orelse self.inactivity_deadline;
    }

    fn needsFill(self: *const Reply) bool {
        return self.header_sent == self.header_length and self.offset != self.end and
            self.body != .json and self.window_sent == self.window_length;
    }

    fn sendAvailable(self: *Reply, fd: std.posix.fd_t) !bool {
        // A reply with no installed body has nothing to send, so it has no peer wait to time out.
        if (self.body == .none) return true;
        if (std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds >= self.deadline())
            return if (self.absolute_deadline != null) error.ExchangeDeadlineExceeded else error.TransferInactive;
        if (self.header_sent < self.header_length) {
            self.header_sent += try self.write(fd, self.header[self.header_sent..self.header_length]);
            return false;
        }
        if (self.offset == self.end) return true;
        if (self.body == .json) {
            const from: usize = @intCast(self.offset);
            const end = @min(self.body.json.len, from + protocol.content_window_bytes);
            self.offset += try self.write(fd, self.body.json[from..end]);
        } else {
            if (self.window_sent == self.window_length) {
                try self.fill();
                return false;
            }
            const count = try self.write(fd, self.window[self.window_sent..self.window_length]);
            self.window_sent += count;
            self.offset += count;
        }
        return self.offset == self.end;
    }

    fn write(self: *Reply, fd: std.posix.fd_t, bytes: []const u8) !usize {
        const count = std.c.write(fd, bytes.ptr, bytes.len);
        if (count < 0) switch (std.posix.errno(count)) {
            .AGAIN, .INTR => return 0,
            else => return error.WriteFailed,
        };
        if (count == 0) return error.ConnectionClosed;
        self.renew();
        return @intCast(count);
    }

    /// Test client: sends `bytes` as the whole body, with no header.
    fn deliverBytes(self: *Reply, fd: std.posix.fd_t, bytes: []const u8) !void {
        self.body = .{ .json = try self.allocator.dupe(u8, bytes) };
        self.end = bytes.len;
        try self.deliver(fd);
    }

    fn deliver(self: *Reply, fd: std.posix.fd_t) !void {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.WriteFailed;
        self.renew();
        while (true) {
            wire_request.pollExchange(self.io, fd, std.posix.POLL.OUT, self.deadline()) catch |err|
                return if (err == error.ExchangeDeadlineExceeded and self.absolute_deadline == null) error.TransferInactive else err;
            if (try self.advance(fd)) return;
        }
    }
};

/// The allocator a reply's answer bodies are rendered with.
pub fn allocatorOf(reply: *const Reply) std.mem.Allocator {
    return reply.allocator;
}

/// Test client: sends one reply on the socket, waiting within the reply's own budget.
pub fn sendReply(io: std.Io, fd: std.posix.fd_t, reply: *Reply) !void {
    try makeNonblocking(fd);
    while (true) {
        try wire_request.pollExchange(io, fd, std.posix.POLL.OUT, null);
        if (try reply.advance(fd)) return;
    }
}

/// Test client: sends raw bytes on the socket, waiting at most a minute for each window.
pub fn sendBytes(io: std.Io, fd: std.posix.fd_t, bytes: []const u8) !void {
    try makeNonblocking(fd);
    var sent: usize = 0;
    while (sent < bytes.len) {
        try wire_request.pollExchange(io, fd, std.posix.POLL.OUT, null);
        const count = std.c.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (count < 0) switch (std.posix.errno(count)) {
            .AGAIN, .INTR => continue,
            else => return error.WriteFailed,
        };
        if (count == 0) return error.ConnectionClosed;
        sent += @intCast(count);
    }
}

/// Test client: sends the reply and returns every byte it wrote, headers included. The caller frees it.
pub fn sentWire(io: std.Io, allocator: std.mem.Allocator, reply: *Reply) ![]u8 {
    var sockets: [2]c_int = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(sockets[1]);
    defer _ = std.c.close(sockets[0]);
    try sendReply(io, sockets[0], reply);
    _ = std.c.shutdown(sockets[0], std.posix.SHUT.WR);
    var received: std.ArrayList(u8) = .empty;
    errdefer received.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const count = std.c.read(sockets[1], &chunk, chunk.len);
        if (count < 0) return error.ReadFailed;
        if (count == 0) break;
        try received.appendSlice(allocator, chunk[0..@intCast(count)]);
    }
    return received.toOwnedSlice(allocator);
}

/// The body that follows the headers of wire bytes from `sentWire`.
pub fn bodyOf(wire: []const u8) []const u8 {
    const headers_end = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse return wire[wire.len..];
    return wire[headers_end + 4 ..];
}

fn makeNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.WriteFailed;
}

/// Answers a refusal with its static JSON body. A reply whose allocation fails sends nothing.
pub fn refuse(reply: *Reply, status: u16, kind: protocol.ErrorType, code: []const u8) void {
    const answer = Answer.json(reply.allocator, status, protocol.max_control_error_response_bytes, .reserved, host_reply.renderStatic, .{ kind, code }) catch return;
    _ = reply.start(answer, .{}) catch {};
}

pub const ControlTiming = struct {
    probes: *Probes,
    io: std.Io,
    command_key: protocol.Bounded(protocol.max_key_bytes),
    kind: []const u8,
    accepted_at_ns: u64,
    store_queued_ns: u64 = 0,
    lock_acquired_ns: u64 = 0,
    store_complete_ns: u64 = 0,

    pub fn init(probes: *Probes, io: std.Io, command_key: protocol.Bounded(protocol.max_key_bytes), kind: []const u8, accepted_at_ns: u64) ControlTiming {
        return .{
            .probes = probes,
            .io = io,
            .command_key = command_key,
            .kind = kind,
            .accepted_at_ns = accepted_at_ns,
        };
    }

    pub fn storeTrace(self: *ControlTiming) ?store_module.ControlTrace {
        if (!self.probes.hooks.phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.ControlTracePhase) void {
        const self: *ControlTiming = @ptrCast(@alignCast(context));
        switch (phase) {
            .lock_requested => {
                self.store_queued_ns = nowNs(self.io);
                self.probes.traceSubject("control_store_queued", "command_key", self.command_key.slice());
            },
            .lock_acquired => {
                self.lock_acquired_ns = nowNs(self.io);
                self.probes.traceSubject("control_lock_acquired", "command_key", self.command_key.slice());
                self.waitAtTestGate();
            },
            .durable_acceptance => {
                self.probes.traceSubject("control_durable_acceptance", "command_key", self.command_key.slice());
            },
            .store_complete => {
                self.store_complete_ns = nowNs(self.io);
                self.probes.traceSubject("control_store_complete", "command_key", self.command_key.slice());
            },
        }
    }

    fn waitAtTestGate(self: *ControlTiming) void {
        const gate_hook = self.probes.hooks.control_gate orelse return;
        var candidates = std.mem.splitScalar(u8, gate_hook.keys, ',');
        while (candidates.next()) |candidate| {
            if (!std.mem.eql(u8, candidate, self.command_key.slice())) continue;
            var gate = std.Io.Dir.cwd().openFile(self.io, gate_hook.path, .{}) catch return;
            defer gate.close(self.io);
            var release: [1]u8 = undefined;
            const count = gate.readStreaming(self.io, &.{&release}) catch return;
            if (count == 1) self.probes.traceSubject("control_gate_released", "command_key", self.command_key.slice());
            return;
        }
    }

    inline fn replyComplete(self: *ControlTiming) void {
        if (self.probes.hooks.phase_trace) self.writeReplyComplete();
    }

    noinline fn writeReplyComplete(self: *ControlTiming) void {
        const reply_complete_ns = nowNs(self.io);
        if (self.store_queued_ns == 0 or self.lock_acquired_ns == 0 or self.store_complete_ns == 0) return;
        var publication = self.probes.beginObservation("control_timing", null);
        defer if (publication) |*value| value.finish();
        var trace: protocol.DiagnosticBuffer = .{};
        trace.append("{\"rui_test_phase\":\"control_timing\",\"command_key\":") catch return;
        trace.appendJsonString(self.command_key.slice()) catch return;
        trace.append(",\"kind\":") catch return;
        trace.appendJsonString(self.kind) catch return;
        trace.appendFmt(",\"store_queued_at_ns\":\"{d}\",\"lock_acquired_at_ns\":\"{d}\",\"store_complete_at_ns\":\"{d}\",\"reply_complete_at_ns\":\"{d}\",\"queue_wait_ns\":\"{d}\",\"store_lock_wait_ns\":\"{d}\",\"store_service_ns\":\"{d}\",\"post_commit_reply_ns\":\"{d}\",\"host_total_ns\":\"{d}\"}}", .{
            self.store_queued_ns,
            self.lock_acquired_ns,
            self.store_complete_ns,
            reply_complete_ns,
            self.store_queued_ns - self.accepted_at_ns,
            self.lock_acquired_ns - self.store_queued_ns,
            self.store_complete_ns - self.lock_acquired_ns,
            reply_complete_ns - self.store_complete_ns,
            reply_complete_ns - self.accepted_at_ns,
        }) catch return;
        self.probes.writeTrace(&trace, &publication);
    }
};

fn httpReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        409 => "Conflict",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        else => "Error",
    };
}

/// Test client: sends `bytes` as a reply would, within the reply's inactivity budget.
fn writeHttpUntil(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8, deadline: ?i128) !void {
    var reply = Reply.init(io, std.testing.allocator, deadline);
    defer reply.deinit();
    _ = try reply.start(try Answer.json(std.testing.allocator, status, 64 * 1024, .reserved, protocol.JsonOut.append, .{body}), .{});
    try reply.deliver(fd);
}

fn writeAll(io: std.Io, fd: std.posix.fd_t, bytes: []const u8) !void {
    var reply = Reply.init(io, std.testing.allocator, null);
    defer reply.deinit();
    try reply.deliverBytes(fd, bytes);
}

test "reply delivery establishes nonblocking only when sending" {
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[0], std.c.F.GETFL) & nonblocking);
    try writeAll(std.testing.io, sockets[0], "a\xc3\xa9\x00z");
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 5), std.c.read(sockets[1], &actual, actual.len));
    try std.testing.expectEqualSlices(u8, "a\xc3\xa9\x00z", &actual);
    try std.testing.expectEqual(nonblocking, std.c.fcntl(sockets[0], std.c.F.GETFL) & nonblocking);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.GETFL) & nonblocking);
}

test "discovery reply delivery shares its absolute budget across header and partial body writes" {
    const Peer = struct {
        fd: std.posix.fd_t,
        actual: [65536 + 256]u8 = undefined,
        used: usize = 0,
        writes: usize = 0,
        at: i96 = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before = self.used;
            while (self.used < self.actual.len) {
                const count = std.c.read(self.fd, self.actual[self.used..].ptr, self.actual.len - self.used);
                if (count < 0) {
                    std.debug.assert(std.posix.errno(count) == .AGAIN);
                    break;
                }
                std.debug.assert(count > 0);
                self.used += @intCast(count);
            }
            if (self.used != before) {
                self.writes += 1;
                self.at += 3 * std.time.ns_per_s;
            }
            return .fromNanoseconds(self.at);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const capacity: c_int = 1024;
    try std.posix.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.SETFL, nonblocking));
    var peer: Peer = .{ .fd = sockets[1] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Peer.now;
    const io: std.Io = .{ .userdata = &peer, .vtable = &vtable };
    var body: [65536]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast((index * 19 + 37) % 251);
    try std.testing.expectError(error.ExchangeDeadlineExceeded, writeHttpUntil(io, sockets[0], 200, &body, 10 * std.time.ns_per_s));
    const boundary = std.mem.indexOf(u8, peer.actual[0..peer.used], "\r\n\r\n").? + 4;
    try std.testing.expect(peer.writes >= 4 and peer.at >= 10 * std.time.ns_per_s);
    try std.testing.expect(peer.used > boundary and peer.used - boundary < body.len);
    try std.testing.expectEqualSlices(u8, body[0 .. peer.used - boundary], peer.actual[boundary..peer.used]);
}

test "reply delivery renews on short writes and excludes production between windows" {
    const Peer = struct {
        fd: std.posix.fd_t,
        actual: [65536]u8 = undefined,
        used: usize = 0,
        writes: usize = 0,
        at: i96 = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before = self.used;
            while (self.used < self.actual.len) {
                const count = std.c.read(self.fd, self.actual[self.used..].ptr, self.actual.len - self.used);
                if (count < 0) {
                    std.debug.assert(std.posix.errno(count) == .AGAIN);
                    break;
                }
                std.debug.assert(count > 0);
                self.used += @intCast(count);
            }
            if (self.used != before) {
                self.writes += 1;
                self.at += 30 * std.time.ns_per_s;
            }
            return .fromNanoseconds(self.at);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    var capacity: c_int = 1024;
    try std.posix.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.SETFL, nonblocking));
    var peer: Peer = .{ .fd = sockets[1] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Peer.now;
    const io: std.Io = .{ .userdata = &peer, .vtable = &vtable };
    var expected: [65536]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @intCast((index * 17 + 29) % 251);
    try writeAll(io, sockets[0], &expected);
    try std.testing.expectEqualSlices(u8, &expected, peer.actual[0..peer.used]);
    try std.testing.expect(peer.writes >= 3);
    try std.testing.expect(peer.at > 60 * std.time.ns_per_s);
    peer.used = 0;
    peer.at += 120 * std.time.ns_per_s;
    try writeAll(io, sockets[0], "next\x00window");
    try std.testing.expectEqualSlices(u8, "next\x00window", peer.actual[0..peer.used]);
}

test "reply delivery retries actual AGAIN without renewing inactivity" {
    const Race = struct {
        fd: std.posix.fd_t,
        calls: usize = 0,
        filled: usize = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.calls == 3) {
                const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
                std.debug.assert(std.c.fcntl(self.fd, std.c.F.GETFL) & nonblocking != 0);
                const bytes = @as([1024]u8, @splat(0x69));
                while (true) {
                    const count = std.c.write(self.fd, &bytes, bytes.len);
                    if (count < 0) {
                        std.debug.assert(std.posix.errno(count) == .AGAIN);
                        break;
                    }
                    std.debug.assert(count > 0);
                    self.filled += @intCast(count);
                }
            }
            return .fromNanoseconds(if (self.calls > 3) @as(i96, @intCast(self.calls - 3)) * 60 * std.time.ns_per_s else 0);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    var race: Race = .{ .fd = sockets[0] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Race.now;
    const io: std.Io = .{ .userdata = &race, .vtable = &vtable };
    try std.testing.expectError(error.TransferInactive, writeAll(io, sockets[0], "not delivered"));
    try std.testing.expect(race.filled > 0);
    try std.testing.expectEqual(@as(usize, 4), race.calls);
}

test "reply delivery interrupted poll consumes the existing inactivity budget" {
    const Interrupt = struct {
        var hits: std.atomic.Value(u32) = .init(0);
        target: std.c.pthread_t,
        fd: std.posix.fd_t,
        stop: std.atomic.Value(bool) = .init(false),

        fn signal(_: std.posix.SIG) callconv(.c) void {
            _ = hits.fetchAdd(1, .monotonic);
        }

        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .fromNanoseconds(@as(i96, hits.load(.monotonic)) * 20 * std.time.ns_per_s);
        }

        fn run(self: *@This()) void {
            const io = std.Io.Threaded.global_single_threaded.io();
            const limit = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 3 * std.time.ns_per_s;
            while (!self.stop.load(.acquire)) {
                std.Io.sleep(io, .fromMilliseconds(5), .awake) catch unreachable;
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= limit) {
                    _ = socket_os.shutdown(self.fd, std.c.SHUT.RDWR);
                    return;
                }
                _ = std.c.pthread_kill(self.target, .USR1);
            }
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[0], std.c.F.SETFL, nonblocking));
    const bytes = @as([1024]u8, @splat(0x53));
    while (std.c.write(sockets[0], &bytes, bytes.len) >= 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(@as(isize, -1)));
    var old_action: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = Interrupt.signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.USR1, &action, &old_action);
    defer std.posix.sigaction(.USR1, &old_action, null);
    Interrupt.hits.store(0, .monotonic);
    var interrupt: Interrupt = .{ .target = std.c.pthread_self(), .fd = sockets[0] };
    const thread = try std.Thread.spawn(.{}, Interrupt.run, .{&interrupt});
    defer {
        interrupt.stop.store(true, .release);
        thread.join();
    }
    var vtable = std.testing.io.vtable.*;
    vtable.now = Interrupt.now;
    const io: std.Io = .{ .userdata = null, .vtable = &vtable };
    try std.testing.expectError(error.TransferInactive, writeAll(io, sockets[0], "not delivered"));
    try std.testing.expect(Interrupt.hits.load(.monotonic) >= 3);
}

test "delayed control replies retain command identity after request storage reuse" {
    const native = @import("posix");
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |control_kind| {
        if (comptime !command_spec.spec(control_kind).is_control) continue;
        const kind = @tagName(control_kind);
        var descriptors: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
        defer _ = native.close(descriptors[0]);
        for (descriptors) |fd| {
            try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
        }
        const backing = native.tmpfile() orelse return error.TestUnexpectedResult;
        defer _ = native.fclose(backing);
        try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(native.fileno(backing), TestObservation.state_bytes));
        var observation = try TestObservation.init(descriptors[1], native.dup(native.fileno(backing)), .control, 37);
        defer observation.close();
        var probes: Probes = .init(std.testing.io, .{ .phase_trace = true });
        probes.observation = observation;
        var original: [protocol.max_key_bytes]u8 = undefined;
        for (&original, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
        var request_key = protocol.Bounded(protocol.max_key_bytes){ .bytes = original, .len = original.len };
        var reply = Reply{ .io = std.testing.io, .allocator = std.testing.allocator };
        defer reply.deinit();
        reply.timing = ControlTiming.init(&probes, std.testing.io, request_key, kind, 1);
        reply.timing.?.store_queued_ns = 2;
        reply.timing.?.lock_acquired_ns = 3;
        reply.timing.?.store_complete_ns = 4;
        @memset(&request_key.bytes, 'X');
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[0]);
        defer _ = std.c.close(sockets[1]);
        _ = try reply.start(try Answer.json(std.testing.allocator, 200, protocol.max_response_bytes, .reserved, protocol.JsonOut.append, .{"{\"accepted\":true}"}), .{});
        try reply.deliver(sockets[0]);
        var bytes: [TestObservation.record_bytes]u8 = undefined;
        const length = native.read(descriptors[0], &bytes, bytes.len);
        try std.testing.expect(length >= 28);
        const frame = bytes[0..@intCast(length)];
        try std.testing.expect(std.mem.indexOf(u8, frame, "control_timing") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, &original) != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, kind) != null);
        try std.testing.expectEqual(@as(u64, 2), observation.shared.state.load(.acquire));
    }
}

test "SH-122 answer shaping sends nothing when reserved bytes cannot be allocated and refusals carry their status kind and code" {
    const Refusal = struct { status: u16, kind: protocol.ErrorType, code: []const u8 };
    const refusals = [_]Refusal{
        .{ .status = 409, .kind = .invocation_error, .code = "wrong_store_identity" },
        .{ .status = 400, .kind = .invocation_error, .code = "host_instance_required" },
        .{ .status = 500, .kind = .observation_error, .code = "OutOfMemory" },
        .{ .status = 503, .kind = .host_unavailable, .code = "dispatch_fenced" },
    };
    for (refusals) |row| {
        var reply = Reply.init(std.testing.io, std.testing.allocator, null);
        defer reply.deinit();
        refuse(&reply, row.status, row.kind, row.code);
        const wire = try sentWire(std.testing.io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        var status_line: [32]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, wire, try std.fmt.bufPrint(&status_line, "HTTP/1.1 {d} ", .{row.status})));
        var code_field: [64]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, wire, try std.fmt.bufPrint(&code_field, "\"code\":\"{s}\"", .{row.code})) != null);
    }

    // A reserved answer whose bytes cannot be allocated sends nothing: the peer reads zero bytes.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var silent = Reply.init(std.testing.io, failing.allocator(), null);
    defer silent.deinit();
    refuse(&silent, 500, .observation_error, "OutOfMemory");
    const silent_wire = try sentWire(std.testing.io, std.testing.allocator, &silent);
    defer std.testing.allocator.free(silent_wire);
    try std.testing.expectEqual(@as(usize, 0), silent_wire.len);

    // A growing answer has no reserved size to fail on, so its allocation failure is reported to the caller.
    var growing_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Answer.json(growing_failing.allocator(), 500, 4096, .growing, host_reply.renderStatic, .{ .observation_error, "OutOfMemory" }));
}
