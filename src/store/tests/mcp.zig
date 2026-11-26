const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const store_testing = @import("../testing.zig");
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const expectOneWork = shared_fixtures.expectOneWork;
const membershipToolSet = shared_fixtures.membershipToolSet;
const membership_records = shared_fixtures.membership_records;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingListRow = shared_fixtures.testingListRow;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "MCP settlement saves one decoded presentation line or the tool name" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            const records = testingHostToolRecords(&.{.{
                .name = "fetch_page",
                .owner = .mcp,
                .server = "docs",
                .description = "Fetch a page.",
                .input_schema = "{\"type\":\"object\",\"properties\":{}}",
            }});
            const digests = blk: {
                var out: [records.len][32]u8 = undefined;
                for (records, &out) |record, *digest| digest.* = tool_defs.recordDigest(&record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            const Case = struct { arguments: []const u8, expected: []const u8 = "fetch_page" };
            const cases = [_]Case{
                .{ .arguments = "{\"rui_call_description\":\"Fetch page\"}", .expected = "Fetch page" },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([200]u8, @splat('a')) ++ "\"}", .expected = &@as([200]u8, @splat('a')) },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([200]u8, @bitCast(@as([100][2]u8, @splat("é".*)))) ++ "\"}", .expected = &@as([200]u8, @bitCast(@as([100][2]u8, @splat("é".*)))) },
                .{ .arguments = "{\"rui_call_description\":\"Fetch \\u00e9 page\"}", .expected = "Fetch é page" },
                .{ .arguments = "{\"padding\":\"" ++ @as([4100]u8, @splat('x')) ++ "\",\"rui_call_description\":\"Fetch after padding\"}", .expected = "Fetch after padding" },
                .{ .arguments = "{\"rui_call_\\u0064escription\":\"" ++ @as([1200]u8, @bitCast(@as([200][6]u8, @splat("\\u0061".*)))) ++ "\"}", .expected = &@as([200]u8, @splat('a')) },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([201]u8, @splat('a')) ++ "\"}" },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([202]u8, @bitCast(@as([101][2]u8, @splat("é".*)))) ++ "\"}" },
                .{ .arguments = "{}" },
                .{ .arguments = "{\"rui_call_description\":7}" },
                .{ .arguments = "{\"rui_call_description\":null}" },
                .{ .arguments = "{\"rui_call_description\":\"\"}" },
                .{ .arguments = "{\"rui_call_description\":\" \\t\\u00a0\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\npage\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\rpage\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u0085page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u2028page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u2029page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch page\",\"broken\":" },
            };
            for (cases) |line| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("mcp-line-config", "", try canonicalCwd(std.testing.io, &workspace), "model-a");
                configure.configuration.tools = try .of(&.{"fetch_page"});
                const configured = try storage.configure(&configure, .{});
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "mcp-line-input", "mcp-line-message", session.slice(), "fetch");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var encoded: [8192]u8 = undefined;
                var writer = std.Io.Writer.fixed(&encoded);
                try std.json.Stringify.value(line.arguments, .{}, &writer);
                const quoted = writer.buffered();
                try settleCallsForTesting(&storage, &tmp, binding, "mcp-line-calls", &.{.{
                    .item_id = "item-1",
                    .name = "fetch_page",
                    .encoded_call_id = "call-1",
                    .decoded_call_id = "call-1",
                    .encoded_arguments = quoted[1 .. quoted.len - 1],
                    .decoded_arguments = line.arguments,
                }});
                errdefer std.debug.print("MCP arguments: {s}\n", .{line.arguments});
                // The call keeps the label the model gave, or with none the tool's name, which is what the call has always read as.
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE label=?1 AND subject IS NULL", .{line.expected}));
                const page = try store_core.activityPageForTesting(&storage, .{ .session = session });
                // A call whose arguments are not one JSON object is rejected: it is no Action, so Activity counts no call.
                if (page.aggregates.?.call_activity.count == 1) {
                    try std.testing.expectEqualStrings(line.expected, page.aggregates.?.call_activity.entries[0].presentation.line.?.words.slice());
                } else {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code='invalid_arguments'", .{}));
                }
                if (line.expected.len == 200) {
                    try std.testing.expectEqual(@as(usize, 1), page.aggregates.?.call_activity.count);
                    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                    defer std.testing.allocator.free(report);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
                    defer parsed.deinit();
                    const unresolved = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items;
                    try std.testing.expectEqualStrings(line.expected, unresolved[0].object.get("presentation").?.object.get("line").?.object.get("before").?.string);
                }
            }
        }
    }.run);
}

test "saved MCP call lines survive all work reads pending, running and completed at every boundary" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            for ([_]usize{ 100, 101, 200 }) |length| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("mcp-work-config", "", try canonicalCwd(std.testing.io, &workspace), "model-a");
                configure.configuration.tools = try .of(&.{"fetch_page"});
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("bypass");
                const configured = try storage.configure(&configure, .{});
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "mcp-work-input", "mcp-work-message", session.slice(), "fetch");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var description: [protocol.max_tool_description_bytes]u8 = @splat('x');
                for (0..length / 2) |i| @memcpy(description[i * 2 ..][0..2], "é");
                const text = description[0..length];
                var arguments: [1024]u8 = undefined;
                const args = try std.fmt.bufPrint(&arguments, "{{\"rui_call_description\":\"{s}\"}}", .{text});
                var encoded: [2048]u8 = undefined;
                var writer = std.Io.Writer.fixed(&encoded);
                try std.json.Stringify.value(args, .{}, &writer);
                const quoted = writer.buffered();
                try settleCallsForTesting(&storage, &tmp, model, "mcp-work-calls", &.{.{
                    .item_id = "item-1",
                    .name = "fetch_page",
                    .encoded_call_id = "call-1",
                    .decoded_call_id = "call-1",
                    .encoded_arguments = quoted[1 .. quoted.len - 1],
                    .decoded_arguments = args,
                }});
                try reads(&storage, &tmp, session.slice(), "pending", text);
                const action = (try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })).?;
                const binding = (try storage.admitActionAttempt(action, 600_000, .{})).?.permit.binding;
                try reads(&storage, &tmp, session.slice(), "bash", text);
                _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
                try reads(&storage, &tmp, session.slice(), "pending", text);
            }
        }

        fn reads(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, kind: []const u8, description: []const u8) !void {
            _ = try expectOneWork(storage, tmp, session, kind);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session);
            const page = try store_core.activityPageForTesting(storage, request);
            for (page.aggregates.?.call_activity.entries[0..page.aggregates.?.call_activity.count]) |*call|
                try std.testing.expectEqualStrings(description, call.presentation.line.?.words.slice());
            var listed = try testingListRow(storage, tmp, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings(kind, listed.get(&.{ "work", "state", "kind" }).string);
            const observed = (try store_testing.observeCommandForTesting(storage, "mcp-work-message")).kind.message.?;
            const state = observed.work.?.state;
            try std.testing.expectEqualStrings(kind, @tagName(state));
            if (state == .bash) {
                try std.testing.expectEqualStrings(description, page.work.work.state.bash.description.?.slice());
                try std.testing.expectEqualStrings(description, listed.get(&.{ "work", "state", "description" }).string);
                try std.testing.expectEqualStrings(description, state.bash.description.?.slice());
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "MCP calls of one reply run at once and settle in any order" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = comptime testingHostToolRecords(&.{
                .{ .name = "read_page", .owner = .mcp, .server = "docs", .description = "Read a page.", .input_schema = "{\"type\":\"object\"}" },
                .{ .name = "write_page", .owner = .mcp, .server = "docs", .description = "Write a page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            const patterns = [_]struct { reads: []const bool }{
                .{ .reads = &.{ false, true, true, false } },
                .{ .reads = &.{ true, true } },
                .{ .reads = &.{ false, false } },
                .{ .reads = &.{ true, false } },
            };
            for (patterns) |pattern| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("reply-order", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                configure.configuration.tools = try .of(&.{ "read_page", "write_page" });
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("bypass");
                const configured = try storage.configure(&configure, .{});
                try std.testing.expect(configured == .accepted);
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "reply-input", "reply-message", session.slice(), "exercise read waves");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var calls: [4]TestingCall = undefined;
                const ids = [_][]const u8{ "call-a", "call-b", "call-c", "call-d" };
                for (pattern.reads, 0..) |read, index| calls[index] = .{
                    .item_id = ids[index],
                    .name = if (read) "read_page" else "write_page",
                    .encoded_call_id = ids[index],
                    .decoded_call_id = ids[index],
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
                try settleCallsForTesting(&storage, &tmp, model, "reply-calls", calls[0..pattern.reads.len]);

                var ready: [4]action_domain.ReadyAction = undefined;
                var bindings: [4]ActionAttemptBinding = undefined;
                for (ready[0..pattern.reads.len], 0..) |*action, index| {
                    action.* = .{ .action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1 AND call_ordinal=?2", .{ model.operation_id, index }), .runner = .mcp };
                    try action.server.set("docs");
                }
                for (ready[0..pattern.reads.len], bindings[0..pattern.reads.len]) |action, *attempt| {
                    const selected = (try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })).?;
                    try std.testing.expectEqual(action.action_id, selected.action_id);
                    attempt.* = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
                }
                try std.testing.expect((try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })) == null);
                var remaining = pattern.reads.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                    try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(bindings[remaining], .succeeded, "done", .{})).outcome);
                }
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
                try std.testing.expect((try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })) == null);
            }
        }
    }.run);
}

test "MCP promotion keeps old frozen Operations eligible without hiding finite work or repeating Attempts" {
    try store_testing.forEachEngine(struct {
        fn propose(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, key: []const u8) !u64 {
            try submitTestMessage(storage, tmp, key, key, session, "Fetch a page.");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var metadata_name: [64]u8 = undefined;
            try settleCallsForTesting(storage, tmp, model, try std.fmt.bufPrint(&metadata_name, "{s}-metadata", .{key}), &.{.{
                .item_id = "item",
                .name = "fetch_page",
                .encoded_call_id = "call",
                .decoded_call_id = "call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            return store_testing.queryU64(storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
        }

        fn run(case: *store_testing.Case) !void {
            body(case) catch |err| {
                std.debug.print("MCP promotion regression error: {s}\n", .{@errorName(err)});
                return err;
            };
        }

        fn body(case: *store_testing.Case) !void {
            var phase: []const u8 = "configure";
            errdefer std.debug.print("MCP promotion regression phase: {s}\n", .{phase});
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tools = membershipToolSet(&digests);
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
            defer storage.close() catch unreachable;
            var sessions: [2]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&sessions, 0..) |*session, index| {
                const key = if (index == 0) "old-background" else "finite-mcp";
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration(key, "", try canonicalCwd(std.testing.io, &workspace), "model-a");
                configure.configuration.tools = try .of(&.{"fetch_page"});
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("bypass");
                session.* = (try storage.configure(&configure, .{})).accepted.session;
            }
            phase = "old proposal";
            const old = try propose(&storage, &tmp, sessions[0].slice(), "old-call");
            var promote: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = old };
            try promote.key.set("promote-old");
            promote.session = sessions[0];

            phase = "promotion";
            try std.testing.expect(storage.backgroundAction(.{ .command = &promote }, .{}) == .accepted);
            try std.testing.expectEqual(old, (try storage.nextAction(.mcp, .fromFree(2, true))).?.action_id);
            phase = "continuation";
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try shared_fixtures.settleMessagesForTesting(&storage, &tmp, continuation, 1, false, null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND outcome_code IS NOT NULL", .{continuation.turn_id}));
            phase = "same-Session proposal";
            const same_session = try propose(&storage, &tmp, sessions[0].slice(), "same-session-call");
            phase = "finite proposal";
            const finite = try propose(&storage, &tmp, sessions[1].slice(), "finite-call");
            phase = "selection";
            try std.testing.expect(old < same_session and same_session < finite);
            try std.testing.expect((try storage.nextAction(.mcp, .fromFree(0, true))) == null);
            try std.testing.expect((try storage.nextAction(.mcp, .fromFree(2, false))) == null);
            try std.testing.expectEqual(old, (try storage.nextAction(.mcp, .fromFree(1, true))).?.action_id);
            const selected_old = (try storage.nextAction(.mcp, .fromFree(2, true))).?;
            try std.testing.expectEqual(old, selected_old.action_id);
            phase = "old Attempt";
            const old_binding = (try storage.admitActionAttempt(selected_old, 30_000, .{})).?.permit.binding;
            try std.testing.expect((try storage.admitActionAttempt(selected_old, 30_000, .{})) == null);
            phase = "same-Session Attempt";
            const selected_same = (try storage.nextAction(.mcp, .fromFree(1, true))).?;
            try std.testing.expectEqual(same_session, selected_same.action_id);
            const same_binding = (try storage.admitActionAttempt(selected_same, 30_000, .{})).?.permit.binding;
            const selected_finite = (try storage.nextAction(.mcp, .fromFree(1, true))).?;
            try std.testing.expectEqual(finite, selected_finite.action_id);
            phase = "finite Attempt";
            const finite_binding = (try storage.admitActionAttempt(selected_finite, 30_000, .{})).?.permit.binding;
            phase = "finite settlement";
            try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(finite_binding, .succeeded, "Finite result", .{})).outcome);
            try std.testing.expect((try storage.nextAction(.mcp, .fromFree(2, true))) == null);
            phase = "old settlement";
            try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(old_binding, .succeeded, "Old background result", .{})).outcome);
            try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(same_binding, .succeeded, "Same-Session result", .{})).outcome);
            try std.testing.expect((try storage.nextAction(.mcp, .fromFree(2, true))) == null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND resolution_code='succeeded'", .{old}));
        }
    }.run);
}

/// One saved call of the line matrix: the tool, its arguments and the line every reader derives for it (null: no line).
const LineCase = struct { name: []const u8, arguments: []const u8, expected: ?[]const u8 };

/// Settles `cases` as one Operation's calls on `session` and returns nothing; the readers are asked afterwards.
fn settleLineCases(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, prefix: []const u8, cases: []const LineCase) !void {
    var key: [32]u8 = undefined;
    const input = try std.fmt.bufPrint(&key, "{s}-input", .{prefix});
    try submitTestMessage(storage, tmp, input, input, session, "run");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var calls: [16]TestingCall = undefined;
    var ids: [16][8]u8 = undefined;
    var encoded: [16][512]u8 = undefined;
    for (cases, 0..) |case, at| {
        const id = try std.fmt.bufPrint(&ids[at], "call-{d}", .{at});
        var writer = std.Io.Writer.fixed(&encoded[at]);
        try std.json.Stringify.value(case.arguments, .{}, &writer);
        const quoted = writer.buffered();
        calls[at] = .{ .item_id = id, .name = case.name, .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = quoted[1 .. quoted.len - 1], .decoded_arguments = case.arguments };
    }
    try settleCallsForTesting(storage, tmp, binding, prefix, calls[0..cases.len]);
}

/// A Session's calls as Activity shows them: every call is a `call` row whose `description` is its line, and a rejected call is
/// also a `tool_result` row whose presentation carries it. Each case's line is checked on both, the rejected ones in order.
fn expectActivityLines(storage: *Store, session: []const u8, cases: []const LineCase, rejected: []const bool) !void {
    var request: protocol.ActivityPage = .{ .kinds = .initMany(&.{.call}) };
    try request.session.set(session);
    const calls = try store_core.activityPageForTesting(storage, request);
    try std.testing.expectEqual(cases.len, calls.count);
    for (calls.items[0..calls.count]) |item| {
        const call = item.value.call;
        if (cases[call.call_ordinal].expected) |expected| {
            try std.testing.expectEqualStrings(expected, call.description.?.slice());
        } else try std.testing.expect(call.description == null);
    }
    // A rejected call's result is published once every call of its Operation is fulfilled, so only a Session of rejected calls has them.
    var count: usize = 0;
    for (rejected) |yes| count += @intFromBool(yes);
    if (count != cases.len) return;
    request.kinds = .initMany(&.{.tool_result});
    const results = try store_core.activityPageForTesting(storage, request);
    var at: usize = 0;
    for (results.items[0..results.count]) |item| {
        while (!rejected[at]) at += 1;
        const line = item.value.tool_result.presentation.line;
        if (cases[at].expected) |expected| {
            try std.testing.expectEqualStrings(expected, line.?.words.slice());
        } else try std.testing.expect(line == null);
        at += 1;
    }
    try std.testing.expectEqual(count, results.count);
}

test "TPR-4 a call reads its line from its tool, whether a tool served it and the label it saved, as it did when the line was saved" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            const records = testingHostToolRecords(&.{.{
                .name = "fetch_page",
                .owner = .mcp,
                .server = "docs",
                .description = "Fetch a page.",
                .input_schema = "{\"type\":\"object\",\"properties\":{}}",
            }});
            const digests = blk: {
                var out: [records.len][32]u8 = undefined;
                for (records, &out) |record, *digest| digest.* = tool_defs.recordDigest(&record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            var workspace: [protocol.max_workspace_bytes]u8 = undefined;
            const cwd = try canonicalCwd(std.testing.io, &workspace);

            // A Session that offers Bash, a core tool, an MCP tool: each call is accepted, or rejected for what it carried.
            var offered = try completeConfiguration("line-offered", "", cwd, "model-a");
            offered.configuration.tools = try .of(&.{ "bash", "fetch_page", "find_tools" });
            offered.configuration.permission_mode.state = .value;
            try offered.configuration.permission_mode.value.set("bypass");
            const offered_session = (try storage.configure(&offered, .{})).accepted.session;
            const offered_cases = [_]LineCase{
                .{ .name = "bash", .arguments = "{\"description\":\"Run the tests\",\"cmd\":\"zig build test\"}", .expected = "Run the tests" },
                .{ .name = "bash", .arguments = "{\"cmd\":\"zig build test\"}", .expected = "Tool call" },
                .{ .name = "find_tools", .arguments = "{}", .expected = "Find tools" },
                .{ .name = "fetch_page", .arguments = "{\"rui_call_description\":\"Fetch the docs page\"}", .expected = "Fetch the docs page" },
                .{ .name = "fetch_page", .arguments = "{}", .expected = "fetch_page" },
                .{ .name = "fetch_page", .arguments = "{\"rui_call_description\":\"Fetch\",\"broken\":", .expected = "fetch_page" },
                .{ .name = "no_such_tool", .arguments = "{}", .expected = null },
            };
            const offered_rejected = [_]bool{ false, false, false, false, false, true, true };
            try settleLineCases(&storage, &tmp, offered_session.slice(), "line-offered-calls", &offered_cases);
            try expectActivityLines(&storage, offered_session.slice(), &offered_cases, &offered_rejected);

            // A Session that offers nothing: a Bash call that said what it did keeps those words, a core tool keeps its own,
            // and an MCP tool nothing served has none.
            var bare = try completeConfiguration("line-bare", "", cwd, "model-a");
            bare.configuration.tools = try .of(&.{});
            const bare_session = (try storage.configure(&bare, .{})).accepted.session;
            const bare_cases = [_]LineCase{
                .{ .name = "bash", .arguments = "{\"description\":\"Run the tests\",\"cmd\":\"zig build test\"}", .expected = "Run the tests" },
                .{ .name = "bash", .arguments = "{\"cmd\":\"zig build test\"}", .expected = null },
                .{ .name = "find_tools", .arguments = "{}", .expected = "Find tools" },
                .{ .name = "fetch_page", .arguments = "{\"rui_call_description\":\"Fetch the docs page\"}", .expected = null },
                .{ .name = "stop_action", .arguments = "{}", .expected = null },
            };
            const bare_rejected = [_]bool{ true, true, true, true, true };
            try settleLineCases(&storage, &tmp, bare_session.slice(), "line-bare-calls", &bare_cases);
            try expectActivityLines(&storage, bare_session.slice(), &bare_cases, &bare_rejected);

            // A lane root that declares an app tool: its call saves no label, so it has no line.
            const declaration = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";
            var lane = try completeConfiguration("line-lane", "", cwd, "model-a");
            lane.configuration.tools = try .of(&.{});
            lane.configuration.app_tools = .{ .state = .value, .borrowed = declaration.ptr, .length = declaration.len, .digest = protocol.contentDigest(declaration) };
            const lane_session = (try storage.configure(&lane, .{})).accepted.session;
            const lane_cases = [_]LineCase{.{ .name = "ask", .arguments = "{}", .expected = null }};
            try settleLineCases(&storage, &tmp, lane_session.slice(), "line-lane-calls", &lane_cases);
            var request: protocol.ActivityPage = .{ .kinds = .initMany(&.{.call}) };
            try request.session.set(lane_session.slice());
            const lane_page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), lane_page.count);
            try std.testing.expect(lane_page.items[0].value.call.description == null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE session_ref=?1 AND label IS NULL AND subject IS NULL AND rejection_code IS NULL", .{lane_session.slice()}));
        }
    }.run);
}
