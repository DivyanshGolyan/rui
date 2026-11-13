//! Mcp SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const next_action_attempt_sql = action_domain.next_action_attempt_sql;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = tests.TestingCall;
const completeSessionStop = tests.completeSessionStop;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleMessagesForTesting = tests.settleMessagesForTesting;
const testingSessionReport = tests.testingSessionReport;
const testingStoreToolSet = store_testing.testingStoreToolSet;
const mcp_record = shared_fixtures.mcp_record;
const mcp_records = shared_fixtures.mcp_records;
const mcp_tool_set = shared_fixtures.mcp_tool_set;

test "MCP Actions follow ask and bypass permission and continue after resolution" {
    for ([_][]const u8{ "ask", "bypass" }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var command = try completeConfiguration("mcp-permission-config", "", workspace, "model-a");
        command.configuration.tools = try .of(&.{ "bash", "fetch_page" });
        command.configuration.permission_mode.state = .value;
        try command.configuration.permission_mode.value.set(mode);
        const reply = try storage.configure(&command, .{});
        try std.testing.expect(reply == .accepted);
        const session = reply.accepted.session;
        try submitTestMessage(&storage, &tmp, "mcp-permission-message", "mcp-permission-message", session.slice(), "fetch");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        // The Operation's offer, not a later Session revision, owns this call.
        var update: wire_request.ConfigureCommand = .{};
        try update.key.set("mcp-permission-remove");
        update.session = session;
        update.configuration.tools = try .of(&.{"bash"});
        try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
        const calls = [_]TestingCall{
            .{ .item_id = "item-1", .name = "fetch_page", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{", .decoded_arguments = "{" },
        };
        try settleCallsForTesting(&storage, &tmp, binding, "mcp-permission-metadata", &calls);
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code IS NULL AND action_kind=1", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code='invalid_arguments' AND action_kind IS NULL", .{}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE tool_kind=1 AND bash_timeout_override_ms IS NULL AND attempt_ordinal=0 AND resolution_code IS NULL", .{}));
        const pending_report = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(pending_report);
        try std.testing.expect(std.mem.indexOf(u8, pending_report, "\"tool\":\"fetch_page\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, pending_report, "\"server\":\"docs\"") != null);

        try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
        try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        if (std.mem.eql(u8, mode, "ask")) {
            try std.testing.expect((try storage.nextAction(.mcp)) == null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=0 AND approval_position IS NOT NULL", .{}));
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{}), .decision = .allow_once };
            try allow.key.set("mcp-permission-allow");
            allow.session = session;
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
        }
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1", .{}));
        const action = (try storage.nextAction(.mcp)).?;
        try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
        try storage.resolveAction(action, .spawn_failed, "Failed, not run: this Host does not run MCP tool calls yet.", .{});
        try std.testing.expect((try storage.nextAction(.mcp)) == null);
        // A selected Action that was resolved before dispatch is a harmless no-op.
        try storage.resolveAction(action, .spawn_failed, "not used", .{});
        try std.testing.expect(!storage.isFenced());
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
        try std.testing.expectEqual(binding.operation_id + 1, continuation.operation_id);
        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='spawn_failed' AND attempt_ordinal=0", .{}));
    }
}

test "MCP and Bash admission seek each Action's call without scanning calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
    defer storage.close() catch unreachable;
    inline for ([_][:0]const u8{ next_action_attempt_sql, action_domain.next_mcp_action_sql }, 0..) |sql, index| {
        const statement = try sqlite.prepare(storage.sqliteDatabase(), "EXPLAIN QUERY PLAN " ++ sql);
        defer _ = c.sqlite3_finalize(statement);
        var seeks_call = false;
        var executable_index = false;
        var seeks_action = false;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
                const length = c.sqlite3_column_bytes(statement, 3);
                if (length < 0) return error.InvalidQueryPlan;
                const detail = pointer[0..@intCast(length)];
                seeks_call = seeks_call or std.mem.indexOf(u8, detail, "SEARCH tool_call") != null;
                executable_index = executable_index or std.mem.indexOf(u8, detail, "action_operation_executable") != null;
                try std.testing.expect(std.mem.indexOf(u8, detail, "SCAN tool_call") == null);
                seeks_action = seeks_action or std.mem.indexOf(u8, detail, "SEARCH action USING INDEX sqlite_autoindex_action_operation_") != null;
                if (index == 0) try std.testing.expect(std.mem.indexOf(u8, detail, "TEMP B-TREE") == null);
                if (index == 1) {
                    try std.testing.expect(std.mem.indexOf(u8, detail, "SCAN action") == null);
                    try std.testing.expect(std.mem.indexOf(u8, detail, "action_operation_executable") == null);
                }
            },
            c.SQLITE_DONE => break,
            else => return error.InvalidQueryPlan,
        };
        try std.testing.expect(seeks_call);
        if (index == 0) try std.testing.expect(executable_index) else try std.testing.expect(seeks_action);
    }
}

test "MCP invalid and removed calls share their batch rejection lookup rounds" {
    for ([_]bool{ false, true }) |removed| {
        var rounds: [2]u16 = undefined;
        for ([_]usize{ 1, 64 }, &rounds) |count, *cost| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var command = try completeConfiguration("mcp-rounds-config", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            command.configuration.tools = try .of(&.{ "bash", "fetch_page" });
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            if (removed) {
                var update: wire_request.ConfigureCommand = .{};
                try update.key.set("mcp-rounds-remove");
                update.session = session;
                update.configuration.tools = try .of(&.{"bash"});
                try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            }
            try submitTestMessage(&storage, &tmp, "mcp-rounds-message", "mcp-rounds-message", session.slice(), "fetch");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = try std.testing.allocator.alloc(TestingCall, count);
            defer std.testing.allocator.free(calls);
            const names = try std.testing.allocator.alloc([2][32]u8, count);
            defer std.testing.allocator.free(names);
            for (calls, names, 0..) |*call, *name, index| {
                const id = try std.fmt.bufPrint(&name[1], "call-{d}", .{index});
                call.* = .{
                    .item_id = try std.fmt.bufPrint(&name[0], "item-{d}", .{index}),
                    .name = "fetch_page",
                    .encoded_call_id = id,
                    .decoded_call_id = id,
                    .encoded_arguments = if (removed) "{}" else "{",
                    .decoded_arguments = if (removed) "{}" else "{",
                };
            }
            const before = storage.testing_content_work.rounds;
            try settleCallsForTesting(&storage, &tmp, model, "mcp-rounds-metadata", calls);
            cost.* = storage.testing_content_work.rounds - before;
            try std.testing.expectEqual(@as(u64, count), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code=?1", .{if (removed) @as([]const u8, "unknown_tool") else "invalid_arguments"}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call", .{}));
        }
        // Cold rejection content is looked up once per batch, not per call.
        try std.testing.expect(rounds[1] <= rounds[0] + 1);
        try std.testing.expect(rounds[1] <= 5);
    }
}

test "MCP permission and core authorization coexist in one Turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try completeConfiguration("mixed-core-mcp", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    command.configuration.tools = try .of(&.{ "bash", "fetch_page", "message_agent", "start_agent" });
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    try submitTestMessage(&storage, &tmp, "mixed-input", "mixed-key", session.slice(), "fetch and delegate");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var decoded_buffer: [96]u8 = undefined;
    const decoded = try std.fmt.bufPrint(&decoded_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
    var encoded_buffer: [128]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
    const calls = [_]TestingCall{
        .{ .item_id = "mcp-item", .name = "fetch_page", .encoded_call_id = "mcp-call", .decoded_call_id = "mcp-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "message-item", .name = "message_agent", .encoded_call_id = "message-call", .decoded_call_id = "message-call", .encoded_arguments = encoded, .decoded_arguments = decoded },
        .{ .item_id = "start-item", .name = "start_agent", .encoded_call_id = "start-call", .decoded_call_id = "start-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, model, "mixed-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1", .{}));
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
    try std.testing.expect((try storage.nextAction(.mcp)) == null);
    const report = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"tool\":\"fetch_page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"tool\":\"message_agent\",\"permission_revision\":\"1\",\"authorization\":\"core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"tool\":\"start_agent\",\"permission_revision\":\"1\",\"authorization\":\"core\"") != null);
    const message = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(message.tool == .message_agent);
    try std.testing.expect(try storage.deliverAgentMessage(message.binding, session.slice(), "hi", .{}) == .delivered);
    const start = (try storage.nextCoreWork()).?.action;
    try std.testing.expect(start.tool == .start_agent);
    try std.testing.expect(try storage.failCoreCall(start.binding, "Nothing was started.", .{}));
    try std.testing.expect((try storage.nextCoreWork()) == null);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
    const action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE call_ordinal=0", .{});
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("mixed-allow");
    allow.session = session;
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const mcp = (try storage.nextAction(.mcp)).?;
    try std.testing.expectEqual(action_id, mcp.action_id);
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
    try storage.resolveAction(mcp, .spawn_failed, "Failed, not run: this Host does not run MCP tool calls yet.", .{});
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(model.turn_id, continuation.turn_id);
}

test "MCP work selected before its parent stops yields to the owed child stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
    defer storage.close() catch unreachable;
    const parent = try configureTestSession(&storage, "mcp-parent");
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var configuration = try completeConfiguration("mcp-child", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    configuration.configuration.tools = try .of(&.{"fetch_page"});
    configuration.configuration.permission_mode.state = .value;
    try configuration.configuration.permission_mode.value.set("bypass");
    const configured = try storage.configure(&configuration, .{});
    try std.testing.expect(configured == .accepted);
    const child = configured.accepted.session;
    try store_testing.sqlite_only.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
    try submitTestMessage(&storage, &tmp, "mcp-child-input", "mcp-child-input", child.slice(), "fetch");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, model, "mcp-child-calls", &.{
        .{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    });
    const selected = (try storage.nextCoreWork()).?.mcp;
    var stop = try completeSessionStop("mcp-parent-stop", parent.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    // A selection is not authority: the parent's stop committed first.
    try storage.resolveAction(selected, .spawn_failed, "must not resolve", .{});
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NOT NULL", .{}));
    try std.testing.expect((try storage.nextAction(.mcp)) == null);
    const owed = (try storage.nextCoreWork()).?.stop;
    var owed_stop = try completeSessionStop(owed.key.slice(), owed.session.slice());
    try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
    const ending = (try storage.nextCoreWork()).?.ending;
    try std.testing.expect(ending.quiet);
    try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
    // Even a quiet ending is forwarded to the ancestor Activity feed.
    const forward = (try storage.nextCoreWork()).?.forward;
    try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
    try std.testing.expect((try storage.nextCoreWork()) == null);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'", .{}));
    // The settled stop stays as history; the resumed child's MCP work runs.
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=1", .{child.slice()}));
    try submitTestMessage(&storage, &tmp, "mcp-child-again", "mcp-child-again", child.slice(), "fetch again");
    const resumed = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, resumed, "mcp-child-calls-again", &.{
        .{ .item_id = "item-2", .name = "fetch_page", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    });
    const again = (try storage.nextCoreWork()).?.mcp;
    try storage.resolveAction(again, .spawn_failed, "interim", .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NOT NULL", .{again.action_id}));
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
}

test "an empty MCP selection does not visit queued Bash Actions from a Bash-only offer" {
    var costs: [2]c_int = undefined;
    for ([_]usize{ 1, 1000 }, &costs) |count, *cost| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        var configuration = try completeConfiguration("bash-population", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
        configuration.configuration.tools = try .of(&.{"bash"});
        configuration.configuration.permission_mode.state = .value;
        try configuration.configuration.permission_mode.value.set("bypass");
        const configured = try storage.configure(&configuration, .{});
        try std.testing.expect(configured == .accepted);
        const session = configured.accepted.session;
        try submitTestMessage(&storage, &tmp, "bash-population-input", "bash-population-input", session.slice(), "propose");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = try allocator.alloc(TestingCall, count);
        for (calls, 0..) |*call, index| {
            const id = try allocator.print("call-{d}", .{index});
            call.* = .{ .item_id = id, .name = "bash", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\",\"timeout_ms\":null}" };
        }
        try settleCallsForTesting(&storage, &tmp, model, "bash-population-calls", calls);
        try std.testing.expectEqual(count, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND resolution_code IS NULL", .{}));
        const statement = try sqlite.prepare(storage.sqliteDatabase(), action_domain.next_mcp_action_sql);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
        cost.* = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(costs[0], costs[1]);
}

test "MCP selection cost does not grow with earlier Operations of an open Turn" {
    var costs: [2]c_int = undefined;
    for ([_]usize{ 1, 32 }, &costs) |count, *cost| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        var configuration = try completeConfiguration("mcp-history", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
        configuration.configuration.tools = try .of(&.{"fetch_page"});
        configuration.configuration.permission_mode.state = .value;
        try configuration.configuration.permission_mode.value.set("bypass");
        const configured = try storage.configure(&configuration, .{});
        try std.testing.expect(configured == .accepted);
        const session = configured.accepted.session;
        try submitTestMessage(&storage, &tmp, "mcp-history-input", "mcp-history-input", session.slice(), "fetch");
        var turn_id: u64 = 0;
        for (0..count) |index| {
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (index == 0) turn_id = model.turn_id;
            try std.testing.expectEqual(turn_id, model.turn_id);
            if (index + 1 < count) {
                // Queued input keeps the answer's Turn open for another Operation,
                // without adding historical Actions to MCP serialization's work.
                var key_buffer: [64]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "mcp-history-input-{d}", .{index});
                try submitTestMessage(&storage, &tmp, key, key, session.slice(), "continue");
                try settleMessagesForTesting(&storage, &tmp, model, 1, false, null);
            } else {
                try settleCallsForTesting(&storage, &tmp, model, "mcp-history-calls", &.{
                    .{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                });
            }
        }
        // Read the durable population through production selection before measuring.
        const selected = (try storage.nextAction(.mcp)).?;
        try std.testing.expectEqual(count, try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE turn_id=?1", .{turn_id}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND outcome_code IS NULL", .{turn_id}));
        try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0", .{}));
        const statement = try sqlite.prepare(storage.sqliteDatabase(), action_domain.next_mcp_action_sql);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(selected.action_id, @as(u64, @intCast(c.sqlite3_column_int64(statement, 0))));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
        cost.* = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(costs[0], costs[1]);
}

test "MCP attempts serialize Sessions and recover without replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStoreToolSet(&storage, &tmp, std.testing.io, &mcp_tool_set);
    defer storage.close() catch unreachable;
    var sessions: [2]protocol.Bounded(protocol.max_session_bytes) = undefined;
    for (&sessions, 0..) |*session, index| {
        const key = if (index == 0) "mcp-serial-a" else "mcp-serial-b";
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        var command = try completeConfiguration(key, "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
        command.configuration.tools = try .of(&.{ "fetch_page", "message_agent" });
        command.configuration.permission_mode.state = .value;
        try command.configuration.permission_mode.value.set("bypass");
        const reply = try storage.configure(&command, .{});
        try std.testing.expect(reply == .accepted);
        session.* = reply.accepted.session;
        try submitTestMessage(&storage, &tmp, key, if (index == 0) "mcp-serial-message-a" else "mcp-serial-message-b", session.slice(), "fetch");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "one", .name = "fetch_page", .encoded_call_id = "one", .decoded_call_id = "one", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "two", .name = "fetch_page", .encoded_call_id = "two", .decoded_call_id = "two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "core", .name = "message_agent", .encoded_call_id = "core", .decoded_call_id = "core", .encoded_arguments = "{\\\"id\\\":\\\"zzzzzz\\\",\\\"text\\\":\\\"hi\\\"}", .decoded_arguments = "{\"id\":\"zzzzzz\",\"text\":\"hi\"}" },
        };
        try settleCallsForTesting(&storage, &tmp, model, if (index == 0) "mcp-serial-calls-a" else "mcp-serial-calls-b", calls[0..(if (index == 0) @as(usize, 3) else 2)]);
    }
    var replacement_records = mcp_records;
    for (&replacement_records) |*record| {
        if (!std.mem.eql(u8, record.name, "fetch_page")) continue;
        record.server = "replacement";
        record.input_schema = "{}";
    }
    var replacement_digests: [mcp_records.len][32]u8 = undefined;
    for (&replacement_records, &replacement_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
    const replacement_tool_set: tool_defs.HostToolSet = .{ .records = &replacement_records, .digests = &replacement_digests };
    try storage.saveHostToolSet(&replacement_tool_set);
    const first = (try storage.nextCoreWork()).?.mcp.action_id;
    // Selection repeats until admission: later calls cannot overtake it.
    try std.testing.expectEqual(first, (try storage.nextCoreWork()).?.mcp.action_id);
    const binding = (try storage.admitActionAttempt(.{ .action_id = first, .runner = .mcp }, 1234, .{})).?.permit.binding;
    try std.testing.expect((try storage.admitActionAttempt(.{ .action_id = first + 1, .runner = .mcp }, 600_000, .{})) == null);
    var input: action_domain.ActionExecutionInput = undefined;
    try storage.readActionExecutionInput(.mcp, binding, &input);
    try std.testing.expectEqualStrings(sessions[0].slice(), input.session.slice());
    try std.testing.expectEqualStrings(input.session.slice(), input.runner.mcp.root.slice());
    try std.testing.expect(input.runner.mcp.parent == null);
    try std.testing.expectEqualStrings("fetch_page", input.runner.mcp.name.slice());
    try std.testing.expectEqual(@as(u64, 1234), input.timeout_ms);
    try std.testing.expectEqual(@as(usize, 32), input.sender_handle.slice().len);
    try std.testing.expectEqualStrings("docs", input.runner.mcp.server.slice());
    try std.testing.expectEqual(@as(u64, mcp_record.input_schema.len), input.runner.mcp.input_schema.length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(mcp_record.input_schema), &input.runner.mcp.input_schema.digest);
    // Full MCP slots must not hide a later slot-free core call.
    const core = (try storage.nextCoreWorkForHost(false)).?.action;
    try std.testing.expectEqual(first + 2, core.binding.action_id);
    try std.testing.expect(try storage.failCoreCall(core.binding, "Invalid arguments: missing target.", .{}));
    const other = (try storage.nextCoreWork()).?.mcp.action_id;
    try std.testing.expect(other > first + 1);
    try std.testing.expect(try storage.recoverOneUncertainAction(action_domain.ActiveOperationFilter.empty()));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN content c ON c.content_id=action.resolution_content_id WHERE action.action_id=?1 AND action.resolution_code='indeterminate' AND CAST(c.payload AS TEXT) LIKE ?2", .{ first, "%Host stopped%" }));
    try std.testing.expectEqual(first + 1, (try storage.nextCoreWork()).?.mcp.action_id);
    const unsent = (try storage.admitActionAttempt(.{ .action_id = first + 1, .runner = .mcp }, 600_000, .{})).?.permit.binding;
    var stop = try completeSessionStop("mcp-unsent-stop", sessions[0].slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    // Store stop must not replace the adapter's definite not-run evidence.
    _ = try storage.settleActionAttempt(unsent, .spawn_failed, "not available", .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN content c ON c.content_id=action.resolution_content_id WHERE action.action_id=?1 AND action.resolution_code='spawn_failed' AND CAST(c.payload AS TEXT) LIKE ?2", .{ unsent.action_id, "%not available%" }));
    const sent = (try storage.admitActionAttempt(.{ .action_id = other, .runner = .mcp }, 5_000, .{})).?.permit.binding;
    var sent_stop = try completeSessionStop("mcp-sent-stop", sessions[1].slice());
    try std.testing.expect(storage.stopSession(&sent_stop, .{}) == .accepted);
    // A definite remote answer also remains definite when settlement races stop.
    _ = try storage.settleActionAttempt(sent, .succeeded, "terminal result raced stop", .{});
    try std.testing.expectEqual(@as(u64, 1), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN content c ON c.content_id=action.resolution_content_id WHERE action.action_id=?1 AND action.resolution_code='succeeded' AND CAST(c.payload AS TEXT) LIKE ?2", .{ sent.action_id, "%terminal result raced stop%" }));
}
