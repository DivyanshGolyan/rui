const std = @import("std");
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const tools = @import("tools.zig");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const mcp = @import("server_mcp.zig");
const Script = @import("mcp/test_server.zig");
const poll = @import("test_poll");

const records = blk: {
    var out = tools.built_in_tool_set.records[0..tools.built_in_tool_set.records.len].* ++ [_]tools.Record{
        .{ .name = "fetch_other", .owner = .mcp, .server = "other", .description = "Fetch elsewhere.", .input_schema = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" },
        .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}" },
    };
    std.mem.sort(tools.Record, &out, {}, struct {
        fn lessThan(_: void, a: tools.Record, b: tools.Record) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    break :blk out;
};
const digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [records.len][32]u8 = undefined;
    for (&records, &out) |*record, *digest| digest.* = tools.recordDigest(record);
    break :blk out;
};
const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
const reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"page payload\"}]}}");
const arguments = "{\"q\":\"first\",\"rui_call_description\":\"Read docs\",\"unexpected\":\"must not leave Host\"}";
const second_arguments = "{\"q\":\"second\",\"rui_call_description\":\"Read next\"}";
const image_png = @embedFile("codecs/fixtures/image-input/pixel.png");
const image_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
const image_reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"before\"},{\"type\":\"image\",\"data\":\"" ++ image_b64 ++ "\",\"mimeType\":\"image/png\"},{\"type\":\"text\",\"text\":\"after\"}]}}");
const bad_image_reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"image\",\"data\":\"not-base64-secret\",\"mimeType\":\"image/png\"}]}}");
const Case = enum { success, image, image_bad, image_exhausted, image_stop_race, retention_saved, retention_refused, retention_tight, retention_no_bash, retention_settlement_failure, retention_settlement_unlink_failure, two_calls, timeout, down, stop, stop_unsent, shutdown, concurrent };

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;

test "Host MCP forwards schema-only arguments and metadata into a historical continuation" {
    try run(.success);
}

test "Host MCP settles image parts on the original call" {
    try run(.image);
}

test "Host MCP malformed image settles canonical text without base64" {
    try run(.image_bad);
}

test "Host MCP image scratch exhaustion settles storage failure without fencing" {
    try run(.image_exhausted);
}

test "Host MCP definite image settlement survives an earlier Session stop" {
    try run(.image_stop_race);
}

test "Host MCP retains sanitized full image output only when Bash is offered" {
    try run(.retention_saved);
    try run(.retention_refused);
    try run(.retention_tight);
    try run(.retention_no_bash);
}

test "Host MCP releases a retained result when settlement fails" {
    try run(.retention_settlement_failure);
    try run(.retention_settlement_unlink_failure);
}

test "Host MCP offers the second call of one model reply while the first runs" {
    try run(.two_calls);
}

test "Host MCP timeout closes a sent request and records outcome unknown" {
    try run(.timeout);
}

test "Host MCP unavailable server records failed not run and continues" {
    try run(.down);
}

test "Host MCP Session stop after send preserves indeterminate through Action settlement" {
    try run(.stop);
    try run(.stop_unsent);
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
    try store.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
    defer storage.close() catch unreachable;
    const workspace_buffer = try allocator.create([protocol.max_workspace_bytes]u8);
    defer allocator.destroy(workspace_buffer);
    const workspace = try store.testingCanonicalCwd(std.testing.io, workspace_buffer);
    const command = try allocator.create(wire_request.ConfigureCommand);
    defer allocator.destroy(command);
    command.* = try store.testingCompleteConfiguration("mcp-config", "", workspace, "model-a");
    const retention_case = case == .retention_saved or case == .retention_refused or case == .retention_tight or case == .retention_no_bash or case == .retention_settlement_failure or case == .retention_settlement_unlink_failure;
    command.configuration.tools = try .of(if (case == .retention_saved or case == .retention_refused or case == .retention_tight or case == .retention_settlement_failure or case == .retention_settlement_unlink_failure) &.{ "bash", "fetch_page" } else &.{"fetch_page"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("bypass");
    const configured = try storage.configure(command, .{});
    try expectHere(@src(), configured == .accepted);
    const session = configured.accepted.session;
    try store.testingSubmitMessage(storage, &tmp, "mcp-message", "mcp-message", session.slice(), "fetch");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]store.TestingCall{
        .{ .item_id = "item-1", .name = "fetch_page", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"q\\\":\\\"first\\\",\\\"rui_call_description\\\":\\\"Read docs\\\",\\\"unexpected\\\":\\\"must not leave Host\\\"}", .decoded_arguments = arguments },
        .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{\\\"q\\\":\\\"second\\\",\\\"rui_call_description\\\":\\\"Read next\\\"}", .decoded_arguments = second_arguments },
    };
    const count: usize = if (case == .two_calls) 2 else 1;
    try store.settleCallsForTesting(storage, &tmp, binding, "mcp-calls", calls[0..count]);
    try expectHere(@src(), (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
    try expectHere(@src(), (try storage.admitNextModelAttempt(.{})) == null);

    const long_text = try allocator.alloc(u8, @import("mcp/result_text.zig").excerpt_bytes + 37);
    defer allocator.free(long_text);
    @memset(long_text, 'x');
    const retention_body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"start\"}},{{\"type\":\"image\",\"data\":\"not-base64-secret\",\"mimeType\":\"image/png\"}},{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}},{{\"type\":\"text\",\"text\":\"{s}END-OF-TEXT\"}}]}}}}", .{ image_b64, long_text });
    defer allocator.free(retention_body);
    const retention_reply = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ retention_body.len, retention_body });
    defer allocator.free(retention_reply);
    const script = try allocator.create(Script);
    defer allocator.destroy(script);
    script.* = .{ .reply = if (retention_case) retention_reply else if (case == .image_bad) bad_image_reply else if (case == .image or case == .image_exhausted or case == .image_stop_race) image_reply else reply, .more = if (case == .two_calls) &.{reply} else &.{}, .hold_reply = case == .timeout or case == .stop or case == .image_stop_race or case == .shutdown or case == .concurrent };
    if (case != .down) try script.start();
    defer if (case != .down) script.stop();
    if (case == .down) script.port = try @import("socket_fixture.zig").refusedPort();
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{script.port});
    const other_script = try allocator.create(Script);
    defer allocator.destroy(other_script);
    other_script.* = .{ .reply = reply };
    if (case == .concurrent) try other_script.start();
    defer if (case == .concurrent) other_script.stop();
    var other_url_buffer: [128]u8 = undefined;
    const other_url = try std.fmt.bufPrint(&other_url_buffer, "http://127.0.0.1:{d}/mcp", .{if (case == .concurrent) other_script.port else @as(u16, 1)});
    const timeout_ms: u64 = switch (case) {
        .timeout, .down => 50,
        .success => @import("mcp/servers.zig").default_timeout_ms,
        else => 5_000,
    };
    var servers = [_]mcp.Server{ .{ .name = @constCast("docs"), .url = url, .token = @constCast("secret"), .target = try @import("http1/request.zig").parseTarget(url), .timeout_ms = timeout_ms }, .{ .name = @constCast("other"), .url = other_url, .token = @constCast("other-secret"), .target = try @import("http1/request.zig").parseTarget(other_url), .timeout_ms = 5_000 } };
    const retention = @import("output_retention.zig");
    const root_buffer = try allocator.create([protocol.max_store_bytes]u8);
    defer allocator.destroy(root_buffer);
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var retained: [2]retention.Entry = @splat(.{});
    var remove_gate: std.atomic.Value(bool) = .init(case == .retention_settlement_unlink_failure);
    var queue = retention.Queue.initializeWithRemoval(std.testing.io, root, .{ .used = &used, .limit = if (case == .image_exhausted) 0 else if (case == .retention_tight) 16 * 1024 else 8 * 1024 * 1024 }, retained[0..(if (case == .retention_refused) 0 else retained.len)], .{ .gated = &remove_gate });
    defer {
        remove_gate.store(false, .release);
        queue.cleanupAll();
    }
    var custody: [2]execution.CustodyRecord = @splat(.{});
    const host = try allocator.create(Host);
    defer allocator.destroy(host);
    host.* = .{ .io = std.testing.io, .allocator = allocator, .lease = undefined, .store = storage, .custody = execution.CustodyPool.initialize(custody[0..(if (case == .concurrent) 2 else 1)]), .mcp_servers = .{ .entries = &servers }, .retention = &queue };
    var host_parts: TestParts = undefined;
    host_parts.attach(host, null);
    if (case == .retention_settlement_failure or case == .retention_settlement_unlink_failure) host.hooks.failures.insert(.result_before_commit);
    var active: mcp.Calls = .{};
    defer {
        _ = host.lifecycle.advance(.stopping);
        active.shutdown(host);
    }
    var action_binding: store.ActionAttemptBinding = undefined;
    for (0..count) |ordinal| {
        const work = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?;
        try expectHere(@src(), work == .mcp);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, active.admit(host, work.mcp));
        if (case == .image or case == .image_exhausted) action_binding = active.entries[0].?.binding;
        if (case != .down) {
            const input = try allocator.create(store.ActionExecutionInput);
            defer allocator.destroy(input);
            try storage.readActionExecutionInput(.mcp, .{ .action_id = work.mcp.action_id, .parent_operation_id = binding.operation_id, .turn_id = binding.turn_id }, input);
            try std.testing.expectEqual(servers[0].timeout_ms, input.timeout_ms);
        }
        if (case == .two_calls and ordinal == 0) try std.testing.expectEqual(work.mcp.action_id + 1, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.mcp.action_id);
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
        if (case == .image_stop_race) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            const stopped_binding = active.entries[0].?.binding;
            var stop: protocol.SessionStopCommand = .{};
            try stop.key.set("mcp-image-stop");
            stop.session = session;
            try expectHere(@src(), storage.stopSession(&stop, .{}) == .accepted);
            // Model a completed image arriving just after the stop committed.
            try std.testing.expectEqual(store.ActionSettlement.Outcome.session_stop, (try settleImageParts(storage, &tmp, stopped_binding)).outcome);
            _ = host.lifecycle.advance(.stopping);
            active.shutdown(host);
            try std.testing.expectEqual(@as(u64, 1), try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM content WHERE digest=?1 AND byte_length=?2", .{ store.testing.Blob{ .bytes = &protocol.contentDigest(image_png) }, image_png.len }));
            return;
        }
        if (case == .concurrent) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            try command.key.set("other-config");
            command.configuration.tools = try .of(&.{"fetch_other"});
            const other_configured = try storage.configure(command, .{});
            try expectHere(@src(), other_configured == .accepted);
            const other_session = other_configured.accepted.session;
            try expectHere(@src(), !std.mem.eql(u8, session.slice(), other_session.slice()));
            try store.testingSubmitMessage(storage, &tmp, "other-message", "other-message", other_session.slice(), "fetch other");
            const other_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var other_call = calls[0];
            other_call.name = "fetch_other";
            try store.settleCallsForTesting(storage, &tmp, other_binding, "other-calls", &.{other_call});
            const other_work = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?;
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
            _ = host.lifecycle.advance(.stopping);
            active.shutdown(host);
            try expectHere(@src(), try storage.recoverOneUncertainAction(.empty()));
        }
        if (case == .shutdown) {
            try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            _ = host.lifecycle.advance(.stopping);
            active.shutdown(host);
            try expectHere(@src(), try storage.recoverOneUncertainAction(.empty()));
            try expectHere(@src(), !try storage.recoverOneUncertainAction(.empty()));
            try expectHere(@src(), (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
        }
        if (case == .stop or case == .stop_unsent) {
            if (case == .stop) try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.sent);
            var stop: protocol.SessionStopCommand = .{};
            try stop.key.set("mcp-stop");
            stop.session = session;
            try expectHere(@src(), storage.stopSession(&stop, .{}) == .accepted);
        }
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(5)), context, Context.done);
        if (case != .down and case != .stop_unsent) {
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
    if (case == .retention_settlement_failure or case == .retention_settlement_unlink_failure) {
        try std.testing.expect(storage.isFenced());
        try std.testing.expect(!host.lifecycle.launchAllowed());
        var filename_buffer: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buffer, "mcp-output-{d}-1.tmp", .{try store.testing.sqlite_only.queryU64(storage, "SELECT action_id FROM action_operation", .{})});
        if (case == .retention_settlement_unlink_failure) {
            const stat = try tmp.dir.statFile(std.testing.io, filename, .{});
            try std.testing.expect(stat.size > 0);
            try std.testing.expectEqual(stat.size, used.load(.acquire));
            try std.testing.expectEqual(@as(usize, 1), queue.occupied());
            remove_gate.store(false, .release);
            queue.cleanupAll();
        }
        try std.testing.expectEqual(@as(usize, 0), queue.occupied());
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, filename, .{}));
        try storage.close();
        try store.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
        try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
        try std.testing.expect(!try storage.recoverOneUncertainAction(.empty()));
        try std.testing.expectEqual(@as(u64, 1), try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code='indeterminate'", .{}));
        return;
    }
    if (retention_case) {
        try std.testing.expect(host.lifecycle.launchAllowed());
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(@as(u64, 1), try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'", .{}));
        try std.testing.expectEqual(@as(usize, @intFromBool(case == .retention_saved)), queue.occupied());
        var path_buffer: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&path_buffer, "mcp-output-{d}-1.tmp", .{(try store.testing.sqlite_only.queryU64(storage, "SELECT action_id FROM action_operation", .{}))});
        if (case == .retention_saved) {
            const contents = try tmp.dir.readFileAlloc(std.testing.io, filename, allocator, .limited(1024 * 1024));
            defer allocator.free(contents);
            try std.testing.expect(std.mem.indexOf(u8, contents, long_text) != null);
            try std.testing.expect(std.mem.indexOf(u8, contents, "END-OF-TEXT") != null);
            try std.testing.expect(std.mem.indexOf(u8, contents, "[Image unavailable: invalid base64]") != null);
            try std.testing.expect(std.mem.indexOf(u8, contents, "[Image]") != null);
            try std.testing.expect(std.mem.indexOf(u8, contents, image_b64) == null);
            try std.testing.expect(std.mem.indexOf(u8, contents, "not-base64-secret") == null);
        } else {
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, filename, .{}));
        }
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try expectNextRequest(storage, &tmp, continuation, "", 1, true, case);
        return;
    }
    if (case == .image or case == .image_bad or case == .image_exhausted) {
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expect(host.lifecycle.launchAllowed());
        try std.testing.expect(!storage.isFenced());
        const sql = store.testing.sqlite_only;
        const code = if (case == .image_exhausted) "storage_failed" else "succeeded";
        try std.testing.expectEqual(@as(u64, 1), try sql.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code=?1", .{code}));
        if (case == .image) {
            try std.testing.expectEqual(@as(u64, 1), try sql.queryU64(storage, "SELECT count(*) FROM content WHERE digest=?1 AND byte_length=?2", .{ store.testing.Blob{ .bytes = &protocol.contentDigest(image_png) }, image_png.len }));
            try std.testing.expectEqual(@as(u64, 1), try sql.queryU64(storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE c.form=1", .{}));
        }
        if (case == .image_exhausted) {
            const text = @import("result_fault.zig").storage_failed_text;
            try std.testing.expectEqualStrings("The Host's scratch storage filled while saving this result.", text);
            try std.testing.expectEqual(@as(u64, 1), try sql.queryU64(storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='storage_failed' AND c.form=0 AND c.byte_length=?2 AND c.digest=?3", .{ action_binding.action_id, text.len, store.testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
            try std.testing.expect(!(try storage.recoverOneUncertainAction(.empty())));
        }
        if (case == .image_bad) {
            try std.testing.expectEqual(@as(u64, 1), try sql.queryU64(storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE c.form=0", .{}));
            const report = try store.testingSessionReportWithProfile(storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer allocator.free(report);
            try std.testing.expect(std.mem.indexOf(u8, report, "not-base64-secret") == null);
            try std.testing.expect(std.mem.indexOf(u8, report, "invalid base64") != null);
        }
        if (case == .image) {
            // A second image settlement with the already resolved binding is stale.
            try std.testing.expectError(error.StaleActionAttemptBinding, settleImageParts(storage, &tmp, action_binding));
            try std.testing.expect(!storage.isFenced());
        }
        if (case == .image) {
            // Reopen the Store before selecting work or preparing the continuation.
            // The persisted image must be replayed without dispatching MCP again.
            try storage.close();
            try store.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
        }
        try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
        if (case == .image) {
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
            try expectNextRequest(storage, &tmp, continuation, "", 1, true, null);
        }
        return;
    }
    const expected = switch (case) {
        .success, .two_calls => "page payload",
        .image, .image_bad, .image_exhausted, .image_stop_race, .retention_saved, .retention_refused, .retention_tight, .retention_no_bash, .retention_settlement_failure, .retention_settlement_unlink_failure => unreachable,
        .timeout, .stop => "Outcome unknown",
        .stop_unsent => "not sent",
        .shutdown, .concurrent => "Outcome unknown",
        .down => "Failed, not run",
    };
    const report = try store.testingSessionReportWithProfile(storage, &tmp, session.slice(), 1024 * 1024, .full);
    defer allocator.free(report);
    try expectHere(@src(), std.mem.indexOf(u8, report, expected) != null);
    if (case == .stop or case == .stop_unsent) {
        const indeterminate_count = try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code='indeterminate'", .{});
        try std.testing.expectEqual(@as(u64, if (case == .stop) 1 else 0), indeterminate_count);
        const cancelled_count = try store.testing.sqlite_only.queryU64(storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{});
        try std.testing.expectEqual(@as(u64, if (case == .stop_unsent) 1 else 0), cancelled_count);
        if (case == .stop) try expectHere(@src(), std.mem.indexOf(u8, report, "not retried") != null);
        if (case == .stop_unsent) try std.testing.expect(!script.request_received.load(.acquire));
        try expectHere(@src(), (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
        return;
    }
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
    const view = try allocator.create(store.testing.TestingPage);
    defer allocator.destroy(view);
    view.open(storage, continuation);
    defer if (view.isActive()) view.close();
    var position: u64 = 0;
    var found: usize = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        if (entry.kind != .tool_results) continue;
        while (try view.nextToolResult()) |result| {
            var reader: store.testing.TestingReader = undefined;
            try view.openContent(result.output.?, &reader);
            defer reader.close();
            const bytes = try allocator.alloc(u8, @intCast(result.output.?.length));
            defer allocator.free(bytes);
            try std.testing.expectEqual(bytes.len, try reader.read(0, bytes));
            try expectHere(@src(), std.mem.indexOf(u8, bytes, expected) != null);
            found += 1;
        }
    }
    try std.testing.expectEqual(count, found);
    view.close();
    try expectNextRequest(storage, &tmp, continuation, expected, count, false, null);
}

fn settleImageParts(storage: *store.Store, tmp: *std.testing.TmpDir, binding: store.ActionAttemptBinding) !store.ActionSettlement {
    const Capture = @import("InputCapture.zig");
    var used: std.atomic.Value(u64) = .init(0);
    var capture: Capture = undefined;
    {
        const spool = try tmp.dir.createFile(std.testing.io, "mcp-test-spool", .{ .read = true });
        errdefer spool.close(std.testing.io);
        const index = try tmp.dir.createFile(std.testing.io, "mcp-test-index", .{ .read = true });
        errdefer index.close(std.testing.io);
        try tmp.dir.deleteFile(std.testing.io, "mcp-test-spool");
        try tmp.dir.deleteFile(std.testing.io, "mcp-test-index");
        capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 1024 * 1024 });
    }
    defer capture.close();
    try capture.begin(.{ .image = .{ .assertion = .png } }, image_png.len);
    var offset: usize = 0;
    while (offset < image_png.len) {
        var allowance = image_png.len - offset;
        offset += try capture.append(image_png[offset..], &allowance, false);
    }
    try capture.end();
    return storage.settleActionAttemptParts(binding, .succeeded, try capture.seal(), .{});
}

fn expectNextRequest(storage: *store.Store, tmp: *std.testing.TmpDir, binding: store.AttemptBinding, expected: []const u8, count: usize, image: bool, retention_case: ?Case) !void {
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
    preparation.page.open(binding);
    try preparation.init(std.testing.io, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
    defer if (preparation.state.active) preparation.cancel();
    var advances: usize = 0;
    while (true) {
        advances += 1;
        try expectHere(@src(), advances < 16384);
        var progress = preparation.advance(16384, 64);
        while (progress == .read) {
            try storage.readRequestPage(&preparation.page);
            progress = preparation.proceed();
        }
        switch (progress) {
            .read => unreachable,
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
                    const output = item.object.get("output").?;
                    if (image) {
                        const parts = output.array.items;
                        try std.testing.expectEqual(@as(usize, 3), parts.len);
                        try std.testing.expectEqualStrings("input_text", parts[0].object.get("type").?.string);
                        const first = parts[0].object.get("text").?.string;
                        if (retention_case != null) {
                            try std.testing.expect(std.mem.indexOf(u8, first, "[Image unavailable: invalid base64]") != null);
                            try std.testing.expect(std.mem.indexOf(u8, first, "not-base64-secret") == null);
                        } else try std.testing.expectEqualStrings("before", first);
                        try std.testing.expectEqualStrings("input_image", parts[1].object.get("type").?.string);
                        try std.testing.expectEqualStrings("data:image/png;base64," ++ image_b64, parts[1].object.get("image_url").?.string);
                        try std.testing.expectEqualStrings("input_text", parts[2].object.get("type").?.string);
                        const last = parts[2].object.get("text").?.string;
                        if (retention_case) |rc| {
                            try std.testing.expect(std.mem.indexOf(u8, last, "more bytes not shown") != null);
                            try std.testing.expect(std.mem.indexOf(u8, last, "END-OF-TEXT") == null);
                            switch (rc) {
                                .retention_saved => try std.testing.expect(std.mem.indexOf(u8, last, "Full output: ") != null),
                                .retention_refused, .retention_tight => try std.testing.expect(std.mem.indexOf(u8, last, "Full output was not retained.") != null),
                                .retention_no_bash => try std.testing.expect(std.mem.indexOf(u8, last, "Full output") == null),
                                else => unreachable,
                            }
                        } else try std.testing.expectEqualStrings("after", last);
                    } else try expectHere(@src(), std.mem.indexOf(u8, output.string, expected) != null);
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
