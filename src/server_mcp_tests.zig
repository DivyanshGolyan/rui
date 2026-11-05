//! Host/Store boundary regressions for native MCP calls (no provider or Bash).
const std = @import("std");
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const mcp = @import("server_mcp.zig");
const Script = @import("mcp/test_server.zig");
const poll = @import("test_poll");

const records = [_]tools.Record{
    tools.record(.bash).*,
    .{ .name = "fetch_other", .owner = .mcp, .server = "other", .description = "Fetch elsewhere.", .input_schema = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" },
    .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" },
    tools.record(.message_agent).*,
    tools.record(.start_agent).*,
    tools.record(.web_search).*,
};
const digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [records.len][32]u8 = undefined;
    for (&records, &out) |*record, *digest| digest.* = tools.recordDigest(record);
    break :blk out;
};
const catalog: tools.Catalog = .{ .records = &records, .digests = &digests };
const reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"page payload\"}]}}");
const arguments = "{\"q\":\"first\",\"rui_call_description\":\"Read docs\",\"unexpected\":\"must not leave Host\"}";
const second_arguments = "{\"q\":\"second\",\"rui_call_description\":\"Read next\"}";
const Case = enum { success, serial, timeout, down, stop, shutdown, concurrent };

test "Host MCP forwards schema-only arguments and metadata into a historical continuation" {
    try run(.success);
}

test "Host MCP serializes two calls from one model reply in recorded order" {
    try run(.serial);
}

test "Host MCP timeout closes a sent request and records outcome unknown" {
    try run(.timeout);
}

test "Host MCP unavailable server records failed not run and continues" {
    try run(.down);
}

test "Host MCP Session stop closes a sent request without inventing success" {
    try run(.stop);
}

test "Host MCP shutdown closes sent socket and recovery records indeterminate without retry" {
    try run(.shutdown);
}

test "Host MCP independent Sessions progress while another Session holds a reply" {
    try run(.concurrent);
}

fn run(case: Case) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const storage = try allocator.create(store.Store);
    defer allocator.destroy(storage);
    try store.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .catalog = &catalog });
    defer storage.close() catch unreachable;
    const workspace_buffer = try allocator.create([protocol.max_workspace_bytes]u8);
    defer allocator.destroy(workspace_buffer);
    const workspace = try store.testingCanonicalCwd(std.testing.io, workspace_buffer);
    const command = try allocator.create(protocol.ConfigureCommand);
    defer allocator.destroy(command);
    command.* = try store.testingCompleteConfiguration("mcp-config", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"fetch_page"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    const configured = storage.configure(command, .{});
    try expectHere(@src(), configured == .accepted);
    const session = configured.accepted.session;
    try store.testingSubmitMessage(storage, &tmp, "mcp-message", "mcp-message", session.slice(), "fetch");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]store.TestingCall{
        .{ .item_id = "item-1", .name = "fetch_page", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"q\\\":\\\"first\\\",\\\"rui_call_description\\\":\\\"Read docs\\\",\\\"unexpected\\\":\\\"must not leave Host\\\"}", .decoded_arguments = arguments },
        .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{\\\"q\\\":\\\"second\\\",\\\"rui_call_description\\\":\\\"Read next\\\"}", .decoded_arguments = second_arguments },
    };
    const count: usize = if (case == .serial) 2 else 1;
    try store.settleCallsForTesting(storage, &tmp, binding, "mcp-calls", calls[0..count]);
    try expectHere(@src(), (try storage.admitNextActionAttempt(300_000, .{})) == null);
    try expectHere(@src(), (try storage.admitNextModelAttempt(.{})) == null);

    const script = try allocator.create(Script);
    defer allocator.destroy(script);
    script.* = .{ .reply = reply, .more = if (case == .serial) &.{reply} else &.{}, .hold_reply = case == .timeout or case == .stop or case == .shutdown or case == .concurrent };
    if (case != .down) try script.start();
    defer if (case != .down) script.stop();
    // A bound, non-listening endpoint guarantees connection refusal without
    // relying on a globally chosen unused port.
    const down_fd = if (case == .down) std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0) else -1;
    defer if (down_fd >= 0) {
        _ = std.c.close(down_fd);
    };
    if (case == .down) {
        if (down_fd < 0) return error.SocketFailed;
        var address: std.c.sockaddr.in = std.mem.zeroes(std.c.sockaddr.in);
        address.family = std.c.AF.INET;
        address.addr = @bitCast([4]u8{ 127, 0, 0, 1 });
        if (@hasField(std.c.sockaddr.in, "len")) address.len = @sizeOf(std.c.sockaddr.in);
        if (std.c.bind(down_fd, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
        var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(down_fd, @ptrCast(&address), &length) != 0) return error.NameFailed;
        script.port = std.mem.bigToNative(u16, address.port);
    }
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{script.port});
    const other_script = try allocator.create(Script);
    defer allocator.destroy(other_script);
    other_script.* = .{ .reply = reply };
    if (case == .concurrent) try other_script.start();
    defer if (case == .concurrent) other_script.stop();
    var other_url_buffer: [128]u8 = undefined;
    const other_url = try std.fmt.bufPrint(&other_url_buffer, "http://127.0.0.1:{d}/mcp", .{if (case == .concurrent) other_script.port else @as(u16, 1)});
    var servers = [_]mcp.Server{ .{ .name = @constCast("docs"), .url = url, .token = @constCast("secret"), .target = try @import("http1/request.zig").parseTarget(url), .timeout_ms = if (case == .timeout) 50 else if (case == .success) @import("mcp/servers.zig").default_timeout_ms else 5_000 }, .{ .name = @constCast("other"), .url = other_url, .token = @constCast("other-secret"), .target = try @import("http1/request.zig").parseTarget(other_url), .timeout_ms = 5_000 } };
    var custody: [1]execution.CustodyRecord = @splat(.{});
    const host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = .{ .io = std.testing.io, .allocator = allocator, .lease = undefined, .store = storage, .custody = execution.CustodyPool.initialize(&custody), .mcp_servers = .{ .entries = &servers } };
    var active: mcp.Calls = .{};
    defer active.shutdown(host);
    for (0..count) |ordinal| {
        const work = (try storage.nextCoreWork()).?;
        try expectHere(@src(), work == .mcp);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, active.admit(host, work.mcp));
        if (case != .down) {
            const input = try allocator.create(store.McpExecutionInput);
            defer allocator.destroy(input);
            try storage.readMcpExecutionInput(.{ .action_id = work.mcp.action_id, .parent_operation_id = binding.operation_id, .turn_id = binding.turn_id }, input);
            try std.testing.expectEqual(servers[0].timeout_ms, input.timeout_ms);
        }
        if (case == .serial) try expectHere(@src(), (try storage.nextCoreWork()) == null);
        const Context = struct {
            active: *mcp.Calls,
            host: *Host,
            script: *Script,
            fn done(self: @This()) bool {
                _ = self.active.service(self.host);
                return !self.active.any();
            }
            fn sent(self: @This()) bool {
                _ = self.active.service(self.host);
                return self.script.request_received.load(.acquire);
            }
        };
        const context: Context = .{ .active = &active, .host = host, .script = script };
        if (case == .concurrent) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            // A new Session is independent of the first Session's sent call.
            try command.key.set("other-config");
            command.configuration.tools = try .of(&.{"fetch_other"});
            const other_configured = storage.configure(command, .{});
            try expectHere(@src(), other_configured == .accepted);
            const other_session = other_configured.accepted.session;
            try expectHere(@src(), !std.mem.eql(u8, session.slice(), other_session.slice()));
            try store.testingSubmitMessage(storage, &tmp, "other-message", "other-message", other_session.slice(), "fetch other");
            const other_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var other_call = calls[0];
            other_call.name = "fetch_other";
            try store.settleCallsForTesting(storage, &tmp, other_binding, "other-calls", &.{other_call});
            const other_work = (try storage.nextCoreWork()).?;
            try expectHere(@src(), other_work == .mcp);
            try expectHere(@src(), other_work.mcp.action_id != work.mcp.action_id);
            try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, active.admit(host, other_work.mcp));
            const Other = struct {
                active: *mcp.Calls,
                host: *Host,
                action: u64,
                fn done(self: @This()) bool {
                    _ = self.active.service(self.host);
                    return !self.active.contains(self.action);
                }
            };
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), Other{ .active = &active, .host = host, .action = other_work.mcp.action_id }, Other.done);
            try expectHere(@src(), active.contains(work.mcp.action_id));
            try expectHere(@src(), !script.connection_closed.load(.acquire));
            const other_report = try store.testingSessionReportWithProfile(storage, &tmp, other_session.slice(), 1024 * 1024, .full);
            defer allocator.free(other_report);
            try expectHere(@src(), std.mem.indexOf(u8, other_report, "page payload") != null);
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(other_binding.turn_id, next.turn_id);
            active.shutdown(host);
            try expectHere(@src(), try storage.recoverOneUncertainAction(.empty()));
        }
        if (case == .shutdown) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            active.shutdown(host);
            try expectHere(@src(), try storage.recoverOneUncertainAction(.empty()));
            try expectHere(@src(), !try storage.recoverOneUncertainAction(.empty()));
            try expectHere(@src(), (try storage.nextCoreWork()) == null);
        }
        if (case == .stop) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            var stop: protocol.SessionStopCommand = .{};
            try stop.key.set("mcp-stop");
            stop.session = session;
            try expectHere(@src(), storage.stopSession(&stop, .{}) == .accepted);
        }
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.done);
        if (case != .down) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), &script.request_received, poll.isSet);
            const seen = script.seen[0..script.seen_len];
            const body_start = (std.mem.indexOf(u8, seen, "\r\n\r\n") orelse return error.MissingHttpBody) + 4;
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, seen[body_start..], .{});
            defer parsed.deinit();
            const body = parsed.value.object;
            try std.testing.expectEqual(@as(i64, 1), body.get("id").?.integer);
            try std.testing.expectEqualStrings("tools/call", body.get("method").?.string);
            const params = body.get("params").?.object;
            const args = params.get("arguments").?.object;
            try std.testing.expectEqual(@as(usize, 1), args.count());
            try std.testing.expectEqualStrings(if (ordinal == 0) "first" else "second", args.get("q").?.string);
            const meta = params.get("_meta").?.object;
            try std.testing.expectEqual(@as(usize, 6), meta.count());
            try expectHere(@src(), meta.get("dev.rui/parentSessionId") == null);
            try std.testing.expectEqualStrings(session.slice(), meta.get("dev.rui/sessionId").?.string);
            try std.testing.expectEqualStrings(session.slice(), meta.get("dev.rui/rootSessionId").?.string);
            var turn_buffer: [32]u8 = undefined;
            const turn = try std.fmt.bufPrint(&turn_buffer, "{d}", .{binding.turn_id});
            try std.testing.expectEqualStrings(turn, meta.get("dev.rui/turnId").?.string);
        }
        if (ordinal + 1 < count) try expectHere(@src(), (try storage.admitNextModelAttempt(.{})) == null);
    }
    if (case == .timeout or case == .stop or case == .shutdown or case == .concurrent) {
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), &script.connection_closed, poll.isSet);
    }
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    const expected = switch (case) {
        .success, .serial => "page payload",
        .timeout, .stop => "Outcome unknown",
        .shutdown, .concurrent => "Outcome unknown",
        .down => "Failed, not run",
    };
    const report = try store.testingSessionReportWithProfile(storage, &tmp, session.slice(), 1024 * 1024, .full);
    defer allocator.free(report);
    try expectHere(@src(), std.mem.indexOf(u8, report, expected) != null);
    if (case == .stop) return;
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
    const view = try allocator.create(store.HistoricalView);
    defer allocator.destroy(view);
    try storage.openHistoricalView(continuation, view);
    defer if (view.isActive()) view.close();
    var position: u64 = 0;
    var found: usize = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        if (entry.kind != .tool_results) continue;
        while (try view.nextToolResult()) |result| {
            var reader: store.HistoricalReader = undefined;
            try view.openContent(result.output, &reader);
            defer reader.close();
            const bytes = try allocator.alloc(u8, @intCast(result.output.length));
            defer allocator.free(bytes);
            try std.testing.expectEqual(bytes.len, try reader.read(0, bytes));
            try expectHere(@src(), std.mem.indexOf(u8, bytes, expected) != null);
            found += 1;
        }
    }
    try std.testing.expectEqual(count, found);
    view.close();
    try expectNextRequest(storage, &tmp, continuation, expected, count);
}

// Assert the sealed provider request, not merely a report projection: the
// model's next input must include each MCP Tool Result and its original id.
fn expectNextRequest(storage: *store.Store, tmp: *std.testing.TmpDir, binding: store.AttemptBinding, expected: []const u8, count: usize) !void {
    const allocator = std.testing.allocator;
    const adapter = @import("model_adapter.zig");
    const preparation = try allocator.create(adapter.Preparation);
    defer allocator.destroy(preparation);
    const root_buffer = try allocator.create([protocol.max_store_bytes]u8);
    defer allocator.destroy(root_buffer);
    const root_length = try tmp.dir.realPath(std.testing.io, root_buffer);
    const root = root_buffer[0..root_length];
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?@import("named_scratch.zig").Owner = null;
    defer if (retained) |*owner| {
        _ = owner.reclaim(root) catch unreachable;
    };
    try storage.openHistoricalView(binding, &preparation.view);
    try preparation.init(std.testing.io, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
    defer if (preparation.state.active) preparation.cancel();
    // A runaway guard on bounded nonblocking work, not a scheduler wait.
    var advances: usize = 0;
    while (true) {
        advances += 1;
        try expectHere(@src(), advances < 16384);
        switch (preparation.advance(16384, 64)) {
            .pending => {},
            .failed => |err| return err,
            .prepared => |request| {
                defer request.deinit(std.testing.io, preparation.writer.budget);
                const bytes = try allocator.alloc(u8, @intCast(request.length));
                defer allocator.free(bytes);
                try std.testing.expectEqual(bytes.len, try request.file.readPositionalAll(std.testing.io, bytes, 0));
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
                defer parsed.deinit();
                var found: usize = 0;
                for (parsed.value.object.get("input").?.array.items) |item| {
                    const kind = item.object.get("type") orelse continue;
                    if (!std.mem.eql(u8, kind.string, "function_call_output")) continue;
                    try expectHere(@src(), found < count);
                    try std.testing.expectEqualStrings(if (found == 0) "call-1" else "call-2", item.object.get("call_id").?.string);
                    const output = item.object.get("output").?.string;
                    try expectHere(@src(), std.mem.indexOf(u8, output, expected) != null);
                    found += 1;
                }
                try std.testing.expectEqual(count, found);
                break;
            },
        }
    }
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

fn expectHere(source: std.builtin.SourceLocation, condition: bool) !void {
    if (!condition) {
        std.debug.print("MCP regression assertion at {s}:{d}\n", .{ source.file, source.line });
        return error.TestUnexpectedResult;
    }
}
