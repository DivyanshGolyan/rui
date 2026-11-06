//! The Store's tests and their helpers.

const std = @import("std");
const named_scratch = @import("../named_scratch.zig");
const platform = @import("../platform.zig");
const protocol = @import("../protocol.zig");
const tool_catalog = @import("../tools.zig");
const tool_set_domain = @import("domain/tool_set.zig");
const model_capability = @import("../model_capability.zig");
const product_defaults = @import("../product_defaults.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const rsql = @import("rsql.zig");
const Store = store_core.Store;
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const content_domain = @import("domain/content.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const store_schema = @import("schema.zig");
const test_poll = @import("test_poll");
const store_testing = @import("testing.zig");
const turn_domain = @import("domain/turn.zig");
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const AttemptBinding = store_core.AttemptBinding;
const BashExecutionInput = action_domain.BashExecutionInput;
const ConfigurationContentAction = configuration_domain.ConfigurationContentAction;
const ConfigurationUpdatePlan = configuration_domain.ConfigurationUpdatePlan;
const ConfigureReply = configuration_domain.ConfigureReply;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const ControlTracePhase = store_core.ControlTracePhase;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const Faults = store_core.Faults;
const HistoricalContent = historical_domain.HistoricalContent;
const HistoricalEntry = historical_domain.HistoricalEntry;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalReader = historical_domain.HistoricalReader;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const MessageReply = command_domain.MessageReply;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const ModelOperationKind = historical_domain.ModelOperationKind;
const OutputItemKind = historical_domain.OutputItemKind;
const OutputMetadataWriter = store_testing.OutputMetadataWriter;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const SessionReport = report_domain.SessionReport;
const SessionStopReply = command_domain.SessionStopReply;
const SettlementTracePhase = store_core.SettlementTracePhase;
const TestingAnswerPart = store_testing.TestingAnswerPart;
const TurnOutcome = turn_domain.TurnOutcome;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const empty_active_context = action_domain.empty_active_context;
const next_action_attempt_sql = action_domain.next_action_attempt_sql;
const pending_message_count_sql = command_domain.pending_message_count_sql;
const retry_admission_page_rows = model_admission_domain.retry_admission_page_rows;
const retry_admission_select_sql = model_admission_domain.retry_admission_select_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;
const runnable_selection_sql = model_admission_domain.runnable_selection_sql;
const schema_version = store_schema.schema_version;
const session_stop_cutoff_sql = command_domain.session_stop_cutoff_sql;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const testingPublicProjection = store_testing.testingPublicProjection;
const testing_absent_model_evidence = store_testing.testing_absent_model_evidence;
const tool_continuation_selection = model_admission_domain.tool_continuation_selection;

const output_metadata_record_bytes = output_format.output_metadata_record_bytes;

test {
    _ = @import("rsql.zig");
    _ = @import("schema.zig");
    _ = @import("access.zig");
    _ = @import("queue.zig");
}

/// Tests read a view's settings by value; the Host fills them in place.
pub fn testSettings(view: *HistoricalView) !HistoricalSettings {
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    return settings;
}

test "Store allocates six character IDs atomically retries collisions and replays creation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Entropy = struct {
                var draws: usize = 0;
                fn random(_: ?*anyopaque, bytes: []u8) std.Io.RandomSecureError!void {
                    std.debug.assert(bytes.len == protocol.session_id_bytes);
                    @memset(bytes, if (draws < 2) 0 else 255);
                    draws += 1;
                }
            };
            Entropy.draws = 0;
            var vtable = std.testing.io.vtable.*;
            vtable.randomSecure = Entropy.random;
            var io = std.testing.io;
            io.vtable = &vtable;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(io, &workspace_buffer);
            var first = try completeConfiguration("first-creation", "", workspace, "model-a");
            const first_reply = storage.configure(&first, .{});
            try std.testing.expect(first_reply == .accepted);
            const a = first_reply.accepted;
            try std.testing.expect(a.created and !a.replayed);
            try std.testing.expectEqualStrings("000000", a.session.slice());
            var second = try completeConfiguration("second-creation", "", workspace, "model-b");
            const second_reply = storage.configure(&second, .{});
            try std.testing.expect(second_reply == .accepted);
            const b = second_reply.accepted;
            try std.testing.expect(b.created and !b.replayed);
            try std.testing.expectEqualStrings("zzzzzz", b.session.slice());
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            try std.testing.expectEqualStrings("model-a", (try store_core.readSessionForTesting(&storage, a.session.slice())).?.model.slice());
            try std.testing.expectEqualStrings("model-b", (try store_core.readSessionForTesting(&storage, b.session.slice())).?.model.slice());
            const replay = storage.configure(&second, .{}).accepted;
            try std.testing.expect(replay.replayed and replay.created);
            try std.testing.expectEqualStrings(b.session.slice(), replay.session.slice());
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            // The schema refuses a noncanonical reference that the production
            // insert binds; "short" and "1234567" are not a SessionHead's 6 bytes.
            const current = (try store_core.readSessionForTesting(&storage, a.session.slice())).?;
            try insertSessionForTesting(&storage, &current, "k7m2qz");
            for ([_]*const [protocol.session_id_bytes]u8{ "K7m2qx", "k7m2qi", "k7m\x00qx" }) |invalid| {
                try std.testing.expectError(error.StatementFailed, insertSessionForTesting(&storage, &current, invalid));
            }
            var unknown = try completeConfiguration("unknown-update", "k7m2qx", workspace, "model-c");
            try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, storage.configure(&unknown, .{}).rejected.code);
            try std.testing.expect(try store_core.readSessionForTesting(&storage, "k7m2qx") == null);
            for ([_][]const u8{ "old/name", "K7m2qx", "k7m2qi", "k7\x00qx" }, 0..) |invalid, index| {
                var key: [32]u8 = undefined;
                var bad = try completeConfiguration(try std.fmt.bufPrint(&key, "invalid-id-{d}", .{index}), invalid, workspace, "model-c");
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, storage.configure(&bad, .{}).rejected.code);
            }
            try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Store distinguishes noncanonical Session references from canonical unknown messages and controls" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const content = try testingBytesContent(&tmp, "reference-input", "input\x00with\nbytes");
            defer content.file.?.close(std.testing.io);
            const references = [_][]const u8{ "", "short", "1234567", "K7m2qx", "k7m2qi", "k7\x00qx", "old/name", "k7m2qx" };
            for (references, 0..) |reference, index| {
                const canonical_unknown = index == references.len - 1;
                var key: [64]u8 = undefined;
                var message: protocol.MessageCommand = .{ .text = content };
                try message.key.set(try std.fmt.bufPrint(&key, "reference-message-{d}", .{index}));
                try message.session.set(reference);
                const message_reply = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(message_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.MessageRejection.unknown_session else .invalid_session_reference, message_reply.rejected.code);
                const message_replay = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(message_replay == .rejected and message_replay.rejected.replayed);
                try std.testing.expectEqual(message_reply.rejected.code, message_replay.rejected.code);

                var stop = try completeSessionStop(try std.fmt.bufPrint(&key, "reference-stop-{d}", .{index}), reference);
                const stop_reply = storage.stopSession(&stop, .{});
                try std.testing.expect(stop_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.SessionStopRejection.unknown_session else .invalid_session_reference, stop_reply.rejected.code);
                const stop_replay = storage.stopSession(&stop, .{});
                try std.testing.expect(stop_replay == .rejected and stop_replay.rejected.replayed);
                try std.testing.expectEqual(stop_reply.rejected.code, stop_replay.rejected.code);

                var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
                try interrupt.key.set(try std.fmt.bufPrint(&key, "reference-interrupt-{d}", .{index}));
                try interrupt.session.set(reference);
                const interrupt_reply = storage.interruptModel(&interrupt, .{});
                try std.testing.expect(interrupt_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.ModelInterruptionRejection.unknown_session else .invalid_session_reference, interrupt_reply.rejected.code);
                const interrupt_replay = storage.interruptModel(&interrupt, .{});
                try std.testing.expect(interrupt_replay == .rejected and interrupt_replay.rejected.replayed);
                try std.testing.expectEqual(interrupt_reply.rejected.code, interrupt_replay.rejected.code);

                var permission: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
                try permission.key.set(try std.fmt.bufPrint(&key, "reference-permission-{d}", .{index}));
                try permission.session.set(reference);
                const permission_reply = storage.decidePermission(&permission, .{});
                try std.testing.expect(permission_reply == .rejected);
                try std.testing.expectEqual(if (canonical_unknown) protocol.PermissionDecisionRejection.unknown_session else .invalid_session_reference, permission_reply.rejected.code);
                const permission_replay = storage.decidePermission(&permission, .{});
                try std.testing.expect(permission_replay == .rejected and permission_replay.rejected.replayed);
                try std.testing.expectEqual(permission_reply.rejected.code, permission_replay.rejected.code);
                try std.testing.expect(!storage.isFenced());
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
        }
    }.run);
}

pub fn testingContent(tmp: *std.testing.TmpDir, name: []const u8, fill: u8, length: usize) !protocol.ContentField {
    const file = try tmp.dir.createFile(std.testing.io, name, .{ .read = true });
    errdefer file.close(std.testing.io);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    @memset(&buffer, fill);
    var remaining = length;
    var hash = protocol.contentHasher();
    while (remaining != 0) {
        const count = @min(remaining, buffer.len);
        try file.writeStreamingAll(std.testing.io, buffer[0..count]);
        hash.update(buffer[0..count]);
        remaining -= count;
    }
    try file.sync(std.testing.io);
    return .{
        .state = .value,
        .file = file,
        .length = length,
        .digest = hash.finalResult(),
    };
}

pub fn testingBytesContent(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !protocol.ContentField {
    const file = try tmp.dir.createFile(std.testing.io, name, .{ .read = true });
    errdefer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
    return .{
        .state = .value,
        .file = file,
        .length = bytes.len,
        .digest = protocol.contentDigest(bytes),
    };
}

/// A content row's length and digest, for a test's own checks.
pub fn testingContentReference(storage: *Store, content_id: u64) !ContentReference {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: reads_domain.ReadAccess = .open(&entry);
    defer a.deinit();
    var row: content_domain.content_metadata.Row = undefined;
    a.read(content_domain.content_metadata, .{ .content_id = content_id }, &row);
    try a.run();
    return .{ .length = row.byte_length, .digest = row.digest };
}

/// Records that the running entry point changed `session`, as an Access's
/// `@session` tie does, for a test that writes its rows by hand. It
/// repeats `Access.touch` because that is private to Access, so that only a
/// typed write touches, and a hand-written row has no typed write.
pub fn touchForTesting(storage: *Store, session: []const u8) !void {
    const workspace = try store_testing.queryU64(storage, "SELECT workspace_key FROM session WHERE session_ref=?1", .{session});
    if (storage.touched.needsEntry(session)) storage.touched.add(.{ .session = session[0..change_ring.id_bytes].*, .workspace = workspace });
}

/// Runs the production INSERT of a created Session under `ref`, then rolls
/// it back, so a test sees what the schema accepts without keeping it.
fn insertSessionForTesting(storage: *Store, current: *const configuration_domain.CurrentConfiguration, ref: *const [protocol.session_id_bytes]u8) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{}) = .open(&entry);
    defer a.deinit();
    const head: rsql.SessionHead = .{ .ref = ref.*, .workspace_key = .of(current.workspace_key), .next_position = .of(1) };
    const digest = store_core.workspaceDigest(current.workspace.slice());
    configuration_domain.insertSession(&a, head, current, &digest, 1_000_000, null);
    const ran = a.run();
    try a.abandon(.{});
    return ran;
}

pub fn admitRetryForTesting(storage: *Store) !?AttemptAdmission {
    return storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{});
}

pub fn completeSessionStop(key: []const u8, session_ref: []const u8) !protocol.SessionStopCommand {
    var command: protocol.SessionStopCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    return command;
}

pub fn completeModelInterruption(
    key: []const u8,
    session_ref: []const u8,
    binding: AttemptBinding,
) !protocol.ModelInterruptionCommand {
    var command: protocol.ModelInterruptionCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.turn_id = binding.turn_id;
    command.operation_id = binding.operation_id;
    return command;
}

pub fn expectActivityOutcome(storage: *Store, session: []const u8, binding: AttemptBinding, ending: protocol.TurnEnding, code: []const u8) !void {
    var request: protocol.ActivityPage = .{ .direction = .backward };
    try request.session.set(session);
    const page = try store_core.activityPageForTesting(storage, request);
    try std.testing.expect(page.count != 0 and page.items[0].value == .turn_ended);
    const outcome = page.items[0].value.turn_ended;
    try std.testing.expectEqual(binding.turn_id, outcome.turn);
    try std.testing.expectEqual(binding.operation_id, outcome.operation);
    try std.testing.expectEqual(ending, outcome.ending);
    try std.testing.expectEqualStrings(code, outcome.code.slice());
    try std.testing.expectEqual(page.end, page.items[0].position);
}

pub fn configureTestSessionAsk(
    storage: *Store,
    key: []const u8,
) !protocol.Bounded(protocol.max_session_bytes) {
    return configureTestSessionWithMode(storage, key, "ask");
}

fn configureTestSessionWithMode(
    storage: *Store,
    key: []const u8,
    mode: []const u8,
) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools = try .of(&.{"bash"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set(mode);
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

pub const TestingCall = struct {
    item_id: []const u8,
    name: []const u8,
    encoded_call_id: []const u8,
    decoded_call_id: []const u8,
    encoded_arguments: []const u8,
    decoded_arguments: []const u8,
};

pub fn settleCallsForTesting(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    binding: AttemptBinding,
    file_prefix: []const u8,
    calls: []const TestingCall,
) !void {
    return settleCallsForTestingWithFaults(storage, tmp, binding, file_prefix, calls, .{}, null);
}

pub fn settleCallsForTestingWithFaults(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    binding: AttemptBinding,
    file_prefix: []const u8,
    calls: []const TestingCall,
    faults: Faults,
    usage_json: ?[]const u8,
) !void {
    var capacity: usize = if (usage_json) |bytes| bytes.len else 0;
    for (calls) |call| capacity += 128 + 6 * (call.item_id.len + call.name.len) +
        call.encoded_call_id.len + call.encoded_arguments.len;
    const source_buffer = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(source_buffer);
    const ranges = try std.testing.allocator.alloc([2]u64, calls.len);
    defer std.testing.allocator.free(ranges);
    var source_writer = std.Io.Writer.fixed(source_buffer);
    for (calls, ranges) |call, *range| {
        const item_start = source_writer.end;
        try source_writer.writeAll("{\"type\":\"function_call\",\"id\":");
        try std.json.Stringify.value(call.item_id, .{}, &source_writer);
        try source_writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, &source_writer);
        try source_writer.print(",\"call_id\":\"{s}\",\"arguments\":\"{s}\"}}", .{ call.encoded_call_id, call.encoded_arguments });
        range.* = .{ item_start, source_writer.end - item_start };
    }
    if (usage_json) |bytes| {
        try source_writer.writeAll(bytes);
    }
    const source_bytes = source_writer.buffered();
    var source_name: [64]u8 = undefined;
    const source = try tmp.dir.createFile(std.testing.io, try std.fmt.bufPrint(&source_name, "{s}-source", .{file_prefix}), .{ .read = true });
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
        file_prefix,
        .{ .used = &metadata_used, .limit = try std.math.mul(u64, calls.len + 1, 64 * output_metadata_record_bytes) },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    // Acceptance's own recorder, so the metadata is what acceptance writes.
    for (ranges, 0..) |range, ordinal| {
        const record = try output_decode.recordItemForTesting(&metadata, source, range[0], range[1], ordinal, .assistant_response);
        std.debug.assert(record.kind == .function_call);
    }
    if (usage_json) |bytes| {
        const start = source_bytes.len - bytes.len;
        try metadata.append(&.{
            .tag = .usage,
            .start = start,
            .length = bytes.len,
            .content_digest = protocol.contentDigest(bytes),
            .usage = try output_decode.readUsageForTesting(std.testing.io, source, start, bytes.len),
        });
    }
    try metadata.sealForRead();
    try storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = calls.len,
        .call_count = calls.len,
        .answer_length = 0,
        .answer_digest = protocol.contentDigest(""),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    }, faults);
}

pub fn settleTwoActionsForTesting(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    binding: AttemptBinding,
    file_prefix: []const u8,
) !void {
    const calls = [_]TestingCall{
        .{
            .item_id = "item-1",
            .name = "bash",
            .encoded_call_id = "call\\nA",
            .decoded_call_id = "call\nA",
            .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}",
        },
        .{
            .item_id = "item-2",
            .name = "bash",
            .encoded_call_id = "call-B",
            .decoded_call_id = "call-B",
            .encoded_arguments = "{\\\"description\\\":\\\"Run second command\\\",\\\"cmd\\\":\\\"two\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"description\":\"Run second command\",\"cmd\":\"two\",\"timeout_ms\":null}",
        },
    };
    try settleCallsForTesting(storage, tmp, binding, file_prefix, &calls);
}

pub fn expectContent(storage: *Store, reference: ContentReference, expected: []const u8) !void {
    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(reference));
    defer reader.close();
    var actual: [128]u8 = undefined;
    const count = try reader.read(0, &actual);
    try std.testing.expectEqualStrings(expected, actual[0..count]);
    try std.testing.expectEqual(@as(usize, 0), try reader.read(count, &actual));
}

pub const TestingReportAction = struct {
    action: []const u8,
    call_ordinal: []const u8,
    permission_revision: []const u8,
    authorization: []const u8,
};

pub const TestingResolvedAction = struct {
    action: []const u8,
    call_ordinal: []const u8,
    code: []const u8,
    acceptance_position: []const u8,
    result: TestingContentReference,
};

pub const TestingContentReference = struct {
    bytes: []const u8,
    sha256: []const u8,
};

pub const TestingRejectedCall = struct {
    call_ordinal: []const u8,
    code: []const u8,
    acceptance_position: []const u8,
    result: TestingContentReference,
    name: TestingContentReference,
    call_id: TestingContentReference,
    arguments: TestingContentReference,
};

pub const TestingSessionReport = struct {
    actions: struct {
        count: []const u8,
        unresolved: []TestingReportAction,
        resolved: []TestingResolvedAction,
    },
    rejected_calls: struct {
        count: []const u8,
        items: []TestingRejectedCall,
    },
};

pub fn testingSessionReport(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session_ref: []const u8,
    limit: u64,
) ![]u8 {
    return testingSessionReportWithProfile(storage, tmp, session_ref, limit, .current);
}

pub fn testingSessionReportWithProfile(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session_ref: []const u8,
    limit: u64,
    profile: protocol.ReportProfile,
) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var report = try storage.captureSessionReport(session_ref, .{
        .scratch_path = root[0..root_length],
        .scratch_budget = .{ .used = &used, .limit = limit },
        .request_number = 1,
        .profile = profile,
        .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
    });
    const bytes = try std.testing.allocator.alloc(u8, @intCast(report.length));
    errdefer std.testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try report.read(offset, bytes[offset..@min(bytes.len, offset + SessionReport.read_window_bytes)]);
        if (count == 0) return error.ShortReportRead;
        offset += count;
    }
    report.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    return bytes;
}

/// Visits real Current and Full captures, including absent, idle, terminal
/// and active approval work. The caller supplies the schema checker.
pub fn checkSessionReportsForTesting(context: anytype) !void {
    const Fixture = struct {
        fn run(engine: *store_testing.Case, checker: @TypeOf(context)) !void {
            const Profiles = struct {
                fn check(sink: @TypeOf(context), storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !void {
                    inline for (.{ protocol.ReportProfile.current, protocol.ReportProfile.full }) |profile| {
                        const bytes = try testingSessionReportWithProfile(storage, tmp, session, 1024 * 1024, profile);
                        defer std.testing.allocator.free(bytes);
                        try sink.report(bytes);
                    }
                }
            };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try Profiles.check(checker, &storage, &tmp, "aaaaaa");
            const session = try configureTestSessionAsk(&storage, "schema-config");
            try Profiles.check(checker, &storage, &tmp, session.slice());
            try store_testing.answerTestTurn(&storage, &tmp, session.slice(), "schema-answer", &.{.{ .encoded = "done", .decoded = "done" }});
            try Profiles.check(checker, &storage, &tmp, session.slice());
            try store_testing.submitTestMessage(&storage, &tmp, "schema-message", "schema-message", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "schema-calls");
            const active = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(active);
            const active_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, active, .{});
            defer active_json.deinit();
            const unresolved = active_json.value.object.get("actions").?.object.get("unresolved").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), unresolved.len);
            try std.testing.expectEqualStrings("approval", active_json.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try Profiles.check(checker, &storage, &tmp, session.slice());
            // Keep one unresolved Action while the other supplies a resolved row,
            // permission decision and ordered Tool Result to both profiles.
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = try std.fmt.parseInt(u64, unresolved[0].object.get("action").?.string, 10), .decision = .deny };
            try deny.key.set("schema-deny");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            try Profiles.check(checker, &storage, &tmp, session.slice());
        }
    };
    inline for (comptime std.enums.values(store_testing.Engine)) |engine| {
        if (engine != .mysql or try @import("mysql_testing.zig").available()) {
            var case: store_testing.Case = .{ .engine = engine };
            try Fixture.run(&case, context);
        }
    }
}

pub fn testingSessionList(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions, used: *std.atomic.Value(u64), request_number: u64) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var report = try storage.captureSessionList(&request, .{
        .scratch_path = root[0..length],
        .scratch_budget = .{ .used = used, .limit = 1024 * 1024 },
        .request_number = request_number,
    });
    defer report.deinit();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(report.length));
    errdefer std.testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try report.read(offset, bytes[offset..@min(bytes.len, offset + SessionReport.read_window_bytes)]);
        if (count == 0) return error.ShortReportRead;
        offset += count;
    }
    return bytes;
}

test "Session list pages accepted creation order with exact workspace and fixed high water" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var long_path: [3 * 241]u8 = undefined;
            @memset(&long_path, 'w');
            long_path[240] = '/';
            long_path[481] = '/';
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, &long_path, .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            var used = std.atomic.Value(u64).init(0);
            // Not configuration: request captures must never create list entries.
            var unrelated = try completeConfiguration("rejected-list", "", workspace, "model");
            unrelated.configuration.workspace.state = .omitted;
            try std.testing.expect(storage.configure(&unrelated, .{}) == .rejected);
            const empty = try testingSessionList(&storage, &tmp, .{}, &used, 1);
            defer std.testing.allocator.free(empty);
            // A full listing's token is this opening's current generation.
            var token: [protocol.SinceToken.max_bytes]u8 = undefined;
            const since = (protocol.SinceToken{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) }).format(&token);
            var expected_empty: [256]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_empty, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[],\"delta\":\"full\",\"since\":\"{s}\",\"next\":null}}", .{since}), empty);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

            var ids: [10]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&ids, 0..) |*id, index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "list-config-{d}", .{index});
                var config = try completeConfiguration(key, "", workspace, "model\nwith-control");
                if (index == 3) try config.configuration.workspace.value.set(other);
                const configured = storage.configure(&config, .{});
                try std.testing.expect(configured == .accepted);
                id.* = configured.accepted.session;
                if (index == 8) {
                    var exactly_eight = protocol.ListSessions{};
                    exactly_eight.workspace = .{};
                    try exactly_eight.workspace.?.set(workspace);
                    const boundary = try testingSessionList(&storage, &tmp, exactly_eight, &used, 99);
                    defer std.testing.allocator.free(boundary);
                    var parsed_boundary = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, boundary, .{});
                    defer parsed_boundary.deinit();
                    try std.testing.expectEqual(@as(usize, 8), parsed_boundary.value.object.get("sessions").?.array.items.len);
                    try std.testing.expect(parsed_boundary.value.object.get("next").? == .null);
                }
            }
            var request = protocol.ListSessions{};
            try std.testing.expectError(error.InvalidCursor, storage.captureSessionList(&.{ .after = 2, .ceiling = 1 }, undefined));
            request.workspace = .{};
            try request.workspace.?.set(workspace);
            const first = try testingSessionList(&storage, &tmp, request, &used, 2);
            defer std.testing.allocator.free(first);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first, .{});
            defer parsed.deinit();
            const sessions = parsed.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 8), sessions.len);
            const expected = [_][]const u8{ ids[0].slice(), ids[1].slice(), ids[2].slice(), ids[4].slice(), ids[5].slice(), ids[6].slice(), ids[7].slice(), ids[8].slice() };
            for (sessions, expected) |item, name| {
                try std.testing.expectEqualStrings(name, item.object.get("reference").?.string);
                try std.testing.expectEqualStrings(workspace, item.object.get("workspace").?.string);
                try std.testing.expectEqualStrings("model\nwith-control", item.object.get("model").?.string);
            }
            const next = parsed.value.object.get("next").?.object;
            request.after = try std.fmt.parseInt(u64, next.get("after").?.string, 10);
            request.ceiling = try std.fmt.parseInt(u64, next.get("ceiling").?.string, 10);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            var later = try completeConfiguration("list-later", "", workspace, "different");
            try std.testing.expect(storage.configure(&later, .{}) == .accepted);
            const second = try testingSessionList(&storage, &tmp, request, &used, 3);
            defer std.testing.allocator.free(second);
            var final = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second, .{});
            defer final.deinit();
            try std.testing.expectEqualStrings(ids[9].slice(), final.value.object.get("sessions").?.array.items[0].object.get("reference").?.string);
            try std.testing.expectEqual(@as(usize, 1), final.value.object.get("sessions").?.array.items.len);
            try std.testing.expect(final.value.object.get("next").? == .null);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            var exact = protocol.ListSessions{};
            exact.workspace = .{};
            try exact.workspace.?.set(other);
            const filtered = try testingSessionList(&storage, &tmp, exact, &used, 4);
            defer std.testing.allocator.free(filtered);
            var filtered_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, filtered, .{});
            defer filtered_json.deinit();
            const one = filtered_json.value.object.get("sessions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), one.len);
            try std.testing.expectEqualStrings(ids[3].slice(), one[0].object.get("reference").?.string);
            try std.testing.expectEqualStrings(other, one[0].object.get("workspace").?.string);
            var scratch_path: [protocol.max_store_bytes]u8 = undefined;
            const scratch_length = try tmp.dir.realPath(std.testing.io, &scratch_path);
            // Hold a captured page while a new configuration commits: delivery owns
            // scratch, not a SQLite cursor, transaction or Store entry.
            var held = try storage.captureSessionList(&.{}, .{
                .scratch_path = scratch_path[0..scratch_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 5,
            });
            try std.testing.expect(used.load(.acquire) > 0);
            var concurrent = try completeConfiguration("list-concurrent", "", workspace, "model");
            try std.testing.expect(storage.configure(&concurrent, .{}) == .accepted);
            held.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expectError(error.ReportScratchExhausted, storage.captureSessionList(&.{}, .{
                .scratch_path = scratch_path[0..scratch_length],
                .scratch_budget = .{ .used = &used, .limit = 16 },
                .request_number = 6,
            }));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

/// One list page as a client reads it, and the request that continues it.
pub const TestingListing = struct {
    delta: protocol.ListDelta,
    since: protocol.SinceToken,
    references: [protocol.session_list_page_size]change_ring.Id = undefined,
    count: usize = 0,
    next: ?protocol.ListSessions = null,

    pub fn read(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions) !TestingListing {
        var used = std.atomic.Value(u64).init(0);
        const bytes = try testingSessionList(storage, tmp, request, &used, 1);
        defer std.testing.allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        var result: TestingListing = .{
            .delta = std.meta.stringToEnum(protocol.ListDelta, object.get("delta").?.string).?,
            .since = try protocol.SinceToken.parse(object.get("since").?.string),
        };
        for (object.get("sessions").?.array.items) |row| {
            result.references[result.count] = row.object.get("reference").?.string[0..protocol.session_id_bytes].*;
            result.count += 1;
        }
        if (object.get("next").? == .object) {
            const next = object.get("next").?.object;
            var continued: protocol.ListSessions = .{ .workspace = request.workspace };
            if (next.get("through")) |through| {
                continued.since = request.since;
                continued.changed = .{ .through = try std.fmt.parseInt(u64, through.string, 10), .after_reference = next.get("after_reference").?.string[0..protocol.session_id_bytes].* };
            } else {
                continued.after = try std.fmt.parseInt(u64, next.get("after").?.string, 10);
                continued.ceiling = try std.fmt.parseInt(u64, next.get("ceiling").?.string, 10);
            }
            result.next = continued;
        }
        return result;
    }

    pub fn expectReferences(self: *const TestingListing, expected: []const change_ring.Id) !void {
        try std.testing.expectEqual(expected.len, self.count);
        for (expected, self.references[0..self.count]) |*want, *got| try std.testing.expectEqualStrings(want, got);
    }
};

test "a since listing answers only the Sessions changed since its token, or everything" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            var commands: u64 = 0;
            const Change = struct {
                /// Creates a Session, or relabels one: a new revision each time.
                fn configure(store: *Store, count: *u64, session: []const u8, place: []const u8) !change_ring.Id {
                    count.* += 1;
                    var key: [32]u8 = undefined;
                    var command = try completeConfiguration(try std.fmt.bufPrint(&key, "since-{d}", .{count.*}), session, place, "model");
                    command.configuration.label.state = .value;
                    try command.configuration.label.value.set(try std.fmt.bufPrint(&key, "Label {d}", .{count.*}));
                    const configured = store.configure(&command, .{});
                    try std.testing.expect(configured == .accepted);
                    return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
                }
            };
            var ids: [12]change_ring.Id = undefined;
            for (&ids) |*id| id.* = try Change.configure(&storage, &commands, "", workspace);
            const elsewhere = try Change.configure(&storage, &commands, "", other);
            var scope: protocol.ListSessions = .{ .workspace = .{} };
            try scope.workspace.?.set(workspace);

            // A full listing's token is the generation it read under.
            const full = try TestingListing.read(&storage, &tmp, scope);
            try std.testing.expectEqual(protocol.ListDelta.full, full.delta);
            try std.testing.expectEqualSlices(u8, &storage.instance, &full.since.instance);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), full.since.generation);
            try std.testing.expect(storage.notModified(full.since));
            var since = scope;
            since.since = full.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});

            // Only what changed, read fresh, in ID order; the token moves to now.
            const changed_pair = [_]change_ring.Id{ ids[3], ids[10] };
            _ = try Change.configure(&storage, &commands, &ids[10], workspace);
            _ = try Change.configure(&storage, &commands, &ids[3], workspace);
            try std.testing.expect(!storage.notModified(full.since));
            var sorted_pair = changed_pair;
            std.mem.sort(change_ring.Id, &sorted_pair, {}, testingIdLess);
            const pair = try TestingListing.read(&storage, &tmp, since);
            try std.testing.expectEqual(protocol.ListDelta.changed, pair.delta);
            try pair.expectReferences(&sorted_pair);
            try std.testing.expectEqual(storage.commit_generation.load(.acquire), pair.since.generation);
            try std.testing.expect(storage.notModified(pair.since));
            // Another opening's token, even at this generation, gets everything.
            var stranger = since;
            stranger.since.?.instance[0] ^= 1;
            stranger.since.?.generation = pair.since.generation;
            try std.testing.expect(!storage.notModified(stranger.since.?));
            try std.testing.expectEqual(protocol.ListDelta.full, (try TestingListing.read(&storage, &tmp, stranger)).delta);

            // The request's Workspace scopes the changes.
            _ = try Change.configure(&storage, &commands, &elsewhere, other);
            since.since = pair.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{});
            try (try TestingListing.read(&storage, &tmp, .{ .since = pair.since })).expectReferences(&.{elsewhere});

            // Eight per page; a continuation answers through the first page's
            // generation, so a commit between pages waits for the next token.
            since.since = (try TestingListing.read(&storage, &tmp, since)).since;
            for (ids) |id| _ = try Change.configure(&storage, &commands, &id, workspace);
            var all = ids;
            std.mem.sort(change_ring.Id, &all, {}, testingIdLess);
            const first = try TestingListing.read(&storage, &tmp, since);
            try first.expectReferences(all[0..8]);
            try std.testing.expectEqual(first.since.generation, first.next.?.changed.?.through);
            _ = try Change.configure(&storage, &commands, &all[0], workspace);
            const rest = try TestingListing.read(&storage, &tmp, first.next.?);
            try std.testing.expectEqual(protocol.ListDelta.changed, rest.delta);
            try rest.expectReferences(all[8..]);
            try std.testing.expect(rest.next == null);
            try std.testing.expectEqual(first.since.generation, rest.since.generation);
            since.since = rest.since;
            try (try TestingListing.read(&storage, &tmp, since)).expectReferences(&.{all[0]});

            // Once the hint forgets a change after the token, the answer is the
            // ordinary traversal, and so is a changed continuation that was
            // overtaken.
            storage.changes.forget(storage.commit_generation.load(.acquire));
            _ = try Change.configure(&storage, &commands, &ids[0], workspace);
            for ([_]protocol.ListSessions{ since, first.next.? }) |request| {
                const restarted = try TestingListing.read(&storage, &tmp, request);
                try std.testing.expectEqual(protocol.ListDelta.full, restarted.delta);
                try std.testing.expectEqual(@as(usize, 8), restarted.count);
                try std.testing.expect(restarted.next.?.since == null and restarted.next.?.after != 0);
                try std.testing.expectEqual(storage.commit_generation.load(.acquire), restarted.since.generation);
            }
            // A fenced Store never answers unchanged, so the read reports the failure.
            const now: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            try std.testing.expect(storage.notModified(now));
            try std.testing.expectEqual(error.SqliteExecFailed, store_core.fence(&storage, error.SqliteExecFailed));
            try std.testing.expect(!storage.notModified(now));
        }
    }.run);
}

fn testingIdLess(_: void, left: change_ring.Id, right: change_ring.Id) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

test "a Session creation that rolls back never reaches a since listing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "rollback-config");
            const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
            {
                // The creation's write round runs, then its transaction rolls back.
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const create = try completeConfiguration("rollback-create", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var a: store_access.Access(.write, error{SessionUpdateFailed}) = .open(&entry);
                defer a.deinit();
                const reads = storage.configurationReads();
                reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
                configuration_domain.prepareConfiguration(&a, "", &create.configuration, reads);
                try a.run();
                try std.testing.expect(try configuration_domain.applyConfiguration(&a, storage.io, "", &create.configuration, .{}, reads) == .accepted);
                try a.run();
                try a.abandon(.{});
            }
            // The rolled-back insert still moved the commit counter. The hint
            // forgot instead of naming a Session that does not exist.
            try std.testing.expect(!storage.notModified(since));
            const listed = try TestingListing.read(&storage, &tmp, .{ .since = since });
            try std.testing.expectEqual(protocol.ListDelta.full, listed.delta);
            try listed.expectReferences(&.{session.slice()[0..protocol.session_id_bytes].*});
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

pub const TestingRound = struct {
    pub const head = rsql.Read(.{
        .sql = "SELECT session_ref,workspace_key,next_position FROM session WHERE session_ref=?1",
        .Args = struct { session_ref: []const u8 },
        .Row = struct { head: rsql.SessionHead },
        .cardinality = .one,
    });
    pub const insert_content = rsql.Write(.{
        .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),0)",
        .Args = struct { content_id: u64, digest: [32]u8, length: u64 },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
    });
    pub const date_session = rsql.Write(.{
        .sql = "UPDATE session SET created_at=@now WHERE session_ref=@session(?1) AND revision=?2",
        .Args = struct { session: rsql.SessionHead, revision: u64 },
        .expect = .{ .exact = .{ .rows = 1, .otherwise = error.TestingGuard } },
    });

    /// Reads `session`'s head, imports `text` and claims two positions,
    /// then dates the Session where its revision is `revision`.
    pub fn change(storage: *Store, session: []const u8, text: []const u8, revision: u64) !u64 {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
        defer a.deinit();
        return entry.finishTransaction(error{TestingGuard}, .{}, a.end(.{}, body(&a, session, text, revision)));
    }

    pub fn body(a: anytype, session: []const u8, text: []const u8, revision: u64) !u64 {
        var loaded: head.Result = undefined;
        a.read(head, .{ .session_ref = session }, &loaded);
        try a.run();
        const positions = try a.positions(loaded.head);
        const first = try positions.take(2);
        const content_id = try a.identity(.content_id);
        const digest = protocol.contentDigest(text);
        a.write(insert_content, .{ .content_id = content_id, .digest = digest, .length = text.len });
        a.writeContent(content_id, text);
        a.write(date_session, .{ .session = loaded.head, .revision = revision });
        try a.commit();
        return first;
    }
};

test "a content sink opens only a content id its Access itself took, stepping its queued insert" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "sink-config");
            // A row a committed configure inserted, not this Access.
            const existing: u64 = @intCast((try store_core.readSessionForTesting(&storage, session.slice())).?.instructions_id.?);

            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.write, error{}) = .open(&entry);
            defer a.deinit();
            // Opens the transaction, so the next id is taken in it, before this
            // Access takes any.
            _ = try a.identity(.turn_id);
            const before = try store_core.takeIdentity(&storage, .content_id);
            // Distinct identities, since content is unique by identity.
            const digests = [3][32]u8{ protocol.contentDigest("sink0"), protocol.contentDigest("sink1"), protocol.contentDigest("sink2") };
            a.write(TestingRound.insert_content, .{ .content_id = before, .digest = digests[0], .length = 4 });
            const first = try a.identity(.content_id);
            a.write(TestingRound.insert_content, .{ .content_id = first, .digest = digests[1], .length = 4 });
            // Taken outside this Access between its own ids: inside the range of
            // the ids it took, but not its own.
            const between = try store_core.takeIdentity(&storage, .content_id);
            const never = try a.identity(.content_id);
            const last = try a.identity(.content_id);
            a.write(TestingRound.insert_content, .{ .content_id = last, .digest = digests[2], .length = 4 });
            try std.testing.expectEqual(first + 3, last);
            // Refused: 0, a committed row, one taken in this transaction before
            // this Access's first, one other code took between its own, and one
            // past its last. A check of the range from its first id to its last
            // accepted `between`.
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(0, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(existing, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(before, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(between, 4));
            try std.testing.expectError(error.ContentNotInserted, a.contentSink(last + 1, 4));
            // The old rule took only the last id, with nothing queued: here the
            // first id opens while inserts are queued, and the pass steps them.
            const sink = try a.contentSink(first, 4);
            try sink.write("sink", 0);
            sink.close();
            try std.testing.expectEqual(0, a.queued);
            const again = try a.contentSink(last, 4);
            again.close();
            // Taken but never inserted: there is no row to open.
            try std.testing.expectError(error.ContentWriteFailed, a.contentSink(never, 4));
            try a.abandon(.{});
        }
    }.run);
}

test "a queued read's destination holds poison until the pass that steps it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "poison");
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.read, error{}) = .open(&entry);
            defer a.deinit();
            const poisoned = struct {
                fn all(bytes: []const u8) bool {
                    for (bytes) |byte| if (byte != store_access.poison_byte) return false;
                    return true;
                }
            }.all;
            var first: TestingRound.head.Result = undefined;
            var second: TestingRound.head.Result = undefined;
            @memset(std.mem.asBytes(&first), 0);
            @memset(std.mem.asBytes(&second), 0);
            a.read(TestingRound.head, .{ .session_ref = session.slice() }, &first);
            try std.testing.expect(poisoned(std.mem.asBytes(&first)));
            // Overflow the queue to force an automatic pass on every engine.
            // SQLite may step earlier on rebind; MySQL has no cached handles.
            var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
            for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
            a.read(TestingRound.head, .{ .session_ref = session.slice() }, &second);
            try std.testing.expect(!poisoned(std.mem.asBytes(&first)));
            try std.testing.expectEqualSlices(u8, session.slice(), &first.head.ref);
            try std.testing.expect(poisoned(std.mem.asBytes(&second)));
            try a.run();
            try std.testing.expectEqualSlices(u8, session.slice(), &second.head.ref);
        }
    }.run);
}

test "a queued readInto's Found is pending until the pass that steps it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "found-pending");
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.read, error{}) = .open(&entry);
            defer a.deinit();
            var current: configuration_domain.CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
            var missing_current: configuration_domain.CurrentConfiguration = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } };
            // A bool here held 0xAA, which reads as true: found before any step.
            var found: store_access.Found = .missing;
            var missing: store_access.Found = .found;
            configuration_domain.readSaved(&a, session.slice(), &current, &found);
            try std.testing.expectEqual(store_access.Found.pending, found);
            // Fill with small rows in distinct stable destinations, rather
            // than copying the 4.6 KiB configuration Row for every queue slot.
            // Overflow forces a pass even without SQLite's rebind boundary.
            var fillers: [a.queue.len - 1]TestingRound.head.Result = undefined;
            for (&fillers) |*filler| a.read(TestingRound.head, .{ .session_ref = session.slice() }, filler);
            configuration_domain.readSaved(&a, "AAAAAA", &missing_current, &missing);
            try std.testing.expectEqual(store_access.Found.found, found);
            try std.testing.expectEqual(store_access.Found.pending, missing);
            try a.run();
            try std.testing.expect(found.get());
            try std.testing.expect(!missing.get());
        }
    }.run);
}

test "the touch oracle names a sender whose sent Message changed without its touch" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const recipient = try configureTestSession(&storage, "oracle-recipient");
            const sender = try configureTestSession(&storage, "oracle-sender");
            try submitTestMessage(&storage, &tmp, "oracle-message-file", "oracle-message", recipient.slice(), "hello");
            {
                // Make the Message a sent one, touching both its Sessions.
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                try store_testing.exec(&storage, "UPDATE message_admission SET sender_session_ref=?1,sender_position=1000000 WHERE command_key='oracle-message'", .{sender.slice()});
                try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, recipient.slice());
                try touchForTesting(&storage, sender.slice());
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                try touchForTesting(&storage, recipient.slice());
                // A column only the recipient reads.
                try store_testing.exec(&storage, "UPDATE message_admission SET turn_id=NULL WHERE command_key='oracle-message'", .{});
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
                // A hand-written writer that changes what the sender's page reads
                // and skips the sender.
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=admitted_at+1 WHERE command_key='oracle-message'", .{});
                try std.testing.expectEqualStrings(sender.slice(), &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, sender.slice());
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
        }
    }.run);
}

test "an Access that touches a fifth Session records everything and still commits" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var sessions: [5]protocol.Bounded(protocol.max_session_bytes) = undefined;
            inline for (&sessions, .{ "five-a", "five-b", "five-c", "five-d", "five-e" }) |*session, key| session.* = try configureTestSession(&storage, key);

            const Five = struct {
                fn body(a: anytype, all: []const protocol.Bounded(protocol.max_session_bytes)) !void {
                    for (all) |session| {
                        var loaded: TestingRound.head.Result = undefined;
                        a.read(TestingRound.head, .{ .session_ref = session.slice() }, &loaded);
                        try a.run();
                        a.write(TestingRound.date_session, .{ .session = loaded.head, .revision = 1 });
                        try a.run();
                    }
                    try a.commit();
                }
            };
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
                defer a.deinit();
                try entry.finishTransaction(error{TestingGuard}, .{}, a.end(.{}, Five.body(&a, &sessions)));
            }
            try std.testing.expect(storage.touched.everything);
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
        }
    }.run);
}

test "every round of a write Access dates its rows with the transaction's second" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const first = try configureTestSession(&storage, "second-first");
            const second = try configureTestSession(&storage, "second-second");
            const Clock = struct {
                fn passed(dated: i64) !bool {
                    return @divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000) > dated;
                }
            };
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
            defer a.deinit();
            var heads: [2]TestingRound.head.Result = undefined;
            a.read(TestingRound.head, .{ .session_ref = first.slice() }, &heads[0]);
            a.read(TestingRound.head, .{ .session_ref = second.slice() }, &heads[1]);
            try a.run();
            a.write(TestingRound.date_session, .{ .session = heads[0].head, .revision = 1 });
            try a.run();
            const dated = try store_core.transactionSecond(&storage);
            // The clock moves on to a later second before the next round dates.
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(3)), dated, Clock.passed);
            a.write(TestingRound.date_session, .{ .session = heads[1].head, .revision = 1 });
            try a.commit();
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT created_at) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, @intCast(dated)), try store_testing.queryU64(&storage, "SELECT max(created_at) FROM session", .{}));
            // Commit cleared it: the next transaction reads the clock again.
            try store_core.begin(&storage);
            try std.testing.expect(try store_core.transactionSecond(&storage) > dated);
            try store_core.rollbackAfterError(&storage, .{});
        }
    }.run);
}

test "an Access commits its writes, positions and identities together, or none of them" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "round-config");
            const next_sql = "SELECT next_position FROM session";
            const position = try store_testing.queryU64(&storage, next_sql, .{});
            const contents = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const content_id = storage.identities().next.get(.content_id);

            // A failed guard stops the round before COMMIT: no row, position or id stays.
            try std.testing.expectError(error.TestingGuard, TestingRound.change(&storage, session.slice(), "round rolled back", 99));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(position, try store_testing.queryU64(&storage, next_sql, .{}));
            try std.testing.expectEqual(contents, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(content_id, storage.identities().next.get(.content_id));

            const before = @divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000);
            try std.testing.expectEqual(position, try TestingRound.change(&storage, session.slice(), "round committed", 1));
            const after = @divFloor(try store_core.readUnixMilliseconds(std.testing.io), 1000);
            try std.testing.expectEqual(position + 2, try store_testing.queryU64(&storage, next_sql, .{}));
            try std.testing.expectEqual(content_id, try store_testing.queryU64(&storage, "SELECT content_id FROM content WHERE byte_length=15 AND private=0 AND digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest("round committed") }}));
            const dated: i64 = @intCast(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}));
            try std.testing.expect(before <= dated and dated <= after);
        }
    }.run);
}

const counted_dating = rsql.Write(.{
    .sql = "UPDATE session SET created_at=?2 WHERE session_ref=@session(?1) AND revision=?3",
    .Args = struct { session: rsql.SessionHead, at: u64, revision: u64 },
    .expect = .{ .counted = .{ .otherwise = error.TestingGuard } },
});

/// Dates `session` at `at` where its revision is `revision`, stating
/// `rows` as the rows that write changes.
fn countedDatingForTesting(storage: *Store, session: []const u8, at: u64, revision: u64, rows: u64) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var a: store_access.Access(.write, error{TestingGuard}) = .open(&entry);
    defer a.deinit();
    return entry.finishTransaction(error{TestingGuard}, .{}, a.end(.{}, struct {
        fn body(access: anytype, ref: []const u8, value: u64, current: u64, count: u64) !void {
            var loaded: TestingRound.head.Result = undefined;
            access.read(TestingRound.head, .{ .session_ref = ref }, &loaded);
            try access.run();
            access.writeCount(counted_dating, .{ .session = loaded.head, .at = value, .revision = current }, count);
            try access.commit();
        }
    }.body(&a, session, at, revision, rows)));
}

test "a counted write commits only when it changes the rows its caller states" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "counted-config");
            const dated = "SELECT created_at FROM session";
            const created = try store_testing.queryU64(&storage, dated, .{});
            // One row changes: stating none or two fails before COMMIT.
            for ([_]u64{ 0, 2 }) |rows| {
                try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 7, 1, rows));
                try std.testing.expectEqual(created, try store_testing.queryU64(&storage, dated, .{}));
            }
            try std.testing.expect(!storage.isFenced());
            try countedDatingForTesting(&storage, session.slice(), 7, 1, 1);
            try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
            // No row changes: zero is checked like any count.
            try std.testing.expectError(error.TestingGuard, countedDatingForTesting(&storage, session.slice(), 8, 2, 1));
            try countedDatingForTesting(&storage, session.slice(), 8, 2, 0);
            try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, dated, .{}));
        }
    }.run);
}

test "the touch oracle names a Session whose rows changed without a touch" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            var command = try completeConfiguration("oracle", "", root[0..try tmp.dir.realPath(std.testing.io, &root)], "model");
            const configured = storage.configure(&command, .{});
            const session = configured.accepted.session.slice();
            const generation = storage.commit_generation.load(.acquire);
            {
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
                // A writer that forgets its touch.
                try store_testing.exec(&storage, "UPDATE session SET label='forgot' WHERE session_ref=?1", .{session});
                try std.testing.expectEqualStrings(session, &store_core.untouchedForTesting(&storage).?);
                try touchForTesting(&storage, session);
                try std.testing.expect(store_core.untouchedForTesting(&storage) == null);
            }
            // The touched write is recorded under the generation it advanced to.
            try std.testing.expectEqual(generation + 1, storage.commit_generation.load(.acquire));
            var out: [1]change_ring.Id = undefined;
            try std.testing.expectEqualStrings(session, &storage.changes.changed(generation, generation + 1, null, null, &out)[0]);
        }
    }.run);
}

test "Session list capture and cursor storage stay page bounded as dormant Sessions grow" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var used = std.atomic.Value(u64).init(0);
            var first_length: usize = 0;
            for (0..1000) |i| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "dormant-key-{d}", .{i});
                var config = try completeConfiguration(key, "", workspace, "model");
                try std.testing.expect(storage.configure(&config, .{}) == .accepted);
                if (i == 99 or i == 999) {
                    const bytes = try testingSessionList(&storage, &tmp, .{}, &used, i + 1);
                    defer std.testing.allocator.free(bytes);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer parsed.deinit();
                    try std.testing.expectEqual(@as(usize, protocol.session_list_page_size), parsed.value.object.get("sessions").?.array.items.len);
                    // Only the ceiling and the token's generation gain a digit.
                    if (i == 99) first_length = bytes.len else try std.testing.expect(bytes.len <= first_length + 2);
                    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
                }
            }
        }
    }.run);
}

/// One Session's listed row, from one unfiltered page.
pub const TestingListRow = struct {
    parsed: std.json.Parsed(std.json.Value),
    row: std.json.Value,

    pub fn deinit(self: *TestingListRow) void {
        self.parsed.deinit();
    }

    pub fn get(self: *const TestingListRow, path: []const []const u8) std.json.Value {
        var value = self.row;
        for (path) |name| value = value.object.get(name).?;
        return value;
    }

    pub fn number(self: *const TestingListRow, path: []const []const u8) !u64 {
        return std.fmt.parseInt(u64, self.get(path).string, 10);
    }
};

pub fn testingListRow(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !TestingListRow {
    var used = std.atomic.Value(u64).init(0);
    const bytes = try testingSessionList(storage, tmp, .{}, &used, 77);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    for (parsed.value.object.get("sessions").?.array.items) |row| {
        if (std.mem.eql(u8, row.object.get("reference").?.string, session)) return .{ .parsed = parsed, .row = row };
    }
    return error.TestUnexpectedResult;
}

test "a list row carries its Session's Label, times, first Message, work and peers" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("row-create", "", workspace, "model-a");
            create.configuration.label.state = .value;
            try create.configuration.label.value.set("Review PR 412");
            const session = storage.configure(&create, .{}).accepted.session;
            const created_at = try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{});
            {
                // Configured, never messaged: idle since its creation.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expect(listed.get(&.{"parent"}) == .null);
                try std.testing.expectEqualStrings("Review PR 412", listed.get(&.{"label"}).string);
                try std.testing.expectEqual(created_at, try listed.number(&.{"created_at"}));
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{"revision"}));
                try std.testing.expectEqual(@as(u64, 0), try listed.number(&.{"end"}));
                try std.testing.expect(listed.get(&.{"first_message"}) == .null);
                try std.testing.expectEqualStrings("idle", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(created_at, try listed.number(&.{ "work", "state", "since" }));
                try std.testing.expect(listed.get(&.{ "peers", "from_person_at" }) == .null);
            }
            try submitTestMessage(&storage, &tmp, "row-first", "row-first", session.slice(), "hello");
            // Distinct times show which Message each fact names.
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=1000", .{});
            {
                // Queued: the first Message is unbound, and a person sent it.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{"end"}));
                try std.testing.expectEqual(@as(u64, 1), try listed.number(&.{ "first_message", "position" }));
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
                try std.testing.expect(listed.get(&.{ "first_message", "sender" }) == .null);
                try std.testing.expectEqualStrings("5", listed.get(&.{ "first_message", "content", "bytes" }).string);
                const digest = std.fmt.bytesToHex(protocol.contentDigest("hello"), .lower);
                try std.testing.expectEqualStrings(&digest, listed.get(&.{ "first_message", "content", "sha256" }).string);
                try std.testing.expectEqualStrings("pending", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "peers", "from_person_at" }));
            }
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try submitTestMessage(&storage, &tmp, "row-second", "row-second", session.slice(), "and then");
            const newest_admission = try store_testing.queryU64(&storage, "SELECT max(admission_id) FROM message_admission", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=2000 WHERE admission_id=?1", .{newest_admission});
            {
                // The first Message is now its Turn's; the latest person's Message is
                // the queued second one.
                var listed = try testingListRow(&storage, &tmp, session.slice());
                defer listed.deinit();
                try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
                try std.testing.expectEqualStrings("working", listed.get(&.{ "work", "state", "kind" }).string);
                try std.testing.expect(listed.get(&.{ "work", "turn" }) != .null and listed.get(&.{ "work", "operation" }) != .null);
                try std.testing.expectEqual(@as(u64, 2000), try listed.number(&.{ "peers", "from_person_at" }));
                try std.testing.expectEqual(try listed.number(&.{"end"}), try store_testing.queryU64(&storage, "SELECT next_position-1 FROM session", .{}));
            }
            // Current reports the same creation time and peer fact.
            const current = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(current);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
            defer report.deinit();
            try std.testing.expectEqual(created_at, try std.fmt.parseInt(u64, report.value.object.get("session").?.object.get("created_at").?.string, 10));
            try std.testing.expectEqualStrings("2000", report.value.object.get("peers").?.object.get("from_person_at").?.string);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a page lists only the kinds it asks for, up to its limit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "kinds-config");
            for ([_][]const u8{ "one", "two", "three" }) |text| try submitTestMessage(&storage, &tmp, text, text, session.slice(), text);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const all = try store_core.activityPageForTesting(&storage, request);
            // Three admissions, and a User row for each the attempt took.
            var user_rows: usize = 0;
            for (all.items[0..all.count]) |item| user_rows += @intFromBool(item.value == .user);
            try std.testing.expect(user_rows > 0 and all.count == 3 + user_rows and !all.more);
            request.kinds = .initOne(.user);
            const users = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(users.count == user_rows and !users.more);
            for (users.items[0..users.count]) |item| try std.testing.expect(item.value == .user);
            request.kinds = .initMany(&.{ .admission, .user });
            request.limit = 2;
            const two = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(two.count == 2 and two.more);
            try std.testing.expectEqual(all.items[0].position, two.items[0].position);
            try std.testing.expectEqual(all.items[1].position, two.items[1].position);
            request.limit = 0;
            try std.testing.expectError(error.InvalidCursor, store_core.activityPageForTesting(&storage, request));
            request.limit = 1;
            request.kinds = .empty;
            try std.testing.expectError(error.InvalidCursor, store_core.activityPageForTesting(&storage, request));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "Current excludes history while Full exposes exact closed Session inventory" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "profile-config");

            const current = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(current);
            try std.testing.expect(std.mem.indexOf(u8, current, "\"profile\":\"current\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, current, "\"full\"") == null);

            const text = try std.testing.allocator.alloc(u8, 64 * 1024);
            defer std.testing.allocator.free(text);
            @memset(text, 1);
            try submitTestMessage(&storage, &tmp, "profile-message", "profile-message", session.slice(), text);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            // One worst-case escaped copy fits; duplicating it in Conversation would not.
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 512 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("full", parsed.value.object.get("profile").?.string);
            const inventory = parsed.value.object.get("full").?.object;
            inline for (.{ "session_revisions", "messages", "conversation", "turns", "model_operations", "tool_calls", "actions", "permission_decisions", "session_stops", "model_interruptions", "tool_results" }) |name| {
                try std.testing.expect(inventory.get(name) != null);
            }
            try std.testing.expectEqualStrings(text, inventory.get("messages").?.array.items[0].object.get("content").?.object.get("text").?.string);
            const conversation_content = inventory.get("conversation").?.array.items[0].object.get("content").?.object;
            try std.testing.expectEqualStrings("65536", conversation_content.get("bytes").?.string);
            const digest = protocol.contentDigest(text);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), conversation_content.get("sha256").?.string);
            try std.testing.expect(conversation_content.get("text") == null);
        }
    }.run);
}

test "Current preserves empty Message identity across queue, active Turn and history" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "empty-key-config");
            try submitTestMessage(&storage, &tmp, "empty-key-file", "", session.slice(), "input");
            try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, (try storage.observeCommand("")).message.?.progress.?.status);
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("", report.value.object.get("selected_message").?.string);
            }
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try storage.observeCommand("")).message.?.progress.?.status);
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("", report.value.object.get("selected_message").?.string);
            }
            try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            try std.testing.expect((try storage.observeCommand("")).message.?.progress == null);
            try submitTestMessage(&storage, &tmp, "after-empty-file", "after-empty", session.slice(), "next");
            {
                const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
                defer std.testing.allocator.free(bytes);
                var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                defer report.deinit();
                try std.testing.expectEqualStrings("after-empty", report.value.object.get("selected_message").?.string);
                try std.testing.expectEqualStrings("", report.value.object.get("recent_messages").?.array.items[0].object.get("message").?.string);
            }
        }
    }.run);
}

test "Full preserves rejected model interruption targets as canonical u64 text" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "interrupt-report-config");

            const targets = [_]struct { key: []const u8, turn: u64, operation: u64 }{
                .{ .key = "zero-turn", .turn = 0, .operation = 1 },
                .{ .key = "zero-operation", .turn = 1, .operation = 0 },
                .{ .key = "wide-targets", .turn = @as(u64, std.math.maxInt(i64)) + 1, .operation = std.math.maxInt(u64) },
            };
            for (targets) |target| {
                var command: protocol.ModelInterruptionCommand = .{ .turn_id = target.turn, .operation_id = target.operation };
                try command.key.set(target.key);
                try command.session.set(session.slice());
                const rejected = storage.interruptModel(&command, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.ModelInterruptionRejection.invalid_target, rejected.rejected.code);
                const replay = storage.interruptModel(&command, .{});
                try std.testing.expect(replay == .rejected);
                try std.testing.expect(replay.rejected.replayed);
            }

            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const interruptions = parsed.value.object.get("full").?.object.get("model_interruptions").?.array.items;
            try std.testing.expectEqual(targets.len, interruptions.len);
            for (targets, interruptions) |target, interruption| {
                const object = interruption.object;
                try std.testing.expectEqualStrings(target.key, object.get("command_key").?.string);
                try std.testing.expectEqualStrings("rejected", object.get("status").?.string);
                try std.testing.expectEqualStrings("invalid_target", object.get("code").?.string);
                var expected_turn: [20]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_turn, "{d}", .{target.turn}), object.get("turn").?.string);
                var expected_operation: [20]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_operation, "{d}", .{target.operation}), object.get("operation").?.string);
            }
            try std.testing.expect(!storage.isFenced());
            try std.testing.expect((try storage.inspectSessionForTesting(session.slice())).found);
        }
    }.run);
}

test "a configure whose instructions and output schema are the same new bytes imports one row and verifies both files" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const rows = store_testing.content_beside_tools;

            const create_bytes = "{\"title\":\"same-create\"}";
            var create = try completeConfiguration("same-create", "", workspace, "model-a");
            create.configuration.instructions = try testingBytesContent(&tmp, "same-create-instructions", create_bytes);
            create.configuration.output_schema = try testingBytesContent(&tmp, "same-create-schema", create_bytes);
            defer create.removeTemporaryContent(std.testing.io) catch unreachable;
            const before_create = try store_testing.queryU64(&storage, rows, .{});
            const created = storage.configure(&create, .{});
            try std.testing.expect(created == .accepted);
            try std.testing.expectEqual(before_create + 1, try store_testing.queryU64(&storage, rows, .{}));
            const session = created.accepted.session;
            const after_create = (try store_core.readSessionForTesting(&storage, session.slice())).?;
            try std.testing.expectEqual(after_create.instructions_id.?, after_create.output_schema_id.?);

            const update_bytes = "{\"title\":\"same-update\"}";
            var update = try completeConfiguration("same-update", session.slice(), workspace, "model-a");
            update.configuration.instructions = try testingBytesContent(&tmp, "same-update-instructions", update_bytes);
            update.configuration.output_schema = try testingBytesContent(&tmp, "same-update-schema", update_bytes);
            defer update.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(before_create + 2, try store_testing.queryU64(&storage, rows, .{}));
            const after_update = (try store_core.readSessionForTesting(&storage, session.slice())).?;
            try std.testing.expectEqual(after_update.instructions_id.?, after_update.output_schema_id.?);
            try std.testing.expect(after_update.instructions_id.? != after_create.instructions_id.?);

            // The schema's file claims the instructions' identity but holds other
            // bytes of the same length: sharing the row still verifies its file.
            const claimed = "{\"title\":\"same-claim\"}";
            var forged = try completeConfiguration("same-forged", session.slice(), workspace, "model-a");
            forged.configuration.instructions = try testingBytesContent(&tmp, "same-forged-instructions", claimed);
            forged.configuration.output_schema = try testingBytesContent(&tmp, "same-forged-schema", "{\"title\":\"same-other\"}");
            forged.configuration.output_schema.digest = forged.configuration.instructions.digest;
            defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&forged, .{}) != .accepted);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key='same-forged'", .{}));
            try std.testing.expectEqual(before_create + 2, try store_testing.queryU64(&storage, rows, .{}));
        }
    }.run);
}

test "Full revisions own repeated content once and render semantic settings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("revision-owner-1", "", workspace, "model-a");
            initial.configuration.tools.state = .value;
            initial.configuration.tools = try .of(&.{"bash"});
            initial.configuration.permission_mode.state = .value;
            try initial.configuration.permission_mode.value.set("ask");
            initial.configuration.instructions = try testingContent(&tmp, "revision-owner-instructions", 1, 64 * 1024);
            const schema_a = "{}";
            initial.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a", schema_a);
            defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            var second: protocol.ConfigureCommand = .{};
            try second.key.set("revision-owner-2");
            try second.session.set(created_session_0.slice());
            second.configuration.tools.state = .value;
            second.configuration.tools.count = 0;
            second.configuration.permission_mode.state = .value;
            try second.configuration.permission_mode.value.set("bypass");
            const schema_b = "{\"type\":\"object\"}";
            second.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-b", schema_b);
            defer second.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&second, .{}) == .accepted);

            var third: protocol.ConfigureCommand = .{};
            try third.key.set("revision-owner-3");
            try third.session.set(created_session_0.slice());
            third.configuration.tools.state = .value;
            third.configuration.tools = try .of(&.{"bash"});
            third.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a-again", schema_a);
            defer third.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&third, .{}) == .accepted);

            var fourth: protocol.ConfigureCommand = .{};
            try fourth.key.set("revision-owner-4");
            try fourth.session.set(created_session_0.slice());
            fourth.configuration.tools.state = .value;
            fourth.configuration.tools.count = 0;
            try std.testing.expect(storage.configure(&fourth, .{}) == .accepted);

            var fifth: protocol.ConfigureCommand = .{};
            try fifth.key.set("revision-owner-5");
            try fifth.session.set(created_session_0.slice());
            fifth.configuration.instructions = try testingBytesContent(&tmp, "revision-owner-instructions-schema-a", schema_a);
            defer fifth.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&fifth, .{}) == .accepted);

            const full = try testingSessionReportWithProfile(&storage, &tmp, created_session_0.slice(), 512 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const revisions = parsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
            try std.testing.expectEqual(@as(usize, 5), revisions.len);

            const first = revisions[0].object;
            const first_instructions = first.get("instructions").?.object;
            try std.testing.expectEqual(@as(usize, 64 * 1024), first_instructions.get("text").?.string.len);
            for (first_instructions.get("text").?.string) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
            try std.testing.expectEqualStrings(schema_a, first.get("output_schema").?.object.get("text").?.string);

            for (revisions[1..4]) |revision| {
                const owner = revision.object.get("instructions").?.object.get("owner").?.object;
                try std.testing.expectEqualStrings("1", owner.get("revision").?.string);
                try std.testing.expectEqualStrings("instructions", owner.get("field").?.string);
                try std.testing.expect(revision.object.get("tools_mask") == null);
                try std.testing.expectEqualStrings("bypass", revision.object.get("permission_mode").?.string);
            }
            const fifth_instruction_owner = revisions[4].object.get("instructions").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", fifth_instruction_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", fifth_instruction_owner.get("field").?.string);
            const third_schema_owner = revisions[2].object.get("output_schema").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", third_schema_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", third_schema_owner.get("field").?.string);
            const fourth_schema_owner = revisions[3].object.get("output_schema").?.object.get("owner").?.object;
            try std.testing.expectEqualStrings("1", fourth_schema_owner.get("revision").?.string);
            try std.testing.expectEqualStrings("output_schema", fourth_schema_owner.get("field").?.string);

            const expected_tools = [_][]const []const u8{
                &.{"bash"},
                &.{},
                &.{"bash"},
                &.{},
                &.{},
            };
            for (revisions, expected_tools) |revision, expected| {
                const tools = revision.object.get("tools").?.array.items;
                try std.testing.expectEqual(expected.len, tools.len);
                for (tools, expected) |actual, name| try std.testing.expectEqualStrings(name, actual.string);
            }
        }
    }.run);
}

test "Full attributes unbound Messages to the earliest covering stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "stop-merge-config");

            try submitTestMessage(&storage, &tmp, "stop-merge-message-1-file", "stop-merge-message-1", session.slice(), "one");
            var first_stop = try completeSessionStop("z-first-stop", session.slice());
            try std.testing.expect(storage.stopSession(&first_stop, .{}) == .accepted);
            var same_cutoff_stop = try completeSessionStop("a-second-stop", session.slice());
            try std.testing.expect(storage.stopSession(&same_cutoff_stop, .{}) == .accepted);

            try submitTestMessage(&storage, &tmp, "stop-merge-message-2-file", "stop-merge-message-2", session.slice(), "two");
            var later_stop = try completeSessionStop("m-third-stop", session.slice());
            try std.testing.expect(storage.stopSession(&later_stop, .{}) == .accepted);

            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
            defer parsed.deinit();
            const messages = parsed.value.object.get("full").?.object.get("messages").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), messages.len);
            try std.testing.expectEqualStrings("z-first-stop", messages[0].object.get("exclusion").?.object.get("command_key").?.string);
            try std.testing.expectEqualStrings("m-third-stop", messages[1].object.get("exclusion").?.object.get("command_key").?.string);
            const first_observation = (try storage.observeCommand("stop-merge-message-1")).message.?.queue.?.state.excluded;
            const second_observation = (try storage.observeCommand("stop-merge-message-2")).message.?.queue.?.state.excluded;
            try std.testing.expectEqualStrings("session_stopped", first_observation.code.slice());
            try std.testing.expectEqualStrings("session_stopped", second_observation.code.slice());
        }
    }.run);
}

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
            try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
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

            var update: protocol.ConfigureCommand = .{};
            try update.key.set("allow-mode-change");
            try update.session.set(session.slice());
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
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
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            try std.testing.expectEqual(action_id, action.action_id);
            try std.testing.expect(storage.decidePermission(&allow, .{}).accepted.replayed);
            // The admitted Action cannot be reissued; its unapproved sibling remains pending.
            try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
        }
    }.run);
}

test "Current, activity pages and Message progress report one work through an approval" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "mixed-config");
            try submitTestMessage(&storage, &tmp, "mixed-file", "mixed-message", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "mixed-metadata");
            const before = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(before);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, before, .{});
            defer parsed.deinit();
            const first = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items[0];
            const action_id = try std.fmt.parseInt(u64, first.object.get("action").?.string, 10);
            try std.testing.expectEqualStrings("approval", parsed.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try pageWorkAgrees(&storage, parsed.value, action_id);
            try std.testing.expectEqual(protocol.MessageProgressStatus.waiting_for_permission, (try storage.observeCommand("mixed-message")).message.?.progress.?.status);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("mixed-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);

            // Approved Bash awaiting a slot can progress: the work is pending and
            // the Message runnable, though a sibling still awaits permission.
            const after = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(after);
            var mixed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after, .{});
            defer mixed.deinit();
            try std.testing.expectEqualStrings("pending", mixed.value.object.get("work").?.object.get("state").?.object.get("kind").?.string);
            try std.testing.expectEqual(@as(usize, 1), mixed.value.object.get("actionable_permissions").?.array.items.len);
            var message = (try storage.observeCommand("mixed-message")).message.?;
            try std.testing.expectEqualStrings("processing", @tagName(message.queue.?.state));
            try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, message.progress.?.status);
            try std.testing.expectEqual(action_id + 1, message.progress.?.action_id.?);
            try pageWorkAgrees(&storage, mixed.value, action_id + 1);

            // Once it runs, the Session is in Bash with one approval outstanding.
            _ = (try storage.admitNextActionAttempt(300_000, .{})).?;
            const running = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(running);
            var bash = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, running, .{});
            defer bash.deinit();
            const state = bash.value.object.get("work").?.object.get("state").?.object;
            try std.testing.expectEqualStrings("bash", state.get("kind").?.string);
            try std.testing.expectEqualStrings("1", state.get("running").?.string);
            try std.testing.expectEqualStrings("1", state.get("approvals").?.string);
            message = (try storage.observeCommand("mixed-message")).message.?;
            try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, message.progress.?.status);
            try pageWorkAgrees(&storage, bash.value, action_id + 1);
        }
    }.run);
}

/// The activity page carries the work Current reports and the first
/// actionable Action, from its own read.
fn pageWorkAgrees(store: *Store, report: std.json.Value, first_action: u64) !void {
    var request: protocol.ActivityPage = .{};
    try request.session.set(report.object.get("session").?.object.get("reference").?.string);
    const page = try store_core.activityPageForTesting(store, request);
    const work = report.object.get("work").?.object;
    var state: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&state);
    try std.json.Stringify.value(work.get("state").?, .{}, &writer);
    var page_state: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var page_writer: std.Io.Writer = .fixed(&page_state);
    try (protocol.WorkStateJson{ .state = page.work.work.state }).writeJson(&page_writer);
    try std.testing.expectEqualStrings(writer.buffered(), page_writer.buffered());
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("turn").?.string, 10), page.work.work.turn.?);
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("operation").?.string, 10), page.work.work.operation.?);
    try std.testing.expectEqual(first_action, page.work.work.first_action.?);
    const session = report.object.get("session").?.object;
    try std.testing.expectEqual(try std.fmt.parseInt(u64, session.get("revision").?.string, 10), page.work.revision);
    try std.testing.expectEqualStrings(session.get("workspace").?.string, page.work.workspace.slice());
}

/// Current and an activity page report the same work, and its kind is
/// `kind`. Returns the state's `since`.
pub fn expectOneWork(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, kind: []const u8) !u64 {
    const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const work = report.value.object.get("work").?.object;
    const state = work.get("state").?.object;
    try std.testing.expectEqualStrings(kind, state.get("kind").?.string);
    var current: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var current_writer: std.Io.Writer = .fixed(&current);
    try std.json.Stringify.value(work.get("state").?, .{}, &current_writer);

    var request: protocol.ActivityPage = .{};
    try request.session.set(session);
    const page = try store_core.activityPageForTesting(storage, request);
    var paged: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
    var paged_writer: std.Io.Writer = .fixed(&paged);
    try (protocol.WorkStateJson{ .state = page.work.work.state }).writeJson(&paged_writer);
    try std.testing.expectEqualStrings(current_writer.buffered(), paged_writer.buffered());
    inline for (.{ "turn", "operation", "first_action" }) |name| {
        const value = work.get(name).?;
        const expected: ?u64 = if (value == .null) null else try std.fmt.parseInt(u64, value.string, 10);
        try std.testing.expectEqual(expected, @field(page.work.work, name));
    }
    return page.work.work.state.since();
}

fn expectProgress(storage: *Store, key: []const u8, status: protocol.MessageProgressStatus) !void {
    const message = (try storage.observeCommand(key)).message.?;
    try std.testing.expectEqual(status, message.progress.?.status);
}

test "Current, activity pages and Message progress report one work in each state" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            // A configure-only Session is idle since its creation.
            const session = try configureTestSession(&storage, "one-work-config");
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT created_at FROM session", .{}), try expectOneWork(&storage, &tmp, session.slice(), "idle"));

            // Queued, then admitted.
            try submitTestMessage(&storage, &tmp, "one-work-file", "one-work-message", session.slice(), "first");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT attempt_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "working"));
            try expectProgress(&storage, "one-work-message", .in_flight);

            // A retry due later is in flight; once due it is runnable, though
            // nothing committed in between.
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT retry_scheduled_at FROM model_operation", .{}), try expectOneWork(&storage, &tmp, session.slice(), "retrying"));
            try expectProgress(&storage, "one-work-message", .in_flight);
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            try expectProgress(&storage, "one-work-message", .runnable);

            // A quota failure carries its saved reset time.
            const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
            var diagnostic: [512]u8 = undefined;
            const quota: @import("../transport_policy.zig").Quota = .{ .refusal = .quota, .resets_at = 1792940000 };
            try storage.settleModelAttemptFailure(retry, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT outcome_at FROM turn", .{}), try expectOneWork(&storage, &tmp, session.slice(), "failed"));
            {
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const failed = (try store_core.activityPageForTesting(&storage, request)).work.work.state.failed;
                try std.testing.expectEqualStrings("provider_quota", failed.code.slice());
                try std.testing.expectEqual(@as(?u64, 1792940000), failed.resets_at);
            }

            // A completed Turn is finished.
            const done = try configureTestSession(&storage, "one-work-done");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, done.slice(), "one-work-answer", &answer);
            _ = try expectOneWork(&storage, &tmp, done.slice(), "finished");

            // A stop selecting a Turn whose Bash runs is stopping until the Attempt
            // settles; the Turn then ends stopped by the stop.
            const bash = try configureTestSessionAsk(&storage, "one-work-bash");
            try submitTestMessage(&storage, &tmp, "one-work-bash-file", "one-work-bash-message", bash.slice(), "propose");
            const proposing = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, proposing, "one-work-bash-metadata");
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "approval");
            try expectProgress(&storage, "one-work-bash-message", .waiting_for_permission);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&storage, "SELECT min(action_id) FROM action_operation", .{}), .decision = .allow_once };
            try allow.key.set("one-work-allow");
            try allow.session.set(bash.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "bash");
            try expectProgress(&storage, "one-work-bash-message", .in_flight);
            var stop = try completeSessionStop("one-work-stop", bash.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT stopped_at FROM session_stop", .{}), try expectOneWork(&storage, &tmp, bash.slice(), "stopping"));
            try expectProgress(&storage, "one-work-bash-message", .in_flight);
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            _ = try expectOneWork(&storage, &tmp, bash.slice(), "stopped");
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a stop that selected no Turn decides work only through the input it excluded" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "no-turn-stop-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "no-turn-stop-answer", &answer);

            // A stop with nothing to stop leaves the Session finished.
            var idle_stop = try completeSessionStop("no-turn-stop-idle", session.slice());
            try std.testing.expect(storage.stopSession(&idle_stop, .{}) == .accepted);
            _ = try expectOneWork(&storage, &tmp, session.slice(), "finished");

            // A stop that excluded queued input stops the Session from that stop,
            // and later no-op stops change nothing.
            try submitTestMessage(&storage, &tmp, "no-turn-stop-file", "no-turn-stop-queued", session.slice(), "queued");
            var effective = try completeSessionStop("no-turn-stop-effective", session.slice());
            try std.testing.expect(storage.stopSession(&effective, .{}) == .accepted);
            const stopped_at = try store_testing.queryU64(&storage, "SELECT stopped_at FROM session_stop WHERE command_key='no-turn-stop-effective'", .{});
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));
            var later = try completeSessionStop("no-turn-stop-later", session.slice());
            try std.testing.expect(storage.stopSession(&later, .{}) == .accepted);
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));

            // New input after the stop starts a Turn whose state is the Session's.
            try submitTestMessage(&storage, &tmp, "no-turn-stop-next-file", "no-turn-stop-next", session.slice(), "next");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            _ = try expectOneWork(&storage, &tmp, session.slice(), "working");
        }
    }.run);
}

test "a quota reset is read from a saved record and never fences" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            for ([_]struct { code: []const u8, diagnostic: ?[]const u8, resets_at: ?u64 }{
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":null}", .resets_at = null },
                .{ .code = "provider_plan", .diagnostic = "{\"refusal\":\"plan\",\"resets_at\":42}", .resets_at = 42 },
                // A missing, corrupt or mismatched record gives no time.
                .{ .code = "provider_quota", .diagnostic = null, .resets_at = null },
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":4x}", .resets_at = null },
                .{ .code = "provider_quota", .diagnostic = "{\"refusal\":\"plan\",\"resets_at\":42}", .resets_at = null },
                // Only a quota code reads one.
                .{ .code = "provider_http_403", .diagnostic = "{\"refusal\":\"quota\",\"resets_at\":42}", .resets_at = null },
            }, 0..) |case, index| {
                var key_buffer: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "quota-{d}", .{index});
                var message_buffer: [32]u8 = undefined;
                const message = try std.fmt.bufPrint(&message_buffer, "quota-message-{d}", .{index});
                const session = try configureTestSession(&storage, key);
                try submitTestMessage(&storage, &tmp, message, message, session.slice(), "q");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const failure: ModelFailure = if (case.diagnostic) |detail| .{ .rejected = .{ .code = case.code, .diagnostic = detail, .request_id = .{}, .report = "" } } else .{ .uncorrelated = case.code };
                try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const failed = (try store_core.activityPageForTesting(&storage, request)).work.work.state.failed;
                try std.testing.expectEqualStrings(case.code, failed.code.slice());
                try std.testing.expectEqual(case.resets_at, failed.resets_at);
            }
            try std.testing.expect(!storage.isFenced());
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
            const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;

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
                (try storage.observeCommand("settlement-first-later")).message.?.queue.?.state == .queued,
            );
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'", .{allocated_session_0.slice()}));
        }
    }.run);
}

test "Full reports every closed Action resolution without fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSessionAsk(&storage, "shutdown-report-config");
            try submitTestMessage(&storage, &tmp, "shutdown-report-message", "shutdown-report-message", session.slice(), "execute");
            const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{
                .item_id = "shutdown-report-item",
                .name = "bash",
                .encoded_call_id = "shutdown-report-call",
                .decoded_call_id = "shutdown-report-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":1234}",
                .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":1234}",
            }};
            try settleCallsForTesting(&storage, &tmp, model_binding, "shutdown-report-metadata", &calls);
            const action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{});
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
            try allow.key.set("shutdown-report-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: BashExecutionInput = undefined;
            try storage.readBashExecutionInput(action_binding, &input);
            try std.testing.expectEqual(@as(u64, 1234), input.timeout_ms);
            try std.testing.expectEqual(
                ActionSettlement.effect,
                try storage.settleActionAttempt(action_binding, .infrastructure_shutdown, "Host shutdown.", .{}),
            );

            const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report_bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
            defer report.deinit();
            const actions = report.value.object.get("full").?.object.get("actions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), actions.len);
            try std.testing.expectEqualStrings("infrastructure_shutdown", actions[0].object.get("resolution").?.string);
            try std.testing.expectEqualStrings("Host shutdown.", actions[0].object.get("result").?.object.get("text").?.string);
            try std.testing.expect(!storage.isFenced());
            _ = try storage.inspectSessionForTesting(session.slice());
        }
    }.run);
}

test "report scratch exhaustion is an observation failure without Store fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-config");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ReportScratchExhausted, storage.captureSessionReport(session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            }));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expect((try storage.inspectSessionForTesting(session.slice())).found);
        }
    }.run);
}

test "report unlink failure retains a startup-owned zero-request file" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-unlink-config");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ReportScratchCleanupFailed, storage.captureSessionReport(session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 0,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
                .fail_unlink = true,
            }));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expectEqual(std.Io.File.Kind.file, (try tmp.dir.statFile(std.testing.io, "report-0-1.tmp", .{})).kind);
            try tmp.dir.deleteFile(std.testing.io, "report-0-1.tmp");
        }
    }.run);
}

test "the Store prepares only typed statements, its transaction control and test fixtures" {
    // Open text cannot reach SQLite beside `rsql`: the one prepare is
    // `cachedStatic`, called only by these three, and `cachedTyped` takes
    // only a type `rsql.Read` or `rsql.Write` made (`rsql.isStatement`).
    const source = @embedFile("engine/Sqlite.zig");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "sqlite3_" ++ "prepare"));
    const callers = [_][]const u8{ "controlStatement", "cachedTyped", "fixtureStatement" };
    var calls = std.mem.splitSequence(u8, source, "cachedStatic" ++ "(self, ");
    var before = calls.first();
    var found: usize = 0;
    while (calls.next()) |rest| : (found += 1) {
        const name_start = std.mem.lastIndexOf(u8, before, "fn ").? + 3;
        const name = before[name_start .. name_start + std.mem.indexOfScalar(u8, before[name_start..], '(').?];
        var allowed = false;
        for (callers) |caller| allowed = allowed or std.mem.eql(u8, name, caller);
        if (!allowed) std.debug.print("cachedStatic called from {s}\n", .{name});
        try std.testing.expect(allowed);
        before = rest;
    }
    try std.testing.expectEqual(callers.len, found);
    // Opening's own text: engine settings, and one sweep held to
    // `rsql.portabilityError`.
    var execs = std.mem.splitSequence(u8, source, "sqlite.exec" ++ "(database.?, ");
    _ = execs.first();
    while (execs.next()) |rest| {
        const allowed = std.mem.startsWith(u8, rest, "\"PRAGMA ") or std.mem.startsWith(u8, rest, "cache_size") or
            std.mem.startsWith(u8, rest, "if (options.cache_spill) \"PRAGMA ") or std.mem.startsWith(u8, rest, "comptime portable(");
        try std.testing.expect(allowed);
    }
}

test "Store entry points queue and fence only through canonical access" {
    // Every entry point classifies its errors through `Entry`; a new path
    // cannot take a lock beside the Store's queue, read or set the fence
    // beside it, or enter without returning through a classifier.
    const sources = .{
        @embedFile("Store.zig"),
        @embedFile("access.zig"),
        @embedFile("engine.zig"),
        @embedFile("engine/Sqlite.zig"),
        @embedFile("engine/Mysql.zig"),
        @embedFile("engine/mysql_content.zig"),
        @embedFile("engine/mysql_open.zig"),
        @embedFile("engine/mysql_refusal.zig"),
        @embedFile("domain/action.zig"),
        @embedFile("domain/forward.zig"),
        @embedFile("domain/command.zig"),
        @embedFile("domain/configuration.zig"),
        @embedFile("domain/content.zig"),
        @embedFile("domain/find_tools.zig"),
        @embedFile("domain/historical.zig"),
        @embedFile("domain/history_floor.zig"),
        @embedFile("domain/model_admission.zig"),
        @embedFile("domain/model_facts.zig"),
        @embedFile("domain/model_settlement.zig"),
        @embedFile("domain/reads.zig"),
        @embedFile("domain/report.zig"),
        @embedFile("domain/report_full_shape.zig"),
        @embedFile("domain/tool_set.zig"),
        @embedFile("domain/turn.zig"),
        @embedFile("find_tools_tests.zig"),
        @embedFile("mysql_literal.zig"),
        @embedFile("mysql_row.zig"),
        @embedFile("rsql.zig"),
        @embedFile("schema.zig"),
        @embedFile("sqlite.zig"),
        @embedFile("testing.zig"),
        @embedFile("queue.zig"),
    };
    var locks: usize = 0;
    var fence_stores: usize = 0;
    var fence_loads: usize = 0;
    var entered: usize = 0;
    inline for (sources) |source| {
        locks += std.mem.count(u8, source, "mutex.lock" ++ "Uncancelable(");
        fence_stores += std.mem.count(u8, source, "fenced.store" ++ "(true");
        fence_loads += std.mem.count(u8, source, "fenced.load" ++ "(");
        const enter = "enter" ++ "(self, ";
        var entries = std.mem.splitSequence(u8, source, enter);
        _ = entries.next();
        while (entries.next()) |rest| : (entered += 1) {
            const body = rest[0 .. std.mem.indexOf(u8, rest, "\n    }\n") orelse rest.len];
            try std.testing.expect(std.mem.indexOf(u8, body, "entry.finish") != null);
        }
    }
    // The Store's queue: `release`, `closing`, `take`, and its tests' `waitQueued`.
    try std.testing.expectEqual(@as(usize, 4), locks);
    try std.testing.expectEqual(@as(usize, 1), fence_stores);
    try std.testing.expectEqual(@as(usize, 1), fence_loads);
    try std.testing.expect(entered > 0);
}

test "response-stage model failures require their provenance" {
    // #511 lost request correlation and classification through defaulted
    // fields; a response-stage settlement must name every fact explicitly.
    inline for (.{ ModelFailure.Correlated, ModelFailure.Rejected }) |Stage| {
        inline for (@typeInfo(Stage).@"struct".field_attrs) |attrs| {
            try std.testing.expect(attrs.default_value_ptr == null);
        }
    }
    try std.testing.expect(@hasField(ModelFailure.Correlated, "request_id"));
    try std.testing.expect(@hasField(ModelFailure.Rejected, "request_id"));
    try std.testing.expect(@hasField(ModelFailure.Rejected, "diagnostic"));
    try std.testing.expect(@FieldType(ModelFailure.Rejected, "diagnostic") == []const u8);
}

test "canonical step faults fence rather than reading as ordinary misses" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Route = enum { result, view, purpose, handoff, failure, success };
            for (std.enums.values(Route)) |route| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "step-fault-config");
                try submitTestMessage(&storage, &tmp, "step-fault-input", "step-fault-message", session.slice(), "work");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const result: anyerror!void = switch (route) {
                    .result => blk: {
                        try store_testing.failReadsOf(&storage, "core_command");
                        break :blk if (storage.commandResult("step-fault-message")) |_| {} else |err| err;
                    },
                    .success => blk: {
                        try store_testing.failReadsOf(&storage, "session_revision");
                        break :blk settleCallsForTesting(&storage, &tmp, binding, "step-fault-success", &.{});
                    },
                    .view, .purpose, .handoff, .failure => blk: {
                        try store_testing.failReadsOf(&storage, "model_operation");
                        var view: HistoricalView = undefined;
                        break :blk switch (route) {
                            .view => storage.openHistoricalView(binding, &view),
                            .purpose => if (storage.modelOperationKind(binding)) |_| {} else |err| err,
                            .handoff => storage.withDispatchHandoff(binding, {}, struct {
                                fn run(_: void) !void {
                                    return error.TestUnexpectedResult;
                                }
                            }.run),
                            .failure => storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_failure" }, .ordinary, .{}),
                            .result, .success => unreachable,
                        };
                    },
                };
                // Before the Store owned classification these were ResultNotFound or
                // StaleAttemptBinding: ordinary outcomes that left the Store usable.
                try std.testing.expectError(if (route == .result) error.ResultReadFailed else error.OperationReadFailed, result);
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "a Bash call the Operation did not offer is rejected and keeps its description" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("unoffered-config", "", workspace, "model-a");
            command.configuration.tools.state = .value;
            command.configuration.tools = try .of(&.{});
            const reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const session = reply.accepted.session;
            try submitTestMessage(&storage, &tmp, "unoffered-message", "unoffered-message", session.slice(), "classify");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\"}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\"}" },
            };
            try settleCallsForTesting(&storage, &tmp, binding, "unoffered-metadata", &calls);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=0 AND rejection_code='unknown_tool' AND description='Run'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
        }
    }.run);
}

test "kind-specific admission selects a tool continuation despite fresh input and rolls back atomically" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_0 = try configureTestSessionAsk(&storage, "peer-config");
            const allocated_session_1 = try configureTestSessionAsk(&storage, "fresh-config");
            try submitTestMessage(&storage, &tmp, "peer-input", "peer-input", allocated_session_0.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, first, "peer-output", &calls);
            try submitTestMessage(&storage, &tmp, "fresh-input", "fresh-input", allocated_session_1.slice(), "competing input");

            try std.testing.expectError(error.InjectedAttemptCommitFailure, storage.admitModelAttempt(.tool_continuation, .{ .attempt_before_commit = true }));
            // A failed admission commit fences; recovery is a fresh Store open.
            try std.testing.expectError(error.StoreFenced, storage.admitModelAttempt(.tool_continuation, .{}));
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try std.testing.expectEqual(first.turn_id, continued.turn_id);
            try std.testing.expectEqual(first.operation_id + 1, continued.operation_id);
            try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            const fresh = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expect(fresh.turn_id != first.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
        }
    }.run);
}

test "tool continuation selection leaves a ready Turn with queued input to message selection" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            const queued_session = try configureTestSessionAsk(&storage, "queued-config");
            const ready_session = try configureTestSessionAsk(&storage, "ready-config");
            try submitTestMessage(&storage, &tmp, "queued-start", "queued-start", queued_session.slice(), "start");
            const queued = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, queued, "queued-output", &calls);
            try submitTestMessage(&storage, &tmp, "ready-start", "ready-start", ready_session.slice(), "start");
            const ready = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, ready, "ready-output", &calls);
            try submitTestMessage(&storage, &tmp, "queued-input", "queued-input", queued_session.slice(), "more");

            const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
            try std.testing.expectEqual(ready.turn_id, continued.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            const joined = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expectEqual(queued.turn_id, joined.turn_id);
            try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
        }
    }.run);
}

test "each transition that lets a Turn continue without input makes it selectable" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const Path = enum { rejected, denied, settled, indeterminate, overflow };
            for (std.enums.values(Path)) |path| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "continue-{s}", .{@tagName(path)});
                var config_buffer: [40]u8 = undefined;
                const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
                const session = if (path == .overflow) try configureTestSession(&storage, config) else try configureTestSessionAsk(&storage, config);
                try submitTestMessage(&storage, &tmp, name, name, session.slice(), "start");
                const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                switch (path) {
                    .rejected => {
                        const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                        try settleCallsForTesting(&storage, &tmp, first, config, &calls);
                    },
                    .denied, .settled, .indeterminate => {
                        try settleTwoActionsForTesting(&storage, &tmp, first, config);
                        const last_action = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{});
                        var key_buffer: [48]u8 = undefined;
                        try denyForTesting(&storage, session.slice(), try std.fmt.bufPrint(&key_buffer, "{s}-deny-first", .{name}), last_action - 1);
                        try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                        switch (path) {
                            .denied => try denyForTesting(&storage, session.slice(), try std.fmt.bufPrint(&key_buffer, "{s}-deny-last", .{name}), last_action),
                            else => {
                                var allow: protocol.PermissionDecisionCommand = .{ .action_id = last_action, .decision = .allow_once };
                                try allow.key.set(try std.fmt.bufPrint(&key_buffer, "{s}-allow", .{name}));
                                try allow.session.set(session.slice());
                                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                                const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
                                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                                if (path == .settled) {
                                    try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
                                } else {
                                    try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
                                }
                            },
                        }
                    },
                    .overflow => try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{}),
                }
                const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
                try std.testing.expectEqual(first.turn_id, continued.turn_id);
                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a Turn whose continuation was never recorded fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "unrecorded-config");
            try submitTestMessage(&storage, &tmp, "unrecorded", "unrecorded", session.slice(), "start");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, first, "unrecorded-metadata", &calls);
            try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=NULL", .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "a continuation recorded for a Turn waiting on its tool results fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "premature-config");
            try submitTestMessage(&storage, &tmp, "premature", "premature", session.slice(), "propose");
            const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "premature-config");
            try submitTestMessage(&storage, &tmp, "premature-input", "premature-input", session.slice(), "more");
            try store_testing.exec(&storage, "UPDATE turn SET continuation_operation_id=operation_id", .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "production turn preserves skipped continuation preference through actual Store admissions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const turn = @import("../execution_turn.zig");
            // Real canonical admissions and outcomes; no native effect is launched.
            // The test controls only available preparation and execution capacity.
            const Context = struct {
                storage: *Store,
                preparation_open: bool = true,
                /// Counts each preparation slot opening or closing, as setSlot does.
                slot_changes: u64 = 0,
                observed_open: bool = true,
                model: ?AttemptBinding = null,
                action: ?ActionAttemptBinding = null,
                failure: ?anyerror = null,
                faults: Faults = .{},

                pub fn now(_: *@This()) std.Io.Clock.Timestamp {
                    return .now(std.testing.io, .awake);
                }
                pub fn noteLifecycleOpportunity(_: *@This()) void {}
                pub fn consumeControlHint(_: *@This()) bool {
                    return false;
                }
                pub fn commitGeneration(self: *@This()) u64 {
                    return self.storage.commitGeneration();
                }
                pub fn slotChanges(self: *@This()) u64 {
                    if (self.observed_open != self.preparation_open) self.slot_changes += 1;
                    self.observed_open = self.preparation_open;
                    return self.slot_changes;
                }
                pub fn reconcileControls(_: *@This()) void {}
                pub fn advanceBashPreparation(_: *@This()) bool {
                    return false;
                }
                pub fn advanceLiveBash(_: *@This()) bool {
                    return false;
                }
                pub fn advanceRetainedCleanup(_: *@This(), _: std.Io.Clock.Timestamp, _: *std.Io.Clock.Timestamp) bool {
                    return false;
                }
                pub fn dispatchFenced(self: *@This()) bool {
                    return self.storage.isFenced();
                }
                pub fn freeSlots(_: *@This()) usize {
                    return 1;
                }
                pub fn providerConfigured(_: *@This()) bool {
                    return true;
                }
                pub fn bashPreparationOpen(_: *@This()) bool {
                    return true;
                }
                pub fn modelPreparationOpen(self: *@This()) bool {
                    return self.preparation_open;
                }
                pub fn recoverUncertainAction(_: *@This()) error{Fence}!bool {
                    return false;
                }
                pub fn recoverExhaustedRetry(_: *@This()) error{Fence}!bool {
                    return false;
                }
                pub fn runCoreAction(_: *@This()) turn.Admission {
                    return .no_work;
                }
                pub fn admitBash(self: *@This()) turn.Admission {
                    var admission = (self.storage.admitNextActionAttempt(1000, self.faults) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.action = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                pub fn admitRetry(self: *@This()) turn.Admission {
                    var admission = (self.storage.tryAdmitNextModelRetry(.empty(), self.faults) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.model = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                fn admit(self: *@This(), kind: ModelAdmissionKind) turn.Admission {
                    var admission = (self.storage.admitModelAttempt(kind, self.faults) catch |err| {
                        self.failure = err;
                        return .retry_later;
                    }) orelse return .no_work;
                    self.model = admission.permit.consume() catch unreachable;
                    return .admitted;
                }
                pub fn turnsPaused(_: *@This()) bool {
                    return false;
                }
                pub fn admitNewModel(self: *@This(), paused: bool) turn.Admission {
                    return self.admit(if (paused) .open_turn_message else .message);
                }
                pub fn admitToolContinuation(self: *@This()) turn.Admission {
                    return self.admit(.tool_continuation);
                }
                pub fn hasTransport(_: *@This()) bool {
                    return false;
                }
                pub fn hasBash(_: *@This()) bool {
                    return false;
                }
                pub fn driveTransport(_: *@This()) error{Fence}!void {}
                pub fn serviceOneCompletion(_: *@This()) bool {
                    return false;
                }
                pub fn modelPreparationAllowance(_: *@This()) turn.Allowance {
                    return .{ .bytes = 1, .items = 1 };
                }
                pub fn advanceModelPreparation(_: *@This(), _: usize, _: usize) bool {
                    return false;
                }
            };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_0 = try configureTestSession(&storage, "peer-config");
            const allocated_session_1 = try configureTestSession(&storage, "sender-config");
            const allocated_session_2 = try configureTestSession(&storage, "fresh-config");
            try submitTestMessage(&storage, &tmp, "peer-message", "peer-message", allocated_session_0.slice(), "start");
            const peer = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            const unknown = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, peer, "peer-result", &unknown);
            try submitTestMessage(&storage, &tmp, "sender-message", "sender-message", allocated_session_1.slice(), "send");
            try submitTestMessage(&storage, &tmp, "fresh-message", "fresh-message", allocated_session_2.slice(), "compete");
            var state: turn.State = .{};
            var context = Context{ .storage = &storage, .faults = .{ .attempt_before_commit = true } };
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(error.InjectedAttemptCommitFailure, context.failure.?);
            try std.testing.expect(context.model == null and context.action == null);
            try std.testing.expect(storage.isFenced());
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            context.faults = .{};
            context.failure = null;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            const sender = context.model.?;
            try std.testing.expect(sender.turn_id != peer.turn_id);
            const bash_calls = [_]TestingCall{.{ .item_id = "bash-item", .name = "bash", .encoded_call_id = "bash-call", .decoded_call_id = "bash-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&storage, &tmp, sender, "sender-result", &bash_calls);
            context.model = null;
            context.preparation_open = false;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            try std.testing.expectEqual(sender.operation_id, context.action.?.parent_operation_id);
            _ = try storage.settleActionAttempt(context.action.?, .succeeded, "sent", .{});
            context.preparation_open = true;
            _ = turn.run(&state, &context);
            try std.testing.expectEqual(@as(?anyerror, null), context.failure);
            // A circular cursor reset by the Bash winner, or the old combined
            // fresh-input-first Store selector, admits fresh work here instead.
            try std.testing.expectEqual(peer.turn_id, context.model.?.turn_id);
            try std.testing.expect((try storage.observeCommand("fresh-message")).message.?.queue.?.state == .queued);

            // Keep fresh Messages available while actual retries, Bash and tool-only
            // continuations repeatedly commit. The fixture makes retry clocks due;
            // the production turn and Store still own eligibility and admission.
            var sustained_tmp = std.testing.tmpDir(.{});
            defer sustained_tmp.cleanup();
            var sustained: Store = undefined;
            try store_testing.testingStore(case, &sustained, &sustained_tmp, std.testing.io);
            defer sustained.close() catch unreachable;
            var bindings: [3]AttemptBinding = undefined;
            for ([_][]const u8{ "continuing", "retrying", "sending" }, 0..) |reference, index| {
                var config_key_buffer: [64]u8 = undefined;
                const config_key = try std.fmt.bufPrint(&config_key_buffer, "{s}-config", .{reference});
                const session = try configureTestSession(&sustained, config_key);
                try submitTestMessage(&sustained, &sustained_tmp, reference, reference, session.slice(), "start");
                bindings[index] = (try sustained.admitModelAttempt(.message, .{})).?.permit.binding;
            }
            try settleCallsForTesting(&sustained, &sustained_tmp, bindings[0], "continued-result", &unknown);
            try sustained.settleModelAttemptFailure(bindings[1], .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
            try settleCallsForTesting(&sustained, &sustained_tmp, bindings[2], "sending-result", &bash_calls);
            const allocated_session_3 = try configureTestSession(&sustained, "fresh-loop-config");
            var progress = [_]usize{ 0, 0, 0, 0 }; // Bash, retry, fresh Message, continuation.
            var sustained_state: turn.State = .{};
            var sustained_context = Context{ .storage = &sustained };
            var fresh_number: usize = 0;
            for (0..32) |iteration| {
                // Replenish independently before every selection, never only after
                // the competing candidate has won.
                var key_buffer: [64]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buffer, "fresh-loop-{d}", .{fresh_number});
                fresh_number += 1;
                try submitTestMessage(&sustained, &sustained_tmp, key, key, allocated_session_3.slice(), "more input");
                try store_testing.exec(&sustained, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms>0 AND resolution_code IS NULL", .{});
                sustained_context.model = null;
                sustained_context.action = null;
                // The timer edge is fixture-owned; it grants no Attempt authority.
                sustained_state.last_retry_poll = null;
                _ = turn.run(&sustained_state, &sustained_context);
                try std.testing.expectEqual(@as(?anyerror, null), sustained_context.failure);
                if (sustained_context.action) |action| {
                    progress[0] += 1;
                    _ = try sustained.settleActionAttempt(action, .succeeded, "sent", .{});
                } else if (sustained_context.model) |model| {
                    if (model.operation_id == bindings[1].operation_id) {
                        progress[1] += 1;
                        try std.testing.expect(model.attempt_ordinal > 1);
                        try sustained.settleModelAttemptFailure(model, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
                    } else if (model.turn_id == bindings[0].turn_id or model.turn_id == bindings[2].turn_id) {
                        progress[3] += 1;
                        var name_buffer: [64]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buffer, "continuation-{d}", .{iteration});
                        try settleCallsForTesting(&sustained, &sustained_tmp, model, name, if (model.turn_id == bindings[0].turn_id) &unknown else &bash_calls);
                    } else {
                        progress[2] += 1;
                        try sustained.settleModelAttemptFailure(model, .{ .uncorrelated = "completed-fixture" }, .ordinary, .{});
                    }
                } else return error.NoProgressUnderSustainedInput;
            }
            try std.testing.expect(progress[0] >= 2 and progress[2] >= 2 and progress[3] >= 2);
            try std.testing.expectEqual(@as(usize, 3), progress[1]);
        }
    }.run);
}

test "terminal call-result import and read failures preserve canonical authority" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var import_tmp = std.testing.tmpDir(.{});
            defer import_tmp.cleanup();
            var import_store: Store = undefined;
            try store_testing.testingStore(case, &import_store, &import_tmp, std.testing.io);
            defer import_store.close() catch unreachable;
            const allocated_session_0 = try configureTestSessionAsk(&import_store, "result-import-config");
            try submitTestMessage(&import_store, &import_tmp, "result-import-message", "result-import-message", allocated_session_0.slice(), "call");
            const import_binding = (try import_store.admitNextModelAttempt(.{})).?.permit.binding;
            const valid_call = [_]TestingCall{.{ .item_id = "import-item", .name = "bash", .encoded_call_id = "import-call", .decoded_call_id = "import-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&import_store, &import_tmp, import_binding, "result-import-metadata", &valid_call);
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&import_store, "SELECT action_id FROM action_operation", .{}) };
            try deny.key.set("result-import-deny");
            try deny.session.set(allocated_session_0.slice());
            try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, import_store.decidePermission(&deny, .{ .content_import = true }));
            try std.testing.expect(import_store.isFenced());
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&import_store, "SELECT count(*) FROM core_command WHERE command_key='result-import-deny'", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&import_store, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL", .{}));

            var read_tmp = std.testing.tmpDir(.{});
            defer read_tmp.cleanup();
            var read_store: Store = undefined;
            try store_testing.testingStore(case, &read_store, &read_tmp, std.testing.io);
            defer read_store.close() catch unreachable;
            const allocated_session_1 = try configureTestSession(&read_store, "result-read-config");
            try submitTestMessage(&read_store, &read_tmp, "result-read-message", "result-read-message", allocated_session_1.slice(), "call");
            const read_binding = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
            const rejected_call = [_]TestingCall{.{ .item_id = "read-item", .name = "unknown", .encoded_call_id = "read-call", .decoded_call_id = "read-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&read_store, &read_tmp, read_binding, "result-read-metadata", &rejected_call);
            const continuation = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.withoutForeignKeys(&read_store, "UPDATE model_tool_call SET rejection_content_id=9223372036854775807", .{});
            var view: HistoricalView = undefined;
            try read_store.openHistoricalView(continuation, &view);
            defer view.close();
            var position: u64 = 0;
            while (true) {
                const entry = view.nextEntry(position) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                } orelse return error.MissingCorruptionFailure;
                position = entry.position;
            }
            try std.testing.expect(read_store.isFenced());
        }
    }.run);
}

test "runnable discovery fences structurally incomplete current tool calls" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { action, call }{ .action, .call };
            for (corruptions, 0..) |corruption, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const configs = [_][]const u8{ "discovery-action-config", "discovery-call-config" };
                const messages = [_][]const u8{ "discovery-action-message", "discovery-call-message" };
                const files = [_][]const u8{ "discovery-action-file", "discovery-call-file" };
                const metadata = [_][]const u8{ "discovery-action-metadata", "discovery-call-metadata" };
                const session = try configureTestSession(&storage, configs[index]);
                const session_ref = session.slice();
                try submitTestMessage(&storage, &tmp, files[index], messages[index], session_ref, "call");
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{.{
                    .item_id = "discovery-item",
                    .name = "bash",
                    .encoded_call_id = "discovery-call",
                    .decoded_call_id = "discovery-call",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                }};
                try settleCallsForTesting(&storage, &tmp, source, metadata[index], &calls);
                try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation", .{});
                if (corruption == .call) try store_testing.withoutForeignKeys(&storage, "DELETE FROM model_tool_call", .{});
                try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "compaction pressure uses provider usage appended input and complete call result groups" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (0..3) |scenario| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("1");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{
                    .{ .item_id = "item-a", .name = "unknown", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                    .{ .item_id = "item-b", .name = "unknown", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                };
                try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &calls, .{}, if (scenario == 0)
                    "{\"input_tokens\":99999,\"output_tokens\":1,\"details\":{\"input_tokens\":0}}"
                else
                    "{\"input_tokens\":9,\"output_tokens\":1,\"details\":{\"input_tokens\":1000000}}");
                var appended: [5000]u8 = @splat('x');
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), if (scenario == 2) &appended else "later");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const purpose: ModelOperationKind = if (scenario == 1) .assistant_response else .compaction;
                try std.testing.expectEqual(purpose, try storage.modelOperationKind(next));
                {
                    var view: HistoricalView = undefined;
                    try storage.openHistoricalView(next, &view);
                    defer view.close();
                    var cursor: TestingHistoryCursor = .{};
                    try std.testing.expect((try view.coverage()).anchor == null);
                    try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    for (0..2) |_| try std.testing.expectEqual(HistoricalEntryKind.provider_output, (try cursor.next(&view)).?.kind);
                    try std.testing.expectEqual(HistoricalEntryKind.tool_results, (try cursor.next(&view)).?.kind);
                    for ([_][]const u8{ "call-a", "call-b" }) |expected| {
                        const result = (try view.nextToolResult()).?;
                        var reader: HistoricalReader = undefined;
                        try view.openContent(result.call_id, &reader);
                        defer reader.close();
                        var bytes: [64]u8 = undefined;
                        const count = try reader.read(0, &bytes);
                        try std.testing.expectEqualStrings(expected, bytes[0..count]);
                    }
                    try std.testing.expect((try view.nextToolResult()) == null);
                    if (scenario == 1) try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    try std.testing.expect((try cursor.next(&view)) == null);
                }
                if (purpose == .compaction) {
                    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                    try settleCompactionForTesting(&storage, &tmp, next, &.{.compaction});
                    const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    var view: HistoricalView = undefined;
                    try storage.openHistoricalView(successor, &view);
                    defer view.close();
                    var cursor: TestingHistoryCursor = .{};
                    const anchor = (try view.coverage()).anchor.?;
                    for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .tool_results }) |kind|
                        try std.testing.expectEqual(kind, (try cursor.next(&view)).?.kind);
                    while (try view.nextToolResult()) |_| {}
                    const base_entry = (try cursor.next(&view)).?;
                    try std.testing.expectEqual(anchor, base_entry.position);
                    try std.testing.expectEqual(HistoricalEntryKind.provider_output, base_entry.kind);
                    try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
                    try std.testing.expect((try cursor.next(&view)) == null);
                    if (scenario == 0) {
                        // Accepted suffix without usage must not revive the large
                        // pre-base usage on the next admission.
                        try settleCallsForTesting(&storage, &tmp, successor, "suffix-output", &calls);
                        try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "small suffix");
                        const after_base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(after_base));
                    }
                }
            }
        }
    }.run);
}

test "missing canonical call outcome rows fence history and inspection" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { action, call, result_content }{ .action, .call, .result_content };
            const config_keys = [_][]const u8{ "missing-config-action", "missing-config-call", "missing-config-content" };
            const message_keys = [_][]const u8{ "missing-message-action", "missing-message-call", "missing-message-content" };
            const message_files = [_][]const u8{ "missing-file-action", "missing-file-call", "missing-file-content" };
            const metadata_files = [_][]const u8{ "missing-metadata-action", "missing-metadata-call", "missing-metadata-content" };
            const denial_keys = [_][]const u8{ "missing-denial-action", "missing-denial-call", "missing-denial-content" };
            for (corruptions, 0..) |corruption, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, config_keys[index]);
                const session_ref = session.slice();
                try submitTestMessage(
                    &storage,
                    &tmp,
                    message_files[index],
                    message_keys[index],
                    session_ref,
                    "call",
                );
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const calls = [_]TestingCall{.{
                    .item_id = "missing-item",
                    .name = "bash",
                    .encoded_call_id = "missing-call",
                    .decoded_call_id = "missing-call",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                }};
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    source,
                    metadata_files[index],
                    &calls,
                );
                var denial: protocol.PermissionDecisionCommand = .{
                    .action_id = try store_testing.queryU64(&storage, "SELECT max(action_id) FROM action_operation", .{}),
                };
                try denial.key.set(denial_keys[index]);
                try denial.session.set(session_ref);
                try std.testing.expect(storage.decidePermission(&denial, .{}) == .accepted);
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

                switch (corruption) {
                    .action => try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation", .{}),
                    .call => try store_testing.withoutForeignKeys(&storage, "DELETE FROM action_operation; DELETE FROM model_tool_call", .{}),
                    .result_content => try store_testing.withoutForeignKeys(&storage, "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation LIMIT 1)", .{}),
                }

                if (corruption == .action) {
                    var view: HistoricalView = undefined;
                    try storage.openHistoricalView(continuation, &view);
                    defer view.close();
                    var position: u64 = 0;
                    while (true) {
                        const entry = view.nextEntry(position) catch |err| {
                            try std.testing.expectEqual(error.CorruptStore, err);
                            break;
                        } orelse return error.MissingCorruptionFailure;
                        position = entry.position;
                    }
                } else {
                    try std.testing.expectError(
                        error.CorruptStore,
                        testingSessionReport(&storage, &tmp, session_ref, 1024 * 1024),
                    );
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "historical tool-result EOF revalidates complete canonical coverage" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "eof-coverage-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "eof-coverage-file",
                "eof-coverage-message",
                session.slice(),
                "call",
            );
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "eof-item-0", .name = "unknown", .encoded_call_id = "eof-call-0", .decoded_call_id = "eof-call-0", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "eof-item-1", .name = "unknown", .encoded_call_id = "eof-call-1", .decoded_call_id = "eof-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, source, "eof-coverage-metadata", &calls);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(continuation, &view);
            defer view.close();
            var position: u64 = 0;
            while (true) {
                const entry = (try nextTestingItem(&view, position)) orelse return error.MissingToolResultGroup;
                position = entry.position;
                if (entry.kind == .tool_results) break;
            }
            try std.testing.expect((try view.nextToolResult()) != null);

            try store_testing.withoutForeignKeys(&storage, "DELETE FROM model_tool_call WHERE call_ordinal=1", .{});
            try std.testing.expectError(error.CorruptStore, view.nextToolResult());
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "call classification uses the proposing Operation frozen catalog" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "frozen-call-config");
            var remove_bash: protocol.ConfigureCommand = .{};
            try remove_bash.key.set("frozen-call-no-tools");
            try remove_bash.session.set(session.slice());
            remove_bash.configuration.tools.state = .value;
            remove_bash.configuration.tools.count = 0;
            try std.testing.expect(storage.configure(&remove_bash, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "frozen-call-message", "frozen-call-message", session.slice(), "classify");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

            var add_bash: protocol.ConfigureCommand = .{};
            try add_bash.key.set("frozen-call-add-bash");
            try add_bash.session.set(session.slice());
            add_bash.configuration.tools.state = .value;
            add_bash.configuration.tools = try .of(&.{"bash"});
            try std.testing.expect(storage.configure(&add_bash, .{}) == .accepted);
            const calls = [_]TestingCall{.{
                .item_id = "frozen-item",
                .name = "bash",
                .encoded_call_id = "frozen-call",
                .decoded_call_id = "frozen-call",
                .encoded_arguments = "{\\\"description\\\":\\\"Print frozen marker\\\",\\\"cmd\\\":\\\"echo frozen\\\",\\\"timeout_ms\\\":null}",
                .decoded_arguments = "{\"description\":\"Print frozen marker\",\"cmd\":\"echo frozen\",\"timeout_ms\":null}",
            }};
            try settleCallsForTesting(&storage, &tmp, binding, "frozen-call-metadata", &calls);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool'", .{}));
        }
    }.run);
}

test "duplicate trustworthy call identity rolls back every imported consequence" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "duplicate-call-config");
            try submitTestMessage(&storage, &tmp, "duplicate-call-message", "duplicate-call-message", session.slice(), "duplicate");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "duplicate-item-1", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}" },
                .{ .item_id = "duplicate-item-2", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"description\\\":\\\"Run second command\\\",\\\"cmd\\\":\\\"two\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run second command\",\"cmd\":\"two\",\"timeout_ms\":null}" },
            };
            try std.testing.expectError(
                error.InvalidProviderEnvelope,
                settleCallsForTesting(&storage, &tmp, binding, "duplicate-call-metadata", &calls),
            );
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
        }
    }.run);
}

/// `count` message items, each its own id and text unless `same_text`,
/// whose item `repeat_at` (if any) repeats item 0's id; the last answers.
pub fn settleMessagesForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, comptime count: usize, same_text: bool, repeat_at: ?usize) !void {
    var buffers: [count][128]u8 = undefined;
    var items: [count][]const u8 = undefined;
    var answer_buffer: [32]u8 = undefined;
    var answer: []const u8 = "";
    for (&buffers, &items, 0..) |*buffer, *item, index| {
        const id = if (repeat_at == index) 0 else index;
        const text = if (same_text) 0 else index;
        item.* = try std.fmt.bufPrint(buffer, "{{\"type\":\"message\",\"id\":\"m{d}\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"t{d}\"}}]}}", .{ id, text });
        answer = try std.fmt.bufPrint(&answer_buffer, "t{d}", .{text});
    }
    try settleItemsForTesting(storage, tmp, binding, &items, answer);
}

test "each saved outcome names one feed ending" {
    const cases = .{
        .{ turn_domain.TurnOutcome{ .completed = 1 }, false, protocol.TurnEnding.done },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, true, protocol.TurnEnding.stopped },
        .{ turn_domain.TurnOutcome{ .cancelled = {} }, false, protocol.TurnEnding.interrupted },
        .{ turn_domain.TurnOutcome{ .retry_exhausted = null }, false, protocol.TurnEnding.provider_unavailable },
        .{ turn_domain.TurnOutcome{ .resource_exceeded = 2 }, false, protocol.TurnEnding.context_full },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_policy", .report = 3 } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_http_400", .report = null } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_api_key_rejected", .report = null } }, false, protocol.TurnEnding.provider_refused },
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "provider_tls_verification_failed", .report = null } }, false, protocol.TurnEnding.provider_unavailable },
        // A stop that selected a Turn a failure ended first leaves its ending.
        .{ turn_domain.TurnOutcome{ .failed = .{ .code = "malformed_provider_output", .report = null } }, true, protocol.TurnEnding.failed },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[2], case[0].ending(case[1]));
}

test "while new Turns are held, waiting input joins only an open Turn" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const open = try configureTestSession(&storage, "held-open-config");
            try submitTestMessage(&storage, &tmp, "held-first", "held-first-key", open.slice(), "first");
            const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            // A Message that arrives while the answer is being made keeps its Turn open.
            try submitTestMessage(&storage, &tmp, "held-second", "held-second-key", open.slice(), "second");
            try settleMessagesForTesting(&storage, &tmp, first, 1, false, null);
            const idle = try configureTestSession(&storage, "held-idle-config");
            try submitTestMessage(&storage, &tmp, "held-new", "held-new-key", idle.slice(), "new");
            // Held: the open Turn takes its input; the idle Session starts nothing.
            const joined = (try storage.admitModelAttempt(.open_turn_message, .{})).?.permit.binding;
            try std.testing.expectEqual(first.turn_id, joined.turn_id);
            try settleMessagesForTesting(&storage, &tmp, joined, 1, false, null);
            try std.testing.expect((try storage.admitModelAttempt(.open_turn_message, .{})) == null);
            // Resumed: the held Message starts its Turn.
            const started = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            try std.testing.expect(started.turn_id != first.turn_id);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "the final row is the answer phase selection picked, even when later text repeats it or it is blank" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            const final_then_commentary = [_][]const u8{
                "{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"same\"}]}",
                "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"same\"}]}",
            };
            const blank = [_][]const u8{
                "{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"working\"}]}",
                "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"  \"}]}",
            };
            const Case = struct { items: []const []const u8, selected: u64, answer: []const u8 };
            for ([_]Case{
                .{ .items = &final_then_commentary, .selected = 0, .answer = "same" },
                // A blank answer saves as empty content; its row keeps the blank text.
                .{ .items = &blank, .selected = 1, .answer = "" },
            }) |case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "selected-config");
                try submitTestMessage(&storage, &tmp, "selected-input", "selected-key", session.slice(), "answer");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try store_testing.settleSelectedItemsForTesting(&storage, &tmp, binding, case.items, case.selected, case.answer);
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                request.kinds = .initMany(&.{ .assistant, .turn_ended });
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), page.count);
                try std.testing.expectEqual(protocol.TurnEnding.done, page.items[2].value.turn_ended.ending);
                for (page.items[0..2], 0..) |item, index| try std.testing.expectEqual(index == case.selected, item.value.assistant.final);
            }
        }
    }.run);
}

test "a done Turn marks its answer final once its ending is within the page" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Three messages, the last the answer; with one text repeated, only
            // the answer itself, the last, is final.
            for ([_]bool{ false, true }) |same_text| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "final-config");
                try submitTestMessage(&storage, &tmp, "final-input", "final-key", session.slice(), "answer");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleMessagesForTesting(&storage, &tmp, binding, 3, same_text, null);
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                request.kinds = .initMany(&.{ .assistant, .turn_ended });
                const page = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 4), page.count);
                for (page.items[0..3], 0..) |item, index| try std.testing.expectEqual(index == 2, item.value.assistant.final);
                try std.testing.expectEqual(protocol.TurnEnding.done, page.items[3].value.turn_ended.ending);
                // A page that ends before the ending marks nothing final yet.
                request.end = page.items[2].position;
                const earlier = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(@as(usize, 3), earlier.count);
                for (earlier.items[0..3]) |item| try std.testing.expect(!item.value.assistant.final);
            }
        }
    }.run);
}

test "a call id repeated in a later call batch fails the settlement" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "repeat-call-config");
            try submitTestMessage(&storage, &tmp, "repeat-call-input", "repeat-call-key", session.slice(), "repeat");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var item_ids: [65][16]u8 = undefined;
            var call_ids: [65][16]u8 = undefined;
            var calls: [65]TestingCall = undefined;
            for (&calls, &item_ids, &call_ids, 0..) |*call, *item_id, *call_id, index| {
                const id = try std.fmt.bufPrint(call_id, "call-{d}", .{if (index == 64) 0 else index});
                call.* = .{
                    .item_id = try std.fmt.bufPrint(item_id, "item-{d}", .{index}),
                    .name = "bash",
                    .encoded_call_id = id,
                    .decoded_call_id = id,
                    .encoded_arguments = "{\\\"description\\\":\\\"Run it\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run it\",\"cmd\":\"true\",\"timeout_ms\":null}",
                };
            }
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCallsForTesting(&storage, &tmp, binding, "repeat-call", &calls));
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(0, try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
        }
    }.run);
}

test "valid and rejected call populations grow independently" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const population = 128;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var valid_item_storage: [population][24]u8 = undefined;
            var valid_call_storage: [population][24]u8 = undefined;
            var rejected_item_storage: [population][24]u8 = undefined;
            var rejected_call_storage: [population][24]u8 = undefined;
            var valid_calls: [population]TestingCall = undefined;
            var rejected_calls: [population]TestingCall = undefined;
            for (0..population) |index| {
                const valid_item = try std.fmt.bufPrint(&valid_item_storage[index], "valid-item-{d}", .{index});
                const valid_call = try std.fmt.bufPrint(&valid_call_storage[index], "valid-call-{d}", .{index});
                valid_calls[index] = .{
                    .item_id = valid_item,
                    .name = "bash",
                    .encoded_call_id = valid_call,
                    .decoded_call_id = valid_call,
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                };
                const rejected_item = try std.fmt.bufPrint(&rejected_item_storage[index], "rejected-item-{d}", .{index});
                const rejected_call = try std.fmt.bufPrint(&rejected_call_storage[index], "rejected-call-{d}", .{index});
                rejected_calls[index] = .{
                    .item_id = rejected_item,
                    .name = "unknown",
                    .encoded_call_id = rejected_call,
                    .decoded_call_id = rejected_call,
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
            }

            const allocated_session_0 = try configureTestSession(&storage, "valid-growth-config");
            try submitTestMessage(&storage, &tmp, "valid-growth-message", "valid-growth-message", allocated_session_0.slice(), "valid");
            const valid_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, valid_binding, "valid-growth-metadata", &valid_calls);
            try std.testing.expectEqual(@as(u64, population), (try storage.inspectSessionForTesting(allocated_session_0.slice())).action_count);
            const valid_report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
            defer std.testing.allocator.free(valid_report_bytes);
            const valid_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, valid_report_bytes, .{ .ignore_unknown_fields = true });
            defer valid_report.deinit();
            try std.testing.expectEqual(@as(usize, population), valid_report.value.actions.unresolved.len);

            const allocated_session_1 = try configureTestSession(&storage, "rejected-growth-config");
            try submitTestMessage(&storage, &tmp, "rejected-growth-message", "rejected-growth-message", allocated_session_1.slice(), "rejected");
            const rejected_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, rejected_binding, "rejected-growth-metadata", &rejected_calls);
            const rejected = try storage.inspectSessionForTesting(allocated_session_1.slice());
            try std.testing.expectEqual(@as(u64, 0), rejected.action_count);
            try std.testing.expectEqual(@as(u64, population), rejected.rejected_call_count);
            const rejected_report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_1.slice(), 1024 * 1024);
            defer std.testing.allocator.free(rejected_report_bytes);
            const rejected_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, rejected_report_bytes, .{ .ignore_unknown_fields = true });
            defer rejected_report.deinit();
            try std.testing.expectEqual(@as(usize, population), rejected_report.value.rejected_calls.items.len);
        }
    }.run);
}

test "Session stop freezes its selection and excludes only the admitted prefix" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-stop");
            try submitTestMessage(&storage, &tmp, "stop-a", "message-a", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?;
            const binding = first.permit.binding;

            var stop = try completeSessionStop("stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(!accepted.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expectEqual(binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
            try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(binding.operation_id, accepted.accepted.interrupted_operation_id.?);
            var view: HistoricalView = undefined;
            try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding, &view));

            const cancelled = (try storage.observeCommand("message-a")).message.?.queue.?;
            const cancellation = switch (cancelled.state) {
                .cancelled => |value| value,
                else => return error.ExpectedCancelledObservation,
            };
            try std.testing.expectEqual(binding.turn_id, cancellation.binding.turn_id);
            try std.testing.expectEqualStrings("cancelled", cancellation.code.slice());
            const active_report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(active_report);
            var active_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, active_report, .{});
            defer active_json.deinit();
            const active_message = active_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("applied", active_message.get("application").?.string);
            try std.testing.expect(active_message.get("exclusion").? == .null);

            var after_stop = try completeModelInterruption("interrupt-after-stop", session.slice(), binding);
            const rejected_interrupt = storage.interruptModel(&after_stop, .{});
            try std.testing.expect(rejected_interrupt == .rejected);
            try std.testing.expectEqual(
                protocol.ModelInterruptionRejection.operation_resolved,
                rejected_interrupt.rejected.code,
            );

            try submitTestMessage(&storage, &tmp, "stop-b", "message-b", session.slice(), "later");
            const replay = storage.stopSession(&stop, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
            try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
            try std.testing.expect((try storage.observeCommand("message-b")).message.?.queue.?.state == .queued);
            const later = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expect(later.permit.binding.turn_id != binding.turn_id);
        }
    }.run);
}

test "later idle stop does not reclassify a completed Message" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "completed-stop-config");
            try submitTestMessage(&storage, &tmp, "completed-stop-file", "completed-stop-message", session.slice(), "answer");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code='answer',attempt_at=NULL,resolved_at=1," ++
                "resolution_content_id=(SELECT content_id FROM message_admission WHERE command_key='completed-stop-message')", .{});
            try store_testing.exec(&storage, "UPDATE turn SET outcome_code='completed',outcome_at=1,outcome_content_id=(SELECT content_id FROM message_admission " ++
                "WHERE command_key='completed-stop-message'),outcome_position=(SELECT next_position FROM session WHERE session_ref=?1) WHERE session_ref=?1", .{session.slice()});
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+1 WHERE session_ref=?1", .{session.slice()});
            var stop = try completeSessionStop("completed-stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(accepted.accepted.selection.selected_turn_id == null);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expect((try storage.observeCommand("completed-stop-message")).message.?.queue.?.state == .completed);

            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer parsed.deinit();
            const message = parsed.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("applied", message.get("application").?.string);
            try std.testing.expect(message.get("exclusion").? == .null);
            try std.testing.expect(message.get("outcome").?.object.get("content").?.object.get("text") == null);
        }
    }.run);
}

test "idle Session stop excludes queued work but not later admissions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var storage_open = true;
            defer if (storage_open) storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-idle-stop");
            try submitTestMessage(&storage, &tmp, "idle-stop-a", "idle-message-a", session.slice(), "before");
            var stop = try completeSessionStop("idle-stop", session.slice());
            const accepted = storage.stopSession(&stop, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(!accepted.accepted.replayed);
            try std.testing.expectEqual(@as(?u64, null), accepted.accepted.selection.selected_turn_id);
            try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
            try std.testing.expectEqual(@as(?u64, null), accepted.accepted.interrupted_operation_id);
            const excluded = (try storage.observeCommand("idle-message-a")).message.?.queue.?;
            try std.testing.expect(excluded.state == .excluded);
            try std.testing.expectEqualStrings("session_stopped", excluded.state.excluded.code.slice());
            const excluded_report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(excluded_report);
            var excluded_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, excluded_report, .{});
            defer excluded_json.deinit();
            const excluded_message = excluded_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
            try std.testing.expectEqualStrings("excluded", excluded_message.get("application").?.string);
            try std.testing.expectEqualStrings("idle-stop", excluded_message.get("exclusion").?.object.get("command_key").?.string);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

            try submitTestMessage(&storage, &tmp, "idle-stop-b", "idle-message-b", session.slice(), "after");
            const later = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(@as(u64, 1), later.permit.binding.turn_id);

            // Replay before and after a real database reopen while newer work is live.
            for (0..2) |pass| {
                if (pass == 1) {
                    try storage.close();
                    storage_open = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    storage_open = true;
                }
                const replay = storage.stopSession(&stop, .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(accepted.accepted.selection, replay.accepted.selection);
                try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
                try std.testing.expectEqual(@as(?u64, null), replay.accepted.interrupted_operation_id);
                const newer = (try storage.observeCommand("idle-message-b")).message.?.queue.?.state;
                try std.testing.expect(newer == .processing);
                try std.testing.expectEqual(later.permit.binding, newer.processing);
                const original = (try storage.observeCommand("idle-message-a")).message.?.queue.?.state;
                try std.testing.expect(original == .excluded);
                try std.testing.expectEqualStrings("session_stopped", original.excluded.code.slice());
            }
            var fresh = try completeSessionStop("idle-stop-newer", session.slice());
            const stopped = storage.stopSession(&fresh, .{});
            try std.testing.expect(stopped == .accepted and !stopped.accepted.replayed);
            try std.testing.expectEqual(later.permit.binding.turn_id, stopped.accepted.selection.selected_turn_id.?);
            try std.testing.expectEqual(@as(u64, 2), stopped.accepted.selection.admission_cutoff);
            try std.testing.expectEqual(later.permit.binding.operation_id, stopped.accepted.interrupted_operation_id.?);
            try std.testing.expect((try storage.observeCommand("idle-message-b")).message.?.queue.?.state == .cancelled);
        }
    }.run);
}

test "exact model interruption continues only with applicable pending input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-interrupt");
            try submitTestMessage(&storage, &tmp, "interrupt-a", "interrupt-message-a", session.slice(), "first");
            const first = (try storage.admitNextModelAttempt(.{})).?;
            const binding = first.permit.binding;
            try submitTestMessage(&storage, &tmp, "interrupt-b", "interrupt-message-b", session.slice(), "second");

            var interrupt = try completeModelInterruption("interrupt", session.slice(), binding);
            const accepted = storage.interruptModel(&interrupt, .{});
            try std.testing.expect(accepted == .accepted);
            var view: HistoricalView = undefined;
            try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding, &view));
            const successor = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(binding.turn_id, successor.permit.binding.turn_id);
            try std.testing.expect(successor.permit.binding.operation_id != binding.operation_id);

            const observation = try storage.observeCommand("interrupt");
            try std.testing.expectEqual(binding.turn_id, observation.model_interruption.?.turn_id);
            try std.testing.expectEqual(binding.operation_id, observation.model_interruption.?.operation_id);

            try std.testing.expectError(
                error.SupersededByControl,
                storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "late_old_failure" }, .ordinary, .{}),
            );
            const successor_observation = (try storage.observeCommand("interrupt-message-b")).message.?.queue.?;
            const observed_successor = switch (successor_observation.state) {
                .processing => |value| value,
                else => return error.ExpectedProcessingObservation,
            };
            try std.testing.expectEqual(successor.permit.binding, observed_successor);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='interrupted' " ++
                "AND interrupted_by_command_key='interrupt'", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL", .{}));
            const replay = storage.interruptModel(&interrupt, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try storage.settleModelAttemptFailure(successor.permit.binding, .{ .uncorrelated = "successor_failure" }, .ordinary, .{});
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='successor_failure'", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='late_old_failure'", .{}));
        }
    }.run);
}

test "exact model interruption rejects stale targets and replays before applicability" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-rejected-interrupt");
            var early: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
            try early.key.set("early-interrupt");
            try early.session.set(session.slice());
            const rejected = storage.interruptModel(&early, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.unknown_operation, rejected.rejected.code);

            try submitTestMessage(&storage, &tmp, "rejected-interrupt-a", "rejected-interrupt-message", session.slice(), "first");
            const admitted = (try storage.admitNextModelAttempt(.{})).?;
            try std.testing.expectEqual(@as(u64, 1), admitted.permit.binding.operation_id);
            const replay = storage.interruptModel(&early, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.unknown_operation, replay.rejected.code);

            early.operation_id = 2;
            try std.testing.expect(storage.interruptModel(&early, .{}) == .conflict);

            var exact = try completeModelInterruption("exact-interrupt", session.slice(), admitted.permit.binding);
            try std.testing.expect(storage.interruptModel(&exact, .{}) == .accepted);
            try std.testing.expect(
                (try storage.observeCommand("rejected-interrupt-message")).message.?.queue.?.state == .cancelled,
            );
            try std.testing.expectError(
                error.SupersededByControl,
                storage.settleModelAttemptFailure(admitted.permit.binding, .{ .uncorrelated = "late_failure" }, .ordinary, .{}),
            );

            var after = try completeModelInterruption("after-interrupt", session.slice(), admitted.permit.binding);
            const resolved = storage.interruptModel(&after, .{});
            try std.testing.expect(resolved == .rejected);
            try std.testing.expectEqual(protocol.ModelInterruptionRejection.operation_resolved, resolved.rejected.code);
        }
    }.run);
}

test "controls remove scheduled retries and replay without cancelling newer work after reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Control = enum { none, stop, interruption };
            for ([_]Control{ .none, .stop, .interruption }) |control| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var storage_open = true;
                defer if (storage_open) storage.close() catch unreachable;

                const session = try configureTestSession(&storage, "retry-config");
                try submitTestMessage(&storage, &tmp, "retry-first", "retry-message", session.slice(), "first");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "temporary" }, .{ .retryable = .{
                    .waits_ms = .{ 60_000, 60_000, 60_000 },
                } }, .{});
                // Make the saved retry due without depending on wall-clock scheduling.
                try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});

                if (control == .none) {
                    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
                    try std.testing.expectEqual(binding.turn_id, retry.turn_id);
                    try std.testing.expectEqual(binding.operation_id, retry.operation_id);
                    try std.testing.expectEqual(@as(u64, 2), retry.attempt_ordinal);
                    continue;
                }
                const is_stop = control == .stop;
                var stop = try completeSessionStop("retry-control", session.slice());
                var interrupt = try completeModelInterruption("retry-control", session.slice(), binding);
                if (is_stop) {
                    const accepted = storage.stopSession(&stop, .{});
                    try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
                } else {
                    const accepted = storage.interruptModel(&interrupt, .{});
                    try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
                }
                try std.testing.expect((try admitRetryForTesting(&storage)) == null);
                try expectActivityOutcome(&storage, session.slice(), binding, if (is_stop) .stopped else .interrupted, "cancelled");

                try submitTestMessage(&storage, &tmp, "retry-newer", "retry-newer-message", session.slice(), "newer");
                const newer_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expect(newer_binding.turn_id != binding.turn_id);
                for (0..2) |pass| {
                    if (pass == 1) {
                        try storage.close();
                        storage_open = false;
                        try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                        storage_open = true;
                    }
                    if (is_stop) {
                        const replay = storage.stopSession(&stop, .{});
                        try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                        try std.testing.expectEqual(binding.turn_id, replay.accepted.selection.selected_turn_id.?);
                        try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
                        try std.testing.expectEqual(protocol.SessionStopCompletion.completed, replay.accepted.completion);
                        try std.testing.expectEqual(binding.operation_id, replay.accepted.interrupted_operation_id.?);
                    } else {
                        const replay = storage.interruptModel(&interrupt, .{});
                        try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                        const target = (try storage.observeCommand("retry-control")).model_interruption.?;
                        try std.testing.expectEqualStrings(session.slice(), target.session.slice());
                        try std.testing.expectEqual(binding.turn_id, target.turn_id);
                        try std.testing.expectEqual(binding.operation_id, target.operation_id);
                    }
                    const original = (try storage.observeCommand("retry-message")).message.?.queue.?.state;
                    try std.testing.expect(original == .cancelled);
                    try std.testing.expectEqual(binding, original.cancelled.binding);
                    const newer = (try storage.observeCommand("retry-newer-message")).message.?.queue.?.state;
                    try std.testing.expect(newer == .processing);
                    try std.testing.expectEqual(newer_binding, newer.processing);
                }
            }
        }
    }.run);
}

test "accepted stop remains discoverable without a control hint" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "hintless-config");
            try submitTestMessage(&storage, &tmp, "hintless-file", "hintless-message", session.slice(), "work");
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            const binding = try admitted.permit.consume();
            try std.testing.expect((try storage.operationSupersededByControl(binding)) == null);

            var stop = try completeSessionStop("hintless-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            const control = (try storage.operationSupersededByControl(binding)).?;
            try std.testing.expectEqualStrings("hintless-stop", control.command_key.slice());
        }
    }.run);
}

test "dispatch handoff refuses a stopped Attempt without invoking the launch callback" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "handoff-config");
            try submitTestMessage(&storage, &tmp, "handoff-file", "handoff-message", session.slice(), "work");
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            const binding = try admitted.permit.consume();

            const Launch = struct {
                fn run(calls: *usize) !void {
                    calls.* += 1;
                }
            };
            var calls: usize = 0;
            try storage.withDispatchHandoff(binding, &calls, Launch.run);
            try std.testing.expectEqual(@as(usize, 1), calls);

            var stop = try completeSessionStop("handoff-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectError(error.SupersededByControl, storage.withDispatchHandoff(binding, &calls, Launch.run));
            try std.testing.expectEqual(@as(usize, 1), calls);
        }
    }.run);
}

test "configuration pre-Workspace decisions preserve completeness and immutable binding" {
    const Case = struct {
        name: []const u8,
        has_current: bool,
        workspace_requested: bool,
        provider_requested: ?[]const u8,
        model_requested: ?[]const u8,
        expected: ?protocol.ConfigurationRejection,
    };
    const cases = [_]Case{
        .{
            .name = "new sparse request",
            .has_current = false,
            .workspace_requested = false,
            .provider_requested = null,
            .model_requested = null,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new request missing model",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = "codex",
            .model_requested = null,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new request uses Host provider",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = null,
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "new complete request",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = "codex",
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "different model is immutable",
            .has_current = true,
            .workspace_requested = true,
            .provider_requested = "codex",
            .model_requested = "model-b",
            .expected = .model_is_immutable,
        },
        .{
            .name = "same binding is accepted",
            .has_current = true,
            .workspace_requested = false,
            .provider_requested = "codex",
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "omitted binding is accepted",
            .has_current = true,
            .workspace_requested = false,
            .provider_requested = null,
            .model_requested = null,
            .expected = null,
        },
        .{ .name = "unknown provider is bounded", .has_current = true, .workspace_requested = false, .provider_requested = "other", .model_requested = null, .expected = .unsupported_provider },
    };

    var existing: CurrentConfiguration = .{};
    try existing.workspace.set("/canonical/workspace");
    existing.provider = .codex;
    try existing.model.set("model-a");
    existing.instructions_id = 11;
    existing.revision = 1;
    for (cases) |case| {
        var requested: protocol.Configuration = .{};
        if (!case.has_current) {
            requested.tools = try .of(&.{"bash"});
            requested.permission_mode.state = .value;
            try requested.permission_mode.value.set("bypass");
            requested.reasoning_effort.state = .explicit_null;
            requested.compaction_trigger.state = .value;
            try requested.compaction_trigger.value.set("115200");
        }
        if (case.workspace_requested) {
            requested.workspace.state = .value;
            try requested.workspace.value.set("relative-or-different-workspace");
        }
        if (case.model_requested) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        if (case.provider_requested) |provider| {
            requested.provider.state = .value;
            try requested.provider.value.set(provider);
        }
        const current: ?*const CurrentConfiguration = if (case.has_current) &existing else null;
        std.testing.expectEqual(
            case.expected,
            configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, current, &requested, .codex),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "configure refuses a tool name the catalog lacks and a provider tool its provider does not run" {
    const hosted: tool_catalog.Record = .{ .name = "code_interpreter", .owner = .provider };
    const records = [_]tool_catalog.Record{ tool_catalog.bash_record, hosted, tool_catalog.web_search_record };
    const digests = [_][32]u8{ tool_catalog.recordDigest(&records[0]), tool_catalog.recordDigest(&records[1]), tool_catalog.recordDigest(&records[2]) };
    const catalog: tool_catalog.Catalog = .{ .records = &records, .digests = &digests };
    try std.testing.expect(catalog.valid());
    var existing: CurrentConfiguration = .{};
    existing.provider = .codex;
    try existing.model.set("model-a");
    const Case = struct { names: []const []const u8, expected: ?protocol.ConfigurationRejection };
    for ([_]Case{
        .{ .names = &.{ "bash", "web_search" }, .expected = null },
        .{ .names = &.{}, .expected = null },
        .{ .names = &.{"edit"}, .expected = .unknown_tool },
        .{ .names = &.{ "bash", "edit" }, .expected = .unknown_tool },
        .{ .names = &.{"code_interpreter"}, .expected = .provider_tool_missing },
    }) |case| {
        var requested: protocol.Configuration = .{};
        requested.tools = try .of(case.names);
        try std.testing.expectEqual(case.expected, configuration_domain.configurationBeforeWorkspace(&catalog, &existing, &requested, .codex));
    }
}

test "Store configuration requires model, Bash workspace and, on a Host serving several, a provider" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            for (0..8) |mask| {
                var key_buffer: [32]u8 = undefined;
                var command = try completeConfiguration(
                    try std.fmt.bufPrint(&key_buffer, "presence-{d}", .{mask}),
                    "",
                    workspace,
                    "model-a",
                );
                if (mask & 1 == 0) command.configuration.workspace.state = .omitted;
                if (mask & 2 == 0) command.configuration.provider.state = .omitted;
                if (mask & 4 == 0) command.configuration.model.state = .omitted;
                const reply = storage.configure(&command, .{});
                // The test Store serves every provider, so none is the default (D221).
                if (mask == 7) {
                    try std.testing.expect(reply == .accepted);
                } else {
                    try std.testing.expect(reply == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, reply.rejected.code);
                    try std.testing.expect(!(try storage.inspectSessionForTesting(command.session.slice())).found);
                }
            }

            var initial = try completeConfiguration("binding-initial", "", workspace, "model-a");
            const initial_reply = storage.configure(&initial, .{});
            try std.testing.expect(initial_reply == .accepted);
            const session = initial_reply.accepted.session;
            const observation = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(protocol.Provider.codex, observation.provider.?);
            try std.testing.expectEqualStrings("model-a", observation.model.slice());

            var equal: protocol.ConfigureCommand = .{};
            try equal.key.set("binding-equal");
            equal.session = session;
            equal.configuration.provider.state = .value;
            try equal.configuration.provider.value.set("codex");
            equal.configuration.model.state = .value;
            try equal.configuration.model.value.set("model-a");
            try std.testing.expect(storage.configure(&equal, .{}) == .accepted);

            var different = equal;
            try different.key.set("binding-different");
            different.configuration.model.value.len = 0;
            try different.configuration.model.value.set("model-a ");
            const rejected = storage.configure(&different, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.model_is_immutable, rejected.rejected.code);
        }
    }.run);
}

test "unsupported provider rejects mixed configuration atomically and replays exact shape" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("atomic-initial", "", workspace, "model-a");
            const created_session_0_reply = storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            var update: protocol.ConfigureCommand = .{};
            try update.key.set("atomic-unsupported");
            try update.session.set(created_session_0.slice());
            update.configuration.provider.state = .value;
            try update.configuration.provider.value.set("anthropic");
            update.configuration.instructions = try testingBytesContent(&tmp, "atomic-instructions", "new instructions");
            update.configuration.output_schema = try testingBytesContent(&tmp, "atomic-schema", "{}");
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            defer update.removeTemporaryContent(std.testing.io) catch unreachable;
            const content_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const revision_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{});
            const rejected = storage.configure(&update, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_provider, rejected.rejected.code);
            try std.testing.expectEqual(content_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(revision_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            const current = try storage.inspectSessionForTesting(created_session_0.slice());
            try std.testing.expectEqual(@as(u64, 1), current.revision);
            try std.testing.expectEqual(tool_catalog.toolBit(.bash) | tool_catalog.toolBit(.web_search), current.tools_mask);
            try std.testing.expectEqualStrings("bypass", current.permission_mode.slice());
            const replay = storage.configure(&update, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);

            var omitted: protocol.ConfigureCommand = .{};
            try omitted.key.set("provider-shape");
            try omitted.session.set(created_session_0.slice());
            omitted.configuration.tools.state = .value;
            omitted.configuration.tools.count = 0;
            try std.testing.expect(storage.configure(&omitted, .{}) == .accepted);
            var explicit = omitted;
            explicit.configuration.provider.state = .value;
            try explicit.configuration.provider.value.set("codex");
            try std.testing.expect(storage.configure(&explicit, .{}) == .conflict);
            try std.testing.expect(storage.configure(&omitted, .{}).accepted.replayed);
        }
    }.run);
}

test "creation requires every agent setting and accepts an unused Workspace" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            inline for (.{ "model", "reasoning_effort", "compaction_trigger", "tools", "permission_mode" }) |field| {
                var command = try completeConfiguration("missing-" ++ field, "", workspace, "model-a");
                @field(command.configuration, field).state = .omitted;
                const reply = storage.configure(&command, .{});
                try std.testing.expect(reply == .rejected);
                try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, reply.rejected.code);
            }
            // A supplied Workspace is checked even when no tool uses it.
            var missing = try completeConfiguration("unused-missing", "", "/does-not-exist/rui-unused-workspace", "model-a");
            missing.configuration.tools = try .of(&.{});
            const refused = storage.configure(&missing, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_workspace, refused.rejected.code);
            {
                var key: [32]u8 = undefined;
                const index: usize = 0;
                var command = try completeConfiguration("unused-omitted", "", workspace, "model-a");
                command.configuration.tools = try .of(&.{});
                command.configuration.workspace.state = .omitted;
                const reply = storage.configure(&command, .{});
                try std.testing.expect(reply == .accepted);
                const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
                try std.testing.expectEqual(@as(u8, 0), observed.tools_mask);
                try std.testing.expectEqual(protocol.Provider.codex, observed.provider.?);
                var enable: protocol.ConfigureCommand = .{};
                try enable.key.set(try std.fmt.bufPrint(&key, "enable-{d}", .{index}));
                enable.session = reply.accepted.session;
                enable.configuration.tools = try .of(&.{"bash"});
                try std.testing.expect(storage.configure(&enable, .{}) == .accepted);
                const enabled = try storage.inspectSessionForTesting(reply.accepted.session.slice());
                try std.testing.expectEqualStrings(observed.workspace.slice(), enabled.workspace.slice());
                try std.testing.expectEqualStrings("/", enabled.workspace.slice());
                try std.testing.expectEqual(@as(u8, tool_catalog.toolBit(.bash)), enabled.tools_mask);
            }
        }
    }.run);
}

test "an omitted provider selects the Host's sole served provider" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var routes = protocol.routesAll(.unserved);
            routes.openai = .endpoint;
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = routes });
            defer storage.close() catch unreachable;
            var command = try completeConfiguration("host-provider", "", "/", "model-a");
            command.configuration.provider.state = .omitted;
            command.configuration.workspace.state = .omitted;
            command.configuration.tools = try .of(&.{});
            command.require_model = true;
            const reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
            try std.testing.expectEqual(protocol.Provider.openai, observed.provider.?);
            try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), observed.reasoning_effort);
        }
    }.run);
}

test "an omitted provider is refused on a Host serving several" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var routes = protocol.routesAll(.unserved);
            routes.openai = .endpoint;
            routes.codex = .endpoint;
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = routes });
            defer storage.close() catch unreachable;
            // D221: no provider is preferred, so the creation must name one.
            var command = try completeConfiguration("several-providers", "", "/", "model-a");
            command.configuration.provider.state = .omitted;
            command.configuration.workspace.state = .omitted;
            command.configuration.tools = try .of(&.{});
            const reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, reply.rejected.code);
            try command.key.set("several-providers-named");
            command.configuration.provider.state = .value;
            try command.configuration.provider.value.set("openai");
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
        }
    }.run);
}

test "compactAt enforces only known context windows on create and update" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const window: u64 = @import("../model_catalog.zig").find(@import("../model_catalog.zig").shipped, "gpt-6.1-sol").?.context_window.?;
            var buffer: [20]u8 = undefined;
            var command = try completeConfiguration("too-large-create", "", workspace, "gpt-6.1-sol");
            try command.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window + 1}));
            var reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, reply.rejected.code);
            try std.testing.expect(storage.configure(&command, .{}).rejected.replayed);
            try command.key.set("u64-too-large-create");
            try command.configuration.compaction_trigger.value.set("18446744073709551615");
            const huge = storage.configure(&command, .{});
            try std.testing.expect(huge == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, huge.rejected.code);
            try command.key.set("window-boundary");
            try command.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window}));
            reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("too-large-update");
            patch.session = reply.accepted.session;
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window + 1}));
            const refused = storage.configure(&patch, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, refused.rejected.code);
            try std.testing.expect(storage.configure(&patch, .{}).rejected.replayed);
            const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
            try std.testing.expectEqual(@as(u64, 1), observed.revision);
            try std.testing.expectEqual(@as(?u64, window), observed.compaction_trigger);
            try command.key.set("unlisted-window");
            try command.configuration.model.value.set("model-not-in-catalog");
            command.configuration.reasoning_effort.state = .explicit_null;
            try command.configuration.compaction_trigger.value.set("999999999");
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
        }
    }.run);
}

test "loaded tools select saved records even after the Host catalog changes or removes them" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var records = [_]tool_catalog.Record{
                tool_catalog.bash_record,
                .{ .name = "fetch_page", .owner = .mcp, .server = "original", .description = "Original page", .input_schema = "{\"type\":\"object\"}" },
                tool_catalog.find_tools_record,
                tool_catalog.message_agent_record,
                .{ .name = "other_page", .owner = .mcp, .server = "original", .description = "Other page", .input_schema = "{\"type\":\"object\"}" },
                tool_catalog.read_transcript_record,
                tool_catalog.start_agent_record,
                tool_catalog.web_search_record,
            };
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_catalog.recordDigest(record);
            const original: tool_catalog.Catalog = .{ .records = &records, .digests = &digests };
            try storage.saveCatalog(&original);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("loaded-records-create", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{ "fetch_page", "find_tools", "other_page" });
            create.configuration.loaded_tools = try .of(&.{"find_tools"});
            const first = storage.configure(&create, .{}).accepted.session;
            try create.key.set("loaded-records-second");
            const second = storage.configure(&create, .{}).accepted.session;
            const saved_record = try store_testing.queryU64(&storage, "SELECT t.tool_record_id FROM session s JOIN tool_set_member m ON m.tool_set_id=s.tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{first.slice()});

            var changed_records = records;
            changed_records[1] = .{ .name = "fetch_page", .owner = .mcp, .server = "replacement", .description = "New page", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}" };
            var changed_digests = digests;
            changed_digests[1] = tool_catalog.recordDigest(&changed_records[1]);
            const changed: tool_catalog.Catalog = .{ .records = &changed_records, .digests = &changed_digests };
            try storage.saveCatalog(&changed);
            var update: protocol.ConfigureCommand = .{};
            try update.key.set("loaded-records-reworded");
            update.session = first;
            update.configuration.loaded_tools = try .of(&.{ "fetch_page", "find_tools" });
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            const loaded_record = try store_testing.queryU64(&storage, "SELECT t.tool_record_id FROM session s JOIN tool_set_member m ON m.tool_set_id=s.loaded_tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{first.slice()});
            try std.testing.expectEqual(saved_record, loaded_record);

            var removed_records: [records.len - 1]tool_catalog.Record = undefined;
            removed_records[0] = records[0];
            @memcpy(removed_records[1..], records[2..]);
            var removed_digests: [removed_records.len][32]u8 = undefined;
            for (&removed_records, &removed_digests) |*record, *digest| digest.* = tool_catalog.recordDigest(record);
            const removed: tool_catalog.Catalog = .{ .records = &removed_records, .digests = &removed_digests };
            try storage.saveCatalog(&removed);
            try update.key.set("loaded-records-removed");
            update.session = second;
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            // Both configurations select the original records and intern
            // the very same loaded set despite today's catalog contents.
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT loaded_tool_set_id) FROM session WHERE session_ref=?1 OR session_ref=?2", .{ first.slice(), second.slice() }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "configuration planning preserves sparse defaults and rejection precedence" {
    const WorkspaceRequest = enum { omitted, same, different };
    const InstructionsRequest = enum { omitted, value };
    const SchemaRequest = enum { omitted, value, clear };
    const Actions = struct {
        instructions: ConfigurationContentAction,
        output_schema: configuration_domain.OutputSchemaAction,
    };
    const Case = struct {
        name: []const u8,
        created: bool,
        workspace: WorkspaceRequest,
        model: ?[]const u8 = null,
        empty_tools: bool = false,
        permission: ?[]const u8 = null,
        instructions: InstructionsRequest = .omitted,
        schema: SchemaRequest = .omitted,
        current_revision: u64 = 7,
        expected_rejection: ?protocol.ConfigurationRejection = null,
        expected_actions: ?Actions = null,
        expected_model: []const u8 = "model-a",
        expected_permission: u8 = 0,
        expected_revision: u64 = 8,
    };
    const cases = [_]Case{
        .{
            .name = "new explicit permission",
            .created = true,
            .workspace = .same,
            .model = "model-a",
            .permission = "bypass",
            .expected_actions = .{ .instructions = .default_empty, .output_schema = .clear },
            .expected_permission = 1,
            .expected_revision = 1,
        },
        .{
            .name = "sparse update preserves omitted content",
            .created = false,
            .workspace = .omitted,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .preserve },
        },
        .{
            .name = "explicit update requests imports and clear",
            .created = false,
            .workspace = .same,
            .model = "model-a",
            .empty_tools = true,
            .permission = "bypass",
            .instructions = .value,
            .schema = .clear,
            .expected_actions = .{ .instructions = .import_requested, .output_schema = .clear },
            .expected_model = "model-a",
            .expected_permission = 1,
        },
        .{
            .name = "requested schema imports",
            .created = false,
            .workspace = .omitted,
            .schema = .value,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .import_requested },
        },
        .{
            .name = "Workspace immutability precedes revision exhaustion",
            .created = false,
            .workspace = .different,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .workspace_is_immutable,
            .expected_revision = std.math.maxInt(i64),
        },
        .{
            .name = "revision exhaustion follows equal Workspace",
            .created = false,
            .workspace = .same,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .revision_exhausted,
            .expected_revision = std.math.maxInt(i64),
        },
    };

    try std.testing.expect(@sizeOf(ConfigurationUpdatePlan) <= 4);
    for (cases) |case| {
        var existing: CurrentConfiguration = .{};
        try existing.workspace.set("/canonical/workspace");
        existing.provider = .codex;
        try existing.model.set("model-a");
        existing.instructions_id = 11;
        existing.tools_mask = 1;
        existing.permission_mode = 0;
        existing.output_schema_id = 12;
        existing.revision = case.current_revision;

        var requested: protocol.Configuration = .{};
        requested.provider.state = .value;
        try requested.provider.value.set("codex");
        if (case.workspace != .omitted) requested.workspace.state = .value;
        if (case.model) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        if (case.empty_tools) {
            requested.tools.state = .value;
            requested.tools.count = 0;
        }
        if (case.permission) |permission| {
            requested.permission_mode.state = .value;
            try requested.permission_mode.value.set(permission);
        }
        if (case.instructions == .value) requested.instructions.state = .value;
        requested.output_schema.state = switch (case.schema) {
            .omitted => .omitted,
            .value => .value,
            .clear => .explicit_null,
        };

        const workspace_matches: ?bool = switch (case.workspace) {
            .omitted => null,
            .same => true,
            .different => false,
        };
        const current: ?*const CurrentConfiguration = if (case.created) null else &existing;
        var next = if (current) |value| value.* else CurrentConfiguration{};
        const plan = configuration_domain.planConfigurationUpdate(current, &requested, workspace_matches, &next);

        if (case.expected_rejection) |expected| {
            std.testing.expect(plan == .rejected) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected, plan.rejected);
        } else {
            const expected = case.expected_actions.?;
            std.testing.expect(plan == .update) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected.instructions, plan.update.instructions);
            try std.testing.expectEqual(expected.output_schema, plan.update.output_schema);
        }
        try std.testing.expectEqualStrings(case.expected_model, next.model.slice());
        try std.testing.expectEqual(case.expected_permission, next.permission_mode);
        try std.testing.expectEqual(case.expected_revision, next.revision);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 11), next.instructions_id);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 12), next.output_schema_id);
    }
}

test "configuration answers replay without reverting newer settings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var first = try completeConfiguration("first", "", workspace, "model-a");
            const first_reply = storage.configure(&first, .{});
            try std.testing.expect(first_reply == .accepted);
            try std.testing.expect(first_reply.accepted.created);

            var update: protocol.ConfigureCommand = .{};
            try update.key.set("update");
            update.session = first_reply.accepted.session;
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            const update_reply = storage.configure(&update, .{});
            try std.testing.expect(update_reply == .accepted);
            try std.testing.expectEqual(@as(u64, 2), update_reply.accepted.revision);

            const replay = storage.configure(&first, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
            const observation = try storage.inspectSessionForTesting(first_reply.accepted.session.slice());
            try std.testing.expectEqualStrings("model-a", observation.model.slice());
            try std.testing.expectEqual(@as(u64, 2), observation.revision);
            try std.testing.expectEqual(@as(u8, 0), observation.tools_mask);
            try std.testing.expectEqualStrings("bypass", observation.permission_mode.slice());
            try std.testing.expectEqual(@as(u64, 0), observation.instructions.length);
            var empty_digest: [32]u8 = undefined;
            empty_digest = protocol.contentDigest("");
            try std.testing.expectEqualSlices(u8, &empty_digest, &observation.instructions.digest);
            try std.testing.expect(observation.output_schema == null);

            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var content_window: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 0), try reader.read(0, &content_window));
            try std.testing.expectError(error.RangeOutOfBounds, reader.read(1, &content_window));
            try std.testing.expect((try storage.observeCommand("first")).status == .accepted);

            first.configuration.tools.state = .value;
            first.configuration.tools.count = 0;
            try std.testing.expect(storage.configure(&first, .{}) == .conflict);
        }
    }.run);
}

test "content reader owns the bounded result-delivery window" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(@as(usize, 4096), protocol.content_window_bytes);
            try std.testing.expectEqual(
                @as(usize, 64 * 1024),
                ContentReader.content_window_bytes,
            );

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const session = try configureTestSession(&storage, "configure-window");
            var text: [ContentReader.content_window_bytes + 17]u8 = undefined;
            for (&text, 0..) |*byte, index| byte.* = @intCast(index % 251);
            try submitTestMessage(
                &storage,
                &tmp,
                "window-message-source",
                "window-message",
                session.slice(),
                &text,
            );
            const reference = (try storage.observeCommand("window-message")).message.?.content;
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(reference));
            defer reader.close();

            var window: [ContentReader.content_window_bytes]u8 = undefined;
            try std.testing.expectEqual(window.len, try reader.read(0, &window));
            try std.testing.expectEqualSlices(u8, text[0..window.len], &window);
            try std.testing.expectEqual(
                @as(usize, 17),
                try reader.read(window.len, &window),
            );
            try std.testing.expectEqualSlices(u8, text[window.len..], window[0..17]);
            try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &window));
            try std.testing.expectError(
                error.RangeOutOfBounds,
                reader.read(text.len + 1, &window),
            );
            try std.testing.expectError(error.WindowTooLarge, reader.read(0, &text));
        }
    }.run);
}

test "core preserves empty and NUL keys while Session references stay canonical" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("", "", workspace, "model-a");
            const reply = storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const session = reply.accepted.session;
            try std.testing.expect(protocol.validSessionId(session.slice()));
            const observation = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expect(observation.found);
            try std.testing.expectEqualStrings(session.slice(), observation.session.slice());
            try std.testing.expect((try storage.observeCommand("")).status == .accepted);

            var update: protocol.ConfigureCommand = .{};
            try update.key.set("exact\x00key");
            update.session = session;
            const updated = storage.configure(&update, .{});
            try std.testing.expect(updated == .accepted and !updated.accepted.created);
            try std.testing.expectEqual(@as(u64, 2), updated.accepted.revision);
            try std.testing.expect((try storage.observeCommand("exact\x00key")).status == .accepted);
            try std.testing.expect(storage.configure(&update, .{}).accepted.replayed);

            var invalid = try completeConfiguration("invalid-nul-session", "exact\x00reference", workspace, "model-a");
            const rejected = storage.configure(&invalid, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(session.slice())).revision);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "saved incomplete initialization stays rejected after Session creation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var incomplete: protocol.ConfigureCommand = .{};
            try incomplete.key.set("incomplete");
            const rejected = storage.configure(&incomplete, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, rejected.rejected.code);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var complete = try completeConfiguration(
                "complete",
                "",
                workspace,
                "model-a",
            );
            try std.testing.expect(storage.configure(&complete, .{}) == .accepted);
            const replay = storage.configure(&incomplete, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
        }
    }.run);
}

test "capability-required configuration rejects on replacement and replays its saved decision" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("capability-guard", "", workspace, "model-a");
            command.require_model = true;

            storage.served = protocol.routesAll(.unserved);
            const rejected = storage.configure(&command, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.model_capability_unavailable, rejected.rejected.code);
            try std.testing.expect(!(try storage.inspectSessionForTesting(command.session.slice())).found);
            const replay = storage.configure(&command, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqual(rejected.rejected.code, replay.rejected.code);

            var new_key = command;
            try new_key.key.set("capability-guard-next");
            storage.served = protocol.routesAll(.endpoint);
            try std.testing.expect(storage.configure(&new_key, .{}) == .accepted);
            storage.served = protocol.routesAll(.unserved);
            try std.testing.expect(storage.configure(&new_key, .{}).accepted.replayed);
            var changed_intent = command;
            changed_intent.require_model = false;
            try std.testing.expect(storage.configure(&changed_intent, .{}) == .conflict);
            try changed_intent.key.set("explicit-offline-config");
            try std.testing.expect(storage.configure(&changed_intent, .{}) == .accepted);
        }
    }.run);
}

test "failed commit saves neither answer nor partial Session" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration(
                "commit-fault",
                "",
                workspace,
                "model-a",
            );
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const reply = storage.configure(&command, .{ .before_commit = true });
                try std.testing.expect(reply == .infrastructure_failure);
                try storage.close();
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                try std.testing.expect((try storage.observeCommand("commit-fault")).status == .absent);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expect(storage.configure(&command, .{}) == .accepted);
            }
        }
    }.run);
}

/// Records each `MessageCommitted` call, as the Host's environment install sees it.
pub const TestingCommits = struct {
    calls: [4]struct { session: protocol.Bounded(protocol.max_session_bytes), admission_id: u64, from_peer: bool } = undefined,
    count: usize = 0,

    pub fn callback(self: *TestingCommits) Store.MessageCommitted {
        return .{ .context = self, .call = record };
    }

    pub fn record(context: *anyopaque, admission: Store.MessageAdmission) void {
        const self: *TestingCommits = @ptrCast(@alignCast(context));
        self.calls[self.count] = .{ .session = .{}, .admission_id = admission.admission_id, .from_peer = admission.from_peer };
        self.calls[self.count].session.set(admission.session) catch unreachable;
        self.count += 1;
    }
};

fn testingLabel(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?[]u8 {
    const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const label = report.value.object.get("session").?.object.get("label").?;
    return if (label == .null) null else try std.testing.allocator.dupe(u8, label.string);
}

test "a Label is configured, replayed, cleared and validated like any setting" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            // Set at creation.
            var create = try completeConfiguration("label-create", "", workspace, "model-a");
            create.configuration.label.state = .value;
            try create.configuration.label.value.set("Review PR 412");
            const created = storage.configure(&create, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            {
                const label = (try testingLabel(&storage, &tmp, session.slice())).?;
                defer std.testing.allocator.free(label);
                try std.testing.expectEqualStrings("Review PR 412", label);
            }
            // An exact replay answers the saved admission; a changed Label under the
            // same key conflicts.
            try std.testing.expect(storage.configure(&create, .{}).accepted.replayed);
            var changed = create;
            try changed.configuration.label.value.set("Review PR 413");
            try std.testing.expect(storage.configure(&changed, .{}) == .conflict);

            // A Label-only revision relabels without touching the Conversation, and
            // omission preserves the Label.
            var relabel: protocol.ConfigureCommand = .{};
            try relabel.key.set("label-relabel");
            try relabel.session.set(session.slice());
            relabel.configuration.label.state = .value;
            try relabel.configuration.label.value.set("Fix the flaky resize test");
            try std.testing.expectEqual(@as(u64, 2), storage.configure(&relabel, .{}).accepted.revision);
            var effort: protocol.ConfigureCommand = .{};
            try effort.key.set("label-preserved");
            try effort.session.set(session.slice());
            effort.configuration.permission_mode.state = .value;
            try effort.configuration.permission_mode.value.set("ask");
            try std.testing.expect(storage.configure(&effort, .{}) == .accepted);
            {
                const label = (try testingLabel(&storage, &tmp, session.slice())).?;
                defer std.testing.allocator.free(label);
                try std.testing.expectEqualStrings("Fix the flaky resize test", label);
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry", .{}));
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE label IS NOT NULL", .{}));

            // Explicit null clears it.
            var clear: protocol.ConfigureCommand = .{};
            try clear.key.set("label-clear");
            try clear.session.set(session.slice());
            clear.configuration.label.state = .explicit_null;
            try std.testing.expect(storage.configure(&clear, .{}) == .accepted);
            try std.testing.expect((try testingLabel(&storage, &tmp, session.slice())) == null);

            // A Label obeys the saved description rule: blank and multi-line text
            // is refused and saved as such.
            for ([_][]const u8{ " ", "two\nlines", "tab\u{2028}separated" }, 0..) |text, index| {
                var refused: protocol.ConfigureCommand = .{};
                var key_buffer: [32]u8 = undefined;
                try refused.key.set(try std.fmt.bufPrint(&key_buffer, "label-refused-{d}", .{index}));
                try refused.session.set(session.slice());
                refused.configuration.label.state = .value;
                try refused.configuration.label.value.set(text);
                const reply = storage.configure(&refused, .{});
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_label, reply.rejected.code);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a creating Message with require_model creates nothing without a model" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("composer", "", workspace, "model-a");
            var message: protocol.MessageCommand = .{ .configuration = settings.configuration, .require_model = true };
            try message.key.set("composer");
            message.text = try testingBytesContent(&tmp, "composer-message", "start here");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;

            storage.served = protocol.routesAll(.unserved);
            const refused = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expectEqual(protocol.MessageRejection.model_capability_unavailable, refused.rejected.code);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            // The saved refusal replays even once a model is available, and the
            // same key without the condition is a different request.
            storage.served = protocol.routesAll(.endpoint);
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}).rejected.replayed);
            var unconditional = message;
            unconditional.require_model = false;
            try std.testing.expect(storage.submitMessageWithModel(&unconditional, null, .{}) == .conflict);

            var accepted = message;
            try accepted.key.set("composer-ready");
            const reply = storage.submitMessageWithModel(&accepted, null, .{});
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "initial Message atomically allocates its Session and replays its original admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("start", "", workspace, "model-a");
            var message: protocol.MessageCommand = .{ .configuration = settings.configuration };
            try message.key.set("start");
            message.text = try testingBytesContent(&tmp, "initial-message", "assignment\x00雪\n\n");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var first: AcceptedMessage = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const reply = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(reply == .accepted);
                first = reply.accepted;
                try std.testing.expect(protocol.validSessionId(first.session.slice()));
                const observed = try storage.observeCommand("start");
                try std.testing.expect(observed.target.eql(first.session.slice()));
                try std.testing.expectEqual(first.admission_id, observed.message.?.queue.?.admission_id);
                try std.testing.expectError(error.ResultNotReady, storage.commandResult("start"));
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(first.session.slice())).pending_messages);
                var changed = message;
                changed.configuration.?.model.value = .{};
                try changed.configuration.?.model.value.set("model-b");
                try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                var refused = message;
                try refused.key.set("invalid-initial-settings");
                refused.configuration.?.workspace.value = .{};
                const rejected = storage.submitMessageWithModel(&refused, null, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.MessageRejection.invalid_workspace, rejected.rejected.code);
                try std.testing.expect(storage.submitMessageWithModel(&refused, null, .{}).rejected.replayed);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const replay = storage.submitMessageWithModel(&message, null, .{}).accepted;
                try std.testing.expect(replay.replayed);
                try std.testing.expectEqual(first.admission_id, replay.admission_id);
                try std.testing.expectEqualStrings(first.session.slice(), replay.session.slice());
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
                var failed = message;
                try failed.key.set("failed-start-commit");
                try std.testing.expect(storage.submitMessageWithModel(&failed, null, .{ .before_commit = true }) == .infrastructure_failure);
                try storage.close();
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                try std.testing.expectEqual(.absent, (try storage.observeCommand("failed-start-commit")).status);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            }
        }
    }.run);
}

test "message rejections replay before current Session checks without retained input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Fix entropy so a real allocation makes the formerly unknown target live.
            // Replay must still return the original rejection, not re-run admission.
            const Entropy = struct {
                fn random(_: ?*anyopaque, bytes: []u8) std.Io.RandomSecureError!void {
                    @memset(bytes, 0);
                }
            };
            var vtable = std.testing.io.vtable.*;
            vtable.randomSecure = Entropy.random;
            var io = std.testing.io;
            io.vtable = &vtable;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, io);
            defer storage.close() catch unreachable;

            const text = "rejected input";
            const file = try tmp.dir.createFile(std.testing.io, "rejected-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("rejected-message", "000000", file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            const rejected = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, rejected.rejected.code);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure-later", "", workspace, "model-a");
            const configured = storage.configure(&configuration, .{});
            try std.testing.expect(configured == .accepted);
            try std.testing.expectEqualStrings(message.session.slice(), configured.accepted.session.slice());
            const replay = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, replay.rejected.code);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &replay.rejected.content.digest);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(configured.accepted.session.slice())).pending_messages);

            const observed = try storage.observeCommand("rejected-message");
            try std.testing.expect(observed.status == .rejected);
            try std.testing.expect(observed.message == null);
        }
    }.run);
}

test "a peer sender is resolved from its Action handle and exact replays survive revocation" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const sender_id = try configureTestSession(&storage, "configure-sender");
            const sender = sender_id.slice();
            // Pages retain the complete allocated identity, not a display alias.
            _ = try configureTestSession(&storage, "configure-neighbour");
            const allocated_session_1 = try configureTestSession(&storage, "configure-receiver");
            var tools: protocol.ConfigureCommand = .{};
            try tools.key.set("sender-tools");
            try tools.session.set(sender);
            tools.configuration.tools = try .of(&.{"bash"});
            tools.configuration.permission_mode.state = .value;
            try tools.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(storage.configure(&tools, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "sender-seed", "sender-seed", sender, "send a report");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "sender-calls");
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: BashExecutionInput = undefined;
            try storage.readBashExecutionInput(action, &input);
            const handle = input.sender_handle;
            var own_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
            try own_ref.set(sender);
            const sender_end = (try store_core.activityPageForTesting(&storage, .{ .session = own_ref })).end;
            const Send = struct {
                fn make(dir: std.Io.Dir, key: []const u8, target: []const u8, from: ?[]const u8, text: []const u8) !protocol.MessageCommand {
                    const file = try dir.createFile(std.testing.io, key, .{ .read = true });
                    try file.writeStreamingAll(std.testing.io, text);
                    try file.sync(std.testing.io);
                    var command = try completeMessage(key, target, file, text);
                    if (from) |ref| {
                        command.sender = .{};
                        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
                        try command.sender.?.store.set(root_buffer[0..try dir.realPath(std.testing.io, &root_buffer)]);
                        try command.sender.?.session.set(ref);
                    }
                    return command;
                }
            };

            var sent = try Send.make(tmp.dir, "peer-send", allocated_session_1.slice(), sender, "look at this\nsecond line");
            sent.sender_handle = handle;
            defer sent.removeTemporaryContent(std.testing.io) catch unreachable;
            var commits: TestingCommits = .{};
            const accepted = storage.submitMessageWithModel(&sent, commits.callback(), .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expect(storage.submitMessageWithModel(&sent, commits.callback(), .{}).accepted.replayed);
            try std.testing.expectEqual(@as(usize, 1), commits.count);
            try std.testing.expect(commits.calls[0].from_peer);
            try std.testing.expectEqual(accepted.accepted.admission_id, commits.calls[0].admission_id);
            // The sender is part of the request: the same key without it conflicts.
            var anonymous = try Send.make(tmp.dir, "peer-send-anonymous", allocated_session_1.slice(), null, "look at this\nsecond line");
            defer anonymous.removeTemporaryContent(std.testing.io) catch unreachable;
            try anonymous.key.set("peer-send");
            try std.testing.expect(storage.submitMessageWithModel(&anonymous, null, .{}) == .conflict);

            var refused = try Send.make(tmp.dir, "peer-refused", "absent", sender, "lost");
            refused.sender_handle = handle;
            defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, storage.submitMessageWithModel(&refused, commits.callback(), .{}).rejected.code);
            // A rejected Message installs nothing.
            try std.testing.expectEqual(@as(usize, 1), commits.count);

            var forged = try Send.make(tmp.dir, "peer-forged", allocated_session_1.slice(), "f0rged", "forged");
            defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&forged, null, .{}).rejected.code);
            const forged_replay = storage.submitMessageWithModel(&forged, null, .{});
            try std.testing.expect(forged_replay.rejected.replayed and forged_replay.rejected.code == .invalid_sender_handle);
            // Every invalid binding must leave both receiver admission and the
            // falsely claimed sender's Activity untouched.
            for (0..5) |variant| {
                var invalid = sent;
                var key_buffer: [32]u8 = undefined;
                try invalid.key.set(try std.fmt.bufPrint(&key_buffer, "invalid-binding-{d}", .{variant}));
                switch (variant) {
                    0 => invalid.sender_handle = null,
                    1 => try invalid.sender_handle.?.set(""),
                    2 => try invalid.sender_handle.?.set("00000000000000000000000000000000"),
                    3 => try invalid.sender.?.session.set(allocated_session_1.slice()),
                    4 => invalid.sender = null,
                    else => unreachable,
                }
                try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&invalid, null, .{}).rejected.code);
            }
            var changed_handle = sent;
            changed_handle.sender_handle = null;
            try std.testing.expect(storage.submitMessageWithModel(&changed_handle, null, .{}) == .conflict);
            // An invalid target is refused first, whichever sender: an unknown one
            // claims no sequence position, and the Store stays open.
            for ([_]struct { key: []const u8, from: []const u8 }{
                .{ .key = "peer-empty-forged", .from = "f0rged" },
                .{ .key = "peer-empty-known", .from = sender },
            }) |case| {
                var empty = try Send.make(tmp.dir, case.key, "", case.from, "nowhere");
                if (std.mem.eql(u8, case.from, sender)) empty.sender_handle = handle;
                defer empty.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expectEqual(protocol.MessageRejection.invalid_session_reference, storage.submitMessageWithModel(&empty, null, .{}).rejected.code);
            }
            // An unknown sender has no sequence: only the known sender's refusals are kept.
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection", .{}));
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(allocated_session_1.slice())).pending_messages);

            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try session.set(allocated_session_1.slice());
            const received = try store_core.activityPageForTesting(&storage, .{ .session = session });
            try std.testing.expectEqual(@as(usize, 1), received.count);
            const peer = received.items[0].value.received.sender.?;
            try std.testing.expectEqualStrings(sender, peer.session.slice());
            {
                // The receiver's row names that peer as its starter; no person has
                // messaged it.
                var listed = try testingListRow(&storage, &tmp, allocated_session_1.slice());
                defer listed.deinit();
                try std.testing.expectEqualStrings(sender, listed.get(&.{ "first_message", "sender", "session" }).string);
                try std.testing.expect(listed.get(&.{ "peers", "from_person_at" }) == .null);
            }

            try session.set(sender);
            try store_testing.exec(&storage, "UPDATE sent_rejection SET rejected_at=200+sender_position", .{});
            const own = try store_core.activityPageForTesting(&storage, .{ .session = session, .position = sender_end });
            try std.testing.expectEqual(@as(usize, 3), own.count);
            try std.testing.expectEqualStrings("invalid_session_reference", own.items[2].value.send_failed.code.slice());
            const out = own.items[0].value.sent;
            try std.testing.expectEqual(accepted.accepted.admission_id, out.admission);
            // One Message's two rows share its admission time; a refused send is
            // dated by its refusal.
            try std.testing.expectEqual(out.admitted_at, own.items[0].at);
            try std.testing.expectEqual(received.items[0].at, own.items[0].at);
            for (own.items[1..3]) |failure| try std.testing.expectEqual(200 + failure.position, failure.at);
            try std.testing.expectEqualStrings(allocated_session_1.slice(), out.target.session.slice());
            const failed = own.items[1].value.send_failed;
            try std.testing.expectEqualStrings("absent", failed.target.session.slice());
            try std.testing.expectEqualStrings("unknown_session", failed.code.slice());
            try std.testing.expect(own.items[0].position < own.items[1].position);
            {
                // Each peer row names the peer by its label as it is now; a peer
                // without one, or one the Store never held, has none.
                try std.testing.expectEqual(@as(usize, 0), out.target.label.len);
                try std.testing.expectEqual(@as(usize, 0), failed.target.label.len);
                try store_testing.exec(&storage, "UPDATE session SET label='Review the WAL' WHERE session_ref=?1", .{allocated_session_1.slice()});
                const renamed = try store_core.activityPageForTesting(&storage, .{ .session = session, .position = sender_end });
                try std.testing.expectEqualStrings("Review the WAL", renamed.items[0].value.sent.target.label.slice());
                try std.testing.expectEqual(@as(usize, 0), renamed.items[1].value.send_failed.target.label.len);
                try store_testing.exec(&storage, "UPDATE session SET label='Lead' WHERE session_ref=?1", .{sender});
                var receiver: protocol.Bounded(protocol.max_session_bytes) = .{};
                try receiver.set(allocated_session_1.slice());
                const named = try store_core.activityPageForTesting(&storage, .{ .session = receiver });
                try std.testing.expectEqualStrings("Lead", named.items[0].value.received.sender.?.label.slice());
            }
            try storage.revokeActionSender(action);
            try std.testing.expect(storage.submitMessageWithModel(&sent, null, .{}).accepted.replayed);
            var stale = sent;
            try stale.key.set("stale-handle");
            try std.testing.expectEqual(protocol.MessageRejection.invalid_sender_handle, storage.submitMessageWithModel(&stale, null, .{}).rejected.code);
            // The sent row's bytes are the Message's, read through the sender.
            var reader: ContentReader = undefined;
            reader.open(try storage.openActivityContent(&.{ .session = session, .position = own.items[0].position }));
            reader.close();

            // The model's historical view carries the recorded sender, not text.
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(try admitted.permit.consume(), &view);
            defer view.close();
            const entry = (try view.nextEntry(0)).?;
            try std.testing.expect(entry.kind == .user);
            try std.testing.expectEqualStrings(sender, entry.sender.?.slice());
        }
    }.run);
}

test "message observation validates accepted admission references independently" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const corruptions = [_]enum { session, content }{ .session, .content };
            for (corruptions) |corruption| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;

                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var primary_configuration = try completeConfiguration(
                    "reference-primary-configure",
                    "",
                    workspace,
                    "model-a",
                );
                const created_session_0_reply = storage.configure(&primary_configuration, .{});
                try std.testing.expect(created_session_0_reply == .accepted);
                const created_session_0 = created_session_0_reply.accepted.session;
                var other_configuration = try completeConfiguration(
                    "reference-other-configure",
                    "",
                    workspace,
                    "model-a",
                );
                const other_reply = storage.configure(&other_configuration, .{});
                try std.testing.expect(other_reply == .accepted);
                const other_session = other_reply.accepted.session;

                const primary_file = try tmp.dir.createFile(std.testing.io, "reference-primary-message", .{ .read = true });
                try primary_file.writeStreamingAll(std.testing.io, "primary input");
                try primary_file.sync(std.testing.io);
                var primary_message = try completeMessage(
                    "reference-primary-message",
                    created_session_0.slice(),
                    primary_file,
                    "primary input",
                );
                defer primary_message.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&primary_message, null, .{}) == .accepted);

                const other_file = try tmp.dir.createFile(std.testing.io, "reference-other-message", .{ .read = true });
                try other_file.writeStreamingAll(std.testing.io, "other input");
                try other_file.sync(std.testing.io);
                var other_message = try completeMessage(
                    "reference-other-message",
                    other_session.slice(),
                    other_file,
                    "other input",
                );
                defer other_message.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&other_message, null, .{}) == .accepted);

                switch (corruption) {
                    .session => try store_testing.exec(&storage, "UPDATE message_admission SET session_ref=?1 " ++
                        "WHERE command_key='reference-primary-message'", .{other_session.slice()}),
                    .content => try store_testing.exec(&storage, "UPDATE message_admission SET content_id=?1 " ++
                        "WHERE command_key='reference-primary-message'", .{try store_testing.queryU64(
                        &storage,
                        "SELECT content_id FROM message_admission WHERE command_key='reference-other-message'",
                        .{},
                    )}),
                }
                try std.testing.expectError(
                    error.CorruptStore,
                    storage.observeCommand("reference-primary-message"),
                );
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "message observation rejects an answer attached to processing durable facts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration(
                "corrupt-observation-configure",
                "",
                workspace,
                "model-a",
            );
            const created_session_0_reply = storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            const file = try tmp.dir.createFile(std.testing.io, "corrupt-observation-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "input");
            try file.sync(std.testing.io);
            var message = try completeMessage(
                "corrupt-observation-message",
                created_session_0.slice(),
                file,
                "input",
            );
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try store_testing.exec(&storage, "UPDATE turn SET outcome_content_id=(" ++
                "SELECT content_id FROM message_admission WHERE command_key='corrupt-observation-message')", .{});

            try std.testing.expectError(
                error.CorruptStore,
                storage.observeCommand("corrupt-observation-message"),
            );
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "message conflicts and failed commits cannot create another admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure", "", workspace, "model-a");
            const created_session_0_reply = storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            const text = "one admission";
            const file = try tmp.dir.createFile(std.testing.io, "message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("message", created_session_0.slice(), file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var commits: TestingCommits = .{};
            try std.testing.expect(storage.submitMessageWithModel(&message, commits.callback(), .{ .before_commit = true }) == .infrastructure_failure);
            // A Message that did not commit installs nothing.
            try std.testing.expectEqual(@as(usize, 0), commits.count);
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expect((try storage.observeCommand("message")).status == .absent);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            const accepted = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(accepted == .accepted);

            var retargeted = message;
            retargeted.text.file = null;
            try retargeted.session.set("0ther0");
            try std.testing.expect(storage.submitMessageWithModel(&retargeted, null, .{}) == .conflict);
            var changed = message;
            changed.text.file = null;
            changed.text.length += 1;
            try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
            var changed_kind = try completeConfiguration("message", created_session_0.slice(), workspace, "model-a");
            try std.testing.expect(storage.configure(&changed_kind, .{}) == .conflict);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            try storage.close();
        }
    }.run);
}

test "failed message import rolls back content command and admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("configure", "", workspace, "model-a");
            const created_session_0_reply = storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            const text = "larger than an empty import";
            const file = try tmp.dir.createFile(std.testing.io, "import-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("message-import", created_session_0.slice(), file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{ .content_import = true }) == .infrastructure_failure);
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expect((try storage.observeCommand("message-import")).status == .absent);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
            try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        }
    }.run);
}

test "external content import follows sealed descriptor custody" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const captured = "captured instructions";
            const replacement = "pathname replacement";
            const file = try tmp.dir.createFile(std.testing.io, "ingress", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, captured);
            try file.sync(std.testing.io);
            try tmp.dir.deleteFile(std.testing.io, "ingress");
            var replacement_file = try tmp.dir.createFile(std.testing.io, "ingress", .{});
            try replacement_file.writeStreamingAll(std.testing.io, replacement);
            replacement_file.close(std.testing.io);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("sealed", "", workspace, "model-a");
            command.configuration.instructions = .{
                .state = .value,
                .file = file,
                .length = captured.len,
                .digest = protocol.contentDigest(captured),
            };
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            const observation = try storage.inspectSessionForTesting(created_session_0.slice());
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var bytes: [captured.len]u8 = undefined;
            try std.testing.expectEqual(captured.len, try reader.read(0, &bytes));
            try std.testing.expectEqualStrings(captured, &bytes);
        }
    }.run);
}

test "external content identity is verified before canonical commit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            const captured = "captured instructions";
            const file = try tmp.dir.createFile(std.testing.io, "changed", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, captured);
            try file.sync(std.testing.io);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("changed", "", workspace, "model-a");
            command.configuration.instructions = .{
                .state = .value,
                .file = file,
                .length = captured.len,
                .digest = protocol.contentDigest("different bytes"),
            };
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;

            try std.testing.expect(storage.configure(&command, .{}) == .infrastructure_failure);
            try std.testing.expectError(error.StoreFenced, storage.observeCommand("changed"));
        }
    }.run);
}

test "content verification failure rolls back new imports and deduplicated inputs" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            const Case = enum { digest, short, long, empty_digest, read_failure };
            inline for (.{ false, true }) |deduplicated| {
                inline for (std.meta.tags(Case)) |case| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    const length: usize = if (case == .empty_digest) 0 else protocol.content_window_bytes * 2 + 17;

                    var initial = try completeConfiguration("initial", "", workspace, "model-a");
                    initial.configuration.instructions = try testingContent(&tmp, "original", 'a', length);
                    defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
                    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
                    if (deduplicated) {
                        const configured = storage.configure(&initial, .{});
                        try std.testing.expect(configured == .accepted);
                        session = configured.accepted.session;
                    }
                    const content_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                    const command_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{});
                    const revision_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{});

                    var command = try completeConfiguration("invalid", session.slice(), workspace, "model-a");
                    command.configuration.instructions = try testingContent(&tmp, "invalid", 'b', length);
                    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                    const content = &command.configuration.instructions;
                    switch (case) {
                        .digest => {
                            // A dedup hit must check supplied bytes, not trust the claimed digest.
                            content.digest = initial.configuration.instructions.digest;
                        },
                        .short => content.length += 1,
                        .long => content.length -= 1,
                        .empty_digest => content.digest[0] ^= 1,
                        .read_failure => {
                            if (deduplicated) content.digest = initial.configuration.instructions.digest;
                        },
                    }
                    try std.testing.expect(storage.configure(&command, .{ .content_read = case == .read_failure }) == .infrastructure_failure);
                    try std.testing.expectError(error.StoreFenced, storage.observeCommand("invalid"));
                    try std.testing.expectEqual(content_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expectEqual(command_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                    try std.testing.expectEqual(revision_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
                    try std.testing.expectEqual(@as(u64, if (deduplicated) 1 else 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}

test "content import reads once and rolls back sources that change during reading" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Probe = struct {
                const Change = enum { none, truncate, grow };
                var change: Change = .none;
                var bytes_read: usize = 0;

                fn read(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
                    const count = try std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
                    bytes_read += count;
                    if (offset == 0) switch (change) {
                        .none => {},
                        .truncate => file.setLength(std.testing.io, count) catch return error.Unexpected,
                        .grow => file.setLength(std.testing.io, protocol.content_window_bytes * 2 + 18) catch return error.Unexpected,
                    };
                    return count;
                }
            };
            for (std.meta.tags(Probe.Change)) |change| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var vtable = std.testing.io.vtable.*;
                vtable.fileReadPositional = Probe.read;
                storage.io.vtable = &vtable;
                Probe.change = change;
                Probe.bytes_read = 0;

                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var command = try completeConfiguration("read-probe", "", workspace, "model-a");
                const length = protocol.content_window_bytes * 2 + 17;
                command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
                defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                if (change == .none) {
                    const created_session_0_reply = storage.configure(&command, .{});
                    try std.testing.expect(created_session_0_reply == .accepted);
                    const created_session_0 = created_session_0_reply.accepted.session;
                    try std.testing.expectEqual(length, Probe.bytes_read);
                    Probe.bytes_read = 0;
                    try command.key.set("deduplicated");
                    command.session = created_session_0;
                    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
                    try std.testing.expectEqual(length, Probe.bytes_read);
                } else {
                    try std.testing.expect(storage.configure(&command, .{}) == .infrastructure_failure);
                    try std.testing.expectError(error.StoreFenced, storage.observeCommand("read-probe"));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE content_id NOT IN (SELECT description_content_id FROM tool_record) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}

test "multiwindow content import and deduplication preserve all bytes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("first", "", workspace, "model-a");
            const length = protocol.content_window_bytes * 2 + 17;
            command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const created_session_0_reply = storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            try command.key.set("second");
            command.session = created_session_0;
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
            const observation = try storage.inspectSessionForTesting(created_session_0.slice());
            try std.testing.expectEqual(@as(u64, 2), observation.revision);
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var offset: usize = 0;
            while (offset < length) {
                const count = try reader.read(offset, buffer[0..@min(buffer.len, length - offset)]);
                try std.testing.expect(count != 0);
                for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
                offset += count;
            }
            try std.testing.expectEqual(length, offset);
        }
    }.run);
}

test "large raw content opens without materializing its payload" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("large", "", workspace, "model-a");
            const length = 32 * 1024 * 1024 + 10;
            command.configuration.instructions = try testingContent(&tmp, "large-source", 'q', length);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const reference = ContentReference{
                .length = command.configuration.instructions.length,
                .digest = command.configuration.instructions.digest,
            };
            const created_session_0_reply = storage.configure(&command, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(reference));
            defer reader.close();
            var first: [17]u8 = undefined;
            try std.testing.expectEqual(first.len, try reader.read(0, &first));
            for (first) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
            var last: [17]u8 = undefined;
            try std.testing.expectEqual(last.len, try reader.read(length - last.len, &last));
            for (last) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
        }
    }.run);
}

test "public conversation owner fixes end, filters settings and bounds content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var configuration = try completeConfiguration("public-config", "", workspace, "model-a");
            // The 1 MiB Message must not start a compaction: this test reads pages.
            configuration.configuration.compaction_trigger.state = .value;
            try configuration.configuration.compaction_trigger.value.set("1000000000");
            const created_session_0_reply = storage.configure(&configuration, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            var request = protocol.ConversationPage{};
            try request.session.set(created_session_0.slice());
            try std.testing.expectEqual(@as(usize, 0), (try store_core.publicConversationPageForTesting(&storage, request)).count);

            // A large first input and nineteen small ones expose both the item and
            // content bound; no answer is invented for queued, unapplied input.
            for (0..20) |index| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "public-{d}", .{index});
                var command: protocol.MessageCommand = .{};
                try command.key.set(name);
                try command.session.set(created_session_0.slice());
                command.text = if (index == 19)
                    try testingBytesContent(&tmp, name, "é中")
                else
                    try testingContent(&tmp, name, 'x', if (index == 0) 1024 * 1024 else 3);
                try std.testing.expect(storage.submitMessageWithModel(&command, null, .{}) == .accepted);
                try command.removeTemporaryContent(std.testing.io);
            }
            try std.testing.expectEqual(@as(usize, 0), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            var instruction: protocol.ConfigureCommand = .{};
            try instruction.key.set("public-instruction-before-selection");
            try instruction.session.set(created_session_0.slice());
            instruction.configuration.instructions = try testingContent(&tmp, "public-instruction-before", 's', 7);
            defer instruction.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&instruction, .{}) == .accepted);
            const active = (try storage.admitNextModelAttempt(.{})).?;
            const first = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 16), first.count);
            try std.testing.expect(first.more);
            try std.testing.expectEqual(@as(u64, 41), first.items[0].position);
            try std.testing.expectEqual(@as(u64, 26), first.items[15].position);
            for (first.items[0..first.count]) |item| try std.testing.expect(item.kind == .user);
            try std.testing.expectEqual(@as(u64, 5), first.items[0].content.length);
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, .{
                .session = request.session,
                .end = first.end,
                .before_position = first.items[15].position,
                .before_ordinal = 1,
            }));
            try std.testing.expect(!storage.isFenced());
            var unicode_reader: ContentReader = undefined;
            unicode_reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = 41 }));
            var lead: [1]u8 = undefined;
            var rest: [4]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 1), try unicode_reader.read(0, &lead));
            try std.testing.expectEqual(@as(usize, 4), try unicode_reader.read(1, &rest));
            try std.testing.expectEqual("é中"[0], lead[0]);
            try std.testing.expectEqualStrings("é中"[1..], &rest);
            unicode_reader.close();

            var later: protocol.ConfigureCommand = .{};
            try later.key.set("public-instructions");
            try later.session.set(created_session_0.slice());
            later.configuration.instructions = try testingContent(&tmp, "public-private-settings", 'p', 16);
            defer later.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&later, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "after-page", "after-page-key", created_session_0.slice(), "later public input");
            try storage.settleModelAttemptFailure(active.permit.binding, .{ .uncorrelated = "fixture_failure" }, .ordinary, .{});
            _ = (try storage.admitNextModelAttempt(.{})).?;
            const fixed_first = try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session, .end = first.end });
            try std.testing.expectEqual(first.end, fixed_first.end);
            try std.testing.expectEqual(first.count, fixed_first.count);
            for (first.items[0..first.count], fixed_first.items[0..fixed_first.count]) |expected, actual| {
                try std.testing.expectEqual(expected.position, actual.position);
                try std.testing.expectEqual(expected.ordinal, actual.ordinal);
            }
            request.end = first.end;
            request.before_position = first.items[15].position;
            const older = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 4), older.count);
            try std.testing.expect(!older.more);
            try std.testing.expectEqual(@as(u64, 25), older.items[0].position);
            try std.testing.expectEqual(@as(u64, 22), older.items[3].position);
            try std.testing.expectEqual(@as(u64, 1024 * 1024), older.items[3].content.length);
            const fresh = try store_core.publicConversationPageForTesting(&storage, .{ .session = request.session });
            try std.testing.expectEqual(@as(usize, 16), fresh.count);
            try std.testing.expect(fresh.items[0].position > first.end);
            try std.testing.expect(fresh.items[0].kind == .user);
            var read = protocol.ConversationContent{ .session = request.session, .position = older.items[3].position, .start = 1024 * 1024 - 2 };
            var reader: ContentReader = undefined;
            reader.open(try storage.openPublicConversationContent(&read));
            var tail: [2]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 2), try reader.read(read.start, &tail));
            try std.testing.expectEqualStrings("xx", &tail);
            reader.close();
            read.position = 42; // the applied instruction is not public content
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&read));
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = .{}, .position = 1 }));
            try std.testing.expectError(error.RangeOutOfBounds, storage.openPublicConversationContent(&.{ .session = request.session, .position = 22, .start = 1024 * 1024 + 1 }));
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, .{ .session = request.session, .end = first.end + 100, .before_position = 1 }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "private-only model output never becomes public conversation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "private-config");
            try submitTestMessage(&storage, &tmp, "private-input", "private-message", session.slice(), "hi");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Keep a successor queued: a terminal text Turn requires an answer, while
            // this intermediate accepted output contains only opaque continuation.
            try submitTestMessage(&storage, &tmp, "private-next", "private-next-message", session.slice(), "later");
            const bytes = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"private continuation\"}";
            const source = try tmp.dir.createFile(std.testing.io, "private-output", .{ .read = true });
            defer source.close(std.testing.io);
            try source.writeStreamingAll(std.testing.io, bytes);
            try source.sync(std.testing.io);
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used: std.atomic.Value(u64) = .init(0);
            var retained: ?named_scratch.Owner = null;
            var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "private-metadata", .{ .used = &used, .limit = 1024 }, false, &retained);
            defer metadata.deinit();
            _ = try output_decode.recordItemForTesting(&metadata, source, 0, bytes.len, 0, .assistant_response);
            try metadata.sealForRead();
            try storage.settleModelSuccess(binding, &.{
                .source = source,
                .source_length = bytes.len,
                .metadata = metadata.file,
                .item_count = 1,
                .call_count = 0,
                .answer_length = 0,
                .answer_digest = protocol.contentDigest(""),
                .response_id = .{},
                .model_evidence = testing_absent_model_evidence,
                .request_id = .{},
            }, .{});
            var request = protocol.ConversationPage{};
            try request.session.set(session.slice());
            const page = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            try std.testing.expect(page.items[0].kind == .user);
            try std.testing.expect(page.end > page.items[0].position);
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{
                .session = request.session,
                .position = page.end,
            }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "public tool-result cursor crosses a completed group boundary" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "group-config");
            try submitTestMessage(&storage, &tmp, "group-input", "group-message", session.slice(), "run tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var ids: [17][16]u8 = undefined;
            var names: [17][16]u8 = undefined;
            var calls: [17]TestingCall = undefined;
            for (&calls, 0..) |*call, index| {
                const id = try std.fmt.bufPrint(&ids[index], "item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&names[index], "call-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = call_id, .decoded_call_id = call_id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "group-metadata", &calls);
            var cursor = protocol.ConversationPage{};
            try cursor.session.set(session.slice());
            const newest = try store_core.publicConversationPageForTesting(&storage, cursor);
            try std.testing.expectEqual(@as(usize, 16), newest.count);
            try std.testing.expect(newest.more);
            for (newest.items[0..newest.count], 0..) |item, index| {
                try std.testing.expect(item.kind == .tool_result);
                try std.testing.expectEqual(newest.items[0].position, item.position);
                try std.testing.expectEqual(@as(u64, 17) - index, item.ordinal);
            }
            cursor.end = newest.end;
            cursor.before_position = newest.items[15].position;
            cursor.before_ordinal = 18; // No such completed call in this group.
            try std.testing.expectError(error.InvalidCursor, store_core.publicConversationPageForTesting(&storage, cursor));
            try std.testing.expect(!storage.isFenced());
            cursor.before_ordinal = newest.items[15].ordinal;
            const older = try store_core.publicConversationPageForTesting(&storage, cursor);
            try std.testing.expectEqual(@as(usize, 2), older.count);
            try std.testing.expect(!older.more);
            try std.testing.expectEqual(@as(u64, 1), older.items[0].ordinal);
            try std.testing.expect(older.items[0].kind == .tool_result);
            try std.testing.expect(older.items[1].kind == .user);
            var reader: ContentReader = undefined;
            reader.open(try storage.openPublicConversationContent(&.{ .session = cursor.session, .position = older.items[0].position, .ordinal = 1 }));
            defer reader.close();
            var result: [64]u8 = undefined;
            const size = try reader.read(0, &result);
            try std.testing.expectEqualStrings("Unknown tool: unknown.", result[0..size]);
        }
    }.run);
}

test "definite rejections retain decisions without retaining payloads" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("initial", "", workspace, "model-a");
            const created_session_0_reply = storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            try store_testing.exec(&storage, "UPDATE session SET revision=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});

            var unknown_message: protocol.MessageCommand = .{};
            try unknown_message.key.set("unknown-message");
            try unknown_message.session.set("absent");
            unknown_message.text = try testingContent(&tmp, "unknown-message", 'm', 64 * 1024);
            defer unknown_message.removeTemporaryContent(std.testing.io) catch unreachable;
            const unknown_reply = storage.submitMessageWithModel(&unknown_message, null, .{});
            try std.testing.expect(unknown_reply == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, unknown_reply.rejected.code);

            var incomplete: protocol.ConfigureCommand = .{};
            try incomplete.key.set("incomplete");
            incomplete.configuration.instructions = try testingContent(&tmp, "incomplete", 'i', 64 * 1024);
            defer incomplete.removeTemporaryContent(std.testing.io) catch unreachable;
            const incomplete_reply = storage.configure(&incomplete, .{});
            try std.testing.expect(incomplete_reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, incomplete_reply.rejected.code);

            var exhausted: protocol.ConfigureCommand = .{};
            try exhausted.key.set("exhausted");
            try exhausted.session.set(created_session_0.slice());
            exhausted.configuration.instructions = try testingContent(&tmp, "exhausted", 'e', 64 * 1024);
            defer exhausted.removeTemporaryContent(std.testing.io) catch unreachable;
            const exhausted_reply = storage.configure(&exhausted, .{});
            try std.testing.expect(exhausted_reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.revision_exhausted, exhausted_reply.rejected.code);

            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE accepted=0 AND (primary_content_id IS NOT NULL OR secondary_content_id IS NOT NULL)", .{}));

            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expect(storage.submitMessageWithModel(&unknown_message, null, .{}).rejected.replayed);
            try std.testing.expect(storage.configure(&incomplete, .{}).rejected.replayed);
            try std.testing.expect(storage.configure(&exhausted, .{}).rejected.replayed);

            var changed = unknown_message;
            changed.text.digest[0] ^= 1;
            try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
            var retargeted = incomplete;
            try retargeted.session.set("0ther0");
            try std.testing.expect(storage.configure(&retargeted, .{}) == .conflict);
            var changed_kind: protocol.MessageCommand = .{};
            try changed_kind.key.set("incomplete");
            try changed_kind.session.set("absent");
            changed_kind.text = unknown_message.text;
            try std.testing.expect(storage.submitMessageWithModel(&changed_kind, null, .{}) == .conflict);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
        }
    }.run);
}

test "model rejection diagnostic is atomic Attempt-bound provenance not Turn output" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Fault = enum { stale, import, commit };
            for ([_]Fault{ .stale, .import, .commit }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                const detail = "{\"reason\":\"UnsupportedMessagePhase\",\"stage\":\"item\",\"byte_offset\":\"37\",\"output_index\":1}";
                const request_id = if (fault == .import) "" else "request-\"quoted\"\\path";
                var failure: ModelFailure = .{ .rejected = .{ .code = "unsupported_provider_output", .diagnostic = detail, .request_id = .{}, .report = "" } };
                try failure.rejected.request_id.set(request_id);
                var binding: AttemptBinding = undefined;
                var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
                var original_content: u64 = 0;
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    session = try configureTestSession(&storage, "diagnostic-config");
                    try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
                    binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    original_content = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                    var delivered = binding;
                    if (fault == .stale) delivered.attempt_ordinal += 1;
                    try std.testing.expectError(switch (fault) {
                        .stale => error.StaleAttemptBinding,
                        .import => error.InjectedContentImportFailure,
                        .commit => error.InjectedCommitFailure,
                    }, storage.settleModelAttemptFailure(delivered, failure, .ordinary, .{
                        .content_import = fault == .import,
                        .before_commit = fault == .commit,
                    }));
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    try std.testing.expectEqual(original_content, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code IS NOT NULL OR resolution_content_id IS NOT NULL OR request_id IS NOT NULL", .{}));
                    try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
                    defer std.testing.allocator.free(bytes);
                    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer report.deinit();
                    const full = report.value.object.get("full").?.object;
                    const operation = full.get("model_operations").?.array.items[0].object;
                    const resolution = operation.get("resolution").?.object;
                    try std.testing.expect(operation.contains("request_id"));
                    if (request_id.len == 0) {
                        try std.testing.expect(operation.get("request_id").? == .null);
                    } else {
                        try std.testing.expectEqualStrings(request_id, operation.get("request_id").?.string);
                    }
                    try std.testing.expectEqualStrings("unsupported_provider_output", resolution.get("code").?.string);
                    try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
                    try std.testing.expect(full.get("turns").?.array.items[0].object.get("outcome").?.object.get("content").? == .null);
                    try std.testing.expectEqual(@as(u64, if (request_id.len == 0) 0 else 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE request_id IS NOT NULL", .{}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_output_item", .{}));
                    try expectActivityOutcome(&storage, session.slice(), binding, .failed, "unsupported_provider_output");
                }
            }
        }
    }.run);
}

test "model rejection diagnostic cannot masquerade as assistant content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Route = enum { conversation, conversation_content, activity, activity_content };
            for ([_]Route{ .conversation, .conversation_content, .activity, .activity_content }) |route| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "diagnostic-config");
                try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .rejected = .{
                    .code = "unsupported_provider_output",
                    .diagnostic = "{\"reason\":\"UnsupportedMessagePhase\"}",
                    .request_id = .{},
                    .report = "",
                } }, .ordinary, .{});
                const healthy = try store_core.publicConversationPageForTesting(&storage, .{ .session = session });
                try std.testing.expectEqual(@as(usize, 1), healthy.count);
                try std.testing.expect(healthy.items[0].kind == .user);
                const position = try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{});
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id,recorded_at) " ++
                    "SELECT o.session_ref,2,s.next_position,3,o.turn_id,o.operation_id,0,o.resolution_content_id,1 " ++
                    "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref", .{});
                try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+1", .{});
                const result: anyerror!void = switch (route) {
                    .conversation => if (store_core.publicConversationPageForTesting(&storage, .{ .session = session })) |_| {} else |err| err,
                    .activity => if (store_core.activityPageForTesting(&storage, .{ .session = session })) |_| {} else |err| err,
                    .conversation_content => if (storage.openPublicConversationContent(&.{ .session = session, .position = position })) |value| blk: {
                        var reader: ContentReader = undefined;
                        reader.open(value);
                        reader.close();
                        break :blk {};
                    } else |err| err,
                    .activity_content => if (storage.openActivityContent(&.{ .session = session, .position = position })) |value| blk: {
                        var reader: ContentReader = undefined;
                        reader.open(value);
                        reader.close();
                        break :blk {};
                    } else |err| err,
                };
                try std.testing.expectError(error.CorruptStore, result);
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "a failed Turn's activity outcome references the provider's report" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "report-config");
            const report = "cyber_policy: This request has been flagged.";
            for ([_][]const u8{ report, "" }, 0..) |words, index| {
                var key: [16]u8 = undefined;
                const message = try std.fmt.bufPrint(&key, "report-{d}", .{index});
                try submitTestMessage(&storage, &tmp, message, message, session.slice(), "work");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_policy", .request_id = .{}, .report = words } }, .ordinary, .{});
                try expectActivityOutcome(&storage, session.slice(), binding, .provider_refused, "provider_policy");
                var request: protocol.ActivityPage = .{ .direction = .backward };
                try request.session.set(session.slice());
                const outcome = (try store_core.activityPageForTesting(&storage, request)).items[0].value.turn_ended;
                if (words.len == 0) {
                    // No words, no report: never an empty one.
                    try std.testing.expect(outcome.content == null);
                } else {
                    try std.testing.expectEqual(@as(u64, words.len), outcome.content.?.length);
                    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(words), &outcome.content.?.digest);
                }
            }
        }
    }.run);
}

test "a failure whose report equals its new diagnostic saves one content row for both" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "same-words-config");
            try submitTestMessage(&storage, &tmp, "same-words-input", "same-words-message", session.slice(), "work");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const words = "provider_rejected: the same words twice";
            const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = "provider_rejected", .diagnostic = words, .request_id = .{}, .report = words } }, .ordinary, .{});
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectEqual(before + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation o JOIN turn t ON t.operation_id=o.operation_id " ++
                "WHERE o.resolution_content_id IS NOT NULL AND o.resolution_content_id=t.outcome_content_id", .{}));
        }
    }.run);
}

test "retryable stream rejections retain only the settling Attempt diagnostic through reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const diagnostic = "{\"reason\":\"TemporaryProviderFailure\",\"stage\":\"event\",\"byte_offset\":\"6\",\"output_index\":null}";
            var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                session = try configureTestSession(&storage, "stream-retry-config");
                try submitTestMessage(&storage, &tmp, "stream-input", "stream-message", session.slice(), "retry");
                var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                for (1..5) |ordinal| {
                    try std.testing.expectEqual(@as(u64, ordinal), binding.attempt_ordinal);
                    var request_id: protocol.Bounded(256) = .{};
                    try request_id.set(if (ordinal == 4) "last-request" else "earlier-request");
                    try storage.settleModelAttemptFailure(binding, .{ .rejected = .{
                        .code = "provider_temporary_error",
                        .diagnostic = if (ordinal == 4) diagnostic else "earlier diagnostic",
                        .request_id = request_id,
                        .report = if (ordinal == 4) "server_is_overloaded: Try again later." else "earlier words",
                    } }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
                    if (ordinal < 4) {
                        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_content_id IS NOT NULL OR request_id IS NOT NULL", .{}));
                        try store_testing.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL", .{});
                        binding = (try admitRetryForTesting(&storage)).?.permit.binding;
                    }
                }
            }
            var reopened: Store = undefined;
            try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
            defer reopened.close() catch unreachable;
            const bytes = try testingSessionReportWithProfile(&reopened, &tmp, session.slice(), 64 * 1024, .full);
            defer std.testing.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            const operation = parsed.value.object.get("full").?.object.get("model_operations").?.array.items[0].object;
            try std.testing.expectEqualStrings("last-request", operation.get("request_id").?.string);
            const resolution = operation.get("resolution").?.object;
            try std.testing.expectEqualStrings("retry_exhausted", resolution.get("code").?.string);
            try std.testing.expectEqualStrings(diagnostic, resolution.get("content").?.object.get("text").?.string);
            // The Turn keeps the settling Attempt's report, the provider's own words.
            const outcome = parsed.value.object.get("full").?.object.get("turns").?.array.items[0].object.get("outcome").?.object;
            try std.testing.expectEqualStrings("retry_exhausted", outcome.get("code").?.string);
            const words = "server_is_overloaded: Try again later.";
            const reference = outcome.get("content").?.object;
            try std.testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{words.len}), reference.get("bytes").?.string);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(protocol.contentDigest(words), .lower), reference.get("sha256").?.string);
        }
    }.run);
}

test "retry settlement adds actual entropy after the provider deadline" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "jitter-config");
            try submitTestMessage(&storage, &tmp, "jitter-input", "jitter-message", session.slice(), "retry");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const Fixed = struct {
                fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    return .{ .nanoseconds = 31_000_000_000 };
                }
                fn random(_: ?*anyopaque, bytes: []u8) void {
                    const draw: u64 = 499;
                    @memcpy(bytes, std.mem.asBytes(&draw));
                }
            };
            var vtable = std.testing.io.vtable.*;
            vtable.now = Fixed.now;
            vtable.random = Fixed.random;
            storage.io.vtable = &vtable;
            defer storage.io = std.testing.io;
            try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{
                .waits_ms = retry_policy.default_waits_ms,
                .retry_after_ms = 7_000,
                .retry_after_deadline_ms = 40_000,
            } }, .{});
            try std.testing.expectEqual(@as(u64, 40_500), try store_testing.queryU64(&storage, "SELECT retry_due_at_ms FROM model_operation", .{}));
            try std.testing.expect((try admitRetryForTesting(&storage)) == null);
        }
    }.run);
}

test "content readers hold no decode window" {
    try std.testing.expect(@sizeOf(ContentReader) <= 512);
    try std.testing.expect(@sizeOf(HistoricalReader) <= 1024);
}

test "activity fixed admission prefix survives later application and stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "activity-config");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const empty = try store_core.activityPageForTesting(&storage, request);
            try submitTestMessage(&storage, &tmp, "activity-a", "a", session.slice(), "same");
            try submitTestMessage(&storage, &tmp, "activity-b", "b", session.slice(), "same");
            const queued = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), queued.count);
            try std.testing.expect(queued.items[0].value.admission.admission != queued.items[1].value.admission.admission);
            try std.testing.expect(queued.items[0].value.admission.turn == null);
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            _ = try admitted.permit.consume();
            var stop = try completeSessionStop("activity-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expectActivityOutcome(&storage, session.slice(), admitted.permit.binding, .stopped, "cancelled");
            request.end = queued.end;
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), frozen.count);
            try std.testing.expect(frozen.items[0].value.admission.state == .queued and frozen.items[0].value.admission.turn == null);
            request.end = empty.end;
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
        }
    }.run);
}

test "a page's rows share their rounds, so a full page takes as many as one row" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "rounds-config");
            try submitTestMessage(&storage, &tmp, "rounds-input", "message", session.slice(), "run tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Seventeen calls in one group: every page below is full.
            var calls: [17]TestingCall = undefined;
            var names: [17][16]u8 = undefined;
            for (&calls, &names, 0..) |*call, *name, index| {
                const id = try std.fmt.bufPrint(name, "rounds-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "rounds-output", &calls);
            var conversation: protocol.ConversationPage = .{};
            try conversation.session.set(session.slice());
            var activity: protocol.ActivityPage = .{};
            try activity.session.set(session.slice());
            const full = try pageRounds(&storage, &conversation, &activity);
            try std.testing.expectEqual(@as(usize, 16), full.conversation);
            try std.testing.expectEqual(@as(usize, 16), full.activity);
            // Smaller pages of the same kinds: the first Tool Result and the User
            // entry before it; the rows through the first call.
            conversation = .{ .session = conversation.session, .end = full.end, .before_position = full.results, .before_ordinal = 2 };
            activity.end = try store_testing.queryU64(&storage, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3", .{});
            const small = try pageRounds(&storage, &conversation, &activity);
            try std.testing.expectEqual(@as(usize, 2), small.conversation);
            try std.testing.expect(small.activity < 16);
            try std.testing.expectEqual(small.rounds, full.rounds);
        }
    }.run);
}

const PageRounds = struct { rounds: [2]u32, conversation: usize, activity: usize, results: u64, end: u64 };

/// The rounds each page read takes, with its row counts and the positions
/// its caller bounds smaller pages with.
fn pageRounds(storage: *Store, conversation: *const protocol.ConversationPage, activity: *const protocol.ActivityPage) !PageRounds {
    var result: PageRounds = undefined;
    var public_page: reads_domain.PublicConversationPage = undefined;
    var activity_page: protocol.ActivityFacts = undefined;
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        try reads_domain.publicConversationPage(&a, conversation, &public_page);
        result.rounds[0] = storage.testing_content_work.rounds - before;
    }
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        const before = storage.testing_content_work.rounds;
        try reads_domain.activityPage(&a, activity, &activity_page);
        result.rounds[1] = storage.testing_content_work.rounds - before;
    }
    result.conversation = public_page.count;
    result.activity = activity_page.count;
    result.results = public_page.items[0].position;
    result.end = public_page.end;
    return result;
}

test "the tool-group scan answers a missing Proposal as main did, before its outcome" {
    // The scan reads a call's Proposal and outcome in one round; main read
    // the Proposal first, so neither row answers ContentNotFound.
    try std.testing.expectError(error.ContentNotFound, historical_domain.scannedCall(&.{ .position = 7 }, null, 1, 0));
}

test "an activity page reports the queued Messages at its end, until applied or stopped" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "queued-config");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            try std.testing.expectEqual(@as(protocol.Queued, .{}), (try store_core.activityPageForTesting(&storage, request)).queued);
            try submitTestMessage(&storage, &tmp, "queued-a", "a", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "queued-b", "b", session.slice(), "second");
            const waiting = try store_core.activityPageForTesting(&storage, request);
            const first = waiting.items[0];
            const second = waiting.items[1];
            try std.testing.expectEqual(@as(protocol.Queued, .{ .count = 2, .oldest_position = first.position, .newest_admission = second.value.admission.admission, .newest_position = second.position }), waiting.queued);
            // Taken at an input boundary: none waits at the latest end, both still
            // do at the earlier one.
            var admitted = (try storage.admitNextModelAttempt(.{})).?;
            _ = try admitted.permit.consume();
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).queued.count);
            var frozen = request;
            frozen.end = waiting.end;
            try std.testing.expectEqual(waiting.queued, (try store_core.activityPageForTesting(&storage, frozen)).queued);
            // One sent behind the work waits until a stop excludes it.
            try submitTestMessage(&storage, &tmp, "queued-c", "c", session.slice(), "third");
            const behind = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(u64, 1), behind.queued.count);
            try std.testing.expectEqual(behind.end, behind.queued.oldest_position);
            try std.testing.expectEqual(behind.end, behind.queued.newest_position);
            var stop = try completeSessionStop("queued-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).queued.count);
            frozen.end = behind.end;
            try std.testing.expectEqual(behind.queued, (try store_core.activityPageForTesting(&storage, frozen)).queued);
        }
    }.run);
}

test "every activity row is dated by the fact that owns it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "dated-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "dated-answer", &answer);
            try submitTestMessage(&storage, &tmp, "dated-input", "dated-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "dated-calls");
            var stop = try completeSessionStop("dated-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            // Distinct times name the owning fact of each row. Tool Result entries
            // are recorded too, but a result row is dated by its group's last
            // acceptance.
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=101;" ++
                "UPDATE conversation_entry SET recorded_at=CASE entry_kind WHEN 1 THEN 102 WHEN 3 THEN 103 ELSE 109 END;" ++
                "UPDATE model_operation SET resolved_at=104;" ++
                "UPDATE action_operation SET resolved_at=CASE call_ordinal WHEN 0 THEN 105 ELSE 106 END;" ++
                "UPDATE turn SET outcome_at=107;" ++
                "UPDATE session_stop SET stopped_at=108", .{});
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            var seen: std.EnumSet(std.meta.Tag(protocol.ActivityItem.Value)) = .empty;
            for (page.items[0..page.count]) |item| {
                const expected: u64 = switch (item.value) {
                    .admission => 101,
                    .user => 102,
                    .assistant => 103,
                    .call => 104,
                    .tool_result => 106,
                    .turn_ended => 107,
                    .stop => 108,
                    // Asked when its call was made.
                    .approval_requested => 104,
                    .hosted_call, .sent, .send_failed, .received, .session_changed, .compacted => unreachable,
                };
                try std.testing.expectEqual(expected, item.at);
                seen.insert(item.value);
            }
            try std.testing.expectEqual(@as(usize, 8), seen.count());
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a call made while the Session asks follows with its approval request, and one under bypass has none" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_][]const u8{ "ask", "bypass" }) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionWithMode(&storage, "approval-config", mode);
                try submitTestMessage(&storage, &tmp, "approval-input", "approval-input", session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, "approval-calls");
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const page = try store_core.activityPageForTesting(&storage, request);
                var calls: usize = 0;
                var approvals: usize = 0;
                for (page.items[0..page.count], 0..) |item, index| switch (item.value) {
                    .call => calls += 1,
                    .approval_requested => |approval| {
                        approvals += 1;
                        // It sits right after its call, at the call's position.
                        const call = page.items[index - 1];
                        try std.testing.expectEqual(call.position, item.position);
                        try std.testing.expectEqual(@as(u64, 1), item.ordinal);
                        try std.testing.expectEqual(call.value.call.action.?, approval.action);
                        try std.testing.expectEqual(call.value.call.operation, approval.operation);
                        try std.testing.expectEqual(call.value.call.call_ordinal, approval.call_ordinal);
                    },
                    else => {},
                };
                try std.testing.expectEqual(@as(usize, 2), calls);
                try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, mode, "ask")) 2 else 0), approvals);
                // A page of approval requests alone names each by its own row.
                request.kinds = .initOne(.approval_requested);
                const only = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(approvals, only.count);
                // Backward, from the end, the same rows come in reverse.
                request.kinds = .full;
                request.direction = .backward;
                const backward = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(page.count, backward.count);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "a Tool Result is dated by its group's last acceptance, even when the clock stepped back" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "stepped-config");
            try submitTestMessage(&storage, &tmp, "stepped-input", "stepped-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "stepped-calls");
            var stop = try completeSessionStop("stepped-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            // The clock stepped back between the two acceptances: the later one,
            // at the greater position, carries the earlier time.
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(DISTINCT acceptance_position) FROM action_operation", .{}));
            const latest_acceptance = try store_testing.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try store_testing.exec(&storage, "UPDATE action_operation SET resolved_at=" ++
                "CASE WHEN acceptance_position=?1 THEN 100 ELSE 200 END", .{latest_acceptance});
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            var results: usize = 0;
            for (page.items[0..page.count]) |item| if (item.value == .tool_result) {
                try std.testing.expectEqual(@as(u64, 100), item.at);
                results += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), results);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

pub fn denyForTesting(storage: *Store, session: []const u8, key: []const u8, action_id: u64) !void {
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .deny };
    try deny.key.set(key);
    try deny.session.set(session);
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
}

test "queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            for ([_]enum { behind_the_turn, after_the_outcome }{ .behind_the_turn, .after_the_outcome }) |case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "stepped-queue-config");
                switch (case) {
                    // Queued behind the active Turn, which then fails: pending from
                    // the outcome, though the clock read earlier than at admission.
                    .behind_the_turn => {
                        try submitTestMessage(&storage, &tmp, "stepped-queue-first", "stepped-queue-first", session.slice(), "first");
                        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                        var diagnostic: [512]u8 = undefined;
                        const quota: @import("../transport_policy.zig").Quota = .{ .refusal = .quota, .resets_at = 1792940000 };
                        try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
                        try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=200 WHERE command_key='stepped-queue-input';UPDATE turn SET outcome_at=100", .{});
                    },
                    // Admitted after the outcome: pending from the admission, though
                    // the clock read earlier than at the outcome.
                    .after_the_outcome => {
                        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                        try answerTestTurn(&storage, &tmp, session.slice(), "stepped-queue-answer", &answer);
                        try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                        try store_testing.exec(&storage, "UPDATE turn SET outcome_at=200;UPDATE message_admission SET admitted_at=100 WHERE command_key='stepped-queue-input'", .{});
                    },
                }
                try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, session.slice(), "pending"));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "tool label observation trusts admission over damaged call field bytes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "label-config");
                try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
                var request: protocol.ActivityPage = .{};
                try request.session.set(session.slice());
                const before = try store_core.activityPageForTesting(&storage, request);
                // Damage only the call fields' bytes, not the accepted references or
                // their metadata. Lightweight observations do not read those bytes.
                try store_testing.zeroContent(&storage, "SELECT arguments_content_id FROM model_tool_call");
                const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                defer std.testing.allocator.free(report);
                try std.testing.expect(std.mem.indexOf(u8, report, "Run first command") != null);
                const after = try store_core.activityPageForTesting(&storage, request);
                try std.testing.expectEqual(before.call_activity.total, after.call_activity.total);
                for (before.call_activity.entries[0..before.call_activity.count], after.call_activity.entries[0..after.call_activity.count]) |original, observed| {
                    try std.testing.expectEqualStrings(original.presentation.description.?.slice(), observed.presentation.description.?.slice());
                    try std.testing.expectEqual(original.presentation.code, observed.presentation.code);
                }
                // Model replay, not label observation, authenticates field bytes.
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "completed tool labels trust admission while model replay authenticates payload" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "replay-config");
            try submitTestMessage(&storage, &tmp, "replay-input", "replay-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "replay-calls");
            var stop = try completeSessionStop("replay-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            const before = try store_core.publicConversationPageForTesting(&storage, request);
            try store_testing.zeroContent(&storage, "SELECT name_content_id FROM model_tool_call");
            const after = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(before.count, after.count);
            var results: usize = 0;
            for (before.items[0..before.count], after.items[0..after.count]) |original, observed| {
                if (original.presentation) |presentation| {
                    results += 1;
                    try std.testing.expectEqualStrings(presentation.description.?.slice(), observed.presentation.?.description.?.slice());
                    try std.testing.expectEqual(presentation.code, observed.presentation.?.code);
                }
            }
            try std.testing.expectEqual(@as(usize, 2), results);
            try submitTestMessage(&storage, &tmp, "replay-next", "replay-next", session.slice(), "continue");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(next, &view);
            defer view.close();
            // Discovery trusts the labels; the first call's name fences when it is
            // read for replay.
            const first = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, first.kind);
            const call = (try nextTestingItem(&view, first.position)).?;
            try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3", .{}), call.position);
            const name = (try view.openOutput(call.position)).call.?[0];
            var reader: HistoricalReader = undefined;
            try view.openContent(name, &reader);
            defer reader.close();
            var buffer: [4096]u8 = undefined;
            try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(name.length)]));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "live tool activity survives completed Turns and split result pages" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "live-config");
            try submitTestMessage(&storage, &tmp, "live-input", "input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var identities: [20][24]u8 = undefined;
            var calls: [20]TestingCall = undefined;
            for (&calls, &identities, 0..) |*call, *identity, index| {
                const id = try std.fmt.bufPrint(identity, "live-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "live-calls", &calls);
            var stop = try completeSessionStop("live-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(page.more);
            for (page.items[0..page.count]) |item| try std.testing.expect(item.value != .tool_result);
            try std.testing.expectEqual(@as(u64, 20), page.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
            for (page.call_activity.entries, 0..) |entry, index| {
                try std.testing.expectEqual(binding.operation_id, entry.operation);
                try std.testing.expectEqual(index, entry.ordinal);
                try std.testing.expect(entry.presentation.code == .unknown_tool);
            }
            const last = page.items[page.count - 1];
            request.end = page.end;
            request.position = last.position;
            request.ordinal = last.ordinal;
            const split = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(split.more);
            try std.testing.expectEqual(@as(u64, 10), split.call_activity.total);
            try std.testing.expectEqual(@as(u64, 10), split.call_activity.entries[0].ordinal);
            const split_last = split.items[split.count - 1];
            request.position = split_last.position;
            request.ordinal = split_last.ordinal;
            const finished = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expect(!finished.more);
            try std.testing.expectEqual(@as(u64, 0), finished.call_activity.total);
            request.position = 0;
            request.ordinal = null;
            request.direction = .backward;
            try std.testing.expectEqual(@as(u64, 0), (try store_core.activityPageForTesting(&storage, request)).call_activity.total);

            // Fixed history boundaries cannot suppress newer live calls.
            try submitTestMessage(&storage, &tmp, "live-new", "new", session.slice(), "propose again");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, next, "live-new-calls");
            request.direction = .forward;
            request.position = finished.end;
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), frozen.count);
            try std.testing.expectEqual(@as(u64, 2), frozen.call_activity.total);
            try std.testing.expectEqual(next.operation_id, frozen.call_activity.entries[0].operation);
        }
    }.run);
}

test "live tool activity counts calls past the sixteenth Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "ops-config");
            try submitTestMessage(&storage, &tmp, "ops-input", "input", session.slice(), "propose");
            // One call per Operation, so the count spans more Operations than a
            // read bounded by the page's 16 rows would reach.
            var first: u64 = 0;
            for (0..32) |index| {
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (index == 0) first = binding.operation_id;
                var identity: [24]u8 = undefined;
                const id = try std.fmt.bufPrint(&identity, "ops-{d}", .{index});
                var prefix: [24]u8 = undefined;
                const calls = [_]TestingCall{.{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" }};
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "ops-calls-{d}", .{index}), &calls);
            }
            var stop = try completeSessionStop("ops-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.activityPageForTesting(&storage, request);
            // The page shows the first Operations' items; activity counts the
            // calls whose groups are published after its last item.
            const after = try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE acceptance_position>?1", .{page.items[page.count - 1].position});
            try std.testing.expect(after > 16);
            try std.testing.expectEqual(after, page.call_activity.total);
            try std.testing.expectEqual(@as(usize, 3), page.call_activity.count);
            try std.testing.expect(page.call_activity.entries[0].operation > first);
        }
    }.run);
}

test "the Current report's resolved and rejected calls carry their group's publication" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "publication-config");
            try submitTestMessage(&storage, &tmp, "publication-input", "input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{
                    .item_id = "publication-item-0",
                    .name = "bash",
                    .encoded_call_id = "publication-call-0",
                    .decoded_call_id = "publication-call-0",
                    .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
                    .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
                },
                .{ .item_id = "publication-item-1", .name = "other", .encoded_call_id = "publication-call-1", .decoded_call_id = "publication-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, binding, "publication-calls", &calls);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation", .{}), .decision = .allow_once };
            try allow.key.set("publication-allow");
            try allow.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            const group = try store_testing.queryU64(&storage, "SELECT max(acceptance_position) FROM action_operation", .{});
            try std.testing.expect(group > try store_testing.queryU64(&storage, "SELECT acceptance_position FROM model_tool_call WHERE rejection_code IS NOT NULL", .{}));

            const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer report.deinit();
            const resolved = report.value.object.get("actions").?.object.get("resolved").?.array.items;
            const rejected = report.value.object.get("rejected_calls").?.object.get("items").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), resolved.len);
            try std.testing.expectEqual(@as(usize, 1), rejected.len);
            var expected: [20]u8 = undefined;
            const position = try std.fmt.bufPrint(&expected, "{d}", .{group});
            for ([_]std.json.Value{ resolved[0], rejected[0] }) |row| {
                const published = row.object.get("presentation").?.object.get("publication_position").?;
                try std.testing.expectEqualStrings(position, switch (published) {
                    .string => |text| text,
                    else => return error.TestUnexpectedResult,
                });
            }
        }
    }.run);
}

test "compaction overflow admits a new Operation without losing applied input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "compact-config");
            try submitTestMessage(&storage, &tmp, "compact-input", "input", session.slice(), "keep all input");
            const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const detail = "{\"reason\":\"ContextOverflow\",\"stage\":\"response\",\"byte_offset\":\"0\",\"output_index\":null}";
            var failure: ModelFailure = .{ .rejected = .{ .code = "context_overflow", .diagnostic = detail, .request_id = .{}, .report = "" } };
            try failure.rejected.request_id.set("compact-overflow-request");
            try storage.settleModelAttemptFailure(original, failure, .context_overflow, .{});
            const next = (try storage.admitNextModelAttempt(.{})) orelse return error.MissingCompaction;
            try std.testing.expect(next.permit.binding.operation_id != original.operation_id);
            try std.testing.expectEqual(original.turn_id, next.permit.binding.turn_id);
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next.permit.binding));
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(next.permit.binding, &view);
            defer view.close();
            try std.testing.expectEqual(ModelOperationKind.compaction, (try testSettings(&view)).operation);
            try std.testing.expect((try view.coverage()).anchor == null);
            const input = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
            try std.testing.expect((try nextTestingItem(&view, input.position)) == null);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
            defer std.testing.allocator.free(bytes);
            var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer report.deinit();
            const resolution = report.value.object.get("full").?.object.get("model_operations").?.array.items[0].object.get("resolution").?.object;
            try std.testing.expectEqualStrings("context_overflow", resolution.get("code").?.string);
            try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
            try std.testing.expectEqual(original.operation_id, try store_testing.queryU64(&storage, "SELECT operation_id FROM model_operation WHERE request_id='compact-overflow-request' AND resolution_code='context_overflow' AND last_failure_code='context_overflow'", .{}));
        }
    }.run);
}

pub fn readTestingContent(view: *HistoricalView, content: HistoricalContent, out: *std.Io.Writer) !void {
    var reader: HistoricalReader = undefined;
    try view.openContent(content, &reader);
    defer reader.close();
    var bytes: [256]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try reader.read(offset, &bytes);
        if (count == 0) break;
        try out.writeAll(bytes[0..count]);
        offset += count;
    }
}

/// Renders a historical entry as the Store holds it: a user entry's text,
/// an earlier Operation's effort (`operation.high`), or an output item's
/// kind, bag, call fields and parts (`array.kind=text{bag}`).
pub fn renderTestingEntry(view: *HistoricalView, entry: HistoricalEntry, buffer: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    if (entry.kind == .operation) {
        try out.print("operation.{s}", .{if (entry.effort) |effort| @tagName(effort) else "default"});
        return out.buffered();
    }
    if (entry.kind != .provider_output) {
        try readTestingContent(view, entry.content.?, &out);
        return out.buffered();
    }
    const output = try view.openOutput(entry.position);
    try out.writeAll(@tagName(output.kind));
    if (output.phase != .unphased) try out.print(".{s}", .{@tagName(output.phase)});
    try out.writeByte('{');
    if (output.bag) |bag| try readTestingContent(view, bag, &out);
    try out.writeByte('}');
    if (output.call) |fields| for (fields) |field| {
        try out.writeByte('|');
        try readTestingContent(view, field, &out);
    };
    while (try view.nextOutputPart()) |part| {
        try out.print("|{s}.{s}=", .{ @tagName(part.array), @tagName(part.kind) });
        if (part.text) |text| try readTestingContent(view, text, &out);
        if (part.bag) |bag| {
            try out.writeByte('{');
            try readTestingContent(view, bag, &out);
            try out.writeByte('}');
        }
    }
    return out.buffered();
}

pub const TestingHistoryCursor = struct {
    position: u64 = 0,

    pub fn next(self: *@This(), view: *HistoricalView) !?HistoricalEntry {
        const entry = try nextTestingItem(view, self.position);
        if (entry) |item| self.position = item.position;
        return entry;
    }
};

/// The next history entry after `after` that is no earlier Operation's
/// effort boundary: the history these tests check, without the boundaries
/// the codec places between it (tested on their own).
fn nextTestingItem(view: *HistoricalView, after: u64) !?HistoricalEntry {
    var position = after;
    while (try view.nextEntry(position)) |entry| {
        if (entry.kind != .operation) return entry;
        position = entry.position;
    }
    return null;
}

test "compaction success retains host inputs and ordered anchor suffix across reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "compact-config");
            try submitTestMessage(&storage, &tmp, "compact-input", "input", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try submitTestMessage(&storage, &tmp, "compact-arrival", "arrival", session.slice(), "later");
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{.message}));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .function_call }));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .compaction }));
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, compact, &.{ .compaction, .web_search_call }));
            try std.testing.expect(!storage.isFenced());
            try settleCompactionForTesting(&storage, &tmp, compact, &.{ .reasoning, .compaction, .message });
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            try std.testing.expectEqual(@as(usize, 1), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).action_count);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            // Accepted compaction message items remain private, without a required
            // assistant Conversation entry, across every public inventory on reopen.
            try std.testing.expectEqual(@as(usize, 1), (try store_core.publicConversationPageForTesting(&storage, request)).count);
            const activity = try store_core.activityPageForTesting(&storage, .{ .session = request.session });
            for (activity.items[0..activity.count]) |item| try std.testing.expect(item.value != .assistant);
            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            var parsed_report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer parsed_report.deinit();
            for (parsed_report.value.object.get("full").?.object.get("conversation").?.array.items) |entry|
                try std.testing.expect(!std.mem.eql(u8, "assistant", entry.object.get("kind").?.string));
            const compaction_message = try store_testing.queryU64(&storage, "SELECT session_position FROM model_output_item WHERE item_kind=2", .{});
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = compaction_message }));
            try std.testing.expect(!storage.isFenced());
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(compact.turn_id, successor.turn_id);
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
            {
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(successor, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_][]const u8{
                    "original",
                    "reasoning{\"id\":\"reasoning-0\",\"summary\":[],\"encrypted_content\":\"opaque\"}",
                    "compaction{\"id\":\"compaction-1\",\"encrypted_content\":\"opaque\"}",
                    "message{\"id\":\"message-2\"}|content.output_text=",
                    "later",
                }, 0..) |expected, index| {
                    const entry = (try cursor.next(&view)).?;
                    if (index == 2) try std.testing.expectEqual(anchor, entry.position);
                    var bytes: [512]u8 = undefined;
                    try std.testing.expectEqualStrings(expected, try renderTestingEntry(&view, entry, &bytes));
                }
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            // New applied input permits one new compaction; its unchanged successor
            // must terminalize irreducible overflow rather than loop.
            try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const second_base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, second_base, &.{.compaction});
            const exhausted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(exhausted, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user }) |kind|
                    try std.testing.expectEqual(kind, (try cursor.next(&view)).?.kind);
                try std.testing.expectEqual(anchor, (try cursor.next(&view)).?.position);
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            try storage.settleModelAttemptFailure(exhausted, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
            // Recovery eligibility changes the Turn outcome, never the failure fact.
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE resolution_code='context_overflow'", .{}));
            const observation = try storage.observeCommand("input");
            try std.testing.expectEqualStrings("ResourceExceeded", observation.message.?.queue.?.state.failed.code.slice());
        }
    }.run);
}

test "explicit compaction thresholds and frozen retry survive reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Representative reasoning models, plus unlisted bindings below.
            const supported_ids = [_][]const u8{ "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5" };
            for (supported_ids ++ [_][]const u8{ "model-a", "gpt-6-luna-alias" }) |model| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try completeConfiguration("config", "", workspace, model);
                // D111: the client supplies tokens even when it chooses 90%.
                const expected: ?u64 = model_capability.contextWindow(model) * product_defaults.compaction_trigger_percent / 100;
                var threshold: [20]u8 = undefined;
                try configure.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&threshold, "{d}", .{expected.?}));
                const created_session_0_reply = storage.configure(&configure, .{});
                try std.testing.expect(created_session_0_reply == .accepted);
                const created_session_0 = created_session_0_reply.accepted.session;
                const initial = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(expected, initial.compaction_trigger);
                try std.testing.expectEqual(@as(u64, 0), initial.output_reservation);
                try std.testing.expect(initial.compaction_trigger_override == expected and initial.output_reservation_override == null);
                try submitTestMessage(&storage, &tmp, "one", "one", created_session_0.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("override");
                try patch.session.set(created_session_0.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("10");
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("8");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                const selected = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(@as(?u64, 10), selected.compaction_trigger_override);
                try std.testing.expectEqual(@as(?u64, 8), selected.output_reservation_override);
                try storage.close();
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
                try std.testing.expectEqual(first.operation_id, retry.operation_id);
                {
                    var view: HistoricalView = undefined;
                    try storage.openHistoricalView(retry, &view);
                    defer view.close();
                    var frozen: HistoricalSettings = undefined;
                    try view.settings(&frozen);
                    try std.testing.expectEqual(expected, frozen.compaction_trigger);
                    try std.testing.expectEqual(@as(u64, 0), frozen.output_reservation);
                }
                try patch.key.set("inherit");
                patch.configuration.compaction_trigger.state = .explicit_null;
                patch.configuration.output_reservation.state = .explicit_null;
                const refused_clear = storage.configure(&patch, .{});
                try std.testing.expect(refused_clear == .rejected);
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, refused_clear.rejected.code);
                try patch.key.set("explicit-threshold");
                patch.configuration.compaction_trigger = configure.configuration.compaction_trigger;
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                const reset = try storage.inspectSessionForTesting(created_session_0.slice());
                try std.testing.expectEqual(expected, reset.compaction_trigger);
                try std.testing.expectEqual(@as(u64, 0), reset.output_reservation);
                try std.testing.expect(reset.compaction_trigger_override == expected and reset.output_reservation_override == null);
                {
                    const report = try testingSessionReportWithProfile(&storage, &tmp, created_session_0.slice(), 1024 * 1024, .full);
                    defer std.testing.allocator.free(report);
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"output_reservation_override\":null") != null);
                    // D111: revision one records the client's explicit threshold.
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":null") == null);
                    try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":\"10\",\"output_reservation\":\"8\"") != null);
                }
                try storage.settleModelAttemptFailure(retry, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compact));
                try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                // Overflow recovery compacts once; unchanged context cannot
                // authorize another compaction.
                try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try expectActivityOutcome(&storage, created_session_0.slice(), successor, .context_full, "ResourceExceeded");
            }
        }
    }.run);
}

/// The Current report's `context_estimate`, or null.
fn testingContextEstimate(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?u64 {
    const report = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(report);
    const key = "\"context_estimate\":";
    const at = (std.mem.indexOf(u8, report, key) orelse return error.TestUnexpectedResult) + key.len;
    if (std.mem.startsWith(u8, report[at..], "null,")) return null;
    const end = std.mem.indexOfScalarPos(u8, report, at + 1, '"') orelse return error.TestUnexpectedResult;
    return try std.fmt.parseInt(u64, report[at + 1 .. end], 10);
}

test "compaction exact threshold zero reservation and integer usage fallback" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_][]const u8{
                "{\"input_tokens\":999,\"output_tokens\":0}",
                "{\"input_tokens\":1000,\"output_tokens\":0}",
                "{\"input_tokens\":1000.5,\"output_tokens\":0}",
                "{\"input_tokens\":1000e0,\"output_tokens\":0}",
                "{\"input_tokens\":-1000,\"output_tokens\":0}",
                "{\"input_tokens\":0,\"output_tokens\":0}",
                "{\"input_tokens\":18446744073709551616,\"output_tokens\":0}",
                "{\"input_tokens\":1000000,\"output_tokens\":0}",
                "{\"input_tokens\":9223372036854775807,\"output_tokens\":0}",
                "{\"input_tokens\":9223372036854775807,\"output_tokens\":9223372036854775807}",
                "{\"input_tokens\":1000,\"input_tokens_details\":{\"cached_tokens\":600},\"output_tokens\":0}",
            }, 0..) |usage, index| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                // An unlisted model without an override compacts at the share of
                // the small window Rui assumes for it.
                if (index == 7) patch.configuration.compaction_trigger.state = .omitted;
                patch.configuration.output_reservation.state = .value;
                try patch.configuration.output_reservation.value.set("0");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                // A Session's first call never compacts, so nothing is compared.
                try std.testing.expectEqual(@as(?u64, null), try testingContextEstimate(&storage, &tmp, session.slice()));
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "");
                try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &.{}, .{}, usage);
                if (index == 9) {
                    // The counts are stored as reported; their sum passes SQLite's
                    // signed range, and pressure saturates instead of wrapping.
                    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), try store_testing.queryU64(&storage, "SELECT usage_output_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                }
                if (index == 10) {
                    try std.testing.expectEqual(@as(u64, 400), try store_testing.queryU64(&storage, "SELECT usage_uncached_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                    try std.testing.expectEqual(@as(u64, 600), try store_testing.queryU64(&storage, "SELECT usage_cache_read_tokens FROM model_operation WHERE output_item_count IS NOT NULL", .{}));
                }
                // The Current report's estimate is the pressure the next admission
                // compares: at or past the trigger exactly when it compacts.
                const compacts = index == 1 or index >= 7;
                const estimate = (try testingContextEstimate(&storage, &tmp, session.slice())).?;
                const trigger: u64 = if (index == 7) model_capability.compactionPolicy("model-a", null, null).compaction_trigger else 1000;
                try std.testing.expectEqual(compacts, estimate >= trigger);
                if (index == 0) try std.testing.expectEqual(@as(u64, 999), estimate);
                if (index == 7) try std.testing.expectEqual(@as(u64, 1000000), estimate);
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(if (compacts) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
                // The call after a compaction answers whatever the pressure, so
                // nothing is compared while one runs.
                if (compacts) try std.testing.expectEqual(@as(?u64, null), try testingContextEstimate(&storage, &tmp, session.slice()));
            }
        }
    }.run);
}

test "compaction pressure uses the latest accepted output even without usage" {
    try store_testing.forEachEngine(struct {
        fn run(store_case: *store_testing.Case) !void {
            for ([_]struct { usage: ?[]const u8, usable: bool }{
                .{ .usage = null, .usable = false },
                .{ .usage = "{\"total_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"total_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1}", .usable = false },
                .{ .usage = "{\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":null}", .usable = false },
                .{ .usage = "{\"input_tokens\":null,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":-1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":9223372036854775808}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1}", .usable = true },
                .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999}", .usable = false },
                .{ .usage = "{\"total_tokens\":1.5,\"input_tokens\":0,\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":2,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":2}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":null,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":null,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":null}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1.5,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":1.5}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens\":1,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_tokens\":1}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_\\u0074okens\":2,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1,\"output_\\u0074okens\":2}", .usable = false },
                .{ .usage = "{\"input_tokens\":99999,\"input_tokens\":99999,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":99999,\"output_tokens\":99999}", .usable = false },
                .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999,\"input_tokens\":null,\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":99999,\"total_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":1},\"output_tokens\":0}", .usable = true },
                .{ .usage = "{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens\":0}", .usable = false },
                .{ .usage = "{\"input_tokens\":0,\"details\":{\"input_tokens\":99999,\"output_tokens\":99999},\"output_tokens\":0}", .usable = true },
            }) |case| {
                for ([_]enum { host_input, provider_output, small }{ .host_input, .provider_output, .small }) |context| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(store_case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try configureTestSession(&storage, "config");
                    var patch: protocol.ConfigureCommand = .{};
                    try patch.key.set("heuristics");
                    try patch.session.set(session.slice());
                    patch.configuration.compaction_trigger.state = .value;
                    try patch.configuration.compaction_trigger.value.set("1000");
                    try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                    const original: [4000]u8 = @splat('x');
                    try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), if (context == .host_input) &original else "small input");
                    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                    try settleCallsForTestingWithFaults(&storage, &tmp, first, "older-output", &calls, .{}, "{\"input_tokens\":1,\"output_tokens\":0}");
                    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "small suffix");
                    const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(second));
                    var latest_calls = calls;
                    if (context == .provider_output) {
                        latest_calls[0].encoded_arguments = &original;
                        latest_calls[0].decoded_arguments = &original;
                    }
                    try settleCallsForTestingWithFaults(&storage, &tmp, second, "latest-output", &latest_calls, .{}, case.usage);
                    try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "small suffix");
                    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expectEqual(if (case.usable or context == .small) ModelOperationKind.assistant_response else ModelOperationKind.compaction, try storage.modelOperationKind(next));
                }
            }
        }
    }.run);
}

test "compaction soft trigger freezes settings before selecting arrivals and instructions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "pending");
            const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(compact, &view);
            defer view.close();
            var frozen: HistoricalSettings = undefined;
            try view.settings(&frozen);
            try std.testing.expectEqual(ModelOperationKind.compaction, frozen.operation);
            try std.testing.expectEqual(@as(u64, 1), frozen.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 1), frozen.output_reservation);
            try std.testing.expect((try view.coverage()).anchor == null);
            const input = (try nextTestingItem(&view, 0)).?;
            try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
            try std.testing.expect((try nextTestingItem(&view, input.position)) == null);
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            try patch.key.set("updated-heuristics");
            try patch.configuration.compaction_trigger.value.set("999");
            try patch.configuration.output_reservation.value.set("8");
            patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", "later instruction");
            defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), (try testSettings(&view)).compaction_trigger);
            try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "arrival");
            try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var later: HistoricalView = undefined;
            try storage.openHistoricalView(successor, &later);
            defer later.close();
            var settings: HistoricalSettings = undefined;
            try later.settings(&settings);
            try std.testing.expectEqual(ModelOperationKind.assistant_response, settings.operation);
            try std.testing.expectEqual(@as(u64, 999), settings.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 8), settings.output_reservation);
            var cursor: TestingHistoryCursor = .{};
            const anchor = (try later.coverage()).anchor.?;
            for ([_]HistoricalEntryKind{ .user, .provider_output, .user, .user, .instruction }) |kind| {
                const entry = (try cursor.next(&later)).?;
                try std.testing.expectEqual(kind, entry.kind);
                if (kind == .provider_output) try std.testing.expectEqual(anchor, entry.position);
            }
            try std.testing.expect((try cursor.next(&later)) == null);
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            const replay = storage.configure(&patch, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            var omitted: protocol.ConfigureCommand = .{};
            try omitted.key.set("omitted-heuristics");
            try omitted.session.set(session.slice());
            try std.testing.expect(storage.configure(&omitted, .{}) == .accepted);
            const observed = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(@as(u64, 999), observed.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 8), observed.output_reservation);
            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(report);
            try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":\"999\",\"context_estimate\":\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, report, "\",\"output_reservation\":\"8\"") != null);
            for ([_][]const u8{ "0", "", "-1", "9223372036854775808", "+1", "1.5", "1_000", " 1", "١" }, 0..) |invalid, index| {
                var invalid_patch: protocol.ConfigureCommand = .{};
                var key: [32]u8 = undefined;
                try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-heuristic-{d}", .{index}));
                try invalid_patch.session.set(session.slice());
                invalid_patch.configuration.compaction_trigger.state = .value;
                try invalid_patch.configuration.compaction_trigger.value.set(invalid);
                const rejected = storage.configure(&invalid_patch, .{});
                try std.testing.expect(rejected == .rejected);
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, rejected.rejected.code);
                try std.testing.expectEqual(observed.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
                if (!std.mem.eql(u8, invalid, "0")) {
                    try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-reserve-{d}", .{index}));
                    invalid_patch.configuration.compaction_trigger.state = .omitted;
                    invalid_patch.configuration.output_reservation.state = .value;
                    try invalid_patch.configuration.output_reservation.value.set(invalid);
                    const reserve_rejected = storage.configure(&invalid_patch, .{});
                    try std.testing.expect(reserve_rejected == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_output_reservation, reserve_rejected.rejected.code);
                    try std.testing.expectEqual(observed.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
                }
            }
        }
    }.run);
}

test "compaction failed and unresolved candidates preserve the accepted base" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{ .reasoning, .compaction, .message });
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
            const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(assistant, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const candidate = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(candidate, &view);
                defer view.close();
                var cursor: TestingHistoryCursor = .{};
                const anchor = (try view.coverage()).anchor.?;
                for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user }, 0..) |kind, index| {
                    const entry = (try cursor.next(&view)).?;
                    try std.testing.expectEqual(kind, entry.kind);
                    if (index == 2) try std.testing.expectEqual(anchor, entry.position);
                }
                try std.testing.expect((try cursor.next(&view)) == null);
            }
            try std.testing.expectError(error.InvalidProviderEnvelope, settleCompactionForTesting(&storage, &tmp, candidate, &.{}));
            try storage.settleModelAttemptFailure(candidate, .{ .uncorrelated = "bad_compaction" }, .ordinary, .{});
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "new turn");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(next, &view);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            const anchor = (try view.coverage()).anchor.?;
            for ([_]HistoricalEntryKind{ .user, .provider_output, .provider_output, .provider_output, .user, .user }, 0..) |kind, index| {
                const entry = (try cursor.next(&view)).?;
                try std.testing.expectEqual(kind, entry.kind);
                if (index == 2) try std.testing.expectEqual(anchor, entry.position);
            }
            try std.testing.expect((try cursor.next(&view)) == null);
        }
    }.run);
}

test "compaction selected newest base corruption fences rather than using an older base" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]enum { payload, anchor, tail }{ .payload, .anchor, .tail }) |corruption| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
                const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(assistant, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const newest = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, newest, &.{ .compaction, .message });
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const newest_operation = try store_testing.queryU64(&storage, "SELECT max(operation_id) FROM model_output_item", .{});
                switch (corruption) {
                    .anchor => try store_testing.exec(&storage, "DELETE FROM model_output_item WHERE operation_id=?1 AND item_kind=4", .{newest_operation}),
                    .tail => try store_testing.exec(&storage, "DELETE FROM model_output_item WHERE operation_id=?1 AND item_kind=2", .{newest_operation}),
                    .payload => try store_testing.zeroContent(&storage, "SELECT extras_content_id FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4"),
                }
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(next, &view);
                defer view.close();
                if (corruption != .payload) {
                    try std.testing.expectError(error.CorruptStore, view.coverage());
                } else {
                    const anchor = (try view.coverage()).anchor.?;
                    const selected = (try nextTestingItem(&view, anchor - 1)).?;
                    try std.testing.expectEqual(anchor, selected.position);
                    var reader: HistoricalReader = undefined;
                    try view.openContent((try view.openOutput(selected.position)).bag.?, &reader);
                    defer reader.close();
                    var bytes: [4096]u8 = undefined;
                    try std.testing.expectError(error.CorruptStore, reader.read(0, &bytes));
                }
                try std.testing.expect(storage.isFenced());
            }
        }
    }.run);
}

test "compaction repeated overflow consumes fixed pending prefix without a proactive loop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |with_base| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (with_base) {
                    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                    const assistant = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    // A new bound input after the base makes another recovery necessary.
                    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "bound suffix");
                    try settleCompactionForTesting(&storage, &tmp, assistant, &.{.reasoning});
                    const suffix = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try storage.settleModelAttemptFailure(suffix, .{ .uncorrelated = "network" }, .ordinary, .{});
                } else {
                    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "network" }, .ordinary, .{});
                }
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "fixed pending prefix");
                const proactive = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(proactive));
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                try storage.settleModelAttemptFailure(proactive, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
                try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const recovery = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(recovery));
                try storage.settleModelAttemptFailure(recovery, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
                try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                const observation = try storage.observeCommand("pending");
                try std.testing.expectEqualStrings("ResourceExceeded", observation.message.?.queue.?.state.failed.code.slice());
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "compaction does not repeat a soft trigger after a failed assistant with unchanged source" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
            const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "network_failure" }, .ordinary, .{});
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "new pending input");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
            try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
        }
    }.run);
}

test "compaction missing usage estimates covered retained host input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]?[]const u8{
                null,
                "{\"total_tokens\":1.5}",
                "{\"input_tokens\":1}",
                "{\"input_tokens\":1,\"output_tokens\":1.5}",
                "{\"input_tokens\":1,\"input_tokens\":null,\"output_tokens\":0}",
                "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":1}",
            }) |usage| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("heuristics");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                const original: [4000]u8 = @splat('x');
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), &original);
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, base, &.{.compaction});
                const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
                const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
                try settleCallsForTestingWithFaults(&storage, &tmp, successor, "usage", &calls, .{}, usage);
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "small suffix");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next));
            }
        }
    }.run);
}

test "compaction new Turn evaluates pressure independently of stopped overflow recovery" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |stop_compaction| {
                for ([_]bool{ false, true }) |pressure| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const session = try configureTestSession(&storage, "config");
                    try submitTestMessage(&storage, &tmp, "original", "original", session.slice(), "retain original input");
                    const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    if (stop_compaction) {
                        const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compact));
                    }
                    var stop = try completeSessionStop("stop", session.slice());
                    const stopped = storage.stopSession(&stop, .{});
                    try std.testing.expect(stopped == .accepted);
                    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, stopped.accepted.completion);
                    try storage.close();
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

                    var patch: protocol.ConfigureCommand = .{};
                    try patch.key.set("pressure");
                    try patch.session.set(session.slice());
                    patch.configuration.compaction_trigger.state = .value;
                    try patch.configuration.compaction_trigger.value.set(if (pressure) "1" else "1000000");
                    try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                    try submitTestMessage(&storage, &tmp, "new", "new", session.slice(), "new work");
                    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expect(next.turn_id != original.turn_id);
                    try std.testing.expectEqual(if (pressure) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
                    try std.testing.expectEqual(@as(u64, if (pressure) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                }
            }
        }
    }.run);
}

test "compaction purpose admission fences a missing latest Turn Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "original input");
            const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            try store_testing.exec(&storage, "UPDATE turn SET operation_id=99999", .{});
            try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "new input");
            try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "saved Turn outcomes read back as the outcome that closed the Turn" {
    const Saved = struct { code: []const u8, content_id: ?i64, tag: TurnOutcome.Tag };
    // The on-disk codes are the Store format; readers branch on the tag.
    const saved = [_]Saved{
        .{ .code = "completed", .content_id = 7, .tag = .completed },
        .{ .code = "cancelled", .content_id = null, .tag = .cancelled },
        .{ .code = "retry_exhausted", .content_id = null, .tag = .retry_exhausted },
        .{ .code = "ResourceExceeded", .content_id = null, .tag = .resource_exceeded },
        .{ .code = "ResourceExceeded", .content_id = 10, .tag = .resource_exceeded },
        .{ .code = "retry_exhausted", .content_id = 8, .tag = .retry_exhausted },
        .{ .code = "provider_http_401", .content_id = null, .tag = .failed },
        .{ .code = "provider_policy", .content_id = 9, .tag = .failed },
    };
    for (saved) |row| {
        const outcome = try TurnOutcome.decode(row.code, row.content_id);
        try std.testing.expectEqual(row.tag, std.meta.activeTag(outcome));
        try std.testing.expectEqualStrings(row.code, outcome.code());
        try std.testing.expectEqual(row.content_id, outcome.content());
    }
    try std.testing.expectEqual(@as(i64, 7), (try TurnOutcome.decode("completed", 7)).completed);
    // A completed Turn saves its answer and a failure may save its report;
    // a cancelled one saves no content, and every outcome saves a code.
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("completed", null));
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("cancelled", 7));
    try std.testing.expectError(error.CorruptStore, TurnOutcome.decode("", null));
}

test "a web search call shows as its line, in the conversation and the activity, at its own position" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "search-config");
            try submitTestMessage(&storage, &tmp, "search-input", "search-key", session.slice(), "what changed?");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleItemsForTesting(&storage, &tmp, binding, &.{
                "{\"type\":\"web_search_call\",\"id\":\"ws1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"zig\\n0.17 \\\"notes\\\"\"}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws2\",\"status\":\"failed\",\"action\":{\"type\":\"open_page\",\"url\":\"https://www.ziglang.org/x\"}}",
                "{\"type\":\"web_search_call\",\"id\":\"ws3\",\"action\":{\"type\":\"find_in_page\",\"url\":\"ziglang.org\",\"pattern\":\"Io\"}}",
                "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}",
            }, "done");
            const expected = [_]struct { []const u8, protocol.ToolPresentation.Code }{
                .{ "Find “Io” in ziglang.org", .succeeded },
                .{ "Open ziglang.org/x", .failed },
                .{ "Search “zig 0.17 \"notes\"”", .succeeded },
            };
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            const page = try store_core.publicConversationPageForTesting(&storage, request);
            // Newest first: the answer, the three calls in reverse, the Message.
            try std.testing.expectEqual(@as(usize, 5), page.count);
            try std.testing.expect(page.items[0].kind == .assistant);
            for (page.items[1..4], expected, 0..) |item, want, index| {
                try std.testing.expect(item.kind == .hosted_call);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
                try std.testing.expectEqual(page.items[0].position - 1 - index, item.position);
                try std.testing.expectEqualStrings(want[0], item.presentation.?.description.?.slice());
                try std.testing.expectEqual(want[1], item.presentation.?.code);
                try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
            }
            try std.testing.expect(page.items[4].kind == .user);
            // A cursor may stop at a call, and the page goes on from there.
            request.end = page.end;
            request.before_position = page.items[2].position;
            const older = try store_core.publicConversationPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), older.count);
            try std.testing.expectEqualStrings(expected[2][0], older.items[0].presentation.?.description.?.slice());
            // A call has no content to read.
            try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 0 }));

            const activity = try store_core.activityPageForTesting(&storage, .{ .session = request.session, .direction = .backward });
            var calls: usize = 0;
            for (activity.items[0..activity.count]) |item| if (item.value == .hosted_call) {
                const want = expected[calls];
                try std.testing.expectEqual(page.items[1 + calls].position, item.position);
                try std.testing.expectEqualStrings(want[0], item.value.hosted_call.description.?.slice());
                try std.testing.expectEqual(want[1], item.value.hosted_call.code);
                calls += 1;
            };
            try std.testing.expectEqual(@as(usize, 3), calls);
            try std.testing.expectError(error.ContentNotFound, storage.openActivityContent(&.{ .session = request.session, .position = page.items[1].position, .ordinal = 0 }));
        }
    }.run);
}

/// The rounds one list page takes over a Store of `count` Sessions, each
/// whose work reads its deepest stages: an answered Turn, then a queued
/// Message a stop excluded.
fn listRoundsForTesting(case: *store_testing.Case, count: usize) !u32 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    inline for (0..protocol.session_list_page_size) |index| if (index < count) {
        const name = std.fmt.comptimePrint("list-rounds-{d}", .{index});
        const session = try configureTestSession(&storage, name);
        try answerTestTurn(&storage, &tmp, session.slice(), name ++ "-answer", &answer);
        try submitTestMessage(&storage, &tmp, name ++ "-queued-file", name ++ "-queued", session.slice(), "excluded");
        var stop = try completeSessionStop(name ++ "-stop", session.slice());
        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    };
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
    try capture.create(root[0..length], 1, false);
    defer capture.deinit();
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: reads_domain.ReadAccess = .open(&entry);
    defer a.deinit();
    const before = storage.testing_content_work.rounds;
    try report_domain.renderSessionList(&a, &.{}, &capture);
    const rounds = storage.testing_content_work.rounds - before;
    var report = try capture.seal();
    defer report.deinit();
    var bytes: [8192]u8 = undefined;
    const read = try report.read(0, bytes[0..@intCast(@min(report.length, bytes.len))]);
    // Every shown row's work went through its stop.
    try std.testing.expectEqual(count, std.mem.count(u8, bytes[0..read], "\"kind\":\"stopped\""));
    return rounds;
}

test "a list page's rows share their rounds, so eight rows take as many as one" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // The page; its rows' latest Turns and first-Message seeks; then the
            // stop cutoff, the queue after it, the excluded Message and its stop;
            // then the rows themselves.
            try std.testing.expectEqual(@as(u32, 7), try listRoundsForTesting(case, 1));
            try std.testing.expectEqual(@as(u32, 7), try listRoundsForTesting(case, protocol.session_list_page_size));
        }
    }.run);
}

test "a list row's failed Actions read answers main's ActionReadFailed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "list-actions-config");
            try submitTestMessage(&storage, &tmp, "list-actions-input", "list-actions-message", session.slice(), "call");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const call = [_]TestingCall{.{ .item_id = "list-actions-item", .name = "bash", .encoded_call_id = "list-actions-call", .decoded_call_id = "list-actions-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
            try settleCallsForTesting(&storage, &tmp, binding, "list-actions-output", &call);
            try store_testing.failReadsOf(&storage, "action_operation");
            var used = std.atomic.Value(u64).init(0);
            try std.testing.expectError(error.ActionReadFailed, testingSessionList(&storage, &tmp, .{}, &used, 5));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "an .each visitor supplies storage for a big Row through decoded" {
    const Big = struct { bytes: [1025]u8 };
    const Small = struct { id: u64 };
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Small, struct { count: u8 }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: Big }));
    try std.testing.expectEqual(@as(?[]const u8, null), comptime store_access.eachVisitorError(Big, struct { decoded: *Big }));
    try std.testing.expectEqualStrings("rsql: an .each Row over 1 KiB decodes into its visitor's own decoded field", comptime store_access.eachVisitorError(Big, struct { count: u8 }).?);
    try std.testing.expectEqualStrings("rsql: a visitor's decoded field is the Row or *Row its .each read decodes, " ++ @typeName(Small), comptime store_access.eachVisitorError(Small, struct { decoded: Big }).?);
}

/// The rendered text of the one statement the failure table `named`
/// holds whose text holds `fragment`, among those it names `failed` when
/// that is not null.
pub fn namedStatementForTesting(comptime named: anytype, comptime failed: ?anyerror, comptime fragment: []const u8) [:0]const u8 {
    @setEvalBranchQuota(200_000);
    comptime var found: ?[:0]const u8 = null;
    inline for (named) |pair| {
        if (comptime (failed == null or pair[1] == failed.?) and std.mem.indexOf(u8, pair[0].sql, fragment) != null) {
            if (found != null and !std.mem.eql(u8, found.?, pair[0].sql)) @compileError("two statements hold " ++ fragment);
            found = pair[0].sql;
        }
    }
    return found orelse @compileError("no statement holds " ++ fragment);
}

/// A Session in each work shape the list and report read: no Message, a
/// finished Turn, a queued Message a stop excluded, and a Turn awaiting
/// a permission decision.
pub const TestingWorkShape = enum {
    idle,
    finished,
    stopped,
    awaiting,

    pub fn make(shape: TestingWorkShape, storage: *Store, tmp: *std.testing.TmpDir, comptime name: []const u8) !protocol.Bounded(protocol.max_session_bytes) {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
        switch (shape) {
            .idle => return configureTestSession(storage, name),
            .finished, .stopped => {
                const session = try configureTestSession(storage, name);
                try answerTestTurn(storage, tmp, session.slice(), name ++ "-answer", &answer);
                if (shape == .stopped) {
                    try submitTestMessage(storage, tmp, name ++ "-queued-file", name ++ "-queued", session.slice(), "excluded");
                    var stop = try completeSessionStop(name ++ "-stop", session.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                }
                return session;
            },
            .awaiting => {
                const session = try configureTestSessionAsk(storage, name);
                try submitTestMessage(storage, tmp, name ++ "-message-file", name ++ "-message", session.slice(), "call");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const call = [_]TestingCall{.{ .item_id = name ++ "-item", .name = "bash", .encoded_call_id = name ++ "-call", .decoded_call_id = name ++ "-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
                try settleCallsForTesting(storage, tmp, binding, name ++ "-metadata", &call);
                return session;
            },
        }
    }
};

/// The rounds a Current report takes for a Session of `shape`.
fn reportRoundsForTesting(case: *store_testing.Case, shape: TestingWorkShape) !u32 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try shape.make(&storage, &tmp, "report-rounds");
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
    try capture.create(root[0..length], 1, false);
    defer capture.deinit();
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var a: reads_domain.ReadAccess = .open(&entry);
    defer a.deinit();
    const before = storage.testing_content_work.rounds;
    try std.testing.expect(try report_domain.renderHead(&a, session.slice(), .current, &capture));
    return storage.testing_content_work.rounds - before;
}

/// One tool cycle of the cost fixture: a Message whose Operation proposes
/// two Bash calls and an unknown one; one call is allowed and runs, one
/// denied, the unknown one rejected; the continuation answers.
pub fn costCycleForTesting(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, index: usize) !void {
    var name: [64]u8 = undefined;
    var key: [64]u8 = undefined;
    try submitTestMessage(storage, tmp, try std.fmt.bufPrint(&name, "cycle-{d}-input", .{index}), try std.fmt.bufPrint(&key, "cycle-{d}-key", .{index}), session, "list the files, then summarize");
    const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-a", .name = "bash", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{\\\"description\\\":\\\"List files\\\",\\\"cmd\\\":\\\"ls -la\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"List files\",\"cmd\":\"ls -la\",\"timeout_ms\":null}" },
        .{ .item_id = "item-b", .name = "bash", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = "{\\\"description\\\":\\\"Remove files\\\",\\\"cmd\\\":\\\"rm -rf x\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Remove files\",\"cmd\":\"rm -rf x\",\"timeout_ms\":null}" },
        .{ .item_id = "item-c", .name = "unknown", .encoded_call_id = "call-c", .decoded_call_id = "call-c", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(storage, tmp, binding, try std.fmt.bufPrint(&name, "cycle-{d}-calls", .{index}), &calls);
    const first_action = try store_testing.queryU64(storage, "SELECT max(action_id)-1 FROM action_operation", .{});
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = first_action, .decision = .allow_once };
    try allow.key.set(try std.fmt.bufPrint(&key, "cycle-{d}-allow", .{index}));
    try allow.session.set(session);
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    try denyForTesting(storage, session, try std.fmt.bufPrint(&key, "cycle-{d}-deny", .{index}), first_action + 1);
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    _ = try storage.settleActionAttempt(action, .succeeded, "total 8\ndrwxr-xr-x 2 user user 4096 a\n-rw-r--r-- 1 user user 120 b\n", .{});
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Two files; the removal was denied.\"}]}"};
    try settleItemsForTesting(storage, tmp, continued, &items, "Two files; the removal was denied.");
}

test "a Current report takes its reads' dependency depth in rounds, not its rows" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Every shape: the saved Session; the facts' first round, with the
            // work's and compaction facts' latest Turn; the pending count with
            // their second stages; then the recent Messages. Idle and finished
            // work reads the queue after the cutoff in a fourth round; stopped
            // work then the excluded Message and its stop.
            try std.testing.expectEqual(@as(u32, 5), try reportRoundsForTesting(case, .idle));
            try std.testing.expectEqual(@as(u32, 5), try reportRoundsForTesting(case, .finished));
            try std.testing.expectEqual(@as(u32, 7), try reportRoundsForTesting(case, .stopped));
            // Awaiting work ends with its Actions in the third round; its Action
            // adds the unresolved, resolved and actionable lists, and with no
            // rejected call there is no rejected list.
            try std.testing.expectEqual(@as(u32, 7), try reportRoundsForTesting(case, .awaiting));
        }
    }.run);
}

/// `session`'s Full history rendered alone, on an Access of its own, as
/// `renderFull` follows the Current facts, inside `{"head":0...}` so it
/// parses. The bytes are the caller's; `rounds` gets the rounds
/// `renderFull` ran, not its `readRaw` windows.
pub fn testingFullHistory(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, rounds: ?*u32) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 8 * 1024 * 1024 } };
    try capture.create(root[0..length], 1, false);
    defer capture.deinit();
    {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: reads_domain.ReadAccess = .open(&entry);
        defer a.deinit();
        try capture.append("{\"head\":0");
        const before = storage.testing_content_work.rounds;
        try report_domain.renderFull(&a, session, &capture);
        try capture.append("}");
        if (rounds) |out| out.* = storage.testing_content_work.rounds - before;
    }
    var report = try capture.seal();
    defer report.deinit();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(report.length));
    errdefer std.testing.allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) offset += try report.read(offset, bytes[offset..@min(bytes.len, offset + SessionReport.read_window_bytes)]);
    return bytes;
}

/// A list whose statement fails at its first row's step.
const FailingList = struct {
    pub const S = rsql.Page(.{
        .arms = &.{.{ .on = .{ .index = "turn_session_latest" }, .alias = "t", .columns = "abs(-9223372036854775808+0*t.turn_id) AS failing" }},
        .Row = struct { turn_id: rsql.Positive, failing: u64 },
        .take = 256,
    });
    pub const failed = error.TurnReadFailed;
    pub const header = "],\"failing\":[";
    pub const kept_rows = 0;

    pub fn render(_: *reads_domain.ReadAccess, _: *report_domain.SessionReportCapture, _: *const S.Row) error{}!void {}
};

fn expectListError(comptime L: type, comptime prefix: []const u8) !void {
    const message = comptime report_domain.listError(L).?;
    try std.testing.expectEqualStrings(prefix, message[0..@min(prefix.len, message.len)]);
}

test "a Full list declares its statement, header and render, and each group of hooks whole, and nothing else" {
    const Stray = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const header = FailingList.header;
        pub const kept_rows = 0;
        pub const render = FailingList.render;
        pub const chunk_limit = 4;
    };
    const Half = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const header = FailingList.header;
        pub const kept_rows = 0;
        pub const render = FailingList.render;
        pub const State = struct {};
    };
    const Hidden = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const header = FailingList.header;
        pub const kept_rows = 0;
        pub const render = FailingList.render;
        pub const State = struct {};
        fn check(_: *State, _: *const S.Row) error{}!void {}
    };
    const Missing = struct {
        pub const S = FailingList.S;
        pub const failed = FailingList.failed;
        pub const kept_rows = 0;
        pub const render = FailingList.render;
    };
    try std.testing.expect(comptime report_domain.listError(FailingList) == null);
    try expectListError(Stray, "a Full list declares only its statement, failed, header, kept_rows, render and its hooks, not chunk_limit: ");
    try expectListError(Half, "a Full list declares all of a group of hooks or none: check in ");
    // `@hasDecl` sees a private `check` only from its own file, so here
    // the group is incomplete; report.zig's own test covers a private hook.
    try expectListError(Hidden, "a Full list declares all of a group of hooks or none: check in ");
    try expectListError(Missing, "a Full list declares pub header: ");
}

test "Full history answers a list's first check before a later list's failed step in its round" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // Conversation's first read finds an assistant message without its
            // entry, and in the same round the list after it fails its step: main
            // checked the entries before it read any later list.
            for ([_]bool{ false, true }) |check| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "first-check-config");
                const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
                try answerTestTurn(&storage, &tmp, session.slice(), "first-check", &answer);
                if (check) try store_testing.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
                var root: [protocol.max_store_bytes]u8 = undefined;
                const length = try tmp.dir.realPath(std.testing.io, &root);
                var used = std.atomic.Value(u64).init(0);
                var capture: report_domain.SessionReportCapture = .{ .io = std.testing.io, .writer = null, .budget = .{ .used = &used, .limit = 1024 * 1024 } };
                try capture.create(root[0..length], 1, false);
                defer capture.deinit();
                const entry = try store_core.enter(&storage, .none);
                defer entry.release();
                var a: reads_domain.ReadAccess = .open(&entry);
                defer a.deinit();
                try std.testing.expectError(
                    if (check) error.CorruptStore else error.TurnReadFailed,
                    report_domain.renderRun(&a, .{ report_domain.Conversation, FailingList }, session.slice(), &capture),
                );
            }
        }
    }.run);
}

test "Full Conversation refuses an accepted assistant message without its entry" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "assistant-entry-config");
                const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
                try answerTestTurn(&storage, &tmp, session.slice(), "assistant-entry", &answer);
                if (fault) {
                    try store_testing.exec(&storage, "DELETE FROM conversation_entry WHERE entry_kind=3", .{});
                    try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
                } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
            }
        }
    }.run);
}

test "Full history refuses content whose bytes no longer match their digest" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |fault| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSessionAsk(&storage, "digest-config");
                // Longer than one content window, so the digest spans windows.
                const text: [2100]u8 = @splat('d');
                try submitTestMessage(&storage, &tmp, "digest-message", "digest-message", session.slice(), &text);
                if (fault) {
                    try store_testing.zeroContent(&storage, "SELECT content_id FROM message_admission WHERE command_key='digest-message'");
                    try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
                } else std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full));
            }
        }
    }.run);
}

test "Full history takes a round per chunk" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "history-rounds-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "hello", .decoded = "hello" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "history-rounds", &answer);
            var rounds: u32 = 0;
            const content_before = storage.testing_content_work.content_rounds;
            std.testing.allocator.free(try testingFullHistory(&storage, &tmp, session.slice(), &rounds));
            // Every list fits one chunk, so the rounds are the reads' depth: one
            // for the revisions, whose one revision's empty instructions read no
            // content, then one per run of `renderFull`: Messages; Conversation,
            // Turns and Operations; calls; Actions; decisions, stops,
            // interruptions and results. A run's lists share a round because
            // every list but its last renders all its rows in the pass.
            try std.testing.expectEqual(@as(u32, 1 + 5), rounds);
            // The Message's and the answer's content are content rounds,
            // which differ by engine: on SQLite a `readRaw` window each.
            const content_rounds: u16 = switch (case.engine) {
                .sqlite, .mysql => 2,
            };
            try std.testing.expectEqual(content_rounds, storage.testing_content_work.content_rounds - content_before);
        }
    }.run);
}

test "Full revision queries bound the rows MySQL must drain after a streaming stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "revision-drain");
            for (2..9) |revision| {
                var key: [32]u8 = undefined;
                var change: protocol.ConfigureCommand = .{};
                try change.key.set(try std.fmt.bufPrint(&key, "revision-drain-{d}", .{revision}));
                try change.session.set(session.slice());
                change.configuration.instructions = try testingBytesContent(&tmp, key[0..change.key.len], key[0..change.key.len]);
                try std.testing.expect(storage.configure(&change, .{}) == .accepted);
            }
            const Rows = struct {
                count: usize = 0,
                valid: bool = true,
                after: report_domain.full_revisions.Args,
                decoded: report_domain.full_revisions.Row = undefined,

                pub fn visit(rows: *@This(), row: *const report_domain.full_revisions.Row) bool {
                    const next = report_domain.full_revisions.next(rows.after, row) orelse {
                        rows.valid = false;
                        return false;
                    };
                    rows.after = next;
                    rows.count += 1;
                    return true;
                }
            };
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            // Consume the SQL result, not just RevisionChunk's prefix: this
            // includes every row the MySQL server must compute and send even
            // when the renderer stops at the first owned nonempty content.
            // Test both the initial query and a seek after a streaming stop.
            for ([_]u64{ 0, 2 }) |after| {
                var rows: Rows = .{ .after = .{ .session = session.slice(), .revision = after } };
                a.readEach(report_domain.full_revisions, rows.after, 256 + 1, &rows);
                try a.run();
                try std.testing.expect(rows.valid);
                try std.testing.expectEqual(@as(usize, 3), rows.count);
            }
        }
    }.run);
}

test "Full revisions show each content whole where it first occurs" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // `mixed`: new, older and repeated content, an output schema that is
            // none, the instructions or other content. `same`: one older content
            // throughout. `grown`: `mixed` with more than 512 distinct values.
            const Shape = enum { mixed, same, grown };
            const capacity = 1024;
            for ([_]Shape{ .mixed, .same, .grown }, [_]usize{ 70, 130, capacity * 2 }) |shape, revisions| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                // Content another Session admitted first is older than this
                // Session's.
                const other = try configureTestSessionAsk(&storage, "owners-other");
                const session = try configureTestSessionAsk(&storage, "owners-session");
                const texts = try std.testing.allocator.alloc([32]u8, 4 * capacity);
                defer std.testing.allocator.free(texts);
                const lengths = try std.testing.allocator.alloc(usize, 4 * capacity);
                defer std.testing.allocator.free(lengths);
                // Text 0 is the first revision's empty instructions.
                lengths[0] = 0;
                for (1..11) |index| {
                    lengths[index] = (try std.fmt.bufPrint(&texts[index], "{{\"title\":\"old {d}\"}}", .{index})).len;
                    var key: [48]u8 = undefined;
                    var reconfigure: protocol.ConfigureCommand = .{};
                    try reconfigure.key.set(try std.fmt.bufPrint(&key, "owners-other-{d}", .{index}));
                    try reconfigure.session.set(other.slice());
                    reconfigure.configuration.instructions = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-other-i-{d}", .{index}), texts[index][0..lengths[index]]);
                    try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
                }
                // Each revision's text, as an index into `texts` (`null`: none).
                const instructions = try std.testing.allocator.alloc(?usize, revisions + 1);
                defer std.testing.allocator.free(instructions);
                const output_schema = try std.testing.allocator.alloc(?usize, revisions + 1);
                defer std.testing.allocator.free(output_schema);
                instructions[1] = 0;
                output_schema[1] = null;
                var fresh: usize = 11;
                // The texts the Session holds.
                const held = try std.testing.allocator.alloc(bool, 4 * capacity);
                defer std.testing.allocator.free(held);
                @memset(held, false);
                held[0] = true;
                var distinct: usize = 1;
                for (2..revisions + 1) |revision| {
                    instructions[revision] = if (shape == .same) 1 else switch (revision % 5) {
                        // Older content, out of id order.
                        0 => 1 + (revision * 7) % 10,
                        // An earlier revision's instructions.
                        1 => instructions[revision - 3],
                        else => blk: {
                            lengths[fresh] = (try std.fmt.bufPrint(&texts[fresh], "{{\"title\":\"fresh {d}\"}}", .{revision})).len;
                            fresh += 1;
                            break :blk fresh - 1;
                        },
                    };
                    output_schema[revision] = if (shape == .same) null else switch (revision % 3) {
                        0 => null,
                        1 => instructions[revision],
                        else => 1 + (revision * 3) % 10,
                    };
                    for ([_]?usize{ instructions[revision], output_schema[revision] }) |text| if (text) |index| if (!held[index]) {
                        held[index] = true;
                        distinct += 1;
                    };
                    var key: [48]u8 = undefined;
                    var reconfigure: protocol.ConfigureCommand = .{};
                    try reconfigure.key.set(try std.fmt.bufPrint(&key, "owners-revision-{d}", .{revision}));
                    try reconfigure.session.set(session.slice());
                    const i = instructions[revision].?;
                    reconfigure.configuration.instructions = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-i-{d}", .{revision}), texts[i][0..lengths[i]]);
                    if (output_schema[revision]) |o| {
                        reconfigure.configuration.output_schema = try testingBytesContent(&tmp, try std.fmt.bufPrint(&key, "owners-s-{d}", .{revision}), texts[o][0..lengths[o]]);
                    } else reconfigure.configuration.output_schema.state = .explicit_null;
                    try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
                }
                try std.testing.expectEqual(shape == .grown, 2 * distinct > capacity);
                const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .full);
                defer std.testing.allocator.free(full);
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full, .{});
                defer parsed.deinit();
                const listed = parsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
                try std.testing.expectEqual(revisions, listed.len);
                // Each text's first occurrence, found by walking the revisions.
                const owners = try std.testing.allocator.alloc(?report_domain.ContentOwner, 4 * capacity);
                defer std.testing.allocator.free(owners);
                @memset(owners, null);
                for (listed, 1..) |row, revision| {
                    try std.testing.expectEqualStrings(try std.fmt.allocPrint(parsed.arena.allocator(), "{d}", .{revision}), row.object.get("revision").?.string);
                    for ([_]?usize{ instructions[revision], output_schema[revision] }, [_]configuration_domain.RevisionContentField{ .instructions, .output_schema }) |text, field| {
                        const shown = row.object.get(@tagName(field)).?;
                        const index = text orelse {
                            try std.testing.expect(shown == .null);
                            continue;
                        };
                        const here: report_domain.ContentOwner = .{ .revision = revision, .field = field };
                        const owner = owners[index] orelse blk: {
                            owners[index] = here;
                            break :blk here;
                        };
                        if (owner.revision == here.revision and owner.field == here.field) {
                            try std.testing.expectEqualStrings(texts[index][0..lengths[index]], shown.object.get("text").?.string);
                        } else {
                            const reference = shown.object.get("owner").?.object;
                            try std.testing.expectEqualStrings(try std.fmt.allocPrint(parsed.arena.allocator(), "{d}", .{owner.revision}), reference.get("revision").?.string);
                            try std.testing.expectEqualStrings(@tagName(owner.field), reference.get("field").?.string);
                        }
                    }
                }
                // Owners are the Session's own: the other Session's revisions each
                // own their instructions, which this one's revisions also hold.
                const again = try testingSessionReportWithProfile(&storage, &tmp, other.slice(), 64 * 1024 * 1024, .full);
                defer std.testing.allocator.free(again);
                var reparsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, again, .{});
                defer reparsed.deinit();
                const others = reparsed.value.object.get("full").?.object.get("session_revisions").?.array.items;
                try std.testing.expectEqual(@as(usize, 11), others.len);
                for (others[1..], 1..) |row, index| {
                    try std.testing.expectEqualStrings(texts[index][0..lengths[index]], row.object.get("instructions").?.object.get("text").?.string);
                }
            }
        }
    }.run);
}

/// A Store holding one admitted Attempt, its Message's content and a seal.
pub const TestingAttempt = struct {
    binding: AttemptBinding,
    content: ContentReference,
    pub const seal: historical_domain.PrefixSeal = .{ .anchor = null, .admission_position = 1, .span_length = 0, .digest = @splat(0) };

    pub fn admit(storage: *Store, tmp: *std.testing.TmpDir) !TestingAttempt {
        const session = try configureTestSession(storage, "attempt-config");
        try submitTestMessage(storage, tmp, "attempt-input", "attempt-message", session.slice(), "work");
        return .{
            .binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding,
            .content = (try storage.observeCommand("attempt-message")).message.?.content,
        };
    }

    pub fn handoff(_: void) !void {}
};

test "a prefix seal is recorded only while its Attempt is current" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(attempt.binding, &view);
            defer view.close();
            try view.recordPrefixSeal(&TestingAttempt.seal);
            try std.testing.expectEqualDeep(TestingAttempt.seal, (try storage.prefixSealForTesting(attempt.binding)).?);
            try storage.settleModelAttemptFailure(attempt.binding, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
            var later = TestingAttempt.seal;
            later.span_length = 1;
            try std.testing.expectError(error.StaleAttemptBinding, view.recordPrefixSeal(&later));
            try std.testing.expectEqualDeep(TestingAttempt.seal, (try storage.prefixSealForTesting(attempt.binding)).?);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "an Attempt check reads no Session, and a prefix seal's Session read answers OperationReadFailed" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(attempt.binding, &view);
            defer view.close();
            // Main touched the Session in each check, so a faulted session row
            // answered SessionReadFailed there; only the seal's write reads it now.
            try store_testing.failReadsOf(&storage, "session");
            try view.checkAttempt();
            try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(attempt.binding));
            try storage.withDispatchHandoff(attempt.binding, {}, TestingAttempt.handoff);
            try std.testing.expect(!storage.isFenced());
            try std.testing.expectError(error.OperationReadFailed, view.recordPrefixSeal(&TestingAttempt.seal));
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "a content lookup's failed step answers CorruptStore, as on main" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const attempt = try TestingAttempt.admit(&storage, &tmp);
            try store_testing.failReadsOf(&storage, "content");
            try std.testing.expectError(error.CorruptStore, storage.openContent(attempt.content));
            try std.testing.expect(storage.isFenced());
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

            var permission_update: protocol.ConfigureCommand = .{};
            try permission_update.key.set("action-bypass");
            try permission_update.session.set(session.slice());
            permission_update.configuration.permission_mode.state = .value;
            try permission_update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(storage.configure(&permission_update, .{}) == .accepted);
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

test "failed control commit saves no answer after reopening" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            const session = try configureTestSession(&storage, "configure-control-rollback");
            var stop = try completeSessionStop("rollback-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{ .before_commit = true }) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try storage.close();

            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expect((try storage.observeCommand("rollback-stop")).status == .absent);
        }
    }.run);
}

test "model admission skips Sessions of a provider the Host does not serve" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("unserved", "", workspace, "model-a");
            var message: protocol.MessageCommand = .{ .configuration = settings.configuration };
            try message.key.set("unserved");
            message.text = try testingBytesContent(&tmp, "unserved-message", "wait for a Host that serves me");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            {
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = protocol.routesAll(.unserved) });
                defer storage.close() catch unreachable;
                try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
                try std.testing.expect(try storage.admitNextModelAttempt(.{}) == null);
            }
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = protocol.routesAll(.endpoint) });
            defer storage.close() catch unreachable;
            try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
        }
    }.run);
}

test "existing Store rejects a different canonical identity" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try storage.close();
            var refused: Store = undefined;
            try std.testing.expectError(
                error.WrongStoreIdentity,
                store_testing.testingStoreWith(case, &refused, &tmp, std.testing.io, .{ .identity = "/different/canonical/store" }),
            );
        }
    }.run);
}

test "RUI_TEST_REQUIRE_ENGINES names engines by exact token" {
    const Name = store_testing.EngineName;
    try std.testing.expectEqual(0, (try store_testing.parseRequiredEngines("")).count());
    const listed = try store_testing.parseRequiredEngines("postgres,mysql");
    try std.testing.expect(listed.contains(Name.mysql) and listed.contains(Name.postgres) and !listed.contains(Name.sqlite));
    try std.testing.expect((try store_testing.parseRequiredEngines("sqlite")).contains(Name.sqlite));
    for ([_][]const u8{ "mysqlx", "my", " mysql", "mysql,", ",sqlite", "postgres,,mysql", "MySQL", "oracle" }) |list| {
        try std.testing.expectError(error.UnknownRequiredEngine, store_testing.parseRequiredEngines(list));
    }
}

test "a required engine these tests do not build fails them" {
    const Name = store_testing.EngineName;
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.empty, .empty));
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.mysql }), .empty));
    try std.testing.expectEqual(Name.postgres, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.postgres }), .initOne(Name.mysql)));
    // CI's live shards list both servers; each has a test of its own here.
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.mysql, Name.postgres }), store_testing.checked_elsewhere));
}

test "a fixture's SQL is portable Rui SQL and names no SQLite mechanism" {
    inline for (store_testing.fixture_text_cases) |case| {
        const message = comptime store_testing.fixtureTextError(case.text);
        if ((message != null) != case.refused) {
            std.debug.print("fixtureTextError({s}) = {?s}\n", .{ case.text, message });
            return error.FixtureVerdictChanged;
        }
    }
    try std.testing.expectEqualStrings("fixture: 'pragma' is a SQLite mechanism; write the test in sqlite_tests.zig", comptime store_testing.fixtureTextError("DELETE FROM turn; pragma ignore_check_constraints=ON").?);
    try std.testing.expectEqualStrings("rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write", comptime store_testing.fixtureTextError("INSERT OR IGNORE INTO turn VALUES(1)").?);
}

/// The functions that enter the Store (`enter(self, ...)`), each a
/// separate transition while the Store is held, by the name the source
/// gives it (less the `Held` of a body an entry point queues).
const EntryPoint = enum {
    saveCatalog,
    saveModelFacts,
    readModelCatalogSource,
    modelFact,
    readOpenAiModelIds,
    readCatalogSet,
    readCatalogRecords,
    readCatalogText,
    configure,
    submitMessageWithModel,
    stopSession,
    interruptModel,
    decidePermission,
    observeCommand,
    commandResult,
    inspectSession,
    publicConversationPage,
    openPublicConversationContent,
    activityPage,
    searchActivity,
    openActivityContent,
    activityTool,
    captureFailedResponse,
    captureSessionReport,
    captureSessionList,
    actionContent,
    admitModelAttempt,
    admitNextActionAttempt,
    readBashExecutionInput,
    admitMcpActionAttempt,
    readMcpExecutionInput,
    revokeActionSender,
    nextCoreWork,
    nextMcpAction,
    resolveMcpAction,
    deliverAgentMessage,
    deliverChildEnding,
    deliverSessionForward,
    startAgent,
    findTools,
    stopOwedSession,
    resolveCoreCall,
    actionSupersededByStop,
    withActionDispatchHandoff,
    settleActionAttempt,
    recoverOneUncertainAction,
    tryAdmitNextModelRetry,
    operationSupersededByControl,
    withDispatchHandoff,
    claimModelAuthRefresh,
    settleModelAttemptFailure,
    recoverOneExhaustedModelAttempt,
    settleModelSuccess,
    openContentIdentity,
    readOwnedContent,
    readHistoricalSettings,
    readHistoricalEntry,
    validateHistoricalOutputsStep,
    readPrefixSeal,
    recordPrefixSeal,
    readCompactionAnchor,
    readHistoricalOutput,
    readHistoricalPart,
    readHistoricalToolResult,
    readHistoricalTool,
    readDeclaredTool,
    readProviderTool,
    checkAttempt,
};

/// Each entry point's rounds (`Access.run` and `commit`, counted in
/// `Store.testing_content_work.rounds`) on the path the round budget test
/// drives it. Content rounds (`readRaw` windows) differ by engine, so
/// `content_round_budgets` holds them apart.
const round_budgets: std.EnumArray(EntryPoint, u32) = .init(.{
    .configure = 3,
    .submitMessageWithModel = 2,
    .stopSession = 2,
    .interruptModel = 2,
    .decidePermission = 2,
    .observeCommand = 5,
    .commandResult = 1,
    .inspectSession = 3,
    .publicConversationPage = 4,
    .openPublicConversationContent = 2,
    .activityPage = 7,
    .searchActivity = 5,
    .openActivityContent = 4,
    .activityTool = 4,
    .captureFailedResponse = 1,
    .captureSessionReport = 5,
    .captureSessionList = 6,
    .actionContent = 2,
    .admitModelAttempt = 3,
    .admitNextActionAttempt = 2,
    .readBashExecutionInput = 2,
    .admitMcpActionAttempt = 2,
    .readMcpExecutionInput = 3,
    .revokeActionSender = 2,
    .nextCoreWork = 3,
    .nextMcpAction = 1,
    .resolveMcpAction = 2,
    .deliverAgentMessage = 3,
    .deliverChildEnding = 2,
    .deliverSessionForward = 2,
    .startAgent = 4,
    .findTools = 5,
    .stopOwedSession = 2,
    .resolveCoreCall = 2,
    .actionSupersededByStop = 1,
    .withActionDispatchHandoff = 1,
    .settleActionAttempt = 3,
    .recoverOneUncertainAction = 1,
    .tryAdmitNextModelRetry = 1,
    .operationSupersededByControl = 1,
    .withDispatchHandoff = 1,
    .claimModelAuthRefresh = 2,
    .settleModelAttemptFailure = 2,
    .recoverOneExhaustedModelAttempt = 1,
    .settleModelSuccess = 2,
    .openContentIdentity = 1,
    .readOwnedContent = 0,
    .readHistoricalSettings = 2,
    .readHistoricalEntry = 10,
    .validateHistoricalOutputsStep = 1,
    .readPrefixSeal = 1,
    .recordPrefixSeal = 2,
    .readCompactionAnchor = 2,
    .readHistoricalOutput = 2,
    .readHistoricalPart = 1,
    .readHistoricalToolResult = 2,
    .readHistoricalTool = 1,
    .readDeclaredTool = 1,
    .readProviderTool = 1,
    .checkAttempt = 1,
    .saveModelFacts = 3,
    .readModelCatalogSource = 1,
    .modelFact = 1,
    .readOpenAiModelIds = 1,
    // A Host's tool catalog is saved once; each later open finds it.
    .saveCatalog = 1,
    .readCatalogSet = 1,
    .readCatalogRecords = 1,
    .readCatalogText = 0,
});

/// Each entry point's content rounds (`readRaw` windows, counted in
/// `Store.testing_content_work.content_rounds`) on the same path, per
/// engine: how many windows a blob read takes depends on the engine's
/// blob access, so each engine states its own. An entry point left out
/// takes none.
fn contentRoundBudget(engine: store_testing.Engine, point: EntryPoint) u16 {
    return switch (engine) {
        // One window holds the driven content.
        .sqlite, .mysql => switch (point) {
            .readOwnedContent, .readCatalogText, .searchActivity, .findTools => 1,
            else => 0,
        },
    };
}

/// The functions that enter the Store only to serve tests, so they take
/// no round budget.
const entering_fixtures = [_][]const u8{ "prefixSealForTesting", "readSessionForTesting" };

test "every function that enters the Store has a round budget" {
    // Every Store file but its test files and wire clients;
    // import_architecture.py checks this list against src/store/.
    const sources = .{
        @embedFile("Store.zig"),
        @embedFile("access.zig"),
        @embedFile("engine.zig"),
        @embedFile("engine/Sqlite.zig"),
        @embedFile("engine/Mysql.zig"),
        @embedFile("engine/mysql_content.zig"),
        @embedFile("engine/mysql_open.zig"),
        @embedFile("engine/mysql_refusal.zig"),
        @embedFile("domain/action.zig"),
        @embedFile("domain/forward.zig"),
        @embedFile("domain/command.zig"),
        @embedFile("domain/configuration.zig"),
        @embedFile("domain/content.zig"),
        @embedFile("domain/find_tools.zig"),
        @embedFile("domain/historical.zig"),
        @embedFile("domain/history_floor.zig"),
        @embedFile("domain/model_admission.zig"),
        @embedFile("domain/model_facts.zig"),
        @embedFile("domain/model_settlement.zig"),
        @embedFile("domain/reads.zig"),
        @embedFile("domain/report.zig"),
        @embedFile("domain/report_full_shape.zig"),
        @embedFile("domain/tool_set.zig"),
        @embedFile("domain/turn.zig"),
        @embedFile("find_tools_tests.zig"),
        @embedFile("mysql_literal.zig"),
        @embedFile("mysql_row.zig"),
        @embedFile("rsql.zig"),
        @embedFile("schema.zig"),
        @embedFile("sqlite.zig"),
        @embedFile("testing.zig"),
        @embedFile("queue.zig"),
    };
    var found: std.EnumSet(EntryPoint) = .empty;
    var fixtures: [entering_fixtures.len]bool = @splat(false);
    inline for (sources) |source| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, "enter" ++ "(")) |index| : (at = index + 1) {
            if (index > 0 and (std.ascii.isAlphanumeric(source[index - 1]) or source[index - 1] == '_')) continue;
            if (std.mem.endsWith(u8, source[0..index], "fn ")) continue;
            // Every call enters with the Store it is a method of.
            if (!std.mem.startsWith(u8, source[index..], "enter" ++ "(self, ")) {
                std.debug.print("an enter call takes another first argument: {s}\n", .{source[index..][0..@min(40, source.len - index)]});
                return error.EnterWithoutSelf;
            }
            const before = source[0..index];
            const fn_at = @max(std.mem.lastIndexOf(u8, before, " fn ") orelse 0, std.mem.lastIndexOf(u8, before, "\nfn ") orelse 0) + " fn ".len;
            var end = fn_at;
            while (std.ascii.isAlphanumeric(source[end]) or source[end] == '_') end += 1;
            // The body a public entry point queues; only a test fixture
            // enters outside one, holding the Store for itself.
            const held = std.mem.endsWith(u8, source[fn_at..end], "Held");
            const name = if (held) source[fn_at .. end - "Held".len] else source[fn_at..end];
            if (!held and !std.mem.endsWith(u8, name, "ForTesting")) {
                std.debug.print("{s} enters the Store outside the queue; give it a body named {s}Held\n", .{ name, name });
                return error.EnterOutsideQueue;
            }
            if (std.mem.endsWith(u8, name, "ForTesting")) {
                const listed = for (entering_fixtures, 0..) |fixture, position| {
                    if (std.mem.eql(u8, fixture, name)) break position;
                } else {
                    std.debug.print("{s} enters the Store but is not in entering_fixtures\n", .{name});
                    return error.UnlistedFixture;
                };
                try std.testing.expect(!fixtures[listed]);
                fixtures[listed] = true;
                continue;
            }
            const point = std.meta.stringToEnum(EntryPoint, name) orelse {
                std.debug.print("{s} enters the Store but has no round budget\n", .{name});
                return error.EntryPointWithoutBudget;
            };
            try std.testing.expect(!found.contains(point));
            found.insert(point);
        }
    }
    try std.testing.expectEqual(std.enums.values(EntryPoint).len, found.count());
    for (fixtures) |seen| try std.testing.expect(seen);
}

const RoundMeter = struct {
    storage: *Store,
    rounds_before: u16 = 0,
    content_before: u16 = 0,
    shape_before: QueryShape = .{},
    measured: std.EnumArray(EntryPoint, ?Measured) = .initFill(null),

    const Measured = struct { rounds: u16, content_rounds: u16, shape: QueryShape };

    /// Actual protocol sends beside independently counted semantic work.
    /// Empty Access rounds send nothing; deferred BEGIN/SAVEPOINT share the
    /// next pass, RELEASE sends nothing, and only real controls count here.
    const QueryShape = struct {
        queries: u64 = 0,
        access_passes: u64 = 0,
        identity_passes: u64 = 0,
        content_queries: u64 = 0,
        controls: u64 = 0,
        prefix_only: u64 = 0,

        fn snapshot(storage: *Store) QueryShape {
            if (storage.engine != .mysql) return .{};
            const state = storage.engine.mysql.state;
            const shape = state.testing_shape;
            return .{
                .queries = state.connection.queries,
                .access_passes = shape.access_passes,
                .identity_passes = shape.identity_passes,
                .content_queries = shape.content_queries,
                .controls = shape.controls,
                .prefix_only = shape.prefix_only,
            };
        }

        fn since(after: QueryShape, before: QueryShape) QueryShape {
            var delta: QueryShape = undefined;
            inline for (@typeInfo(QueryShape).@"struct".field_names) |name|
                @field(delta, name) = @field(after, name) - @field(before, name);
            return delta;
        }

        fn expected(shape: QueryShape) u64 {
            return shape.access_passes + shape.identity_passes + shape.content_queries + shape.controls + shape.prefix_only;
        }
    };

    fn start(meter: *RoundMeter) void {
        meter.rounds_before = meter.storage.testing_content_work.rounds;
        meter.content_before = meter.storage.testing_content_work.content_rounds;
        meter.shape_before = QueryShape.snapshot(meter.storage);
    }

    fn stop(meter: *RoundMeter, point: EntryPoint) void {
        std.debug.assert(meter.measured.get(point) == null);
        meter.measured.set(point, .{
            .rounds = meter.storage.testing_content_work.rounds - meter.rounds_before,
            .content_rounds = meter.storage.testing_content_work.content_rounds - meter.content_before,
            .shape = QueryShape.snapshot(meter.storage).since(meter.shape_before),
        });
    }
};

test "MySQL round shape subtracts the entry baseline from every component" {
    const Shape = RoundMeter.QueryShape;
    const before: Shape = .{ .queries = 100, .access_passes = 10, .identity_passes = 4, .content_queries = 7, .controls = 12, .prefix_only = 3 };
    const after: Shape = .{ .queries = 109, .access_passes = 12, .identity_passes = 5, .content_queries = 10, .controls = 14, .prefix_only = 4 };
    const delta = after.since(before);
    try std.testing.expectEqual(@as(u64, 2), delta.access_passes);
    try std.testing.expectEqual(@as(u64, 1), delta.identity_passes);
    try std.testing.expectEqual(@as(u64, 3), delta.content_queries);
    try std.testing.expectEqual(@as(u64, 2), delta.controls);
    try std.testing.expectEqual(@as(u64, 1), delta.prefix_only);
    try std.testing.expectEqual(@as(u64, 9), delta.queries);
    try std.testing.expectEqual(delta.expected(), delta.queries);
}

/// A `start_agent` spec as the Host's check leaves it: gpt-6.1-sol at low
/// effort, `tools`, `permission_mode` and no label.
pub fn testingAgentSpec(tools: []const []const u8, permission_mode: []const u8) !protocol.Configuration {
    var spec: protocol.Configuration = .{};
    spec.model.state = .value;
    try spec.model.value.set("gpt-6.1-sol");
    spec.reasoning_effort.state = .value;
    try spec.reasoning_effort.value.set("low");
    spec.compaction_trigger.state = .value;
    try spec.compaction_trigger.value.set("100000");
    spec.tools.state = .value;
    spec.tools = try .of(tools);
    spec.permission_mode.state = .value;
    try spec.permission_mode.value.set(permission_mode);
    return spec;
}

test "each Store entry point takes its round budget on its common path" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var meter: RoundMeter = .{ .storage = &storage };
            meter.start();
            try storage.saveModelFacts(&.{.{ .id = "catalog-budget", .context_window = null, .efforts = .{}, .openai_listed = true }}, null);
            meter.stop(.saveModelFacts);
            meter.start();
            _ = try storage.readModelCatalogSource();
            meter.stop(.readModelCatalogSource);
            meter.start();
            _ = try storage.modelFact("catalog-budget");
            meter.stop(.modelFact);
            meter.start();
            const model_ids = try storage.readOpenAiModelIds(std.testing.allocator);
            defer {
                for (model_ids) |id| std.testing.allocator.free(id);
                std.testing.allocator.free(model_ids);
            }
            meter.stop(.readOpenAiModelIds);
            meter.start();
            try storage.saveCatalog(&tool_catalog.built_in);
            meter.stop(.saveCatalog);
            meter.start();
            const saved = (try storage.readCatalogSet()).?;
            meter.stop(.readCatalogSet);
            var rows: [tool_catalog.built_in.records.len]tool_set_domain.catalog_records.Row = undefined;
            meter.start();
            try std.testing.expectEqual(rows.len, try storage.readCatalogRecords(saved.tool_set_id.get(), 0, &rows));
            meter.stop(.readCatalogRecords);
            var text: [tool_catalog.bash_record.description.len]u8 = undefined;
            meter.start();
            try storage.readCatalogText(rows[0].description_id.get(), &text);
            meter.stop(.readCatalogText);
            try std.testing.expectEqualStrings(tool_catalog.bash_record.description, &text);
            try plainTurn(&storage, &tmp, &meter);
            try toolTurn(&storage, &tmp, &meter);
            try compactedTurn(&storage, &tmp, &meter);
            try coreTurn(&storage, &tmp, &meter);
            try mcpTurn(case, &meter);
            try findTurn(&storage, &tmp, &meter);
            var failed = false;
            for (std.enums.values(EntryPoint)) |point| {
                const measured = meter.measured.get(point) orelse {
                    std.debug.print("{s}: not driven\n", .{@tagName(point)});
                    failed = true;
                    continue;
                };
                if (measured.rounds != round_budgets.get(point)) failed = true;
                if (measured.content_rounds != contentRoundBudget(case.engine, point)) failed = true;
                if (case.engine == .mysql) {
                    std.testing.expectEqual(measured.shape.expected(), measured.shape.queries) catch {
                        std.debug.print("{s}: COM_QUERY shape differs\n", .{@tagName(point)});
                        failed = true;
                    };
                }
            }
            if (failed) {
                for (std.enums.values(EntryPoint)) |point| {
                    const measured = meter.measured.get(point) orelse continue;
                    std.debug.print(".{s} = {d} (budget {d}), content {d} (budget {d})\n", .{
                        @tagName(point),
                        measured.rounds,
                        round_budgets.get(point),
                        measured.content_rounds,
                        contentRoundBudget(case.engine, point),
                    });
                    if (case.engine == .mysql) std.debug.print(
                        "  COM_QUERY {d} = Access passes {d} + identity passes {d} + content queries {d} + controls {d} + prefix-only passes {d} (expected {d})\n",
                        .{
                            measured.shape.queries,
                            measured.shape.access_passes,
                            measured.shape.identity_passes,
                            measured.shape.content_queries,
                            measured.shape.controls,
                            measured.shape.prefix_only,
                            measured.shape.expected(),
                        },
                    );
                }
                return error.RoundBudgetChanged;
            }
            try std.testing.expect(!storage.isFenced());
        }

        const Launch = struct {
            fn run(_: void) !void {}
        };

        /// A Message answered with text, its result read back, a second
        /// Message interrupted, and a stop.
        fn plainTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            meter.start();
            const session = try configureTestSession(storage, "budget-plain");
            meter.stop(.configure);
            meter.start();
            try submitTestMessage(storage, tmp, "budget-plain-input", "budget-plain-key", session.slice(), "hello");
            meter.stop(.submitMessageWithModel);
            const search = try std.testing.allocator.create(protocol.ActivitySearchFacts);
            defer std.testing.allocator.destroy(search);
            var search_request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission), .limit = 1 };
            try search_request.query.set("hello");
            meter.start();
            try storage.searchActivity(&search_request, search);
            meter.stop(.searchActivity);
            try std.testing.expectEqual(@as(usize, 1), search.count);
            meter.start();
            _ = try storage.observeCommand("budget-plain-key");
            meter.stop(.observeCommand);
            meter.start();
            const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            meter.stop(.admitModelAttempt);
            meter.start();
            _ = try storage.modelOperationKind(binding);
            meter.stop(.checkAttempt);
            meter.start();
            try std.testing.expect(try storage.operationSupersededByControl(binding) == null);
            meter.stop(.operationSupersededByControl);
            meter.start();
            try storage.withDispatchHandoff(binding, {}, Launch.run);
            meter.stop(.withDispatchHandoff);
            meter.start();
            _ = try storage.claimModelAuthRefresh(binding);
            meter.stop(.claimModelAuthRefresh);
            const item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}";
            meter.start();
            try settleItemsForTesting(storage, tmp, binding, &.{item}, "hi");
            meter.stop(.settleModelSuccess);
            meter.start();
            const result = try storage.commandResult("budget-plain-key");
            meter.stop(.commandResult);
            meter.start();
            const location = try storage.openContent(result);
            meter.stop(.openContentIdentity);
            var reader: ContentReader = undefined;
            reader.open(location);
            defer reader.close();
            var bytes: [64]u8 = undefined;
            meter.start();
            try std.testing.expectEqual(2, try reader.read(0, &bytes));
            meter.stop(.readOwnedContent);
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            var page: reads_domain.PublicConversationPage = undefined;
            meter.start();
            try storage.publicConversationPage(&request, &page);
            meter.stop(.publicConversationPage);
            const answer = for (page.items[0..page.count]) |entry| {
                if (entry.kind == .assistant) break entry.position;
            } else return error.NoAnswer;
            meter.start();
            _ = try storage.openPublicConversationContent(&.{ .session = session, .position = answer });
            meter.stop(.openPublicConversationContent);

            try submitTestMessage(storage, tmp, "budget-again-input", "budget-again-key", session.slice(), "again");
            const running = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = running.turn_id, .operation_id = running.operation_id };
            try interrupt.key.set("budget-interrupt");
            try interrupt.session.set(session.slice());
            meter.start();
            try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
            meter.stop(.interruptModel);
            var stop = try completeSessionStop("budget-stop", session.slice());
            meter.start();
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            meter.stop(.stopSession);
        }

        /// Drive MCP through an actual frozen catalog offer, without changing
        /// the built-in catalog used by the other entry points' fixtures.
        fn mcpTurn(case: *store_testing.Case, meter: *RoundMeter) !void {
            const records = [_]tool_catalog.Record{
                tool_catalog.bash_record,
                .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a docs page.", .input_schema = "{\"type\":\"object\"}" },
                tool_catalog.find_tools_record,
                tool_catalog.message_agent_record,
                tool_catalog.read_transcript_record,
                tool_catalog.start_agent_record,
                tool_catalog.web_search_record,
            };
            const digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_catalog.recordDigest(record);
                break :blk out;
            };
            const catalog: tool_catalog.Catalog = .{ .records = &records, .digests = &digests };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .catalog = &catalog });
            defer storage.close() catch unreachable;
            const previous_storage = meter.storage;
            meter.storage = &storage;
            defer meter.storage = previous_storage;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("budget-mcp", "", workspace, "model-a");
            command.configuration.tools = try .of(&.{"fetch_page"});
            command.configuration.permission_mode.state = .value;
            try command.configuration.permission_mode.value.set("bypass");
            const configured = storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "budget-mcp-input", "budget-mcp-key", session.slice(), "fetch a page");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "budget-mcp-calls", &.{
                .{ .item_id = "mcp-item", .name = "fetch_page", .encoded_call_id = "mcp-call", .decoded_call_id = "mcp-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "mcp-item-two", .name = "fetch_page", .encoded_call_id = "mcp-call-two", .decoded_call_id = "mcp-call-two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            });
            meter.start();
            const action = (try storage.nextMcpAction()).?;
            meter.stop(.nextMcpAction);
            meter.start();
            try storage.resolveMcpAction(action.action_id, .spawn_failed, "Failed, not run: this Host does not run MCP tool calls yet.", .{});
            meter.stop(.resolveMcpAction);
            const second = (try storage.nextMcpAction()).?;
            meter.start();
            const binding = (try storage.admitMcpActionAttempt(second.action_id, 600_000, .{})).?;
            meter.stop(.admitMcpActionAttempt);
            var input: action_domain.McpExecutionInput = undefined;
            meter.start();
            try storage.readMcpExecutionInput(binding, &input);
            meter.stop(.readMcpExecutionInput);
            _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
            try std.testing.expect((try storage.nextMcpAction()) == null);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
        }

        /// SQL narrows one unloaded tool; eight matchers share one description
        /// window. A no-match call still writes no revision.
        fn findTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var configuration = try completeConfiguration("budget-find", "", try canonicalCwd(std.testing.io, &path), "model-a");
            configuration.configuration.tools = try .of(&.{ "bash", "find_tools" });
            configuration.configuration.loaded_tools = try .of(&.{"find_tools"});
            const session = storage.configure(&configuration, .{}).accepted.session;
            try submitTestMessage(storage, tmp, "budget-find-input", "budget-find-key", session.slice(), "find tools");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "find-item", .name = "find_tools", .encoded_call_id = "find-call", .decoded_call_id = "find-call", .encoded_arguments = "{\\\"words\\\":\\\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\\\"}", .decoded_arguments = "{\"words\":\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\"}" }};
            try settleCallsForTesting(storage, tmp, model, "budget-find-calls", &calls);
            const input = (try storage.nextCoreWork()).?.action;
            const words: @import("../core_tools.zig").FindTools = .{ .words = .{ "absent0", "absent1", "absent2", "absent3", "absent4", "absent5", "absent6", "absent7" }, .count = 8 };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            meter.start();
            try std.testing.expect(try storage.findTools(input.binding, arena.allocator(), &words, null, .{}));
            meter.stop(.findTools);
        }

        /// Three core calls: a Message delivered, an agent started, and a
        /// start whose arguments the Host refused; then the stop the started
        /// child owes once its parent stops.
        fn coreTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("budget-core", "", workspace, "model-a");
            command.configuration.tools.state = .value;
            command.configuration.tools = try .of(&.{ "message_agent", "start_agent" });
            const session = storage.configure(&command, .{}).accepted.session;
            try submitTestMessage(storage, tmp, "budget-core-input", "budget-core-key", session.slice(), "message yourself");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arguments_buffer: [64]u8 = undefined;
            const decoded = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
            var encoded_buffer: [96]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
            const calls = [_]TestingCall{
                .{ .item_id = "core-item", .name = "message_agent", .encoded_call_id = "core-call", .decoded_call_id = "core-call", .encoded_arguments = encoded, .decoded_arguments = decoded },
                .{ .item_id = "start-item", .name = "start_agent", .encoded_call_id = "start-call", .decoded_call_id = "start-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "refused-item", .name = "start_agent", .encoded_call_id = "refused-call", .decoded_call_id = "refused-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(storage, tmp, model, "budget-core-calls", &calls);
            meter.start();
            const core = (try storage.nextCoreWork()).?.action;
            meter.stop(.nextCoreWork);
            meter.start();
            try std.testing.expect(try storage.deliverAgentMessage(core.binding, session.slice(), "hi", .{}) == .delivered);
            meter.stop(.deliverAgentMessage);
            const start = (try storage.nextCoreWork()).?.action;
            try std.testing.expect(start.tool == .start_agent);
            var spec = try testingAgentSpec(&.{"message_agent"}, "ask");
            meter.start();
            try std.testing.expect(try storage.startAgent(start.binding, session.slice(), "look around", true, &spec, null, .{}) == .started);
            meter.stop(.startAgent);
            const refused = (try storage.nextCoreWork()).?.action;
            meter.start();
            try std.testing.expect(try storage.failCoreCall(refused.binding, "Rui could not start the agent: task is required. Nothing was started.", .{}));
            meter.stop(.resolveCoreCall);
            // A Tool Result's identity comes from its original call, not the
            // group's position. Drive the public read on the last ordinal.
            const result_page = try store_core.activityPageForTesting(storage, .{ .session = session, .direction = .backward, .kinds = .initOne(.tool_result), .limit = 1 });
            const result = result_page.items[0];
            try std.testing.expectEqual(@as(u64, 3), result.ordinal);
            meter.start();
            const tool = try storage.activityTool(&.{ .session = session, .position = result.position, .ordinal = result.ordinal });
            meter.stop(.activityTool);
            try std.testing.expect(tool.presentation.code == .failed);
            try expectContent(storage, .{ .length = tool.name.length, .digest = tool.name.digest }, "start_agent");
            // Admit the child task so stopping it closes a Turn.
            while (try storage.admitNextModelAttempt(.{})) |_| {}
            var stop = try completeSessionStop("budget-core-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            const owed = (try storage.nextCoreWork()).?.stop;
            var owed_stop: protocol.SessionStopCommand = .{ .key = owed.key };
            try owed_stop.session.set(owed.session.slice());
            meter.start();
            try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
            meter.stop(.stopOwedSession);
            const ending = (try storage.nextCoreWork()).?.ending;
            meter.start();
            try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
            meter.stop(.deliverChildEnding);
            const forward = (try storage.nextCoreWork()).?.forward;
            meter.start();
            try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
            meter.stop(.deliverSessionForward);
        }

        /// Two Bash calls under ask: one allowed, run and settled, one
        /// denied; then the continuation's history, its failure, and the
        /// Session's reads.
        fn toolTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            const session = try configureTestSessionAsk(storage, "budget-tools");
            try submitTestMessage(storage, tmp, "budget-tools-input", "budget-tools-key", session.slice(), "run");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const arguments = "{\\\"description\\\":\\\"Disk usage\\\",\\\"cmd\\\":\\\"df -h\\\",\\\"timeout_ms\\\":null}";
            const decoded = "{\"description\":\"Disk usage\",\"cmd\":\"df -h\",\"timeout_ms\":null}";
            const calls = [_]TestingCall{
                .{ .item_id = "item-a", .name = "bash", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = arguments, .decoded_arguments = decoded },
                .{ .item_id = "item-b", .name = "bash", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = arguments, .decoded_arguments = decoded },
            };
            try settleCallsForTesting(storage, tmp, first, "budget-calls", &calls);
            const allowed = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation", .{});
            const denied = try store_testing.queryU64(storage, "SELECT max(action_id) FROM action_operation", .{});
            meter.start();
            _ = try storage.actionArguments(session.slice(), allowed);
            meter.stop(.actionContent);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = allowed, .decision = .allow_once };
            try allow.key.set("budget-allow");
            try allow.session.set(session.slice());
            meter.start();
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            meter.stop(.decidePermission);
            meter.start();
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            meter.stop(.admitNextActionAttempt);
            var input: BashExecutionInput = undefined;
            meter.start();
            try storage.readBashExecutionInput(action, &input);
            meter.stop(.readBashExecutionInput);
            meter.start();
            try storage.withActionDispatchHandoff(action, {}, Launch.run);
            meter.stop(.withActionDispatchHandoff);
            meter.start();
            try std.testing.expect(try storage.actionSupersededByStop(action) == null);
            meter.stop(.actionSupersededByStop);
            meter.start();
            try storage.revokeActionSender(action);
            meter.stop(.revokeActionSender);
            meter.start();
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            meter.stop(.settleActionAttempt);
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = denied, .decision = .deny };
            try deny.key.set("budget-deny");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            meter.start();
            try std.testing.expect(!try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
            meter.stop(.recoverOneUncertainAction);

            // The continuation also offers web search, so its tools stage
            // reads a provider-run member.
            var add_search: protocol.ConfigureCommand = .{};
            try add_search.key.set("budget-add-search");
            try add_search.session.set(session.slice());
            add_search.configuration.tools = try .of(&.{ "bash", "web_search" });
            add_search.configuration.tools.state = .value;
            try std.testing.expect(storage.configure(&add_search, .{}) == .accepted);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(continuation, &view);
                defer view.close();
                meter.start();
                _ = try view.validateOutputsStep();
                meter.stop(.validateHistoricalOutputsStep);
                while (!try view.validateOutputsStep()) {}
                var settings: HistoricalSettings = undefined;
                meter.start();
                try view.settings(&settings);
                meter.stop(.readHistoricalSettings);
                var tool: historical_domain.HistoricalTool = .{};
                meter.start();
                try std.testing.expect(try view.nextTool(&tool));
                meter.stop(.readHistoricalTool);
                // Web search, past Bash.
                meter.start();
                try std.testing.expect(try view.nextProviderTool(&tool));
                meter.stop(.readProviderTool);
                // Bash was declared at the first Operation already, so the
                // one read finds nothing to declare.
                _ = try view.coverage();
                var declaration = view.currentDeclaration();
                meter.start();
                try std.testing.expect(!try view.nextDeclaredTool(&declaration, &tool));
                meter.stop(.readDeclaredTool);
                meter.start();
                var entry = (try view.nextEntry(0)).?;
                meter.stop(.readHistoricalEntry);
                entry = (try nextTestingItem(&view, entry.position)).?;
                try std.testing.expectEqual(HistoricalEntryKind.provider_output, entry.kind);
                meter.start();
                _ = try view.openOutput(entry.position);
                meter.stop(.readHistoricalOutput);
                meter.start();
                _ = try view.nextOutputPart();
                meter.stop(.readHistoricalPart);
                while (entry.kind != .tool_results) entry = (try nextTestingItem(&view, entry.position)).?;
                meter.start();
                _ = (try view.nextToolResult()).?;
                meter.stop(.readHistoricalToolResult);
                meter.start();
                try std.testing.expect(try view.prefixSeal() == null);
                meter.stop(.readPrefixSeal);
                const seal: historical_domain.PrefixSeal = .{ .anchor = null, .admission_position = 1, .span_length = 0, .digest = @splat(0) };
                meter.start();
                try view.recordPrefixSeal(&seal);
                meter.stop(.recordPrefixSeal);
            }
            meter.start();
            try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            meter.stop(.settleModelAttemptFailure);
            meter.start();
            try std.testing.expect(try storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}) == null);
            meter.stop(.tryAdmitNextModelRetry);
            meter.start();
            try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()));
            meter.stop(.recoverOneExhaustedModelAttempt);

            meter.start();
            _ = try storage.inspectSessionForTesting(session.slice());
            meter.stop(.inspectSession);
            var activity: protocol.ActivityPage = .{};
            try activity.session.set(session.slice());
            meter.start();
            const rows = try store_core.activityPageForTesting(storage, activity);
            meter.stop(.activityPage);
            meter.start();
            _ = try storage.openActivityContent(&.{ .session = session, .position = rows.items[0].position });
            meter.stop(.openActivityContent);
            meter.start();
            std.testing.allocator.free(try testingSessionReport(storage, tmp, session.slice(), 1024 * 1024));
            meter.stop(.captureSessionReport);
            var used = std.atomic.Value(u64).init(0);
            meter.start();
            std.testing.allocator.free(try testingSessionList(storage, tmp, .{}, &used, 2));
            meter.stop(.captureSessionList);
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var inspect: protocol.InspectSession = .{ .failed_response = .{ .operation = continuation.operation_id, .attempt = continuation.attempt_ordinal, .part = .body } };
            try inspect.session.set(session.slice());
            meter.start();
            if (storage.captureFailedResponse(&inspect, tmp.dir, .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 3,
            })) |report| {
                var kept = report;
                kept.deinit();
            } else |_| {}
            meter.stop(.captureFailedResponse);
        }

        /// A Turn over the compaction trigger, compacted, so its
        /// successor's history starts at an anchor.
        fn compactedTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            const session = try configureTestSession(storage, "budget-compacted");
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("budget-heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(storage, tmp, "budget-one", "budget-one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "item-a", .name = "unknown", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTestingWithFaults(storage, tmp, first, "budget-usage", &calls, .{}, "{\"input_tokens\":99999,\"output_tokens\":1,\"details\":{\"input_tokens\":0}}");
            try submitTestMessage(storage, tmp, "budget-two", "budget-two", session.slice(), "later");
            const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compaction));
            try settleCompactionForTesting(storage, tmp, compaction, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(successor, &view);
            defer view.close();
            while (!try view.validateOutputsStep()) {}
            meter.start();
            try std.testing.expect((try view.coverage()).anchor != null);
            meter.stop(.readCompactionAnchor);
        }
    }.run);
}

// The rounds twins of sqlite_tests.zig's work tests. Each test there
// holds a population's VM steps or statements still, which only SQLite
// shows; its twin here holds the rounds of the same work at the same two
// sizes, which every engine shows.

/// The rounds `store` took since `start`: its Accesses' runs and commits.
const TwinRounds = struct {
    store: *Store,
    before: u16,

    fn start(store: *Store) TwinRounds {
        return .{ .store = store, .before = store.testing_content_work.rounds };
    }

    fn taken(self: TwinRounds) u16 {
        return self.store.testing_content_work.rounds - self.before;
    }
};

/// A Session whose active Turn's one Operation proposed `count` calls of
/// an unknown tool, each rejected, so the report lists every one.
pub fn rejectedCallsForTesting(storage: *Store, tmp: *std.testing.TmpDir, count: usize) !protocol.Bounded(protocol.max_session_bytes) {
    const session = try configureTestSession(storage, "one-operation-config");
    try submitTestMessage(storage, tmp, "one-operation-input", "one-operation-key", session.slice(), "many calls");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var ids: [256][16]u8 = undefined;
    var calls: [256]TestingCall = undefined;
    for (calls[0..count], ids[0..count], 0..) |*call, *id_buffer, index| {
        const id = try std.fmt.bufPrint(id_buffer, "call-{d}", .{index});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
    }
    try settleCallsForTesting(storage, tmp, binding, "one-operation-calls", calls[0..count]);
    return session;
}

test "creating a Session takes the same work however many Sessions exist, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const few = TwinRounds.start(&storage);
            _ = try configureTestSession(&storage, "creation-rounds-few");
            const few_rounds = few.taken();
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tool_set_id,permission_mode," ++
                "output_schema_content_id,revision,next_position,created_at,created_seq,workspace_digest,workspace_key) " ++
                "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<2000) " ++
                "SELECT 100000+value,'/','codex','openai-responses/1','model-a',1,1,0,NULL,1,1,1,value+1000000,zeroblob(32),value+1000000 FROM sequence", .{});
            const many = TwinRounds.start(&storage);
            _ = try configureTestSession(&storage, "creation-rounds-many");
            try std.testing.expectEqual(few_rounds, many.taken());
        }
    }.run);
}

test "a Workspace's changed page reads only its own Sessions, however many others changed, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root: [protocol.max_store_bytes]u8 = undefined;
            const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
            var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
            defer nested.close(std.testing.io);
            var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
            const watched = try configure(&storage, "scoped-watched", "", workspace);
            var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
            try request.workspace.?.set(workspace);
            _ = try configure(&storage, "scoped-watched-again", &watched, workspace);
            const alone = try rounds(&storage, &tmp, request, &watched);
            for (1..change_ring.capacity) |index| {
                var key: [32]u8 = undefined;
                _ = try configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
            }
            try std.testing.expect(storage.changes.covers(request.since.?.generation));
            try std.testing.expectEqual(alone, try rounds(&storage, &tmp, request, &watched));
        }

        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
        }

        fn rounds(store: *Store, dir: *std.testing.TmpDir, request: protocol.ListSessions, watched: *const change_ring.Id) !u16 {
            const counter = TwinRounds.start(store);
            const page = try TestingListing.read(store, dir, request);
            const taken = counter.taken();
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try page.expectReferences(&.{watched.*});
            try std.testing.expect(page.next == null);
            return taken;
        }
    }.run);
}

test "a list row reads the same steps however long its Session's history, in rounds" {
    try store_testing.forEachEngine(struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "row-rounds");
            try stopped(&storage, &tmp, session.slice(), "row-rounds-0");
            try answerTestTurn(&storage, &tmp, session.slice(), "row-rounds-short", &answer);
            const short = try rowRounds(&storage, &tmp, session.slice());
            inline for (1..33) |turn| try stopped(&storage, &tmp, session.slice(), std.fmt.comptimePrint("row-rounds-{d}", .{turn}));
            try answerTestTurn(&storage, &tmp, session.slice(), "row-rounds-long", &answer);
            try std.testing.expect(short > 0);
            try std.testing.expectEqual(short, try rowRounds(&storage, &tmp, session.slice()));
        }

        /// An answered Turn, then a queued Message a stop excluded.
        fn stopped(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }

        /// The Session is the list's only row, so the page's rounds are its row's.
        fn rowRounds(store: *Store, dir: *std.testing.TmpDir, session: []const u8) !u16 {
            var used = std.atomic.Value(u64).init(0);
            const counter = TwinRounds.start(store);
            std.testing.allocator.free(try testingSessionList(store, dir, .{}, &used, 79));
            const taken = counter.taken();
            var listed = try testingListRow(store, dir, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings("finished", listed.get(&.{ "work", "state", "kind" }).string);
            return taken;
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
                try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
                cost.* = counter.taken();
            }
            try std.testing.expectEqual(@as(u64, 4), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE authorized=0 AND resolution_code IS NULL", .{}));
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }
    }.run);
}

test "tool continuation selection never visits a Turn waiting for its tool results, in rounds" {
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
                const name = try std.fmt.bufPrint(&name_buffer, "waiting-{d}", .{pass});
                var config_buffer: [40]u8 = undefined;
                const config = try std.fmt.bufPrint(&config_buffer, "{s}-config", .{name});
                const session = try configureTestSessionAsk(&storage, config);
                try submitTestMessage(&storage, &tmp, name, name, session.slice(), "propose");
                const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
                try settleTwoActionsForTesting(&storage, &tmp, binding, config);
                const counter = TwinRounds.start(&storage);
                try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
                cost.* = counter.taken();
            }
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE outcome_code IS NULL", .{}));
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }
    }.run);
}

test "complete historical tool-result traversal scales with groups and calls, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const baseline = try measure(case, 4, 1);
            const more_groups = try measure(case, 16, 1);
            const call_baseline = try measure(case, 4, 8);
            const more_calls = try measure(case, 4, 32);
            std.testing.expect(more_groups > baseline and more_calls >= call_baseline) catch |err| {
                std.debug.print("rounds: {d} {d} {d} {d}\n", .{ baseline, more_groups, call_baseline, more_calls });
                return err;
            };
        }

        fn measure(engine: *store_testing.Case, group_count: usize, calls_per_group: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "scale-config");
            try submitTestMessage(&storage, &tmp, "scale-input", "scale-input", session.slice(), "call");
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [32]TestingCall = undefined;
            var item_ids: [32][32]u8 = undefined;
            var call_ids: [32][32]u8 = undefined;
            for (calls[0..calls_per_group], 0..) |*call, index| {
                const item_id = try std.fmt.bufPrint(&item_ids[index], "scale-item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&call_ids[index], "scale-call-{d}", .{index});
                call.* = .{ .item_id = item_id, .name = "unknown", .encoded_call_id = call_id, .decoded_call_id = call_id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            for (0..group_count) |index| {
                var prefix_buffer: [64]u8 = undefined;
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix_buffer, "scale-metadata-{d}", .{index}), calls[0..calls_per_group]);
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            const counter = TwinRounds.start(&storage);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(binding, &view);
            defer view.close();
            var position: u64 = 0;
            var groups_seen: usize = 0;
            var results_seen: usize = 0;
            while (try view.nextEntry(position)) |entry| {
                position = entry.position;
                if (entry.kind != .tool_results) continue;
                groups_seen += 1;
                while (try view.nextToolResult()) |_| results_seen += 1;
            }
            try std.testing.expectEqual(group_count, groups_seen);
            try std.testing.expectEqual(group_count * calls_per_group, results_seen);
            return counter.taken();
        }
    }.run);
}

/// A bound fixture statement that adds `?1` failed Operations after
/// Operation `?2`, in its Turn.
const failed_operations_sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
    "attempt_ordinal,output_reservation,resolution_code,resolved_at) " ++
    "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) " ++
    "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
    "1,0,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2";

/// `failed_operations_sql`, the Operations alternating in purpose.
const failed_purpose_operations_sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
    "output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
    "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) " ++
    "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
    "0,1,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2";

test "historical accepted output selection work excludes failed Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 8), try measure(case, 1024));
        }

        fn measure(engine: *store_testing.Case, population: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            try store_testing.exec(&storage, failed_operations_sql, .{ population, current.operation_id });
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            const counter = TwinRounds.start(&storage);
            while (!try view.validateOutputsStep()) {}
            return counter.taken();
        }
    }.run);
}

test "historical context selection work excludes nonmatching Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |with_base| {
                try std.testing.expectEqual(try measure(case, 8, with_base), try measure(case, 1024, with_base));
            }
        }

        fn measure(engine: *store_testing.Case, population: usize, with_base: bool) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            var current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (with_base) {
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, current, &.{ .reasoning, .compaction, .message });
                current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL", .{});
            try store_testing.exec(&storage, failed_purpose_operations_sql, .{ population, current.operation_id });
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            const counter = TwinRounds.start(&storage);
            while (!try view.validateOutputsStep()) {}
            const taken = counter.taken();
            try std.testing.expectEqual(with_base, (try view.coverage()).anchor != null);
            return taken;
        }
    }.run);
}

test "Current report work is independent of terminal tool history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 16), try measure(case, 64));
        }

        fn measure(engine: *store_testing.Case, group_count: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "current-cost-config");
            const calls = [_]TestingCall{.{ .item_id = "current-cost-item", .name = "unknown", .encoded_call_id = "current-cost-call", .decoded_call_id = "current-cost-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            for (0..group_count) |index| {
                var file_buffer: [64]u8 = undefined;
                var key_buffer: [64]u8 = undefined;
                var metadata_buffer: [64]u8 = undefined;
                try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file_buffer, "current-cost-file-{d}", .{index}), try std.fmt.bufPrint(&key_buffer, "current-cost-message-{d}", .{index}), session.slice(), "call");
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, source, try std.fmt.bufPrint(&metadata_buffer, "current-cost-metadata-{d}", .{index}), &calls);
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            }
            try submitTestMessage(&storage, &tmp, "current-cost-active-file", "current-cost-active-message", session.slice(), "active");
            const active = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTestingWithFaults(&storage, &tmp, active, "current-cost-active-metadata", &calls, .{}, "{\"input_tokens\":10,\"output_tokens\":0}");
            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            const counter = TwinRounds.start(&storage);
            var report = try storage.captureSessionReport(session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            });
            const taken = counter.taken();
            report.deinit();
            return taken;
        }
    }.run);
}

test "Full Message projection work does not multiply Messages by stops, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const baseline = try measure(case, 32, 32);
            const more_messages = try measure(case, 128, 32);
            const more_stops = try measure(case, 32, 128);
            const both_larger = try measure(case, 128, 128);
            // The Messages' rounds grow with their chunks; stops add none
            // at either Message count.
            std.testing.expect(more_messages > baseline and more_stops == baseline and both_larger == more_messages) catch |err| {
                std.debug.print("rounds: {d} {d} {d} {d}\n", .{ baseline, more_messages, more_stops, both_larger });
                return err;
            };
        }

        fn measure(engine: *store_testing.Case, message_count: usize, stop_count: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "full-scale-config");
            for (1..message_count + 1) |index| {
                var key: [32]u8 = undefined;
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at,admission_position) " ++
                    "VALUES(?1,?2,?3,1,NULL,1,?4)", .{ index, session.slice(), try std.fmt.bufPrint(&key, "message-{d}", .{index}), 1000 + index });
            }
            const last_command = try store_testing.queryU64(&storage, "SELECT coalesce(max(command_seq),0) FROM core_command", .{});
            for (1..stop_count + 1) |index| {
                var key: [32]u8 = undefined;
                const command = try std.fmt.bufPrint(&key, "stop-{d}", .{index});
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) " ++
                    "VALUES(?1,3,?2,zeroblob(32),NULL,NULL,1,'accepted',0,0,?3)", .{ command, session.slice(), last_command + index });
                try store_testing.withoutForeignKeys(&storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                    "VALUES(?1,?2,NULL,?3,?4,1)", .{ command, session.slice(), message_count, index });
            }
            const counter = TwinRounds.start(&storage);
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
            const taken = counter.taken();
            std.testing.allocator.free(full);
            return taken;
        }
    }.run);
}

/// The WITH of a fixture INSERT over `value` 1 through `?1`. It goes after
/// the INSERT's column list, the one place MySQL and SQLite both take it.
const sequence_to_first_argument = "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) ";

test "an Activity page costs the same steps after 10 or 10,000 earlier rows, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var rounds: [2][2]u16 = undefined;
            for ([_]usize{ 10, 10_000 }, &rounds) |history, *cost| cost.* = try measure(case, history);
            try std.testing.expectEqual(rounds[0], rounds[1]);
        }

        /// `history` earlier units, a Message, its call item, the call's
        /// rejection and its Turn's outcome, then the same tail: a Message,
        /// twenty rejected calls and a stop. The rounds of the opening's
        /// page and of a forward page from the tail's first row.
        fn measure(engine: *store_testing.Case, history: usize) ![2]u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "cost-config");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session", .{});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session", .{});
            // Foreign keys are off: each history Message names its Turn
            // before the Turn row exists.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,value+1000000,?4,?3+4*(value-1),value,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                sequence_to_first_argument ++
                "SELECT value,value,?2,1,value,?3+4*(value-1),0,1,'tool_proposals',1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                sequence_to_first_argument ++
                "SELECT value,0,?2,?3+4*(value-1)+1,3,1,zeroblob(32),0,?4,0 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,0,0,?4,?4,?4,zeroblob(120),'unknown_tool',?4,?3+4*(value-1)+2 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                sequence_to_first_argument ++
                "SELECT value,?2,value,value,value,'completed',?3+4*(value-1)+3,1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+4*?1", .{history});
            // The history rows bypass the Host's ids.
            try store_core.reloadIdentitiesForTesting(&storage);
            const tail = (try store_core.readSessionForTesting(&storage, session.slice())).?.next_position;
            try submitTestMessage(&storage, &tmp, "cost-input", "input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var identities: [20][24]u8 = undefined;
            var calls: [20]TestingCall = undefined;
            for (&calls, &identities, 0..) |*call, *identity, index| {
                const id = try std.fmt.bufPrint(identity, "cost-{d}", .{index});
                call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "", .decoded_arguments = "" };
            }
            try settleCallsForTesting(&storage, &tmp, binding, "cost-calls", &calls);
            var stop = try completeSessionStop("cost-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);

            var cost: [2]u16 = undefined;
            var opening: protocol.ActivityPage = .{ .direction = .backward };
            try opening.session.set(session.slice());
            const opened = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, opening);
            cost[0] = opened.taken();
            try std.testing.expect(page.more);
            var forward: protocol.ActivityPage = .{ .end = page.end, .position = tail - 1 };
            try forward.session.set(session.slice());
            const forwarded = TwinRounds.start(&storage);
            const later = try store_core.activityPageForTesting(&storage, forward);
            cost[1] = forwarded.taken();
            try std.testing.expect(later.more);
            try std.testing.expectEqual(tail, later.items[0].position);
            return cost;
        }
    }.run);
}

test "a one-row page of a person's Messages costs the same steps after 10 or 10,000 received ones, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 10), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "recall-config");
            const peer = try configureTestSession(&storage, "recall-peer");
            try submitTestMessage(&storage, &tmp, "recall-first", "first", session.slice(), "first");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1,?5,value FROM sequence", .{ history, session.slice(), start, content, peer.slice() });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].value == .admission and !page.more);
            return taken;
        }
    }.run);
}

test "a forward one-row page of a person's Messages costs the same steps past 10 or 10,000 tool groups, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 10), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "forward-config");
            try submitTestMessage(&storage, &tmp, "forward-first", "first", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "forward-second", "second", session.slice(), "second");
            const first = try store_testing.queryU64(&storage, "SELECT min(admission_position) FROM message_admission", .{});
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            // Each tool group names its Turn before the Turn row exists. A
            // cancelled Turn needs no answer content.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,1000+value,?2,1,1000+value,?3+3*(value-1),0,1,'tool_proposals',1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,extras_content_id,part_count) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,0,?2,?3+3*(value-1),3,1,zeroblob(32),0,?4,0 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,field_metadata,rejection_code,rejection_content_id,acceptance_position) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,0,0,?4,?4,?4,zeroblob(120),'unknown_tool',?4,?3+3*(value-1)+1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,1000+value,1000+value,1000+value,'cancelled',?3+3*(value-1)+2,1 FROM sequence", .{ history, session.slice(), start });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+3*?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            try submitTestMessage(&storage, &tmp, "forward-third", "third", session.slice(), "third");
            var request: protocol.ActivityPage = .{ .position = first, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].position > first and page.more);
            try std.testing.expectEqual(@as(u64, 0), page.call_activity.total);
            return taken;
        }
    }.run);
}

test "a one-row page of a person's Messages costs the same steps past 100 or 10,000 waiting ones, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            try std.testing.expectEqual(try measure(case, 100), try measure(case, 10_000));
        }

        fn measure(engine: *store_testing.Case, history: usize) !u16 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "waiting-config");
            const start = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{session.slice()});
            const content = try store_testing.queryU64(&storage, "SELECT instructions_content_id FROM session WHERE session_ref=?1", .{session.slice()});
            // The waiting Messages have no commands.
            try store_testing.withoutForeignKeys(&storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                sequence_to_first_argument ++
                "SELECT 1000+value,?2,value+1000000,?4,?3+value-1,1 FROM sequence", .{ history, session.slice(), start, content });
            try store_testing.exec(&storage, "UPDATE session SET next_position=next_position+?1 WHERE session_ref=?2", .{ history, session.slice() });
            try store_core.reloadIdentitiesForTesting(&storage);
            try submitTestMessage(&storage, &tmp, "waiting-newest", "newest", session.slice(), "newest");
            var request: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initOne(.admission), .limit = 1 };
            try request.session.set(session.slice());
            const counter = TwinRounds.start(&storage);
            const page = try store_core.activityPageForTesting(&storage, request);
            const taken = counter.taken();
            try std.testing.expect(page.count == 1 and page.items[0].value.admission.state == .queued and page.more);
            try std.testing.expectEqual(@as(u64, 0), page.queued.count);
            return taken;
        }
    }.run);
}

test "model admission work excludes failed historical Operation population, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |overflow| {
                const small = try Measure.run(case, 8, overflow);
                const large = try Measure.run(case, 1024, overflow);
                try std.testing.expectEqual(small, large);
            }
        }

        const Measure = struct {
            fn run(engine: *store_testing.Case, population: usize, overflow: bool) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
                const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                // Keep the actual current Operation newer than all injected history.
                try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001", .{});
                try store_testing.exec(&storage, failed_purpose_operations_sql, .{ population, current.operation_id });
                try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (overflow) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (overflow) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                return taken;
            }
        };
    }.run);
}

test "model admission work excludes accepted compaction base history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var bounded = true;
            for ([_]Measure.Suffix{ .unchanged, .low, .high, .missing }) |suffix| {
                const small = try Measure.run(case, 8, suffix);
                const large = try Measure.run(case, 128, suffix);
                bounded = bounded and large == small;
            }
            try std.testing.expect(bounded);
        }

        const Measure = struct {
            const Suffix = enum { unchanged, low, high, missing };

            fn run(engine: *store_testing.Case, population: usize, suffix: Suffix) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
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
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("policy");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("1000");
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (suffix == .high) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (suffix == .high) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                return taken;
            }
        };
    }.run);
}

test "model admission work excludes usage-covered accepted tool and instruction history, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var bounded = true;
            for ([_]Measure.Population{ .rejection, .action, .instruction }) |kind| {
                for ([_]bool{ false, true }) |compact| {
                    const small = try Measure.run(case, 8, kind, compact);
                    const large = try Measure.run(case, 128, kind, compact);
                    bounded = bounded and large == small;
                }
            }
            try std.testing.expect(bounded);
        }

        const Measure = struct {
            const Population = enum { rejection, action, instruction };

            fn run(engine: *store_testing.Case, population: usize, kind: Population, compact: bool) !u16 {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                if (kind == .action) {
                    var tools: protocol.ConfigureCommand = .{};
                    try tools.key.set("tools");
                    try tools.session.set(session.slice());
                    tools.configuration.tools.state = .value;
                    try tools.configuration.tools.append("bash");
                    tools.configuration.permission_mode.state = .value;
                    try tools.configuration.permission_mode.value.set("bypass");
                    try std.testing.expect(storage.configure(&tools, .{}) == .accepted);
                }
                const call = TestingCall{ .item_id = "item", .name = if (kind == .action) "bash" else "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = if (kind == .action) "{\\\"description\\\":\\\"Run no-op\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}" else "{}", .decoded_arguments = if (kind == .action) "{\"description\":\"Run no-op\",\"cmd\":\"true\",\"timeout_ms\":null}" else "{}" };
                const instructions: [400]u8 = @splat('x');
                for (0..population + 1) |index| {
                    var key: [64]u8 = undefined;
                    if (kind == .instruction) {
                        var patch: protocol.ConfigureCommand = .{};
                        try patch.key.set(try std.fmt.bufPrint(&key, "instructions-{d}", .{index}));
                        try patch.session.set(session.slice());
                        patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", &instructions);
                        defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                        try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
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
                var patch: protocol.ConfigureCommand = .{};
                try patch.key.set("policy");
                try patch.session.set(session.slice());
                patch.configuration.compaction_trigger.state = .value;
                try patch.configuration.compaction_trigger.value.set("100000");
                if (kind == .instruction) {
                    // Same-text updates are new input, not content deduplication.
                    patch.configuration.instructions = try testingBytesContent(&tmp, "pending-instruction", &instructions);
                }
                defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
                if (kind == .instruction) {
                    var clear: protocol.ConfigureCommand = .{};
                    try clear.key.set("clear");
                    try clear.session.set(session.slice());
                    clear.configuration.instructions = try testingBytesContent(&tmp, "clear-instruction", "");
                    defer clear.removeTemporaryContent(std.testing.io) catch unreachable;
                    try std.testing.expect(storage.configure(&clear, .{}) == .accepted);
                }
                try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
                const counter = TwinRounds.start(&storage);
                const admitted = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
                const taken = counter.taken();
                try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
                try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
                if (kind == .instruction) try std.testing.expectEqual(@as(u64, @intCast(population + 1 + @as(usize, if (compact) 0 else 2))), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE source_revision IS NOT NULL", .{}));
                return taken;
            }
        };
    }.run);
}

test "a Current report's work grows linearly in one Operation's calls, as main's did, in rounds" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var rounds: [3]u16 = undefined;
            inline for (.{ 16, 64, 256 }, &rounds) |calls, *cost| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try rejectedCallsForTesting(&storage, &tmp, calls);
                const counter = TwinRounds.start(&storage);
                std.testing.allocator.free(try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024 * 1024, .current));
                cost.* = counter.taken();
            }
            std.testing.expect(rounds[0] == rounds[1] and rounds[1] == rounds[2]) catch |err| {
                std.debug.print("rounds: {any}\n", .{rounds});
                return err;
            };
        }
    }.run);
}

test "each setting a revision changes is one session_changed row at the position it was accepted" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("change-create", "", workspace, "model-a");
            const session = storage.configure(&create, .{}).accepted.session;
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.session_changed) };
            try request.session.set(session.slice());
            // A creation is no change.
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            try submitTestMessage(&storage, &tmp, "change-before", "change-before", session.slice(), "before");
            var change = try completeConfiguration("change-mode-label", session.slice(), workspace, "model-a");
            change.configuration.permission_mode.state = .value;
            // The default is bypass.
            try change.configuration.permission_mode.value.set("ask");
            change.configuration.label.state = .value;
            try change.configuration.label.value.set("renamed");
            try std.testing.expect(storage.configure(&change, .{}) == .accepted);
            // A revision that changes nothing writes no row.
            var same = try completeConfiguration("change-same", session.slice(), workspace, "model-a");
            try std.testing.expect(storage.configure(&same, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "change-after", "change-after", session.slice(), "after");
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            const expected = [_]protocol.SessionField{ .permission_mode, .label };
            for (page.items[0..2], expected, 0..) |item, field, ordinal| {
                try std.testing.expectEqual(page.items[0].position, item.position);
                try std.testing.expectEqual(@as(u64, ordinal), item.ordinal);
                try std.testing.expectEqual(@as(u64, 2), item.value.session_changed.revision);
                try std.testing.expectEqual(field, item.value.session_changed.field);
            }
            // The rows sit between the Messages admitted before and after.
            var all: protocol.ActivityPage = .{};
            try all.session.set(session.slice());
            const every = try store_core.activityPageForTesting(&storage, all);
            var admissions: [2]u64 = undefined;
            var seen: usize = 0;
            for (every.items[0..every.count]) |item| if (item.value == .admission) {
                admissions[seen] = item.position;
                seen += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), seen);
            try std.testing.expect(admissions[0] < page.items[0].position and page.items[0].position < admissions[1]);
            // Backward from the end, the same rows come in reverse.
            request.direction = .backward;
            const backward = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), backward.count);
            try std.testing.expectEqual(protocol.SessionField.label, backward.items[0].value.session_changed.field);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "each compaction that succeeds is one compacted row, with the entries its floor dropped" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("compacted-create", "", workspace, "model-a");
            const session = storage.configure(&create, .{}).accepted.session;
            var request: protocol.ActivityPage = .{ .kinds = .initOne(.compacted) };
            try request.session.set(session.slice());
            // model-a's levels aim at 512,000, 128,000 and 32,000 bytes:
            // level 1 drops the 600 KB Message and keeps the first and last.
            const big = try std.testing.allocator.alloc(u8, 600_000);
            defer std.testing.allocator.free(big);
            @memset(big, 'b');
            try submitTestMessage(&storage, &tmp, "compacted-first", "compacted-first", session.slice(), "first");
            try submitTestMessage(&storage, &tmp, "compacted-big", "compacted-big", session.slice(), big);
            try submitTestMessage(&storage, &tmp, "compacted-last", "compacted-last", session.slice(), "last");
            const call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(call, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const full = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(full, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            // An overflowed compaction has no row.
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, request)).count);
            const room = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // A poll while the compaction runs reads a frozen end past its
            // admission; the row then takes a later position, so that
            // prefix never gains it and a poll from its end finds it.
            const frozen = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 0), frozen.count);
            try settleCompactionForTesting(&storage, &tmp, room, &.{.compaction});
            var reread = request;
            reread.end = frozen.end;
            try std.testing.expectEqual(@as(usize, 0), (try store_core.activityPageForTesting(&storage, reread)).count);
            var follow = request;
            follow.position = frozen.end;
            const followed = try store_core.activityPageForTesting(&storage, follow);
            try std.testing.expectEqual(@as(usize, 1), followed.count);
            try std.testing.expectEqual(room.operation_id, followed.items[0].value.compacted.operation);
            // A later compaction without a floor drops nothing.
            try submitTestMessage(&storage, &tmp, "compacted-again", "compacted-again", session.slice(), "again");
            const again = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try storage.settleModelAttemptFailure(again, .{ .uncorrelated = "provider_context_overflow" }, .context_overflow, .{});
            const plain = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCompactionForTesting(&storage, &tmp, plain, &.{.compaction});
            const page = try store_core.activityPageForTesting(&storage, request);
            try std.testing.expectEqual(@as(usize, 2), page.count);
            for (page.items[0..2], [_]u64{ room.operation_id, plain.operation_id }, [_]u64{ 1, 0 }) |item, operation, dropped| {
                try std.testing.expectEqual(protocol.ActivityItem.Compacted{ .operation = operation, .dropped = dropped }, item.value.compacted);
                try std.testing.expectEqual(@as(u64, 0), item.ordinal);
            }
            try std.testing.expect(page.items[0].position < page.items[1].position);
        }
    }.run);
}

test "core_tools start_agent persists optional borrowed spec content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("optional-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            const parent = storage.configure(&create, .{}).accepted.session;
            try submitTestMessage(&storage, &tmp, "optional-agent-message", "optional-agent-key", parent.slice(), "start a child");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "optional-agent-call", &.{.{
                .item_id = "optional-item",
                .name = "start_agent",
                .encoded_call_id = "optional-call",
                .decoded_call_id = "optional-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const action = (try storage.nextCoreWork()).?.action;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const core_tools = @import("../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            const result = try core_tools.checkStartAgent(arena.allocator(), "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"model-a\",\"effort\":null,\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\",\"instructions\":\"Persist these instructions\",\"outputSchema\":{\"type\":\"object\"}}}", start);
            try std.testing.expect(result == .accepted);
            const Capture = struct {
                child: protocol.Bounded(protocol.session_id_bytes) = .{},
                fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.child.set(admission.session) catch unreachable;
                }
            };
            var capture: Capture = .{};
            try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
            const child = (try store_core.readSessionForTesting(&storage, capture.child.slice())).?;
            const instructions = try testingContentReference(&storage, @intCast(child.instructions_id.?));
            const schema = try testingContentReference(&storage, @intCast(child.output_schema_id.?));
            try std.testing.expectEqual(@as(u64, "Persist these instructions".len), instructions.length);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Persist these instructions"), &instructions.digest);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("{\"type\":\"object\"}"), &schema.digest);
        }
    }.run);
}

test "core_tools start_agent spec refusals fail calls and name the refused setting" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("refused-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            const parent = storage.configure(&create, .{}).accepted.session;
            try submitTestMessage(&storage, &tmp, "refused-agent-message", "refused-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const cases = .{
                .{ "\"effort\":null,\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"", "model" },
                .{ "\"model\":\"gpt-6.1-sol\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"", "effort" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":null,\"tools\":[],\"permissionMode\":\"ask\"", "compactAt" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":null,\"compactAt\":1,\"permissionMode\":\"ask\"", "tools" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":null,\"compactAt\":1,\"tools\":[]", "permissionMode" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":1050001,\"tools\":[],\"permissionMode\":\"ask\"", "compact_at_too_large" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":\"none\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"", "unsupported_reasoning_effort" },
            };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var calls: [cases.len]TestingCall = undefined;
            var arguments: [cases.len][]const u8 = undefined;
            inline for (cases, 0..) |entry, index| {
                const id = std.fmt.comptimePrint("refused-{d}", .{index});
                const bytes = "{\"task\":\"read\",\"attached\":false,\"spec\":{" ++ entry[0] ++ "}}";
                const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), bytes, .{});
                arguments[index] = bytes;
                calls[index] = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = bytes };
            }
            try settleCallsForTesting(&storage, &tmp, model, "refused-agent-calls", &calls);
            const core_tools = @import("../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            inline for (cases, 0..) |entry, index| {
                const action = (try storage.nextCoreWork()).?.action;
                const check = try core_tools.checkStartAgent(arena.allocator(), arguments[index], start);
                const expected_reason = switch (check) {
                    .accepted => accepted: {
                        try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{}) == .failed);
                        break :accepted "Rui could not start the agent (" ++ entry[1] ++ "). Nothing was started.";
                    },
                    .rejected => |reason| refused: {
                        try std.testing.expect(std.mem.indexOf(u8, reason, entry[1]) != null);
                        try std.testing.expect(try storage.failCoreCall(action.binding, reason, .{}));
                        break :refused reason;
                    },
                };
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(expected_reason) } }));
            }
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "a start_agent child works in its caller's Workspace with its provider" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("binding-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{ "bash", "start_agent" });
            const parent = storage.configure(&create, .{}).accepted.session;
            try submitTestMessage(&storage, &tmp, "binding-agent-message", "binding-agent-key", parent.slice(), "start a child");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "binding-agent-call", &.{.{
                .item_id = "binding-item",
                .name = "start_agent",
                .encoded_call_id = "binding-call",
                .decoded_call_id = "binding-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const action = (try storage.nextCoreWork()).?.action;
            // D122/D221: a Bash spec names no Workspace; the child inherits both.
            var spec = try testingAgentSpec(&.{"bash"}, "ask");
            try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), "work here", true, &spec, null, .{}) == .started);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1 AND workspace=?2 AND provider='codex'", .{ parent.slice(), workspace }));
        }
    }.run);
}

test "a null effort on a listed model refuses a mixed update before any changes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("effort-null-spec", "", workspace, "gpt-6.1-sol");
            const session = storage.configure(&create, .{}).accepted.session;
            var patch: protocol.ConfigureCommand = .{};
            patch.session = session;
            try patch.key.set("effort-set-low");
            patch.configuration.reasoning_effort.state = .value;
            try patch.configuration.reasoning_effort.value.set("low");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            const before = try storage.inspectSessionForTesting(session.slice());
            try patch.key.set("effort-clear-mixed");
            patch.configuration.reasoning_effort.state = .explicit_null;
            patch.configuration.tools = try .of(&.{});
            patch.configuration.label.state = .value;
            try patch.configuration.label.value.set("must not apply");
            const bytes = "must not import these instructions";
            patch.configuration.instructions = .{ .state = .value, .borrowed = bytes.ptr, .length = bytes.len, .digest = protocol.contentDigest(bytes) };
            const refused = storage.configure(&patch, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, refused.rejected.code);
            const after = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(before.revision, after.revision);
            try std.testing.expectEqual(before.tools_mask, after.tools_mask);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND label IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), after.reasoning_effort);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest(bytes) }}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation", .{}));
        }
    }.run);
}

test "a null effort is refused for listed reasoning models and admitted for unlisted models" {
    var requested: protocol.Configuration = .{};
    requested.reasoning_effort.state = .explicit_null;
    var current: CurrentConfiguration = .{ .reasoning_effort = null, .provider = .codex };
    try current.model.set("gpt-6.1-sol");
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, &current, &requested, .codex).?);
    try current.model.set("model-a");
    try std.testing.expect(configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, &current, &requested, .codex) == null);
}

test "null effort supports nonreasoning catalog entries but never clears assigned effort" {
    var requested: protocol.Configuration = .{};
    requested.reasoning_effort.state = .explicit_null;
    var current: CurrentConfiguration = .{ .reasoning_effort = null, .provider = .codex };
    for ([_][]const u8{ "openai/whisper-1", "unlisted-model" }) |model| {
        try current.model.set(model);
        current.reasoning_effort = null;
        try std.testing.expect(configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, &current, &requested, .codex) == null);
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), configuration_domain.effectiveReasoningEffort(&current));
        current.reasoning_effort = .low;
        try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, &current, &requested, .codex).?);
    }
    try current.model.set("gpt-6.1-sol");
    current.reasoning_effort = null;
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), configuration_domain.effectiveReasoningEffort(&current));
}

test "effective effort carries legacy history without inferring a fresh default" {
    var current: CurrentConfiguration = .{ .provider = .codex };
    try current.model.set("unlisted-model");
    try std.testing.expect(configuration_domain.effectiveReasoningEffort(&current) == null);
    current.previous_reasoning_effort = .high;
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), configuration_domain.effectiveReasoningEffort(&current));
    var requested: protocol.Configuration = .{};
    requested.reasoning_effort.state = .explicit_null;
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, configuration_domain.configurationBeforeWorkspace(&tool_catalog.built_in, &current, &requested, .codex).?);
    current.reasoning_effort = .low;
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), configuration_domain.effectiveReasoningEffort(&current));
}

test "loaded tools configure defaults equality membership and reachability" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            var initial = try completeConfiguration("loaded-default", "", workspace, "model-a");
            const created = storage.configure(&initial, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

            var update: protocol.ConfigureCommand = .{};
            try update.session.set(session.slice());
            try update.key.set("loaded-equal");
            update.configuration.tools = try .of(&.{"bash"});
            update.configuration.loaded_tools = try .of(&.{"bash"});
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expect(storage.configure(&update, .{}).accepted.replayed);
            var conflict = update;
            conflict.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(storage.configure(&conflict, .{}) == .conflict);

            try update.key.set("loaded-not-in-tools");
            update.configuration.loaded_tools = try .of(&.{"web_search"});
            const outside = storage.configure(&update, .{});
            try std.testing.expect(outside == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_not_in_tools, outside.rejected.code);
            try std.testing.expect(storage.configure(&update, .{}).rejected.replayed);

            try update.key.set("loaded-unreachable");
            update.configuration.loaded_tools = try .of(&.{});
            const unreachable_set = storage.configure(&update, .{});
            try std.testing.expect(unreachable_set == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, unreachable_set.rejected.code);

            // Membership is checked against saved tools if tools is omitted.
            try update.key.set("loaded-saved-tools");
            update.configuration.tools.state = .omitted;
            update.configuration.loaded_tools = try .of(&.{"web_search"});
            const saved_outside = storage.configure(&update, .{});
            try std.testing.expect(saved_outside == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_not_in_tools, saved_outside.rejected.code);

            // An omitted loaded list continues to follow tools after equality.
            try update.key.set("loaded-follow-tools");
            update.configuration.tools = try .of(&.{ "bash", "web_search" });
            update.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL AND revision=3", .{session.slice()}));

            // Explicit equality is also accepted on create, including empty sets.
            var equal = try completeConfiguration("loaded-create-equal", "", workspace, "model-a");
            equal.configuration.tools = try .of(&.{"bash"});
            equal.configuration.loaded_tools = try .of(&.{"bash"});
            try std.testing.expect(storage.configure(&equal, .{}) == .accepted);
            try equal.key.set("loaded-create-empty");
            equal.configuration.tools = try .of(&.{});
            equal.configuration.loaded_tools = try .of(&.{});
            try std.testing.expect(storage.configure(&equal, .{}) == .accepted);
            try equal.key.set("loaded-create-unreachable");
            equal.configuration.tools = try .of(&.{"bash"});
            const rejected_create = storage.configure(&equal, .{});
            try std.testing.expect(rejected_create == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, rejected_create.rejected.code);
        }
    }.run);
}

test "loaded tools preserve and intersect a saved subset through the catalog" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // The production catalog now makes strict loaded subsets reachable.
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("loaded-subset-create", "", workspace, "model-a");
            initial.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            initial.configuration.loaded_tools = try .of(&.{ "bash", "find_tools" });
            const created = storage.configure(&initial, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            const loaded_id = try store_testing.queryU64(&storage, "SELECT loaded_tool_set_id FROM session WHERE session_ref=?1", .{session.slice()});
            try std.testing.expect(loaded_id > 0);

            // An unrelated update must preserve the saved set id.
            var update: protocol.ConfigureCommand = .{};
            try update.session.set(session.slice());
            try update.key.set("loaded-subset-label");
            update.configuration.label.state = .value;
            try update.configuration.label.value.set("same loaded subset");
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(loaded_id, try store_testing.queryU64(&storage, "SELECT loaded_tool_set_id FROM session WHERE session_ref=?1", .{session.slice()}));

            try update.key.set("loaded-subset-intersect");
            update.configuration.tools = try .of(&.{ "find_tools", "web_search" });
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=s.loaded_tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='find_tools'", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM session s JOIN tool_set t ON t.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1", .{session.slice()}));

            // Re-adding a configured tool does not implicitly load it.
            try update.key.set("loaded-subset-grow-tools");
            update.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM session s JOIN tool_set t ON t.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1", .{session.slice()}));

            try update.key.set("loaded-subset-unreachable");
            update.configuration.tools = try .of(&.{"bash"});
            const unreachable_set = storage.configure(&update, .{});
            try std.testing.expect(unreachable_set == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, unreachable_set.rejected.code);

            // Intersection with an empty tools set is equality, not an
            // unreachable subset, and normalizes to NULL.
            try update.key.set("loaded-subset-clear");
            update.configuration.tools = try .of(&.{});
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

            // Explicit equality uses NULL, including when clearing both sets.
            try update.key.set("loaded-subset-equal");
            update.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            update.configuration.loaded_tools = try .of(&.{ "bash", "find_tools", "web_search" });
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try update.key.set("loaded-subset-empty");
            update.configuration.tools = try .of(&.{});
            update.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
        }
    }.run);
}

// Engine transcripts and content boundary tests remain part of the native suite.
test {
    _ = @import("engine/Mysql.zig");
    _ = @import("engine/mysql_content.zig");
    _ = @import("mysql_testing.zig");
}

test "core_tools presets retain caller narrowing after overrides resolve" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("preset-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            try create.configuration.permission_mode.value.set("ask");
            const parent = storage.configure(&create, .{}).accepted.session;
            try submitTestMessage(&storage, &tmp, "preset-agent-message", "preset-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer memory.deinit();
            const arena = memory.allocator();
            const core_tools = @import("../core_tools.zig");
            const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
                \\{"model":"gpt-6.1-sol","effort":"low","compactAt":1000,"tools":["bash"],"permissionMode":"bypass"}
            , .{})).object;
            const presets = [_]core_tools.Preset{.{ .name = "worker", .spec = spec }};
            const arguments = [_][]const u8{
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\",\"spec\":{\"tools\":[],\"permissionMode\":\"ask\"}}",
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\"}",
                "{\"task\":\"read\",\"attached\":false,\"preset\":\"worker\",\"spec\":{\"tools\":[]}}",
            };
            var calls: [arguments.len]TestingCall = undefined;
            for (arguments, &calls, 0..) |bytes, *call, at| {
                const id = try std.fmt.allocPrint(arena, "preset-{d}", .{at});
                const encoded = try std.json.Stringify.valueAlloc(arena, bytes, .{});
                call.* = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = bytes };
            }
            try settleCallsForTesting(&storage, &tmp, model, "preset-agent-calls", &calls);
            const start = try arena.create(core_tools.StartAgent);
            for (arguments, 0..) |bytes, at| {
                const action = (try storage.nextCoreWork()).?.action;
                try std.testing.expect(try core_tools.checkStartAgentWithPresets(arena, bytes, &presets, start) == .accepted);
                const result = try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{});
                if (at == 0) {
                    try std.testing.expect(result == .started);
                } else {
                    try std.testing.expect(result == .failed);
                    const reason = if (at == 1)
                        "spec.tools: bash is not one of your tools. Nothing was started."
                    else
                        "spec.permissionMode: you ask before running commands, so your agents ask too. Nothing was started.";
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(reason) } }));
                }
            }
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "launch presets resolve MCP tools through the same catalog as configure" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const launch_frame = @import("../launch_frame.zig");
            const core_tools = @import("../core_tools.zig");
            var frame: launch_frame.Frame = .{};
            defer frame.deinit();
            var refusal: launch_frame.Refusal = undefined;
            try launch_frame.parse(std.testing.allocator,
                \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","mcpServers":[{"name":"pages","url":"http://127.0.0.1:3000/mcp","bearerToken":"t","callTimeoutMs":1000}],"presets":{"reader":{"model":"model-a","effort":null,"compactAt":1000,"tools":["fetch_page"],"permissionMode":"ask"}}}
            , &frame, &refusal);
            var records = [_]tool_catalog.Record{
                tool_catalog.bash_record,
                .{ .name = "fetch_page", .owner = .mcp, .server = "pages", .description = "Fetch page", .input_schema = "{\"type\":\"object\"}" },
                tool_catalog.find_tools_record,
                tool_catalog.message_agent_record,
                tool_catalog.read_transcript_record,
                tool_catalog.start_agent_record,
                tool_catalog.web_search_record,
            };
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_catalog.recordDigest(record);
            const offered: tool_catalog.Catalog = .{ .records = &records, .digests = &digests };
            var routes = protocol.routesAll(.unserved);
            routes.openai = .endpoint;
            for ([_]bool{ false, true }) |available| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{
                    .served = routes,
                    .catalog = if (available) &offered else &tool_catalog.built_in,
                });
                defer storage.close() catch unreachable;

                var direct: protocol.ConfigureCommand = .{};
                try direct.key.set("mcp-direct");
                direct.configuration.model.state = .value;
                try direct.configuration.model.value.set("model-a");
                direct.configuration.reasoning_effort.state = .explicit_null;
                direct.configuration.compaction_trigger.state = .value;
                try direct.configuration.compaction_trigger.value.set("1000");
                direct.configuration.tools = try .of(&.{"fetch_page"});
                direct.configuration.permission_mode.state = .value;
                try direct.configuration.permission_mode.value.set("ask");
                const ordinary = storage.configure(&direct, .{});

                var request: protocol.ConfigureCommand = .{ .preset = .{} };
                try request.key.set("mcp-preset");
                try request.preset.?.set("reader");
                var resolved: protocol.ConfigureCommand = .{ .key = request.key };
                var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer memory.deinit();
                try std.testing.expect(try core_tools.parseAgentSpec(memory.allocator(), frame.presets[0].spec, &resolved.configuration) == .accepted);
                const preset = storage.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{});
                if (available) {
                    try std.testing.expect(ordinary == .accepted);
                    try std.testing.expect(preset == .accepted);
                    for ([_]@TypeOf(ordinary.accepted.session){ ordinary.accepted.session, preset.accepted.session }) |session| {
                        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=s.tool_set_id " ++
                            "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{session.slice()}));
                    }
                } else {
                    try std.testing.expect(ordinary == .rejected);
                    try std.testing.expect(preset == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, ordinary.rejected.code);
                    try std.testing.expectEqual(ordinary.rejected.code, preset.rejected.code);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}

test "preset unknown rejection survives reopen and later resolution" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var request: protocol.ConfigureCommand = .{ .preset = .{} };
            try request.key.set("preset-unknown-replay");
            try request.preset.?.set("review");
            request.configuration.label.state = .value;
            try request.configuration.label.value.set("Review");
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const refused = storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .unknown_preset }, .{});
                try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, refused.rejected.code);
                const saved = try storage.observeCommand(request.key.slice());
                try std.testing.expectEqual(protocol.CommandObservationStatus.rejected, saved.status);
                try std.testing.expectEqualStrings("unknown_preset", saved.code.slice());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            }
            {
                var reopened: Store = undefined;
                try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
                defer reopened.close() catch unreachable;
                // The restarted Host now knows review, but the same original
                // request must replay its rejection, not admit this full spec.
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var resolved = try completeConfiguration(request.key.slice(), "", workspace, "model-a");
                resolved.configuration.label = request.configuration.label;
                const replay = reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, replay.rejected.code);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&reopened, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&reopened, "SELECT count(*) FROM core_command", .{}));
                // Neither a different name nor different overrides share that
                // rejection's identity, even if they resolve to the same spec.
                try request.preset.?.set("other");
                try std.testing.expect(reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{}) == .conflict);
                try request.preset.?.set("review");
                try request.configuration.label.value.set("Changed");
                try std.testing.expect(reopened.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{}) == .conflict);
                try std.testing.expect(reopened.configure(&resolved, .{}) == .conflict);
            }
        }
    }.run);
}

test "preset refusal cannot replace an accepted configure key" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("preset-bound-key", "", workspace, "model-a");
            const first = storage.configure(&create, .{});
            try std.testing.expect(first == .accepted);
            var request = create;
            request.preset = .{};
            try request.preset.?.set("missing");
            const result = storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .unknown_preset }, .{});
            try std.testing.expect(result == .conflict);
            const saved = try storage.observeCommand(create.key.slice());
            try std.testing.expectEqual(protocol.CommandObservationStatus.accepted, saved.status);
            try std.testing.expectEqualStrings(first.accepted.session.slice(), saved.target.slice());
            const replay = storage.configure(&create, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqualStrings(first.accepted.session.slice(), replay.accepted.session.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "preset on update rejection is durable and replayed before applying fields" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var request: protocol.ConfigureCommand = .{ .preset = .{} };
            try request.key.set("preset-update-replay");
            try request.preset.?.set("review");
            request.configuration.label.state = .value;
            try request.configuration.label.value.set("Must not apply");
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("preset-update-parent", "", workspace, "model-a");
                const first = storage.configure(&create, .{});
                try std.testing.expect(first == .accepted);
                request.session = first.accepted.session;
                const refused = storage.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{});
                try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, refused.rejected.code);
                const saved = try storage.observeCommand(request.key.slice());
                try std.testing.expectEqual(protocol.CommandObservationStatus.rejected, saved.status);
                try std.testing.expectEqualStrings("preset_on_update", saved.code.slice());
                try std.testing.expectEqualStrings(request.session.slice(), saved.target.slice());
                try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(request.session.slice())).revision);
            }
            {
                var reopened: Store = undefined;
                try store_testing.testingStore(case, &reopened, &tmp, std.testing.io);
                defer reopened.close() catch unreachable;
                const replay = reopened.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, replay.rejected.code);
                try request.preset.?.set("other");
                try std.testing.expect(reopened.configureWithPreset(&request, &.{ .request_digest = request.presetRequestDigest(), .rejection = .preset_on_update }, .{}) == .conflict);
                request.preset = null;
                try std.testing.expect(reopened.configure(&request, .{}) == .conflict);
                try std.testing.expectEqual(@as(u64, 1), (try reopened.inspectSessionForTesting(request.session.slice())).revision);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&reopened, "SELECT count(*) FROM session WHERE label IS NULL", .{}));
            }
        }
    }.run);
}

test "saved model facts replace generations and hide removed ids" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocator = std.testing.allocator;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const first = try @import("../models_dev.zig").parse(arena.allocator(),
                \\{"openai":{"models":{"a":{"limit":{"context":100},"reasoning_options":[{"type":"effort","values":["low","high"]}]},"b":{}}},"other":{"models":{"c":{}}}}
            );
            try std.testing.expect(try storage.readModelCatalogSource() == null);
            try storage.saveModelFacts(first, "\"one\"");
            const source = (try storage.readModelCatalogSource()).?;
            try std.testing.expectEqual(@as(u64, 1), source.generation);
            try std.testing.expectEqualStrings("\"one\"", source.etag.?.slice());
            try std.testing.expect(source.fetched_at > 0);
            const a = (try storage.modelFact("a")).?;
            try std.testing.expectEqual(@as(?u32, 100), a.context_window);
            try std.testing.expectEqual(@as(u8, @intCast(first[0].efforts.bits.mask)), a.efforts);
            try std.testing.expect(a.openai_listed);
            const ids = try storage.readOpenAiModelIds(allocator);
            defer {
                for (ids) |id| allocator.free(id);
                allocator.free(ids);
            }
            try std.testing.expectEqual(@as(usize, 2), ids.len);
            try std.testing.expectEqualStrings("a", ids[0]);
            try std.testing.expectEqualStrings("b", ids[1]);
            const second = try @import("../models_dev.zig").parse(arena.allocator(),
                \\{"openai":{"models":{"b":{"limit":{"context":200}}}}}
            );
            try storage.saveModelFacts(second, null);
            try std.testing.expectEqual(@as(u64, 2), (try storage.readModelCatalogSource()).?.generation);
            try std.testing.expect(try storage.modelFact("a") == null);
            try std.testing.expect(try storage.modelFact("c") == null);
            try std.testing.expectEqual(@as(?u32, 200), (try storage.modelFact("b")).?.context_window);
            try std.testing.expect((try storage.readModelCatalogSource()).?.etag == null);
            const current_ids = try storage.readOpenAiModelIds(allocator);
            defer {
                for (current_ids) |id| allocator.free(id);
                allocator.free(current_ids);
            }
            try std.testing.expectEqual(@as(usize, 1), current_ids.len);
            try std.testing.expectEqualStrings("b", current_ids[0]);
        }
    }.run);
}

test "model fact effort masks are format-defined on every engine" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // These fixed bits, not a loop index or inferred enum value, are
            // part of the Store format. Reordering tags must fail this test.
            const cases = .{ .{ .none, 1 }, .{ .low, 2 }, .{ .medium, 4 }, .{ .high, 8 }, .{ .xhigh, 16 }, .{ .max, 32 } };
            inline for (cases) |effort| {
                try storage.saveModelFacts(&.{.{ .id = "effort", .context_window = null, .efforts = .initOne(effort[0]), .openai_listed = false }}, null);
                try std.testing.expectEqual(@as(u8, effort[1]), (try storage.modelFact("effort")).?.efforts);
            }
            const insert = "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) VALUES(?1,NULL,?2,0,1)";
            const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.StatementFailed;
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "below", @as(i64, -1) }));
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, insert, .{ "above", @as(i64, 64) }));
            try store_testing.exec(&storage, insert, .{ "empty", @as(i64, 0) });
            try store_testing.exec(&storage, insert, .{ "full", @as(i64, 63) });
        }
    }.run);
}
