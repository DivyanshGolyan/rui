const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const tool_catalog = @import("tools.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 15;
pub const maximum_model_attempts: u64 = 4;
pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;
const complete_tool_results_sql =
    "current.resolution_code='tool_calls' AND EXISTS(" ++
    " SELECT 1 FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_kind=3" ++
    ") AND (SELECT count(*) FROM model_tool_call call WHERE call.operation_id=current.operation_id)=(" ++
    " SELECT count(*) FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_kind=3" ++
    ") AND NOT EXISTS(" ++
    " SELECT 1 FROM model_output_item item LEFT JOIN model_tool_call call " ++
    " ON call.operation_id=item.operation_id AND call.item_ordinal=item.item_ordinal " ++
    " LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id " ++
    " AND action.call_ordinal=call.call_ordinal WHERE item.operation_id=current.operation_id AND item.item_kind=3 AND (" ++
    " call.operation_id IS NULL OR (call.rejection_code IS NULL AND (action.action_id IS NULL OR action.resolution_code IS NULL))" ++
    ")" ++
    ")";
const runnable_eligibility_sql =
    "m.turn_id IS NULL AND NOT EXISTS(" ++
    " SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
    " AND m.admission_id<=stopped.admission_cutoff" ++
    ") AND (NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") OR EXISTS(" ++
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    " AND (current.resolution_code IN ('continued','interrupted') OR (" ++ complete_tool_results_sql ++ "))" ++
    "))";
const runnable_probe_sql =
    "SELECT 1 FROM message_admission m INDEXED BY message_admission_pending WHERE " ++
    runnable_eligibility_sql ++ " UNION ALL SELECT 1 FROM turn active " ++
    "JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.outcome_code IS NULL AND " ++ complete_tool_results_sql ++ " LIMIT 1";
const runnable_selection_sql =
    "WITH candidate AS (" ++
    "SELECT m.session_ref FROM message_admission m INDEXED BY message_admission_pending WHERE " ++
    runnable_eligibility_sql ++ " ORDER BY m.admission_id LIMIT 1) " ++
    "SELECT m.session_ref,min(m.admission_id),max(m.admission_id),count(*),s.revision,s.next_position," ++
    "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    "AND (current.resolution_code IN ('continued','interrupted') OR (" ++ complete_tool_results_sql ++ "))) " ++
    "FROM candidate chosen JOIN message_admission m INDEXED BY message_admission_session_order " ++
    "ON m.session_ref=chosen.session_ref JOIN session s ON s.session_ref=m.session_ref " ++
    "WHERE " ++ runnable_eligibility_sql ++
    " GROUP BY m.session_ref";
const tool_continuation_selection_sql =
    "SELECT active.session_ref,active.first_admission_id,active.input_cutoff,0,s.revision,s.next_position,active.turn_id " ++
    "FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "JOIN session s ON s.session_ref=active.session_ref WHERE active.outcome_code IS NULL AND " ++
    complete_tool_results_sql ++ " ORDER BY current.operation_id LIMIT 1";
const continuation_risk_sql =
    "SELECT 1 FROM model_output_item WHERE session_ref=?1 UNION ALL " ++
    "SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND current.resolution_code IS NULL LIMIT 1";
const session_stop_cutoff_sql =
    "SELECT admission_cutoff FROM session_stop WHERE session_ref=?1 ORDER BY admission_cutoff DESC LIMIT 1";
const pending_message_count_sql =
    "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2";
const retry_admission_select_sql =
    "SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms FROM model_operation " ++
    "INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL AND allowance_used<4 " ++
    "AND retry_due_at_ms<=?1 ORDER BY operation_id LIMIT ?2";

pub const Faults = struct {
    content_read: bool = false,
    content_import: bool = false,
    before_commit: bool = false,
    attempt_before_commit: bool = false,
    output_read: bool = false,
    output_import: bool = false,
    output_commit: bool = false,
    rollback_failure: bool = false,
    control_trace: ?ControlTrace = null,
    settlement_trace: ?SettlementTrace = null,
};

pub const ControlTracePhase = enum { lock_requested, lock_acquired, store_complete };

pub const ControlTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, ControlTracePhase) void,

    fn mark(self: ControlTrace, phase: ControlTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const SettlementTracePhase = enum { lock_acquired, settlement_complete };

pub const SettlementTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, SettlementTracePhase) void,

    fn mark(self: SettlementTrace, phase: SettlementTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const AcceptedConfiguration = struct {
    replayed: bool,
    revision: u64 = 0,
    created: bool = false,
};

pub const ConfigurationRejection = enum {
    invalid_session_reference,
    unsupported_permission_mode,
    invalid_model,
    invalid_output_schema,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    continuation_model_incompatible,
    revision_exhausted,
};

pub const RejectedConfiguration = struct {
    replayed: bool,
    code: ConfigurationRejection,
};

pub const ConfigureReply = union(enum) {
    accepted: AcceptedConfiguration,
    rejected: RejectedConfiguration,
    conflict,
    infrastructure_failure,
};

pub const MessageRejection = enum {
    invalid_session_reference,
    unknown_session,
};

pub const AcceptedMessage = struct {
    replayed: bool,
    admission_id: u64,
    content: ContentReference,
};

pub const RejectedMessage = struct {
    replayed: bool,
    code: MessageRejection,
    content: ContentReference,
};

pub const MessageReply = union(enum) {
    accepted: AcceptedMessage,
    rejected: RejectedMessage,
    conflict,
    infrastructure_failure,
};

pub const CommandKind = enum { configure, message, session_stop, model_interruption, permission_decision };

const StoredAnswer = struct {
    accepted: bool,
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
};

pub const CommandObservation = struct {
    status: enum { absent, accepted, rejected },
    kind: CommandKind = .configure,
    target: protocol.Bounded(protocol.max_session_bytes) = .{},
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
    message: ?MessageObservation = null,
    session_stop: ?SessionStopObservation = null,
    model_interruption: ?ModelInterruptionTarget = null,
    permission_action_id: ?u64 = null,
    permission_decision: ?protocol.PermissionDecision = null,
};

pub const SessionStopSelection = struct {
    selected_turn_id: ?u64 = null,
    admission_cutoff: u64,
};

pub const SessionStopObservation = struct {
    selection: SessionStopSelection,
    completion: enum { pending, completed },
};

pub const ModelInterruptionTarget = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    turn_id: u64,
    operation_id: u64,
};

pub const SessionStopRejection = enum { invalid_session_reference, unknown_session };

pub const SessionStopReply = union(enum) {
    accepted: struct {
        replayed: bool,
        selection: SessionStopSelection,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: SessionStopRejection },
    conflict,
    infrastructure_failure,
};

pub const ModelInterruptionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_operation,
    target_mismatch,
    operation_resolved,
};

pub const ModelInterruptionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: ModelInterruptionRejection },
    conflict,
    infrastructure_failure,
};

pub const PermissionDecisionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    action_not_pending,
};

pub const PermissionDecisionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: PermissionDecisionRejection },
    conflict,
    infrastructure_failure,
};

pub const ActionAttemptBinding = struct {
    turn_id: u64,
    parent_operation_id: u64,
    action_id: u64,
    attempt_ordinal: u64,
};

pub const ActionAttemptAdmission = struct {
    permit: ActionDispatchPermit,
};

pub const ActionResolutionCode = enum {
    cancelled,
    succeeded,
    failed,
    timed_out,
    indeterminate,
    storage_failed,
    spawn_failed,
    infrastructure_shutdown,
};

const max_action_resolution_code_bytes = maxEnumTagBytes(ActionResolutionCode);
const max_permission_decision_bytes = maxEnumTagBytes(protocol.PermissionDecision);

pub const ActionSettlement = enum { effect, session_stop };

pub const ActionDispatchPermit = struct {
    binding: ActionAttemptBinding,
    available: bool = true,

    pub fn consume(self: *ActionDispatchPermit) !ActionAttemptBinding {
        if (!self.available) return error.DispatchPermitConsumed;
        self.available = false;
        return self.binding;
    }
};

pub const BashExecutionInput = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    arguments: ContentReference,
    timeout_ms: u64,
};

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

pub const MessageObservation = struct {
    content: ContentReference,
    queue: ?AcceptedMessageQueue = null,
};

pub const AcceptedMessageQueue = struct {
    admission_id: u64,
    state: State,

    pub const State = union(enum) {
        queued,
        excluded: struct { code: protocol.Bounded(96) },
        processing: AttemptBinding,
        completed: struct {
            binding: AttemptBinding,
            answer: ContentReference,
        },
        cancelled: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(96),
        },
        failed: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(96),
        },
    };
};

pub const AttemptBinding = struct {
    turn_id: u64,
    operation_id: u64,
    attempt_ordinal: u64,
};

pub const DispatchPermit = struct {
    binding: AttemptBinding,
    available: bool = true,

    pub fn consume(self: *DispatchPermit) !AttemptBinding {
        if (!self.available) return error.DispatchPermitConsumed;
        self.available = false;
        return self.binding;
    }
};

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
};

/// Borrowed from one pointer-stable preparation view. Invalid after it closes.
pub const HistoricalContent = struct {
    view: *HistoricalView,
    length: u64,
    digest: [32]u8,
    private: bool = false,

    fn belongsTo(self: HistoricalContent, view: *HistoricalView) bool {
        return self.view == view and view.active;
    }
};

pub const RetryPolicyInput = struct {
    waits_ms: [3]u64,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const ModelFailureDisposition = union(enum) {
    terminal,
    retryable: RetryPolicyInput,
};

const ModelRetryDecision = union(enum) {
    schedule_at_ms: i64,
    exhausted,
};

pub const ActiveOperationFilter = struct {
    context: *const anyopaque,
    containsFn: *const fn (*const anyopaque, u64) bool,
    maximum_exclusions: usize,

    pub fn contains(self: ActiveOperationFilter, operation_id: u64) bool {
        return self.containsFn(self.context, operation_id);
    }

    pub fn empty() ActiveOperationFilter {
        return .{
            .context = &empty_active_context,
            .containsFn = containsNoActiveOperation,
            .maximum_exclusions = 0,
        };
    }
};

const empty_active_context: u8 = 0;

fn containsNoActiveOperation(_: *const anyopaque, _: u64) bool {
    return false;
}

pub const HistoricalSettings = struct {
    model: protocol.Bounded(protocol.max_model_bytes),
    baseline_instructions: HistoricalContent,
    output_schema: ?HistoricalContent,
    tools_mask: u8,
};

pub const HistoricalEntryKind = enum { user, instruction, provider_output, tool_results };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ?HistoricalContent = null,
};

pub const HistoricalToolResult = struct {
    call_id: HistoricalContent,
    output: HistoricalContent,
};

/// The preparation owner keeps this value at one address until every borrowed
/// handle/reader is discarded. Readers must close before the view closes.
pub const HistoricalView = struct {
    store: *Store,
    binding: AttemptBinding,
    active: bool = true,
    readers: usize = 0,
    tool_group_initialized: bool = false,
    tool_group_scan_after: u64 = 0,
    tool_group_source_cursor: u64 = 0,
    next_tool_group: ?HistoricalEntry = null,
    next_tool_group_source_id: ?u64 = null,
    active_tool_group_source_id: ?u64 = null,
    active_tool_group_after_ordinal: ?u64 = null,
    active_tool_group_count: u64 = 0,

    pub fn settings(self: *HistoricalView) !HistoricalSettings {
        std.debug.assert(self.active);
        return self.store.readHistoricalSettings(self);
    }

    pub fn nextEntry(self: *HistoricalView, after_position: u64) !?HistoricalEntry {
        std.debug.assert(self.active);
        std.debug.assert(self.active_tool_group_source_id == null);
        return self.store.readHistoricalEntry(self, after_position);
    }

    /// A tool-results entry activates one canonical group. Consume it fully
    /// before requesting the next historical entry.
    pub fn nextToolResult(self: *HistoricalView) !?HistoricalToolResult {
        std.debug.assert(self.active and self.active_tool_group_source_id != null);
        return self.store.readHistoricalToolResult(self);
    }

    pub fn openContent(self: *HistoricalView, reference: HistoricalContent) !HistoricalReader {
        std.debug.assert(reference.belongsTo(self));
        const reader = try self.store.openContentIdentity(.{ .length = reference.length, .digest = reference.digest }, reference.private);
        self.readers += 1;
        return .{ .view = self, .reference = reference, .reader = reader };
    }

    pub fn close(self: *HistoricalView) void {
        std.debug.assert(self.active and self.readers == 0);
        self.active = false;
    }
};

pub const HistoricalReader = struct {
    reader: ContentReader,
    view: *HistoricalView,
    reference: HistoricalContent,
    active: bool = true,

    fn usable(self: *const HistoricalReader) bool {
        return self.active and self.reference.belongsTo(self.view);
    }

    pub fn read(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.usable());
        return self.reader.read(start, destination);
    }

    pub fn close(self: *HistoricalReader) void {
        std.debug.assert(self.usable());
        self.reader.close();
        self.view.readers -= 1;
        self.active = false;
    }
};

pub const OutputItemKind = enum(u8) { reasoning = 1, message = 2, function_call = 3 };
pub const OutputRecordTag = enum(u8) {
    item = 1,
    text = 2,
    usage = 3,
    item_id = 4,
    name = 5,
    call_id = 6,
    arguments = 7,
};

pub const OutputMetadataRecord = struct {
    tag: OutputRecordTag,
    kind: OutputItemKind = .reasoning,
    ordinal: u64 = 0,
    start: u64,
    length: u64,
    decoded_length: u64 = 0,
    id_digest: [32]u8 = [_]u8{0} ** 32,
    content_digest: [32]u8 = [_]u8{0} ** 32,
};

const output_metadata_record_bytes = 104;

pub const OutputMetadataWriter = struct {
    io: std.Io,
    file: std.Io.File,
    budget: protocol.ScratchBudget,
    charged: u64 = 0,
    records: u64 = 0,
    decoded_length: u64 = 0,
    fail_writes: bool = false,
    sealed: bool = false,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        name: []const u8,
        budget: protocol.ScratchBudget,
        fail_unlink: bool,
        retained: *?named_scratch.Owner,
    ) !OutputMetadataWriter {
        retained.* = null;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        if (fail_unlink) {
            retained.* = .init(
                io,
                file,
                null,
                name,
                budget,
                0,
                .injected_failure,
            );
            return error.InjectedMetadataUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = .init(io, file, null, name, budget, 0, .native);
            return err;
        };
        return .{ .io = io, .file = file, .budget = budget };
    }

    pub fn append(self: *OutputMetadataWriter, record: OutputMetadataRecord) !void {
        std.debug.assert(!self.sealed);
        if (self.fail_writes) return error.InjectedMetadataFailure;
        if (!self.budget.reserve(output_metadata_record_bytes)) {
            return error.MetadataScratchExhausted;
        }
        // A failed write ends validation; retain the complete fixed-record
        // reservation until deinit so a partial OS write is never uncharged.
        self.charged += output_metadata_record_bytes;
        var bytes: [output_metadata_record_bytes]u8 = [_]u8{0} ** output_metadata_record_bytes;
        bytes[0] = @intFromEnum(record.tag);
        bytes[1] = @intFromEnum(record.kind);
        std.mem.writeInt(u64, bytes[8..16], record.ordinal, .little);
        std.mem.writeInt(u64, bytes[16..24], record.start, .little);
        std.mem.writeInt(u64, bytes[24..32], record.length, .little);
        std.mem.writeInt(u64, bytes[32..40], record.decoded_length, .little);
        @memcpy(bytes[40..72], &record.id_digest);
        @memcpy(bytes[72..104], &record.content_digest);
        try self.file.writeStreamingAll(self.io, &bytes);
        self.records += 1;
        if (record.tag == .text) {
            self.decoded_length = try std.math.add(u64, self.decoded_length, record.decoded_length);
        }
    }

    pub fn sealForRead(self: *OutputMetadataWriter) !void {
        if (self.sealed) return;
        try self.file.sync(self.io);
        if (try self.file.length(self.io) != self.charged) return error.MetadataSealFailed;
        self.sealed = true;
    }

    pub fn deinit(self: *OutputMetadataWriter) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

pub const OutputMetadataReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    length: u64,

    pub fn init(io: std.Io, file: std.Io.File, _: u64) !OutputMetadataReader {
        const length = try file.length(io);
        return .{ .io = io, .file = file, .length = length };
    }

    pub fn next(self: *OutputMetadataReader) !?OutputMetadataRecord {
        if (self.offset == self.length) return null;
        if (self.length - self.offset < output_metadata_record_bytes) return error.CorruptOutputMetadata;
        var bytes: [output_metadata_record_bytes]u8 = undefined;
        const count = try self.file.readPositionalAll(self.io, &bytes, self.offset);
        if (count != bytes.len) return error.CorruptOutputMetadata;
        self.offset += bytes.len;
        return .{
            .tag = switch (bytes[0]) {
                1 => .item,
                2 => .text,
                3 => .usage,
                4 => .item_id,
                5 => .name,
                6 => .call_id,
                7 => .arguments,
                else => return error.CorruptOutputMetadata,
            },
            .kind = switch (bytes[1]) {
                1 => .reasoning,
                2 => .message,
                3 => .function_call,
                else => return error.CorruptOutputMetadata,
            },
            .ordinal = std.mem.readInt(u64, bytes[8..16], .little),
            .start = std.mem.readInt(u64, bytes[16..24], .little),
            .length = std.mem.readInt(u64, bytes[24..32], .little),
            .decoded_length = std.mem.readInt(u64, bytes[32..40], .little),
            .id_digest = bytes[40..72].*,
            .content_digest = bytes[72..104].*,
        };
    }

    pub fn nextItem(self: *OutputMetadataReader) !?OutputMetadataRecord {
        while (try self.next()) |record| if (record.tag == .item) return record;
        return null;
    }
};

const EncodedStringReader = struct {
    io: std.Io,
    file: std.Io.File,
    position: u64,
    end: u64,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [protocol.content_window_bytes]u8 = undefined,
    pending: [4]u8 = undefined,
    pending_start: u3 = 0,
    pending_end: u3 = 0,

    fn init(io: std.Io, file: std.Io.File, record: OutputMetadataRecord) !EncodedStringReader {
        return .{
            .io = io,
            .file = file,
            .position = record.start,
            .end = try std.math.add(u64, record.start, record.length),
        };
    }

    fn raw(self: *EncodedStringReader) !?u8 {
        if (self.position == self.end) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.end - self.position, self.buffer.len));
            const count = try self.file.readPositionalAll(self.io, self.buffer[0..wanted], self.position);
            if (count != wanted) return error.ShortOutputRead;
            self.buffer_length = count;
        }
        const byte = self.buffer[@intCast(self.position - self.buffer_start)];
        self.position += 1;
        return byte;
    }

    fn requiredRaw(self: *EncodedStringReader) !u8 {
        return try self.raw() orelse error.InvalidEncodedString;
    }

    fn hexScalar(self: *EncodedStringReader) !u21 {
        var value: u21 = 0;
        for (0..4) |_| {
            const byte = try self.requiredRaw();
            const digit: u8 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidEncodedString,
            };
            value = value * 16 + digit;
        }
        return value;
    }

    fn next(self: *EncodedStringReader) !?u8 {
        if (self.pending_start < self.pending_end) {
            const byte = self.pending[self.pending_start];
            self.pending_start += 1;
            return byte;
        }
        const byte = try self.raw() orelse return null;
        if (byte < 0x20) return error.InvalidEncodedString;
        if (byte != '\\') return byte;
        const escape = try self.requiredRaw();
        return switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => blk: {
                var scalar = try self.hexScalar();
                if (scalar >= 0xd800 and scalar <= 0xdbff) {
                    if (try self.requiredRaw() != '\\' or try self.requiredRaw() != 'u') {
                        return error.InvalidEncodedString;
                    }
                    const low = try self.hexScalar();
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidEncodedString;
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
                } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidEncodedString;
                const count = try std.unicode.utf8Encode(scalar, &self.pending);
                self.pending_start = 1;
                self.pending_end = count;
                break :blk self.pending[0];
            },
            else => error.InvalidEncodedString,
        };
    }
};

const JsonStringSource = struct {
    encoded: EncodedStringReader,
    lookahead: ?u8 = null,
    has_lookahead: bool = false,

    pub fn peek(self: *JsonStringSource) !?u8 {
        if (!self.has_lookahead) {
            self.lookahead = try self.encoded.next();
            self.has_lookahead = true;
        }
        return self.lookahead;
    }

    pub fn take(self: *JsonStringSource) !u8 {
        const byte = try self.peek() orelse return error.InvalidDescriptorJson;
        self.has_lookahead = false;
        return byte;
    }

    pub fn space(self: *JsonStringSource) !void {
        while (try self.peek()) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => _ = try self.take(),
            else => return,
        };
    }

    pub fn expect(self: *JsonStringSource, expected: u8) !void {
        try self.space();
        if (try self.take() != expected) return error.InvalidDescriptorJson;
    }

    pub fn string(self: *JsonStringSource, destination: ?*protocol.Bounded(16)) !void {
        try self.space();
        if (try self.take() != '"') return error.InvalidDescriptorJson;
        if (destination) |value| value.len = 0;
        while (true) {
            const byte = try self.take();
            if (byte == '"') return;
            if (byte < 0x20) return error.InvalidDescriptorJson;
            if (byte != '\\') {
                if (destination) |value| {
                    if (value.len == value.bytes.len) return error.InvalidDescriptorShape;
                    value.bytes[value.len] = byte;
                    value.len += 1;
                }
                continue;
            }
            const escape = try self.take();
            const simple: ?u8 = switch (escape) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 8,
                'f' => 12,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => null,
                else => return error.InvalidDescriptorJson,
            };
            if (simple) |decoded| {
                if (destination) |value| {
                    if (value.len == value.bytes.len) return error.InvalidDescriptorShape;
                    value.bytes[value.len] = decoded;
                    value.len += 1;
                }
                continue;
            }
            var scalar: u21 = 0;
            for (0..4) |_| {
                const hex = try self.take();
                const digit: u8 = switch (hex) {
                    '0'...'9' => hex - '0',
                    'a'...'f' => hex - 'a' + 10,
                    'A'...'F' => hex - 'A' + 10,
                    else => return error.InvalidDescriptorJson,
                };
                scalar = scalar * 16 + digit;
            }
            if (scalar >= 0xd800 and scalar <= 0xdbff) {
                if (try self.take() != '\\' or try self.take() != 'u') return error.InvalidDescriptorJson;
                var low: u21 = 0;
                for (0..4) |_| {
                    const hex = try self.take();
                    const digit: u8 = switch (hex) {
                        '0'...'9' => hex - '0',
                        'a'...'f' => hex - 'a' + 10,
                        'A'...'F' => hex - 'A' + 10,
                        else => return error.InvalidDescriptorJson,
                    };
                    low = low * 16 + digit;
                }
                if (low < 0xdc00 or low > 0xdfff) return error.InvalidDescriptorJson;
                scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
            } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidDescriptorJson;
            if (destination) |value| {
                var encoded: [4]u8 = undefined;
                const count = std.unicode.utf8Encode(scalar, &encoded) catch return error.InvalidDescriptorJson;
                if (value.len + count > value.bytes.len) return error.InvalidDescriptorShape;
                @memcpy(value.bytes[value.len .. value.len + count], encoded[0..count]);
                value.len += count;
            }
        }
    }
};

fn metadataStringEql(
    io: std.Io,
    file: std.Io.File,
    record: OutputMetadataRecord,
    expected: []const u8,
) !bool {
    if (record.decoded_length != expected.len) return false;
    var source = try EncodedStringReader.init(io, file, record);
    for (expected) |byte| if (try source.next() != byte) return false;
    return try source.next() == null;
}

fn bashArguments(io: std.Io, file: std.Io.File, record: OutputMetadataRecord) !?tool_catalog.BashArguments {
    var source = JsonStringSource{ .encoded = try EncodedStringReader.init(io, file, record) };
    return tool_catalog.inspectBashArguments(&source);
}

pub const ValidatedOutput = struct {
    source: std.Io.File,
    source_length: u64,
    metadata: std.Io.File,
    item_count: u64,
    call_count: u64,
    answer_length: u64,
    answer_digest: [32]u8,
    response_id: protocol.Bounded(256),
    body_model: protocol.Bounded(protocol.max_model_bytes),
    openai_model: protocol.Bounded(protocol.max_model_bytes),
    x_openai_model: protocol.Bounded(protocol.max_model_bytes),
    request_id: protocol.Bounded(256),
};

pub const SessionObservation = struct {
    found: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    revision: u64 = 0,
    tools_mask: u8 = 0,
    permission_mode: protocol.Bounded(16) = .{},
    instructions: ContentReference = .{ .length = 0, .digest = [_]u8{0} ** 32 },
    output_schema: ?ContentReference = null,
    pending_messages: u64 = 0,
    action_count: u64 = 0,
    rejected_call_count: u64 = 0,
};

pub const SessionReportExecution = struct {
    dispatch_fenced: bool,
    custody_occupied: usize,
    scratch_used_bytes: u64,
};

pub const SessionReportOptions = struct {
    scratch_path: []const u8,
    scratch_budget: protocol.ScratchBudget,
    request_number: u64,
    profile: protocol.ReportProfile = .current,
    execution: SessionReportExecution,
    fail_unlink: bool = false,
};

pub const SessionReport = struct {
    pub const read_window_bytes = 64 * 1024;

    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: protocol.ScratchBudget,

    pub fn read(self: *SessionReport, start: u64, destination: []u8) !usize {
        if (destination.len > read_window_bytes) return error.WindowTooLarge;
        if (start > self.length) return error.RangeOutOfBounds;
        const wanted: usize = @intCast(@min(self.length - start, destination.len));
        return self.file.readPositionalAll(self.io, destination[0..wanted], start);
    }

    pub fn deinit(self: *SessionReport) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

const SessionReportCapture = struct {
    const buffer_bytes = 4096;

    io: std.Io,
    writer: ?std.Io.File,
    budget: protocol.ScratchBudget,
    buffer: [buffer_bytes]u8 = undefined,
    buffered: usize = 0,
    length: u64 = 0,
    charged: u64 = 0,
    ordinary_failure: bool = false,

    fn init(io: std.Io, options: SessionReportOptions) !SessionReportCapture {
        var scratch = try std.Io.Dir.cwd().openDir(io, options.scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "report-{d}-1.tmp", .{options.request_number});
        const writer = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        errdefer writer.close(io);
        if (options.fail_unlink) return error.ReportScratchCleanupFailed;
        scratch.deleteFile(io, name) catch return error.ReportScratchCleanupFailed;
        return .{
            .io = io,
            .writer = writer,
            .budget = options.scratch_budget,
        };
    }

    fn append(self: *SessionReportCapture, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            if (self.buffered == self.buffer.len) try self.flush();
            const count = @min(remaining.len, self.buffer.len - self.buffered);
            @memcpy(self.buffer[self.buffered..][0..count], remaining[0..count]);
            self.buffered += count;
            remaining = remaining[count..];
        }
    }

    fn appendFmt(self: *SessionReportCapture, comptime format: []const u8, args: anytype) !void {
        var bytes: [512]u8 = undefined;
        const value = std.fmt.bufPrint(&bytes, format, args) catch {
            self.ordinary_failure = true;
            return error.ReportEncodingFailed;
        };
        try self.append(value);
    }

    fn appendJsonString(self: *SessionReportCapture, value: []const u8) !void {
        try self.append("\"");
        try self.appendJsonStringBytes(value);
        try self.append("\"");
    }

    fn appendJsonStringBytes(self: *SessionReportCapture, value: []const u8) !void {
        var run_start: usize = 0;
        for (value, 0..) |byte, index| {
            const escaped: ?[]const u8 = switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                8 => "\\b",
                12 => "\\f",
                0...7, 11, 14...31 => null,
                else => continue,
            };
            if (index != run_start) try self.append(value[run_start..index]);
            if (escaped) |bytes| {
                try self.append(bytes);
            } else {
                var control: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&control, "\\u00{x:0>2}", .{byte}) catch unreachable;
                try self.append(&control);
            }
            run_start = index + 1;
        }
        if (run_start != value.len) try self.append(value[run_start..]);
    }

    fn appendContentReference(self: *SessionReportCapture, reference: ContentReference) !void {
        try self.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.append("\"}");
    }

    fn appendBareContentReference(self: *SessionReportCapture, reference: ContentReference) !void {
        try self.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.append("\"}");
    }

    fn appendOwnedContentReference(
        self: *SessionReportCapture,
        reference: ContentReference,
        owner_revision: i64,
        owner_field: RevisionContentField,
    ) !void {
        try self.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try self.append(&std.fmt.bytesToHex(reference.digest, .lower));
        try self.appendFmt("\",\"owner\":{{\"revision\":\"{d}\",\"field\":\"{s}\"}}}}", .{ owner_revision, @tagName(owner_field) });
    }

    fn appendTools(self: *SessionReportCapture, tools_mask: u8) !void {
        if (tools_mask > 3) return error.CorruptStore;
        try self.append("[");
        if (tools_mask & 1 != 0) try self.append("\"bash\"");
        if (tools_mask & 2 != 0) {
            if (tools_mask & 1 != 0) try self.append(",");
            try self.append("\"edit\"");
        }
        try self.append("]");
    }

    fn appendPermissionMode(self: *SessionReportCapture, permission_mode: u8) !void {
        try self.appendJsonString(switch (permission_mode) {
            0 => "ask",
            1 => "bypass",
            else => return error.CorruptStore,
        });
    }

    fn flush(self: *SessionReportCapture) !void {
        if (self.buffered == 0) return;
        const amount: u64 = self.buffered;
        const next_charged = std.math.add(u64, self.charged, amount) catch {
            self.ordinary_failure = true;
            return error.ReportLengthOverflow;
        };
        const next_length = std.math.add(u64, self.length, amount) catch {
            self.ordinary_failure = true;
            return error.ReportLengthOverflow;
        };
        if (!self.budget.reserve(amount)) {
            self.ordinary_failure = true;
            return error.ReportScratchExhausted;
        }
        self.charged = next_charged;
        const writer = self.writer orelse unreachable;
        writer.writeStreamingAll(self.io, self.buffer[0..self.buffered]) catch |err| {
            self.ordinary_failure = true;
            return err;
        };
        self.length = next_length;
        self.buffered = 0;
    }

    fn seal(self: *SessionReportCapture) !SessionReport {
        try self.flush();
        const writer = self.writer orelse unreachable;
        writer.sync(self.io) catch |err| {
            self.ordinary_failure = true;
            return err;
        };
        if (writer.length(self.io) catch |err| {
            self.ordinary_failure = true;
            return err;
        } != self.length) {
            self.ordinary_failure = true;
            return error.ReportSealFailed;
        }
        const report = SessionReport{
            .io = self.io,
            .file = writer,
            .length = self.length,
            .charged = self.charged,
            .budget = self.budget,
        };
        self.writer = null;
        self.charged = 0;
        return report;
    }

    fn deinit(self: *SessionReportCapture) void {
        if (self.writer) |writer| writer.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

/// Raw values allow ranged reads; derived values are read sequentially from
/// zero. No reader or SQLite handle is retained across owner cleanup.
pub const ContentReader = struct {
    pub const content_window_bytes = 64 * 1024;

    content_id: i64,
    representation: union(enum) { raw, projection: ProjectionCursor },
    store: *Store,
    reference: ContentReference,
    active: bool = true,

    pub fn read(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active);
        return self.store.readOwnedContent(self, start, destination);
    }

    pub fn close(self: *ContentReader) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

const CurrentConfiguration = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    tools_mask: u8 = 3,
    permission_mode: u8 = 0,
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
};

const MessageProjection = struct {
    admission_id: u64,
    command_key: protocol.Bounded(128),
    session: protocol.Bounded(protocol.max_session_bytes),
    content_id: i64,
    state: union(enum) {
        pending,
        excluded: protocol.Bounded(128),
        applied: struct {
            binding: AttemptBinding,
            outcome_code: ?protocol.Bounded(96),
            outcome_content_id: ?i64,
        },
    },
};

const RevisionContentField = enum(c_int) {
    instructions = 0,
    output_schema = 1,
};

const ConfigurationContentAction = enum(u2) {
    preserve,
    import_requested,
    default_empty,
    clear,
};

const ConfigurationUpdatePlan = union(enum) {
    rejected: ConfigurationRejection,
    update: struct {
        instructions: ConfigurationContentAction,
        output_schema: ConfigurationContentAction,
    },
};

fn configurationBeforeWorkspace(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
    continuation_risk: bool,
) ?ConfigurationRejection {
    if (current == null and
        (requested.workspace.state != .value or requested.model.state != .value))
    {
        return .incomplete_initial_configuration;
    }
    if (current) |existing| {
        if (requested.model.state == .value and
            !existing.model.eql(requested.model.value.slice()) and
            continuation_risk)
        {
            return .continuation_model_incompatible;
        }
    }
    return null;
}

fn planConfigurationUpdate(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
    canonical_workspace: ?*const protocol.Bounded(protocol.max_workspace_bytes),
    next: *CurrentConfiguration,
) ConfigurationUpdatePlan {
    const created = current == null;
    if (requested.workspace.state == .value) {
        const workspace = canonical_workspace orelse unreachable;
        if (current) |existing| {
            if (!existing.workspace.eql(workspace.slice())) {
                return .{ .rejected = .workspace_is_immutable };
            }
        }
    } else {
        std.debug.assert(canonical_workspace == null);
    }
    if (current) |existing| {
        if (existing.revision == std.math.maxInt(i64)) {
            return .{ .rejected = .revision_exhausted };
        }
    }

    if (canonical_workspace) |workspace| next.workspace = workspace.*;
    if (requested.model.state == .value) next.model = requested.model.value;
    if (requested.tools.state == .value) {
        next.tools_mask = 0;
        for (requested.tools.values[0..requested.tools.count]) |tool| {
            next.tools_mask |= switch (tool) {
                .bash => 1,
                .edit => 2,
            };
        }
    }
    if (requested.permission_mode.state == .value) {
        next.permission_mode = if (requested.permission_mode.value.eql("ask")) 0 else 1;
    }
    next.revision = if (created) 1 else current.?.revision + 1;

    return .{ .update = .{
        .instructions = switch (requested.instructions.state) {
            .value => .import_requested,
            .omitted, .explicit_null => if (created) .default_empty else .preserve,
        },
        .output_schema = switch (requested.output_schema.state) {
            .value => .import_requested,
            .explicit_null => .clear,
            .omitted => if (created) .clear else .preserve,
        },
    } };
}

pub const OpenOptions = struct {
    cache_spill: bool = true,
    cache_kib: u32 = 4096,
};

pub const SqliteDiagnostic = struct {
    process_memory_current_bytes: ?u64 = null,
    process_memory_highwater_bytes: ?u64 = null,
    cache_used_bytes: ?u64 = null,
    cache_spills: ?u64 = null,
    hard_heap_limit_bytes: ?u64 = null,
    page_size_bytes: ?u64 = null,
    cache_size_setting: ?i64 = null,
    cache_spill_threshold: ?i64 = null,
    mmap_size_bytes: ?u64 = null,
    synchronous: ?i64 = null,
    temp_store: ?i64 = null,
    busy_timeout_ms: ?u64 = null,
    journal_mode: ?protocol.Bounded(16) = null,
};

pub const Store = struct {
    io: std.Io,
    database: *c.sqlite3,
    selector: protocol.Bounded(protocol.max_store_bytes),
    mutex: std.Io.Mutex = .init,
    fenced: std.atomic.Value(bool) = .init(false),

    pub fn open(io: std.Io, database_path: []const u8, selector: []const u8) !Store {
        return openWithOptions(io, database_path, selector, .{});
    }

    pub fn openWithOptions(
        io: std.Io,
        database_path: []const u8,
        selector: []const u8,
        options: OpenOptions,
    ) !Store {
        if (options.cache_kib == 0 or options.cache_kib > 4096) return error.InvalidSqliteCacheSize;
        if (c.sqlite3_hard_heap_limit64(@intCast(sqlite_heap_bytes)) < 0) {
            return error.SqliteHeapLimitConfigurationFailed;
        }
        errdefer _ = c.sqlite3_hard_heap_limit64(0);

        const existing = blk: {
            const stat = std.Io.Dir.cwd().statFile(io, database_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            if (stat.kind != .file) return error.InvalidStoreDatabase;
            break :blk stat.size != 0;
        };

        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{database_path});
        var database: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(
            path,
            &database,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (open_result != c.SQLITE_OK) {
            if (database) |db| _ = c.sqlite3_close(db);
            return error.StoreOpenFailed;
        }
        errdefer _ = c.sqlite3_close(database.?);

        try setLimit(database.?, c.SQLITE_LIMIT_LENGTH, @intCast(protocol.max_sqlite_content_bytes + 4096));
        try setLimit(database.?, c.SQLITE_LIMIT_SQL_LENGTH, 16 * 1024);
        try setLimit(database.?, c.SQLITE_LIMIT_COLUMN, 32);
        try setLimit(database.?, c.SQLITE_LIMIT_EXPR_DEPTH, protocol.max_json_depth);
        try setLimit(database.?, c.SQLITE_LIMIT_COMPOUND_SELECT, 4);
        try setLimit(database.?, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
        try setLimit(database.?, c.SQLITE_LIMIT_VARIABLE_NUMBER, 16);
        try setLimit(database.?, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
        try setLimit(database.?, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 4096);
        try setLimit(database.?, c.SQLITE_LIMIT_ATTACHED, 0);
        try setLimit(database.?, c.SQLITE_LIMIT_WORKER_THREADS, 0);
        try dbConfig(database.?, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
        try dbConfig(database.?, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
        if (existing) {
            try validateExisting(database.?, selector);
        }
        try exec(database.?, "PRAGMA busy_timeout=0");
        try exec(database.?, "PRAGMA foreign_keys=ON");
        try exec(database.?, "PRAGMA mmap_size=0");
        try exec(database.?, "PRAGMA temp_store=FILE");
        var cache_size_buffer: [64:0]u8 = undefined;
        const cache_size = try std.fmt.bufPrintZ(&cache_size_buffer, "PRAGMA cache_size=-{d}", .{options.cache_kib});
        try exec(database.?, cache_size);
        try exec(database.?, if (options.cache_spill) "PRAGMA cache_spill=ON" else "PRAGMA cache_spill=OFF");
        try exec(database.?, "PRAGMA synchronous=EXTRA");
        if (@import("builtin").os.tag == .macos) try exec(database.?, "PRAGMA fullfsync=ON");
        if (!existing) try bootstrap(database.?, selector);
        try exec(database.?, "PRAGMA journal_mode=DELETE");

        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        return .{ .io = io, .database = database.?, .selector = stored_selector };
    }

    pub fn sqliteDiagnostic(self: *Store) SqliteDiagnostic {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var result: SqliteDiagnostic = .{};
        var current: c.sqlite3_int64 = 0;
        var highwater: c.sqlite3_int64 = 0;
        if (c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &current, &highwater, 0) == c.SQLITE_OK and
            current >= 0 and highwater >= 0)
        {
            result.process_memory_current_bytes = @intCast(current);
            result.process_memory_highwater_bytes = @intCast(highwater);
        }

        var cache_used: c_int = 0;
        var unused_highwater: c_int = 0;
        if (c.sqlite3_db_status(
            self.database,
            c.SQLITE_DBSTATUS_CACHE_USED,
            &cache_used,
            &unused_highwater,
            0,
        ) == c.SQLITE_OK and cache_used >= 0) {
            result.cache_used_bytes = @intCast(cache_used);
        }
        var spills: c_int = 0;
        if (c.sqlite3_db_status(
            self.database,
            c.SQLITE_DBSTATUS_CACHE_SPILL,
            &spills,
            &unused_highwater,
            0,
        ) == c.SQLITE_OK and spills >= 0) {
            result.cache_spills = @intCast(spills);
        }

        const hard_heap_limit = c.sqlite3_hard_heap_limit64(-1);
        if (hard_heap_limit >= 0) result.hard_heap_limit_bytes = @intCast(hard_heap_limit);
        result.page_size_bytes = diagnosticUnsignedPragma(self.database, "PRAGMA page_size");
        result.cache_size_setting = diagnosticSignedPragma(self.database, "PRAGMA cache_size");
        result.cache_spill_threshold = diagnosticSignedPragma(self.database, "PRAGMA cache_spill");
        result.mmap_size_bytes = diagnosticUnsignedPragma(self.database, "PRAGMA mmap_size");
        result.synchronous = diagnosticSignedPragma(self.database, "PRAGMA synchronous");
        result.temp_store = diagnosticSignedPragma(self.database, "PRAGMA temp_store");
        result.busy_timeout_ms = diagnosticUnsignedPragma(self.database, "PRAGMA busy_timeout");
        result.journal_mode = diagnosticTextPragma(self.database, "PRAGMA journal_mode");
        return result;
    }

    pub fn close(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        const close_result = c.sqlite3_close(self.database);
        self.mutex.unlock(self.io);
        if (close_result != c.SQLITE_OK) return error.StoreCloseFailed;
        _ = c.sqlite3_hard_heap_limit64(0);
        self.* = undefined;
    }

    pub fn validateRetryWaits(self: *Store, waits_ms: [3]u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms = try readUnixMilliseconds(self.database);
        for (waits_ms) |wait_ms| {
            if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
            _ = std.math.add(i64, now_ms, @intCast(wait_ms)) catch
                return error.InvalidRetryWait;
        }
    }

    pub fn configure(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) ConfigureReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        return self.configureLocked(command, faults) catch {
            self.finishTransactionFailure(faults);
            return .infrastructure_failure;
        };
    }

    fn configureLocked(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) !ConfigureReply {
        try exec(self.database, "BEGIN IMMEDIATE");

        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .configure or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest))
            {
                return .conflict;
            }
            if (existing.accepted) return .{ .accepted = .{
                .replayed = true,
                .revision = existing.revision,
                .created = existing.created,
            } };
            return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(ConfigurationRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
        }

        if (command.session.len == 0) {
            return try self.saveConfigurationRejection(command, &digest, .invalid_session_reference, faults);
        }
        const configuration = &command.configuration;
        if (configuration.permission_mode.state == .value and
            !configuration.permission_mode.value.eql("ask") and
            !configuration.permission_mode.value.eql("bypass"))
        {
            return try self.saveConfigurationRejection(command, &digest, .unsupported_permission_mode, faults);
        }
        if (configuration.model.state == .value and configuration.model.value.len == 0) {
            return try self.saveConfigurationRejection(command, &digest, .invalid_model, faults);
        }
        if (configuration.output_schema.state == .value and
            !try validateJsonFile(self.io, configuration.output_schema.file orelse return error.MissingContentCustody))
        {
            return try self.saveConfigurationRejection(command, &digest, .invalid_output_schema, faults);
        }

        const current = try self.readSession(command.session.slice());
        const current_configuration: ?*const CurrentConfiguration = if (current) |*value| value else null;
        const continuation_risk = if (current_configuration) |existing|
            if (configuration.model.state == .value and
                !existing.model.eql(configuration.model.value.slice()))
                try self.sessionHasContinuationRisk(command.session.slice())
            else
                false
        else
            false;
        if (configurationBeforeWorkspace(current_configuration, configuration, continuation_risk)) |rejection| {
            return try self.saveConfigurationRejection(command, &digest, rejection, faults);
        }

        var canonical_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        const canonical_workspace_ref: ?*const protocol.Bounded(protocol.max_workspace_bytes) =
            if (configuration.workspace.state == .value) canonical: {
                validateWorkspace(
                    self.io,
                    configuration.workspace.value.slice(),
                    &canonical_workspace,
                ) catch {
                    return try self.saveConfigurationRejection(command, &digest, .invalid_workspace, faults);
                };
                break :canonical &canonical_workspace;
            } else null;

        const created = current_configuration == null;
        var next = if (current_configuration) |existing| existing.* else CurrentConfiguration{};
        const content_actions = switch (planConfigurationUpdate(
            current_configuration,
            configuration,
            canonical_workspace_ref,
            &next,
        )) {
            .rejected => |rejection| return try self.saveConfigurationRejection(
                command,
                &digest,
                rejection,
                faults,
            ),
            .update => |actions| actions,
        };

        var command_instructions_id: ?i64 = null;
        switch (content_actions.instructions) {
            .preserve => {},
            .import_requested => {
                command_instructions_id = try self.importContent(&configuration.instructions, faults);
                next.instructions_id = command_instructions_id;
            },
            .default_empty => next.instructions_id = try self.importEmptyContent(),
            .clear => next.instructions_id = null,
        }
        var command_output_schema_id: ?i64 = null;
        switch (content_actions.output_schema) {
            .preserve => {},
            .import_requested => {
                command_output_schema_id = try self.importContent(&configuration.output_schema, faults);
                next.output_schema_id = command_output_schema_id;
            },
            .default_empty => next.output_schema_id = try self.importEmptyContent(),
            .clear => next.output_schema_id = null,
        }
        if (created) {
            try self.insertSession(command.session.slice(), &next);
        } else {
            try self.updateSession(command.session.slice(), &next);
        }
        try self.insertRevision(
            command.session.slice(),
            command.key.slice(),
            &next,
            created or configuration.instructions.state == .value,
        );
        const answer = StoredAnswer{
            .accepted = true,
            .revision = next.revision,
            .created = created,
        };
        try self.insertCommand(
            command.key.slice(),
            .configure,
            command.session.slice(),
            &digest,
            command_instructions_id,
            command_output_schema_id,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{ .replayed = false, .revision = next.revision, .created = created } };
    }

    fn saveConfigurationRejection(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        digest: *const [32]u8,
        code: ConfigurationRejection,
        faults: Faults,
    ) !ConfigureReply {
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try self.insertCommand(
            command.key.slice(),
            .configure,
            command.session.slice(),
            digest,
            null,
            null,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    fn sessionHasContinuationRisk(self: *Store, session_ref: []const u8) !bool {
        const statement = try prepare(self.database, continuation_risk_sql);
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.ContinuationReadFailed,
        };
    }

    pub fn submitMessage(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) MessageReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        return self.submitMessageLocked(command, faults) catch {
            self.finishTransactionFailure(faults);
            return .infrastructure_failure;
        };
    }

    fn submitMessageLocked(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) !MessageReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        const supplied_content = ContentReference{
            .length = command.text.length,
            .digest = command.text.digest,
        };
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .message or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (existing.accepted) {
                const content_id = existing.primary_content_id orelse return error.CorruptStore;
                const metadata = try self.readContentMetadata(content_id);
                const admission_id = try self.readMessageAdmission(
                    command.key.slice(),
                    command.session.slice(),
                    content_id,
                );
                return .{ .accepted = .{
                    .replayed = true,
                    .admission_id = admission_id,
                    .content = .{ .length = metadata.length, .digest = metadata.digest },
                } };
            }
            const code = std.meta.stringToEnum(MessageRejection, existing.code.slice()) orelse
                return error.CorruptStore;
            return .{ .rejected = .{ .replayed = true, .code = code, .content = supplied_content } };
        }
        const code: ?MessageRejection = if (command.session.len == 0)
            .invalid_session_reference
        else if (try self.readSession(command.session.slice()) == null)
            .unknown_session
        else
            null;
        if (code) |rejection| {
            var answer = StoredAnswer{ .accepted = false };
            try answer.code.set(@tagName(rejection));
            try self.insertCommand(
                command.key.slice(),
                .message,
                command.session.slice(),
                &digest,
                null,
                null,
                answer,
            );
            if (faults.before_commit) return error.InjectedCommitFailure;
            try exec(self.database, "COMMIT");
            return .{ .rejected = .{ .replayed = false, .code = rejection, .content = supplied_content } };
        }
        const text_id = try self.importContent(&command.text, faults);
        const metadata = try self.readContentMetadata(text_id);
        try self.insertCommand(
            command.key.slice(),
            .message,
            command.session.slice(),
            &digest,
            text_id,
            null,
            .{ .accepted = true },
        );
        const admission_id = try self.insertMessageAdmission(
            command.session.slice(),
            command.key.slice(),
            text_id,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{
            .replayed = false,
            .admission_id = admission_id,
            .content = .{ .length = metadata.length, .digest = metadata.digest },
        } };
    }

    pub fn stopSession(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        if (faults.control_trace) |trace| trace.mark(.lock_requested);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.control_trace) |trace| trace.mark(.lock_acquired);
        const result: SessionStopReply = result: {
            if (self.fenced.load(.acquire)) break :result .infrastructure_failure;
            break :result self.stopSessionLocked(command, faults) catch {
                self.finishTransactionFailure(faults);
                break :result .infrastructure_failure;
            };
        };
        if (faults.control_trace) |trace| trace.mark(.store_complete);
        return result;
    }

    fn stopSessionLocked(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) !SessionStopReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .session_stop or
                !existing.target.eql(command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (!existing.accepted) return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(SessionStopRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
            const selection = try self.readSessionStopSelection(command.key.slice());
            return .{ .accepted = .{
                .replayed = true,
                .selection = selection,
                .interrupted_operation_id = try self.readInterruptedOperation(command.key.slice()),
            } };
        }

        if (command.session.len == 0) {
            return self.saveSessionStopRejection(command, &digest, .invalid_session_reference, faults);
        }
        if (try self.readSession(command.session.slice()) == null) {
            return self.saveSessionStopRejection(command, &digest, .unknown_session, faults);
        }

        const cutoff_statement = try prepare(
            self.database,
            "SELECT coalesce(max(admission_id),0) FROM message_admission WHERE session_ref=?1",
        );
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try bindText(cutoff_statement, 1, command.session.slice());
        if (c.sqlite3_step(cutoff_statement) != c.SQLITE_ROW) return error.StopSelectionFailed;
        const cutoff_value = c.sqlite3_column_int64(cutoff_statement, 0);
        if (cutoff_value < 0) return error.CorruptStore;

        const active_statement = try prepare(
            self.database,
            "SELECT t.turn_id,t.operation_id,o.resolution_code FROM turn t " ++
                "JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE t.session_ref=?1 AND t.outcome_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(active_statement);
        try bindText(active_statement, 1, command.session.slice());
        const active_result = c.sqlite3_step(active_statement);
        var selected_turn_id: ?u64 = null;
        var current_operation_id: ?u64 = null;
        var operation_unresolved = false;
        if (active_result == c.SQLITE_ROW) {
            const turn_value = c.sqlite3_column_int64(active_statement, 0);
            const operation_value = c.sqlite3_column_int64(active_statement, 1);
            if (turn_value <= 0 or operation_value <= 0) return error.CorruptStore;
            selected_turn_id = @intCast(turn_value);
            current_operation_id = @intCast(operation_value);
            operation_unresolved = c.sqlite3_column_type(active_statement, 2) == c.SQLITE_NULL;
        } else if (active_result != c.SQLITE_DONE) return error.StopSelectionFailed;

        try self.insertCommand(
            command.key.slice(),
            .session_stop,
            command.session.slice(),
            &digest,
            null,
            null,
            .{ .accepted = true },
        );
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) VALUES(?1,?2,?3,?4)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, command.key.slice());
            try bindText(insert, 2, command.session.slice());
            try bindNullableU64(insert, 3, selected_turn_id);
            try bindI64(insert, 4, cutoff_value);
            try expectDone(insert);
        }
        var interrupted_operation_id: ?u64 = null;
        if (selected_turn_id) |turn_id| {
            if (operation_unresolved) {
                self.interruptOperation(current_operation_id.?, command.key.slice()) catch |err| {
                    return switch (err) {
                        error.InterruptionTargetChanged => error.StopSelectionChanged,
                        else => err,
                    };
                };
                interrupted_operation_id = current_operation_id;
            }
            var current = try self.readSession(command.session.slice()) orelse return error.CorruptStore;
            const cancellation_content_id = try self.importBytesContent("Cancelled by Session stop.", false, faults.content_import);
            const cancel_actions = try prepare(
                self.database,
                "WITH cancelled(action_id,acceptance_position) AS MATERIALIZED (" ++
                    "SELECT action_id,?3+row_number() OVER (ORDER BY call_ordinal)-1 FROM action_operation " ++
                    "WHERE parent_operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=0) " ++
                    "UPDATE action_operation SET resolution_code='cancelled',resolution_content_id=?2," ++
                    "acceptance_position=(SELECT acceptance_position FROM cancelled WHERE cancelled.action_id=action_operation.action_id) " ++
                    "WHERE action_id IN (SELECT action_id FROM cancelled)",
            );
            defer _ = c.sqlite3_finalize(cancel_actions);
            try bindU64(cancel_actions, 1, current_operation_id.?);
            try bindI64(cancel_actions, 2, cancellation_content_id);
            try bindU64(cancel_actions, 3, current.next_position);
            try expectDone(cancel_actions);
            const cancelled_count = c.sqlite3_changes(self.database);
            if (cancelled_count < 0) return error.CorruptStore;
            current.next_position = try std.math.add(u64, current.next_position, @intCast(cancelled_count));
            try self.updateSession(command.session.slice(), &current);
            try self.completeStoppedTurnIfReady(turn_id);
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{
            .replayed = false,
            .selection = .{
                .selected_turn_id = selected_turn_id,
                .admission_cutoff = @intCast(cutoff_value),
            },
            .interrupted_operation_id = interrupted_operation_id,
        } };
    }

    fn saveSessionStopRejection(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        digest: *const [32]u8,
        code: SessionStopRejection,
        faults: Faults,
    ) !SessionStopReply {
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try self.insertCommand(
            command.key.slice(),
            .session_stop,
            command.session.slice(),
            digest,
            null,
            null,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    pub fn interruptModel(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        if (faults.control_trace) |trace| trace.mark(.lock_requested);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.control_trace) |trace| trace.mark(.lock_acquired);
        const result: ModelInterruptionReply = result: {
            if (self.fenced.load(.acquire)) break :result .infrastructure_failure;
            break :result self.interruptModelLocked(command, faults) catch {
                self.finishTransactionFailure(faults);
                break :result .infrastructure_failure;
            };
        };
        if (faults.control_trace) |trace| trace.mark(.store_complete);
        return result;
    }

    fn interruptModelLocked(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) !ModelInterruptionReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .model_interruption or
                !existing.target.eql(command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            const saved_target = try self.readModelInterruptionTarget(command.key.slice());
            if (!saved_target.session.eql(command.session.slice()) or
                saved_target.turn_id != command.turn_id or
                saved_target.operation_id != command.operation_id) return error.CorruptStore;
            if (existing.accepted) return .{ .accepted = .{ .replayed = true } };
            return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(ModelInterruptionRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
        }

        var rejection: ?ModelInterruptionRejection = null;
        if (command.session.len == 0) {
            rejection = .invalid_session_reference;
        } else if (command.turn_id == 0 or command.operation_id == 0 or
            command.turn_id > std.math.maxInt(i64) or command.operation_id > std.math.maxInt(i64))
        {
            rejection = .invalid_target;
        } else if (try self.readSession(command.session.slice()) == null) {
            rejection = .unknown_session;
        }

        if (rejection == null) {
            const operation = try prepare(
                self.database,
                "SELECT turn_id,session_ref,resolution_code FROM model_operation WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(operation);
            try bindU64(operation, 1, command.operation_id);
            const result = c.sqlite3_step(operation);
            if (result == c.SQLITE_DONE) {
                rejection = .unknown_operation;
            } else if (result != c.SQLITE_ROW) {
                return error.InterruptionTargetReadFailed;
            } else {
                const turn_value = c.sqlite3_column_int64(operation, 0);
                var session: protocol.Bounded(protocol.max_session_bytes) = .{};
                try readText(operation, 1, &session);
                if (turn_value <= 0 or @as(u64, @intCast(turn_value)) != command.turn_id or
                    !session.eql(command.session.slice()))
                {
                    rejection = .target_mismatch;
                } else if (c.sqlite3_column_type(operation, 2) != c.SQLITE_NULL) {
                    rejection = .operation_resolved;
                }
            }
        }

        if (rejection) |code| {
            return self.saveModelInterruptionAnswer(command, &digest, false, @tagName(code), faults);
        }

        const current_turn = try prepare(
            self.database,
            "SELECT 1 FROM turn WHERE turn_id=?1 AND session_ref=?2 AND operation_id=?3 AND outcome_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(current_turn);
        try bindU64(current_turn, 1, command.turn_id);
        try bindText(current_turn, 2, command.session.slice());
        try bindU64(current_turn, 3, command.operation_id);
        const current_result = c.sqlite3_step(current_turn);
        if (current_result == c.SQLITE_DONE) {
            return self.saveModelInterruptionAnswer(
                command,
                &digest,
                false,
                @tagName(ModelInterruptionRejection.target_mismatch),
                faults,
            );
        }
        if (current_result != c.SQLITE_ROW) return error.InterruptionTargetReadFailed;

        try self.insertModelInterruptionCommand(command, &digest, .{ .accepted = true });
        try self.interruptOperation(command.operation_id, command.key.slice());
        if (!try self.hasApplicablePendingMessage(command.session.slice())) {
            const settle_turn = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='cancelled' WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(settle_turn);
            try bindU64(settle_turn, 1, command.turn_id);
            try bindU64(settle_turn, 2, command.operation_id);
            try expectDone(settle_turn);
            if (c.sqlite3_changes(self.database) != 1) return error.InterruptionTargetChanged;
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{ .replayed = false } };
    }

    // The caller owns the Store lock and transaction, including the causing command.
    fn interruptOperation(self: *Store, operation_id: u64, command_key: []const u8) !void {
        const update = try prepare(
            self.database,
            "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='interrupted'," ++
                "interrupted_by_command_key=?2 WHERE operation_id=?1 AND resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, operation_id);
        try bindText(update, 2, command_key);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.InterruptionTargetChanged;
    }

    fn saveModelInterruptionAnswer(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        digest: *const [32]u8,
        accepted: bool,
        code: []const u8,
        faults: Faults,
    ) !ModelInterruptionReply {
        var answer = StoredAnswer{ .accepted = accepted };
        try answer.code.set(code);
        try self.insertModelInterruptionCommand(command, digest, answer);
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        if (accepted) return .{ .accepted = .{ .replayed = false } };
        return .{ .rejected = .{
            .replayed = false,
            .code = std.meta.stringToEnum(ModelInterruptionRejection, code) orelse unreachable,
        } };
    }

    fn insertModelInterruptionCommand(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        digest: *const [32]u8,
        answer: StoredAnswer,
    ) !void {
        try self.insertCommand(
            command.key.slice(),
            .model_interruption,
            command.session.slice(),
            digest,
            null,
            null,
            answer,
        );
        var turn_buffer: [20]u8 = undefined;
        const turn = try std.fmt.bufPrint(&turn_buffer, "{d}", .{command.turn_id});
        var operation_buffer: [20]u8 = undefined;
        const operation = try std.fmt.bufPrint(&operation_buffer, "{d}", .{command.operation_id});
        const insert = try prepare(
            self.database,
            "INSERT INTO model_interruption_command(command_key,session_ref,turn_id,operation_id) VALUES(?1,?2,?3,?4)",
        );
        defer _ = c.sqlite3_finalize(insert);
        try bindText(insert, 1, command.key.slice());
        try bindText(insert, 2, command.session.slice());
        try bindText(insert, 3, turn);
        try bindText(insert, 4, operation);
        try expectDone(insert);
    }

    pub fn decidePermission(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        if (faults.control_trace) |trace| trace.mark(.lock_requested);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.control_trace) |trace| trace.mark(.lock_acquired);
        const result: PermissionDecisionReply = result: {
            if (self.fenced.load(.acquire)) break :result .infrastructure_failure;
            break :result self.decidePermissionLocked(command, faults) catch {
                self.finishTransactionFailure(faults);
                break :result .infrastructure_failure;
            };
        };
        if (faults.control_trace) |trace| trace.mark(.store_complete);
        return result;
    }

    pub fn denyPermission(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        return self.decidePermission(command, faults);
    }

    fn decidePermissionLocked(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) !PermissionDecisionReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .permission_decision or !existing.target.eql(command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (existing.accepted) return .{ .accepted = .{ .replayed = true } };
            return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(PermissionDecisionRejection, existing.code.slice()) orelse return error.CorruptStore,
            } };
        }
        var rejection: ?PermissionDecisionRejection = null;
        if (command.session.len == 0) rejection = .invalid_session_reference else if (command.action_id == 0 or
            command.action_id > std.math.maxInt(i64)) rejection = .invalid_target else if (try self.readSession(command.session.slice()) == null) rejection = .unknown_session;
        if (rejection == null) {
            const action = try prepare(
                self.database,
                "SELECT a.session_ref,a.permission_state,a.resolution_code,t.outcome_code FROM action_operation a " ++
                    "JOIN model_operation operation ON operation.operation_id=a.parent_operation_id " ++
                    "JOIN turn t ON t.turn_id=operation.turn_id WHERE a.action_id=?1",
            );
            defer _ = c.sqlite3_finalize(action);
            try bindU64(action, 1, command.action_id);
            const row = c.sqlite3_step(action);
            if (row == c.SQLITE_DONE) rejection = .unknown_action else if (row != c.SQLITE_ROW) return error.ActionReadFailed else {
                var session: protocol.Bounded(protocol.max_session_bytes) = .{};
                try readText(action, 0, &session);
                if (!session.eql(command.session.slice())) rejection = .target_mismatch else if (c.sqlite3_column_int(action, 1) != 0 or
                    c.sqlite3_column_type(action, 2) != c.SQLITE_NULL or
                    c.sqlite3_column_type(action, 3) != c.SQLITE_NULL) rejection = .action_not_pending;
            }
        }
        var answer = StoredAnswer{ .accepted = rejection == null };
        if (rejection) |code| try answer.code.set(@tagName(code));
        try self.insertCommand(command.key.slice(), .permission_decision, command.session.slice(), &digest, null, null, answer);
        var action_buffer: [20]u8 = undefined;
        const action_text = try std.fmt.bufPrint(&action_buffer, "{d}", .{command.action_id});
        const save = try prepare(self.database, "INSERT INTO permission_decision_command(command_key,action_id,decision) VALUES(?1,?2,?3)");
        defer _ = c.sqlite3_finalize(save);
        try bindText(save, 1, command.key.slice());
        try bindText(save, 2, action_text);
        try bindText(save, 3, @tagName(command.decision));
        try expectDone(save);
        if (rejection == null) {
            switch (command.decision) {
                .allow_once => {
                    const update = try prepare(
                        self.database,
                        "UPDATE action_operation SET permission_state=1 WHERE action_id=?1 AND permission_state=0 AND resolution_code IS NULL",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, command.action_id);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
                },
                .deny => {
                    var current = try self.readSession(command.session.slice()) orelse return error.CorruptStore;
                    const result_content_id = try self.importBytesContent("Permission denied.", false, faults.content_import);
                    const update = try prepare(
                        self.database,
                        "UPDATE action_operation SET permission_state=2,resolution_code='denied',resolution_content_id=?2,acceptance_position=?3 " ++
                            "WHERE action_id=?1 AND permission_state=0 AND resolution_code IS NULL",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, command.action_id);
                    try bindI64(update, 2, result_content_id);
                    try bindU64(update, 3, current.next_position);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
                    current.next_position = try std.math.add(u64, current.next_position, 1);
                    try self.updateSession(command.session.slice(), &current);
                },
            }
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        if (rejection) |code| return .{ .rejected = .{ .replayed = false, .code = code } };
        return .{ .accepted = .{ .replayed = false } };
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const existing = self.readExistingCommand(key) catch |err| return self.fenceReadFailure(err);
        const command = existing orelse return .{ .status = .absent };
        var observation = CommandObservation{
            .status = if (command.accepted) .accepted else .rejected,
            .kind = command.kind,
            .revision = command.revision,
            .created = command.created,
        };
        observation.target = command.target;
        observation.code = command.code;
        if (command.kind == .message and command.accepted) {
            const content_id = command.primary_content_id orelse
                return self.fenceReadFailure(error.CorruptStore);
            const metadata = self.readContentMetadata(content_id) catch |err|
                return self.fenceReadFailure(err);
            observation.message = .{
                .content = .{ .length = metadata.length, .digest = metadata.digest },
                .queue = self.readMessageQueue(
                    key,
                    command.target.slice(),
                    content_id,
                    command.accepted,
                ) catch |err| return self.fenceReadFailure(err),
            };
        } else if (command.kind == .session_stop and command.accepted) {
            const selection = self.readSessionStopSelection(key) catch |err|
                return self.fenceReadFailure(err);
            observation.session_stop = .{
                .selection = selection,
                .completion = if (selection.selected_turn_id) |turn_id|
                    if (self.turnIsComplete(turn_id) catch |err| return self.fenceReadFailure(err))
                        .completed
                    else
                        .pending
                else
                    .completed,
            };
        } else if (command.kind == .model_interruption) {
            observation.model_interruption = self.readModelInterruptionTarget(key) catch |err|
                return self.fenceReadFailure(err);
        } else if (command.kind == .permission_decision) {
            const target = self.readPermissionTarget(key) catch |err|
                return self.fenceReadFailure(err);
            observation.permission_action_id = target.action_id;
            observation.permission_decision = target.decision;
        }
        return observation;
    }

    fn readMessageQueue(
        self: *Store,
        command_key: []const u8,
        session_ref: []const u8,
        content_id: i64,
        accepted: bool,
    ) !?AcceptedMessageQueue {
        const statement = try prepare(
            self.database,
            "SELECT m.session_ref,m.content_id,m.admission_id,m.command_key,m.turn_id,t.operation_id,o.attempt_ordinal," ++
                "t.outcome_code,t.outcome_content_id,CASE WHEN m.turn_id IS NULL THEN (" ++
                "SELECT stopped.command_key FROM session_stop stopped JOIN core_command stop_command " ++
                "ON stop_command.command_key=stopped.command_key WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff ORDER BY stop_command.rowid LIMIT 1) END " ++
                "FROM message_admission m " ++
                "LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
                "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE m.command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return if (accepted) error.CorruptStore else null;
        if (step != c.SQLITE_ROW) return error.CorruptStore;
        if (!accepted) return error.CorruptStore;
        var stop_key: protocol.Bounded(128) = .{};
        const excluding_stop = if (c.sqlite3_column_type(statement, 9) == c.SQLITE_NULL)
            null
        else blk: {
            try readText(statement, 9, &stop_key);
            break :blk stop_key.slice();
        };
        const projection = try readMessageProjectionRow(statement, excluding_stop);
        if (!projection.session.eql(session_ref) or projection.content_id != content_id or
            !projection.command_key.eql(command_key)) return error.CorruptStore;
        return switch (projection.state) {
            .pending => .{ .admission_id = projection.admission_id, .state = .queued },
            .excluded => blk: {
                var code: protocol.Bounded(96) = .{};
                try code.set("session_stopped");
                break :blk .{ .admission_id = projection.admission_id, .state = .{ .excluded = .{ .code = code } } };
            },
            .applied => |applied| blk: {
                const outcome = applied.outcome_code orelse
                    break :blk .{ .admission_id = projection.admission_id, .state = .{ .processing = applied.binding } };
                if (outcome.eql("completed")) {
                    const answer = try self.readContentMetadata(applied.outcome_content_id orelse return error.CorruptStore);
                    break :blk .{ .admission_id = projection.admission_id, .state = .{ .completed = .{
                        .binding = applied.binding,
                        .answer = .{ .length = answer.length, .digest = answer.digest },
                    } } };
                }
                if (applied.outcome_content_id != null) return error.CorruptStore;
                break :blk if (outcome.eql("cancelled"))
                    .{ .admission_id = projection.admission_id, .state = .{ .cancelled = .{ .binding = applied.binding, .code = outcome } } }
                else
                    .{ .admission_id = projection.admission_id, .state = .{ .failed = .{ .binding = applied.binding, .code = outcome } } };
            },
        };
    }

    pub fn commandResult(self: *Store, key: []const u8) !ContentReference {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = try prepare(
            self.database,
            "SELECT t.outcome_code,t.outcome_content_id,EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff) FROM core_command command " ++
                "JOIN message_admission m ON m.command_key=command.command_key " ++
                "LEFT JOIN turn t ON t.turn_id=m.turn_id WHERE command.command_key=?1 AND command.kind=2 AND command.accepted=1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ResultNotFound;
        if (c.sqlite3_column_int(statement, 2) != 0 and c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) {
            return error.ResultFailed;
        }
        if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return error.ResultNotReady;
        var outcome: protocol.Bounded(96) = .{};
        try readText(statement, 0, &outcome);
        if (!outcome.eql("completed")) return error.ResultFailed;
        const content_id = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        const metadata = try self.readContentMetadata(content_id);
        return .{ .length = metadata.length, .digest = metadata.digest };
    }

    pub fn inspectSession(self: *Store, session_ref: []const u8) !SessionObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const maybe_current = self.readSession(session_ref) catch |err| return self.fenceReadFailure(err);
        const current = maybe_current orelse return .{};
        var observation = SessionObservation{
            .found = true,
            .revision = current.revision,
            .tools_mask = current.tools_mask,
        };
        try observation.session.set(session_ref);
        observation.workspace = current.workspace;
        observation.model = current.model;
        try observation.permission_mode.set(if (current.permission_mode == 0) "ask" else "bypass");
        if (current.instructions_id) |content_id| {
            const metadata = self.readContentMetadata(content_id) catch |err| return self.fenceReadFailure(err);
            observation.instructions = .{ .length = metadata.length, .digest = metadata.digest };
        }
        if (current.output_schema_id) |content_id| {
            const metadata = self.readContentMetadata(content_id) catch |err| return self.fenceReadFailure(err);
            observation.output_schema = .{ .length = metadata.length, .digest = metadata.digest };
        }
        observation.pending_messages = self.countPendingMessages(session_ref) catch |err|
            return self.fenceReadFailure(err);
        self.validateActiveTurnToolCalls(session_ref) catch |err|
            return self.fenceReadFailure(err);
        observation.action_count = self.countActions(session_ref) catch |err|
            return self.fenceReadFailure(err);
        observation.rejected_call_count = self.countRejectedCalls(session_ref) catch |err|
            return self.fenceReadFailure(err);
        return observation;
    }

    pub fn captureSessionReport(
        self: *Store,
        session_ref: []const u8,
        options: SessionReportOptions,
    ) !SessionReport {
        var capture = try SessionReportCapture.init(self.io, options);
        errdefer capture.deinit();
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        const capture_result = self.renderSessionReportLocked(session_ref, options.profile, options.execution, &capture);
        capture_result catch |err| {
            if (!capture.ordinary_failure) self.fenced.store(true, .release);
            self.mutex.unlock(self.io);
            return err;
        };
        self.mutex.unlock(self.io);
        return capture.seal();
    }

    fn renderSessionReportLocked(
        self: *Store,
        session_ref: []const u8,
        profile: protocol.ReportProfile,
        execution: SessionReportExecution,
        capture: *SessionReportCapture,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const maybe_current = try self.readSession(session_ref);
        try capture.append("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"");
        try capture.append(@tagName(profile));
        try capture.append("\",\"session\":");
        const current = maybe_current orelse {
            try capture.append("null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}");
            return;
        };
        const instructions = try self.readContentMetadata(current.instructions_id orelse return error.CorruptStore);
        const output_schema = if (current.output_schema_id) |content_id|
            try self.readContentMetadata(content_id)
        else
            null;
        const pending_messages = try self.countPendingMessages(session_ref);
        try self.validateActiveTurnToolCalls(session_ref);
        const action_count = try self.countActions(session_ref);
        const rejected_call_count = try self.countRejectedCalls(session_ref);

        try capture.append("{\"reference\":");
        try capture.appendJsonString(session_ref);
        try capture.append(",\"workspace\":");
        try capture.appendJsonString(current.workspace.slice());
        try capture.append(",\"model\":");
        try capture.appendJsonString(current.model.slice());
        try capture.appendFmt(",\"revision\":\"{d}\",\"tools\":", .{current.revision});
        try capture.appendTools(current.tools_mask);
        try capture.append(",\"permission_mode\":");
        try capture.appendPermissionMode(current.permission_mode);
        try capture.append(",\"instructions\":");
        try capture.appendBareContentReference(.{ .length = instructions.length, .digest = instructions.digest });
        try capture.append(",\"output_schema\":");
        if (output_schema) |reference| {
            try capture.appendBareContentReference(.{ .length = reference.length, .digest = reference.digest });
        } else {
            try capture.append("null");
        }
        try capture.appendFmt("}},\"pending_messages\":\"{d}\",\"work\":", .{pending_messages});
        try self.appendCurrentWork(session_ref, pending_messages, capture);
        try capture.appendFmt(",\"actions\":{{\"count\":\"{d}\",\"unresolved\":[", .{
            action_count,
        });
        try self.appendUnresolvedActions(session_ref, capture);
        try capture.append("],\"resolved\":[");
        try self.appendResolvedActions(session_ref, capture);
        try capture.appendFmt("]}},\"rejected_calls\":{{\"count\":\"{d}\",\"items\":[", .{rejected_call_count});
        try self.appendRejectedCalls(session_ref, capture);
        try capture.append("]},\"actionable_permissions\":[");
        try self.appendActionablePermissions(session_ref, capture);
        try capture.append("]");
        if (profile == .full) {
            try capture.append(",\"full\":{\"session_revisions\":[");
            try self.appendSessionRevisions(session_ref, capture);
            try capture.append("],\"messages\":[");
            try self.appendMessages(session_ref, capture);
            try capture.append("],\"conversation\":[");
            try self.appendConversation(session_ref, capture);
            try capture.append("],\"turns\":[");
            try self.appendTurns(session_ref, capture);
            try capture.append("],\"model_operations\":[");
            try self.appendModelOperations(session_ref, capture);
            try capture.append("],\"tool_calls\":[");
            try self.appendToolCalls(session_ref, capture);
            try capture.append("],\"actions\":[");
            try self.appendAllActions(session_ref, capture);
            try capture.append("],\"permission_decisions\":[");
            try self.appendPermissionDecisions(session_ref, capture);
            try capture.append("],\"session_stops\":[");
            try self.appendSessionStops(session_ref, capture);
            try capture.append("],\"model_interruptions\":[");
            try self.appendModelInterruptions(session_ref, capture);
            try capture.append("],\"tool_results\":[");
            try self.appendToolResults(session_ref, capture);
            try capture.append("]}");
        }
        try capture.appendFmt(",\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":{s},\"custody_occupied\":\"{d}\",\"scratch_used_bytes\":\"{d}\",\"unavailable\":[\"structured_output\"]}}}}", .{
            if (execution.dispatch_fenced) "true" else "false",
            execution.custody_occupied,
            execution.scratch_used_bytes,
        });
    }

    fn appendCurrentWork(self: *Store, session_ref: []const u8, pending_messages: u64, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.resolution_code " ++
                "FROM turn t JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE t.session_ref=?1 ORDER BY t.turn_id DESC LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return capture.append(if (pending_messages == 0)
            "{\"status\":\"idle\",\"latest_outcome\":null}"
        else
            "{\"status\":\"runnable\",\"latest_outcome\":null}");
        if (result != c.SQLITE_ROW) return error.TurnReadFailed;
        const turn_id = c.sqlite3_column_int64(statement, 0);
        const operation_id = c.sqlite3_column_int64(statement, 1);
        if (turn_id <= 0 or operation_id <= 0) return error.CorruptStore;
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) {
            const actionable = try self.countActionablePermissions(session_ref);
            const unresolved_actions = try self.countUnresolvedActiveActions(session_ref);
            var status: []const u8 = "in_flight";
            if (c.sqlite3_column_type(statement, 4) != c.SQLITE_NULL) {
                var resolution: protocol.Bounded(96) = .{};
                try readText(statement, 4, &resolution);
                status = if (resolution.eql("continued") or resolution.eql("interrupted"))
                    "runnable"
                else if (resolution.eql("tool_calls") and actionable != 0)
                    "waiting_for_permission"
                else if (resolution.eql("tool_calls") and unresolved_actions == 0)
                    "runnable"
                else
                    "in_flight";
            }
            return capture.appendFmt("{{\"status\":\"{s}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"latest_outcome\":null}}", .{ status, turn_id, operation_id });
        }
        var code: protocol.Bounded(96) = .{};
        try readText(statement, 2, &code);
        const status = if (pending_messages != 0)
            "runnable"
        else if (code.eql("completed"))
            "completed"
        else if (code.eql("cancelled"))
            "cancelled"
        else
            "failed";
        try capture.append("{\"status\":");
        try capture.appendJsonString(status);
        try capture.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"latest_outcome\":{{\"code\":", .{ turn_id, operation_id });
        try capture.appendJsonString(code.slice());
        try capture.append(",\"content\":");
        if (try readNullablePositiveI64(statement, 3)) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
        } else {
            try capture.append("null");
        }
        try capture.append("}}");
    }

    fn countActionablePermissions(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(
            self.database,
            "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
                "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL " ++
                "AND action.permission_state=0 AND action.resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ActionReadFailed;
        const count = c.sqlite3_column_int64(statement, 0);
        if (count < 0) return error.CorruptStore;
        return @intCast(count);
    }

    fn countUnresolvedActiveActions(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(
            self.database,
            "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
                "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND action.resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ActionReadFailed;
        const count = c.sqlite3_column_int64(statement, 0);
        if (count < 0) return error.CorruptStore;
        return @intCast(count);
    }

    fn appendActionablePermissions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT action.action_id,action.permission_revision FROM turn active INDEXED BY turn_one_active_per_session " ++
                "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL " ++
                "AND action.permission_state=0 AND action.resolution_code IS NULL ORDER BY action.action_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.ActionReadFailed)) {
            const action_id = c.sqlite3_column_int64(statement, 0);
            const revision = c.sqlite3_column_int64(statement, 1);
            if (action_id <= 0 or revision <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"action\":\"{d}\",\"permission_revision\":\"{d}\"}}", .{ action_id, revision });
        }
    }

    fn appendUnresolvedActions(
        self: *Store,
        session_ref: []const u8,
        capture: *SessionReportCapture,
    ) !void {
        const statement = try prepare(
            self.database,
            "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.permission_revision,a.permission_state," ++
                "call_id.byte_length,call_id.digest,arguments.byte_length,arguments.digest," ++
                "decision.command_key " ++
                "FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN action_operation a ON a.parent_operation_id=active.operation_id " ++
                "CROSS JOIN model_tool_call call ON call.operation_id=a.parent_operation_id " ++
                "AND call.call_ordinal=a.call_ordinal CROSS JOIN content call_id " ++
                "ON call_id.content_id=call.call_id_content_id CROSS JOIN content arguments " ++
                "ON arguments.content_id=call.arguments_content_id LEFT JOIN permission_decision_command decision " ++
                "ON decision.action_id=CAST(a.action_id AS TEXT) AND decision.decision='allow_once' " ++
                "AND EXISTS(SELECT 1 FROM core_command command WHERE command.command_key=decision.command_key " ++
                "AND command.kind=5 AND command.accepted=1) " ++
                "WHERE active.session_ref=?1 " ++
                "AND active.outcome_code IS NULL AND a.permission_state IN (0,1) " ++
                "AND a.resolution_code IS NULL ORDER BY a.action_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return;
            if (result != c.SQLITE_ROW) return error.ActionReadFailed;
            const action_id = c.sqlite3_column_int64(statement, 0);
            const parent = c.sqlite3_column_int64(statement, 1);
            const ordinal = c.sqlite3_column_int64(statement, 2);
            const revision = c.sqlite3_column_int64(statement, 3);
            const permission = c.sqlite3_column_int(statement, 4);
            const call_id_length = c.sqlite3_column_int64(statement, 5);
            const arguments_length = c.sqlite3_column_int64(statement, 7);
            if (action_id <= 0 or parent <= 0 or ordinal < 0 or revision <= 0 or
                permission < 0 or permission > 1 or call_id_length < 0 or arguments_length < 0)
            {
                return error.CorruptStore;
            }
            if (!first) try capture.append(",");
            first = false;
            try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"tool\":\"bash\",\"permission_revision\":\"{d}\",\"authorization\":\"{s}\",\"call_id\":", .{
                action_id,
                parent,
                ordinal,
                revision,
                if (permission == 0) "pending" else if (c.sqlite3_column_type(statement, 9) == c.SQLITE_NULL) "bypass" else "allow_once",
            });
            try capture.appendContentReference(.{
                .length = @intCast(call_id_length),
                .digest = try readDigest(statement, 6),
            });
            try capture.append(",\"arguments\":");
            try capture.appendContentReference(.{
                .length = @intCast(arguments_length),
                .digest = try readDigest(statement, 8),
            });
            try capture.append("}");
        }
    }

    fn appendResolvedActions(
        self: *Store,
        session_ref: []const u8,
        capture: *SessionReportCapture,
    ) !void {
        const statement = try prepare(
            self.database,
            "SELECT a.action_id,a.parent_operation_id,a.call_ordinal,a.resolution_code,a.acceptance_position," ++
                "result.byte_length,result.digest FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "CROSS JOIN action_operation a ON a.parent_operation_id=operation.operation_id " ++
                "CROSS JOIN content result ON result.content_id=a.resolution_content_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND a.resolution_code IS NOT NULL " ++
                "ORDER BY a.action_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return;
            if (result != c.SQLITE_ROW) return error.ActionReadFailed;
            const action_id = c.sqlite3_column_int64(statement, 0);
            const parent = c.sqlite3_column_int64(statement, 1);
            const ordinal = c.sqlite3_column_int64(statement, 2);
            const position = c.sqlite3_column_int64(statement, 4);
            const length = c.sqlite3_column_int64(statement, 5);
            if (action_id <= 0 or parent <= 0 or ordinal < 0 or position <= 0 or length < 0) return error.CorruptStore;
            var code: protocol.Bounded(32) = .{};
            try readText(statement, 3, &code);
            if (!first) try capture.append(",");
            first = false;
            try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{
                action_id,
                parent,
                ordinal,
            });
            try capture.appendJsonString(code.slice());
            try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{position});
            try capture.appendContentReference(.{
                .length = @intCast(length),
                .digest = try readDigest(statement, 6),
            });
            try capture.append("}");
        }
    }

    fn appendRejectedCalls(
        self: *Store,
        session_ref: []const u8,
        capture: *SessionReportCapture,
    ) !void {
        const statement = try prepare(
            self.database,
            "SELECT call.operation_id,call.call_ordinal,call.rejection_code,call.acceptance_position," ++
                "rejection.byte_length,rejection.digest," ++
                "item_id.byte_length,item_id.digest,name.byte_length,name.digest," ++
                "call_id.byte_length,call_id.digest,arguments.byte_length,arguments.digest " ++
                "FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "CROSS JOIN model_tool_call call ON call.operation_id=operation.operation_id " ++
                "CROSS JOIN content item_id ON item_id.content_id=call.item_id_content_id " ++
                "CROSS JOIN content name ON name.content_id=call.name_content_id " ++
                "CROSS JOIN content call_id ON call_id.content_id=call.call_id_content_id " ++
                "CROSS JOIN content arguments ON arguments.content_id=call.arguments_content_id " ++
                "CROSS JOIN content rejection ON rejection.content_id=call.rejection_content_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND call.rejection_code IS NOT NULL " ++
                "ORDER BY call.operation_id,call.call_ordinal",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return;
            if (result != c.SQLITE_ROW) return error.CallReadFailed;
            const operation_id = c.sqlite3_column_int64(statement, 0);
            const call_ordinal = c.sqlite3_column_int64(statement, 1);
            const acceptance_position = c.sqlite3_column_int64(statement, 3);
            const rejection_length = c.sqlite3_column_int64(statement, 4);
            if (operation_id <= 0 or call_ordinal < 0 or acceptance_position <= 0 or rejection_length < 0) return error.CorruptStore;
            var code: protocol.Bounded(32) = .{};
            try readText(statement, 2, &code);
            if (!first) try capture.append(",");
            first = false;
            try capture.appendFmt("{{\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"code\":", .{
                operation_id,
                call_ordinal,
            });
            try capture.appendJsonString(code.slice());
            try capture.appendFmt(",\"acceptance_position\":\"{d}\",\"result\":", .{acceptance_position});
            try capture.appendContentReference(.{
                .length = @intCast(rejection_length),
                .digest = try readDigest(statement, 5),
            });
            inline for (.{
                .{ "item_id", 6, 7 },
                .{ "name", 8, 9 },
                .{ "call_id", 10, 11 },
                .{ "arguments", 12, 13 },
            }) |field| {
                const length = c.sqlite3_column_int64(statement, field[1]);
                if (length < 0) return error.CorruptStore;
                try capture.append(",\"");
                try capture.append(field[0]);
                try capture.append("\":");
                try capture.appendContentReference(.{
                    .length = @intCast(length),
                    .digest = try readDigest(statement, field[2]),
                });
            }
            try capture.append("}");
        }
    }

    fn appendSessionRevisions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "WITH occurrence(revision,field_order,content_id) AS MATERIALIZED (" ++
                "SELECT revision,0,instructions_content_id FROM session_revision WHERE session_ref=?1 UNION ALL " ++
                "SELECT revision,1,output_schema_content_id FROM session_revision WHERE session_ref=?1 AND output_schema_content_id IS NOT NULL)," ++
                "ownership AS MATERIALIZED (SELECT revision,field_order,content_id," ++
                "first_value(revision) OVER (PARTITION BY content_id ORDER BY revision,field_order) owner_revision," ++
                "first_value(field_order) OVER (PARTITION BY content_id ORDER BY revision,field_order) owner_field FROM occurrence) " ++
                "SELECT revision_row.revision,revision_row.command_key,revision_row.workspace,revision_row.model," ++
                "revision_row.tools_mask,revision_row.permission_mode,revision_row.instructions_content_id,revision_row.output_schema_content_id," ++
                "instructions.owner_revision,instructions.owner_field,output_schema.owner_revision,output_schema.owner_field " ++
                "FROM session_revision revision_row JOIN ownership instructions ON instructions.revision=revision_row.revision AND instructions.field_order=0 " ++
                "LEFT JOIN ownership output_schema ON output_schema.revision=revision_row.revision AND output_schema.field_order=1 " ++
                "WHERE revision_row.session_ref=?1 ORDER BY revision_row.revision",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.SessionReadFailed)) {
            const revision = c.sqlite3_column_int64(statement, 0);
            const tools = c.sqlite3_column_int(statement, 4);
            const permission = c.sqlite3_column_int(statement, 5);
            const instructions_id = c.sqlite3_column_int64(statement, 6);
            if (revision <= 0 or tools < 0 or tools > 3 or permission < 0 or permission > 1 or instructions_id <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"revision\":\"{d}\",\"command_key\":", .{revision});
            try appendColumnString(statement, 1, 128, capture);
            try capture.append(",\"workspace\":");
            try appendColumnString(statement, 2, protocol.max_workspace_bytes, capture);
            try capture.append(",\"model\":");
            try appendColumnString(statement, 3, protocol.max_model_bytes, capture);
            try capture.append(",\"tools\":");
            try capture.appendTools(@intCast(tools));
            try capture.append(",\"permission_mode\":");
            try capture.appendPermissionMode(@intCast(permission));
            try capture.append(",\"instructions\":");
            try self.appendRevisionContent(
                instructions_id,
                revision,
                .instructions,
                c.sqlite3_column_int64(statement, 8),
                c.sqlite3_column_int(statement, 9),
                capture,
            );
            try capture.append(",\"output_schema\":");
            if (try readNullablePositiveI64(statement, 7)) |content_id| {
                if (c.sqlite3_column_type(statement, 10) == c.SQLITE_NULL or c.sqlite3_column_type(statement, 11) == c.SQLITE_NULL) return error.CorruptStore;
                try self.appendRevisionContent(
                    content_id,
                    revision,
                    .output_schema,
                    c.sqlite3_column_int64(statement, 10),
                    c.sqlite3_column_int(statement, 11),
                    capture,
                );
            } else {
                if (c.sqlite3_column_type(statement, 10) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 11) != c.SQLITE_NULL) return error.CorruptStore;
                try capture.append("null");
            }
            try capture.append("}");
        }
    }

    fn appendRevisionContent(
        self: *Store,
        content_id: i64,
        revision: i64,
        field: RevisionContentField,
        owner_revision: i64,
        owner_field_value: c_int,
        capture: *SessionReportCapture,
    ) !void {
        if (content_id <= 0 or revision <= 0 or owner_revision <= 0 or owner_revision > revision) return error.CorruptStore;
        const owner_field: RevisionContentField = switch (owner_field_value) {
            0 => .instructions,
            1 => .output_schema,
            else => return error.CorruptStore,
        };
        if (owner_revision == revision and @intFromEnum(owner_field) > @intFromEnum(field)) return error.CorruptStore;
        if (owner_revision == revision and owner_field == field) return self.appendInlineContent(content_id, capture);
        const metadata = try self.readContentMetadata(content_id);
        try capture.appendOwnedContentReference(
            .{ .length = metadata.length, .digest = metadata.digest },
            owner_revision,
            owner_field,
        );
    }

    fn appendMessages(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT m.session_ref,m.content_id,m.admission_id,m.command_key,m.turn_id,t.operation_id,o.attempt_ordinal," ++
                "t.outcome_code,t.outcome_content_id " ++
                "FROM message_admission m LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
                "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE m.session_ref=?1 ORDER BY m.admission_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const stops = try prepare(
            self.database,
            "SELECT stopped.command_key,stopped.admission_cutoff FROM session_stop stopped " ++
                "JOIN core_command command ON command.command_key=stopped.command_key " ++
                "WHERE stopped.session_ref=?1 ORDER BY command.rowid",
        );
        defer _ = c.sqlite3_finalize(stops);
        try bindText(stops, 1, session_ref);
        var stop_result = c.sqlite3_step(stops);
        if (stop_result != c.SQLITE_ROW and stop_result != c.SQLITE_DONE) return error.SessionStopReadFailed;
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.MessageReadFailed)) {
            const admission_id = c.sqlite3_column_int64(statement, 2);
            if (admission_id <= 0) return error.CorruptStore;
            var excluding_key: protocol.Bounded(128) = .{};
            var excluding_stop: ?[]const u8 = null;
            if (c.sqlite3_column_type(statement, 4) == c.SQLITE_NULL) {
                while (stop_result == c.SQLITE_ROW) {
                    const cutoff = c.sqlite3_column_int64(stops, 1);
                    if (cutoff < 0) return error.CorruptStore;
                    if (cutoff >= admission_id) {
                        try readText(stops, 0, &excluding_key);
                        excluding_stop = excluding_key.slice();
                        break;
                    }
                    stop_result = c.sqlite3_step(stops);
                    if (stop_result != c.SQLITE_ROW and stop_result != c.SQLITE_DONE) return error.SessionStopReadFailed;
                }
            }
            const projection = try readMessageProjectionRow(statement, excluding_stop);
            if (!projection.session.eql(session_ref)) return error.CorruptStore;
            try capture.appendFmt("{{\"admission\":\"{d}\",\"command_key\":", .{projection.admission_id});
            try capture.appendJsonString(projection.command_key.slice());
            try capture.append(",\"content\":");
            try self.appendInlineContent(projection.content_id, capture);
            try capture.append(",\"turn\":");
            switch (projection.state) {
                .applied => |applied| try capture.appendFmt("\"{d}\"", .{applied.binding.turn_id}),
                .pending, .excluded => try capture.append("null"),
            }
            try capture.append(",\"application\":");
            try capture.appendJsonString(@tagName(projection.state));
            try capture.append(",\"exclusion\":");
            switch (projection.state) {
                .excluded => |stop_key| {
                    try capture.append("{\"code\":\"session_stopped\",\"command_key\":");
                    try capture.appendJsonString(stop_key.slice());
                    try capture.append("}");
                },
                .pending, .applied => try capture.append("null"),
            }
            try capture.append(",\"outcome\":");
            switch (projection.state) {
                .applied => |applied| if (applied.outcome_code) |code| {
                    try capture.append("{\"code\":");
                    try capture.appendJsonString(code.slice());
                    try capture.append(",\"content\":");
                    if (applied.outcome_content_id) |content_id| {
                        const metadata = try self.readContentMetadata(content_id);
                        try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
                    } else try capture.append("null");
                    try capture.append("}");
                } else try capture.append("null"),
                .pending, .excluded => try capture.append("null"),
            }
            try capture.append("}");
        }
    }

    fn appendConversation(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id " ++
                "FROM conversation_entry WHERE session_ref=?1 ORDER BY entry_ordinal",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.ConversationReadFailed)) {
            const ordinal = c.sqlite3_column_int64(statement, 0);
            const position = c.sqlite3_column_int64(statement, 1);
            const kind = c.sqlite3_column_int(statement, 2);
            const turn_id = c.sqlite3_column_int64(statement, 3);
            const content_id = c.sqlite3_column_int64(statement, 7);
            if (ordinal <= 0 or position <= 0 or kind < 1 or kind > 3 or turn_id <= 0 or content_id <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"ordinal\":\"{d}\",\"position\":\"{d}\",\"kind\":\"{s}\",\"turn\":\"{d}\",\"source_admission\":", .{ ordinal, position, switch (kind) {
                1 => "message",
                2 => "settings",
                3 => "assistant",
                else => unreachable,
            }, turn_id });
            try appendNullablePositiveInteger(statement, 4, capture);
            try capture.append(",\"source_revision\":");
            try appendNullablePositiveInteger(statement, 5, capture);
            try capture.append(",\"source_operation\":");
            try appendNullablePositiveInteger(statement, 6, capture);
            try capture.append(",\"content\":");
            const metadata = try self.readContentMetadata(content_id);
            try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
            try capture.append("}");
        }
    }

    fn appendTurns(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT turn_id,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id FROM turn WHERE session_ref=?1 ORDER BY turn_id");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.TurnReadFailed)) {
            const turn_id = c.sqlite3_column_int64(statement, 0);
            const first_admission = c.sqlite3_column_int64(statement, 1);
            const cutoff = c.sqlite3_column_int64(statement, 2);
            const operation = c.sqlite3_column_int64(statement, 3);
            if (turn_id <= 0 or first_admission <= 0 or cutoff < first_admission or operation <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"turn\":\"{d}\",\"first_admission\":\"{d}\",\"input_cutoff\":\"{d}\",\"operation\":\"{d}\",\"outcome\":", .{ turn_id, first_admission, cutoff, operation });
            try self.appendReferencedOutcome(statement, 4, 5, capture);
            try capture.append("}");
        }
    }

    fn appendModelOperations(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT operation_id,turn_id,resolution_code,resolution_content_id,interrupted_by_command_key FROM model_operation WHERE session_ref=?1 ORDER BY operation_id");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.OperationReadFailed)) {
            const operation = c.sqlite3_column_int64(statement, 0);
            const turn_id = c.sqlite3_column_int64(statement, 1);
            if (operation <= 0 or turn_id <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"operation\":\"{d}\",\"turn\":\"{d}\",\"resolution\":", .{ operation, turn_id });
            try self.appendInlineOutcome(statement, 2, 3, capture);
            try capture.append(",\"interrupted_by\":");
            try appendNullableColumnString(statement, 4, 128, capture);
            try capture.append("}");
        }
    }

    fn appendToolCalls(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT call.operation_id,call.call_ordinal,call.item_ordinal,call.rejection_code,call.acceptance_position," ++
                "call.item_id_content_id,call.name_content_id,call.call_id_content_id,call.arguments_content_id,call.rejection_content_id " ++
                "FROM model_tool_call call JOIN model_operation operation ON operation.operation_id=call.operation_id " ++
                "WHERE operation.session_ref=?1 ORDER BY call.operation_id,call.call_ordinal",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.CallReadFailed)) {
            const operation = c.sqlite3_column_int64(statement, 0);
            const ordinal = c.sqlite3_column_int64(statement, 1);
            const item = c.sqlite3_column_int64(statement, 2);
            if (operation <= 0 or ordinal < 0 or item < 0) return error.CorruptStore;
            try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"item_ordinal\":\"{d}\",\"rejection\":", .{ operation, ordinal, item });
            try appendNullableColumnString(statement, 3, 32, capture);
            try capture.append(",\"acceptance_position\":");
            try appendNullablePositiveInteger(statement, 4, capture);
            inline for (.{ .{ "item_id", 5 }, .{ "name", 6 }, .{ "call_id", 7 }, .{ "arguments", 8 } }) |field| {
                try capture.append(",\"");
                try capture.append(field[0]);
                try capture.append("\":");
                const content_id = c.sqlite3_column_int64(statement, field[1]);
                if (content_id <= 0) return error.CorruptStore;
                try self.appendInlineContent(content_id, capture);
            }
            try capture.append(",\"rejection_result\":");
            if (try readNullablePositiveI64(statement, 9)) |content_id| try self.appendInlineContent(content_id, capture) else try capture.append("null");
            try capture.append("}");
        }
    }

    fn appendAllActions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT action_id,parent_operation_id,call_ordinal,permission_revision,permission_state,resolution_code,resolution_content_id,acceptance_position FROM action_operation WHERE session_ref=?1 ORDER BY action_id");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.ActionReadFailed)) {
            const action = c.sqlite3_column_int64(statement, 0);
            const parent = c.sqlite3_column_int64(statement, 1);
            const ordinal = c.sqlite3_column_int64(statement, 2);
            const revision = c.sqlite3_column_int64(statement, 3);
            const permission = c.sqlite3_column_int(statement, 4);
            if (action <= 0 or parent <= 0 or ordinal < 0 or revision <= 0 or permission < 0 or permission > 2) return error.CorruptStore;
            try capture.appendFmt("{{\"action\":\"{d}\",\"parent_operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"permission_revision\":\"{d}\",\"permission\":\"{s}\",\"resolution\":", .{ action, parent, ordinal, revision, switch (permission) {
                0 => "requested",
                1 => "authorized",
                2 => "denied",
                else => unreachable,
            } });
            try appendNullableColumnString(statement, 5, max_action_resolution_code_bytes, capture);
            try capture.append(",\"result\":");
            if (try readNullablePositiveI64(statement, 6)) |content_id| try self.appendInlineContent(content_id, capture) else try capture.append("null");
            try capture.append(",\"acceptance_position\":");
            try appendNullablePositiveInteger(statement, 7, capture);
            try capture.append("}");
        }
    }

    fn appendPermissionDecisions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT decision.command_key,decision.action_id,decision.decision,command.accepted,command.code FROM permission_decision_command decision JOIN core_command command ON command.command_key=decision.command_key WHERE command.kind=5 AND command.target=?1 ORDER BY command.rowid");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.PermissionReadFailed)) {
            try capture.append("{\"command_key\":");
            try appendColumnString(statement, 0, 128, capture);
            try capture.append(",\"action\":");
            try appendColumnString(statement, 1, 20, capture);
            var decision_text: protocol.Bounded(max_permission_decision_bytes) = .{};
            try readText(statement, 2, &decision_text);
            const decision = std.meta.stringToEnum(protocol.PermissionDecision, decision_text.slice()) orelse return error.CorruptStore;
            try capture.appendFmt(",\"decision\":\"{s}\",\"status\":\"{s}\",\"code\":", .{
                @tagName(decision),
                if (c.sqlite3_column_int(statement, 3) == 0) "rejected" else "accepted",
            });
            try appendColumnString(statement, 4, 96, capture);
            try capture.append("}");
        }
    }

    fn appendSessionStops(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT command.command_key,command.accepted,command.code,stop.selected_turn_id,stop.admission_cutoff FROM core_command command LEFT JOIN session_stop stop ON stop.command_key=command.command_key WHERE command.kind=3 AND command.target=?1 ORDER BY command.rowid");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.SessionStopReadFailed)) {
            try capture.append("{\"command_key\":");
            try appendColumnString(statement, 0, 128, capture);
            try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{if (c.sqlite3_column_int(statement, 1) == 0) "rejected" else "accepted"});
            try appendColumnString(statement, 2, 96, capture);
            try capture.append(",\"selected_turn\":");
            try appendNullablePositiveInteger(statement, 3, capture);
            try capture.append(",\"admission_cutoff\":");
            try appendNullableNonnegativeInteger(statement, 4, capture);
            try capture.append("}");
        }
    }

    fn appendModelInterruptions(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(self.database, "SELECT command.command_key,command.accepted,command.code,interruption.turn_id,interruption.operation_id FROM model_interruption_command interruption JOIN core_command command ON command.command_key=interruption.command_key WHERE interruption.session_ref=?1 ORDER BY command.rowid");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.InterruptionReadFailed)) {
            try capture.append("{\"command_key\":");
            try appendColumnString(statement, 0, 128, capture);
            try capture.appendFmt(",\"status\":\"{s}\",\"code\":", .{if (c.sqlite3_column_int(statement, 1) == 0) "rejected" else "accepted"});
            try appendColumnString(statement, 2, 96, capture);
            try capture.append(",\"turn\":");
            try appendColumnString(statement, 3, 20, capture);
            try capture.append(",\"operation\":");
            try appendColumnString(statement, 4, 20, capture);
            try capture.append("}");
        }
    }

    fn appendToolResults(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        const statement = try prepare(
            self.database,
            "SELECT call.operation_id,call.call_ordinal,coalesce(call.acceptance_position,action.acceptance_position)," ++
                "call.call_id_content_id,coalesce(call.rejection_code,action.resolution_code)," ++
                "coalesce(call.rejection_content_id,action.resolution_content_id) FROM model_tool_call call " ++
                "JOIN model_operation operation ON operation.operation_id=call.operation_id " ++
                "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
                "WHERE operation.session_ref=?1 AND coalesce(call.rejection_code,action.resolution_code) IS NOT NULL " ++
                "ORDER BY call.operation_id,coalesce(call.acceptance_position,action.acceptance_position)",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.CallReadFailed)) {
            const operation = c.sqlite3_column_int64(statement, 0);
            const ordinal = c.sqlite3_column_int64(statement, 1);
            const position = c.sqlite3_column_int64(statement, 2);
            const call_id = c.sqlite3_column_int64(statement, 3);
            const result = c.sqlite3_column_int64(statement, 5);
            if (operation <= 0 or ordinal < 0 or position <= 0 or call_id <= 0 or result <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"operation\":\"{d}\",\"call_ordinal\":\"{d}\",\"acceptance_position\":\"{d}\",\"call_id\":", .{ operation, ordinal, position });
            try self.appendInlineContent(call_id, capture);
            try capture.append(",\"code\":");
            try appendColumnString(statement, 4, 32, capture);
            try capture.append(",\"result\":");
            try self.appendInlineContent(result, capture);
            try capture.append("}");
        }
    }

    fn appendReferencedOutcome(self: *Store, statement: *c.sqlite3_stmt, code_index: c_int, content_id_index: c_int, capture: *SessionReportCapture) !void {
        if (c.sqlite3_column_type(statement, code_index) == c.SQLITE_NULL) {
            if (c.sqlite3_column_type(statement, content_id_index) != c.SQLITE_NULL) return error.CorruptStore;
            return capture.append("null");
        }
        try capture.append("{\"code\":");
        try appendColumnString(statement, code_index, 96, capture);
        try capture.append(",\"content\":");
        if (try readNullablePositiveI64(statement, content_id_index)) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
        } else try capture.append("null");
        try capture.append("}");
    }

    fn appendInlineOutcome(self: *Store, statement: *c.sqlite3_stmt, code_index: c_int, content_id_index: c_int, capture: *SessionReportCapture) !void {
        if (c.sqlite3_column_type(statement, code_index) == c.SQLITE_NULL) {
            if (c.sqlite3_column_type(statement, content_id_index) != c.SQLITE_NULL) return error.CorruptStore;
            return capture.append("null");
        }
        try capture.append("{\"code\":");
        try appendColumnString(statement, code_index, 96, capture);
        try capture.append(",\"content\":");
        if (try readNullablePositiveI64(statement, content_id_index)) |content_id| try self.appendInlineContent(content_id, capture) else try capture.append("null");
        try capture.append("}");
    }

    fn appendInlineContent(self: *Store, content_id: i64, capture: *SessionReportCapture) !void {
        const metadata = try self.readContentMetadata(content_id);
        const statement = try prepare(self.database, "SELECT payload IS NULL FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var reader = ContentReader{ .content_id = content_id, .representation = if (c.sqlite3_column_int(statement, 0) == 0) .raw else .{ .projection = .{} }, .store = self, .reference = .{ .length = metadata.length, .digest = metadata.digest } };
        try capture.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{metadata.length});
        try capture.append(&std.fmt.bytesToHex(metadata.digest, .lower));
        try capture.append("\",\"text\":\"");
        var buffer: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (offset < metadata.length) {
            const wanted: usize = @intCast(@min(metadata.length - offset, buffer.len));
            const count = try self.readOwnedContentLocked(&reader, offset, buffer[0..wanted]);
            if (count != wanted) return error.CorruptStore;
            try capture.appendJsonStringBytes(buffer[0..count]);
            offset += count;
        }
        try capture.append("\"}");
    }

    fn countActions(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(
            self.database,
            "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "CROSS JOIN action_operation action ON action.parent_operation_id=operation.operation_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ActionReadFailed;
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptStore;
        return @intCast(value);
    }

    fn countRejectedCalls(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(
            self.database,
            "SELECT count(*) FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "CROSS JOIN model_tool_call call ON call.operation_id=operation.operation_id " ++
                "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND call.rejection_code IS NOT NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CallReadFailed;
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptStore;
        return @intCast(value);
    }

    fn validateActiveTurnToolCalls(self: *Store, session_ref: []const u8) !void {
        const statement = try prepare(
            self.database,
            "SELECT operation.operation_id FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "WHERE active.session_ref=?1 " ++
                "AND active.outcome_code IS NULL AND operation.resolution_code='tool_calls' " ++
                "ORDER BY operation.operation_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const operation_id = c.sqlite3_column_int64(statement, 0);
                if (operation_id <= 0) return error.CorruptStore;
                _ = try self.readToolOutcomeFacts(@intCast(operation_id), false);
            },
            c.SQLITE_DONE => return,
            else => return error.CallReadFailed,
        };
    }

    const ToolOutcomeFacts = struct {
        position: ?u64,
        call_count: u64,
    };

    /// Validates the immutable function-call cardinality and every canonical
    /// classification row. When terminal outcomes are required, it also
    /// proves that each accepted call has a canonical result.
    fn readToolOutcomeFacts(
        self: *Store,
        operation_id: u64,
        require_terminal: bool,
    ) !ToolOutcomeFacts {
        const statement = try prepare(
            self.database,
            "SELECT (SELECT count(*) FROM model_output_item expected " ++
                "WHERE expected.operation_id=?1 AND expected.item_kind=3),count(call.operation_id)," ++
                "coalesce(sum(CASE WHEN item.operation_id IS NOT NULL AND item.item_kind=3 " ++
                "AND item_content.content_id IS NOT NULL AND item_id.content_id IS NOT NULL " ++
                "AND name.content_id IS NOT NULL AND call_id.content_id IS NOT NULL " ++
                "AND arguments.content_id IS NOT NULL AND ((call.rejection_code IS NOT NULL " ++
                "AND rejection.content_id IS NOT NULL AND call.acceptance_position IS NOT NULL " ++
                "AND action.action_id IS NULL) OR (call.rejection_code IS NULL AND action.action_id IS NOT NULL " ++
                "AND ((action.resolution_code IS NULL AND action.resolution_content_id IS NULL " ++
                "AND action.acceptance_position IS NULL) OR (action.resolution_code IS NOT NULL " ++
                "AND result.content_id IS NOT NULL AND action.acceptance_position IS NOT NULL)))) THEN 1 ELSE 0 END),0)," ++
                "coalesce(sum(CASE WHEN call.rejection_code IS NOT NULL AND rejection.content_id IS NOT NULL " ++
                "AND call.acceptance_position IS NOT NULL OR call.rejection_code IS NULL " ++
                "AND action.resolution_code IS NOT NULL AND result.content_id IS NOT NULL " ++
                "AND action.acceptance_position IS NOT NULL THEN 1 ELSE 0 END),0)," ++
                "max(coalesce(call.acceptance_position,action.acceptance_position)) " ++
                "FROM model_tool_call call LEFT JOIN model_output_item item ON item.operation_id=call.operation_id " ++
                "AND item.item_ordinal=call.item_ordinal LEFT JOIN content item_content ON item_content.content_id=item.content_id " ++
                "LEFT JOIN content item_id ON item_id.content_id=call.item_id_content_id " ++
                "LEFT JOIN content name ON name.content_id=call.name_content_id " ++
                "LEFT JOIN content call_id ON call_id.content_id=call.call_id_content_id " ++
                "LEFT JOIN content arguments ON arguments.content_id=call.arguments_content_id " ++
                "LEFT JOIN content rejection ON rejection.content_id=call.rejection_content_id " ++
                "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id " ++
                "AND action.call_ordinal=call.call_ordinal LEFT JOIN content result " ++
                "ON result.content_id=action.resolution_content_id WHERE call.operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CallReadFailed;
        const expected = c.sqlite3_column_int64(statement, 0);
        const calls = c.sqlite3_column_int64(statement, 1);
        const valid = c.sqlite3_column_int64(statement, 2);
        const terminal = c.sqlite3_column_int64(statement, 3);
        if (expected <= 0 or calls != expected or valid != expected or
            (require_terminal and terminal != expected)) return error.CorruptStore;
        const position = try readNullablePositiveI64(statement, 4);
        if (require_terminal and position == null) return error.CorruptStore;
        return .{
            .position = if (position) |value| @intCast(value) else null,
            .call_count = @intCast(calls),
        };
    }

    pub fn actionArguments(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, "arguments_content_id");
    }

    pub fn actionCallId(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, "call_id_content_id");
    }

    fn actionContent(self: *Store, session_ref: []const u8, action_id: u64, comptime column: []const u8) !ContentReference {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        if (action_id == 0 or action_id > std.math.maxInt(i64)) return error.ActionNotFound;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.actionContentLocked(session_ref, action_id, column) catch |err| switch (err) {
            error.ActionNotFound => error.ActionNotFound,
            else => self.fenceReadFailure(err),
        };
    }

    fn actionContentLocked(self: *Store, session_ref: []const u8, action_id: u64, comptime column: []const u8) !ContentReference {
        const statement = try prepare(
            self.database,
            "SELECT call." ++ column ++ " FROM action_operation action JOIN model_tool_call call " ++
                "ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal " ++
                "WHERE action.action_id=?1 AND action.session_ref=?2",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, action_id);
        try bindText(statement, 2, session_ref);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return error.ActionNotFound,
            c.SQLITE_ROW => {},
            else => return error.ActionReadFailed,
        }
        const content_id = c.sqlite3_column_int64(statement, 0);
        if (content_id <= 0) return error.CorruptStore;
        const metadata = try self.readContentMetadata(content_id);
        return .{ .length = metadata.length, .digest = metadata.digest };
    }

    pub fn admitNextModelAttempt(self: *Store, faults: Faults) !?AttemptAdmission {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.admitNextModelAttemptLocked(faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.InjectedAttemptCommitFailure,
            );
        };
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.admitNextActionAttemptLocked(bash_timeout_ms, faults) catch |err| {
            return self.finishTransactionError(err, faults, err == error.InjectedAttemptCommitFailure);
        };
    }

    fn admitNextActionAttemptLocked(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        try exec(self.database, "BEGIN IMMEDIATE");
        const select = try prepare(
            self.database,
            "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms FROM action_operation action " ++
                "INDEXED BY action_operation_executable JOIN model_operation operation " ++
                "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
                "WHERE action.permission_state=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
                "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
                "ORDER BY action.action_id LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(select);
        const step = c.sqlite3_step(select);
        if (step == c.SQLITE_DONE) {
            try exec(self.database, "ROLLBACK");
            return null;
        }
        if (step != c.SQLITE_ROW) return error.ActionSelectionFailed;
        const action_id = c.sqlite3_column_int64(select, 0);
        const parent_operation_id = c.sqlite3_column_int64(select, 1);
        const turn_id = c.sqlite3_column_int64(select, 2);
        if (action_id <= 0 or parent_operation_id <= 0 or turn_id <= 0) return error.CorruptStore;
        const selected_timeout_ms = if (try readNullablePositiveI64(select, 3)) |override|
            @as(u64, @intCast(override))
        else
            bash_timeout_ms;
        const update = try prepare(
            self.database,
            "UPDATE action_operation SET attempt_ordinal=1,bash_timeout_ms=?2 " ++
                "WHERE action_id=?1 AND permission_state=1 AND resolution_code IS NULL AND attempt_ordinal=0",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindI64(update, 1, action_id);
        try bindU64(update, 2, selected_timeout_ms);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .permit = .{ .binding = .{
            .turn_id = @intCast(turn_id),
            .parent_operation_id = @intCast(parent_operation_id),
            .action_id = @intCast(action_id),
            .attempt_ordinal = 1,
        } } };
    }

    pub fn readBashExecutionInput(self: *Store, binding: ActionAttemptBinding) !BashExecutionInput {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = prepare(
            self.database,
            "SELECT revision.workspace,call.arguments_content_id,action.bash_timeout_ms,operation.turn_id " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "JOIN session_revision revision ON revision.session_ref=action.session_ref AND revision.revision=action.permission_revision " ++
                "JOIN model_tool_call call ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3 " ++
                "AND action.resolution_code IS NULL",
        ) catch |err| return self.fenceReadFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        bindU64(statement, 1, binding.action_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 2, binding.parent_operation_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 3, binding.attempt_ordinal) catch |err| return self.fenceReadFailure(err);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
        if (step != c.SQLITE_ROW) return self.fenceReadFailure(error.ActionReadFailed);
        if (c.sqlite3_column_int64(statement, 3) != binding.turn_id) return error.StaleActionAttemptBinding;
        var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        readText(statement, 0, &workspace) catch |err| return self.fenceReadFailure(err);
        const content_id = c.sqlite3_column_int64(statement, 1);
        const timeout_ms = c.sqlite3_column_int64(statement, 2);
        if (content_id <= 0 or timeout_ms <= 0) return self.fenceReadFailure(error.CorruptStore);
        const metadata = self.readContentMetadata(content_id) catch |err| return self.fenceReadFailure(err);
        return .{
            .workspace = workspace,
            .arguments = .{ .length = metadata.length, .digest = metadata.digest },
            .timeout_ms = @intCast(timeout_ms),
        };
    }

    pub fn actionSupersededByStop(self: *Store, binding: ActionAttemptBinding) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = prepare(
            self.database,
            "SELECT EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3",
        ) catch |err| return self.fenceReadFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        bindU64(statement, 1, binding.action_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 2, binding.parent_operation_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 3, binding.attempt_ordinal) catch |err| return self.fenceReadFailure(err);
        const step = c.sqlite3_step(statement);
        if (step != c.SQLITE_ROW) return self.fenceReadFailure(if (step == c.SQLITE_DONE) error.CorruptStore else error.ActionReadFailed);
        const stopped = c.sqlite3_column_int(statement, 0);
        if (stopped != 0 and stopped != 1) return self.fenceReadFailure(error.CorruptStore);
        return stopped == 1;
    }

    pub fn withActionDispatchHandoff(
        self: *Store,
        binding: ActionAttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = prepare(
            self.database,
            "SELECT operation.turn_id,EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3 " ++
                "AND action.resolution_code IS NULL",
        ) catch |err| return self.fenceReadFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        bindU64(statement, 1, binding.action_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 2, binding.parent_operation_id) catch |err| return self.fenceReadFailure(err);
        bindU64(statement, 3, binding.attempt_ordinal) catch |err| return self.fenceReadFailure(err);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
        if (step != c.SQLITE_ROW) return self.fenceReadFailure(error.ActionReadFailed);
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id) return error.StaleActionAttemptBinding;
        if (c.sqlite3_column_int(statement, 1) != 0) return error.SupersededByControl;
        try handoff(context);
    }

    pub fn settleActionAttempt(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        if (result.len == 0) return error.InvalidActionResult;
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.settleActionAttemptLocked(binding, code, result, faults) catch |err| {
            return self.finishTransactionError(err, faults, err == error.StaleActionAttemptBinding);
        };
    }

    fn settleActionAttemptLocked(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        try exec(self.database, "BEGIN IMMEDIATE");
        const statement = try prepare(
            self.database,
            "SELECT action.session_ref,operation.turn_id," ++
                "EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
                "FROM action_operation action JOIN model_operation operation " ++
                "ON operation.operation_id=action.parent_operation_id " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 " ++
                "AND action.attempt_ordinal=?3 AND action.resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.action_id);
        try bindU64(statement, 2, binding.parent_operation_id);
        try bindU64(statement, 3, binding.attempt_ordinal);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
        if (step != c.SQLITE_ROW) return error.ActionReadFailed;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 0, &session_ref);
        if (c.sqlite3_column_int64(statement, 1) != binding.turn_id) return error.StaleActionAttemptBinding;
        const stopped = c.sqlite3_column_int(statement, 2);
        if (stopped != 0 and stopped != 1) return error.CorruptStore;
        const effective_code: ActionResolutionCode = if (stopped == 1) .cancelled else code;
        const effective_result = if (stopped == 1) "Cancelled by Session stop." else result;
        var current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;
        const content_id = try self.importBytesContent(effective_result, false, faults.content_import);
        const update = try prepare(
            self.database,
            "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4 " ++
                "WHERE action_id=?1 AND parent_operation_id=?5 AND attempt_ordinal=?6 AND resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, binding.action_id);
        try bindText(update, 2, @tagName(effective_code));
        try bindI64(update, 3, content_id);
        try bindU64(update, 4, current.next_position);
        try bindU64(update, 5, binding.parent_operation_id);
        try bindU64(update, 6, binding.attempt_ordinal);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.StaleActionAttemptBinding;
        current.next_position = try std.math.add(u64, current.next_position, 1);
        try self.updateSession(session_ref.slice(), &current);
        try self.completeStoppedTurnIfReady(binding.turn_id);
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return if (stopped == 1) .session_stop else .effect;
    }

    pub fn recoverOneUncertainAction(self: *Store, active: ActiveOperationFilter) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.recoverOneUncertainActionLocked(active) catch |err| return self.finishTransactionError(err, .{}, false);
    }

    fn recoverOneUncertainActionLocked(self: *Store, active: ActiveOperationFilter) !bool {
        const limit = try std.math.add(usize, active.maximum_exclusions, 1);
        if (limit > std.math.maxInt(i64)) return error.ActionSelectionLimitExceeded;
        var selected: ?u64 = null;
        {
            const select = try prepare(
                self.database,
                "SELECT action_id,parent_operation_id FROM action_operation INDEXED BY action_operation_unresolved_attempt " ++
                    "WHERE resolution_code IS NULL AND attempt_ordinal=1 ORDER BY action_id LIMIT ?1",
            );
            defer _ = c.sqlite3_finalize(select);
            try bindI64(select, 1, @as(i64, @intCast(limit)));
            while (true) switch (c.sqlite3_step(select)) {
                c.SQLITE_ROW => {
                    const action_id = c.sqlite3_column_int64(select, 0);
                    const operation_id = c.sqlite3_column_int64(select, 1);
                    if (action_id <= 0 or operation_id <= 0) return error.CorruptStore;
                    if (!active.contains(@intCast(action_id))) {
                        selected = @intCast(action_id);
                        break;
                    }
                },
                c.SQLITE_DONE => break,
                else => return error.ActionReadFailed,
            };
        }
        const action_id = selected orelse return false;
        try exec(self.database, "BEGIN IMMEDIATE");
        const action = try prepare(self.database, "SELECT session_ref FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL AND attempt_ordinal=1");
        defer _ = c.sqlite3_finalize(action);
        try bindU64(action, 1, action_id);
        if (c.sqlite3_step(action) != c.SQLITE_ROW) return error.ActionSelectionChanged;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(action, 0, &session_ref);
        var current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;
        const content_id = try self.importBytesContent(
            "Bash outcome is indeterminate after Host recovery; the command was not replayed.",
            false,
            false,
        );
        const update = try prepare(
            self.database,
            "UPDATE action_operation SET resolution_code='indeterminate',resolution_content_id=?2,acceptance_position=?3 " ++
                "WHERE action_id=?1 AND resolution_code IS NULL AND attempt_ordinal=1",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, action_id);
        try bindI64(update, 2, content_id);
        try bindU64(update, 3, current.next_position);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.ActionSelectionChanged;
        current.next_position = try std.math.add(u64, current.next_position, 1);
        try self.updateSession(session_ref.slice(), &current);
        const turn_statement = try prepare(
            self.database,
            "SELECT operation.turn_id FROM action_operation action JOIN model_operation operation " ++
                "ON operation.operation_id=action.parent_operation_id WHERE action.action_id=?1",
        );
        defer _ = c.sqlite3_finalize(turn_statement);
        try bindU64(turn_statement, 1, action_id);
        if (c.sqlite3_step(turn_statement) != c.SQLITE_ROW) return error.CorruptStore;
        const turn_id = c.sqlite3_column_int64(turn_statement, 0);
        if (turn_id <= 0) return error.CorruptStore;
        try self.completeStoppedTurnIfReady(@intCast(turn_id));
        try exec(self.database, "COMMIT");
        return true;
    }

    fn completeStoppedTurnIfReady(self: *Store, turn_id: u64) !void {
        const update = try prepare(
            self.database,
            "UPDATE turn SET outcome_code='cancelled' WHERE turn_id=?1 AND outcome_code IS NULL " ++
                "AND EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=turn.turn_id) " ++
                "AND NOT EXISTS(SELECT 1 FROM action_operation action " ++
                "WHERE action.parent_operation_id=turn.operation_id AND action.resolution_code IS NULL)",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, turn_id);
        try expectDone(update);
    }

    fn admitNextModelAttemptLocked(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!try self.hasRunnableWorkLocked()) return null;
        try exec(self.database, "BEGIN IMMEDIATE");

        var select = try prepare(self.database, runnable_selection_sql);
        var step_result = c.sqlite3_step(select);
        if (step_result == c.SQLITE_DONE) {
            if (c.sqlite3_finalize(select) != c.SQLITE_OK) return error.RunnableSelectionFailed;
            select = try prepare(self.database, tool_continuation_selection_sql);
            step_result = c.sqlite3_step(select);
        }
        defer _ = c.sqlite3_finalize(select);
        if (step_result == c.SQLITE_DONE) return error.RunnableSelectionFailed;
        if (step_result != c.SQLITE_ROW) return error.RunnableSelectionFailed;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(select, 0, &session_ref);
        const first_admission = c.sqlite3_column_int64(select, 1);
        const cutoff = c.sqlite3_column_int64(select, 2);
        const selected = c.sqlite3_column_int64(select, 3);
        const revision = c.sqlite3_column_int64(select, 4);
        const initial_position = c.sqlite3_column_int64(select, 5);
        const existing_turn = try readNullablePositiveI64(select, 6);
        if (first_admission <= 0 or cutoff < first_admission or selected < 0 or revision <= 0 or initial_position <= 0) {
            return error.CorruptStore;
        }

        const turn_id = if (existing_turn) |value| @as(u64, @intCast(value)) else try nextIdentity(self.database, "turn", "turn_id");
        const operation_id = try nextIdentity(self.database, "model_operation", "operation_id");
        if (existing_turn == null) {
            const insert = try prepare(
                self.database,
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id) " ++
                    "VALUES(?1,?2,?3,?4,?5,NULL,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, turn_id);
            try bindText(insert, 2, session_ref.slice());
            try bindI64(insert, 3, first_admission);
            try bindI64(insert, 4, cutoff);
            try bindU64(insert, 5, operation_id);
            try expectDone(insert);
        } else {
            const update = try prepare(
                self.database,
                "UPDATE turn SET input_cutoff=?2,operation_id=?3 WHERE turn_id=?1 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, turn_id);
            try bindI64(update, 2, cutoff);
            try bindU64(update, 3, operation_id);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        if (selected != 0) {
            const bind = try prepare(
                self.database,
                "UPDATE message_admission SET turn_id=?1 WHERE session_ref=?2 AND turn_id IS NULL AND admission_id<=?3 " ++
                    "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=message_admission.session_ref " ++
                    "AND message_admission.admission_id<=stopped.admission_cutoff)",
            );
            defer _ = c.sqlite3_finalize(bind);
            try bindU64(bind, 1, turn_id);
            try bindText(bind, 2, session_ref.slice());
            try bindI64(bind, 3, cutoff);
            try expectDone(bind);
            if (c.sqlite3_changes(self.database) != selected) return error.SelectionChanged;
        }
        if (selected != 0) {
            const project = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                    "row_number() OVER (ORDER BY admission_id),?3 + row_number() OVER (ORDER BY admission_id) - 1,1,?2,admission_id,NULL,NULL,content_id " ++
                    "FROM message_admission WHERE turn_id=?2 AND admission_id>=?4 ORDER BY admission_id",
            );
            defer _ = c.sqlite3_finalize(project);
            try bindText(project, 1, session_ref.slice());
            try bindU64(project, 2, turn_id);
            try bindI64(project, 3, initial_position);
            try bindI64(project, 4, first_admission);
            try expectDone(project);
            if (c.sqlite3_changes(self.database) != selected) return error.ProjectionFailed;
        }
        var next_position: u64 = try std.math.add(u64, @intCast(initial_position), @intCast(selected));
        const instruction_count = blk: {
            const count = try prepare(
                self.database,
                "SELECT count(*) FROM session_revision r WHERE r.session_ref=?1 AND r.revision>1 AND " ++
                    "r.revision<=?2 AND r.instructions_updated=1 AND NOT EXISTS(" ++
                    "SELECT 1 FROM conversation_entry e WHERE e.session_ref=r.session_ref AND e.source_revision=r.revision)",
            );
            defer _ = c.sqlite3_finalize(count);
            try bindText(count, 1, session_ref.slice());
            try bindI64(count, 2, revision);
            if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.InstructionSelectionFailed;
            const value = c.sqlite3_column_int64(count, 0);
            if (value < 0) return error.CorruptStore;
            break :blk value;
        };
        if (instruction_count != 0) {
            const project = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                    "row_number() OVER (ORDER BY revision),?3 + row_number() OVER (ORDER BY revision) - 1,2,?2,NULL,revision,NULL,instructions_content_id " ++
                    "FROM session_revision r WHERE r.session_ref=?1 AND r.revision>1 AND r.revision<=?4 AND r.instructions_updated=1 AND NOT EXISTS(" ++
                    "SELECT 1 FROM conversation_entry e WHERE e.session_ref=r.session_ref AND e.source_revision=r.revision) ORDER BY revision",
            );
            defer _ = c.sqlite3_finalize(project);
            try bindText(project, 1, session_ref.slice());
            try bindU64(project, 2, turn_id);
            try bindU64(project, 3, next_position);
            try bindI64(project, 4, revision);
            try expectDone(project);
            if (c.sqlite3_changes(self.database) != instruction_count) return error.InstructionSelectionFailed;
            next_position = try std.math.add(u64, next_position, @intCast(instruction_count));
        }
        {
            const update = try prepare(self.database, "UPDATE session SET next_position=?2 WHERE session_ref=?1 AND next_position=?3");
            defer _ = c.sqlite3_finalize(update);
            try bindText(update, 1, session_ref.slice());
            try bindU64(update, 2, try std.math.add(u64, next_position, 1));
            try bindI64(update, 3, initial_position);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                    "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,body_model,openai_model,x_openai_model,request_id,usage_content_id) " ++
                    "VALUES(?1,?2,?3,?4,?5,?6,1,1,1,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, operation_id);
            try bindU64(insert, 2, turn_id);
            try bindText(insert, 3, session_ref.slice());
            try bindI64(insert, 4, revision);
            try bindI64(insert, 5, cutoff);
            try bindU64(insert, 6, next_position);
            try expectDone(insert);
        }
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        const binding = AttemptBinding{
            .turn_id = turn_id,
            .operation_id = operation_id,
            .attempt_ordinal = 1,
        };
        return .{ .permit = .{ .binding = binding } };
    }

    pub fn tryAdmitNextModelRetry(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.tryAdmitNextModelRetryLocked(active, faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.InjectedAttemptCommitFailure,
            );
        };
    }

    fn tryAdmitNextModelRetryLocked(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        try exec(self.database, "BEGIN IMMEDIATE");
        const snapshot_ms = try readUnixMilliseconds(self.database);
        const selection_limit = try std.math.add(
            usize,
            active.maximum_exclusions,
            1,
        );
        if (selection_limit > std.math.maxInt(i64)) return error.RetrySelectionLimitExceeded;
        const select = try prepare(self.database, retry_admission_select_sql);
        var select_open = true;
        defer {
            if (select_open) _ = c.sqlite3_finalize(select);
        }
        try bindI64(select, 1, snapshot_ms);
        try bindI64(select, 2, @as(i64, @intCast(selection_limit)));
        var selected: ?AttemptBinding = null;
        while (true) {
            const result = c.sqlite3_step(select);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.RetrySelectionFailed;
            const turn_id = c.sqlite3_column_int64(select, 0);
            const operation_id = c.sqlite3_column_int64(select, 1);
            const attempt_ordinal = c.sqlite3_column_int64(select, 2);
            const allowance_used = c.sqlite3_column_int64(select, 3);
            const due_at_ms = c.sqlite3_column_int64(select, 4);
            if (turn_id <= 0 or operation_id <= 0 or attempt_ordinal <= 0 or
                allowance_used != attempt_ordinal or allowance_used >= maximum_model_attempts or
                due_at_ms < 0 or due_at_ms > snapshot_ms)
            {
                return error.CorruptStore;
            }
            if (active.contains(@intCast(operation_id))) continue;
            selected = .{
                .turn_id = @intCast(turn_id),
                .operation_id = @intCast(operation_id),
                .attempt_ordinal = @intCast(attempt_ordinal),
            };
            break;
        }
        if (c.sqlite3_finalize(select) != c.SQLITE_OK) return error.RetrySelectionFailed;
        select_open = false;

        // Eligibility exists only inside this Store transition. No selected
        // candidate or time snapshot survives rollback, capacity loss or exit.
        const current = selected orelse {
            try exec(self.database, "ROLLBACK");
            return null;
        };
        if (current.attempt_ordinal >= maximum_model_attempts) return error.CorruptStore;
        const replacement_ordinal = current.attempt_ordinal + 1;
        const update = try prepare(
            self.database,
            "UPDATE model_operation SET attempt_ordinal=?2,allowance_used=?2,uncertain=1,retry_due_at_ms=0 " ++
                "WHERE operation_id=?1 AND turn_id=?3 AND resolution_code IS NULL " ++
                "AND attempt_ordinal=?4 AND allowance_used=?4 AND allowance_used<4 AND retry_due_at_ms<=?5",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, current.operation_id);
        try bindU64(update, 2, replacement_ordinal);
        try bindU64(update, 3, current.turn_id);
        try bindU64(update, 4, current.attempt_ordinal);
        try bindI64(update, 5, snapshot_ms);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) {
            try exec(self.database, "ROLLBACK");
            return null;
        }
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .permit = .{ .binding = .{
            .turn_id = current.turn_id,
            .operation_id = current.operation_id,
            .attempt_ordinal = replacement_ordinal,
        } } };
    }

    fn hasRunnableWorkLocked(self: *Store) !bool {
        const statement = try prepare(self.database, runnable_probe_sql);
        defer _ = c.sqlite3_finalize(statement);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => {
                try self.validateBlockedToolCalls();
                return false;
            },
            else => error.RunnableSelectionFailed,
        };
    }

    /// Before declaring the Store idle, distinguish valid permission waits
    /// from malformed canonical classification. Only each active Turn's
    /// current Operation can be blocking successor discovery.
    fn validateBlockedToolCalls(self: *Store) !void {
        const statement = try prepare(
            self.database,
            "SELECT operation.operation_id FROM turn active JOIN model_operation operation " ++
                "ON operation.operation_id=active.operation_id WHERE active.outcome_code IS NULL " ++
                "AND operation.resolution_code='tool_calls' ORDER BY operation.operation_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const operation_id = c.sqlite3_column_int64(statement, 0);
                if (operation_id <= 0) return error.CorruptStore;
                _ = try self.readToolOutcomeFacts(@intCast(operation_id), false);
            },
            c.SQLITE_DONE => return,
            else => return error.CallReadFailed,
        };
    }

    pub fn openHistoricalView(self: *Store, binding: AttemptBinding) !HistoricalView {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        try self.validateCurrentAttempt(binding);
        return .{ .store = self, .binding = binding };
    }

    fn validateCurrentAttempt(self: *Store, binding: AttemptBinding) !void {
        const statement = try prepare(
            self.database,
            "SELECT turn_id,attempt_ordinal,resolution_code,interrupted_by_command_key " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return error.StaleAttemptBinding;
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return;
        if (c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL) return error.SupersededByControl;
        return error.StaleAttemptBinding;
    }

    fn readHistoricalSettings(self: *Store, view: *HistoricalView) !HistoricalSettings {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalSettingsLocked(view) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalSettingsLocked(self: *Store, view: *HistoricalView) !HistoricalSettings {
        try self.validateCurrentAttempt(view.binding);
        const statement = try prepare(
            self.database,
            "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,r.tools_mask " ++
                "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref " ++
                "AND r.revision=o.settings_revision JOIN session_revision baseline ON baseline.session_ref=o.session_ref AND baseline.revision=1 WHERE o.operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, view.binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var model: protocol.Bounded(protocol.max_model_bytes) = .{};
        try readText(statement, 0, &model);
        const instructions_id = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        const output_schema_id = try readNullablePositiveI64(statement, 2);
        const tools = c.sqlite3_column_int(statement, 3);
        if (tools < 0 or tools > 3) return error.CorruptStore;
        const instructions = try self.readContentMetadata(instructions_id);
        const output_schema = if (output_schema_id) |content_id| blk: {
            const metadata = try self.readContentMetadata(content_id);
            break :blk HistoricalContent{ .view = view, .length = metadata.length, .digest = metadata.digest };
        } else null;
        return .{
            .model = model,
            .baseline_instructions = .{ .view = view, .length = instructions.length, .digest = instructions.digest },
            .output_schema = output_schema,
            .tools_mask = @intCast(tools),
        };
    }

    fn readHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64) !?HistoricalEntry {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalEntryLocked(view, after_position) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalEntryLocked(self: *Store, view: *HistoricalView, after_position: u64) !?HistoricalEntry {
        try self.validateCurrentAttempt(view.binding);
        var scan_tool_groups = !view.tool_group_initialized;
        if (view.tool_group_initialized and after_position < view.tool_group_scan_after) {
            view.tool_group_source_cursor = 0;
            view.next_tool_group = null;
            view.next_tool_group_source_id = null;
            scan_tool_groups = true;
        } else if (view.next_tool_group) |group| {
            if (group.position <= after_position) {
                view.next_tool_group = null;
                view.next_tool_group_source_id = null;
                scan_tool_groups = true;
            }
        }
        if (scan_tool_groups) {
            while (try self.readNextHistoricalToolGroup(view)) |group| {
                view.tool_group_source_cursor = group.source_operation_id;
                if (group.entry.position > after_position) {
                    view.next_tool_group = group.entry;
                    view.next_tool_group_source_id = group.source_operation_id;
                    break;
                }
            }
            view.tool_group_initialized = true;
        }
        view.tool_group_scan_after = after_position;
        const statement = try prepare(
            self.database,
            "SELECT position,kind,content_id FROM (" ++
                "SELECT e.session_position AS position,e.entry_kind AS kind,e.content_id AS content_id " ++
                "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
                "AND e.entry_kind IN (1,2) UNION ALL " ++
                "SELECT item.session_position AS position,3 AS kind,item.content_id AS content_id " ++
                "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position" ++
                ") ORDER BY position LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, view.binding.operation_id);
        try bindU64(statement, 2, after_position);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return self.activateHistoricalToolGroup(view);
        if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
        const position = c.sqlite3_column_int64(statement, 0);
        const kind_value = c.sqlite3_column_int(statement, 1);
        const content_id = c.sqlite3_column_int64(statement, 2);
        if (position <= 0 or content_id <= 0) return error.CorruptStore;
        const kind: HistoricalEntryKind = switch (kind_value) {
            1 => .user,
            2 => .instruction,
            3 => .provider_output,
            else => return error.CorruptStore,
        };
        const metadata = try self.readContentMetadata(content_id);
        const ordinary = HistoricalEntry{
            .position = @intCast(position),
            .kind = kind,
            .content = .{
                .view = view,
                .length = metadata.length,
                .digest = metadata.digest,
                .private = kind == .provider_output,
            },
        };
        if (view.next_tool_group) |group| {
            if (group.position < ordinary.position) return self.activateHistoricalToolGroup(view);
        }
        return ordinary;
    }

    fn activateHistoricalToolGroup(self: *Store, view: *HistoricalView) !?HistoricalEntry {
        _ = self;
        const entry = view.next_tool_group orelse return null;
        view.active_tool_group_source_id = view.next_tool_group_source_id orelse return error.CorruptStore;
        view.active_tool_group_after_ordinal = null;
        view.active_tool_group_count = 0;
        return entry;
    }

    const HistoricalToolGroup = struct {
        entry: HistoricalEntry,
        source_operation_id: u64,
    };

    fn readNextHistoricalToolGroup(
        self: *Store,
        view: *HistoricalView,
    ) !?HistoricalToolGroup {
        const statement = try prepare(
            self.database,
            "SELECT source.operation_id,current.admission_position FROM model_operation current " ++
                "JOIN model_operation source INDEXED BY model_operation_session_history " ++
                "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 " ++
                "AND source.operation_id>?2 AND source.operation_id<current.operation_id " ++
                "AND source.resolution_code='tool_calls' ORDER BY source.operation_id LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, view.binding.operation_id);
        try bindU64(statement, 2, view.tool_group_source_cursor);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
        const source_operation_id = c.sqlite3_column_int64(statement, 0);
        const admission_position = c.sqlite3_column_int64(statement, 1);
        if (source_operation_id <= 0 or admission_position <= 0) return error.CorruptStore;
        const facts = try self.readToolOutcomeFacts(@intCast(source_operation_id), true);
        const position = facts.position orelse return error.CorruptStore;
        if (position >= admission_position) return error.CorruptStore;
        return .{
            .entry = .{
                .position = position,
                .kind = .tool_results,
            },
            .source_operation_id = @intCast(source_operation_id),
        };
    }

    fn readHistoricalToolResult(
        self: *Store,
        view: *HistoricalView,
    ) !?HistoricalToolResult {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalToolResultLocked(view) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalToolResultLocked(
        self: *Store,
        view: *HistoricalView,
    ) !?HistoricalToolResult {
        try self.validateCurrentAttempt(view.binding);
        const source_operation_id = view.active_tool_group_source_id orelse unreachable;
        const after_call_ordinal = view.active_tool_group_after_ordinal;
        const statement = try prepare(
            self.database,
            "SELECT call.call_ordinal,call.call_id_content_id," ++
                "coalesce(call.rejection_content_id,action.resolution_content_id),current.admission_position " ++
                "FROM model_operation current " ++
                "CROSS JOIN model_operation source ON source.operation_id=?2 AND source.session_ref=current.session_ref " ++
                "CROSS JOIN model_tool_call call ON call.operation_id=source.operation_id LEFT JOIN action_operation action " ++
                "ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
                "WHERE current.operation_id=?1 AND source.resolution_code='tool_calls' " ++
                "AND coalesce(call.acceptance_position,action.acceptance_position)<current.admission_position " ++
                (if (after_call_ordinal == null)
                    "AND call.call_ordinal>=0 "
                else
                    "AND call.call_ordinal>?3 ") ++
                "ORDER BY call.call_ordinal LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, view.binding.operation_id);
        try bindU64(statement, 2, source_operation_id);
        if (after_call_ordinal) |ordinal| try bindU64(statement, 3, ordinal);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) {
            const facts = try self.readToolOutcomeFacts(source_operation_id, true);
            if (view.active_tool_group_count != facts.call_count) return error.CorruptStore;
            view.active_tool_group_source_id = null;
            view.active_tool_group_after_ordinal = null;
            view.active_tool_group_count = 0;
            return null;
        }
        if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
        const call_ordinal = c.sqlite3_column_int64(statement, 0);
        const call_id_content_id = c.sqlite3_column_int64(statement, 1);
        const output_content_id = c.sqlite3_column_int64(statement, 2);
        const admission_position = c.sqlite3_column_int64(statement, 3);
        if (call_ordinal < 0 or call_id_content_id <= 0 or output_content_id <= 0 or admission_position <= 0)
            return error.CorruptStore;
        const call_id = try self.readContentMetadata(call_id_content_id);
        const output = try self.readContentMetadata(output_content_id);
        view.active_tool_group_after_ordinal = @intCast(call_ordinal);
        view.active_tool_group_count += 1;
        return .{
            .call_id = .{ .view = view, .length = call_id.length, .digest = call_id.digest },
            .output = .{ .view = view, .length = output.length, .digest = output.digest },
        };
    }

    pub fn isFenced(self: *const Store) bool {
        return self.fenced.load(.acquire);
    }

    pub fn operationSupersededByControl(self: *Store, binding: AttemptBinding) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = prepare(
            self.database,
            "SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation WHERE operation_id=?1",
        ) catch |err| return self.fenceReadFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        bindU64(statement, 1, binding.operation_id) catch |err| return self.fenceReadFailure(err);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return false;
        if (step != c.SQLITE_ROW) return self.fenceReadFailure(error.OperationReadFailed);
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return false;
        return c.sqlite3_column_type(statement, 2) != c.SQLITE_NULL;
    }

    pub fn withDispatchHandoff(
        self: *Store,
        binding: AttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.validateCurrentAttempt(binding) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => return err,
            else => return self.fenceReadFailure(err),
        };
        try handoff(context);
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        disposition: ModelFailureDisposition,
        faults: Faults,
    ) !void {
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.settleModelAttemptFailureLocked(binding, code, disposition, faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.StaleAttemptBinding or err == error.SupersededByControl,
            );
        };
    }

    fn settleModelAttemptFailureLocked(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        disposition: ModelFailureDisposition,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        try self.validateCurrentAttempt(binding);
        switch (disposition) {
            .terminal => {
                const update = try prepare(
                    self.database,
                    "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2 " ++
                        "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                );
                defer _ = c.sqlite3_finalize(update);
                try bindU64(update, 1, binding.operation_id);
                try bindText(update, 2, code);
                try bindU64(update, 3, binding.attempt_ordinal);
                try expectDone(update);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;

                const settle_turn = try prepare(
                    self.database,
                    "UPDATE turn SET outcome_code=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
                );
                defer _ = c.sqlite3_finalize(settle_turn);
                try bindU64(settle_turn, 1, binding.turn_id);
                try bindText(settle_turn, 2, code);
                try bindU64(settle_turn, 3, binding.operation_id);
                try expectDone(settle_turn);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
            },
            .retryable => |policy| switch (try decideModelRetry(binding.attempt_ordinal, policy, try readUnixMilliseconds(self.database))) {
                .schedule_at_ms => |due_at_ms| {
                    const update = try prepare(
                        self.database,
                        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=?2,last_failure_code=?3 " ++
                            "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?4",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, binding.operation_id);
                    try bindI64(update, 2, due_at_ms);
                    try bindText(update, 3, code);
                    try bindU64(update, 4, binding.attempt_ordinal);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                },
                .exhausted => {
                    const update = try prepare(
                        self.database,
                        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,last_failure_code=?2,resolution_code='retry_exhausted' " ++
                            "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, binding.operation_id);
                    try bindText(update, 2, code);
                    try bindU64(update, 3, binding.attempt_ordinal);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;

                    const settle_turn = try prepare(
                        self.database,
                        "UPDATE turn SET outcome_code='retry_exhausted' " ++
                            "WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
                    );
                    defer _ = c.sqlite3_finalize(settle_turn);
                    try bindU64(settle_turn, 1, binding.turn_id);
                    try bindU64(settle_turn, 2, binding.operation_id);
                    try expectDone(settle_turn);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                },
            },
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
    }

    pub fn recoverOneExhaustedModelAttempt(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.recoverOneExhaustedModelAttemptLocked(active) catch |err| {
            return self.finishTransactionError(err, .{}, false);
        };
    }

    fn recoverOneExhaustedModelAttemptLocked(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        const scan_limit = try std.math.add(
            usize,
            active.maximum_exclusions,
            1,
        );
        if (scan_limit > std.math.maxInt(i64)) return error.RetrySelectionLimitExceeded;
        const select = try prepare(
            self.database,
            "SELECT turn_id,operation_id FROM model_operation INDEXED BY model_operation_retry_exhausted " ++
                "WHERE resolution_code IS NULL AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0 " ++
                "ORDER BY operation_id LIMIT ?1",
        );
        var select_open = true;
        defer {
            if (select_open) _ = c.sqlite3_finalize(select);
        }
        try bindI64(select, 1, @as(i64, @intCast(scan_limit)));
        var selected: ?AttemptBinding = null;
        while (true) {
            const result = c.sqlite3_step(select);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.RetryRecoveryFailed;
            const turn_id = c.sqlite3_column_int64(select, 0);
            const operation_id = c.sqlite3_column_int64(select, 1);
            if (turn_id <= 0 or operation_id <= 0) return error.CorruptStore;
            if (active.contains(@intCast(operation_id))) continue;
            selected = .{
                .turn_id = @intCast(turn_id),
                .operation_id = @intCast(operation_id),
                .attempt_ordinal = maximum_model_attempts,
            };
            break;
        }
        if (c.sqlite3_finalize(select) != c.SQLITE_OK) return error.RetryRecoveryFailed;
        select_open = false;
        const binding = selected orelse return false;

        try exec(self.database, "BEGIN IMMEDIATE");
        {
            const update_operation = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='retry_exhausted' " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND uncertain=1 AND allowance_used=?2",
            );
            defer _ = c.sqlite3_finalize(update_operation);
            try bindI64(update_operation, 1, binding.operation_id);
            try bindU64(update_operation, 2, maximum_model_attempts);
            try expectDone(update_operation);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        {
            const update_turn = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='retry_exhausted' " ++
                    "WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update_turn);
            try bindI64(update_turn, 1, binding.turn_id);
            try bindI64(update_turn, 2, binding.operation_id);
            try expectDone(update_turn);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        try exec(self.database, "COMMIT");
        return true;
    }

    pub fn settleModelSuccess(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.settlement_trace) |trace| trace.mark(.lock_acquired);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.settleModelSuccessLocked(binding, output, faults) catch |err| {
            const final_err = self.finishTransactionError(
                err,
                faults,
                err == error.StaleAttemptBinding or err == error.SupersededByControl or
                    err == error.InvalidProviderEnvelope,
            );
            if (faults.settlement_trace) |trace| trace.mark(.settlement_complete);
            return final_err;
        };
        if (faults.settlement_trace) |trace| trace.mark(.settlement_complete);
    }

    fn settleModelSuccessLocked(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        try self.validateCurrentAttempt(binding);
        const operation = try prepare(
            self.database,
            "SELECT o.session_ref,r.tools_mask FROM model_operation o JOIN session_revision r " ++
                "ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
                "WHERE o.operation_id=?1 AND o.turn_id=?2",
        );
        defer _ = c.sqlite3_finalize(operation);
        try bindU64(operation, 1, binding.operation_id);
        try bindU64(operation, 2, binding.turn_id);
        if (c.sqlite3_step(operation) != c.SQLITE_ROW) return error.StaleAttemptBinding;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(operation, 0, &session_ref);
        const frozen_tools_value = c.sqlite3_column_int(operation, 1);
        if (frozen_tools_value < 0 or frozen_tools_value > 3) return error.CorruptStore;
        const frozen_tools: u8 = @intCast(frozen_tools_value);
        var current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;

        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var imported_items: u64 = 0;
        var usage_id: ?i64 = null;
        while (try metadata.next()) |record| {
            if (record.tag == .text) continue;
            if (record.tag == .usage) {
                if (usage_id != null) return error.CorruptOutputMetadata;
                usage_id = try self.importSourceRange(
                    output.source,
                    output.source_length,
                    record.start,
                    record.length,
                    &record.content_digest,
                    true,
                    faults,
                );
                continue;
            }
            if (record.tag != .item) continue;
            if (record.ordinal != imported_items) return error.CorruptOutputMetadata;
            const duplicate_identity = try prepare(
                self.database,
                "SELECT 1 FROM model_output_item WHERE operation_id=?1 AND item_id_digest=?2 LIMIT 1",
            );
            defer _ = c.sqlite3_finalize(duplicate_identity);
            try bindU64(duplicate_identity, 1, binding.operation_id);
            try bindBlob(duplicate_identity, 2, &record.id_digest);
            if (c.sqlite3_step(duplicate_identity) == c.SQLITE_ROW) return error.InvalidProviderEnvelope;
            const content_id = try self.importSourceRange(
                output.source,
                output.source_length,
                record.start,
                record.length,
                &record.content_digest,
                true,
                faults,
            );
            const insert = try prepare(
                self.database,
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,content_id,attempt_ordinal,item_id_digest) " ++
                    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, binding.operation_id);
            try bindU64(insert, 2, record.ordinal);
            try bindText(insert, 3, session_ref.slice());
            try bindU64(insert, 4, current.next_position);
            try bindI64(insert, 5, @intFromEnum(record.kind));
            try bindI64(insert, 6, content_id);
            try bindU64(insert, 7, binding.attempt_ordinal);
            try bindBlob(insert, 8, &record.id_digest);
            try expectDone(insert);
            current.next_position = try std.math.add(u64, current.next_position, 1);
            imported_items += 1;
        }
        if (imported_items != output.item_count) return error.CorruptOutputMetadata;

        var imported_calls: u64 = 0;
        var item_id_record: ?OutputMetadataRecord = null;
        var name_record: ?OutputMetadataRecord = null;
        var call_id_record: ?OutputMetadataRecord = null;
        metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var call_items = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var call_item = try call_items.nextItem();
        while (try metadata.next()) |record| switch (record.tag) {
            .item_id => item_id_record = record,
            .name => name_record = record,
            .call_id => call_id_record = record,
            .arguments => {
                const item_id = item_id_record orelse return error.CorruptOutputMetadata;
                const name = name_record orelse return error.CorruptOutputMetadata;
                const call_id = call_id_record orelse return error.CorruptOutputMetadata;
                if (item_id.ordinal != record.ordinal or name.ordinal != record.ordinal or
                    call_id.ordinal != record.ordinal or record.kind != .function_call)
                    return error.CorruptOutputMetadata;
                while (call_item != null and call_item.?.ordinal < record.ordinal) call_item = try call_items.nextItem();
                const owner = call_item orelse return error.CorruptOutputMetadata;
                if (owner.ordinal != record.ordinal or owner.kind != .function_call) return error.CorruptOutputMetadata;
                const item_id_content_id = try self.importStringProjection(binding, item_id, owner);
                const name_content_id = try self.importStringProjection(binding, name, owner);
                const call_id_content_id = try self.importStringProjection(binding, call_id, owner);
                const arguments_content_id = try self.importStringProjection(binding, record, owner);

                const duplicate_call = try prepare(
                    self.database,
                    "SELECT 1 FROM model_tool_call WHERE operation_id=?1 AND call_id_content_id=?2 LIMIT 1",
                );
                defer _ = c.sqlite3_finalize(duplicate_call);
                try bindU64(duplicate_call, 1, binding.operation_id);
                try bindI64(duplicate_call, 2, call_id_content_id);
                if (c.sqlite3_step(duplicate_call) == c.SQLITE_ROW) return error.InvalidProviderEnvelope;

                const is_bash = try metadataStringEql(self.io, output.source, name, "bash");
                const is_edit = try metadataStringEql(self.io, output.source, name, "edit");
                const bash_arguments = if (is_bash and frozen_tools & 1 != 0)
                    try bashArguments(self.io, output.source, record)
                else
                    null;
                const rejection_code: ?[]const u8 = if (is_bash and frozen_tools & 1 == 0)
                    "unknown_tool"
                else if (is_bash and bash_arguments == null)
                    "invalid_arguments"
                else if (is_edit and frozen_tools & 2 != 0)
                    "tool_unavailable"
                else if (!is_bash)
                    "unknown_tool"
                else
                    null;
                var rejection_buffer: [192]u8 = undefined;
                const rejection_text = if (rejection_code) |code|
                    try rejectionResult(self.io, output.source, code, name, &rejection_buffer)
                else
                    null;
                const rejection_content_id = if (rejection_text) |text|
                    try self.importBytesContent(text, false, faults.output_import)
                else
                    null;
                const acceptance_position = if (rejection_code != null) position: {
                    const position = current.next_position;
                    current.next_position = try std.math.add(u64, current.next_position, 1);
                    break :position position;
                } else null;
                const insert_call = try prepare(
                    self.database,
                    "INSERT INTO model_tool_call(operation_id,call_ordinal,item_ordinal,item_id_content_id,name_content_id,call_id_content_id,arguments_content_id," ++
                        "rejection_code,rejection_content_id,acceptance_position,action_kind) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                );
                defer _ = c.sqlite3_finalize(insert_call);
                try bindU64(insert_call, 1, binding.operation_id);
                try bindU64(insert_call, 2, imported_calls);
                try bindU64(insert_call, 3, record.ordinal);
                try bindI64(insert_call, 4, item_id_content_id);
                try bindI64(insert_call, 5, name_content_id);
                try bindI64(insert_call, 6, call_id_content_id);
                try bindI64(insert_call, 7, arguments_content_id);
                try bindOptionalText(insert_call, 8, if (rejection_code) |code| code else "");
                try bindNullableI64(insert_call, 9, rejection_content_id);
                try bindNullableU64(insert_call, 10, acceptance_position);
                if (rejection_code == null) try bindI64(insert_call, 11, 1) else try bindNullableI64(insert_call, 11, null);
                try expectDone(insert_call);

                if (rejection_code == null) {
                    const action_id = try nextIdentity(self.database, "action_operation", "action_id");
                    const insert_action = try prepare(
                        self.database,
                        "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,permission_state,bash_timeout_override_ms,resolution_code) " ++
                            "VALUES(?1,?2,?3,?4,1,?5,?6,?7,NULL)",
                    );
                    defer _ = c.sqlite3_finalize(insert_action);
                    try bindU64(insert_action, 1, action_id);
                    try bindU64(insert_action, 2, binding.operation_id);
                    try bindU64(insert_action, 3, imported_calls);
                    try bindText(insert_action, 4, session_ref.slice());
                    try bindU64(insert_action, 5, current.revision);
                    try bindI64(insert_action, 6, @as(i64, if (current.permission_mode == 0) 0 else 1));
                    try bindNullableU64(insert_action, 7, bash_arguments.?.timeout_ms);
                    try expectDone(insert_action);
                }
                item_id_record = null;
                name_record = null;
                call_id_record = null;
                imported_calls += 1;
            },
            else => {},
        };
        if (item_id_record != null or name_record != null or call_id_record != null or
            imported_calls != output.call_count) return error.CorruptOutputMetadata;

        const answer_id: ?i64 = if (output.answer_length != 0)
            try self.importAnswerProjection(binding, output)
        else
            null;
        if (answer_id) |content_id| {
            const insert = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "VALUES(?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+1,?2,3,?3,NULL,NULL,?4,?5)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, session_ref.slice());
            try bindU64(insert, 2, current.next_position);
            try bindU64(insert, 3, binding.turn_id);
            try bindU64(insert, 4, binding.operation_id);
            try bindI64(insert, 5, content_id);
            try expectDone(insert);
            current.next_position = try std.math.add(u64, current.next_position, 1);
        }
        const pending = try self.countPendingMessages(session_ref.slice());
        const resolution_code = if (output.call_count != 0) "tool_calls" else if (pending == 0) "completed" else "continued";
        {
            const update = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,body_model=?5,openai_model=?6,x_openai_model=?7,request_id=?8,usage_content_id=?9 " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?10",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, binding.operation_id);
            try bindText(update, 2, resolution_code);
            try bindNullableI64(update, 3, answer_id);
            try bindOptionalText(update, 4, output.response_id.slice());
            try bindOptionalText(update, 5, output.body_model.slice());
            try bindOptionalText(update, 6, output.openai_model.slice());
            try bindOptionalText(update, 7, output.x_openai_model.slice());
            try bindOptionalText(update, 8, output.request_id.slice());
            try bindNullableI64(update, 9, usage_id);
            try bindU64(update, 10, binding.attempt_ordinal);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        if (output.call_count == 0 and pending == 0) {
            const update = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='completed',outcome_content_id=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, binding.turn_id);
            try bindI64(update, 2, answer_id.?);
            try bindU64(update, 3, binding.operation_id);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        {
            const update = try prepare(self.database, "UPDATE session SET next_position=?2 WHERE session_ref=?1");
            defer _ = c.sqlite3_finalize(update);
            try bindText(update, 1, session_ref.slice());
            try bindU64(update, 2, current.next_position);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SessionUpdateFailed;
        }
        if (faults.output_commit) return error.InjectedOutputCommitFailure;
        try exec(self.database, "COMMIT");
    }

    const ContentSlot = struct { id: i64, existing: bool };

    fn rejectionResult(
        io: std.Io,
        source_file: std.Io.File,
        code: []const u8,
        name: OutputMetadataRecord,
        buffer: *[192]u8,
    ) ![]const u8 {
        if (std.mem.eql(u8, code, "unknown_tool")) {
            var decoded = try EncodedStringReader.init(io, source_file, name);
            var prefix: [32]u8 = undefined;
            var prefix_length: usize = 0;
            while (prefix_length < prefix.len) {
                prefix[prefix_length] = (try decoded.next()) orelse break;
                prefix_length += 1;
            }
            while (!std.unicode.utf8ValidateSlice(prefix[0..prefix_length])) prefix_length -= 1;
            if (name.decoded_length <= prefix.len) {
                return std.fmt.bufPrint(buffer, "Unknown tool: {s}.", .{prefix[0..prefix_length]});
            }
            const digest_hex = std.fmt.bytesToHex(name.content_digest, .lower);
            return std.fmt.bufPrint(buffer, "Unknown tool: {s}… (name continues; Rui content digest {s}).", .{
                prefix[0..prefix_length],
                &digest_hex,
            });
        }
        if (std.mem.eql(u8, code, "invalid_arguments")) return "Invalid arguments for tool 'bash'.";
        if (std.mem.eql(u8, code, "tool_unavailable")) return "Tool 'edit' is unavailable.";
        return error.CorruptStore;
    }

    fn contentSlot(self: *Store, digest: *const [32]u8, length: u64, private: bool) !ContentSlot {
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, digest);
        try bindU64(find, 2, length);
        try bindI64(find, 3, @as(i64, if (private) 1 else 0));
        const result = c.sqlite3_step(find);
        if (result == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(find, 0);
            if (id <= 0) return error.CorruptStore;
            return .{ .id = id, .existing = true };
        }
        if (result != c.SQLITE_DONE) return error.ContentReadFailed;
        const insert = try prepare(
            self.database,
            "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,zeroblob(?2),?3)",
        );
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, digest);
        try bindU64(insert, 2, length);
        try bindI64(insert, 3, @as(i64, if (private) 1 else 0));
        try expectDone(insert);
        const id = c.sqlite3_last_insert_rowid(self.database);
        if (id <= 0) return error.ContentWriteFailed;
        return .{ .id = id, .existing = false };
    }

    fn importBytesContent(self: *Store, bytes: []const u8, private: bool, fail_import: bool) !i64 {
        if (fail_import) return error.InjectedContentImportFailure;
        const digest = protocol.contentDigest(bytes);
        const slot = try self.contentSlot(&digest, bytes.len, private);
        if (slot.existing or bytes.len == 0) return slot.id;
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        if (c.sqlite3_blob_write(blob, bytes.ptr, @intCast(bytes.len), 0) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        return slot.id;
    }

    fn importSourceRange(
        self: *Store,
        file: std.Io.File,
        source_length: u64,
        start: u64,
        length: u64,
        digest: *const [32]u8,
        private: bool,
        faults: Faults,
    ) !i64 {
        const end = try std.math.add(u64, start, length);
        if (end > source_length) return error.CorruptOutputMetadata;
        const slot = try self.contentSlot(digest, length, private);
        var blob: ?*c.sqlite3_blob = null;
        if (!slot.existing and length != 0) {
            if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
        }
        defer if (blob) |value| {
            _ = c.sqlite3_blob_close(value);
        };
        var hash = protocol.contentHasher();
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < length) {
            const wanted: usize = @intCast(@min(length - offset, buffer.len));
            const count = try file.readPositionalAll(self.io, buffer[0..wanted], start + offset);
            if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
            hash.update(buffer[0..count]);
            if (blob) |value| {
                if (c.sqlite3_blob_write(value, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                    return error.ContentWriteFailed;
                }
            }
            if (faults.output_import) return error.InjectedOutputImportFailure;
            offset += count;
        }
        if (!std.mem.eql(u8, &hash.finalResult(), digest)) return error.OutputSourceChanged;
        return slot.id;
    }

    fn importAnswerProjection(self: *Store, binding: AttemptBinding, output: *const ValidatedOutput) !i64 {
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=0");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &output.answer_digest);
        try bindU64(find, 2, output.answer_length);
        const found = c.sqlite3_step(find);
        if (found != c.SQLITE_ROW and found != c.SQLITE_DONE) return error.ContentReadFailed;
        const existing = found == c.SQLITE_ROW;
        const answer_id = if (existing) c.sqlite3_column_int64(find, 0) else blk: {
            const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,NULL,0)");
            defer _ = c.sqlite3_finalize(insert);
            try bindBlob(insert, 1, &output.answer_digest);
            try bindU64(insert, 2, output.answer_length);
            try expectDone(insert);
            break :blk c.sqlite3_last_insert_rowid(self.database);
        };
        if (answer_id <= 0) return error.CorruptStore;
        var decoded_offset: u64 = 0;
        var part: u64 = 0;
        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var items = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var item = try items.nextItem();
        while (try metadata.next()) |record| {
            if (record.tag != .text) continue;
            while (item != null and item.?.ordinal < record.ordinal) item = try items.nextItem();
            const owner = item orelse return error.CorruptOutputMetadata;
            if (owner.ordinal != record.ordinal or owner.kind != .message or record.start < owner.start or
                record.length > owner.length or record.start - owner.start > owner.length - record.length)
                return error.CorruptOutputMetadata;
            // The validator owns decoded metadata; raw item import already
            // verified its exact bytes. No second decoded payload pass is needed.
            decoded_offset = try std.math.add(u64, decoded_offset, record.decoded_length);
            if (!existing) {
                const insert = try prepare(self.database, "INSERT INTO answer_text_projection(answer_content_id,part_ordinal,source_content_id,encoded_start,encoded_length,decoded_length) " ++
                    "SELECT ?1,?2,content_id,?3,?4,?5 FROM model_output_item WHERE operation_id=?6 AND item_ordinal=?7");
                defer _ = c.sqlite3_finalize(insert);
                try bindI64(insert, 1, answer_id);
                try bindU64(insert, 2, part);
                try bindU64(insert, 3, record.start - owner.start);
                try bindU64(insert, 4, record.length);
                try bindU64(insert, 5, record.decoded_length);
                try bindU64(insert, 6, binding.operation_id);
                try bindU64(insert, 7, record.ordinal);
                try expectDone(insert);
                if (c.sqlite3_changes(self.database) != 1) return error.CorruptOutputMetadata;
            }
            part += 1;
        }
        if (decoded_offset != output.answer_length) return error.OutputSourceChanged;
        return answer_id;
    }

    fn importStringProjection(
        self: *Store,
        binding: AttemptBinding,
        record: OutputMetadataRecord,
        item: OutputMetadataRecord,
    ) !i64 {
        if (item.kind != .function_call or record.start < item.start or record.length > item.length or
            record.start - item.start > item.length - record.length) return error.CorruptOutputMetadata;
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=0");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &record.content_digest);
        try bindU64(find, 2, record.decoded_length);
        const found = c.sqlite3_step(find);
        if (found != c.SQLITE_ROW and found != c.SQLITE_DONE) return error.ContentReadFailed;
        const existing = found == c.SQLITE_ROW;
        const content_id = if (existing) c.sqlite3_column_int64(find, 0) else blk: {
            const insert_content = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,NULL,0)");
            defer _ = c.sqlite3_finalize(insert_content);
            try bindBlob(insert_content, 1, &record.content_digest);
            try bindU64(insert_content, 2, record.decoded_length);
            try expectDone(insert_content);
            break :blk c.sqlite3_last_insert_rowid(self.database);
        };
        if (content_id <= 0) return error.CorruptStore;
        if (!existing) {
            const insert = try prepare(
                self.database,
                "INSERT INTO answer_text_projection(answer_content_id,part_ordinal,source_content_id,encoded_start,encoded_length,decoded_length) " ++
                    "SELECT ?1,0,content_id,?2,?3,?4 FROM model_output_item WHERE operation_id=?5 AND item_ordinal=?6",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindI64(insert, 1, content_id);
            try bindU64(insert, 2, record.start - item.start);
            try bindU64(insert, 3, record.length);
            try bindU64(insert, 4, record.decoded_length);
            try bindU64(insert, 5, binding.operation_id);
            try bindU64(insert, 6, record.ordinal);
            try expectDone(insert);
            if (c.sqlite3_changes(self.database) != 1) return error.CorruptOutputMetadata;
        }
        return content_id;
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentReader {
        return self.openContentIdentity(reference, false);
    }

    fn openContentIdentity(self: *Store, reference: ContentReference, private: bool) !ContentReader {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.openContentIdentityLocked(reference, private) catch |err|
            return self.fenceReadFailure(err);
    }

    fn openContentIdentityLocked(self: *Store, reference: ContentReference, private: bool) !ContentReader {
        const id = try self.resolveContentReference(reference, private);
        const statement = try prepare(self.database, "SELECT payload IS NULL FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        return .{ .store = self, .reference = reference, .content_id = id, .representation = if (c.sqlite3_column_int(statement, 0) == 0) .raw else .{ .projection = .{} } };
    }

    fn readOwnedContent(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !usize {
        if (destination.len > ContentReader.content_window_bytes) return error.WindowTooLarge;
        if (start > reader.reference.length) return error.RangeOutOfBounds;
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const wanted: usize = @intCast(@min(destination.len, reader.reference.length - start));
        return self.readOwnedContentLocked(reader, start, destination[0..wanted]) catch |err| return self.fenceReadFailure(err);
    }

    fn readOwnedContentLocked(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !usize {
        switch (reader.representation) {
            .raw => try self.readBlob(reader.content_id, start, destination),
            .projection => |*cursor| {
                std.debug.assert(start == cursor.decoded_position);
                var filled: usize = 0;
                while (filled < destination.len) {
                    if (cursor.pending_start < cursor.pending_end) {
                        const count = @min(destination.len - filled, cursor.pending_end - cursor.pending_start);
                        @memcpy(destination[filled..][0..count], cursor.pending[cursor.pending_start..][0..count]);
                        cursor.pending_start += count;
                        cursor.decoded_position += count;
                        filled += count;
                        continue;
                    }
                    if (cursor.encoded_position == cursor.encoded_end) {
                        if (cursor.part_decoded != cursor.expected_decoded) return error.CorruptStore;
                        const row = try prepare(self.database, "SELECT source_content_id,encoded_start,encoded_length,decoded_length FROM answer_text_projection " ++
                            "WHERE answer_content_id=?1 AND part_ordinal=?2");
                        defer _ = c.sqlite3_finalize(row);
                        try bindI64(row, 1, reader.content_id);
                        try bindU64(row, 2, cursor.next_part);
                        if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.CorruptStore;
                        cursor.source_id = c.sqlite3_column_int64(row, 0);
                        cursor.encoded_position = @intCast(c.sqlite3_column_int64(row, 1));
                        cursor.encoded_end = try std.math.add(u64, cursor.encoded_position, @intCast(c.sqlite3_column_int64(row, 2)));
                        cursor.expected_decoded = @intCast(c.sqlite3_column_int64(row, 3));
                        cursor.part_decoded = 0;
                        cursor.buffer_length = 0;
                        cursor.next_part += 1;
                        if (cursor.encoded_position == cursor.encoded_end) continue;
                    }
                    var source = ProjectedByteSource{ .store = self, .cursor = cursor };
                    cursor.pending_end = try decodeOutputScalar(&source, &cursor.pending);
                    cursor.pending_start = 0;
                    cursor.part_decoded += cursor.pending_end;
                }
                if (cursor.decoded_position == reader.reference.length and
                    (cursor.pending_start != cursor.pending_end or cursor.encoded_position != cursor.encoded_end or
                        cursor.part_decoded != cursor.expected_decoded)) return error.CorruptStore;
            },
        }
        return destination.len;
    }

    // Called only while the Store mutex is held; the blob handle never crosses
    // a delivery or adapter callback boundary.
    fn readBlob(self: *Store, content_id: i64, start: u64, destination: []u8) !void {
        if (destination.len == 0) return;
        if (start > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob) != c.SQLITE_OK) return error.ContentReadFailed;
        defer _ = c.sqlite3_blob_close(blob);
        if (c.sqlite3_blob_read(blob, destination.ptr, @intCast(destination.len), @intCast(start)) != c.SQLITE_OK) return error.ContentReadFailed;
    }

    fn fenceReadFailure(self: *Store, err: anyerror) anyerror {
        self.fenced.store(true, .release);
        return err;
    }

    fn finishTransactionError(
        self: *Store,
        err: anyerror,
        faults: Faults,
        preserve_expected: bool,
    ) anyerror {
        self.rollbackAfterError(faults) catch |rollback_err| {
            self.fenced.store(true, .release);
            return rollback_err;
        };
        if (!preserve_expected) self.fenced.store(true, .release);
        return err;
    }

    fn finishTransactionFailure(self: *Store, faults: Faults) void {
        self.rollbackAfterError(faults) catch {};
        self.fenced.store(true, .release);
    }

    fn rollbackAfterError(self: *Store, faults: Faults) !void {
        if (c.sqlite3_get_autocommit(self.database) != 0) return;
        if (faults.rollback_failure) return error.CanonicalRollbackFailed;
        if (c.sqlite3_exec(self.database, "ROLLBACK", null, null, null) != c.SQLITE_OK or
            c.sqlite3_get_autocommit(self.database) == 0)
        {
            return error.CanonicalRollbackFailed;
        }
    }

    const ExistingCommand = struct {
        kind: CommandKind,
        target: protocol.Bounded(protocol.max_session_bytes),
        digest: [32]u8,
        accepted: bool,
        code: protocol.Bounded(96),
        revision: u64,
        created: bool,
        primary_content_id: ?i64,
    };

    fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
        const statement = try prepare(self.database, "SELECT kind,target,input_digest,accepted,code,revision,created,primary_content_id FROM core_command WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return null;
        if (step_result != c.SQLITE_ROW) return error.CommandReadFailed;
        const kind_value = c.sqlite3_column_int(statement, 0);
        const kind: CommandKind = switch (kind_value) {
            1 => .configure,
            2 => .message,
            3 => .session_stop,
            4 => .model_interruption,
            5 => .permission_decision,
            else => return error.CorruptStore,
        };
        var target: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 1, &target);
        const digest = try readDigest(statement, 2);
        const accepted_value = c.sqlite3_column_int(statement, 3);
        if (accepted_value != 0 and accepted_value != 1) return error.CorruptStore;
        var code: protocol.Bounded(96) = .{};
        try readText(statement, 4, &code);
        const revision_value = c.sqlite3_column_int64(statement, 5);
        if (revision_value < 0) return error.CorruptStore;
        const created_value = c.sqlite3_column_int(statement, 6);
        if (created_value != 0 and created_value != 1) return error.CorruptStore;
        const primary_content_id = readNullablePositiveI64(statement, 7) catch return error.CorruptStore;
        return .{
            .kind = kind,
            .target = target,
            .digest = digest,
            .accepted = accepted_value == 1,
            .code = code,
            .revision = @intCast(revision_value),
            .created = created_value == 1,
            .primary_content_id = primary_content_id,
        };
    }

    fn readMessageAdmission(
        self: *Store,
        command_key: []const u8,
        session_ref: []const u8,
        content_id: i64,
    ) !u64 {
        const statement = try prepare(self.database, "SELECT admission_id,session_ref,content_id FROM message_admission WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const admission_id = c.sqlite3_column_int64(statement, 0);
        var stored_session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 1, &stored_session);
        if (admission_id <= 0 or
            !stored_session.eql(session_ref) or
            c.sqlite3_column_int64(statement, 2) != content_id)
        {
            return error.CorruptStore;
        }
        return @intCast(admission_id);
    }

    fn countPendingMessages(self: *Store, session_ref: []const u8) !u64 {
        const cutoff = try self.latestSessionStopCutoff(session_ref);
        const statement = try prepare(self.database, pending_message_count_sql);
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, cutoff);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.MessageAdmissionReadFailed;
        const count = c.sqlite3_column_int64(statement, 0);
        if (count < 0) return error.CorruptStore;
        return @intCast(count);
    }

    fn hasApplicablePendingMessage(self: *Store, session_ref: []const u8) !bool {
        const cutoff = try self.latestSessionStopCutoff(session_ref);
        const statement = try prepare(
            self.database,
            "SELECT 1 FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, cutoff);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.MessageAdmissionReadFailed,
        };
    }

    fn latestSessionStopCutoff(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(self.database, session_stop_cutoff_sql);
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => 0,
            c.SQLITE_ROW => blk: {
                const cutoff = c.sqlite3_column_int64(statement, 0);
                if (cutoff < 0) return error.CorruptStore;
                break :blk @intCast(cutoff);
            },
            else => error.SessionStopReadFailed,
        };
    }

    fn readSessionStopSelection(self: *Store, command_key: []const u8) !SessionStopSelection {
        const statement = try prepare(
            self.database,
            "SELECT selected_turn_id,admission_cutoff FROM session_stop WHERE command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const cutoff = c.sqlite3_column_int64(statement, 1);
        if (cutoff < 0) return error.CorruptStore;
        return .{
            .selected_turn_id = if (try readNullablePositiveI64(statement, 0)) |value| @intCast(value) else null,
            .admission_cutoff = @intCast(cutoff),
        };
    }

    fn readInterruptedOperation(self: *Store, command_key: []const u8) !?u64 {
        const statement = try prepare(
            self.database,
            "SELECT operation_id FROM model_operation WHERE interrupted_by_command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.CorruptStore;
        const operation_id = c.sqlite3_column_int64(statement, 0);
        if (operation_id <= 0 or c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptStore;
        return @intCast(operation_id);
    }

    fn readModelInterruptionTarget(self: *Store, command_key: []const u8) !ModelInterruptionTarget {
        const statement = try prepare(
            self.database,
            "SELECT session_ref,turn_id,operation_id FROM model_interruption_command WHERE command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var target = ModelInterruptionTarget{
            .session = .{},
            .turn_id = 0,
            .operation_id = 0,
        };
        try readText(statement, 0, &target.session);
        var turn_text: protocol.Bounded(20) = .{};
        try readText(statement, 1, &turn_text);
        var operation_text: protocol.Bounded(20) = .{};
        try readText(statement, 2, &operation_text);
        target.turn_id = std.fmt.parseInt(u64, turn_text.slice(), 10) catch return error.CorruptStore;
        target.operation_id = std.fmt.parseInt(u64, operation_text.slice(), 10) catch return error.CorruptStore;
        return target;
    }

    const PermissionTarget = struct {
        action_id: u64,
        decision: protocol.PermissionDecision,
    };

    fn readPermissionTarget(self: *Store, command_key: []const u8) !PermissionTarget {
        const statement = try prepare(self.database, "SELECT action_id,decision FROM permission_decision_command WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var value: protocol.Bounded(20) = .{};
        try readText(statement, 0, &value);
        var decision: protocol.Bounded(16) = .{};
        try readText(statement, 1, &decision);
        return .{
            .action_id = std.fmt.parseInt(u64, value.slice(), 10) catch return error.CorruptStore,
            .decision = std.meta.stringToEnum(protocol.PermissionDecision, decision.slice()) orelse
                return error.CorruptStore,
        };
    }

    fn turnIsComplete(self: *Store, turn_id: u64) !bool {
        const statement = try prepare(self.database, "SELECT outcome_code FROM turn WHERE turn_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        return c.sqlite3_column_type(statement, 0) != c.SQLITE_NULL;
    }

    fn readSession(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
        const statement = try prepare(self.database, "SELECT workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position FROM session WHERE session_ref=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return null;
        if (step_result != c.SQLITE_ROW) return error.SessionReadFailed;
        var current: CurrentConfiguration = .{};
        try readText(statement, 0, &current.workspace);
        try readText(statement, 1, &current.model);
        current.instructions_id = (readNullablePositiveI64(statement, 2) catch return error.CorruptStore) orelse
            return error.CorruptStore;
        const tools = c.sqlite3_column_int(statement, 3);
        if (tools < 0 or tools > 3) return error.CorruptStore;
        current.tools_mask = @intCast(tools);
        const permission = c.sqlite3_column_int(statement, 4);
        if (permission < 0 or permission > 1) return error.CorruptStore;
        current.permission_mode = @intCast(permission);
        current.output_schema_id = readNullablePositiveI64(statement, 5) catch return error.CorruptStore;
        const revision = c.sqlite3_column_int64(statement, 6);
        if (revision <= 0) return error.CorruptStore;
        current.revision = @intCast(revision);
        const next_position = c.sqlite3_column_int64(statement, 7);
        if (next_position <= 0) return error.CorruptStore;
        current.next_position = @intCast(next_position);
        return current;
    }

    fn insertSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
    }

    fn updateSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "UPDATE session SET workspace=?2,model=?3,instructions_content_id=?4,tools_mask=?5,permission_mode=?6,output_schema_content_id=?7,revision=?8,next_position=?9 WHERE session_ref=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.SessionUpdateFailed;
    }

    fn insertRevision(
        self: *Store,
        session_ref: []const u8,
        command_key: []const u8,
        current: *const CurrentConfiguration,
        instructions_updated: bool,
    ) !void {
        const statement = try prepare(self.database, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, current.revision);
        try bindText(statement, 3, command_key);
        try bindText(statement, 4, current.workspace.slice());
        try bindText(statement, 5, current.model.slice());
        try bindNullableI64(statement, 6, current.instructions_id);
        try bindI64(statement, 7, @as(i64, if (instructions_updated) 1 else 0));
        try bindI64(statement, 8, current.tools_mask);
        try bindI64(statement, 9, current.permission_mode);
        try bindNullableI64(statement, 10, current.output_schema_id);
        try expectDone(statement);
    }

    fn insertCommand(
        self: *Store,
        key: []const u8,
        kind: CommandKind,
        target: []const u8,
        digest: *const [32]u8,
        primary_content_id: ?i64,
        secondary_content_id: ?i64,
        answer: StoredAnswer,
    ) !void {
        const statement = try prepare(self.database, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        const kind_value: i64 = switch (kind) {
            .configure => 1,
            .message => 2,
            .session_stop => 3,
            .model_interruption => 4,
            .permission_decision => 5,
        };
        try bindI64(statement, 2, kind_value);
        try bindText(statement, 3, target);
        try bindBlob(statement, 4, digest);
        try bindNullableI64(statement, 5, primary_content_id);
        try bindNullableI64(statement, 6, secondary_content_id);
        const accepted_value: i64 = if (answer.accepted) 1 else 0;
        try bindI64(statement, 7, accepted_value);
        try bindText(statement, 8, answer.code.slice());
        try bindU64(statement, 9, answer.revision);
        const created_value: i64 = if (answer.created) 1 else 0;
        try bindI64(statement, 10, created_value);
        try expectDone(statement);
    }

    fn insertMessageAdmission(
        self: *Store,
        session_ref: []const u8,
        command_key: []const u8,
        content_id: i64,
    ) !u64 {
        const latest = try prepare(self.database, "SELECT admission_id FROM message_admission ORDER BY admission_id DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(latest);
        const latest_result = c.sqlite3_step(latest);
        const admission_id: u64 = if (latest_result == c.SQLITE_DONE)
            1
        else if (latest_result == c.SQLITE_ROW) blk: {
            const prior = c.sqlite3_column_int64(latest, 0);
            if (prior <= 0 or prior == std.math.maxInt(i64)) {
                return error.MessageAdmissionIdentityExhausted;
            }
            break :blk @intCast(prior + 1);
        } else return error.MessageAdmissionReadFailed;
        const statement = try prepare(self.database, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id) VALUES(?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, admission_id);
        try bindText(statement, 2, session_ref);
        try bindText(statement, 3, command_key);
        try bindI64(statement, 4, content_id);
        try expectDone(statement);
        return admission_id;
    }

    fn importEmptyContent(self: *Store) !i64 {
        var empty: protocol.ContentField = .{ .state = .value };
        empty.digest = protocol.contentDigest("");
        return self.importContent(&empty, .{});
    }

    fn importContent(self: *Store, content: *const protocol.ContentField, faults: Faults) !i64 {
        std.debug.assert(content.state == .value);
        if (content.file) |source| {
            if (try source.length(self.io) != content.length) return error.ContentChanged;
        } else if (content.length != 0 or
            !std.mem.eql(u8, &protocol.contentDigest(""), &content.digest))
        {
            return error.MissingContentCustody;
        }
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=0");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &content.digest);
        try bindU64(find, 2, content.length);
        const find_result = c.sqlite3_step(find);
        if (find_result == c.SQLITE_ROW) {
            const content_id = c.sqlite3_column_int64(find, 0);
            if (content_id <= 0) return error.CorruptStore;
            if (content.file) |source| {
                try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
            }
            return content_id;
        }
        if (find_result != c.SQLITE_DONE) return error.ContentReadFailed;

        const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,zeroblob(?2),0)");
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, &content.digest);
        try bindU64(insert, 2, content.length);
        try expectDone(insert);
        const content_id = c.sqlite3_last_insert_rowid(self.database);
        if (content_id <= 0) return error.ContentWriteFailed;

        if (content.length == 0) {
            if (content.file) |source| {
                try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
            }
            return content_id;
        }
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        const file = content.file orelse return error.MissingContentCustody;
        // Verify the exact bytes copied while the row is still uncommitted.
        // The caller rolls back the whole transaction if verification fails.
        try verifyExternalContent(self.io, file, content.length, &content.digest, blob, faults);
        return content_id;
    }

    const ContentMetadata = struct { length: u64, digest: [32]u8 };

    fn readContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
        const statement = try prepare(self.database, "SELECT byte_length,digest FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const length = c.sqlite3_column_int64(statement, 0);
        if (length < 0) return error.CorruptStore;
        return .{ .length = @intCast(length), .digest = try readDigest(statement, 1) };
    }

    fn resolveContentReference(self: *Store, reference: ContentReference, private: bool) !i64 {
        const statement = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3");
        defer _ = c.sqlite3_finalize(statement);
        try bindBlob(statement, 1, &reference.digest);
        try bindU64(statement, 2, reference.length);
        try bindI64(statement, 3, @as(i64, if (private) 1 else 0));
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const content_id = c.sqlite3_column_int64(statement, 0);
        if (content_id <= 0) return error.CorruptStore;
        return content_id;
    }
};

fn validateWorkspace(io: std.Io, supplied: []const u8, destination: anytype) !void {
    if (!std.fs.path.isAbsolute(supplied)) return error.WorkspaceMustBeAbsolute;
    if (std.mem.indexOfScalar(u8, supplied, 0) != null) return error.InvalidWorkspace;
    var directory = try std.Io.Dir.cwd().openDir(io, supplied, .{});
    defer directory.close(io);
    var canonical: [protocol.max_workspace_bytes]u8 = undefined;
    const length = try directory.realPath(io, &canonical);
    try destination.set(canonical[0..length]);
}

fn verifyExternalContent(
    io: std.Io,
    file: std.Io.File,
    expected_length: u64,
    expected_digest: *const [32]u8,
    destination: ?*c.sqlite3_blob,
    faults: Faults,
) !void {
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    var hash = protocol.contentHasher();
    while (offset < expected_length) {
        const wanted: usize = @intCast(@min(expected_length - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count != wanted) return error.ContentReadFailed;
        if (faults.content_read) return error.InjectedContentReadFailure;
        hash.update(buffer[0..count]);
        if (destination) |blob| {
            if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
            if (c.sqlite3_blob_write(blob, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
            if (faults.content_import) return error.InjectedContentImportFailure;
        }
        offset += count;
    }
    if (try file.length(io) != expected_length) return error.ContentChanged;
    if (!std.mem.eql(u8, &hash.finalResult(), expected_digest)) return error.ContentChanged;
}

// Batch canonical BLOB reads independently of the caller delivery window.
// One fixed window is owned per reader, including readers of raw content.
const projection_read_window_bytes = 4 * 1024;

// One cursor per open reader, independent of answer size and part count.
const ProjectionCursor = struct {
    next_part: u64 = 0,
    decoded_position: u64 = 0,
    source_id: i64 = 0,
    encoded_position: u64 = 0,
    encoded_end: u64 = 0,
    expected_decoded: u64 = 0,
    part_decoded: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [projection_read_window_bytes]u8 = undefined,
    pending: [4]u8 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,
};

const ProjectedByteSource = struct {
    store: *Store,
    cursor: *ProjectionCursor,

    fn take(self: *ProjectedByteSource) !u8 {
        const cursor = self.cursor;
        if (cursor.encoded_position == cursor.encoded_end) return error.IncompleteJsonString;
        if (cursor.buffer_length == 0 or cursor.encoded_position >= cursor.buffer_start + cursor.buffer_length) {
            cursor.buffer_start = cursor.encoded_position;
            cursor.buffer_length = @intCast(@min(cursor.encoded_end - cursor.encoded_position, cursor.buffer.len));
            try self.store.readBlob(cursor.source_id, cursor.buffer_start, cursor.buffer[0..cursor.buffer_length]);
        }
        const byte = cursor.buffer[@intCast(cursor.encoded_position - cursor.buffer_start)];
        cursor.encoded_position += 1;
        return byte;
    }
};

fn decodeOutputScalar(source: anytype, encoded: *[4]u8) !usize {
    const byte = try source.take();
    if (byte != '\\') {
        encoded[0] = byte;
        return 1;
    }
    const escape = try source.take();
    encoded[0] = switch (escape) {
        '"', '\\', '/' => escape,
        'b' => 8,
        'f' => 12,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => {
            var scalar = try readOutputHex(source);
            if (scalar >= 0xd800 and scalar <= 0xdbff) {
                if (try source.take() != '\\' or try source.take() != 'u') return error.InvalidJsonSurrogate;
                const low = try readOutputHex(source);
                if (low < 0xdc00 or low > 0xdfff) return error.InvalidJsonSurrogate;
                scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
            } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidJsonSurrogate;
            return try std.unicode.utf8Encode(scalar, encoded);
        },
        else => return error.InvalidJsonEscape,
    };
    return 1;
}

fn readOutputHex(source: anytype) !u21 {
    var value: u21 = 0;
    for (0..4) |_| {
        const byte = try source.take();
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidJsonEscape,
        };
        value = value * 16 + digit;
    }
    return value;
}

fn validateJsonFile(io: std.Io, file: std.Io.File) !bool {
    var read_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var json_reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer json_reader.deinit();
    try json_reader.ensureTotalStackCapacity(protocol.max_json_depth);
    while (true) {
        const token = json_reader.next() catch |err| switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => return false,
            else => return err,
        };
        if (json_reader.stackHeight() > protocol.max_json_depth) return false;
        if (token == .end_of_document) return true;
    }
}

fn bootstrap(database: *c.sqlite3, selector: []const u8) !void {
    try exec(database, "BEGIN EXCLUSIVE");
    errdefer rollback(database);
    try exec(database,
        \\CREATE TABLE store_meta(
        \\ key TEXT PRIMARY KEY,
        \\ value TEXT NOT NULL
        \\) STRICT;
        \\CREATE TABLE content(
        \\ content_id INTEGER PRIMARY KEY,
        \\ digest BLOB NOT NULL CHECK(length(digest)=32),
        \\ byte_length INTEGER NOT NULL CHECK(byte_length>=0 AND byte_length<=1073737728),
        \\ payload BLOB CHECK(payload IS NULL OR length(payload)=byte_length),
        \\ private INTEGER NOT NULL CHECK(private IN (0,1) AND (private=0 OR payload IS NOT NULL)),
        \\ UNIQUE(digest,byte_length,private)
        \\) STRICT;
        \\CREATE TABLE session(
        \\ session_ref TEXT PRIMARY KEY CHECK(length(CAST(session_ref AS BLOB)) BETWEEN 1 AND 128),
        \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
        \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND 3),
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ next_position INTEGER NOT NULL CHECK(next_position>0)
        \\) STRICT;
        \\CREATE TABLE core_command(
        \\ command_key TEXT PRIMARY KEY CHECK(length(CAST(command_key AS BLOB))<=128),
        \\ kind INTEGER NOT NULL CHECK(kind IN (1,2,3,4,5)),
        \\ target TEXT NOT NULL CHECK(length(CAST(target AS BLOB))<=128),
        \\ input_digest BLOB NOT NULL CHECK(length(input_digest)=32),
        \\ primary_content_id INTEGER REFERENCES content(content_id),
        \\ secondary_content_id INTEGER REFERENCES content(content_id),
        \\ accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
        \\ code TEXT NOT NULL CHECK(length(CAST(code AS BLOB))<=96),
        \\ revision INTEGER NOT NULL CHECK(revision>=0),
        \\ created INTEGER NOT NULL CHECK(created IN (0,1))
        \\) STRICT;
        \\CREATE TABLE session_revision(
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ workspace TEXT NOT NULL,
        \\ model TEXT NOT NULL,
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
        \\ tools_mask INTEGER NOT NULL,
        \\ permission_mode INTEGER NOT NULL,
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,revision)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE message_admission(
        \\ admission_id INTEGER PRIMARY KEY CHECK(admission_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ turn_id INTEGER REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED
        \\) STRICT;
        \\CREATE TABLE turn(
        \\ turn_id INTEGER PRIMARY KEY CHECK(turn_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ first_admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id) DEFERRABLE INITIALLY DEFERRED,
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>=first_admission_id),
        \\ operation_id INTEGER NOT NULL,
        \\ outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96),
        \\ outcome_content_id INTEGER REFERENCES content(content_id)
        \\) STRICT;
        \\CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
        \\CREATE TABLE session_stop(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ selected_turn_id INTEGER REFERENCES turn(turn_id),
        \\ admission_cutoff INTEGER NOT NULL CHECK(admission_cutoff>=0)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_interruption_command(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL CHECK(length(CAST(session_ref AS BLOB))<=128),
        \\ turn_id TEXT NOT NULL CHECK(length(turn_id) BETWEEN 1 AND 20),
        \\ operation_id TEXT NOT NULL CHECK(length(operation_id) BETWEEN 1 AND 20)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_operation(
        \\ operation_id INTEGER PRIMARY KEY CHECK(operation_id>0),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ session_ref TEXT NOT NULL,
        \\ settings_revision INTEGER NOT NULL CHECK(settings_revision>0),
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),
        \\ admission_position INTEGER NOT NULL CHECK(admission_position>0),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ allowance_used INTEGER NOT NULL CHECK(allowance_used BETWEEN 1 AND 4),
        \\ uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
        \\ retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
        \\ last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),
        \\ body_model TEXT CHECK(body_model IS NULL OR length(CAST(body_model AS BLOB))<=256),
        \\ openai_model TEXT CHECK(openai_model IS NULL OR length(CAST(openai_model AS BLOB))<=256),
        \\ x_openai_model TEXT CHECK(x_openai_model IS NULL OR length(CAST(x_openai_model AS BLOB))<=256),
        \\ request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),
        \\ usage_content_id INTEGER REFERENCES content(content_id),
        \\ interrupted_by_command_key TEXT REFERENCES core_command(command_key),
        \\ FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK((resolution_code IS NULL AND ((uncertain=1 AND retry_due_at_ms=0) OR (uncertain=0 AND retry_due_at_ms>0))) OR
        \\       (resolution_code IS NOT NULL AND uncertain=0 AND retry_due_at_ms IS NULL)),
        \\ CHECK((resolution_code='interrupted' AND interrupted_by_command_key IS NOT NULL) OR
        \\       (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),
        \\ UNIQUE(operation_id,session_ref)
        \\) STRICT;
        \\CREATE TABLE conversation_entry(
        \\ session_ref TEXT NOT NULL,
        \\ entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ entry_kind INTEGER NOT NULL CHECK(entry_kind IN (1,2,3)),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
        \\ source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),
        \\ source_revision INTEGER,
        \\ source_operation_id INTEGER REFERENCES model_operation(operation_id),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,entry_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ UNIQUE(session_ref,source_revision),
        \\ FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_output_item(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ session_ref TEXT NOT NULL,
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ item_kind INTEGER NOT NULL CHECK(item_kind IN (1,2,3)),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ item_id_digest BLOB NOT NULL CHECK(length(item_id_digest)=32),
        \\ PRIMARY KEY(operation_id,item_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ UNIQUE(operation_id,item_id_digest)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_tool_call(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ item_id_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ name_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ call_id_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ arguments_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ rejection_code TEXT CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments','tool_unavailable')),
        \\ rejection_content_id INTEGER REFERENCES content(content_id),
        \\ acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
        \\ action_kind INTEGER CHECK(action_kind IS NULL OR action_kind=1),
        \\ PRIMARY KEY(operation_id,call_ordinal),
        \\ UNIQUE(operation_id,item_ordinal),
        \\ UNIQUE(operation_id,call_id_content_id),
        \\ UNIQUE(operation_id,call_ordinal,action_kind),
        \\ CHECK((rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND action_kind=1) OR
        \\       (rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE action_operation(
        \\ action_id INTEGER PRIMARY KEY CHECK(action_id>0),
        \\ parent_operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ tool_kind INTEGER NOT NULL CHECK(tool_kind=1),
        \\ permission_revision INTEGER NOT NULL CHECK(permission_revision>0),
        \\ permission_state INTEGER NOT NULL CHECK(permission_state IN (0,1,2)),
        \\ attempt_ordinal INTEGER NOT NULL DEFAULT 0 CHECK(attempt_ordinal IN (0,1)),
        \\ bash_timeout_override_ms INTEGER CHECK(bash_timeout_override_ms IS NULL OR bash_timeout_override_ms>0),
        \\ bash_timeout_ms INTEGER CHECK(bash_timeout_ms IS NULL OR bash_timeout_ms>0),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR resolution_code IN ('denied','cancelled','succeeded','failed','timed_out','indeterminate','storage_failed','spawn_failed','infrastructure_shutdown')),
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
        \\ UNIQUE(parent_operation_id,call_ordinal),
        \\ FOREIGN KEY(parent_operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
        \\ FOREIGN KEY(parent_operation_id,call_ordinal,tool_kind) REFERENCES model_tool_call(operation_id,call_ordinal,action_kind),
        \\ FOREIGN KEY(session_ref,permission_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK((permission_state=2 AND resolution_code='denied' AND attempt_ordinal=0) OR
        \\       (permission_state IN (0,1) AND (resolution_code IS NULL OR resolution_code!='denied'))),
        \\ CHECK((attempt_ordinal=0 AND bash_timeout_ms IS NULL) OR
        \\       (attempt_ordinal=1 AND bash_timeout_ms IS NOT NULL)),
        \\ CHECK((resolution_code IS NULL AND resolution_content_id IS NULL AND acceptance_position IS NULL) OR
        \\       (resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL AND acceptance_position IS NOT NULL))
        \\) STRICT;
        \\CREATE TABLE permission_decision_command(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ action_id TEXT NOT NULL CHECK(length(action_id) BETWEEN 1 AND 20),
        \\ decision TEXT NOT NULL CHECK(decision IN ('allow_once','deny'))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE answer_text_projection(
        \\ answer_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ part_ordinal INTEGER NOT NULL CHECK(part_ordinal>=0),
        \\ source_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ encoded_start INTEGER NOT NULL CHECK(encoded_start>=0),
        \\ encoded_length INTEGER NOT NULL CHECK(encoded_length>=0),
        \\ decoded_length INTEGER NOT NULL CHECK(decoded_length>=0),
        \\ PRIMARY KEY(answer_content_id,part_ordinal)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
        \\CREATE INDEX message_admission_pending ON message_admission(admission_id,session_ref) WHERE turn_id IS NULL;
        \\CREATE INDEX message_admission_session_pending ON message_admission(session_ref,admission_id) WHERE turn_id IS NULL;
        \\CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff);
        \\CREATE INDEX action_operation_session_order ON action_operation(session_ref,action_id);
        \\CREATE INDEX action_operation_executable ON action_operation(action_id) WHERE permission_state=1 AND resolution_code IS NULL AND attempt_ordinal=0;
        \\CREATE INDEX action_operation_unresolved_attempt ON action_operation(action_id) WHERE resolution_code IS NULL AND attempt_ordinal=1;
        \\CREATE INDEX model_tool_call_rejections ON model_tool_call(operation_id,call_ordinal) WHERE rejection_code IS NOT NULL;
        \\CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND allowance_used<4;
        \\CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0;
        \\CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id);
        \\CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id);
        \\CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
        \\CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
        \\CREATE INDEX turn_session_latest ON turn(session_ref,turn_id DESC);
    );
    try exec(database, "PRAGMA application_id=1280591409");
    try exec(database, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version}));
    const statement = try prepare(database, "INSERT INTO store_meta(key,value) VALUES('wire_version','1'),('store_selector',?1)");
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, selector);
    try expectDone(statement);
    try exec(database, "COMMIT");
}

fn validateExisting(database: *c.sqlite3, selector: []const u8) !void {
    if (try pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    if (try pragmaInt(database, "PRAGMA user_version") != schema_version) return error.WrongStoreVersion;
    {
        const statement = try prepare(
            database,
            "SELECT count(*) FROM sqlite_schema WHERE " ++
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_tool_call','action_operation','permission_decision_command','answer_text_projection')) OR " ++
                "(type='index' AND ((sql IS NULL AND tbl_name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_tool_call','action_operation','permission_decision_command','answer_text_projection')) OR " ++
                "(sql IS NOT NULL AND name NOT IN ('message_admission_session_order','message_admission_pending','message_admission_session_pending','session_stop_exclusion','action_operation_session_order','action_operation_executable','action_operation_unresolved_attempt','model_tool_call_rejections','turn_one_active_per_session','model_operation_retry_due','model_operation_retry_exhausted','model_operation_session_history','model_operation_turn_history','conversation_entry_history','model_output_history','turn_session_latest')))) OR " ++
                "type NOT IN ('table','index')",
        );
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_int64(statement, 0) != 0) {
            return error.WrongStoreSchema;
        }
    }
    {
        const statement = try prepare(database, "SELECT value FROM store_meta WHERE key='wire_version'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreVersion;
        var version: protocol.Bounded(16) = .{};
        try readText(statement, 0, &version);
        if (!version.eql(protocol.wire_version)) return error.WrongStoreVersion;
    }
    {
        const statement = try prepare(database, "SELECT value FROM store_meta WHERE key='store_selector'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try readText(statement, 0, &stored_selector);
        if (!stored_selector.eql(selector)) return error.WrongStoreIdentity;
    }
}

fn diagnosticSignedPragma(database: *c.sqlite3, sql: [:0]const u8) ?i64 {
    const statement = prepare(database, sql) catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int64(statement, 0);
}

fn diagnosticUnsignedPragma(database: *c.sqlite3, sql: [:0]const u8) ?u64 {
    const value = diagnosticSignedPragma(database, sql) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn diagnosticTextPragma(
    database: *c.sqlite3,
    sql: [:0]const u8,
) ?protocol.Bounded(16) {
    const statement = prepare(database, sql) catch return null;
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
    var value: protocol.Bounded(16) = .{};
    readText(statement, 0, &value) catch return null;
    return value;
}

fn pragmaInt(database: *c.sqlite3, sql: [:0]const u8) !u32 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.PragmaReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0 or value > std.math.maxInt(u32)) return error.CorruptStore;
    return @intCast(value);
}

fn readUnixMilliseconds(database: *c.sqlite3) !i64 {
    const statement = try prepare(
        database,
        "SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER)",
    );
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ClockReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value <= 0) return error.ClockReadFailed;
    return value;
}

fn decideModelRetry(attempt_ordinal: u64, policy: RetryPolicyInput, now_ms: i64) !ModelRetryDecision {
    if (attempt_ordinal == 0 or attempt_ordinal > maximum_model_attempts) {
        return error.InvalidAttemptOrdinal;
    }
    for (policy.waits_ms) |wait_ms| {
        if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (policy.retry_after_ms) |retry_after_ms| {
        if (retry_after_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (attempt_ordinal == maximum_model_attempts) return .exhausted;
    const index: usize = @intCast(attempt_ordinal - 1);
    var due_at_ms = try std.math.add(i64, now_ms, @intCast(policy.waits_ms[index]));
    if (policy.retry_after_ms) |delay_ms| {
        // An external constraint that cannot name a deadline is invalid, not
        // an infrastructure failure. Preserve normal backoff and valid dates.
        const provider_due = std.math.add(i64, now_ms, @intCast(delay_ms)) catch due_at_ms;
        due_at_ms = @max(due_at_ms, provider_due);
    }
    return .{ .schedule_at_ms = @max(due_at_ms, policy.retry_after_deadline_ms orelse 0) };
}

fn bindCurrent(statement: *c.sqlite3_stmt, session_ref: []const u8, current: *const CurrentConfiguration) !void {
    try bindText(statement, 1, session_ref);
    try bindText(statement, 2, current.workspace.slice());
    try bindText(statement, 3, current.model.slice());
    try bindNullableI64(statement, 4, current.instructions_id);
    try bindI64(statement, 5, current.tools_mask);
    try bindI64(statement, 6, current.permission_mode);
    try bindNullableI64(statement, 7, current.output_schema_id);
    try bindU64(statement, 8, current.revision);
    try bindU64(statement, 9, current.next_position);
}

fn nextIdentity(database: *c.sqlite3, comptime table: []const u8, comptime column: []const u8) !u64 {
    const statement = try prepare(
        database,
        "SELECT " ++ column ++ " FROM " ++ table ++ " ORDER BY " ++ column ++ " DESC LIMIT 1",
    );
    defer _ = c.sqlite3_finalize(statement);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return 1;
    if (result != c.SQLITE_ROW) return error.IdentityReadFailed;
    const prior = c.sqlite3_column_int64(statement, 0);
    if (prior <= 0 or prior == std.math.maxInt(i64)) return error.IdentityExhausted;
    return @intCast(prior + 1);
}

fn prepare(database: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v3(database, sql, -1, c.SQLITE_PREPARE_PERSISTENT, &statement, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    return statement orelse error.StatementPrepareFailed;
}

fn exec(database: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(database, sql, null, null, null) != c.SQLITE_OK) return error.SqliteExecFailed;
}

fn rollback(database: *c.sqlite3) void {
    _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
}

fn dbConfig(database: *c.sqlite3, operation: c_int, value: c_int) !void {
    var prior: c_int = 0;
    if (c.sqlite3_db_config(database, operation, value, &prior) != c.SQLITE_OK) {
        return error.SqliteConfigurationFailed;
    }
}

fn setLimit(database: *c.sqlite3, category: c_int, value: c_int) !void {
    _ = c.sqlite3_limit(database, category, value);
    if (c.sqlite3_limit(database, category, -1) != value) return error.SqliteLimitConfigurationFailed;
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text64(statement, index, value.ptr, value.len, null, c.SQLITE_UTF8) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

fn bindOptionalText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (value.len == 0) {
        if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
    } else try bindText(statement, index, value);
}

fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_blob64(statement, index, value.ptr, value.len, null) != c.SQLITE_OK) return error.BindFailed;
}

fn bindI64(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return error.BindFailed;
}

fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.IntegerOutOfRange;
    try bindI64(statement, index, value);
}

fn bindNullableI64(statement: *c.sqlite3_stmt, index: c_int, value: ?i64) !void {
    const result = if (value) |actual|
        c.sqlite3_bind_int64(statement, index, actual)
    else
        c.sqlite3_bind_null(statement, index);
    if (result != c.SQLITE_OK) return error.BindFailed;
}

fn bindNullableU64(statement: *c.sqlite3_stmt, index: c_int, value: ?u64) !void {
    if (value) |present| return bindU64(statement, index, present);
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
}

fn expectDone(statement: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.StatementFailed;
}

fn readText(statement: *c.sqlite3_stmt, index: c_int, destination: anytype) !void {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0) return error.CorruptStore;
    if (length == 0) return destination.set("");
    const pointer = c.sqlite3_column_text(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    try destination.set(bytes[0..@intCast(length)]);
}

fn nextReportRow(statement: *c.sqlite3_stmt, first: *bool, capture: *SessionReportCapture, read_error: anyerror) !bool {
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return false;
    if (result != c.SQLITE_ROW) return read_error;
    if (!first.*) try capture.append(",");
    first.* = false;
    return true;
}

fn appendColumnString(statement: *c.sqlite3_stmt, index: c_int, comptime capacity: usize, capture: *SessionReportCapture) !void {
    var value: protocol.Bounded(capacity) = .{};
    try readText(statement, index, &value);
    try capture.appendJsonString(value.slice());
}

fn appendNullableColumnString(statement: *c.sqlite3_stmt, index: c_int, comptime capacity: usize, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    try appendColumnString(statement, index, capacity, capture);
}

fn maxEnumTagBytes(comptime Enum: type) usize {
    var maximum: usize = 0;
    for (std.meta.tags(Enum)) |value| maximum = @max(maximum, @tagName(value).len);
    return maximum;
}

fn appendNullablePositiveInteger(statement: *c.sqlite3_stmt, index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.CorruptStore;
    try capture.appendFmt("\"{d}\"", .{value});
}

fn appendNullableNonnegativeInteger(statement: *c.sqlite3_stmt, index: c_int, capture: *SessionReportCapture) !void {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return capture.append("null");
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0) return error.CorruptStore;
    try capture.appendFmt("\"{d}\"", .{value});
}

fn readMessageProjectionRow(statement: *c.sqlite3_stmt, excluding_stop: ?[]const u8) !MessageProjection {
    var projection: MessageProjection = undefined;
    try readText(statement, 0, &projection.session);
    projection.content_id = c.sqlite3_column_int64(statement, 1);
    const admission_id = c.sqlite3_column_int64(statement, 2);
    try readText(statement, 3, &projection.command_key);
    if (projection.content_id <= 0 or admission_id <= 0) return error.CorruptStore;
    projection.admission_id = @intCast(admission_id);
    const turn_id = try readNullablePositiveI64(statement, 4);
    if (turn_id == null) {
        if (c.sqlite3_column_type(statement, 5) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 6) != c.SQLITE_NULL or
            c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL or c.sqlite3_column_type(statement, 8) != c.SQLITE_NULL) return error.CorruptStore;
        if (excluding_stop) |key| {
            var stop_key: protocol.Bounded(128) = .{};
            try stop_key.set(key);
            projection.state = .{ .excluded = stop_key };
        } else {
            projection.state = .pending;
        }
        return projection;
    }
    if (excluding_stop != null) return error.CorruptStore;
    const operation_id = try readNullablePositiveI64(statement, 5) orelse return error.CorruptStore;
    const attempt_ordinal = try readNullablePositiveI64(statement, 6) orelse return error.CorruptStore;
    var outcome_code: ?protocol.Bounded(96) = null;
    if (c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL) {
        var code: protocol.Bounded(96) = .{};
        try readText(statement, 7, &code);
        if (code.len == 0) return error.CorruptStore;
        outcome_code = code;
    }
    const outcome_content_id = try readNullablePositiveI64(statement, 8);
    if (outcome_code == null and outcome_content_id != null) return error.CorruptStore;
    projection.state = .{ .applied = .{
        .binding = .{ .turn_id = @intCast(turn_id.?), .operation_id = @intCast(operation_id), .attempt_ordinal = @intCast(attempt_ordinal) },
        .outcome_code = outcome_code,
        .outcome_content_id = outcome_content_id,
    } };
    return projection;
}

fn readDigest(statement: *c.sqlite3_stmt, index: c_int) ![32]u8 {
    if (c.sqlite3_column_bytes(statement, index) != 32) return error.CorruptStore;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..32].*;
}

fn readNullablePositiveI64(statement: *c.sqlite3_stmt, index: c_int) !?i64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.InvalidIdentity;
    return value;
}

fn testingStore(tmp: *std.testing.TmpDir, io: std.Io) !Store {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return Store.open(io, database, root) catch |err| {
        std.debug.print("testing Store open failed: {s}\n", .{@errorName(err)});
        return err;
    };
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

fn queryU64(database: *c.sqlite3, sql: [:0]const u8) !u64 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

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

fn configureTestSession(
    storage: *Store,
    key: []const u8,
    session_ref: []const u8,
) !void {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, session_ref, workspace, "model-a");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
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
    try std.testing.expect(storage.submitMessage(&command, .{}) == .accepted);
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
    var source_buffer: [64 * 1024]u8 = undefined;
    var source_writer = std.Io.Writer.fixed(&source_buffer);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(
        std.testing.io,
        root_buffer[0..root_length],
        file_prefix,
        .{
            .used = &metadata_used,
            .limit = try std.math.mul(u64, calls.len, 5 * output_metadata_record_bytes),
        },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    var offset: u64 = 0;
    for (calls, 0..) |call, index| {
        const item_start = offset;
        try source_writer.writeAll(call.item_id);
        try metadata.append(.{
            .tag = .item_id,
            .kind = .function_call,
            .ordinal = index,
            .start = offset,
            .length = call.item_id.len,
            .decoded_length = call.item_id.len,
            .content_digest = protocol.contentDigest(call.item_id),
        });
        offset += call.item_id.len;
        try source_writer.writeAll(call.name);
        try metadata.append(.{
            .tag = .name,
            .kind = .function_call,
            .ordinal = index,
            .start = offset,
            .length = call.name.len,
            .decoded_length = call.name.len,
            .content_digest = protocol.contentDigest(call.name),
        });
        offset += call.name.len;
        try source_writer.writeAll(call.encoded_call_id);
        try metadata.append(.{
            .tag = .call_id,
            .kind = .function_call,
            .ordinal = index,
            .start = offset,
            .length = call.encoded_call_id.len,
            .decoded_length = call.decoded_call_id.len,
            .content_digest = protocol.contentDigest(call.decoded_call_id),
        });
        offset += call.encoded_call_id.len;
        try source_writer.writeAll(call.encoded_arguments);
        try metadata.append(.{
            .tag = .arguments,
            .kind = .function_call,
            .ordinal = index,
            .start = offset,
            .length = call.encoded_arguments.len,
            .decoded_length = call.decoded_arguments.len,
            .content_digest = protocol.contentDigest(call.decoded_arguments),
        });
        offset += call.encoded_arguments.len;
        try metadata.append(.{
            .tag = .item,
            .kind = .function_call,
            .ordinal = index,
            .start = item_start,
            .length = offset - item_start,
            .id_digest = protocol.contentDigest(call.item_id),
            .content_digest = protocol.contentDigest(source_writer.buffered()[@intCast(item_start)..@intCast(offset)]),
        });
    }
    try metadata.sealForRead();
    const source_bytes = source_writer.buffered();
    var source_name: [64]u8 = undefined;
    const source = try tmp.dir.createFile(std.testing.io, try std.fmt.bufPrint(&source_name, "{s}-source", .{file_prefix}), .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    try storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = calls.len,
        .call_count = calls.len,
        .answer_length = 0,
        .answer_digest = protocol.contentDigest(""),
        .response_id = .{},
        .body_model = .{},
        .openai_model = .{},
        .x_openai_model = .{},
        .request_id = .{},
    }, .{});
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
            .encoded_arguments = "{\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"cmd\":\"one\",\"timeout_ms\":null}",
        },
        .{
            .item_id = "item-2",
            .name = "bash",
            .encoded_call_id = "call-B",
            .decoded_call_id = "call-B",
            .encoded_arguments = "{\\\"cmd\\\":\\\"two\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"cmd\":\"two\",\"timeout_ms\":null}",
        },
    };
    try settleCallsForTesting(storage, tmp, binding, file_prefix, &calls);
}

fn expectContent(storage: *Store, reference: ContentReference, expected: []const u8) !void {
    var reader = try storage.openContent(reference);
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
    item_id: TestingContentReference,
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

test "Current excludes history while Full exposes exact closed Session inventory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "profile-config", "direct/profile");

    const current = try testingSessionReportWithProfile(&storage, &tmp, "direct/profile", 1024 * 1024, .current);
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"profile\":\"current\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"full\"") == null);

    const text = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(text);
    @memset(text, 1);
    try submitTestMessage(&storage, &tmp, "profile-message", "profile-message", "direct/profile", text);
    _ = (try storage.admitNextModelAttempt(.{})).?;
    // One worst-case escaped copy fits; duplicating it in Conversation would not.
    const full = try testingSessionReportWithProfile(&storage, &tmp, "direct/profile", 512 * 1024, .full);
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

test "Full preserves rejected model interruption targets as canonical u64 text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "interrupt-report-config", "direct/interrupt-report");

    const targets = [_]struct { key: []const u8, turn: u64, operation: u64 }{
        .{ .key = "zero-turn", .turn = 0, .operation = 1 },
        .{ .key = "zero-operation", .turn = 1, .operation = 0 },
        .{ .key = "wide-targets", .turn = @as(u64, std.math.maxInt(i64)) + 1, .operation = std.math.maxInt(u64) },
    };
    for (targets) |target| {
        var command: protocol.ModelInterruptionCommand = .{ .turn_id = target.turn, .operation_id = target.operation };
        try command.key.set(target.key);
        try command.session.set("direct/interrupt-report");
        const rejected = storage.interruptModel(&command, .{});
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(ModelInterruptionRejection.invalid_target, rejected.rejected.code);
        const replay = storage.interruptModel(&command, .{});
        try std.testing.expect(replay == .rejected);
        try std.testing.expect(replay.rejected.replayed);
    }

    const full = try testingSessionReportWithProfile(&storage, &tmp, "direct/interrupt-report", 1024 * 1024, .full);
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
    try std.testing.expect((try storage.inspectSession("direct/interrupt-report")).found);
}

test "Full revisions own repeated content once and render semantic settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("revision-owner-1", "direct/revision-owner", workspace, "model-a");
    initial.configuration.instructions = try testingContent(&tmp, "revision-owner-instructions", 1, 64 * 1024);
    const schema_a = "{}";
    initial.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a", schema_a);
    defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&initial, .{}) == .accepted);

    var second: protocol.ConfigureCommand = .{};
    try second.key.set("revision-owner-2");
    try second.session.set("direct/revision-owner");
    second.configuration.tools.state = .value;
    second.configuration.tools.count = 1;
    second.configuration.tools.values[0] = .edit;
    second.configuration.permission_mode.state = .value;
    try second.configuration.permission_mode.value.set("bypass");
    const schema_b = "{\"type\":\"object\"}";
    second.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-b", schema_b);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&second, .{}) == .accepted);

    var third: protocol.ConfigureCommand = .{};
    try third.key.set("revision-owner-3");
    try third.session.set("direct/revision-owner");
    third.configuration.tools.state = .value;
    third.configuration.tools.count = 1;
    third.configuration.tools.values[0] = .bash;
    third.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a-again", schema_a);
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&third, .{}) == .accepted);

    var fourth: protocol.ConfigureCommand = .{};
    try fourth.key.set("revision-owner-4");
    try fourth.session.set("direct/revision-owner");
    fourth.configuration.tools.state = .value;
    fourth.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&fourth, .{}) == .accepted);

    var fifth: protocol.ConfigureCommand = .{};
    try fifth.key.set("revision-owner-5");
    try fifth.session.set("direct/revision-owner");
    fifth.configuration.instructions = try testingBytesContent(&tmp, "revision-owner-instructions-schema-a", schema_a);
    defer fifth.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&fifth, .{}) == .accepted);

    const full = try testingSessionReportWithProfile(&storage, &tmp, "direct/revision-owner", 512 * 1024, .full);
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
        &.{ "bash", "edit" },
        &.{"edit"},
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "stop-merge-config", "direct/stop-merge");

    try submitTestMessage(&storage, &tmp, "stop-merge-message-1-file", "stop-merge-message-1", "direct/stop-merge", "one");
    var first_stop = try completeSessionStop("z-first-stop", "direct/stop-merge");
    try std.testing.expect(storage.stopSession(&first_stop, .{}) == .accepted);
    var same_cutoff_stop = try completeSessionStop("a-second-stop", "direct/stop-merge");
    try std.testing.expect(storage.stopSession(&same_cutoff_stop, .{}) == .accepted);

    try submitTestMessage(&storage, &tmp, "stop-merge-message-2-file", "stop-merge-message-2", "direct/stop-merge", "two");
    var later_stop = try completeSessionStop("m-third-stop", "direct/stop-merge");
    try std.testing.expect(storage.stopSession(&later_stop, .{}) == .accepted);

    const full = try testingSessionReportWithProfile(&storage, &tmp, "direct/stop-merge", 1024 * 1024, .full);
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
    var storage = try testingStore(&tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    try configureTestSession(&storage, "action-config", "direct/actions");
    try submitTestMessage(&storage, &tmp, "action-message", "action-message", "direct/actions", "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "action-metadata");

    const first_action_id = first: {
        const report_bytes = try testingSessionReport(&storage, &tmp, "direct/actions", 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        try std.testing.expect(std.mem.indexOf(u8, report_bytes, "\"work\":{\"status\":\"waiting_for_permission\"") != null);
        const parsed = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("2", parsed.value.actions.count);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.actions.unresolved.len);
        const first = parsed.value.actions.unresolved[0];
        try std.testing.expectEqualStrings("0", first.call_ordinal);
        try std.testing.expectEqualStrings("1", first.permission_revision);
        break :first try std.fmt.parseInt(u64, first.action, 10);
    };
    try std.testing.expectError(error.ActionNotFound, storage.actionCallId("direct/actions", std.math.maxInt(u64)));
    try std.testing.expectError(error.ActionNotFound, storage.actionArguments("direct/actions", std.math.maxInt(u64)));
    try std.testing.expect(!storage.isFenced());
    try expectContent(&storage, try storage.actionCallId("direct/actions", first_action_id), "call\nA");
    try expectContent(&storage, try storage.actionArguments("direct/actions", first_action_id), "{\"cmd\":\"one\",\"timeout_ms\":null}");

    var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny.key.set("deny-first");
    try deny.session.set("direct/actions");
    const accepted = storage.denyPermission(&deny, .{});
    try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
    try std.testing.expect(storage.denyPermission(&deny, .{}).accepted.replayed);
    deny.action_id += 1;
    try std.testing.expect(storage.denyPermission(&deny, .{}) == .conflict);

    var permission_update: protocol.ConfigureCommand = .{};
    try permission_update.key.set("action-bypass");
    try permission_update.session.set("direct/actions");
    permission_update.configuration.permission_mode.state = .value;
    try permission_update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&permission_update, .{}) == .accepted);
    const second_action_id = second: {
        const report_bytes = try testingSessionReport(&storage, &tmp, "direct/actions", 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        const parsed = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, report_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.actions.unresolved.len);
        const second = parsed.value.actions.unresolved[0];
        try std.testing.expectEqualStrings("1", second.call_ordinal);
        try std.testing.expectEqualStrings("1", second.permission_revision);
        break :second try std.fmt.parseInt(u64, second.action, 10);
    };
    try expectContent(&storage, try storage.actionCallId("direct/actions", second_action_id), "call-B");
    try expectContent(&storage, try storage.actionArguments("direct/actions", second_action_id), "{\"cmd\":\"two\",\"timeout_ms\":null}");

    var stop = try completeSessionStop("action-stop", "direct/actions");
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    var stale: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
    try stale.key.set("stale-denial");
    try stale.session.set("direct/actions");
    stale.decision = .allow_once;
    const rejected = storage.denyPermission(&stale, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(PermissionDecisionRejection.action_not_pending, rejected.rejected.code);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL"));

    const full_bytes = try testingSessionReportWithProfile(&storage, &tmp, "direct/actions", 1024 * 1024, .full);
    defer std.testing.allocator.free(full_bytes);
    var full = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, full_bytes, .{});
    defer full.deinit();
    const decisions = full.value.object.get("full").?.object.get("permission_decisions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), decisions.len);
    try std.testing.expectEqualStrings("deny", decisions[0].object.get("decision").?.string);
    try std.testing.expectEqualStrings("accepted", decisions[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("allow_once", decisions[1].object.get("decision").?.string);
    try std.testing.expectEqualStrings("rejected", decisions[1].object.get("status").?.string);

    try submitTestMessage(&storage, &tmp, "bypass-message", "bypass-message", "direct/actions", "bypass proposal");
    const bypass_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, bypass_binding, "bypass-metadata");
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM action_operation WHERE permission_state=1 AND permission_revision=2 AND resolution_code IS NULL"));

    try storage.close();
    storage_open = false;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var database: [platform.max_database_path_bytes]u8 = undefined;
    var reopened = try Store.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    try std.testing.expectEqual(@as(u64, 2), try queryU64(reopened.database, "SELECT count(*) FROM action_operation WHERE permission_state=1 AND permission_revision=2 AND resolution_code IS NULL"));
    const recovered_bytes = try testingSessionReport(&reopened, &tmp, "direct/actions", 1024 * 1024);
    defer std.testing.allocator.free(recovered_bytes);
    const recovered = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.value.actions.unresolved.len);
    for (recovered.value.actions.unresolved) |action| {
        try std.testing.expectEqualStrings("bypass", action.authorization);
        try std.testing.expectEqualStrings("2", action.permission_revision);
    }
}

test "Action settlement atomically yields to an earlier Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "settlement-stop-config", "direct/settlement-stop");
    try submitTestMessage(
        &storage,
        &tmp,
        "settlement-stop-message",
        "settlement-stop-message",
        "direct/settlement-stop",
        "execute",
    );
    const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "settlement-stop-item",
        .name = "bash",
        .encoded_call_id = "settlement-stop-call",
        .decoded_call_id = "settlement-stop-call",
        .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}",
    }};
    try settleCallsForTesting(&storage, &tmp, model_binding, "settlement-stop-metadata", &calls);
    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("settlement-stop-allow");
    try allow.session.set("direct/settlement-stop");
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;

    var stop = try completeSessionStop("settlement-stop", "direct/settlement-stop");
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(
        ActionSettlement.session_stop,
        try storage.settleActionAttempt(action_binding, .succeeded, "Bash succeeded.", .{}),
    );

    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM action_operation WHERE resolution_code='cancelled'",
    ));
    const result_content_id = try queryU64(
        storage.database,
        "SELECT resolution_content_id FROM action_operation",
    );
    const result_metadata = try storage.readContentMetadata(@intCast(result_content_id));
    try expectContent(&storage, .{
        .length = result_metadata.length,
        .digest = result_metadata.digest,
    }, "Cancelled by Session stop.");
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM turn WHERE session_ref='direct/settlement-stop' AND outcome_code='cancelled'",
    ));
}

test "Full reports every closed Action resolution without fencing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "shutdown-report-config", "direct/shutdown-report");
    try submitTestMessage(&storage, &tmp, "shutdown-report-message", "shutdown-report-message", "direct/shutdown-report", "execute");
    const model_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{.{
        .item_id = "shutdown-report-item",
        .name = "bash",
        .encoded_call_id = "shutdown-report-call",
        .decoded_call_id = "shutdown-report-call",
        .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":1234}",
        .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":1234}",
    }};
    try settleCallsForTesting(&storage, &tmp, model_binding, "shutdown-report-metadata", &calls);
    const action_id = try queryU64(storage.database, "SELECT action_id FROM action_operation");
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("shutdown-report-allow");
    try allow.session.set("direct/shutdown-report");
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const action_binding = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 1234), (try storage.readBashExecutionInput(action_binding)).timeout_ms);
    try std.testing.expectEqual(
        ActionSettlement.effect,
        try storage.settleActionAttempt(action_binding, .infrastructure_shutdown, "Host shutdown.", .{}),
    );

    const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, "direct/shutdown-report", 1024 * 1024, .full);
    defer std.testing.allocator.free(report_bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_bytes, .{});
    defer report.deinit();
    const actions = report.value.object.get("full").?.object.get("actions").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings("infrastructure_shutdown", actions[0].object.get("resolution").?.string);
    try std.testing.expectEqualStrings("Host shutdown.", actions[0].object.get("result").?.object.get("text").?.string);
    try std.testing.expect(!storage.isFenced());
    _ = try storage.inspectSession("direct/shutdown-report");
}

test "report scratch exhaustion is an observation failure without Store fencing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "report-config", "direct/report-failure");
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.ReportScratchExhausted, storage.captureSessionReport("direct/report-failure", .{
        .scratch_path = root[0..root_length],
        .scratch_budget = .{ .used = &used, .limit = 1 },
        .request_number = 1,
        .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
    }));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect((try storage.inspectSession("direct/report-failure")).found);
}

test "report unlink failure retains a startup-owned zero-request file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "report-unlink-config", "direct/report-unlink");
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.ReportScratchCleanupFailed, storage.captureSessionReport("direct/report-unlink", .{
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
    var report_store = try testingStore(&report_tmp, std.testing.io);
    defer report_store.close() catch unreachable;
    try configureTestSession(&report_store, "report-corrupt-config", "direct/report-corrupt");
    try exec(report_store.database, "PRAGMA foreign_keys=OFF");
    try exec(report_store.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/report-corrupt'");
    try exec(report_store.database, "PRAGMA foreign_keys=ON");
    var report_root: [protocol.max_store_bytes]u8 = undefined;
    const report_root_length = try report_tmp.dir.realPath(std.testing.io, &report_root);
    var report_used = std.atomic.Value(u64).init(0);
    try std.testing.expectError(error.CorruptStore, report_store.captureSessionReport("direct/report-corrupt", .{
        .scratch_path = report_root[0..report_root_length],
        .scratch_budget = .{ .used = &report_used, .limit = 1024 * 1024 },
        .request_number = 1,
        .execution = .{ .dispatch_fenced = false, .custody_occupied = 0, .scratch_used_bytes = 0 },
    }));
    try std.testing.expect(report_store.isFenced());
    var blocked_denial: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
    try blocked_denial.key.set("blocked-after-report-failure");
    try blocked_denial.session.set("direct/report-corrupt");
    try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, report_store.denyPermission(&blocked_denial, .{}));

    var action_tmp = std.testing.tmpDir(.{});
    defer action_tmp.cleanup();
    var action_store = try testingStore(&action_tmp, std.testing.io);
    defer action_store.close() catch unreachable;
    try configureTestSession(&action_store, "action-corrupt-config", "direct/action-corrupt");
    try submitTestMessage(&action_store, &action_tmp, "action-corrupt-message", "action-corrupt-message", "direct/action-corrupt", "propose");
    const binding = (try action_store.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&action_store, &action_tmp, binding, "action-corrupt-metadata");
    const action_id = try queryU64(action_store.database, "SELECT min(action_id) FROM action_operation");
    try exec(action_store.database, "PRAGMA foreign_keys=OFF");
    try exec(action_store.database, "DELETE FROM content WHERE content_id=(SELECT call_id_content_id FROM model_tool_call ORDER BY operation_id,call_ordinal LIMIT 1)");
    try exec(action_store.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, action_store.actionCallId("direct/action-corrupt", action_id));
    try std.testing.expect(action_store.isFenced());
    try std.testing.expectError(error.StoreFenced, action_store.actionArguments("direct/action-corrupt", action_id));
}

test "Core classifies trustworthy calls atomically without Action-shaped rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    try configureTestSession(&storage, "mixed-config", "direct/mixed-calls");
    try submitTestMessage(&storage, &tmp, "mixed-message", "mixed-message", "direct/mixed-calls", "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "item-1", .name = "bash", .encoded_call_id = "call-1", .decoded_call_id = "call-1", .encoded_arguments = "{\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "item-2", .name = "other", .encoded_call_id = "call-2", .decoded_call_id = "call-2", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-3", .name = "bash", .encoded_call_id = "call-3", .decoded_call_id = "call-3", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "item-4", .name = "bash", .encoded_call_id = "call-4", .decoded_call_id = "call-4", .encoded_arguments = "{\\\"command\\\":\\\"wrong\\\"}", .decoded_arguments = "{\"command\":\"wrong\"}" },
        .{ .item_id = "item-5", .name = "edit", .encoded_call_id = "call-5", .decoded_call_id = "call-5", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-6", .name = "x" ** 300, .encoded_call_id = "call-6", .decoded_call_id = "call-6", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "item-7", .name = "bash", .encoded_call_id = "call-7", .decoded_call_id = "call-7", .encoded_arguments = "{\\\"cmd\\\":\\\"seven\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"seven\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, binding, "mixed-metadata", &calls);

    try std.testing.expectEqual(@as(u64, 7), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call"));
    try std.testing.expectEqual(@as(u64, 5), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE rejection_code IS NOT NULL"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE rejection_code='tool_unavailable'"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE call_ordinal=5 AND rejection_code='unknown_tool'"));
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM action_operation"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation action JOIN model_tool_call call ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal WHERE call.rejection_code IS NOT NULL"));
    {
        const rejected_action = try prepare(storage.database, "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,permission_state,resolution_code) VALUES(999,?1,1,'direct/mixed-calls',1,1,0,NULL)");
        defer _ = c.sqlite3_finalize(rejected_action);
        try bindU64(rejected_action, 1, binding.operation_id);
        try std.testing.expectError(error.StatementFailed, expectDone(rejected_action));
    }
    {
        const invalid_denial = try prepare(storage.database, "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,permission_state,resolution_code) VALUES(998,?1,0,'direct/mixed-calls',1,1,2,NULL)");
        defer _ = c.sqlite3_finalize(invalid_denial);
        try bindU64(invalid_denial, 1, binding.operation_id);
        try std.testing.expectError(error.StatementFailed, expectDone(invalid_denial));
    }

    var observation = try storage.inspectSession("direct/mixed-calls");
    try std.testing.expectEqual(@as(u64, 2), observation.action_count);
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    const first_action_id = first: {
        const report_bytes = try testingSessionReportWithProfile(&storage, &tmp, "direct/mixed-calls", 1024 * 1024, .full);
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
            .{ rejected.item_id, "item-2" },
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
        const metadata = try storage.readContentMetadata(@intCast(content_id));
        var reader = try storage.openContent(.{ .length = metadata.length, .digest = metadata.digest });
        defer reader.close();
        var result: [192]u8 = undefined;
        const count = try reader.read(0, &result);
        try std.testing.expect(std.mem.startsWith(u8, result[0..count], "Unknown tool: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…"));
        try std.testing.expect(std.mem.indexOf(u8, result[0..count], "name continues; Rui content digest") != null);
    }
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny.key.set("mixed-deny");
    try deny.session.set("direct/mixed-calls");
    try std.testing.expect(storage.denyPermission(&deny, .{}) == .accepted);
    observation = try storage.inspectSession("direct/mixed-calls");
    try std.testing.expectEqual(@as(u64, 5), observation.rejected_call_count);
    {
        const report_bytes = try testingSessionReport(&storage, &tmp, "direct/mixed-calls", 1024 * 1024);
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
    var reopened = try Store.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    const recovered = try reopened.inspectSession("direct/mixed-calls");
    try std.testing.expectEqual(@as(u64, 2), recovered.action_count);
    try std.testing.expectEqual(@as(u64, 5), recovered.rejected_call_count);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        reopened.database,
        "SELECT count(*) FROM action_operation WHERE action_id=(SELECT min(action_id) FROM action_operation) " ++
            "AND parent_operation_id=(SELECT min(parent_operation_id) FROM action_operation) " ++
            "AND call_ordinal=0 AND permission_state=2 AND resolution_code='denied'",
    ));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        reopened.database,
        "SELECT count(*) FROM permission_decision_command WHERE command_key='mixed-deny' " ++
            "AND action_id=CAST((SELECT min(action_id) FROM action_operation) AS TEXT)",
    ));
    try expectContent(&reopened, try reopened.actionCallId("direct/mixed-calls", first_action_id), "call-1");
    try expectContent(&reopened, try reopened.actionArguments("direct/mixed-calls", first_action_id), "{\"cmd\":\"one\",\"timeout_ms\":null}");
    const recovered_bytes = try testingSessionReport(&reopened, &tmp, "direct/mixed-calls", 1024 * 1024);
    defer std.testing.allocator.free(recovered_bytes);
    const recovered_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, recovered_bytes, .{ .ignore_unknown_fields = true });
    defer recovered_report.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered_report.value.actions.unresolved.len);
    try std.testing.expectEqualStrings("6", recovered_report.value.actions.unresolved[0].call_ordinal);
    try std.testing.expectEqual(@as(usize, 5), recovered_report.value.rejected_calls.items.len);
}

test "complete call outcomes continue once in call order ahead of pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "result-config", "direct/tool-results");
    try submitTestMessage(&storage, &tmp, "result-first", "result-first", "direct/tool-results", "first");
    const first_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "result-item-0", .name = "bash", .encoded_call_id = "result-call-0", .decoded_call_id = "result-call-0", .encoded_arguments = "{\\\"cmd\\\":\\\"zero\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"zero\",\"timeout_ms\":null}" },
        .{ .item_id = "result-item-1", .name = "unknown", .encoded_call_id = "result-call-1", .decoded_call_id = "result-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "result-item-2", .name = "bash", .encoded_call_id = "result-call-2", .decoded_call_id = "result-call-2", .encoded_arguments = "{", .decoded_arguments = "{" },
        .{ .item_id = "result-item-3", .name = "bash", .encoded_call_id = "result-call-3", .decoded_call_id = "result-call-3", .encoded_arguments = "{\\\"cmd\\\":\\\"three\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"three\",\"timeout_ms\":null}" },
    };
    try settleCallsForTesting(&storage, &tmp, first_binding, "result-metadata", &calls);
    try submitTestMessage(&storage, &tmp, "result-second", "result-second", "direct/tool-results", "second");
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const first_action_id = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation");
    const second_action_id = try queryU64(storage.database, "SELECT max(action_id) FROM action_operation");
    var deny_second: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
    try deny_second.key.set("result-deny-second");
    try deny_second.session.set("direct/tool-results");
    try std.testing.expect(storage.denyPermission(&deny_second, .{}) == .accepted);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    var deny_first: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try deny_first.key.set("result-deny-first");
    try deny_first.session.set("direct/tool-results");
    try std.testing.expect(storage.denyPermission(&deny_first, .{}) == .accepted);
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(first_binding.turn_id, continuation.turn_id);
    try std.testing.expectEqual(first_binding.operation_id + 1, continuation.operation_id);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    const replayed_denial = storage.denyPermission(&deny_first, .{});
    try std.testing.expect(replayed_denial == .accepted);
    try std.testing.expect(replayed_denial.accepted.replayed);
    var stale_denial: protocol.PermissionDecisionCommand = .{ .action_id = first_action_id };
    try stale_denial.key.set("result-stale-denial");
    try stale_denial.session.set("direct/tool-results");
    const stale_reply = storage.denyPermission(&stale_denial, .{});
    try std.testing.expect(stale_reply == .rejected);
    try std.testing.expectEqual(PermissionDecisionRejection.action_not_pending, stale_reply.rejected.code);

    var view = try storage.openHistoricalView(continuation);
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
        var call_id = try view.openContent(result.call_id);
        var output = try view.openContent(result.output);
        var buffer: [128]u8 = undefined;
        const call_id_count = try call_id.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_call_id, buffer[0..call_id_count]);
        const output_count = try output.read(0, &buffer);
        try std.testing.expectEqualStrings(expected_output, buffer[0..output_count]);
        output.close();
        call_id.close();
    }
    try std.testing.expect((try view.nextToolResult()) == null);
    const pending = (try view.nextEntry(position)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, pending.kind);
    try std.testing.expect((try view.nextEntry(pending.position)) == null);
    try std.testing.expectEqual(HistoricalEntryKind.user, (try view.nextEntry(0)).?.kind);
}

test "terminal call-result import and read failures preserve canonical authority" {
    var import_tmp = std.testing.tmpDir(.{});
    defer import_tmp.cleanup();
    var import_store = try testingStore(&import_tmp, std.testing.io);
    defer import_store.close() catch unreachable;
    try configureTestSession(&import_store, "result-import-config", "direct/result-import");
    try submitTestMessage(&import_store, &import_tmp, "result-import-message", "result-import-message", "direct/result-import", "call");
    const import_binding = (try import_store.admitNextModelAttempt(.{})).?.permit.binding;
    const valid_call = [_]TestingCall{.{ .item_id = "import-item", .name = "bash", .encoded_call_id = "import-call", .decoded_call_id = "import-call", .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}" }};
    try settleCallsForTesting(&import_store, &import_tmp, import_binding, "result-import-metadata", &valid_call);
    var deny: protocol.PermissionDecisionCommand = .{ .action_id = try queryU64(import_store.database, "SELECT action_id FROM action_operation") };
    try deny.key.set("result-import-deny");
    try deny.session.set("direct/result-import");
    try std.testing.expectEqual(PermissionDecisionReply.infrastructure_failure, import_store.denyPermission(&deny, .{ .content_import = true }));
    try std.testing.expect(import_store.isFenced());
    try std.testing.expectEqual(@as(u64, 0), try queryU64(import_store.database, "SELECT count(*) FROM core_command WHERE command_key='result-import-deny'"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(import_store.database, "SELECT count(*) FROM action_operation WHERE resolution_code IS NULL"));

    var read_tmp = std.testing.tmpDir(.{});
    defer read_tmp.cleanup();
    var read_store = try testingStore(&read_tmp, std.testing.io);
    defer read_store.close() catch unreachable;
    try configureTestSession(&read_store, "result-read-config", "direct/result-read");
    try submitTestMessage(&read_store, &read_tmp, "result-read-message", "result-read-message", "direct/result-read", "call");
    const read_binding = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
    const rejected_call = [_]TestingCall{.{ .item_id = "read-item", .name = "unknown", .encoded_call_id = "read-call", .decoded_call_id = "read-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
    try settleCallsForTesting(&read_store, &read_tmp, read_binding, "result-read-metadata", &rejected_call);
    const continuation = (try read_store.admitNextModelAttempt(.{})).?.permit.binding;
    try exec(read_store.database, "PRAGMA foreign_keys=OFF");
    try exec(read_store.database, "UPDATE model_tool_call SET rejection_content_id=9223372036854775807");
    try exec(read_store.database, "PRAGMA foreign_keys=ON");
    var view = try read_store.openHistoricalView(continuation);
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const sessions = [_][]const u8{ "direct/discovery-missing-action", "direct/discovery-missing-call" };
        const configs = [_][]const u8{ "discovery-action-config", "discovery-call-config" };
        const messages = [_][]const u8{ "discovery-action-message", "discovery-call-message" };
        const files = [_][]const u8{ "discovery-action-file", "discovery-call-file" };
        const metadata = [_][]const u8{ "discovery-action-metadata", "discovery-call-metadata" };
        const session_ref = sessions[index];
        try configureTestSession(&storage, configs[index], session_ref);
        try submitTestMessage(&storage, &tmp, files[index], messages[index], session_ref, "call");
        const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{.{
            .item_id = "discovery-item",
            .name = "bash",
            .encoded_call_id = "discovery-call",
            .decoded_call_id = "discovery-call",
            .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}",
        }};
        try settleCallsForTesting(&storage, &tmp, source, metadata[index], &calls);
        try exec(storage.database, "PRAGMA foreign_keys=OFF");
        try exec(storage.database, "DELETE FROM action_operation");
        if (corruption == .call) try exec(storage.database, "DELETE FROM model_tool_call");
        try exec(storage.database, "PRAGMA foreign_keys=ON");
        try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
        try std.testing.expect(storage.isFenced());
    }
}

test "missing canonical call outcome rows fence history and inspection" {
    const corruptions = [_]enum { action, call, result_content }{ .action, .call, .result_content };
    const session_refs = [_][]const u8{
        "direct/missing-outcome-action",
        "direct/missing-outcome-call",
        "direct/missing-outcome-content",
    };
    const config_keys = [_][]const u8{ "missing-config-action", "missing-config-call", "missing-config-content" };
    const message_keys = [_][]const u8{ "missing-message-action", "missing-message-call", "missing-message-content" };
    const message_files = [_][]const u8{ "missing-file-action", "missing-file-call", "missing-file-content" };
    const metadata_files = [_][]const u8{ "missing-metadata-action", "missing-metadata-call", "missing-metadata-content" };
    const denial_keys = [_][]const u8{ "missing-denial-action", "missing-denial-call", "missing-denial-content" };
    for (corruptions, 0..) |corruption, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session_ref = session_refs[index];
        try configureTestSession(&storage, config_keys[index], session_ref);
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
            .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}",
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
        try std.testing.expect(storage.denyPermission(&denial, .{}) == .accepted);
        const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

        try exec(storage.database, "PRAGMA foreign_keys=OFF");
        switch (corruption) {
            .action => try exec(storage.database, "DELETE FROM action_operation"),
            .call => try exec(storage.database, "DELETE FROM action_operation; DELETE FROM model_tool_call"),
            .result_content => try exec(
                storage.database,
                "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation LIMIT 1)",
            ),
        }
        try exec(storage.database, "PRAGMA foreign_keys=ON");

        if (corruption == .action) {
            var view = try storage.openHistoricalView(continuation);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "eof-coverage-config", "direct/eof-coverage");
    try submitTestMessage(
        &storage,
        &tmp,
        "eof-coverage-file",
        "eof-coverage-message",
        "direct/eof-coverage",
        "call",
    );
    const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "eof-item-0", .name = "unknown", .encoded_call_id = "eof-call-0", .decoded_call_id = "eof-call-0", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "eof-item-1", .name = "unknown", .encoded_call_id = "eof-call-1", .decoded_call_id = "eof-call-1", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try settleCallsForTesting(&storage, &tmp, source, "eof-coverage-metadata", &calls);
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view = try storage.openHistoricalView(continuation);
    defer view.close();
    var position: u64 = 0;
    while (true) {
        const entry = (try view.nextEntry(position)) orelse return error.MissingToolResultGroup;
        position = entry.position;
        if (entry.kind == .tool_results) break;
    }
    try std.testing.expect((try view.nextToolResult()) != null);

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(storage.database, "DELETE FROM model_tool_call WHERE call_ordinal=1");
    try exec(storage.database, "PRAGMA foreign_keys=ON");
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try configureTestSession(&storage, "scale-config", "direct/tool-result-scale");
            try submitTestMessage(
                &storage,
                &tmp,
                "scale-message-file",
                "scale-message",
                "direct/tool-result-scale",
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
            var view = try storage.openHistoricalView(binding);
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try configureTestSession(&storage, "current-cost-config", "direct/current-cost");
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
                    "direct/current-cost",
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
                try storage.settleModelAttemptFailure(continuation, "provider_http_422", .terminal, .{});
            }
            try submitTestMessage(
                &storage,
                &tmp,
                "current-cost-active-file",
                "current-cost-active-message",
                "direct/current-cost",
                "active",
            );
            const active = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(
                &storage,
                &tmp,
                active,
                "current-cost-active-metadata",
                &calls,
            );

            var root: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(std.testing.io, &root);
            var used = std.atomic.Value(u64).init(0);
            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.database, 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            var report = try storage.captureSessionReport("direct/current-cost", .{
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

    const one_group = try Measure.run(1);
    const sixteen_groups = try Measure.run(16);
    try std.testing.expectEqual(one_group, sixteen_groups);
}

test "Current pending count skips excluded Message history by indexed cutoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "pending-cost-config", "direct/pending-cost");
    try exec(storage.database, "PRAGMA foreign_keys=OFF");

    var costs: [2]i32 = undefined;
    for ([_]usize{ 100, 10_000 }, 0..) |history, index| {
        try exec(storage.database, "DELETE FROM message_admission; DELETE FROM session_stop");
        const insert = try std.fmt.allocPrintSentinel(
            std.testing.allocator,
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                "SELECT value,'direct/pending-cost',printf('excluded-%d',value),1,NULL FROM sequence; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                "VALUES({0}+1,'direct/pending-cost','eligible',1,NULL); " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                "VALUES('history-stop','direct/pending-cost',NULL,{0})",
            .{history},
            0,
        );
        defer std.testing.allocator.free(insert);
        try exec(storage.database, insert);
        try std.testing.expectEqual(@as(u64, 1), try storage.countPendingMessages("direct/pending-cost"));

        const cutoff_statement = try prepare(storage.database, session_stop_cutoff_sql);
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try bindText(cutoff_statement, 1, "direct/pending-cost");
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cutoff_statement));
        const cutoff = c.sqlite3_column_int64(cutoff_statement, 0);
        const count_statement = try prepare(storage.database, pending_message_count_sql);
        defer _ = c.sqlite3_finalize(count_statement);
        try bindText(count_statement, 1, "direct/pending-cost");
        try bindI64(count_statement, 2, cutoff);
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try configureTestSession(&storage, "full-scale-config", "direct/full-scale");
            try exec(storage.database, "PRAGMA foreign_keys=OFF");

            for (1..message_count + 1) |index| {
                const insert = try std.fmt.allocPrintSentinel(
                    std.testing.allocator,
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                        "VALUES({0},'direct/full-scale','message-{0}',1,NULL)",
                    .{index},
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(storage.database, insert);
            }
            for (1..stop_count + 1) |index| {
                const insert = try std.fmt.allocPrintSentinel(
                    std.testing.allocator,
                    "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) " ++
                        "VALUES('stop-{0}',3,'direct/full-scale',zeroblob(32),NULL,NULL,1,'accepted',0,0);" ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                        "VALUES('stop-{0}','direct/full-scale',NULL,{1})",
                    .{ index, message_count },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(storage.database, insert);
            }

            var counter: Counter = .{};
            c.sqlite3_progress_handler(storage.database, 1, Counter.progress, &counter);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            const full = try testingSessionReportWithProfile(&storage, &tmp, "direct/full-scale", 8 * 1024 * 1024, .full);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "frozen-call-config", "direct/frozen-call");
    var remove_bash: protocol.ConfigureCommand = .{};
    try remove_bash.key.set("frozen-call-edit-only");
    try remove_bash.session.set("direct/frozen-call");
    remove_bash.configuration.tools.state = .value;
    remove_bash.configuration.tools.count = 1;
    remove_bash.configuration.tools.values[0] = .edit;
    try std.testing.expect(storage.configure(&remove_bash, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "frozen-call-message", "frozen-call-message", "direct/frozen-call", "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    var add_bash: protocol.ConfigureCommand = .{};
    try add_bash.key.set("frozen-call-add-bash");
    try add_bash.session.set("direct/frozen-call");
    add_bash.configuration.tools.state = .value;
    add_bash.configuration.tools.count = 1;
    add_bash.configuration.tools.values[0] = .bash;
    try std.testing.expect(storage.configure(&add_bash, .{}) == .accepted);
    const calls = [_]TestingCall{.{
        .item_id = "frozen-item",
        .name = "bash",
        .encoded_call_id = "frozen-call",
        .decoded_call_id = "frozen-call",
        .encoded_arguments = "{\\\"cmd\\\":\\\"echo frozen\\\",\\\"timeout_ms\\\":null}",
        .decoded_arguments = "{\"cmd\":\"echo frozen\",\"timeout_ms\":null}",
    }};
    try settleCallsForTesting(&storage, &tmp, binding, "frozen-call-metadata", &calls);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM action_operation"));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool'"));
}

test "duplicate trustworthy call identity rolls back every imported consequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "duplicate-call-config", "direct/duplicate-call");
    try submitTestMessage(&storage, &tmp, "duplicate-call-message", "duplicate-call-message", "direct/duplicate-call", "duplicate");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]TestingCall{
        .{ .item_id = "duplicate-item-1", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"cmd\\\":\\\"one\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"one\",\"timeout_ms\":null}" },
        .{ .item_id = "duplicate-item-2", .name = "bash", .encoded_call_id = "same-call", .decoded_call_id = "same-call", .encoded_arguments = "{\\\"cmd\\\":\\\"two\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"cmd\":\"two\",\"timeout_ms\":null}" },
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
    var storage = try testingStore(&tmp, std.testing.io);
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
            .encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}",
            .decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}",
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

    try configureTestSession(&storage, "valid-growth-config", "direct/valid-growth");
    try submitTestMessage(&storage, &tmp, "valid-growth-message", "valid-growth-message", "direct/valid-growth", "valid");
    const valid_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, valid_binding, "valid-growth-metadata", &valid_calls);
    try std.testing.expectEqual(@as(u64, population), (try storage.inspectSession("direct/valid-growth")).action_count);
    const valid_report_bytes = try testingSessionReport(&storage, &tmp, "direct/valid-growth", 1024 * 1024);
    defer std.testing.allocator.free(valid_report_bytes);
    const valid_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, valid_report_bytes, .{ .ignore_unknown_fields = true });
    defer valid_report.deinit();
    try std.testing.expectEqual(@as(usize, population), valid_report.value.actions.unresolved.len);

    try configureTestSession(&storage, "rejected-growth-config", "direct/rejected-growth");
    try submitTestMessage(&storage, &tmp, "rejected-growth-message", "rejected-growth-message", "direct/rejected-growth", "rejected");
    const rejected_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, rejected_binding, "rejected-growth-metadata", &rejected_calls);
    const rejected = try storage.inspectSession("direct/rejected-growth");
    try std.testing.expectEqual(@as(u64, 0), rejected.action_count);
    try std.testing.expectEqual(@as(u64, population), rejected.rejected_call_count);
    const rejected_report_bytes = try testingSessionReport(&storage, &tmp, "direct/rejected-growth", 1024 * 1024);
    defer std.testing.allocator.free(rejected_report_bytes);
    const rejected_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, rejected_report_bytes, .{ .ignore_unknown_fields = true });
    defer rejected_report.deinit();
    try std.testing.expectEqual(@as(usize, population), rejected_report.value.rejected_calls.items.len);
}

test "Session stop freezes its selection and excludes only the admitted prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-stop", "direct/stop");
    try submitTestMessage(&storage, &tmp, "stop-a", "message-a", "direct/stop", "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;

    var stop = try completeSessionStop("stop", "direct/stop");
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(!accepted.accepted.replayed);
    try std.testing.expectEqual(binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
    try std.testing.expectEqual(binding.operation_id, accepted.accepted.interrupted_operation_id.?);
    try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding));

    const cancelled = (try storage.observeCommand("message-a")).message.?.queue.?;
    const cancellation = switch (cancelled.state) {
        .cancelled => |value| value,
        else => return error.ExpectedCancelledObservation,
    };
    try std.testing.expectEqual(binding.turn_id, cancellation.binding.turn_id);
    try std.testing.expectEqualStrings("cancelled", cancellation.code.slice());
    const active_report = try testingSessionReportWithProfile(&storage, &tmp, "direct/stop", 1024 * 1024, .full);
    defer std.testing.allocator.free(active_report);
    var active_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, active_report, .{});
    defer active_json.deinit();
    const active_message = active_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
    try std.testing.expectEqualStrings("applied", active_message.get("application").?.string);
    try std.testing.expect(active_message.get("exclusion").? == .null);

    var after_stop = try completeModelInterruption("interrupt-after-stop", "direct/stop", binding);
    const rejected_interrupt = storage.interruptModel(&after_stop, .{});
    try std.testing.expect(rejected_interrupt == .rejected);
    try std.testing.expectEqual(
        ModelInterruptionRejection.operation_resolved,
        rejected_interrupt.rejected.code,
    );

    try submitTestMessage(&storage, &tmp, "stop-b", "message-b", "direct/stop", "later");
    const replay = storage.stopSession(&stop, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
    try std.testing.expect((try storage.observeCommand("message-b")).message.?.queue.?.state == .queued);
    const later = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expect(later.permit.binding.turn_id != binding.turn_id);
}

test "later idle stop does not reclassify a completed Message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try configureTestSession(&storage, "completed-stop-config", "direct/completed-stop");
    try submitTestMessage(&storage, &tmp, "completed-stop-file", "completed-stop-message", "direct/completed-stop", "answer");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try exec(
        storage.database,
        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='completed'," ++
            "resolution_content_id=(SELECT content_id FROM message_admission WHERE command_key='completed-stop-message');" ++
            "UPDATE turn SET outcome_code='completed',outcome_content_id=(SELECT content_id FROM message_admission " ++
            "WHERE command_key='completed-stop-message') WHERE session_ref='direct/completed-stop'",
    );
    var stop = try completeSessionStop("completed-stop", "direct/completed-stop");
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(accepted.accepted.selection.selected_turn_id == null);
    try std.testing.expect((try storage.observeCommand("completed-stop-message")).message.?.queue.?.state == .completed);

    const report = try testingSessionReportWithProfile(&storage, &tmp, "direct/completed-stop", 1024 * 1024, .full);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-idle-stop", "direct/idle-stop");
    try submitTestMessage(&storage, &tmp, "idle-stop-a", "idle-message-a", "direct/idle-stop", "before");
    var stop = try completeSessionStop("idle-stop", "direct/idle-stop");
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectEqual(@as(?u64, null), accepted.accepted.selection.selected_turn_id);
    try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
    const excluded = (try storage.observeCommand("idle-message-a")).message.?.queue.?;
    try std.testing.expect(excluded.state == .excluded);
    try std.testing.expectEqualStrings("session_stopped", excluded.state.excluded.code.slice());
    const excluded_report = try testingSessionReportWithProfile(&storage, &tmp, "direct/idle-stop", 1024 * 1024, .full);
    defer std.testing.allocator.free(excluded_report);
    var excluded_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, excluded_report, .{});
    defer excluded_json.deinit();
    const excluded_message = excluded_json.value.object.get("full").?.object.get("messages").?.array.items[0].object;
    try std.testing.expectEqualStrings("excluded", excluded_message.get("application").?.string);
    try std.testing.expectEqualStrings("idle-stop", excluded_message.get("exclusion").?.object.get("command_key").?.string);
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    try submitTestMessage(&storage, &tmp, "idle-stop-b", "idle-message-b", "direct/idle-stop", "after");
    const later = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 1), later.permit.binding.turn_id);
}

test "exact model interruption continues only with applicable pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-interrupt", "direct/interrupt");
    try submitTestMessage(&storage, &tmp, "interrupt-a", "interrupt-message-a", "direct/interrupt", "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;
    try submitTestMessage(&storage, &tmp, "interrupt-b", "interrupt-message-b", "direct/interrupt", "second");

    var interrupt = try completeModelInterruption("interrupt", "direct/interrupt", binding);
    const accepted = storage.interruptModel(&interrupt, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding));
    const successor = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(binding.turn_id, successor.permit.binding.turn_id);
    try std.testing.expect(successor.permit.binding.operation_id != binding.operation_id);

    const observation = try storage.observeCommand("interrupt");
    try std.testing.expectEqual(binding.turn_id, observation.model_interruption.?.turn_id);
    try std.testing.expectEqual(binding.operation_id, observation.model_interruption.?.operation_id);
}

test "exact model interruption rejects stale targets and replays before applicability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-rejected-interrupt", "direct/rejected-interrupt");
    var early: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
    try early.key.set("early-interrupt");
    try early.session.set("direct/rejected-interrupt");
    const rejected = storage.interruptModel(&early, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, rejected.rejected.code);

    try submitTestMessage(&storage, &tmp, "rejected-interrupt-a", "rejected-interrupt-message", "direct/rejected-interrupt", "first");
    const admitted = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 1), admitted.permit.binding.operation_id);
    const replay = storage.interruptModel(&early, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, replay.rejected.code);

    early.operation_id = 2;
    try std.testing.expect(storage.interruptModel(&early, .{}) == .conflict);

    var exact = try completeModelInterruption("exact-interrupt", "direct/rejected-interrupt", admitted.permit.binding);
    try std.testing.expect(storage.interruptModel(&exact, .{}) == .accepted);
    try std.testing.expect(
        (try storage.observeCommand("rejected-interrupt-message")).message.?.queue.?.state == .cancelled,
    );
    try std.testing.expectError(
        error.SupersededByControl,
        storage.settleModelAttemptFailure(admitted.permit.binding, "late_failure", .terminal, .{}),
    );

    var after = try completeModelInterruption("after-interrupt", "direct/rejected-interrupt", admitted.permit.binding);
    const resolved = storage.interruptModel(&after, .{});
    try std.testing.expect(resolved == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.operation_resolved, resolved.rejected.code);
}

test "model interruption removes a scheduled retry from admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-retry-interrupt", "direct/retry-interrupt");
    try submitTestMessage(&storage, &tmp, "retry-interrupt-a", "retry-interrupt-message", "direct/retry-interrupt", "first");
    const admitted = (try storage.admitNextModelAttempt(.{})).?;
    try storage.settleModelAttemptFailure(admitted.permit.binding, "temporary", .{ .retryable = .{
        .waits_ms = .{ 1, 1, 1 },
    } }, .{});

    var interrupt = try completeModelInterruption(
        "retry-interrupt",
        "direct/retry-interrupt",
        admitted.permit.binding,
    );
    try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
}

test "failed control commit saves no answer after reopening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    try configureTestSession(&storage, "configure-control-rollback", "direct/control-rollback");
    var stop = try completeSessionStop("rollback-stop", "direct/control-rollback");
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
    storage = try Store.open(std.testing.io, database, root_buffer[0..root_length]);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("rollback-stop")).status == .absent);
}

test "configuration pre-Workspace decisions preserve completeness and continuation precedence" {
    const Case = struct {
        name: []const u8,
        has_current: bool,
        workspace_requested: bool,
        model_requested: ?[]const u8,
        continuation_risk: bool,
        expected: ?ConfigurationRejection,
    };
    const cases = [_]Case{
        .{
            .name = "new sparse request",
            .has_current = false,
            .workspace_requested = false,
            .model_requested = null,
            .continuation_risk = false,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new request missing model",
            .has_current = false,
            .workspace_requested = true,
            .model_requested = null,
            .continuation_risk = false,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new complete request",
            .has_current = false,
            .workspace_requested = true,
            .model_requested = "model-a",
            .continuation_risk = true,
            .expected = null,
        },
        .{
            .name = "risky incompatible model before Workspace",
            .has_current = true,
            .workspace_requested = true,
            .model_requested = "model-b",
            .continuation_risk = true,
            .expected = .continuation_model_incompatible,
        },
        .{
            .name = "same model with continuation",
            .has_current = true,
            .workspace_requested = false,
            .model_requested = "model-a",
            .continuation_risk = true,
            .expected = null,
        },
        .{
            .name = "compatible sparse update",
            .has_current = true,
            .workspace_requested = false,
            .model_requested = "model-b",
            .continuation_risk = false,
            .expected = null,
        },
    };

    var existing: CurrentConfiguration = .{};
    try existing.workspace.set("/canonical/workspace");
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
        const current: ?*const CurrentConfiguration = if (case.has_current) &existing else null;
        std.testing.expectEqual(
            case.expected,
            configurationBeforeWorkspace(current, &requested, case.continuation_risk),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
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
        expected_rejection: ?ConfigurationRejection = null,
        expected_actions: ?Actions = null,
        expected_model: []const u8 = "model-a",
        expected_tools: u8 = 3,
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
            .model = "model-b",
            .empty_tools = true,
            .permission = "bypass",
            .instructions = .value,
            .schema = .clear,
            .expected_actions = .{ .instructions = .import_requested, .output_schema = .clear },
            .expected_model = "model-b",
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
        try existing.model.set("model-a");
        existing.instructions_id = 11;
        existing.output_schema_id = 12;
        existing.revision = case.current_revision;

        var requested: protocol.Configuration = .{};
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

        var canonical_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        try canonical_workspace.set(switch (case.workspace) {
            .omitted, .same => "/canonical/workspace",
            .different => "/different/workspace",
        });
        const canonical_workspace_ref: ?*const protocol.Bounded(protocol.max_workspace_bytes) =
            if (case.workspace == .omitted) null else &canonical_workspace;
        const current: ?*const CurrentConfiguration = if (case.created) null else &existing;
        var next = if (current) |value| value.* else CurrentConfiguration{};
        const plan = planConfigurationUpdate(current, &requested, canonical_workspace_ref, &next);

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
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&command, .{
            .content_import = true,
            .before_commit = true,
        }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("rejected-content")).status == .absent);
        const rolled_back_content = try prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(rolled_back_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(rolled_back_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(rolled_back_content, 0));

        const rejected = storage.configure(&command, .{ .content_import = true });
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
        const committed_content = try prepare(
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
        try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, replay.rejected.code);
        const retained_content = try prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(retained_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(retained_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(retained_content, 0));
    }
}

test "configuration answers replay without reverting newer settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var first = try completeConfiguration("first", "direct/test", workspace, "model-a");
    const first_reply = storage.configure(&first, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(first_reply.accepted.created);

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("update");
    try update.session.set("direct/test");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const update_reply = storage.configure(&update, .{});
    try std.testing.expect(update_reply == .accepted);
    try std.testing.expectEqual(@as(u64, 2), update_reply.accepted.revision);

    const replay = storage.configure(&first, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
    const observation = try storage.inspectSession("direct/test");
    try std.testing.expectEqualStrings("model-b", observation.model.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    try std.testing.expectEqual(@as(u8, 3), observation.tools_mask);
    try std.testing.expectEqualStrings("ask", observation.permission_mode.slice());
    try std.testing.expectEqual(@as(u64, 0), observation.instructions.length);
    var empty_digest: [32]u8 = undefined;
    empty_digest = protocol.contentDigest("");
    try std.testing.expectEqualSlices(u8, &empty_digest, &observation.instructions.digest);
    try std.testing.expect(observation.output_schema == null);

    var reader = try storage.openContent(observation.instructions);
    defer reader.close();
    var content_window: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try reader.read(0, &content_window));
    try std.testing.expectError(error.RangeOutOfBounds, reader.read(1, &content_window));
    try std.testing.expect((try storage.observeCommand("first")).status == .accepted);

    first.configuration.model.value.len = 0;
    try first.configuration.model.value.set("model-c");
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-window", "direct/window");
    var text: [ContentReader.content_window_bytes + 17]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try submitTestMessage(
        &storage,
        &tmp,
        "window-message-source",
        "window-message",
        "direct/window",
        &text,
    );
    const reference = (try storage.observeCommand("window-message")).message.?.content;
    var reader = try storage.openContent(reference);
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

test "core preserves empty keys and Session references containing NUL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    const session_ref = "exact\x00reference";
    var command = try completeConfiguration("", session_ref, workspace, "model-a");
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const observation = try storage.inspectSession(session_ref);
    try std.testing.expect(observation.found);
    try std.testing.expectEqualSlices(u8, session_ref, observation.session.slice());
    try std.testing.expect((try storage.observeCommand("")).status == .accepted);
}

test "saved incomplete initialization stays rejected after Session creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    try incomplete.session.set("direct/rejection");
    const rejected = storage.configure(&incomplete, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var complete = try completeConfiguration(
        "complete",
        "direct/rejection",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&complete, .{}) == .accepted);
    const replay = storage.configure(&incomplete, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
}

test "failed commit saves neither answer nor partial Session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "commit-fault",
        "direct/fault",
        workspace,
        "model-a",
    );
    {
        var storage = try testingStore(&tmp, std.testing.io);
        const reply = storage.configure(&command, .{ .before_commit = true });
        try std.testing.expect(reply == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("commit-fault")).status == .absent);
        try std.testing.expect(!(try storage.inspectSession("direct/fault")).found);
        try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    }
}

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/messages", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_text = "first message\n" ++ ("abcdef" ** 700) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", "direct/messages", first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const first_reply = storage.submitMessage(&first, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", "direct/messages", second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessage(&second, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);

    const replay = storage.submitMessage(&first, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSession("direct/messages");
    try std.testing.expectEqual(@as(u64, 2), session.pending_messages);
    const observed = try storage.observeCommand("message-1");
    try std.testing.expect(observed.status == .accepted);
    try std.testing.expect(observed.kind == .message);
    try std.testing.expect(observed.message != null);
    const accepted_observation = observed.message.?.queue.?;
    try std.testing.expectEqual(first_reply.accepted.admission_id, accepted_observation.admission_id);
    try std.testing.expect(accepted_observation.state == .queued);

    var reader = try storage.openContent(observed.message.?.content);
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
    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const restarted = try storage.observeCommand("message-1");
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.message.?.queue.?.admission_id);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSession("direct/messages")).pending_messages);
}

test "message rejections replay before current Session checks without retained input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const text = "rejected input";
    const file = try tmp.dir.createFile(std.testing.io, "rejected-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("rejected-message", "direct/later", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    const rejected = storage.submitMessage(&message, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure-later", "direct/later", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const replay = storage.submitMessage(&message, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(MessageRejection.unknown_session, replay.rejected.code);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &replay.rejected.content.digest);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/later")).pending_messages);

    const observed = try storage.observeCommand("rejected-message");
    try std.testing.expect(observed.status == .rejected);
    try std.testing.expect(observed.message == null);
}

test "message observation validates accepted admission references independently" {
    const corruptions = [_]enum { session, content }{ .session, .content };
    for (corruptions) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;

        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var primary_configuration = try completeConfiguration(
            "reference-primary-configure",
            "direct/reference-primary",
            workspace,
            "model-a",
        );
        try std.testing.expect(storage.configure(&primary_configuration, .{}) == .accepted);
        var other_configuration = try completeConfiguration(
            "reference-other-configure",
            "direct/reference-other",
            workspace,
            "model-a",
        );
        try std.testing.expect(storage.configure(&other_configuration, .{}) == .accepted);

        const primary_file = try tmp.dir.createFile(std.testing.io, "reference-primary-message", .{ .read = true });
        try primary_file.writeStreamingAll(std.testing.io, "primary input");
        try primary_file.sync(std.testing.io);
        var primary_message = try completeMessage(
            "reference-primary-message",
            "direct/reference-primary",
            primary_file,
            "primary input",
        );
        defer primary_message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&primary_message, .{}) == .accepted);

        const other_file = try tmp.dir.createFile(std.testing.io, "reference-other-message", .{ .read = true });
        try other_file.writeStreamingAll(std.testing.io, "other input");
        try other_file.sync(std.testing.io);
        var other_message = try completeMessage(
            "reference-other-message",
            "direct/reference-other",
            other_file,
            "other input",
        );
        defer other_message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&other_message, .{}) == .accepted);

        switch (corruption) {
            .session => try exec(
                storage.database,
                "UPDATE message_admission SET session_ref='direct/reference-other' " ++
                    "WHERE command_key='reference-primary-message'",
            ),
            .content => try exec(
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "corrupt-observation-configure",
        "direct/corrupt-observation",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "corrupt-observation-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "input");
    try file.sync(std.testing.io);
    var message = try completeMessage(
        "corrupt-observation-message",
        "direct/corrupt-observation",
        file,
        "input",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try exec(
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
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/conflict", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const text = "one admission";
    const file = try tmp.dir.createFile(std.testing.io, "message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message", "direct/conflict", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .before_commit = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect((try storage.observeCommand("message")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/conflict")).pending_messages);
    const accepted = storage.submitMessage(&message, .{});
    try std.testing.expect(accepted == .accepted);

    var retargeted = message;
    retargeted.text.file = null;
    try retargeted.session.set("direct/other");
    try std.testing.expect(storage.submitMessage(&retargeted, .{}) == .conflict);
    var changed = message;
    changed.text.file = null;
    changed.text.length += 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var changed_kind = try completeConfiguration("message", "direct/conflict", workspace, "model-a");
    try std.testing.expect(storage.configure(&changed_kind, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession("direct/conflict")).pending_messages);
    try storage.close();
}

test "failed message import rolls back content command and admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/import", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const text = "larger than an empty import";
    const file = try tmp.dir.createFile(std.testing.io, "import-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message-import", "direct/import", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .content_import = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("message-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/import")).pending_messages);
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
}

test "rollback failure fences mutation until fresh reopen restores committed facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "rollback-configure",
        "direct/rollback",
        workspace,
        "model-a",
    );
    const message_file = try tmp.dir.createFile(std.testing.io, "rollback-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "committed prefix");
    try message_file.sync(std.testing.io);
    var message = try completeMessage(
        "rollback-message",
        "direct/rollback",
        message_file,
        "committed prefix",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
        try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
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
        var later = try completeConfiguration("rollback-later", "direct/later", workspace, "model-a");
        try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
        try storage.close();
    }

    var binding: AttemptBinding = undefined;
    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect((try storage.observeCommand("rollback-configure")).status == .accepted);
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .queued,
        );
        {
            const partial = try prepare(
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
                "must-not-settle",
                .terminal,
                .{ .rollback_failure = true },
            ),
        );
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(
            error.StoreFenced,
            storage.settleModelAttemptFailure(binding, "must-not-settle", .terminal, .{}),
        );
        try storage.close();
    }

    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("rollback-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(binding.operation_id, observed_binding.operation_id);
        try storage.settleModelAttemptFailure(binding, "provider_http_422", .terminal, .{});
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .failed,
        );
    }
}

test "production Store applies finite durable SQLite settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 3), try pragmaInt(storage.database, "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4096), try pragmaInt(storage.database, "PRAGMA page_size"));
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA trusted_schema"));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_threadsafe());
    try std.testing.expectEqual(@as(i64, sqlite_heap_bytes), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expectEqual(@as(c_int, 16 * 1024), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_SQL_LENGTH, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_ATTACHED, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_WORKER_THREADS, -1));

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?u64, 4096), diagnostic.page_size_bytes);
    try std.testing.expectEqual(@as(?i64, -4096), diagnostic.cache_size_setting);
    try std.testing.expect(diagnostic.cache_spill_threshold.? > 0);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.mmap_size_bytes);
    try std.testing.expectEqual(@as(?i64, 3), diagnostic.synchronous);
    try std.testing.expectEqual(@as(?i64, 1), diagnostic.temp_store);
    try std.testing.expectEqual(@as(?u64, 0), diagnostic.busy_timeout_ms);
    try std.testing.expectEqualStrings("delete", diagnostic.journal_mode.?.slice());
    try std.testing.expect(diagnostic.process_memory_current_bytes != null);
    try std.testing.expect(diagnostic.process_memory_highwater_bytes != null);
    try std.testing.expect(diagnostic.cache_used_bytes != null);
    try std.testing.expect(diagnostic.cache_spills != null);
}

test "maximum canonical Store path completes a journaled transaction" {
    const vfs = c.sqlite3_vfs_find(null) orelse return error.SqliteVfsUnavailable;
    try std.testing.expectEqual(@as(c_int, 512), vfs.*.mxPathname);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_buffer: [protocol.max_store_bytes]u8 = undefined;
    const store_path = try createMaximumCanonicalStore(&tmp, &store_buffer);
    const paths = try platform.resolveClientPaths(std.testing.io, store_path);
    try std.testing.expectEqual(@as(usize, platform.max_database_path_bytes), paths.database.len);

    var storage = try Store.open(std.testing.io, paths.database.slice(), paths.store.slice());
    defer storage.close() catch unreachable;
    try exec(storage.database, "BEGIN IMMEDIATE");
    errdefer rollback(storage.database);
    try exec(storage.database, "UPDATE store_meta SET value='temporary' WHERE key='wire_version'");
    var journal_buffer: [platform.max_database_path_bytes + "-journal".len]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_buffer, "{s}-journal", .{paths.database.slice()});
    const journal = try std.Io.Dir.cwd().statFile(std.testing.io, journal_path, .{});
    try std.testing.expect(journal.kind == .file);
    try exec(storage.database, "ROLLBACK");
}

test "measurement Store can disable cache spill without changing other limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage = try Store.openWithOptions(
        std.testing.io,
        database,
        root,
        .{ .cache_spill = false },
    );
    defer storage.close() catch unreachable;

    const diagnostic = storage.sqliteDiagnostic();
    try std.testing.expectEqual(@as(?i64, 0), diagnostic.cache_spill_threshold);
    try std.testing.expectEqual(@as(?u64, sqlite_heap_bytes), diagnostic.hard_heap_limit_bytes);
    try std.testing.expectEqual(@as(?i64, -4096), diagnostic.cache_size_setting);
    try std.testing.expectEqual(@as(?i64, 3), diagnostic.synchronous);
    try std.testing.expectEqualStrings("delete", diagnostic.journal_mode.?.slice());
}

test "measurement Store can force a smaller SQLite cache without changing production defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage = try Store.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 32 });
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(?i64, -32), storage.sqliteDiagnostic().cache_size_setting);

    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        Store.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 0 }),
    );
    try std.testing.expectError(
        error.InvalidSqliteCacheSize,
        Store.openWithOptions(std.testing.io, database, root, .{ .cache_kib = 4097 }),
    );
}

test "fresh Store uses current schema and rejects the prior version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage = try Store.open(std.testing.io, database, root);
    try std.testing.expectEqual(schema_version, try pragmaInt(storage.database, "PRAGMA user_version"));
    {
        const removed_index = try prepare(
            storage.database,
            "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='model_operation_runnable'",
        );
        defer _ = c.sqlite3_finalize(removed_index);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(removed_index));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(removed_index, 0));
    }
    {
        const duplicated_action_uncertainty = try prepare(
            storage.database,
            "SELECT count(*) FROM pragma_table_info('action_operation') WHERE name='uncertain'",
        );
        defer _ = c.sqlite3_finalize(duplicated_action_uncertainty);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(duplicated_action_uncertainty));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(duplicated_action_uncertainty, 0));
    }
    try exec(
        storage.database,
        std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version - 1}),
    );
    try storage.close();

    try std.testing.expectError(
        error.WrongStoreVersion,
        Store.open(std.testing.io, database, root),
    );
}

test "existing Store rejects noncanonical durable authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage = try Store.open(std.testing.io, database, root);
    try exec(storage.database, "CREATE TABLE tool_result_authority(call_id INTEGER PRIMARY KEY, result_content_id INTEGER NOT NULL)");
    try storage.close();

    try std.testing.expectError(
        error.WrongStoreSchema,
        Store.open(std.testing.io, database, root),
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
    var storage = try Store.open(std.testing.io, database, root);
    try storage.close();
    try std.testing.expectError(
        error.WrongStoreIdentity,
        Store.open(std.testing.io, database, "/different/canonical/store"),
    );
}

test "canonical observation failure fences later admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("create", "direct/corrupt", workspace, "model-a");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(storage.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/corrupt'");
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSession("direct/corrupt"));

    var later = try completeConfiguration("later", "direct/later", workspace, "model-a");
    try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("later"));
}

test "external content import follows sealed descriptor custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    var command = try completeConfiguration("sealed", "direct/sealed", workspace, "model-a");
    command.configuration.instructions = .{
        .state = .value,
        .file = file,
        .length = captured.len,
        .digest = protocol.contentDigest(captured),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);

    const observation = try storage.inspectSession("direct/sealed");
    var reader = try storage.openContent(observation.instructions);
    defer reader.close();
    var bytes: [captured.len]u8 = undefined;
    try std.testing.expectEqual(captured.len, try reader.read(0, &bytes));
    try std.testing.expectEqualStrings(captured, &bytes);
}

test "external content identity is verified before canonical commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const captured = "captured instructions";
    const file = try tmp.dir.createFile(std.testing.io, "changed", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, captured);
    try file.sync(std.testing.io);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("changed", "direct/changed", workspace, "model-a");
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const length: usize = if (case == .empty_digest) 0 else protocol.content_window_bytes * 2 + 17;

            var initial = try completeConfiguration("initial", "direct/import", workspace, "model-a");
            initial.configuration.instructions = try testingContent(&tmp, "original", 'a', length);
            defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
            if (deduplicated) try std.testing.expect(storage.configure(&initial, .{}) == .accepted);
            const content_count = try queryU64(storage.database, "SELECT count(*) FROM content");
            const command_count = try queryU64(storage.database, "SELECT count(*) FROM core_command");
            const revision_count = try queryU64(storage.database, "SELECT count(*) FROM session_revision");

            var command = try completeConfiguration("invalid", "direct/import", workspace, "model-b");
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var vtable = std.testing.io.vtable.*;
        vtable.fileReadPositional = Probe.read;
        storage.io.vtable = &vtable;
        Probe.change = change;
        Probe.bytes_read = 0;

        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var command = try completeConfiguration("read-probe", "direct/import", workspace, "model-a");
        const length = protocol.content_window_bytes * 2 + 17;
        command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        if (change == .none) {
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
            try std.testing.expectEqual(length, Probe.bytes_read);
            Probe.bytes_read = 0;
            try command.key.set("deduplicated");
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("first", "direct/import", workspace, "model-a");
    const length = protocol.content_window_bytes * 2 + 17;
    command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    try command.key.set("second");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    const observation = try storage.inspectSession("direct/import");
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    var reader = try storage.openContent(observation.instructions);
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

test "definite rejections retain decisions without retaining payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("initial", "direct/exhausted", workspace, "model-a");
    try std.testing.expect(storage.configure(&initial, .{}) == .accepted);
    try exec(storage.database, "UPDATE session SET revision=9223372036854775807 WHERE session_ref='direct/exhausted'");

    var unknown_message: protocol.MessageCommand = .{};
    try unknown_message.key.set("unknown-message");
    try unknown_message.session.set("direct/unknown");
    unknown_message.text = try testingContent(&tmp, "unknown-message", 'm', 64 * 1024);
    defer unknown_message.removeTemporaryContent(std.testing.io) catch unreachable;
    const unknown_reply = storage.submitMessage(&unknown_message, .{});
    try std.testing.expect(unknown_reply == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, unknown_reply.rejected.code);

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    try incomplete.session.set("direct/incomplete");
    incomplete.configuration.instructions = try testingContent(&tmp, "incomplete", 'i', 64 * 1024);
    defer incomplete.removeTemporaryContent(std.testing.io) catch unreachable;
    const incomplete_reply = storage.configure(&incomplete, .{});
    try std.testing.expect(incomplete_reply == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, incomplete_reply.rejected.code);

    var exhausted: protocol.ConfigureCommand = .{};
    try exhausted.key.set("exhausted");
    try exhausted.session.set("direct/exhausted");
    exhausted.configuration.instructions = try testingContent(&tmp, "exhausted", 'e', 64 * 1024);
    defer exhausted.removeTemporaryContent(std.testing.io) catch unreachable;
    const exhausted_reply = storage.configure(&exhausted, .{});
    try std.testing.expect(exhausted_reply == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.revision_exhausted, exhausted_reply.rejected.code);

    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        storage.database,
        "SELECT count(*) FROM core_command WHERE accepted=0 AND (primary_content_id IS NOT NULL OR secondary_content_id IS NOT NULL)",
    ));

    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect(storage.submitMessage(&unknown_message, .{}).rejected.replayed);
    try std.testing.expect(storage.configure(&incomplete, .{}).rejected.replayed);
    try std.testing.expect(storage.configure(&exhausted, .{}).rejected.replayed);

    var changed = unknown_message;
    changed.text.digest[0] ^= 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var retargeted = incomplete;
    try retargeted.session.set("direct/other");
    try std.testing.expect(storage.configure(&retargeted, .{}) == .conflict);
    var changed_kind: protocol.MessageCommand = .{};
    try changed_kind.key.set("incomplete");
    try changed_kind.session.set("direct/incomplete");
    changed_kind.text = unknown_message.text;
    try std.testing.expect(storage.submitMessage(&changed_kind, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
}

test "one committed selection freezes its settings and input prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/dispatch", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_file = try tmp.dir.createFile(std.testing.io, "dispatch-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage("dispatch-1", "direct/dispatch", first_file, "first");
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);

    const second_file = try tmp.dir.createFile(std.testing.io, "dispatch-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage("dispatch-2", "direct/dispatch", second_file, "second");
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&second, .{}) == .accepted);

    var instructions_update: protocol.ConfigureCommand = .{};
    try instructions_update.key.set("instructions-before-selection");
    try instructions_update.session.set("direct/dispatch");
    instructions_update.configuration.instructions = try testingContent(&tmp, "instructions-before", 'b', 1);
    defer instructions_update.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instructions_update, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expect(
        (try storage.observeCommand("dispatch-1")).message.?.queue.?.state == .queued,
    );

    // Failed admission publishes neither projection nor instruction inclusion.
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(storage.database, "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(i64, 1), try pragmaInt(storage.database, "SELECT next_position FROM session"));

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const second_observation = (try storage.observeCommand("dispatch-2")).message.?.queue.?;
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
    var third = try completeMessage("dispatch-3", "direct/dispatch", third_file, "later");
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&third, .{}) == .accepted);
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set("direct/dispatch");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = storage.configure(&update, .{});
    try std.testing.expect(active_update == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.continuation_model_incompatible,
        active_update.rejected.code,
    );

    var view = try storage.openHistoricalView(binding);
    defer if (view.active) view.close();
    const settings = try view.settings();
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    const first_input = (try view.nextEntry(0)).?;
    const second_input = (try view.nextEntry(first_input.position)).?;
    const instruction = (try view.nextEntry(second_input.position)).?;
    try std.testing.expect(instruction.kind == .instruction);
    try std.testing.expect((try view.nextEntry(instruction.position)) == null);
    var first_reader = try view.openContent(first_input.content.?);
    defer if (first_reader.active) first_reader.close();
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(actual.len, try first_reader.read(0, &actual));
    try std.testing.expectEqualStrings("first", &actual);

    var foreign_view = try storage.openHistoricalView(binding);
    try std.testing.expect(first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_input.content.?.belongsTo(&foreign_view));
    foreign_view.close();
    try std.testing.expectEqual(@as(usize, 1), view.readers);
    first_reader.close();
    try std.testing.expectEqual(@as(usize, 0), view.readers);
    view.close();
    try std.testing.expect(!first_input.content.?.belongsTo(&view));
    try std.testing.expect(!first_reader.usable());

    try storage.settleModelAttemptFailure(binding, "provider_http_422", .terminal, .{});
    const failed = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const failure = switch (failed.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("provider_http_422", failure.code.slice());
    try std.testing.expect(
        (try storage.observeCommand("dispatch-3")).message.?.queue.?.state == .queued,
    );
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession("direct/dispatch")).pending_messages);

    try update.key.set("configure-after-failure");
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view = try storage.openHistoricalView(later.permit.binding);
    defer later_view.close();
    try std.testing.expectEqualStrings("model-b", (try later_view.settings()).model.slice());
    var position: u64 = 0;
    for ([_]HistoricalEntryKind{ .user, .user, .instruction, .user }) |kind| {
        const entry = (try later_view.nextEntry(position)).?;
        try std.testing.expectEqual(kind, entry.kind);
        position = entry.position;
    }
    try std.testing.expect((try later_view.nextEntry(position)) == null);
}

test "continued accepted output keeps model continuation incompatible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "continued-config",
        "direct/continued-output",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_file = try tmp.dir.createFile(std.testing.io, "continued-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage(
        "continued-first",
        "direct/continued-output",
        first_file,
        "first",
    );
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    const second_file = try tmp.dir.createFile(std.testing.io, "continued-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage(
        "continued-second",
        "direct/continued-output",
        second_file,
        "second",
    );
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&second, .{}) == .accepted);

    const source_bytes = "\"answer\"";
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
    try metadata.append(.{
        .tag = .item,
        .kind = .message,
        .start = 0,
        .length = source_bytes.len,
        .content_digest = protocol.contentDigest(source_bytes),
    });
    try metadata.append(.{
        .tag = .text,
        .start = 1,
        .length = "answer".len,
        .decoded_length = "answer".len,
    });
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .call_count = 0,
        .answer_length = "answer".len,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .body_model = .{},
        .openai_model = .{},
        .x_openai_model = .{},
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
    {
        const resolution = try prepare(
            storage.database,
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(96) = .{};
        try readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("continued", code.slice());
    }

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set("direct/continued-output");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const rejected = storage.configure(&update, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.continuation_model_incompatible,
        rejected.rejected.code,
    );

    const completion_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelSuccess(completion_binding, &output, .{});
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

test "failed model settlement recovers uncertainty with a fresh consumed Attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/failure", workspace, "model-a");

    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
        const message_file = try tmp.dir.createFile(std.testing.io, "failure-message", .{ .read = true });
        try message_file.writeStreamingAll(std.testing.io, "fail");
        try message_file.sync(std.testing.io);
        var message = try completeMessage("failure-message", "direct/failure", message_file, "fail");
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectError(
            error.InjectedCommitFailure,
            storage.settleModelAttemptFailure(
                binding,
                "request_preparation_failed",
                .terminal,
                .{ .before_commit = true },
            ),
        );
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
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
            const force_exhausted = try prepare(
                storage.database,
                "UPDATE model_operation SET attempt_ordinal=4,allowance_used=4 WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(force_exhausted);
            try bindU64(force_exhausted, 1, replacement_binding.operation_id);
            try expectDone(force_exhausted);
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
    }
}

test "temporary model failures conserve allowance and exhaust after four Attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("retry-config", "direct/retry", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const message_file = try tmp.dir.createFile(std.testing.io, "retry-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "retry me");
    try message_file.sync(std.testing.io);
    var message = try completeMessage("retry-message", "direct/retry", message_file, "retry me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);

    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const retry_policy = RetryPolicyInput{
        .waits_ms = .{ 50, 1, 1 },
        // This valid integer cannot name a deadline at the settlement clock.
        .retry_after_ms = 9_223_372_036_854_775_000,
    };
    try storage.settleModelAttemptFailure(
        first,
        "provider_temporary_http_429",
        .{ .retryable = retry_policy },
        .{},
    );
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    {
        const statement = try prepare(
            storage.database,
            "SELECT uncertain,retry_due_at_ms-CAST(unixepoch('subsec')*1000 AS INTEGER),last_failure_code,resolution_code " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, first.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 0));
        try std.testing.expect(c.sqlite3_column_int64(statement, 1) > 0);
        var failure: protocol.Bounded(96) = .{};
        try readText(statement, 2, &failure);
        try std.testing.expectEqualStrings("provider_temporary_http_429", failure.slice());
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    }

    try std.testing.io.sleep(.fromMilliseconds(60), .awake);
    const second = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, second.operation_id);
    try std.testing.expectEqual(@as(u64, 2), second.attempt_ordinal);
    try std.testing.expectError(
        error.StaleAttemptBinding,
        storage.settleModelAttemptFailure(first, "late_old_failure", .terminal, .{}),
    );
    try std.testing.expect(!storage.isFenced());

    try storage.settleModelAttemptFailure(
        second,
        "provider_transport_failure",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const third = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 3), third.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        third,
        "provider_temporary_http_503",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const fourth = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), fourth.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        fourth,
        "provider_transport_failure",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );

    const observation = (try storage.observeCommand("retry-message")).message.?.queue.?;
    const failure = switch (observation.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    const statement = try prepare(
        storage.database,
        "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code " ++
            "FROM model_operation WHERE operation_id=?1",
    );
    defer _ = c.sqlite3_finalize(statement);
    try bindU64(statement, 1, first.operation_id);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 2));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    var last_failure: protocol.Bounded(96) = .{};
    try readText(statement, 4, &last_failure);
    try std.testing.expectEqualStrings("provider_transport_failure", last_failure.slice());
    var resolution: protocol.Bounded(96) = .{};
    try readText(statement, 5, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
}

test "model retry decision applies configured waits Retry-After and exhaustion" {
    const defaults = RetryPolicyInput{ .waits_ms = .{ 2_000, 4_000, 8_000 } };
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_at_ms = 2_000 },
        try decideModelRetry(1, defaults, 0),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_at_ms = 4_000 },
        try decideModelRetry(2, defaults, 0),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_at_ms = 8_000 },
        try decideModelRetry(3, defaults, 0),
    );
    try std.testing.expectEqual(
        ModelRetryDecision.exhausted,
        try decideModelRetry(4, defaults, 0),
    );

    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_at_ms = 6_000 },
        try decideModelRetry(2, .{
            .waits_ms = defaults.waits_ms,
            .retry_after_ms = 6_000,
        }, 0),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_at_ms = 8_000 },
        try decideModelRetry(3, .{
            .waits_ms = defaults.waits_ms,
            .retry_after_ms = 6_000,
        }, 0),
    );

    try std.testing.expectError(error.InvalidAttemptOrdinal, decideModelRetry(0, defaults, 0));
    try std.testing.expectError(error.InvalidAttemptOrdinal, decideModelRetry(5, defaults, 0));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = .{ 0, 4_000, 8_000 },
    }, 0));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = .{ @as(u64, @intCast(std.math.maxInt(i64))) + 1, 4_000, 8_000 },
    }, 0));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = defaults.waits_ms,
        .retry_after_ms = @as(u64, @intCast(std.math.maxInt(i64))) + 1,
    }, 0));
}

test "retry dates stay absolute across body transfer and checked settlement arithmetic" {
    const now_ms: i64 = 1_700_000_015_000;
    const waits = [3]u64{ 2_000, 4_000, 8_000 };
    // Headers arrived fifteen seconds ago with a date ten seconds ahead.
    // A progressing body crossed that deadline: only normal backoff remains.
    for ([_]i64{ now_ms - 5_000, now_ms, now_ms + 1_000 }) |deadline| {
        try std.testing.expectEqual(ModelRetryDecision{ .schedule_at_ms = now_ms + 2_000 }, try decideModelRetry(1, .{
            .waits_ms = waits,
            .retry_after_deadline_ms = deadline,
        }, now_ms));
    }
    try std.testing.expectEqual(ModelRetryDecision{ .schedule_at_ms = now_ms + 10_000 }, try decideModelRetry(1, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = now_ms + 10_000,
        .retry_after_ms = 6_000,
    }, now_ms));
    try std.testing.expectEqual(ModelRetryDecision{ .schedule_at_ms = now_ms + 6_000 }, try decideModelRetry(1, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = now_ms + 3_000,
        .retry_after_ms = 6_000,
    }, now_ms));
    try std.testing.expectEqual(ModelRetryDecision.exhausted, try decideModelRetry(4, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = std.math.maxInt(i64),
    }, now_ms));
    const extreme_delay: u64 = 9_223_372_036_854_775_000;
    try std.testing.expectEqual(ModelRetryDecision{ .schedule_at_ms = now_ms + 2_000 }, try decideModelRetry(1, .{
        .waits_ms = waits,
        .retry_after_ms = extreme_delay,
    }, now_ms));
    try std.testing.expectEqual(ModelRetryDecision{ .schedule_at_ms = now_ms + 10_000 }, try decideModelRetry(1, .{
        .waits_ms = waits,
        .retry_after_ms = extreme_delay,
        .retry_after_deadline_ms = now_ms + 10_000,
    }, now_ms));
    try std.testing.expectError(error.Overflow, decideModelRetry(1, .{ .waits_ms = waits }, std.math.maxInt(i64) - 1));
}

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "direct/historical-corrupt", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", "direct/historical-corrupt", file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    var attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try attempt.permit.consume();

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(storage.database, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/historical-corrupt'");
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    var view = try storage.openHistoricalView(binding);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, view.settings());
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, "request_preparation_failed", .terminal, .{}),
    );
}

test "idle runnable probe uses the pending-only admission index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try prepare(storage.database, "EXPLAIN QUERY PLAN " ++ runnable_probe_sql);
    defer _ = c.sqlite3_finalize(statement);
    var uses_pending_index = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const detail = pointer[0..@intCast(length)];
            uses_pending_index = uses_pending_index or
                std.mem.indexOf(u8, detail, "message_admission_pending") != null;
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_pending_index);
}

test "runnable selection finds age through pending index then groups one session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try prepare(storage.database, "EXPLAIN QUERY PLAN " ++ runnable_selection_sql);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    const QueryCost = struct {
        const Result = struct {
            steps: i32,
            first_admission: i64,
        };

        fn reset(database: *c.sqlite3, eligible: usize, ineligible: usize, history: usize) !void {
            try exec(database, "DELETE FROM message_admission; DELETE FROM session_stop; DELETE FROM model_operation; DELETE FROM turn; DELETE FROM session");
            if (ineligible != 0) {
                try exec(
                    database,
                    "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode," ++
                        "output_schema_content_id,revision,next_position) VALUES('stopped','/','model-a',1,0,0,NULL,1,1)",
                );
                const insert = try std.fmt.allocPrintSentinel(
                    std.testing.allocator,
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                        "SELECT value,'stopped',printf('stopped-%d',value),1,NULL FROM sequence; " ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                        "VALUES('stop','stopped',NULL,{0})",
                    .{ineligible},
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(database, insert);
            }
            const eligible_insert = try std.fmt.allocPrintSentinel(
                std.testing.allocator,
                "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode," ++
                    "output_schema_content_id,revision,next_position) " ++
                    "SELECT printf('eligible-%06d',value),'/','model-a',1,0,0,NULL,1,1 FROM sequence; " ++
                    "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                    "SELECT {1}+value,printf('eligible-%06d',value),printf('eligible-%d',value),1,NULL FROM sequence",
                .{ eligible, ineligible + 1 },
                0,
            );
            defer std.testing.allocator.free(eligible_insert);
            try exec(database, eligible_insert);
            if (history != 0) {
                const history_insert = try std.fmt.allocPrintSentinel(
                    std.testing.allocator,
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id) " ++
                        "SELECT {1}+value,'history',printf('history-%d',value),1,value FROM sequence",
                    .{ history, ineligible + eligible },
                    0,
                );
                defer std.testing.allocator.free(history_insert);
                try exec(database, history_insert);
            }
        }

        fn measureProbe(database: *c.sqlite3) !i32 {
            const statement = try prepare(database, runnable_probe_sql);
            defer _ = c.sqlite3_finalize(statement);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
            return c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        }

        fn measureSelection(database: *c.sqlite3) !Result {
            const statement = try prepare(database, runnable_selection_sql);
            defer _ = c.sqlite3_finalize(statement);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
            var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
            try readText(statement, 0, &session_ref);
            if (!session_ref.eql("eligible-000000")) return error.RunnableSelectionFailed;
            const first_admission = c.sqlite3_column_int64(statement, 1);
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
            return .{
                .steps = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0),
                .first_admission = first_admission,
            };
        }

        fn measureDrain(database: *c.sqlite3, eligible: usize) !i64 {
            const mark = try prepare(database, "UPDATE message_admission SET turn_id=admission_id WHERE admission_id=?1");
            defer _ = c.sqlite3_finalize(mark);
            var total_steps: i64 = 0;
            for (0..eligible) |index| {
                const statement = try prepare(database, runnable_selection_sql);
                defer _ = c.sqlite3_finalize(statement);
                if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.RunnableSelectionFailed;
                const first_admission = c.sqlite3_column_int64(statement, 1);
                if (first_admission != index + 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.RunnableSelectionFailed;
                total_steps += c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);

                try bindI64(mark, 1, first_admission);
                try expectDone(mark);
                if (c.sqlite3_changes(database) != 1) return error.RunnableSelectionFailed;
                if (c.sqlite3_reset(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
                if (c.sqlite3_clear_bindings(mark) != c.SQLITE_OK) return error.RunnableSelectionFailed;
            }
            return total_steps;
        }
    };

    var history_probe_costs: [3]i32 = undefined;
    var history_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |history, index| {
        try QueryCost.reset(storage.database, 1, 0, history);
        history_probe_costs[index] = try QueryCost.measureProbe(storage.database);
        const measured = try QueryCost.measureSelection(storage.database);
        try std.testing.expectEqual(@as(i64, 1), measured.first_admission);
        history_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(@max(history_probe_costs[0], history_probe_costs[1], history_probe_costs[2]) -
        @min(history_probe_costs[0], history_probe_costs[1], history_probe_costs[2]) <= 16);
    try std.testing.expect(@max(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) -
        @min(history_selection_costs[0], history_selection_costs[1], history_selection_costs[2]) <= 32);

    var ineligible_probe_costs: [3]i32 = undefined;
    var ineligible_selection_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |ineligible, index| {
        try QueryCost.reset(storage.database, 1, ineligible, 0);
        ineligible_probe_costs[index] = try QueryCost.measureProbe(storage.database);
        const measured = try QueryCost.measureSelection(storage.database);
        try std.testing.expectEqual(@as(i64, @intCast(ineligible + 1)), measured.first_admission);
        ineligible_selection_costs[index] = measured.steps;
    }
    try std.testing.expect(ineligible_probe_costs[1] > ineligible_probe_costs[0]);
    try std.testing.expect(ineligible_probe_costs[2] > ineligible_probe_costs[1]);
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

test "content reader metadata and decode window remain bounded" {
    try std.testing.expect(@sizeOf(ContentReader) <= projection_read_window_bytes + 512);
    try std.testing.expect(@sizeOf(HistoricalReader) <= projection_read_window_bytes + 1024);
}

test "continuation risk follows output and active Turn indexes without Operation scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try prepare(storage.database, "EXPLAIN QUERY PLAN " ++ continuation_risk_sql);
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, "direct/query-plan");
    var uses_output_index = false;
    var uses_active_turn_index = false;
    var uses_current_operation_identity = false;
    var scans_model_operations = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const detail = pointer[0..@intCast(length)];
            uses_output_index = uses_output_index or
                std.mem.indexOf(u8, detail, "model_output_history") != null;
            uses_active_turn_index = uses_active_turn_index or
                std.mem.indexOf(u8, detail, "turn_one_active_per_session") != null;
            uses_current_operation_identity = uses_current_operation_identity or
                (std.mem.indexOf(u8, detail, "current") != null and
                    std.mem.indexOf(u8, detail, "INTEGER PRIMARY KEY") != null);
            const scans_relation = std.mem.startsWith(u8, detail, "SCAN ") or
                std.mem.indexOf(u8, detail, " SCAN ") != null;
            scans_model_operations = scans_model_operations or
                (scans_relation and
                    (std.mem.indexOf(u8, detail, "current") != null or
                        std.mem.indexOf(u8, detail, "model_operation") != null));
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_output_index);
    try std.testing.expect(uses_active_turn_index);
    try std.testing.expect(uses_current_operation_identity);
    try std.testing.expect(!scans_model_operations);
}

test "retry admission and exhausted recovery use their selection indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const queries = [_]struct { sql: [:0]const u8, index: []const u8, no_temporary_sort: bool }{
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms " ++
                "FROM model_operation INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL " ++
                "AND allowance_used<4 AND retry_due_at_ms<=99 ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_due",
            .no_temporary_sort = false,
        },
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id FROM model_operation " ++
                "INDEXED BY model_operation_retry_exhausted WHERE resolution_code IS NULL " ++
                "AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0 " ++
                "ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_exhausted",
            .no_temporary_sort = true,
        },
    };
    for (queries) |query| {
        const statement = try prepare(storage.database, query.sql);
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

test "retry due index excludes future population and preserves age ordering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    const QueryCost = struct {
        fn measure(database: *c.sqlite3, sql: [:0]const u8, snapshot_ms: i64, limit: i64) !i32 {
            const statement = try prepare(database, sql);
            defer _ = c.sqlite3_finalize(statement);
            try bindI64(statement, 1, snapshot_ms);
            try bindI64(statement, 2, limit);
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
    try exec(
        storage.database,
        "CREATE INDEX test_model_operation_retry_age ON model_operation(operation_id) " ++
            "WHERE resolution_code IS NULL AND allowance_used<4",
    );
    const age_control_sql =
        "SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms FROM model_operation " ++
        "INDEXED BY test_model_operation_retry_age WHERE resolution_code IS NULL AND allowance_used<4 " ++
        "AND retry_due_at_ms<=?1 ORDER BY operation_id LIMIT ?2";
    for ([_]usize{ 100, 1_000, 10_000 }, 0..) |future_count, index| {
        try exec(storage.database, "DELETE FROM model_operation");
        const insert = try std.fmt.allocPrintSentinel(
            std.testing.allocator,
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
                "SELECT value,value,printf('future-%d',value),1,1,1,1,1,0,9223372036854775807 FROM sequence; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) VALUES" ++
                "({1},{1},'older-due',1,1,1,1,1,0,99),({2},{2},'earlier-deadline',1,1,1,1,1,0,1)",
            .{ future_count, future_count + 1, future_count + 2 },
            0,
        );
        defer std.testing.allocator.free(insert);
        try exec(storage.database, insert);
        future_costs[index] = try QueryCost.measure(storage.database, retry_admission_select_sql, 99, 2);
        age_control_costs[index] = try QueryCost.measure(storage.database, age_control_sql, 99, 2);
    }
    const minimum_future_cost = @min(future_costs[0], future_costs[1], future_costs[2]);
    const maximum_future_cost = @max(future_costs[0], future_costs[1], future_costs[2]);
    try std.testing.expect(maximum_future_cost - minimum_future_cost <= 16);
    try std.testing.expect(age_control_costs[2] > age_control_costs[0] * 10);

    var due_costs: [3]i32 = undefined;
    for ([_]usize{ 10, 100, 1_000 }, 0..) |due_count, index| {
        try exec(storage.database, "DELETE FROM model_operation");
        const insert = try std.fmt.allocPrintSentinel(
            std.testing.allocator,
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
                "SELECT value,value,printf('due-%d',value),1,1,1,1,1,0,1 FROM sequence",
            .{due_count},
            0,
        );
        defer std.testing.allocator.free(insert);
        try exec(storage.database, insert);
        due_costs[index] = try QueryCost.measure(storage.database, retry_admission_select_sql, 99, 2);
    }
    try std.testing.expect(due_costs[1] > due_costs[0]);
    try std.testing.expect(due_costs[2] > due_costs[1]);

    try exec(storage.database, "DELETE FROM model_operation");
    try exec(
        storage.database,
        "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) VALUES" ++
            "(1,1,'oldest-active',1,1,1,1,1,0,99)," ++
            "(2,2,'oldest-free',1,1,1,1,1,0,50)," ++
            "(3,3,'earliest-deadline',1,1,1,1,1,0,1)",
    );
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

test "retry transitions preserve age and settle one exhausted outcome per call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<201) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
            "SELECT value,value,printf('retry-%d',value),1,1,1,1,1,0," ++
            "CASE WHEN value<=100 THEN 9223372036854775807 ELSE 1 END FROM sequence",
    );

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
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 5150), comparisons);
    comparisons = 0;
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, 201), admitted.permit.binding.operation_id);
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.attempt_ordinal);
    try std.testing.expectEqual(@as(usize, 5150), comparisons);

    try exec(storage.database, "DELETE FROM model_operation");
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(6000) UNION ALL SELECT value+1 FROM sequence WHERE value<6101) " ++
            "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) " ++
            "SELECT value,printf('exhausted-%d',value),1,1,value FROM sequence",
    );
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(6000) UNION ALL SELECT value+1 FROM sequence WHERE value<6101) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
            "SELECT value,value,printf('exhausted-%d',value),1,1,1,4,4,1,0 FROM sequence",
    );
    try exec(storage.database, "PRAGMA foreign_keys=ON");

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
    const outcomes = try prepare(
        storage.database,
        "SELECT operation_id,resolution_code FROM model_operation WHERE operation_id IN (6100,6101) ORDER BY operation_id",
    );
    defer _ = c.sqlite3_finalize(outcomes);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6100), c.sqlite3_column_int64(outcomes, 0));
    var resolution: protocol.Bounded(96) = .{};
    try readText(outcomes, 1, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 6101), c.sqlite3_column_int64(outcomes, 0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(outcomes, 1));
}
