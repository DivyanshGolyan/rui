//! Execution-thread ownership of MCP calls. The Store owns admission and
//! settlement; these bounded owners hold only a live socket and borrowed input.
const std = @import("std");
const Host = @import("server_host.zig").Host;
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const Running = @import("mcp/Running.zig");
const offered = @import("mcp/offered.zig");
const fenceDispatch = @import("server_host.zig").fenceDispatch;

pub const Server = @import("mcp/servers.zig").Server;
pub const Servers = @import("mcp/servers.zig").Servers;

// Each live call reserves a 4 MiB answer buffer. Sixteen bounds that storage
// at 64 MiB while allowing independent Sessions to make concurrent progress.
pub const capacity = 16;

const Active = struct {
    binding: store.ActionAttemptBinding,
    arena: std.heap.ArenaAllocator,
    running: Running = undefined,
    started: bool = false,

    fn destroy(self: *Active, allocator: std.mem.Allocator) void {
        if (self.started) self.running.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const Calls = struct {
    entries: [capacity]?*Active = @splat(null),

    pub fn any(self: *const Calls) bool {
        for (self.entries) |entry| if (entry != null) return true;
        return false;
    }

    pub fn full(self: *const Calls) bool {
        for (self.entries) |entry| if (entry == null) return false;
        return true;
    }

    pub fn contains(self: *const Calls, action_id: u64) bool {
        for (self.entries) |entry| if (entry) |active| {
            if (active.binding.action_id == action_id) return true;
        };
        return false;
    }

    pub noinline fn admit(self: *Calls, host: *Host, call: store.McpAction) @import("execution_turn.zig").Admission {
        var place: ?*?*Active = null;
        for (&self.entries) |*entry| if (entry.* == null) {
            place = entry;
            break;
        };
        const entry = place orelse return .retry_later;
        // Reserve the local owner before the durable attempt. After that
        // commit every failure either settles or fences, never retries.
        const active = host.allocator.create(Active) catch return .retry_later;
        active.* = .{ .binding = undefined, .arena = .init(host.allocator) };
        const timeout_ms = for (host.mcp_servers.entries) |*server| {
            if (std.mem.eql(u8, server.name, call.server.slice())) break server.timeout_ms;
        } else @import("mcp/servers.zig").default_timeout_ms;
        const binding = (host.store.admitMcpActionAttempt(call.action_id, timeout_ms, host.hooks.storeFaults(.attempt_admission)) catch |err| {
            active.destroy(host.allocator);
            fenceDispatch(host, "MCP admission", err);
            return .retry_later;
        }) orelse {
            active.destroy(host.allocator);
            return .admitted;
        };
        active.binding = binding;
        prepare(host, active) catch |err| {
            // A canonical read fault fences dispatch; a local resource failure
            // is a definite not-sent outcome. Neither can launch a second try.
            if (host.store.isFenced()) fenceDispatch(host, "MCP input", err) else settle(host, binding, .spawn_failed, "Failed, not run: the Host could not prepare this MCP call.");
            active.destroy(host.allocator);
            return .admitted;
        };
        if (!active.started) {
            active.destroy(host.allocator);
            return .admitted;
        }
        entry.* = active;
        return .admitted;
    }

    /// Every loop services every ready call without blocking. Readiness is a
    /// hint only; Running owns partial writes, parsing and its absolute timer.
    pub fn service(self: *Calls, host: *Host) bool {
        var progress = false;
        for (&self.entries) |*entry| if (entry.*) |active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "MCP stop reconciliation", err);
                return progress;
            };
            if (stopped != null) {
                cancel(host, active);
                active.destroy(host.allocator);
                entry.* = null;
                progress = true;
                continue;
            }
            const now = nowMs(host);
            const fd = active.running.fd();
            if (fd >= 0 and now < active.running.deadlineMs()) {
                var poll: std.c.pollfd = .{ .fd = fd, .events = active.running.events(), .revents = 0 };
                const ready = std.c.poll(@ptrCast(&poll), 1, 0);
                // Running owns socket errors; even a failed poll is serviced
                // there rather than mistaking it for an empty readiness set.
                if (ready == 0) continue;
            }
            var out: std.Io.Writer.Allocating = .init(host.allocator);
            defer out.deinit();
            var code: ?@import("mcp/result_text.zig").Code = null;
            if (!active.running.requestSent()) {
                // Until the first byte, Store stop selection and the Host's
                // launch gate must stay ordered before the external effect.
                host.store.withActionDispatchHandoff(active.binding, .{ .host = host, .active = active, .now = now, .out = &out.writer, .code = &code }, struct {
                    fn handoff(context: anytype) !void {
                        try context.host.withEffectLaunch(context, send);
                    }
                    fn send(context: anytype) !void {
                        context.code.* = try context.active.running.service(context.now, context.out);
                    }
                }.handoff) catch |err| {
                    switch (err) {
                        error.SupersededByControl => cancel(host, active),
                        // Like Bash, Host shutdown leaves the attempt uncertain.
                        error.HostDispatchSuppressed => {},
                        else => fenceDispatch(host, "MCP dispatch", err),
                    }
                    active.destroy(host.allocator);
                    entry.* = null;
                    progress = true;
                    continue;
                };
            } else {
                code = active.running.service(now, &out.writer) catch |err| {
                    fenceDispatch(host, "MCP result rendering", err);
                    active.destroy(host.allocator);
                    entry.* = null;
                    return true;
                };
            }
            if (code) |result| {
                settle(host, active.binding, switch (result) {
                    .succeeded => .succeeded,
                    .failed => .failed,
                    .spawn_failed => .spawn_failed,
                    .indeterminate => .indeterminate,
                }, out.written());
                active.destroy(host.allocator);
                entry.* = null;
                progress = true;
            }
        };
        return progress;
    }

    /// Like Bash shutdown, discard socket evidence and leave an unresolved
    /// attempt for recovery, rather than inventing a semantic result.
    pub fn shutdown(self: *Calls, host: *Host) void {
        for (&self.entries) |*entry| if (entry.*) |active| {
            active.destroy(host.allocator);
            entry.* = null;
        };
    }
};

fn nowMs(host: *const Host) u64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds, std.time.ns_per_ms));
}

fn settle(host: *Host, binding: store.ActionAttemptBinding, code: store.ActionResolutionCode, text: []const u8) void {
    _ = host.store.settleActionAttempt(binding, code, text, host.hooks.storeFaults(.action_result)) catch |err| {
        fenceDispatch(host, "MCP settlement", err);
    };
}

noinline fn prepare(host: *Host, active: *Active) !void {
    const arena = active.arena.allocator();
    // This input is canonical and potentially kilobytes; keep its one address
    // with the call rather than copying it through the Host thread's frame.
    const input = try arena.create(store.McpExecutionInput);
    try host.store.readMcpExecutionInput(active.binding, input);
    const config = for (host.mcp_servers.entries) |*server| {
        if (std.mem.eql(u8, server.name, input.server.slice())) break server;
    } else {
        const text = try std.fmt.allocPrint(arena, "Failed, not run: MCP server {s} is not available (mcp_server_unavailable).", .{input.server.slice()});
        settle(host, active.binding, .spawn_failed, text);
        return;
    };
    const arguments = try readContent(host, arena, input.arguments);
    // The API writes Session references as their stored six-character string
    // (protocol.SessionRow); Turn ids use its decimal Hole, without a prefix.
    var turn: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeShape(&turn.writer, .{protocol.Hole.decimal}, .{active.binding.turn_id});
    try active.running.start(host.allocator, .{
        .server = .{ .target = config.target, .bearer_token = config.token },
        .client = offered.client,
        .name = input.name.slice(),
        .input_schema = try readContent(host, arena, input.input_schema),
        .arguments = arguments,
        .caller = .{
            .session_id = input.session.slice(),
            .parent_session_id = if (input.parent) |*parent| parent.slice() else null,
            .root_session_id = input.root.slice(),
            .turn_id = turn.written(),
        },
        // JSON-RPC only correlates one request on this private connection.
        // It is not an action/call identity and never appears in _meta.
        .id = 1,
        .server_name = config.name,
        .timeout_ms = input.timeout_ms,
    }, nowMs(host));
    active.started = true;
}

fn readContent(host: *Host, allocator: std.mem.Allocator, reference: store.ContentReference) ![]const u8 {
    const bytes = try allocator.alloc(u8, std.math.cast(usize, reference.length) orelse return error.OutOfMemory);
    var reader: store.ContentReader = undefined;
    reader.open(try host.store.openContent(reference));
    defer reader.close();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + store.ContentReader.content_window_bytes);
        const count = try reader.read(offset, bytes[offset..end]);
        if (count == 0) return error.ShortCanonicalRead;
        offset += count;
    }
    return bytes;
}

fn cancel(host: *Host, active: *Active) void {
    const sent = active.running.requestSent();
    active.running.deinit();
    settle(host, active.binding, .cancelled, if (sent)
        store.mcp_stop_unknown_text
    else
        store.mcp_stop_not_sent_text);
}

test "MCP Host call bound refuses admission before touching the Store" {
    var active: Active = .{ .binding = .{ .action_id = 1, .parent_operation_id = 1, .turn_id = 1 }, .arena = .init(std.testing.allocator) };
    defer active.arena.deinit();
    var calls: Calls = .{ .entries = @splat(&active) };
    // There is deliberately no Host/Store to consult when every local place
    // is occupied. A full scan cannot record a seventeenth attempt.
    try std.testing.expect(calls.full());
    try std.testing.expectEqual(@import("execution_turn.zig").Admission.retry_later, calls.admit(undefined, .{ .action_id = 17, .server = .{} }));
    calls.entries[0] = null;
    try std.testing.expect(!calls.full());
}
