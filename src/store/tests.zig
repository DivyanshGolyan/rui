//! The Store's tests and their helpers.

const std = @import("std");
const named_scratch = @import("../named_scratch.zig");
const protocol = @import("../protocol.zig");
const wire_request = @import("../wire_request.zig");
const tool_defs = @import("../tools.zig");
const tool_set_domain = @import("domain/tool_set.zig");

/// Asserts exact saved-set membership by names, independent of tool ownership.
pub fn expectToolSetNames(storage: *Store, set: u64, names: []const []const u8) !void {
    try std.testing.expectEqual(@as(u64, @intCast(names.len)), try store_testing.queryU64(storage, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=?1", .{set}));
    for (names) |name| try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(storage, "SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 AND tool.name=?2", .{ set, name }));
}

// A stored Host tool set must contain every native tool. Keep that inventory
// canonical while each fixture independently states its MCP schema and offer.
pub fn testingHostToolRecords(comptime extras: []const tool_defs.Record) [tool_defs.built_in_tool_set.records.len + extras.len]tool_defs.Record {
    var records = tool_defs.built_in_tool_set.records[0..tool_defs.built_in_tool_set.records.len].* ++ extras[0..extras.len].*;
    std.sort.heap(tool_defs.Record, &records, {}, struct {
        fn lessThan(_: void, left: tool_defs.Record, right: tool_defs.Record) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return records;
}
const model_capability = @import("../model_capability.zig");
const product_defaults = @import("../product_defaults.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const transition = @import("transition.zig");
const rsql = @import("rsql.zig");
const Store = store_core.Store;
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const operation_effort = @import("domain/operation_effort.zig");
const content_domain = @import("domain/content.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const session_list_read_domain = @import("domain/session_list_read.zig");
const session_list_reply = @import("../session_list_reply.zig");
const session_report = @import("../session_report.zig");
const session_report_read_domain = @import("domain/session_report_read.zig");
const session_report_reply = @import("../session_report_reply.zig");
const store_schema = @import("schema.zig");
const store_testing = @import("testing.zig");
const turn_domain = @import("domain/turn.zig");
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const AttemptBinding = store_core.AttemptBinding;
const ActionExecutionInput = action_domain.ActionExecutionInput;
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
const ScratchBudget = @import("../ScratchBudget.zig");
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
    _ = @import("domain/configuration.zig");
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

pub fn testingContent(tmp: *std.testing.TmpDir, name: []const u8, fill: u8, length: usize) !wire_request.ContentField {
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

pub fn testingBytesContent(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !wire_request.ContentField {
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

pub fn admitRetryForTesting(storage: *Store) !?AttemptAdmission {
    return storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, null);
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

pub fn configureTestSessionWithMode(
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
    const reply = try storage.configure(&command, .{});
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
    return testingSessionReportWithExecution(storage, tmp, session_ref, limit, profile, .{
        .dispatch_fenced = false,
        .custody_occupied = 0,
        .scratch_used_bytes = 0,
    });
}

pub fn testingSessionReportWithExecution(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session_ref: []const u8,
    limit: u64,
    profile: protocol.ReportProfile,
    execution: session_report.Execution,
) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    var report = try testingCaptureSessionReport(storage, session_ref, .{
        .scratch_path = root[0..root_length],
        .scratch_budget = .{ .used = &used, .limit = limit },
        .request_number = 1,
        .profile = profile,
        .execution = execution,
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
/// and active approval work and a pending MCP call. The caller supplies the
/// schema checker.
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
            try mcp(engine, checker, Profiles);
        }

        /// An unresolved MCP call, which names an MCP tool and its server.
        fn mcp(engine: *store_testing.Case, checker: @TypeOf(context), comptime Profiles: type) !void {
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
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var command = try completeConfiguration("schema-mcp", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            command.configuration.tools = try .of(&.{"fetch_page"});
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "schema-mcp-input", "schema-mcp-key", session.slice(), "fetch a page");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, binding, "schema-mcp-calls", &.{
                .{ .item_id = "mcp-item", .name = "fetch_page", .encoded_call_id = "mcp-call", .decoded_call_id = "mcp-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            });
            const pending = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
            defer std.testing.allocator.free(pending);
            const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending, .{});
            defer json.deinit();
            const unresolved = json.value.object.get("actions").?.object.get("unresolved").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), unresolved.len);
            try std.testing.expectEqualStrings("fetch_page", unresolved[0].object.get("tool").?.string);
            try std.testing.expectEqualStrings("docs", unresolved[0].object.get("server").?.string);
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

pub const TestingReportReply = session_report_reply.Reply(report_domain.SessionReportCapture);

pub const TestingReportOptions = struct {
    scratch_path: []const u8,
    scratch_budget: ScratchBudget,
    request_number: u64,
    profile: protocol.ReportProfile = .current,
    execution: session_report.Execution,
    fail_unlink: bool = false,
};

/// A report captured as the server captures one: the Store's read
/// written by the Host's reply into an unlinked scratch file.
pub fn testingCaptureSessionReport(storage: *Store, session_ref: []const u8, options: TestingReportOptions) !SessionReport {
    var capture: report_domain.SessionReportCapture = .{ .io = storage.io, .writer = null, .budget = options.scratch_budget };
    try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
    errdefer capture.deinit();
    var reply: TestingReportReply = .{ .capture = &capture, .execution = options.execution };
    try storage.readSessionReport(session_ref, options.profile, &reply);
    return capture.seal();
}

pub const TestingListReply = session_list_reply.Reply(report_domain.SessionReportCapture);

/// A list page captured as the server captures one: the Store's read
/// written by the Host's reply into an unlinked scratch file.
pub fn testingSessionListReport(storage: *Store, request: *const protocol.ListSessions, scratch_path: []const u8, budget: ScratchBudget, request_number: u64) !SessionReport {
    try request.validate();
    var capture: report_domain.SessionReportCapture = .{ .io = storage.io, .writer = null, .budget = budget };
    try capture.create(scratch_path, request_number, false);
    errdefer capture.deinit();
    var reply: TestingListReply = .{ .capture = &capture };
    try storage.readSessionList(request, &reply);
    return capture.seal();
}

pub fn testingSessionList(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions, used: *std.atomic.Value(u64), request_number: u64) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var report = try testingSessionListReport(storage, &request, root[0..length], .{ .used = used, .limit = 1024 * 1024 }, request_number);
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
            const version = try protocol.SinceToken.parse(row.object.get("read_version").?.string);
            try std.testing.expectEqualDeep(protocol.SinceToken{ .instance = storage.instance, .generation = storage.commitGeneration() }, version);
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

pub fn testingIdLess(_: void, left: change_ring.Id, right: change_ring.Id) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

/// What a `TestingScript` body asks for after a step.
pub const TestingAsk = enum { round, commit, done };

/// A test's own steps on the runner's writer, inside one transaction:
/// `Body.step(body, r, ran)` queues on `r`, the step's `transition.Round`,
/// and asks for another round, the commit, or the end, which rolls back;
/// `ran` counts the rounds run before it. A test that holds what the writer
/// does within and between rounds reaches it as a production step does: it
/// never opens a writer itself, and only the runner runs or commits.
/// `Body` declares `Guards`, and optionally `pass` and `failed(body)`,
/// which the runner calls on an error before its transaction rolls back.
pub fn TestingScript(comptime Body: type) type {
    return struct {
        const Self = @This();
        /// One round, which runs as often as the body asks.
        pub const rounds = transition.rounds(.{ .round = .{.paged} });
        pub const round_budget = 1;
        pub const commit: transition.Commit = .transaction;
        pub const pass: transition.Pass = if (@hasDecl(Body, "pass")) Body.pass else .ordinary;
        pub const begin: ?rounds.At = .round;
        pub const Input = *Body;
        pub const Result = void;
        pub const Ordinary = error{};
        pub const Guards = Body.Guards;
        pub const Declined = error{};

        input: Input,
        ran: u32 = 0,

        pub fn step(t: *Self, r: *transition.Round(Self), ran: ?rounds.At) !transition.Next(Self) {
            if (ran != null) t.ran += 1;
            return switch (try t.input.step(r, t.ran)) {
                .round => .{ .round = .round },
                .commit => .commit,
                .done => .{ .done = {} },
            };
        }

        pub fn committed(_: *const Self) Result {}

        pub fn failed(t: *Self) void {
            if (comptime @hasDecl(Body, "failed")) t.input.failed();
        }

        /// Runs `body`'s steps under `entry`'s lock.
        pub fn run(entry: *const store_core.Entry, body: *Body) !void {
            var t: Self = .{ .input = body };
            return transition.run(entry, Self, &t, .{});
        }
    };
}

/// A `TestingScript` body that prepares, validates and applies
/// `configuration` as Configure's steps do, one round at a time, then runs
/// the round its writes queued and ends, rolling them back. `Check`, held
/// as `check`, may declare `ready(check, plan, reads)`, called once
/// validation readied `plan`, and `applied(check, plan, reads, applied)`,
/// called once application accepted it, both in the transaction.
pub fn TestingConfiguring(comptime Check: type) type {
    return struct {
        const Self = @This();
        pub const Guards = error{SessionUpdateFailed};

        storage: *Store,
        /// Empty for a creation.
        session: []const u8,
        configuration: *const @FieldType(wire_request.ConfigureCommand, "configuration"),
        check: Check = .{},
        reads: *configuration_domain.ConfigurationReads = undefined,
        saved: tool_set_domain.SavedSelection = undefined,
        /// What validation readied.
        plan: *const configuration_domain.ValidatedConfiguration = undefined,
        at: union(enum) {
            prepare,
            validate: ?configuration_domain.ValidationRound,
            apply: ?configuration_domain.ApplyRound,
            written,
        } = .prepare,

        pub fn step(b: *Self, r: anytype, _: u32) !TestingAsk {
            const request: configuration_domain.Request = .{
                .io = b.storage.io,
                .tools = b.storage.hostTools(),
                .served = b.storage.served,
                .session = b.session,
                .configuration = b.configuration,
                .initial_skills = null,
                .saved = &b.saved,
            };
            while (true) switch (b.at) {
                .prepare => {
                    b.reads = r.configurationReads();
                    b.reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
                    configuration_domain.prepareConfiguration(r, b.storage.hostTools().host_tool_set, b.session, b.configuration, b.reads);
                    b.at = .{ .validate = null };
                    return .round;
                },
                .validate => |ran| switch (try configuration_domain.validateStep(r, &request, b.reads, ran)) {
                    .round => |next| {
                        b.at = .{ .validate = next };
                        return .round;
                    },
                    .rejected => return error.TestUnexpectedResult,
                    .ready => |plan| {
                        b.plan = plan;
                        if (comptime @hasDecl(Check, "ready")) try b.check.ready(plan, b.reads);
                        b.at = .{ .apply = null };
                    },
                },
                .apply => |ran| switch (try configuration_domain.applyStep(r, &request, r.faults(), b.reads, ran)) {
                    .round => |next| {
                        b.at = .{ .apply = next };
                        return .round;
                    },
                    .accepted => |applied| {
                        if (comptime @hasDecl(Check, "applied")) try b.check.applied(b.plan, b.reads, applied);
                        b.at = .written;
                        return .round;
                    },
                },
                .written => return .done,
            };
        }
    };
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
};

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
    // Both an upcoming retry and its elapsed/pending projection are unsafe
    // for commit-only tokens, including when the wall clock moves backward.
    if (page.work.work.state == .retrying or page.work.work.state == .pending)
        try std.testing.expect(page.token == null);
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

/// Reconcile after a fixture changes immutable times or topology outside a
/// Store entry point. Production transitions enter this owner automatically.
pub fn refreshFrontierForTesting(storage: *Store, session: []const u8) !void {
    return refreshFrontiersForTesting(storage, &.{session});
}

pub fn refreshFrontiersForTesting(storage: *Store, sessions: []const []const u8) !void {
    std.debug.assert(sessions.len > 0 and sessions.len <= 4);
    const Refresh = struct {
        pub const Guards = error{};
        const head = rsql.Read(.{
            .sql = "SELECT session_ref,workspace_key,next_position FROM session WHERE session_ref=?1",
            .Args = struct { session: []const u8 },
            .Row = struct { session: rsql.SessionHead },
            .cardinality = .optional,
        });
        refs: []const []const u8,
        rows: [4]head.Result = undefined,

        pub fn step(b: *@This(), r: anytype, ran: u32) !TestingAsk {
            if (ran == 0) {
                for (b.refs, b.rows[0..b.refs.len]) |ref, *row| r.read(head, .{ .session = ref }, row);
                return .round;
            }
            for (b.rows[0..b.refs.len]) |row| r.obligationsChanged((row orelse return error.CorruptStore).session);
            return .commit;
        }
    };
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var refresh: Refresh = .{ .refs = sessions };
    return entry.finishTransaction(store_core.Ordinary.none, .{}, TestingScript(Refresh).run(&entry, &refresh));
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

pub fn denyForTesting(storage: *Store, session: []const u8, key: []const u8, action_id: u64) !void {
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .deny };
    try deny.key.set(key);
    try deny.session.set(session);
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
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
pub fn nextTestingItem(view: *HistoricalView, after: u64) !?HistoricalEntry {
    var position = after;
    while (try view.nextEntry(position)) |entry| {
        if (entry.kind != .operation) return entry;
        position = entry.position;
    }
    return null;
}

/// Opens `view` and reads its settings, whose round checks the binding;
/// a view that fails is closed.
pub fn openCheckedView(storage: *Store, binding: AttemptBinding, view: *HistoricalView) !void {
    storage.openHistoricalView(binding, view);
    var settings: HistoricalSettings = undefined;
    view.settings(&settings) catch |err| {
        view.close();
        return err;
    };
}

/// The rounds and content rounds `store` took since `start`.
pub const ViewRounds = struct {
    store: *Store,
    rounds: u16,
    content_rounds: u16,

    pub fn start(store: *Store) ViewRounds {
        return .{ .store = store, .rounds = store.testing_content_work.rounds, .content_rounds = store.testing_content_work.content_rounds };
    }

    pub fn taken(self: ViewRounds) struct { rounds: u16, content_rounds: u16 } {
        return .{ .rounds = self.store.testing_content_work.rounds - self.rounds, .content_rounds = self.store.testing_content_work.content_rounds - self.content_rounds };
    }
};

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

/// `session`'s Full history read alone, on an Access of its own, and
/// written by the Host's reply as it follows the Current facts, inside
/// `{"head":0...}` so it parses. The bytes are the caller's; `rounds` gets
/// the rounds `readFull` ran, not its `readRaw` windows.
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
        var reply: TestingReportReply = .{ .capture = &capture, .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 } };
        var watched: session_report_read_domain.Watched(*TestingReportReply) = .{ .visitor = &reply };
        const before = storage.testing_content_work.rounds;
        try report_domain.readFull(&a, session, &watched);
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
            .content = (try store_testing.observeCommandForTesting(storage, "attempt-message")).kind.message.?.content,
        };
    }

    pub fn handoff(_: void) !void {}
};

/// The functions that enter the Store (`enter(self, ...)`), each a
/// separate transition while the Store is held, by the name the source
/// gives it (less the `Held` of a body an entry point queues).
pub const EntryPoint = enum {
    saveHostToolSet,
    saveModelFacts,
    readModelCatalogSource,
    readModelCatalog,
    modelFact,
    readOpenAiModelIds,
    readHostToolSetSet,
    readHostToolSetRecords,
    readHostToolSetText,
    commandExists,
    readSkills,
    settleSkillTool,
    configure,
    submitMessageWithModel,
    stopSession,
    archiveSession,
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
    failedResponseBinding,
    readSessionReport,
    readSessionList,
    actionContent,
    admitModelAttempt,
    admitNextActionAttempt,
    readBashExecutionInput,
    admitActionAttempt,
    readMcpExecutionInput,
    revokeActionSender,
    nextCoreWork,
    nextAction,
    resolveAction,
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
    dispatchWork,
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
    readHistoricalParts,
    readHistoricalToolResult,
    readTools,
    readProviderTool,
    checkAttempt,
};

/// Each entry point's rounds (`Access.run` and `commit`, counted in
/// `Store.testing_content_work.rounds`) on the path the round budget test
/// drives it. Content rounds (`readRaw` windows) differ by engine, so
/// `content_round_budgets` holds them apart. Frontier maintenance shares the
/// existing write/COMMIT round, regardless of ancestry. Otherwise settled work
/// reads add one saved-key read, never a tree seed.
pub const round_budgets: std.EnumArray(EntryPoint, u32) = .init(.{
    .commandExists = 1,
    .readSkills = 2,
    .settleSkillTool = 3,
    .configure = 4,
    .submitMessageWithModel = 2,
    .stopSession = 2,
    .archiveSession = 2,
    .interruptModel = 2,
    .decidePermission = 2,
    .observeCommand = 3,
    .commandResult = 1,
    .inspectSession = 3,
    .publicConversationPage = 4,
    .openPublicConversationContent = 2,
    .activityPage = 8,
    .searchActivity = 5,
    .openActivityContent = 4,
    .activityTool = 4,
    .failedResponseBinding = 1,
    .readSessionReport = 6,
    .readSessionList = 7,
    .actionContent = 2,
    .admitModelAttempt = 2,
    .admitNextActionAttempt = 2,
    .readBashExecutionInput = 2,
    .admitActionAttempt = 2,
    .readMcpExecutionInput = 3,
    .revokeActionSender = 2,
    .nextCoreWork = 3,
    .nextAction = 1,
    .resolveAction = 2,
    .deliverAgentMessage = 3,
    .deliverChildEnding = 2,
    .deliverSessionForward = 2,
    .startAgent = 5,
    .findTools = 5,
    .stopOwedSession = 2,
    .resolveCoreCall = 2,
    .actionSupersededByStop = 1,
    .withActionDispatchHandoff = 1,
    .settleActionAttempt = 3,
    .recoverOneUncertainAction = 1,
    .tryAdmitNextModelRetry = 1,
    .dispatchWork = 1,
    .operationSupersededByControl = 1,
    .withDispatchHandoff = 1,
    .claimModelAuthRefresh = 2,
    .settleModelAttemptFailure = 2,
    .recoverOneExhaustedModelAttempt = 1,
    .settleModelSuccess = 2,
    .openContentIdentity = 1,
    .readOwnedContent = 0,
    .readHistoricalSettings = 1,
    .readHistoricalEntry = 1,
    .validateHistoricalOutputsStep = 1,
    .readPrefixSeal = 1,
    .recordPrefixSeal = 2,
    // The entry batch's page already holds the item's parts.
    .readHistoricalParts = 0,
    .readHistoricalToolResult = 1,
    // A page of a tool walk, which holds the tools after its first.
    .readTools = 1,
    .readProviderTool = 1,
    .checkAttempt = 1,
    .saveModelFacts = 2,
    .readModelCatalogSource = 1,
    .readModelCatalog = 1,
    .modelFact = 1,
    .readOpenAiModelIds = 1,
    // A Host tool set is saved once; each later open finds it.
    .saveHostToolSet = 1,
    .readHostToolSetSet = 1,
    .readHostToolSetRecords = 1,
    .readHostToolSetText = 0,
});

pub const RoundMeter = struct {
    storage: *Store,
    rounds_before: u16 = 0,
    content_before: u16 = 0,
    shape_before: QueryShape = .{},
    measured: std.EnumArray(EntryPoint, ?Measured) = .initFill(null),

    pub const Measured = struct { rounds: u16, content_rounds: u16, shape: QueryShape };

    /// Actual protocol sends beside independently counted semantic work.
    /// Empty Access rounds send nothing; deferred BEGIN/SAVEPOINT share the
    /// next pass, RELEASE sends nothing, and only real controls count here.
    pub const QueryShape = struct {
        queries: u64 = 0,
        access_passes: u64 = 0,
        identity_passes: u64 = 0,
        content_queries: u64 = 0,
        controls: u64 = 0,
        prefix_only: u64 = 0,

        pub fn snapshot(storage: *Store) QueryShape {
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

        pub fn since(after: QueryShape, before: QueryShape) QueryShape {
            var delta: QueryShape = undefined;
            inline for (@typeInfo(QueryShape).@"struct".field_names) |name|
                @field(delta, name) = @field(after, name) - @field(before, name);
            return delta;
        }

        pub fn expected(shape: QueryShape) u64 {
            return shape.access_passes + shape.identity_passes + shape.content_queries + shape.controls + shape.prefix_only;
        }
    };

    pub fn start(meter: *RoundMeter) void {
        meter.rounds_before = meter.storage.testing_content_work.rounds;
        meter.content_before = meter.storage.testing_content_work.content_rounds;
        meter.shape_before = QueryShape.snapshot(meter.storage);
    }

    pub fn stop(meter: *RoundMeter, point: EntryPoint) void {
        std.debug.assert(meter.measured.get(point) == null);
        meter.measured.set(point, .{
            .rounds = meter.storage.testing_content_work.rounds - meter.rounds_before,
            .content_rounds = meter.storage.testing_content_work.content_rounds - meter.content_before,
            .shape = QueryShape.snapshot(meter.storage).since(meter.shape_before),
        });
    }
};

/// A `start_agent` spec as the Host's check leaves it: gpt-6.1-sol at low
/// effort, `tools`, `permission_mode` and no label.
pub fn testingAgentSpec(tools: []const []const u8, permission_mode: []const u8) !wire_request.Configuration {
    var spec: wire_request.Configuration = .{};
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

// The rounds twins of the work tests in sqlite_tests/. Each test there
// holds a population's VM steps or statements still, which only SQLite
// shows; its twin in tests/ holds the rounds of the same work at the same
// two sizes, which every engine shows.

/// The rounds `store` took since `start`: its Accesses' runs and commits.
pub const TwinRounds = struct {
    store: *Store,
    before: u16,

    pub fn start(store: *Store) TwinRounds {
        return .{ .store = store, .before = store.testing_content_work.rounds };
    }

    pub fn taken(self: TwinRounds) u16 {
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

/// `failed_operations_sql`, the Operations alternating in purpose.
pub const failed_purpose_operations_sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
    "output_reservation,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window,request_codec,request_codec_options) " ++
    "WITH RECURSIVE sequence(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM sequence WHERE value<?1) " ++
    "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
    "0,1,'failed',1,current.tool_set_id,current.context_window,current.request_codec,current.request_codec_options FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2";

// Engine transcripts and content boundary tests remain part of the native suite.
test {
    _ = @import("engine/Mysql.zig");
    _ = @import("engine/mysql_content.zig");
    _ = @import("mysql_testing.zig");
}

/// Two real attempted Actions whose unknown outcomes are saved by recovery.
pub fn recoverPairForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, prefix: []const u8) ![2]u64 {
    try settleTwoActionsForTesting(storage, tmp, binding, prefix);
    var ids: [2]u64 = undefined;
    for (&ids) |*id| id.* = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding.action_id;
    for (ids) |_| try std.testing.expect(try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
    return ids;
}

const runtime_catalog = @import("../model_catalog.zig");

// Native filesystem capture belongs to the Host. These distinct, immutable
// values exercise only the Store's composed transaction and provenance owners.
const skills_fixture_domain = @import("domain/skills.zig");

/// Both real format-69 fixtures call this after the owning 69 -> 70 step.
/// The fixed historical rows contain a finished root and two Bash calls in
/// its attached child's open Turn, one authorized and one awaiting approval.
pub fn expectWireMigrationFacts(storage: *Store, tmp: *std.testing.TmpDir) !void {
    _ = try expectOneWork(storage, tmp, "d8mv7p", "working");
    _ = try expectOneWork(storage, tmp, "brhkcj", "pending");
    var row = try testingListRow(storage, tmp, "brhkcj");
    defer row.deinit();
    try std.testing.expectEqualStrings("d8mv7p", row.get(&.{"parent"}).string);
    var child: protocol.Bounded(protocol.max_session_bytes) = .{};
    try child.set("brhkcj");
    const page = try store_core.activityPageForTesting(storage, .{ .session = child, .kinds = .initMany(&.{ .call, .approval_requested }) });
    try std.testing.expectEqual(@as(usize, 4), page.count);
    var calls: usize = 0;
    var approvals: usize = 0;
    for (page.items[0..page.count]) |item| {
        const ordinal = switch (item.value) {
            .call => |call| ordinal: {
                calls += 1;
                try std.testing.expectEqualStrings("bash", call.tool.?.slice());
                try std.testing.expectEqualStrings(if (call.call_ordinal == 0) "Run first command" else "Run second command", call.description.?.slice());
                try std.testing.expect(call.server == null);
                break :ordinal call.call_ordinal;
            },
            .approval_requested => |approval| ordinal: {
                approvals += 1;
                try std.testing.expectEqualStrings("brhkcj", approval.session.slice());
                try std.testing.expectEqualStrings("bash", approval.tool.?.slice());
                try std.testing.expectEqualStrings(if (approval.call_ordinal == 0) "Run first command" else "Run second command", approval.description.?.slice());
                try std.testing.expect(approval.server == null);
                break :ordinal approval.call_ordinal;
            },
            else => return error.UnexpectedActivity,
        };
        try expectActivityArguments(storage, child, item, if (ordinal == 0)
            "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}"
        else
            "{\"description\":\"Run second command\",\"cmd\":\"two\",\"timeout_ms\":null}");
    }
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 2), approvals);
}

pub fn expectActivityArguments(storage: *Store, session: protocol.Bounded(protocol.max_session_bytes), item: protocol.ActivityItem, expected: []const u8) !void {
    var reader: ContentReader = undefined;
    reader.open(try storage.openActivityContent(&.{ .session = session, .position = item.position, .ordinal = item.ordinal }));
    defer reader.close();
    var bytes: [1024]u8 = undefined;
    const length = try reader.read(0, &bytes);
    try std.testing.expectEqualStrings(expected, bytes[0..length]);
}

pub const membership_records = store_testing.hostToolRecordsWith(&.{.{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" }});
pub fn membershipToolSet(digests: *[membership_records.len][32]u8) tool_defs.HostToolSet {
    for (&membership_records, digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
    return .{ .records = &membership_records, .digests = digests };
}
