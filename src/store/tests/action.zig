//! Action Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
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
            // The admitted Action cannot be reissued; its unapproved sibling remains pending.
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
                ActionSettlement.effect,
                try storage.settleActionAttempt(action_binding, .succeeded, "Original Bash result.", .{}),
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

test "core tool table routes every built-in to its sole action selector" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = @import("../../tool_record.zig");
            for (std.enums.values(records.Tool)) |tool| {
                errdefer std.debug.print("table routing failed for {s}\n", .{@tagName(tool)});
                const row = records.built_in_rows.get(tool);
                // Independent expectations pin the pre-table runner domain.
                const expected: records.Runner = switch (tool) {
                    .bash => .bash,
                    .web_search => .provider,
                    else => .core,
                };
                try std.testing.expectEqual(expected, row.runner);
                try std.testing.expectEqual(row.runner, records.Runner.of(records.record(tool)));
                // A provider name sent as a function call is rejected by
                // classification, so it must reach neither selector.

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
                    .message_agent => "{\"id\":\"zzzzzz\",\"text\":\"hi\"}",
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
                try std.testing.expectEqual(expected == .core, core != null);
                try std.testing.expectEqual(expected == .bash, bash != null);
                if (core) |work| {
                    const call = work.action;
                    try std.testing.expectEqualStrings(@tagName(tool), @tagName(call.tool));
                    try std.testing.expectEqual(binding.operation_id, call.binding.parent_operation_id);
                    try std.testing.expectEqual(binding.turn_id, call.binding.turn_id);
                    try std.testing.expectEqualStrings(session.slice(), call.session.slice());
                    // Selection is a read, not an Attempt or a resolution.
                    try std.testing.expectEqual(call.binding.action_id, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action.binding.action_id);
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
            // The provider's complete proposal, including its call arguments, is not
            // addressable as a public content position.
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
                try std.testing.expectEqualStrings("Run first command", presentation.get("description").?.string);
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
                try std.testing.expectEqualStrings("Run first command", presentation.get("description").?.string);
                try std.testing.expectEqualStrings("denied", presentation.get("code").?.string);
                // A terminal sibling is not a published complete group.
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
            try std.testing.expectEqualStrings("Run second command", settled_page.items[0].presentation.?.description.?.slice());
            try std.testing.expectEqualStrings("Run first command", settled_page.items[1].presentation.?.description.?.slice());
            try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, settled_page.items[1].presentation.?.code);
            for (settled_page.items[0..2]) |item| try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = public_request.session, .direction = .backward });
            var results: usize = 0;
            for (activity.items[0..activity.count]) |item| if (item.value == .tool_result) {
                const p = item.value.tool_result.presentation;
                try std.testing.expectEqual(item.position, p.publication_position.?);
                try std.testing.expectEqualStrings(if (item.ordinal == 1) "Run first command" else "Run second command", p.description.?.slice());
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
            // The ask-mode pair was never authorized: one denied, one stopped.
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
            // Each pass adds a Turn with two Actions waiting for permission.
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
            // The replay fixture executes every write transaction twice.
            // Frontier maintenance shares the two original rounds on both passes.
            const write_rounds: u64 = if (case.rerun) 4 else 2;
            inline for (.{ .bash, .mcp }) |runner| {
                for (0..4) |scenario| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    var configure = try completeConfiguration("runner-seam", "", workspace, "model-a");
                    const tool = if (runner == .bash) "bash" else "fetch_page";
                    const arguments = if (runner == .bash) "{\"cmd\":\"printf seam\",\"description\":\"Print seam\",\"timeout_ms\":5678}" else "{}";
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
                    var wrong = selected;
                    wrong.runner = if (runner == .bash) .mcp else .bash;
                    try std.testing.expect((try storage.admitActionAttempt(wrong, 1234, .{})) == null);
                    try storage.resolveAction(wrong, .spawn_failed, "Wrong runner must not resolve.", .{});
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
                        2 => if (runner == .bash) "Bash outcome is indeterminate after Host recovery; the command was not replayed." else "Outcome unknown: the Host stopped while this MCP call was running; it was not retried.",
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
                        if (runner == .bash) {
                            try std.testing.expectEqualStrings(workspace, input.runner.bash.workspace.slice());
                        } else {
                            try std.testing.expect(input.runner.mcp.parent == null);
                            try std.testing.expectEqualStrings(session.slice(), input.runner.mcp.root.slice());
                            try std.testing.expectEqualStrings("fetch_page", input.runner.mcp.name.slice());
                            try std.testing.expectEqualStrings("docs", input.runner.mcp.server.slice());
                            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("{\"type\":\"object\"}"), &input.runner.mcp.input_schema.digest);
                        }
                        if (scenario == 0) {
                            try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(binding, .succeeded, expected_text, .{}));
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
                try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(binding, .succeeded, bytes, .{}));
                try storage.readAction(&request, &result);
                try std.testing.expect(result.status == .resolved);
                const first = result.status.resolved;
                try std.testing.expectEqualStrings("succeeded", first.resolution.code.slice());
                try std.testing.expectEqual(bytes.len, first.resolution.content.length);
                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(bytes), &first.resolution.content.digest);
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

    fn capacity(total: usize, free: *const usize) @import("../domain/action_control.zig").CapacityView {
        return .{ .total = total, .context = free, .freeFn = struct {
            fn read(context: *const anyopaque) usize {
                return @as(*const usize, @ptrCast(@alignCast(context))).*;
            }
        }.read };
    }

    fn command(session: []const u8, key: []const u8, action: u64) !@import("../../command_input.zig").ActionBackgroundCommand {
        var result: @import("../../command_input.zig").ActionBackgroundCommand = .{ .action_id = action };
        try result.session.set(session);
        try result.key.set(key);
        return result;
    }

    fn promoted(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !u64 {
        const action = try propose(storage, tmp, session);
        const free: usize = 2;
        var key: [64]u8 = undefined;
        var request = try command(session, try std.fmt.bufPrint(&key, "promote-{s}", .{session}), action);
        try std.testing.expect(storage.backgroundAction(&request, capacity(2, &free), .{}) == .accepted);
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

test "native promotion keeps one attempted invocation and its immutable receipt while final polling stays explicit" {
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
            var free: usize = 0;
            var command = try NativePromotion.command(session.slice(), "refused-promotion", action);
            const refused = storage.backgroundAction(&command, NativePromotion.capacity(2, &free), .{});
            try std.testing.expect(refused == .rejected and refused.rejected.code == .background_unavailable);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            free = 1;
            const refusal_replay = storage.backgroundAction(&command, NativePromotion.capacity(2, &free), .{});
            try std.testing.expect(refusal_replay == .rejected and refusal_replay.rejected.replayed);
            try command.key.set("promote-existing-attempt");
            const accepted = storage.backgroundAction(&command, NativePromotion.capacity(2, &free), .{});
            try std.testing.expect(accepted == .accepted and accepted.accepted.selection.kind == .background);
            const receipt_position = accepted.accepted.selection.position;
            const receipt_content = try store_testing.queryU64(&storage, "SELECT background_content_id FROM action_operation WHERE action_id=?1", .{action});
            try storage.readActionExecutionInput(.bash, binding, &input);
            try std.testing.expectEqualSlices(u8, sender.slice(), input.sender_handle.slice());
            try std.testing.expectEqualDeep(arguments, input.arguments);
            try std.testing.expectEqual(@as(u64, 30_000), input.timeout_ms);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try NativePromotion.finishModel(&storage, &tmp, continuation);
            try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(binding, .succeeded, "One invocation's final", .{}));
            free = 0;
            const replay = storage.backgroundAction(&command, NativePromotion.capacity(1, &free), .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(receipt_position, replay.accepted.selection.position);
            var read: @import("../../action_read.zig").Read = undefined;
            try storage.readAction(&.{ .session = session, .action_id = action }, &read);
            try std.testing.expect(read.status == .resolved);
            try std.testing.expectEqualStrings("succeeded", read.status.resolved.resolution.code.slice());
            try std.testing.expectEqualStrings("One invocation's final", read.status.resolved.window.text.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND attempt_ordinal=1 AND background_position=?2 AND background_content_id=?3 AND resolution_code='succeeded'", .{ action, receipt_position, receipt_content }));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try std.testing.expectError(error.StaleActionAttemptBinding, storage.settleActionAttempt(binding, .failed, "Replacement", .{}));
        }
    }.run);
}

test "native promotion rollback and capacity one refusal leave the original foreground wait unchanged" {
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
            const free: usize = 2;
            var request = try NativePromotion.command(session.slice(), "cap-one", action);
            const refused = storage.backgroundAction(&request, NativePromotion.capacity(1, &free), .{});
            try std.testing.expect(refused == .rejected and refused.rejected.code == .background_unavailable);
            try request.key.set("foreign");
            request.session = other;
            const foreign = storage.backgroundAction(&request, NativePromotion.capacity(2, &free), .{});
            try std.testing.expect(foreign == .rejected and foreign.rejected.code == .target_mismatch);
            request.session = session;
            try request.key.set("rollback");
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try std.testing.expect(storage.backgroundAction(&request, NativePromotion.capacity(2, &free), .{ .before_commit = true }) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expectEqual(contents, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key='rollback'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE background_position IS NOT NULL OR attempt_ordinal!=0 OR resolution_code IS NOT NULL", .{}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            const accepted = storage.backgroundAction(&request, NativePromotion.capacity(2, &free), .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect((try storage.nextAction(.bash, .fromFree(1, true))) == null);
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
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
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
            try std.testing.expectEqual(admissions, try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        }
    }.run);
}

test "native promotion Host recovery retains background fulfillment and records uncertainty without another Attempt" {
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
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
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
