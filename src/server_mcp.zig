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

    pub noinline fn admit(self: *Calls, host: *Host, call: store.ReadyAction) @import("execution_turn.zig").Admission {
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
        const admission = (host.store.admitActionAttempt(call, timeout_ms, host.hooks.storeFaults(.attempt_admission)) catch |err| {
            active.destroy(host.allocator);
            fenceDispatch(host, "MCP admission", err);
            return .retry_later;
        }) orelse {
            active.destroy(host.allocator);
            return .admitted;
        };
        const binding = admission.permit.binding;
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
                    .cancelled => .cancelled,
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
    const input = try arena.create(store.ActionExecutionInput);
    try host.store.readActionExecutionInput(.mcp, active.binding, input);
    const config = for (host.mcp_servers.entries) |*server| {
        if (std.mem.eql(u8, server.name, input.runner.mcp.server.slice())) break server;
    } else {
        const text = try std.fmt.allocPrint(arena, "Failed, not run: MCP server {s} is not available (mcp_server_unavailable).", .{input.runner.mcp.server.slice()});
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
        .name = input.runner.mcp.name.slice(),
        .input_schema = try readContent(host, arena, input.runner.mcp.input_schema),
        .arguments = arguments,
        .caller = .{
            .session_id = input.session.slice(),
            .parent_session_id = if (input.runner.mcp.parent) |*parent| parent.slice() else null,
            .root_session_id = input.runner.mcp.root.slice(),
            .turn_id = turn.written(),
        },
        // JSON-RPC only correlates one request on this private connection.
        // It is not an action/call identity and never appears in _meta.
        .id = 1,
        .server_name = config.name,
        .timeout_ms = input.timeout_ms,
        .bash_offered = input.runner.mcp.bash_offered,
        .retention = .{
            .queue = host.retention,
            .action_id = active.binding.action_id,
            .attempt_ordinal = @import("attempt.zig").action_attempt_ordinal,
        },
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
    const text = @import("mcp/action_text.zig");
    var buffer: [@max(text.stop_unknown.len, text.stop_not_sent.len)]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    // The only possible stop texts both fit this exactly derived buffer.
    const code = @import("mcp/result_text.zig").write(&out, .{ .server_name = "", .ended = .{ .stopped = sent } }) catch unreachable;
    settle(host, active.binding, switch (code) {
        .cancelled => .cancelled,
        .indeterminate => .indeterminate,
        else => unreachable,
    }, out.buffered());
}

test "MCP Host call bound refuses admission before touching the Store" {
    var active: Active = .{ .binding = .{ .action_id = 1, .parent_operation_id = 1, .turn_id = 1 }, .arena = .init(std.testing.allocator) };
    defer active.arena.deinit();
    var calls: Calls = .{ .entries = @splat(&active) };
    // There is deliberately no Host/Store to consult when every local place
    // is occupied. A full scan cannot record a seventeenth attempt.
    try std.testing.expect(calls.full());
    try std.testing.expectEqual(@import("execution_turn.zig").Admission.retry_later, calls.admit(undefined, .{ .action_id = 17, .runner = .mcp, .server = .{} }));
    calls.entries[0] = null;
    try std.testing.expect(!calls.full());
}

test "MCP full output hints follow the frozen Bash offer despite later settings" {
    const store_testing = store.testing;
    const tools = @import("tools.zig");
    const wire_request = @import("wire_request.zig");
    const output_retention = @import("output_retention.zig");
    const Script = @import("mcp/test_server.zig");
    const poll = @import("test_poll");
    const gpa = std.testing.allocator;
    const records = comptime store_testing.hostToolRecordsWith(&.{.{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" }});
    var digests: [records.len][32]u8 = undefined;
    for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
    const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    const payload = try gpa.alloc(u8, @import("mcp/result_text.zig").excerpt_bytes + 1);
    defer gpa.free(payload);
    @memset(payload, 'x');
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{payload});
    defer gpa.free(body);
    const reply = try std.fmt.allocPrint(gpa, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer gpa.free(reply);
    for ([_]bool{ false, true }) |bash_offered| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store_testing.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try store.testingCanonicalCwd(std.testing.io, &workspace_buffer);
        var configure = try store_testing.completeConfiguration("mcp-output-configure", "", workspace, "model-a");
        configure.configuration.tools = try .of(if (bash_offered) &.{ "bash", "fetch_page" } else &.{"fetch_page"});
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try store_testing.submitTestMessage(&storage, &tmp, "task", "mcp-output-task", session.slice(), "fetch");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // Both adding and removing Bash after admission must be irrelevant.
        var update: wire_request.ConfigureCommand = .{ .session = session };
        try update.key.set("mcp-output-live-tools");
        update.configuration.tools = try .of(if (bash_offered) &.{"fetch_page"} else &.{ "bash", "fetch_page" });
        try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
        try store.settleCallsForTesting(&storage, &tmp, model, "mcp-output-calls", &.{.{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
        const selected = (try storage.nextAction(.mcp)).?;
        var script: Script = .{ .reply = reply };
        try script.start();
        defer script.stop();
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{script.port});
        var server_name = "docs".*;
        var token = "t".*;
        var configs = [_]Server{.{ .name = &server_name, .url = url, .token = &token, .target = try @import("http1/request.zig").parseTarget(url), .timeout_ms = 10_000 }};
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]output_retention.Entry = @splat(.{});
        var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes }, &entries);
        defer retention.cleanupAll();
        var host: Host = .{ .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = &storage, .mcp_servers = .{ .entries = &configs }, .retention = &retention };
        var calls: Calls = .{};
        defer calls.shutdown(&host);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, calls.admit(&host, selected));
        const Drive = struct {
            calls: *Calls,
            host: *Host,
            fn step(self: *@This()) !bool {
                _ = self.calls.service(self.host);
                return !self.calls.any();
            }
        };
        var drive: Drive = .{ .calls = &calls, .host = &host };
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &drive, Drive.step);
        try std.testing.expect(script.request_received.load(.acquire));
        try std.testing.expect(!storage.isFenced());
        const report = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 128 * 1024, .full);
        defer gpa.free(report);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("full").?.object.get("actions").?.array.items[0].object.get("result").?.object.get("text").?.string;
        const expected = if (bash_offered)
            try std.fmt.allocPrint(gpa, "{s}\n[1 more bytes not shown]\nFull output: {s}/mcp-output-{d}-1.tmp\n", .{ payload[0 .. payload.len - 1], root, selected.action_id })
        else
            try std.fmt.allocPrint(gpa, "{s}\n[1 more bytes not shown]", .{payload[0 .. payload.len - 1]});
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, result);
        try std.testing.expectEqual(@as(usize, @intFromBool(bash_offered)), retention.occupied());
    }
}
