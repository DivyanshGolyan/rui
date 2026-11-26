const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const action_domain = @import("../domain/action.zig");
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const ContentReader = content_domain.ContentReader;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const TestingSessionReport = shared_fixtures.TestingSessionReport;
const TwinRounds = shared_fixtures.TwinRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectContent = shared_fixtures.expectContent;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingContentReference = shared_fixtures.testingContentReference;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionReport = shared_fixtures.testingSessionReport;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "allow once survives mode changes and reopen without granting another Attempt" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "allow-config");
            try submitTestMessage(&storage, &tmp, "allow-input", "allow-message", session.slice(), "propose");
            const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model_binding, "allow-metadata");
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
            const action_id = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
            const sibling_id = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("allow-first");
            try allow.session.set(session.slice());
            const accepted = storage.decidePermission(&allow, .{});
            try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);

            var changed = allow;
            changed.decision = .deny;
            try std.testing.expect(storage.decidePermission(&changed, .{}) == .conflict);
            changed = allow;
            changed.action_id = sibling_id;
            try std.testing.expect(storage.decidePermission(&changed, .{}) == .conflict);
            changed = allow;
            try changed.key.set("allow-again");
            const fresh = storage.decidePermission(&changed, .{});
            try std.testing.expect(fresh == .rejected and !fresh.rejected.replayed);
            try std.testing.expectEqual(protocol.PermissionDecisionRejection.action_not_pending, fresh.rejected.code);

            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("allow-mode-change");
            try update.session.set(session.slice());
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            for (0..2) |pass| {
                if (pass == 1) {
                    try storage.close();
                    storage_open = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    storage_open = true;
                }
                const replay = storage.decidePermission(&allow, .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
                defer report.deinit();
                try std.testing.expectEqual(@as(usize, 2), report.value.actions.unresolved.len);
                try std.testing.expectEqualStrings("allow_once", report.value.actions.unresolved[0].authorization);
                for (report.value.actions.unresolved) |action| try std.testing.expectEqualStrings("1", action.permission_revision);
            }
            const action = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
            try std.testing.expectEqual(action_id, action.action_id);
            try std.testing.expect(storage.decidePermission(&allow, .{}).accepted.replayed);
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
        }
    }.run);
}

test "earlier Action settlement remains authoritative after Session stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const allocated_session_0 = try configureTestSessionAsk(&storage, "settlement-first-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "settlement-first-message",
                "settlement-first-message",
                allocated_session_0.slice(),
                "execute",
            );
            const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{
                .item_id = "settlement-first-item",
                .name = "bash",
                .encoded_call_id = "settlement-first-call",
                .decoded_call_id = "settlement-first-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
            }};
            try settleCallsForTesting(&storage, &tmp, model_binding, "settlement-first-metadata", &calls);
            const action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("settlement-first-allow");
            try allow.session.set(allocated_session_0.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action_binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;

            try std.testing.expectEqual(
                ActionSettlement.Outcome.effect,
                (try storage.settleActionAttempt(action_binding, .succeeded, "Original Bash result.", .{})).outcome,
            );
            const original_content_id = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation", .{});
            const original_content_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try std.testing.expectError(
                error.StaleActionAttemptBinding,
                storage.settleActionAttempt(action_binding, .failed, "Late replacement.", .{}),
            );
            try std.testing.expectEqual(
                original_content_count,
                try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}),
            );

            var stop = try completeSessionStop("settlement-first-stop", allocated_session_0.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(model_binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expectEqual(original_content_id, try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'", .{}));
            const result_metadata = try testingContentReference(&storage, original_content_id);
            try expectContent(&storage, result_metadata, "Original Bash result.");
            try std.testing.expectError(
                error.StaleActionAttemptBinding,
                storage.settleActionAttempt(action_binding, .cancelled, "Late stop result.", .{}),
            );
            try std.testing.expectEqual(
                original_content_count,
                try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}),
            );
            try submitTestMessage(
                &storage,
                &tmp,
                "settlement-first-later",
                "settlement-first-later",
                allocated_session_0.slice(),
                "later",
            );
            const stop_replay = storage.stopSession(&stop, .{});
            try std.testing.expect(stop_replay == .accepted);
            try std.testing.expect(stop_replay.accepted.replayed);
            try std.testing.expectEqual(accepted.accepted.selection, stop_replay.accepted.selection);
            try std.testing.expect(
                (try store_testing.observeCommandForTesting(&storage, "settlement-first-later")).kind.message.?.queue.?.state == .queued,
            );
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'", .{allocated_session_0.slice()}));
        }
    }.run);
}

// EXR-68: every runner SQL fragment derived from a tool row agrees with a pinned runner table and with Runner.of.
test "EXR-68 runner SQL agrees with Runner.of over every owner and built-in name" {
    try store_testing.forEachEngine(struct {
        const records = @import("../../tool_record.zig");
        const Runner = records.Runner;
        const Case = struct { owner: records.Owner, name: []const u8 };
        // Every owner against every built-in name and one unknown name, built at comptime.
        const cases = blk: {
            var names: []const []const u8 = &.{};
            for (std.enums.values(records.Tool)) |tool| names = names ++ .{@tagName(tool)};
            names = names ++ .{"not_a_built_in_tool"};
            var out: []const Case = &.{};
            for (std.enums.values(records.Owner)) |owner| {
                for (names) |name| out = out ++ .{Case{ .owner = owner, .name = name }};
            }
            break :blk out;
        };

        // The oracle, written out by hand rather than read from the table under test.
        fn pinned(comptime entry: Case) Runner {
            return switch (entry.owner) {
                .mcp => .mcp,
                .provider => .provider,
                .app => .app,
                .rui => if (std.mem.eql(u8, entry.name, "bash")) .bash else if (std.mem.eql(u8, entry.name, "read_image")) .read_image else if (std.mem.eql(u8, entry.name, "watch_github_pr")) .github_pr_watch else if (std.mem.eql(u8, entry.name, "web_search")) .provider else if (std.mem.eql(u8, entry.name, "not_a_built_in_tool")) .bash else .core,
            };
        }

        fn expectSql(storage: *Store, comptime probe: []const u8, expected: u64) !void {
            try std.testing.expectEqual(expected, try store_testing.queryU64(storage, "SELECT " ++ probe, .{}));
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            inline for (cases) |entry| {
                const record: records.Record = .{ .name = entry.name, .owner = entry.owner };
                const expected = comptime pinned(entry);
                errdefer std.debug.print("runner SQL disagrees for owner {s} name {s}\n", .{ @tagName(entry.owner), entry.name });
                try std.testing.expectEqual(expected, Runner.of(&record));
                const owner = "'" ++ @tagName(entry.owner) ++ "'";
                const name = "'" ++ entry.name ++ "'";
                try expectSql(&storage, "(" ++ records.sql.runnerOf(owner, name) ++ ")='" ++ @tagName(expected) ++ "'", 1);
                try expectSql(&storage, "CASE WHEN " ++ records.sql.notDefaultTest(owner, name) ++ " THEN 1 ELSE 0 END", @intFromBool(expected != records.default_runner));
                // Uncertain-action recovery keeps exactly the attempts whose runner is not app (`uncertain_actions`).
                try expectSql(&storage, "CASE WHEN (" ++ records.sql.runnerOf(owner, name) ++ ")<>'" ++ @tagName(Runner.app) ++ "' THEN 1 ELSE 0 END", @intFromBool(expected != .app));
                inline for (comptime std.enums.values(Runner)) |runner| {
                    try expectSql(&storage, "CASE WHEN " ++ records.sql.runnerTest(owner, name, runner) ++ " THEN 1 ELSE 0 END", @intFromBool(expected == runner));
                }
            }
        }
    }.run);
}

test "core tool table routes every built-in and promotion excludes the full core domain" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = @import("../../tool_record.zig");
            for (std.enums.values(records.Tool)) |tool| {
                errdefer std.debug.print("table routing failed for {s}\n", .{@tagName(tool)});
                const row = records.built_in_rows.get(tool);
                const expected: records.Runner = switch (tool) {
                    .bash => .bash,
                    .read_image => .read_image,
                    .watch_github_pr => .github_pr_watch,
                    .web_search => .provider,
                    else => .core,
                };
                try std.testing.expectEqual(expected, row.runner);
                try std.testing.expectEqual(expected, records.Runner.of(records.record(tool)));

                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var command = try completeConfiguration("table-config", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                command.configuration.tools = try .of(&.{@tagName(tool)});
                const configured = try storage.configure(&command, .{});
                try std.testing.expect(configured == .accepted);
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "table-input", "table-input", session.slice(), "call");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const arguments = switch (tool) {
                    .bash => "{\"cmd\":\"true\",\"description\":\"Run table check\"}",
                    .read_image => "{\"path\":\"image.png\"}",
                    .watch_github_pr => "{\"url\":\"https://github.com/org/repo/pull/42\"}",
                    .message_agent => "{\"id\":\"zzzzzz\",\"text\":\"hi\"}",
                    .stop_action => "{\"action\":\"1\"}",
                    else => "{}",
                };
                var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer encoded.deinit();
                try std.json.Stringify.value(arguments, .{}, &encoded.writer);
                const quoted = encoded.written();
                const calls = [_]TestingCall{.{
                    .item_id = "table-item",
                    .name = @tagName(tool),
                    .encoded_call_id = "table-call",
                    .decoded_call_id = "table-call",
                    .encoded_arguments = quoted[1 .. quoted.len - 1],
                    .decoded_arguments = arguments,
                }};
                try settleCallsForTesting(&storage, &tmp, binding, "table-calls", &calls);
                const core = try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true });
                const bash = try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{});
                try std.testing.expectEqual(expected == .core or expected == .read_image or expected == .github_pr_watch, core != null);
                try std.testing.expectEqual(expected == .bash, bash != null);
                if (expected == .read_image) {
                    const call = core.?.read_image;
                    try std.testing.expectEqual(records.Runner.read_image, call.runner);
                    try std.testing.expectEqualDeep(call, (try storage.nextAction(.read_image, .fromFree(1, false))).?);
                    const attempted = (try storage.admitActionAttempt(call, 1234, .{})).?.permit.binding;
                    try std.testing.expectEqual(binding.operation_id, attempted.parent_operation_id);
                    try std.testing.expectEqual(binding.turn_id, attempted.turn_id);
                    try std.testing.expect((try storage.nextCoreWork(.fromFree(1, false))) == null);
                } else if (expected == .github_pr_watch) {
                    const call = core.?.github_pr_watch;
                    try std.testing.expectEqual(records.Runner.github_pr_watch, call.runner);
                    try std.testing.expectEqualDeep(call, (try storage.nextAction(.github_pr_watch, .fromFree(1, false))).?);
                    const attempted = (try storage.admitActionAttempt(call, 1234, .{})).?.permit.binding;
                    try std.testing.expectEqual(binding.operation_id, attempted.parent_operation_id);
                    try std.testing.expect((try storage.nextCoreWork(.fromFree(1, false))) == null);
                } else if (core) |work| {
                    const call = work.action;
                    try std.testing.expectEqualStrings(@tagName(tool), @tagName(call.tool));
                    try std.testing.expectEqual(binding.operation_id, call.binding.parent_operation_id);
                    try std.testing.expectEqual(binding.turn_id, call.binding.turn_id);
                    try std.testing.expectEqualStrings(session.slice(), call.session.slice());
                    try std.testing.expectEqual(call.binding.action_id, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action.binding.action_id);
                    var promotion = try NativePromotion.command(session.slice(), "core-promotion", call.binding.action_id);
                    const refused = storage.backgroundAction(.{ .command = &promotion }, .{});
                    try std.testing.expect(refused == .rejected and refused.rejected.code == .action_not_backgroundable);
                    const replay = storage.backgroundAction(.{ .command = &promotion }, .{});
                    try std.testing.expect(replay == .rejected and replay.rejected.replayed and replay.rejected.code == .action_not_backgroundable);
                    var stop = try completeSessionStop("core-stop", session.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    try promotion.key.set("stopped-core-promotion");
                    const stopped = storage.backgroundAction(.{ .command = &promotion }, .{});
                    try std.testing.expect(stopped == .rejected and stopped.rejected.code == .action_not_backgroundable);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE background_position IS NOT NULL", .{}));
                }
                if (bash) |attempted| {
                    try std.testing.expectEqual(binding.operation_id, attempted.permit.binding.parent_operation_id);
                    try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
                    try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
                }
            }
        }
    }.run);
}

test "Bash proposals retain exact order permission provenance denial and stop terminality" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;

            const session = try configureTestSessionAsk(&storage, "action-config");
            try submitTestMessage(&storage, &tmp, "action-message", "action-message", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "action-metadata");

            var public_request = protocol.ConversationPage{};
            try public_request.session.set(session.slice());
            const proposed = try store_core.publicConversationPageForTesting(&storage, public_request);
            try std.testing.expectEqual(@as(usize, 1), proposed.count);
            try std.testing.expect(proposed.items[0].kind == .user);
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{
                .session = public_request.session,
                .position = proposed.end,
            }));

            const first_action_id = first: {
                const report_bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(report_bytes);
                try std.testing.expect(std.mem.indexOf(u8, report_bytes, "\"work\":{\"state\":{\"kind\":\"approval\"") != null);
                const parsed = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                try std.testing.expectEqualStrings("2", parsed.value.actions.count);
                try std.testing.expectEqual(@as(usize, 2), parsed.value.actions.unresolved.len);
                const wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
                defer wire.deinit();
                const presentation = wire.value.object.get("actions").?.object.get("unresolved").?.array.items[0].object.get("presentation").?.object;
                try std.testing.expectEqualStrings("Run first command", presentation.get("line").?.object.get("before").?.string);
                try std.testing.expectEqualStrings("pending_permission", presentation.get("code").?.string);
                try std.testing.expect(presentation.get("publication_position").? == .null);
                const first = parsed.value.actions.unresolved[0];
                try std.testing.expectEqualStrings("0", first.call_ordinal);
                try std.testing.expectEqualStrings("1", first.permission_revision);
                break :first try std.fmt.parseInt(u64, first.action, 10);
            };
            try std.testing.expectError(error.ActionNotFound, storage.actionCallId(session.slice(), std.math.maxInt(u64)));
            try std.testing.expectError(error.ActionNotFound, storage.actionArguments(session.slice(), std.math.maxInt(u64)));
            try std.testing.expect(!storage.isFenced());
            try expectContent(&storage, try storage.actionCallId(session.slice(), first_action_id), "call\nA");
            try expectContent(&storage, try storage.actionArguments(session.slice(), first_action_id), "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}");

            var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
            try deny.key.set("deny-first");
            try deny.session.set(session.slice());
            const accepted = storage.decidePermission(&deny, .{});
            try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
            try std.testing.expectEqual(@as(usize, 1), (try store_core.publicConversationPageForTesting(&storage, public_request)).count);
            try std.testing.expect(storage.decidePermission(&deny, .{}).accepted.replayed);
            deny.action_id += 1;
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .conflict);

            var permission_update: wire_request.ConfigureCommand = .{};
            try permission_update.key.set("action-bypass");
            try permission_update.session.set(session.slice());
            permission_update.configuration.permission_mode.state = .value;
            try permission_update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&permission_update, .{}) == .accepted);
            const second_action_id = second: {
                const report_bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(report_bytes);
                const parsed = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                try std.testing.expectEqual(@as(usize, 1), parsed.value.actions.unresolved.len);
                const wire = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
                defer wire.deinit();
                const resolved = wire.value.object.get("actions").?.object.get("resolved").?.array.items[0].object;
                try std.testing.expectEqualStrings("0", resolved.get("call_ordinal").?.string);
                const presentation = resolved.get("presentation").?.object;
                try std.testing.expectEqualStrings("Run first command", presentation.get("line").?.object.get("before").?.string);
                try std.testing.expectEqualStrings("denied", presentation.get("code").?.string);
                try std.testing.expectEqual(std.json.Value.null, std.meta.activeTag(presentation.get("publication_position").?));
                const second = parsed.value.actions.unresolved[0];
                try std.testing.expectEqualStrings("1", second.call_ordinal);
                try std.testing.expectEqualStrings("1", second.permission_revision);
                break :second try std.fmt.parseInt(u64, second.action, 10);
            };
            try expectContent(&storage, try storage.actionCallId(session.slice(), second_action_id), "call-B");
            try expectContent(&storage, try storage.actionArguments(session.slice(), second_action_id), "{\"description\":\"Run second command\",\"cmd\":\"two\",\"timeout_ms\":null}");

            var stop = try completeSessionStop("action-stop", session.slice());
            const action_stop = storage.stopSession(&stop, .{});
            try std.testing.expect(action_stop == .accepted);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, action_stop.accepted.completion);
            const settled_page = try store_core.publicConversationPageForTesting(&storage, public_request);
            try std.testing.expectEqual(@as(usize, 3), settled_page.count);
            try std.testing.expect(settled_page.items[0].kind == .tool_result);
            try std.testing.expectEqual(settled_page.items[0].position, settled_page.items[1].position);
            try std.testing.expectEqual(@as(u64, 2), settled_page.items[0].ordinal);
            try std.testing.expectEqual(@as(u64, 1), settled_page.items[1].ordinal);
            try std.testing.expectEqualStrings("Run second command", settled_page.items[0].presentation.?.line.?.words.slice());
            try std.testing.expectEqualStrings("Run first command", settled_page.items[1].presentation.?.line.?.words.slice());
            try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, settled_page.items[1].presentation.?.code);
            for (settled_page.items[0..2]) |item| try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = public_request.session, .direction = .backward });
            var results: usize = 0;
            for (activity.items[0..activity.count]) |item| if (item.value == .tool_result) {
                const p = item.value.tool_result.presentation;
                try std.testing.expectEqual(item.position, p.publication_position.?);
                try std.testing.expectEqualStrings(if (item.ordinal == 1) "Run first command" else "Run second command", p.line.?.words.slice());
                results += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), results);
            var result_reader: ContentReader = undefined;
            result_reader.open(try storage.openPublicConversationContent(&.{
                .session = public_request.session,
                .position = settled_page.items[0].position,
                .ordinal = 2,
            }));
            result_reader.close();
            var stale: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
            try stale.key.set("stale-denial");
            try stale.session.set(session.slice());
            stale.decision = .allow_once;
            const rejected = storage.decidePermission(&stale, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.PermissionDecisionRejection.action_not_pending, rejected.rejected.code);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL", .{}));

            const full_bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(full_bytes);
            var full = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full_bytes, .{});
            defer full.deinit();
            const decisions = full.value.object.get("full").?.object.get("permission_decisions").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), decisions.len);
            try std.testing.expectEqualStrings("deny", decisions[0].object.get("decision").?.string);
            try std.testing.expectEqualStrings("accepted", decisions[0].object.get("status").?.string);
            try std.testing.expectEqualStrings("allow_once", decisions[1].object.get("decision").?.string);
            try std.testing.expectEqualStrings("rejected", decisions[1].object.get("status").?.string);

            try submitTestMessage(&storage, &tmp, "bypass-message", "bypass-message", session.slice(), "bypass proposal");
            const bypass_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, bypass_binding, "bypass-metadata");
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=1", .{}));
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=2 AND resolution_code IS NULL", .{}));

            try storage.close();
            storage_open = false;
            var reopened: Store = undefined;
            try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
            defer reopened.close() catch unreachable;
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&reopened, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=2 AND resolution_code IS NULL", .{}));
            const recovered_bytes = try testingSessionReport(&reopened, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(recovered_bytes);
            const recovered = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
            defer recovered.deinit();
            try std.testing.expectEqual(@as(usize, 2), recovered.value.actions.unresolved.len);
            for (recovered.value.actions.unresolved) |action| {
                try std.testing.expectEqualStrings("bypass", action.authorization);
                try std.testing.expectEqualStrings("2", action.permission_revision);
            }
        }
    }.run);
}

test "Action admission never visits an Action waiting for permission, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var rounds: [2]u16 = undefined;
            for (&rounds, 0..) |*cost, pass| {
                var name_buffer: [32]u8 = undefined;
                const session = try configureTestSessionAsk(&storage, try std.fmt.bufPrint(&name_buffer, "waiting-config-{d}", .{pass}));
                var message_buffer: [32]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, "waiting-message-{d}", .{pass});
                try submitTestMessage(&storage, &tmp, message, message, session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var metadata_buffer: [32]u8 = undefined;
                try settleTwoActionsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&metadata_buffer, "waiting-metadata-{d}", .{pass}));
                const counter = TwinRounds.start(&storage);
                try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})) == null);
                cost.* = counter.taken();
            }
            try std.testing.expectEqual(@as(u64, 4), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=0 AND resolution_code IS NULL", .{}));
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }
    }.run);
}

test "runner action seam covers selection admission input settlement stop and recovery" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = comptime testingHostToolRecords(&.{
                .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a docs page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            const write_rounds: u64 = if (case.rerun) 4 else 2;
            inline for (.{ .bash, .mcp, .read_image, .github_pr_watch }) |runner| {
                for (0..4) |scenario| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    var configure = try completeConfiguration("runner-seam", "", workspace, "model-a");
                    const tool = switch (runner) {
                        .bash => "bash",
                        .mcp => "fetch_page",
                        .read_image => "read_image",
                        .github_pr_watch => "watch_github_pr",
                        else => unreachable,
                    };
                    const arguments = switch (runner) {
                        .bash => "{\"cmd\":\"printf seam\",\"description\":\"Print seam\",\"timeout_ms\":5678}",
                        .read_image => "{\"path\":\"./image.png\"}",
                        .github_pr_watch => "{\"url\":\"https://github.com/org/repo/pull/42\"}",
                        else => "{}",
                    };
                    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
                    defer std.testing.allocator.free(encoded);
                    configure.configuration.tools = try .of(&.{tool});
                    configure.configuration.permission_mode.state = .value;
                    try configure.configuration.permission_mode.value.set("bypass");
                    const configured = try storage.configure(&configure, .{});
                    try std.testing.expect(configured == .accepted);
                    const session = configured.accepted.session;
                    try submitTestMessage(&storage, &tmp, "seam-input", "seam-message", session.slice(), "exercise runner seam");
                    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCallsForTesting(&storage, &tmp, model, "seam-calls", &.{
                        .{ .item_id = "seam-item", .name = tool, .encoded_call_id = "seam-call", .decoded_call_id = "seam-call", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments },
                    });
                    const selection_rounds = storage.testing_content_work.rounds;
                    const selected = (try storage.nextAction(runner, .{ .free_credit = .one, .mcp_open = true })).?;
                    if (runner == .bash) try std.testing.expectEqual(selection_rounds + 1, storage.testing_content_work.rounds);
                    inline for (.{ .bash, .mcp, .read_image, .github_pr_watch }) |other| {
                        if (runner != other) {
                            var wrong = selected;
                            wrong.runner = other;
                            try std.testing.expect((try storage.admitActionAttempt(wrong, 1234, .{})) == null);
                            try storage.resolveAction(wrong, .spawn_failed, "Wrong runner must not resolve.", .{});
                        }
                    }
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=0 AND resolution_code IS NULL", .{selected.action_id}));
                    try std.testing.expectEqual(runner, selected.runner);
                    try std.testing.expectEqual(selected.action_id, (try storage.nextAction(runner, .{ .free_credit = .one, .mcp_open = true })).?.action_id);
                    if (runner == .mcp) try std.testing.expectEqualStrings("docs", selected.server.slice());
                    const expected_code: []const u8 = switch (scenario) {
                        0 => "succeeded",
                        1 => "cancelled",
                        2 => "indeterminate",
                        else => "spawn_failed",
                    };
                    const expected_text: []const u8 = switch (scenario) {
                        0 => "Runner seam succeeded.",
                        1 => "Cancelled by Session stop.",
                        2 => switch (runner) {
                            .bash => "Bash outcome is indeterminate after Host recovery; the command was not replayed.",
                            .mcp => "Outcome unknown: the Host stopped while this MCP call was running; it was not retried.",
                            .read_image => "The Host stopped before saving this image read result. The read may have completed; it was not automatically repeated.",
                            .github_pr_watch => "The Host stopped while watching this pull request. The watch was not automatically repeated.",
                            else => unreachable,
                        },
                        else => "Runner seam rejected before execution.",
                    };
                    if (scenario == 1) {
                        var stop = try completeSessionStop("seam-stop", session.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                        try std.testing.expect((try storage.admitActionAttempt(selected, 1234, .{})) == null);
                        try storage.resolveAction(selected, .spawn_failed, "Stale stop selection must not resolve.", .{});
                    } else if (scenario == 3) {
                        const resolve_rounds = storage.testing_content_work.rounds;
                        try storage.resolveAction(selected, .spawn_failed, expected_text, .{});
                        if (runner == .bash) try std.testing.expectEqual(resolve_rounds + write_rounds, storage.testing_content_work.rounds);
                    } else {
                        const admission_rounds = storage.testing_content_work.rounds;
                        const binding = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
                        if (runner == .bash) try std.testing.expectEqual(admission_rounds + write_rounds, storage.testing_content_work.rounds);
                        try std.testing.expectEqual(selected.action_id, binding.action_id);
                        var input: action_domain.ActionExecutionInput = undefined;
                        try storage.readActionExecutionInput(runner, binding, &input);
                        try std.testing.expectEqualDeep(binding, input.binding);
                        try std.testing.expectEqualStrings(session.slice(), input.session.slice());
                        try std.testing.expectEqual(@as(usize, 32), input.sender_handle.slice().len);
                        try std.testing.expectEqual(@as(u64, if (runner == .bash) 5678 else 1234), input.timeout_ms);
                        try std.testing.expectEqual(@as(u64, arguments.len), input.arguments.length);
                        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(arguments), &input.arguments.digest);
                        inline for (.{ .bash, .mcp, .read_image, .github_pr_watch }) |other| {
                            if (runner != other) try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(other, binding, &input));
                        }
                        try storage.readActionExecutionInput(runner, binding, &input);
                        if (runner == .bash) {
                            try std.testing.expectEqualStrings(workspace, input.runner.bash.workspace.slice());
                        } else if (runner == .read_image) {
                            try std.testing.expectEqualStrings(workspace, input.runner.read_image.workspace.slice());
                        } else if (runner == .github_pr_watch) {
                            try std.testing.expectEqualStrings(workspace, input.runner.github_pr_watch.workspace.slice());
                        } else {
                            try std.testing.expect(input.runner.mcp.parent == null);
                            try std.testing.expectEqualStrings(session.slice(), input.runner.mcp.root.slice());
                            try std.testing.expectEqualStrings("fetch_page", input.runner.mcp.name.slice());
                            try std.testing.expectEqualStrings("docs", input.runner.mcp.server.slice());
                            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("{\"type\":\"object\"}"), &input.runner.mcp.input_schema.digest);
                        }
                        if (scenario == 0) {
                            try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(binding, .succeeded, expected_text, .{})).outcome);
                        } else {
                            try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                        }
                    }
                    try storage.resolveAction(selected, .spawn_failed, "Repeated resolution must not replace the result.", .{});
                    try std.testing.expect((try storage.nextAction(runner, .{ .free_credit = .one, .mcp_open = true })) == null);
                    try std.testing.expect((try storage.admitActionAttempt(selected, 1234, .{})) == null);
                    try std.testing.expect(!try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                    try std.testing.expectEqual(@as(u64, if (scenario == 0 or scenario == 2) 1 else 0), try store_testing.queryU64(&storage, "SELECT attempt_ordinal FROM action_operation WHERE action_id=?1", .{selected.action_id}));
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code=?2 AND c.digest=?3", .{ selected.action_id, expected_code, store_testing.Blob{ .bytes = &protocol.contentDigest(expected_text) } }));
                    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
                    defer std.testing.allocator.free(report);
                    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
                    defer parsed.deinit();
                    const actions = parsed.value.object.get("full").?.object.get("actions").?.array.items;
                    try std.testing.expectEqual(@as(usize, 1), actions.len);
                    try std.testing.expectEqualStrings(expected_code, actions[0].object.get("resolution").?.string);
                    try std.testing.expectEqualStrings(expected_text, actions[0].object.get("result").?.object.get("text").?.string);
                }
            }
        }
    }.run);
}

test "PRW-60 a settled watch call is selected only as a watch and reads its raw arguments" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const arguments = "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"octocat\"}";
            for ([_]enum { recovered, stopped }{ .recovered, .stopped }) |ending| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("watch-select", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                configure.configuration.tools = try .of(&.{"watch_github_pr"});
                const configured = try storage.configure(&configure, .{});
                try std.testing.expect(configured == .accepted);
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "watch-input", "watch-message", session.slice(), "watch");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, model, "watch-calls", &.{
                    .{ .item_id = "watch-item", .name = "watch_github_pr", .encoded_call_id = "watch-call", .decoded_call_id = "watch-call", .encoded_arguments = "{\\\"url\\\":\\\"https://github.com/org/repo/pull/42\\\",\\\"account\\\":\\\"octocat\\\"}", .decoded_arguments = arguments },
                });
                const capacity: action_domain.Capacity = .{ .free_credit = .one, .mcp_open = true };
                // Neither another runner's selection nor the Bash lane returns the watch; the core lane offers it
                // only as a watch, and only with a free credit, like `read_image`.
                try std.testing.expect((try storage.nextAction(.bash, capacity)) == null);
                try std.testing.expect((try storage.nextAction(.mcp, capacity)) == null);
                try std.testing.expect((try storage.nextAction(.read_image, capacity)) == null);
                try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .none, .mcp_open = true })) == null);
                try std.testing.expect((try storage.admitNextActionAttempt(capacity, 300_000, .{})) == null);
                try std.testing.expect((try storage.nextAction(.github_pr_watch, .{ .free_credit = .none, .mcp_open = true })) == null);
                const selected = (try storage.nextAction(.github_pr_watch, capacity)).?;
                const lane = (try storage.nextCoreWork(capacity)).?;
                try std.testing.expectEqual(selected.action_id, lane.github_pr_watch.action_id);
                try std.testing.expectEqual(tool_defs.Runner.github_pr_watch, lane.github_pr_watch.runner);
                try std.testing.expectEqual(tool_defs.Runner.github_pr_watch, selected.runner);
                const binding = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.github_pr_watch, binding, &input);
                try std.testing.expectEqual(@as(u64, arguments.len), input.arguments.length);
                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(arguments), &input.arguments.digest);
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.read_image, binding, &input));
                try std.testing.expect((try storage.nextAction(.github_pr_watch, capacity)) == null);
                try std.testing.expect((try storage.nextCoreWork(capacity)) == null);
                const text: []const u8 = switch (ending) {
                    .recovered => "The Host stopped while watching this pull request. The watch was not automatically repeated.",
                    .stopped => "Stopped before this pull request watch completed.",
                };
                const code: []const u8 = if (ending == .recovered) "indeterminate" else "cancelled";
                switch (ending) {
                    .recovered => try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty())),
                    .stopped => {
                        var stop = try completeSessionStop("watch-stop", session.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                        try std.testing.expectEqual(ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(binding, .succeeded, "Watch finished.", .{})).outcome);
                    },
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code=?2 AND c.digest=?3", .{ selected.action_id, code, store_testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
            }
        }
    }.run);
}

test "read_image exact permission frozen workspace capacity background and stop share the Action owner" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try completeConfiguration("image-permission", "", workspace, "model-a");
                configure.configuration.tools = try .of(&.{"read_image"});
                try configure.configuration.permission_mode.value.set("ask");
                const configured = try storage.configure(&configure, .{});
                try std.testing.expect(configured == .accepted);
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "image-input", "image-message", session.slice(), "inspect");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, model, "image-calls", &.{
                    .{ .item_id = "image-item", .name = "read_image", .encoded_call_id = "image-call", .decoded_call_id = "image-call", .encoded_arguments = "{\\\"path\\\":\\\"missing.png\\\"}", .decoded_arguments = "{\"path\":\"missing.png\"}" },
                });
                const action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
                const forged: action_domain.ReadyAction = .{ .action_id = action_id, .runner = .read_image };
                try std.testing.expect((try storage.nextAction(.read_image, .fromFree(1, false))) == null);
                try std.testing.expect((try storage.nextAction(.bash, .fromFree(1, false))) == null);
                try std.testing.expect((try storage.admitActionAttempt(forged, 1234, .{})) == null);
                const unattempted: action_domain.ActionAttemptBinding = .{ .action_id = action_id, .parent_operation_id = model.operation_id, .turn_id = model.turn_id };
                var input: action_domain.ActionExecutionInput = undefined;
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.read_image, unattempted, &input));
                var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
                try allow.key.set("image-allow");
                try allow.session.set(session.slice());
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                if (background) {
                    var promotion: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = action_id };
                    try promotion.key.set("image-background");
                    try promotion.session.set(session.slice());
                    try std.testing.expect(storage.backgroundAction(.{ .command = &promotion }, .{}) == .accepted);
                }
                var patch: wire_request.ConfigureCommand = .{};
                try patch.key.set("image-workspace-change");
                try patch.session.set(session.slice());
                patch.configuration.workspace.state = .value;
                try patch.configuration.workspace.value.set("/");
                const refused_workspace = try storage.configure(&patch, .{});
                try std.testing.expect(refused_workspace == .rejected and refused_workspace.rejected.code == .workspace_is_immutable);
                var update: wire_request.ConfigureCommand = .{};
                try update.key.set("image-config-change");
                try update.session.set(session.slice());
                update.configuration.tools = try .of(&.{});
                update.configuration.permission_mode.state = .value;
                try update.configuration.permission_mode.value.set("bypass");
                try std.testing.expect((try storage.configure(&update, .{})) == .accepted);
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expect(storage.decidePermission(&allow, .{}).accepted.replayed);
                for ([_]bool{ false, true }) |mcp_open| {
                    try std.testing.expect((try storage.nextAction(.read_image, .fromFree(0, mcp_open))) == null);
                    try std.testing.expect((try storage.nextCoreWork(.fromFree(0, mcp_open))) == null);
                    const blocked = try storage.dispatchWork(false, .fromFree(0, mcp_open));
                    try std.testing.expect(!blocked.mcp and !blocked.bash and !blocked.core);
                    const ready = (try storage.nextAction(.read_image, .fromFree(1, mcp_open))).?;
                    try std.testing.expectEqual(action_id, ready.action_id);
                    try std.testing.expectEqual(background, ready.background);
                    try std.testing.expectEqualDeep(action_domain.ReadyAction{ .action_id = action_id, .runner = .read_image, .background = background }, (try storage.nextCoreWork(.fromFree(1, mcp_open))).?.read_image);
                    const work = try storage.dispatchWork(false, .fromFree(1, mcp_open));
                    try std.testing.expect(work.mcp and !work.bash and !work.core);
                    try std.testing.expect((try storage.admitNextActionAttempt(.fromFree(1, mcp_open), 1234, .{})) == null);
                }
                const selected = (try storage.nextAction(.read_image, .fromFree(1, false))).?;
                const binding = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
                try storage.readActionExecutionInput(.read_image, binding, &input);
                try std.testing.expectEqualStrings(workspace, input.runner.read_image.workspace.slice());
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.bash, binding, &input));
                var wrong = binding;
                wrong.turn_id += 1;
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.read_image, wrong, &input));
                wrong = binding;
                wrong.parent_operation_id += 1;
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.read_image, wrong, &input));
                try std.testing.expect((try storage.admitActionAttempt(selected, 1234, .{})) == null);
                var stop = try completeSessionStop("image-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(binding, .succeeded, "Image read finished.", .{})).outcome);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='cancelled' AND c.digest=?2", .{ action_id, store_testing.Blob{ .bytes = &protocol.contentDigest("Stopped before this image read completed.") } }));
                try std.testing.expectError(error.StaleActionAttemptBinding, storage.readActionExecutionInput(.read_image, binding, &input));
            }
        }
    }.run);
}

test "Action read covers permission queue attempt and immutable final paging" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const status = @import("../../action_read.zig");
            const repeats = status.window_bytes / 3 + 3;
            const large = "a" ++ @as([3 * repeats]u8, @bitCast(@as([repeats][3]u8, @splat("雪".*))));
            for ([_][]const u8{ "done", large }) |bytes| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "read-session");
                const other = try configureTestSessionAsk(&storage, "other-session");
                try submitTestMessage(&storage, &tmp, "read-input", "read-message", session.slice(), "propose");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, model, "read-calls");
                const action = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
                const sibling = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
                var result: status.Read = undefined;
                var deny: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = sibling, .decision = .deny };
                try deny.key.set("read-deny");
                try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
                try NativePromotion.expectCount(&storage, &tmp, session.slice(), "2");
                try storage.readAction(&.{ .session = session, .action_id = sibling }, &result);
                try std.testing.expect(result.status == .resolved);
                try std.testing.expectEqualStrings("denied", result.status.resolved.resolution.code.slice());
                const request: status.Request = .{ .session = session, .action_id = action };
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .pending and result.status.pending == .waiting_approval);
                try std.testing.expectError(error.ActionNotFound, storage.readAction(&.{ .session = other, .action_id = action }, &result));
                try std.testing.expectError(error.ActionNotFound, storage.readAction(&.{ .session = session, .action_id = 0 }, &result));
                try std.testing.expectError(error.ActionNotFound, storage.readAction(&.{ .session = session, .action_id = std.math.maxInt(i64) }, &result));
                try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = 1 }, &result));
                var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
                try allow.key.set("read-allow");
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .pending and result.status.pending == .queued);
                const binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 30_000, .{})).?.permit.binding;
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .pending and result.status.pending == .attempted);
                try std.testing.expectError(error.InvalidActionResult, storage.settleActionAttempt(binding, .succeeded, "", .{}));
                try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(binding, .succeeded, bytes, .{})).outcome);
                try NativePromotion.expectCount(&storage, &tmp, session.slice(), "2");
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .resolved);
                const first = result.status.resolved;
                try std.testing.expectEqualStrings("succeeded", first.resolution.code.slice());
                try std.testing.expectEqual(bytes.len, first.resolution.content.text.length);
                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(bytes), &first.resolution.content.text.digest);
                try std.testing.expectEqualSlices(u8, bytes[0..first.window.next], first.window.text.slice());
                try std.testing.expect(first.window.more == (bytes.len > status.window_bytes));
                try std.testing.expect(std.unicode.utf8ValidateSlice(first.window.text.slice()));
                if (first.window.more) {
                    try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = 2 }, &result));
                    try storage.readAction(&.{ .session = session, .action_id = action, .offset = first.window.next }, &result);
                    try std.testing.expect(!result.status.resolved.window.more);
                    try std.testing.expectEqualSlices(u8, bytes[first.window.next..], result.status.resolved.window.text.slice());
                }
                try storage.readAction(&.{ .session = session, .action_id = action, .offset = bytes.len }, &result);
                try std.testing.expectEqualStrings("", result.status.resolved.window.text.slice());
                try std.testing.expect(!result.status.resolved.window.more);
                try std.testing.expectError(error.InvalidCursor, storage.readAction(&.{ .session = session, .action_id = action, .offset = bytes.len + 1 }, &result));
                try storage.readAction(&request, &result);
                try std.testing.expectEqualDeep(first, result.status.resolved);
                try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 30_000, .{})) == null);
            }
        }
    }.run);
}

const NativePromotion = struct {
    fn expectCount(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, expected: []const u8) !void {
        const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqualStrings(expected, report.value.actions.count);
    }

    fn uncoveredBytes(storage: *Store, session: []const u8, covered: u64) !u64 {
        const admission = @import("../domain/model_admission.zig");
        const Query = admission.compaction_failures[3][0];
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var access: @import("../domain/reads.zig").ReadAccess = .open(&entry);
        defer access.deinit();
        var row: Query.Result = undefined;
        access.read(Query, .{ .session = session, .covered = covered, .frontier = 0, .results = 0 }, &row);
        try entry.finish(store_core.Ordinary.none, access.run());
        return row.uncovered_bytes orelse return error.TestUnexpectedResult;
    }

    fn propose(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !u64 {
        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "task-{s}", .{session});
        try submitTestMessage(storage, tmp, "input", key, session, "Run the tool.");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const arguments = "{\"description\":\"Held tool\",\"cmd\":\"true\"}";
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
        defer std.testing.allocator.free(encoded);
        try settleCallsForTesting(storage, tmp, model, "calls", &.{.{
            .item_id = "call-item",
            .name = "bash",
            .encoded_call_id = "call-id",
            .decoded_call_id = "call-id",
            .encoded_arguments = encoded[1 .. encoded.len - 1],
            .decoded_arguments = arguments,
        }});
        return store_testing.queryU64(storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
    }

    fn sendPeer(storage: *Store, tmp: *std.testing.TmpDir, sender: []const u8, target: []const u8, text: []const u8) !u64 {
        const binding = try shared_fixtures.proposeMessageAgent(storage, tmp, sender, target, text);
        try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(binding, target, text, .{}));
        return binding.action_id;
    }

    fn command(session: []const u8, key: []const u8, action: u64) !@import("../../command_input.zig").ActionBackgroundCommand {
        var result: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = action };
        try result.session.set(session);
        try result.key.set(key);
        return result;
    }

    fn promoted(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !u64 {
        const action = try propose(storage, tmp, session);

        var key: [64]u8 = undefined;
        var request = try command(session, try std.fmt.bufPrint(&key, "promote-{s}", .{session}), action);
        try std.testing.expect(storage.backgroundAction(.{ .command = &request }, .{}) == .accepted);
        return action;
    }

    fn finishModel(storage: *Store, tmp: *std.testing.TmpDir, binding: store_core.AttemptBinding) !void {
        try store_testing.settleItemsForTesting(storage, tmp, binding, &.{"{\"type\":\"message\",\"id\":\"answer-item\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
    }

    fn expectReported(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, action: u64, visible: bool, actionable: bool) !void {
        const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer decoded.deinit();
        const report = decoded.value.object;
        const pending = report.get("actions").?.object.get("unresolved").?.array.items;
        const permissions = report.get("actionable_permissions").?.array.items;
        try std.testing.expectEqual(@as(usize, if (visible) 1 else 0), pending.len);
        try std.testing.expectEqual(@as(usize, if (actionable) 1 else 0), permissions.len);
        if (visible) try std.testing.expectEqual(action, try std.fmt.parseInt(u64, pending[0].object.get("action").?.string, 10));
        if (actionable) try std.testing.expectEqual(action, try std.fmt.parseInt(u64, permissions[0].object.get("action").?.string, 10));
        const expected: ?u64 = if (actionable) action else null;
        const first = report.get("work").?.object.get("first_action").?;
        try std.testing.expectEqual(expected, if (first == .null) null else @as(?u64, try std.fmt.parseInt(u64, first.string, 10)));
        var request: protocol.ActivityPage = .{};
        try request.session.set(session);
        const page = store_core.activityPageForTesting(storage, request) catch |err| {
            std.debug.print("native promotion Activity read: {s} visible={any} actionable={any}\n", .{ @errorName(err), visible, actionable });
            return err;
        };
        try std.testing.expectEqual(expected, page.work.work.first_action);
    }
};

test "native promotion keeps one attempted invocation and receipt while final input wakes the Session" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try NativePromotion.propose(&storage, &tmp, session.slice());
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
            const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
            var input: action_domain.ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, binding, &input);
            const sender = input.sender_handle;
            const arguments = input.arguments;

            var command = try NativePromotion.command(session.slice(), "promote-existing-attempt", action);
            const accepted = storage.backgroundAction(.{ .command = &command }, .{});
            try std.testing.expect(accepted == .accepted and accepted.accepted.selection.kind == .background);
            const receipt_position = accepted.accepted.selection.position;
            const receipt_content = try store_testing.queryU64(&storage, "SELECT background_content_id FROM action_operation WHERE action_id=?1", .{action});
            try storage.readActionExecutionInput(.bash, binding, &input);
            try std.testing.expectEqualSlices(u8, sender.slice(), input.sender_handle.slice());
            try std.testing.expectEqualDeep(arguments, input.arguments);
            try std.testing.expectEqual(@as(u64, 30_000), input.timeout_ms);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.expectCount(&storage, &tmp, session.slice(), "1");
            try NativePromotion.finishModel(&storage, &tmp, continuation);
            try NativePromotion.expectCount(&storage, &tmp, session.slice(), "1");
            const uncovered_before = try NativePromotion.uncoveredBytes(&storage, session.slice(), receipt_position - 1);
            const covered_before = try NativePromotion.uncoveredBytes(&storage, session.slice(), receipt_position);
            const receipt_bytes = try store_testing.queryU64(&storage, "SELECT byte_length FROM content WHERE content_id=?1", .{receipt_content});
            try std.testing.expectEqual(receipt_bytes, uncovered_before - covered_before);
            try std.testing.expectEqual(ActionSettlement.Outcome.effect, (try storage.settleActionAttempt(binding, .succeeded, "One invocation's final", .{})).outcome);
            try NativePromotion.expectCount(&storage, &tmp, session.slice(), "0");
            try std.testing.expectEqual(uncovered_before + "One invocation's final".len, try NativePromotion.uncoveredBytes(&storage, session.slice(), receipt_position - 1));
            try std.testing.expectEqual(covered_before + "One invocation's final".len, try NativePromotion.uncoveredBytes(&storage, session.slice(), receipt_position));

            const replay = storage.backgroundAction(.{ .command = &command }, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(receipt_position, replay.accepted.selection.position);
            var read: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &read);
            try std.testing.expect(read.status == .resolved);
            try std.testing.expectEqualStrings("succeeded", read.status.resolved.resolution.code.slice());
            try std.testing.expectEqualStrings("One invocation's final", read.status.resolved.window.text.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND background_position=?2 AND background_content_id=?3 AND resolution_code='succeeded'", .{ action, receipt_position, receipt_content }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .failed, "Replacement", .{}));
        }
    }.run);
}

test "native promotion rollback and target refusal leave the original foreground wait unchanged" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            const other = try configureTestSessionAsk(&storage, "other");
            const action = try NativePromotion.propose(&storage, &tmp, session.slice());

            var request = try NativePromotion.command(session.slice(), "foreign", action);
            request.session = other;
            const foreign = storage.backgroundAction(.{ .command = &request }, .{});
            try std.testing.expect(foreign == .rejected and foreign.rejected.code == .target_mismatch);
            request.session = session;
            try request.key.set("rollback");
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try std.testing.expect(storage.backgroundAction(.{ .command = &request }, .{ .before_commit = true }) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expectEqual(contents, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key='rollback'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE background_position IS NOT NULL OR attempt_ordinal!=0 OR resolution_code IS NOT NULL", .{}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const accepted = storage.backgroundAction(.{ .command = &request }, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(action, (try storage.nextAction(.bash, .fromFree(1, true))).?.action_id);
            try std.testing.expectEqual(action, (try storage.nextAction(.bash, .fromFree(2, true))).?.action_id);
        }
    }.run);
}

test "native promotion preserves old Turn approval discovery without launching before permission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { allow, deny, stop }{ .allow, .deny, .stop }) |choice| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "configure");
                const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, true, true);
                try NativePromotion.finishModel(&storage, &tmp, continuation);
                try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, true, true);
                try std.testing.expect((try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})) == null);
                if (choice == .stop) {
                    var stop = try completeSessionStop("stop-pending", session.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                } else {
                    var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = if (choice == .allow) .allow_once else .deny };
                    try decision.key.set("decide-old-turn");
                    try std.testing.expect(storage.decidePermission(&decision, .{}) == .accepted);
                    if (choice == .allow) {
                        const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
                        try std.testing.expectEqual(action, selected.action_id);
                        const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
                        _ = try storage.settleActionAttempt(binding, .succeeded, "Approved after Turn ended", .{});
                    }
                }
                try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, false, false);
                try std.testing.expectEqual(choice != .stop, (try storage.admitNextModelAttempt(.{})) != null);
            }
        }
    }.run);
}

test "native promotion Session stop reaches old background Actions through attached descendants but not standalone Sessions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try shared_fixtures.configureTestSessionWithMode(&storage, "root", "bypass");
            const standalone = try shared_fixtures.configureTestSessionWithMode(&storage, "standalone", "bypass");
            var sessions: [4]@TypeOf(root) = .{ root, undefined, undefined, standalone };
            for (1..3) |depth| {
                var request: @import("../../wire_request.zig").ConfigureCommand = .{};
                var key: [32]u8 = undefined;
                try request.key.set(try std.fmt.bufPrint(&key, "attached-{d}", .{depth}));
                request.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, "bypass");
                request.configuration.parent.state = .value;
                try request.configuration.parent.value.set(sessions[depth - 1].slice());
                sessions[depth] = (try storage.configure(&request, .{})).accepted.session;
            }
            var bindings: [4]@import("../domain/action.zig").ActionAttemptBinding = undefined;
            for (sessions, 0..) |session, index| {
                _ = try NativePromotion.promoted(&storage, &tmp, session.slice());
                bindings[index] = (try storage.admitNextActionAttempt(.{ .free_credit = .multiple, .mcp_open = true }, 30_000, .{})).?.permit.binding;
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try NativePromotion.finishModel(&storage, &tmp, continuation);
            }
            var stop = try shared_fixtures.completeSessionStop("stop-root", root.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[0])) != null);
            try std.testing.expect((try storage.actionSupersededByStop(bindings[3])) == null);
            for (1..3) |depth| {
                const work = (try storage.nextCoreWork(.{ .free_credit = .multiple, .mcp_open = false })) orelse return error.MissingOwedDescendantStop;
                try std.testing.expect(work == .stop);
                try std.testing.expectEqualStrings(sessions[depth].slice(), work.stop.session.slice());
                var owed: protocol.SessionStopCommand = .{ .key = work.stop.key, .session = sessions[depth] };
                try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
                try std.testing.expect((try storage.actionSupersededByStop(bindings[depth])) != null);
                try std.testing.expect((try storage.actionSupersededByStop(bindings[3])) == null);
            }
            const admissions = try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{});
            for (bindings, 0..) |binding, index| {
                _ = try storage.settleActionAttempt(binding, .succeeded, "Final evidence", .{});

                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ binding.action_id, if (index == 3) @as([]const u8, "succeeded") else "cancelled" }));
            }
            try std.testing.expectEqual(admissions + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            const wake = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(bindings[3].action_id, try store_testing.queryU64(&storage, "SELECT source_action_id FROM message_admission WHERE turn_id=?1", .{wake.turn_id}));
        }
    }.run);
}

test "native promotion Host death delivers one final Resolution without resuming or retrying the Action" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const binding = (try storage.admitNextActionAttempt(.{ .free_credit = .multiple, .mcp_open = true }, 30_000, .{})).?.permit.binding;
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.finishModel(&storage, &tmp, continuation);
            var status: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &status);
            try std.testing.expect(status.status == .pending);
            const receipt = try store_testing.queryU64(&storage, "SELECT background_position FROM action_operation WHERE action_id=?1", .{action});
            try storage.close();
            opened = false;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            const active = @import("../domain/action.zig").ActiveOperationFilter.empty();
            try std.testing.expect(try storage.recoverOneUncertainAction(active));
            try std.testing.expect(!try storage.recoverOneUncertainAction(active));
            try std.testing.expect((try storage.admitNextActionAttempt(.{ .free_credit = .multiple, .mcp_open = true }, 30_000, .{})) == null);
            try storage.readAction(&.{ .session = session, .action_id = action }, &status);
            try std.testing.expectEqual(receipt, try store_testing.queryU64(&storage, "SELECT background_position FROM action_operation WHERE action_id=?1", .{action}));
            try std.testing.expect(status.status == .resolved);
            try std.testing.expectEqualStrings("indeterminate", status.status.resolved.resolution.code.slice());
            try std.testing.expect(std.mem.indexOf(u8, status.status.resolved.window.text.slice(), "not replayed") != null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND background_position=?2", .{ action, receipt }));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN action_operation a ON a.action_id=m.source_action_id WHERE a.action_id=?1 AND m.content_id=a.resolution_content_id", .{action}));
            try storage.close();
            opened = false;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try std.testing.expect(!try storage.recoverOneUncertainAction(active));
            const wake = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.finishModel(&storage, &tmp, wake);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .succeeded, "Cannot replace recovery evidence", .{}));
        }
    }.run);
}

test "native promotion reports stopped Actions until settlement while suppressing approval and dispatch" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |terminal| {
                for ([_]bool{ false, true }) |owed| {
                    for ([_]bool{ false, true }) |attempted| {
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        var storage: Store = undefined;
                        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                        defer storage.close() catch unreachable;
                        const root = try configureTestSessionAsk(&storage, "root");
                        const session = if (owed) child: {
                            var child: wire_request.ConfigureCommand = .{};
                            try child.key.set("child");
                            child.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, "ask");
                            child.configuration.parent.state = .value;
                            try child.configuration.parent.value.set(root.slice());
                            break :child (try storage.configure(&child, .{})).accepted.session;
                        } else root;
                        const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                        const binding: ?action_domain.ActionAttemptBinding = if (attempted) held: {
                            var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
                            try allow.key.set("allow-held");
                            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                            break :held (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                        } else null;
                        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        if (terminal) try NativePromotion.finishModel(&storage, &tmp, continuation);
                        try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, true, !attempted);
                        var stop = try completeSessionStop("stop-selected", root.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                        try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, owed or attempted, false);
                        try std.testing.expect((try storage.nextAction(.bash, .fromFree(2, true))) == null);
                        if (owed) {
                            const selected = (try storage.nextCoreWork(.fromFree(2, false))).?;
                            try std.testing.expect(selected == .stop);
                            try std.testing.expectEqualStrings(session.slice(), selected.stop.session.slice());
                            var child_stop: protocol.SessionStopCommand = .{ .key = selected.stop.key, .session = session };
                            try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
                        }
                        try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, attempted, false);
                        if (terminal and attempted) {
                            const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                            defer std.testing.allocator.free(bytes);
                            const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                            defer report.deinit();
                            try std.testing.expectEqualStrings("1", report.value.object.get("actions").?.object.get("count").?.string);
                        }
                        if (binding) |held| {
                            try std.testing.expect((try storage.actionSupersededByStop(held)) != null);
                            _ = try storage.settleActionAttempt(held, .succeeded, "Terminal evidence after stop", .{});
                        }
                        try NativePromotion.expectReported(&storage, &tmp, session.slice(), action, false, false);
                        if (terminal) {
                            const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                            defer std.testing.allocator.free(bytes);
                            const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                            defer report.deinit();
                            try std.testing.expectEqualStrings("0", report.value.object.get("actions").?.object.get("count").?.string);
                        }
                    }
                }
            }
        }
    }.run);
}

test "background final input joins the next Turn boundary without changing an in-flight request and wakes idle Sessions once" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { running, answered, reopened_idle }{ .running, .answered, .reopened_idle }) |timing| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
                const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                const effect = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const cutoff = try store_testing.queryU64(&storage, "SELECT input_cutoff FROM model_operation WHERE operation_id=?1", .{current.operation_id});
                if (timing != .running) try NativePromotion.finishModel(&storage, &tmp, current);
                if (timing == .reopened_idle) {
                    try storage.close();
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                }
                const text = "Final result \u{96ea}\nwith original bytes";
                _ = try storage.settleActionAttempt(effect, .succeeded, text, .{});
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN action_operation a ON a.action_id=m.source_action_id WHERE a.action_id=?1 AND m.content_id=a.resolution_content_id AND m.turn_id IS NULL", .{action}));
                // The current request remains frozen. No final can interrupt it.
                try std.testing.expectEqual(cutoff, try store_testing.queryU64(&storage, "SELECT input_cutoff FROM model_operation WHERE operation_id=?1", .{current.operation_id}));
                if (timing == .running) {
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                    const arguments = "{\"description\":\"Continue the running Turn\",\"cmd\":\"true\"}";
                    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, arguments, .{});
                    defer std.testing.allocator.free(encoded);
                    try settleCallsForTesting(&storage, &tmp, current, "next-calls", &.{.{
                        .item_id = "next-call-item",
                        .name = "bash",
                        .encoded_call_id = "next-call-id",
                        .decoded_call_id = "next-call-id",
                        .encoded_arguments = encoded[1 .. encoded.len - 1],
                        .decoded_arguments = arguments,
                    }});
                    const sibling = (try storage.admitNextActionAttempt(.fromFree(1, true), 30_000, .{})).?.permit.binding;
                    _ = try storage.settleActionAttempt(sibling, .succeeded, "Continued", .{});
                }
                // Replay and a restart see the same one immutable admission.

                var replay = try NativePromotion.command(session.slice(), "fresh-control-after-final", action);
                try std.testing.expect(storage.backgroundAction(.{ .command = &replay }, .{}) == .accepted);
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (timing == .running) {
                    try std.testing.expectEqual(current.turn_id, next.turn_id);
                    try std.testing.expectEqual(current.turn_id, try store_testing.queryU64(&storage, "SELECT turn_id FROM message_admission WHERE source_action_id=?1", .{action}));
                } else try std.testing.expect(current.turn_id != next.turn_id);
                var page: store_testing.TestingPage = undefined;
                page.open(&storage, next);
                defer page.close();
                var position: u64 = 0;
                var finals: usize = 0;
                while (try page.nextEntry(position)) |entry| {
                    position = entry.position;
                    if (entry.kind == .tool_results) {
                        while (try page.nextToolResult()) |_| {}
                    }
                    if (entry.source_action) |source| {
                        try std.testing.expectEqual(action, source.id);
                        try std.testing.expectEqualStrings(session.slice(), &source.session);
                        var reader: store_testing.TestingReader = undefined;
                        try page.openContent(entry.content.?, &reader);
                        defer reader.close();
                        var bytes: [128]u8 = undefined;
                        const count = try reader.read(0, &bytes);
                        try std.testing.expectEqualStrings(text, bytes[0..count]);
                        finals += 1;
                    }
                }
                try std.testing.expectEqual(@as(usize, 1), finals);
                const activity = try store_core.activityPageForTesting(&storage, .{ .session = session });
                var received: usize = 0;
                for (activity.items[0..activity.count]) |item| switch (item.value) {
                    .received, .user => |message| if (message.origin == .action) {
                        try std.testing.expectEqual(action, message.origin.action);
                        try std.testing.expectEqual(@as(u64, text.len), message.content.text.length);
                        try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &message.content.text.digest);
                        if (item.value == .received) received += 1;
                    },
                    else => {},
                };
                try std.testing.expectEqual(@as(usize, 1), received);
                const person = try store_core.activityPageForTesting(&storage, .{ .session = session, .kinds = .initOne(.admission) });
                for (person.items[0..person.count]) |item| try std.testing.expect(item.value.admission.origin == .person);
                const public = try store_core.publicConversationPageForTesting(&storage, .{ .session = session });
                var projected: usize = 0;
                for (public.items[0..public.count]) |item| if (item.source_action) |source| {
                    try std.testing.expectEqual(action, source);
                    try std.testing.expect(item.sender == null);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &item.content.text.digest);
                    projected += 1;
                };
                try std.testing.expectEqual(@as(usize, 1), projected);
                try NativePromotion.finishModel(&storage, &tmp, next);
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
            }
        }
    }.run);
}

test "background final input covers every live Action Resolution without a second payload" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(action_domain.ActionResolutionCode)) |code| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
                const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                const effect = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try NativePromotion.finishModel(&storage, &tmp, current);
                _ = try storage.settleActionAttempt(effect, code, @tagName(code), .{});
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN action_operation a ON a.action_id=m.source_action_id WHERE a.action_id=?1 AND m.content_id=a.resolution_content_id AND a.resolution_code=?2", .{ action, @tagName(code) }));
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
            }
        }
    }.run);
}

test "background final input and Resolution roll back together then recover once across Host restarts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const effect = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.finishModel(&storage, &tmp, current);
            try std.testing.expectError(error.InjectedCommitFailure, storage.settleActionAttempt(effect, .succeeded, "Rolled back", .{ .before_commit = true }));
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NOT NULL", .{action}));
            try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
            for (0..2) |_| {
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                try std.testing.expect(!try storage.recoverOneUncertainAction(.empty()));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
            }
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
        }
    }.run);
}

test "background final input from stopped and archived sources never restarts their Session" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |archive| {
                for ([_]bool{ false, true }) |recover| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
                    const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                    const effect = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                    const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try NativePromotion.finishModel(&storage, &tmp, current);
                    if (archive) {
                        var command: protocol.SessionArchiveCommand = .{ .session = session, .archived = true };
                        try command.key.set("archive-source");
                        try std.testing.expect(storage.archiveSession(&command, .{}) == .accepted);
                    } else {
                        var command = try completeSessionStop("stop-source", session.slice());
                        try std.testing.expect(storage.stopSession(&command, .{}) == .accepted);
                    }
                    if (recover) {
                        try storage.close();
                        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                        try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
                    } else {
                        _ = try storage.settleActionAttempt(effect, .cancelled, "Stopped", .{});
                        try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(effect, .cancelled, "Stopped twice", .{}));
                    }
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NOT NULL", .{action}));
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                }
            }
        }
    }.run);
}

test "background final input admitted before Session stop remains admitted without a fabricated Turn" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const effect = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.finishModel(&storage, &tmp, current);
            _ = try storage.settleActionAttempt(effect, .succeeded, "Before stop", .{});
            const position = try store_testing.queryU64(&storage, "SELECT admission_position FROM message_admission WHERE source_action_id=?1", .{action});
            var stop = try completeSessionStop("stop-after-admission", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1 AND admission_position=?2 AND turn_id IS NULL", .{ action, position }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expectEqual(position, try store_testing.queryU64(&storage, "SELECT admission_position FROM message_admission WHERE source_action_id=?1", .{action}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        }
    }.run);
}

test "native promotion replays an old capacity refusal while fresh selection has no capacity policy" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
            var old = try NativePromotion.command(session.slice(), "old-capacity-refusal", 0);
            try std.testing.expect(storage.backgroundAction(.{ .command = &old }, .{}) == .rejected);
            try store_testing.exec(&storage, "UPDATE core_command SET code='background_unavailable' WHERE command_key=?1", .{old.key.slice()});
            const replay = storage.backgroundAction(.{ .command = &old }, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqual(@import("../../action_control.zig").Rejection.background_unavailable, replay.rejected.code);
            const action = try NativePromotion.propose(&storage, &tmp, session.slice());
            var fresh = try NativePromotion.command(session.slice(), "fresh-promotion", action);
            try std.testing.expect(storage.backgroundAction(.{ .command = &fresh }, .{}) == .accepted);
        }
    }.run);
}

test "automatic background promotion shares receipts replay stop and the original timeout" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { success, stopped, final }{ .success, .stopped, .final }) |state| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "configure", "bypass");
                const action = try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 1234, .{})).?.permit.binding;
                const deadline = try store_testing.queryU64(&storage, "SELECT attempt_timeout_ms FROM action_operation WHERE action_id=?1", .{action});
                if (state == .stopped) {
                    var stop = try completeSessionStop("stop", session.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                }
                if (state == .final) _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
                const reply = storage.backgroundAction(.{ .live_action = action }, .{});
                if (state == .stopped) {
                    try std.testing.expectEqual(@import("../../action_control.zig").Rejection.source_stopped, reply.rejected.code);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND background_position IS NOT NULL", .{action}));
                } else {
                    try std.testing.expectEqual(if (state == .final) .final else @as(@FieldType(@import("../../action_control.zig").Selection, "kind"), .background), reply.accepted.selection.kind);
                    const replay = storage.backgroundAction(.{ .live_action = action }, .{});
                    try std.testing.expect(replay.accepted.replayed);
                    try std.testing.expectEqual(reply.accepted.selection, replay.accepted.selection);
                    try std.testing.expectEqual(deadline, try store_testing.queryU64(&storage, "SELECT attempt_timeout_ms FROM action_operation WHERE action_id=?1", .{action}));
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT attempt_ordinal FROM action_operation WHERE action_id=?1", .{action}));
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
                }
            }
        }
    }.run);
}

test "background owed stop suppresses final admission across settlement recovery and permission decisions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { settle, recover, deny }{ .settle, .recover, .deny }) |ending| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const parent = try shared_fixtures.configureTestSessionWithMode(&storage, "parent", "bypass");
                var configure: wire_request.ConfigureCommand = .{};
                try configure.key.set("attached-child");
                configure.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, if (ending == .deny) "ask" else "bypass");
                configure.configuration.parent.state = .value;
                try configure.configuration.parent.value.set(parent.slice());
                const child = (try storage.configure(&configure, .{})).accepted.session;
                const action = try NativePromotion.promoted(&storage, &tmp, child.slice());
                const binding = if (ending != .deny) (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding else null;
                var stop = try completeSessionStop("stop-parent", parent.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_stop_owed WHERE child_ref=?1 AND settled=0", .{child.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_stop WHERE session_ref=?1", .{child.slice()}));
                switch (ending) {
                    .settle => {
                        try std.testing.expectEqual(ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(binding.?, .succeeded, "Final after parent stop", .{})).outcome);
                        try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding.?, .succeeded, "Duplicate", .{}));
                    },
                    .recover => {
                        try storage.close();
                        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                        try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                        try std.testing.expect(!try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                    },
                    .deny => {
                        var decision: @import("../../command_input.zig").PermissionDecisionCommand = .{ .action_id = action, .decision = .deny, .session = child };
                        try decision.key.set("deny-after-parent-stop");
                        try std.testing.expect(storage.decidePermission(&decision, .{}) == .accepted);
                    },
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NOT NULL", .{action}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
                const operations = try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation", .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                const work = (try storage.nextCoreWork(.fromFree(2, true))).?.stop;
                var owed: protocol.SessionStopCommand = .{ .key = work.key, .session = child };
                try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try std.testing.expectEqual(operations, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation", .{}));
            }
        }
    }.run);
}

test "queue records source kinds and source predicates for person peer and action final" {
    const sourced_input = @import("../domain/sourced_input.zig");
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { person, peer, action_final }{ .person, .peer, .action_final }) |source| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const parent = try shared_fixtures.configurePeerSender(&storage, "source-parent");
                var configure: wire_request.ConfigureCommand = .{};
                try configure.key.set("source-child");
                configure.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, "bypass");
                configure.configuration.parent.state = .value;
                try configure.configuration.parent.value.set(parent.slice());
                const child = (try storage.configure(&configure, .{})).accepted.session;
                const action = try NativePromotion.promoted(&storage, &tmp, child.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var key_buffer: [64]u8 = undefined;
                const key: []const u8 = switch (source) {
                    .person => blk: {
                        try submitTestMessage(&storage, &tmp, "source-person", "source-person-key", child.slice(), "Person input");
                        break :blk "source-person-key";
                    },
                    .peer => blk: {
                        const sender_action = try NativePromotion.sendPeer(&storage, &tmp, parent.slice(), child.slice(), "Peer input");
                        break :blk try std.fmt.bufPrint(&key_buffer, "rui.core/message_agent/{d}", .{sender_action});
                    },
                    .action_final => blk: {
                        _ = try storage.settleActionAttempt(binding, .succeeded, "Final input", .{});
                        break :blk "";
                    },
                };
                const where = " FROM message_admission m WHERE m.session_ref=?1 AND (m.command_key=?2 OR m.source_action_id=?3)";
                const args = .{ child.slice(), key, action };
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*)" ++ where, args));
                const kind: u64 = switch (source) {
                    .person => 1,
                    .peer => 2,
                    .action_final => 3,
                };
                try std.testing.expectEqual(kind, try store_testing.queryU64(&storage, "SELECT m.source_kind" ++ where, args));
                try std.testing.expectEqual(@as(u64, if (source == .person) 1 else 0), try store_testing.queryU64(&storage, "SELECT count(*)" ++ where ++ " AND " ++ sourced_input.personSql("m"), args));
                try std.testing.expectEqual(@as(u64, if (source != .action_final) 1 else 0), try store_testing.queryU64(&storage, "SELECT count(*)" ++ where ++ " AND " ++ sourced_input.messageSql("m"), args));
                const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.StatementFailed;
                const contradictory_kind: u64 = if (source == .person) 2 else 1;
                try std.testing.expectError(constraint_error, store_testing.exec(&storage, "UPDATE message_admission SET source_kind=?4 WHERE session_ref=?1 AND (command_key=?2 OR source_action_id=?3)", .{ child.slice(), key, action, contradictory_kind }));
                try std.testing.expectEqual(kind, try store_testing.queryU64(&storage, "SELECT m.source_kind" ++ where, args));
            }
        }
    }.run);
}

test "background owed stop excludes person peer and previously admitted final input at active and idle boundaries" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { person, peer, action_final }{ .person, .peer, .action_final }) |source| {
                for ([_]bool{ false, true }) |idle| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const parent = try shared_fixtures.configurePeerSender(&storage, "parent");
                    var configure: wire_request.ConfigureCommand = .{};
                    try configure.key.set("attached-child");
                    configure.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, "bypass");
                    configure.configuration.parent.state = .value;
                    try configure.configuration.parent.value.set(parent.slice());
                    const child = (try storage.configure(&configure, .{})).accepted.session;
                    const peer_send = if (source == .peer) try shared_fixtures.proposeMessageAgent(&storage, &tmp, parent.slice(), child.slice(), "") else null;
                    _ = try NativePromotion.promoted(&storage, &tmp, child.slice());
                    const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                    if (idle) {
                        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try NativePromotion.finishModel(&storage, &tmp, continuation);
                    }
                    switch (source) {
                        .person => try submitTestMessage(&storage, &tmp, "late-person", "late-person-key", child.slice(), "Pending person input"),
                        .peer => {
                            try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(peer_send.?, child.slice(), "Pending peer input", .{}));
                            const continuation = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
                            try NativePromotion.finishModel(&storage, &tmp, continuation);
                        },
                        .action_final => _ = (try storage.settleActionAttempt(binding, .succeeded, "Final before stop", .{})).outcome,
                    }
                    const admissions = try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL", .{child.slice()});
                    try std.testing.expect(admissions > 0);
                    var stop = try completeSessionStop("stop-parent", parent.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    const operations = try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation", .{});
                    try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
                    try std.testing.expect((try storage.admitModelAttempt(.open_turn_message, .{})) == null);
                    try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                    try std.testing.expectEqual(admissions, try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL", .{child.slice()}));
                    try std.testing.expectEqual(operations, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation", .{}));
                    const work = (try storage.nextCoreWork(.fromFree(2, true))).?.stop;
                    var owed: protocol.SessionStopCommand = .{ .key = work.key, .session = child };
                    try std.testing.expect(storage.stopOwedSession(&owed, .{}) == .accepted);
                    if (source != .action_final) _ = try storage.settleActionAttempt(binding, .succeeded, "Final after settled stop", .{});
                    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                    try std.testing.expectEqual(admissions, try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL", .{child.slice()}));
                }
            }
        }
    }.run);
}

test "native promotion owed stop refuses a foreground call and preserves an earlier receipt" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |promoted| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const parent = try shared_fixtures.configureTestSessionWithMode(&storage, "parent", "bypass");
                var configure: wire_request.ConfigureCommand = .{};
                try configure.key.set("attached-child");
                configure.configuration = try shared_fixtures.testingAgentSpec(&.{"bash"}, "bypass");
                configure.configuration.parent.state = .value;
                try configure.configuration.parent.value.set(parent.slice());
                const child = (try storage.configure(&configure, .{})).accepted.session;
                const action = try NativePromotion.propose(&storage, &tmp, child.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var before = try NativePromotion.command(child.slice(), "promote-before-stop", action);
                if (promoted) try std.testing.expect(storage.backgroundAction(.{ .command = &before }, .{}) == .accepted);
                var stop = try completeSessionStop("stop-parent", parent.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                var after = try NativePromotion.command(child.slice(), "promote-after-stop", action);
                const reply = storage.backgroundAction(.{ .command = &after }, .{});
                if (promoted) {
                    try std.testing.expect(reply == .accepted);
                    try std.testing.expectEqual(@import("../../action_control.zig").Selection{ .kind = .background, .position = try store_testing.queryU64(&storage, "SELECT background_position FROM action_operation WHERE action_id=?1", .{action}) }, reply.accepted.selection);
                } else {
                    try std.testing.expect(reply == .rejected);
                    try std.testing.expectEqual(@import("../../action_control.zig").Rejection.source_stopped, reply.rejected.code);
                }
                try std.testing.expectEqual(ActionSettlement.Outcome.session_stop, (try storage.settleActionAttempt(binding, .succeeded, "Stopped", .{})).outcome);
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE source_action_id=?1", .{action}));
            }
        }
    }.run);
}

test "interrupt regression: a new Message declines pending approvals through the permission owner" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "message-decline-config");
            try submitTestMessage(&storage, &tmp, "message-decline-first", "message-decline-first", session.slice(), "run");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "message-decline-calls");
            try std.testing.expect((try storage.nextCoreWork(.fromFree(2, true))) == null);
            try submitTestMessage(&storage, &tmp, "message-decline-next", "message-decline-next", session.slice(), "new instructions");
            for (0..2) |_| {
                const work = (try storage.nextCoreWork(.fromFree(2, true))).?;
                try std.testing.expect(work == .auto_deny);
                var late_allow: protocol.PermissionDecisionCommand = .{ .action_id = work.auto_deny.action_id, .decision = .allow_once };
                late_allow.session = work.auto_deny.session;
                const allow_key = try std.fmt.bufPrint(&late_allow.key.bytes, "late-allow-{d}", .{late_allow.action_id});
                late_allow.key.len = allow_key.len;
                const late_result = storage.decidePermission(&late_allow, .{});
                try std.testing.expect(late_result == .rejected and late_result.rejected.code == .action_not_pending);
                var decision: protocol.PermissionDecisionCommand = .{ .action_id = work.auto_deny.action_id };
                decision.session = work.auto_deny.session;
                const key = try std.fmt.bufPrint(&decision.key.bytes, "rui.core/message-decline/{d}", .{decision.action_id});
                decision.key.len = key.len;
                try std.testing.expect(storage.declineForMessage(&decision, .{}) == .accepted);
                const content_id = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1 AND resolution_code='denied'", .{decision.action_id});
                try expectContent(&storage, try testingContentReference(&storage, content_id), "declined: a new message arrived; ask again if still needed");
            }
            try std.testing.expect((try storage.nextCoreWork(.fromFree(2, true))) == null);
            const continued = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(binding.turn_id, continued.turn_id);
            var page: store_testing.TestingPage = undefined;
            page.open(&storage, continued);
            defer page.close();
            var position: u64 = 0;
            var seen: usize = 0;
            while (try page.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.kind != .tool_results) continue;
                while (try page.nextToolResult()) |result| {
                    var reader: store_testing.TestingReader = undefined;
                    try page.openContent(result.output.?, &reader);
                    defer reader.close();
                    var bytes: [256]u8 = undefined;
                    const length = try reader.read(0, &bytes);
                    try std.testing.expectEqualStrings("declined: a new message arrived; ask again if still needed", bytes[0..length]);
                    seen += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 2), seen);
        }
    }.run);
}

test "interrupt regression: Message declines background approval through originating Turn lifecycle" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { current, continued, completed, selected }{ .current, .continued, .completed, .selected }) |stage| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "background-approval");
                const action = try NativePromotion.promoted(&storage, &tmp, session.slice());
                if (stage != .current) {
                    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    if (stage == .completed or stage == .selected) try NativePromotion.finishModel(&storage, &tmp, continuation);
                }
                try submitTestMessage(&storage, &tmp, "background-new", "background-new", session.slice(), "new instructions");
                if (stage == .selected) _ = try storage.admitNextModelAttempt(.{});
                var allow: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action, .decision = .allow_once };
                try allow.key.set("late-background-allow");
                const result = storage.decidePermission(&allow, .{});
                try std.testing.expect(result == .rejected and result.rejected.code == .action_not_pending);
                const work = (try storage.nextCoreWork(.fromFree(2, true))).?;
                try std.testing.expect(work == .auto_deny);
                try std.testing.expectEqual(action, work.auto_deny.action_id);
                var decision: protocol.PermissionDecisionCommand = .{ .session = session, .action_id = action };
                try decision.key.set("background-message-denial");
                try std.testing.expect(storage.declineForMessage(&decision, .{}) == .accepted);
                const content = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1 AND resolution_code='denied'", .{action});
                try expectContent(&storage, try testingContentReference(&storage, content), "declined: a new message arrived; ask again if still needed");
            }
        }
    }.run);
}

test "interrupt regression: person and peer Messages decline approval alongside running Action promotion" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |peer| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const sender = try shared_fixtures.configurePeerSender(&storage, "sender");
                const target = try configureTestSessionAsk(&storage, "target");
                const sender_action = try shared_fixtures.proposeMessageAgent(&storage, &tmp, sender.slice(), target.slice(), "new peer message");
                try submitTestMessage(&storage, &tmp, "seed", "seed", target.slice(), "run both");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, model, "mixed-calls");
                const running_id = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation WHERE parent_operation_id=?1", .{model.operation_id});
                var allow: protocol.PermissionDecisionCommand = .{ .action_id = running_id, .decision = .allow_once };
                try allow.key.set("allow-running");
                allow.session = target;
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                const running = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                try std.testing.expectEqual(running_id, running.action_id);
                var cutoff: u64 = 0;
                try storage.withActionLaunchHandoff(running, &cutoff, struct {
                    fn capture(out: *u64, value: u64) !void {
                        out.* = value;
                    }
                }.capture);
                try std.testing.expect(!try storage.messageAfterActionLaunch(running, cutoff));
                if (peer) {
                    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(sender_action, target.slice(), "new peer message", .{}));
                } else {
                    try submitTestMessage(&storage, &tmp, "person-message", "person-message", target.slice(), "new person message");
                }
                try std.testing.expect(try storage.messageAfterActionLaunch(running, cutoff));
                try std.testing.expect(storage.backgroundAction(.{ .live_action = running.action_id }, .{}) == .accepted);
                const work = (try storage.nextCoreWork(.fromFree(2, true))).?;
                try std.testing.expect(work == .auto_deny);
                var decision: protocol.PermissionDecisionCommand = .{ .action_id = work.auto_deny.action_id };
                decision.session = work.auto_deny.session;
                try decision.key.set("message-denial");
                try std.testing.expect(storage.declineForMessage(&decision, .{}) == .accepted);
                const content = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1 AND resolution_code='denied'", .{decision.action_id});
                try expectContent(&storage, try testingContentReference(&storage, content), "declined: a new message arrived; ask again if still needed");
                try std.testing.expect(!try storage.messageAfterActionLaunch(running, cutoff));
            }
        }
    }.run);
}

test "interrupt regression: Message promotion watches running calls and ignores earlier and background-final inputs" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (0..3) |scenario| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "watch-config", "bypass");
                try submitTestMessage(&storage, &tmp, "watch-start", "watch-start", session.slice(), "start calls");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (scenario == 1) try submitTestMessage(&storage, &tmp, "stream-message", "stream-message", session.slice(), "while streaming");
                try settleTwoActionsForTesting(&storage, &tmp, model, "watch-calls");
                const first = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                const second = (try storage.admitNextActionAttempt(.fromFree(1, true), 30_000, .{})).?.permit.binding;
                var cutoffs: [2]u64 = undefined;
                const capture = struct {
                    fn handoff(out: *u64, cutoff: u64) !void {
                        out.* = cutoff;
                    }
                }.handoff;
                try storage.withActionLaunchHandoff(first, &cutoffs[0], capture);
                try storage.withActionLaunchHandoff(second, &cutoffs[1], capture);
                switch (scenario) {
                    0 => {
                        try submitTestMessage(&storage, &tmp, "watch-message", "watch-message", session.slice(), "interrupt both");
                        for ([_]@TypeOf(first){ first, second }, cutoffs) |binding, cutoff| {
                            try std.testing.expect(try storage.messageAfterActionLaunch(binding, cutoff));
                            try std.testing.expect(storage.backgroundAction(.{ .live_action = binding.action_id }, .{}) == .accepted);
                            try std.testing.expect(!try storage.messageAfterActionLaunch(binding, cutoff));
                        }
                    },
                    1 => {
                        try std.testing.expect(!try storage.messageAfterActionLaunch(first, cutoffs[0]));
                        try std.testing.expect(!try storage.messageAfterActionLaunch(second, cutoffs[1]));
                    },
                    2 => {
                        try std.testing.expect(storage.backgroundAction(.{ .live_action = first.action_id }, .{}) == .accepted);
                        _ = try storage.settleActionAttempt(first, .succeeded, "background final", .{});
                        try std.testing.expect(!try storage.messageAfterActionLaunch(second, cutoffs[1]));
                    },
                    else => unreachable,
                }
            }
        }
    }.run);
}

test "EXR-10 an Action read projects a compound Resolution as its owned parts value without walking it" {
    // The read does no manifest work: damage behind the manifest identity is the parts list's
    // to certify (INS-9), so every case projects the same value and the Store stays serving.
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Damage = enum { none, missing_last, extra_part, wrong_identity, nested_value, private_part, manifest_bytes };
            for (std.enums.values(Damage)) |damage| {
                errdefer std.debug.print("compound Resolution damage {s} failed\n", .{@tagName(damage)});
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try store_testing.configureTestSession(&storage, "resolution-corruption-config");
                try submitTestMessage(&storage, &tmp, "resolution-corruption-input", "resolution-corruption-message", session.slice(), "run");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, model, "resolution-corruption-calls");
                const binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 30_000, .{})).?.permit.binding;
                if (damage == .none) {
                    var input: action_domain.ActionExecutionInput = undefined;
                    try storage.readActionExecutionInput(.bash, binding, &input);
                    try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), "first", "starting")) == .accepted);
                    try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), "second", "雪")) == .accepted);
                }
                // The final row is beyond the Cursor's first relational page.
                var text: [17][24]u8 = undefined;
                var parts: [17]store_testing.MessagePart = undefined;
                for (&parts, &text, 0..) |*part, *buffer, ordinal|
                    part.* = .{ .bytes = try std.fmt.bufPrint(buffer, "resolution part {d}", .{ordinal}) };
                try store_testing.settleTestActionParts(&storage, &tmp, binding, &parts);
                const value = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{binding.action_id});
                switch (damage) {
                    .none => {},
                    .missing_last => try store_testing.exec(&storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=16", .{value}),
                    .extra_part => try store_testing.exec(&storage, "INSERT INTO content_part(content_id,ordinal,part_content_id) SELECT content_id,17,part_content_id FROM content_part WHERE content_id=?1 AND ordinal=0", .{value}),
                    .wrong_identity => {
                        const first = try store_testing.queryU64(&storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=0", .{value});
                        try store_testing.exec(&storage, "UPDATE content_part SET part_content_id=?2 WHERE content_id=?1 AND ordinal=16", .{ value, first });
                    },
                    .nested_value => {
                        try store_testing.submitTestMessageParts(&storage, &tmp, "resolution-nested", session.slice(), &.{ .{ .bytes = "nested first" }, .{ .bytes = "nested last" } });
                        const nested = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key='resolution-nested'", .{});
                        try store_testing.exec(&storage, "UPDATE content_part SET part_content_id=?2 WHERE content_id=?1 AND ordinal=16", .{ value, nested });
                    },
                    .private_part => {
                        const last = try store_testing.queryU64(&storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=16", .{value});
                        try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=?1", .{last});
                    },
                    .manifest_bytes => try store_testing.zeroContent(&storage, "SELECT resolution_content_id FROM action_operation WHERE resolution_code IS NOT NULL"),
                }
                const length = try store_testing.queryU64(&storage, "SELECT byte_length FROM content WHERE content_id=?1", .{value});
                var result: @import("../../action_read.zig").Read = undefined;
                var request: @import("../../action_read.zig").Request = .{
                    .session = session,
                    .action_id = binding.action_id,
                    .after = if (damage == .none) 1 else 0,
                };
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .resolved_parts);
                const projected = result.status.resolved_parts.content;
                try std.testing.expectEqual(@import("../../content_value.zig").Owner{ .action = binding.action_id }, projected.parts.owner);
                try std.testing.expectEqual(length, projected.parts.identity.length);
                if (damage == .none) {
                    try std.testing.expectEqual(@as(usize, 1), result.values.count);
                    try std.testing.expectEqual(@as(u64, 2), result.values.next);
                    try std.testing.expect(!result.values.more);
                    const item = result.values.items[0];
                    try std.testing.expectEqual(@as(u64, 2), item.ordinal);
                    try std.testing.expectEqualStrings("second", item.key.slice());
                    try std.testing.expectEqualStrings("雪", result.values.bytes[item.start..][0..item.length]);
                }
                request.offset = 1;
                try std.testing.expectError(error.InvalidCursor, storage.readAction(&request, &result));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

const ValueRowCounts = struct {
    content: u64,
    commands: u64,
    admissions: u64,
    values: u64,

    fn read(storage: *Store) !ValueRowCounts {
        return .{
            .content = try store_testing.queryU64(storage, "SELECT count(*) FROM content", .{}),
            .commands = try store_testing.queryU64(storage, "SELECT count(*) FROM core_command", .{}),
            .admissions = try store_testing.queryU64(storage, "SELECT count(*) FROM message_admission", .{}),
            .values = try store_testing.queryU64(storage, "SELECT count(*) FROM action_value", .{}),
        };
    }
};

test "APV-4 publication rollback leaves no partial rows" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                const before_rollback = try ValueRowCounts.read(&storage);
                try std.testing.expectError(error.InjectedCommitFailure, storage.publishActionValueForTesting(handle, "rollback", "rollback payload", .{ .before_commit = true }));
                try std.testing.expectEqual(before_rollback, try ValueRowCounts.read(&storage));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id}));
            }
        }
    }.run);
}

test "APV-5 publication keys replay or conflict across sender lifecycle" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                const first = try storage.publishActionValue(handle, "first", "one");
                try std.testing.expect(first == .accepted);
                const before_replay = try ValueRowCounts.read(&storage);
                const replay = try storage.publishActionValue(handle, "first", "one");
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(action_id, replay.accepted.action_id);
                try std.testing.expectEqual(first.accepted.ordinal, replay.accepted.ordinal);
                try std.testing.expectEqual(first.accepted.admission_id, replay.accepted.admission_id);
                try std.testing.expectEqual(before_replay, try ValueRowCounts.read(&storage));
                try std.testing.expect((try storage.publishActionValue(handle, "first", "different")).refused == .conflict);
                try std.testing.expectEqual(before_replay, try ValueRowCounts.read(&storage));
                if (background) {
                    for (1..32) |index| {
                        var key_buffer: [32]u8 = undefined;
                        const key = try std.fmt.bufPrint(&key_buffer, "value-{d}", .{index});
                        try std.testing.expect((try storage.publishActionValue(handle, key, "pending")) == .accepted);
                    }
                }
                var stop = try completeSessionStop("values-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                const stopped_counts = try ValueRowCounts.read(&storage);
                try std.testing.expect((try storage.publishActionValue(handle, "first", "one")).accepted.replayed);
                try std.testing.expectEqual(stopped_counts, try ValueRowCounts.read(&storage));
                try storage.revokeActionSender(binding);
                const retired_counts = try ValueRowCounts.read(&storage);
                try std.testing.expect((try storage.publishActionValue(handle, "first", "one")).accepted.replayed);
                try std.testing.expect((try storage.publishActionValue(handle, "first", "different")).refused == .conflict);
                try std.testing.expectEqual(retired_counts, try ValueRowCounts.read(&storage));
            }
            {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-resolved", "bypass");
                _ = try NativePromotion.promoted(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                const first = try storage.publishActionValue(handle, "saved", "value");
                try std.testing.expect(first == .accepted);
                _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
                const resolved_counts = try ValueRowCounts.read(&storage);
                const replay = try storage.publishActionValue(handle, "saved", "value");
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(first.accepted.action_id, replay.accepted.action_id);
                try std.testing.expectEqual(first.accepted.ordinal, replay.accepted.ordinal);
                try std.testing.expectEqual(first.accepted.admission_id, replay.accepted.admission_id);
                try std.testing.expectEqual(resolved_counts, try ValueRowCounts.read(&storage));
            }
        }
    }.run);
}

test "APV-12 publication receipts identify foreground and background values" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                const first = try storage.publishActionValue(handle, "first", "one");
                try std.testing.expect(first == .accepted);
                try std.testing.expectEqual(action_id, first.accepted.action_id);
                try std.testing.expectEqual(@as(u64, 1), first.accepted.ordinal);
                try std.testing.expectEqual(background, first.accepted.admission_id != null);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT c.form FROM action_value v JOIN content c ON c.content_id=v.content_id WHERE v.action_id=?1", .{action_id}));
                try std.testing.expectEqual(@as(u64, if (background) 1 else 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1 AND admission_id IS NOT NULL", .{action_id}));
            }
        }
    }.run);
}

test "APV-6 oversized values leave no partial rows" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                try std.testing.expect((try storage.publishActionValue(handle, "first", "one")) == .accepted);
                const before_oversized = try ValueRowCounts.read(&storage);
                const oversized: [16 * 1024 + 1]u8 = @splat('x');
                try std.testing.expect((try storage.publishActionValue(handle, "oversized", &oversized)).refused == .too_large);
                try std.testing.expectEqual(before_oversized, try ValueRowCounts.read(&storage));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id}));
            }
        }
    }.run);
}

test "APV-7 background backlog refuses overflow without partial rows" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
            const action_id = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            var input: action_domain.ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, binding, &input);
            const handle = input.sender_handle.slice();
            try std.testing.expect((try storage.publishActionValue(handle, "first", "one")) == .accepted);
            for (1..32) |index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "value-{d}", .{index});
                try std.testing.expect((try storage.publishActionValue(handle, key, "pending")) == .accepted);
            }
            const before_overflow = try ValueRowCounts.read(&storage);
            try std.testing.expect((try storage.publishActionValue(handle, "overflow", "overflow payload")).refused == .backlog_full);
            try std.testing.expectEqual(before_overflow, try ValueRowCounts.read(&storage));
            try std.testing.expectEqual(@as(u64, 32), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id}));
        }
    }.run);
}

test "APV-8 stopped and retired senders reject new values" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                const handle = input.sender_handle.slice();
                try std.testing.expect((try storage.publishActionValue(handle, "first", "one")) == .accepted);
                if (background) {
                    for (1..32) |index| {
                        var key_buffer: [32]u8 = undefined;
                        const key = try std.fmt.bufPrint(&key_buffer, "value-{d}", .{index});
                        try std.testing.expect((try storage.publishActionValue(handle, key, "pending")) == .accepted);
                    }
                }
                const before_stop = try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id});
                var stop = try completeSessionStop("values-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                const stopped_counts = try ValueRowCounts.read(&storage);
                try std.testing.expect((try storage.publishActionValue(handle, "after-stop", "stopped payload")).refused == .stopped);
                try std.testing.expectEqual(stopped_counts, try ValueRowCounts.read(&storage));
                try std.testing.expectEqual(before_stop, try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id}));
                try storage.revokeActionSender(binding);
                const retired_counts = try ValueRowCounts.read(&storage);
                try std.testing.expect((try storage.publishActionValue(handle, "new", "unknown payload")).refused == .unknown_handle);
                try std.testing.expectEqual(retired_counts, try ValueRowCounts.read(&storage));
            }
        }
    }.run);
}

test "APV-9 resolved Actions reject fresh publications" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "values-resolved", "bypass");
            const action_id = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            var input: action_domain.ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, binding, &input);
            const handle = input.sender_handle.slice();
            try std.testing.expect((try storage.publishActionValue(handle, "saved", "value")) == .accepted);
            _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
            try std.testing.expect((try storage.publishActionValue(handle, "fresh", "value")).refused == .unknown_handle);
            // Exercise a resolved row with a still-present handle separately from normal retirement.
            try store_testing.exec(&storage, "UPDATE action_operation SET sender_handle=?1 WHERE action_id=?2", .{ handle, action_id });
            const resolved_counts = try ValueRowCounts.read(&storage);
            try std.testing.expect((try storage.publishActionValue(handle, "fresh", "resolved payload")).refused == .resolved);
            try std.testing.expectEqual(resolved_counts, try ValueRowCounts.read(&storage));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value WHERE action_id=?1", .{action_id}));
        }
    }.run);
}

test "action value pages preserve delivery state" {
    // ARD-1
    const action_read = @import("../../action_read.zig");
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |background| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try shared_fixtures.configureTestSessionWithMode(&storage, "page-session", "bypass");
                const action_id = if (background) try NativePromotion.promoted(&storage, &tmp, session.slice()) else try NativePromotion.propose(&storage, &tmp, session.slice());
                const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
                var input: action_domain.ActionExecutionInput = undefined;
                try storage.readActionExecutionInput(.bash, binding, &input);
                for (0..20) |index| {
                    var key: [32]u8 = undefined;
                    var text: [32]u8 = undefined;
                    const k = try std.fmt.bufPrint(&key, "key-{d}", .{index});
                    const t = try std.fmt.bufPrint(&text, "value-{d}", .{index});
                    try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), k, t)) == .accepted);
                }
                const before = try ValueRowCounts.read(&storage);
                const pending = try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value v JOIN message_admission m ON m.admission_id=v.admission_id WHERE v.action_id=?1 AND m.turn_id IS NULL", .{action_id});
                try std.testing.expectEqual(@as(u64, if (background) 20 else 0), pending);
                const result = try std.testing.allocator.create(action_read.Read);
                defer std.testing.allocator.destroy(result);
                var after: u64 = 0;
                for (0..2) |page| {
                    try storage.readAction(&.{ .session = session, .action_id = action_id, .after = after }, result);
                    try std.testing.expectEqual(@as(usize, if (page == 0) 16 else 4), result.values.count);
                    try std.testing.expectEqual(page == 0, result.values.more);
                    for (result.values.items[0..result.values.count], 0..) |item, index| {
                        const ordinal = page * 16 + index + 1;
                        var expected_key: [32]u8 = undefined;
                        var expected_text: [32]u8 = undefined;
                        try std.testing.expectEqual(@as(u64, @intCast(ordinal)), item.ordinal);
                        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_key, "key-{d}", .{ordinal - 1}), item.key.slice());
                        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_text, "value-{d}", .{ordinal - 1}), result.values.bytes[item.start..][0..item.length]);
                    }
                    after = result.values.next;
                }
                try std.testing.expectEqual(@as(u64, 20), after);
                try storage.readAction(&.{ .session = session, .action_id = action_id, .after = after }, result);
                try std.testing.expectEqual(@as(usize, 0), result.values.count);
                try std.testing.expectEqual(after, result.values.next);
                try std.testing.expect(!result.values.more);
                try std.testing.expectEqual(before, try ValueRowCounts.read(&storage));
                try std.testing.expectEqual(pending, try store_testing.queryU64(&storage, "SELECT count(*) FROM action_value v JOIN message_admission m ON m.admission_id=v.admission_id WHERE v.action_id=?1 AND m.turn_id IS NULL", .{action_id}));
                const big = try std.testing.allocator.alloc(u8, action_read.page_bytes);
                defer std.testing.allocator.free(big);
                @memset(big, 'x');
                try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), "large", big)) == .accepted);
                try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), "unicode", "雪")) == .accepted);
                try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), "empty", "")) == .accepted);
                try storage.readAction(&.{ .session = session, .action_id = action_id, .after = 20 }, result);
                try std.testing.expectEqual(@as(usize, 1), result.values.count);
                try std.testing.expect(result.values.more);
                try std.testing.expectEqual(@as(u64, 21), result.values.next);
                try std.testing.expectEqualSlices(u8, big, result.values.bytes[0..result.values.length]);
                try storage.readAction(&.{ .session = session, .action_id = action_id, .after = 21 }, result);
                try std.testing.expectEqual(@as(usize, 2), result.values.count);
                try std.testing.expectEqualStrings("雪", result.values.bytes[0..result.values.items[0].length]);
                try std.testing.expectEqual(@as(usize, 0), result.values.items[1].length);
                try std.testing.expect(!result.values.more);
                _ = try storage.settleActionAttempt(binding, .succeeded, "final", .{});
                try storage.readAction(&.{ .session = session, .action_id = action_id, .offset = 2, .after = 21 }, result);
                try std.testing.expect(result.status == .resolved);
                try std.testing.expectEqualStrings("nal", result.status.resolved.window.text.slice());
                try std.testing.expectEqual(@as(usize, 2), result.values.count);
                var stop = try completeSessionStop("page-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try storage.readAction(&.{ .session = session, .action_id = action_id, .after = 21 }, result);
                try std.testing.expectEqual(@as(usize, 2), result.values.count);
                try store_testing.zeroContent(&storage, "SELECT content_id FROM action_value WHERE publication_key='unicode'");
                try std.testing.expectError(error.CorruptStore, storage.readAction(&.{ .session = session, .action_id = action_id, .after = 21 }, result));
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "APV-10 Activity keeps Action values and public Conversation omits them" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try shared_fixtures.configureTestSessionWithMode(&storage, "value-provenance", "bypass");
            const peer = try shared_fixtures.configurePeerSender(&storage, "value-provenance-peer");
            const peer_send = try shared_fixtures.proposeMessageAgent(&storage, &tmp, peer.slice(), session.slice(), "");
            const action_id = try NativePromotion.promoted(&storage, &tmp, session.slice());
            const binding = (try storage.admitNextActionAttempt(.fromFree(2, true), 30_000, .{})).?.permit.binding;
            var input: action_domain.ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, binding, &input);
            for (0..20) |index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "value-{d}", .{index});
                try std.testing.expect((try storage.publishActionValue(input.sender_handle.slice(), key, "hidden value")) == .accepted);
            }
            for (0..20) |index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "visible-person-{d}", .{index});
                try submitTestMessage(&storage, &tmp, key, key, session.slice(), "visible person");
            }
            try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(peer_send, session.slice(), "visible peer", .{}));
            _ = try storage.settleActionAttempt(binding, .succeeded, "visible final", .{});

            var queued_request: protocol.ActivityPage = .{ .session = session, .direction = .forward, .kinds = .initOne(.received) };
            var peer_queued = false;
            var final_queued = false;
            var value_queued: usize = 0;
            var value_at: ?struct { position: u64, ordinal: u64 } = null;
            while (true) {
                const queued = try store_core.activityPageForTesting(&storage, queued_request);
                for (queued.items[0..queued.count]) |item| {
                    const message = item.value.received;
                    try std.testing.expect(message.state == .queued);
                    if (message.origin == .peer) peer_queued = true;
                    if ((message.origin == .action and message.origin.action == action_id)) {
                        if (std.mem.eql(u8, &message.content.identity().digest, &protocol.contentDigest("hidden value"))) {
                            value_queued += 1;
                            if (value_at == null) value_at = .{ .position = item.position, .ordinal = item.ordinal };
                        } else final_queued = true;
                    }
                }
                for (queued.items[0..queued.count]) |item| {
                    _ = try storage.openActivityContent(&.{ .session = session, .position = item.position, .ordinal = item.ordinal });
                }
                if (!queued.more) break;
                queued_request.end = queued.end;
                queued_request.position = queued.items[queued.count - 1].position;
                queued_request.ordinal = queued.items[queued.count - 1].ordinal;
            }
            try std.testing.expect(peer_queued and final_queued);
            try std.testing.expectEqual(@as(usize, 20), value_queued);
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const hidden_entry = try store_testing.queryU64(&storage, "SELECT min(e.session_position) FROM conversation_entry e JOIN message_admission m ON m.admission_id=e.source_admission_id WHERE m.session_ref=?1 AND m.source_kind=4", .{session.slice()});
            _ = try storage.openActivityContent(&.{ .session = session, .position = value_at.?.position, .ordinal = value_at.?.ordinal });
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = session, .position = hidden_entry }));
            const found = try std.testing.allocator.create(protocol.ActivitySearchFacts);
            defer std.testing.allocator.destroy(found);
            var search: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.received), .limit = 4 };
            try search.query.set("hidden value");
            try storage.searchActivity(&search, found);
            try std.testing.expectEqual(@as(usize, 4), found.count);
            var value_user: ?struct { position: u64, ordinal: u64 } = null;

            for ([_]@FieldType(protocol.ActivityPage, "direction"){ .forward, .backward }) |direction| {
                var request: protocol.ActivityPage = .{ .session = session, .direction = direction, .kinds = .initMany(&.{ .admission, .received, .user }), .limit = 3 };
                var person_count: usize = 0;
                var peer_count: usize = 0;
                var final_count: usize = 0;
                var value_count: usize = 0;
                var pages: usize = 0;
                while (true) {
                    const page = try store_core.activityPageForTesting(&storage, request);
                    pages += 1;
                    for (page.items[0..page.count]) |item| {
                        const message = switch (item.value) {
                            .admission, .received, .user => |value| value,
                            else => unreachable,
                        };
                        if (item.value == .user and value_user == null and (message.origin == .action and message.origin.action == action_id) and
                            std.mem.eql(u8, &message.content.identity().digest, &protocol.contentDigest("hidden value"))) value_user = .{ .position = item.position, .ordinal = item.ordinal };
                        if (std.mem.eql(u8, &message.content.identity().digest, &protocol.contentDigest("visible person"))) person_count += 1;
                        if (message.origin == .peer) peer_count += 1;
                        if ((message.origin == .action and message.origin.action == action_id)) {
                            if (std.mem.eql(u8, &message.content.identity().digest, &protocol.contentDigest("hidden value"))) value_count += 1 else final_count += 1;
                        }
                    }
                    if (!page.more) break;
                    try std.testing.expectEqual(@as(usize, 3), page.count);
                    request.end = page.end;
                    request.position = page.items[page.count - 1].position;
                    request.ordinal = page.items[page.count - 1].ordinal;
                }
                try std.testing.expect(pages > 1);
                try std.testing.expectEqual(@as(usize, 40), person_count);
                try std.testing.expectEqual(@as(usize, 2), peer_count);
                try std.testing.expectEqual(@as(usize, 2), final_count);
                try std.testing.expectEqual(@as(usize, 40), value_count);
            }
            _ = try storage.openActivityContent(&.{ .session = session, .position = value_user.?.position, .ordinal = value_user.?.ordinal });
            var conversation: protocol.ConversationPage = .{ .session = session };
            var person_count: usize = 0;
            var peer_count: usize = 0;
            var final_count: usize = 0;
            var pages: usize = 0;
            while (true) {
                const page = try store_core.publicConversationPageForTesting(&storage, conversation);
                pages += 1;
                for (page.items[0..page.count]) |item| {
                    try std.testing.expect(!std.mem.eql(u8, &item.content.identity().digest, &protocol.contentDigest("hidden value")));
                    if (std.mem.eql(u8, &item.content.identity().digest, &protocol.contentDigest("visible person"))) person_count += 1;
                    if (item.sender != null) peer_count += 1;
                    if (item.source_action != null and item.source_action.? == action_id) final_count += 1;
                }
                if (!page.more) break;
                try std.testing.expectEqual(@as(usize, 16), page.count);
                conversation.end = page.end;
                conversation.before_position = page.items[page.count - 1].position;
                conversation.before_ordinal = page.items[page.count - 1].ordinal;
            }
            try std.testing.expect(pages > 1);
            try std.testing.expectEqual(@as(usize, 20), person_count);
            try std.testing.expectEqual(@as(usize, 1), peer_count);
            try std.testing.expectEqual(@as(usize, 1), final_count);
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, .{ .session = session, .end = conversation.end, .before_position = hidden_entry }));
            try NativePromotion.finishModel(&storage, &tmp, model);
        }
    }.run);
}
