const std = @import("std");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");

pub const default_active_capacity = 1000;
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_clients = 128;
pub const max_ordinary_clients = 120;
pub const control_headroom = 8;
// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// One MiB is the next fixed tested bound; at 128 clients the maximum virtual
// stack reservation is therefore 128 MiB, while physical use remains on the
// production resource-measurement path.
pub const connection_stack_bytes = 1024 * 1024;
pub const maximum_connection_stack_reservation_bytes = max_clients * connection_stack_bytes;

pub const Faults = struct {
    content_write: bool = false,
    content_read: bool = false,
    before_commit: bool = false,
    startup_cleanup: bool = false,
    shutdown_after_accept: bool = false,
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    faults: Faults,
    request_counter: std.atomic.Value(u64) = .init(0),
    active_clients: std.atomic.Value(usize) = .init(0),
    classification_clients: std.atomic.Value(usize) = .init(0),
    ordinary_clients: std.atomic.Value(usize) = .init(0),
    scratch_used: std.atomic.Value(u64) = .init(0),
    drain_mutex: std.Io.Mutex = .init,
    drain_condition: std.Io.Condition = .init,

    fn clientFinished(self: *Host) void {
        self.drain_mutex.lockUncancelable(self.io);
        const prior = self.active_clients.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        self.drain_condition.broadcast(self.io);
        self.drain_mutex.unlock(self.io);
    }

    fn drain(self: *Host) void {
        self.drain_mutex.lockUncancelable(self.io);
        defer self.drain_mutex.unlock(self.io);
        while (self.active_clients.load(.acquire) != 0) {
            self.drain_condition.waitUncancelable(self.io, &self.drain_mutex);
        }
    }
};

const Connection = struct {
    host: *Host,
    stream: std.Io.net.Stream,
};

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    active_capacity: usize,
    faults: Faults,
) !void {
    var lease = try platform.StoreLease.acquire(io, store_path);
    defer lease.release();
    var storage = try store_module.Store.open(io, lease.paths.database.slice(), lease.paths.store.slice());
    defer storage.close() catch |err| std.debug.print("latifa: Store close failed: {s}\n", .{@errorName(err)});
    try lease.prepareForServing(faults.startup_cleanup);

    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(io, .{ .kernel_backlog = max_clients });
    var listener_open = true;
    var socket_owned = true;
    errdefer {
        if (listener_open) listener.deinit(io);
        if (socket_owned) std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            std.debug.print("latifa: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
    }
    var socket_path: [257:0]u8 = undefined;
    const socket_z = try std.fmt.bufPrintZ(&socket_path, "{s}", .{lease.paths.socket.slice()});
    if (std.c.chmod(socket_z, 0o600) != 0) return error.SocketProtectionFailed;

    var host = Host{
        .io = io,
        .allocator = allocator,
        .lease = &lease,
        .store = &storage,
        .faults = faults,
    };
    defer {
        // Stop admitting new connections before waiting for transferred
        // streams. Store and lease defers run only after the drain completes.
        listener.deinit(io);
        listener_open = false;
        std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            // The lock still protects this failed cleanup. A later startup
            // removes the owned socket or refuses to serve if it cannot.
            std.debug.print("latifa: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
        socket_owned = false;
        host.drain();
    }
    var ready: protocol.ResponseBuffer = .{};
    try ready.appendFmt("ready store={s} socket={s} active_capacity={d}\n", .{
        lease.paths.store.slice(),
        lease.paths.socket.slice(),
        active_capacity,
    });
    try std.Io.File.stdout().writeStreamingAll(io, ready.slice());

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        const previous = host.active_clients.fetchAdd(1, .acq_rel);
        if (previous >= max_clients) {
            host.clientFinished();
            sendStatic(io, stream.socket.handle, 503, "busy", "connection_capacity_exhausted") catch {};
            stream.close(io);
            continue;
        }
        const previous_classification = host.classification_clients.fetchAdd(1, .acq_rel);
        if (previous_classification >= control_headroom) {
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            sendStatic(io, stream.socket.handle, 503, "busy", "classification_capacity_exhausted") catch {};
            stream.close(io);
            continue;
        }
        const connection = allocator.create(Connection) catch {
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            stream.close(io);
            continue;
        };
        connection.* = .{ .host = &host, .stream = stream };
        const thread = std.Thread.spawn(.{ .stack_size = connection_stack_bytes }, connectionMain, .{connection}) catch {
            allocator.destroy(connection);
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            stream.close(io);
            continue;
        };
        thread.detach();
        if (host.faults.shutdown_after_accept) return error.InjectedListenerFailure;
    }
}

fn connectionMain(connection: *Connection) void {
    const host = connection.host;
    const stream = connection.stream;
    defer {
        stream.close(host.io);
        host.allocator.destroy(connection);
        // This is the last Host access: drain may release the stack owner as
        // soon as the active population reaches zero.
        host.clientFinished();
    }
    handleConnection(host, stream.socket.handle) catch |err| {
        sendStatic(host.io, stream.socket.handle, 400, "invocation_error", @errorName(err)) catch {};
    };
}

const Route = enum { configure, message, observe, inspect, unsupported_control };
const DropMode = enum { none, before_admission, after_commit };

const Header = struct {
    route: Route,
    content_length: u64,
    drop: DropMode = .none,
};

fn handleConnection(host: *Host, fd: std.posix.fd_t) !void {
    var classification_held = true;
    defer if (classification_held) {
        _ = host.classification_clients.fetchSub(1, .acq_rel);
    };
    const header = try readHeader(host.io, fd);
    const ordinary = header.route != .unsupported_control;
    if (ordinary) {
        const previous = host.ordinary_clients.fetchAdd(1, .acq_rel);
        if (previous >= max_ordinary_clients) {
            _ = host.ordinary_clients.fetchSub(1, .acq_rel);
            return respondStatic(host.io, fd, 503, "busy", "ordinary_capacity_exhausted");
        }
        defer _ = host.ordinary_clients.fetchSub(1, .acq_rel);
        const prior = host.classification_clients.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        classification_held = false;
    }
    if (header.route == .unsupported_control) {
        return respondStatic(host.io, fd, 501, "unsupported", "control_surface_enters_in_later_slice");
    }
    if (!try reserveScratch(host, header.content_length)) {
        return respondStatic(host.io, fd, 507, "invocation_error", "scratch_capacity_exhausted");
    }
    var release_scratch = true;
    defer if (release_scratch) releaseScratch(host, header.content_length);

    const request_number = nextRequestNumber(host) catch {
        return respondStatic(host.io, fd, 500, "invocation_error", "request_identity_exhausted");
    };
    var cleanup_failed = false;
    var request = protocol.parseRequest(.{
        .io = host.io,
        .fd = fd,
        .content_length = header.content_length,
        .scratch_path = host.lease.paths.scratch.slice(),
        .request_number = request_number,
        .fault_content_write = host.faults.content_write,
        .cleanup_failed = &cleanup_failed,
    }) catch |err| {
        if (cleanup_failed) release_scratch = false;
        return respondStatic(host.io, fd, 400, "invocation_error", @errorName(err));
    };
    defer request.removeTemporaryContent(host.io) catch |err| {
        release_scratch = false;
        std.debug.print("latifa: retained scratch charge after cleanup failure: {s}\n", .{@errorName(err)});
    };
    if (!std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(host.io, fd, 409, "invocation_error", "wrong_store_identity");
    }
    const route_matches = switch (request) {
        .configure => header.route == .configure,
        .message => header.route == .message,
        .observe_command => header.route == .observe,
        .inspect_session => header.route == .inspect,
    };
    if (!route_matches) {
        return respondStatic(host.io, fd, 400, "invocation_error", "route_kind_mismatch");
    }
    if (header.drop == .before_admission) return;

    switch (request) {
        .configure => |*command| {
            const result = host.store.configure(command, .{
                .content_read = host.faults.content_read,
                .before_commit = host.faults.before_commit,
            });
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderConfigureReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
        },
        .message => |*command| {
            const result = host.store.rejectMessage(command, .{
                .content_read = host.faults.content_read,
                .before_commit = host.faults.before_commit,
            });
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderMessageReply(&response, command, result);
            const status: u16 = switch (result) {
                .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
        },
        .observe_command => |command| {
            const observation = host.store.observeCommand(command.key.slice()) catch {
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, command.key.slice(), observation);
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .inspect_session => |request_value| {
            const observation = host.store.inspectSession(request_value.session.slice()) catch {
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            var response: protocol.ResponseBuffer = .{};
            try renderSessionObservation(&response, observation);
            deliverResponse(host.io, fd, 200, response.slice());
        },
    }
}

fn reserveScratch(host: *Host, amount: u64) !bool {
    if (amount > scratch_limit_bytes) return false;
    var current = host.scratch_used.load(.acquire);
    while (true) {
        const next = std.math.add(u64, current, amount) catch return false;
        if (next > scratch_limit_bytes) return false;
        current = host.scratch_used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
    }
}

fn releaseScratch(host: *Host, amount: u64) void {
    const prior = host.scratch_used.fetchSub(amount, .acq_rel);
    std.debug.assert(prior >= amount);
}

fn nextRequestNumber(host: *Host) !u64 {
    var current = host.request_counter.load(.acquire);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.RequestIdentityExhausted;
        current = host.request_counter.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse
            return current;
    }
}

fn readHeader(io: std.Io, fd: std.posix.fd_t) !Header {
    var buffer: [protocol.max_header_bytes]u8 = undefined;
    var used: usize = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (used < buffer.len) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed = start.durationTo(now).raw.nanoseconds;
        if (elapsed >= 10 * std.time.ns_per_s) return error.HeaderDeadlineExceeded;
        const remaining_ms: i32 = @intCast(@max(1, @divFloor(10 * std.time.ns_per_s - elapsed, std.time.ns_per_ms)));
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, remaining_ms) == 0) return error.HeaderDeadlineExceeded;
        const count = try std.posix.read(fd, buffer[used .. used + 1]);
        if (count == 0) return error.IncompleteHeader;
        used += count;
        if (used >= 4 and std.mem.eql(u8, buffer[used - 4 .. used], "\r\n\r\n")) break;
    } else return error.HeaderTooLarge;

    const headers = buffer[0..used];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    const request_line = lines.next() orelse return error.InvalidRequestLine;
    var request_parts = std.mem.splitScalar(u8, request_line, ' ');
    if (!std.mem.eql(u8, request_parts.next() orelse return error.InvalidRequestLine, "POST")) {
        return error.InvalidMethod;
    }
    const path = request_parts.next() orelse return error.InvalidRequestLine;
    if (!std.mem.eql(u8, request_parts.next() orelse return error.InvalidRequestLine, "HTTP/1.1") or
        request_parts.next() != null)
    {
        return error.InvalidRequestLine;
    }
    const route: Route = if (std.mem.eql(u8, path, "/v1/configure"))
        .configure
    else if (std.mem.eql(u8, path, "/v1/message"))
        .message
    else if (std.mem.eql(u8, path, "/v1/observe-command"))
        .observe
    else if (std.mem.eql(u8, path, "/v1/inspect-session"))
        .inspect
    else if (std.mem.startsWith(u8, path, "/v1/control/"))
        .unsupported_control
    else
        return error.UnknownRoute;

    var content_length: ?u64 = null;
    var wire_ok = false;
    var content_type_ok = false;
    var drop: DropMode = .none;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (content_length != null) return error.DuplicateContentLength;
            content_length = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            content_type_ok = std.ascii.eqlIgnoreCase(value, "application/json");
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Wire-Version")) {
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Test-Drop-Reply")) {
            drop = if (std.mem.eql(u8, value, "before-admission"))
                .before_admission
            else if (std.mem.eql(u8, value, "after-commit"))
                .after_commit
            else
                return error.InvalidTestDropMode;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            return error.TransferEncodingUnsupported;
        }
    }
    if (!wire_ok) return error.WrongWireVersion;
    if (!content_type_ok) return error.InvalidContentType;
    return .{ .route = route, .content_length = content_length orelse return error.MissingContentLength, .drop = drop };
}

fn renderConfigureReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ConfigureCommand,
    result: store_module.ConfigureReply,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append("\",\"replayed\":");
    try response.append(if (replayed) "true" else "false");
    try response.append(",\"session\":");
    try response.appendJsonString(command.session.slice());
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => {
            try response.append(",\"code\":\"idempotency_key_conflict\"");
        },
        .infrastructure_failure => {
            try response.append(",\"code\":\"canonical_store_failure\"");
        },
        .accepted => {},
    }
    if (result == .accepted) {
        const value = result.accepted;
        try response.appendFmt(",\"revision\":\"{d}\",\"created\":{s}", .{
            value.revision,
            if (value.created) "true" else "false",
        });
    }
    try response.append("},\"execution\":{\"status\":\"unavailable\",\"reason\":\"model_processing_enters_in_issue_171\"}}");
}

fn renderMessageReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.MessageCommand,
    result: store_module.MessageReply,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    try response.append("\",\"replayed\":");
    try response.append(if (result == .rejected and result.rejected.replayed) "true" else "false");
    try response.append(",\"session\":");
    try response.appendJsonString(command.session.slice());
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => {
            try response.append(",\"code\":\"idempotency_key_conflict\"");
        },
        .infrastructure_failure => {
            try response.append(",\"code\":\"canonical_store_failure\"");
        },
    }
    try response.append("},\"execution\":{\"status\":\"unavailable\",\"reason\":\"model_processing_enters_in_issue_171\"}}");
}

fn renderCommandObservation(
    response: *protocol.ResponseBuffer,
    key: []const u8,
    observation: store_module.CommandObservation,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"command_observation\",\"key\":");
    try response.appendJsonString(key);
    try response.append(",\"observation\":{\"status\":\"");
    try response.append(@tagName(observation.status));
    try response.append("\"");
    if (observation.status != .absent) {
        try response.append(",\"kind\":\"");
        try response.append(@tagName(observation.kind));
        try response.append("\",\"target\":");
        try response.appendJsonString(observation.target.slice());
        if (observation.code.len != 0) {
            try response.append(",\"code\":");
            try response.appendJsonString(observation.code.slice());
        }
        if (observation.status == .accepted) {
            try response.appendFmt(",\"revision\":\"{d}\",\"created\":{s}", .{
                observation.revision,
                if (observation.created) "true" else "false",
            });
        }
    }
    try response.append("}}");
}

fn renderSessionObservation(
    response: *protocol.ResponseBuffer,
    observation: store_module.SessionObservation,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"session_observation\",\"session\":");
    if (!observation.found) {
        try response.append("null,\"execution\":{\"status\":\"unavailable\",\"reason\":\"model_processing_enters_in_issue_171\"}}");
        return;
    }
    try response.append("{\"reference\":");
    try response.appendJsonString(observation.session.slice());
    try response.append(",\"workspace\":");
    try response.appendJsonString(observation.workspace.slice());
    try response.append(",\"model\":");
    try response.appendJsonString(observation.model.slice());
    try response.appendFmt(",\"revision\":\"{d}\",\"tools\":[", .{observation.revision});
    var need_comma = false;
    if (observation.tools_mask & 1 != 0) {
        try response.append("\"bash\"");
        need_comma = true;
    }
    if (observation.tools_mask & 2 != 0) {
        if (need_comma) try response.append(",");
        try response.append("\"edit\"");
    }
    try response.append("],\"permission_mode\":");
    try response.appendJsonString(observation.permission_mode.slice());
    try response.appendFmt(",\"instructions\":{{\"bytes\":\"{d}\",\"sha256\":\"", .{observation.instructions.length});
    try appendHex(response, &observation.instructions.digest);
    try response.append("\"},\"output_schema\":");
    if (observation.output_schema) |reference| {
        try response.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try appendHex(response, &reference.digest);
        try response.append("\"}");
    } else {
        try response.append("null");
    }
    try response.append("},\"execution\":{\"status\":\"unavailable\",\"reason\":\"model_processing_enters_in_issue_171\"}}");
}

fn appendHex(response: *protocol.ResponseBuffer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try response.append(&.{ alphabet[byte >> 4], alphabet[byte & 0x0f] });
    }
}

fn sendStatic(io: std.Io, fd: std.posix.fd_t, status: u16, kind: []const u8, code: []const u8) !void {
    var response: protocol.ResponseBuffer = .{};
    try response.append("{\"version\":\"1\",\"type\":");
    try response.appendJsonString(kind);
    try response.append(",\"code\":");
    try response.appendJsonString(code);
    try response.append("}");
    try writeHttp(io, fd, status, response.slice());
}

fn respondStatic(io: std.Io, fd: std.posix.fd_t, status: u16, kind: []const u8, code: []const u8) void {
    sendStatic(io, fd, status, kind, code) catch {};
}

fn deliverResponse(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8) void {
    // A delivery failure leaves the saved semantic answer recoverable. Never
    // append a second HTTP message to an already-started response.
    writeHttp(io, fd, status, body) catch {};
}

fn writeHttp(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8) !void {
    _ = io;
    const reason = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        409 => "Conflict",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        else => "Error",
    };
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\n\r\n", .{ status, reason, body.len });
    try writeAll(fd, header);
    try writeAll(fd, body);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, 60_000) == 0) return error.TransferInactive;
        const count = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0) return error.WriteFailed;
        if (count == 0) return error.ConnectionClosed;
        offset += @intCast(count);
    }
}

test "connection populations preserve eight control places" {
    try std.testing.expectEqual(max_clients, max_ordinary_clients + control_headroom);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), maximum_connection_stack_reservation_bytes);
}

test "Session observation buffer covers worst-case JSON escaping" {
    var observation: store_module.SessionObservation = .{ .found = true };
    try observation.session.set(&([_]u8{0x1f} ** protocol.max_session_bytes));
    try observation.workspace.set(&([_]u8{0x1f} ** protocol.max_workspace_bytes));
    try observation.model.set(&([_]u8{0x1f} ** protocol.max_model_bytes));
    try observation.permission_mode.set("bypass");
    observation.revision = std.math.maxInt(u64);
    observation.tools_mask = 3;
    observation.instructions = .{
        .length = std.math.maxInt(u64),
        .digest = [_]u8{0xff} ** 32,
    };
    observation.output_schema = .{
        .length = std.math.maxInt(u64),
        .digest = [_]u8{0xff} ** 32,
    };
    var response: protocol.ResponseBuffer = .{};
    try renderSessionObservation(&response, observation);
    try std.testing.expect(response.len <= protocol.max_response_bytes);
}

fn finishTestClient(host: *Host, release: *std.atomic.Value(bool), completed: *std.atomic.Value(bool)) void {
    while (!release.load(.acquire)) std.atomic.spinLoopHint();
    host.clientFinished();
    completed.store(true, .release);
}

test "shutdown drain retains stack-owned Host until active clients finish" {
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{},
    };
    host.active_clients.store(1, .release);
    var release: std.atomic.Value(bool) = .init(false);
    var completed: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, finishTestClient, .{ &host, &release, &completed });
    release.store(true, .release);
    host.drain();
    try std.testing.expect(completed.load(.acquire));
    thread.join();
}
