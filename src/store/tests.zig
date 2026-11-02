//! The Store's tests and their helpers.

const std = @import("std");
const named_scratch = @import("../named_scratch.zig");
const platform = @import("../platform.zig");
const protocol = @import("../protocol.zig");
const model_capability = @import("../model_capability.zig");
const product_defaults = @import("../product_defaults.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const Store = @import("Store.zig");
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
const sqlite = @import("sqlite.zig");
const turn_domain = @import("domain/turn.zig");
const c = sqlite.c;
const AcceptedMessage = command_domain.AcceptedMessage;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const AttemptBinding = Store.AttemptBinding;
const BashExecutionInput = action_domain.BashExecutionInput;
const ConfigurationContentAction = configuration_domain.ConfigurationContentAction;
const ConfigurationUpdatePlan = configuration_domain.ConfigurationUpdatePlan;
const ConfigureReply = configuration_domain.ConfigureReply;
const ContentReader = content_domain.ContentReader;
const ContentReference = content_domain.ContentReference;
const ControlTracePhase = Store.ControlTracePhase;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const Faults = Store.Faults;
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
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const SessionReport = report_domain.SessionReport;
const SessionStopReply = command_domain.SessionStopReply;
const SettlementTracePhase = Store.SettlementTracePhase;
const StatementCache = sqlite.StatementCache;
const TurnOutcome = turn_domain.TurnOutcome;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const activity_sequence_guard_sql = reads_domain.activity_sequence_guard_sql;
const empty_active_context = action_domain.empty_active_context;
const next_action_attempt_sql = action_domain.next_action_attempt_sql;
const pending_message_count_sql = command_domain.pending_message_count_sql;
const queued_sql = reads_domain.queued_sql;
const retry_admission_page_rows = model_admission_domain.retry_admission_page_rows;
const retry_admission_select_sql = model_admission_domain.retry_admission_select_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;
const runnable_selection_sql = model_admission_domain.runnable_selection_sql;
const schema_version = store_schema.schema_version;
const session_stop_cutoff_sql = command_domain.session_stop_cutoff_sql;
const sqlite_heap_bytes = sqlite.sqlite_heap_bytes;
const tool_continuation_selection_sql = model_admission_domain.tool_continuation_selection_sql;
const workspace_key_sql = sqlite.workspace_key_sql;

const OutputMetadataWriter = output_format.OutputMetadataWriter;
const output_metadata_record_bytes = output_format.output_metadata_record_bytes;

test {
    _ = @import("rsql.zig");
}

/// Tests read a view's settings by value; the Host fills them in place.
fn testSettings(view: *HistoricalView) !HistoricalSettings {
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    return settings;
}

fn testingStore(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return storage.open(io, database, root) catch |err| {
        std.debug.print("testing Store open failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "Store allocates six character IDs atomically retries collisions and replays creation" {
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
    try testingStore(&storage, &tmp, io);
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
    try std.testing.expectEqualStrings("model-a", (try storage.readSessionForTesting(a.session.slice())).?.model.slice());
    try std.testing.expectEqualStrings("model-b", (try storage.readSessionForTesting(b.session.slice())).?.model.slice());
    const replay = storage.configure(&second, .{}).accepted;
    try std.testing.expect(replay.replayed and replay.created);
    try std.testing.expectEqualStrings(b.session.slice(), replay.session.slice());
    try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
    const current = (try storage.readSessionForTesting(a.session.slice())).?;
    for ([_][]const u8{ "short", "1234567", "K7m2qx", "k7m2qi", "k7m\x00qx" }) |invalid| {
        try std.testing.expectError(error.StatementFailed, configuration_domain.insertSession(&storage, invalid, &current));
    }
    var unknown = try completeConfiguration("unknown-update", "k7m2qx", workspace, "model-c");
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, storage.configure(&unknown, .{}).rejected.code);
    try std.testing.expect(try storage.readSessionForTesting("k7m2qx") == null);
    for ([_][]const u8{ "old/name", "K7m2qx", "k7m2qi", "k7\x00qx" }, 0..) |invalid, index| {
        var key: [32]u8 = undefined;
        var bad = try completeConfiguration(try std.fmt.bufPrint(&key, "invalid-id-{d}", .{index}), invalid, workspace, "model-c");
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, storage.configure(&bad, .{}).rejected.code);
    }
    try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
    try std.testing.expect(!storage.isFenced());
}

test "Store distinguishes noncanonical Session references from canonical unknown messages and controls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM message_admission"));
}

test "Store open failures return typed errors without unwinding panics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    // A database path below a missing directory cannot be created; the open
    // must fail as a typed error rather than unwrapping a null handle.
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/missing-dir/store.sqlite3", .{root});
    var refused: Store = undefined;
    try std.testing.expectError(error.StoreOpenFailed, refused.open(std.testing.io, database, root));
}

fn createMaximumCanonicalStore(tmp: *std.testing.TmpDir, path_buffer: []u8) ![]const u8 {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const relative_length = protocol.max_store_bytes - root.len - 1;
    var relative_buffer: [protocol.max_store_bytes]u8 = undefined;
    var offset: usize = 0;
    var remaining = relative_length;
    while (remaining > 255) {
        @memset(relative_buffer[offset .. offset + 255], 'a');
        relative_buffer[offset + 255] = '/';
        offset += 256;
        remaining -= 256;
    }
    if (remaining == 0) return error.InvalidStoreTestPath;
    @memset(relative_buffer[offset .. offset + remaining], 'b');
    const relative = relative_buffer[0 .. offset + remaining];
    var directory = try tmp.dir.createDirPathOpen(std.testing.io, relative, .{
        .permissions = .fromMode(0o700),
    });
    directory.close(std.testing.io);
    const path = try std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ root, relative });
    std.debug.assert(path.len == protocol.max_store_bytes);
    return path;
}

fn completeConfiguration(key: []const u8, session_ref: []const u8, workspace: []const u8, model: []const u8) !protocol.ConfigureCommand {
    var command: protocol.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set(model);
    return command;
}

fn completeMessage(
    key: []const u8,
    session_ref: []const u8,
    file: std.Io.File,
    text: []const u8,
) !protocol.MessageCommand {
    var command: protocol.MessageCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.text = .{
        .state = .value,
        .file = file,
        .length = text.len,
        .digest = protocol.contentDigest(text),
    };
    return command;
}

fn canonicalCwd(io: std.Io, buffer: []u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer directory.close(io);
    const length = try directory.realPath(io, buffer);
    return buffer[0..length];
}

fn testingContent(tmp: *std.testing.TmpDir, name: []const u8, fill: u8, length: usize) !protocol.ContentField {
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

fn testingBytesContent(tmp: *std.testing.TmpDir, name: []const u8, bytes: []const u8) !protocol.ContentField {
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

/// Test aid: statements left mid-step. Cached statements are reset and idle;
/// read blobs must close before the Store entry point returns.
fn busyStatements(database: *c.sqlite3) usize {
    var count: usize = 0;
    var statement = c.sqlite3_next_stmt(database, null);
    while (statement) |current| : (statement = c.sqlite3_next_stmt(database, current)) {
        if (c.sqlite3_stmt_busy(current) != 0) count += 1;
    }
    return count;
}

fn queryU64(database: *c.sqlite3, sql: [:0]const u8) !u64 {
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

fn querySessionU64(database: *c.sqlite3, sql: [:0]const u8, session: []const u8) !u64 {
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

fn execSessionSql(database: *c.sqlite3, sql: [:0]const u8, session: []const u8) !void {
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    try sqlite.expectDone(statement);
}

const testing_absent_model_evidence: protocol.Bounded(775) = .{
    .bytes = .{1} ++ @as([774]u8, @splat(0)),
    .len = 7,
};

fn admitRetryForTesting(storage: *Store) !?AttemptAdmission {
    return storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{});
}

fn completeSessionStop(key: []const u8, session_ref: []const u8) !protocol.SessionStopCommand {
    var command: protocol.SessionStopCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    return command;
}

fn completeModelInterruption(
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

fn expectActivityOutcome(storage: *Store, session: []const u8, binding: AttemptBinding, code: []const u8) !void {
    var request: protocol.ActivityPage = .{ .direction = .backward };
    try request.session.set(session);
    const page = try storage.activityPageForTesting(request);
    try std.testing.expect(page.count != 0 and page.items[0].value == .outcome);
    const outcome = page.items[0].value.outcome;
    try std.testing.expectEqual(binding.turn_id, outcome.turn);
    try std.testing.expectEqual(binding.operation_id, outcome.operation);
    try std.testing.expectEqualStrings(code, outcome.code.slice());
    try std.testing.expectEqual(page.end, page.items[0].position);
}

fn configureTestSession(
    storage: *Store,
    key: []const u8,
) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, "", workspace, "model-a");
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

fn configureTestSessionAsk(
    storage: *Store,
    key: []const u8,
) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, "", workspace, "model-a");
    command.configuration.tools.state = .value;
    command.configuration.tools.count = 1;
    command.configuration.tools.values[0] = .bash;
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

fn submitTestMessage(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    file_name: []const u8,
    key: []const u8,
    session_ref: []const u8,
    text: []const u8,
) !void {
    const file = try tmp.dir.createFile(std.testing.io, file_name, .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var command = try completeMessage(key, session_ref, file, text);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&command, null, .{}) == .accepted);
}

const TestingCall = struct {
    item_id: []const u8,
    name: []const u8,
    encoded_call_id: []const u8,
    decoded_call_id: []const u8,
    encoded_arguments: []const u8,
    decoded_arguments: []const u8,
};

fn settleCallsForTesting(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    binding: AttemptBinding,
    file_prefix: []const u8,
    calls: []const TestingCall,
) !void {
    return settleCallsForTestingWithFaults(storage, tmp, binding, file_prefix, calls, .{}, null);
}

fn settleCallsForTestingWithFaults(
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

fn settleTwoActionsForTesting(
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

fn expectContent(storage: *Store, reference: ContentReference, expected: []const u8) !void {
    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(reference));
    defer reader.close();
    var actual: [128]u8 = undefined;
    const count = try reader.read(0, &actual);
    try std.testing.expectEqualStrings(expected, actual[0..count]);
    try std.testing.expectEqual(@as(usize, 0), try reader.read(count, &actual));
}

const TestingReportAction = struct {
    action: []const u8,
    call_ordinal: []const u8,
    permission_revision: []const u8,
    authorization: []const u8,
};

const TestingResolvedAction = struct {
    action: []const u8,
    call_ordinal: []const u8,
    code: []const u8,
    acceptance_position: []const u8,
    result: TestingContentReference,
};

const TestingContentReference = struct {
    bytes: []const u8,
    sha256: []const u8,
};

const TestingRejectedCall = struct {
    call_ordinal: []const u8,
    code: []const u8,
    acceptance_position: []const u8,
    result: TestingContentReference,
    name: TestingContentReference,
    call_id: TestingContentReference,
    arguments: TestingContentReference,
};

const TestingSessionReport = struct {
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

fn testingSessionReport(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session_ref: []const u8,
    limit: u64,
) ![]u8 {
    return testingSessionReportWithProfile(storage, tmp, session_ref, limit, .current);
}

fn testingSessionReportWithProfile(
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

fn testingSessionList(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions, used: *std.atomic.Value(u64), request_number: u64) ![]u8 {
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected_empty, "{{\"version\":\"4\",\"type\":\"session_list\",\"sessions\":[],\"delta\":\"full\",\"since\":\"{s}\",\"next\":null}}", .{since}), empty);
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
    // scratch, not a SQLite cursor, transaction or Store mutex.
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

/// One list page as a client reads it, and the request that continues it.
const TestingListing = struct {
    delta: protocol.ListDelta,
    since: protocol.SinceToken,
    references: [protocol.session_list_page_size]change_ring.Id = undefined,
    count: usize = 0,
    next: ?protocol.ListSessions = null,

    fn read(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions) !TestingListing {
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

    fn expectReferences(self: *const TestingListing, expected: []const change_ring.Id) !void {
        try std.testing.expectEqual(expected.len, self.count);
        for (expected, self.references[0..self.count]) |*want, *got| try std.testing.expectEqualStrings(want, got);
    }
};

test "a since listing answers only the Sessions changed since its token, or everything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(error.SqliteExecFailed, storage.fence(error.SqliteExecFailed));
    try std.testing.expect(!storage.notModified(now));
}

fn testingIdLess(_: void, left: change_ring.Id, right: change_ring.Id) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

/// Counts SQLite VM steps from `begin` to `end`. Preparing a statement also
/// steps, so measure a call only after the same call prepared its
/// statements.
const TestingSteps = struct {
    steps: u64 = 0,

    fn begin(self: *TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    fn end(_: *const TestingSteps, database: *c.sqlite3) void {
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingSteps = @ptrCast(@alignCast(context.?));
        self.steps += 1;
        return 0;
    }
};

test "a Workspace's changed page reads only its own Sessions, however many others changed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var nested = try tmp.dir.createDirPathOpen(std.testing.io, "other", .{});
    defer nested.close(std.testing.io);
    var other_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const other = other_buffer[0..try nested.realPath(std.testing.io, &other_buffer)];
    const Page = struct {
        fn configure(store: *Store, key: []const u8, session: []const u8, place: []const u8) !change_ring.Id {
            var command = try completeConfiguration(key, session, place, "model");
            const configured = store.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            return configured.accepted.session.slice()[0..protocol.session_id_bytes].*;
        }

        /// Steps for the page, which names only `watched`.
        fn steps(store: *Store, dir: *std.testing.TmpDir, request: protocol.ListSessions, watched: *const change_ring.Id) !u64 {
            _ = try TestingListing.read(store, dir, request);
            var counter: TestingSteps = .{};
            counter.begin(store.database);
            defer counter.end(store.database);
            const page = try TestingListing.read(store, dir, request);
            try std.testing.expectEqual(protocol.ListDelta.changed, page.delta);
            try page.expectReferences(&.{watched.*});
            try std.testing.expect(page.next == null);
            return counter.steps;
        }
    };
    const watched = try Page.configure(&storage, "scoped-watched", "", workspace);
    var request: protocol.ListSessions = .{ .workspace = .{}, .since = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) } };
    try request.workspace.?.set(workspace);
    _ = try Page.configure(&storage, "scoped-watched-again", &watched, workspace);
    const alone = try Page.steps(&storage, &tmp, request, &watched);
    // The rest of the ring: a distinct Session in another Workspace per
    // entry, each changed after the token.
    for (1..change_ring.capacity) |index| {
        var key: [32]u8 = undefined;
        _ = try Page.configure(&storage, try std.fmt.bufPrint(&key, "scoped-other-{d}", .{index}), "", other);
    }
    try std.testing.expect(storage.changes.covers(request.since.?.generation));
    try std.testing.expectEqual(alone, try Page.steps(&storage, &tmp, request, &watched));
}

/// Interrupts the one statement whose text is `sql` as it steps, the way an
/// I/O fault fails a read. No schema changes, so no cached plan expires.
const TestingStatementFault = struct {
    sql: [:0]const u8,
    running: bool = false,
    failed: u64 = 0,

    fn arm(self: *TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    fn disarm(_: *const TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    fn traced(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        self.running = std.mem.eql(u8, std.mem.span(c.sqlite3_sql(@ptrCast(statement))), self.sql);
        return 0;
    }

    fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        if (!self.running) return 0;
        self.failed += 1;
        return 1;
    }
};

test "a failed Workspace-key read fails and fences the entry point that touched its Session" {
    const Route = enum { configure, message };
    for (std.enums.values(Route)) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "key-fault-config");
        var fault: TestingStatementFault = .{ .sql = workspace_key_sql };
        switch (route) {
            .configure => {
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var relabel = try completeConfiguration("key-fault-relabel", session.slice(), try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                relabel.configuration.label.state = .value;
                try relabel.configuration.label.value.set("Relabelled");
                fault.arm(storage.database);
                defer fault.disarm(storage.database);
                try std.testing.expectEqual(std.meta.Tag(ConfigureReply).infrastructure_failure, std.meta.activeTag(storage.configure(&relabel, .{})));
            },
            .message => {
                const file = try tmp.dir.createFile(std.testing.io, "key-fault-message", .{ .read = true });
                try file.writeStreamingAll(std.testing.io, "work");
                try file.sync(std.testing.io);
                var command = try completeMessage("key-fault-message", session.slice(), file, "work");
                defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                fault.arm(storage.database);
                defer fault.disarm(storage.database);
                try std.testing.expectEqual(std.meta.Tag(MessageReply).infrastructure_failure, std.meta.activeTag(storage.submitMessageWithModel(&command, null, .{})));
            },
        }
        try std.testing.expect(fault.failed > 0);
        try std.testing.expect(storage.isFenced());
        // Nothing of the failed command committed.
        try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM core_command WHERE command_key IN ('key-fault-relabel','key-fault-message')"));
    }
}

test "a Session creation that rolls back never reaches a since listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "rollback-config");
    const since: protocol.SinceToken = .{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) };
    {
        const access = try storage.enter(.none);
        defer access.release();
        try storage.execute("BEGIN IMMEDIATE");
        const current = (try storage.readSessionForTesting(session.slice())).?;
        try std.testing.expect(try configuration_domain.insertSession(&storage, "zzzzzz", &current));
        try storage.rollbackAfterError(.{});
    }
    // The rolled-back insert still moved the commit counter. The hint
    // forgot instead of naming a Session that does not exist.
    try std.testing.expect(!storage.notModified(since));
    const listed = try TestingListing.read(&storage, &tmp, .{ .since = since });
    try std.testing.expectEqual(protocol.ListDelta.full, listed.delta);
    try listed.expectReferences(&.{session.slice()[0..protocol.session_id_bytes].*});
    try std.testing.expect(!storage.isFenced());
}

test "the touch oracle names a Session whose rows changed without a touch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    var command = try completeConfiguration("oracle", "", root[0..try tmp.dir.realPath(std.testing.io, &root)], "model");
    const configured = storage.configure(&command, .{});
    const session = configured.accepted.session.slice();
    const generation = storage.commit_generation.load(.acquire);
    {
        const access = try storage.enter(.none);
        defer access.release();
        try std.testing.expect(storage.untouchedForTesting() == null);
        // A writer that forgets its touch.
        var sql: [96]u8 = undefined;
        try sqlite.exec(storage.database, try std.mem.printSentinel(&sql, "UPDATE session SET label='forgot' WHERE session_ref='{s}'", .{session}, 0));
        try std.testing.expectEqualStrings(session, &storage.untouchedForTesting().?);
        try storage.touch(session);
        try std.testing.expect(storage.untouchedForTesting() == null);
    }
    // The touched write is recorded under the generation it advanced to.
    try std.testing.expectEqual(generation + 1, storage.commit_generation.load(.acquire));
    var out: [1]change_ring.Id = undefined;
    try std.testing.expectEqualStrings(session, &storage.changes.changed(generation, generation + 1, null, null, &out)[0]);
}

test "Session list capture and cursor storage stay page bounded as dormant Sessions grow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

/// One Session's listed row, from one unfiltered page.
const TestingListRow = struct {
    parsed: std.json.Parsed(std.json.Value),
    row: std.json.Value,

    fn deinit(self: *TestingListRow) void {
        self.parsed.deinit();
    }

    fn get(self: *const TestingListRow, path: []const []const u8) std.json.Value {
        var value = self.row;
        for (path) |name| value = value.object.get(name).?;
        return value;
    }

    fn number(self: *const TestingListRow, path: []const []const u8) !u64 {
        return std.fmt.parseInt(u64, self.get(path).string, 10);
    }
};

fn testingListRow(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !TestingListRow {
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

test "a list row reads the same steps however long its Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    // One Session, measured at two lengths of the same shape: answered
    // Turns, each followed by a queued Message a stop excluded, then a last
    // answered Turn. Alone in the Store, its index probes have the same
    // neighbours both times.
    const Round = struct {
        const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};

        fn run(store: *Store, dir: *std.testing.TmpDir, session: []const u8, comptime name: []const u8) !void {
            try answerTestTurn(store, dir, session, name ++ "-answer", &answer);
            try submitTestMessage(store, dir, name ++ "-queued-file", name ++ "-queued", session, "excluded");
            var stop = try completeSessionStop(name ++ "-stop", session);
            try std.testing.expect(store.stopSession(&stop, .{}) == .accepted);
        }
    };
    const Counter = struct {
        fn rowSteps(store: *Store, session: []const u8) !u64 {
            var row: protocol.SessionRow = .{};
            try report_domain.readSessionRowLocked(store, session, try Store.readUnixMilliseconds(std.testing.io), &row);
            var counter: TestingSteps = .{};
            counter.begin(store.database);
            defer counter.end(store.database);
            try report_domain.readSessionRowLocked(store, session, try Store.readUnixMilliseconds(std.testing.io), &row);
            try std.testing.expect(row.work.state == .finished and row.first_message != null);
            return counter.steps;
        }
    };
    const session = try configureTestSession(&storage, "row-steps");
    try Round.run(&storage, &tmp, session.slice(), "row-steps-0");
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-short", &Round.answer);
    const short = try Counter.rowSteps(&storage, session.slice());
    inline for (1..33) |round| try Round.run(&storage, &tmp, session.slice(), std.fmt.comptimePrint("row-steps-{d}", .{round}));
    try answerTestTurn(&storage, &tmp, session.slice(), "row-steps-long", &Round.answer);
    try std.testing.expect(short > 0);
    try std.testing.expectEqual(short, try Counter.rowSteps(&storage, session.slice()));
}

test "a list row carries its Session's Label, times, first Message, work and peers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var create = try completeConfiguration("row-create", "", workspace, "model-a");
    create.configuration.label.state = .value;
    try create.configuration.label.value.set("Review PR 412");
    const session = storage.configure(&create, .{}).accepted.session;
    const created_at = try queryU64(storage.database, "SELECT created_at FROM session");
    {
        // Configured, never messaged: idle since its creation.
        var listed = try testingListRow(&storage, &tmp, session.slice());
        defer listed.deinit();
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
    try sqlite.exec(storage.database, "UPDATE message_admission SET admitted_at=1000");
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
    try sqlite.exec(storage.database, "UPDATE message_admission SET admitted_at=2000 WHERE admission_id=(SELECT max(admission_id) FROM message_admission)");
    {
        // The first Message is now its Turn's; the latest person's Message is
        // the queued second one.
        var listed = try testingListRow(&storage, &tmp, session.slice());
        defer listed.deinit();
        try std.testing.expectEqual(@as(u64, 1000), try listed.number(&.{ "first_message", "admitted_at" }));
        try std.testing.expectEqualStrings("working", listed.get(&.{ "work", "state", "kind" }).string);
        try std.testing.expect(listed.get(&.{ "work", "turn" }) != .null and listed.get(&.{ "work", "operation" }) != .null);
        try std.testing.expectEqual(@as(u64, 2000), try listed.number(&.{ "peers", "from_person_at" }));
        try std.testing.expectEqual(try listed.number(&.{"end"}), try queryU64(storage.database, "SELECT next_position-1 FROM session"));
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

test "a person's Message next to a position is one indexed row, at a fixed end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "person-config");
    var request: protocol.ReadPersonMessage = .{ .direction = .backward };
    try request.session.set(session.slice());
    try std.testing.expectEqual(protocol.PersonMessage{ .end = 0 }, try storage.personMessage(&request));
    for ([_][]const u8{ "one", "two", "three" }) |text| try submitTestMessage(&storage, &tmp, text, text, session.slice(), text);
    var positions: [3]u64 = undefined;
    inline for (0..3) |index| positions[index] = try queryU64(storage.database, std.fmt.comptimePrint("SELECT admission_position FROM message_admission ORDER BY admission_id LIMIT 1 OFFSET {d}", .{index}));
    const newest = try storage.personMessage(&request);
    try std.testing.expectEqual(positions[2], newest.message.?.position);
    try std.testing.expectEqual(protocol.contentDigest("three"), newest.message.?.content.digest);
    try std.testing.expectEqual(@as(u64, 5), newest.message.?.content.length);
    request.end = newest.end;
    // Older from each one, then newer back: each step names its neighbour.
    for ([_]?u64{ positions[1], positions[0], null }, [_]u64{ positions[2], positions[1], positions[0] }) |expected, from| {
        request.position = from;
        const found = try storage.personMessage(&request);
        try std.testing.expectEqual(expected, if (found.message) |message| message.position else null);
    }
    request.direction = .forward;
    try submitTestMessage(&storage, &tmp, "four", "four", session.slice(), "four");
    for ([_]?u64{ positions[1], positions[2], null }, positions) |expected, from| {
        request.position = from;
        try std.testing.expectEqual(expected, if ((try storage.personMessage(&request)).message) |message| message.position else null);
    }
    // A later Message waits beyond the end it was read at.
    request.end = null;
    request.position = positions[2];
    try std.testing.expect((try storage.personMessage(&request)).message.?.position > positions[2]);
    request.end = try queryU64(storage.database, "SELECT next_position FROM session");
    try std.testing.expectError(error.InvalidCursor, storage.personMessage(&request));
    try request.session.set("nosuch");
    request.end = null;
    try std.testing.expectError(error.SessionNotFound, storage.personMessage(&request));
    try std.testing.expect(!storage.isFenced());
}

test "Current excludes history while Full exposes exact closed Session inventory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "Current selects active then queued work and bounds recent Message identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "selection-config");

    for (0..12) |index| {
        var file: [48]u8 = undefined;
        var key: [48]u8 = undefined;
        try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file, "selection-file-{d}", .{index}), try std.fmt.bufPrint(&key, "selection-message-{d}", .{index}), session.slice(), "input");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    }
    try expectDenseSessionPositions(&storage, session.slice());
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expect(report.value.object.get("selected_message").? == .null);
        const recent = report.value.object.get("recent_messages").?.array.items;
        try std.testing.expectEqual(@as(usize, 10), recent.len);
        for (recent, 0..) |item, index| {
            var expected: [48]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "selection-message-{d}", .{11 - index}), item.object.get("message").?.string);
            try std.testing.expectEqualStrings("provider_http_422", item.object.get("outcome").?.string);
        }
    }
    try submitTestMessage(&storage, &tmp, "selection-next-file", "selection-next", session.slice(), "next");
    try std.testing.expectEqual(protocol.MessageProgressStatus.runnable, (try storage.observeCommand("selection-next")).message.?.progress.?.status);
    try std.testing.expect((try storage.observeCommand("selection-message-11")).message.?.progress == null);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("selection-next", report.value.object.get("selected_message").?.string);
    }
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try submitTestMessage(&storage, &tmp, "selection-queued-file", "selection-queued", session.slice(), "queued");
    const queued = (try storage.observeCommand("selection-queued")).message.?;
    try std.testing.expect(queued.queue.?.state == .queued);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, queued.progress.?.status);
    try std.testing.expect(queued.progress.?.action_id == null);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("selection-next", report.value.object.get("selected_message").?.string);
        try std.testing.expectEqualStrings("1", report.value.object.get("pending_messages").?.string);
    }
}

test "Current preserves empty Message identity across queue, active Turn and history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "Full preserves rejected model interruption targets as canonical u64 text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "Full revisions own repeated content once and render semantic settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("revision-owner-1", "", workspace, "model-a");
    initial.configuration.tools.state = .value;
    initial.configuration.tools.count = 1;
    initial.configuration.tools.values[0] = .bash;
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
    third.configuration.tools.count = 1;
    third.configuration.tools.values[0] = .bash;
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

test "Full attributes unbound Messages to the earliest covering stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "Bash proposals retain exact order permission provenance denial and stop terminality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "action-config");
    try submitTestMessage(&storage, &tmp, "action-message", "action-message", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "action-metadata");

    var public_request = protocol.ConversationPage{};
    try public_request.session.set(session.slice());
    const proposed = try storage.publicConversationPageForTesting(public_request);
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
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPageForTesting(public_request)).count);
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
    const settled_page = try storage.publicConversationPageForTesting(public_request);
    try std.testing.expectEqual(@as(usize, 3), settled_page.count);
    try std.testing.expect(settled_page.items[0].kind == .tool_result);
    try std.testing.expectEqual(settled_page.items[0].position, settled_page.items[1].position);
    try std.testing.expectEqual(@as(u64, 2), settled_page.items[0].ordinal);
    try std.testing.expectEqual(@as(u64, 1), settled_page.items[1].ordinal);
    try std.testing.expectEqualStrings("Run second command", settled_page.items[0].presentation.?.description.?.slice());
    try std.testing.expectEqualStrings("Run first command", settled_page.items[1].presentation.?.description.?.slice());
    try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, settled_page.items[1].presentation.?.code);
    for (settled_page.items[0..2]) |item| try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
    const activity = try storage.activityPageForTesting(.{ .session = public_request.session, .direction = .backward });
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL"));

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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=1"));
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=2 AND resolution_code IS NULL"));

    try storage.close();
    storage_open = false;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var database: [platform.max_database_path_bytes]u8 = undefined;
    var reopened: Store = undefined;
    try reopened.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, 2), try queryU64(reopened.database, "SELECT count(*) FROM action_operation WHERE authorized=1 AND permission_revision=2 AND resolution_code IS NULL"));
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

test "allow once survives mode changes and reopen without granting another Attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "allow-config");
    try submitTestMessage(&storage, &tmp, "allow-input", "allow-message", session.slice(), "propose");
    const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, model_binding, "allow-metadata");
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
    const action_id = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation");
    const sibling_id = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation");
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
            try testingStore(&storage, &tmp, std.testing.io);
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

test "Current, activity pages and Message progress report one work through an approval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

/// The activity page carries the work Current reports and the first
/// actionable Action, from its own read.
fn pageWorkAgrees(store: *Store, report: std.json.Value, first_action: u64) !void {
    var request: protocol.ActivityPage = .{};
    try request.session.set(report.object.get("session").?.object.get("reference").?.string);
    const page = try store.activityPageForTesting(request);
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
fn expectOneWork(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, kind: []const u8) !u64 {
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
    const page = try storage.activityPageForTesting(request);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // A configure-only Session is idle since its creation.
    const session = try configureTestSession(&storage, "one-work-config");
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT created_at FROM session"), try expectOneWork(&storage, &tmp, session.slice(), "idle"));

    // Queued, then admitted.
    try submitTestMessage(&storage, &tmp, "one-work-file", "one-work-message", session.slice(), "first");
    _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
    try expectProgress(&storage, "one-work-message", .runnable);
    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT attempt_at FROM model_operation"), try expectOneWork(&storage, &tmp, session.slice(), "working"));
    try expectProgress(&storage, "one-work-message", .in_flight);

    // A retry due later is in flight; once due it is runnable, though
    // nothing committed in between.
    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{ .waits_ms = .{ 60_000, 60_000, 60_000 } } }, .{});
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT retry_scheduled_at FROM model_operation"), try expectOneWork(&storage, &tmp, session.slice(), "retrying"));
    try expectProgress(&storage, "one-work-message", .in_flight);
    try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL");
    _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
    try expectProgress(&storage, "one-work-message", .runnable);

    // A quota failure carries its saved reset time.
    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
    var diagnostic: [512]u8 = undefined;
    const quota: @import("../transport_policy.zig").Quota = .{ .code = .usage_limit_reached, .resets_at = 1792940000 };
    try storage.settleModelAttemptFailure(retry, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT outcome_at FROM turn"), try expectOneWork(&storage, &tmp, session.slice(), "failed"));
    {
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const failed = (try storage.activityPageForTesting(request)).work.work.state.failed;
        try std.testing.expectEqualStrings("provider_usage_limit_reached", failed.code.slice());
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
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation"), .decision = .allow_once };
    try allow.key.set("one-work-allow");
    try allow.session.set(bash.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    _ = try expectOneWork(&storage, &tmp, bash.slice(), "bash");
    try expectProgress(&storage, "one-work-bash-message", .in_flight);
    var stop = try completeSessionStop("one-work-stop", bash.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT stopped_at FROM session_stop"), try expectOneWork(&storage, &tmp, bash.slice(), "stopping"));
    try expectProgress(&storage, "one-work-bash-message", .in_flight);
    _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
    _ = try expectOneWork(&storage, &tmp, bash.slice(), "stopped");
    try std.testing.expect(!storage.isFenced());
}

test "a stop that selected no Turn decides work only through the input it excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const stopped_at = try queryU64(storage.database, "SELECT stopped_at FROM session_stop WHERE command_key='no-turn-stop-effective'");
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

test "a quota reset is read from a saved record and never fences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    for ([_]struct { code: []const u8, diagnostic: ?[]const u8, resets_at: ?u64 }{
        .{ .code = "provider_insufficient_quota", .diagnostic = "{\"provider_code\":\"insufficient_quota\",\"resets_at\":null}", .resets_at = null },
        .{ .code = "provider_usage_not_included", .diagnostic = "{\"provider_code\":\"usage_not_included\",\"resets_at\":42}", .resets_at = 42 },
        // A missing, corrupt or mismatched record gives no time.
        .{ .code = "provider_usage_limit_reached", .diagnostic = null, .resets_at = null },
        .{ .code = "provider_usage_limit_reached", .diagnostic = "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":4x}", .resets_at = null },
        .{ .code = "provider_usage_limit_reached", .diagnostic = "{\"provider_code\":\"insufficient_quota\",\"resets_at\":42}", .resets_at = null },
        // Only a quota code reads one.
        .{ .code = "provider_http_403", .diagnostic = "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":42}", .resets_at = null },
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
        const failed = (try storage.activityPageForTesting(request)).work.work.state.failed;
        try std.testing.expectEqualStrings(case.code, failed.code.slice());
        try std.testing.expectEqual(case.resets_at, failed.resets_at);
    }
    try std.testing.expect(!storage.isFenced());
}

test "contradictory work inputs fence the Store" {
    for ([_][:0]const u8{
        // A failure code on an active Turn: its settlement closes the Turn.
        "UPDATE model_operation SET resolution_code='provider_http_500',retry_due_at_ms=NULL,attempt_at=NULL,resolved_at=1",
        // An Action beside an Operation still in flight.
        "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,resolution_code) " ++
            "SELECT 999,operation_id,0,session_ref,1,1,0,NULL FROM model_operation",
        // A waiting retry without the failure that caused it.
        "UPDATE model_operation SET retry_due_at_ms=9223372036854775807,attempt_at=NULL,retry_scheduled_at=1,last_failure_code=NULL",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "contradiction-config");
        try submitTestMessage(&storage, &tmp, "contradiction-file", "contradiction-message", session.slice(), "x");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.database, fault);
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        try std.testing.expectError(error.CorruptStore, storage.activityPageForTesting(request));
        try std.testing.expect(storage.isFenced());
    }
}

test "Action settlement atomically yields to an earlier Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const allocated_session_0 = try configureTestSessionAsk(&storage, "settlement-stop-config");
    try submitTestMessage(
        &storage,
        &tmp,
        "settlement-stop-message",
        "settlement-stop-message",
        allocated_session_0.slice(),
        "execute",
    );
    const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "settlement-stop-item",
        .name = "bash",
        .encoded_call_id = "settlement-stop-call",
        .decoded_call_id = "settlement-stop-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};
    try settleCallsForTesting(&storage, &tmp, model_binding, "settlement-stop-metadata", &calls);
    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("settlement-stop-allow");
    try allow.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;

    var stop = try completeSessionStop("settlement-stop", allocated_session_0.slice());
    const pending_stop = storage.stopSession(&stop, .{});
    try std.testing.expect(pending_stop == .accepted);
    try std.testing.expectEqual(protocol.SessionStopCompletion.pending, pending_stop.accepted.completion);
    try std.testing.expectEqual(
        protocol.SessionStopCompletion.pending,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    try std.testing.expectEqual(
        ActionSettlement.session_stop,
        try storage.settleActionAttempt(action_binding, .succeeded, "Bash succeeded.", .{}),
    );
    try std.testing.expectEqual(
        protocol.SessionStopCompletion.completed,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    const completed_replay = storage.stopSession(&stop, .{});
    try std.testing.expect(completed_replay == .accepted);
    try std.testing.expect(completed_replay.accepted.replayed);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, completed_replay.accepted.completion);

    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'",
    ));
    const result_content_id = try queryU64(
        storage.database,
        "SELECT resolution_content_id FROM action_operation",
    );
    const result_metadata = try content_domain.readContentMetadata(&storage, @intCast(result_content_id));
    try expectContent(&storage, .{
        .length = result_metadata.length,
        .digest = result_metadata.digest,
    }, "Cancelled by Session stop.");
    try std.testing.expectEqual(@as(u64, 1), try querySessionU64(
        storage.database,
        "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'",
        allocated_session_0.slice(),
    ));
    try expectDenseSessionPositions(&storage, allocated_session_0.slice());
}

test "earlier Action settlement remains authoritative after Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("settlement-first-allow");
    try allow.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;

    try std.testing.expectEqual(
        ActionSettlement.effect,
        try storage.settleActionAttempt(action_binding, .succeeded, "Original Bash result.", .{}),
    );
    const original_content_id = try queryU64(
        storage.database,
        "SELECT resolution_content_id FROM action_operation",
    );
    const original_content_count = try queryU64(storage.database, "SELECT count(*) FROM content");
    try std.testing.expectError(
        error.StaleActionAttemptBinding,
        storage.settleActionAttempt(action_binding, .failed, "Late replacement.", .{}),
    );
    try std.testing.expectEqual(
        original_content_count,
        try queryU64(storage.database, "SELECT count(*) FROM content"),
    );

    var stop = try completeSessionStop("settlement-first-stop", allocated_session_0.slice());
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectEqual(model_binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, accepted.accepted.completion);
    try std.testing.expectEqual(original_content_id, try queryU64(
        storage.database,
        "SELECT resolution_content_id FROM action_operation",
    ));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'",
    ));
    const result_metadata = try content_domain.readContentMetadata(&storage, @intCast(original_content_id));
    try expectContent(&storage, .{
        .length = result_metadata.length,
        .digest = result_metadata.digest,
    }, "Original Bash result.");
    try std.testing.expectError(
        error.StaleActionAttemptBinding,
        storage.settleActionAttempt(action_binding, .cancelled, "Late stop result.", .{}),
    );
    try std.testing.expectEqual(
        original_content_count,
        try queryU64(storage.database, "SELECT count(*) FROM content"),
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
    try std.testing.expectEqual(@as(u64, 1), try querySessionU64(
        storage.database,
        "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'",
        allocated_session_0.slice(),
    ));
}

test "Full reports every closed Action resolution without fencing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
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

test "report scratch exhaustion is an observation failure without Store fencing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "report unlink failure retains a startup-owned zero-request file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "canonical report and Action read failures fence later commands" {
    var report_tmp = std.testing.tmpDir(.{});
    defer report_tmp.cleanup();
    var report_store: Store = undefined;
    try testingStore(&report_store, &report_tmp, std.testing.io);
    defer report_store.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&report_store, "report-corrupt-config");
    try sqlite.exec(report_store.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(report_store.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", allocated_session_0.slice());
    try sqlite.exec(report_store.database, "PRAGMA foreign_keys=ON");
    var report_root: [protocol.max_store_bytes]u8 = undefined;
    const report_root_length = try report_tmp.dir.realPath(std.testing.io, &report_root);
    var report_used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, report_store.captureSessionReport(allocated_session_0.slice(), .{
        .scratch_path = report_root[0..report_root_length],
        .scratch_budget = .{ .used = &report_used, .limit = 1024 * 1024 },
        .request_number = 1,
        .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
    }));
    try std.testing.expect(report_store.isFenced());
    var blocked_denial: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
    try blocked_denial.key.set("blocked-after-report-failure");
    try blocked_denial.session.set(allocated_session_0.slice());
    try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, report_store.decidePermission(&blocked_denial, .{}));

    var action_tmp = std.testing.tmpDir(.{});
    defer action_tmp.cleanup();
    var action_store: Store = undefined;
    try testingStore(&action_store, &action_tmp, std.testing.io);
    defer action_store.close() catch unreachable;
    const allocated_session_1 = try configureTestSession(&action_store, "action-corrupt-config");
    try submitTestMessage(&action_store, &action_tmp, "action-corrupt-message", "action-corrupt-message", allocated_session_1.slice(), "propose");
    const binding = (try action_store.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&action_store, &action_tmp, binding, "action-corrupt-metadata");
    const action_id = try queryU64(action_store.database, "SELECT min(action_id) FROM action_operation");
    try sqlite.exec(action_store.database, "PRAGMA foreign_keys=OFF");
    try sqlite.exec(action_store.database, "DELETE FROM content WHERE content_id=(SELECT call_id_content_id FROM model_tool_call ORDER BY operation_id,call_ordinal LIMIT 1)");
    try sqlite.exec(action_store.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, action_store.actionCallId(allocated_session_1.slice(), action_id));
    try std.testing.expect(action_store.isFenced());
    try std.testing.expectError(error.StoreFenced, action_store.actionArguments(allocated_session_1.slice(), action_id));

    // Existing public content is not necessarily a valid accepted descriptor.
    // A changed name must fence just like changed arguments, before dispatch.
    for ([_][:0]const u8{
        "UPDATE model_tool_call SET arguments_content_id=name_content_id",
        "UPDATE model_tool_call SET name_content_id=call_id_content_id",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
    }) |damage| {
        for ([_]enum { report, arguments, execution }{ .report, .arguments, .execution }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_2 = try configureTestSession(&storage, "descriptor-config");
            try submitTestMessage(&storage, &tmp, "descriptor-input", "descriptor-message", allocated_session_2.slice(), "propose");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, source, "descriptor-metadata");
            try sqlite.exec(storage.database, damage);
            const result: anyerror!void = switch (route) {
                .report => if (testingSessionReport(&storage, &tmp, allocated_session_2.slice(), 1024 * 1024)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .arguments => if (storage.actionArguments(allocated_session_2.slice(), try queryU64(storage.database, "SELECT min(action_id) FROM action_operation"))) |_| {} else |err| err,
                .execution => blk: {
                    const action = (try storage.admitNextActionAttempt(300_000, .{})).?;
                    var input: BashExecutionInput = undefined;
                    break :blk storage.readBashExecutionInput(action.permit.binding, &input);
                },
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.admitNextActionAttempt(300_000, .{}));
        }
    }
}

test "Store entry points lock and fence only through canonical access" {
    // Every entry point classifies its errors through `Access`; a new path
    // cannot take the mutex, read or set the fence beside it, or enter
    // without returning through a classifier.
    const sources = .{
        @embedFile("Store.zig"),                   @embedFile("sqlite.zig"),            @embedFile("schema.zig"),
        @embedFile("domain/action.zig"),           @embedFile("domain/command.zig"),    @embedFile("domain/configuration.zig"),
        @embedFile("domain/content.zig"),          @embedFile("domain/historical.zig"), @embedFile("domain/model_admission.zig"),
        @embedFile("domain/model_settlement.zig"), @embedFile("domain/reads.zig"),      @embedFile("domain/report.zig"),
        @embedFile("domain/turn.zig"),
    };
    var locks: usize = 0;
    var fence_stores: usize = 0;
    var fence_loads: usize = 0;
    var entered: usize = 0;
    inline for (sources) |source| {
        locks += std.mem.count(u8, source, "mutex.lock" ++ "Uncancelable(");
        fence_stores += std.mem.count(u8, source, "fenced.store" ++ "(true");
        fence_loads += std.mem.count(u8, source, "fenced.load" ++ "(");
        const enter = "self.enter" ++ "(";
        var entries = std.mem.splitSequence(u8, source, enter);
        _ = entries.next();
        while (entries.next()) |rest| : (entered += 1) {
            const body = rest[0 .. std.mem.indexOf(u8, rest, "\n}\n") orelse rest.len];
            try std.testing.expect(std.mem.indexOf(u8, body, "access.finish") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), locks);
    try std.testing.expectEqual(@as(usize, 1), fence_stores);
    try std.testing.expectEqual(@as(usize, 1), fence_loads);
    try std.testing.expect(entered > 0);
}

/// Leaves `table` prepared normally but failing at the first step, the
/// shape of an I/O or corruption fault after a statement compiled.
fn failAtStepForTesting(database: *c.sqlite3, comptime table: []const u8) !void {
    try sqlite.exec(database, "ALTER TABLE " ++ table ++ " RENAME TO " ++ table ++ "_unreadable");
    try sqlite.exec(database, "CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable " ++
        "WHERE abs(-9223372036854775808) IS NOT NULL");
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
    const Route = enum { result, view, purpose, handoff, failure, success };
    for (std.enums.values(Route)) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "step-fault-config");
        try submitTestMessage(&storage, &tmp, "step-fault-input", "step-fault-message", session.slice(), "work");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const result: anyerror!void = switch (route) {
            .result => blk: {
                try failAtStepForTesting(storage.database, "core_command");
                break :blk if (storage.commandResult("step-fault-message")) |_| {} else |err| err;
            },
            .success => blk: {
                try failAtStepForTesting(storage.database, "session_revision");
                break :blk settleCallsForTesting(&storage, &tmp, binding, "step-fault-success", &.{});
            },
            .view, .purpose, .handoff, .failure => blk: {
                try failAtStepForTesting(storage.database, "model_operation");
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

/// Every claimed Session position is used exactly once: the claims, from
/// every table that saves one, are exactly 1 through `next_position - 1`.
fn expectDenseSessionPositions(storage: *Store, session: []const u8) !void {
    // Each compound keeps within the Store's four-term limit.
    const statement = try sqlite.prepare(storage.database, "WITH messages(position) AS (" ++
        "SELECT admission_position FROM message_admission WHERE session_ref=?1 AND admission_position IS NOT NULL " ++
        "UNION ALL SELECT sender_position FROM message_admission WHERE sender_session_ref=?1 " ++
        "UNION ALL SELECT sender_position FROM sent_rejection WHERE sender_session_ref=?1 " ++
        "UNION ALL SELECT session_position FROM conversation_entry WHERE session_ref=?1 AND entry_kind!=3), " ++
        "model(position) AS (SELECT admission_position FROM model_operation WHERE session_ref=?1 " ++
        "UNION ALL SELECT session_position FROM model_output_item WHERE session_ref=?1 " ++
        "UNION ALL SELECT call.acceptance_position FROM model_tool_call call JOIN model_operation op ON op.operation_id=call.operation_id " ++
        "WHERE op.session_ref=?1 AND call.acceptance_position IS NOT NULL), " ++
        "settled(position) AS (SELECT acceptance_position FROM action_operation WHERE session_ref=?1 AND acceptance_position IS NOT NULL " ++
        "UNION ALL SELECT outcome_position FROM turn WHERE session_ref=?1 AND outcome_position IS NOT NULL " ++
        "UNION ALL SELECT position FROM session_stop WHERE session_ref=?1), " ++
        "claimed(position) AS (SELECT position FROM messages UNION ALL SELECT position FROM model UNION ALL SELECT position FROM settled) " ++
        "SELECT count(*),count(DISTINCT position),coalesce(min(position),1),coalesce(max(position),0)," ++
        "(SELECT next_position FROM session WHERE session_ref=?1) FROM claimed");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    const count = c.sqlite3_column_int64(statement, 0);
    try std.testing.expectEqual(count, c.sqlite3_column_int64(statement, 1));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(statement, 2));
    try std.testing.expectEqual(count, c.sqlite3_column_int64(statement, 3));
    try std.testing.expectEqual(count + 1, c.sqlite3_column_int64(statement, 4));
}

test "Core classifies trustworthy calls atomically without Action-shaped rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const allocated_session_0 = try configureTestSessionAsk(&storage, "mixed-config");
    try submitTestMessage(&storage, &tmp, "mixed-message", "mixed-message", allocated_session_0.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run first command\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-3", .name = "bash", .encoded_call_id = "call-3", .decoded_call_id = "call-3", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "item-4", .name = "bash", .encoded_call_id = "call-4", .decoded_call_id = "call-4", .encoded_arguments = "{\\\"command\\\":\\\"wrong\\\"}", .decoded_arguments = "{\"command\":\"wrong\"}" },
        .{ .item_id = "item-5", .name = "edit", .encoded_call_id = "call-5", .decoded_call_id = "call-5", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-6", .name = &@as([300]u8, @splat('x')), .encoded_call_id = "call-6", .decoded_call_id = "call-6", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-7", .name = "bash", .encoded_call_id = "call-7", .decoded_call_id = "call-7", .encoded_arguments = "{\\\"description\\\":\\\"Run seventh command\\\",\\\"cmd\\\":\\\"seven\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run seventh command\",\"cmd\":\"seven\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mixed-metadata", &calls);

    try std.testing.expectEqual(@as(u64, 7), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call"));
    try std.testing.expectEqual(@as(u64, 5), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE rejection_code IS NOT NULL"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=4 AND rejection_code='unknown_tool'"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=5 AND rejection_code='unknown_tool'"));
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM action_operation"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation action JOIN model_tool_call call ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal WHERE call.rejection_code IS NOT NULL"));
    try expectDenseSessionPositions(&storage, allocated_session_0.slice());
    {
        const rejected_action = try sqlite.prepare(storage.database, "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,resolution_code) VALUES(999,?1,1,?2,1,1,0,NULL)");
        defer _ = c.sqlite3_finalize(rejected_action);
        try sqlite.bindU64(rejected_action, 1, binding.operation_id);
        try sqlite.bindText(rejected_action, 2, allocated_session_0.slice());
        try std.testing.expectError(error.StatementFailed, sqlite.expectDone(rejected_action));
    }
    var observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.action_count);
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    const first_action_id = first: {
        const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024, .full);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 2), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("0", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[1].call_ordinal);
        try std.testing.expectEqual(@as(usize, 5), report.value.rejected_calls.items.len);
        const rejected = report.value.rejected_calls.items[0];
        try std.testing.expectEqualStrings("1", rejected.call_ordinal);
        try std.testing.expectEqualStrings("unknown_tool", rejected.code);
        try std.testing.expect((try std.fmt.parseInt(u64, rejected.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("20", rejected.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Unknown tool: other."), .lower),
            rejected.result.sha256,
        );
        inline for (.{
            .{ rejected.name, "other" },
            .{ rejected.call_id, "call-2" },
            .{ rejected.arguments, "{}" },
        }) |expected| {
            var length_buffer: [20]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&length_buffer, "{d}", .{expected[1].len}), expected[0].bytes);
            const digest = protocol.contentDigest(expected[1]);
            try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), expected[0].sha256);
        }
        var full = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
        defer full.deinit();
        const rejected_rows = full.value.object.get("rejected_calls").?.object.get("items").?.array.items;
        for (rejected_rows) |row| {
            const p = row.object.get("presentation").?.object;
            try std.testing.expect(p.get("description").? == .null);
            try std.testing.expect(p.get("publication_position").? == .null);
            try std.testing.expectEqualStrings(row.object.get("code").?.string, p.get("code").?.string);
        }
        const full_rejected = full.value.object.get("full").?.object.get("tool_calls").?.array.items[1].object;
        try std.testing.expectEqualStrings("other", full_rejected.get("name").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("{}", full_rejected.get("arguments").?.object.get("text").?.string);
        try std.testing.expectEqualStrings("Unknown tool: other.", full_rejected.get("rejection_result").?.object.get("text").?.string);
        break :first try std.fmt.parseInt(u64, report.value.actions.unresolved[0].action, 10);
    };
    {
        const content_id = try queryU64(
            storage.database,
            "SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=5",
        );
        const metadata = try content_domain.readContentMetadata(&storage, @intCast(content_id));
        var reader: ContentReader = undefined;
        reader.open(try storage.openContent(.{ .length = metadata.length, .digest = metadata.digest }));
        defer reader.close();
        var result: [192]u8 = undefined;
        const count = try reader.read(0, &result);
        try std.testing.expect(std.mem.startsWith(u8, result[0..count], "Unknown tool: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…"));
        try std.testing.expect(std.mem.indexOf(u8, result[0..count], "name continues; Rui content digest") != null);
    }
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny.key.set("mixed-deny");
    try deny.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
    observation = try storage.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    {
        const report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        const report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.unresolved.len);
        try std.testing.expectEqualStrings("6", report.value.actions.unresolved[0].call_ordinal);
        try std.testing.expectEqual(@as(usize, 1), report.value.actions.resolved.len);
        const resolved = report.value.actions.resolved[0];
        try std.testing.expectEqualStrings("0", resolved.call_ordinal);
        try std.testing.expectEqualStrings("denied", resolved.code);
        try std.testing.expect((try std.fmt.parseInt(u64, resolved.acceptance_position, 10)) > 0);
        try std.testing.expectEqualStrings("18", resolved.result.bytes);
        try std.testing.expectEqualStrings(
            &std.fmt.bytesToHex(protocol.contentDigest("Permission denied."), .lower),
            resolved.result.sha256,
        );
    }

    try storage.close();
    storage_open = false;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var database: [platform.max_database_path_bytes]u8 = undefined;
    var reopened: Store = undefined;
    try reopened.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    const recovered = try reopened.inspectSessionForTesting(allocated_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), recovered.action_count);
    try std.testing.expectEqual(@as(u64, 5), recovered.rejected_call_count);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        reopened.database,
        "SELECT count(*) FROM action_operation WHERE action_id=(SELECT min(action_id) FROM action_operation) " ++
            "AND parent_operation_id=(SELECT min(parent_operation_id) FROM action_operation) " ++
            "AND call_ordinal=0 AND resolution_code='denied'",
    ));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        reopened.database,
        "SELECT count(*) FROM permission_decision_command WHERE command_key='mixed-deny' " ++
            "AND action_id=CAST((SELECT min(action_id) FROM action_operation) AS TEXT)",
    ));
    try expectContent(&reopened, try reopened.actionCallId(allocated_session_0.slice(), first_action_id), "call-1");
    try expectContent(&reopened, try reopened.actionArguments(allocated_session_0.slice(), first_action_id), "{\"description\":\"Run first command\",\"cmd\":\"one\",\"timeout_ms\":null}");
    const recovered_bytes = try testingSessionReport(&reopened, &tmp, allocated_session_0.slice(), 1024 * 1024);
    defer std.testing.allocator.free(recovered_bytes);
    const recovered_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
    defer recovered_report.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered_report.value.actions.unresolved.len);
    try std.testing.expectEqualStrings("6", recovered_report.value.actions.unresolved[0].call_ordinal);
    try std.testing.expectEqual(@as(usize, 5), recovered_report.value.rejected_calls.items.len);
}

const ConstraintProbe = enum { accepted, check_violation, other_failure };

/// Runs one write inside a rolled-back savepoint and reports whether SQLite
/// accepted it or rejected it on a CHECK rather than another constraint.
fn probeConstraint(database: *c.sqlite3, sql: [:0]const u8) !ConstraintProbe {
    try sqlite.exec(database, "SAVEPOINT constraint_probe");
    defer sqlite.exec(database, "ROLLBACK TO constraint_probe; RELEASE constraint_probe") catch unreachable;
    const statement = try sqlite.prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) == c.SQLITE_DONE) return .accepted;
    return if (c.sqlite3_extended_errcode(database) == c.SQLITE_CONSTRAINT_CHECK) .check_violation else .other_failure;
}

test "lifecycle CHECKs reject null-valued invalid combinations on the CHECK itself" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "check-config");
    try submitTestMessage(&storage, &tmp, "check-message", "check-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "check-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE call_ordinal=0 AND resolution_code IS NULL AND attempt_ordinal=0"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=1 AND rejection_code='unknown_tool'"));

    // Each pair changes only one field, the null-valued one where a NULL could
    // pass the CHECK. The valid witness shows the row satisfies every
    // unrelated constraint, so the invalid write can only fail on the
    // lifecycle CHECK.
    const Case = struct { valid: [:0]const u8, invalid: [:0]const u8 };
    const cases = [_]Case{
        // An unresolved Operation needs a retry time; zero marks it uncertain.
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=NULL,attempt_at=1,resolved_at=NULL",
        },
        // Interruption linkage requires the interrupted Resolution.
        .{
            .valid = "UPDATE model_operation SET resolution_code='interrupted',retry_due_at_ms=NULL,interrupted_by_command_key=(SELECT min(command_key) FROM core_command)",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,interrupted_by_command_key=(SELECT min(command_key) FROM core_command)",
        },
        // A call without rejection fields must be an Action call.
        .{
            .valid = "UPDATE model_tool_call SET rejection_code=NULL,rejection_content_id=NULL,acceptance_position=NULL,action_kind=1 WHERE call_ordinal=1",
            .invalid = "UPDATE model_tool_call SET rejection_code=NULL,rejection_content_id=NULL,acceptance_position=NULL,action_kind=NULL WHERE call_ordinal=1",
        },
        // A denied Action never started an Attempt.
        .{
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1,resolution_code='failed'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1,resolution_code='denied'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
        },
        // An authorized Action is never denied.
        .{
            .valid = "UPDATE action_operation SET authorized=1,decided_at=1,resolution_code='failed'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .invalid = "UPDATE action_operation SET authorized=1,decided_at=1,resolution_code='denied'," ++
                "resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
        },
    };
    var outcomes: [cases.len]ConstraintProbe = undefined;
    for (cases, &outcomes) |case, *outcome| {
        try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.database, case.valid));
        outcome.* = try probeConstraint(storage.database, case.invalid);
    }
    try std.testing.expectEqual(@as([cases.len]ConstraintProbe, @splat(.check_violation)), outcomes);
}

test "closed value columns accept exactly their values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "values-config");
    try submitTestMessage(&storage, &tmp, "values-message", "values-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "values-metadata", &calls);

    const efforts = [_][]const u8{ "NULL", "'none'", "'low'", "'medium'", "'high'", "'xhigh'", "'max'" };
    const not_efforts = [_][]const u8{ "'minimal'", "'Medium'", "''" };
    const Column = struct { update: []const u8, accepted: []const []const u8, rejected: []const []const u8 };
    const columns = [_]Column{
        .{ .update = "UPDATE core_command SET kind={s}", .accepted = &.{ "1", "2", "3", "4", "5" }, .rejected = &.{ "0", "6" } },
        .{ .update = "UPDATE model_output_item SET item_kind=v.k,message_content_id=CASE WHEN v.k=2 THEN extras_content_id END FROM (SELECT {s} AS k) v", .accepted = &.{ "1", "2", "3", "4" }, .rejected = &.{ "0", "5" } },
        .{
            .update = "UPDATE conversation_entry SET entry_kind=v.k,source_admission_id=CASE WHEN v.k=1 THEN source_admission_id END," ++
                "source_revision=CASE WHEN v.k=2 THEN 1 END,source_operation_id=CASE WHEN v.k=3 THEN (SELECT min(operation_id) FROM model_output_item) END," ++
                "source_item_ordinal=CASE WHEN v.k=3 THEN 0 END FROM (SELECT {s} AS k) v WHERE entry_kind=1",
            .accepted = &.{ "1", "2", "3" },
            .rejected = &.{ "0", "4" },
        },
        .{ .update = "UPDATE session SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{ .update = "UPDATE session_revision SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{ .update = "UPDATE model_operation SET reasoning_effort={s}", .accepted = &efforts, .rejected = &not_efforts },
        .{
            .update = "UPDATE action_operation SET resolution_code={s},resolution_content_id=(SELECT min(content_id) FROM content)," ++
                "acceptance_position=1,resolved_at=1 WHERE call_ordinal=0",
            .accepted = &.{ "'denied'", "'cancelled'", "'succeeded'", "'failed'", "'timed_out'", "'indeterminate'", "'storage_failed'", "'spawn_failed'", "'infrastructure_shutdown'" },
            .rejected = &.{ "'interrupted'", "'Failed'", "''" },
        },
    };
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM conversation_entry WHERE entry_kind=1"));
    var sql: [512]u8 = undefined;
    inline for (columns) |column| {
        for (column.accepted) |value|
            try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.database, try std.mem.printSentinel(&sql, column.update, .{value}, 0)));
        for (column.rejected) |value|
            try std.testing.expectEqual(ConstraintProbe.check_violation, try probeConstraint(storage.database, try std.mem.printSentinel(&sql, column.update, .{value}, 0)));
    }
}

test "claiming Session positions stops at the largest position, and fails when its write does not land" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "claim-config");
    const last: u64 = std.math.maxInt(i64);
    try execSessionSql(storage.database, "UPDATE session SET next_position=9223372036854775805 WHERE session_ref=?1", session.slice());
    {
        const access = try storage.enter(.none);
        defer access.release();
        try storage.execute("BEGIN IMMEDIATE");
        try std.testing.expectEqual(last - 2, try turn_domain.claimSessionPositions(&storage, session.slice(), 2));
        try std.testing.expectError(error.SessionPositionExhausted, turn_domain.claimSessionPositions(&storage, session.slice(), 1));
        try std.testing.expectEqual(last, try turn_domain.claimSessionPositions(&storage, session.slice(), 0));
        try std.testing.expectError(error.SessionPositionExhausted, turn_domain.claimSessionPositions(&storage, session.slice(), last + 1));
        try storage.execute("COMMIT");
    }
    try std.testing.expectEqual(last, try queryU64(storage.database, "SELECT next_position FROM session"));

    try execSessionSql(storage.database, "UPDATE session SET next_position=1 WHERE session_ref=?1", session.slice());
    try sqlite.exec(storage.database, "CREATE TEMP TRIGGER skip_claim BEFORE UPDATE OF next_position ON main.session BEGIN SELECT RAISE(IGNORE); END");
    {
        const access = try storage.enter(.none);
        defer access.release();
        try storage.execute("BEGIN IMMEDIATE");
        try std.testing.expectError(error.CorruptStore, turn_domain.claimSessionPositions(&storage, session.slice(), 1));
        try storage.execute("ROLLBACK");
    }
}

test "each state-bearing row keeps exactly the time its state owns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "time-config");
    try submitTestMessage(&storage, &tmp, "time-message", "time-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "time-metadata", &calls);

    // Each pair moves one row to a state. The valid write sets exactly that
    // state's time; the invalid one forgets it or keeps the old state's time.
    const Case = struct { valid: [:0]const u8, invalid: [:0]const u8 };
    const cases = [_]Case{
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1",
        },
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,attempt_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=0,resolved_at=NULL",
        },
        .{
            .valid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=5,retry_scheduled_at=1,resolved_at=NULL",
            .invalid = "UPDATE model_operation SET resolution_code=NULL,resolution_content_id=NULL,retry_due_at_ms=5,retry_scheduled_at=1,attempt_at=1,resolved_at=NULL",
        },
        .{
            .valid = "UPDATE model_operation SET resolved_at=2",
            .invalid = "UPDATE model_operation SET resolved_at=NULL",
        },
        .{
            .valid = "UPDATE turn SET outcome_code='cancelled',outcome_position=99,outcome_at=1",
            .invalid = "UPDATE turn SET outcome_code='cancelled',outcome_position=99",
        },
        .{
            .valid = "UPDATE action_operation SET attempt_ordinal=1,attempt_at=1,bash_timeout_ms=1",
            .invalid = "UPDATE action_operation SET attempt_ordinal=1,bash_timeout_ms=1",
        },
        .{
            .valid = "UPDATE action_operation SET authorized=1,decided_at=1",
            .invalid = "UPDATE action_operation SET authorized=1",
        },
        .{
            .valid = "UPDATE action_operation SET resolution_code='failed',resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1,resolved_at=1",
            .invalid = "UPDATE action_operation SET resolution_code='failed',resolution_content_id=(SELECT min(content_id) FROM content),acceptance_position=1",
        },
        .{
            .valid = "UPDATE conversation_entry SET recorded_at=1",
            .invalid = "UPDATE conversation_entry SET recorded_at=0",
        },
    };
    var outcomes: [cases.len]ConstraintProbe = undefined;
    for (cases, &outcomes) |case, *outcome| {
        try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.database, case.valid));
        outcome.* = try probeConstraint(storage.database, case.invalid);
    }
    try std.testing.expectEqual(@as([cases.len]ConstraintProbe, @splat(.check_violation)), outcomes);
}

test "every transition dates its fact from the Host clock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const before: u64 = @intCast(@divFloor(try Store.readUnixMilliseconds(std.testing.io), 1000));

    const session = try configureTestSessionAsk(&storage, "dated-config");
    try submitTestMessage(&storage, &tmp, "dated-message", "dated-message", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"one\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "dated-metadata", &calls);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation"), .decision = .allow_once };
    try allow.key.set("dated-allow");
    try allow.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    var stop = try completeSessionStop("dated-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(ActionSettlement.session_stop, try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{}));
    const after: u64 = @intCast(@divFloor(try Store.readUnixMilliseconds(std.testing.io), 1000));

    const Column = struct { table: []const u8, column: []const u8 };
    const columns = [_]Column{
        .{ .table = "session", .column = "created_at" },
        .{ .table = "conversation_entry", .column = "recorded_at" },
        .{ .table = "model_operation", .column = "resolved_at" },
        .{ .table = "action_operation", .column = "decided_at" },
        .{ .table = "action_operation", .column = "attempt_at" },
        .{ .table = "action_operation", .column = "resolved_at" },
        .{ .table = "session_stop", .column = "stopped_at" },
        .{ .table = "turn", .column = "outcome_at" },
    };
    for (columns) |column| {
        var sql_buffer: [160]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&sql_buffer, "SELECT count(*) FROM {s} WHERE {s} BETWEEN {d} AND {d}", .{ column.table, column.column, before, after }, 0);
        const dated = try queryU64(storage.database, sql);
        if (dated == 0) std.debug.print("{s}.{s} is not dated within the transition\n", .{ column.table, column.column });
        try std.testing.expect(dated != 0);
    }
}

test "Action admission never visits an Action waiting for permission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Each round adds a Turn with two Actions waiting for permission.
    var sessions: [2]protocol.Bounded(protocol.max_session_bytes) = undefined;
    var steps: [2]i32 = undefined;
    var allowed: [2]u64 = undefined;
    for (&sessions, &steps, &allowed, 0..) |*session, *cost, *allowed_id, round| {
        var name_buffer: [32]u8 = undefined;
        session.* = try configureTestSessionAsk(&storage, try std.fmt.bufPrint(&name_buffer, "waiting-config-{d}", .{round}));
        var message_buffer: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "waiting-message-{d}", .{round});
        try submitTestMessage(&storage, &tmp, message, message, session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var metadata_buffer: [32]u8 = undefined;
        try settleTwoActionsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&metadata_buffer, "waiting-metadata-{d}", .{round}));
        try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
        allowed_id.* = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation");

        const select = try sqlite.prepare(storage.database, next_action_attempt_sql);
        defer _ = c.sqlite3_finalize(select);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(select));
        cost.* = c.sqlite3_stmt_status(select, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    // Four waiting Actions cost the scan what two did: none is in its index.
    try std.testing.expectEqual(@as(u64, 4), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE authorized=0 AND resolution_code IS NULL"));
    try std.testing.expectEqual(steps[0], steps[1]);

    // One allowed Action per Turn enters the index; its sibling stays out.
    for (sessions, allowed, 0..) |session, action_id, round| {
        var key_buffer: [32]u8 = undefined;
        var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
        try allow.key.set(try std.fmt.bufPrint(&key_buffer, "waiting-allow-{d}", .{round}));
        try allow.session.set(session.slice());
        try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    }
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM action_operation INDEXED BY action_operation_executable " ++
        "WHERE authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0"));
    for (allowed) |action_id| {
        const admitted = (try storage.admitNextActionAttempt(300_000, .{})).?;
        try std.testing.expectEqual(action_id, admitted.permit.binding.action_id);
    }
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
}

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

    const first_action_id = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation");
    const second_action_id = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation");
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
    try storage.openHistoricalView(continuation, &view);
    defer view.close();
    var position: u64 = 0;
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(position)).?.kind);
    position = (try view.nextEntry(position)).?.position;
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
        "Invalid arguments for tool 'bash'.",
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
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
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

test "kind-specific admission selects a tool continuation despite fresh input and rolls back atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try testingStore(&storage, &tmp, std.testing.io);
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try std.testing.expectEqual(first.turn_id, continued.turn_id);
    try std.testing.expectEqual(first.operation_id + 1, continued.operation_id);
    try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
    const fresh = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    try std.testing.expect(fresh.turn_id != first.turn_id);
    try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
}

test "tool continuation selection leaves a ready Turn with queued input to message selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

    const selection = try storage.cached(tool_continuation_selection_sql);
    const runs_before = c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0);
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try std.testing.expectEqual(first.turn_id, continued.turn_id);
    try std.testing.expectEqual(runs_before + 1, c.sqlite3_stmt_status(selection, c.SQLITE_STMTSTATUS_RUN, 0));
}

test "each transition that lets a Turn continue without input makes it selectable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
                const last_action = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation");
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

test "a Turn whose continuation was never recorded fences the Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "unrecorded-config");
    try submitTestMessage(&storage, &tmp, "unrecorded", "unrecorded", session.slice(), "start");
    const first = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
    try settleCallsForTesting(&storage, &tmp, first, "unrecorded-metadata", &calls);
    try sqlite.exec(storage.database, "UPDATE turn SET continuation_operation_id=NULL");
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
    try std.testing.expect(storage.isFenced());
}

test "a continuation recorded for a Turn waiting on its tool results fences the Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "premature-config");
    try submitTestMessage(&storage, &tmp, "premature", "premature", session.slice(), "propose");
    const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "premature-config");
    try submitTestMessage(&storage, &tmp, "premature-input", "premature-input", session.slice(), "more");
    try sqlite.exec(storage.database, "UPDATE turn SET continuation_operation_id=operation_id");
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectError(error.CorruptStore, storage.admitModelAttempt(.tool_continuation, .{}));
    try std.testing.expect(storage.isFenced());
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
    try std.testing.expectEqual(ConstraintProbe.accepted, try probeConstraint(storage.database, "UPDATE turn SET continuation_operation_id=operation_id"));
    try std.testing.expectEqual(ConstraintProbe.check_violation, try probeConstraint(storage.database, "UPDATE turn SET continuation_operation_id=operation_id+1"));
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

        const select = try sqlite.prepare(storage.database, tool_continuation_selection_sql);
        defer _ = c.sqlite3_finalize(select);
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(select));
        cost.* = c.sqlite3_stmt_status(select, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM turn WHERE outcome_code IS NULL"));
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "production turn preserves skipped continuation preference through actual Store admissions" {
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
        pub fn admitNewModel(self: *@This()) turn.Admission {
            return self.admit(.message);
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
    try testingStore(&storage, &tmp, std.testing.io);
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
    try testingStore(&storage, &tmp, std.testing.io);
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
    try testingStore(&sustained, &sustained_tmp, std.testing.io);
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
        try sqlite.exec(sustained.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms>0 AND resolution_code IS NULL");
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

test "terminal call-result import and read failures preserve canonical authority" {
    var import_tmp = std.testing.tmpDir(.{});
    defer import_tmp.cleanup();
    var import_store: Store = undefined;
    try testingStore(&import_store, &import_tmp, std.testing.io);
    defer import_store.close() catch unreachable;
    const allocated_session_0 = try configureTestSessionAsk(&import_store, "result-import-config");
    try submitTestMessage(&import_store, &import_tmp, "result-import-message", "result-import-message", allocated_session_0.slice(), "call");
    const import_binding = (try import_store.admitNextModelAttempt(.{})).?.permit.binding;
    const valid_call = [_]TestingCall{.{ .item_id = "import-item", .name = "bash", .encoded_call_id = "import-call", .decoded_call_id = "import-call", .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}" }};
    try settleCallsForTesting(&import_store, &import_tmp, import_binding, "result-import-metadata", &valid_call);
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = try queryU64(import_store.database, "SELECT action_id FROM action_operation") };
    try deny.key.set("result-import-deny");
    try deny.session.set(allocated_session_0.slice());
    try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, import_store.decidePermission(&deny, .{ .content_import = true }));
    try std.testing.expect(import_store.isFenced());
    try std.testing.expectEqual(@as(u64, 0), try queryU64(import_store.database, "SELECT count(*) FROM core_command WHERE command_key='result-import-deny'"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(import_store.database, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL"));

    var read_tmp = std.testing.tmpDir(.{});
    defer read_tmp.cleanup();
    var read_store: Store = undefined;
    try testingStore(&read_store, &read_tmp, std.testing.io);
    defer read_store.close() catch unreachable;
    const allocated_session_1 = try configureTestSession(&read_store, "result-read-config");
    try submitTestMessage(&read_store, &read_tmp, "result-read-message", "result-read-message", allocated_session_1.slice(), "call");
    const read_binding = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
    const rejected_call = [_]TestingCall{.{ .item_id = "read-item", .name = "unknown", .encoded_call_id = "read-call", .decoded_call_id = "read-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
    try settleCallsForTesting(&read_store, &read_tmp, read_binding, "result-read-metadata", &rejected_call);
    const continuation = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
    try sqlite.exec(read_store.database, "PRAGMA foreign_keys=OFF");
    try sqlite.exec(read_store.database, "UPDATE model_tool_call SET rejection_content_id=9223372036854775807");
    try sqlite.exec(read_store.database, "PRAGMA foreign_keys=ON");
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

test "runnable discovery fences structurally incomplete current tool calls" {
    const corruptions = [_]enum { action, call }{ .action, .call };
    for (corruptions, 0..) |corruption, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.database, "DELETE FROM action_operation");
        if (corruption == .call) try sqlite.exec(storage.database, "DELETE FROM model_tool_call");
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
        try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
        try std.testing.expect(storage.isFenced());
    }
}

test "compaction pressure uses provider usage appended input and complete call result groups" {
    for (0..3) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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

test "missing canonical call outcome rows fence history and inspection" {
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
        try testingStore(&storage, &tmp, std.testing.io);
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
            .action_id = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation"),
        };
        try denial.key.set(denial_keys[index]);
        try denial.session.set(session_ref);
        try std.testing.expect(storage.decidePermission(&denial, .{}) == .accepted);
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

        try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
        switch (corruption) {
            .action => try sqlite.exec(storage.database, "DELETE FROM action_operation"),
            .call => try sqlite.exec(storage.database, "DELETE FROM action_operation; DELETE FROM model_tool_call"),
            .result_content => try sqlite.exec(
                storage.database,
                "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation LIMIT 1)",
            ),
        }
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");

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

test "historical tool-result EOF revalidates complete canonical coverage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
        const entry = (try view.nextEntry(position)) orelse return error.MissingToolResultGroup;
        position = entry.position;
        if (entry.kind == .tool_results) break;
    }
    try std.testing.expect((try view.nextToolResult()) != null);

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    try sqlite.exec(storage.database, "DELETE FROM model_tool_call WHERE call_ordinal=1");
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, view.nextToolResult());
    try std.testing.expect(storage.isFenced());
}

test "complete historical tool-result traversal scales with groups and calls" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(group_count: usize, calls_per_group: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "scale-config");
            try submitTestMessage(
                &storage,
                &tmp,
                "scale-message-file",
                "scale-message",
                session.slice(),
                "scale",
            );
            var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [32]TestingCall = undefined;
            var item_ids: [32][32]u8 = undefined;
            var call_ids: [32][32]u8 = undefined;
            for (calls[0..calls_per_group], 0..) |*call, index| {
                const item_id = try std.fmt.bufPrint(&item_ids[index], "scale-item-{d}", .{index});
                const call_id = try std.fmt.bufPrint(&call_ids[index], "scale-call-{d}", .{index});
                call.* = .{
                    .item_id = item_id,
                    .name = "unknown",
                    .encoded_call_id = call_id,
                    .decoded_call_id = call_id,
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
            }
            for (0..group_count) |index| {
                var prefix_buffer: [64]u8 = undefined;
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    binding,
                    try std.fmt.bufPrint(&prefix_buffer, "scale-metadata-{d}", .{index}),
                    calls[0..calls_per_group],
                );
                binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.database, 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
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
                while (try view.nextToolResult()) |_| {
                    results_seen += 1;
                }
            }
            try std.testing.expectEqual(group_count, groups_seen);
            try std.testing.expectEqual(group_count * calls_per_group, results_seen);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(4, 1);
    const more_groups = try Measure.run(16, 1);
    const call_baseline = try Measure.run(4, 8);
    const more_calls = try Measure.run(4, 32);
    try std.testing.expect(more_groups > baseline);
    try std.testing.expect(more_groups < baseline * 7);
    try std.testing.expect(more_calls > call_baseline);
    try std.testing.expect(more_calls < call_baseline * 8);
}

/// One bounded step through history in preparation order. Each served
/// entry moves `after` past it, a tool group is drained, and the end sets
/// `after` to the largest position.
fn testingHistoricalStep(view: *HistoricalView, after: *u64, bytes: *usize, items: *usize) !void {
    switch (try view.nextEntryStep(after.*, bytes, items)) {
        .pending => {},
        .ready => |served| if (served) |entry| {
            after.* = entry.position;
            if (entry.kind == .tool_results) while (try view.nextToolResult()) |_| {};
        } else {
            after.* = std.math.maxInt(u64);
        },
    }
}

test "historical preparation yields covered group populations under small allowances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&storage, "bounded-config");
    try submitTestMessage(&storage, &tmp, "bounded-input", "bounded-input", allocated_session_0.slice(), "tools");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var calls: [16]TestingCall = undefined;
    var ids: [16][32]u8 = undefined;
    const arguments: [3072]u8 = @splat('x');
    for (&calls, 0..) |*call, i| {
        const id = try std.fmt.bufPrint(&ids[i], "bounded-{d}", .{i});
        call.* = .{ .item_id = id, .name = "unknown", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = &arguments, .decoded_arguments = &arguments };
    }
    for (0..8) |i| {
        var prefix: [32]u8 = undefined;
        try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&prefix, "bounded-{d}", .{i}), &calls);
        binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    }
    // An after-position covering every group must not drain discovery in one
    // call, and a view closed mid-discovery leaves checkpoints free.
    {
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(binding, &view);
        while (!try view.validateOutputsStep()) {}
        var bytes: usize = 7;
        var items: usize = 1;
        try std.testing.expect(try view.nextEntryStep(view.output_boundary, &bytes, &items) == .pending);
        _ = try configureTestSession(&storage, "yielded-checkpoint");
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        view.close();
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer view.close();
    while (!try view.validateOutputsStep()) {}
    var turns: usize = 0;
    var served: usize = 0;
    var after: u64 = 0;
    while (after != std.math.maxInt(u64)) {
        turns += 1;
        try std.testing.expect(turns < 200000);
        var bytes: usize = 127;
        var items: usize = 3;
        const before = after;
        try testingHistoricalStep(&view, &after, &bytes, &items);
        if (after != before) served += 1;
    }
    // One user input, 8 groups of 16 calls, their 8 result groups and the
    // end, each served by its own step after discovery yields.
    try std.testing.expectEqual(@as(usize, 1 + 8 * calls.len + 8 + 1), served);
    try std.testing.expect(turns > served);
    try std.testing.expect(!storage.isFenced());
}

test "large historical readers leave checkpoints free" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const text = try std.testing.allocator.alloc(u8, 1024 * 1024 + 37);
    defer std.testing.allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = @intCast('a' + index % 23);
    const session = try configureTestSession(&storage, "large-history-config");
    try submitTestMessage(&storage, &tmp, "large-history-input", "large-history-key", session.slice(), text);
    const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, source, "large-history-call", &.{.{
        .item_id = "large-item",
        .name = "unknown",
        .encoded_call_id = "large-call",
        .decoded_call_id = "large-call",
        .encoded_arguments = text,
        .decoded_arguments = text,
    }});
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(continuation, &view);
    defer view.close();
    const entry = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, entry.kind);
    var reader: HistoricalReader = undefined;
    try view.openContent(entry.content.?, &reader);
    defer reader.close();
    reader.reader.allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < text.len) {
        const wanted = @min(buffer.len, text.len - offset);
        try std.testing.expectEqual(wanted, try reader.read(offset, &buffer));
        try std.testing.expectEqualSlices(u8, text[offset..][0..wanted], buffer[0..wanted]);
        if (offset == 0) {
            _ = try configureTestSession(&storage, "large-history-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
        offset += wanted;
    }
    try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &buffer));
    try std.testing.expect(!storage.isFenced());
}

test "historical preparation rejects missing extra and reordered sibling classifications incrementally" {
    for ([_]bool{ false, true }) |covered| {
        // `corrupts_bytes`: the fault breaks bytes replay reads, not rows.
        cases: for ([_]struct { sql: [:0]const u8, corrupts_bytes: bool = false }{
            .{ .sql = "UPDATE model_tool_call SET call_ordinal=99 WHERE call_ordinal=0; UPDATE model_tool_call SET call_ordinal=0 WHERE call_ordinal=1; UPDATE model_tool_call SET call_ordinal=1 WHERE call_ordinal=99" },
            .{ .sql = "DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "UPDATE model_output_item SET item_kind=1 WHERE item_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE item_ordinal=1; DELETE FROM model_tool_call WHERE call_ordinal=1" },
            .{ .sql = "DELETE FROM model_output_item WHERE operation_id IN (SELECT operation_id FROM model_tool_call); DELETE FROM model_tool_call" },
            .{ .sql = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1", .corrupts_bytes = true },
        }) |fault| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "sibling-config");
            try submitTestMessage(&storage, &tmp, "sibling-input", "sibling-input", session.slice(), "tools");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, source, "sibling-output", &calls);
            var next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            if (covered) {
                try storage.settleModelAttemptFailure(next, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
                next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.database, fault.sql);
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(next, &view);
            defer view.close();
            while (!(view.validateOutputsStep() catch |err| {
                try std.testing.expectEqual(error.CorruptStore, err);
                try std.testing.expect(storage.isFenced());
                continue :cases;
            })) {}
            // Row faults fail while discovery walks the group, before any
            // entry is served. Corrupt call bytes fence when replay reads
            // the first call, whose digest no longer matches.
            const bytes_fault = fault.corrupts_bytes;
            var served: ?HistoricalEntry = null;
            while (true) {
                var bytes: usize = 1;
                var items: usize = 1;
                const progress = view.nextEntryStep(if (served) |entry| entry.position else 0, &bytes, &items) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    try std.testing.expect(!bytes_fault);
                    break;
                };
                if (!bytes_fault and view.tool_group_initialized) return error.MissingCorruptionFailure;
                switch (progress) {
                    .pending => {},
                    .ready => |entry| {
                        // The view never reaches its end, so no request seals.
                        if (!bytes_fault) return error.MissingCorruptionFailure;
                        served = entry.?.*;
                        if (served.?.kind == .user) continue;
                        try std.testing.expectEqual(HistoricalEntryKind.provider_output, served.?.kind);
                        const output = try view.openOutput(served.?.position);
                        try std.testing.expectEqual(OutputItemKind.function_call, output.kind);
                        // The call's private bag holds its item ID.
                        var reader: HistoricalReader = undefined;
                        try view.openContent(output.bag.?, &reader);
                        defer reader.close();
                        var buffer: [4096]u8 = undefined;
                        try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(output.bag.?.length)]));
                        break;
                    },
                }
            }
            try std.testing.expect(storage.isFenced());
        }
    }
}

test "historical accepted assistant output completeness and provenance fence reads" {
    // Replay trusts each item's saved kind, identity and bytes once their
    // digest matches; acceptance judged them, and the rows below the
    // admission boundary are immutable.
    const Incompatibility = enum { none, model };
    for ([_]struct { fault: ?[:0]const u8 = null, incompatible: Incompatibility = .none, tied_owners: bool = false, failure: anyerror = error.CorruptStore }{
        .{ .tied_owners = true, .fault = "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=(SELECT max(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "DELETE FROM model_output_item WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .tied_owners = true, .fault = "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=(SELECT min(operation_id) FROM model_output_item)" },
        .{ .fault = "DELETE FROM model_output_item" },
        .{ .fault = "DELETE FROM model_output_item WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET item_ordinal=9 WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET session_position=session_position+100 WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET session_position=session_position+100 WHERE item_ordinal IN (0,1); " ++
            "UPDATE model_output_item SET session_position=session_position-99-2*item_ordinal WHERE item_ordinal IN (0,1)" },
        .{ .fault = "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1" },
        .{ .fault = "UPDATE model_output_item SET session_ref='f0re1g'" },
        .{ .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1" },
        .{ .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=1)" },
        // Once continuation is unavailable, later items are not read.
        .{ .incompatible = .model, .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=0)", .failure = error.ContinuationUnavailable },
        .{ .fault = "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='future' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='tool_proposals' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE turn SET session_ref='f0re1g' WHERE turn_id=(SELECT turn_id FROM model_operation WHERE output_item_count IS NOT NULL)" },
        .{ .incompatible = .model, .failure = error.ContinuationUnavailable },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "output-config");
        try submitTestMessage(&storage, &tmp, "output-input", "output-input", session.slice(), "first");
        var source_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const reasoning = "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\"}";
        const answer = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}";
        const sse = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++ reasoning ++ "}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":" ++ answer ++ "}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n";
        const source = try tmp.dir.createFile(std.testing.io, "output-source", .{ .read = true });
        defer source.close(std.testing.io);
        try source.writeStreamingAll(std.testing.io, sse);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..length], "output-metadata", .{ .used = &used, .limit = 4096 }, false, &retained);
        defer metadata.deinit();
        var event_data: output_decode.EventData = undefined;
        try event_data.init(std.testing.io, root[0..length], "output-event-data", .{ .used = &used, .limit = 4096 }, false, &retained);
        defer event_data.deinit();
        var interpreted: output_decode.Interpretation = undefined;
        output_decode.interpret(output_decode.testingInterpret(), .@"openai-responses/1", std.testing.io, source, sse.len, &metadata, &event_data, .assistant_response, .{}, output_decode.testingProviderFailure(), &interpreted);
        if (interpreted != .accepted) return error.TestUnexpectedResult;
        const validated = &interpreted.accepted.output;
        for (0..@as(usize, if (case.tied_owners) 2 else 1)) |index| {
            if (index != 0) {
                try submitTestMessage(&storage, &tmp, "output-second", "output-second", session.slice(), "second");
                source_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try storage.settleModelSuccess(source_binding, &.{
                .source = validated.source,
                .source_length = validated.source_length,
                .metadata = metadata.file,
                .item_count = validated.item_count,
                .call_count = validated.call_count,
                .answer_item_ordinal = validated.answer_item_ordinal,
                .answer_length = validated.answer_length,
                .answer_digest = validated.answer_digest,
                .response_id = validated.evidence.response_id,
                .model_evidence = testing_absent_model_evidence,
                .request_id = .{},
            }, .{});
        }
        var reconfigure: protocol.ConfigureCommand = .{};
        try reconfigure.key.set("output-reconfigure");
        reconfigure.session = session;
        try std.testing.expect(storage.configure(&reconfigure, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "output-next", "output-next", session.slice(), "next");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        switch (case.incompatible) {
            .none => {},
            .model => try storage.setHistoricalModelForTesting(source_binding, "different-model"),
        }
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
        if (case.tied_owners) try sqlite.exec(storage.database, "UPDATE model_operation SET admission_position=" ++
            "(SELECT min(admission_position) FROM model_operation WHERE output_item_count IS NOT NULL) WHERE output_item_count IS NOT NULL");
        // Deliberately bypass the message-certificate CHECK too: these cases
        // exercise read-time detection of damaged persisted item kinds.
        try sqlite.exec(storage.database, "PRAGMA ignore_check_constraints=ON");
        if (case.fault) |fault| try sqlite.exec(storage.database, fault);
        try sqlite.exec(storage.database, "PRAGMA ignore_check_constraints=OFF");
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
        var preparation: @import("../model_adapter.zig").Preparation = undefined;
        try storage.openHistoricalView(binding, &preparation.view);
        try preparation.init(std.testing.io, root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
        defer if (preparation.state.active) preparation.cancel();
        while (true) {
            const progress = preparation.advance(7, 2);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(case.failure, err);
                    break;
                },
                .prepared => |request| {
                    request.deinit(std.testing.io, preparation.writer.budget);
                    return error.MissingCorruptionFailure;
                },
            }
        }
        try std.testing.expectEqual(case.failure == error.CorruptStore, storage.isFenced());
        preparation.cancel();
        try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
    }
}

test "historical preparation fences a served call that does not match its certificate" {
    // A call binds its Tool Results through its admission certificate; replay
    // reads each call's bytes against their digest.
    for ([_][:0]const u8{
        "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1",
        "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE item_ordinal=1)",
        "UPDATE model_tool_call SET arguments_content_id=name_content_id",
        "UPDATE model_operation SET resolution_code='answer' WHERE output_item_count IS NOT NULL",
        "UPDATE model_operation SET resolution_code='compacted' WHERE output_item_count IS NOT NULL",
        "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "incompatible-config");
        try submitTestMessage(&storage, &tmp, "incompatible-input", "incompatible-input", session.slice(), "tools");
        const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        };
        try settleCallsForTesting(&storage, &tmp, source, "incompatible-output", &calls);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.database, fault);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: @import("../model_adapter.zig").Preparation = undefined;
        try storage.openHistoricalView(binding, &preparation.view);
        try preparation.init(std.testing.io, root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, protocol.routesAll(.endpoint), null, .{}, &retained);
        defer if (preparation.state.active) preparation.cancel();
        while (true) {
            const progress = preparation.advance(1, 1);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                },
                .prepared => |request| {
                    request.deinit(std.testing.io, preparation.writer.budget);
                    return error.MissingCompatibilityFailure;
                },
            }
        }
        try std.testing.expect(storage.isFenced());
        preparation.cancel();
        try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expect(retained == null);
    }
}

test "historical accepted output selection work excludes failed Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try sqlite.exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL");
            const insert = try sqlite.prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
                "attempt_ordinal,output_reservation,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
                "1,0,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            while (!try view.validateOutputsStep()) {}
            return measured.steps;
        }
    };
    const small = try Measure.run(8);
    const large = try Measure.run(1024);
    try std.testing.expect(large <= small + 100);
}

test "Current report work is independent of terminal tool history" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(group_count: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "current-cost-config");
            const calls = [_]TestingCall{.{
                .item_id = "current-cost-item",
                .name = "unknown",
                .encoded_call_id = "current-cost-call",
                .decoded_call_id = "current-cost-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }};
            for (0..group_count) |index| {
                var file_buffer: [64]u8 = undefined;
                var key_buffer: [64]u8 = undefined;
                var metadata_buffer: [64]u8 = undefined;
                try submitTestMessage(
                    &storage,
                    &tmp,
                    try std.fmt.bufPrint(&file_buffer, "current-cost-file-{d}", .{index}),
                    try std.fmt.bufPrint(&key_buffer, "current-cost-message-{d}", .{index}),
                    session.slice(),
                    "call",
                );
                const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(
                    &storage,
                    &tmp,
                    source,
                    try std.fmt.bufPrint(&metadata_buffer, "current-cost-metadata-{d}", .{index}),
                    &calls,
                );
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            }
            try submitTestMessage(
                &storage,
                &tmp,
                "current-cost-active-file",
                "current-cost-active-message",
                session.slice(),
                "active",
            );
            const active = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Usage anchors the context estimate here, so the report reads
            // only what follows this call, as it does with a real provider.
            try settleCallsForTestingWithFaults(
                &storage,
                &tmp,
                active,
                "current-cost-active-metadata",
                &calls,
                .{},
                "{\"input_tokens\":10,\"output_tokens\":0}",
            );

            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.database, 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            var report = try storage.captureSessionReport(session.slice(), .{
                .scratch_path = root[0..root_length],
                .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
                .request_number = 1,
                .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
            });
            report.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            return counter.steps;
        }
    };

    const sixteen_groups = try Measure.run(16);
    const sixty_four_groups = try Measure.run(64);
    try std.testing.expectEqual(sixteen_groups, sixty_four_groups);
}

test "Current pending count skips excluded Message history by indexed cutoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "pending-cost-config");
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");

    var costs: [2]i32 = undefined;
    for ([_]usize{ 100, 10_000 }, 0..) |history, index| {
        try sqlite.exec(storage.database, "DELETE FROM message_admission; DELETE FROM session_stop");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "SELECT value,'{1s}',printf('excluded-%d',value),1,NULL,1 FROM sequence; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "VALUES({0}+1,'{1s}','eligible',1,NULL,1); " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,stopped_at) " ++
                "VALUES('history-stop','{1s}',NULL,{0},1)",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.database, insert);
        try std.testing.expectEqual(@as(u64, 1), try command_domain.countPendingMessages(&storage, session.slice()));

        const cutoff_statement = try sqlite.prepare(storage.database, session_stop_cutoff_sql);
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try sqlite.bindText(cutoff_statement, 1, session.slice());
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cutoff_statement));
        const cutoff = c.sqlite3_column_int64(cutoff_statement, 0);
        const count_statement = try sqlite.prepare(storage.database, pending_message_count_sql);
        defer _ = c.sqlite3_finalize(count_statement);
        try sqlite.bindText(count_statement, 1, session.slice());
        try sqlite.bindI64(count_statement, 2, cutoff);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(count_statement));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(count_statement, 0));
        costs[index] = c.sqlite3_stmt_status(cutoff_statement, c.SQLITE_STMTSTATUS_VM_STEP, 0) +
            c.sqlite3_stmt_status(count_statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expect(costs[1] <= costs[0] + 8);
}

test "Full Message projection work does not multiply Messages by stops" {
    const Measure = struct {
        const Counter = struct {
            steps: u64 = 0,

            fn progress(context: ?*anyopaque) callconv(.c) c_int {
                const counter: *Counter = @ptrCast(@alignCast(context orelse return 1));
                counter.steps += 1;
                return 0;
            }
        };

        fn run(message_count: usize, stop_count: usize) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "full-scale-config");
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");

            for (1..message_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at,admission_position) " ++
                        "VALUES({0},'{1s}','message-{0}',1,NULL,1,{2})",
                    .{ index, session.slice(), 1000 + index },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.database, insert);
            }
            for (1..stop_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) " ++
                        "VALUES('stop-{0}',3,'{2s}',zeroblob(32),NULL,NULL,1,'accepted',0,0);" ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                        "VALUES('stop-{0}','{2s}',NULL,{1},{0},1)",
                    .{ index, message_count, session.slice() },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try sqlite.exec(storage.database, insert);
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.database, 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            const full = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 8 * 1024 * 1024, .full);
            defer std.testing.allocator.free(full);
            return counter.steps;
        }
    };

    const baseline = try Measure.run(32, 32);
    const more_messages = try Measure.run(128, 32);
    const more_stops = try Measure.run(32, 128);
    const both_larger = try Measure.run(128, 128);
    try std.testing.expect(more_messages > baseline);
    try std.testing.expect(more_stops > baseline);
    try std.testing.expect(both_larger > more_messages);
    try std.testing.expect(both_larger > more_stops);
    try std.testing.expect(both_larger * 2 < (more_messages + more_stops) * 3);
}

test "call classification uses the proposing Operation frozen catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    add_bash.configuration.tools.count = 1;
    add_bash.configuration.tools.values[0] = .bash;
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool'"));
}

test "duplicate trustworthy call identity rolls back every imported consequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_output_item"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation"));
}

test "valid and rejected call populations grow independently" {
    const population = 128;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "Session stop freezes its selection and excludes only the admitted prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "later idle stop does not reclassify a completed Message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "completed-stop-config");
    try submitTestMessage(&storage, &tmp, "completed-stop-file", "completed-stop-message", session.slice(), "answer");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try sqlite.exec(
        storage.database,
        "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code='answer',attempt_at=NULL,resolved_at=1," ++
            "resolution_content_id=(SELECT content_id FROM message_admission WHERE command_key='completed-stop-message')",
    );
    try execSessionSql(storage.database, "UPDATE turn SET outcome_code='completed',outcome_at=1,outcome_content_id=(SELECT content_id FROM message_admission " ++
        "WHERE command_key='completed-stop-message'),outcome_position=(SELECT next_position FROM session WHERE session_ref=?1) WHERE session_ref=?1", session.slice());
    try execSessionSql(storage.database, "UPDATE session SET next_position=next_position+1 WHERE session_ref=?1", session.slice());
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

test "idle Session stop excludes queued work but not later admissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
            try testingStore(&storage, &tmp, std.testing.io);
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

test "exact model interruption continues only with applicable pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM model_operation WHERE resolution_code='interrupted' " ++
            "AND interrupted_by_command_key='interrupt'",
    ));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL",
    ));
    const replay = storage.interruptModel(&interrupt, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try storage.settleModelAttemptFailure(successor.permit.binding, .{ .uncorrelated = "successor_failure" }, .ordinary, .{});
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM model_operation WHERE resolution_code='successor_failure'",
    ));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        storage.database,
        "SELECT count(*) FROM model_operation WHERE resolution_code='late_old_failure'",
    ));
}

test "exact model interruption rejects stale targets and replays before applicability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "controls wait behind an active model settlement transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "transaction-race-config");
    try submitTestMessage(
        &storage,
        &tmp,
        "transaction-race-message",
        "transaction-race-message",
        session.slice(),
        "execute",
    );
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "transaction-race-item",
        .name = "bash",
        .encoded_call_id = "transaction-race-call",
        .decoded_call_id = "transaction-race-call",
        .encoded_arguments = "{\\\"description\\\":\\\"Run no-op command\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    }};

    const SettlementCheckpoint = enum(u8) { waiting, transaction_active, worker_finished };
    const Shared = struct {
        io: std.Io,
        order: std.atomic.Value(u64) = .init(0),
        checkpoint_ready: std.Io.Semaphore = .{},
        settlement_release: std.Io.Semaphore = .{},
        controls_requested: std.Io.Semaphore = .{},
        checkpoint: std.atomic.Value(SettlementCheckpoint) = .init(.waiting),
        transaction_active_order: std.atomic.Value(u64) = .init(0),
        settlement_complete_order: std.atomic.Value(u64) = .init(0),

        fn next(self: *@This()) u64 {
            return self.order.fetchAdd(1, .seq_cst) + 1;
        }

        fn settlementTrace(context: *anyopaque, phase: SettlementTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .transaction_active => {
                    self.transaction_active_order.store(self.next(), .seq_cst);
                    std.debug.assert(
                        self.checkpoint.cmpxchgStrong(
                            .waiting,
                            .transaction_active,
                            .acq_rel,
                            .acquire,
                        ) == null,
                    );
                    self.checkpoint_ready.post(self.io);
                    self.settlement_release.waitUncancelable(self.io);
                },
                .settlement_complete => self.settlement_complete_order.store(self.next(), .seq_cst),
                else => {},
            }
        }

        fn workerFinished(self: *@This()) void {
            if (self.checkpoint.swap(.worker_finished, .acq_rel) != .worker_finished) {
                self.checkpoint_ready.post(self.io);
            }
        }
    };
    const ControlProbe = struct {
        shared: *Shared,
        lock_acquired_order: std.atomic.Value(u64) = .init(0),

        fn mark(context: *anyopaque, phase: ControlTracePhase) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (phase) {
                .lock_requested => self.shared.controls_requested.post(self.shared.io),
                .lock_acquired => self.lock_acquired_order.store(self.shared.next(), .seq_cst),
                else => {},
            }
        }
    };
    const SettlementContext = struct {
        storage: *Store,
        tmp: *std.testing.TmpDir,
        binding: AttemptBinding,
        calls: []const TestingCall,
        shared: *Shared,
        failure_before_settlement: ?anyerror = null,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            defer self.shared.workerFinished();
            if (self.failure_before_settlement) |err| {
                self.result = err;
                return;
            }
            settleCallsForTestingWithFaults(
                self.storage,
                self.tmp,
                self.binding,
                "transaction-race-metadata",
                self.calls,
                .{ .settlement_trace = .{ .context = self.shared, .mark_fn = Shared.settlementTrace } },
                null,
            ) catch |err| {
                self.result = err;
            };
        }
    };
    const StopContext = struct {
        storage: *Store,
        command: *const protocol.SessionStopCommand,
        probe: ControlProbe,
        reply: ?SessionStopReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.stopSession(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };
    const InterruptContext = struct {
        storage: *Store,
        command: *const protocol.ModelInterruptionCommand,
        probe: ControlProbe,
        reply: ?ModelInterruptionReply = null,
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.reply = self.storage.interruptModel(self.command, .{
                .control_trace = .{ .context = &self.probe, .mark_fn = ControlProbe.mark },
            });
            self.finished.store(true, .seq_cst);
        }
    };

    var early_shared: Shared = .{ .io = std.testing.io };
    var early: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &early_shared,
        .failure_before_settlement = error.InjectedSettlementCheckpointFailure,
    };
    const early_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&early});
    early_shared.checkpoint_ready.waitUncancelable(std.testing.io);
    early_thread.join();
    try std.testing.expectEqual(SettlementCheckpoint.worker_finished, early_shared.checkpoint.load(.acquire));
    try std.testing.expectEqual(error.InjectedSettlementCheckpointFailure, early.result.?);

    var shared: Shared = .{ .io = std.testing.io };
    var settlement_thread: ?std.Thread = null;
    var stop_thread: ?std.Thread = null;
    var interrupt_thread: ?std.Thread = null;
    var settlement_released = false;
    defer {
        if (!settlement_released) shared.settlement_release.post(std.testing.io);
        if (settlement_thread) |thread| thread.join();
        if (stop_thread) |thread| thread.join();
        if (interrupt_thread) |thread| thread.join();
    }
    var settlement: SettlementContext = .{
        .storage = &storage,
        .tmp = &tmp,
        .binding = binding,
        .calls = &calls,
        .shared = &shared,
    };
    settlement_thread = try std.Thread.spawn(.{}, SettlementContext.run, .{&settlement});
    shared.checkpoint_ready.waitUncancelable(std.testing.io);
    if (shared.checkpoint.load(.acquire) == .worker_finished) {
        settlement_thread.?.join();
        settlement_thread = null;
        if (settlement.result) |err| return err;
        return error.SettlementCheckpointMissing;
    }
    try std.testing.expectEqual(SettlementCheckpoint.transaction_active, shared.checkpoint.load(.acquire));

    var stop = try completeSessionStop("transaction-race-stop", session.slice());
    var interrupt = try completeModelInterruption(
        "transaction-race-interrupt",
        session.slice(),
        binding,
    );
    var stop_context: StopContext = .{
        .storage = &storage,
        .command = &stop,
        .probe = .{ .shared = &shared },
    };
    var interrupt_context: InterruptContext = .{
        .storage = &storage,
        .command = &interrupt,
        .probe = .{ .shared = &shared },
    };
    stop_thread = try std.Thread.spawn(.{}, StopContext.run, .{&stop_context});
    interrupt_thread = try std.Thread.spawn(.{}, InterruptContext.run, .{&interrupt_context});
    shared.controls_requested.waitUncancelable(std.testing.io);
    shared.controls_requested.waitUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 0), interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(!stop_context.finished.load(.seq_cst));
    try std.testing.expect(!interrupt_context.finished.load(.seq_cst));

    shared.settlement_release.post(std.testing.io);
    settlement_released = true;
    settlement_thread.?.join();
    settlement_thread = null;
    stop_thread.?.join();
    stop_thread = null;
    interrupt_thread.?.join();
    interrupt_thread = null;
    if (settlement.result) |err| return err;

    const settlement_complete_order = shared.settlement_complete_order.load(.seq_cst);
    try std.testing.expect(shared.transaction_active_order.load(.seq_cst) < settlement_complete_order);
    try std.testing.expect(settlement_complete_order < stop_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expect(settlement_complete_order < interrupt_context.probe.lock_acquired_order.load(.seq_cst));
    try std.testing.expectEqual(c.SQLITE_TXN_NONE, c.sqlite3_txn_state(storage.database, "main"));

    const stop_reply = stop_context.reply.?;
    try std.testing.expect(stop_reply == .accepted);
    try std.testing.expectEqual(binding.turn_id, stop_reply.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(protocol.SessionStopCompletion.completed, stop_reply.accepted.completion);
    const interrupt_reply = interrupt_context.reply.?;
    try std.testing.expect(interrupt_reply == .rejected);
    try std.testing.expectEqual(protocol.ModelInterruptionRejection.operation_resolved, interrupt_reply.rejected.code);

    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
    try expectContent(
        &storage,
        try storage.actionCallId(session.slice(), action_id),
        "transaction-race-call",
    );
    try expectContent(
        &storage,
        try storage.actionArguments(session.slice(), action_id),
        "{\"description\":\"Run no-op command\",\"cmd\":\"true\",\"timeout_ms\":null}",
    );
}

test "controls remove scheduled retries and replay without cancelling newer work after reopen" {
    const Control = enum { none, stop, interruption };
    for ([_]Control{ .none, .stop, .interruption }) |control| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        var storage_open = true;
        defer if (storage_open) storage.close() catch unreachable;

        const session = try configureTestSession(&storage, "retry-config");
        try submitTestMessage(&storage, &tmp, "retry-first", "retry-message", session.slice(), "first");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "temporary" }, .{ .retryable = .{
            .waits_ms = .{ 60_000, 60_000, 60_000 },
        } }, .{});
        // Make the saved retry due without depending on wall-clock scheduling.
        try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL");

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
        try expectActivityOutcome(&storage, session.slice(), binding, "cancelled");

        try submitTestMessage(&storage, &tmp, "retry-newer", "retry-newer-message", session.slice(), "newer");
        const newer_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expect(newer_binding.turn_id != binding.turn_id);
        for (0..2) |pass| {
            if (pass == 1) {
                try storage.close();
                storage_open = false;
                try testingStore(&storage, &tmp, std.testing.io);
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

test "accepted stop remains discoverable without a control hint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "dispatch handoff refuses a stopped Attempt without invoking the launch callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "failed control commit saves no answer after reopening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    const session = try configureTestSession(&storage, "configure-control-rollback");
    var stop = try completeSessionStop("rollback-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{ .before_commit = true }) == .infrastructure_failure);
    try std.testing.expect(storage.isFenced());
    try storage.close();

    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(
        &database_buffer,
        "{s}/store.sqlite3",
        .{root_buffer[0..root_length]},
    );
    try storage.open(std.testing.io, database, root_buffer[0..root_length]);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("rollback-stop")).status == .absent);
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
            .name = "new request missing provider",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = null,
            .model_requested = "model-a",
            .expected = .incomplete_initial_configuration,
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
            configuration_domain.configurationBeforeWorkspace(current, &requested),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "Store configuration requires and freezes provider model and workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "unsupported provider rejects mixed configuration atomically and replays exact shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const content_count = try queryU64(storage.database, "SELECT count(*) FROM content");
    const revision_count = try queryU64(storage.database, "SELECT count(*) FROM session_revision");
    const rejected = storage.configure(&update, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_provider, rejected.rejected.code);
    try std.testing.expectEqual(content_count, try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(revision_count, try queryU64(storage.database, "SELECT count(*) FROM session_revision"));
    const current = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 1), current.revision);
    try std.testing.expectEqual(@as(u8, 1), current.tools_mask);
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

fn expectBindingPreserved(storage: *Store, session: []const u8, phase: []const u8) !void {
    for (0..6) |variant| {
        const before = try storage.inspectSessionForTesting(session);
        var key_buffer: [128]u8 = undefined;
        var update: protocol.ConfigureCommand = .{};
        try update.key.set(try std.fmt.bufPrint(&key_buffer, "binding-{s}-{d}", .{ phase, variant }));
        try update.session.set(session);
        if (variant & 1 != 0 or variant == 4) {
            update.configuration.provider.state = .value;
            try update.configuration.provider.value.set(if (variant == 4) "anthropic" else "codex");
        }
        if (variant & 2 != 0 or variant == 5) {
            update.configuration.model.state = .value;
            try update.configuration.model.value.set(if (variant == 5) "model-b" else "model-a");
        }
        if (variant >= 4) {
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
        }
        const reply = storage.configure(&update, .{});
        if (variant < 4) {
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(before.revision + 1, reply.accepted.revision);
        } else {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(if (variant == 4) protocol.ConfigurationRejection.unsupported_provider else protocol.ConfigurationRejection.model_is_immutable, reply.rejected.code);
        }
        const after = try storage.inspectSessionForTesting(session);
        try std.testing.expectEqual(before.revision + @as(u64, if (variant < 4) 1 else 0), after.revision);
        try std.testing.expectEqual(protocol.Provider.codex, after.provider.?);
        try std.testing.expectEqualStrings("model-a", after.model.slice());
        try std.testing.expectEqual(before.tools_mask, after.tools_mask);
        try std.testing.expectEqualStrings(before.permission_mode.slice(), after.permission_mode.slice());
        try std.testing.expectEqualDeep(before.instructions, after.instructions);
        try std.testing.expectEqualDeep(before.output_schema, after.output_schema);
    }
}

test "persisted settings survive reopen and corrupt canonical provider fences current and historical reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("provider-reopen", "", workspace, "model-a");
    configuration.configuration.tools.state = .value;
    configuration.configuration.tools.count = 1;
    configuration.configuration.tools.values[0] = .bash;
    configuration.configuration.permission_mode.state = .value;
    try configuration.configuration.permission_mode.value.set("ask");
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try expectBindingPreserved(&storage, created_session_0.slice(), "before-reopen");
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const reopened = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(protocol.Provider.codex, reopened.provider.?);
    try std.testing.expectEqual(@as(u8, 1), reopened.tools_mask);
    try std.testing.expectEqualStrings("ask", reopened.permission_mode.slice());
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-reopen");

    const file = try tmp.dir.createFile(std.testing.io, "provider-reopen-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("provider-reopen-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try execSessionSql(storage.database, "UPDATE session_revision SET provider='other' WHERE session_ref=?1", created_session_0.slice());
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    view.close();
    try execSessionSql(storage.database, "UPDATE session_revision SET provider='codex' WHERE session_ref=?1", created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT codec='openai-responses/1' AND codec_options IS NULL FROM session"));
    for ([_][:0]const u8{
        "UPDATE session SET provider='Codex' WHERE session_ref=?1",
        "UPDATE session_revision SET provider='9codex' WHERE session_ref=?1",
        "UPDATE session SET provider='codex.v2' WHERE session_ref=?1",
        "UPDATE session SET provider='' WHERE session_ref=?1",
        "UPDATE session SET provider='abcdefghijklmnopq' WHERE session_ref=?1",
        "UPDATE session SET codec_options=x'' WHERE session_ref=?1",
    }) |fault| try std.testing.expectError(error.StatementFailed, execSessionSql(storage.database, fault, created_session_0.slice()));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);

    try execSessionSql(storage.database, "UPDATE session SET provider='other' WHERE session_ref=?1", created_session_0.slice());
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));
}

test "a Session pinned to a codec this Host cannot build fences its settings" {
    for ([_]?[:0]const u8{
        null,
        "UPDATE session SET codec='openai-responses/2' WHERE session_ref=?1",
        "UPDATE session SET codec_options=x'00' WHERE session_ref=?1",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT codec='openai-responses/1' AND codec_options IS NULL FROM session"));
        try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "text");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        if (fault) |sql| try execSessionSql(storage.database, sql, session.slice());
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(binding, &view);
        defer view.close();
        if (fault == null) _ = try testSettings(&view) else try std.testing.expectError(error.CorruptStore, testSettings(&view));
    }
}

test "created Session tools and permission resolve to product defaults" {
    // Decode the persisted encoding independently of toolBit/permissionModeCode.
    const created: CurrentConfiguration = .{};
    var tools: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&tools);
    if (created.tools_mask & 1 != 0) try writer.writeAll("bash");
    try std.testing.expect(created.tools_mask & ~@as(u8, 1) == 0);
    try std.testing.expectEqualStrings(product_defaults.tools, writer.buffered());
    try std.testing.expectEqualStrings(product_defaults.permission_mode, switch (created.permission_mode) {
        0 => "ask",
        1 => "bypass",
        else => return error.TestUnexpectedResult,
    });
}

test "configuration planning preserves sparse defaults and rejection precedence" {
    const WorkspaceRequest = enum { omitted, same, different };
    const InstructionsRequest = enum { omitted, value };
    const SchemaRequest = enum { omitted, value, clear };
    const Actions = struct {
        instructions: ConfigurationContentAction,
        output_schema: ConfigurationContentAction,
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
        expected_tools: u8 = 1,
        expected_permission: u8 = 0,
        expected_revision: u64 = 8,
    };
    const cases = [_]Case{
        .{
            .name = "new defaults",
            .created = true,
            .workspace = .same,
            .model = "model-a",
            .expected_actions = .{ .instructions = .default_empty, .output_schema = .clear },
            .expected_tools = 1,
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
            .expected_tools = 0,
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
        try std.testing.expectEqual(case.expected_tools, next.tools_mask);
        try std.testing.expectEqual(case.expected_permission, next.permission_mode);
        try std.testing.expectEqual(case.expected_revision, next.revision);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 11), next.instructions_id);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 12), next.output_schema_id);
    }
}

test "configuration rejections bypass content effects and replay committed answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const instructions = "rejected instructions";
    const instructions_file = try tmp.dir.createFile(std.testing.io, "rejected-instructions", .{ .read = true });
    try instructions_file.writeStreamingAll(std.testing.io, instructions);
    try instructions_file.sync(std.testing.io);
    const schema = "{\"type\":\"object\"}";
    const schema_file = try tmp.dir.createFile(std.testing.io, "rejected-schema", .{ .read = true });
    try schema_file.writeStreamingAll(std.testing.io, schema);
    try schema_file.sync(std.testing.io);
    var command: protocol.ConfigureCommand = .{};
    try command.key.set("rejected-content");
    try command.session.set("invalid/session");
    command.configuration.instructions = .{
        .state = .value,
        .file = instructions_file,
        .length = instructions.len,
        .digest = protocol.contentDigest(instructions),
    };
    command.configuration.output_schema = .{
        .state = .value,
        .file = schema_file,
        .length = schema.len,
        .digest = protocol.contentDigest(schema),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect(storage.configure(&command, .{
            .content_import = true,
            .before_commit = true,
        }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("rejected-content")).status == .absent);
        const rolled_back_content = try sqlite.prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(rolled_back_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(rolled_back_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(rolled_back_content, 0));

        const rejected = storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
        const committed_content = try sqlite.prepare(
            storage.database,
            "SELECT COUNT(*) FROM core_command WHERE command_key='rejected-content' " ++
                "AND primary_content_id IS NULL AND secondary_content_id IS NULL",
        );
        defer _ = c.sqlite3_finalize(committed_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(committed_content));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(committed_content, 0));

        const replay = storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(replay == .rejected);
        try std.testing.expect(replay.rejected.replayed);
        try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, replay.rejected.code);
        const retained_content = try sqlite.prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(retained_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(retained_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(retained_content, 0));
    }
}

test "configuration answers replay without reverting newer settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "content reader owns the bounded result-delivery window" {
    try std.testing.expectEqual(@as(usize, 4096), protocol.content_window_bytes);
    try std.testing.expectEqual(
        @as(usize, 64 * 1024),
        ContentReader.content_window_bytes,
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "interleaved large content readers bound repeated SQLite page reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const length = 4 * 1024 * 1024;
    const first = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(second);
    for (first, second, 0..) |*a, *b, index| {
        a.* = @intCast(index % 251);
        b.* = @intCast((index * 17 + 37) % 253);
    }
    _ = try content_domain.importBytesContent(&storage, first, false, false);
    _ = try content_domain.importBytesContent(&storage, second, false, false);
    var readers: [2]ContentReader = undefined;
    readers[0].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(first) }));
    readers[1].open(try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(second) }));
    defer for (&readers) |*reader| reader.close();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    readers[0].allocator = failing.allocator();
    var buffer: [4096]u8 = undefined;
    // EOF needs no read-ahead allocation. A real allocation failure preserves
    // the existing bounded reads and leaves this same Store usable.
    try std.testing.expectEqual(@as(usize, 0), try readers[0].read(length, &buffer));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(buffer.len, try readers[0].read(0, &buffer));
    try std.testing.expectEqualSlices(u8, first[0..buffer.len], &buffer);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    for (&readers) |*reader| reader.allocator = std.testing.allocator;
    var misses: c_int = 0;
    var ignored: c_int = 0;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.database, c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 1));
    var offset: usize = 0;
    while (offset < length) : (offset += buffer.len) {
        for (&readers, [_][]const u8{ first, second }) |*reader, expected| {
            try std.testing.expectEqual(buffer.len, try reader.read(offset, &buffer));
            try std.testing.expectEqualSlices(u8, expected[offset..][0..buffer.len], &buffer);
        }
        if (offset == 0) {
            _ = try configureTestSession(&storage, "interleaved-write");
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
    }
    for (&readers) |*reader| try std.testing.expectEqual(@as(usize, 0), try reader.read(length, &buffer));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_db_status(storage.database, c.SQLITE_DBSTATUS_CACHE_MISS, &misses, &ignored, 0));
    // Two 4-MiB streams through a 1-MiB SQLite cache must not re-read their
    // entire overflow prefix for every 4-KiB delivery, including interleaving.
    const pages = 2 * length / 4096;
    try std.testing.expect(misses <= 16 * pages);
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    {
        const corrupt = try sqlite.prepare(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindI64(corrupt, 1, readers[0].content_id);
        try sqlite.expectDone(corrupt);
    }
    // Copied bytes belong only to their original reader. A newly resolved
    // raw reader must see the changed row, not another reader's old window.
    var fresh: ContentReader = undefined;
    fresh.open(try storage.openContent(readers[0].reference));
    defer fresh.close();
    fresh.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(first[length - 1], buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), try fresh.read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
    {
        const remove = try sqlite.prepare(storage.database, "DELETE FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(remove);
        try sqlite.bindI64(remove, 1, readers[0].content_id);
        try sqlite.expectDone(remove);
    }
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectError(error.ContentReadFailed, readers[0].read(0, &buffer));
    try std.testing.expect(storage.isFenced());
}

test "retained readers allow checkpoints between committed windows" {
    var checkpoints: [2]c_int = undefined;
    for ([_]bool{ false, true }, 0..) |answer, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const text = @as([32768]u8, @splat('x')) ++ "asymmetric-é-tail";
        const location = if (answer) blk: {
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = text, .decoded = text }});
            break :blk try storage.openPublicConversationContent(&request);
        } else blk: {
            _ = try content_domain.importBytesContent(&storage, text, false, false);
            break :blk try storage.openContent(.{ .length = text.len, .digest = protocol.contentDigest(text) });
        };
        var reader: ContentReader = undefined;
        reader.open(location);
        defer reader.close();
        var window: [4096]u8 = undefined;
        try std.testing.expectEqual(window.len, try reader.read(0, &window));
        try std.testing.expectEqualSlices(u8, text[0..window.len], &window);
        // Keep the reader alive across an unrelated ordinary commit, just as
        // slow Reply delivery or an allowance-limited preparation does.
        _ = try configureTestSession(&storage, "checkpoint-write");
        checkpoints[index] = c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        var offset: usize = window.len;
        while (offset < text.len) {
            const count = try reader.read(offset, &window);
            try std.testing.expectEqualSlices(u8, text[offset..][0..count], window[0..count]);
            offset += count;
        }
        try std.testing.expectEqual(@as(usize, 0), try reader.read(text.len, &window));
    }
    try std.testing.expectEqualSlices(c_int, &.{ c.SQLITE_OK, c.SQLITE_OK }, &checkpoints);
}

test "yielded Bash preparation leaves checkpoints free while retaining its descriptor" {
    const bash = @import("../bash.zig");
    for ([_]usize{ 0, 1024 * 1024 }) |padding_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const command = "printf " ++ @as([16384]u8, @splat('x'));
        const padding = try std.testing.allocator.alloc(u8, padding_length);
        defer std.testing.allocator.free(padding);
        @memset(padding, ' ');
        const descriptor = try std.testing.allocator.print("{{\"cmd\":\"{s}\",{s}\"timeout_ms\":null,\"description\":\"Print marker\"}}", .{ command, padding });
        defer std.testing.allocator.free(descriptor);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, descriptor, .{});
        defer std.testing.allocator.free(encoded);
        const request = try testingPublicProjection(&storage, &tmp, &.{.{
            .encoded = encoded[1 .. encoded.len - 1],
            .decoded = descriptor,
        }});
        var input: BashExecutionInput = .{
            .session = request.session,
            .sender_handle = .{},
            .workspace = .{},
            .arguments = .{ .length = descriptor.len, .digest = undefined },
            .timeout_ms = 1000,
        };
        try input.workspace.set(storage.selector.slice());
        var used: std.atomic.Value(u64) = .init(0);
        const scratch: bash.Scratch = .{ .io = std.testing.io, .path = storage.selector.slice(), .budget = .{ .used = &used, .limit = 4096 } };
        var preparation: bash.Preparation = undefined;
        if (preparation.start(scratch, std.testing.allocator, try storage.openPublicConversationContent(&request), &input, storage.selector.slice(), "/bin/bash", 11, .{})) |initial| {
            var failure = initial;
            try failure.cleanup.cleanup(scratch);
            return failure.cause;
        }
        var owned = true;
        defer if (owned) {
            var cleanup = preparation.cancel();
            cleanup.cleanup(scratch) catch unreachable;
        };
        var prepared: bash.Prepared = undefined;
        try std.testing.expect(preparation.advance(&prepared) == .pending);
        _ = try configureTestSession(&storage, "bash-checkpoint");
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        while (true) {
            var progress = preparation.advance(&prepared);
            switch (progress) {
                .pending => {},
                .prepared => {
                    owned = false;
                    defer prepared.cleanup() catch unreachable;
                    try std.testing.expectEqualStrings(command, prepared.command.?);
                    break;
                },
                .failed => |*failure| {
                    owned = false;
                    try failure.cleanup.cleanup(scratch);
                    return failure.cause;
                },
            }
        }
        try std.testing.expectEqual(@as(u64, 0), used.load(.monotonic));
    }
}

test "core preserves empty and NUL keys while Session references stay canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(session.slice())).revision);
    try std.testing.expect(!storage.isFenced());
}

test "saved incomplete initialization stays rejected after Session creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "capability-required configuration rejects on replacement and replays its saved decision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "failed commit saves neither answer nor partial Session" {
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
        try testingStore(&storage, &tmp, std.testing.io);
        const reply = storage.configure(&command, .{ .before_commit = true });
        try std.testing.expect(reply == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("commit-fault")).status == .absent);
        try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    }
}

test "an outside SQLite writer cannot take the open Store's lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    const database = try std.fmt.bufPrintSentinel(&database_buffer, "{s}/store.sqlite3", .{root}, 0);
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    var blocker: ?*c.sqlite3 = null;
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_OK),
        c.sqlite3_open_v2(
            database.ptr,
            &blocker,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_NOMUTEX,
            null,
        ),
    );
    var blocker_open = true;
    defer if (blocker_open) {
        _ = c.sqlite3_close(blocker);
    };
    // The Store's exclusive lock refuses the outside writer, never the Host.
    try std.testing.expectEqual(
        @as(c_int, c.SQLITE_BUSY),
        c.sqlite3_exec(blocker, "BEGIN IMMEDIATE", null, null, null),
    );

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "busy-save",
        "",
        workspace,
        "model-a",
    );
    const configured = storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    try std.testing.expect(!storage.isFenced());

    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_close(blocker));
    blocker_open = false;
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try reopened.open(std.testing.io, database, root);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("busy-save")).status != .absent);
    try std.testing.expect((try reopened.inspectSessionForTesting(configured.accepted.session.slice())).found);
}

test "real SQLite full during import publishes no canonical prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const page_count = try sqlite.pragmaInt(storage.database, "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    const limit = try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0);
    try sqlite.exec(storage.database, limit);
    try std.testing.expectEqual(page_count, try sqlite.pragmaInt(storage.database, "PRAGMA max_page_count"));

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "full-import",
        "",
        workspace,
        "model-a",
    );
    command.configuration.instructions = try testingContent(
        &tmp,
        "full-import-content",
        'x',
        128 * 1024,
    );
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    // Drive the production transaction body directly so the test observes
    // the exact import-step result before the public wrapper maps it. SQLite
    // automatically rolls this FULL transaction back; the public wrapper's
    // `finishTransaction` then fences it as a non-ordinary error.
    try std.testing.expectError(
        error.CanonicalStorageFull,
        configuration_domain.configureLocked(&storage, &command, .{}),
    );
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    storage.fence(error.CanonicalStorageFull) catch {};
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("full-import"));
    try storage.close();
    storage_open = false;

    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("full-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(reopened.database, "SELECT count(*) FROM session"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        reopened.database,
        "SELECT count(*) FROM content WHERE byte_length=131072",
    ));
}

/// Records each `MessageCommitted` call, as the Host's environment install sees it.
const TestingCommits = struct {
    calls: [4]struct { session: protocol.Bounded(protocol.max_session_bytes), admission_id: u64, from_peer: bool } = undefined,
    count: usize = 0,

    fn callback(self: *TestingCommits) Store.MessageCommitted {
        return .{ .context = self, .call = record };
    }

    fn record(context: *anyopaque, admission: Store.MessageAdmission) void {
        const self: *TestingCommits = @ptrCast(@alignCast(context));
        self.calls[self.count] = .{ .session = .{}, .admission_id = admission.admission_id, .from_peer = admission.from_peer };
        self.calls[self.count].session.set(admission.session) catch unreachable;
        self.count += 1;
    }
};

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_text = "first message\n" ++ @as([700 * 6]u8, @bitCast(@as([700][6]u8, @splat("abcdef".*)))) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", created_session_0.slice(), first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const before = try sqlite.pragmaInt(storage.database, "SELECT unixepoch()");
    var commits: TestingCommits = .{};
    const first_reply = storage.submitMessageWithModel(&first, commits.callback(), .{});
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(commits.calls[0].session.eql(created_session_0.slice()));
    try std.testing.expectEqual(@as(u64, 1), commits.calls[0].admission_id);
    try std.testing.expect(!commits.calls[0].from_peer);
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", created_session_0.slice(), second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessageWithModel(&second, null, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);
    // The Host stamps each admission with its wall clock, to the second.
    const after = try sqlite.pragmaInt(storage.database, "SELECT unixepoch()");
    const stamped = try sqlite.pragmaInt(storage.database, "SELECT admitted_at FROM message_admission WHERE admission_id=1");
    try std.testing.expect(before <= stamped and stamped <= after);
    // A replayed or restarted admission keeps the time it was admitted at.
    try sqlite.exec(storage.database, "UPDATE message_admission SET admitted_at=1000 WHERE admission_id=1");

    const replay = storage.submitMessageWithModel(&first, commits.callback(), .{});
    // A replayed admission installs nothing.
    try std.testing.expectEqual(@as(usize, 1), commits.count);
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSessionForTesting(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 2), session.pending_messages);
    const observed = try storage.observeCommand("message-1");
    try std.testing.expect(observed.status == .accepted);
    try std.testing.expect(observed.kind == .message);
    try std.testing.expect(observed.message != null);
    const accepted_observation = observed.message.?.queue.?;
    try std.testing.expectEqual(first_reply.accepted.admission_id, accepted_observation.admission_id);
    try std.testing.expect(accepted_observation.state == .queued);

    var reader: ContentReader = undefined;
    reader.open(try storage.openContent(observed.message.?.content));
    var actual: [first_text.len]u8 = undefined;
    var offset: usize = 0;
    while (offset < actual.len) {
        const count = try reader.read(offset, actual[offset..@min(actual.len, offset + 31)]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    reader.close();
    try std.testing.expectEqualSlices(u8, first_text, &actual);

    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const restarted = try storage.observeCommand("message-1");
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.message.?.queue.?.admission_id);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
    try std.testing.expectEqual(@as(u32, 1000), try sqlite.pragmaInt(storage.database, "SELECT admitted_at FROM message_admission WHERE admission_id=1"));
}

fn testingLabel(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?[]u8 {
    const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const label = report.value.object.get("session").?.object.get("label").?;
    return if (label == .null) null else try std.testing.allocator.dupe(u8, label.string);
}

test "a Label is configured, replayed, cleared and validated like any setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(u64, 3), try queryU64(storage.database, "SELECT count(*) FROM session_revision WHERE label IS NOT NULL"));

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

test "model admission skips Sessions of a provider the Host does not serve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    const settings = try completeConfiguration("unserved", "", workspace, "model-a");
    var message: protocol.MessageCommand = .{ .configuration = settings.configuration };
    try message.key.set("unserved");
    message.text = try testingBytesContent(&tmp, "unserved-message", "wait for a Host that serves me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    {
        var storage: Store = undefined;
        try storage.openWithOptions(std.testing.io, database, root, .{ .served = protocol.routesAll(.unserved) });
        defer storage.close() catch unreachable;
        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        try std.testing.expect(try storage.admitNextModelAttempt(.{}) == null);
    }
    var storage: Store = undefined;
    try storage.openWithOptions(std.testing.io, database, root, .{ .served = protocol.routesAll(.endpoint) });
    defer storage.close() catch unreachable;
    try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
}

test "a creating Message with require_model creates nothing without a model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
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
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
}

test "initial Message atomically allocates its Session and replays its original admission" {
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
        try testingStore(&storage, &tmp, std.testing.io);
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
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
        var refused = message;
        try refused.key.set("invalid-initial-settings");
        refused.configuration.?.workspace.value = .{};
        const rejected = storage.submitMessageWithModel(&refused, null, .{});
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.MessageRejection.invalid_workspace, rejected.rejected.code);
        try std.testing.expect(storage.submitMessageWithModel(&refused, null, .{}).rejected.replayed);
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const replay = storage.submitMessageWithModel(&message, null, .{}).accepted;
        try std.testing.expect(replay.replayed);
        try std.testing.expectEqual(first.admission_id, replay.admission_id);
        try std.testing.expectEqualDeep(first.session, replay.session);
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM message_admission"));
        var failed = message;
        try failed.key.set("failed-start-commit");
        try std.testing.expect(storage.submitMessageWithModel(&failed, null, .{ .before_commit = true }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expectEqual(.absent, (try storage.observeCommand("failed-start-commit")).status);
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
        try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM message_admission"));
    }
}

test "message rejections replay before current Session checks without retained input" {
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
    try testingStore(&storage, &tmp, io);
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

test "a peer sender is resolved from its Action handle and exact replays survive revocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const sender_id = try configureTestSession(&storage, "configure-sender");
    const sender = sender_id.slice();
    // Pages retain the complete allocated identity, not a display alias.
    _ = try configureTestSession(&storage, "configure-neighbour");
    const allocated_session_1 = try configureTestSession(&storage, "configure-receiver");
    var tools: protocol.ConfigureCommand = .{};
    try tools.key.set("sender-tools");
    try tools.session.set(sender);
    tools.configuration.tools = .{ .state = .value, .count = 1, .values = .{.bash} };
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
    const sender_end = (try storage.activityPageForTesting(.{ .session = own_ref })).end;
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
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM sent_rejection"));
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(allocated_session_1.slice())).pending_messages);

    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set(allocated_session_1.slice());
    const received = try storage.activityPageForTesting(.{ .session = session });
    try std.testing.expectEqual(@as(usize, 1), received.count);
    const peer = received.items[0].value.admission.sender.?;
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
    try sqlite.exec(storage.database, "UPDATE sent_rejection SET rejected_at=200+sender_position");
    const own = try storage.activityPageForTesting(.{ .session = session, .position = sender_end });
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

test "message observation validates accepted admission references independently" {
    const corruptions = [_]enum { session, content }{ .session, .content };
    for (corruptions) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
            .session => try execSessionSql(
                storage.database,
                "UPDATE message_admission SET session_ref=?1 " ++
                    "WHERE command_key='reference-primary-message'",
                other_session.slice(),
            ),
            .content => try sqlite.exec(
                storage.database,
                "UPDATE message_admission SET content_id=(" ++
                    "SELECT content_id FROM message_admission WHERE command_key='reference-other-message') " ++
                    "WHERE command_key='reference-primary-message'",
            ),
        }
        try std.testing.expectError(
            error.CorruptStore,
            storage.observeCommand("reference-primary-message"),
        );
        try std.testing.expect(storage.isFenced());
    }
}

test "message observation rejects an answer attached to processing durable facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try sqlite.exec(
        storage.database,
        "UPDATE turn SET outcome_content_id=(" ++
            "SELECT content_id FROM message_admission WHERE command_key='corrupt-observation-message')",
    );

    try std.testing.expectError(
        error.CorruptStore,
        storage.observeCommand("corrupt-observation-message"),
    );
    try std.testing.expect(storage.isFenced());
}

test "message conflicts and failed commits cannot create another admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);

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

    try testingStore(&storage, &tmp, std.testing.io);
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

test "failed message import rolls back content command and admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);

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

    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("message-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
}

test "rollback failure fences mutation until fresh reopen restores committed facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "rollback-configure",
        "",
        workspace,
        "model-a",
    );
    const message_file = try tmp.dir.createFile(std.testing.io, "rollback-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "committed prefix");
    try message_file.sync(std.testing.io);
    var message = try completeMessage(
        "rollback-message",
        "",
        message_file,
        "committed prefix",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const configured = storage.configure(&configuration, .{});
        try std.testing.expect(configured == .accepted);
        message.session = configured.accepted.session;
        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.admitNextModelAttempt(.{
                .attempt_before_commit = true,
                .rollback_failure = true,
            }),
        );
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_get_autocommit(storage.database));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, storage.admitNextModelAttempt(.{}));
        var later = try completeConfiguration("rollback-later", "", workspace, "model-a");
        try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
        try storage.close();
    }

    var binding: AttemptBinding = undefined;
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        try std.testing.expect((try storage.observeCommand("rollback-configure")).status == .accepted);
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .queued,
        );
        {
            const partial = try sqlite.prepare(
                storage.database,
                "SELECT (SELECT count(*) FROM turn),(SELECT count(*) FROM model_operation)," ++
                    "(SELECT count(*) FROM conversation_entry)",
            );
            defer _ = c.sqlite3_finalize(partial);
            try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(partial));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 0));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 1));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 2));
        }

        var admission = (try storage.admitNextModelAttempt(.{})).?;
        binding = try admission.permit.consume();
        var stale = binding;
        stale.attempt_ordinal += 1;
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.settleModelAttemptFailure(
                stale,
                .{ .uncorrelated = "must-not-settle" },
                .ordinary,
                .{ .rollback_failure = true },
            ),
        );
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(
            error.StoreFenced,
            storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "must-not-settle" }, .ordinary, .{}),
        );
        try storage.close();
    }

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("rollback-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(binding.operation_id, observed_binding.operation_id);
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .failed,
        );
    }
}

test "production Store applies finite durable SQLite settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.database, "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.database, "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.database, "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(storage.database, "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(storage.database, "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4194304), try sqlite.pragmaInt(storage.database, "PRAGMA journal_size_limit"));
    try std.testing.expectEqualStrings("exclusive", (sqlite.diagnosticTextPragma(storage.database, "PRAGMA locking_mode") orelse return error.TestUnexpectedResult).slice());
    try std.testing.expectEqual(@as(u32, 4096), try sqlite.pragmaInt(storage.database, "PRAGMA page_size"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(storage.database, "PRAGMA trusted_schema"));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_threadsafe());
    try std.testing.expectEqual(@as(i64, sqlite_heap_bytes), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expectEqual(@as(c_int, 16 * 1024), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_SQL_LENGTH, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_ATTACHED, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_WORKER_THREADS, -1));

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?u64, 4096), diagnostic.page_size_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expect(diagnostic.cache_spill_threshold.? > 0);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.mmap_size_bytes);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqual(@as(?i64, 1), diagnostic.temp_store);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.busy_timeout_ms);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
    try std.testing.expect(diagnostic.process_memory_current_bytes != null);
    try std.testing.expect(diagnostic.process_memory_highwater_bytes != null);
    try std.testing.expect(diagnostic.cache_used_bytes != null);
    try std.testing.expect(diagnostic.cache_spills != null);
    // Readback alone would only prove configuration. A single SQLite-owned
    // allocation larger than the process-global hard ceiling must be denied
    // by the pinned library while this Store owns the configured limit.
    const over_limit = c.sqlite3_malloc64(sqlite_heap_bytes + 1);
    defer c.sqlite3_free(over_limit);
    try std.testing.expect(over_limit == null);
}

/// Rows in a raw copy's content table, or null when the copy lacks the table.
fn rawContentCount(path: []const u8) !?u64 {
    var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    if (c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0), &raw) != c.SQLITE_OK) return error.StoreOpenFailed;
    const statement = sqlite.prepare(raw.?, "SELECT count(*) FROM content") catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    return @intCast(c.sqlite3_column_int64(statement, 0));
}

test "Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const vfs = c.sqlite3_vfs_find(null) orelse return error.SqliteVfsUnavailable;
    try std.testing.expectEqual(@as(c_int, 512), vfs.*.mxPathname);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    const paths = try platform.resolveClientPaths(io, store_path);
    const database = paths.database.slice();
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), database.len);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    const wal = try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database});
    var shm_buffer: [platform.max_database_path_bytes + "-shm".len]u8 = undefined;
    const shm = try std.fmt.bufPrint(&shm_buffer, "{s}-shm", .{database});
    var journal_buffer: [platform.max_database_path_bytes + "-journal".len]u8 = undefined;
    const journal = try std.fmt.bufPrint(&journal_buffer, "{s}-journal", .{database});
    try tmp.dir.createDir(io, "crash", .default_dir);
    try tmp.dir.createDir(io, "database-only", .default_dir);

    var storage: Store = undefined;
    try storage.open(io, database, paths.store.slice());
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    try sqlite.exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))");
    const crash_rows = try queryU64(storage.database, "SELECT count(*) FROM content");
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size > 0);
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, journal, .{}));

    // The open Host excludes every other reader and a second owner.
    {
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        var raw: ?*c.sqlite3 = null;
        defer _ = c.sqlite3_close(raw);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw, c.SQLITE_OPEN_READONLY, null));
        var statement: ?*c.sqlite3_stmt = null;
        const prepared = c.sqlite3_prepare_v2(raw, "SELECT count(*) FROM content", -1, &statement, null);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expect(prepared == c.SQLITE_BUSY or (prepared == c.SQLITE_OK and c.sqlite3_step(statement) == c.SQLITE_BUSY));
    }
    var refused: Store = undefined;
    if (refused.open(io, database, paths.store.slice())) |_| return error.TestUnexpectedResult else |_| {}
    // The failed open released the process-wide heap limit; restore it.
    _ = c.sqlite3_hard_heap_limit64(sqlite_heap_bytes);

    // A process crash leaves exactly these files; the WAL holds the commits.
    try cwd.copyFile(database, tmp.dir, "crash/rui.sqlite3", io, .{});
    try cwd.copyFile(wal, tmp.dir, "crash/rui.sqlite3-wal", io, .{});
    try cwd.copyFile(database, tmp.dir, "database-only/rui.sqlite3", io, .{});

    // A payload past the auto-checkpoint size moves into the database file,
    // and the next commit truncates the reset WAL to the size limit.
    try sqlite.exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),6291456,0,zeroblob(6291456))");
    try sqlite.exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,zeroblob(0))");
    try std.testing.expect((try cwd.statFile(io, database, .{})).size > 6291456);
    try std.testing.expect((try cwd.statFile(io, wal, .{})).size <= 4194304);
    try storage.close();
    storage_open = false;
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, wal, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.statFile(io, shm, .{}));

    // Restoring the complete crash copy at the original path recovers its
    // commits; the database file alone does not.
    try tmp.dir.copyFile("crash/rui.sqlite3", cwd, database, io, .{});
    try tmp.dir.copyFile("crash/rui.sqlite3-wal", cwd, wal, io, .{});
    try storage.open(io, database, paths.store.slice());
    storage_open = true;
    try std.testing.expectEqual(crash_rows, try queryU64(storage.database, "SELECT count(*) FROM content"));
    var database_only_buffer: [protocol.max_store_bytes + 32]u8 = undefined;
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const database_only = try std.fmt.bufPrint(&database_only_buffer, "{s}/database-only/rui.sqlite3", .{root});
    const surviving = try rawContentCount(database_only);
    try std.testing.expect(surviving == null or surviving.? < crash_rows);
}

test "measurement Store can disable cache spill without changing other limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.openWithOptions(
        std.testing.io,
        database,
        root,
        .{ .cache_spill = false },
    );
    defer storage.close() catch unreachable;

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?i64, 0), diagnostic.cache_spill_threshold);
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?i64, -1024), diagnostic.cache_size_setting);
    try std.testing.expectEqual(@as(?i64, 2), diagnostic.synchronous);
    try std.testing.expectEqualStrings("wal", diagnostic.journal_mode.?.slice());
}

test "measurement Store can force a smaller SQLite cache without changing production defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 32 });
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(?i64, -32), storage.sqliteDiagnostic().cache_size_setting);
    var refused: Store = undefined;

    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 0 }),
    );
    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        refused.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 4097 }),
    );
}

test "the schema value renders today's SQLite schema" {
    // Each difference is semantically equal by construction: SQL table
    // constraints are an unordered set, and parentheses add no expression node.
    const Difference = struct { object: []const u8, today: []const u8, rendered: []const u8 };
    const differences = [_]Difference{
        // Table constraints render primary key, uniques, foreign keys, checks.
        .{ .object = "model_operation", .today = ", UNIQUE(operation_id,session_ref) )", .rendered = " )" },
        .{ .object = "model_operation", .today = "resolved_at>0), FOREIGN KEY", .rendered = "resolved_at>0), UNIQUE(operation_id,session_ref), FOREIGN KEY" },
        .{ .object = "model_output_part", .today = ", PRIMARY KEY(operation_id,item_ordinal,part_ordinal) )", .rendered = " )" },
        .{ .object = "model_output_part", .today = "content(content_id), CHECK(", .rendered = "content(content_id), PRIMARY KEY(operation_id,item_ordinal,part_ordinal), CHECK(" },
        // @same and @distinct render parenthesized, so any operand context reads them alike.
        .{ .object = "model_operation", .today = "CHECK((resolution_code IS 'interrupted' AND", .rendered = "CHECK(((resolution_code IS 'interrupted') AND" },
        .{ .object = "model_tool_call", .today = "AND action_kind IS 1)", .rendered = "AND (action_kind IS 1))" },
        .{ .object = "action_operation", .today = "CHECK(resolution_code IS NOT 'denied' OR", .rendered = "CHECK((resolution_code IS NOT 'denied') OR" },
    };
    var today = try testingSchemaRows(store_schema.legacy_ddl);
    defer today.deinit(std.testing.allocator);
    var rendered = try testingSchemaRows(store_schema.ddl(.sqlite));
    defer rendered.deinit(std.testing.allocator);
    for (differences) |difference| {
        const marker = try std.fmt.allocPrint(std.testing.allocator, "\ntable|{s}|", .{difference.object});
        defer std.testing.allocator.free(marker);
        const row = std.mem.indexOf(u8, today.items, marker).?;
        const row_end = row + 1 + std.mem.indexOfScalar(u8, today.items[row + 1 ..], '\n').?;
        const at = row + std.mem.indexOf(u8, today.items[row..row_end], difference.today).?;
        try std.testing.expect(std.mem.indexOf(u8, today.items[at + 1 .. row_end], difference.today) == null);
        try today.replaceRange(std.testing.allocator, at, difference.today.len, difference.rendered);
    }
    try std.testing.expectEqualStrings(today.items, rendered.items);
}

/// One line per sqlite_schema row of a database holding `ddl`, sorted, with
/// `--` comments dropped and whitespace runs collapsed to one space.
fn testingSchemaRows(ddl: [:0]const u8) !std.ArrayList(u8) {
    var raw: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &raw));
    defer _ = c.sqlite3_close(raw);
    try sqlite.exec(raw.?, ddl);
    const statement = try sqlite.prepare(raw.?, "SELECT type,name,tbl_name,coalesce(sql,'') FROM sqlite_schema ORDER BY type,name");
    defer _ = c.sqlite3_finalize(statement);
    var rows: std.ArrayList(u8) = .empty;
    errdefer rows.deinit(std.testing.allocator);
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) {
        for (0..4) |column| {
            const text: [*]const u8 = c.sqlite3_column_text(statement, @intCast(column));
            const bytes = text[0..@intCast(c.sqlite3_column_bytes(statement, @intCast(column)))];
            var quoted = false;
            var space = false;
            var index: usize = 0;
            while (index < bytes.len) : (index += 1) {
                const byte = bytes[index];
                if (!quoted and byte == '-' and index + 1 < bytes.len and bytes[index + 1] == '-') {
                    while (index + 1 < bytes.len and bytes[index + 1] != '\n') index += 1;
                    space = true;
                } else if (!quoted and std.ascii.isWhitespace(byte)) {
                    space = true;
                } else {
                    if (byte == '\'') quoted = !quoted;
                    if (space) try rows.append(std.testing.allocator, ' ');
                    space = false;
                    try rows.append(std.testing.allocator, byte);
                }
            }
            try rows.append(std.testing.allocator, if (column == 3) '\n' else '|');
        }
    }
    return rows;
}

test "fresh Store uses current schema and rejects the prior version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(storage.database, "PRAGMA user_version"));
    {
        const removed_index = try sqlite.prepare(
            storage.database,
            "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='model_operation_runnable'",
        );
        defer _ = c.sqlite3_finalize(removed_index);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(removed_index));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(removed_index, 0));
    }
    {
        // Uncertainty is derived from resolution and retry facts, not stored.
        const stored_uncertainty = try sqlite.prepare(
            storage.database,
            "SELECT (SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='uncertain')+" ++
                "(SELECT count(*) FROM pragma_table_info('model_operation') WHERE name='uncertain')",
        );
        defer _ = c.sqlite3_finalize(stored_uncertainty);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_uncertainty));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_uncertainty, 0));
    }
    {
        // An Action stores only its authorization; its denial is its Resolution.
        const stored_permission = try sqlite.prepare(
            storage.database,
            "SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='permission_state'",
        );
        defer _ = c.sqlite3_finalize(stored_permission);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stored_permission));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stored_permission, 0));
    }
    try storage.close();
    // Model the prior format's rollback-journal header; rejection must
    // happen before the WAL switch, leaving that Store unmodified.
    {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        defer _ = c.sqlite3_close(raw);
        try sqlite.exec(raw.?, "PRAGMA journal_mode=DELETE");
        try sqlite.exec(raw.?, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version - 1}));
    }
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(u8, 1), before[18]);

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreVersion,
        refused.open(std.testing.io, database, root),
    );
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    var wal_buffer: [platform.max_database_path_bytes + "-wal".len]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{database}), .{}));
}

test "existing Store rejects noncanonical durable authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try sqlite.exec(storage.database, "CREATE TABLE tool_result_authority(call_id INTEGER PRIMARY KEY, result_content_id INTEGER NOT NULL)");
    try storage.close();

    var refused: Store = undefined;

    try std.testing.expectError(
        error.WrongStoreSchema,
        refused.open(std.testing.io, database, root),
    );
}

test "existing Store rejects a different canonical identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage: Store = undefined;
    try storage.open(std.testing.io, database, root);
    try storage.close();
    var refused: Store = undefined;
    try std.testing.expectError(
        error.WrongStoreIdentity,
        refused.open(std.testing.io, database, "/different/canonical/store"),
    );
}

test "canonical observation failure fences later admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("create", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&command, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(storage.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSessionForTesting(created_session_0.slice()));

    var later = try completeConfiguration("later", "", workspace, "model-a");
    try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("later"));
}

test "external content import follows sealed descriptor custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "external content identity is verified before canonical commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "content verification failure rolls back new imports and deduplicated inputs" {
    const Case = enum { digest, short, long, empty_digest, read_failure };
    inline for (.{ false, true }) |deduplicated| {
        inline for (std.meta.tags(Case)) |case| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
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
            const content_count = try queryU64(storage.database, "SELECT count(*) FROM content");
            const command_count = try queryU64(storage.database, "SELECT count(*) FROM core_command");
            const revision_count = try queryU64(storage.database, "SELECT count(*) FROM session_revision");

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
            try std.testing.expectEqual(content_count, try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(command_count, try queryU64(storage.database, "SELECT count(*) FROM core_command"));
            try std.testing.expectEqual(revision_count, try queryU64(storage.database, "SELECT count(*) FROM session_revision"));
            try std.testing.expectEqual(@as(u64, if (deduplicated) 1 else 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        }
    }
}

test "content import reads once and rolls back sources that change during reading" {
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
        try testingStore(&storage, &tmp, std.testing.io);
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
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM core_command"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        }
    }
}

test "multiwindow content import and deduplication preserve all bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
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

test "large raw content opens without materializing its payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "public conversation owner fixes end, filters settings and bounds content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(usize, 0), (try storage.publicConversationPageForTesting(request)).count);

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
    try std.testing.expectEqual(@as(usize, 0), (try storage.publicConversationPageForTesting(request)).count);
    var instruction: protocol.ConfigureCommand = .{};
    try instruction.key.set("public-instruction-before-selection");
    try instruction.session.set(created_session_0.slice());
    instruction.configuration.instructions = try testingContent(&tmp, "public-instruction-before", 's', 7);
    defer instruction.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instruction, .{}) == .accepted);
    const active = (try storage.admitNextModelAttempt(.{})).?;
    const first = try storage.publicConversationPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 16), first.count);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 40), first.items[0].position);
    try std.testing.expectEqual(@as(u64, 25), first.items[15].position);
    for (first.items[0..first.count]) |item| try std.testing.expect(item.kind == .user);
    try std.testing.expectEqual(@as(u64, 5), first.items[0].content.length);
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPageForTesting(.{
        .session = request.session,
        .end = first.end,
        .before_position = first.items[15].position,
        .before_ordinal = 1,
    }));
    try std.testing.expect(!storage.isFenced());
    var unicode_reader: ContentReader = undefined;
    unicode_reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = 40 }));
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
    const fixed_first = try storage.publicConversationPageForTesting(.{ .session = request.session, .end = first.end });
    try std.testing.expectEqual(first.end, fixed_first.end);
    try std.testing.expectEqual(first.count, fixed_first.count);
    for (first.items[0..first.count], fixed_first.items[0..fixed_first.count]) |expected, actual| {
        try std.testing.expectEqual(expected.position, actual.position);
        try std.testing.expectEqual(expected.ordinal, actual.ordinal);
    }
    request.end = first.end;
    request.before_position = first.items[15].position;
    const older = try storage.publicConversationPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 4), older.count);
    try std.testing.expect(!older.more);
    try std.testing.expectEqual(@as(u64, 24), older.items[0].position);
    try std.testing.expectEqual(@as(u64, 21), older.items[3].position);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), older.items[3].content.length);
    const fresh = try storage.publicConversationPageForTesting(.{ .session = request.session });
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
    read.position = 41; // the applied instruction is not public content
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&read));
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = .{}, .position = 1 }));
    try std.testing.expectError(error.RangeOutOfBounds, storage.openPublicConversationContent(&.{ .session = request.session, .position = 21, .start = 1024 * 1024 + 1 }));
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPageForTesting(.{ .session = request.session, .end = first.end + 100, .before_position = 1 }));
    try std.testing.expect(!storage.isFenced());
}

test "public content SQL failure fences Store instead of reporting absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "public-read-config");
    try submitTestMessage(&storage, &tmp, "public-read-text", "public-read-key", session.slice(), "text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request: protocol.ConversationContent = .{ .position = 1 };
    try request.session.set(session.slice());
    const Interrupt = struct {
        fn progress(_: ?*anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    c.sqlite3_progress_handler(storage.database, 1, Interrupt.progress, null);
    defer c.sqlite3_progress_handler(storage.database, 0, null, null);
    // The shared provenance query is interrupted during preparation, before
    // identity lookup can step. Either phase must retain the public fence.
    try std.testing.expectError(error.StatementPrepareFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

test "public content SQLite step failure fences after successful preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "step-config");
    try submitTestMessage(&storage, &tmp, "step-input", "step-key", session.slice(), "step text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationContent{ .position = 1 };
    try request.session.set(session.slice());
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{ .session = request.session, .position = 999 }));
    try std.testing.expect(!storage.isFenced());
    const Interrupt = struct {
        database: *c.sqlite3,
        interrupted_step: bool = false,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var statement = c.sqlite3_next_stmt(self.database, null);
            while (statement != null) : (statement = c.sqlite3_next_stmt(self.database, statement)) {
                // Preparation may also invoke progress. Interrupt only a
                // statement that has actually entered sqlite3_step.
                if (c.sqlite3_stmt_busy(statement) != 0) {
                    self.interrupted_step = true;
                    return 1;
                }
            }
            return 0;
        }
    };
    var interrupt = Interrupt{ .database = storage.database };
    c.sqlite3_progress_handler(storage.database, 1, Interrupt.progress, &interrupt);
    defer c.sqlite3_progress_handler(storage.database, 0, null, null);
    try std.testing.expectError(error.ConversationReadFailed, storage.openPublicConversationContent(&request));
    try std.testing.expect(interrupt.interrupted_step);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(&request));
}

const TestingPublicReadRoute = enum { page, content, cursor };

fn testingOrdinaryPublicCorruption(route: TestingPublicReadRoute, foreign_turn: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "ordinary-config");
    try submitTestMessage(&storage, &tmp, "ordinary-input", "ordinary-key", session.slice(), "public input");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationPage{};
    request.session = session;
    const valid = try storage.publicConversationPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 1), valid.count);
    try std.testing.expect(valid.items[0].kind == .user);
    if (foreign_turn) {
        const foreign_session = try configureTestSession(&storage, "foreign-config");
        try submitTestMessage(&storage, &tmp, "foreign-input", "foreign-key", foreign_session.slice(), "other input");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        const corrupt = try sqlite.prepare(storage.database, "UPDATE conversation_entry SET turn_id=(SELECT turn_id FROM turn WHERE session_ref=?1) WHERE session_ref=?2 AND entry_kind=1");
        defer _ = c.sqlite3_finalize(corrupt);
        try sqlite.bindText(corrupt, 1, foreign_session.slice());
        try sqlite.bindText(corrupt, 2, session.slice());
        try sqlite.expectDone(corrupt);
    } else {
        try execSessionSql(storage.database, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1)", session.slice());
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
    request.end = valid.end;
    if (route == .cursor) request.before_position = valid.items[0].position;
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = valid.items[0].position })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (storage.publicConversationPageForTesting(request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.publicConversationPageForTesting(request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
}

test "public ordinary private bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, false);
    try testingOrdinaryPublicCorruption(.cursor, false);
}

test "public ordinary private page fences" {
    try testingOrdinaryPublicCorruption(.page, false);
}

test "public foreign Turn bytes and cursor fence" {
    try testingOrdinaryPublicCorruption(.content, true);
    try testingOrdinaryPublicCorruption(.cursor, true);
}

test "public foreign Turn page fences" {
    try testingOrdinaryPublicCorruption(.page, true);
}

fn testingToolPublicCorruption(route: TestingPublicReadRoute, damage: enum { private, missing, sibling_ordinal, sibling_call_id, sibling_arguments }, target_sibling: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "tool-config");
    try submitTestMessage(&storage, &tmp, "tool-input", "tool-key", session.slice(), "run tool");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "sibling", .name = "other", .encoded_call_id = "sibling-call", .decoded_call_id = "sibling-call", .encoded_arguments = "[]", .decoded_arguments = "[]" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "tool-output", &calls);
    // Damaging the first rejection must leave the requested sibling healthy;
    // identical rejection bytes would deduplicate into one content identity.
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(DISTINCT rejection_content_id) FROM model_tool_call"));
    var request = protocol.ConversationPage{};
    try request.session.set(session.slice());
    const valid = try storage.publicConversationPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 3), valid.count);
    const item = valid.items[if (target_sibling) 0 else 1];
    try std.testing.expect(item.kind == .tool_result and item.ordinal == (if (target_sibling) @as(u64, 2) else 1));
    {
        var reader: ContentReader = undefined;
        reader.open(try storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal }));
        defer reader.close();
        var bytes: [64]u8 = undefined;
        const count = try reader.read(0, &bytes);
        try std.testing.expectEqualStrings(if (target_sibling) "Unknown tool: other." else "Unknown tool: unknown.", bytes[0..count]);
    }
    // Keep counts, acceptance positions and results intact for sibling damage:
    // reading the healthy highest ordinal must validate the entire group.
    switch (damage) {
        .sibling_ordinal => try sqlite.exec(storage.database, "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0"),
        .sibling_call_id => try sqlite.exec(storage.database, "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0"),
        .sibling_arguments => try sqlite.exec(storage.database, "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0"),
        .private => try sqlite.exec(storage.database, "UPDATE content SET private=1 WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)"),
        .missing => {
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.database, "DELETE FROM content WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)");
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
        },
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
    request.end = item.position;
    if (route == .cursor) {
        request.before_position = item.position;
        request.before_ordinal = item.ordinal;
    }
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(&.{ .session = request.session, .position = item.position, .ordinal = item.ordinal })) |location| blk: {
            var reader: ContentReader = undefined;
            reader.open(location);
            reader.close();
            break :blk {};
        } else |err| err
    else if (storage.publicConversationPageForTesting(request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.publicConversationPageForTesting(request));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
}

test "public private tool bytes fence" {
    try testingToolPublicCorruption(.content, .private, false);
}

test "public private tool page fences" {
    try testingToolPublicCorruption(.page, .private, false);
}

test "public private tool cursor fences" {
    try testingToolPublicCorruption(.cursor, .private, false);
}

test "public completed tool group with missing exposed content fences" {
    try testingToolPublicCorruption(.page, .missing, false);
    try testingToolPublicCorruption(.content, .missing, false);
    try testingToolPublicCorruption(.cursor, .missing, false);
}

test "public completed tool group with corrupt sibling provenance fences" {
    for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
        try testingToolPublicCorruption(route, .sibling_ordinal, true);
        try testingToolPublicCorruption(route, .sibling_call_id, true);
        try testingToolPublicCorruption(route, .sibling_arguments, true);
        try testingToolPublicCorruption(route, .private, true);
        try testingToolPublicCorruption(route, .missing, true);
    }
}

test "public completed Action sibling corruption fences first Conversation read" {
    const faults = [_][:0]const u8{
        "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0",
        "UPDATE model_tool_call SET call_id_content_id=(SELECT name_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET private=1 WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
        "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "two tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "output");
            for ([_][]const u8{ "allow-first", "allow-second" }) |key| {
                const action_id = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation WHERE resolution_code IS NULL");
                var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
                try allow.key.set(key);
                try allow.session.set(session.slice());
                try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
                const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
                _ = try storage.settleActionAttempt(action_binding, .succeeded, key, .{});
            }
            // Obtain only the immutable identity, not a traversal on another
            // public route that could accidentally supply validation authority.
            const position = try queryU64(storage.database, "SELECT max(acceptance_position) FROM action_operation");
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
            var request: protocol.ConversationPage = .{ .end = position };
            try request.session.set(session.slice());
            if (route == .cursor) {
                request.before_position = position;
                request.before_ordinal = 2;
            }
            const result: anyerror!void = if (route == .content)
                if (storage.openPublicConversationContent(&.{ .session = request.session, .position = position, .ordinal = 2 })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.publicConversationPageForTesting(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.publicConversationPageForTesting(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "private-only model output never becomes public conversation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const page = try storage.publicConversationPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expect(page.items[0].kind == .user);
    try std.testing.expect(page.end > page.items[0].position);
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(&.{
        .session = request.session,
        .position = page.end,
    }));
    try std.testing.expect(!storage.isFenced());
}

test "public tool-result cursor crosses a completed group boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const newest = try storage.publicConversationPageForTesting(cursor);
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
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPageForTesting(cursor));
    try std.testing.expect(!storage.isFenced());
    cursor.before_ordinal = newest.items[15].ordinal;
    const older = try storage.publicConversationPageForTesting(cursor);
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

const TestingAnswerPart = struct { encoded: []const u8, decoded: []const u8 };

pub fn testingPublicProjection(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    parts: []const TestingAnswerPart,
) !protocol.ConversationContent {
    const session = try configureTestSession(storage, "projection-config");
    try answerTestTurn(storage, tmp, session.slice(), "projection", parts);
    const page = try storage.publicConversationPageForTesting(.{ .session = session });
    try std.testing.expect(page.items[0].kind == .assistant);
    return .{ .session = session, .position = page.items[0].position };
}

/// One Turn: a message named by `name`, its admission and an answer of `parts`.
fn answerTestTurn(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session: []const u8,
    comptime name: []const u8,
    parts: []const TestingAnswerPart,
) !void {
    try submitTestMessage(storage, tmp, name ++ "-input", name ++ "-key", session, "input");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A real message item whose output_text blocks hold the parts.
    var capacity: usize = 128;
    for (parts) |part| capacity += part.encoded.len + 32;
    const source_buffer = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(source_buffer);
    var writer = std.Io.Writer.fixed(source_buffer);
    var digest = protocol.contentHasher();
    var decoded_length: u64 = 0;
    try writer.writeAll("{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[");
    for (parts, 0..) |part, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"type\":\"output_text\",\"text\":\"{s}\"}}", .{part.encoded});
        digest.update(part.decoded);
        decoded_length += part.decoded.len;
    }
    try writer.writeAll("]}");
    const bytes = writer.buffered();
    const source = try tmp.dir.createFile(std.testing.io, name ++ "-source", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root_buffer[0..root_length], name ++ "-metadata", .{ .used = &metadata_used, .limit = 1 << 20 }, false, &retained);
    defer metadata.deinit();
    _ = try output_decode.recordItemForTesting(&metadata, source, 0, bytes.len, 0, .assistant_response);
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .call_count = 0,
        .answer_item_ordinal = 0,
        .answer_length = decoded_length,
        .answer_digest = digest.finalResult(),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
}

test "replay fences part damage that keeps every digest" {
    for ([_][:0]const u8{
        "DELETE FROM model_output_part WHERE part_ordinal=1",
        "UPDATE model_output_item SET part_count=part_count+1 WHERE item_kind=2",
        "UPDATE model_output_part SET part_array=2,part_kind=3,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0",
        // The text parts must cover the message text in order, exactly.
        "UPDATE model_output_part SET text_length=text_length+1 WHERE part_ordinal=0",
        "UPDATE model_output_part SET text_length=text_length-1 WHERE part_ordinal=1",
        // The text keeps its digest while its bytes change: the parts'
        // reads check it across both ranges.
        "UPDATE content SET payload=CAST('onetwx' AS BLOB) WHERE payload=CAST('onetwo' AS BLOB)",
    }) |fault| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "part-damage-config");
        const answer = [_]TestingAnswerPart{ .{ .encoded = "one", .decoded = "one" }, .{ .encoded = "two", .decoded = "two" } };
        try answerTestTurn(&storage, &tmp, session.slice(), "part-damage", &answer);
        try submitTestMessage(&storage, &tmp, "part-damage-next", "part-damage-next", session.slice(), "next");
        const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try sqlite.exec(storage.database, fault);
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(next, &view);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        var bytes: [512]u8 = undefined;
        while (try cursor.next(&view)) |entry| {
            if (entry.kind != .provider_output) continue;
            try std.testing.expectError(error.CorruptStore, renderTestingEntry(&view, entry, &bytes));
            break;
        } else return error.MissingCorruptionFailure;
        try std.testing.expect(storage.isFenced());
    }
}

test "a message's text is stored once and its parts replay as lengths of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "text-once-config");
    const answer = [_]TestingAnswerPart{ .{ .encoded = "one ", .decoded = "one " }, .{ .encoded = "", .decoded = "" }, .{ .encoded = "tw\\u00f6", .decoded = "tw\u{f6}" } };
    try answerTestTurn(&storage, &tmp, session.slice(), "text-once", &answer);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content WHERE payload=CAST('one tw\u{f6}' AS BLOB) AND private=0"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM content WHERE payload IN (CAST('one ' AS BLOB),CAST('tw\u{f6}' AS BLOB))"));
    try std.testing.expectEqual(@as(u64, 3), try queryU64(storage.database, "SELECT count(*) FROM model_output_part WHERE text_content_id IS NULL"));
    try std.testing.expectEqual(@as(u64, 4 + 0 + 4), try queryU64(storage.database, "SELECT sum(text_length) FROM model_output_part"));
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT content_id FROM conversation_entry WHERE entry_kind=3"), try queryU64(storage.database, "SELECT message_content_id FROM model_output_item WHERE item_kind=2"));
    // Each part kind holds exactly its text shape, and a message names its text.
    for ([_]struct { ConstraintProbe, [:0]const u8 }{
        .{ .check_violation, "UPDATE model_output_part SET text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET text_length=-1 WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=0 WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=0,text_length=NULL WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL WHERE part_ordinal=0" },
        .{ .accepted, "UPDATE model_output_part SET part_kind=3,part_array=2,text_length=NULL,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_part SET part_kind=4,text_content_id=extras_content_id WHERE part_ordinal=0" },
        .{ .check_violation, "UPDATE model_output_item SET message_content_id=NULL WHERE item_kind=2" },
        .{ .check_violation, "UPDATE model_output_item SET item_kind=1,phase=0 WHERE item_kind=2" },
    }) |case| try std.testing.expectEqual(case[0], try probeConstraint(storage.database, case[1]));
    try submitTestMessage(&storage, &tmp, "text-once-next", "text-once-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    var bytes: [512]u8 = undefined;
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        try std.testing.expectEqualStrings("message{\"id\":\"m\"}|content.output_text=one |content.output_text=|content.output_text=tw\u{f6}", try renderTestingEntry(&view, entry, &bytes));
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}

test "a large message's parts read only their own ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "large-parts-config");
    // Many small parts before one large one: each small part's reader must
    // not read ahead into the rest of the text.
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024 + 4096);
    defer std.testing.allocator.free(large);
    @memset(large, 'a');
    var answer: [65]TestingAnswerPart = undefined;
    for (answer[0..64]) |*part| part.* = .{ .encoded = "x", .decoded = "x" };
    answer[64] = .{ .encoded = large, .decoded = large };
    try answerTestTurn(&storage, &tmp, session.slice(), "large-parts", &answer);
    try submitTestMessage(&storage, &tmp, "large-parts-next", "large-parts-next", session.slice(), "next");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(next, &view);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    while (try cursor.next(&view)) |entry| {
        if (entry.kind != .provider_output) continue;
        _ = try view.openOutput(entry.position);
        const before = storage.testing_content_work.blob.load(.monotonic);
        var window: [4096]u8 = undefined;
        var text_bytes: u64 = 0;
        while (try view.nextOutputPart()) |part| {
            const text = part.text orelse continue;
            var reader: HistoricalReader = undefined;
            try view.openContent(text, &reader);
            defer reader.close();
            var offset: u64 = 0;
            while (true) {
                const count = try reader.read(offset, &window);
                if (count == 0) break;
                offset += count;
            }
            text_bytes += offset;
        }
        try std.testing.expectEqual(@as(u64, 64 + large.len), text_bytes);
        try std.testing.expectEqual(text_bytes, storage.testing_content_work.blob.load(.monotonic) - before);
        break;
    } else return error.MissingMessage;
    try std.testing.expect(!storage.isFenced());
}

test "a warm Turn prepares no statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "warm-config");
    const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
    try answerTestTurn(&storage, &tmp, session.slice(), "cold", &answer);
    try answerTestTurn(&storage, &tmp, session.slice(), "warming", &answer);
    const Steps = struct {
        cache: *const StatementCache,
        uncached: usize = 0,

        fn traced(mask: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            std.debug.assert(mask == c.SQLITE_TRACE_STMT);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            for (self.cache.slots) |slot| {
                if (slot.statement == @as(?*c.sqlite3_stmt, @ptrCast(statement))) return 0;
            }
            self.uncached += 1;
            return 0;
        }
    };
    var steps = Steps{ .cache = &storage.statements };
    const prepared = storage.statements.count;
    _ = c.sqlite3_trace_v2(storage.database, c.SQLITE_TRACE_STMT, Steps.traced, &steps);
    defer _ = c.sqlite3_trace_v2(storage.database, 0, null, null);
    try answerTestTurn(&storage, &tmp, session.slice(), "warm", &answer);
    try std.testing.expectEqual(@as(usize, 0), steps.uncached);
    try std.testing.expectEqual(prepared, storage.statements.count);
}

test "public assistant message provenance binds the exact accepted item" {
    const faults = [_][:0]const u8{
        "DELETE FROM conversation_entry WHERE entry_kind=3",
        "UPDATE conversation_entry SET source_item_ordinal=source_item_ordinal+1 WHERE entry_kind=3",
        "UPDATE conversation_entry SET content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE entry_kind=3",
        "UPDATE model_output_item SET message_content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE item_kind=2",
        "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1 WHERE item_kind=2",
        "UPDATE content SET private=1 WHERE content_id=(SELECT message_content_id FROM model_output_item WHERE item_kind=2)",
    };
    for (faults) |fault| {
        for ([_]enum { page, bytes, activity, activity_bytes, full }{ .page, .bytes, .activity, .activity_bytes, .full }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "visible", .decoded = "visible" }});
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
            try storage.close();
            try testingStore(&storage, &tmp, std.testing.io);
            const result: anyerror!void = switch (route) {
                .page => if (storage.publicConversationPageForTesting(.{ .session = request.session })) |_| {} else |err| err,
                .bytes => if (storage.openPublicConversationContent(&request)) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .activity => if (storage.activityPageForTesting(.{ .session = request.session })) |_| {} else |err| err,
                .activity_bytes => if (storage.openActivityContent(&.{ .session = request.session, .position = request.position })) |location| blk: {
                    var owned: ContentReader = undefined;
                    owned.open(location);
                    owned.close();
                    break :blk {};
                } else |err| err,
                .full => if (testingSessionReportWithProfile(&storage, &tmp, request.session.slice(), 1024 * 1024, .full)) |report| blk: {
                    std.testing.allocator.free(report);
                    break :blk {};
                } else |err| err,
            };
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "missing assistant certificates respect page windows and fixed ends" {
    for ([_]bool{ false, true }) |activity| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const missing = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "answer", .decoded = "answer" }});
        for (0..20) |index| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "later-{d}", .{index});
            try submitTestMessage(&storage, &tmp, key, key, missing.session.slice(), "later user input");
        }
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try sqlite.exec(storage.database, "DELETE FROM conversation_entry WHERE entry_kind=3");
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        try storage.close();
        try testingStore(&storage, &tmp, std.testing.io);
        // A historical window ending before the damage remains readable.
        _ = try storage.publicConversationPageForTesting(.{ .session = missing.session, .end = missing.position - 1 });
        _ = try storage.activityPageForTesting(.{ .session = missing.session, .end = missing.position - 1 });
        if (activity) {
            const latest = try storage.activityPageForTesting(.{ .session = missing.session, .direction = .backward });
            try std.testing.expect(latest.more);
            var cursor = latest.items[latest.count - 1];
            while (true) {
                const older = storage.activityPageForTesting(.{
                    .session = missing.session,
                    .end = latest.end,
                    .direction = .backward,
                    .position = cursor.position,
                    .ordinal = cursor.ordinal,
                }) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                };
                try std.testing.expect(older.more);
                try std.testing.expect(older.items[older.count - 1].position < cursor.position);
                cursor = older.items[older.count - 1];
            }
        } else {
            const latest = try storage.publicConversationPageForTesting(.{ .session = missing.session });
            try std.testing.expectEqual(@as(usize, 16), latest.count);
            try std.testing.expect(latest.more);
            try std.testing.expectError(error.CorruptStore, storage.publicConversationPageForTesting(.{
                .session = missing.session,
                .end = latest.end,
                .before_position = latest.items[latest.count - 1].position,
                .before_ordinal = latest.items[latest.count - 1].ordinal,
            }));
        }
        try std.testing.expect(storage.isFenced());
    }
}

test "definite rejections retain decisions without retaining payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("initial", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&initial, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try execSessionSql(storage.database, "UPDATE session SET revision=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());

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

    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        storage.database,
        "SELECT count(*) FROM core_command WHERE accepted=0 AND (primary_content_id IS NOT NULL OR secondary_content_id IS NOT NULL)",
    ));

    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
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
    const created_session_0_reply = storage.configure(&configuration, .{});
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

    var instructions_update: protocol.ConfigureCommand = .{};
    try instructions_update.key.set("instructions-before-selection");
    try instructions_update.session.set(created_session_0.slice());
    instructions_update.configuration.instructions = try testingContent(&tmp, "instructions-before", 'b', 1);
    defer instructions_update.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instructions_update, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("dispatch-1"));
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try std.testing.expect(
        (try storage.observeCommand("dispatch-1")).message.?.queue.?.state == .queued,
    );

    // Failed admission publishes neither projection nor instruction inclusion.
    try std.testing.expectEqual(@as(i64, 0), try sqlite.pragmaInt(storage.database, "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(i64, 3), try sqlite.pragmaInt(storage.database, "SELECT next_position FROM session"));

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const second_observation = (try storage.observeCommand("dispatch-2")).message.?.queue.?;
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try storage.observeCommand("dispatch-1")).message.?.progress.?.status);
    try std.testing.expectEqual(protocol.MessageProgressStatus.in_flight, (try storage.observeCommand("dispatch-2")).message.?.progress.?.status);
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
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = storage.configure(&update, .{});
    try std.testing.expect(active_update == .rejected);
    try std.testing.expectEqual(
        protocol.ConfigurationRejection.model_is_immutable,
        active_update.rejected.code,
    );
    try expectBindingPreserved(&storage, created_session_0.slice(), "during-work");

    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer if (view.active) view.close();
    var settings: HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(protocol.Provider.codex, settings.provider);
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    try std.testing.expectEqual(@as(u8, 1), settings.tools_mask);
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
    try storage.openHistoricalView(binding, &foreign_view);
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
    try expectActivityOutcome(&storage, created_session_0.slice(), binding, "provider_http_422");
    const failed = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const failure = switch (failed.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("provider_http_422", failure.code.slice());
    try std.testing.expect(
        (try storage.observeCommand("dispatch-3")).message.?.queue.?.state == .queued,
    );
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(created_session_0.slice())).pending_messages);

    try update.key.set("configure-after-failure");
    const failed_update = storage.configure(&update, .{});
    try std.testing.expect(failed_update == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.model_is_immutable, failed_update.rejected.code);
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-failure");

    var tools_update: protocol.ConfigureCommand = .{};
    try tools_update.key.set("tools-after-failure");
    try tools_update.session.set(created_session_0.slice());
    tools_update.configuration.tools.state = .value;
    tools_update.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&tools_update, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view: HistoricalView = undefined;
    try storage.openHistoricalView(later.permit.binding, &later_view);
    defer later_view.close();
    var later_settings: HistoricalSettings = undefined;
    try later_view.settings(&later_settings);
    try std.testing.expectEqual(protocol.Provider.codex, later_settings.provider);
    try std.testing.expectEqualStrings("model-a", later_settings.model.slice());
    try std.testing.expectEqual(@as(u8, 0), later_settings.tools_mask);
    var position: u64 = 0;
    for ([_]HistoricalEntryKind{ .user, .user, .instruction, .user }) |kind| {
        const entry = (try later_view.nextEntry(position)).?;
        try std.testing.expectEqual(kind, entry.kind);
        position = entry.position;
    }
    try std.testing.expect((try later_view.nextEntry(position)) == null);
}

test "continued accepted output keeps model immutable and public text readable" {
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
    const created_session_0_reply = storage.configure(&configuration, .{});
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
    const public_page = try storage.publicConversationPageForTesting(public_request);
    try std.testing.expectEqual(@as(usize, 2), public_page.count);
    try std.testing.expect(public_page.items[0].kind == .assistant);
    var public_reader: ContentReader = undefined;
    public_reader.open(try storage.openPublicConversationContent(&.{ .session = public_request.session, .position = public_page.items[0].position }));
    {
        // The answer is the message's public text row; its bag is private.
        const backing = try sqlite.prepare(storage.database, "SELECT text.private,bag.private FROM model_output_item item " ++
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
    const before_answer = try storage.publicConversationPageForTesting(.{
        .session = public_request.session,
        .end = public_page.end,
        .before_position = public_page.items[0].position,
    });
    try std.testing.expectEqual(@as(usize, 1), before_answer.count);
    try std.testing.expect(before_answer.items[0].kind == .user);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    {
        const resolution = try sqlite.prepare(
            storage.database,
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try sqlite.bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("answer", code.slice());
    }

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const rejected = storage.configure(&update, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(
        protocol.ConfigurationRejection.model_is_immutable,
        rejected.rejected.code,
    );

    const completion_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelSuccess(completion_binding, &output, .{});
    // The same output is an answer both before and after pending input is
    // consumed. Only the owning Turn's completion decision differs.
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code='answer'"));
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-output");
    const completed = (try storage.observeCommand("continued-first")).message.?.queue.?;
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

test "model rejection diagnostic is atomic Attempt-bound provenance not Turn output" {
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
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            session = try configureTestSession(&storage, "diagnostic-config");
            try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
            binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            original_content = try queryU64(storage.database, "SELECT count(*) FROM content");
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
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expectEqual(original_content, try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code IS NOT NULL OR resolution_content_id IS NOT NULL OR request_id IS NOT NULL"));
            try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
        }
        {
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
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
            try std.testing.expectEqual(@as(u64, if (request_id.len == 0) 0 else 1), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE request_id IS NOT NULL"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_output_item"));
            try expectActivityOutcome(&storage, session.slice(), binding, "unsupported_provider_output");
        }
    }
}

test "model rejection diagnostic cannot masquerade as assistant content" {
    const Route = enum { conversation, conversation_content, activity, activity_content };
    for ([_]Route{ .conversation, .conversation_content, .activity, .activity_content }) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
        const healthy = try storage.publicConversationPageForTesting(.{ .session = session });
        try std.testing.expectEqual(@as(usize, 1), healthy.count);
        try std.testing.expect(healthy.items[0].kind == .user);
        const position = try queryU64(storage.database, "SELECT next_position FROM session");
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(storage.database, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id,recorded_at) " ++
            "SELECT o.session_ref,2,s.next_position,3,o.turn_id,o.operation_id,0,o.resolution_content_id,1 " ++
            "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref");
        try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
        try sqlite.exec(storage.database, "UPDATE session SET next_position=next_position+1");
        const result: anyerror!void = switch (route) {
            .conversation => if (storage.publicConversationPageForTesting(.{ .session = session })) |_| {} else |err| err,
            .activity => if (storage.activityPageForTesting(.{ .session = session })) |_| {} else |err| err,
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

test "failed model settlement recovers uncertainty with a fresh consumed Attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    var created_session_0: protocol.Bounded(protocol.max_session_bytes) = undefined;

    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        const created_session_0_reply = storage.configure(&configuration, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        created_session_0 = created_session_0_reply.accepted.session;
        const message_file = try tmp.dir.createFile(std.testing.io, "failure-message", .{ .read = true });
        try message_file.writeStreamingAll(std.testing.io, "fail");
        try message_file.sync(std.testing.io);
        var message = try completeMessage("failure-message", created_session_0.slice(), message_file, "fail");
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectError(
            error.InjectedCommitFailure,
            storage.settleModelAttemptFailure(
                binding,
                .{ .uncorrelated = "request_preparation_failed" },
                .ordinary,
                .{ .before_commit = true },
            ),
        );
        try storage.close();
    }
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 1), observed_binding.attempt_ordinal);
        var replacement = (try admitRetryForTesting(&storage)).?;
        const replacement_binding = try replacement.permit.consume();
        try std.testing.expectEqual(@as(u64, 2), replacement_binding.attempt_ordinal);
        try std.testing.expectEqual(
            replacement_binding.operation_id,
            observed_binding.operation_id,
        );
        const recovered = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const recovered_binding = switch (recovered.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 2), recovered_binding.attempt_ordinal);

        {
            const force_exhausted = try sqlite.prepare(
                storage.database,
                "UPDATE model_operation SET attempt_ordinal=4 WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(force_exhausted);
            try sqlite.bindU64(force_exhausted, 1, replacement_binding.operation_id);
            try sqlite.expectDone(force_exhausted);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        }

        const Active = struct {
            fn contains(context: *const anyopaque, operation_id: u64) bool {
                const expected: *const u64 = @ptrCast(@alignCast(context));
                return operation_id == expected.*;
            }
        };
        const active_operation = replacement_binding.operation_id;
        try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(.{
            .context = &active_operation,
            .containsFn = Active.contains,
            .maximum_exclusions = 1,
        }));
        try std.testing.expect(
            try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()),
        );
        const exhausted = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const failure = switch (exhausted.state) {
            .failed => |value| value,
            else => return error.ExpectedFailedObservation,
        };
        try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
        try expectActivityOutcome(&storage, created_session_0.slice(), replacement_binding, "retry_exhausted");
    }
}

test "HTTP status failures keep the settling Attempt's provider correlation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "correlation-config");
    try submitTestMessage(&storage, &tmp, "correlation-input", "correlation-message", session.slice(), "retry");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const request_ids = [_][]const u8{ "attempt-1", "", "attempt-3", "attempt-\"4\"" };
    for (request_ids, 1..) |request_id, ordinal| {
        try std.testing.expectEqual(@as(u64, ordinal), binding.attempt_ordinal);
        var failure: ModelFailure = .{ .correlated = .{ .code = "provider_temporary_http_503", .request_id = .{}, .report = "" } };
        try failure.correlated.request_id.set(request_id);
        try storage.settleModelAttemptFailure(binding, failure, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
        var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
        var recorded: protocol.Bounded(256) = .{};
        {
            const statement = try sqlite.prepare(storage.database, "SELECT coalesce(resolution_code,''),coalesce(request_id,'') FROM model_operation WHERE operation_id=?1");
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindU64(statement, 1, binding.operation_id);
            try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
            try sqlite.readText(statement, 0, &resolution);
            try sqlite.readText(statement, 1, &recorded);
        }
        if (ordinal < request_ids.len) {
            // A scheduled retry has not settled the Operation; the next
            // Attempt's answer will.
            try std.testing.expectEqualStrings("", resolution.slice());
            try std.testing.expectEqualStrings("", recorded.slice());
            try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL");
            binding = (try admitRetryForTesting(&storage)).?.permit.binding;
        } else {
            try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
            try std.testing.expectEqualStrings(request_id, recorded.slice());
        }
    }

    // An ordinary HTTP failure retains the source bytes too, not a slice of
    // a copied union payload which expires before the SQLite step.
    try submitTestMessage(&storage, &tmp, "correlated-input", "correlated-message", session.slice(), "fail with correlation");
    const correlated = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var ordinary: ModelFailure = .{ .correlated = .{ .code = "provider_http_403", .request_id = .{}, .report = "" } };
    try ordinary.correlated.request_id.set("terminal-\"request\"-é");
    try storage.settleModelAttemptFailure(correlated, ordinary, .ordinary, .{});
    {
        const statement = try sqlite.prepare(storage.database, "SELECT request_id FROM model_operation WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try sqlite.bindU64(statement, 1, correlated.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        var recorded: protocol.Bounded(256) = .{};
        try sqlite.readText(statement, 0, &recorded);
        try std.testing.expectEqualStrings("terminal-\"request\"-é", recorded.slice());
    }

    // A provider answer without correlation records none.
    try submitTestMessage(&storage, &tmp, "uncorrelated-input", "uncorrelated-message", session.slice(), "fail");
    const terminal = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(terminal, .{ .correlated = .{ .code = "provider_http_401", .request_id = .{}, .report = "" } }, .ordinary, .{});
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE request_id IS NULL AND resolution_code='provider_http_401'"));
}

test "a failed Turn's activity outcome references the provider's report" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "report-config");
    const report = "cyber_policy: This request has been flagged.";
    for ([_][]const u8{ report, "" }, 0..) |words, index| {
        var key: [16]u8 = undefined;
        const message = try std.fmt.bufPrint(&key, "report-{d}", .{index});
        try submitTestMessage(&storage, &tmp, message, message, session.slice(), "work");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_cyber_policy", .request_id = .{}, .report = words } }, .ordinary, .{});
        try expectActivityOutcome(&storage, session.slice(), binding, "provider_cyber_policy");
        var request: protocol.ActivityPage = .{ .direction = .backward };
        try request.session.set(session.slice());
        const outcome = (try storage.activityPageForTesting(request)).items[0].value.outcome;
        if (words.len == 0) {
            // No words, no report: never an empty one.
            try std.testing.expect(outcome.content == null);
        } else {
            try std.testing.expectEqual(@as(u64, words.len), outcome.content.?.length);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(words), &outcome.content.?.digest);
        }
    }
}

test "retryable stream rejections retain only the settling Attempt diagnostic through reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const diagnostic = "{\"reason\":\"TemporaryProviderFailure\",\"stage\":\"event\",\"byte_offset\":\"6\",\"output_index\":null}";
    var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
    {
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
                try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_content_id IS NOT NULL OR request_id IS NOT NULL"));
                try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL");
                binding = (try admitRetryForTesting(&storage)).?.permit.binding;
            }
        }
    }
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
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

test "retry settlement adds actual entropy after the provider deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 40_500), try queryU64(storage.database, "SELECT retry_due_at_ms FROM model_operation"));
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
}

test "temporary model failures conserve allowance and exhaust after four Attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("retry-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const message_file = try tmp.dir.createFile(std.testing.io, "retry-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "retry me");
    try message_file.sync(std.testing.io);
    var message = try completeMessage("retry-message", created_session_0.slice(), message_file, "retry me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);

    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const policy = retry_policy.Input{
        .waits_ms = .{ 50, 1, 1 },
        // This valid integer cannot name a deadline at the settlement clock.
        .retry_after_ms = 9_223_372_036_854_775_000,
        // Future eligibility must not assume a commit returns within 50 ms.
        .retry_after_deadline_ms = std.math.maxInt(i64),
    };
    try storage.settleModelAttemptFailure(
        first,
        .{ .uncorrelated = "provider_temporary_http_429" },
        .{ .retryable = policy },
        .{},
    );
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    {
        const statement = try sqlite.prepare(
            storage.database,
            "SELECT resolution_code IS NULL AND retry_due_at_ms IS 0,retry_due_at_ms,last_failure_code,resolution_code " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try sqlite.bindU64(statement, 1, first.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 0));
        try std.testing.expectEqual(std.math.maxInt(i64), c.sqlite3_column_int64(statement, 1));
        var failure: protocol.Bounded(protocol.max_code_bytes) = .{};
        try sqlite.readText(statement, 2, &failure);
        try std.testing.expectEqualStrings("provider_temporary_http_429", failure.slice());
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    }

    // Make this fixture's operation eligible explicitly; admission still uses
    // the real Store transition and checks the allowance and stale binding.
    {
        const due = try sqlite.prepare(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(due);
        try sqlite.bindU64(due, 1, first.operation_id);
        try sqlite.expectDone(due);
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
    }
    const second = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, second.operation_id);
    try std.testing.expectEqual(@as(u64, 2), second.attempt_ordinal);
    try std.testing.expectError(
        error.StaleAttemptBinding,
        storage.settleModelAttemptFailure(first, .{ .uncorrelated = "late_old_failure" }, .ordinary, .{}),
    );
    try std.testing.expect(!storage.isFenced());

    try storage.settleModelAttemptFailure(
        second,
        .{ .uncorrelated = "provider_transport_failure" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const third = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 3), third.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        third,
        .{ .uncorrelated = "provider_temporary_http_503" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const fourth = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), fourth.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        fourth,
        .{ .uncorrelated = "provider_transport_failure" },
        .{ .retryable = .{ .waits_ms = policy.waits_ms } },
        .{},
    );

    const observation = (try storage.observeCommand("retry-message")).message.?.queue.?;
    const failure = switch (observation.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
    try expectActivityOutcome(&storage, created_session_0.slice(), fourth, "retry_exhausted");
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    const statement = try sqlite.prepare(
        storage.database,
        "SELECT attempt_ordinal,resolution_code IS NULL AND retry_due_at_ms IS 0,retry_due_at_ms,last_failure_code,resolution_code " ++
            "FROM model_operation WHERE operation_id=?1",
    );
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindU64(statement, 1, first.operation_id);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 1));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 2));
    var last_failure: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 3, &last_failure);
    try std.testing.expectEqualStrings("provider_transport_failure", last_failure.slice());
    var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(statement, 4, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try expectDenseSessionPositions(&storage, created_session_0.slice());
}

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
    var admitted_attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted_attempt.permit.consume();

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(storage.database, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
    var view: HistoricalView = undefined;
    try storage.openHistoricalView(binding, &view);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, testSettings(&view));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "request_preparation_failed" }, .ordinary, .{}),
    );
}

test "runnable selection finds age through pending index then groups one session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try sqlite.prepare(storage.database, "EXPLAIN QUERY PLAN " ++ runnable_selection_sql);
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

test "activity revalidation takes the same steps however long a Session's history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");

    var steps: [2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try sqlite.exec(storage.database, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM turn");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at) " ++
                "SELECT value,'h1st0r',printf('history-%d',value),1,3*value,value,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_position,outcome_at) " ++
                "SELECT value,'h1st0r',value,value,value,'cancelled',3*value+1,1 FROM sequence; " ++
                "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position,stopped_at) " ++
                "SELECT printf('stop-%d',value),'h1st0r',value,value,3*value+2,1 FROM sequence",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.database, insert);
        const guard = try sqlite.prepare(storage.database, activity_sequence_guard_sql);
        defer _ = c.sqlite3_finalize(guard);
        try sqlite.bindText(guard, 1, "h1st0r");
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(guard));
        cost.* = c.sqlite3_stmt_status(guard, c.SQLITE_STMTSTATUS_VM_STEP, 0);
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "runnable discovery measures eligible ineligible and history populations independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
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
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tools_mask,permission_mode," ++
                        "output_schema_content_id,revision,next_position,created_at) VALUES('st0ped','/','codex','openai-responses/1','model-a',1,0,0,NULL,1,1,1)",
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
                    "INSERT INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tools_mask,permission_mode," ++
                    "output_schema_content_id,revision,next_position,created_at) " ++
                    "SELECT printf('%06d',value),'/','codex','openai-responses/1','model-a',1,0,0,NULL,1,1,1 FROM sequence; " ++
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
            const first_admission = c.sqlite3_column_int64(statement, 1);
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
                const first_admission = c.sqlite3_column_int64(statement, 1);
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
        try QueryCost.reset(storage.database, 1, 0, history);
        const measured = try QueryCost.measureSelection(storage.database);
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        history_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(@max(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) -
        @min(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) <= 32);

    var ineligible_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |ineligible, index| {
        try QueryCost.reset(storage.database, 1, ineligible, 0);
        const measured = try QueryCost.measureSelection(storage.database);
        try std.testing.expectEqual(@as(i64, @intCast(ineligible + 1)), measured.first_admission);
        ineligible_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(ineligible_selection_costs[1] > ineligible_selection_costs[0]);
    try std.testing.expect(ineligible_selection_costs[2] > ineligible_selection_costs[1]);

    var eligible_selection_costs: [3]i32 = undefined;
    var eligible_drain_costs: [3]i64 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |eligible, index| {
        try QueryCost.reset(storage.database, eligible, 0, 0);
        const measured = try QueryCost.measureSelection(storage.database);
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        eligible_selection_costs[index] = measured.steps;
        try QueryCost.reset(storage.database, eligible, 0, 0);
        eligible_drain_costs[index] = try QueryCost.measureDrain(storage.database, eligible);
    }
    try std.testing.expect(@max(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) -
        @min(eligible_selection_costs[0], eligible_selection_costs[1], eligible_selection_costs[2]) <= 32);
    try std.testing.expect(eligible_drain_costs[1] <= eligible_drain_costs[0] * 12);
    try std.testing.expect(eligible_drain_costs[2] <= eligible_drain_costs[1] * 12);
}

test "content readers hold no decode window" {
    try std.testing.expect(@sizeOf(ContentReader) <= 512);
    try std.testing.expect(@sizeOf(HistoricalReader) <= 1024);
}

test "retry admission and exhausted recovery use their selection indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const queries = [_]struct { sql: [:0]const u8, index: []const u8, no_temporary_sort: bool }{
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id,attempt_ordinal,retry_due_at_ms " ++
                "FROM model_operation INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL " ++
                "AND attempt_ordinal<4 AND retry_due_at_ms<=99 ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_due",
            .no_temporary_sort = false,
        },
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id FROM model_operation " ++
                "INDEXED BY model_operation_retry_exhausted WHERE " ++ retry_exhausted_sql ++ " " ++
                "ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_exhausted",
            .no_temporary_sort = true,
        },
    };
    for (queries) |query| {
        const statement = try sqlite.prepare(storage.database, query.sql);
        defer _ = c.sqlite3_finalize(statement);
        var uses_index = false;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
                const length = c.sqlite3_column_bytes(statement, 3);
                if (length < 0) return error.InvalidQueryPlan;
                const detail = pointer[0..@intCast(length)];
                uses_index = uses_index or std.mem.indexOf(u8, detail, query.index) != null;
                if (query.no_temporary_sort) {
                    try std.testing.expect(std.mem.indexOf(u8, detail, "TEMP B-TREE") == null);
                }
            },
            c.SQLITE_DONE => break,
            else => return error.InvalidQueryPlan,
        };
        try std.testing.expect(uses_index);
    }
}

/// Gives each Session an Operation names a row, for a fixture that inserts
/// Operations with foreign keys off: a writer reads every Session it touches.
fn insertTestingSessionsForOperations(database: *c.sqlite3) !void {
    try sqlite.exec(
        database,
        "INSERT OR IGNORE INTO session(session_ref,workspace,provider,codec,model,instructions_content_id,tools_mask," ++
            "permission_mode,revision,next_position,created_at) " ++
            "SELECT DISTINCT session_ref,'/w','codex','openai-responses/1','m',1,0,0,1,1,1 FROM model_operation",
    );
}

test "retry due index excludes future population and preserves age ordering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    const QueryCost = struct {
        fn measure(database: *c.sqlite3, sql: [:0]const u8, snapshot_ms: i64) !i32 {
            const statement = try sqlite.prepare(database, sql);
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindI64(statement, 1, snapshot_ms);
            try sqlite.bindI64(statement, 2, 0);
            while (true) switch (c.sqlite3_step(statement)) {
                c.SQLITE_ROW => {},
                c.SQLITE_DONE => break,
                else => return error.RetrySelectionFailed,
            };
            return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }
    };

    var future_costs: [3]i32 = undefined;
    var age_control_costs: [3]i32 = undefined;
    try sqlite.exec(
        storage.database,
        "CREATE INDEX test_model_operation_retry_age ON model_operation(operation_id) " ++
            "WHERE resolution_code IS NULL AND attempt_ordinal<4",
    );
    const age_control_sql =
        "SELECT turn_id,operation_id,attempt_ordinal,retry_due_at_ms FROM model_operation " ++
        "INDEXED BY test_model_operation_retry_age WHERE resolution_code IS NULL AND attempt_ordinal<4 " ++
        "AND retry_due_at_ms<=?1 AND operation_id>?2 ORDER BY operation_id LIMIT 2";
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |future_count, index| {
        try sqlite.exec(storage.database, "DELETE FROM model_operation");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,9223372036854775807,0,1 FROM sequence; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) VALUES" ++
                "({1},{1},'0der00',1,1,1,1,99,0,1),({2},{2},'ear1er',1,1,1,1,1,0,1)",
            .{ future_count, future_count + 1, future_count + 2 },
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.database, insert);
        future_costs[index] = try QueryCost.measure(storage.database, retry_admission_select_sql, 99);
        age_control_costs[index] = try QueryCost.measure(storage.database, age_control_sql, 99);
    }
    const minimum_future_cost = @min(future_costs[0], future_costs[1], future_costs[2]);
    const maximum_future_cost = @max(future_costs[0], future_costs[1], future_costs[2]);
    try std.testing.expect(maximum_future_cost - minimum_future_cost <= 16);
    try std.testing.expect(age_control_costs[2] > age_control_costs[0] * 10);

    var due_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |due_count, index| {
        try sqlite.exec(storage.database, "DELETE FROM model_operation");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1 FROM sequence",
            .{due_count},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.database, insert);
        due_costs[index] = try QueryCost.measure(storage.database, retry_admission_select_sql, 99);
    }
    try std.testing.expect(due_costs[1] > due_costs[0]);
    try std.testing.expect(due_costs[2] > due_costs[1]);

    try sqlite.exec(storage.database, "DELETE FROM model_operation");
    try sqlite.exec(
        storage.database,
        "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) VALUES" ++
            "(1,1,'000001',1,1,1,1,99,0,1)," ++
            "(2,2,'000002',1,1,1,1,50,0,1)," ++
            "(3,3,'000003',1,1,1,1,1,0,1)",
    );
    try insertTestingSessionsForOperations(storage.database);
    const Active = struct {
        fn contains(_: *const anyopaque, operation_id: u64) bool {
            return operation_id == 1;
        }
    };
    const admitted = (try storage.tryAdmitNextModelRetry(.{
        .context = &empty_active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = 1,
    }, .{})).?;
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.operation_id);
}

const testing_401: ModelFailure = .{ .correlated = .{ .code = "provider_http_401", .request_id = .{}, .report = "" } };

fn settleTransientForTesting(storage: *Store, binding: AttemptBinding) !AttemptBinding {
    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_temporary_http_503" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
    try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL AND retry_due_at_ms!=0");
    return (try admitRetryForTesting(storage)).?.permit.binding;
}

test "a 401 forced refresh is claimed at most once per Operation across failures and restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "refresh-config");

    // Claimed once: the claim commits before any refresh, the Attempt stays
    // uncertain, and a second claim for the same Operation is refused.
    try submitTestMessage(&storage, &tmp, "refresh-a", "refresh-a", session.slice(), "a");
    const a1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try storage.claimModelAuthRefresh(a1));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND auth_refresh_claimed=1"));
    try std.testing.expect(!try storage.claimModelAuthRefresh(a1));
    // A completed refresh makes the one replacement immediately eligible,
    // without generic backoff, and records the 401.
    try storage.settleModelAttemptFailure(a1, testing_401, .refreshed, .{});
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL AND retry_due_at_ms!=0 AND last_failure_code='provider_http_401' AND retry_due_at_ms<=CAST(unixepoch('subsec')*1000 AS INTEGER)"));
    const a2 = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 2), a2.attempt_ordinal);
    // Counterexample A: a transient failure intervenes; the next 401 must
    // not claim again.
    const a3 = try settleTransientForTesting(&storage, a2);
    try std.testing.expect(!try storage.claimModelAuthRefresh(a3));
    try storage.settleModelAttemptFailure(a3, testing_401, .ordinary, .{});

    // Counterexample B: same saved shape at Attempt 3, but no earlier claim.
    try submitTestMessage(&storage, &tmp, "refresh-b", "refresh-b", session.slice(), "b");
    const b1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const b3 = try settleTransientForTesting(&storage, try settleTransientForTesting(&storage, b1));
    try std.testing.expectEqual(@as(u64, 3), b3.attempt_ordinal);
    try std.testing.expect(try storage.claimModelAuthRefresh(b3));
    try storage.settleModelAttemptFailure(b3, testing_401, .refreshed, .{});
    // The replacement consumes the ordinary allowance: Attempt 4 has none
    // left, so a 401 there cannot claim.
    const b4 = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), b4.attempt_ordinal);
    try std.testing.expect(!try storage.claimModelAuthRefresh(b4));
    try storage.settleModelAttemptFailure(b4, testing_401, .ordinary, .{});

    // A stale binding cannot claim, and a refreshed settlement requires the
    // claim.
    try submitTestMessage(&storage, &tmp, "refresh-c", "refresh-c", session.slice(), "c");
    const c1 = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var stale = c1;
    stale.attempt_ordinal = 2;
    try std.testing.expectError(error.StaleAttemptBinding, storage.claimModelAuthRefresh(stale));
    try std.testing.expectError(error.StaleAttemptBinding, storage.settleModelAttemptFailure(c1, testing_401, .refreshed, .{}));

    // Crash after the claim and before settlement: restart replaces the
    // uncertain Attempt under ordinary policy and the claim survives.
    try std.testing.expect(try storage.claimModelAuthRefresh(c1));
    try storage.close();
    storage_open = false;
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    const c2 = (try admitRetryForTesting(&reopened)).?.permit.binding;
    try std.testing.expectEqual(c1.operation_id, c2.operation_id);
    try std.testing.expectEqual(@as(u64, 2), c2.attempt_ordinal);
    try std.testing.expect(!try reopened.claimModelAuthRefresh(c2));
}

test "retry admission reads past a full page of active Operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    const insert = try std.testing.allocator.printSentinel(
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
            "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1 FROM sequence",
        .{retry_admission_page_rows + 1},
        0,
    );
    defer std.testing.allocator.free(insert);
    try sqlite.exec(storage.database, insert);
    try insertTestingSessionsForOperations(storage.database);
    const Active = struct {
        fn contains(_: *const anyopaque, operation_id: u64) bool {
            return operation_id <= retry_admission_page_rows;
        }
    };
    const active_filter = ActiveOperationFilter{
        .context = &empty_active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = retry_admission_page_rows,
    };
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, retry_admission_page_rows + 1), admitted.permit.binding.operation_id);
}

test "retry transitions preserve age and settle one exhausted outcome per call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    try sqlite.exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<201) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,retry_scheduled_at) " ++
            "SELECT value,value,printf('%06d',value),1,1,1,1," ++
            "CASE WHEN value<=100 THEN 9223372036854775807 ELSE 1 END,0,1 FROM sequence",
    );
    try insertTestingSessionsForOperations(storage.database);

    const Active = struct {
        const Context = struct {
            operation_ids: *const [100]u64,
            comparisons: *usize,
        };

        fn contains(context: *const anyopaque, operation_id: u64) bool {
            const active: *const Context = @ptrCast(@alignCast(context));
            for (active.operation_ids) |active_id| {
                active.comparisons.* += 1;
                if (operation_id == active_id) return true;
            }
            return false;
        }
    };
    var active_operations: [100]u64 = undefined;
    for (&active_operations, 0..) |*operation_id, index| {
        operation_id.* = 101 + @as(u64, @intCast(index));
    }
    var comparisons: usize = 0;
    const active_context = Active.Context{
        .operation_ids = &active_operations,
        .comparisons = &comparisons,
    };
    const active_filter = ActiveOperationFilter{
        .context = &active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_operations.len,
    };

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.tryAdmitNextModelRetry(active_filter, .{ .attempt_before_commit = true }),
    );
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(@as(usize, 5150), comparisons);
    comparisons = 0;
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, 201), admitted.permit.binding.operation_id);
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.attempt_ordinal);
    try std.testing.expectEqual(@as(usize, 5150), comparisons);

    try sqlite.exec(storage.database, "DELETE FROM model_operation");
    for (6000..6102) |value| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "exhausted-{d}", .{value});
        const session = try configureTestSession(&storage, key);
        const insert_turn = try sqlite.prepare(storage.database, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) VALUES(?1,?2,1,1,?1)");
        defer _ = c.sqlite3_finalize(insert_turn);
        try sqlite.bindU64(insert_turn, 1, value);
        try sqlite.bindText(insert_turn, 2, session.slice());
        try sqlite.expectDone(insert_turn);
        const insert_operation = try sqlite.prepare(storage.database, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,retry_due_at_ms,output_reservation,attempt_at) " ++
            "VALUES(?1,?1,?2,1,1,1,4,0,0,1)");
        defer _ = c.sqlite3_finalize(insert_operation);
        try sqlite.bindU64(insert_operation, 1, value);
        try sqlite.bindText(insert_operation, 2, session.slice());
        try sqlite.expectDone(insert_operation);
    }
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");

    var active_exhausted: [100]u64 = undefined;
    for (&active_exhausted, 0..) |*operation_id, index| operation_id.* = 6000 + @as(u64, @intCast(index));
    var exhausted_comparisons: usize = 0;
    const exhausted_context = Active.Context{
        .operation_ids = &active_exhausted,
        .comparisons = &exhausted_comparisons,
    };
    try std.testing.expect(try storage.recoverOneExhaustedModelAttempt(.{
        .context = &exhausted_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_exhausted.len,
    }));
    try std.testing.expectEqual(@as(usize, 5150), exhausted_comparisons);
    const outcomes = try sqlite.prepare(
        storage.database,
        "SELECT operation_id,resolution_code FROM model_operation WHERE operation_id IN (6100,6101) ORDER BY operation_id",
    );
    defer _ = c.sqlite3_finalize(outcomes);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6100), c.sqlite3_column_int64(outcomes, 0));
    var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(outcomes, 1, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6101), c.sqlite3_column_int64(outcomes, 0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(outcomes, 1));
}

test "public proposal structural corruption fences independently on every route" {
    const faults = [_][:0]const u8{
        "UPDATE content SET private=1,payload=zeroblob(byte_length) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
        "DELETE FROM model_tool_call WHERE call_ordinal=0",
        "UPDATE turn SET session_ref='f0re1g'",
        "UPDATE model_tool_call SET name_content_id=(SELECT call_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "run tools");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "original", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "replacement", .name = "unknown", .encoded_call_id = "sibling", .decoded_call_id = "sibling", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(&storage, &tmp, binding, "output", &calls);
            var request: protocol.ProposalPage = .{};
            try request.session.set(session.slice());
            const healthy = try storage.proposalPageForTesting(request);
            try std.testing.expectEqual(@as(usize, 2), healthy.count);
            const item = healthy.items[0];
            try std.testing.expectEqual(binding.operation_id, item.operation);
            try std.testing.expectEqual(binding.turn_id, item.turn);
            try std.testing.expectEqual(@as(u64, 0), item.call_ordinal);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("unknown"), &item.fields[0].digest);
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
            try sqlite.exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
            request.end = healthy.end;
            if (route == .cursor) request.after = item.position;
            const result: anyerror!void = if (route == .content)
                if (storage.openProposalField(&.{ .session = request.session, .position = item.position, .field = .name })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.proposalPageForTesting(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.proposalPageForTesting(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "proposal callable cursor domain preserves healthy Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "proposal-config");
    var request: protocol.ProposalPage = .{};
    try request.session.set(session.slice());
    request.end = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidCursor, storage.proposalPageForTesting(request));
    request.end = null;
    request.after = 1;
    try std.testing.expectError(error.InvalidCursor, storage.proposalPageForTesting(request));
    request.end = 0;
    request.after = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidCursor, storage.proposalPageForTesting(request));
    request.after = 0;
    const page = try storage.proposalPageForTesting(request);
    try std.testing.expectEqual(@as(u64, 0), page.end);
    try std.testing.expectEqual(@as(usize, 0), page.count);
    try std.testing.expect(!page.more and !storage.isFenced());
    try std.testing.expectError(error.ContentNotFound, storage.openProposalField(&.{ .position = std.math.maxInt(u64) }));
}

test "public activity admission corruption fences page and content independently" {
    const faults = [_][:0]const u8{
        "UPDATE message_admission SET admission_position=NULL WHERE command_key='message'",
        "UPDATE core_command SET target='f0re1g' WHERE command_key='message'",
        "DELETE FROM conversation_entry WHERE source_admission_id=(SELECT admission_id FROM message_admission WHERE command_key='message')",
    };
    for (faults) |fault| {
        for ([_]bool{ false, true }) |content_route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "input bytes");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const queued = try storage.activityPageForTesting(request);
            try std.testing.expectEqual(@as(usize, 1), queued.count);
            const item = queued.items[0];
            try std.testing.expectEqualStrings("message", item.value.admission.key.slice());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("input bytes"), &item.value.admission.content.digest);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try sqlite.exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            request.position = item.position - 1;
            const result: anyerror!void = if (content_route)
                if (storage.openActivityContent(&.{ .session = request.session, .position = item.position })) |value| blk: {
                    var reader: ContentReader = undefined;
                    reader.open(value);
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.activityPageForTesting(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.activityPageForTesting(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "activity fixed admission prefix survives later application and stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "activity-config");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const empty = try storage.activityPageForTesting(request);
    try submitTestMessage(&storage, &tmp, "activity-a", "a", session.slice(), "same");
    try submitTestMessage(&storage, &tmp, "activity-b", "b", session.slice(), "same");
    const queued = try storage.activityPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 2), queued.count);
    try std.testing.expect(queued.items[0].value.admission.admission != queued.items[1].value.admission.admission);
    try std.testing.expect(queued.items[0].value.admission.turn == null);
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    _ = try admitted.permit.consume();
    var stop = try completeSessionStop("activity-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try expectActivityOutcome(&storage, session.slice(), admitted.permit.binding, "cancelled");
    request.end = queued.end;
    const frozen = try storage.activityPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 2), frozen.count);
    try std.testing.expect(frozen.items[0].value.admission.state == .queued and frozen.items[0].value.admission.turn == null);
    request.end = empty.end;
    try std.testing.expectEqual(@as(usize, 0), (try storage.activityPageForTesting(request)).count);
}

test "an activity page reports the queued Messages at its end, until applied or stopped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "queued-config");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    try std.testing.expectEqual(@as(protocol.Queued, .{}), (try storage.activityPageForTesting(request)).queued);
    try submitTestMessage(&storage, &tmp, "queued-a", "a", session.slice(), "first");
    try submitTestMessage(&storage, &tmp, "queued-b", "b", session.slice(), "second");
    const waiting = try storage.activityPageForTesting(request);
    const first = waiting.items[0];
    const second = waiting.items[1];
    try std.testing.expectEqual(@as(protocol.Queued, .{ .count = 2, .oldest_position = first.position, .newest_admission = second.value.admission.admission, .newest_position = second.position }), waiting.queued);
    // Taken at an input boundary: none waits at the latest end, both still
    // do at the earlier one.
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    _ = try admitted.permit.consume();
    try std.testing.expectEqual(@as(u64, 0), (try storage.activityPageForTesting(request)).queued.count);
    var frozen = request;
    frozen.end = waiting.end;
    try std.testing.expectEqual(waiting.queued, (try storage.activityPageForTesting(frozen)).queued);
    // One sent behind the work waits until a stop excludes it.
    try submitTestMessage(&storage, &tmp, "queued-c", "c", session.slice(), "third");
    const behind = try storage.activityPageForTesting(request);
    try std.testing.expectEqual(@as(u64, 1), behind.queued.count);
    try std.testing.expectEqual(behind.end, behind.queued.oldest_position);
    try std.testing.expectEqual(behind.end, behind.queued.newest_position);
    var stop = try completeSessionStop("queued-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 0), (try storage.activityPageForTesting(request)).queued.count);
    frozen.end = behind.end;
    try std.testing.expectEqual(behind.queued, (try storage.activityPageForTesting(frozen)).queued);
}

test "the queued Messages cost the queue, not the history after a page's end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
    // Messages 1..n wait at positions 2, 4, ...; a stop at 2n+1 excludes all
    // but the newest. A page ending at the first Message has one waiting,
    // as one ending after the stop does.
    var steps: [2][2]i32 = undefined;
    for ([_]usize{ 10, 10_000 }, &steps) |history, *cost| {
        try sqlite.exec(storage.database, "DELETE FROM message_admission; DELETE FROM session_stop");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at) " ++
                "SELECT value,'qu3u3d',printf('queued-%d',value),1,2*value,1 FROM sequence; " ++
                "INSERT INTO session_stop(command_key,session_ref,admission_cutoff,position,stopped_at) VALUES('stop','qu3u3d',{0}-1,2*{0}+1,1)",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try sqlite.exec(storage.database, insert);
        const statement = try storage.cached(queued_sql);
        for ([_]u64{ 2, 2 * history + 1 }, [_]u64{ 1, history }, cost) |end, newest, *probe| {
            _ = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 1);
            try std.testing.expectEqual(protocol.Queued{ .count = 1, .oldest_position = 2 * newest, .newest_admission = newest, .newest_position = 2 * newest }, try reads_domain.readQueuedLocked(&storage, "qu3u3d", end));
            probe.* = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }
    }
    try std.testing.expectEqual(steps[0], steps[1]);
}

test "every activity row is dated by the fact that owns it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try sqlite.exec(storage.database, "UPDATE message_admission SET admitted_at=101;" ++
        "UPDATE conversation_entry SET recorded_at=CASE entry_kind WHEN 1 THEN 102 WHEN 3 THEN 103 ELSE 109 END;" ++
        "UPDATE model_operation SET resolved_at=104;" ++
        "UPDATE action_operation SET resolved_at=CASE call_ordinal WHEN 0 THEN 105 ELSE 106 END;" ++
        "UPDATE turn SET outcome_at=107;" ++
        "UPDATE session_stop SET stopped_at=108");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const page = try storage.activityPageForTesting(request);
    var seen: std.EnumSet(std.meta.Tag(protocol.ActivityItem.Value)) = .empty;
    for (page.items[0..page.count]) |item| {
        const expected: u64 = switch (item.value) {
            .admission => 101,
            .user => 102,
            .assistant => 103,
            .call => 104,
            .tool_result => 106,
            .outcome => 107,
            .stop => 108,
            .sent, .send_failed => unreachable,
        };
        try std.testing.expectEqual(expected, item.at);
        seen.insert(item.value);
    }
    try std.testing.expectEqual(@as(usize, 7), seen.count());
    try std.testing.expect(!storage.isFenced());
}

test "a Tool Result is dated by its group's last acceptance, even when the clock stepped back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "stepped-config");
    try submitTestMessage(&storage, &tmp, "stepped-input", "stepped-input", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "stepped-calls");
    var stop = try completeSessionStop("stepped-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    // The clock stepped back between the two acceptances: the later one,
    // at the greater position, carries the earlier time.
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(DISTINCT acceptance_position) FROM action_operation"));
    try sqlite.exec(storage.database, "UPDATE action_operation SET resolved_at=" ++
        "CASE WHEN acceptance_position=(SELECT max(acceptance_position) FROM action_operation) THEN 100 ELSE 200 END");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const page = try storage.activityPageForTesting(request);
    var results: usize = 0;
    for (page.items[0..page.count]) |item| if (item.value == .tool_result) {
        try std.testing.expectEqual(@as(u64, 100), item.at);
        results += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), results);
    try std.testing.expect(!storage.isFenced());
}

fn denyForTesting(storage: *Store, session: []const u8, key: []const u8, action_id: u64) !void {
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .deny };
    try deny.key.set(key);
    try deny.session.set(session);
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
}

test "Session work dates a tool group by its last acceptance, even when the clock stepped back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;

    // Ask: denying one Action leaves the other awaiting, so the Session
    // awaits approval from that denial, though the clock read earlier than
    // at the proposal.
    const ask = try configureTestSessionAsk(&storage, "stepped-ask");
    try submitTestMessage(&storage, &tmp, "stepped-ask-input", "stepped-ask-input", ask.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-ask-calls");
    const first = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation");
    try denyForTesting(&storage, ask.slice(), "stepped-deny-first", first);
    try sqlite.exec(storage.database, "UPDATE model_operation SET resolved_at=300;UPDATE action_operation SET resolved_at=100 WHERE resolution_code IS NOT NULL");
    try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, ask.slice(), "approval"));
    // Denying the other settles the group: pending from the later denial,
    // whose clock read earlier still.
    try denyForTesting(&storage, ask.slice(), "stepped-deny-second", try queryU64(storage.database, "SELECT max(action_id) FROM action_operation"));
    try sqlite.exec(storage.database, "UPDATE action_operation SET resolved_at=" ++
        "CASE WHEN acceptance_position=(SELECT max(acceptance_position) FROM action_operation) THEN 50 ELSE 100 END");
    try std.testing.expectEqual(@as(u64, 50), try expectOneWork(&storage, &tmp, ask.slice(), "pending"));

    // Bypass: both Actions are authorized with the proposal. Once one has
    // run, the other waits for a slot from that run's resolution, not from
    // its own authorization, whatever the clock read.
    const bypass = try configureTestSessionAsk(&storage, "stepped-bypass");
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("stepped-bypass-mode");
    try update.session.set(bypass.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "stepped-bypass-input", "stepped-bypass-input", bypass.slice(), "propose");
    try settleTwoActionsForTesting(&storage, &tmp, (try storage.admitNextModelAttempt(.{})).?.permit.binding, "stepped-bypass-calls");
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
    var sql: [256]u8 = undefined;
    try sqlite.exec(storage.database, try std.fmt.bufPrintSentinel(&sql, "UPDATE model_operation SET resolved_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET decided_at=300 WHERE session_ref='{0s}';" ++
        "UPDATE action_operation SET resolved_at=70 WHERE session_ref='{0s}' AND resolution_code IS NOT NULL", .{bypass.slice()}, 0));
    try std.testing.expectEqual(@as(u64, 70), try expectOneWork(&storage, &tmp, bypass.slice(), "pending"));
    try std.testing.expect(!storage.isFenced());
}

test "queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back" {
    for ([_]enum { behind_the_turn, after_the_outcome }{ .behind_the_turn, .after_the_outcome }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
                const quota: @import("../transport_policy.zig").Quota = .{ .code = .usage_limit_reached, .resets_at = 1792940000 };
                try storage.settleModelAttemptFailure(binding, .{ .rejected = .{ .code = quota.failureCode(), .diagnostic = quota.format(&diagnostic), .request_id = .{}, .report = "" } }, .ordinary, .{});
                try sqlite.exec(storage.database, "UPDATE message_admission SET admitted_at=200 WHERE command_key='stepped-queue-input';UPDATE turn SET outcome_at=100");
            },
            // Admitted after the outcome: pending from the admission, though
            // the clock read earlier than at the outcome.
            .after_the_outcome => {
                const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                try answerTestTurn(&storage, &tmp, session.slice(), "stepped-queue-answer", &answer);
                try submitTestMessage(&storage, &tmp, "stepped-queue-input", "stepped-queue-input", session.slice(), "queued");
                try sqlite.exec(storage.database, "UPDATE turn SET outcome_at=200;UPDATE message_admission SET admitted_at=100 WHERE command_key='stepped-queue-input'");
            },
        }
        try std.testing.expectEqual(@as(u64, 100), try expectOneWork(&storage, &tmp, session.slice(), "pending"));
        try std.testing.expect(!storage.isFenced());
    }
}

test "persisted tool label corruption fences every publication route" {
    const invalid = [_]struct { sql: []const u8, failure: anyerror = error.CorruptStore }{
        .{ .sql = "' '" },
        .{ .sql = "'Read' || char(10) || 'files'" },
        .{ .sql = "char(160)" },
        .{ .sql = "'Read' || char(8232) || 'files'" },
        // Bounded text rejects malformed UTF-8 before semantic validation.
        .{ .sql = "CAST(X'80' AS TEXT)", .failure = error.InvalidUtf8 },
    };
    for (invalid) |description| {
        for ([_]enum { current, full, live_activity, settled_activity, conversation }{ .current, .full, .live_activity, .settled_activity, .conversation }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "label-config");
            try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            request.direction = .backward;
            const healthy = try storage.activityPageForTesting(request);
            try std.testing.expectEqual(@as(u64, 2), healthy.call_activity.total);
            try std.testing.expectEqualStrings("Run first command", healthy.call_activity.entries[0].presentation.description.?.slice());
            if (route == .settled_activity or route == .conversation) {
                var stop = try completeSessionStop("label-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(@as(usize, 3), (try storage.publicConversationPageForTesting(.{ .session = request.session })).count);
            }
            var sql: [256]u8 = undefined;
            try sqlite.exec(storage.database, try std.fmt.bufPrintSentinel(&sql, "UPDATE model_tool_call SET description={s} WHERE call_ordinal=0", .{description.sql}, 0));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            const result: anyerror!void = switch (route) {
                .current, .full => if (testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, if (route == .full) .full else .current)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .live_activity, .settled_activity => if (storage.activityPageForTesting(request)) |_| {} else |err| err,
                .conversation => if (storage.publicConversationPageForTesting(.{ .session = request.session })) |_| {} else |err| err,
            };
            try std.testing.expectError(description.failure, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.activityPageForTesting(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "tool label observation trusts admission over damaged call field bytes" {
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "label-config");
        try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const before = try storage.activityPageForTesting(request);
        // Damage only the call fields' bytes, not the accepted references or
        // their metadata. Lightweight observations do not read those bytes.
        try sqlite.exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT arguments_content_id FROM model_tool_call)");
        const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
        defer std.testing.allocator.free(report);
        try std.testing.expect(std.mem.indexOf(u8, report, "Run first command") != null);
        const after = try storage.activityPageForTesting(request);
        try std.testing.expectEqual(before.call_activity.total, after.call_activity.total);
        for (before.call_activity.entries[0..before.call_activity.count], after.call_activity.entries[0..after.call_activity.count]) |original, observed| {
            try std.testing.expectEqualStrings(original.presentation.description.?.slice(), observed.presentation.description.?.slice());
            try std.testing.expectEqual(original.presentation.code, observed.presentation.code);
        }
        // Model replay, not label observation, authenticates field bytes.
        try std.testing.expect(!storage.isFenced());
    }
}

test "completed tool labels trust admission while model replay authenticates payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "replay-config");
    try submitTestMessage(&storage, &tmp, "replay-input", "replay-input", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "replay-calls");
    var stop = try completeSessionStop("replay-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    var request: protocol.ConversationPage = .{};
    try request.session.set(session.slice());
    const before = try storage.publicConversationPageForTesting(request);
    try sqlite.exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT name_content_id FROM model_tool_call)");
    const after = try storage.publicConversationPageForTesting(request);
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
    const first = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, first.kind);
    const call = (try view.nextEntry(first.position)).?;
    try std.testing.expectEqual(try queryU64(storage.database, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3"), call.position);
    const name = (try view.openOutput(call.position)).call.?[0];
    var reader: HistoricalReader = undefined;
    try view.openContent(name, &reader);
    defer reader.close();
    var buffer: [4096]u8 = undefined;
    try std.testing.expectError(error.CorruptStore, reader.read(0, buffer[0..@intCast(name.length)]));
    try std.testing.expect(storage.isFenced());
}

test "live tool activity survives completed Turns and split result pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const page = try storage.activityPageForTesting(request);
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
    const split = try storage.activityPageForTesting(request);
    try std.testing.expect(split.more);
    try std.testing.expectEqual(@as(u64, 10), split.call_activity.total);
    try std.testing.expectEqual(@as(u64, 10), split.call_activity.entries[0].ordinal);
    const split_last = split.items[split.count - 1];
    request.position = split_last.position;
    request.ordinal = split_last.ordinal;
    const finished = try storage.activityPageForTesting(request);
    try std.testing.expect(!finished.more);
    try std.testing.expectEqual(@as(u64, 0), finished.call_activity.total);
    request.position = 0;
    request.ordinal = null;
    request.direction = .backward;
    try std.testing.expectEqual(@as(u64, 0), (try storage.activityPageForTesting(request)).call_activity.total);

    // Fixed history boundaries cannot suppress newer live calls.
    try submitTestMessage(&storage, &tmp, "live-new", "new", session.slice(), "propose again");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, next, "live-new-calls");
    request.direction = .forward;
    request.position = finished.end;
    const frozen = try storage.activityPageForTesting(request);
    try std.testing.expectEqual(@as(usize, 0), frozen.count);
    try std.testing.expectEqual(@as(u64, 2), frozen.call_activity.total);
    try std.testing.expectEqual(next.operation_id, frozen.call_activity.entries[0].operation);
}

test "compaction overflow admits a new Operation without losing applied input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const input = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
    try std.testing.expect((try view.nextEntry(input.position)) == null);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
    const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const resolution = report.value.object.get("full").?.object.get("model_operations").?.array.items[0].object.get("resolution").?.object;
    try std.testing.expectEqualStrings("context_overflow", resolution.get("code").?.string);
    try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
    try std.testing.expectEqual(original.operation_id, try queryU64(storage.database, "SELECT operation_id FROM model_operation WHERE request_id='compact-overflow-request' AND resolution_code='context_overflow' AND last_failure_code='context_overflow'"));
}

fn readTestingContent(view: *HistoricalView, content: HistoricalContent, out: *std.Io.Writer) !void {
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
/// or an output item's kind, bag, call fields and parts (`array.kind=text{bag}`).
fn renderTestingEntry(view: *HistoricalView, entry: HistoricalEntry, buffer: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
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

const TestingHistoryCursor = struct {
    position: u64 = 0,

    fn next(self: *@This(), view: *HistoricalView) !?HistoricalEntry {
        const entry = try view.nextEntry(self.position);
        if (entry) |item| self.position = item.position;
        return entry;
    }
};

pub fn settleCompactionForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, kinds: []const OutputItemKind) !void {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    const source = try tmp.dir.createFile(std.testing.io, "compaction-output", .{ .read = true });
    defer source.close(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "compaction-metadata", .{ .used = &used, .limit = 4096 }, false, &retained);
    defer metadata.deinit();
    var offset: u64 = 0;
    var calls: u64 = 0;
    for (kinds, 0..) |kind, ordinal| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{s}-{d}", .{ @tagName(kind), ordinal });
        const fields: []const u8 = switch (kind) {
            .reasoning => ",\"summary\":[],\"encrypted_content\":\"opaque\"",
            .function_call => ",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\"",
            .compaction => ",\"encrypted_content\":\"opaque\"",
            .message => ",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]",
        };
        var item_buffer: [256]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&item_buffer, "{{\"type\":\"{s}\",\"id\":\"{s}\"{s}}}", .{ @tagName(kind), id, fields });
        if (kind == .function_call) calls += 1;
        try source.writeStreamingAll(std.testing.io, bytes);
        try source.sync(std.testing.io);
        // Each item is judged under the Operation that accepts its kind, so
        // the Store's own Operation check is what rejects a misplaced item.
        const operation: output_format.ModelOperationKind = if (kind == .compaction) .compaction else .assistant_response;
        _ = try output_decode.recordItemForTesting(&metadata, source, offset, bytes.len, ordinal, operation);
        offset += bytes.len;
    }
    try metadata.sealForRead();
    try storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = offset,
        .metadata = metadata.file,
        .item_count = kinds.len,
        .call_count = calls,
        // Deliberately present: compaction must not project visible messages.
        .answer_length = if (try storage.modelOperationKind(binding) == .compaction) 6 else 0,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    }, .{});
}

test "compaction success retains host inputs and ordered anchor suffix across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try std.testing.expect(!storage.isFenced());
    try settleCompactionForTesting(&storage, &tmp, compact, &.{ .reasoning, .compaction, .message });
    var request: protocol.ConversationPage = .{};
    try request.session.set(session.slice());
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPageForTesting(request)).count);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSessionForTesting(session.slice())).action_count);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
    try storage.close();
    try testingStore(&storage, &tmp, std.testing.io);
    // Accepted compaction message items remain private, without a required
    // assistant Conversation entry, across every public inventory on reopen.
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPageForTesting(request)).count);
    const activity = try storage.activityPageForTesting(.{ .session = request.session });
    for (activity.items[0..activity.count]) |item| try std.testing.expect(item.value != .assistant);
    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
    defer std.testing.allocator.free(report);
    var parsed_report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
    defer parsed_report.deinit();
    for (parsed_report.value.object.get("full").?.object.get("conversation").?.array.items) |entry|
        try std.testing.expect(!std.mem.eql(u8, "assistant", entry.object.get("kind").?.string));
    const compaction_message = try queryU64(storage.database, "SELECT session_position FROM model_output_item WHERE item_kind=2");
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
    try std.testing.expectEqual(@as(u64, 3), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code='context_overflow'"));
    const observation = try storage.observeCommand("input");
    try std.testing.expectEqualStrings("ResourceExceeded", observation.message.?.queue.?.state.failed.code.slice());
}

test "compaction defaults nullable overrides and frozen retry survive reopen" {
    const supported_ids = comptime blk: {
        var ids: [model_capability.models.len][]const u8 = undefined;
        for (model_capability.models, &ids) |row, *id| id.* = row.id;
        break :blk ids;
    };
    for (supported_ids ++ [_][]const u8{ "model-a", "gpt-6-luna-alias" }, 0..) |model, model_index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var configure = try completeConfiguration("config", "", workspace, model);
        const created_session_0_reply = storage.configure(&configure, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        const created_session_0 = created_session_0_reply.accepted.session;
        // An unlisted model compacts at 90% of the window Rui assumes for it.
        const expected: ?u64 = if (model_index < supported_ids.len) 244800 else 115200;
        const initial = try storage.inspectSessionForTesting(created_session_0.slice());
        try std.testing.expectEqual(expected, initial.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 0), initial.output_reservation);
        try std.testing.expect(initial.compaction_trigger_override == null and initial.output_reservation_override == null);
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
        try testingStore(&storage, &tmp, std.testing.io);
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
        try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
        const reset = try storage.inspectSessionForTesting(created_session_0.slice());
        try std.testing.expectEqual(expected, reset.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 0), reset.output_reservation);
        try std.testing.expect(reset.compaction_trigger_override == null and reset.output_reservation_override == null);
        {
            const report = try testingSessionReportWithProfile(&storage, &tmp, created_session_0.slice(), 1024 * 1024, .full);
            defer std.testing.allocator.free(report);
            try std.testing.expect(std.mem.indexOf(u8, report, "\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null") != null);
            // Revision one records inheritance, not today's effective default.
            try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":null,\"output_reservation\":null") != null);
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
        try expectActivityOutcome(&storage, created_session_0.slice(), successor, "ResourceExceeded");
    }
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
        try testingStore(&storage, &tmp, std.testing.io);
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
            try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), try queryU64(storage.database, "SELECT usage_output_tokens FROM model_operation WHERE output_item_count IS NOT NULL"));
        }
        if (index == 10) {
            try std.testing.expectEqual(@as(u64, 400), try queryU64(storage.database, "SELECT usage_uncached_tokens FROM model_operation WHERE output_item_count IS NOT NULL"));
            try std.testing.expectEqual(@as(u64, 600), try queryU64(storage.database, "SELECT usage_cache_read_tokens FROM model_operation WHERE output_item_count IS NOT NULL"));
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

test "compaction pressure uses the latest accepted output even without usage" {
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
            try testingStore(&storage, &tmp, std.testing.io);
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

test "compaction soft trigger freezes settings before selecting arrivals and instructions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    const input = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
    try std.testing.expect((try view.nextEntry(input.position)) == null);
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

fn configureTestEffort(storage: *Store, key: []const u8, session: []const u8, state: protocol.FieldState, value: []const u8) !ConfigureReply {
    var command: protocol.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session);
    command.configuration.reasoning_effort.state = state;
    if (state == .value) try command.configuration.reasoning_effort.value.set(value);
    return storage.configure(&command, .{});
}

fn testingRevisionEfforts(storage: *Store, session: []const u8, destination: []?protocol.ReasoningEffort) !usize {
    const statement = try sqlite.prepare(storage.database, "SELECT reasoning_effort FROM session_revision WHERE session_ref=?1 ORDER BY revision");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    var count: usize = 0;
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) : (count += 1) {
        destination[count] = try sqlite.readNullableEffort(statement, 0);
    }
    return count;
}

test "reasoning effort overrides are model-checked and frozen on each admitted Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

    var create = try completeConfiguration("effort-create", "", workspace, "gpt-6-luna");
    create.configuration.reasoning_effort.state = .value;
    try create.configuration.reasoning_effort.value.set("high");
    const created = storage.configure(&create, .{});
    try std.testing.expect(created == .accepted);
    const session = created.accepted.session;
    var observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort_override);

    try submitTestMessage(&storage, &tmp, "effort-one", "effort-one", session.slice(), "first");
    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    // Clearing the override selects the catalog default for later work only.
    try std.testing.expect(try configureTestEffort(&storage, "effort-clear", session.slice(), .explicit_null, "") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .medium), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), observed.reasoning_effort_override);

    // A replacement Attempt keeps its Operation's frozen effort.
    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
    try sqlite.exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL");
    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, retry.operation_id);
    {
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(retry, &view);
        defer view.close();
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), (try testSettings(&view)).reasoning_effort);
    }

    // Unsupported and outside-grammar values reject without a revision.
    const revision = observed.revision;
    for ([_][]const u8{ "none", "ultra", "HIGH", "" }, 0..) |invalid, index| {
        var key: [32]u8 = undefined;
        const rejected = try configureTestEffort(&storage, try std.fmt.bufPrint(&key, "effort-invalid-{d}", .{index}), session.slice(), .value, invalid);
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, rejected.rejected.code);
        try std.testing.expectEqual(revision, (try storage.inspectSessionForTesting(session.slice())).revision);
    }
    // An omitted field preserves the saved override.
    try std.testing.expect(try configureTestEffort(&storage, "effort-low", session.slice(), .value, "low") == .accepted);
    try std.testing.expect(try configureTestEffort(&storage, "effort-omitted", session.slice(), .omitted, "") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort_override);
    var revisions: [8]?protocol.ReasoningEffort = undefined;
    const revision_count = try testingRevisionEfforts(&storage, session.slice(), &revisions);
    try std.testing.expectEqualSlices(?protocol.ReasoningEffort, &.{ .high, null, .low, .low }, revisions[0..revision_count]);

    // A binding without a catalog default has no effective effort and
    // rejects every explicit value.
    const unknown = try configureTestSession(&storage, "effort-unknown");
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), (try storage.inspectSessionForTesting(unknown.slice())).reasoning_effort);
    const unknown_rejected = try configureTestEffort(&storage, "effort-unknown-low", unknown.slice(), .value, "low");
    try std.testing.expect(unknown_rejected == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, unknown_rejected.rejected.code);

    // A new Operation freezes the effective effort current at its admission,
    // and the frozen value survives reopening.
    try storage.settleModelAttemptFailure(retry, .{ .uncorrelated = "permanent" }, .ordinary, .{});
    try submitTestMessage(&storage, &tmp, "effort-two", "effort-two", session.slice(), "second");
    const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try configureTestEffort(&storage, "effort-xhigh", session.slice(), .value, "xhigh") == .accepted);
    try storage.close();
    storage_open = false;
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    var view: HistoricalView = undefined;
    try reopened.openHistoricalView(second, &view);
    defer view.close();
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), (try testSettings(&view)).reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .xhigh), (try reopened.inspectSessionForTesting(session.slice())).reasoning_effort);
}

test "compaction failed and unresolved candidates preserve the accepted base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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
    try testingStore(&storage, &tmp, std.testing.io);
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

test "compaction selected newest base corruption fences rather than using an older base" {
    for ([_]enum { payload, anchor, tail }{ .payload, .anchor, .tail }) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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
        switch (corruption) {
            .anchor => try sqlite.exec(storage.database, "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4"),
            .tail => try sqlite.exec(storage.database, "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=2"),
            .payload => try sqlite.exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT extras_content_id FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4)"),
        }
        var view: HistoricalView = undefined;
        try storage.openHistoricalView(next, &view);
        defer view.close();
        if (corruption != .payload) {
            try std.testing.expectError(error.CorruptStore, view.coverage());
        } else {
            const anchor = (try view.coverage()).anchor.?;
            const selected = (try view.nextEntry(anchor - 1)).?;
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

test "historical accepted output completeness and provenance fence both read paths" {
    for ([_]enum { no_base, base, suffix, tied_base, tied_suffix }{ .no_base, .base, .suffix, .tied_base, .tied_suffix }) |scenario| {
        for ([_][:0]const u8{
            "DELETE FROM model_output_item WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count+1 WHERE operation_id=?1",
            "UPDATE model_operation SET output_item_count=output_item_count-1 WHERE operation_id=?1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=2",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=1",
            "DELETE FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0",
            "UPDATE model_output_item SET item_ordinal=8 WHERE operation_id=?1 AND item_ordinal=1",
            "UPDATE model_output_item SET session_ref='f0re1g' WHERE operation_id=?1",
            "UPDATE model_output_item SET attempt_ordinal=99 WHERE operation_id=?1",
            "UPDATE model_output_item SET session_position=session_position+1000 WHERE operation_id=?1",
        }) |sql| {
            for ([_]bool{ false, true }) |context_read| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try testingStore(&storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "config");
                try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
                var output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var corrupt_id = output.operation_id;
                var tied_id: ?u64 = null;
                if (scenario != .no_base) {
                    try storage.settleModelAttemptFailure(output, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
                    const base = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCompactionForTesting(&storage, &tmp, base, &.{ .reasoning, .compaction, .message });
                    corrupt_id = base.operation_id;
                    if (scenario == .tied_base) tied_id = base.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario == .tied_suffix) {
                    try submitTestMessage(&storage, &tmp, "between", "between", session.slice(), "between");
                    try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message });
                    tied_id = output.operation_id;
                    output = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                }
                if (scenario != .base) corrupt_id = output.operation_id;
                try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "later");
                try settleCompactionForTesting(&storage, &tmp, output, &.{ .reasoning, .message, .reasoning });
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (tied_id) |previous| {
                    const tie = try sqlite.prepare(storage.database, "UPDATE model_operation SET admission_position=" ++
                        "(SELECT admission_position FROM model_operation WHERE operation_id=?1) WHERE operation_id=?2");
                    defer _ = c.sqlite3_finalize(tie);
                    try sqlite.bindU64(tie, 1, previous);
                    try sqlite.bindU64(tie, 2, output.operation_id);
                    try sqlite.expectDone(tie);
                }
                // Message entries now reference their exact raw items. Bypass
                // that FK only while injecting the intended missing-item fault.
                try sqlite.exec(storage.database, "PRAGMA foreign_keys=OFF");
                const mutation = try sqlite.prepare(storage.database, sql);
                defer _ = c.sqlite3_finalize(mutation);
                try sqlite.bindU64(mutation, 1, corrupt_id);
                try sqlite.expectDone(mutation);
                try sqlite.exec(storage.database, "PRAGMA foreign_keys=ON");
                var view: HistoricalView = undefined;
                try storage.openHistoricalView(next, &view);
                defer view.close();
                if (context_read) {
                    try std.testing.expectError(error.CorruptStore, view.coverage());
                } else {
                    try std.testing.expectError(error.CorruptStore, view.nextEntry(0));
                }
                try std.testing.expect(storage.isFenced());
                try std.testing.expectError(error.StoreFenced, testSettings(&view));
            }
        }
    }
}

test "compaction repeated overflow consumes fixed pending prefix without a proactive loop" {
    for ([_]bool{ false, true }) |with_base| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try testingStore(&storage, &tmp, std.testing.io);
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

test "compaction does not repeat a soft trigger after a failed assistant with unchanged source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
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

test "compaction missing usage estimates covered retained host input" {
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
        try testingStore(&storage, &tmp, std.testing.io);
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

test "historical context selection work excludes nonmatching Operation population" {
    const Measure = struct {
        steps: u64 = 0,

        fn progress(context: ?*anyopaque) callconv(.c) c_int {
            const counter: *@This() = @ptrCast(@alignCast(context orelse return 1));
            counter.steps += 1;
            return 0;
        }

        fn run(population: usize, with_base: bool) !u64 {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
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
            // Isolate search work from payload work: failed assistant/compaction
            // Operations have no accepted output. Their population must not be
            // scanned inside one source/frontier/anchor selection step.
            try sqlite.exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL");
            const insert = try sqlite.prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);

            var view: HistoricalView = undefined;
            try storage.openHistoricalView(current, &view);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            while (!try view.validateOutputsStep()) {}
            try std.testing.expectEqual(with_base, (try view.coverage()).anchor != null);
            return measured.steps;
        }
    };
    for ([_]bool{ false, true }) |with_base| {
        const small = try Measure.run(8, with_base);
        const large = try Measure.run(1024, with_base);
        try std.testing.expect(large <= small + 100);
    }
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
            try sqlite.exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001");
            const insert = try sqlite.prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,'failed',1 FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try sqlite.bindU64(insert, 1, population);
            try sqlite.bindU64(insert, 2, current.operation_id);
            try sqlite.expectDone(insert);
            try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
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
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
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
                var tools: protocol.ConfigureCommand = .{};
                try tools.key.set("tools");
                try tools.session.set(session.slice());
                tools.configuration.tools.state = .value;
                tools.configuration.tools.count = 1;
                tools.configuration.tools.values[0] = .bash;
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
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
            };
            try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSessionForTesting(session.slice())).pending_messages);
            if (kind == .instruction) try std.testing.expectEqual(@as(u64, @intCast(population + 1 + @as(usize, if (compact) 0 else 2))), try queryU64(storage.database, "SELECT count(*) FROM conversation_entry WHERE source_revision IS NOT NULL"));
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

test "compaction new Turn evaluates pressure independently of stopped overflow recovery" {
    for ([_]bool{ false, true }) |stop_compaction| {
        for ([_]bool{ false, true }) |pressure| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
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
            try testingStore(&storage, &tmp, std.testing.io);

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

test "compaction purpose admission fences a missing latest Turn Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "config");
    try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "original input");
    const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    try sqlite.exec(storage.database, "UPDATE turn SET operation_id=99999");
    try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "new input");
    try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
    try std.testing.expect(storage.isFenced());
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
        .{ .code = "provider_cyber_policy", .content_id = 9, .tag = .failed },
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
