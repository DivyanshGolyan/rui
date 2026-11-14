//! Model admission SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const tests = @import("../tests.zig");
const std = @import("std");
const named_scratch = @import("../../named_scratch.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const output_decode = @import("../../output_decode.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const model_admission_domain = @import("../domain/model_admission.zig");
const model_settlement_domain = @import("../domain/model_settlement.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ContentReader = content_domain.ContentReader;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const ModelOperationKind = historical_domain.ModelOperationKind;
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const runnable_selection_sql = model_admission_domain.runnable_selection_sql;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testing_absent_model_evidence = store_testing.testing_absent_model_evidence;
const tool_continuation_selection = model_admission_domain.tool_continuation_selection;
const TestingCall = tests.TestingCall;
const configureTestSessionAsk = tests.configureTestSessionAsk;
const expectActivityOutcome = tests.expectActivityOutcome;
const settleCallsForTesting = tests.settleCallsForTesting;
const settleCallsForTestingWithFaults = tests.settleCallsForTestingWithFaults;
const settleTwoActionsForTesting = tests.settleTwoActionsForTesting;
const testingBytesContent = tests.testingBytesContent;
const testingContent = tests.testingContent;
const testingStore = store_testing.testingSqliteStore;
const ConstraintProbe = shared_fixtures.ConstraintProbe;
const TestingStatementFault = shared_fixtures.TestingStatementFault;
const busyStatements = shared_fixtures.busyStatements;
const expectModelRevisions = shared_fixtures.expectModelRevisions;
const probeConstraint = shared_fixtures.probeConstraint;
const runsOf = shared_fixtures.runsOf;

test "complete call outcomes continue once in call order ahead of pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "result-config");
    try submitTestMessage(&storage, &tmp, "result-first", "result-first", session.slice(), "first");
    const first_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "result-item-0", .name = "bash", .encoded_call_id = "result-call-0", .decoded_call_id = "result-call-0", .encoded_arguments = "{\\\"description\\\":\\\"Run zeroth command\\\",\\\"cmd\\\":\\\"zero\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run zeroth command\",\"cmd\":\"zero\",\"timeout_ms\":null}" },
        .{ .item_id = "result-item-1", .name = "unknown", .encoded_call_id = "result-call-1", .decoded_call_id = "result-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "result-item-2", .name = "bash", .encoded_call_id = "result-call-2", .decoded_call_id = "result-call-2", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "result-item-3", .name = "bash", .encoded_call_id = "result-call-3", .decoded_call_id = "result-call-3", .encoded_arguments = "{\\\"description\\\":\\\"Run third command\\\",\\\"cmd\\\":\\\"three\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run third command\",\"cmd\":\"three\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, first_binding, "result-metadata", &calls);
    try submitTestMessage(&storage, &tmp, "result-second", "result-second", session.slice(), "second");
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const first_action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{});
    const second_action_id = try store_testing.sqlite_only.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
    var deny_second: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
    try deny_second.key.set("result-deny-second");
    try deny_second.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&deny_second, .{}) == .accepted);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    var deny_first: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny_first.key.set("result-deny-first");
    try deny_first.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&deny_first, .{}) == .accepted);
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(first_binding.turn_id, continuation.turn_id);
    try std.testing.expectEqual(first_binding.operation_id + 1, continuation.operation_id);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const replayed_denial = storage.decidePermission(&deny_first, .{});
    try std.testing.expect(replayed_denial == .accepted);
    try std.testing.expect(replayed_denial.accepted.replayed);
    var stale_denial: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try stale_denial.key.set("result-stale-denial");
    try stale_denial.session.set(session.slice());
    const stale_reply = storage.decidePermission(&stale_denial, .{});
    try std.testing.expect(stale_reply == .rejected);
    try std.testing.expectEqual(protocol.PermissionDecisionRejection.action_not_pending, stale_reply.rejected.code);

    var view: HistoricalView = undefined;
    storage.openHistoricalView(continuation, &view);
    defer view.close();
    var position: u64 = 0;
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(position)).?.kind);
    position = (try view.nextEntry(position)).?.position;
    // The Operation that proposed the calls, at its admission position.
    const proposing = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.operation, proposing.kind);
    position = proposing.position;
    for (0..calls.len) |_| {
        const item = (try view.nextEntry(position)).?;
        try std.testing.expectEqual(HistoricalEntryKind.provider_output, item.kind);
        position = item.position;
    }
    const group = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.tool_results, group.kind);
    position = group.position;

    const expected_call_ids = [_][]const u8{ "result-call-0", "result-call-1", "result-call-2", "result-call-3" };
    const expected_outputs = [_][]const u8{
        "Permission denied.",
        "Unknown tool: unknown.",
        "Invalid arguments for tool 'bash': the arguments are not one well-formed JSON object.",
        "Permission denied.",
    };
    for (expected_call_ids, expected_outputs, 0..) |expected_call_id, expected_output, ordinal| {
        _ = ordinal;
        const result = (try view.nextToolResult()).?;
        var call_id: HistoricalReader = undefined;
        try view.openContent(result.call_id, &call_id);
        var output: HistoricalReader = undefined;
        try view.openContent(result.output, &output);
        var buffer: [128]u8 = undefined;
        const call_id_count = try call_id.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_call_id, buffer[0..call_id_count]);
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.sqliteDatabase(), null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        const output_count = try output.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_output, buffer[0..output_count]);
        output.close();
        call_id.close();
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    try std.testing.expect((try view.nextToolResult()) == null);
    const pending = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, pending.kind);
    try std.testing.expect((try view.nextEntry(pending.position)) == null);
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(0)).?.kind);
}

test "tool continuation admission runs its selection once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "config");
    try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "start");
    const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
    try settleCallsForTesting(&storage, &tmp, first, "output", &calls);

    const selection = try storage.engine.sqlite.cachedTyped(tool_continuation_selection);
    const runs_before = c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0);
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try std.testing.expectEqual(first.turn_id, continued.turn_id);
    try std.testing.expectEqual(runs_before + 1, c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0));
}

test "a stored continuation never names a later Operation than its Turn's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "later-config");
    try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "start");
    _ = (try storage.admitModelAttempt(.message, .{})).?;
    try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.sqliteDatabase(), "UPDATE turn SET continuation_operation_id=operation_id"));
    try std.testing.expectEqual(ConstraintProbe.check_violation, try probeConstraint(storage.sqliteDatabase(), "UPDATE turn SET continuation_operation_id=operation_id+1"));
}

test "tool continuation selection never visits a Turn waiting for its tool results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Each round adds a Turn with two Actions waiting for permission.
    var steps: [2]i32 = undefined;
    for (&steps, 0..) |*cost, round| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "waiting-{d}", .{round});
        var config_buffer: [40]u8 = undefined;
        const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
        const session = try configureTestSessionAsk(&storage, config);
        try submitTestMessage(&storage, &tmp, name, name, session.slice(), "propose");
        const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
        try settleTwoActionsForTesting(&storage, &tmp, binding, config);

        const select = try sqlite.prepare(storage.sqliteDatabase(), tool_continuation_selection.sql);
        defer _ = c.sqlite3_finalize(select);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(select));
        cost.* = c.sqlite3_stmt_status(select, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code IS NULL", .{}));
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "one committed selection freezes its settings and input prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = try storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_file = try tmp.dir.createFile(std.testing.io, "dispatch-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage("dispatch-1", created_session_0.slice(), first_file, "first");
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .accepted);

    const second_file = try tmp.dir.createFile(std.testing.io, "dispatch-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage("dispatch-2", created_session_0.slice(), second_file, "second");
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&second, null, .{}) == .accepted);

    var instructions_update: wire_request.ConfigureCommand = .{};
    try instructions_update.key.set("instructions-before-selection");
    try instructions_update.session.set(created_session_0.slice());
    instructions_update.configuration.instructions = try testingContent(&tmp, "instructions-before", 'b', 1);
    defer instructions_update.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(try storage.configure(&instructions_update, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expectError(error.StoreFenced, store_testing.observeCommandForTesting(&storage, "dispatch-1"));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try std.testing.expect(
        (try store_testing.observeCommandForTesting(&storage, "dispatch-1")).kind.message.?.queue.?.state == .queued,
    );

    // Failed admission publishes neither projection nor instruction
    // inclusion; the revision's change row holds position 3.
    try std.testing.expectEqual(@as(i64, 0), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(i64, 4), try sqlite.pragmaInt(storage.sqliteDatabase(), "SELECT next_position FROM session"));

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try store_testing.observeCommandForTesting(&storage, "dispatch-1")).kind.message.?.queue.?;
    const second_observation = (try store_testing.observeCommandForTesting(&storage, "dispatch-2")).kind.message.?.queue.?;
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try store_testing.observeCommandForTesting(&storage, "dispatch-1")).kind.message.?.work.?.state.progress().?);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try store_testing.observeCommandForTesting(&storage, "dispatch-2")).kind.message.?.work.?.state.progress().?);
    const first_binding = switch (first_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    const second_binding = switch (second_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    try std.testing.expectEqual(binding.turn_id, first_binding.turn_id);
    try std.testing.expectEqual(binding.turn_id, second_binding.turn_id);
    try std.testing.expectEqual(binding.operation_id, first_binding.operation_id);
    try std.testing.expectEqual(binding.operation_id, second_binding.operation_id);

    const third_file = try tmp.dir.createFile(std.testing.io, "dispatch-third", .{ .read = true });
    try third_file.writeStreamingAll(std.testing.io, "later");
    try third_file.sync(std.testing.io);
    var third = try completeMessage("dispatch-3", created_session_0.slice(), third_file, "later");
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&third, null, .{}) == .accepted);
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = try storage.configure(&update, .{});
    try std.testing.expect(active_update == .accepted);
    try std.testing.expectEqualStrings("model-b", (try storage.inspectSessionForTesting(created_session_0.slice())).model.slice());
    try expectModelRevisions(&storage, created_session_0.slice(), "during-work");

    var view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &view);
    defer if (view.active) view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(protocol.Provider.codex, settings.provider);
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    // The frozen tools come back as the Store saved them, in set order.
    const offered = [_]*const tool_defs.Record{ tool_defs.record(.bash), tool_defs.record(.web_search) };
    try std.testing.expectEqual(@as(u64, offered.len), settings.tool_count);
    var tool: historical_domain.HistoricalTool = .{};
    for (offered) |expected| {
        try std.testing.expect(try view.nextTool(&tool));
        try std.testing.expectEqualStrings(expected.name, tool.name.slice());
        try std.testing.expectEqual(expected.owner, tool.owner);
        try std.testing.expectEqual(@as(u64, expected.description.len), tool.description.length);
    }
    try std.testing.expect(!try view.nextTool(&tool));
    const first_input = (try view.nextEntry(0)).?;
    const second_input = (try view.nextEntry(first_input.position)).?;
    const instruction = (try view.nextEntry(second_input.position)).?;
    try std.testing.expect(instruction.kind == .instruction);
    try std.testing.expect((try view.nextEntry(instruction.position)) == null);
    var first_reader: HistoricalReader = undefined;
    try view.openContent(first_input.content.?, &first_reader);
    defer if (first_reader.active) first_reader.close();
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(actual.len, try first_reader.read(0, &actual));
    try std.testing.expectEqualStrings("first", &actual);

    var foreign_view: HistoricalView = undefined;
    storage.openHistoricalView(binding, &foreign_view);
    try std.testing.expect(first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_input.content.?.belongsTo(&foreign_view));
    foreign_view.close();
    try std.testing.expectEqual(@as(usize, 1), view.readers);
    first_reader.close();
    try std.testing.expectEqual(@as(usize, 0), view.readers);
    view.close();
    try std.testing.expect(!first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_reader.usable());

    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    try expectActivityOutcome(&storage, created_session_0.slice(), binding, .provider_refused, "provider_http_422");
    const failed = (try store_testing.observeCommandForTesting(&storage, "dispatch-1")).kind.message.?.queue.?;
    const failure = switch (failed.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("provider_http_422", failure.code.slice());
    try std.testing.expect(
        (try store_testing.observeCommandForTesting(&storage, "dispatch-3")).kind.message.?.queue.?.state == .queued,
    );
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);

    try update.key.set("configure-after-failure");
    const failed_update = try storage.configure(&update, .{});
    try std.testing.expect(failed_update == .accepted);
    try std.testing.expectEqualStrings("model-b", (try storage.inspectSessionForTesting(created_session_0.slice())).model.slice());
    try expectModelRevisions(&storage, created_session_0.slice(), "after-failure");

    var tools_update: wire_request.ConfigureCommand = .{};
    try tools_update.key.set("tools-after-failure");
    try tools_update.session.set(created_session_0.slice());
    tools_update.configuration.tools.state = .value;
    tools_update.configuration.tools.count = 0;
    try std.testing.expect(try storage.configure(&tools_update, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view: HistoricalView = undefined;
    storage.openHistoricalView(later.permit.binding, &later_view);
    defer later_view.close();
    var later_settings: HistoricalSettings = undefined;
    try later_view.settings(&later_settings);
    try std.testing.expectEqual(protocol.Provider.codex, later_settings.provider);
    try std.testing.expectEqualStrings("model-b", later_settings.model.slice());
    try std.testing.expectEqual(@as(u64, 0), later_settings.tool_count);
    var position: u64 = 0;
    // The failed first Operation keeps its boundary between the inputs.
    for ([_]HistoricalEntryKind{ .user, .user, .instruction, .operation, .user }) |kind| {
        const entry = (try later_view.nextEntry(position)).?;
        try std.testing.expectEqual(kind, entry.kind);
        position = entry.position;
    }
    try std.testing.expect((try later_view.nextEntry(position)) == null);
}

test "continued accepted output allows model revisions and keeps public text readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "continued-config",
        "",
        workspace,
        "model-a",
    );
    const created_session_0_reply = try storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_file = try tmp.dir.createFile(std.testing.io, "continued-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage(
        "continued-first",
        created_session_0.slice(),
        first_file,
        "first",
    );
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    const second_file = try tmp.dir.createFile(std.testing.io, "continued-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage(
        "continued-second",
        created_session_0.slice(),
        second_file,
        "second",
    );
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&second, null, .{}) == .accepted);

    const source_bytes = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}";
    const source = try tmp.dir.createFile(std.testing.io, "continued-output", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(
        std.testing.io,
        root_buffer[0..root_length],
        "continued-metadata",
        .{ .used = &metadata_used, .limit = 1_024 },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    try std.testing.expect(retained_metadata == null);
    _ = try output_decode.recordItemForTesting(&metadata, source, 0, source_bytes.len, 0, .assistant_response);
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .call_count = 0,
        .answer_item_ordinal = 0,
        .answer_length = "answer".len,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
    var public_request = protocol.ConversationPage{};
    try public_request.session.set(created_session_0.slice());
    const public_page = try store_core.publicConversationPageForTesting(&storage, public_request);
    try std.testing.expectEqual(@as(usize, 2), public_page.count);
    try std.testing.expect(public_page.items[0].kind == .assistant);
    var public_reader: ContentReader = undefined;
    public_reader.open(try storage.openPublicConversationContent(&.{ .session = public_request.session, .position = public_page.items[0].position }));
    {
        // The answer is the message's public text row; its bag is private.
        const backing = try sqlite.prepare(storage.sqliteDatabase(), "SELECT text.private,bag.private FROM model_output_item item " ++
            "JOIN content text ON text.content_id=item.message_content_id " ++
            "JOIN content bag ON bag.content_id=item.extras_content_id WHERE item.message_content_id=?1");
        defer _ = c.sqlite3_finalize(backing);
        try sqlite.bindI64(backing, 1, public_reader.content_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(backing));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(backing, 0));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(backing, 1));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(backing));
    }
    var decoded: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try public_reader.read(0, &decoded));
    try std.testing.expectEqualStrings("answer", &decoded);
    public_reader.close();
    const before_answer = try store_core.publicConversationPageForTesting(&storage, .{
        .session = public_request.session,
        .end = public_page.end,
        .before_position = public_page.items[0].position,
    });
    try std.testing.expectEqual(@as(usize, 1), before_answer.count);
    try std.testing.expect(before_answer.items[0].kind == .user);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.sqliteDatabase()));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.sqliteDatabase()));
    {
        const resolution = try sqlite.prepare(
            storage.sqliteDatabase(),
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try sqlite.bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("answer", code.slice());
    }

    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const changed = try storage.configure(&update, .{});
    try std.testing.expect(changed == .accepted);
    try std.testing.expectEqualStrings("model-b", (try storage.inspectSessionForTesting(created_session_0.slice())).model.slice());

    const completion_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelSuccess(completion_binding, &output, .{});
    // The same output is an answer both before and after pending input is
    // consumed. Only the owning Turn's completion decision differs.
    try std.testing.expectEqual(@as(u64, 2), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='answer'", .{}));
    try expectModelRevisions(&storage, created_session_0.slice(), "after-output");
    const completed = (try store_testing.observeCommandForTesting(&storage, "continued-first")).kind.message.?.queue.?;
    const completion = switch (completed.state) {
        .completed => |value| value,
        else => return error.ExpectedCompletedObservation,
    };
    try std.testing.expectEqual(completion_binding, completion.binding);
    try std.testing.expectEqual(@as(u64, "answer".len), completion.answer.length);
    try std.testing.expectEqualSlices(
        u8,
        &protocol.contentDigest("answer"),
        &completion.answer.digest,
    );
}

test "runnable selection finds age through pending index then groups one session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try sqlite.prepare(storage.sqliteDatabase(), "EXPLAIN QUERY PLAN " ++ runnable_selection_sql);
    defer _ = c.sqlite3_finalize(statement);
    var uses_pending_index = false;
    var uses_session_index = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const detail = c.sqlite3_column_text(statement, 3);
            if (detail == null) return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const text = detail[0..@intCast(length)];
            uses_pending_index = uses_pending_index or
                std.mem.indexOf(u8, text, "message_admission_pending") != null;
            uses_session_index = uses_session_index or
                std.mem.indexOf(u8, text, "message_admission_session_order") != null;
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_pending_index);
    try std.testing.expect(uses_session_index);
}

test "runnable discovery measures eligible ineligible and history populations independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    // Query-only populations use canonical six-byte fixtures, not named
    // Session creation. Command keys retain their independent text identities.
    const QueryCost = struct {
        const Result = struct {
            steps: i32,
            first_admission: i64,
        };

        fn reset(database: *c.sqlite3, eligible: usize, ineligible: usize, history: usize) !void {
            try sqlite.exec(database, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM model_operation; DELETE FROM turn; DELETE FROM session");
            if (ineligible != 0) {
                try sqlite.exec(
                    database,
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                        "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                        "VALUES('st0ped','/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,1000000,zeroblob(32),1000000)",
                );
                const insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT value,'st0ped',printf('stopped-%d',value),1,NULL,1 FROM sequence; " ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) " ++
                        "VALUES('stop','st0ped',NULL,{0},1)",
                    .{ineligible},
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(database, insert);
            }
            const eligible_insert = try std.testing.allocator.printSentinel(
                "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                    "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                    "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1,zeroblob(32),value+1 FROM sequence; " ++
                    "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                    "SELECT {1}+value,printf('%06d',value),printf('eligible-%d',value),1,NULL,1 FROM sequence",
                .{ eligible, ineligible + 1 },
                0,
            );
            defer std.testing.allocator.free(eligible_insert);
            try sqlite.exec(database, eligible_insert);
            if (history != 0) {
                const history_insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT {1}+value,'h1st0r',printf('history-%d',value),1,value,1 FROM sequence",
                    .{ history, ineligible + eligible },
                    0,
                );
                defer std.testing.allocator.free(history_insert);
                try sqlite.exec(database, history_insert);
            }
        }

        fn measureSelection(database: *c.sqlite3) !Result {
            const statement = try sqlite.prepare(database, runnable_selection_sql);
            defer _ = c.sqlite3_finalize(statement);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
            var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
            try sqlite.readText(statement, 0, &session_ref);
            if (!session_ref.eql("000000")) return error.RunnableSelectionFailed;
            const first_admission = c.sqlite3_column_int64(statement, 3);
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
            return .{
                .steps = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0),
                .first_admission = first_admission,
            };
        }

        fn measureDrain(database: *c.sqlite3, eligible: usize) !i64 {
            const mark = try sqlite.prepare(database, "UPDATE message_admission SET turn_id=admission_id WHERE admission_id=?1");
            defer _ = c.sqlite3_finalize(mark);
            var total_steps: i64 = 0;
            for (0..eligible) |index| {
                const statement = try sqlite.prepare(database, runnable_selection_sql);
                defer _ = c.sqlite3_finalize(statement);
                if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
                const first_admission = c.sqlite3_column_int64(statement, 3);
                if (first_admission != index + 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
                total_steps += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);

                try sqlite.bindI64(mark, 1, first_admission);
                try sqlite.expectDone(mark);
                if (c.sqlite3_changes(database) != 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_reset(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
                if (c.sqlite3_clear_bindings(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
            }
            return total_steps;
        }
    };

    var history_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |history, index| {
        try QueryCost.reset(storage.sqliteDatabase(), 1, 0, history);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        history_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(@max(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) -
        @min(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) <= 32);

    var ineligible_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |ineligible, index| {
        try QueryCost.reset(storage.sqliteDatabase(), 1, ineligible, 0);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, @intCast(ineligible + 1)), measured.first_admission);
        ineligible_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(ineligible_selection_costs[1] > ineligible_selection_costs[0]);
    try std.testing.expect(ineligible_selection_costs[2] > ineligible_selection_costs[1]);

    var eligible_selection_costs: [3]i32 = undefined;
    var eligible_drain_costs: [3]i64 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |eligible, index| {
        try QueryCost.reset(storage.sqliteDatabase(), eligible, 0, 0);
        const measured = try QueryCost.measureSelection(storage.sqliteDatabase());
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        eligible_selection_costs[index] = measured.steps;
        try QueryCost.reset(storage.sqliteDatabase(), eligible, 0, 0);
        eligible_drain_costs[index] = try QueryCost.measureDrain(storage.sqliteDatabase(), eligible);
    }
    try std.testing.expect(@max(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) -
        @min(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) <= 32);
    try std.testing.expect(eligible_drain_costs[1] <= eligible_drain_costs[0] * 12);
    try std.testing.expect(eligible_drain_costs[2] <= eligible_drain_costs[1] * 12);
}

test "model admission work excludes failed historical Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, overflow: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Keep the actual current Operation newer than all injected history.
            try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001", .{});
            const insert = try sqlite.prepare(storage.sqliteDatabase(), "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window,request_codec,request_codec_options) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1,current.tool_set_id,current.context_window,current.request_codec,current.request_codec_options FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (overflow) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (overflow) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            return measured.steps;
        }
    };
    for ([_]bool{ false, true }) |overflow| {
        const small = try Measure.run(8, overflow);
        const large = try Measure.run(1024, overflow);
        try std.testing.expect(large <= small + 100);
    }
}

test "model admission work excludes accepted compaction base history" {
    const Measure = struct {
        steps: u64 = 0,
        const Suffix = enum { unchanged, low, high, missing };

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, suffix: Suffix) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            for (0..population) |index| {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(base));
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (index + 1 != population) {
                    // Provider-only suffix allows the next overflow recovery
                    // without accumulating retained host input.
                    const call = TestingCall{ .item_id = "old-item", .name = "unknown", .encoded_call_id = "old-call", .decoded_call_id = "old-call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                    try settleCallsForTestingWithFaults(&storage, &tmp, current, "old-output", &.{call}, .{}, null);
                    current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
            }
            if (suffix == .unchanged) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "network" }, .ordinary, .{});
            } else {
                const call = TestingCall{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                try settleCallsForTestingWithFaults(&storage, &tmp, current, "output", &.{call}, .{}, switch (suffix) {
                    .low => "{\"input_tokens\":1,\"output_tokens\":0}",
                    .high => "{\"input_tokens\":1000,\"output_tokens\":0}",
                    .missing => null,
                    .unchanged => unreachable,
                });
            }
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (suffix == .high) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (suffix == .high) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            return measured.steps;
        }
    };
    var bounded = true;
    for ([_]Measure.Suffix{ .unchanged, .low, .high, .missing }) |suffix| {
        const small = try Measure.run(8, suffix);
        const large = try Measure.run(128, suffix);
        bounded = bounded and large <= small + 200;
    }
    try std.testing.expect(bounded);
}

test "model admission work excludes usage-covered accepted tool and instruction history" {
    const Measure = struct {
        steps: u64 = 0,
        const Population = enum { rejection, action, instruction };

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, kind: Population, compact: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            if (kind == .action) {
                var tools: wire_request.ConfigureCommand = .{};
                try tools.key.set("tools");
                try tools.session.set(session.slice());
                tools.configuration.tools.state = .value;
                tools.configuration.tools = try .of(&.{"bash"});
                tools.configuration.permission_mode.state = .value;
                try tools.configuration.permission_mode.value.set("bypass");
                try std.testing.expect(try storage.configure(&tools, .{}) == .accepted);
            }
            const call = TestingCall{ .item_id = "item", .name = if (kind == .action) "bash" else "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = if (kind == .action) "{\\\"description\\\":\\\"Run no-op\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}" else "{}", .decoded_arguments = if (kind == .action) "{\"description\":\"Run no-op\",\"cmd\":\"true\",\"timeout_ms\":null}" else "{}" };
            const instructions: [400]u8 = @splat('x');
            for (0..population + 1) |index| {
                var key: [64]u8 = undefined;
                if (kind == .instruction) {
                    var patch: wire_request.ConfigureCommand = .{};
                    try patch.key.set(try std.fmt.bufPrint(&key, "instructions-{d}", .{index}));
                    try patch.session.set(session.slice());
                    patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", &instructions);
                    defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                }
                const message_key = try std.fmt.bufPrint(&key, "message-{d}", .{index});
                try submitTestMessage(&storage, &tmp, "input", message_key, session.slice(), "old input");
                const binding = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureInput).permit.binding;
                if (kind == .instruction and index != population) {
                    // Isolate revision history from accepted-output population.
                    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                } else {
                    try settleCallsForTestingWithFaults(&storage, &tmp, binding, "output", &.{call}, .{}, if (index == population) (if (compact) (if (kind == .instruction) "{\"input_tokens\":99900,\"output_tokens\":0}" else "{\"input_tokens\":99999,\"output_tokens\":0}") else "{\"input_tokens\":1,\"output_tokens\":0}") else null);
                }
                if (kind == .action) {
                    const action = (try storage.admitNextActionAttempt(1000, .{}) orelse return error.MissingPressureAction).permit.binding;
                    _ = try storage.settleActionAttempt(action, .succeeded, "result", .{});
                    // Measure the actual tool successor: the producer's result
                    // is after its usage/output and must remain in pressure.
                    if (index != population) {
                        const continuation = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureContinuation).permit.binding;
                        try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                    }
                }
            }
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("100000");
            if (kind == .instruction) {
                // Same-text updates are new input, not content deduplication.
                patch.configuration.instructions = try testingBytesContent(&tmp, "pending-instruction", &instructions);
            }
            defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            if (kind == .instruction) {
                var clear: wire_request.ConfigureCommand = .{};
                try clear.key.set("clear");
                try clear.session.set(session.slice());
                clear.configuration.instructions = try testingBytesContent(&tmp, "clear-instruction", "");
                defer clear.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(try storage.configure(&clear, .{}) == .accepted);
            }
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.sqliteDatabase(), 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
            };
            try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            if (kind == .instruction) try std.testing.expectEqual(@as(u64, @intCast(population + 1 + @as(usize, if (compact) 0 else 2))), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_revision IS NOT NULL", .{}));
            return measured.steps;
        }
    };
    var bounded = true;
    for ([_]Measure.Population{ .rejection, .action, .instruction }) |kind| {
        for ([_]bool{ false, true }) |compact| {
            const small = try Measure.run(8, kind, compact);
            const large = try Measure.run(128, kind, compact);
            bounded = bounded and large <= small + 200;
        }
    }
    try std.testing.expect(bounded);
}

test "admission fails before COMMIT when a counted write changes other than its selection's rows" {
    const Case = struct { trigger: [:0]const u8, expected: anyerror };
    for ([_]Case{
        .{ .trigger = "CREATE TEMP TRIGGER skip_bind BEFORE UPDATE OF turn_id ON main.message_admission BEGIN SELECT RAISE(IGNORE); END", .expected = error.SelectionChanged },
        .{ .trigger = "CREATE TEMP TRIGGER skip_message BEFORE INSERT ON main.conversation_entry WHEN NEW.entry_kind=1 BEGIN SELECT RAISE(IGNORE); END", .expected = error.ProjectionFailed },
        .{ .trigger = "CREATE TEMP TRIGGER skip_instruction BEFORE INSERT ON main.conversation_entry WHEN NEW.entry_kind=2 BEGIN SELECT RAISE(IGNORE); END", .expected = error.InstructionSelectionFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "counted-admission-config");
        var patch: wire_request.ConfigureCommand = .{};
        try patch.key.set("counted-admission-instructions");
        try patch.session.set(session.slice());
        patch.configuration.instructions = try testingBytesContent(&tmp, "counted-admission-instruction", "an instruction");
        defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "counted-admission-input", "counted-admission-message", session.slice(), "work");
        try sqlite.exec(storage.sqliteDatabase(), case.trigger);
        try std.testing.expectError(case.expected, storage.admitModelAttempt(.message, .{}));
        try std.testing.expect(storage.isFenced());
        // The round failed before COMMIT: no Turn, entry or bound Message stays.
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM conversation_entry", .{}));
        try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE turn_id IS NOT NULL", .{}));
    }
}

test "an admission that selects nothing answers main's names for its idle checks' failed steps" {
    // The idle round's failed step is TurnReadFailed, but the blocked
    // Operation's seek and its calls' outcomes are CallReadFailed.
    const statements = model_admission_domain.idle_statements;
    inline for (.{
        .{ statements[0].sql, error.TurnReadFailed },
        .{ statements[1].sql, error.CallReadFailed },
        .{ statements[2].sql, error.CallReadFailed },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSessionAsk(&storage, "idle-names");
        try submitTestMessage(&storage, &tmp, "idle-names-input", "idle-names-message", session.slice(), "start");
        const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
        // Asked calls block the Operation, so every idle statement steps.
        try settleTwoActionsForTesting(&storage, &tmp, first, "idle-names");
        var fault: TestingStatementFault = .{ .sql = case[0] };
        fault.arm(storage.sqliteDatabase());
        defer fault.disarm(storage.sqliteDatabase());
        try std.testing.expectError(case[1], storage.admitModelAttempt(.message, .{}));
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(storage.isFenced());
    }
}

/// Runs `write` on the connection as the statement whose text is `sql`
/// starts: another writer's commit, between that statement and the ones
/// before it in its round.
const TestingStatementInterleave = struct {
    sql: [:0]const u8,
    write: [:0]const u8,
    database: *c.sqlite3,
    ran: u64 = 0,

    fn arm(self: *TestingStatementInterleave) void {
        _ = c.sqlite3_trace_v2(self.database, c.SQLITE_TRACE_STMT, traced, self);
    }

    fn disarm(self: *const TestingStatementInterleave) void {
        _ = c.sqlite3_trace_v2(self.database, 0, null, null);
    }

    fn traced(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementInterleave = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, std.mem.span(c.sqlite3_sql(@ptrCast(statement))), self.sql)) return 0;
        if (c.sqlite3_exec(self.database, self.write, null, null, null) == c.SQLITE_OK) self.ran += 1;
        return 0;
    }
};

test "a model admission whose Session moves between its selection and its facts writes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "moved-head-config");
    try submitTestMessage(&storage, &tmp, "moved-head-input", "moved-head-message", session.slice(), "work");
    // The selection reads the Session's head; another writer moves it
    // before the facts read it again, outside any transaction.
    var interleave: TestingStatementInterleave = .{
        .sql = model_admission_domain.selected_context_sql,
        .write = "UPDATE session SET next_position=next_position+1",
        .database = storage.sqliteDatabase(),
    };
    interleave.arm();
    const admitted = storage.admitModelAttempt(.message, .{});
    interleave.disarm();
    try std.testing.expectEqual(@as(u64, 1), interleave.ran);
    try std.testing.expectError(error.SelectionChanged, admitted);
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM turn", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM model_operation", .{}));
    try std.testing.expectEqual(@as(u64, 0), try store_testing.sqlite_only.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE turn_id IS NOT NULL", .{}));
}

test "a model admission selects outside its transaction, and one that selects nothing opens none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const database = storage.sqliteDatabase();
    var begins = runsOf(database, "BEGIN IMMEDIATE");
    try std.testing.expect(try storage.admitModelAttempt(.message, .{}) == null);
    try std.testing.expectEqual(begins, runsOf(database, "BEGIN IMMEDIATE"));
    const session = try configureTestSession(&storage, "outside-config");
    try submitTestMessage(&storage, &tmp, "outside-input", "outside-message", session.slice(), "work");
    begins = runsOf(database, "BEGIN IMMEDIATE");
    try std.testing.expect(try storage.admitModelAttempt(.message, .{}) != null);
    try std.testing.expectEqual(begins + 1, runsOf(database, "BEGIN IMMEDIATE"));
    try std.testing.expect(!storage.isFenced());
}
