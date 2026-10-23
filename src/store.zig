const std = @import("std");
const attempt = @import("attempt.zig");
const named_scratch = @import("named_scratch.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const model_capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const tool_catalog = @import("tools.zig");
const output_format = @import("output_format.zig");
const provider_output = @import("provider_output.zig");
const retry_policy = @import("retry_policy.zig");
const turn_policy = @import("turn_policy.zig");

const c = @import("sqlite");

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 33;
pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;
pub const ModelAdmissionKind = enum { message, tool_continuation };

/// SQL membership in a Turn policy resolution set, generated at compile time.
inline fn resolutionIn(comptime column: []const u8, comptime set: []const turn_policy.Resolution) []const u8 {
    comptime var sql: []const u8 = column ++ " IN (";
    inline for (set, 0..) |resolution, index| sql = sql ++ (if (index == 0) "'" else ",'") ++ @tagName(resolution) ++ "'";
    return sql ++ ")";
}

inline fn resolutionIs(comptime column: []const u8, comptime resolution: turn_policy.Resolution) []const u8 {
    return column ++ "='" ++ @tagName(resolution) ++ "'";
}

const public_tool_groups_sql = "WITH groups AS (SELECT op.operation_id,max(coalesce(call.acceptance_position,action.acceptance_position)) AS position " ++
    "FROM model_operation op JOIN model_tool_call call ON call.operation_id=op.operation_id " ++
    "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
    "WHERE op.session_ref=?1 AND " ++ resolutionIs("op.resolution_code", .tool_proposals) ++ " GROUP BY op.operation_id " ++
    "HAVING count(*)=(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
    "AND count(coalesce(call.acceptance_position,action.acceptance_position))=count(*) " ++
    "AND count(coalesce(call.rejection_content_id,action.resolution_content_id))=count(*)), ";
const activity_sql = public_tool_groups_sql ++
    "entries AS (SELECT admission_position AS position,0 AS ordinal,1 AS kind,admission_id AS id FROM message_admission WHERE session_ref=?1 " ++
    "UNION ALL SELECT session_position,0,CASE entry_kind WHEN 1 THEN 2 ELSE 3 END,source_admission_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind IN (1,3) " ++
    "UNION ALL SELECT session_position,0,4,NULL FROM model_output_item WHERE session_ref=?1 AND item_kind=3 " ++
    "UNION ALL SELECT sender_position,0,8,admission_id FROM message_admission WHERE sender_session_ref=?1), " ++
    "completions AS (SELECT groups.position AS position,call.call_ordinal+1 AS ordinal,5 AS kind,NULL AS id FROM groups JOIN model_tool_call call ON call.operation_id=groups.operation_id " ++
    "UNION ALL SELECT outcome_position,0,6,turn_id FROM turn WHERE session_ref=?1 AND outcome_code IS NOT NULL " ++
    "UNION ALL SELECT position,0,7,NULL FROM session_stop WHERE session_ref=?1 " ++
    // Each compound keeps within the Store's four-term limit.
    "UNION ALL SELECT sender_position,0,9,NULL FROM sent_rejection WHERE sender_session_ref=?1), " ++
    "activity AS (SELECT * FROM entries UNION ALL SELECT * FROM completions) ";
const complete_tool_results_sql =
    resolutionIs("current.resolution_code", .tool_proposals) ++ " AND EXISTS(" ++
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
    " AND (" ++ resolutionIn("current.resolution_code", &turn_policy.continues_with_input) ++ " OR (" ++ complete_tool_results_sql ++ "))" ++
    "))";
const runnable_probe_sql =
    "SELECT 1 FROM message_admission m INDEXED BY message_admission_pending WHERE " ++
    runnable_eligibility_sql ++ " LIMIT 1";
const runnable_selection_sql =
    "WITH candidate AS (" ++
    "SELECT m.session_ref FROM message_admission m INDEXED BY message_admission_pending WHERE " ++
    runnable_eligibility_sql ++ " ORDER BY m.admission_id LIMIT 1) " ++
    "SELECT m.session_ref,min(m.admission_id),max(m.admission_id),count(*),s.revision,s.next_position," ++
    "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    "AND (" ++ resolutionIn("current.resolution_code", &turn_policy.continues_with_input) ++ " OR (" ++ complete_tool_results_sql ++ "))) " ++
    "FROM candidate chosen JOIN message_admission m INDEXED BY message_admission_session_order " ++
    "ON m.session_ref=chosen.session_ref JOIN session s ON s.session_ref=m.session_ref " ++
    "WHERE " ++ runnable_eligibility_sql ++
    " GROUP BY m.session_ref";
const tool_continuation_selection_sql =
    "SELECT active.session_ref,active.first_admission_id,active.input_cutoff,0,s.revision,s.next_position,active.turn_id " ++
    "FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "JOIN session s ON s.session_ref=active.session_ref WHERE active.outcome_code IS NULL AND " ++
    "(" ++ resolutionIn("current.resolution_code", &turn_policy.continues_without_input) ++ " OR " ++ complete_tool_results_sql ++ ") AND NOT EXISTS(SELECT 1 FROM message_admission m " ++
    "WHERE m.session_ref=active.session_ref AND " ++ runnable_eligibility_sql ++
    ") ORDER BY current.operation_id LIMIT 1";
const session_stop_cutoff_sql =
    "SELECT admission_cutoff FROM session_stop WHERE session_ref=?1 ORDER BY admission_cutoff DESC LIMIT 1";
const pending_message_count_sql =
    "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2";
/// Matches the partial retry indexes' text, which the schema fixes.
const retry_allowance_open_sql = std.fmt.comptimePrint("allowance_used<{d}", .{retry_policy.maximum_attempts});
const retry_admission_select_sql =
    "SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms FROM model_operation " ++
    "INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL AND " ++ retry_allowance_open_sql ++ " " ++
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

pub const ControlTracePhase = enum { lock_requested, lock_acquired, durable_acceptance, store_complete };

pub const ControlTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, ControlTracePhase) void,

    fn mark(self: ControlTrace, phase: ControlTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const SettlementTracePhase = enum {
    lock_requested,
    lock_acquired,
    transaction_active,
    settlement_complete,
};

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
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
};

pub const ConfigurationRejection = enum {
    invalid_session_reference,
    unknown_session,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    invalid_output_reservation,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
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
    invalid_sender_handle,
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

pub const SessionStopCompletion = enum { pending, completed };

pub const SessionStopObservation = struct {
    selection: SessionStopSelection,
    completion: SessionStopCompletion,
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
        completion: SessionStopCompletion,
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

pub const ActionAttemptBinding = attempt.ActionAttemptBinding;

pub const SupersedingControl = struct {
    command_key: protocol.Bounded(protocol.max_key_bytes),
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

pub const ActionDispatchPermit = attempt.ActionDispatchPermit;

pub const BashExecutionInput = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    sender_handle: protocol.Bounded(32),
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    arguments: ContentReference,
    timeout_ms: u64,
};

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

pub const PublicConversationItem = struct {
    position: u64,
    ordinal: u64, // Zero for User/Assistant; one-based call ordinal in a completed Tool Result group.
    kind: enum { user, assistant, tool_result },
    content: ContentReference,
    presentation: ?protocol.ToolPresentation = null,
    admitted_at: ?u64 = null, // The Host wall-clock second a User item was admitted.
    sender: ?protocol.Peer = null, // A User item's sending peer Session.
};

pub const PublicConversationPage = struct {
    pub const capacity = protocol.public_conversation_page_items;
    end: u64,
    items: [capacity]PublicConversationItem = undefined,
    count: usize = 0,
    more: bool = false,
};

pub const ProposalPage = struct {
    end: u64,
    items: [protocol.proposal_page_items]protocol.ProposalMetadata = undefined,
    count: usize = 0,
    more: bool = false,
};

pub const MessageObservation = struct {
    content: ContentReference,
    queue: ?AcceptedMessageQueue = null,
    // Present only while this admission can still advance. This is a fact
    // about its active dependency, not an instruction to a particular caller.
    progress: ?MessageProgress = null,
};

pub const MessageProgress = struct {
    pub const Status = enum { runnable, in_flight, waiting_for_permission };
    status: Status,
    action_id: ?u64 = null,
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

pub const AttemptBinding = attempt.AttemptBinding;
pub const DispatchPermit = attempt.DispatchPermit;

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
};

/// Borrowed from one pointer-stable preparation view. Invalid after it closes.
pub const HistoricalContent = struct {
    view: *HistoricalView,
    length: u64,
    digest: [32]u8,
    private: bool = false,
    item_identity: ?struct { kind: OutputItemKind, id_digest: [32]u8 } = null,

    fn belongsTo(self: HistoricalContent, view: *HistoricalView) bool {
        return self.view == view and view.active;
    }
};

pub const ModelFailureClass = union(enum) {
    ordinary,
    context_overflow,
    retryable: retry_policy.Input,
};

/// What the provider returned decides which provenance a failed Attempt's
/// settlement must carry, so an answered failure cannot settle without it.
pub const ModelFailure = union(enum) {
    /// No provider HTTP status reached classification: preparation,
    /// transport or capture failure. The code is the only recorded fact.
    uncorrelated: []const u8,
    /// The provider answered: an HTTP error status, or a sealed successful
    /// response that never reached validation.
    correlated: Correlated,
    /// Validation or settlement rejected a sealed successful response.
    rejected: Rejected,

    pub const Correlated = struct {
        code: []const u8,
        /// The provider's own correlation; empty when it sent none.
        request_id: protocol.Bounded(256),
    };

    pub const Rejected = struct {
        code: []const u8,
        // Borrowed for settlement only; never Turn output or model continuation.
        diagnostic: []const u8,
        request_id: protocol.Bounded(256),
    };

    fn code(self: *const ModelFailure) []const u8 {
        return switch (self.*) {
            .uncorrelated => |value| value,
            .correlated => |value| value.code,
            .rejected => |value| value.code,
        };
    }

    fn diagnostic(self: *const ModelFailure) ?[]const u8 {
        return switch (self.*) {
            .rejected => |value| value.diagnostic,
            .uncorrelated, .correlated => null,
        };
    }

    fn requestId(self: *const ModelFailure) []const u8 {
        return switch (self.*) {
            .uncorrelated => "",
            .correlated => |*value| value.request_id.slice(),
            .rejected => |*value| value.request_id.slice(),
        };
    }
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

const ModelOperationKind = output_format.ModelOperationKind;

pub const HistoricalSettings = struct {
    operation: ModelOperationKind = .assistant_response,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    provider: protocol.Provider,
    model: protocol.Bounded(protocol.max_model_bytes),
    workspace: protocol.Bounded(protocol.max_workspace_bytes),
    /// The originating Operation's own address: canonical Store selector and
    /// exact Session reference, for the Rui-owned request context.
    store: protocol.Bounded(protocol.max_store_bytes),
    session: protocol.Bounded(protocol.max_session_bytes),
    session_affinity: [16]u8,
    baseline_instructions: HistoricalContent,
    output_schema: ?HistoricalContent,
    tools_mask: u8,
};

pub const HistoricalEntryKind = enum { user, instruction, provider_output, tool_results };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ?HistoricalContent = null,
    requested_model: ?protocol.Bounded(protocol.max_model_bytes) = null,
    // A User entry's peer sender, in this view's Store.
    sender: ?protocol.Bounded(protocol.max_session_bytes) = null,
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
    outputs_validated: bool = false,
    output_frontier: ?u64 = null,
    output_boundary: u64 = 0,
    output_cursor: u64 = 0,
    output_cursor_id: u64 = 0,
    output_source: u64 = 0,
    output_expected: u64 = 0,
    output_count: u64 = 0,
    output_previous_position: u64 = 0,
    group_scan: GroupScan = .{},
    next_tool_group_count: u64 = 0,
    active_tool_group_expected: u64 = 0,

    // One population cursor and one private-item validator, independent of
    // group/call counts. No statement, blob handle or transaction survives a step.
    const GroupScan = struct {
        source: u64 = 0,
        boundary: u64 = 0,
        admission: u64 = 0,
        expected_items: u64 = 0,
        previous_position: u64 = 0,
        item: u64 = 0,
        calls: u64 = 0,
        position: u64 = 0,
        reader: ?ContentReader = null,
        hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
        validation: @import("provider_output.zig").ReplayValidationCursor = .{},
        fields: @FieldType(protocol.ProposalMetadata, "fields") = undefined,
    };

    pub const EntryProgress = union(enum) { pending, ready: ?HistoricalEntry };

    /// Charge discovery/classification items and private authentication bytes
    /// to the same caller allowance. Pending exposes no storage-level state.
    pub fn nextEntryStep(self: *HistoricalView, after_position: u64, bytes_left: *usize, items_left: *usize) !EntryProgress {
        std.debug.assert(self.active and self.outputs_validated and self.active_tool_group_source_id == null);
        if (bytes_left.* == 0 or items_left.* == 0) return .pending;
        if (self.group_scan.reader == null) items_left.* -= 1;
        return self.store.readHistoricalEntry(self, after_position, bytes_left, items_left) catch |err| switch (err) {
            error.HistoricalPending => .pending,
            else => return err,
        };
    }

    pub fn settings(self: *HistoricalView) !HistoricalSettings {
        std.debug.assert(self.active);
        return self.store.readHistoricalSettings(self);
    }

    /// Validate at most one producing Operation or output item, releasing
    /// Store custody between steps. Returns true after the complete population.
    pub fn validateOutputsStep(self: *HistoricalView) !bool {
        std.debug.assert(self.active);
        return self.store.validateHistoricalOutputsStep(self);
    }

    pub fn nextEntry(self: *HistoricalView, after_position: u64) !?HistoricalEntry {
        std.debug.assert(self.active);
        std.debug.assert(self.active_tool_group_source_id == null);
        while (!try self.validateOutputsStep()) {}
        while (true) {
            var bytes: usize = 64 * 1024;
            var items: usize = 1024;
            switch (try self.nextEntryStep(after_position, &bytes, &items)) {
                .pending => {},
                .ready => |entry| return entry,
            }
        }
    }

    /// Validated selected base position. Interpretation belongs to the caller.
    pub fn contextAnchor(self: *HistoricalView) !?u64 {
        std.debug.assert(self.active);
        while (!try self.validateOutputsStep()) {}
        return self.store.selectedContextAnchor(self.binding);
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
        if (self.group_scan.reader) |*reader| reader.close();
        self.active = false;
    }

    /// Test/slow-check aid: outstanding borrowed readers owned by this view.
    /// Legal checkpoint is between synchronous preparation advances, while
    /// the preparation owner remains in final storage under the existing
    /// single-owner discipline. No new state is maintained.
    pub fn outstandingReaders(self: *const HistoricalView) usize {
        return self.readers;
    }

    /// Test/slow-check aid: the view has not been closed. Reader closure
    /// before view closure is enforced by the close-path asserts; this
    /// exposes the committed fact for integrity checks.
    pub fn isActive(self: *const HistoricalView) bool {
        return self.active;
    }

    /// Test/slow-check aid: borrowed content belongs to this live view.
    /// References are validated at open; this re-checks the committed fact
    /// without treating notifications or hints as authority.
    pub fn ownsContent(self: *HistoricalView, content: HistoricalContent) bool {
        return content.belongsTo(self);
    }

    /// Test/slow-check aid: this view owns the admitted Attempt binding.
    /// Lets preparation checks verify owner correspondence without exposing
    /// storage rows or a generic query language.
    pub fn bindingMatches(self: *const HistoricalView, expected: AttemptBinding) bool {
        return self.binding.turn_id == expected.turn_id and
            self.binding.operation_id == expected.operation_id and
            self.binding.attempt_ordinal == expected.attempt_ordinal;
    }

    /// Test/slow-check aid: frozen settings references belong to this view.
    pub fn ownsSettings(self: *HistoricalView, frozen: HistoricalSettings) bool {
        if (!self.ownsContent(frozen.baseline_instructions)) return false;
        if (frozen.output_schema) |schema| {
            if (!self.ownsContent(schema)) return false;
        }
        return true;
    }
};

pub const HistoricalReader = struct {
    reader: ContentReader,
    view: *HistoricalView,
    reference: HistoricalContent,
    active: bool = true,
    hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
    verified_position: u64 = 0,
    verified: bool = false,

    fn usable(self: *const HistoricalReader) bool {
        return self.active and self.reference.belongsTo(self.view);
    }

    /// Test/slow-check aid: this live reader is owned by the given view.
    /// Reuses the same active/borrowed-view facts as the production read
    /// path; introduces no registry or additional state.
    pub fn ownedBy(self: *const HistoricalReader, view: *HistoricalView) bool {
        return self.view == view and self.usable();
    }

    pub fn read(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.usable());
        const count = try self.reader.read(start, destination);
        if (!self.verified) {
            std.debug.assert(start == self.verified_position);
            self.hash.update(destination[0..count]);
            self.verified_position += count;
            if (self.verified_position == self.reference.length) {
                if (!std.mem.eql(u8, &self.hash.finalResult(), &self.reference.digest))
                    return self.view.store.fence(error.CorruptStore);
                self.verified = true;
            }
        }
        return count;
    }

    pub fn itemIdentity(self: *HistoricalReader) struct { kind: OutputItemKind, id_digest: [32]u8 } {
        std.debug.assert(self.usable() and self.verified);
        const identity = self.reference.item_identity orelse unreachable;
        return .{ .kind = identity.kind, .id_digest = identity.id_digest };
    }

    /// Reread only after the complete canonical content digest was verified.
    pub fn readRange(self: *HistoricalReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.usable() and self.verified);
        return self.reader.readRange(start, destination);
    }

    /// Canonical documents passed syntax validation before acceptance.
    pub fn malformed(self: *HistoricalReader) anyerror {
        std.debug.assert(self.usable());
        return self.view.store.fence(error.CorruptStore);
    }

    pub fn close(self: *HistoricalReader) void {
        std.debug.assert(self.usable());
        self.reader.close();
        self.view.readers -= 1;
        self.active = false;
    }
};

const OutputItemKind = output_format.OutputItemKind;
const OutputRecordTag = output_format.OutputRecordTag;
const OutputMetadataRecord = output_format.OutputMetadataRecord;
const OutputMetadataWriter = output_format.OutputMetadataWriter;
const OutputMetadataReader = output_format.OutputMetadataReader;
const output_metadata_record_bytes = output_format.output_metadata_record_bytes;

pub const ValidatedOutput = struct {
    source: std.Io.File,
    source_length: u64,
    metadata: std.Io.File,
    item_count: u64,
    call_count: u64,
    answer_item_ordinal: ?u64 = null,
    answer_length: u64,
    answer_digest: [32]u8,
    response_id: protocol.Bounded(256),
    /// Adapter-certified opaque observations; Store never decodes provider grammar.
    model_evidence: protocol.Bounded(775),
    request_id: protocol.Bounded(256),
};

pub const SessionObservation = struct {
    found: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: ?protocol.Provider = null,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    revision: u64 = 0,
    tools_mask: u8 = 0,
    compaction_trigger: ?u64 = null,
    output_reservation: u64 = 0,
    compaction_trigger_override: ?u64 = null,
    output_reservation_override: ?u64 = null,
    permission_mode: protocol.Bounded(16) = .{},
    instructions: ContentReference = .{ .length = 0, .digest = @splat(0) },
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

pub const SessionListOptions = struct {
    scratch_path: []const u8,
    scratch_budget: protocol.ScratchBudget,
    request_number: u64,
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

    fn init(io: std.Io, scratch_path: []const u8, budget: protocol.ScratchBudget, request_number: u64, fail_unlink: bool) !SessionReportCapture {
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.report.format(&name_buffer, request_number, 1);
        const writer = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        errdefer writer.close(io);
        if (fail_unlink) return error.ReportScratchCleanupFailed;
        scratch.deleteFile(io, name) catch return error.ReportScratchCleanupFailed;
        return .{
            .io = io,
            .writer = writer,
            .budget = budget,
        };
    }

    pub fn append(self: *SessionReportCapture, bytes: []const u8) !void {
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
        if (tools_mask > tool_catalog.toolBit(.bash)) return error.CorruptStore;
        try self.append("[");
        if (tools_mask & tool_catalog.toolBit(.bash) != 0) try self.append("\"bash\"");
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
        if (!self.budget.allocate(amount)) {
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
/// zero. Readers retain copied bytes and identities, never SQLite handles.
pub const ContentReader = struct {
    pub const content_window_bytes = 64 * 1024;

    content_id: i64,
    representation: union(enum) { raw, projection: ProjectionCursor },
    store: *Store,
    reference: ContentReference,
    active: bool = true,
    allocator: std.mem.Allocator = std.heap.c_allocator,
    prefetch: ?[]u8 = null,
    prefetch_source: i64 = 0,
    prefetch_start: u64 = 0,
    prefetch_length: usize = 0,

    // Allocate outside Store access. Read-ahead is optional: allocation failure
    // keeps the original bounded read path, not a canonical/Host fault. Small
    // values keep the inline decode window. Encoded projections can exceed
    // the SQLite cache even when their decoded value does not.
    fn prepareRead(self: *ContentReader) void {
        const extent = switch (self.representation) {
            .raw => self.reference.length,
            .projection => |cursor| @max(self.reference.length, cursor.encoded_end),
        };
        if (self.prefetch == null and extent > 1024 * 1024)
            self.prefetch = self.allocator.alloc(u8, content_prefetch_bytes) catch null;
    }

    pub fn read(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active);
        return self.store.readOwnedContent(self, start, destination);
    }

    /// Read public byte coordinates without exposing the saved representation.
    /// The nonempty caller window also discards preceding projected bytes;
    /// backward ranges restart decoding, never retain a payload or seek index.
    pub fn readRange(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active and destination.len > 0);
        if (destination.len > content_window_bytes) return error.WindowTooLarge;
        if (start > self.reference.length) return error.RangeOutOfBounds;
        if (self.representation == .projection) {
            if (start < self.representation.projection.decoded_position) self.representation.projection = .{};
            var offset = self.representation.projection.decoded_position;
            while (offset < start) {
                const wanted: usize = @intCast(@min(start - offset, destination.len));
                _ = try self.read(offset, destination[0..wanted]);
                offset += wanted;
            }
        }
        return self.read(start, destination);
    }

    pub fn close(self: *ContentReader) void {
        std.debug.assert(self.active);
        if (self.prefetch) |bytes| self.allocator.free(bytes);
        self.prefetch = null;
        self.active = false;
        if (@import("builtin").is_test) _ = self.store.testing_content_work.closes.fetchAdd(1, .monotonic);
    }
};

/// One read handle reused only within a locked Store entry point.
/// Its overflow-page index costs SQLite heap of about length/1024 bytes.
const ContentBlob = struct {
    handle: ?*c.sqlite3_blob = null,
    content_id: i64 = 0,

    fn close(self: *ContentBlob) void {
        // Close reports only an earlier read failure, already returned.
        if (self.handle) |handle| _ = c.sqlite3_blob_close(handle);
        self.* = .{};
    }
};

const Tool = tool_catalog.Tool;

/// Decodes a persisted tools_mask.
fn toolSet(mask: c_int) !tool_catalog.ToolSet {
    var set: tool_catalog.ToolSet = .empty;
    var remaining = std.math.cast(u8, mask) orelse return error.CorruptStore;
    inline for (comptime std.meta.tags(Tool)) |tool| {
        if (remaining & tool_catalog.toolBit(tool) != 0) set.insert(tool);
        remaining &= ~tool_catalog.toolBit(tool);
    }
    if (remaining != 0) return error.CorruptStore;
    return set;
}

/// Persisted session.permission_mode for a validated mode name.
fn permissionModeCode(mode: []const u8) u8 {
    return if (std.mem.eql(u8, mode, "ask")) 0 else 1;
}

/// A created Session's tools when configuration omits them.
const default_tools_mask: u8 = blk: {
    var mask: u8 = 0;
    var names = std.mem.splitScalar(u8, product_defaults.tools, ',');
    while (names.next()) |name| mask |= tool_catalog.toolBit(std.meta.stringToEnum(Tool, name).?);
    break :blk mask;
};

const CurrentConfiguration = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: protocol.Provider = undefined,
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    tools_mask: u8 = default_tools_mask,
    permission_mode: u8 = permissionModeCode(product_defaults.permission_mode),
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
    compaction_trigger: ?u64 = null,
    output_reservation: ?u64 = null,
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

fn configurationTokens(field: @TypeOf(@as(protocol.Configuration, .{}).compaction_trigger), previous: ?u64, allow_zero: bool) !?u64 {
    if (field.state == .omitted) return previous;
    if (field.state == .explicit_null) return null;
    if (field.state != .value) return error.InvalidTokenHeuristic;
    const value = std.fmt.parseInt(u64, field.value.slice(), 10) catch return error.InvalidTokenHeuristic;
    if ((!allow_zero and value == 0) or value > std.math.maxInt(i64)) return error.InvalidTokenHeuristic;
    for (field.value.slice()) |byte| if (byte < '0' or byte > '9') return error.InvalidTokenHeuristic;
    return value;
}

fn configurationBeforeWorkspace(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
) ?ConfigurationRejection {
    _ = configurationTokens(requested.compaction_trigger, null, false) catch return .invalid_compaction_trigger;
    _ = configurationTokens(requested.output_reservation, null, true) catch return .invalid_output_reservation;
    const provider = if (requested.provider.state == .value)
        std.meta.stringToEnum(protocol.Provider, requested.provider.value.slice()) orelse return .unsupported_provider
    else
        null;
    if (current == null and
        (requested.workspace.state != .value or provider == null or requested.model.state != .value))
    {
        return .incomplete_initial_configuration;
    }
    if (current) |existing| {
        if (provider) |value| {
            if (value != existing.provider) return .provider_is_immutable;
        }
        if (requested.model.state == .value and
            !existing.model.eql(requested.model.value.slice()))
        {
            return .model_is_immutable;
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
    if (requested.provider.state == .value) next.provider = std.meta.stringToEnum(protocol.Provider, requested.provider.value.slice()).?;
    if (requested.model.state == .value) next.model = requested.model.value;
    if (requested.tools.state == .value) {
        next.tools_mask = 0;
        for (requested.tools.values[0..requested.tools.count]) |tool| {
            next.tools_mask |= tool_catalog.toolBit(tool);
        }
    }
    if (requested.permission_mode.state == .value) {
        next.permission_mode = permissionModeCode(requested.permission_mode.value.slice());
    }
    next.revision = if (created) 1 else current.?.revision + 1;
    next.compaction_trigger = configurationTokens(requested.compaction_trigger, next.compaction_trigger, false) catch unreachable;
    next.output_reservation = configurationTokens(requested.output_reservation, next.output_reservation, true) catch unreachable;

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
    cache_kib: u32 = 1024,
    found_schema_version: ?*u32 = null,
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
    /// Advances before `release` of any entry point that changed rows, so
    /// after every successful COMMIT. An unchanged value proves no canonical
    /// fact changed since it was read; a rolled-back change also advances it.
    commit_generation: std.atomic.Value(u64) = .init(0),
    hot_statements: std.EnumArray(HotStatement, ?*c.sqlite3_stmt) = .initFill(null),
    // Access.release closes the read transaction before unlocking, including
    // errors and yielded historical scans. Logical readers cannot pin the WAL.
    read_blob: ContentBlob = .{},
    // Source-level proof only: no counters/storage in the production Store.
    testing_content_work: if (@import("builtin").is_test) struct { decoded: std.atomic.Value(u64) = .init(0), closes: std.atomic.Value(u64) = .init(0) } else void = if (@import("builtin").is_test) .{} else {},

    /// Expected outcomes of locked entry points. A canonical read or save
    /// fault fences the Host (ARCHITECTURE.md, "Commit boundaries and crash
    /// recovery"), so every other error from an entry point has fenced the
    /// Store before the caller sees it.
    const Ordinary = struct {
        const none = error{};
        const page = error{ SessionNotFound, InvalidCursor };
        const content = error{ContentNotFound};
        const public_content = error{ ContentNotFound, RangeOutOfBounds };
        const action = error{ActionNotFound};
        const result = error{ ResultNotFound, ResultNotReady, ResultFailed };
        const attempt_binding = error{ StaleAttemptBinding, SupersededByControl };
        const historical_entry = attempt_binding || error{HistoricalPending};
        const model_success = attempt_binding || error{InvalidProviderEnvelope};
        const action_attempt = error{StaleActionAttemptBinding};
        const action_dispatch = action_attempt || error{SupersededByControl};

        /// Rejects a declared ordinary name the body cannot return, so a
        /// stale or misspelled name fails to compile instead of fencing.
        fn produced(comptime Set: type, comptime Result: type) void {
            const returned = @typeInfo(@typeInfo(Result).error_union.error_set).error_set.error_names orelse return;
            outer: inline for (@typeInfo(Set).error_set.error_names.?) |name| {
                inline for (returned) |candidate| {
                    if (comptime std.mem.eql(u8, name, candidate)) continue :outer;
                }
                @compileError("ordinary error " ++ name ++ " is not returned by " ++ @typeName(Result));
            }
        }

        fn contains(comptime Set: type, err: anyerror) bool {
            inline for (@typeInfo(Set).error_set.error_names.?) |name| {
                if (err == @field(anyerror, name)) return true;
            }
            return false;
        }
    };

    const AccessTrace = union(enum) {
        none,
        control: ControlTrace,
        settlement: SettlementTrace,

        fn fromControl(trace: ?ControlTrace) AccessTrace {
            return if (trace) |value| .{ .control = value } else .none;
        }

        fn fromSettlement(trace: ?SettlementTrace) AccessTrace {
            return if (trace) |value| .{ .settlement = value } else .none;
        }

        fn mark(self: AccessTrace, phase: enum { requested, acquired, complete }) void {
            switch (self) {
                .none => {},
                .control => |trace| trace.mark(switch (phase) {
                    .requested => .lock_requested,
                    .acquired => .lock_acquired,
                    .complete => .store_complete,
                }),
                .settlement => |trace| trace.mark(switch (phase) {
                    .requested => .lock_requested,
                    .acquired => .lock_acquired,
                    .complete => .settlement_complete,
                }),
            }
        }
    };

    /// Exclusive canonical access for one entry point, from `enter` through
    /// `release`. Errors leave through `finish` or `finishTransaction`, which
    /// return the entry point's declared ordinary errors and fence the rest.
    /// Only `lockAdmin` otherwise takes the mutex, for open/close diagnostics.
    const Access = struct {
        store: *Store,
        trace: AccessTrace,
        changes: i64,

        fn finish(self: Access, comptime Expected: type, result: anytype) @TypeOf(result) {
            comptime Ordinary.produced(Expected, @TypeOf(result));
            return result catch |err| {
                if (Ordinary.contains(Expected, err)) return err;
                return self.store.fence(err);
            };
        }

        /// Rolls back any open transaction first; a failed rollback fences
        /// and replaces the original error, including an ordinary one.
        fn finishTransaction(self: Access, comptime Expected: type, faults: Faults, result: anytype) Transaction(@TypeOf(result)) {
            comptime Ordinary.produced(Expected, @TypeOf(result));
            return result catch |err| {
                self.store.rollbackAfterError(faults) catch |rollback_err| return self.store.fence(rollback_err);
                if (Ordinary.contains(Expected, err)) return err;
                return self.store.fence(err);
            };
        }

        /// Report capture marks its own scratch failures ordinary.
        fn finishCapture(self: Access, capture: *const SessionReportCapture, result: anytype) @TypeOf(result) {
            return result catch |err| {
                if (capture.ordinary_failure) return err;
                return self.store.fence(err);
            };
        }

        fn release(self: Access) void {
            self.store.read_blob.close();
            // Counts autocommit and explicit-transaction writes alike.
            if (c.sqlite3_total_changes64(self.store.database) != self.changes) {
                _ = self.store.commit_generation.fetchAdd(1, .release);
            }
            self.trace.mark(.complete);
            self.store.mutex.unlock(self.store.io);
        }

        fn Transaction(comptime Result: type) type {
            const info = @typeInfo(Result).error_union;
            return (info.error_set || error{CanonicalRollbackFailed})!info.payload;
        }
    };

    fn enter(self: *Store, trace: AccessTrace) error{StoreFenced}!Access {
        if (self.isFenced()) return error.StoreFenced;
        trace.mark(.requested);
        self.mutex.lockUncancelable(self.io);
        const access: Access = .{ .store = self, .trace = trace, .changes = c.sqlite3_total_changes64(self.database) };
        trace.mark(.acquired);
        if (self.isFenced()) {
            access.release();
            return error.StoreFenced;
        }
        return access;
    }

    /// Administrative access without canonical classification.
    fn lockAdmin(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// The only fence setter. Returns `err` so callers can propagate it.
    fn fence(self: *Store, err: anytype) @TypeOf(err) {
        self.fenced.store(true, .release);
        return err;
    }

    pub fn open(io: std.Io, database_path: []const u8, selector: []const u8) !Store {
        return openWithOptions(io, database_path, selector, .{});
    }

    /// Test fixture for a historical producing binding unavailable through
    /// today's immutable Session configuration admission. Requires a newer
    /// current revision, leaving that revision and its frozen inputs intact.
    pub fn setHistoricalModelForTesting(self: *Store, binding: AttemptBinding, model: []const u8) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        var bounded: protocol.Bounded(protocol.max_model_bytes) = .{};
        try bounded.set(model);
        if (bounded.len == 0) return error.InvalidModel;
        const statement = try prepare(self.database, "UPDATE session_revision SET model=?2 " ++
            "WHERE (session_ref,revision)=(SELECT o.session_ref,o.settings_revision FROM model_operation o " ++
            "JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1 AND o.settings_revision<s.revision)");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        try bindText(statement, 2, model);
        try expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingRevision;
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
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database_path}, 0);
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
        // The handle may still be null on later failure paths; never unwrap
        // it while unwinding an open failure.
        errdefer {
            if (database) |db| _ = c.sqlite3_close(db);
        }

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
        // Before the first read: the Host keeps the file lock until close, and
        // WAL then keeps its index in heap memory, so no -shm file exists.
        try exec(database.?, "PRAGMA locking_mode=EXCLUSIVE");
        if (existing) {
            if (options.found_schema_version) |found| found.* = try pragmaInt(database.?, "PRAGMA user_version");
            try validateExisting(database.?, selector);
        }
        try exec(database.?, "PRAGMA busy_timeout=0");
        try exec(database.?, "PRAGMA foreign_keys=ON");
        try exec(database.?, "PRAGMA mmap_size=0");
        try exec(database.?, "PRAGMA temp_store=FILE");
        var cache_size_buffer: [64:0]u8 = undefined;
        const cache_size = try std.fmt.bufPrintSentinel(&cache_size_buffer, "PRAGMA cache_size=-{d}", .{options.cache_kib}, 0);
        try exec(database.?, cache_size);
        try exec(database.?, if (options.cache_spill) "PRAGMA cache_spill=ON" else "PRAGMA cache_spill=OFF");
        try exec(database.?, "PRAGMA synchronous=FULL");
        if (@import("builtin").os.tag == .macos) try exec(database.?, "PRAGMA fullfsync=ON");
        // Validation precedes this, so an incompatible Store keeps its journal mode.
        const journal_mode = diagnosticTextPragma(database.?, "PRAGMA journal_mode=WAL") orelse return error.StoreJournalModeFailed;
        if (!std.mem.eql(u8, journal_mode.slice(), "wal")) return error.StoreJournalModeFailed;
        // Checkpoints truncate a grown WAL back to the auto-checkpoint size.
        try exec(database.?, "PRAGMA journal_size_limit=4194304");
        if (!existing) try bootstrap(database.?, selector);
        // A new Host never inherits a lost Action's sender authority.
        try exec(database.?, "UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL");

        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        return .{ .io = io, .database = database.?, .selector = stored_selector };
    }

    pub fn sqliteDiagnostic(self: *Store) SqliteDiagnostic {
        self.lockAdmin();
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
        self.lockAdmin();
        for (self.hot_statements.values) |statement| _ = c.sqlite3_finalize(statement);
        const close_result = c.sqlite3_close(self.database);
        self.mutex.unlock(self.io);
        if (close_result != c.SQLITE_OK) return error.StoreCloseFailed;
        _ = c.sqlite3_hard_heap_limit64(0);
        self.* = undefined;
    }

    /// Prepares `which` once for the Store's lifetime; the caller resets it
    /// with `resetHot` before releasing the Store mutex.
    fn hot(self: *Store, which: HotStatement) !*c.sqlite3_stmt {
        const slot = self.hot_statements.getPtr(which);
        if (slot.*) |statement| {
            std.debug.assert(c.sqlite3_stmt_busy(statement) == 0);
            return statement;
        }
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v3(self.database, which.sql(), -1, c.SQLITE_PREPARE_PERSISTENT, &statement, null) != c.SQLITE_OK) {
            return error.StatementPrepareFailed;
        }
        slot.* = statement orelse return error.StatementPrepareFailed;
        return slot.*.?;
    }

    pub fn validateRetryWaits(self: *Store, waits_ms: retry_policy.Waits) !void {
        self.lockAdmin();
        defer self.mutex.unlock(self.io);
        try retry_policy.validateWaits(waits_ms, try readUnixMilliseconds(self.io));
    }

    /// The Host supplies its model capability; a configuration that requires
    /// a model is rejected without one.
    pub fn configure(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        model_available: bool,
        faults: Faults,
    ) ConfigureReply {
        const access = self.enter(.none) catch return .infrastructure_failure;
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.configureLocked(command, model_available, faults)) catch .infrastructure_failure;
    }

    fn configureLocked(
        self: *Store,
        request: *const protocol.ConfigureCommand,
        model_available: bool,
        faults: Faults,
    ) !ConfigureReply {
        try exec(self.database, "BEGIN IMMEDIATE");

        // The captured creation intent has no ID. Save its original digest
        // alongside the allocated target so a lost reply never creates twice.
        var resolved = request.*;
        const command = &resolved;
        const creating = request.session.len == 0;
        const digest = request.semanticDigest();
        switch (try self.classifyReplay(ConfigurationRejection, .configure, command.key.slice(), command.session.slice(), &digest)) {
            .fresh => {},
            .conflict => return .conflict,
            .accepted => |existing| return .{ .accepted = .{
                .replayed = true,
                .revision = existing.revision,
                .created = existing.created,
                .session = existing.target,
            } },
            .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
        }

        if (command.require_model and !model_available) {
            return try self.saveConfigurationRejection(command, &digest, .model_capability_unavailable, faults);
        }
        if (!creating and !protocol.validSessionId(command.session.slice())) {
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
        if (!creating and current == null) {
            return try self.saveConfigurationRejection(command, &digest, .unknown_session, faults);
        }
        const current_configuration: ?*const CurrentConfiguration = if (current) |*value| value else null;
        if (configurationBeforeWorkspace(current_configuration, configuration)) |rejection| {
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
            while (true) {
                var random: [protocol.session_id_bytes]u8 = undefined;
                try std.Io.randomSecure(self.io, &random);
                // 32 symbols divide 256 exactly: six independent five-bit
                // draws give 30 bits, without modulo bias or a weak PRNG.
                for (&random) |*byte| byte.* = protocol.session_alphabet[byte.* & 31];
                try resolved.session.set(&random);
                if (try self.insertSession(command.session.slice(), &next)) break;
            }
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
        return .{ .accepted = .{ .replayed = false, .revision = next.revision, .created = created, .session = resolved.session } };
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

    pub fn submitMessage(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) MessageReply {
        const access = self.enter(.none) catch return .infrastructure_failure;
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.submitMessageLocked(command, faults)) catch .infrastructure_failure;
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
        switch (try self.classifyReplay(MessageRejection, .message, command.key.slice(), command.session.slice(), &digest)) {
            .fresh => {},
            .conflict => return .conflict,
            .accepted => |existing| {
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
            },
            .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code, .content = supplied_content } },
        }
        // Only an authenticated Action can acquire a sender position.
        // A committed exact replay above needs no still-live launch handle.
        const sender_valid = try self.messageSenderMatchesLocked(command);
        const sender_known = command.sender != null and sender_valid;
        const code: ?MessageRejection = if (!protocol.validSessionId(command.session.slice()))
            .invalid_session_reference
        else if (!sender_valid)
            .invalid_sender_handle
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
            if (sender_known) if (command.sender) |sender| {
                const statement = try prepare(self.database, "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position) VALUES(?1,?2,?3)");
                defer _ = c.sqlite3_finalize(statement);
                try bindText(statement, 1, command.key.slice());
                try bindText(statement, 2, sender.session.slice());
                try bindU64(statement, 3, try self.claimSessionPosition(sender.session.slice()));
                try expectDone(statement);
            };
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
            if (command.sender) |*sender| sender.session.slice() else null,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{
            .replayed = false,
            .admission_id = admission_id,
            .content = .{ .length = metadata.length, .digest = metadata.digest },
        } };
    }

    fn messageSenderMatchesLocked(self: *Store, command: *const protocol.MessageCommand) !bool {
        const handle = command.sender_handle orelse return command.sender == null;
        const claimed = command.sender orelse return false;
        if (!claimed.store.eql(self.selector.slice())) return false;
        const statement = try prepare(self.database, "SELECT action.session_ref FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
            "WHERE action.sender_handle=?1 AND action.attempt_ordinal=1 AND action.resolution_code IS NULL " ++
            "AND NOT EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, handle.slice());
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return false;
        if (step != c.SQLITE_ROW) return error.ActionReadFailed;
        var sender: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 0, &sender);
        return sender.eql(claimed.session.slice());
    }

    pub fn stopSession(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        const access = self.enter(.fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.stopSessionLocked(command, faults)) catch .infrastructure_failure;
    }

    fn stopSessionLocked(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) !SessionStopReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        switch (try self.classifyReplay(SessionStopRejection, .session_stop, command.key.slice(), command.session.slice(), &digest)) {
            .fresh => {},
            .conflict => return .conflict,
            .accepted => {
                const selection = try self.readSessionStopSelection(command.key.slice());
                return .{ .accepted = .{
                    .replayed = true,
                    .selection = selection,
                    .completion = try self.sessionStopCompletion(selection),
                    .interrupted_operation_id = try self.readInterruptedOperation(command.key.slice()),
                } };
            },
            .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
        }

        if (!protocol.validSessionId(command.session.slice())) {
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
            const position = try self.claimSessionPosition(command.session.slice());
            const insert = try prepare(
                self.database,
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff,position) VALUES(?1,?2,?3,?4,?5)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, command.key.slice());
            try bindText(insert, 2, command.session.slice());
            try bindNullableU64(insert, 3, selected_turn_id);
            try bindI64(insert, 4, cutoff_value);
            try bindU64(insert, 5, position);
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
            const unresolved_actions = try prepare(
                self.database,
                "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 " ++
                    "AND resolution_code IS NULL AND attempt_ordinal=0",
            );
            defer _ = c.sqlite3_finalize(unresolved_actions);
            try bindU64(unresolved_actions, 1, current_operation_id.?);
            if (c.sqlite3_step(unresolved_actions) != c.SQLITE_ROW) return error.ActionReadFailed;
            const unresolved_count = c.sqlite3_column_int64(unresolved_actions, 0);
            if (unresolved_count < 0) return error.CorruptStore;
            if (unresolved_count != 0) {
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
                if (cancelled_count != unresolved_count) return error.StopSelectionChanged;
                current.next_position = try std.math.add(u64, current.next_position, @intCast(cancelled_count));
                try self.updateSession(command.session.slice(), &current);
            }
            try self.completeStoppedTurnIfReady(turn_id);
        }
        const selection = SessionStopSelection{
            .selected_turn_id = selected_turn_id,
            .admission_cutoff = @intCast(cutoff_value),
        };
        const completion = try self.sessionStopCompletion(selection);
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
        return .{ .accepted = .{
            .replayed = false,
            .selection = selection,
            .completion = completion,
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
        const access = self.enter(.fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.interruptModelLocked(command, faults)) catch .infrastructure_failure;
    }

    fn interruptModelLocked(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) !ModelInterruptionReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        const replay = try self.classifyReplay(ModelInterruptionRejection, .model_interruption, command.key.slice(), command.session.slice(), &digest);
        if (replay == .accepted or replay == .rejected) {
            const saved_target = try self.readModelInterruptionTarget(command.key.slice());
            if (!saved_target.session.eql(command.session.slice()) or
                saved_target.turn_id != command.turn_id or
                saved_target.operation_id != command.operation_id) return error.CorruptStore;
        }
        switch (replay) {
            .fresh => {},
            .conflict => return .conflict,
            .accepted => return .{ .accepted = .{ .replayed = true } },
            .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
        }

        var rejection: ?ModelInterruptionRejection = null;
        if (!protocol.validSessionId(command.session.slice())) {
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
            try self.recordTurnOutcomePosition(command.turn_id);
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
        return .{ .accepted = .{ .replayed = false } };
    }

    // The caller owns the Store lock and transaction, including the causing command.
    fn interruptOperation(self: *Store, operation_id: u64, command_key: []const u8) !void {
        const update = try prepare(
            self.database,
            "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL," ++ resolutionIs("resolution_code", .interrupted) ++ "," ++
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
        const access = self.enter(.fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.decidePermissionLocked(command, faults)) catch .infrastructure_failure;
    }

    fn decidePermissionLocked(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) !PermissionDecisionReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        switch (try self.classifyReplay(PermissionDecisionRejection, .permission_decision, command.key.slice(), command.session.slice(), &digest)) {
            .fresh => {},
            .conflict => return .conflict,
            .accepted => return .{ .accepted = .{ .replayed = true } },
            .rejected => |code| return .{ .rejected = .{ .replayed = true, .code = code } },
        }
        var rejection: ?PermissionDecisionRejection = null;
        if (!protocol.validSessionId(command.session.slice())) rejection = .invalid_session_reference else if (command.action_id == 0 or
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
        if (faults.control_trace) |trace| trace.mark(.durable_acceptance);
        return .{ .accepted = .{ .replayed = false } };
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.observeCommandLocked(key));
    }

    fn observeCommandLocked(self: *Store, key: []const u8) !CommandObservation {
        const existing = try self.readExistingCommand(key);
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
                return error.CorruptStore;
            const metadata = try self.readContentMetadata(content_id);
            observation.message = .{
                .content = .{ .length = metadata.length, .digest = metadata.digest },
                .queue = try self.readMessageQueue(
                    key,
                    command.target.slice(),
                    content_id,
                    command.accepted,
                ),
            };
            const queue = observation.message.?.queue orelse return error.CorruptStore;
            switch (queue.state) {
                .queued, .processing => {
                    observation.message.?.progress = try self.readMessageProgress(command.target.slice(), queue.state);
                },
                else => {},
            }
        } else if (command.kind == .session_stop and command.accepted) {
            const selection = try self.readSessionStopSelection(key);
            observation.session_stop = .{
                .selection = selection,
                .completion = try self.sessionStopCompletion(selection),
            };
        } else if (command.kind == .model_interruption) {
            observation.model_interruption = try self.readModelInterruptionTarget(key);
        } else if (command.kind == .permission_decision) {
            const target = try self.readPermissionTarget(key);
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

    fn readMessageProgress(self: *Store, session_ref: []const u8, state: AcceptedMessageQueue.State) !MessageProgress {
        const statement = try prepare(self.database, "SELECT t.turn_id,o.resolution_code FROM turn t INDEXED BY turn_one_active_per_session " ++
            "JOIN model_operation o ON o.operation_id=t.operation_id " ++
            "WHERE t.session_ref=?1 AND t.outcome_code IS NULL");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) {
            if (state != .queued) return error.CorruptStore;
            return .{ .status = .runnable };
        }
        if (step != c.SQLITE_ROW) return error.TurnReadFailed;
        const turn_id = c.sqlite3_column_int64(statement, 0);
        if (turn_id <= 0) return error.CorruptStore;
        if (state == .processing and state.processing.turn_id != @as(u64, @intCast(turn_id))) return error.CorruptStore;
        const resolution = if (c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL) null else blk: {
            var code: protocol.Bounded(96) = .{};
            try readText(statement, 1, &code);
            break :blk code;
        };
        return self.activeMessageProgress(session_ref, resolution);
    }

    fn activeMessageProgress(self: *Store, session_ref: []const u8, resolution: ?protocol.Bounded(96)) !MessageProgress {
        const statement = try prepare(self.database, "SELECT count(*),count(*) FILTER (WHERE action.permission_state=0)," ++
            "min(CASE WHEN action.permission_state=0 THEN action.action_id END) " ++
            "FROM turn active INDEXED BY turn_one_active_per_session " ++
            "JOIN action_operation action ON action.parent_operation_id=active.operation_id " ++
            "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND action.resolution_code IS NULL");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ActionReadFailed;
        const unresolved = c.sqlite3_column_int64(statement, 0);
        const actionable = c.sqlite3_column_int64(statement, 1);
        if (unresolved < 0 or actionable < 0 or actionable > unresolved) return error.CorruptStore;
        const action_id: ?u64 = if (actionable == 0) null else blk: {
            const id = c.sqlite3_column_int64(statement, 2);
            if (id <= 0) return error.CorruptStore;
            break :blk @intCast(id);
        };
        const known = if (resolution) |code| turn_policy.Resolution.parse(code.slice()) else null;
        const status: MessageProgress.Status = if (known) |current|
            if (turn_policy.contains(&turn_policy.continues_with_input, current)) .runnable else if (current == .tool_proposals and actionable != 0 and actionable == unresolved) .waiting_for_permission else if (current == .tool_proposals and unresolved == 0) .runnable else .in_flight
        else
            .in_flight;
        return .{ .status = status, .action_id = action_id };
    }

    pub fn commandResult(self: *Store, key: []const u8) !ContentReference {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.result, self.commandResultLocked(key));
    }

    fn commandResultLocked(self: *Store, key: []const u8) !ContentReference {
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
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.ResultNotFound;
        if (step != c.SQLITE_ROW) return error.ResultReadFailed;
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.inspectSessionLocked(session_ref));
    }

    fn inspectSessionLocked(self: *Store, session_ref: []const u8) !SessionObservation {
        const maybe_current = try self.readSession(session_ref);
        const current = maybe_current orelse return .{};
        const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
        var observation = SessionObservation{
            .found = true,
            .revision = current.revision,
            .tools_mask = current.tools_mask,
            .compaction_trigger = policy.compaction_trigger,
            .output_reservation = policy.output_reservation,
            .compaction_trigger_override = current.compaction_trigger,
            .output_reservation_override = current.output_reservation,
        };
        try observation.session.set(session_ref);
        observation.workspace = current.workspace;
        observation.provider = current.provider;
        observation.model = current.model;
        try observation.permission_mode.set(if (current.permission_mode == 0) "ask" else "bypass");
        if (current.instructions_id) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            observation.instructions = .{ .length = metadata.length, .digest = metadata.digest };
        }
        if (current.output_schema_id) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            observation.output_schema = .{ .length = metadata.length, .digest = metadata.digest };
        }
        observation.pending_messages = try self.countPendingMessages(session_ref);
        try self.validateActiveTurnToolCalls(session_ref, true);
        observation.action_count = try self.countActions(session_ref);
        observation.rejected_call_count = try self.countRejectedCalls(session_ref);
        return observation;
    }

    // Reverse chronological, with call order breaking ties at a completed
    // group's final acceptance position. No transaction survives this call.
    // The fixed end is the last committed position at the first read, not a
    // count of visible rows; a private-only append cannot become public later.
    pub fn publicConversationPage(self: *Store, request: protocol.ConversationPage) !PublicConversationPage {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.page, self.publicConversationPageLocked(request));
    }

    fn publicConversationPageLocked(self: *Store, request: protocol.ConversationPage) !PublicConversationPage {
        if (request.end > std.math.maxInt(i64) or request.before_position > std.math.maxInt(i64) or
            request.before_ordinal > std.math.maxInt(i64) or
            (request.end == 0 and request.before_position != 0) or
            (request.before_position == 0 and request.before_ordinal != 0) or
            (request.end != 0 and request.before_position > request.end)) return error.InvalidCursor;
        const current = (try self.readSession(request.session.slice())) orelse return error.SessionNotFound;
        const end = if (request.end == 0) current.next_position - 1 else request.end;
        if (request.end != 0 and (request.before_position > end or end >= current.next_position or
            end > std.math.maxInt(i64))) return error.InvalidCursor;
        if (request.before_position != 0) {
            _ = self.publicConversationContentLocked(request.session.slice(), request.before_position, request.before_ordinal) catch |err| switch (err) {
                error.ContentNotFound => return error.InvalidCursor,
                else => return err,
            };
        }
        var page = PublicConversationPage{ .end = end };
        if (end == 0) return page;
        // Tool outcomes enter public Conversation only when the entire group
        // settles. Position is then its last acceptance; call ordinal is the
        // stable tie breaker. Private model items/instructions never enter it.
        const statement = try prepare(self.database, public_tool_groups_sql ++
            "public AS (SELECT e.session_position AS position,0 AS ordinal,e.entry_kind AS kind,e.content_id " ++
            "FROM conversation_entry e WHERE e.session_ref=?1 AND e.entry_kind IN (1,3) AND e.session_position<=?2 " ++
            "UNION ALL SELECT groups.position,call.call_ordinal+1,4,coalesce(call.rejection_content_id,action.resolution_content_id) " ++
            "FROM groups JOIN model_tool_call call ON call.operation_id=groups.operation_id " ++
            "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
            "WHERE groups.position<=?2) " ++
            "SELECT position,ordinal,kind,content_id FROM public WHERE (?3=0 OR position<?3 OR (position=?3 AND ordinal<?4)) " ++
            "ORDER BY position DESC,ordinal DESC LIMIT 17");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, request.session.slice());
        try bindU64(statement, 2, end);
        try bindU64(statement, 3, request.before_position);
        try bindU64(statement, 4, request.before_ordinal);
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.ConversationReadFailed;
            if (page.count == page.items.len) {
                page.more = true;
                break;
            }
            const position = c.sqlite3_column_int64(statement, 0);
            const ordinal = c.sqlite3_column_int64(statement, 1);
            const kind = c.sqlite3_column_int(statement, 2);
            const content_id = c.sqlite3_column_int64(statement, 3);
            if (position <= 0 or ordinal < 0 or content_id <= 0 or
                (kind != 1 and kind != 3 and kind != 4) or
                (kind == 4) != (ordinal > 0)) return error.CorruptStore;
            // Do not filter damaged rows out of SQL: validate ordinary
            // producers and the exposed content before publishing metadata.
            const resolved = try self.publicConversationContentLocked(request.session.slice(), @intCast(position), @intCast(ordinal));
            if (resolved.id != content_id or (kind == 1) != (resolved.admitted_at != null)) return error.CorruptStore;
            const metadata = resolved.metadata;
            page.items[page.count] = .{ .position = @intCast(position), .ordinal = @intCast(ordinal), .kind = switch (kind) {
                1 => .user,
                3 => .assistant,
                4 => .tool_result,
                else => unreachable,
            }, .content = .{ .length = metadata.length, .digest = metadata.digest }, .admitted_at = resolved.admitted_at, .sender = if (resolved.sender) |sender| .{ .session = sender } else null, .presentation = if (resolved.tool_operation) |operation| try self.toolPresentationLocked(operation, @intCast(ordinal - 1), @intCast(position)) else null };
            page.count += 1;
        }
        const upper = if (request.before_position == 0) end else @min(end, request.before_position - @intFromBool(request.before_ordinal == 0));
        try self.validateAssistantEntries(request.session.slice(), if (page.more) page.items[page.count - 1].position else 0, upper);
        return page;
    }

    // Resolve the public identity again, rather than accepting a global digest:
    // another Session's content or private provider material is not authority.
    pub fn openPublicConversationContent(self: *Store, request: protocol.ConversationContent) !ContentReader {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.public_content, self.openPublicConversationContentLocked(request));
    }

    fn openPublicConversationContentLocked(self: *Store, request: protocol.ConversationContent) !ContentReader {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or
            request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const content = try self.publicConversationContentLocked(request.session.slice(), request.position, request.ordinal);
        if (request.start > content.metadata.length) return error.RangeOutOfBounds;
        return .{ .store = self, .content_id = content.id, .reference = .{ .length = content.metadata.length, .digest = content.metadata.digest }, .representation = if (try self.contentIsRaw(content.id, content.metadata.length)) .raw else .{ .projection = .{} } };
    }

    // Accepted assistant messages require entries even when a damaged entry
    // would disappear from an inventory rooted in conversation_entry. Inspect
    // only the requested position interval through the existing history index.
    // Compaction messages deliberately have no Conversation certificate.
    fn validateAssistantEntries(self: *Store, session: []const u8, lower: u64, upper: u64) !void {
        if (lower > upper) return;
        const statement = try prepare(self.database, "SELECT 1 FROM model_output_item item JOIN model_operation op ON op.operation_id=item.operation_id " ++
            "LEFT JOIN conversation_entry e ON e.session_ref=item.session_ref AND e.session_position=item.session_position " ++
            "WHERE item.session_ref=?1 AND item.session_position BETWEEN ?2 AND ?3 AND item.item_kind=2 " ++
            "AND op.purpose=0 AND " ++ resolutionIn("op.resolution_code", &turn_policy.accepted) ++
            " AND CASE WHEN e.entry_kind=3 AND e.source_operation_id=item.operation_id AND e.source_item_ordinal=item.item_ordinal " ++
            "AND e.content_id=item.message_content_id AND e.turn_id=op.turn_id AND op.session_ref=item.session_ref " ++
            "AND item.attempt_ordinal=op.attempt_ordinal THEN 0 ELSE 1 END=1 LIMIT 1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, lower);
        try bindU64(statement, 3, upper);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => {},
            c.SQLITE_ROW => return error.CorruptStore,
            else => return error.ConversationReadFailed,
        }
    }

    // A cursor and a byte reader resolve the same public identity and exposed
    // metadata. Neither may accept a private or absent canonical result.
    fn publicConversationContentLocked(self: *Store, session: []const u8, position: u64, ordinal: u64) !struct { id: i64, metadata: ContentMetadata, tool_operation: ?u64, admitted_at: ?u64, sender: ?protocol.Bounded(protocol.max_session_bytes) = null } {
        if (ordinal == 0) try self.validateAssistantEntries(session, position, position);
        // One indexed ordinary identity owns provenance for pages, cursors and
        // bytes. LEFT JOIN retains damage instead of hiding dependencies.
        const statement = try prepare(self.database, if (ordinal == 0)
            "SELECT e.content_id,CASE WHEN c.content_id IS NOT NULL AND c.private=0 AND t.session_ref=e.session_ref AND " ++
                "((e.entry_kind=1 AND m.session_ref=e.session_ref AND m.turn_id=e.turn_id AND m.content_id=e.content_id) OR " ++
                "(e.entry_kind=3 AND o.purpose=0 AND o.session_ref=e.session_ref AND o.turn_id=e.turn_id " ++
                "AND item.item_kind=2 AND item.message_content_id=e.content_id AND item.session_ref=e.session_ref " ++
                "AND item.session_position=e.session_position AND item.attempt_ordinal=o.attempt_ordinal AND source.private=1 " ++
                "AND " ++ resolutionIn("o.resolution_code", &turn_policy.accepted) ++ ")) THEN 1 ELSE 0 END," ++
                "CASE WHEN e.entry_kind=1 THEN m.admitted_at END,CASE WHEN e.entry_kind=1 THEN m.sender_session_ref END FROM conversation_entry e LEFT JOIN turn t ON t.turn_id=e.turn_id " ++
                "LEFT JOIN message_admission m ON m.admission_id=e.source_admission_id " ++
                "LEFT JOIN model_operation o ON o.operation_id=e.source_operation_id " ++
                "LEFT JOIN model_output_item item ON item.operation_id=e.source_operation_id AND item.item_ordinal=e.source_item_ordinal " ++
                "LEFT JOIN content source ON source.content_id=item.content_id " ++
                "LEFT JOIN content c ON c.content_id=e.content_id " ++
                "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind IN(1,3)"
        else
            "SELECT coalesce(call.rejection_content_id,action.resolution_content_id),NOT EXISTS(SELECT 1 FROM model_tool_call linked " ++
                "LEFT JOIN model_output_item item ON item.operation_id=linked.operation_id AND item.item_ordinal=linked.item_ordinal LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
                "LEFT JOIN content source ON source.content_id=item.content_id LEFT JOIN content id ON id.content_id=linked.item_id_content_id LEFT JOIN content rejection ON rejection.content_id=linked.rejection_content_id " ++
                "LEFT JOIN action_operation a ON a.parent_operation_id=linked.operation_id AND a.call_ordinal=linked.call_ordinal " ++
                "LEFT JOIN content result ON result.content_id=a.resolution_content_id " ++
                "WHERE linked.operation_id=op.operation_id AND CASE WHEN item.item_kind=3 AND item.session_ref=op.session_ref AND t.session_ref=op.session_ref " ++
                "AND item.attempt_ordinal=op.attempt_ordinal AND source.private=1 AND id.private=0 AND id.digest=item.item_id_digest AND " ++
                "((linked.rejection_code IS NOT NULL AND a.action_id IS NULL AND rejection.private=0) OR (linked.rejection_code IS NULL AND a.action_id IS NOT NULL AND a.session_ref=op.session_ref AND result.private=0)) THEN 0 ELSE 1 END=1),op.operation_id,call.call_ordinal FROM model_operation op " ++
                "JOIN model_tool_call call ON call.operation_id=op.operation_id " ++
                "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
                "WHERE op.session_ref=?1 AND " ++ resolutionIs("op.resolution_code", .tool_proposals) ++ " AND call.call_ordinal+1=?3 " ++
                "AND (SELECT max(coalesce(c.acceptance_position,a.acceptance_position)) FROM model_tool_call c " ++
                "LEFT JOIN action_operation a ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id)=?2 " ++
                "AND (SELECT count(*) FROM model_tool_call c WHERE c.operation_id=op.operation_id)=" ++
                "(SELECT count(*) FROM model_output_item item WHERE item.operation_id=op.operation_id AND item.item_kind=3) " ++
                "AND NOT EXISTS (SELECT 1 FROM model_tool_call c LEFT JOIN action_operation a " ++
                "ON a.parent_operation_id=c.operation_id AND a.call_ordinal=c.call_ordinal WHERE c.operation_id=op.operation_id " ++
                "AND (coalesce(c.acceptance_position,a.acceptance_position) IS NULL OR coalesce(c.rejection_content_id,a.resolution_content_id) IS NULL))");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, position);
        if (ordinal != 0) try bindU64(statement, 3, ordinal);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return error.ContentNotFound,
            else => return if (ordinal == 0) error.ConversationReadFailed else error.PublicContentReadFailed,
        }
        if (c.sqlite3_column_int(statement, 1) != 1) return error.CorruptStore;
        const content_id = c.sqlite3_column_int64(statement, 0);
        if (content_id <= 0) return error.CorruptStore;
        const operation: ?u64 = if (ordinal == 0) null else @intCast(try readNullablePositiveI64(statement, 2) orelse return error.CorruptStore);
        if (operation) |op| _ = try self.readToolOutcomeFacts(op, true, false);
        const admitted_at: ?u64 = if (ordinal == 0) if (try readNullablePositiveI64(statement, 2)) |second| @intCast(second) else null else null;
        var sender: ?protocol.Bounded(protocol.max_session_bytes) = null;
        if (ordinal == 0 and c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL) {
            sender = .{};
            try readText(statement, 3, &sender.?);
        }
        return .{ .id = content_id, .metadata = try self.readPublicContentMetadata(content_id), .tool_operation = operation, .admitted_at = admitted_at, .sender = sender };
    }

    const ContentSource = struct {
        store: *Store,
        reader: ContentReader,
        position: u64 = 0,
        end: u64,
        window: [4096]u8 = undefined,
        used: usize = 0,
        count: usize = 0,

        fn init(storage: *Store, id: i64, private: bool) !ContentSource {
            const metadata = try storage.readContentMetadata(id);
            return .{ .store = storage, .reader = try storage.openContentIdentityLocked(.{ .length = metadata.length, .digest = metadata.digest }, private), .end = metadata.length };
        }

        pub fn peek(source: *@This()) !?u8 {
            if (source.used == source.count) {
                const wanted: usize = @intCast(@min(source.window.len, source.end - source.position));
                try source.store.readOwnedContentLocked(&source.reader, source.position, source.window[0..wanted]);
                source.count = wanted;
                source.used = 0;
                if (source.count == 0) return null;
            }
            return source.window[source.used];
        }

        pub fn take(source: *@This()) !u8 {
            const byte = try source.peek() orelse return error.UnexpectedEof;
            source.used += 1;
            source.position += 1;
            return byte;
        }

        pub fn next(source: *@This()) !?u8 {
            return if (try source.peek() != null) try source.take() else null;
        }

        pub fn offset(source: *@This()) u64 {
            return source.position;
        }

        pub fn setRange(source: *@This(), start: u64, length: u64) !void {
            const end = try std.math.add(u64, start, length);
            if (end > source.reader.reference.length) return error.CorruptStore;
            source.position = start;
            source.end = end;
            source.used = 0;
            source.count = 0;
        }

        pub fn space(source: *@This()) !void {
            while (try source.peek()) |byte| switch (byte) {
                ' ', '\t', '\r', '\n' => _ = try source.take(),
                else => return,
            };
        }

        pub fn expect(source: *@This(), expected: u8) !void {
            try source.space();
            if (try source.take() != expected) return error.CorruptStore;
        }

        pub fn expectEnd(source: *@This()) !void {
            try source.space();
            if (try source.peek() != null) return error.CorruptStore;
        }
    };

    fn toolPresentationLocked(self: *Store, operation: u64, ordinal: u64, publication_position: ?u64) !protocol.ToolPresentation {
        const statement = try prepare(self.database, "SELECT call.description,coalesce(call.rejection_code,a.resolution_code),a.permission_state,item.session_ref,item.session_position FROM model_tool_call call LEFT JOIN action_operation a ON a.parent_operation_id=call.operation_id AND a.call_ordinal=call.call_ordinal LEFT JOIN model_output_item item ON item.operation_id=call.operation_id AND item.item_ordinal=call.item_ordinal WHERE call.operation_id=?1 AND call.call_ordinal=?2");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, operation);
        try bindU64(statement, 2, ordinal);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 3, &session);
        const position = try readNullablePositiveI64(statement, 4) orelse return error.CorruptStore;
        _ = try self.proposalLocked(session.slice(), @intCast(position), false);
        var result: protocol.ToolPresentation = .{ .description = null, .code = .unresolved, .publication_position = publication_position };
        if (c.sqlite3_column_type(statement, 0) != c.SQLITE_NULL) {
            var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
            try readText(statement, 0, &description);
            if (!tool_catalog.validDescription(description.slice())) return error.CorruptStore;
            result.description = description;
        }
        if (c.sqlite3_column_type(statement, 1) != c.SQLITE_NULL) {
            var code: protocol.Bounded(32) = .{};
            try readText(statement, 1, &code);
            result.code = std.meta.stringToEnum(protocol.ToolPresentation.Code, code.slice()) orelse return error.CorruptStore;
        } else if (c.sqlite3_column_int(statement, 2) == 0) result.code = .pending_permission;
        if (result.description == null) switch (result.code) {
            .unknown_tool, .invalid_arguments => {},
            else => return error.CorruptStore,
        };
        return result;
    }

    fn appendToolPresentation(self: *Store, operation: u64, ordinal: u64, publication_position: ?u64, capture: *SessionReportCapture) !void {
        const presentation = try self.toolPresentationLocked(operation, ordinal, publication_position);
        var buffer: [protocol.max_tool_presentation_json_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try presentation.writeJson(&writer);
        try capture.append(",\"presentation\":");
        try capture.append(writer.buffered());
    }

    pub fn activityPage(self: *Store, request: protocol.ActivityPage) !protocol.ActivityFacts {
        try request.validate();
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.page, self.activityPageLocked(request));
    }

    fn activityPageLocked(self: *Store, request: protocol.ActivityPage) !protocol.ActivityFacts {
        const session = (try self.readSession(request.session.slice())) orelse return error.SessionNotFound;
        const end = request.end orelse session.next_position - 1;
        if (end >= session.next_position or request.position > end) return error.InvalidCursor;
        try self.validateActivitySequence(request.session.slice());
        if (request.ordinal) |ordinal| {
            _ = self.activityItemLocked(request.session.slice(), end, request.position, ordinal) catch |err| switch (err) {
                error.ContentNotFound => return error.InvalidCursor,
                else => return err,
            };
        }
        var page: protocol.ActivityFacts = .{ .end = end, .direction = request.direction };
        const statement = try prepare(self.database, activity_sql ++ "SELECT position,ordinal FROM activity WHERE position<=?2 AND " ++
            "(?3=0 OR (?5=0 AND (position>?3 OR (?4 IS NOT NULL AND position=?3 AND ordinal>?4))) OR " ++
            "(?5=1 AND (position<?3 OR (?4 IS NOT NULL AND position=?3 AND ordinal<?4)))) " ++
            "ORDER BY CASE WHEN ?5=0 THEN position END,CASE WHEN ?5=0 THEN ordinal END," ++
            "CASE WHEN ?5=1 THEN position END DESC,CASE WHEN ?5=1 THEN ordinal END DESC LIMIT 17");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, request.session.slice());
        try bindU64(statement, 2, end);
        try bindU64(statement, 3, request.position);
        try bindNullableU64(statement, 4, request.ordinal);
        try bindU64(statement, 5, @backingInt(request.direction));
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.ActivityReadFailed;
            if (page.count == page.items.len) {
                page.more = true;
                break;
            }
            const position = try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore;
            const ordinal = c.sqlite3_column_int64(statement, 1);
            if (ordinal < 0) return error.CorruptStore;
            page.items[page.count] = (try self.activityItemLocked(request.session.slice(), end, @intCast(position), @intCast(ordinal))).item;
            page.count += 1;
        }
        const boundary = if (page.more) &page.items[page.count - 1] else null;
        const lower = if (request.direction == .forward) request.position + 1 else if (boundary) |item| item.position else 0;
        const upper = if (request.direction == .forward) (if (boundary) |item| item.position else end) else if (request.position == 0) end else @min(end, request.position - @intFromBool((request.ordinal orelse 0) == 0));
        try self.validateAssistantEntries(request.session.slice(), lower, upper);
        const last = if (request.direction == .forward) boundary else null;
        page.call_activity = try self.readCallActivityLocked(request.session.slice(), if (last) |item| item.position else end, if (last) |item| item.ordinal else null);
        // Work as of this same read, so the footer, consent and first Action
        // always describe the page they arrive with.
        page.work = (try self.readWorkLocked(request.session.slice(), try self.countPendingMessages(request.session.slice()))).page;
        page.work.revision = session.revision;
        try page.work.workspace.set(session.workspace.slice());
        return page;
    }

    // This projection shares the page's canonical capture, not Current's active
    // Turn lifetime. It is staged until the frontend acknowledges that page.
    fn readCallActivityLocked(self: *Store, session: []const u8, position: u64, ordinal: ?u64) !protocol.CallActivity {
        const statement = try prepare(self.database, public_tool_groups_sql ++
            "candidates AS (SELECT op.operation_id,call.call_ordinal,groups.position FROM model_operation op " ++
            "LEFT JOIN model_tool_call call ON call.operation_id=op.operation_id " ++
            "LEFT JOIN groups ON groups.operation_id=op.operation_id WHERE op.session_ref=?1 AND " ++ resolutionIs("op.resolution_code", .tool_proposals) ++ " " ++
            "AND (groups.position IS NULL OR groups.position>?2 OR (groups.position=?2 AND ?3 IS NOT NULL AND call.call_ordinal+1>?3))) " ++
            "SELECT operation_id,call_ordinal,position FROM candidates ORDER BY operation_id,call_ordinal");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, position);
        try bindNullableU64(statement, 3, ordinal);
        var result: protocol.CallActivity = .{};
        var last_operation: u64 = 0;
        var publication: ?u64 = null;
        while (true) {
            const step = c.sqlite3_step(statement);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.CallReadFailed;
            const operation: u64 = @intCast(try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore);
            const call_ordinal = c.sqlite3_column_int64(statement, 1);
            if (c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL or call_ordinal < 0) return error.CorruptStore;
            if (last_operation != operation) {
                publication = (try self.readToolOutcomeFacts(operation, false, false)).position;
                const projected = try readNullablePositiveI64(statement, 2);
                if (publication != (if (projected) |p| @as(u64, @intCast(p)) else null)) return error.CorruptStore;
                last_operation = operation;
            }
            result.total = try std.math.add(u64, result.total, 1);
            if (result.count == result.entries.len) continue;
            result.entries[result.count] = .{ .operation = operation, .ordinal = @intCast(call_ordinal), .presentation = try self.toolPresentationLocked(operation, @intCast(call_ordinal), publication) };
            result.count += 1;
        }
        return result;
    }

    fn validateActivitySequence(self: *Store, session: []const u8) !void {
        // Nullable columns permit corruption detection; no writer may omit one.
        const guard = try prepare(self.database, "SELECT 1 FROM message_admission WHERE session_ref=?1 AND admission_position IS NULL " ++
            "UNION ALL SELECT 1 FROM session_stop WHERE session_ref=?1 AND position IS NULL " ++
            "UNION ALL SELECT 1 FROM turn WHERE session_ref=?1 AND ((outcome_code IS NULL)!=(outcome_position IS NULL)) LIMIT 1");
        defer _ = c.sqlite3_finalize(guard);
        try bindText(guard, 1, session);
        if (c.sqlite3_step(guard) != c.SQLITE_DONE) return error.CorruptStore;
    }

    fn activityMessageLocked(self: *Store, session: []const u8, end: u64, admission: u64) !struct { message: protocol.ActivityItem.Message, content_id: i64 } {
        const statement = try prepare(self.database, "SELECT m.command_key,m.turn_id,m.content_id," ++
            "EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=m.session_ref AND e.source_admission_id=m.admission_id AND e.session_position<=?2)," ++
            "EXISTS(SELECT 1 FROM session_stop s WHERE s.session_ref=m.session_ref AND s.admission_cutoff>=m.admission_id AND s.position<=?2)," ++
            "c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id " ++
            "AND (m.turn_id IS NULL OR (t.session_ref=m.session_ref AND EXISTS(SELECT 1 FROM conversation_entry e " ++
            "WHERE e.source_admission_id=m.admission_id AND e.session_ref=m.session_ref AND e.turn_id=m.turn_id AND e.content_id=m.content_id))),m.admitted_at,m.sender_session_ref FROM message_admission m " ++
            "LEFT JOIN core_command c ON c.command_key=m.command_key LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
            "WHERE m.session_ref=?1 AND m.admission_id=?3");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, end);
        try bindU64(statement, 3, admission);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_int(statement, 5) != 1) return error.CorruptStore;
        const applied = c.sqlite3_column_int(statement, 3) == 1;
        const content_id = try readNullablePositiveI64(statement, 2) orelse return error.CorruptStore;
        const metadata = try self.readPublicContentMetadata(content_id);
        var message: protocol.ActivityItem.Message = .{ .admission = admission, .key = .{}, .turn = null, .state = if (applied) .applied else if (c.sqlite3_column_int(statement, 4) == 1) .excluded else .queued, .content = .{ .length = metadata.length, .digest = metadata.digest }, .admitted_at = @intCast(try readNullablePositiveI64(statement, 6) orelse return error.CorruptStore) };
        try readText(statement, 0, &message.key);
        if (applied) message.turn = @intCast(try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore);
        message.sender = try self.readPeer(statement, 7);
        return .{ .message = message, .content_id = content_id };
    }

    fn readPeer(self: *Store, statement: *c.sqlite3_stmt, column: c_int) !?protocol.Peer {
        _ = self;
        if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) return null;
        var sender: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, column, &sender);
        return .{ .session = sender };
    }

    const ActivityIdentity = struct { item: protocol.ActivityItem, content_id: ?i64 = null };

    fn activityItemLocked(self: *Store, session: []const u8, end: u64, position: u64, ordinal: u64) !ActivityIdentity {
        if (ordinal == 0 and position <= end) try self.validateAssistantEntries(session, position, position);
        const statement = try prepare(self.database, activity_sql ++ "SELECT kind,id FROM activity WHERE position=?3 AND ordinal=?4 AND position<=?2");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, end);
        try bindU64(statement, 3, position);
        try bindU64(statement, 4, ordinal);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.ContentNotFound;
        if (step != c.SQLITE_ROW) return error.ActivityReadFailed;
        var result: ActivityIdentity = .{ .item = .{ .position = position, .ordinal = ordinal, .value = undefined } };
        switch (c.sqlite3_column_int(statement, 0)) {
            1, 2 => |kind| {
                const admission = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
                const owned = try self.activityMessageLocked(session, end, @intCast(admission));
                const message = owned.message;
                if (kind == 2 and message.state != .applied) return error.CorruptStore;
                result.item.value = if (kind == 1) .{ .admission = message } else .{ .user = message };
                result.content_id = owned.content_id;
                if (kind == 2 and (try self.publicConversationContentLocked(session, position, ordinal)).id != result.content_id.?) return error.CorruptStore;
            },
            3, 5 => |kind| {
                const content = try self.publicConversationContentLocked(session, position, ordinal);
                result.item.value = if (kind == 3) .{ .assistant = .{ .length = content.metadata.length, .digest = content.metadata.digest } } else .{ .tool_result = .{ .content = .{ .length = content.metadata.length, .digest = content.metadata.digest }, .presentation = try self.toolPresentationLocked(content.tool_operation orelse return error.CorruptStore, ordinal - 1, position) } };
                result.content_id = content.id;
            },
            4 => result.item.value = .{ .call = (try self.proposalLocked(session, position, false)).metadata },
            8 => {
                const admission = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
                const select = try prepare(self.database, "SELECT m.session_ref,m.content_id,m.admitted_at,c.kind=2 AND c.accepted=1 AND c.target=m.session_ref AND c.primary_content_id=m.content_id " ++
                    "FROM message_admission m LEFT JOIN core_command c ON c.command_key=m.command_key WHERE m.admission_id=?1 AND m.sender_session_ref=?2 AND m.sender_position=?3");
                defer _ = c.sqlite3_finalize(select);
                try bindI64(select, 1, admission);
                try bindText(select, 2, session);
                try bindU64(select, 3, position);
                if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 3) != 1) return error.CorruptStore;
                var target: protocol.Bounded(protocol.max_session_bytes) = .{};
                try readText(select, 0, &target);
                const content_id = try readNullablePositiveI64(select, 1) orelse return error.CorruptStore;
                const metadata = try self.readPublicContentMetadata(content_id);
                result.item.value = .{ .sent = .{
                    .admission = @intCast(admission),
                    .target = .{ .session = target },
                    .content = .{ .length = metadata.length, .digest = metadata.digest },
                    .admitted_at = @intCast(try readNullablePositiveI64(select, 2) orelse return error.CorruptStore),
                } };
                result.content_id = content_id;
            },
            9 => {
                const select = try prepare(self.database, "SELECT s.command_key,c.target,c.code,c.kind=2 AND c.accepted=0 FROM sent_rejection s " ++
                    "LEFT JOIN core_command c ON c.command_key=s.command_key WHERE s.sender_session_ref=?1 AND s.sender_position=?2");
                defer _ = c.sqlite3_finalize(select);
                try bindText(select, 1, session);
                try bindU64(select, 2, position);
                if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 3) != 1) return error.CorruptStore;
                var failed: protocol.ActivityItem.SendFailed = .{ .key = .{}, .target = undefined, .code = .{} };
                try readText(select, 0, &failed.key);
                var target: protocol.Bounded(protocol.max_session_bytes) = .{};
                try readText(select, 1, &target);
                failed.target = .{ .session = target };
                try readText(select, 2, &failed.code);
                result.item.value = .{ .send_failed = failed };
            },
            6 => {
                const select = try prepare(self.database, "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.session_ref=t.session_ref AND o.turn_id=t.turn_id " ++
                    "AND o.resolution_code IS NOT NULL AND ((t.outcome_code='completed' AND t.outcome_content_id=o.resolution_content_id) OR " ++
                    "(t.outcome_code!='completed' AND t.outcome_content_id IS NULL)) FROM turn t LEFT JOIN model_operation o ON o.operation_id=t.operation_id WHERE t.session_ref=?1 AND t.outcome_position=?2");
                defer _ = c.sqlite3_finalize(select);
                try bindText(select, 1, session);
                try bindU64(select, 2, position);
                if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 4) != 1) return error.CorruptStore;
                var outcome: protocol.ActivityItem.Outcome = .{ .turn = @intCast(try readNullablePositiveI64(select, 0) orelse return error.CorruptStore), .operation = @intCast(try readNullablePositiveI64(select, 1) orelse return error.CorruptStore), .code = .{}, .content = null };
                try readText(select, 2, &outcome.code);
                result.content_id = try readNullablePositiveI64(select, 3);
                if (result.content_id) |id| {
                    const content = try self.readPublicContentMetadata(id);
                    outcome.content = .{ .length = content.length, .digest = content.digest };
                }
                result.item.value = .{ .outcome = outcome };
            },
            7 => {
                const select = try prepare(self.database, "SELECT s.command_key,s.selected_turn_id,s.admission_cutoff,t.outcome_position," ++
                    "c.kind=3 AND c.accepted=1 AND c.target=s.session_ref AND (s.selected_turn_id IS NULL OR t.session_ref=s.session_ref) " ++
                    "FROM session_stop s LEFT JOIN core_command c ON c.command_key=s.command_key LEFT JOIN turn t ON t.turn_id=s.selected_turn_id WHERE s.session_ref=?1 AND s.position=?2");
                defer _ = c.sqlite3_finalize(select);
                try bindText(select, 1, session);
                try bindU64(select, 2, position);
                if (c.sqlite3_step(select) != c.SQLITE_ROW or c.sqlite3_column_int(select, 4) != 1 or c.sqlite3_column_int64(select, 2) < 0) return error.CorruptStore;
                const turn = try readNullablePositiveI64(select, 1);
                const outcome_position = try readNullablePositiveI64(select, 3);
                var stop: protocol.ActivityItem.Stop = .{ .key = .{}, .turn = if (turn) |id| @intCast(id) else null, .cutoff = @intCast(c.sqlite3_column_int64(select, 2)), .completion = if (turn == null or (outcome_position != null and outcome_position.? <= end)) .completed else .pending };
                try readText(select, 0, &stop.key);
                result.item.value = .{ .stop = stop };
            },
            else => return error.CorruptStore,
        }
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptStore;
        return result;
    }

    pub fn openActivityContent(self: *Store, request: protocol.ReadActivityContent) !ContentReader {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.content, self.openActivityContentLocked(request));
    }

    fn openActivityContentLocked(self: *Store, request: protocol.ReadActivityContent) !ContentReader {
        self.validateActivitySequence(request.session.slice()) catch |err| return self.fence(err);
        // Only Tool Results have nonzero ordinals. Byte readers need their
        // canonical identity, not a second scan of the original arguments.
        const id = if (request.ordinal != 0) id: {
            const content = self.publicConversationContentLocked(request.session.slice(), request.position, request.ordinal) catch |err| switch (err) {
                error.ContentNotFound => return err,
                else => return self.fence(err),
            };
            break :id content.id;
        } else id: {
            const identity = self.activityItemLocked(request.session.slice(), std.math.maxInt(i64), request.position, request.ordinal) catch |err| switch (err) {
                error.ContentNotFound => return err,
                else => return self.fence(err),
            };
            break :id identity.content_id orelse return error.ContentNotFound;
        };
        const content = self.readPublicContentMetadata(id) catch |err| return self.fence(err);
        const raw = self.contentIsRaw(id, content.length) catch |err| return self.fence(err);
        return .{ .store = self, .content_id = id, .reference = .{ .length = content.length, .digest = content.digest }, .representation = if (raw) .raw else .{ .projection = .{} } };
    }

    pub fn proposalPage(self: *Store, request: protocol.ProposalPage) !ProposalPage {
        try request.validate();
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.page, self.proposalPageLocked(request));
    }

    fn proposalPageLocked(self: *Store, request: protocol.ProposalPage) !ProposalPage {
        const session = (try self.readSession(request.session.slice())) orelse return error.SessionNotFound;
        const end = request.end orelse session.next_position - 1;
        if (end >= session.next_position) return error.InvalidCursor;
        if (request.after != 0) {
            _ = self.proposalLocked(request.session.slice(), request.after, true) catch |err| switch (err) {
                error.ContentNotFound => return error.InvalidCursor,
                else => return err,
            };
        }
        var page: ProposalPage = .{ .end = end };
        // The immutable accepted item owns discovery, including rejected calls.
        // Do not filter on live Actions, permissions or Turn state.
        const statement = try prepare(self.database, "SELECT session_position FROM model_output_item " ++
            "WHERE session_ref=?1 AND session_position>?2 AND session_position<=?3 AND item_kind=3 " ++
            "ORDER BY session_position LIMIT 17");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, request.session.slice());
        try bindU64(statement, 2, request.after);
        try bindU64(statement, 3, end);
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.ProposalReadFailed;
            if (page.count == page.items.len) {
                page.more = true;
                break;
            }
            const position = try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore;
            page.items[page.count] = (try self.proposalLocked(request.session.slice(), @intCast(position), true)).metadata;
            page.count += 1;
        }
        return page;
    }

    const ProposalIdentity = struct { metadata: protocol.ProposalMetadata, content_ids: [4]i64 };

    // The page, continuation cursor and byte route share one provenance check.
    // LEFT JOIN keeps missing/contradictory owners visible as corruption.
    fn proposalLocked(self: *Store, session: []const u8, position: u64, authenticate: bool) !ProposalIdentity {
        const statement = try prepare(self.database, "SELECT item.operation_id,op.turn_id,call.call_ordinal,action.action_id,call.rejection_code," ++
            "call.item_id_content_id,call.name_content_id,call.call_id_content_id,call.arguments_content_id," ++
            "CASE WHEN op.session_ref=item.session_ref AND t.session_ref=item.session_ref AND " ++
            resolutionIs("op.resolution_code", .tool_proposals) ++ " AND op.attempt_ordinal=item.attempt_ordinal AND " ++
            "source.content_id IS NOT NULL AND source.private=1 AND item_id.digest=item.item_id_digest AND " ++
            "((call.rejection_code IS NOT NULL AND action.action_id IS NULL AND call.acceptance_position IS NOT NULL AND " ++
            "rejection.content_id IS NOT NULL AND rejection.private=0) OR " ++
            "(call.rejection_code IS NULL AND action.action_id IS NOT NULL AND action.session_ref=item.session_ref)) " ++
            "THEN 1 ELSE 0 END,source.content_id,call.field_metadata FROM model_output_item item " ++
            "LEFT JOIN model_operation op ON op.operation_id=item.operation_id LEFT JOIN turn t ON t.turn_id=op.turn_id " ++
            "LEFT JOIN content source ON source.content_id=item.content_id " ++
            "LEFT JOIN model_tool_call call ON call.operation_id=item.operation_id AND call.item_ordinal=item.item_ordinal " ++
            "LEFT JOIN content item_id ON item_id.content_id=call.item_id_content_id " ++
            "LEFT JOIN content rejection ON rejection.content_id=call.rejection_content_id " ++
            "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
            "WHERE item.session_ref=?1 AND item.session_position=?2 AND item.item_kind=3");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        try bindU64(statement, 2, position);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return error.ContentNotFound,
            else => return error.ProposalReadFailed,
        }
        if (c.sqlite3_column_int(statement, 9) != 1) return error.CorruptStore;
        const ordinal = c.sqlite3_column_int64(statement, 2);
        if (ordinal < 0 or c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return error.CorruptStore;
        var result: ProposalIdentity = .{ .metadata = .{
            .position = position,
            .operation = @intCast(try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
            .turn = @intCast(try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore),
            .call_ordinal = @intCast(ordinal),
            .action = if (try readNullablePositiveI64(statement, 3)) |action| @intCast(action) else null,
            .rejection = null,
            .fields = undefined,
        }, .content_ids = undefined };
        if (c.sqlite3_column_type(statement, 4) != c.SQLITE_NULL) {
            var code: protocol.Bounded(32) = .{};
            try readText(statement, 4, &code);
            result.metadata.rejection = std.meta.stringToEnum(protocol.ProposalRejection, code.slice()) orelse return error.CorruptStore;
        }
        // Four admission-certified (little-endian length, SHA-256) pairs.
        // Reference substitution is detectable without reopening payloads.
        if (c.sqlite3_column_bytes(statement, 11) != 160) return error.CorruptStore;
        const certified: [*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, 11) orelse return error.CorruptStore);
        for (&result.content_ids, &result.metadata.fields, 0..) |*id, *field, index| {
            id.* = try readNullablePositiveI64(statement, @intCast(5 + index)) orelse return error.CorruptStore;
            const metadata = try self.readPublicContentMetadata(id.*);
            if (metadata.length != std.mem.readInt(u64, certified[index * 40 ..][0..8], .little) or
                !std.mem.eql(u8, &metadata.digest, certified[index * 40 + 8 ..][0..32])) return error.CorruptStore;
            field.* = .{ .length = metadata.length, .digest = metadata.digest };
        }
        if (authenticate) {
            var source = try ContentSource.init(self, try readNullablePositiveI64(statement, 10) orelse return error.CorruptStore, true);
            defer source.reader.close();
            @import("provider_output.zig").authenticateCall(&source, result.metadata.fields) catch return error.CorruptStore;
        }
        return result;
    }

    pub fn openProposalField(self: *Store, request: protocol.ReadProposalField) !ContentReader {
        if (request.position == 0 or request.position > std.math.maxInt(i64)) return error.ContentNotFound;
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.content, self.openProposalFieldLocked(request));
    }

    fn openProposalFieldLocked(self: *Store, request: protocol.ReadProposalField) !ContentReader {
        const identity = self.proposalLocked(request.session.slice(), request.position, true) catch |err| switch (err) {
            error.ContentNotFound => return err,
            else => return self.fence(err),
        };
        const index = @backingInt(request.field);
        const field = identity.metadata.fields[index];
        const raw = self.contentIsRaw(identity.content_ids[index], field.length) catch |err| return self.fence(err);
        return .{ .store = self, .content_id = identity.content_ids[index], .reference = .{ .length = field.length, .digest = field.digest }, .representation = if (raw) .raw else .{ .projection = .{} } };
    }

    /// Authenticates the Session/Operation/Attempt before reading optional
    /// diagnostics. Diagnostic faults never fence canonical state.
    pub fn captureFailedResponse(self: *Store, request: protocol.InspectSession, store_dir: std.Io.Dir, options: SessionListOptions) !SessionReport {
        const selection = request.failed_response.?;
        const binding = binding: {
            const access = try self.enter(.none);
            defer access.release();
            break :binding try access.finish(Ordinary.content, self.failedResponseBindingLocked(request.session.slice(), selection));
        };
        var capture = try SessionReportCapture.init(self.io, options.scratch_path, options.scratch_budget, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        try @import("failed_responses.zig").exportRecord(self.io, store_dir, binding, selection.part, &capture);
        return capture.seal();
    }

    fn failedResponseBindingLocked(self: *Store, session: []const u8, selection: protocol.FailedResponseExport) !AttemptBinding {
        const statement = try prepare(self.database, "SELECT turn_id FROM model_operation WHERE operation_id=?1 AND session_ref=?2 AND attempt_ordinal>=?3");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, selection.operation);
        try bindText(statement, 2, session);
        try bindU64(statement, 3, selection.attempt);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return error.ContentNotFound,
            c.SQLITE_ROW => {},
            else => return error.OperationReadFailed,
        }
        return .{
            .turn_id = @intCast(try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
            .operation_id = selection.operation,
            .attempt_ordinal = selection.attempt,
        };
    }

    pub fn captureSessionReport(
        self: *Store,
        session_ref: []const u8,
        options: SessionReportOptions,
    ) !SessionReport {
        var capture = try SessionReportCapture.init(self.io, options.scratch_path, options.scratch_budget, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        {
            const access = try self.enter(.none);
            defer access.release();
            try access.finishCapture(&capture, self.renderSessionReportLocked(session_ref, options.profile, options.execution, &capture));
        }
        return capture.seal();
    }

    /// Returns an owned, unlinked page; no SQLite cursor or mutex survives capture.
    /// The caller releases its scratch charge by deinitializing the report.
    pub fn captureSessionList(self: *Store, request: protocol.ListSessions, options: SessionListOptions) !SessionReport {
        if (request.after > std.math.maxInt(i64) or request.ceiling > std.math.maxInt(i64) or
            (request.after == 0 and request.ceiling != 0) or
            (request.after != 0 and request.after > request.ceiling)) return error.InvalidCursor;
        var capture = try SessionReportCapture.init(self.io, options.scratch_path, options.scratch_budget, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        {
            const access = try self.enter(.none);
            defer access.release();
            try access.finishCapture(&capture, self.renderSessionListLocked(request, &capture));
        }
        return capture.seal();
    }

    fn renderSessionListLocked(self: *Store, request: protocol.ListSessions, capture: *SessionReportCapture) !void {
        var ceiling = request.ceiling;
        if (request.after == 0) {
            const maximum = try prepare(self.database, "SELECT coalesce(max(rowid),0) FROM session");
            defer _ = c.sqlite3_finalize(maximum);
            if (c.sqlite3_step(maximum) != c.SQLITE_ROW) return error.SessionReadFailed;
            const value = c.sqlite3_column_int64(maximum, 0);
            if (value < 0) return error.CorruptStore;
            ceiling = @intCast(value);
        }
        const statement = try prepare(self.database, if (request.workspace == null)
            "SELECT rowid,session_ref,workspace,provider,model,tools_mask,permission_mode FROM session WHERE rowid>?1 AND rowid<=?2 ORDER BY rowid LIMIT 9"
        else
            "SELECT rowid,session_ref,workspace,provider,model,tools_mask,permission_mode FROM session INDEXED BY session_workspace_list WHERE rowid>?1 AND rowid<=?2 AND workspace=?3 ORDER BY rowid LIMIT 9");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, request.after);
        try bindU64(statement, 2, ceiling);
        if (request.workspace) |*workspace| try bindText(statement, 3, workspace.slice());
        try capture.append("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
        var count: usize = 0;
        var last: u64 = 0;
        var more = false;
        while (true) {
            const step = c.sqlite3_step(statement);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.SessionReadFailed;
            if (count == protocol.session_list_page_size) {
                more = true;
                break;
            }
            const id = c.sqlite3_column_int64(statement, 0);
            if (id <= 0) return error.CorruptStore;
            last = @intCast(id);
            var reference: protocol.Bounded(protocol.max_session_bytes) = .{};
            var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
            var model: protocol.Bounded(protocol.max_model_bytes) = .{};
            try readText(statement, 1, &reference);
            try readText(statement, 2, &workspace);
            const provider = try readProvider(statement, 3);
            try readText(statement, 4, &model);
            const tools = c.sqlite3_column_int(statement, 5);
            const permission = c.sqlite3_column_int(statement, 6);
            if (tools < 0 or tools > tool_catalog.toolBit(.bash) or permission < 0 or permission > 1) return error.CorruptStore;
            if (count != 0) try capture.append(",");
            try capture.append("{\"reference\":");
            try capture.appendJsonString(reference.slice());
            try capture.append(",\"workspace\":");
            try capture.appendJsonString(workspace.slice());
            try capture.append(",\"provider\":");
            try capture.appendJsonString(@tagName(provider));
            try capture.append(",\"model\":");
            try capture.appendJsonString(model.slice());
            try capture.append(",\"tools\":");
            try capture.appendTools(@intCast(tools));
            try capture.append(",\"permission_mode\":");
            try capture.appendPermissionMode(@intCast(permission));
            try capture.append("}");
            count += 1;
        }
        if (more) {
            try capture.appendFmt("],\"next\":{{\"after\":\"{d}\",\"ceiling\":\"{d}\"}}}}", .{ last, ceiling });
        } else {
            try capture.append("],\"next\":null}");
        }
    }

    fn renderSessionReportLocked(
        self: *Store,
        session_ref: []const u8,
        profile: protocol.ReportProfile,
        execution: SessionReportExecution,
        capture: *SessionReportCapture,
    ) !void {
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
        try self.validateActiveTurnToolCalls(session_ref, profile == .full);
        const action_count = try self.countActions(session_ref);
        const rejected_call_count = try self.countRejectedCalls(session_ref);

        try capture.append("{\"reference\":");
        try capture.appendJsonString(session_ref);
        try capture.append(",\"workspace\":");
        try capture.appendJsonString(current.workspace.slice());
        try capture.append(",\"provider\":");
        try capture.appendJsonString(@tagName(current.provider));
        try capture.append(",\"model\":");
        try capture.appendJsonString(current.model.slice());
        const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
        try capture.append(",\"compaction_trigger\":");
        if (policy.compaction_trigger) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
        try capture.appendFmt(",\"output_reservation\":\"{d}\",\"compaction_trigger_override\":", .{policy.output_reservation});
        if (current.compaction_trigger) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
        try capture.append(",\"output_reservation_override\":");
        if (current.output_reservation) |value| try capture.appendFmt("\"{d}\"", .{value}) else try capture.append("null");
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
        try capture.append(",\"selected_message\":");
        try self.appendSelectedMessage(session_ref, capture);
        try capture.append(",\"recent_messages\":[");
        try self.appendRecentMessages(session_ref, capture);
        try capture.append("]");
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
        const work = try self.readWorkLocked(session_ref, pending_messages);
        try capture.appendFmt("{{\"status\":\"{s}\"", .{@tagName(work.page.status)});
        if (work.page.turn) |turn_id| try capture.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\"", .{ turn_id, work.page.operation.? });
        const outcome = work.outcome orelse return capture.append(",\"latest_outcome\":null}");
        try capture.append(",\"latest_outcome\":{\"code\":");
        try capture.appendJsonString(outcome.code.slice());
        try capture.append(",\"content\":");
        if (outcome.content_id) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            try capture.appendBareContentReference(.{ .length = metadata.length, .digest = metadata.digest });
        } else {
            try capture.append("null");
        }
        try capture.append("}}");
    }

    /// The Session's latest Turn as work: Current reports it, and each
    /// activity page carries it from the same read as its items.
    fn readWorkLocked(self: *Store, session_ref: []const u8, pending_messages: u64) !struct {
        page: protocol.PageWork,
        outcome: ?struct { code: protocol.Bounded(96), content_id: ?i64 } = null,
    } {
        const statement = try prepare(
            self.database,
            "SELECT t.turn_id,t.operation_id,t.outcome_code,t.outcome_content_id,o.resolution_code " ++
                "FROM turn t JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE t.session_ref=?1 ORDER BY t.turn_id DESC LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return .{ .page = .{ .status = if (pending_messages == 0) .idle else .runnable } };
        if (result != c.SQLITE_ROW) return error.TurnReadFailed;
        const turn_id = c.sqlite3_column_int64(statement, 0);
        const operation_id = c.sqlite3_column_int64(statement, 1);
        if (turn_id <= 0 or operation_id <= 0) return error.CorruptStore;
        var page: protocol.PageWork = .{ .turn = @intCast(turn_id), .operation = @intCast(operation_id) };
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) {
            const resolution = if (c.sqlite3_column_type(statement, 4) == c.SQLITE_NULL) null else blk: {
                var code: protocol.Bounded(96) = .{};
                try readText(statement, 4, &code);
                break :blk code;
            };
            const progress = try self.activeMessageProgress(session_ref, resolution);
            page.status = switch (progress.status) {
                inline else => |status| @field(protocol.PageWork.Status, @tagName(status)),
            };
            page.first_action = progress.action_id;
            return .{ .page = page };
        }
        var code: protocol.Bounded(96) = .{};
        try readText(statement, 2, &code);
        page.status = if (pending_messages != 0)
            .runnable
        else if (code.eql("completed"))
            .completed
        else if (code.eql("cancelled"))
            .cancelled
        else
            .failed;
        return .{ .page = page, .outcome = .{ .code = code, .content_id = try readNullablePositiveI64(statement, 3) } };
    }

    fn appendSelectedMessage(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        // An active Turn owns the selection even if a successor is queued.
        const active = try prepare(self.database, "SELECT m.command_key FROM turn t INDEXED BY turn_one_active_per_session " ++
            "JOIN message_admission m ON m.admission_id=t.first_admission_id " ++
            "WHERE t.session_ref=?1 AND t.outcome_code IS NULL");
        defer _ = c.sqlite3_finalize(active);
        try bindText(active, 1, session_ref);
        const active_step = c.sqlite3_step(active);
        if (active_step == c.SQLITE_ROW) {
            var key: protocol.Bounded(protocol.max_key_bytes) = .{};
            try readText(active, 0, &key);
            return capture.appendJsonString(key.slice());
        }
        if (active_step != c.SQLITE_DONE) return error.TurnReadFailed;

        const queued = try prepare(self.database, "SELECT command_key FROM message_admission INDEXED BY message_admission_session_pending " ++
            "WHERE session_ref=?1 AND turn_id IS NULL AND admission_id>?2 ORDER BY admission_id LIMIT 1");
        defer _ = c.sqlite3_finalize(queued);
        try bindText(queued, 1, session_ref);
        try bindU64(queued, 2, try self.latestSessionStopCutoff(session_ref));
        const queued_step = c.sqlite3_step(queued);
        if (queued_step == c.SQLITE_ROW) {
            var key: protocol.Bounded(protocol.max_key_bytes) = .{};
            try readText(queued, 0, &key);
            return capture.appendJsonString(key.slice());
        }
        if (queued_step != c.SQLITE_DONE) return error.MessageAdmissionReadFailed;
        try capture.append("null");
    }

    fn appendRecentMessages(self: *Store, session_ref: []const u8, capture: *SessionReportCapture) !void {
        // Traverse terminal Turns newest-first, then their admissions newest-first.
        // CROSS JOIN fixes that indexed order so LIMIT stops after ten Messages,
        // even when older history or unrelated Sessions grow.
        const statement = try prepare(self.database, "SELECT t.turn_id,m.command_key,t.outcome_code FROM turn t INDEXED BY turn_session_latest " ++
            "CROSS JOIN message_admission m INDEXED BY message_admission_session_order " ++
            "WHERE t.session_ref=?1 AND t.outcome_code IS NOT NULL " ++
            "AND m.session_ref=t.session_ref AND m.turn_id=t.turn_id " ++
            "ORDER BY t.turn_id DESC,m.admission_id DESC LIMIT 10");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        var first = true;
        while (try nextReportRow(statement, &first, capture, error.TurnReadFailed)) {
            const id = c.sqlite3_column_int64(statement, 0);
            if (id <= 0) return error.CorruptStore;
            var key: protocol.Bounded(protocol.max_key_bytes) = .{};
            var code: protocol.Bounded(96) = .{};
            try readText(statement, 1, &key);
            try readText(statement, 2, &code);
            try capture.appendFmt("{{\"turn\":\"{d}\",\"message\":", .{id});
            try capture.appendJsonString(key.slice());
            try capture.append(",\"outcome\":");
            try capture.appendJsonString(code.slice());
            try capture.append("}");
        }
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
            try self.appendToolPresentation(@intCast(parent), @intCast(ordinal), null, capture);
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
        var last_parent: i64 = 0;
        var publication: ?u64 = null;
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
            if (parent != last_parent) {
                publication = (try self.readToolOutcomeFacts(@intCast(parent), false, false)).position;
                last_parent = parent;
            }
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
            try self.appendToolPresentation(@intCast(parent), @intCast(ordinal), publication, capture);
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
        var last_parent: i64 = 0;
        var publication: ?u64 = null;
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return;
            if (result != c.SQLITE_ROW) return error.CallReadFailed;
            const operation_id = c.sqlite3_column_int64(statement, 0);
            const call_ordinal = c.sqlite3_column_int64(statement, 1);
            const acceptance_position = c.sqlite3_column_int64(statement, 3);
            const rejection_length = c.sqlite3_column_int64(statement, 4);
            if (operation_id <= 0 or call_ordinal < 0 or acceptance_position <= 0 or rejection_length < 0) return error.CorruptStore;
            if (operation_id != last_parent) {
                publication = (try self.readToolOutcomeFacts(@intCast(operation_id), false, false)).position;
                last_parent = operation_id;
            }
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
            try self.appendToolPresentation(@intCast(operation_id), @intCast(call_ordinal), publication, capture);
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
                "instructions.owner_revision,instructions.owner_field,output_schema.owner_revision,output_schema.owner_field,revision_row.provider,revision_row.compaction_trigger,revision_row.output_reservation " ++
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
            if (revision <= 0 or tools < 0 or tools > tool_catalog.toolBit(.bash) or permission < 0 or permission > 1 or instructions_id <= 0) return error.CorruptStore;
            try capture.appendFmt("{{\"revision\":\"{d}\",\"command_key\":", .{revision});
            try appendColumnString(statement, 1, 128, capture);
            try capture.append(",\"workspace\":");
            try appendColumnString(statement, 2, protocol.max_workspace_bytes, capture);
            try capture.append(",\"provider\":");
            try capture.appendJsonString(@tagName(try readProvider(statement, 12)));
            try capture.append(",\"model\":");
            try appendColumnString(statement, 3, protocol.max_model_bytes, capture);
            try capture.append(",\"compaction_trigger\":");
            try appendNullablePositiveInteger(statement, 13, capture);
            try capture.append(",\"output_reservation\":");
            try appendNullableNonnegativeInteger(statement, 14, capture);
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
        if (owner_revision == revision and @backingInt(owner_field) > @backingInt(field)) return error.CorruptStore;
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
        try self.validateAssistantEntries(session_ref, 0, std.math.maxInt(i64));
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
            if (kind != 2 and (try self.publicConversationContentLocked(session_ref, @intCast(position), 0)).id != content_id) return error.CorruptStore;
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
        const statement = try prepare(self.database, "SELECT operation_id,turn_id,resolution_code,resolution_content_id,interrupted_by_command_key,settings_revision,request_id FROM model_operation WHERE session_ref=?1 ORDER BY operation_id");
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
            const revision = c.sqlite3_column_int64(statement, 5);
            if (revision <= 0) return error.CorruptStore;
            try capture.appendFmt(",\"settings_revision\":\"{d}\"", .{revision});
            try capture.append(",\"request_id\":");
            try appendNullableColumnString(statement, 6, 256, capture);
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
        const raw = try self.contentIsRaw(content_id, metadata.length);
        var reader = ContentReader{ .content_id = content_id, .representation = if (raw) .raw else .{ .projection = .{} }, .store = self, .reference = .{ .length = metadata.length, .digest = metadata.digest } };
        defer reader.close();
        try capture.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{metadata.length});
        try capture.append(&std.fmt.bytesToHex(metadata.digest, .lower));
        try capture.append("\",\"text\":\"");
        var buffer: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (offset < metadata.length) {
            const wanted: usize = @intCast(@min(metadata.length - offset, buffer.len));
            try self.readOwnedContentLocked(&reader, offset, buffer[0..wanted]);
            try capture.appendJsonStringBytes(buffer[0..wanted]);
            offset += wanted;
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

    fn validateActiveTurnToolCalls(self: *Store, session_ref: []const u8, authenticate: bool) !void {
        const statement = try prepare(
            self.database,
            "SELECT operation.operation_id FROM turn active INDEXED BY turn_one_active_per_session " ++
                "CROSS JOIN model_operation operation INDEXED BY model_operation_turn_history " ++
                "ON operation.turn_id=active.turn_id " ++
                "WHERE active.session_ref=?1 " ++
                "AND active.outcome_code IS NULL AND " ++ resolutionIs("operation.resolution_code", .tool_proposals) ++ " " ++
                "ORDER BY operation.operation_id",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const operation_id = c.sqlite3_column_int64(statement, 0);
                if (operation_id <= 0) return error.CorruptStore;
                _ = try self.readToolOutcomeFacts(@intCast(operation_id), false, authenticate);
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
        authenticate: bool,
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
        const sources = try prepare(self.database, "SELECT item.session_ref,item.session_position FROM model_tool_call call " ++
            "LEFT JOIN model_output_item item ON item.operation_id=call.operation_id AND item.item_ordinal=call.item_ordinal " ++
            "WHERE call.operation_id=?1 ORDER BY call.call_ordinal");
        defer _ = c.sqlite3_finalize(sources);
        try bindU64(sources, 1, operation_id);
        while (true) {
            const step = c.sqlite3_step(sources);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return error.CallReadFailed;
            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try readText(sources, 0, &session);
            const source_position = try readNullablePositiveI64(sources, 1) orelse return error.CorruptStore;
            _ = try self.proposalLocked(session.slice(), @intCast(source_position), authenticate);
        }
        return .{
            .position = if (terminal == expected) (if (position) |value| @intCast(value) else null) else null,
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
        const access = try self.enter(.none);
        defer access.release();
        if (action_id == 0 or action_id > std.math.maxInt(i64)) return error.ActionNotFound;
        return access.finish(Ordinary.action, self.actionContentLocked(session_ref, action_id, column));
    }

    fn actionContentLocked(self: *Store, session_ref: []const u8, action_id: u64, comptime column: []const u8) !ContentReference {
        const statement = try prepare(
            self.database,
            "SELECT call." ++ column ++ ",item.session_position FROM action_operation action JOIN model_tool_call call " ++
                "ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal " ++
                "LEFT JOIN model_output_item item ON item.operation_id=call.operation_id AND item.item_ordinal=call.item_ordinal " ++
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
        const position = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        _ = try self.proposalLocked(session_ref, @intCast(position), true);
        const metadata = try self.readPublicContentMetadata(content_id);
        return .{ .length = metadata.length, .digest = metadata.digest };
    }

    pub fn admitNextModelAttempt(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!@import("builtin").is_test) @compileError("Production admission must select an explicit work kind");
        return try self.admitModelAttempt(.message, faults) orelse
            self.admitModelAttempt(.tool_continuation, faults);
    }

    pub fn admitModelAttempt(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.admitNextModelAttemptLocked(kind, faults));
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.admitNextActionAttemptLocked(bash_timeout_ms, faults));
    }

    fn admitNextActionAttemptLocked(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        const select = try self.hot(.executable_action);
        defer resetHot(select);
        const step = c.sqlite3_step(select);
        if (step == c.SQLITE_DONE) return null;
        if (step != c.SQLITE_ROW) return error.ActionSelectionFailed;
        const action_id = c.sqlite3_column_int64(select, 0);
        const parent_operation_id = c.sqlite3_column_int64(select, 1);
        const turn_id = c.sqlite3_column_int64(select, 2);
        if (action_id <= 0 or parent_operation_id <= 0 or turn_id <= 0) return error.CorruptStore;
        const selected_timeout_ms = if (try readNullablePositiveI64(select, 3)) |override|
            @as(u64, @intCast(override))
        else
            bash_timeout_ms;
        // The held Store mutex excludes every other writer, so the candidate
        // read outside the transaction is still current inside it.
        _ = c.sqlite3_reset(select);
        try exec(self.database, "BEGIN IMMEDIATE");
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        const sender_handle = std.fmt.bytesToHex(random, .lower);
        const update = try prepare(
            self.database,
            "UPDATE action_operation SET attempt_ordinal=1,bash_timeout_ms=?2,sender_handle=?3 " ++
                "WHERE action_id=?1 AND permission_state=1 AND resolution_code IS NULL AND attempt_ordinal=0",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindI64(update, 1, action_id);
        try bindU64(update, 2, selected_timeout_ms);
        try bindText(update, 3, &sender_handle);
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.action_attempt, self.readBashExecutionInputLocked(binding));
    }

    fn readBashExecutionInputLocked(self: *Store, binding: ActionAttemptBinding) !BashExecutionInput {
        const statement = try prepare(
            self.database,
            "SELECT revision.workspace,call.arguments_content_id,action.bash_timeout_ms,operation.turn_id,action.session_ref,action.sender_handle " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "JOIN session_revision revision ON revision.session_ref=action.session_ref AND revision.revision=action.permission_revision " ++
                "JOIN model_tool_call call ON call.operation_id=action.parent_operation_id AND call.call_ordinal=action.call_ordinal " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3 " ++
                "AND action.resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.action_id);
        try bindU64(statement, 2, binding.parent_operation_id);
        try bindU64(statement, 3, binding.attempt_ordinal);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
        if (step != c.SQLITE_ROW) return error.ActionReadFailed;
        if (c.sqlite3_column_int64(statement, 3) != binding.turn_id) return error.StaleActionAttemptBinding;
        var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        try readText(statement, 0, &workspace);
        const content_id = c.sqlite3_column_int64(statement, 1);
        const timeout_ms = c.sqlite3_column_int64(statement, 2);
        if (content_id <= 0 or timeout_ms <= 0) return error.CorruptStore;
        var session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 4, &session);
        var sender_handle: protocol.Bounded(32) = .{};
        try readText(statement, 5, &sender_handle);
        const arguments = try self.actionContentLocked(session.slice(), binding.action_id, "arguments_content_id");
        return .{
            .session = session,
            .sender_handle = sender_handle,
            .workspace = workspace,
            .arguments = arguments,
            .timeout_ms = @intCast(timeout_ms),
        };
    }

    pub fn revokeActionSender(self: *Store, binding: ActionAttemptBinding) !void {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.revokeActionSenderLocked(binding));
    }

    fn revokeActionSenderLocked(self: *Store, binding: ActionAttemptBinding) !void {
        const statement = try prepare(self.database, "UPDATE action_operation SET sender_handle=NULL WHERE action_id=?1 AND parent_operation_id=?2 AND attempt_ordinal=?3");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.action_id);
        try bindU64(statement, 2, binding.parent_operation_id);
        try bindU64(statement, 3, binding.attempt_ordinal);
        try expectDone(statement);
    }

    pub fn actionSupersededByStop(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.actionSupersededByStopLocked(binding));
    }

    fn actionSupersededByStopLocked(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
        const statement = try prepare(
            self.database,
            "SELECT (SELECT stop.command_key FROM session_stop stop JOIN core_command command ON command.command_key=stop.command_key " ++
                "WHERE stop.selected_turn_id=operation.turn_id ORDER BY command.rowid LIMIT 1) " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.action_id);
        try bindU64(statement, 2, binding.parent_operation_id);
        try bindU64(statement, 3, binding.attempt_ordinal);
        const step = c.sqlite3_step(statement);
        if (step != c.SQLITE_ROW) return if (step == c.SQLITE_DONE) error.CorruptStore else error.ActionReadFailed;
        if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return null;
        var command_key: protocol.Bounded(protocol.max_key_bytes) = .{};
        try readText(statement, 0, &command_key);
        return .{ .command_key = command_key };
    }

    pub fn withActionDispatchHandoff(
        self: *Store,
        binding: ActionAttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        const access = try self.enter(.none);
        defer access.release();
        try access.finish(Ordinary.action_dispatch, self.validateActionDispatchLocked(binding));
        // Launch failures are effect outcomes, not canonical faults; the
        // caller settles or fences them. The handoff still runs under the lock.
        try handoff(context);
    }

    fn validateActionDispatchLocked(self: *Store, binding: ActionAttemptBinding) !void {
        const statement = try prepare(
            self.database,
            "SELECT operation.turn_id,EXISTS(SELECT 1 FROM session_stop stop WHERE stop.selected_turn_id=operation.turn_id) " ++
                "FROM action_operation action JOIN model_operation operation ON operation.operation_id=action.parent_operation_id " ++
                "WHERE action.action_id=?1 AND action.parent_operation_id=?2 AND action.attempt_ordinal=?3 " ++
                "AND action.resolution_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.action_id);
        try bindU64(statement, 2, binding.parent_operation_id);
        try bindU64(statement, 3, binding.attempt_ordinal);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleActionAttemptBinding;
        if (step != c.SQLITE_ROW) return error.ActionReadFailed;
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id) return error.StaleActionAttemptBinding;
        if (c.sqlite3_column_int(statement, 1) != 0) return error.SupersededByControl;
    }

    pub fn settleActionAttempt(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        if (result.len == 0) return error.InvalidActionResult;
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.action_attempt, faults, self.settleActionAttemptLocked(binding, code, result, faults));
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
            "UPDATE action_operation SET resolution_code=?2,resolution_content_id=?3,acceptance_position=?4,sender_handle=NULL " ++
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.none, .{}, self.recoverOneUncertainActionLocked(active));
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
        if (c.sqlite3_changes(self.database) == 1) try self.recordTurnOutcomePosition(turn_id);
    }

    fn nextModelOperationKind(self: *Store, session_ref: []const u8, first_admission: i64, current: *const CurrentConfiguration, policy: model_capability.CompactionPolicy) !ModelOperationKind {
        const last = try prepare(self.database, "SELECT current.purpose,current.resolution_code,current.operation_id,latest.outcome_code,latest.first_admission_id FROM turn latest INDEXED BY turn_session_latest " ++
            "LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
            "WHERE latest.session_ref=?1 ORDER BY latest.turn_id DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(last);
        try bindText(last, 1, session_ref);
        const result = c.sqlite3_step(last);
        if (result == c.SQLITE_DONE) return .assistant_response;
        if (result != c.SQLITE_ROW) return error.CorruptStore;
        _ = try readNullablePositiveI64(last, 2) orelse return error.CorruptStore;
        var resolution: protocol.Bounded(96) = .{};
        try readText(last, 1, &resolution);
        const active = c.sqlite3_column_type(last, 3) == c.SQLITE_NULL;
        var facts: turn_policy.CompactionFacts = .{
            .previous = .{
                .purpose = switch (c.sqlite3_column_int(last, 0)) {
                    0 => .assistant_response,
                    1 => .compaction,
                    else => return error.CorruptStore,
                },
                .context_overflow = turn_policy.Resolution.parse(resolution.slice()) == .context_overflow,
                .turn_active = active,
                .same_input_prefix = (try readNullablePositiveI64(last, 4) orelse return error.CorruptStore) == first_admission,
            },
            .trigger = policy.compaction_trigger,
            .context_changed = false,
            .usage_tokens = null,
            .uncovered_bytes = 0,
            .output_reservation = policy.output_reservation,
        };
        if (turn_policy.forcedPurpose(facts.previous, facts.trigger)) |purpose| return purpose;
        facts.context_changed = try self.contextChangedSinceBase(session_ref, current.next_position);
        if (!facts.context_changed) return turn_policy.nextPurpose(facts);
        var usage_tokens: ?u64 = null;
        const base = try prepare(self.database, "SELECT coalesce((SELECT admission_position FROM model_operation INDEXED BY model_operation_compaction_bases " ++
            "WHERE session_ref=?1 AND purpose=1 AND " ++ resolutionIs("resolution_code", .compacted) ++ " AND admission_position<?2 ORDER BY admission_position DESC LIMIT 1),0)");
        defer _ = c.sqlite3_finalize(base);
        try bindText(base, 1, session_ref);
        try bindU64(base, 2, current.next_position);
        if (c.sqlite3_step(base) != c.SQLITE_ROW) return error.CorruptStore;
        const frontier = try readNullableTokens(base, 0, true) orelse return error.CorruptStore;
        // Without a usage anchor, all retained host input still contributes.
        // Covered provider/tool material is excluded separately by the base.
        var usage_position: u64 = 0;
        var result_admission = frontier;
        const usage = try prepare(self.database, "SELECT o.usage_tokens,coalesce((SELECT max(i.session_position) FROM model_output_item i WHERE i.operation_id=o.operation_id),o.admission_position),o.admission_position " ++
            "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
            "WHERE o.session_ref=?1 AND " ++ resolutionIn("o.resolution_code", &turn_policy.accepted) ++ " " ++
            "AND o.admission_position>=?2 AND r.provider=?3 AND r.model=?4 ORDER BY o.admission_position DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(usage);
        try bindText(usage, 1, session_ref);
        try bindU64(usage, 2, frontier);
        try bindText(usage, 3, @tagName(current.provider));
        try bindText(usage, 4, current.model.slice());
        switch (c.sqlite3_step(usage)) {
            c.SQLITE_ROW => {
                usage_tokens = try readNullableTokens(usage, 0, true);
                if (usage_tokens != null) {
                    usage_position = @intCast(try readNullablePositiveI64(usage, 1) orelse return error.CorruptStore);
                    // Include this producer: its results follow usage.
                    result_admission = @intCast(try readNullablePositiveI64(usage, 2) orelse return error.CorruptStore);
                }
            },
            c.SQLITE_DONE => {},
            else => return error.CorruptStore,
        }
        const estimate = try prepare(self.database, "SELECT " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
            "WHERE e.session_ref=?1 AND e.entry_kind IN (1,2) AND e.session_position>?2) + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM model_output_item i JOIN content c ON c.content_id=i.content_id " ++
            "WHERE i.session_ref=?1 AND i.session_position>=max(?2+1,coalesce((SELECT max(anchor.session_position) " ++
            "FROM model_operation b INDEXED BY model_operation_compaction_bases JOIN model_output_item anchor ON anchor.operation_id=b.operation_id " ++
            "WHERE b.session_ref=?1 AND b.purpose=1 AND " ++ resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=?3 AND anchor.item_kind=4),0))) + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o INDEXED BY model_operation_context_history " ++
            "CROSS JOIN model_tool_call call ON call.operation_id=o.operation_id " ++
            "JOIN content c ON c.content_id=call.rejection_content_id WHERE o.session_ref=?1 AND o.admission_position>=?4 " ++
            "AND " ++ resolutionIn("o.resolution_code", &turn_policy.accepted) ++ " AND call.acceptance_position>max(?2,?3)) + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id " ++
            "WHERE a.session_ref=?1 AND a.acceptance_position>max(?2,?3)) + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN content c ON c.content_id=m.content_id " ++
            "WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql ++ ") + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
            "WHERE r.session_ref=?1 AND r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
            "AND r.instructions_updated=1) + " ++
            "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
            "WHERE r.session_ref=?1 AND r.revision=1 AND ?2=0)");
        defer _ = c.sqlite3_finalize(estimate);
        try bindText(estimate, 1, session_ref);
        try bindU64(estimate, 2, usage_position);
        try bindU64(estimate, 3, frontier);
        try bindU64(estimate, 4, result_admission);
        if (c.sqlite3_step(estimate) != c.SQLITE_ROW) return error.CorruptStore;
        const bytes = c.sqlite3_column_int64(estimate, 0);
        if (bytes < 0) return error.CorruptStore;
        facts.usage_tokens = usage_tokens;
        facts.uncovered_bytes = @intCast(bytes);
        return turn_policy.nextPurpose(facts);
    }

    fn overflowCanCompact(self: *Store, binding: AttemptBinding) !bool {
        const purpose = try self.readModelOperationKind(binding.operation_id);
        const statement = try prepare(self.database, "SELECT session_ref,admission_position FROM model_operation WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 0, &session_ref);
        const boundary = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        return turn_policy.recoversOverflow(purpose, try self.contextChangedSinceBase(session_ref.slice(), @intCast(boundary)));
    }

    fn contextChangedSinceBase(self: *Store, session_ref: []const u8, boundary: u64) !bool {
        // Any changed suffix of the newest base also belongs to every older
        // base. Older bases cannot change the answer.
        const statement = try prepare(self.database, "WITH base AS (SELECT admission_position FROM model_operation INDEXED BY model_operation_compaction_bases " ++
            "WHERE session_ref=?1 AND purpose=1 AND " ++ resolutionIs("resolution_code", .compacted) ++ " AND admission_position<?2 " ++
            "ORDER BY admission_position DESC LIMIT 1) " ++
            "SELECT NOT EXISTS(SELECT 1 FROM base " ++
            "WHERE NOT EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=?1 " ++
            "AND e.entry_kind IN (1,2) AND e.session_position>base.admission_position AND e.session_position<?2) " ++
            "AND NOT EXISTS(SELECT 1 FROM model_output_item item INDEXED BY model_output_history " ++
            "CROSS JOIN model_operation suffix ON suffix.operation_id=item.operation_id " ++
            "WHERE item.session_ref=?1 AND suffix.session_ref=?1 AND suffix.purpose=0 " ++
            "AND item.session_position>base.admission_position AND item.session_position<?2))");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, boundary);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        return c.sqlite3_column_int(statement, 0) == 1;
    }

    fn admitNextModelAttemptLocked(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        if (!try self.hasRunnableWorkLocked(kind)) return null;
        try exec(self.database, "BEGIN IMMEDIATE");

        const select = try prepare(self.database, switch (kind) {
            .message => runnable_selection_sql,
            .tool_continuation => tool_continuation_selection_sql,
        });
        defer _ = c.sqlite3_finalize(select);
        const step_result = c.sqlite3_step(select);
        if (step_result == c.SQLITE_DONE) return error.RunnableSelectionFailed;
        if (step_result != c.SQLITE_ROW) return error.RunnableSelectionFailed;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(select, 0, &session_ref);
        const first_admission = c.sqlite3_column_int64(select, 1);
        const cutoff = c.sqlite3_column_int64(select, 2);
        var selected = c.sqlite3_column_int64(select, 3);
        const revision = c.sqlite3_column_int64(select, 4);
        const initial_position = c.sqlite3_column_int64(select, 5);
        const existing_turn = try readNullablePositiveI64(select, 6);
        if (first_admission <= 0 or cutoff < first_admission or selected < 0 or revision <= 0 or initial_position <= 0) {
            return error.CorruptStore;
        }
        const current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;
        const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
        const purpose = try self.nextModelOperationKind(session_ref.slice(), first_admission, &current, policy);
        if (purpose == .compaction) selected = 0;

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
        // Assistant admission atomically projects every instruction update in
        // its revision prefix. Conversation's unique source_revision index is
        // therefore the canonical applied frontier, including equal/clear text.
        const instruction_count = blk: {
            if (purpose == .compaction) break :blk @as(i64, 0);
            const count = try prepare(
                self.database,
                "SELECT count(*) FROM session_revision r WHERE r.session_ref=?1 AND " ++
                    "r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
                    "AND r.revision<=?2 AND r.instructions_updated=1",
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
                    "FROM session_revision r WHERE r.session_ref=?1 AND " ++
                    "r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
                    "AND r.revision<=?4 AND r.instructions_updated=1 ORDER BY revision",
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
                    "admission_position,purpose,compaction_trigger,output_reservation,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
                    "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,1,1,1,0)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, operation_id);
            try bindU64(insert, 2, turn_id);
            try bindText(insert, 3, session_ref.slice());
            try bindI64(insert, 4, revision);
            try bindI64(insert, 5, cutoff);
            try bindU64(insert, 6, next_position);
            try bindI64(insert, 7, @as(i64, if (purpose == .compaction) 1 else 0));
            try bindNullableU64(insert, 8, policy.compaction_trigger);
            try bindU64(insert, 9, policy.output_reservation);
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.none, faults, self.tryAdmitNextModelRetryLocked(active, faults));
    }

    fn tryAdmitNextModelRetryLocked(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        const snapshot_ms = try readUnixMilliseconds(self.io);
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
                allowance_used != attempt_ordinal or allowance_used >= retry_policy.maximum_attempts or
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
        // The held Store mutex excludes every other writer, so the candidate
        // read outside the transaction is still current inside it.
        const current = selected orelse return null;
        try exec(self.database, "BEGIN IMMEDIATE");
        if (current.attempt_ordinal >= retry_policy.maximum_attempts) return error.CorruptStore;
        const replacement_ordinal = current.attempt_ordinal + 1;
        const update = try prepare(
            self.database,
            "UPDATE model_operation SET attempt_ordinal=?2,allowance_used=?2,uncertain=1,retry_due_at_ms=0 " ++
                "WHERE operation_id=?1 AND turn_id=?3 AND resolution_code IS NULL " ++
                "AND attempt_ordinal=?4 AND allowance_used=?4 AND " ++ retry_allowance_open_sql ++ " AND retry_due_at_ms<=?5",
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

    fn hasRunnableWorkLocked(self: *Store, kind: ModelAdmissionKind) !bool {
        const statement = try self.hot(switch (kind) {
            .message => .runnable_probe,
            .tool_continuation => .tool_continuation_probe,
        });
        defer resetHot(statement);
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
        const statement = try self.hot(.blocked_tool_calls);
        defer resetHot(statement);
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const operation_id = c.sqlite3_column_int64(statement, 0);
                if (operation_id <= 0) return error.CorruptStore;
                _ = try self.readToolOutcomeFacts(@intCast(operation_id), false, false);
            },
            c.SQLITE_DONE => return,
            else => return error.CallReadFailed,
        };
    }

    pub fn openHistoricalView(self: *Store, binding: AttemptBinding) !HistoricalView {
        const access = try self.enter(.none);
        defer access.release();
        try access.finish(Ordinary.attempt_binding, self.validateCurrentAttempt(binding));
        return .{ .store = self, .binding = binding };
    }

    pub fn modelOperationKind(self: *Store, binding: AttemptBinding) !ModelOperationKind {
        const access = try self.enter(.none);
        defer access.release();
        try access.finish(Ordinary.attempt_binding, self.validateCurrentAttempt(binding));
        return access.finish(Ordinary.none, self.readModelOperationKind(binding.operation_id));
    }

    fn readModelOperationKind(self: *Store, operation_id: u64) !ModelOperationKind {
        const statement = try prepare(self.database, "SELECT purpose FROM model_operation WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        return switch (c.sqlite3_column_int(statement, 0)) {
            0 => .assistant_response,
            1 => .compaction,
            else => error.CorruptStore,
        };
    }

    fn selectedContextAnchor(self: *Store, binding: AttemptBinding) !?u64 {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.attempt_binding, self.selectedContextAnchorLocked(binding));
    }

    fn selectedContextAnchorLocked(self: *Store, binding: AttemptBinding) !?u64 {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(self.database, "SELECT base.operation_id FROM model_operation current JOIN model_operation base INDEXED BY model_operation_compaction_bases " ++
            "ON base.session_ref=current.session_ref WHERE current.operation_id=?1 AND base.purpose=1 " ++
            "AND " ++ resolutionIs("base.resolution_code", .compacted) ++ " AND base.admission_position<current.admission_position " ++
            "ORDER BY base.admission_position DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.CorruptStore;
        const base_id = c.sqlite3_column_int64(statement, 0);
        const anchor = try prepare(self.database, "SELECT session_position,content_id FROM model_output_item INDEXED BY model_output_compaction_anchor WHERE operation_id=?1 AND item_kind=4 ORDER BY item_ordinal");
        defer _ = c.sqlite3_finalize(anchor);
        try bindI64(anchor, 1, base_id);
        if (c.sqlite3_step(anchor) != c.SQLITE_ROW) return error.CorruptStore;
        const position = c.sqlite3_column_int64(anchor, 0);
        const content_id = c.sqlite3_column_int64(anchor, 1);
        if (position <= 0 or content_id <= 0) return error.CorruptStore;
        _ = try self.readContentMetadata(content_id);
        if (c.sqlite3_step(anchor) != c.SQLITE_DONE) return error.CorruptStore;
        return @intCast(position);
    }

    fn validateCurrentAttempt(self: *Store, binding: AttemptBinding) !void {
        const statement = try self.hot(.current_attempt);
        defer resetHot(statement);
        try bindU64(statement, 1, binding.operation_id);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return error.StaleAttemptBinding;
        if (step != c.SQLITE_ROW) return error.OperationReadFailed;
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return error.StaleAttemptBinding;
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return;
        if (c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL) return error.SupersededByControl;
        return error.StaleAttemptBinding;
    }

    fn readHistoricalSettings(self: *Store, view: *HistoricalView) !HistoricalSettings {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.attempt_binding, self.readHistoricalSettingsLocked(view));
    }

    fn readHistoricalSettingsLocked(self: *Store, view: *HistoricalView) !HistoricalSettings {
        try self.validateCurrentAttempt(view.binding);
        const statement = try prepare(
            self.database,
            "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,r.tools_mask,r.provider,o.session_ref,r.workspace,o.compaction_trigger,o.output_reservation " ++
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
        if (tools < 0 or tools > tool_catalog.toolBit(.bash)) return error.CorruptStore;
        const instructions = try self.readContentMetadata(instructions_id);
        const output_schema = if (output_schema_id) |content_id| blk: {
            const metadata = try self.readContentMetadata(content_id);
            break :blk HistoricalContent{ .view = view, .length = metadata.length, .digest = metadata.digest };
        } else null;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 5, &session_ref);
        var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        try readText(statement, 6, &workspace);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("rui/session-affinity/v1");
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, self.selector.len, .big);
        hash.update(&length);
        hash.update(self.selector.slice());
        std.mem.writeInt(u64, &length, session_ref.len, .big);
        hash.update(&length);
        hash.update(session_ref.slice());
        const digest = hash.finalResult();
        return .{
            .operation = try self.readModelOperationKind(view.binding.operation_id),
            .compaction_trigger = try readNullableTokens(statement, 7, false),
            .output_reservation = try readNullableTokens(statement, 8, true) orelse return error.CorruptStore,
            .model = model,
            .provider = try readProvider(statement, 4),
            .workspace = workspace,
            .store = self.selector,
            .session = session_ref,
            .session_affinity = digest[0..16].*,
            .baseline_instructions = .{ .view = view, .length = instructions.length, .digest = instructions.digest },
            .output_schema = output_schema,
            .tools_mask = @intCast(tools),
        };
    }

    fn readHistoricalEntry(self: *Store, view: *HistoricalView, after_position: u64, bytes_left: *usize, items_left: *usize) !HistoricalView.EntryProgress {
        if (view.group_scan.reader) |*reader| reader.prepareRead();
        const access = try self.enter(.none);
        defer access.release();
        return .{ .ready = try access.finish(Ordinary.historical_entry, self.readHistoricalEntryLocked(view, after_position, bytes_left, items_left)) };
    }

    fn validateHistoricalOutputsStep(self: *Store, view: *HistoricalView) !bool {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.attempt_binding, self.validateHistoricalOutputsStepLocked(view));
    }

    // Select the producing Operation before its items, so even a completely
    // missing output is detected. No statement or lock survives this one step.
    fn validateHistoricalOutputsStepLocked(self: *Store, view: *HistoricalView) !bool {
        try self.validateCurrentAttempt(view.binding);
        if (view.outputs_validated) return true;
        if (view.output_frontier == null) {
            const boundary = try prepare(self.database, "SELECT current.admission_position,coalesce((SELECT base.admission_position " ++
                "FROM model_operation base INDEXED BY model_operation_compaction_bases WHERE base.session_ref=current.session_ref AND base.purpose=1 " ++
                "AND " ++ resolutionIs("base.resolution_code", .compacted) ++ " AND base.admission_position<current.admission_position ORDER BY base.admission_position DESC LIMIT 1),0) " ++
                "FROM model_operation current WHERE current.operation_id=?1");
            defer _ = c.sqlite3_finalize(boundary);
            try bindU64(boundary, 1, view.binding.operation_id);
            if (c.sqlite3_step(boundary) != c.SQLITE_ROW) return error.CorruptStore;
            view.output_boundary = try readNullableTokens(boundary, 0, false) orelse return error.CorruptStore;
            view.output_frontier = try readNullableTokens(boundary, 1, true) orelse return error.CorruptStore;
            return false;
        }
        if (view.output_source == 0) {
            const source = try prepare(self.database, "SELECT source.operation_id,source.admission_position,source.output_item_count,source.purpose " ++
                "FROM model_operation current JOIN model_operation source INDEXED BY model_operation_context_history ON source.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND source.admission_position>=?2 AND (source.admission_position,source.operation_id)>(?3,?5) " ++
                "AND source.admission_position<?4 AND " ++ resolutionIn("source.resolution_code", &turn_policy.accepted) ++ " " ++
                "ORDER BY source.admission_position,source.operation_id LIMIT 1");
            defer _ = c.sqlite3_finalize(source);
            try bindU64(source, 1, view.binding.operation_id);
            try bindU64(source, 2, view.output_frontier.?);
            try bindU64(source, 3, view.output_cursor);
            try bindU64(source, 4, view.output_boundary);
            try bindU64(source, 5, view.output_cursor_id);
            const result = c.sqlite3_step(source);
            if (result == c.SQLITE_DONE) {
                view.outputs_validated = true;
                return true;
            }
            if (result != c.SQLITE_ROW) return error.CorruptStore;
            view.output_source = try readNullableTokens(source, 0, false) orelse return error.CorruptStore;
            view.output_cursor = try readNullableTokens(source, 1, false) orelse return error.CorruptStore;
            view.output_cursor_id = view.output_source;
            view.output_expected = try readNullableTokens(source, 2, true) orelse return error.CorruptStore;
            if (c.sqlite3_column_int(source, 3) == 1 and view.output_expected == 0) return error.CorruptStore;
            view.output_count = 0;
            view.output_previous_position = 0;
            return false;
        }
        const item = try prepare(self.database, "SELECT item.item_ordinal,item.session_position," ++
            "item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal " ++
            "FROM model_operation source JOIN model_output_item item ON item.operation_id=source.operation_id " ++
            "WHERE source.operation_id=?1 AND item.item_ordinal>=?2 ORDER BY item.item_ordinal LIMIT 1");
        defer _ = c.sqlite3_finalize(item);
        try bindU64(item, 1, view.output_source);
        try bindU64(item, 2, view.output_count);
        const result = c.sqlite3_step(item);
        if (result == c.SQLITE_DONE) {
            if (view.output_count != view.output_expected) return error.CorruptStore;
            view.output_source = 0;
            return false;
        }
        if (result != c.SQLITE_ROW) return error.CorruptStore;
        const position = try readNullableTokens(item, 1, false) orelse return error.CorruptStore;
        if (view.output_count >= view.output_expected or c.sqlite3_column_int64(item, 0) != view.output_count or
            c.sqlite3_column_int(item, 2) != 1 or position <= view.output_cursor or position >= view.output_boundary or
            (view.output_count != 0 and position != view.output_previous_position + 1)) return error.CorruptStore;
        view.output_count += 1;
        view.output_previous_position = position;
        return false;
    }

    fn readHistoricalEntryLocked(self: *Store, view: *HistoricalView, after_position: u64, bytes_left: *usize, items_left: *usize) !?HistoricalEntry {
        try self.validateCurrentAttempt(view.binding);
        std.debug.assert(view.outputs_validated);
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
            view.tool_group_initialized = false;
            if (try self.readNextHistoricalToolGroup(view, bytes_left, items_left)) |group| {
                view.tool_group_source_cursor = group.source_operation_id;
                if (group.entry.position > after_position) {
                    view.next_tool_group = group.entry;
                    view.next_tool_group_source_id = group.source_operation_id;
                } else return error.HistoricalPending;
            }
            view.tool_group_initialized = true;
        }
        view.tool_group_scan_after = after_position;
        const statement = try prepare(
            self.database,
            "SELECT position,kind,content_id,model,provider,item_kind,item_id_digest,valid_owner,sender FROM (" ++
                "SELECT * FROM (SELECT e.session_position AS position,e.entry_kind AS kind,e.content_id AS content_id,NULL AS model,NULL AS provider,NULL AS item_kind,NULL AS item_id_digest,NULL AS valid_owner," ++
                "(SELECT m.sender_session_ref FROM message_admission m WHERE e.entry_kind=1 AND m.admission_id=e.source_admission_id) AS sender " ++
                "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
                "AND e.entry_kind IN (1,2) ORDER BY e.session_position LIMIT 1) UNION ALL " ++
                "SELECT * FROM (SELECT item.session_position AS position,3 AS kind,item.content_id AS content_id,r.model AS model,r.provider AS provider,item.item_kind,item.item_id_digest," ++
                resolutionIn("owner.resolution_code", &turn_policy.accepted) ++ " AND owner.session_ref=item.session_ref " ++
                "AND owner_turn.session_ref=item.session_ref " ++
                "AND owner.attempt_ordinal=item.attempt_ordinal AND owner.admission_position<item.session_position " ++
                "AND owner.admission_position<current.admission_position AND " ++
                "(item.item_kind!=3 OR " ++ resolutionIs("owner.resolution_code", .tool_proposals) ++ ") AND " ++
                "((" ++ resolutionIs("owner.resolution_code", .tool_proposals) ++ ")=EXISTS(SELECT 1 FROM model_tool_call call WHERE call.operation_id=owner.operation_id)) AS valid_owner,NULL AS sender " ++
                "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
                "LEFT JOIN model_operation owner ON owner.operation_id=item.operation_id " ++
                "LEFT JOIN turn owner_turn ON owner_turn.turn_id=owner.turn_id " ++
                "LEFT JOIN session_revision r ON r.session_ref=owner.session_ref AND r.revision=owner.settings_revision " ++
                "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position ORDER BY item.session_position LIMIT 1)" ++
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
        var requested_model: ?protocol.Bounded(protocol.max_model_bytes) = null;
        if (kind == .provider_output) {
            // Keep contradictory owners visible instead of filtering their
            // output away. Accepted-population validation cannot see failed
            // owners; every selected item must independently certify one.
            if (c.sqlite3_column_int(statement, 7) != 1) return error.CorruptStore;
            var model: protocol.Bounded(protocol.max_model_bytes) = .{};
            try readText(statement, 3, &model);
            if (model.len == 0) return error.CorruptStore;
            _ = try readProvider(statement, 4);
            requested_model = model;
        }
        var sender: ?protocol.Bounded(protocol.max_session_bytes) = null;
        if (c.sqlite3_column_type(statement, 8) != c.SQLITE_NULL) {
            sender = .{};
            try readText(statement, 8, &sender.?);
        }
        const ordinary = HistoricalEntry{
            .position = @intCast(position),
            .kind = kind,
            .requested_model = requested_model,
            .sender = sender,
            .content = .{
                .view = view,
                .length = metadata.length,
                .digest = metadata.digest,
                .private = kind == .provider_output,
                .item_identity = if (kind == .provider_output) .{
                    .kind = std.enums.fromInt(OutputItemKind, c.sqlite3_column_int(statement, 5)) orelse return error.CorruptStore,
                    .id_digest = try readDigest(statement, 6),
                } else null,
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
        view.active_tool_group_expected = view.next_tool_group_count;
        return entry;
    }

    const HistoricalToolGroup = struct {
        entry: HistoricalEntry,
        source_operation_id: u64,
    };

    fn readNextHistoricalToolGroup(
        self: *Store,
        view: *HistoricalView,
        bytes_left: *usize,
        items_left: *usize,
    ) !?HistoricalToolGroup {
        const scan = &view.group_scan;
        if (scan.reader) |*reader| {
            const Source = struct {
                storage: *Store,
                scan: *HistoricalView.GroupScan,

                pub fn contentLength(source: @This()) u64 {
                    return source.scan.reader.?.reference.length;
                }

                pub fn readContent(source: @This(), offset: u64, destination: []u8) !usize {
                    try source.storage.readOwnedContentLocked(&source.scan.reader.?, offset, destination);
                    const count = destination.len;
                    source.scan.hash.update(destination[0..count]);
                    if (offset + count == source.contentLength() and
                        !std.mem.eql(u8, &source.scan.hash.finalResult(), &source.scan.reader.?.reference.digest)) return error.CorruptStore;
                    return count;
                }
            };
            const authenticated = scan.validation.advance(Source{ .storage = self, .scan = scan }, bytes_left, items_left) catch |err| switch (err) {
                // This scan authenticates canonical calls. Preparation owns
                // compatibility of the complete selected provider recipe.
                error.ContinuationUnavailable => true,
                else => return error.CorruptStore,
            };
            if (!authenticated)
                return error.HistoricalPending;
            try scan.validation.authenticateIdentity(.function_call, scan.fields[0].digest);
            try scan.validation.authenticate(scan.fields);
            reader.close();
            scan.reader = null;
            return error.HistoricalPending;
        }
        if (scan.source != 0) {
            // Walk the immutable item population, not just surviving call rows.
            // One item/classification per step also detects wholly missing calls.
            const item = try prepare(self.database, "SELECT item.item_ordinal,item.item_kind,item.session_ref,item.session_position,item.content_id," ++
                "item.session_ref=source.session_ref AND item.attempt_ordinal=source.attempt_ordinal " ++
                "FROM model_output_item item JOIN model_operation source ON source.operation_id=item.operation_id " ++
                "WHERE item.operation_id=?1 AND item.item_ordinal>=?2 ORDER BY item.item_ordinal LIMIT 1");
            defer _ = c.sqlite3_finalize(item);
            try bindU64(item, 1, scan.source);
            try bindU64(item, 2, scan.item);
            const result = c.sqlite3_step(item);
            if (result == c.SQLITE_DONE) {
                const extra = try prepare(self.database, "SELECT call_ordinal FROM model_tool_call WHERE operation_id=?1 AND call_ordinal>=?2 ORDER BY call_ordinal LIMIT 1");
                defer _ = c.sqlite3_finalize(extra);
                try bindU64(extra, 1, scan.source);
                try bindU64(extra, 2, scan.calls);
                if (scan.item != scan.expected_items or scan.calls == 0 or scan.position == 0 or scan.position >= scan.boundary or c.sqlite3_step(extra) != c.SQLITE_DONE)
                    return error.CorruptStore;
                const group = HistoricalToolGroup{ .entry = .{ .position = scan.position, .kind = .tool_results }, .source_operation_id = scan.source };
                view.next_tool_group_count = scan.calls;
                scan.source = 0;
                return group;
            }
            if (result != c.SQLITE_ROW or c.sqlite3_column_int64(item, 0) != scan.item) return error.CorruptStore;
            const position = try readNullableTokens(item, 3, false) orelse return error.CorruptStore;
            if (scan.item >= scan.expected_items or c.sqlite3_column_int(item, 5) != 1 or
                position <= scan.admission or position >= scan.boundary or
                (scan.item != 0 and position != scan.previous_position + 1)) return error.CorruptStore;
            scan.previous_position = position;
            scan.item += 1;
            if (c.sqlite3_column_int(item, 1) != 3) return error.HistoricalPending;
            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            try readText(item, 2, &session);
            const proposal = try self.proposalLocked(session.slice(), position, false);
            if (proposal.metadata.operation != scan.source or proposal.metadata.call_ordinal != scan.calls) return error.CorruptStore;
            const outcome = try prepare(self.database, "SELECT coalesce(call.acceptance_position,action.acceptance_position)," ++
                "coalesce(call.rejection_content_id,action.resolution_content_id)," ++
                "CASE WHEN call.rejection_code IS NOT NULL OR (action.resolution_code IS NOT NULL AND " ++
                "action.session_ref=source.session_ref AND action.tool_kind=call.action_kind) THEN 1 ELSE 0 END " ++
                "FROM model_tool_call call JOIN model_operation source ON source.operation_id=call.operation_id " ++
                "LEFT JOIN action_operation action ON action.parent_operation_id=call.operation_id AND action.call_ordinal=call.call_ordinal " ++
                "WHERE call.operation_id=?1 AND call.call_ordinal=?2");
            defer _ = c.sqlite3_finalize(outcome);
            try bindU64(outcome, 1, scan.source);
            try bindU64(outcome, 2, scan.calls);
            if (c.sqlite3_step(outcome) != c.SQLITE_ROW or c.sqlite3_column_int(outcome, 2) != 1) return error.CorruptStore;
            const accepted = try readNullablePositiveI64(outcome, 0) orelse return error.CorruptStore;
            _ = try self.readPublicContentMetadata(try readNullablePositiveI64(outcome, 1) orelse return error.CorruptStore);
            scan.position = @max(scan.position, @as(u64, @intCast(accepted)));
            scan.calls += 1;
            scan.fields = proposal.metadata.fields;
            scan.validation = .{};
            scan.hash = protocol.contentHasher();
            const metadata = try self.readContentMetadata(try readNullablePositiveI64(item, 4) orelse return error.CorruptStore);
            scan.reader = try self.openContentIdentityLocked(.{ .length = metadata.length, .digest = metadata.digest }, true);
            return error.HistoricalPending;
        }
        const statement = try prepare(
            self.database,
            "SELECT source.operation_id,current.admission_position," ++ resolutionIs("source.resolution_code", .tool_proposals) ++ ",source.admission_position,source.output_item_count FROM model_operation current " ++
                "JOIN model_operation source INDEXED BY model_operation_session_history " ++
                "ON source.session_ref=current.session_ref WHERE current.operation_id=?1 " ++
                "AND source.operation_id>?2 AND source.operation_id<current.operation_id " ++
                "ORDER BY source.operation_id LIMIT 1",
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
        if (c.sqlite3_column_int(statement, 2) != 1) {
            view.tool_group_source_cursor = @intCast(source_operation_id);
            return error.HistoricalPending;
        }
        scan.source = @intCast(source_operation_id);
        scan.boundary = @intCast(admission_position);
        scan.admission = try readNullableTokens(statement, 3, false) orelse return error.CorruptStore;
        scan.expected_items = try readNullableTokens(statement, 4, false) orelse return error.CorruptStore;
        scan.previous_position = 0;
        scan.item = 0;
        scan.calls = 0;
        scan.position = 0;
        return error.HistoricalPending;
    }

    fn readHistoricalToolResult(
        self: *Store,
        view: *HistoricalView,
    ) !?HistoricalToolResult {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.attempt_binding, self.readHistoricalToolResultLocked(view));
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
                "WHERE current.operation_id=?1 AND " ++ resolutionIs("source.resolution_code", .tool_proposals) ++ " " ++
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
            if (view.active_tool_group_count != view.active_tool_group_expected) return error.CorruptStore;
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
        if (call_ordinal != view.active_tool_group_count or view.active_tool_group_count >= view.active_tool_group_expected)
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

    /// Read before the canonical reads it may let a caller skip.
    pub fn commitGeneration(self: *const Store) u64 {
        return self.commit_generation.load(.acquire);
    }

    pub fn operationSupersededByControl(self: *Store, binding: AttemptBinding) !?SupersedingControl {
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.operationSupersededByControlLocked(binding));
    }

    fn operationSupersededByControlLocked(self: *Store, binding: AttemptBinding) !?SupersedingControl {
        const statement = try self.hot(.operation_supersession);
        defer resetHot(statement);
        try bindU64(statement, 1, binding.operation_id);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return null;
        if (step != c.SQLITE_ROW) return error.OperationReadFailed;
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return null;
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return null;
        var command_key: protocol.Bounded(protocol.max_key_bytes) = .{};
        try readText(statement, 2, &command_key);
        return .{ .command_key = command_key };
    }

    pub fn withDispatchHandoff(
        self: *Store,
        binding: AttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        const access = try self.enter(.none);
        defer access.release();
        try access.finish(Ordinary.attempt_binding, self.validateCurrentAttempt(binding));
        // As for Actions, dispatch failures belong to the caller.
        try handoff(context);
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        const code = failure.code();
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        // A rejected response is final; only transport and HTTP status retry.
        if (failure == .rejected) std.debug.assert(disposition != .retryable);
        if (failure.diagnostic()) |detail| {
            std.debug.assert(detail.len <= 512 and std.unicode.utf8ValidateSlice(detail));
        }
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.attempt_binding, faults, self.settleModelAttemptFailureLocked(binding, failure, disposition, faults));
    }

    fn settleModelAttemptFailureLocked(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        const code = failure.code();
        try exec(self.database, "BEGIN IMMEDIATE");
        try self.validateCurrentAttempt(binding);
        switch (disposition) {
            .ordinary, .context_overflow => {
                const compact = disposition == .context_overflow and try self.overflowCanCompact(binding);
                const resolution = if (disposition == .context_overflow) @tagName(turn_policy.Resolution.context_overflow) else code;
                const outcome = if (disposition == .context_overflow) "ResourceExceeded" else code;
                const diagnostic_id = if (failure.diagnostic()) |detail|
                    try self.importBytesContent(detail, false, faults.content_import)
                else
                    null;
                const update = try prepare(
                    self.database,
                    "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?6,request_id=?7," ++
                        "last_failure_code=CASE WHEN ?4=1 THEN ?5 ELSE last_failure_code END " ++
                        "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                );
                defer _ = c.sqlite3_finalize(update);
                try bindU64(update, 1, binding.operation_id);
                try bindText(update, 2, resolution);
                try bindU64(update, 3, binding.attempt_ordinal);
                try bindI64(update, 4, @as(i64, if (disposition == .context_overflow) 1 else 0));
                try bindText(update, 5, code);
                try bindNullableI64(update, 6, diagnostic_id);
                try bindOptionalText(update, 7, failure.requestId());
                try expectDone(update);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                if (compact) {
                    if (faults.before_commit) return error.InjectedCommitFailure;
                    try exec(self.database, "COMMIT");
                    return;
                }

                const settle_turn = try prepare(
                    self.database,
                    "UPDATE turn SET outcome_code=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
                );
                defer _ = c.sqlite3_finalize(settle_turn);
                try bindU64(settle_turn, 1, binding.turn_id);
                try bindText(settle_turn, 2, outcome);
                try bindU64(settle_turn, 3, binding.operation_id);
                try expectDone(settle_turn);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                try self.recordTurnOutcomePosition(binding.turn_id);
            },
            .retryable => |policy| switch (try retry_policy.decide(binding.attempt_ordinal, policy, try readUnixMilliseconds(self.io))) {
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
                        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,last_failure_code=?2,resolution_code='retry_exhausted',request_id=?4 " ++
                            "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, binding.operation_id);
                    try bindText(update, 2, code);
                    try bindU64(update, 3, binding.attempt_ordinal);
                    // The settling Attempt's correlation, like a terminal failure.
                    try bindOptionalText(update, 4, failure.requestId());
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
                    try self.recordTurnOutcomePosition(binding.turn_id);
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finishTransaction(Ordinary.none, .{}, self.recoverOneExhaustedModelAttemptLocked(active));
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
                .attempt_ordinal = retry_policy.maximum_attempts,
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
            try bindU64(update_operation, 2, retry_policy.maximum_attempts);
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
        try self.recordTurnOutcomePosition(@intCast(binding.turn_id));
        try exec(self.database, "COMMIT");
        return true;
    }

    pub fn settleModelSuccess(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        const access = try self.enter(.fromSettlement(faults.settlement_trace));
        defer access.release();
        return access.finishTransaction(Ordinary.model_success, faults, self.settleModelSuccessLocked(binding, output, faults));
    }

    fn settleModelSuccessLocked(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        if (faults.settlement_trace) |trace| {
            std.debug.assert(c.sqlite3_txn_state(self.database, "main") == c.SQLITE_TXN_WRITE);
            trace.mark(.transaction_active);
        }
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
        switch (c.sqlite3_step(operation)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return error.StaleAttemptBinding,
            else => return error.OperationReadFailed,
        }
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(operation, 0, &session_ref);
        const frozen_tools = try toolSet(c.sqlite3_column_int(operation, 1));
        var current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;
        const purpose = try self.readModelOperationKind(binding.operation_id);
        // Validate the explicit candidate before imports, projections or effects.
        var candidate_metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var compaction_count: u64 = 0;
        while (try candidate_metadata.next()) |record| {
            if (record.tag == .item and record.kind == .compaction) {
                if (record.length == 0) return error.InvalidProviderEnvelope;
                compaction_count += 1;
            }
            if (purpose == .compaction and record.kind == .function_call) return error.InvalidProviderEnvelope;
        }
        if (purpose == .compaction) {
            if (compaction_count != 1 or output.call_count != 0) return error.InvalidProviderEnvelope;
        } else if (compaction_count != 0) return error.InvalidProviderEnvelope;

        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var imported_items: u64 = 0;
        var usage_id: ?i64 = null;
        var usage_tokens: ?u64 = null;
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
                usage_tokens = record.usage_tokens;
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
            switch (c.sqlite3_step(duplicate_identity)) {
                c.SQLITE_DONE => {},
                c.SQLITE_ROW => return error.InvalidProviderEnvelope,
                else => return error.OutputReadFailed,
            }
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
            try bindI64(insert, 5, @backingInt(record.kind));
            try bindI64(insert, 6, content_id);
            try bindU64(insert, 7, binding.attempt_ordinal);
            try bindBlob(insert, 8, &record.id_digest);
            try expectDone(insert);
            current.next_position = try std.math.add(u64, current.next_position, 1);
            imported_items += 1;
        }
        if (imported_items != output.item_count) return error.CorruptOutputMetadata;

        // Raw items own stream positions. Each visible message projects at its
        // own item's position, so text remains before/among calls, not after
        // the complete call group. Only the selected message is the result.
        var answer_id: ?i64 = null;
        metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var message_start: u64 = 0;
        while (try metadata.next()) |record| {
            if (record.tag != .item) continue;
            defer message_start = metadata.offset;
            if (purpose != .assistant_response or record.kind != .message) continue;
            const content_id = try self.importAnswerProjection(binding, output, record, message_start, metadata.offset);
            if (output.answer_item_ordinal == record.ordinal and output.answer_length != 0) {
                const content = try self.readContentMetadata(content_id);
                if (content.length != output.answer_length or !std.mem.eql(u8, &content.digest, &output.answer_digest)) return error.OutputSourceChanged;
                answer_id = content_id;
            }
            const certify = try prepare(self.database, "UPDATE model_output_item SET message_content_id=?3 WHERE operation_id=?1 AND item_ordinal=?2");
            defer _ = c.sqlite3_finalize(certify);
            try bindU64(certify, 1, binding.operation_id);
            try bindU64(certify, 2, record.ordinal);
            try bindI64(certify, 3, content_id);
            try expectDone(certify);
            const insert = try prepare(self.database, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id) " ++
                "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+1,session_position,3,?3,?4,?6,?5 " ++
                "FROM model_output_item WHERE operation_id=?4 AND item_ordinal=?6");
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, session_ref.slice());
            try bindU64(insert, 3, binding.turn_id);
            try bindU64(insert, 4, binding.operation_id);
            try bindI64(insert, 5, content_id);
            try bindU64(insert, 6, record.ordinal);
            try expectDone(insert);
            if (c.sqlite3_changes(self.database) != 1) return error.CorruptOutputMetadata;
        }
        if (purpose == .assistant_response and output.answer_length != 0 and answer_id == null) return error.CorruptOutputMetadata;

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
                switch (c.sqlite3_step(duplicate_call)) {
                    c.SQLITE_DONE => {},
                    c.SQLITE_ROW => return error.InvalidProviderEnvelope,
                    else => return error.OutputReadFailed,
                }

                const call_facts = facts: {
                    var call_name = try output_format.EncodedStringReader.init(self.io, output.source, name);
                    var arguments = output_format.JsonStringSource{ .encoded = try output_format.EncodedStringReader.init(self.io, output.source, record) };
                    break :facts try tool_catalog.inspectCall(&call_name, name.decoded_length, &arguments);
                };
                const bash_arguments = call_facts.bash_arguments;
                const rejection_code = tool_catalog.classifyCall(call_facts.name, bash_arguments != null, frozen_tools);
                var rejection_buffer: [192]u8 = undefined;
                const rejection_text = if (rejection_code) |code| text: {
                    var rejected_name = try output_format.EncodedStringReader.init(self.io, output.source, name);
                    break :text try tool_catalog.rejectionResult(code, &rejected_name, name.decoded_length, name.content_digest, &rejection_buffer);
                } else null;
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
                        "rejection_code,rejection_content_id,acceptance_position,action_kind,description,field_metadata) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
                );
                defer _ = c.sqlite3_finalize(insert_call);
                try bindU64(insert_call, 1, binding.operation_id);
                try bindU64(insert_call, 2, imported_calls);
                try bindU64(insert_call, 3, record.ordinal);
                try bindI64(insert_call, 4, item_id_content_id);
                try bindI64(insert_call, 5, name_content_id);
                try bindI64(insert_call, 6, call_id_content_id);
                try bindI64(insert_call, 7, arguments_content_id);
                try bindOptionalText(insert_call, 8, if (rejection_code) |code| @tagName(code) else "");
                try bindNullableI64(insert_call, 9, rejection_content_id);
                try bindNullableU64(insert_call, 10, acceptance_position);
                if (rejection_code == null) try bindI64(insert_call, 11, 1) else try bindNullableI64(insert_call, 11, null);
                try bindOptionalText(insert_call, 12, if (bash_arguments) |*args| args.description.slice() else "");
                var field_metadata: [160]u8 = undefined;
                for ([_]OutputMetadataRecord{ item_id, name, call_id, record }, 0..) |field, index| {
                    std.mem.writeInt(u64, field_metadata[index * 40 ..][0..8], field.decoded_length, .little);
                    @memcpy(field_metadata[index * 40 + 8 ..][0..32], &field.content_digest);
                }
                try bindBlob(insert_call, 13, &field_metadata);
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

        const pending = try self.countPendingMessages(session_ref.slice());
        const output_fact = turn_policy.outputFact(purpose, output.call_count);
        const resolution_code = @tagName(turn_policy.Resolution.of(output_fact));
        {
            const update = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,model_evidence=?5,request_id=?8,usage_content_id=?9,output_item_count=?11,usage_tokens=?12 " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?10",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, binding.operation_id);
            try bindText(update, 2, resolution_code);
            try bindNullableI64(update, 3, answer_id);
            try bindOptionalText(update, 4, output.response_id.slice());
            try bindBlob(update, 5, output.model_evidence.slice());
            try bindOptionalText(update, 8, output.request_id.slice());
            try bindNullableI64(update, 9, usage_id);
            try bindU64(update, 10, binding.attempt_ordinal);
            try bindU64(update, 11, output.item_count);
            // Pressure saturates; every trigger it meets is an SQLite integer,
            // so clamping to the largest one preserves each decision.
            try bindNullableU64(update, 12, if (usage_tokens) |tokens| @min(tokens, std.math.maxInt(i64)) else null);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        if (turn_policy.completesTurn(output_fact, pending)) {
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
        if (turn_policy.completesTurn(output_fact, pending)) try self.recordTurnOutcomePosition(binding.turn_id);
        if (faults.output_commit) return error.InjectedOutputCommitFailure;
        try exec(self.database, "COMMIT");
    }

    const ContentSlot = struct { id: i64, existing: bool };

    fn contentSlot(self: *Store, digest: *const [32]u8, length: u64, private: bool) !ContentSlot {
        const find = try self.hot(.content_lookup);
        defer resetHot(find);
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

    fn importAnswerProjection(self: *Store, binding: AttemptBinding, output: *const ValidatedOutput, owner: OutputMetadataRecord, metadata_start: u64, metadata_end: u64) !i64 {
        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        metadata.offset = metadata_start;
        metadata.length = metadata_end;
        var hash = protocol.contentHasher();
        var decoded_length: u64 = 0;
        while (try metadata.next()) |record| {
            if (record.tag != .text) continue;
            if (owner.ordinal != record.ordinal or owner.kind != .message or record.start < owner.start or
                record.length > owner.length or record.start - owner.start > owner.length - record.length)
                return error.CorruptOutputMetadata;
            var text = try output_format.EncodedStringReader.init(self.io, output.source, record);
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var count: usize = 0;
            while (try text.next()) |byte| {
                buffer[count] = byte;
                count += 1;
                if (count == buffer.len) {
                    hash.update(&buffer);
                    decoded_length = try std.math.add(u64, decoded_length, count);
                    count = 0;
                }
            }
            hash.update(buffer[0..count]);
            decoded_length = try std.math.add(u64, decoded_length, count);
        }
        const digest = hash.finalResult();
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=0");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &digest);
        try bindU64(find, 2, decoded_length);
        const found = c.sqlite3_step(find);
        if (found != c.SQLITE_ROW and found != c.SQLITE_DONE) return error.ContentReadFailed;
        const existing = found == c.SQLITE_ROW;
        const answer_id = if (existing) c.sqlite3_column_int64(find, 0) else blk: {
            const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,NULL,0)");
            defer _ = c.sqlite3_finalize(insert);
            try bindBlob(insert, 1, &digest);
            try bindU64(insert, 2, decoded_length);
            try expectDone(insert);
            break :blk c.sqlite3_last_insert_rowid(self.database);
        };
        if (answer_id <= 0) return error.CorruptStore;
        var decoded_offset: u64 = 0;
        var part: u64 = 0;
        metadata.offset = metadata_start;
        while (try metadata.next()) |record| {
            if (record.tag != .text) continue;
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
        if (decoded_offset != decoded_length) return error.OutputSourceChanged;
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
        const access = try self.enter(.none);
        defer access.release();
        return access.finish(Ordinary.none, self.openContentIdentityLocked(reference, private));
    }

    fn openContentIdentityLocked(self: *Store, reference: ContentReference, private: bool) !ContentReader {
        const id = try self.resolveContentReference(reference, private);
        const raw = try self.contentIsRaw(id, reference.length);
        return .{ .store = self, .reference = reference, .content_id = id, .representation = if (raw) .raw else .{ .projection = .{} } };
    }

    fn contentIsRaw(self: *Store, content_id: i64, length: u64) !bool {
        var blob: ?*c.sqlite3_blob = null;
        const opened = c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob);
        if (opened == c.SQLITE_OK) {
            defer _ = c.sqlite3_blob_close(blob);
            return true;
        }
        const statement = try prepare(
            self.database,
            "SELECT payload IS NULL,(?2=0 OR EXISTS(SELECT 1 FROM answer_text_projection WHERE answer_content_id=?1)) " ++
                "FROM content WHERE content_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, content_id);
        try bindU64(statement, 2, length);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            c.sqlite3_column_int(statement, 0) != 1 or
            c.sqlite3_column_int(statement, 1) != 1) return error.CorruptStore;
        return false;
    }

    fn readOwnedContent(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !usize {
        if (destination.len > ContentReader.content_window_bytes) return error.WindowTooLarge;
        if (start > reader.reference.length) return error.RangeOutOfBounds;
        const wanted: usize = @intCast(@min(destination.len, reader.reference.length - start));
        if (wanted != 0) reader.prepareRead();
        const access = try self.enter(.none);
        defer access.release();
        try access.finish(Ordinary.none, self.readOwnedContentLocked(reader, start, destination[0..wanted]));
        return wanted;
    }

    /// Fills all of `destination` or fails, so no reader sees a short window.
    fn readOwnedContentLocked(self: *Store, reader: *ContentReader, start: u64, destination: []u8) !void {
        switch (reader.representation) {
            .raw => try self.readReaderBlob(reader, reader.content_id, start, reader.reference.length, destination),
            .projection => |*cursor| {
                std.debug.assert(start == cursor.decoded_position);
                var filled: usize = 0;
                while (filled < destination.len) {
                    if (cursor.pending_start < cursor.pending_end) {
                        const count = @min(destination.len - filled, cursor.pending_end - cursor.pending_start);
                        @memcpy(destination[filled..][0..count], cursor.pending[cursor.pending_start..][0..count]);
                        cursor.hash.update(destination[filled..][0..count]);
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
                    var source = ProjectedByteSource{ .store = self, .reader = reader, .cursor = cursor };
                    cursor.pending_end = try decodeOutputScalar(&source, &cursor.pending);
                    if (@import("builtin").is_test) _ = self.testing_content_work.decoded.fetchAdd(cursor.pending_end, .monotonic);
                    cursor.pending_start = 0;
                    cursor.part_decoded += cursor.pending_end;
                }
                if (cursor.decoded_position == reader.reference.length and
                    (cursor.pending_start != cursor.pending_end or cursor.encoded_position != cursor.encoded_end or
                        cursor.part_decoded != cursor.expected_decoded)) return error.CorruptStore;
                // Complete-stream consistency, not authentication of an earlier
                // range. Positioning discards participate in the same hash.
                if (cursor.decoded_position == reader.reference.length) {
                    // Empty text records are legitimate; any unvisited nonempty
                    // part contradicts EOF, even beyond empty rows/ordinal gaps.
                    const tail = try prepare(self.database, "SELECT EXISTS(SELECT 1 FROM answer_text_projection " ++
                        "WHERE answer_content_id=?1 AND part_ordinal>=?2 AND (encoded_length!=0 OR decoded_length!=0))");
                    defer _ = c.sqlite3_finalize(tail);
                    try bindI64(tail, 1, reader.content_id);
                    try bindU64(tail, 2, cursor.next_part);
                    if (c.sqlite3_step(tail) != c.SQLITE_ROW) return error.ContentReadFailed;
                    if (c.sqlite3_column_int(tail, 0) != 0) return error.CorruptStore;
                    // finalResult mutates: preserve state for repeated EOF reads.
                    var hash = cursor.hash;
                    if (!std.mem.eql(u8, &hash.finalResult(), &reader.reference.digest)) return error.CorruptStore;
                }
            },
        }
    }

    // Each reader owns its copied source window. Neither interleaved readers
    // nor another row at the same offset can borrow those bytes. Access still
    // owns and closes the SQLite handle before callbacks or yields.
    fn readReaderBlob(self: *Store, reader: *ContentReader, content_id: i64, start: u64, end: u64, destination: []u8) !void {
        if (destination.len == 0) return;
        const window = reader.prefetch orelse return self.readBlob(content_id, start, destination);
        var filled: usize = 0;
        while (filled < destination.len) {
            const position = start + filled;
            if (reader.prefetch_source != content_id or position < reader.prefetch_start or
                position >= reader.prefetch_start + reader.prefetch_length)
            {
                reader.prefetch_length = 0;
                const wanted: usize = @intCast(@min(window.len, end - position));
                try self.readBlob(content_id, position, window[0..wanted]);
                reader.prefetch_source = content_id;
                reader.prefetch_start = position;
                reader.prefetch_length = wanted;
            }
            const offset: usize = @intCast(position - reader.prefetch_start);
            const count = @min(destination.len - filled, reader.prefetch_length - offset);
            @memcpy(destination[filled..][0..count], window[offset..][0..count]);
            filled += count;
        }
    }

    // Called only inside one Access. Reuse avoids repeated overflow-page walks
    // within synchronous work, never across callbacks or preparation yields.
    fn readBlob(self: *Store, content_id: i64, start: u64, destination: []u8) !void {
        if (destination.len == 0) return;
        if (start > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
        const blob = &self.read_blob;
        if (blob.handle == null) {
            // A failed open leaves the handle null.
            if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob.handle) != c.SQLITE_OK) return error.ContentReadFailed;
            blob.content_id = content_id;
        } else if (blob.content_id != content_id) {
            // A failed reopen aborts the handle; close remains its release.
            if (c.sqlite3_blob_reopen(blob.handle, content_id) != c.SQLITE_OK) return error.ContentReadFailed;
            blob.content_id = content_id;
        }
        if (c.sqlite3_blob_read(blob.handle, destination.ptr, @intCast(destination.len), @intCast(start)) != c.SQLITE_OK) return error.ContentReadFailed;
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

    fn Replay(comptime Rejection: type) type {
        return union(enum) {
            /// No saved command; the caller's transaction stays open.
            fresh,
            conflict,
            accepted: ExistingCommand,
            rejected: Rejection,
        };
    }

    /// Classifies a keyed command against its saved answer. Any saved answer
    /// ends the caller's transaction before it returns.
    fn classifyReplay(
        self: *Store,
        comptime Rejection: type,
        kind: CommandKind,
        key: []const u8,
        target: []const u8,
        digest: *const [32]u8,
    ) !Replay(Rejection) {
        const existing = try self.readExistingCommand(key) orelse return .fresh;
        try exec(self.database, "ROLLBACK");
        if (existing.kind != kind or (!(kind == .configure and target.len == 0) and !existing.target.eql(target)) or
            !std.mem.eql(u8, &existing.digest, digest)) return .conflict;
        if (existing.accepted) return .{ .accepted = existing };
        return .{ .rejected = std.meta.stringToEnum(Rejection, existing.code.slice()) orelse
            return error.CorruptStore };
    }

    fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
        const statement = try self.hot(.existing_command);
        defer resetHot(statement);
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

    fn sessionStopCompletion(self: *Store, selection: SessionStopSelection) !SessionStopCompletion {
        const turn_id = selection.selected_turn_id orelse return .completed;
        return if (try self.turnIsComplete(turn_id)) .completed else .pending;
    }

    fn readSession(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
        const statement = try self.hot(.session);
        defer resetHot(statement);
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
        if (tools < 0 or tools > tool_catalog.toolBit(.bash)) return error.CorruptStore;
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
        current.provider = try readProvider(statement, 8);
        current.compaction_trigger = try readNullableTokens(statement, 9, false);
        current.output_reservation = try readNullableTokens(statement, 10, true);
        return current;
    }

    fn insertSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !bool {
        const statement = try prepare(self.database, "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position,provider,compaction_trigger,output_reservation) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT(session_ref) DO NOTHING");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
        return c.sqlite3_changes(self.database) == 1;
    }

    fn updateSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "UPDATE session SET workspace=?2,model=?3,instructions_content_id=?4,tools_mask=?5,permission_mode=?6,output_schema_content_id=?7,revision=?8,next_position=?9,provider=?10,compaction_trigger=?11,output_reservation=?12 WHERE session_ref=?1");
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
        const statement = try prepare(self.database, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id,provider,compaction_trigger,output_reservation) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)");
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
        try bindText(statement, 11, @tagName(current.provider));
        try bindNullableU64(statement, 12, current.compaction_trigger);
        try bindNullableU64(statement, 13, current.output_reservation);
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
        sender: ?[]const u8,
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
        const position = try self.claimSessionPosition(session_ref);
        // The sender's own sequence orders the send among its other facts.
        const sender_position: ?u64 = if (sender) |ref| try self.claimSessionPosition(ref) else null;
        const statement = try prepare(self.database, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,admitted_at,sender_session_ref,sender_position) VALUES(?1,?2,?3,?4,?5,unixepoch(),?6,?7)");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, admission_id);
        try bindText(statement, 2, session_ref);
        try bindText(statement, 3, command_key);
        try bindI64(statement, 4, content_id);
        try bindU64(statement, 5, position);
        if (sender) |ref| try bindText(statement, 6, ref) else try bindNullableI64(statement, 6, null);
        try bindNullableU64(statement, 7, sender_position);
        try expectDone(statement);
        return admission_id;
    }

    // Called only inside the owning write transaction; no separate frontier.
    fn claimSessionPosition(self: *Store, session: []const u8) !u64 {
        const statement = try prepare(self.database, "UPDATE session SET next_position=next_position+1 " ++
            "WHERE session_ref=?1 AND next_position<9223372036854775807 RETURNING next_position-1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SessionPositionExhausted;
        const position = try readNullablePositiveI64(statement, 0) orelse return error.CorruptStore;
        try expectDone(statement);
        return @intCast(position);
    }

    fn recordTurnOutcomePosition(self: *Store, turn_id: u64) !void {
        const select = try prepare(self.database, "SELECT session_ref FROM turn WHERE turn_id=?1 AND outcome_code IS NOT NULL AND outcome_position IS NULL");
        defer _ = c.sqlite3_finalize(select);
        try bindU64(select, 1, turn_id);
        if (c.sqlite3_step(select) != c.SQLITE_ROW) return error.CorruptStore;
        var session: protocol.Bounded(128) = .{};
        try readText(select, 0, &session);
        const position = try self.claimSessionPosition(session.slice());
        const update = try prepare(self.database, "UPDATE turn SET outcome_position=?2 WHERE turn_id=?1 AND outcome_position IS NULL");
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, turn_id);
        try bindU64(update, 2, position);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.CorruptStore;
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
        const insert_result = c.sqlite3_step(insert);
        if (insert_result == c.SQLITE_FULL) return error.CanonicalStorageFull;
        if (insert_result != c.SQLITE_DONE) return error.StatementFailed;
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

    const ContentMetadata = struct { length: u64, digest: [32]u8, private: bool };

    fn readContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
        const statement = try self.hot(.content_metadata);
        defer resetHot(statement);
        try bindI64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const length = c.sqlite3_column_int64(statement, 0);
        if (length < 0) return error.CorruptStore;
        return .{ .length = @intCast(length), .digest = try readDigest(statement, 1), .private = c.sqlite3_column_int(statement, 2) != 0 };
    }

    // Every public metadata/byte route validates the exposed content, never
    // its projection backing: raw provider source rows are legitimately private.
    fn readPublicContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
        const metadata = try self.readContentMetadata(content_id);
        if (metadata.private) return error.CorruptStore;
        return metadata;
    }

    fn resolveContentReference(self: *Store, reference: ContentReference, private: bool) !i64 {
        const statement = try self.hot(.content_lookup);
        defer resetHot(statement);
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

// Large streaming readers own one bounded heap window, never an inline
// population/worker-stack multiplier. Synchronous locked work needs no heap
// prefetch: it already reuses SQLite's overflow-page index for the whole call.
const content_prefetch_bytes = 128 * 1024;
const projection_read_window_bytes = 4 * 1024;

// One cursor per open reader, independent of answer size and part count.
const ProjectionCursor = struct {
    hash: @TypeOf(protocol.contentHasher()) = protocol.contentHasher(),
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
    reader: *ContentReader,
    cursor: *ProjectionCursor,

    pub fn take(self: *ProjectedByteSource) !u8 {
        const cursor = self.cursor;
        if (cursor.encoded_position == cursor.encoded_end) return error.IncompleteJsonString;
        if (cursor.buffer_length == 0 or cursor.encoded_position >= cursor.buffer_start + cursor.buffer_length) {
            cursor.buffer_start = cursor.encoded_position;
            cursor.buffer_length = @intCast(@min(cursor.encoded_end - cursor.encoded_position, cursor.buffer.len));
            try self.store.readReaderBlob(self.reader, cursor.source_id, cursor.buffer_start, cursor.encoded_end, cursor.buffer[0..cursor.buffer_length]);
        }
        const byte = cursor.buffer[@intCast(cursor.encoded_position - cursor.buffer_start)];
        cursor.encoded_position += 1;
        return byte;
    }
};

const decodeOutputScalar = output_format.decodeScalar;

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
        \\ private INTEGER NOT NULL CHECK(private IN (0,1) AND (private=0 OR payload IS NOT NULL)),
        \\ payload BLOB CHECK(payload IS NULL OR length(payload)=byte_length),
        \\ UNIQUE(digest,byte_length,private)
        \\) STRICT;
        \\CREATE TABLE session(
        \\ session_ref TEXT PRIMARY KEY CHECK(length(session_ref)=6 AND length(CAST(session_ref AS BLOB))=6 AND session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*'),
        \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
        \\ provider TEXT NOT NULL,
        \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
    ++ std.fmt.comptimePrint(" tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND {d}),\n", .{comptime tool_catalog.toolBit(.bash)}) ++
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
        \\ next_position INTEGER NOT NULL CHECK(next_position>0)
        \\) STRICT;
        \\CREATE INDEX session_workspace_list ON session(workspace);
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
        \\ provider TEXT NOT NULL,
        \\ model TEXT NOT NULL,
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
    ++ std.fmt.comptimePrint(" tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND {d}),\n", .{comptime tool_catalog.toolBit(.bash)}) ++
        \\ permission_mode INTEGER NOT NULL,
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
        \\ PRIMARY KEY(session_ref,revision)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE message_admission(
        \\ admission_id INTEGER PRIMARY KEY CHECK(admission_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ admission_position INTEGER CHECK(admission_position>0),
        \\ turn_id INTEGER REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ admitted_at INTEGER NOT NULL CHECK(admitted_at>0),
        \\ sender_session_ref TEXT REFERENCES session(session_ref),
        \\ sender_position INTEGER CHECK(sender_position>0),
        \\ CHECK((sender_session_ref IS NULL)=(sender_position IS NULL))
        \\) STRICT;
        \\CREATE UNIQUE INDEX message_admission_sent ON message_admission(sender_session_ref,sender_position) WHERE sender_session_ref IS NOT NULL;
        \\CREATE TABLE sent_rejection(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ sender_session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ sender_position INTEGER NOT NULL CHECK(sender_position>0),
        \\ UNIQUE(sender_session_ref,sender_position)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE turn(
        \\ turn_id INTEGER PRIMARY KEY CHECK(turn_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ first_admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id) DEFERRABLE INITIALLY DEFERRED,
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>=first_admission_id),
        \\ operation_id INTEGER NOT NULL,
        \\ outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96),
        \\ outcome_content_id INTEGER REFERENCES content(content_id),
        \\ outcome_position INTEGER CHECK(outcome_position>0)
        \\) STRICT;
        \\CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
        \\CREATE TABLE session_stop(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ selected_turn_id INTEGER REFERENCES turn(turn_id),
        \\ position INTEGER CHECK(position>0),
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
        \\ purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),
        \\ output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ allowance_used INTEGER NOT NULL CHECK(allowance_used BETWEEN 1 AND 4),
        \\ uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
        \\ retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
        \\ last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),
        \\ model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),
        \\ request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),
        \\ usage_content_id INTEGER REFERENCES content(content_id),
        \\ usage_tokens INTEGER CHECK(usage_tokens IS NULL OR (usage_tokens>=0 AND usage_content_id IS NOT NULL)),
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
        \\ source_item_ordinal INTEGER CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,entry_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ UNIQUE(session_ref,source_revision),
        \\ FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),
        \\ FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal),
        \\ CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),
        \\ CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_output_item(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ session_ref TEXT NOT NULL,
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ item_kind INTEGER NOT NULL CHECK(item_kind IN (1,2,3,4)),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ message_content_id INTEGER REFERENCES content(content_id) CHECK(message_content_id IS NULL OR item_kind=2),
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
        \\ description TEXT CHECK(description IS NULL OR length(CAST(description AS BLOB)) BETWEEN 1 AND 100),
        \\ field_metadata BLOB NOT NULL CHECK(length(field_metadata)=160),
        \\ rejection_code TEXT CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments')),
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
        \\ sender_handle TEXT CHECK(sender_handle IS NULL OR (length(sender_handle)=32 AND sender_handle NOT GLOB '*[^0-9a-f]*')),
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
        \\CREATE INDEX session_stop_turn ON session_stop(selected_turn_id);
        \\CREATE INDEX action_operation_session_order ON action_operation(session_ref,action_id);
        \\CREATE UNIQUE INDEX action_operation_sender_handle ON action_operation(sender_handle) WHERE sender_handle IS NOT NULL;
        \\CREATE INDEX action_operation_acceptance ON action_operation(session_ref,acceptance_position);
        \\CREATE INDEX action_operation_executable ON action_operation(action_id) WHERE permission_state=1 AND resolution_code IS NULL AND attempt_ordinal=0;
        \\CREATE INDEX action_operation_unresolved_attempt ON action_operation(action_id) WHERE resolution_code IS NULL AND attempt_ordinal=1;
        \\CREATE INDEX model_tool_call_rejections ON model_tool_call(operation_id,call_ordinal) WHERE rejection_code IS NOT NULL;
        \\
    ++ "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND " ++
        retry_allowance_open_sql ++ ";\n" ++
        std.fmt.comptimePrint("CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND uncertain=1 AND allowance_used={d} AND retry_due_at_ms=0;\n", .{retry_policy.maximum_attempts}) ++
        \\CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id);
        \\CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id);
        \\
    ++ "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE " ++
        resolutionIn("resolution_code", &turn_policy.accepted) ++ ";\n" ++
        "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND " ++
        resolutionIs("resolution_code", .compacted) ++ ";\n" ++
        \\CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
        \\CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
        \\CREATE INDEX model_output_compaction_anchor ON model_output_item(operation_id,item_ordinal) WHERE item_kind=4;
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
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','sent_rejection','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_tool_call','action_operation','permission_decision_command','answer_text_projection')) OR " ++
                "(type='index' AND ((sql IS NULL AND tbl_name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','sent_rejection','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_tool_call','action_operation','permission_decision_command','answer_text_projection')) OR " ++
                "(sql IS NOT NULL AND name NOT IN ('session_workspace_list','message_admission_session_order','message_admission_pending','message_admission_session_pending','message_admission_sent','session_stop_exclusion','session_stop_turn','action_operation_session_order','action_operation_sender_handle','action_operation_acceptance','action_operation_executable','action_operation_unresolved_attempt','model_tool_call_rejections','turn_one_active_per_session','model_operation_retry_due','model_operation_retry_exhausted','model_operation_session_history','model_operation_turn_history','model_operation_context_history','model_operation_compaction_bases','conversation_entry_history','model_output_history','model_output_compaction_anchor','turn_session_latest')))) OR " ++
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

fn readUnixMilliseconds(io: std.Io) !i64 {
    const value = std.Io.Clock.real.now(io).toMilliseconds();
    if (value <= 0) return error.ClockReadFailed;
    return value;
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
    try bindText(statement, 10, @tagName(current.provider));
    try bindNullableU64(statement, 11, current.compaction_trigger);
    try bindNullableU64(statement, 12, current.output_reservation);
}

fn readProvider(statement: *c.sqlite3_stmt, column: c_int) !protocol.Provider {
    var name: protocol.Bounded(protocol.max_provider_bytes) = .{};
    try readText(statement, column, &name);
    return std.meta.stringToEnum(protocol.Provider, name.slice()) orelse error.CorruptStore;
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
    // Callers finalize these short-lived statements; allow SQLite lookaside.
    if (c.sqlite3_prepare_v3(database, sql, -1, 0, &statement, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    return statement orelse error.StatementPrepareFailed;
}

/// The ten statements measured most frequent under STREAM100 after the
/// commit-generation skips; every other statement stays short-lived.
const HotStatement = enum {
    operation_supersession,
    current_attempt,
    content_metadata,
    content_lookup,
    blocked_tool_calls,
    session,
    executable_action,
    runnable_probe,
    tool_continuation_probe,
    existing_command,

    fn sql(self: HotStatement) [:0]const u8 {
        return switch (self) {
            .operation_supersession => "SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation WHERE operation_id=?1",
            .current_attempt => "SELECT turn_id,attempt_ordinal,resolution_code,interrupted_by_command_key " ++
                "FROM model_operation WHERE operation_id=?1",
            .content_metadata => "SELECT byte_length,digest,private FROM content WHERE content_id=?1",
            .content_lookup => "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3",
            .blocked_tool_calls => "SELECT operation.operation_id FROM turn active JOIN model_operation operation " ++
                "ON operation.operation_id=active.operation_id WHERE active.outcome_code IS NULL " ++
                "AND " ++ resolutionIs("operation.resolution_code", .tool_proposals) ++ " ORDER BY operation.operation_id",
            .session => "SELECT workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position,provider,compaction_trigger,output_reservation FROM session WHERE session_ref=?1",
            .executable_action => "SELECT action.action_id,action.parent_operation_id,operation.turn_id,action.bash_timeout_override_ms FROM action_operation action " ++
                "INDEXED BY action_operation_executable JOIN model_operation operation " ++
                "ON operation.operation_id=action.parent_operation_id JOIN turn active ON active.turn_id=operation.turn_id " ++
                "WHERE action.permission_state=1 AND action.resolution_code IS NULL AND action.attempt_ordinal=0 " ++
                "AND active.outcome_code IS NULL AND NOT EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.selected_turn_id=active.turn_id) " ++
                "ORDER BY action.action_id LIMIT 1",
            .runnable_probe => runnable_probe_sql,
            .tool_continuation_probe => tool_continuation_selection_sql,
            .existing_command => "SELECT kind,target,input_digest,accepted,code,revision,created,primary_content_id FROM core_command WHERE command_key=?1",
        };
    }
};

fn resetHot(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(statement);
    _ = c.sqlite3_clear_bindings(statement);
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

fn readNullableTokens(statement: *c.sqlite3_stmt, index: c_int, allow_zero: bool) !?u64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_type(statement, index) != c.SQLITE_INTEGER) return error.CorruptStore;
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0 or (!allow_zero and value == 0)) return error.CorruptStore;
    return @intCast(value);
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
    var storage = try testingStore(&tmp, io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(io, &workspace_buffer);
    var first = try completeConfiguration("first-creation", "", workspace, "model-a");
    const first_reply = storage.configure(&first, true, .{});
    try std.testing.expect(first_reply == .accepted);
    const a = first_reply.accepted;
    try std.testing.expect(a.created and !a.replayed);
    try std.testing.expectEqualStrings("000000", a.session.slice());
    var second = try completeConfiguration("second-creation", "", workspace, "model-b");
    const second_reply = storage.configure(&second, true, .{});
    try std.testing.expect(second_reply == .accepted);
    const b = second_reply.accepted;
    try std.testing.expect(b.created and !b.replayed);
    try std.testing.expectEqualStrings("zzzzzz", b.session.slice());
    try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
    try std.testing.expectEqualStrings("model-a", (try storage.readSession(a.session.slice())).?.model.slice());
    try std.testing.expectEqualStrings("model-b", (try storage.readSession(b.session.slice())).?.model.slice());
    const replay = storage.configure(&second, true, .{}).accepted;
    try std.testing.expect(replay.replayed and replay.created);
    try std.testing.expectEqualStrings(b.session.slice(), replay.session.slice());
    try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
    const current = (try storage.readSession(a.session.slice())).?;
    for ([_][]const u8{ "short", "1234567", "K7m2qx", "k7m2qi", "k7m\x00qx" }) |invalid| {
        try std.testing.expectError(error.StatementFailed, storage.insertSession(invalid, &current));
    }
    var unknown = try completeConfiguration("unknown-update", "k7m2qx", workspace, "model-c");
    try std.testing.expectEqual(ConfigurationRejection.unknown_session, storage.configure(&unknown, true, .{}).rejected.code);
    try std.testing.expect(try storage.readSession("k7m2qx") == null);
    for ([_][]const u8{ "old/name", "K7m2qx", "k7m2qi", "k7\x00qx" }, 0..) |invalid, index| {
        var key: [32]u8 = undefined;
        var bad = try completeConfiguration(try std.fmt.bufPrint(&key, "invalid-id-{d}", .{index}), invalid, workspace, "model-c");
        try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, storage.configure(&bad, true, .{}).rejected.code);
    }
    try std.testing.expectEqual(@as(usize, 3), Entropy.draws);
    try std.testing.expect(!storage.isFenced());
}

test "Store distinguishes noncanonical Session references from canonical unknown messages and controls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
        const message_reply = storage.submitMessage(&message, .{});
        try std.testing.expect(message_reply == .rejected);
        try std.testing.expectEqual(if (canonical_unknown) MessageRejection.unknown_session else .invalid_session_reference, message_reply.rejected.code);
        const message_replay = storage.submitMessage(&message, .{});
        try std.testing.expect(message_replay == .rejected and message_replay.rejected.replayed);
        try std.testing.expectEqual(message_reply.rejected.code, message_replay.rejected.code);

        var stop = try completeSessionStop(try std.fmt.bufPrint(&key, "reference-stop-{d}", .{index}), reference);
        const stop_reply = storage.stopSession(&stop, .{});
        try std.testing.expect(stop_reply == .rejected);
        try std.testing.expectEqual(if (canonical_unknown) SessionStopRejection.unknown_session else .invalid_session_reference, stop_reply.rejected.code);
        const stop_replay = storage.stopSession(&stop, .{});
        try std.testing.expect(stop_replay == .rejected and stop_replay.rejected.replayed);
        try std.testing.expectEqual(stop_reply.rejected.code, stop_replay.rejected.code);

        var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
        try interrupt.key.set(try std.fmt.bufPrint(&key, "reference-interrupt-{d}", .{index}));
        try interrupt.session.set(reference);
        const interrupt_reply = storage.interruptModel(&interrupt, .{});
        try std.testing.expect(interrupt_reply == .rejected);
        try std.testing.expectEqual(if (canonical_unknown) ModelInterruptionRejection.unknown_session else .invalid_session_reference, interrupt_reply.rejected.code);
        const interrupt_replay = storage.interruptModel(&interrupt, .{});
        try std.testing.expect(interrupt_replay == .rejected and interrupt_replay.rejected.replayed);
        try std.testing.expectEqual(interrupt_reply.rejected.code, interrupt_replay.rejected.code);

        var permission: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
        try permission.key.set(try std.fmt.bufPrint(&key, "reference-permission-{d}", .{index}));
        try permission.session.set(reference);
        const permission_reply = storage.decidePermission(&permission, .{});
        try std.testing.expect(permission_reply == .rejected);
        try std.testing.expectEqual(if (canonical_unknown) PermissionDecisionRejection.unknown_session else .invalid_session_reference, permission_reply.rejected.code);
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
    try std.testing.expectError(error.StoreOpenFailed, Store.open(std.testing.io, database, root));
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
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

fn querySessionU64(database: *c.sqlite3, sql: [:0]const u8, session: []const u8) !u64 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, session);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

fn execSessionSql(database: *c.sqlite3, sql: [:0]const u8, session: []const u8) !void {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, session);
    try expectDone(statement);
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
    const page = try storage.activityPage(request);
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
    const reply = storage.configure(&command, true, .{});
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
    const reply = storage.configure(&command, true, .{});
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
    try std.testing.expect(storage.submitMessage(&command, .{}) == .accepted);
}

const TestingCall = struct {
    item_id: []const u8,
    name: []const u8,
    encoded_call_id: []const u8,
    decoded_call_id: []const u8,
    encoded_arguments: []const u8,
    decoded_arguments: []const u8,
    controls: []const u8 = "",
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
        call.encoded_call_id.len + call.encoded_arguments.len + call.controls.len;
    const source_buffer = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(source_buffer);
    var source_writer = std.Io.Writer.fixed(source_buffer);
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
            .limit = try std.math.mul(u64, calls.len, 5 * output_metadata_record_bytes) + output_metadata_record_bytes,
        },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    var offset: u64 = 0;
    for (calls, 0..) |call, index| {
        const item_start = offset;
        try source_writer.writeAll("{\"type\":\"function_call\",\"id\":");
        const id_start = source_writer.end + 1;
        try std.json.Stringify.value(call.item_id, .{}, &source_writer);
        try metadata.append(.{
            .tag = .item_id,
            .kind = .function_call,
            .ordinal = index,
            .start = id_start,
            .length = source_writer.end - id_start - 1,
            .decoded_length = call.item_id.len,
            .content_digest = protocol.contentDigest(call.item_id),
        });
        try source_writer.writeAll(",\"name\":");
        const name_start = source_writer.end + 1;
        try std.json.Stringify.value(call.name, .{}, &source_writer);
        try metadata.append(.{
            .tag = .name,
            .kind = .function_call,
            .ordinal = index,
            .start = name_start,
            .length = source_writer.end - name_start - 1,
            .decoded_length = call.name.len,
            .content_digest = protocol.contentDigest(call.name),
        });
        try source_writer.writeAll(",\"call_id\":\"");
        offset = source_writer.end;
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
        try source_writer.writeAll("\",\"arguments\":\"");
        offset = source_writer.end;
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
        try source_writer.writeAll("\"");
        try source_writer.writeAll(call.controls);
        try source_writer.writeAll("}");
        offset = source_writer.end;
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
    if (usage_json) |bytes| {
        try source_writer.writeAll(bytes);
    }
    const source_bytes = source_writer.buffered();
    var source_name: [64]u8 = undefined;
    const source = try tmp.dir.createFile(std.testing.io, try std.fmt.bufPrint(&source_name, "{s}-source", .{file_prefix}), .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    if (usage_json) |bytes| {
        const start = source_bytes.len - bytes.len;
        try metadata.append(.{
            .tag = .usage,
            .start = start,
            .length = bytes.len,
            .content_digest = protocol.contentDigest(bytes),
            .usage_tokens = try provider_output.usagePressure(std.testing.io, source, start, bytes.len),
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

fn testingSessionList(storage: *Store, tmp: *std.testing.TmpDir, request: protocol.ListSessions, used: *std.atomic.Value(u64), request_number: u64) ![]u8 {
    var root: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &root);
    var report = try storage.captureSessionList(request, .{
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expect(storage.configure(&unrelated, true, .{}) == .rejected);
    const empty = try testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}", empty);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

    var ids: [10]protocol.Bounded(protocol.max_session_bytes) = undefined;
    for (&ids, 0..) |*id, index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "list-config-{d}", .{index});
        var config = try completeConfiguration(key, "", workspace, "model\nwith-control");
        if (index == 3) try config.configuration.workspace.value.set(other);
        const configured = storage.configure(&config, true, .{});
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
    try std.testing.expectError(error.InvalidCursor, storage.captureSessionList(.{ .after = 2, .ceiling = 1 }, undefined));
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
    try std.testing.expect(storage.configure(&later, true, .{}) == .accepted);
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
    var held = try storage.captureSessionList(.{}, .{
        .scratch_path = scratch_path[0..scratch_length],
        .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
        .request_number = 5,
    });
    try std.testing.expect(used.load(.acquire) > 0);
    var concurrent = try completeConfiguration("list-concurrent", "", workspace, "model");
    try std.testing.expect(storage.configure(&concurrent, true, .{}) == .accepted);
    held.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.ReportScratchExhausted, storage.captureSessionList(.{}, .{
        .scratch_path = scratch_path[0..scratch_length],
        .scratch_budget = .{ .used = &used, .limit = 16 },
        .request_number = 6,
    }));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(!storage.isFenced());
}

test "Session list capture and cursor storage stay page bounded as dormant Sessions grow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var used = std.atomic.Value(u64).init(0);
    var first_length: usize = 0;
    for (0..1000) |i| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "dormant-key-{d}", .{i});
        var config = try completeConfiguration(key, "", workspace, "model");
        try std.testing.expect(storage.configure(&config, true, .{}) == .accepted);
        if (i == 99 or i == 999) {
            const bytes = try testingSessionList(&storage, &tmp, .{}, &used, i + 1);
            defer std.testing.allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(@as(usize, protocol.session_list_page_size), parsed.value.object.get("sessions").?.array.items.len);
            if (i == 99) first_length = bytes.len else try std.testing.expect(bytes.len <= first_length + 1);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        }
    }
}

test "Current excludes history while Full exposes exact closed Session inventory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "selection-config");

    for (0..12) |index| {
        var file: [48]u8 = undefined;
        var key: [48]u8 = undefined;
        try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file, "selection-file-{d}", .{index}), try std.fmt.bufPrint(&key, "selection-message-{d}", .{index}), session.slice(), "input");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    }
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
    try std.testing.expectEqual(MessageProgress.Status.runnable, (try storage.observeCommand("selection-next")).message.?.progress.?.status);
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
    try std.testing.expectEqual(MessageProgress.Status.in_flight, queued.progress.?.status);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "empty-key-config");
    try submitTestMessage(&storage, &tmp, "empty-key-file", "", session.slice(), "input");
    try std.testing.expectEqual(MessageProgress.Status.runnable, (try storage.observeCommand("")).message.?.progress.?.status);
    {
        const bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer report.deinit();
        try std.testing.expectEqualStrings("", report.value.object.get("selected_message").?.string);
    }
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(MessageProgress.Status.in_flight, (try storage.observeCommand("")).message.?.progress.?.status);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
        try std.testing.expectEqual(ModelInterruptionRejection.invalid_target, rejected.rejected.code);
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
    try std.testing.expect((try storage.inspectSession(session.slice())).found);
}

test "Full revisions own repeated content once and render semantic settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    const created_session_0_reply = storage.configure(&initial, true, .{});
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
    try std.testing.expect(storage.configure(&second, true, .{}) == .accepted);

    var third: protocol.ConfigureCommand = .{};
    try third.key.set("revision-owner-3");
    try third.session.set(created_session_0.slice());
    third.configuration.tools.state = .value;
    third.configuration.tools.count = 1;
    third.configuration.tools.values[0] = .bash;
    third.configuration.output_schema = try testingBytesContent(&tmp, "revision-owner-schema-a-again", schema_a);
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&third, true, .{}) == .accepted);

    var fourth: protocol.ConfigureCommand = .{};
    try fourth.key.set("revision-owner-4");
    try fourth.session.set(created_session_0.slice());
    fourth.configuration.tools.state = .value;
    fourth.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&fourth, true, .{}) == .accepted);

    var fifth: protocol.ConfigureCommand = .{};
    try fifth.key.set("revision-owner-5");
    try fifth.session.set(created_session_0.slice());
    fifth.configuration.instructions = try testingBytesContent(&tmp, "revision-owner-instructions-schema-a", schema_a);
    defer fifth.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&fifth, true, .{}) == .accepted);

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
    var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const session = try configureTestSessionAsk(&storage, "action-config");
    try submitTestMessage(&storage, &tmp, "action-message", "action-message", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "action-metadata");

    var public_request = protocol.ConversationPage{};
    try public_request.session.set(session.slice());
    const proposed = try storage.publicConversationPage(public_request);
    try std.testing.expectEqual(@as(usize, 1), proposed.count);
    try std.testing.expect(proposed.items[0].kind == .user);
    // The provider's complete proposal, including its call arguments, is not
    // addressable as a public content position.
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(.{
        .session = public_request.session,
        .position = proposed.end,
    }));

    const first_action_id = first: {
        const report_bytes = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
        defer std.testing.allocator.free(report_bytes);
        try std.testing.expect(std.mem.indexOf(u8, report_bytes, "\"work\":{\"status\":\"waiting_for_permission\"") != null);
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
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPage(public_request)).count);
    try std.testing.expect(storage.decidePermission(&deny, .{}).accepted.replayed);
    deny.action_id += 1;
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .conflict);

    var permission_update: protocol.ConfigureCommand = .{};
    try permission_update.key.set("action-bypass");
    try permission_update.session.set(session.slice());
    permission_update.configuration.permission_mode.state = .value;
    try permission_update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&permission_update, true, .{}) == .accepted);
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
    try std.testing.expectEqual(SessionStopCompletion.completed, action_stop.accepted.completion);
    const settled_page = try storage.publicConversationPage(public_request);
    try std.testing.expectEqual(@as(usize, 3), settled_page.count);
    try std.testing.expect(settled_page.items[0].kind == .tool_result);
    try std.testing.expectEqual(settled_page.items[0].position, settled_page.items[1].position);
    try std.testing.expectEqual(@as(u64, 2), settled_page.items[0].ordinal);
    try std.testing.expectEqual(@as(u64, 1), settled_page.items[1].ordinal);
    try std.testing.expectEqualStrings("Run second command", settled_page.items[0].presentation.?.description.?.slice());
    try std.testing.expectEqualStrings("Run first command", settled_page.items[1].presentation.?.description.?.slice());
    try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, settled_page.items[1].presentation.?.code);
    for (settled_page.items[0..2]) |item| try std.testing.expectEqual(item.position, item.presentation.?.publication_position.?);
    const activity = try storage.activityPage(.{ .session = public_request.session, .direction = .backward });
    var results: usize = 0;
    for (activity.items[0..activity.count]) |item| if (item.value == .tool_result) {
        const p = item.value.tool_result.presentation;
        try std.testing.expectEqual(item.position, p.publication_position.?);
        try std.testing.expectEqualStrings(if (item.ordinal == 1) "Run first command" else "Run second command", p.description.?.slice());
        results += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), results);
    var result_reader = try storage.openPublicConversationContent(.{
        .session = public_request.session,
        .position = settled_page.items[0].position,
        .ordinal = 2,
    });
    result_reader.close();
    var stale: protocol.PermissionDecisionCommand = .{ .action_id = second_action_id };
    try stale.key.set("stale-denial");
    try stale.session.set(session.slice());
    stale.decision = .allow_once;
    const rejected = storage.decidePermission(&stale, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(PermissionDecisionRejection.action_not_pending, rejected.rejected.code);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(PermissionDecisionRejection.action_not_pending, fresh.rejected.code);

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("allow-mode-change");
    try update.session.set(session.slice());
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    try std.testing.expect(storage.configure(&update, true, .{}) == .accepted);
    for (0..2) |pass| {
        if (pass == 1) {
            try storage.close();
            storage_open = false;
            storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1), action.attempt_ordinal);
    try std.testing.expect(storage.decidePermission(&allow, .{}).accepted.replayed);
    // The admitted Action cannot be reissued; its unapproved sibling remains pending.
    try std.testing.expect((try storage.admitNextActionAttempt(300_000, .{})) == null);
}

test "Current reports progress alongside an actionable sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqualStrings("waiting_for_permission", parsed.value.object.get("work").?.object.get("status").?.string);
    try pageWorkAgrees(&storage, parsed.value, action_id);
    var allow: protocol.PermissionDecisionCommand = .{ .action_id = action_id, .decision = .allow_once };
    try allow.key.set("mixed-allow");
    try allow.session.set(session.slice());
    try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
    const after = try testingSessionReport(&storage, &tmp, session.slice(), 1024 * 1024);
    defer std.testing.allocator.free(after);
    var mixed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after, .{});
    defer mixed.deinit();
    try std.testing.expectEqualStrings("in_flight", mixed.value.object.get("work").?.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), mixed.value.object.get("actionable_permissions").?.array.items.len);
    const message = (try storage.observeCommand("mixed-message")).message.?;
    try std.testing.expectEqualStrings("processing", @tagName(message.queue.?.state));
    try std.testing.expectEqual(MessageProgress.Status.in_flight, message.progress.?.status);
    try std.testing.expectEqual(action_id + 1, message.progress.?.action_id.?);
    try pageWorkAgrees(&storage, mixed.value, action_id + 1);
}

/// The activity page carries the work Current reports and the first
/// actionable Action, from its own read.
fn pageWorkAgrees(store: *Store, report: std.json.Value, first_action: u64) !void {
    var request: protocol.ActivityPage = .{};
    try request.session.set(report.object.get("session").?.object.get("reference").?.string);
    const page = try store.activityPage(request);
    const work = report.object.get("work").?.object;
    try std.testing.expectEqualStrings(work.get("status").?.string, @tagName(page.work.status));
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("turn").?.string, 10), page.work.turn.?);
    try std.testing.expectEqual(try std.fmt.parseInt(u64, work.get("operation").?.string, 10), page.work.operation.?);
    try std.testing.expectEqual(first_action, page.work.first_action.?);
    const session = report.object.get("session").?.object;
    try std.testing.expectEqual(try std.fmt.parseInt(u64, session.get("revision").?.string, 10), page.work.revision);
    try std.testing.expectEqualStrings(session.get("workspace").?.string, page.work.workspace.slice());
}

test "Action settlement atomically yields to an earlier Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(SessionStopCompletion.pending, pending_stop.accepted.completion);
    try std.testing.expectEqual(
        SessionStopCompletion.pending,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    try std.testing.expectEqual(
        ActionSettlement.session_stop,
        try storage.settleActionAttempt(action_binding, .succeeded, "Bash succeeded.", .{}),
    );
    try std.testing.expectEqual(
        SessionStopCompletion.completed,
        (try storage.observeCommand("settlement-stop")).session_stop.?.completion,
    );
    const completed_replay = storage.stopSession(&stop, .{});
    try std.testing.expect(completed_replay == .accepted);
    try std.testing.expect(completed_replay.accepted.replayed);
    try std.testing.expectEqual(SessionStopCompletion.completed, completed_replay.accepted.completion);

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
    try std.testing.expectEqual(@as(u64, 1), try querySessionU64(
        storage.database,
        "SELECT count(*) FROM turn WHERE session_ref=?1 AND outcome_code='cancelled'",
        allocated_session_0.slice(),
    ));
}

test "earlier Action settlement remains authoritative after Session stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(SessionStopCompletion.completed, accepted.accepted.completion);
    try std.testing.expectEqual(original_content_id, try queryU64(
        storage.database,
        "SELECT resolution_content_id FROM action_operation",
    ));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(
        storage.database,
        "SELECT count(*) FROM action_operation WHERE resolution_code='succeeded'",
    ));
    const result_metadata = try storage.readContentMetadata(@intCast(original_content_id));
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, 1234), (try storage.readBashExecutionInput(action_binding)).timeout_ms);
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
    _ = try storage.inspectSession(session.slice());
}

test "report scratch exhaustion is an observation failure without Store fencing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expect((try storage.inspectSession(session.slice())).found);
}

test "report unlink failure retains a startup-owned zero-request file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    var report_store = try testingStore(&report_tmp, std.testing.io);
    defer report_store.close() catch unreachable;
    const allocated_session_0 = try configureTestSession(&report_store, "report-corrupt-config");
    try exec(report_store.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(report_store.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", allocated_session_0.slice());
    try exec(report_store.database, "PRAGMA foreign_keys=ON");
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
    var action_store = try testingStore(&action_tmp, std.testing.io);
    defer action_store.close() catch unreachable;
    const allocated_session_1 = try configureTestSession(&action_store, "action-corrupt-config");
    try submitTestMessage(&action_store, &action_tmp, "action-corrupt-message", "action-corrupt-message", allocated_session_1.slice(), "propose");
    const binding = (try action_store.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&action_store, &action_tmp, binding, "action-corrupt-metadata");
    const action_id = try queryU64(action_store.database, "SELECT min(action_id) FROM action_operation");
    try exec(action_store.database, "PRAGMA foreign_keys=OFF");
    try exec(action_store.database, "DELETE FROM content WHERE content_id=(SELECT call_id_content_id FROM model_tool_call ORDER BY operation_id,call_ordinal LIMIT 1)");
    try exec(action_store.database, "PRAGMA foreign_keys=ON");
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const allocated_session_2 = try configureTestSession(&storage, "descriptor-config");
            try submitTestMessage(&storage, &tmp, "descriptor-input", "descriptor-message", allocated_session_2.slice(), "propose");
            const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, source, "descriptor-metadata");
            try exec(storage.database, damage);
            const result: anyerror!void = switch (route) {
                .report => if (testingSessionReport(&storage, &tmp, allocated_session_2.slice(), 1024 * 1024)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .arguments => if (storage.actionArguments(allocated_session_2.slice(), try queryU64(storage.database, "SELECT min(action_id) FROM action_operation"))) |_| {} else |err| err,
                .execution => blk: {
                    const action = (try storage.admitNextActionAttempt(300_000, .{})).?;
                    break :blk if (storage.readBashExecutionInput(action.permit.binding)) |_| {} else |err| err;
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
    const source = @embedFile("store.zig");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "mutex.lock" ++ "Uncancelable("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fenced.store" ++ "(true"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "fenced.load" ++ "("));
    const enter = "self.enter" ++ "(";
    var entries = std.mem.splitSequence(u8, source[0..std.mem.indexOf(u8, source, "\ntest \"").?], enter);
    _ = entries.next();
    var entered: usize = 0;
    while (entries.next()) |rest| : (entered += 1) {
        const body = rest[0 .. std.mem.indexOf(u8, rest, "\n    }\n") orelse rest.len];
        try std.testing.expect(std.mem.indexOf(u8, body, "access.finish") != null);
    }
    try std.testing.expect(entered > 0);
}

/// Leaves `table` prepared normally but failing at the first step, the
/// shape of an I/O or corruption fault after a statement compiled.
fn failAtStepForTesting(database: *c.sqlite3, comptime table: []const u8) !void {
    try exec(database, "ALTER TABLE " ++ table ++ " RENAME TO " ++ table ++ "_unreadable");
    try exec(database, "CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable " ++
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
        var storage = try testingStore(&tmp, std.testing.io);
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
                break :blk switch (route) {
                    .view => if (storage.openHistoricalView(binding)) |_| {} else |err| err,
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

test "Core classifies trustworthy calls atomically without Action-shaped rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    {
        const rejected_action = try prepare(storage.database, "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,permission_state,resolution_code) VALUES(999,?1,1,?2,1,1,0,NULL)");
        defer _ = c.sqlite3_finalize(rejected_action);
        try bindU64(rejected_action, 1, binding.operation_id);
        try bindText(rejected_action, 2, allocated_session_0.slice());
        try std.testing.expectError(error.StatementFailed, expectDone(rejected_action));
    }
    {
        const invalid_denial = try prepare(storage.database, "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,permission_state,resolution_code) VALUES(998,?1,0,?2,1,1,2,NULL)");
        defer _ = c.sqlite3_finalize(invalid_denial);
        try bindU64(invalid_denial, 1, binding.operation_id);
        try bindText(invalid_denial, 2, allocated_session_0.slice());
        try std.testing.expectError(error.StatementFailed, expectDone(invalid_denial));
    }

    var observation = try storage.inspectSession(allocated_session_0.slice());
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
    try deny.session.set(allocated_session_0.slice());
    try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
    observation = try storage.inspectSession(allocated_session_0.slice());
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
    var reopened = try Store.open(
        std.testing.io,
        try std.fmt.bufPrint(&database, "{s}/store.sqlite3", .{root[0..root_length]}),
        root[0..root_length],
    );
    defer reopened.close() catch unreachable;
    const recovered = try reopened.inspectSession(allocated_session_0.slice());
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

test "complete call outcomes continue once in call order ahead of pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    storage = try testingStore(&tmp, std.testing.io);
    const continued = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try std.testing.expectEqual(first.turn_id, continued.turn_id);
    try std.testing.expectEqual(first.operation_id + 1, continued.operation_id);
    try std.testing.expect((try storage.admitModelAttempt(.tool_continuation, .{})) == null);
    const fresh = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
    try std.testing.expect(fresh.turn_id != first.turn_id);
    try std.testing.expect((try storage.admitModelAttempt(.message, .{})) == null);
}

test "production turn preserves skipped continuation preference through actual Store admissions" {
    const turn = @import("execution_turn.zig");
    // Real canonical admissions and outcomes; no native effect is launched.
    // The test controls only available preparation and execution capacity.
    const Context = struct {
        storage: *Store,
        preparation_open: bool = true,
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    storage = try testingStore(&tmp, std.testing.io);
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
    var sustained = try testingStore(&sustained_tmp, std.testing.io);
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
        try exec(sustained.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms>0 AND resolution_code IS NULL");
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
    var import_store = try testingStore(&import_tmp, std.testing.io);
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
    var read_store = try testingStore(&read_tmp, std.testing.io);
    defer read_store.close() catch unreachable;
    const allocated_session_1 = try configureTestSession(&read_store, "result-read-config");
    try submitTestMessage(&read_store, &read_tmp, "result-read-message", "result-read-message", allocated_session_1.slice(), "call");
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
        try exec(storage.database, "PRAGMA foreign_keys=OFF");
        try exec(storage.database, "DELETE FROM action_operation");
        if (corruption == .call) try exec(storage.database, "DELETE FROM model_tool_call");
        try exec(storage.database, "PRAGMA foreign_keys=ON");
        try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
        try std.testing.expect(storage.isFenced());
    }
}

test "compaction pressure uses provider usage appended input and complete call result groups" {
    for (0..3) |scenario| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        var patch: protocol.ConfigureCommand = .{};
        try patch.key.set("heuristics");
        try patch.session.set(session.slice());
        patch.configuration.compaction_trigger.state = .value;
        try patch.configuration.compaction_trigger.value.set("1000");
        patch.configuration.output_reservation.state = .value;
        try patch.configuration.output_reservation.value.set("1");
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
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
            var view = try storage.openHistoricalView(next);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            try std.testing.expect((try view.contextAnchor()) == null);
            try std.testing.expectEqual(HistoricalEntryKind.user, (try cursor.next(&view)).?.kind);
            for (0..2) |_| try std.testing.expectEqual(HistoricalEntryKind.provider_output, (try cursor.next(&view)).?.kind);
            try std.testing.expectEqual(HistoricalEntryKind.tool_results, (try cursor.next(&view)).?.kind);
            for ([_][]const u8{ "call-a", "call-b" }) |expected| {
                const result = (try view.nextToolResult()).?;
                var reader = try view.openContent(result.call_id);
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
            try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(session.slice())).pending_messages);
            try settleCompactionForTesting(&storage, &tmp, next, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view = try storage.openHistoricalView(successor);
            defer view.close();
            var cursor: TestingHistoryCursor = .{};
            const anchor = (try view.contextAnchor()).?;
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
        var storage = try testingStore(&tmp, std.testing.io);
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

test "historical preparation yields covered group populations and cancels proposal authentication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    // call. Closing in the middle of private validation releases its reader.
    {
        var view = try storage.openHistoricalView(binding);
        while (!try view.validateOutputsStep()) {}
        while (view.group_scan.reader == null) {
            var bytes: usize = 7;
            var items: usize = 1;
            try std.testing.expect(try view.nextEntryStep(view.output_boundary, &bytes, &items) == .pending);
        }
        var bytes: usize = 7;
        var items: usize = 1;
        try std.testing.expect(try view.nextEntryStep(view.output_boundary, &bytes, &items) == .pending);
        _ = try configureTestSession(&storage, "yielded-checkpoint");
        const checkpoint = c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null);
        const closes = storage.testing_content_work.closes.load(.monotonic);
        view.close();
        try std.testing.expectEqual(closes + 1, storage.testing_content_work.closes.load(.monotonic));
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), checkpoint);
    }
    var view = try storage.openHistoricalView(binding);
    defer view.close();
    while (!try view.validateOutputsStep()) {}
    var charged: u64 = 0;
    var turns: usize = 0;
    while (true) {
        turns += 1;
        try std.testing.expect(turns < 200000);
        const closes = storage.testing_content_work.closes.load(.monotonic);
        var bytes: usize = 127;
        var items: usize = 3;
        const progress = try view.nextEntryStep(view.output_boundary, &bytes, &items);
        charged += 127 - bytes;
        try std.testing.expect(storage.testing_content_work.closes.load(.monotonic) - closes <= 1);
        switch (progress) {
            .pending => {},
            .ready => |entry| {
                try std.testing.expect(entry == null);
                break;
            },
        }
    }
    try std.testing.expect(charged >= 8 * calls.len * arguments.len);
    try std.testing.expect(turns > charged / 127);
    try std.testing.expect(!storage.isFenced());
}

test "large historical readers and yielded group authentication leave checkpoints free" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    {
        var view = try storage.openHistoricalView(continuation);
        defer view.close();
        while (!try view.validateOutputsStep()) {}
        while (view.group_scan.reader == null) {
            var bytes: usize = 4096;
            var items: usize = 1;
            try std.testing.expect(try view.nextEntryStep(0, &bytes, &items) == .pending);
        }
        view.group_scan.reader.?.allocator = std.testing.allocator;
        var bytes: usize = 4096;
        var items: usize = 1;
        try std.testing.expect(try view.nextEntryStep(0, &bytes, &items) == .pending);
        _ = try configureTestSession(&storage, "large-group-write");
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        // Closing a pending view also frees its reader-owned copied window.
    }
    var view = try storage.openHistoricalView(continuation);
    defer view.close();
    const entry = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, entry.kind);
    var reader = try view.openContent(entry.content.?);
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
        cases: for ([_][:0]const u8{
            "UPDATE model_tool_call SET call_ordinal=99 WHERE call_ordinal=0; UPDATE model_tool_call SET call_ordinal=0 WHERE call_ordinal=1; UPDATE model_tool_call SET call_ordinal=1 WHERE call_ordinal=99",
            "DELETE FROM model_tool_call WHERE call_ordinal=1",
            "UPDATE model_output_item SET item_kind=1 WHERE item_ordinal=1",
            "DELETE FROM model_output_item WHERE item_ordinal=1; DELETE FROM model_tool_call WHERE call_ordinal=1",
            "DELETE FROM model_output_item WHERE operation_id IN (SELECT operation_id FROM model_tool_call); DELETE FROM model_tool_call",
            "UPDATE model_tool_call SET arguments_content_id=name_content_id,field_metadata=CAST(substr(field_metadata,1,120)||substr(field_metadata,41,40) AS BLOB)",
            "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1",
        }) |fault| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
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
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, fault);
            try exec(storage.database, "PRAGMA foreign_keys=ON");
            var view = try storage.openHistoricalView(next);
            defer view.close();
            while (!(view.validateOutputsStep() catch |err| {
                try std.testing.expectEqual(error.CorruptStore, err);
                try std.testing.expect(storage.isFenced());
                continue :cases;
            })) {}
            while (true) {
                var bytes: usize = 1;
                var items: usize = 1;
                _ = view.nextEntryStep(0, &bytes, &items) catch |err| {
                    try std.testing.expectEqual(error.CorruptStore, err);
                    break;
                };
                if (view.tool_group_initialized) return error.MissingCorruptionFailure;
            }
            try std.testing.expect(storage.isFenced());
        }
    }
}

test "historical accepted assistant output completeness and provenance fence reads" {
    const Incompatibility = enum { none, model, reasoning, answer };
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
        .{ .fault = "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1" },
        .{ .fault = "UPDATE model_output_item SET session_ref='f0re1g'" },
        .{ .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1" },
        .{ .fault = "UPDATE model_output_item SET content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=1) WHERE item_ordinal=0" },
        .{ .fault = "UPDATE model_output_item SET content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=0) WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET item_kind=2 WHERE item_ordinal=0" },
        .{ .fault = "UPDATE model_output_item SET item_kind=1 WHERE item_ordinal=1" },
        .{ .fault = "UPDATE model_output_item SET item_id_digest=zeroblob(32) WHERE item_ordinal=0" },
        .{ .fault = "UPDATE model_output_item SET item_id_digest=zeroblob(32) WHERE item_ordinal=1" },
        .{ .incompatible = .reasoning, .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=1)" },
        .{ .incompatible = .reasoning, .fault = "UPDATE model_output_item SET item_id_digest=zeroblob(32) WHERE item_ordinal=1" },
        .{ .incompatible = .answer, .fault = "UPDATE model_output_item SET item_id_digest=zeroblob(32) WHERE item_ordinal=0" },
        .{ .incompatible = .model, .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=0)" },
        .{ .fault = "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='future' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE model_operation SET resolution_code='tool_proposals' WHERE output_item_count IS NOT NULL" },
        .{ .fault = "UPDATE turn SET session_ref='f0re1g' WHERE turn_id=(SELECT turn_id FROM model_operation WHERE output_item_count IS NOT NULL)" },
        .{ .incompatible = .reasoning, .failure = error.ContinuationUnavailable },
        .{ .incompatible = .answer, .failure = error.ContinuationUnavailable },
        .{ .incompatible = .model, .failure = error.ContinuationUnavailable },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
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
        var rejection: @import("provider_output.zig").Rejection = .{};
        const validated = try @import("provider_output.zig").validate(std.testing.io, source, sse.len, &metadata, .assistant_response, &rejection, .{});
        for (0..@as(usize, if (case.tied_owners) 2 else 1)) |index| {
            if (index != 0) {
                try submitTestMessage(&storage, &tmp, "output-second", "output-second", session.slice(), "second");
                source_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            }
            try storage.settleModelSuccess(source_binding, &.{
                .source = source,
                .source_length = sse.len,
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
        try std.testing.expect(storage.configure(&reconfigure, true, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "output-next", "output-next", session.slice(), "next");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        switch (case.incompatible) {
            .none => {},
            .model => try storage.setHistoricalModelForTesting(source_binding, "different-model"),
            .reasoning, .answer => {
                // Preserve canonical content integrity and certified identity;
                // only current adapter compatibility changes in this sibling.
                const bytes = if (case.incompatible == .reasoning)
                    "{\"type\":\"reasoning\",\"id\":\"r\"}"
                else
                    "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_text\"}]}";
                const update = try prepare(storage.database, "UPDATE content SET payload=?1,byte_length=?2,digest=?3 " ++
                    "WHERE content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=?4)");
                defer _ = c.sqlite3_finalize(update);
                try bindBlob(update, 1, bytes);
                try bindU64(update, 2, bytes.len);
                try bindBlob(update, 3, &protocol.contentDigest(bytes));
                try bindU64(update, 4, if (case.incompatible == .reasoning) 0 else 1);
                try expectDone(update);
            },
        }
        try exec(storage.database, "PRAGMA foreign_keys=OFF");
        if (case.tied_owners) try exec(storage.database, "UPDATE model_operation SET admission_position=" ++
            "(SELECT min(admission_position) FROM model_operation WHERE output_item_count IS NOT NULL) WHERE output_item_count IS NOT NULL");
        // Deliberately bypass the message-certificate CHECK too: these cases
        // exercise read-time detection of damaged persisted item kinds.
        try exec(storage.database, "PRAGMA ignore_check_constraints=ON");
        if (case.fault) |fault| try exec(storage.database, fault);
        try exec(storage.database, "PRAGMA ignore_check_constraints=OFF");
        try exec(storage.database, "PRAGMA foreign_keys=ON");
        var preparation: @import("model_adapter.zig").Preparation = undefined;
        try preparation.init(std.testing.io, try storage.openHistoricalView(binding), root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        while (true) {
            var progress = preparation.advance(7, 2);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(case.failure, err);
                    break;
                },
                .prepared => |*request| {
                    request.deinit();
                    return error.MissingCorruptionFailure;
                },
            }
        }
        try std.testing.expectEqual(case.failure == error.CorruptStore, storage.isFenced());
        preparation.cancel();
        try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
    }
}

test "historical preparation keeps incompatible authenticated calls distinct from corruption" {
    for ([_]struct { controls: []const u8, fault: ?[:0]const u8 = null, failure: anyerror, incompatible_last: bool = false }{
        .{ .controls = ",\"caller\":{\"type\":\"future\"}", .failure = error.ContinuationUnavailable },
        .{ .controls = ",\"namespace\":\"future\"", .failure = error.ContinuationUnavailable },
        .{ .controls = ",\"caller\":{\"type\":\"future\"},\"late\":[0,]", .failure = error.CorruptStore },
        .{ .controls = ",\"caller\":{\"type\":\"future\"}", .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE private=1", .failure = error.CorruptStore },
        .{ .controls = ",\"namespace\":\"future\"", .fault = "UPDATE model_tool_call SET arguments_content_id=name_content_id,field_metadata=CAST(substr(field_metadata,1,120)||substr(field_metadata,41,40) AS BLOB)", .failure = error.CorruptStore },
        .{ .controls = ",\"status\":\"future\",\"arguments\":\"{}\"", .failure = error.CorruptStore },
        .{ .controls = ",\"status\":\"future\",\"name\":\"unknown\"", .failure = error.CorruptStore },
        .{ .controls = ",\"namespace\":\"future\"", .fault = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=(SELECT content_id FROM model_output_item WHERE item_ordinal=1)", .failure = error.CorruptStore },
        .{ .controls = ",\"namespace\":\"future\"", .fault = "UPDATE model_tool_call SET arguments_content_id=name_content_id,field_metadata=CAST(substr(field_metadata,1,120)||substr(field_metadata,41,40) AS BLOB) WHERE call_ordinal=1", .failure = error.CorruptStore },
        .{ .controls = ",\"namespace\":\"future\"", .incompatible_last = true, .fault = "UPDATE model_output_item SET item_id_digest=zeroblob(32) WHERE item_ordinal=0", .failure = error.CorruptStore },
        .{ .controls = "", .fault = "UPDATE model_operation SET resolution_code='answer' WHERE output_item_count IS NOT NULL", .failure = error.CorruptStore },
        .{ .controls = "", .fault = "UPDATE model_operation SET resolution_code='compacted' WHERE output_item_count IS NOT NULL", .failure = error.CorruptStore },
        .{ .controls = "", .fault = "UPDATE model_operation SET resolution_code='failed' WHERE output_item_count IS NOT NULL", .failure = error.CorruptStore },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "incompatible-config");
        try submitTestMessage(&storage, &tmp, "incompatible-input", "incompatible-input", session.slice(), "tools");
        const source = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]TestingCall{
            .{ .item_id = "a", .name = "unknown", .encoded_call_id = "a", .decoded_call_id = "a", .encoded_arguments = "{}", .decoded_arguments = "{}", .controls = if (case.incompatible_last) "" else case.controls },
            .{ .item_id = "b", .name = "unknown", .encoded_call_id = "b", .decoded_call_id = "b", .encoded_arguments = "{}", .decoded_arguments = "{}", .controls = if (case.incompatible_last) case.controls else "" },
        };
        try settleCallsForTesting(&storage, &tmp, source, "incompatible-output", &calls);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        if (case.fault) |fault| try exec(storage.database, fault);
        var root: [protocol.max_store_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(std.testing.io, &root);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: @import("model_adapter.zig").Preparation = undefined;
        try preparation.init(std.testing.io, try storage.openHistoricalView(binding), root[0..length], .{ .used = &used, .limit = 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        while (true) {
            var progress = preparation.advance(1, 1);
            switch (progress) {
                .pending => {},
                .failed => |err| {
                    try std.testing.expectEqual(case.failure, err);
                    break;
                },
                .prepared => |*request| {
                    request.deinit();
                    return error.MissingCompatibilityFailure;
                },
            }
        }
        try std.testing.expectEqual(case.failure == error.CorruptStore, storage.isFenced());
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "selection-config");
            try submitTestMessage(&storage, &tmp, "selection-input", "selection-input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL");
            const insert = try prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position," ++
                "attempt_ordinal,output_reservation,allowance_used,uncertain,resolution_code) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value," ++
                "1,0,1,0,'failed' FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, population);
            try bindU64(insert, 2, current.operation_id);
            try expectDone(insert);
            var view = try storage.openHistoricalView(current);
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
            var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "pending-cost-config");
    try exec(storage.database, "PRAGMA foreign_keys=OFF");

    var costs: [2]i32 = undefined;
    for ([_]usize{ 100, 10_000 }, 0..) |history, index| {
        try exec(storage.database, "DELETE FROM message_admission; DELETE FROM session_stop");
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "SELECT value,'{1s}',printf('excluded-%d',value),1,NULL,1 FROM sequence; " ++
                "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                "VALUES({0}+1,'{1s}','eligible',1,NULL,1); " ++
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                "VALUES('history-stop','{1s}',NULL,{0})",
            .{ history, session.slice() },
            0,
        );
        defer std.testing.allocator.free(insert);
        try exec(storage.database, insert);
        try std.testing.expectEqual(@as(u64, 1), try storage.countPendingMessages(session.slice()));

        const cutoff_statement = try prepare(storage.database, session_stop_cutoff_sql);
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try bindText(cutoff_statement, 1, session.slice());
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(cutoff_statement));
        const cutoff = c.sqlite3_column_int64(cutoff_statement, 0);
        const count_statement = try prepare(storage.database, pending_message_count_sql);
        defer _ = c.sqlite3_finalize(count_statement);
        try bindText(count_statement, 1, session.slice());
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
            const session = try configureTestSession(&storage, "full-scale-config");
            try exec(storage.database, "PRAGMA foreign_keys=OFF");

            for (1..message_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "VALUES({0},'{1s}','message-{0}',1,NULL,1)",
                    .{ index, session.slice() },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(storage.database, insert);
            }
            for (1..stop_count + 1) |index| {
                const insert = try std.testing.allocator.printSentinel(
                    "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) " ++
                        "VALUES('stop-{0}',3,'{2s}',zeroblob(32),NULL,NULL,1,'accepted',0,0);" ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                        "VALUES('stop-{0}','{2s}',NULL,{1})",
                    .{ index, message_count, session.slice() },
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(storage.database, insert);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "frozen-call-config");
    var remove_bash: protocol.ConfigureCommand = .{};
    try remove_bash.key.set("frozen-call-no-tools");
    try remove_bash.session.set(session.slice());
    remove_bash.configuration.tools.state = .value;
    remove_bash.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&remove_bash, true, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "frozen-call-message", "frozen-call-message", session.slice(), "classify");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    var add_bash: protocol.ConfigureCommand = .{};
    try add_bash.key.set("frozen-call-add-bash");
    try add_bash.session.set(session.slice());
    add_bash.configuration.tools.state = .value;
    add_bash.configuration.tools.count = 1;
    add_bash.configuration.tools.values[0] = .bash;
    try std.testing.expect(storage.configure(&add_bash, true, .{}) == .accepted);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(u64, population), (try storage.inspectSession(allocated_session_0.slice())).action_count);
    const valid_report_bytes = try testingSessionReport(&storage, &tmp, allocated_session_0.slice(), 1024 * 1024);
    defer std.testing.allocator.free(valid_report_bytes);
    const valid_report = try std.json.parseFromSlice(TestingSessionReport, std.testing.allocator, valid_report_bytes, .{ .ignore_unknown_fields = true });
    defer valid_report.deinit();
    try std.testing.expectEqual(@as(usize, population), valid_report.value.actions.unresolved.len);

    const allocated_session_1 = try configureTestSession(&storage, "rejected-growth-config");
    try submitTestMessage(&storage, &tmp, "rejected-growth-message", "rejected-growth-message", allocated_session_1.slice(), "rejected");
    const rejected_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleCallsForTesting(&storage, &tmp, rejected_binding, "rejected-growth-metadata", &rejected_calls);
    const rejected = try storage.inspectSession(allocated_session_1.slice());
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "configure-stop");
    try submitTestMessage(&storage, &tmp, "stop-a", "message-a", session.slice(), "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;

    var stop = try completeSessionStop("stop", session.slice());
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(!accepted.accepted.replayed);
    try std.testing.expectEqual(SessionStopCompletion.completed, accepted.accepted.completion);
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
        ModelInterruptionRejection.operation_resolved,
        rejected_interrupt.rejected.code,
    );

    try submitTestMessage(&storage, &tmp, "stop-b", "message-b", session.slice(), "later");
    const replay = storage.stopSession(&stop, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(SessionStopCompletion.completed, replay.accepted.completion);
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
    const session = try configureTestSession(&storage, "completed-stop-config");
    try submitTestMessage(&storage, &tmp, "completed-stop-file", "completed-stop-message", session.slice(), "answer");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try exec(
        storage.database,
        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='answer'," ++
            "resolution_content_id=(SELECT content_id FROM message_admission WHERE command_key='completed-stop-message')",
    );
    try execSessionSql(storage.database, "UPDATE turn SET outcome_code='completed',outcome_content_id=(SELECT content_id FROM message_admission " ++
        "WHERE command_key='completed-stop-message') WHERE session_ref=?1", session.slice());
    var stop = try completeSessionStop("completed-stop", session.slice());
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(accepted.accepted.selection.selected_turn_id == null);
    try std.testing.expectEqual(SessionStopCompletion.completed, accepted.accepted.completion);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(SessionStopCompletion.completed, accepted.accepted.completion);
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
            storage = try testingStore(&tmp, std.testing.io);
            storage_open = true;
        }
        const replay = storage.stopSession(&stop, .{});
        try std.testing.expect(replay == .accepted and replay.accepted.replayed);
        try std.testing.expectEqual(accepted.accepted.selection, replay.accepted.selection);
        try std.testing.expectEqual(SessionStopCompletion.completed, replay.accepted.completion);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "configure-interrupt");
    try submitTestMessage(&storage, &tmp, "interrupt-a", "interrupt-message-a", session.slice(), "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;
    try submitTestMessage(&storage, &tmp, "interrupt-b", "interrupt-message-b", session.slice(), "second");

    var interrupt = try completeModelInterruption("interrupt", session.slice(), binding);
    const accepted = storage.interruptModel(&interrupt, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding));
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const session = try configureTestSession(&storage, "configure-rejected-interrupt");
    var early: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
    try early.key.set("early-interrupt");
    try early.session.set(session.slice());
    const rejected = storage.interruptModel(&early, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, rejected.rejected.code);

    try submitTestMessage(&storage, &tmp, "rejected-interrupt-a", "rejected-interrupt-message", session.slice(), "first");
    const admitted = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 1), admitted.permit.binding.operation_id);
    const replay = storage.interruptModel(&early, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, replay.rejected.code);

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
    try std.testing.expectEqual(ModelInterruptionRejection.operation_resolved, resolved.rejected.code);
}

test "controls wait behind an active model settlement transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(SessionStopCompletion.completed, stop_reply.accepted.completion);
    const interrupt_reply = interrupt_context.reply.?;
    try std.testing.expect(interrupt_reply == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.operation_resolved, interrupt_reply.rejected.code);

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
        var storage = try testingStore(&tmp, std.testing.io);
        var storage_open = true;
        defer if (storage_open) storage.close() catch unreachable;

        const session = try configureTestSession(&storage, "retry-config");
        try submitTestMessage(&storage, &tmp, "retry-first", "retry-message", session.slice(), "first");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "temporary" }, .{ .retryable = .{
            .waits_ms = .{ 60_000, 60_000, 60_000 },
        } }, .{});
        // Make the saved retry due without depending on wall-clock scheduling.
        try exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL");

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
                storage = try testingStore(&tmp, std.testing.io);
                storage_open = true;
            }
            if (is_stop) {
                const replay = storage.stopSession(&stop, .{});
                try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                try std.testing.expectEqual(binding.turn_id, replay.accepted.selection.selected_turn_id.?);
                try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
                try std.testing.expectEqual(SessionStopCompletion.completed, replay.accepted.completion);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    storage = try Store.open(std.testing.io, database, root_buffer[0..root_length]);
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
        expected: ?ConfigurationRejection,
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
            configurationBeforeWorkspace(current, &requested),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "Store configuration requires and freezes provider model and workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
        const reply = storage.configure(&command, true, .{});
        if (mask == 7) {
            try std.testing.expect(reply == .accepted);
        } else {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, reply.rejected.code);
            try std.testing.expect(!(try storage.inspectSession(command.session.slice())).found);
        }
    }

    var initial = try completeConfiguration("binding-initial", "", workspace, "model-a");
    const initial_reply = storage.configure(&initial, true, .{});
    try std.testing.expect(initial_reply == .accepted);
    const session = initial_reply.accepted.session;
    const observation = try storage.inspectSession(session.slice());
    try std.testing.expectEqual(protocol.Provider.codex, observation.provider.?);
    try std.testing.expectEqualStrings("model-a", observation.model.slice());

    var equal: protocol.ConfigureCommand = .{};
    try equal.key.set("binding-equal");
    equal.session = session;
    equal.configuration.provider.state = .value;
    try equal.configuration.provider.value.set("codex");
    equal.configuration.model.state = .value;
    try equal.configuration.model.value.set("model-a");
    try std.testing.expect(storage.configure(&equal, true, .{}) == .accepted);

    var different = equal;
    try different.key.set("binding-different");
    different.configuration.model.value.len = 0;
    try different.configuration.model.value.set("model-a ");
    const rejected = storage.configure(&different, true, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.model_is_immutable, rejected.rejected.code);
}

test "unsupported provider rejects mixed configuration atomically and replays exact shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("atomic-initial", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&initial, true, .{});
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
    const rejected = storage.configure(&update, true, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.unsupported_provider, rejected.rejected.code);
    try std.testing.expectEqual(content_count, try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(revision_count, try queryU64(storage.database, "SELECT count(*) FROM session_revision"));
    const current = try storage.inspectSession(created_session_0.slice());
    try std.testing.expectEqual(@as(u64, 1), current.revision);
    try std.testing.expectEqual(@as(u8, 1), current.tools_mask);
    try std.testing.expectEqualStrings("bypass", current.permission_mode.slice());
    const replay = storage.configure(&update, true, .{});
    try std.testing.expect(replay == .rejected and replay.rejected.replayed);

    var omitted: protocol.ConfigureCommand = .{};
    try omitted.key.set("provider-shape");
    try omitted.session.set(created_session_0.slice());
    omitted.configuration.tools.state = .value;
    omitted.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&omitted, true, .{}) == .accepted);
    var explicit = omitted;
    explicit.configuration.provider.state = .value;
    try explicit.configuration.provider.value.set("codex");
    try std.testing.expect(storage.configure(&explicit, true, .{}) == .conflict);
    try std.testing.expect(storage.configure(&omitted, true, .{}).accepted.replayed);
}

fn expectBindingPreserved(storage: *Store, session: []const u8, phase: []const u8) !void {
    for (0..6) |variant| {
        const before = try storage.inspectSession(session);
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
        const reply = storage.configure(&update, true, .{});
        if (variant < 4) {
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(before.revision + 1, reply.accepted.revision);
        } else {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(if (variant == 4) ConfigurationRejection.unsupported_provider else ConfigurationRejection.model_is_immutable, reply.rejected.code);
        }
        const after = try storage.inspectSession(session);
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
    var storage = try testingStore(&tmp, std.testing.io);
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try expectBindingPreserved(&storage, created_session_0.slice(), "before-reopen");
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const reopened = try storage.inspectSession(created_session_0.slice());
    try std.testing.expectEqual(protocol.Provider.codex, reopened.provider.?);
    try std.testing.expectEqual(@as(u8, 1), reopened.tools_mask);
    try std.testing.expectEqualStrings("ask", reopened.permission_mode.slice());
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-reopen");

    const file = try tmp.dir.createFile(std.testing.io, "provider-reopen-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("provider-reopen-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try execSessionSql(storage.database, "UPDATE session_revision SET provider='other' WHERE session_ref=?1", created_session_0.slice());
    var view = try storage.openHistoricalView(binding);
    try std.testing.expectError(error.CorruptStore, view.settings());
    view.close();
    try execSessionSql(storage.database, "UPDATE session_revision SET provider='codex' WHERE session_ref=?1", created_session_0.slice());
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);

    try execSessionSql(storage.database, "UPDATE session SET provider='other' WHERE session_ref=?1", created_session_0.slice());
    try std.testing.expectError(error.CorruptStore, storage.inspectSession(created_session_0.slice()));
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
        expected_rejection: ?ConfigurationRejection = null,
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
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&command, true, .{
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

        const rejected = storage.configure(&command, true, .{ .content_import = true });
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

        const replay = storage.configure(&command, true, .{ .content_import = true });
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
    var first = try completeConfiguration("first", "", workspace, "model-a");
    const first_reply = storage.configure(&first, true, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(first_reply.accepted.created);

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("update");
    update.session = first_reply.accepted.session;
    update.configuration.tools.state = .value;
    update.configuration.tools.count = 0;
    update.configuration.permission_mode.state = .value;
    try update.configuration.permission_mode.value.set("bypass");
    const update_reply = storage.configure(&update, true, .{});
    try std.testing.expect(update_reply == .accepted);
    try std.testing.expectEqual(@as(u64, 2), update_reply.accepted.revision);

    const replay = storage.configure(&first, true, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
    const observation = try storage.inspectSession(first_reply.accepted.session.slice());
    try std.testing.expectEqualStrings("model-a", observation.model.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    try std.testing.expectEqual(@as(u8, 0), observation.tools_mask);
    try std.testing.expectEqualStrings("bypass", observation.permission_mode.slice());
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

    first.configuration.tools.state = .value;
    first.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&first, true, .{}) == .conflict);
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

test "interleaved large content readers bound repeated SQLite page reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    _ = try storage.importBytesContent(first, false, false);
    _ = try storage.importBytesContent(second, false, false);
    var readers = [_]ContentReader{
        try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(first) }),
        try storage.openContent(.{ .length = length, .digest = protocol.contentDigest(second) }),
    };
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
        const corrupt = try prepare(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(corrupt);
        try bindI64(corrupt, 1, readers[0].content_id);
        try expectDone(corrupt);
    }
    // Copied bytes belong only to their original reader. A newly resolved
    // raw reader must see the changed row, not another reader's old window.
    var fresh = try storage.openContent(readers[0].reference);
    defer fresh.close();
    fresh.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(first[length - 1], buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), try fresh.read(length - 1, buffer[0..1]));
    try std.testing.expectEqual(@as(u8, 0), buffer[0]);
    {
        const remove = try prepare(storage.database, "DELETE FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(remove);
        try bindI64(remove, 1, readers[0].content_id);
        try expectDone(remove);
    }
    try std.testing.expectEqual(@as(usize, 1), try readers[0].read(length - 1, buffer[0..1]));
    try std.testing.expectError(error.ContentReadFailed, readers[0].read(0, &buffer));
    try std.testing.expect(storage.isFenced());
}

test "large projected readers retain distinct copied sources across ranges and commits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const length = 2 * 1024 * 1024;
    const split = length / 2 + 17;
    const next_split = split + 31;
    const expected = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(expected);
    for (expected, 0..) |*byte, index| byte.* = @intCast('a' + index % 23);
    const request = try testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = expected[0..split], .decoded = expected[0..split] },
        .{ .encoded = expected[split..next_split], .decoded = expected[split..next_split] },
        .{ .encoded = expected[next_split..], .decoded = expected[next_split..] },
    });
    // The short middle source leaves offset zero in its copied window when
    // the third source starts there. Only source identity forces that refill.
    for ([_][]const u8{ expected[0..split], expected[split..next_split], expected[next_split..] }, 0..) |part, ordinal| {
        const source = try storage.importBytesContent(part, true, false);
        const update = try prepare(storage.database, "UPDATE answer_text_projection SET source_content_id=?1,encoded_start=0 WHERE part_ordinal=?2");
        defer _ = c.sqlite3_finalize(update);
        try bindI64(update, 1, source);
        try bindU64(update, 2, ordinal);
        try expectDone(update);
    }
    var readers = [_]ContentReader{
        try storage.openPublicConversationContent(request),
        try storage.openActivityContent(.{ .session = request.session, .position = request.position }),
        try storage.openContentIdentity(.{ .length = split, .digest = protocol.contentDigest(expected[0..split]) }, true),
    };
    defer for (&readers) |*reader| reader.close();
    for (&readers) |*reader| reader.allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < length) : (offset += buffer.len) {
        try std.testing.expectEqual(buffer.len, try readers[0].read(offset, &buffer));
        try std.testing.expectEqualSlices(u8, expected[offset..][0..buffer.len], &buffer);
        const ranged_offset = @min(length, offset + 123);
        const ranged_count = @min(buffer.len, length - ranged_offset);
        try std.testing.expectEqual(ranged_count, try readers[1].readRange(ranged_offset, &buffer));
        try std.testing.expectEqualSlices(u8, expected[ranged_offset..][0..ranged_count], buffer[0..ranged_count]);
        const raw_offset = (offset + 317) % split;
        const raw_count = @min(buffer.len, split - raw_offset);
        try std.testing.expectEqual(raw_count, try readers[2].readRange(raw_offset, &buffer));
        try std.testing.expectEqualSlices(u8, expected[raw_offset..][0..raw_count], buffer[0..raw_count]);
        if (offset % (256 * 1024) == 0) {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "projection-write-{d}", .{offset});
            _ = try configureTestSession(&storage, key);
            try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        }
    }
    for (readers[0..2]) |*reader| try std.testing.expectEqual(@as(usize, 0), try reader.read(length, &buffer));
    try std.testing.expectEqual(@as(usize, 0), try readers[2].read(split, &buffer));
    // Backward ranges restart decoding without retaining a seek index.
    try std.testing.expectEqual(buffer.len, try readers[1].readRange(37, &buffer));
    try std.testing.expectEqualSlices(u8, expected[37..][0..buffer.len], &buffer);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
}

test "large projected readers never borrow another reader's prefetched integrity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const expected = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(expected);
    @memset(expected, 'x');
    const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = expected, .decoded = expected }});
    var held = try storage.openPublicConversationContent(request);
    defer held.close();
    held.allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqual(buffer.len, try held.read(0, &buffer));
    try exec(storage.database, "UPDATE content SET payload=CAST(replace(CAST(payload AS TEXT),'x','y') AS BLOB) " ++
        "WHERE content_id=(SELECT source_content_id FROM answer_text_projection LIMIT 1)");
    try std.testing.expectEqual(buffer.len, try held.read(buffer.len, &buffer));
    try std.testing.expectEqualSlices(u8, expected[buffer.len..][0..buffer.len], &buffer);
    var fresh = try storage.openPublicConversationContent(request);
    defer fresh.close();
    fresh.allocator = std.testing.allocator;
    try std.testing.expectEqual(buffer.len, try fresh.read(0, &buffer));
    try std.testing.expectEqualSlices(u8, &@as([4096]u8, @splat('y')), &buffer);
    var offset: usize = buffer.len;
    while (offset + buffer.len < expected.len) : (offset += buffer.len)
        try std.testing.expectEqual(buffer.len, try fresh.read(offset, &buffer));
    try std.testing.expectError(error.CorruptStore, fresh.read(offset, &buffer));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, held.read(2 * buffer.len, &buffer));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
}

test "retained raw and projected readers allow checkpoints between committed windows" {
    var checkpoints: [2]c_int = undefined;
    for ([_]bool{ false, true }, 0..) |projected, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const text = @as([32768]u8, @splat('x')) ++ "asymmetric-é-tail";
        var reader = if (projected) blk: {
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = text, .decoded = text }});
            break :blk try storage.openPublicConversationContent(request);
        } else blk: {
            _ = try storage.importBytesContent(text, false, false);
            break :blk try storage.openContent(.{ .length = text.len, .digest = protocol.contentDigest(text) });
        };
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
    const bash = @import("bash.zig");
    for ([_]usize{ 0, 1024 * 1024 }) |padding_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
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
        var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        try workspace.set(storage.selector.slice());
        var used: std.atomic.Value(u64) = .init(0);
        var preparation = switch (bash.startPreparation(std.testing.io, std.testing.allocator, try storage.openPublicConversationContent(request), descriptor.len, request.session, storage.selector.slice(), workspace, storage.selector.slice(), "/bin/bash", 1000, .{ .used = &used, .limit = 4096 }, 11, 2, .{})) {
            .preparing => |value| value,
            .failed => |initial| {
                var failure = initial;
                try failure.cleanup.cleanup();
                return failure.cause;
            },
        };
        var owned = true;
        defer if (owned) {
            var cleanup = preparation.cancel();
            cleanup.cleanup() catch unreachable;
        };
        try std.testing.expect(preparation.advance() == .pending);
        _ = try configureTestSession(&storage, "bash-checkpoint");
        try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_wal_checkpoint_v2(storage.database, null, c.SQLITE_CHECKPOINT_TRUNCATE, null, null));
        while (true) {
            switch (preparation.advance()) {
                .pending => {},
                .prepared => |value| {
                    owned = false;
                    var prepared = value;
                    defer prepared.cleanup() catch unreachable;
                    try std.testing.expectEqualStrings(command, prepared.command.?);
                    break;
                },
                .failed => |initial| {
                    owned = false;
                    var failure = initial;
                    try failure.cleanup.cleanup();
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("", "", workspace, "model-a");
    const reply = storage.configure(&command, true, .{});
    try std.testing.expect(reply == .accepted);
    const session = reply.accepted.session;
    try std.testing.expect(protocol.validSessionId(session.slice()));
    const observation = try storage.inspectSession(session.slice());
    try std.testing.expect(observation.found);
    try std.testing.expectEqualStrings(session.slice(), observation.session.slice());
    try std.testing.expect((try storage.observeCommand("")).status == .accepted);

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("exact\x00key");
    update.session = session;
    const updated = storage.configure(&update, true, .{});
    try std.testing.expect(updated == .accepted and !updated.accepted.created);
    try std.testing.expectEqual(@as(u64, 2), updated.accepted.revision);
    try std.testing.expect((try storage.observeCommand("exact\x00key")).status == .accepted);
    try std.testing.expect(storage.configure(&update, true, .{}).accepted.replayed);

    var invalid = try completeConfiguration("invalid-nul-session", "exact\x00reference", workspace, "model-a");
    const rejected = storage.configure(&invalid, true, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM session"));
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSession(session.slice())).revision);
    try std.testing.expect(!storage.isFenced());
}

test "saved incomplete initialization stays rejected after Session creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    const rejected = storage.configure(&incomplete, true, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var complete = try completeConfiguration(
        "complete",
        "",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&complete, true, .{}) == .accepted);
    const replay = storage.configure(&incomplete, true, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
}

test "capability-required configuration rejects on replacement and replays its saved decision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("capability-guard", "", workspace, "model-a");
    command.require_model = true;

    const rejected = storage.configure(&command, false, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.model_capability_unavailable, rejected.rejected.code);
    try std.testing.expect(!(try storage.inspectSession(command.session.slice())).found);
    const replay = storage.configure(&command, true, .{});
    try std.testing.expect(replay == .rejected and replay.rejected.replayed);
    try std.testing.expectEqual(rejected.rejected.code, replay.rejected.code);

    var new_key = command;
    try new_key.key.set("capability-guard-next");
    try std.testing.expect(storage.configure(&new_key, true, .{}) == .accepted);
    try std.testing.expect(storage.configure(&new_key, false, .{}).accepted.replayed);
    var changed_intent = command;
    changed_intent.require_model = false;
    try std.testing.expect(storage.configure(&changed_intent, true, .{}) == .conflict);
    try changed_intent.key.set("explicit-offline-config");
    try std.testing.expect(storage.configure(&changed_intent, false, .{}) == .accepted);
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
        var storage = try testingStore(&tmp, std.testing.io);
        const reply = storage.configure(&command, true, .{ .before_commit = true });
        try std.testing.expect(reply == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("commit-fault")).status == .absent);
        try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        try std.testing.expect(storage.configure(&command, true, .{}) == .accepted);
    }
}

test "an outside SQLite writer cannot take the open Store's lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
    const database = try std.fmt.bufPrintSentinel(&database_buffer, "{s}/store.sqlite3", .{root}, 0);
    var storage = try Store.open(std.testing.io, database, root);
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
    const configured = storage.configure(&command, true, .{});
    try std.testing.expect(configured == .accepted);
    try std.testing.expect(!storage.isFenced());

    try std.testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_close(blocker));
    blocker_open = false;
    try storage.close();
    storage_open = false;

    var reopened = try Store.open(std.testing.io, database, root);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("busy-save")).status != .absent);
    try std.testing.expect((try reopened.inspectSession(configured.accepted.session.slice())).found);
}

test "real SQLite full during import publishes no canonical prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;

    const page_count = try pragmaInt(storage.database, "PRAGMA page_count");
    var limit_buffer: [64:0]u8 = undefined;
    const limit = try std.fmt.bufPrintSentinel(&limit_buffer, "PRAGMA max_page_count={d}", .{page_count}, 0);
    try exec(storage.database, limit);
    try std.testing.expectEqual(page_count, try pragmaInt(storage.database, "PRAGMA max_page_count"));

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
        storage.configureLocked(&command, true, .{}),
    );
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    storage.fence(error.CanonicalStorageFull) catch {};
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("full-import"));
    try storage.close();
    storage_open = false;

    var reopened = try testingStore(&tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    try std.testing.expect((try reopened.observeCommand("full-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(reopened.database, "SELECT count(*) FROM session"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        reopened.database,
        "SELECT count(*) FROM content WHERE byte_length=131072",
    ));
}

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_text = "first message\n" ++ @as([700 * 6]u8, @bitCast(@as([700][6]u8, @splat("abcdef".*)))) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", created_session_0.slice(), first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const before = try pragmaInt(storage.database, "SELECT unixepoch()");
    const first_reply = storage.submitMessage(&first, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", created_session_0.slice(), second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessage(&second, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);
    // The Host stamps each admission with its wall clock, to the second.
    const after = try pragmaInt(storage.database, "SELECT unixepoch()");
    const stamped = try pragmaInt(storage.database, "SELECT admitted_at FROM message_admission WHERE admission_id=1");
    try std.testing.expect(before <= stamped and stamped <= after);
    // A replayed or restarted admission keeps the time it was admitted at.
    try exec(storage.database, "UPDATE message_admission SET admitted_at=1000 WHERE admission_id=1");

    const replay = storage.submitMessage(&first, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSession(created_session_0.slice());
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
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSession(created_session_0.slice())).pending_messages);
    try std.testing.expectEqual(@as(u32, 1000), try pragmaInt(storage.database, "SELECT admitted_at FROM message_admission WHERE admission_id=1"));
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
    var storage = try testingStore(&tmp, io);
    defer storage.close() catch unreachable;

    const text = "rejected input";
    const file = try tmp.dir.createFile(std.testing.io, "rejected-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("rejected-message", "000000", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    const rejected = storage.submitMessage(&message, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure-later", "", workspace, "model-a");
    const configured = storage.configure(&configuration, true, .{});
    try std.testing.expect(configured == .accepted);
    try std.testing.expectEqualStrings(message.session.slice(), configured.accepted.session.slice());
    const replay = storage.submitMessage(&message, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(MessageRejection.unknown_session, replay.rejected.code);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &replay.rejected.content.digest);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(configured.accepted.session.slice())).pending_messages);

    const observed = try storage.observeCommand("rejected-message");
    try std.testing.expect(observed.status == .rejected);
    try std.testing.expect(observed.message == null);
}

test "a peer sender is resolved from its Action handle and exact replays survive revocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expect(storage.configure(&tools, true, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "sender-seed", "sender-seed", sender, "send a report");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, model, "sender-calls");
    const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    const handle = (try storage.readBashExecutionInput(action)).sender_handle;
    var own_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try own_ref.set(sender);
    const sender_end = (try storage.activityPage(.{ .session = own_ref })).end;
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
    const accepted = storage.submitMessage(&sent, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(storage.submitMessage(&sent, .{}).accepted.replayed);
    // The sender is part of the request: the same key without it conflicts.
    var anonymous = try Send.make(tmp.dir, "peer-send-anonymous", allocated_session_1.slice(), null, "look at this\nsecond line");
    defer anonymous.removeTemporaryContent(std.testing.io) catch unreachable;
    try anonymous.key.set("peer-send");
    try std.testing.expect(storage.submitMessage(&anonymous, .{}) == .conflict);

    var refused = try Send.make(tmp.dir, "peer-refused", "absent", sender, "lost");
    refused.sender_handle = handle;
    defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expectEqual(MessageRejection.unknown_session, storage.submitMessage(&refused, .{}).rejected.code);

    var forged = try Send.make(tmp.dir, "peer-forged", allocated_session_1.slice(), "f0rged", "forged");
    defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expectEqual(MessageRejection.invalid_sender_handle, storage.submitMessage(&forged, .{}).rejected.code);
    const forged_replay = storage.submitMessage(&forged, .{});
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
        try std.testing.expectEqual(MessageRejection.invalid_sender_handle, storage.submitMessage(&invalid, .{}).rejected.code);
    }
    var changed_handle = sent;
    changed_handle.sender_handle = null;
    try std.testing.expect(storage.submitMessage(&changed_handle, .{}) == .conflict);
    // An invalid target is refused first, whichever sender: an unknown one
    // claims no sequence position, and the Store stays open.
    for ([_]struct { key: []const u8, from: []const u8 }{
        .{ .key = "peer-empty-forged", .from = "f0rged" },
        .{ .key = "peer-empty-known", .from = sender },
    }) |case| {
        var empty = try Send.make(tmp.dir, case.key, "", case.from, "nowhere");
        if (std.mem.eql(u8, case.from, sender)) empty.sender_handle = handle;
        defer empty.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expectEqual(MessageRejection.invalid_session_reference, storage.submitMessage(&empty, .{}).rejected.code);
    }
    // An unknown sender has no sequence: only the known sender's refusals are kept.
    try std.testing.expectEqual(@as(u64, 2), try queryU64(storage.database, "SELECT count(*) FROM sent_rejection"));
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(allocated_session_1.slice())).pending_messages);

    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set(allocated_session_1.slice());
    const received = try storage.activityPage(.{ .session = session });
    try std.testing.expectEqual(@as(usize, 1), received.count);
    const peer = received.items[0].value.admission.sender.?;
    try std.testing.expectEqualStrings(sender, peer.session.slice());

    try session.set(sender);
    const own = try storage.activityPage(.{ .session = session, .position = sender_end });
    try std.testing.expectEqual(@as(usize, 3), own.count);
    try std.testing.expectEqualStrings("invalid_session_reference", own.items[2].value.send_failed.code.slice());
    const out = own.items[0].value.sent;
    try std.testing.expectEqual(accepted.accepted.admission_id, out.admission);
    try std.testing.expectEqualStrings(allocated_session_1.slice(), out.target.session.slice());
    const failed = own.items[1].value.send_failed;
    try std.testing.expectEqualStrings("absent", failed.target.session.slice());
    try std.testing.expectEqualStrings("unknown_session", failed.code.slice());
    try std.testing.expect(own.items[0].position < own.items[1].position);
    try storage.revokeActionSender(action);
    try std.testing.expect(storage.submitMessage(&sent, .{}).accepted.replayed);
    var stale = sent;
    try stale.key.set("stale-handle");
    try std.testing.expectEqual(MessageRejection.invalid_sender_handle, storage.submitMessage(&stale, .{}).rejected.code);
    // The sent row's bytes are the Message's, read through the sender.
    var reader = try storage.openActivityContent(.{ .session = session, .position = own.items[0].position });
    reader.close();

    // The model's historical view carries the recorded sender, not text.
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    var view = try storage.openHistoricalView(try admitted.permit.consume());
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;

        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var primary_configuration = try completeConfiguration(
            "reference-primary-configure",
            "",
            workspace,
            "model-a",
        );
        const created_session_0_reply = storage.configure(&primary_configuration, true, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        const created_session_0 = created_session_0_reply.accepted.session;
        var other_configuration = try completeConfiguration(
            "reference-other-configure",
            "",
            workspace,
            "model-a",
        );
        const other_reply = storage.configure(&other_configuration, true, .{});
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
        try std.testing.expect(storage.submitMessage(&primary_message, .{}) == .accepted);

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
        try std.testing.expect(storage.submitMessage(&other_message, .{}) == .accepted);

        switch (corruption) {
            .session => try execSessionSql(
                storage.database,
                "UPDATE message_admission SET session_ref=?1 " ++
                    "WHERE command_key='reference-primary-message'",
                other_session.slice(),
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
        "",
        workspace,
        "model-a",
    );
    const created_session_0_reply = storage.configure(&configuration, true, .{});
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
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const text = "one admission";
    const file = try tmp.dir.createFile(std.testing.io, "message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message", created_session_0.slice(), file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .before_commit = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect((try storage.observeCommand("message")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(created_session_0.slice())).pending_messages);
    const accepted = storage.submitMessage(&message, .{});
    try std.testing.expect(accepted == .accepted);

    var retargeted = message;
    retargeted.text.file = null;
    try retargeted.session.set("0ther0");
    try std.testing.expect(storage.submitMessage(&retargeted, .{}) == .conflict);
    var changed = message;
    changed.text.file = null;
    changed.text.length += 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var changed_kind = try completeConfiguration("message", created_session_0.slice(), workspace, "model-a");
    try std.testing.expect(storage.configure(&changed_kind, true, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(created_session_0.slice())).pending_messages);
    try storage.close();
}

test "failed message import rolls back content command and admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const text = "larger than an empty import";
    const file = try tmp.dir.createFile(std.testing.io, "import-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message-import", created_session_0.slice(), file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .content_import = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("message-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(created_session_0.slice())).pending_messages);
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
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
        var storage = try testingStore(&tmp, std.testing.io);
        const configured = storage.configure(&configuration, true, .{});
        try std.testing.expect(configured == .accepted);
        message.session = configured.accepted.session;
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
        var later = try completeConfiguration("rollback-later", "", workspace, "model-a");
        try std.testing.expect(storage.configure(&later, true, .{}) == .infrastructure_failure);
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
        var storage = try testingStore(&tmp, std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 2), try pragmaInt(storage.database, "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4194304), try pragmaInt(storage.database, "PRAGMA journal_size_limit"));
    try std.testing.expectEqualStrings("exclusive", (diagnosticTextPragma(storage.database, "PRAGMA locking_mode") orelse return error.TestUnexpectedResult).slice());
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
    const statement = prepare(raw.?, "SELECT count(*) FROM content") catch return null;
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

    var storage = try Store.open(io, database, paths.store.slice());
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    try exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,NULL)");
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
    if (Store.open(io, database, paths.store.slice())) |_| return error.TestUnexpectedResult else |_| {}
    // The failed open released the process-wide heap limit; restore it.
    _ = c.sqlite3_hard_heap_limit64(sqlite_heap_bytes);

    // A process crash leaves exactly these files; the WAL holds the commits.
    try cwd.copyFile(database, tmp.dir, "crash/rui.sqlite3", io, .{});
    try cwd.copyFile(wal, tmp.dir, "crash/rui.sqlite3-wal", io, .{});
    try cwd.copyFile(database, tmp.dir, "database-only/rui.sqlite3", io, .{});

    // A payload past the auto-checkpoint size moves into the database file,
    // and the next commit truncates the reset WAL to the size limit.
    try exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),6291456,0,zeroblob(6291456))");
    try exec(storage.database, "INSERT INTO content(digest,byte_length,private,payload) VALUES(randomblob(32),0,0,NULL)");
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
    storage = try Store.open(io, database, paths.store.slice());
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
    try storage.close();
    // Model the prior format's rollback-journal header; rejection must
    // happen before the WAL switch, leaving that Store unmodified.
    {
        var raw: ?*c.sqlite3 = null;
        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database}, 0), &raw));
        defer _ = c.sqlite3_close(raw);
        try exec(raw.?, "PRAGMA journal_mode=DELETE");
        try exec(raw.?, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version - 1}));
    }
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, database, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqual(@as(u8, 1), before[18]);

    try std.testing.expectError(
        error.WrongStoreVersion,
        Store.open(std.testing.io, database, root),
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
    var command = try completeConfiguration("create", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&command, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(storage.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSession(created_session_0.slice()));

    var later = try completeConfiguration("later", "", workspace, "model-a");
    try std.testing.expect(storage.configure(&later, true, .{}) == .infrastructure_failure);
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
    var command = try completeConfiguration("sealed", "", workspace, "model-a");
    command.configuration.instructions = .{
        .state = .value,
        .file = file,
        .length = captured.len,
        .digest = protocol.contentDigest(captured),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    const created_session_0_reply = storage.configure(&command, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const observation = try storage.inspectSession(created_session_0.slice());
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
    var command = try completeConfiguration("changed", "", workspace, "model-a");
    command.configuration.instructions = .{
        .state = .value,
        .file = file,
        .length = captured.len,
        .digest = protocol.contentDigest("different bytes"),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    try std.testing.expect(storage.configure(&command, true, .{}) == .infrastructure_failure);
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

            var initial = try completeConfiguration("initial", "", workspace, "model-a");
            initial.configuration.instructions = try testingContent(&tmp, "original", 'a', length);
            defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
            var session: protocol.Bounded(protocol.max_session_bytes) = .{};
            if (deduplicated) {
                const configured = storage.configure(&initial, true, .{});
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
            try std.testing.expect(storage.configure(&command, true, .{ .content_read = case == .read_failure }) == .infrastructure_failure);
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
        var command = try completeConfiguration("read-probe", "", workspace, "model-a");
        const length = protocol.content_window_bytes * 2 + 17;
        command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        if (change == .none) {
            const created_session_0_reply = storage.configure(&command, true, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            try std.testing.expectEqual(length, Probe.bytes_read);
            Probe.bytes_read = 0;
            try command.key.set("deduplicated");
            command.session = created_session_0;
            try std.testing.expect(storage.configure(&command, true, .{}) == .accepted);
            try std.testing.expectEqual(length, Probe.bytes_read);
        } else {
            try std.testing.expect(storage.configure(&command, true, .{}) == .infrastructure_failure);
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
    var command = try completeConfiguration("first", "", workspace, "model-a");
    const length = protocol.content_window_bytes * 2 + 17;
    command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    const created_session_0_reply = storage.configure(&command, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try command.key.set("second");
    command.session = created_session_0;
    try std.testing.expect(storage.configure(&command, true, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    const observation = try storage.inspectSession(created_session_0.slice());
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

test "large raw content opens without materializing its payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    const created_session_0_reply = storage.configure(&command, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    var reader = try storage.openContent(reference);
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("public-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    var request = protocol.ConversationPage{};
    try request.session.set(created_session_0.slice());
    try std.testing.expectEqual(@as(usize, 0), (try storage.publicConversationPage(request)).count);

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
        try std.testing.expect(storage.submitMessage(&command, .{}) == .accepted);
        try command.removeTemporaryContent(std.testing.io);
    }
    try std.testing.expectEqual(@as(usize, 0), (try storage.publicConversationPage(request)).count);
    var instruction: protocol.ConfigureCommand = .{};
    try instruction.key.set("public-instruction-before-selection");
    try instruction.session.set(created_session_0.slice());
    instruction.configuration.instructions = try testingContent(&tmp, "public-instruction-before", 's', 7);
    defer instruction.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instruction, true, .{}) == .accepted);
    const active = (try storage.admitNextModelAttempt(.{})).?;
    const first = try storage.publicConversationPage(request);
    try std.testing.expectEqual(@as(usize, 16), first.count);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(u64, 40), first.items[0].position);
    try std.testing.expectEqual(@as(u64, 25), first.items[15].position);
    for (first.items[0..first.count]) |item| try std.testing.expect(item.kind == .user);
    try std.testing.expectEqual(@as(u64, 5), first.items[0].content.length);
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPage(.{
        .session = request.session,
        .end = first.end,
        .before_position = first.items[15].position,
        .before_ordinal = 1,
    }));
    try std.testing.expect(!storage.isFenced());
    var unicode_reader = try storage.openPublicConversationContent(.{ .session = request.session, .position = 40 });
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
    try std.testing.expect(storage.configure(&later, true, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "after-page", "after-page-key", created_session_0.slice(), "later public input");
    try storage.settleModelAttemptFailure(active.permit.binding, .{ .uncorrelated = "fixture_failure" }, .ordinary, .{});
    _ = (try storage.admitNextModelAttempt(.{})).?;
    const fixed_first = try storage.publicConversationPage(.{ .session = request.session, .end = first.end });
    try std.testing.expectEqual(first.end, fixed_first.end);
    try std.testing.expectEqual(first.count, fixed_first.count);
    for (first.items[0..first.count], fixed_first.items[0..fixed_first.count]) |expected, actual| {
        try std.testing.expectEqual(expected.position, actual.position);
        try std.testing.expectEqual(expected.ordinal, actual.ordinal);
    }
    request.end = first.end;
    request.before_position = first.items[15].position;
    const older = try storage.publicConversationPage(request);
    try std.testing.expectEqual(@as(usize, 4), older.count);
    try std.testing.expect(!older.more);
    try std.testing.expectEqual(@as(u64, 24), older.items[0].position);
    try std.testing.expectEqual(@as(u64, 21), older.items[3].position);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), older.items[3].content.length);
    const fresh = try storage.publicConversationPage(.{ .session = request.session });
    try std.testing.expectEqual(@as(usize, 16), fresh.count);
    try std.testing.expect(fresh.items[0].position > first.end);
    try std.testing.expect(fresh.items[0].kind == .user);
    var read = protocol.ConversationContent{ .session = request.session, .position = older.items[3].position, .start = 1024 * 1024 - 2 };
    var reader = try storage.openPublicConversationContent(read);
    var tail: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.read(read.start, &tail));
    try std.testing.expectEqualStrings("xx", &tail);
    reader.close();
    read.position = 41; // the applied instruction is not public content
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(read));
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(.{ .session = .{}, .position = 1 }));
    try std.testing.expectError(error.RangeOutOfBounds, storage.openPublicConversationContent(.{ .session = request.session, .position = 21, .start = 1024 * 1024 + 1 }));
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPage(.{ .session = request.session, .end = first.end + 100, .before_position = 1 }));
    try std.testing.expect(!storage.isFenced());
}

test "public content SQL failure fences Store instead of reporting absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectError(error.StatementPrepareFailed, storage.openPublicConversationContent(request));
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(request));
}

test "public content SQLite step failure fences after successful preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "step-config");
    try submitTestMessage(&storage, &tmp, "step-input", "step-key", session.slice(), "step text");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationContent{ .position = 1 };
    try request.session.set(session.slice());
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(.{ .session = request.session, .position = 999 }));
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
    try std.testing.expectError(error.ConversationReadFailed, storage.openPublicConversationContent(request));
    try std.testing.expect(interrupt.interrupted_step);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.openPublicConversationContent(request));
}

const TestingPublicReadRoute = enum { page, content, cursor };

fn testingOrdinaryPublicCorruption(route: TestingPublicReadRoute, foreign_turn: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "ordinary-config");
    try submitTestMessage(&storage, &tmp, "ordinary-input", "ordinary-key", session.slice(), "public input");
    _ = (try storage.admitNextModelAttempt(.{})).?;
    var request = protocol.ConversationPage{};
    request.session = session;
    const valid = try storage.publicConversationPage(request);
    try std.testing.expectEqual(@as(usize, 1), valid.count);
    try std.testing.expect(valid.items[0].kind == .user);
    if (foreign_turn) {
        const foreign_session = try configureTestSession(&storage, "foreign-config");
        try submitTestMessage(&storage, &tmp, "foreign-input", "foreign-key", foreign_session.slice(), "other input");
        _ = (try storage.admitNextModelAttempt(.{})).?;
        const corrupt = try prepare(storage.database, "UPDATE conversation_entry SET turn_id=(SELECT turn_id FROM turn WHERE session_ref=?1) WHERE session_ref=?2 AND entry_kind=1");
        defer _ = c.sqlite3_finalize(corrupt);
        try bindText(corrupt, 1, foreign_session.slice());
        try bindText(corrupt, 2, session.slice());
        try expectDone(corrupt);
    } else {
        try execSessionSql(storage.database, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND entry_kind=1)", session.slice());
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
    request.end = valid.end;
    if (route == .cursor) request.before_position = valid.items[0].position;
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(.{ .session = request.session, .position = valid.items[0].position })) |reader_value| blk: {
            var reader = reader_value;
            reader.close();
            break :blk {};
        } else |err| err
    else if (storage.publicConversationPage(request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.publicConversationPage(request));
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

fn testingToolPublicCorruption(route: TestingPublicReadRoute, damage: enum { private, missing, sibling_ordinal, sibling_item_id, sibling_call_id, sibling_arguments }, target_sibling: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    const valid = try storage.publicConversationPage(request);
    try std.testing.expectEqual(@as(usize, 3), valid.count);
    const item = valid.items[if (target_sibling) 0 else 1];
    try std.testing.expect(item.kind == .tool_result and item.ordinal == (if (target_sibling) @as(u64, 2) else 1));
    {
        var reader = try storage.openPublicConversationContent(.{ .session = request.session, .position = item.position, .ordinal = item.ordinal });
        defer reader.close();
        var bytes: [64]u8 = undefined;
        const count = try reader.read(0, &bytes);
        try std.testing.expectEqualStrings(if (target_sibling) "Unknown tool: other." else "Unknown tool: unknown.", bytes[0..count]);
    }
    // Keep counts, acceptance positions and results intact for sibling damage:
    // reading the healthy highest ordinal must validate the entire group.
    switch (damage) {
        .sibling_ordinal => try exec(storage.database, "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0"),
        .sibling_item_id => try exec(storage.database, "UPDATE model_tool_call SET item_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0"),
        .sibling_call_id => try exec(storage.database, "UPDATE model_tool_call SET call_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0"),
        .sibling_arguments => try exec(storage.database, "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0"),
        .private => try exec(storage.database, "UPDATE content SET private=1 WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)"),
        .missing => {
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, "DELETE FROM content WHERE content_id=(SELECT rejection_content_id FROM model_tool_call WHERE call_ordinal=0)");
            try exec(storage.database, "PRAGMA foreign_keys=ON");
        },
    }
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
    request.end = item.position;
    if (route == .cursor) {
        request.before_position = item.position;
        request.before_ordinal = item.ordinal;
    }
    const result: anyerror!void = if (route == .content)
        if (storage.openPublicConversationContent(.{ .session = request.session, .position = item.position, .ordinal = item.ordinal })) |reader_value| blk: {
            var reader = reader_value;
            reader.close();
            break :blk {};
        } else |err| err
    else if (storage.publicConversationPage(request)) |_| {} else |err| err;
    try std.testing.expectError(error.CorruptStore, result);
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(error.StoreFenced, storage.publicConversationPage(request));
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
        try testingToolPublicCorruption(route, .sibling_item_id, true);
        try testingToolPublicCorruption(route, .sibling_call_id, true);
        try testingToolPublicCorruption(route, .sibling_arguments, true);
        try testingToolPublicCorruption(route, .private, true);
        try testingToolPublicCorruption(route, .missing, true);
    }
}

test "public completed Action sibling corruption fences first Conversation read" {
    const faults = [_][:0]const u8{
        "UPDATE model_tool_call SET item_ordinal=item_ordinal+1000 WHERE call_ordinal=0",
        "UPDATE model_tool_call SET item_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE model_tool_call SET call_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE model_tool_call SET arguments_content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
        "UPDATE content SET private=1 WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
        "DELETE FROM content WHERE content_id=(SELECT resolution_content_id FROM action_operation WHERE call_ordinal=0)",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
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
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try exec(storage.database, "PRAGMA foreign_keys=ON");
            var request: protocol.ConversationPage = .{ .end = position };
            try request.session.set(session.slice());
            if (route == .cursor) {
                request.before_position = position;
                request.before_ordinal = 2;
            }
            const result: anyerror!void = if (route == .content)
                if (storage.openPublicConversationContent(.{ .session = request.session, .position = position, .ordinal = 2 })) |value| blk: {
                    var reader = value;
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.publicConversationPage(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.publicConversationPage(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "private-only model output never becomes public conversation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "private-config");
    try submitTestMessage(&storage, &tmp, "private-input", "private-message", session.slice(), "hi");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // Keep a successor queued: a terminal text Turn requires an answer, while
    // this intermediate accepted output contains only opaque continuation.
    try submitTestMessage(&storage, &tmp, "private-next", "private-next-message", session.slice(), "later");
    const bytes = "private continuation";
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
    try metadata.append(.{ .tag = .item, .kind = .reasoning, .start = 0, .length = bytes.len, .content_digest = protocol.contentDigest(bytes) });
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
    const page = try storage.publicConversationPage(request);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expect(page.items[0].kind == .user);
    try std.testing.expect(page.end > page.items[0].position);
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(.{
        .session = request.session,
        .position = page.end,
    }));
    try std.testing.expect(!storage.isFenced());
}

test "public tool-result cursor crosses a completed group boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    const newest = try storage.publicConversationPage(cursor);
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
    try std.testing.expectError(error.InvalidCursor, storage.publicConversationPage(cursor));
    try std.testing.expect(!storage.isFenced());
    cursor.before_ordinal = newest.items[15].ordinal;
    const older = try storage.publicConversationPage(cursor);
    try std.testing.expectEqual(@as(usize, 2), older.count);
    try std.testing.expect(!older.more);
    try std.testing.expectEqual(@as(u64, 1), older.items[0].ordinal);
    try std.testing.expect(older.items[0].kind == .tool_result);
    try std.testing.expect(older.items[1].kind == .user);
    var reader = try storage.openPublicConversationContent(.{ .session = cursor.session, .position = older.items[0].position, .ordinal = 1 });
    defer reader.close();
    var result: [64]u8 = undefined;
    const size = try reader.read(0, &result);
    try std.testing.expectEqualStrings("Unknown tool: unknown.", result[0..size]);
}

pub fn testingPublicProjection(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    parts: []const struct { encoded: []const u8, decoded: []const u8 },
) !protocol.ConversationContent {
    const session = try configureTestSession(storage, "projection-config");
    try submitTestMessage(storage, tmp, "projection-input", "projection-key", session.slice(), "input");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var capacity: usize = 2 + parts.len * 3;
    for (parts) |part| capacity += part.encoded.len;
    const source_buffer = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(source_buffer);
    var writer = std.Io.Writer.fixed(source_buffer);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root_buffer[0..root_length], "projection-metadata", .{ .used = &metadata_used, .limit = 4096 }, false, &retained);
    defer metadata.deinit();
    var digest = protocol.contentHasher();
    var decoded_length: u64 = 0;
    try writer.writeByte('[');
    for (parts, 0..) |part, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try metadata.append(.{ .tag = .text, .start = writer.buffered().len, .length = part.encoded.len, .decoded_length = part.decoded.len });
        try writer.writeAll(part.encoded);
        try writer.writeByte('"');
        digest.update(part.decoded);
        decoded_length += part.decoded.len;
    }
    try writer.writeByte(']');
    const bytes = writer.buffered();
    try metadata.append(.{ .tag = .item, .kind = .message, .start = 0, .length = bytes.len, .content_digest = protocol.contentDigest(bytes) });
    try metadata.sealForRead();
    const source = try tmp.dir.createFile(std.testing.io, "projection-source", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
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
    const page = try storage.publicConversationPage(.{ .session = session });
    try std.testing.expect(page.items[0].kind == .assistant);
    return .{ .session = session, .position = page.items[0].position };
}

test "public assistant message provenance binds the exact accepted item" {
    const faults = [_][:0]const u8{
        "DELETE FROM conversation_entry WHERE entry_kind=3",
        "UPDATE conversation_entry SET source_item_ordinal=source_item_ordinal+1 WHERE entry_kind=3",
        "UPDATE conversation_entry SET content_id=(SELECT content_id FROM conversation_entry WHERE entry_kind=1) WHERE entry_kind=3",
        "UPDATE model_output_item SET message_content_id=NULL WHERE item_kind=2",
        "UPDATE model_output_item SET attempt_ordinal=attempt_ordinal+1 WHERE item_kind=2",
        "UPDATE content SET private=0 WHERE content_id=(SELECT content_id FROM model_output_item WHERE item_kind=2)",
    };
    for (faults) |fault| {
        for ([_]enum { page, bytes, activity, activity_bytes, full }{ .page, .bytes, .activity, .activity_bytes, .full }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "visible", .decoded = "visible" }});
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try exec(storage.database, "PRAGMA foreign_keys=ON");
            try storage.close();
            storage = try testingStore(&tmp, std.testing.io);
            const result: anyerror!void = switch (route) {
                .page => if (storage.publicConversationPage(.{ .session = request.session })) |_| {} else |err| err,
                .bytes => if (storage.openPublicConversationContent(request)) |reader| blk: {
                    var owned = reader;
                    owned.close();
                    break :blk {};
                } else |err| err,
                .activity => if (storage.activityPage(.{ .session = request.session })) |_| {} else |err| err,
                .activity_bytes => if (storage.openActivityContent(.{ .session = request.session, .position = request.position })) |reader| blk: {
                    var owned = reader;
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const missing = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = "answer", .decoded = "answer" }});
        for (0..20) |index| {
            var key_buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "later-{d}", .{index});
            try submitTestMessage(&storage, &tmp, key, key, missing.session.slice(), "later user input");
        }
        _ = (try storage.admitNextModelAttempt(.{})).?;
        try exec(storage.database, "DELETE FROM conversation_entry WHERE entry_kind=3");
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        try storage.close();
        storage = try testingStore(&tmp, std.testing.io);
        // A historical window ending before the damage remains readable.
        _ = try storage.publicConversationPage(.{ .session = missing.session, .end = missing.position - 1 });
        _ = try storage.activityPage(.{ .session = missing.session, .end = missing.position - 1 });
        if (activity) {
            const latest = try storage.activityPage(.{ .session = missing.session, .direction = .backward });
            try std.testing.expect(latest.more);
            var cursor = latest.items[latest.count - 1];
            while (true) {
                const older = storage.activityPage(.{
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
            const latest = try storage.publicConversationPage(.{ .session = missing.session });
            try std.testing.expectEqual(@as(usize, 16), latest.count);
            try std.testing.expect(latest.more);
            try std.testing.expectError(error.CorruptStore, storage.publicConversationPage(.{
                .session = missing.session,
                .end = latest.end,
                .before_position = latest.items[latest.count - 1].position,
                .before_ordinal = latest.items[latest.count - 1].ordinal,
            }));
        }
        try std.testing.expect(storage.isFenced());
    }
}

test "public projected content sequential work excludes repeated prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const expected = &@as([32768]u8, @splat('a'));
    const request = try testingPublicProjection(&storage, &tmp, &.{.{ .encoded = expected, .decoded = expected }});
    storage.testing_content_work = .{};
    var window: [protocol.content_window_bytes]u8 = undefined;
    var reader = try storage.openPublicConversationContent(request);
    var offset: u64 = 0;
    while (offset < expected.len) : (offset += window.len) {
        try std.testing.expectEqual(window.len, try reader.readRange(offset, &window));
        try std.testing.expectEqualStrings(expected[@intCast(offset)..][0..window.len], &window);
    }
    reader.close();
    try std.testing.expectEqual(@as(u64, 32768), storage.testing_content_work.decoded.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    // Actual old endpoint work: eight fresh readers, not a timing estimate.
    storage.testing_content_work = .{};
    offset = 0;
    while (offset < expected.len) : (offset += window.len) {
        var ranged = try storage.openPublicConversationContent(request);
        defer ranged.close();
        try std.testing.expectEqual(window.len, try ranged.readRange(offset, &window));
        try std.testing.expectEqualStrings(expected[@intCast(offset)..][0..window.len], &window);
    }
    try std.testing.expectEqual(@as(u64, 147456), storage.testing_content_work.decoded.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 8), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
}

test "public projected content equal-length repoint fences at complete-stream EOF" {
    for ([_]bool{ false, true }) |range| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const request = try testingPublicProjection(&storage, &tmp, &.{
            .{ .encoded = &@as([2500]u8, @splat('a')), .decoded = &@as([2500]u8, @splat('a')) },
            .{ .encoded = &@as([2500]u8, @splat('b')), .decoded = &@as([2500]u8, @splat('b')) },
        });
        // Repoint to another valid, equal-length field in the same private source.
        // Metadata/provenance stay valid, but the complete public identity differs.
        try exec(storage.database, "UPDATE answer_text_projection SET encoded_start=(SELECT encoded_start FROM answer_text_projection WHERE part_ordinal=1) WHERE part_ordinal=0");
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        var reader = try storage.openPublicConversationContent(request);
        defer reader.close();
        var bytes: [4096]u8 = undefined;
        // An earlier range is not authenticated by an eventual EOF comparison.
        try std.testing.expectEqual(@as(usize, 4096), try reader.read(0, &bytes));
        try std.testing.expectEqualStrings(&@as([4096]u8, @splat('b')), &bytes);
        try std.testing.expect(!storage.isFenced());
        // Both serial consumption and a range that discards the middle must
        // include every decoded byte in complete-stream consistency checking.
        try std.testing.expectError(error.CorruptStore, if (range) reader.readRange(4990, &bytes) else reader.read(4096, &bytes));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, reader.read(5000, &bytes));
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    }
}

test "public projected content EOF rejects nonempty trailing parts" {
    for ([_]u64{ 7, 8 }) |start| {
        for ([_]struct { ordinal: u64, encoded: u64, decoded: u64 }{
            .{ .ordinal = 3, .encoded = 1, .decoded = 1 },
            .{ .ordinal = 4, .encoded = 1, .decoded = 0 },
            .{ .ordinal = 4, .encoded = 0, .decoded = 1 },
        }) |tail| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const request = try testingPublicProjection(&storage, &tmp, &.{
                .{ .encoded = "prefix-x", .decoded = "prefix-x" },
                .{ .encoded = "", .decoded = "" },
                .{ .encoded = "", .decoded = "" },
            });
            {
                // Keep the advertised prefix/digest intact. The unexpected
                // tail follows empty parts and can also follow an ordinal gap.
                const insert = try prepare(storage.database, "INSERT INTO answer_text_projection " ++
                    "SELECT answer_content_id,?1,source_content_id,encoded_start,?2,?3 FROM answer_text_projection WHERE part_ordinal=0");
                defer _ = c.sqlite3_finalize(insert);
                try bindU64(insert, 1, tail.ordinal);
                try bindU64(insert, 2, tail.encoded);
                try bindU64(insert, 3, tail.decoded);
                try expectDone(insert);
                try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            }
            var reader = try storage.openPublicConversationContent(request);
            defer reader.close();
            var bytes: [1]u8 = undefined;
            try std.testing.expectError(error.CorruptStore, reader.readRange(start, &bytes));
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, reader.readRange(8, &bytes));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "public projected content trailing empty parts retain final byte and repeated EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const request = try testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = "prefix-x", .decoded = "prefix-x" },
        .{ .encoded = "", .decoded = "" },
        .{ .encoded = "", .decoded = "" },
    });
    var reader = try storage.openPublicConversationContent(request);
    defer reader.close();
    var bytes: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reader.readRange(7, &bytes));
    try std.testing.expectEqualStrings("x", &bytes);
    try std.testing.expectEqual(@as(usize, 0), try reader.readRange(8, &bytes));
    try std.testing.expectEqual(@as(usize, 0), try reader.readRange(8, &bytes));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
}

test "public projected content ranges own positioning across windows and scalar splits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const expected = @as([4094]u8, @splat('x')) ++ "é中🙂\n\\\"/tail";
    const request = try testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = @as([4094]u8, @splat('x')) ++ "\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/", .decoded = @as([4094]u8, @splat('x')) ++ "é中🙂\n\\\"/" },
        .{ .encoded = "", .decoded = "" },
        .{ .encoded = "tail", .decoded = "tail" },
    });
    var reader = try storage.openPublicConversationContent(request);
    const reference = reader.reference;
    try std.testing.expectEqual(@as(u64, expected.len), reference.length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected), &reference.digest);
    var bytes: [5]u8 = undefined;
    // Nonmonotonic byte positions force both forward discard and a reset.
    for ([_]u64{ 4095, 0, 4096, expected.len - 1, expected.len, expected.len, 1, 4094 }) |start| {
        const count = try reader.readRange(start, &bytes);
        const wanted = @min(bytes.len, expected.len - start);
        try std.testing.expectEqual(wanted, count);
        try std.testing.expectEqualStrings(expected[@intCast(start)..][0..count], bytes[0..count]);
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    }
    try std.testing.expectError(error.RangeOutOfBounds, reader.readRange(expected.len + 1, &bytes));
    var oversized: [ContentReader.content_window_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.WindowTooLarge, reader.readRange(0, &oversized));
    try std.testing.expect(!storage.isFenced());
    reader.close();
    try std.testing.expectEqualStrings("é中", &bytes);
    // Copied bytes and immutable identity survive closing the reader.
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected), &reference.digest);
}

test "public projected content empty identity and repeated EOF" {
    for ([_]bool{ false, true }) |corrupt| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        // Empty assistant output has no Conversation row. Exercise the
        // canonical projected reader directly, as used by empty call fields.
        _ = try storage.importBytesContent("", false, false);
        try exec(storage.database, "UPDATE content SET payload=NULL WHERE byte_length=0");
        const digest = protocol.contentDigest(if (corrupt) "not empty" else "");
        if (corrupt) {
            // Persist corruption before opening: no mutation of a reader's
            // trusted reference can substitute for a damaged canonical row.
            const statement = try prepare(storage.database, "UPDATE content SET digest=?1 WHERE payload IS NULL AND byte_length=0");
            defer _ = c.sqlite3_finalize(statement);
            try bindBlob(statement, 1, &digest);
            try expectDone(statement);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        }
        var reader = try storage.openContent(.{ .length = 0, .digest = digest });
        defer reader.close();
        var bytes: [1]u8 = undefined;
        if (corrupt) {
            try std.testing.expectError(error.CorruptStore, reader.readRange(0, &bytes));
            try std.testing.expect(storage.isFenced());
        } else {
            try std.testing.expectEqual(@as(usize, 0), try reader.readRange(0, &bytes));
            try std.testing.expectEqual(@as(usize, 0), try reader.readRange(0, &bytes));
            try std.testing.expect(!storage.isFenced());
        }
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    }
}

test "public projected content range positioning preserves decoding and backing faults" {
    for ([_]bool{ false, true }) |missing| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const request = try testingPublicProjection(&storage, &tmp, &.{
            .{ .encoded = "\\n", .decoded = "\n" },
            .{ .encoded = "z", .decoded = "z" },
        });
        if (missing) {
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, "DELETE FROM content WHERE content_id=(SELECT source_content_id FROM answer_text_projection LIMIT 1)");
            try exec(storage.database, "PRAGMA foreign_keys=ON");
        } else {
            const invalid_source = try storage.importBytesContent("\"\\q\"", true, false);
            const statement = try prepare(storage.database, "UPDATE answer_text_projection SET source_content_id=?1,encoded_start=1 WHERE part_ordinal=0");
            defer _ = c.sqlite3_finalize(statement);
            try bindI64(statement, 1, invalid_source);
            try expectDone(statement);
        }
        if (missing) {
            // Exact message provenance now rejects its absent raw item before
            // exposing a reader, rather than waiting for a projection read.
            try std.testing.expectError(error.CorruptStore, storage.openPublicConversationContent(request));
            try std.testing.expect(storage.isFenced());
            continue;
        }
        var reader = try storage.openPublicConversationContent(request);
        defer reader.close();
        var bytes: [1]u8 = undefined;
        try std.testing.expectError(error.InvalidJsonEscape, reader.readRange(1, &bytes));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
    }
}

test "definite rejections retain decisions without retaining payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("initial", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&initial, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    try execSessionSql(storage.database, "UPDATE session SET revision=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());

    var unknown_message: protocol.MessageCommand = .{};
    try unknown_message.key.set("unknown-message");
    try unknown_message.session.set("absent");
    unknown_message.text = try testingContent(&tmp, "unknown-message", 'm', 64 * 1024);
    defer unknown_message.removeTemporaryContent(std.testing.io) catch unreachable;
    const unknown_reply = storage.submitMessage(&unknown_message, .{});
    try std.testing.expect(unknown_reply == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, unknown_reply.rejected.code);

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    incomplete.configuration.instructions = try testingContent(&tmp, "incomplete", 'i', 64 * 1024);
    defer incomplete.removeTemporaryContent(std.testing.io) catch unreachable;
    const incomplete_reply = storage.configure(&incomplete, true, .{});
    try std.testing.expect(incomplete_reply == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, incomplete_reply.rejected.code);

    var exhausted: protocol.ConfigureCommand = .{};
    try exhausted.key.set("exhausted");
    try exhausted.session.set(created_session_0.slice());
    exhausted.configuration.instructions = try testingContent(&tmp, "exhausted", 'e', 64 * 1024);
    defer exhausted.removeTemporaryContent(std.testing.io) catch unreachable;
    const exhausted_reply = storage.configure(&exhausted, true, .{});
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
    try std.testing.expect(storage.configure(&incomplete, true, .{}).rejected.replayed);
    try std.testing.expect(storage.configure(&exhausted, true, .{}).rejected.replayed);

    var changed = unknown_message;
    changed.text.digest[0] ^= 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var retargeted = incomplete;
    try retargeted.session.set("0ther0");
    try std.testing.expect(storage.configure(&retargeted, true, .{}) == .conflict);
    var changed_kind: protocol.MessageCommand = .{};
    try changed_kind.key.set("incomplete");
    try changed_kind.session.set("absent");
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
    var configuration = try completeConfiguration("configure", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;

    const first_file = try tmp.dir.createFile(std.testing.io, "dispatch-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage("dispatch-1", created_session_0.slice(), first_file, "first");
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);

    const second_file = try tmp.dir.createFile(std.testing.io, "dispatch-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage("dispatch-2", created_session_0.slice(), second_file, "second");
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&second, .{}) == .accepted);

    var instructions_update: protocol.ConfigureCommand = .{};
    try instructions_update.key.set("instructions-before-selection");
    try instructions_update.session.set(created_session_0.slice());
    instructions_update.configuration.instructions = try testingContent(&tmp, "instructions-before", 'b', 1);
    defer instructions_update.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&instructions_update, true, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("dispatch-1"));
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect(
        (try storage.observeCommand("dispatch-1")).message.?.queue.?.state == .queued,
    );

    // Failed admission publishes neither projection nor instruction inclusion.
    try std.testing.expectEqual(@as(i64, 0), try pragmaInt(storage.database, "SELECT count(*) FROM conversation_entry"));
    try std.testing.expectEqual(@as(i64, 3), try pragmaInt(storage.database, "SELECT next_position FROM session"));

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const second_observation = (try storage.observeCommand("dispatch-2")).message.?.queue.?;
    try std.testing.expectEqual(MessageProgress.Status.in_flight, (try storage.observeCommand("dispatch-1")).message.?.progress.?.status);
    try std.testing.expectEqual(MessageProgress.Status.in_flight, (try storage.observeCommand("dispatch-2")).message.?.progress.?.status);
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
    try std.testing.expect(storage.submitMessage(&third, .{}) == .accepted);
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = storage.configure(&update, true, .{});
    try std.testing.expect(active_update == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.model_is_immutable,
        active_update.rejected.code,
    );
    try expectBindingPreserved(&storage, created_session_0.slice(), "during-work");

    var view = try storage.openHistoricalView(binding);
    defer if (view.active) view.close();
    const settings = try view.settings();
    try std.testing.expectEqual(protocol.Provider.codex, settings.provider);
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    try std.testing.expectEqual(@as(u8, 1), settings.tools_mask);
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
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(created_session_0.slice())).pending_messages);

    try update.key.set("configure-after-failure");
    const failed_update = storage.configure(&update, true, .{});
    try std.testing.expect(failed_update == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.model_is_immutable, failed_update.rejected.code);
    try expectBindingPreserved(&storage, created_session_0.slice(), "after-failure");

    var tools_update: protocol.ConfigureCommand = .{};
    try tools_update.key.set("tools-after-failure");
    try tools_update.session.set(created_session_0.slice());
    tools_update.configuration.tools.state = .value;
    tools_update.configuration.tools.count = 0;
    try std.testing.expect(storage.configure(&tools_update, true, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view = try storage.openHistoricalView(later.permit.binding);
    defer later_view.close();
    const later_settings = try later_view.settings();
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

test "continued accepted output keeps model immutable and public projection readable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "continued-config",
        "",
        workspace,
        "model-a",
    );
    const created_session_0_reply = storage.configure(&configuration, true, .{});
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
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);
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
        .tag = .text,
        .start = 1,
        .length = "answer".len,
        .decoded_length = "answer".len,
    });
    try metadata.append(.{
        .tag = .item,
        .kind = .message,
        .start = 0,
        .length = source_bytes.len,
        .content_digest = protocol.contentDigest(source_bytes),
    });
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
    const public_page = try storage.publicConversationPage(public_request);
    try std.testing.expectEqual(@as(usize, 2), public_page.count);
    try std.testing.expect(public_page.items[0].kind == .assistant);
    var public_reader = try storage.openPublicConversationContent(.{ .session = public_request.session, .position = public_page.items[0].position });
    try std.testing.expect(public_reader.representation == .projection);
    {
        const backing = try prepare(storage.database, "SELECT exposed.private,source.private FROM answer_text_projection projection " ++
            "JOIN content exposed ON exposed.content_id=projection.answer_content_id " ++
            "JOIN content source ON source.content_id=projection.source_content_id WHERE projection.answer_content_id=?1");
        defer _ = c.sqlite3_finalize(backing);
        try bindI64(backing, 1, public_reader.content_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(backing));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(backing, 0));
        try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(backing, 1));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(backing));
    }
    var decoded: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try public_reader.read(0, &decoded));
    try std.testing.expectEqualStrings("answer", &decoded);
    public_reader.close();
    const before_answer = try storage.publicConversationPage(.{
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
        const resolution = try prepare(
            storage.database,
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(96) = .{};
        try readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("answer", code.slice());
    }

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set(created_session_0.slice());
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const rejected = storage.configure(&update, true, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.model_is_immutable,
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
        var failure: ModelFailure = .{ .rejected = .{ .code = "unsupported_provider_output", .diagnostic = detail, .request_id = .{} } };
        try failure.rejected.request_id.set(request_id);
        var binding: AttemptBinding = undefined;
        var session: protocol.Bounded(protocol.max_session_bytes) = undefined;
        var original_content: u64 = 0;
        {
            var storage = try testingStore(&tmp, std.testing.io);
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expectEqual(original_content, try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE resolution_code IS NOT NULL OR resolution_content_id IS NOT NULL OR request_id IS NOT NULL"));
            try storage.settleModelAttemptFailure(binding, failure, .ordinary, .{});
        }
        {
            var storage = try testingStore(&tmp, std.testing.io);
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "diagnostic-config");
        try submitTestMessage(&storage, &tmp, "diagnostic-input", "diagnostic-message", session.slice(), "input");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try storage.settleModelAttemptFailure(binding, .{ .rejected = .{
            .code = "unsupported_provider_output",
            .diagnostic = "{\"reason\":\"UnsupportedMessagePhase\"}",
            .request_id = .{},
        } }, .ordinary, .{});
        const healthy = try storage.publicConversationPage(.{ .session = session });
        try std.testing.expectEqual(@as(usize, 1), healthy.count);
        try std.testing.expect(healthy.items[0].kind == .user);
        const position = try queryU64(storage.database, "SELECT next_position FROM session");
        try exec(storage.database, "PRAGMA foreign_keys=OFF");
        try exec(storage.database, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id) " ++
            "SELECT o.session_ref,2,s.next_position,3,o.turn_id,o.operation_id,0,o.resolution_content_id " ++
            "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref");
        try exec(storage.database, "PRAGMA foreign_keys=ON");
        try exec(storage.database, "UPDATE session SET next_position=next_position+1");
        const result: anyerror!void = switch (route) {
            .conversation => if (storage.publicConversationPage(.{ .session = session })) |_| {} else |err| err,
            .activity => if (storage.activityPage(.{ .session = session })) |_| {} else |err| err,
            .conversation_content => if (storage.openPublicConversationContent(.{ .session = session, .position = position })) |value| blk: {
                var reader = value;
                reader.close();
                break :blk {};
            } else |err| err,
            .activity_content => if (storage.openActivityContent(.{ .session = session, .position = position })) |value| blk: {
                var reader = value;
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
        var storage = try testingStore(&tmp, std.testing.io);
        const created_session_0_reply = storage.configure(&configuration, true, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        created_session_0 = created_session_0_reply.accepted.session;
        const message_file = try tmp.dir.createFile(std.testing.io, "failure-message", .{ .read = true });
        try message_file.writeStreamingAll(std.testing.io, "fail");
        try message_file.sync(std.testing.io);
        var message = try completeMessage("failure-message", created_session_0.slice(), message_file, "fail");
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
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
        try expectActivityOutcome(&storage, created_session_0.slice(), replacement_binding, "retry_exhausted");
    }
}

test "HTTP status failures keep the settling Attempt's provider correlation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "correlation-config");
    try submitTestMessage(&storage, &tmp, "correlation-input", "correlation-message", session.slice(), "retry");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const request_ids = [_][]const u8{ "attempt-1", "", "attempt-3", "attempt-\"4\"" };
    for (request_ids, 1..) |request_id, ordinal| {
        try std.testing.expectEqual(@as(u64, ordinal), binding.attempt_ordinal);
        var failure: ModelFailure = .{ .correlated = .{ .code = "provider_temporary_http_503", .request_id = .{} } };
        try failure.correlated.request_id.set(request_id);
        try storage.settleModelAttemptFailure(binding, failure, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
        var resolution: protocol.Bounded(96) = .{};
        var recorded: protocol.Bounded(256) = .{};
        {
            const statement = try prepare(storage.database, "SELECT coalesce(resolution_code,''),coalesce(request_id,'') FROM model_operation WHERE operation_id=?1");
            defer _ = c.sqlite3_finalize(statement);
            try bindU64(statement, 1, binding.operation_id);
            try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
            try readText(statement, 0, &resolution);
            try readText(statement, 1, &recorded);
        }
        if (ordinal < request_ids.len) {
            // A scheduled retry has not settled the Operation; the next
            // Attempt's answer will.
            try std.testing.expectEqualStrings("", resolution.slice());
            try std.testing.expectEqualStrings("", recorded.slice());
            try exec(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE retry_due_at_ms IS NOT NULL");
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
    var ordinary: ModelFailure = .{ .correlated = .{ .code = "provider_http_403", .request_id = .{} } };
    try ordinary.correlated.request_id.set("terminal-\"request\"-é");
    try storage.settleModelAttemptFailure(correlated, ordinary, .ordinary, .{});
    {
        const statement = try prepare(storage.database, "SELECT request_id FROM model_operation WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, correlated.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        var recorded: protocol.Bounded(256) = .{};
        try readText(statement, 0, &recorded);
        try std.testing.expectEqualStrings("terminal-\"request\"-é", recorded.slice());
    }

    // A provider answer without correlation records none.
    try submitTestMessage(&storage, &tmp, "uncorrelated-input", "uncorrelated-message", session.slice(), "fail");
    const terminal = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(terminal, .{ .correlated = .{ .code = "provider_http_401", .request_id = .{} } }, .ordinary, .{});
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM model_operation WHERE request_id IS NULL AND resolution_code='provider_http_401'"));
}

test "temporary model failures conserve allowance and exhaust after four Attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("retry-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const message_file = try tmp.dir.createFile(std.testing.io, "retry-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "retry me");
    try message_file.sync(std.testing.io);
    var message = try completeMessage("retry-message", created_session_0.slice(), message_file, "retry me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);

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
        const statement = try prepare(
            storage.database,
            "SELECT uncertain,retry_due_at_ms,last_failure_code,resolution_code " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, first.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 0));
        try std.testing.expectEqual(std.math.maxInt(i64), c.sqlite3_column_int64(statement, 1));
        var failure: protocol.Bounded(96) = .{};
        try readText(statement, 2, &failure);
        try std.testing.expectEqualStrings("provider_temporary_http_429", failure.slice());
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    }

    // Make this fixture's operation eligible explicitly; admission still uses
    // the real Store transition and checks the allowance and stale binding.
    {
        const due = try prepare(storage.database, "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?1");
        defer _ = c.sqlite3_finalize(due);
        try bindU64(due, 1, first.operation_id);
        try expectDone(due);
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

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "", workspace, "model-a");
    const created_session_0_reply = storage.configure(&configuration, true, .{});
    try std.testing.expect(created_session_0_reply == .accepted);
    const created_session_0 = created_session_0_reply.accepted.session;
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", created_session_0.slice(), file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    var admitted_attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted_attempt.permit.consume();

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try execSessionSql(storage.database, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref=?1", created_session_0.slice());
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    var view = try storage.openHistoricalView(binding);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, view.settings());
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "request_preparation_failed" }, .ordinary, .{}),
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
    // Query-only populations use canonical six-byte fixtures, not named
    // Session creation. Command keys retain their independent text identities.
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
                    "INSERT INTO session(session_ref,workspace,provider,model,instructions_content_id,tools_mask,permission_mode," ++
                        "output_schema_content_id,revision,next_position) VALUES('st0ped','/','codex','model-a',1,0,0,NULL,1,1)",
                );
                const insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT value,'st0ped',printf('stopped-%d',value),1,NULL,1 FROM sequence; " ++
                        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) " ++
                        "VALUES('stop','st0ped',NULL,{0})",
                    .{ineligible},
                    0,
                );
                defer std.testing.allocator.free(insert);
                try exec(database, insert);
            }
            const eligible_insert = try std.testing.allocator.printSentinel(
                "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO session(session_ref,workspace,provider,model,instructions_content_id,tools_mask,permission_mode," ++
                    "output_schema_content_id,revision,next_position) " ++
                    "SELECT printf('%06d',value),'/','codex','model-a',1,0,0,NULL,1,1 FROM sequence; " ++
                    "WITH RECURSIVE sequence(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM sequence WHERE value+1<{0}) " ++
                    "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                    "SELECT {1}+value,printf('%06d',value),printf('eligible-%d',value),1,NULL,1 FROM sequence",
                .{ eligible, ineligible + 1 },
                0,
            );
            defer std.testing.allocator.free(eligible_insert);
            try exec(database, eligible_insert);
            if (history != 0) {
                const history_insert = try std.testing.allocator.printSentinel(
                    "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,turn_id,admitted_at) " ++
                        "SELECT {1}+value,'h1st0r',printf('history-%d',value),1,value,1 FROM sequence",
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
            if (!session_ref.eql("000000")) return error.RunnableSelectionFailed;
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
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{0}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,9223372036854775807,0 FROM sequence; " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) VALUES" ++
                "({1},{1},'0der00',1,1,1,1,1,0,99,0),({2},{2},'ear1er',1,1,1,1,1,0,1,0)",
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
        const insert = try std.testing.allocator.printSentinel(
            "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<{d}) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) " ++
                "SELECT value,value,printf('%06d',value),1,1,1,1,1,0,1,0 FROM sequence",
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
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) VALUES" ++
            "(1,1,'000001',1,1,1,1,1,0,99,0)," ++
            "(2,2,'000002',1,1,1,1,1,0,50,0)," ++
            "(3,3,'000003',1,1,1,1,1,0,1,0)",
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
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) " ++
            "SELECT value,value,printf('%06d',value),1,1,1,1,1,0," ++
            "CASE WHEN value<=100 THEN 9223372036854775807 ELSE 1 END,0 FROM sequence",
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
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(@as(usize, 5150), comparisons);
    comparisons = 0;
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, 201), admitted.permit.binding.operation_id);
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.attempt_ordinal);
    try std.testing.expectEqual(@as(usize, 5150), comparisons);

    try exec(storage.database, "DELETE FROM model_operation");
    for (6000..6102) |value| {
        var buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "exhausted-{d}", .{value});
        const session = try configureTestSession(&storage, key);
        const insert_turn = try prepare(storage.database, "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) VALUES(?1,?2,1,1,?1)");
        defer _ = c.sqlite3_finalize(insert_turn);
        try bindU64(insert_turn, 1, value);
        try bindText(insert_turn, 2, session.slice());
        try expectDone(insert_turn);
        const insert_operation = try prepare(storage.database, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,output_reservation) " ++
            "VALUES(?1,?1,?2,1,1,1,4,4,1,0,0)");
        defer _ = c.sqlite3_finalize(insert_operation);
        try bindU64(insert_operation, 1, value);
        try bindText(insert_operation, 2, session.slice());
        try expectDone(insert_operation);
    }
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

test "public proposal structural corruption fences independently on every route" {
    const faults = [_][:0]const u8{
        "UPDATE content SET private=1,payload=zeroblob(byte_length) WHERE content_id=(SELECT arguments_content_id FROM model_tool_call WHERE call_ordinal=0)",
        "DELETE FROM model_tool_call WHERE call_ordinal=0",
        "UPDATE turn SET session_ref='f0re1g'",
        "UPDATE model_tool_call SET item_id_content_id=(SELECT item_id_content_id FROM model_tool_call WHERE call_ordinal=1) WHERE call_ordinal=0",
    };
    for (faults) |fault| {
        for ([_]TestingPublicReadRoute{ .page, .cursor, .content }) |route| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
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
            const healthy = try storage.proposalPage(request);
            try std.testing.expectEqual(@as(usize, 2), healthy.count);
            const item = healthy.items[0];
            try std.testing.expectEqual(binding.operation_id, item.operation);
            try std.testing.expectEqual(binding.turn_id, item.turn);
            try std.testing.expectEqual(@as(u64, 0), item.call_ordinal);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("original"), &item.fields[0].digest);
            try exec(storage.database, "PRAGMA foreign_keys=OFF");
            try exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            try exec(storage.database, "PRAGMA foreign_keys=ON");
            request.end = healthy.end;
            if (route == .cursor) request.after = item.position;
            const result: anyerror!void = if (route == .content)
                if (storage.openProposalField(.{ .session = request.session, .position = item.position, .field = .item_id })) |value| blk: {
                    var reader = value;
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.proposalPage(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.proposalPage(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "proposal callable cursor domain preserves healthy Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSessionAsk(&storage, "proposal-config");
    var request: protocol.ProposalPage = .{};
    try request.session.set(session.slice());
    request.end = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidCursor, storage.proposalPage(request));
    request.end = null;
    request.after = 1;
    try std.testing.expectError(error.InvalidCursor, storage.proposalPage(request));
    request.end = 0;
    request.after = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidCursor, storage.proposalPage(request));
    request.after = 0;
    const page = try storage.proposalPage(request);
    try std.testing.expectEqual(@as(u64, 0), page.end);
    try std.testing.expectEqual(@as(usize, 0), page.count);
    try std.testing.expect(!page.more and !storage.isFenced());
    try std.testing.expectError(error.ContentNotFound, storage.openProposalField(.{ .position = std.math.maxInt(u64) }));
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "message", session.slice(), "input bytes");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            const queued = try storage.activityPage(request);
            try std.testing.expectEqual(@as(usize, 1), queued.count);
            const item = queued.items[0];
            try std.testing.expectEqualStrings("message", item.value.admission.key.slice());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("input bytes"), &item.value.admission.content.digest);
            _ = (try storage.admitNextModelAttempt(.{})).?;
            try exec(storage.database, fault);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            request.position = item.position - 1;
            const result: anyerror!void = if (content_route)
                if (storage.openActivityContent(.{ .session = request.session, .position = item.position })) |value| blk: {
                    var reader = value;
                    reader.close();
                    break :blk {};
                } else |err| err
            else if (storage.activityPage(request)) |_| {} else |err| err;
            try std.testing.expectError(error.CorruptStore, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.activityPage(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "activity fixed admission prefix survives later application and stop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "activity-config");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const empty = try storage.activityPage(request);
    try submitTestMessage(&storage, &tmp, "activity-a", "a", session.slice(), "same");
    try submitTestMessage(&storage, &tmp, "activity-b", "b", session.slice(), "same");
    const queued = try storage.activityPage(request);
    try std.testing.expectEqual(@as(usize, 2), queued.count);
    try std.testing.expect(queued.items[0].value.admission.admission != queued.items[1].value.admission.admission);
    try std.testing.expect(queued.items[0].value.admission.turn == null);
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    _ = try admitted.permit.consume();
    var stop = try completeSessionStop("activity-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    try expectActivityOutcome(&storage, session.slice(), admitted.permit.binding, "cancelled");
    request.end = queued.end;
    const frozen = try storage.activityPage(request);
    try std.testing.expectEqual(@as(usize, 2), frozen.count);
    try std.testing.expect(frozen.items[0].value.admission.state == .queued and frozen.items[0].value.admission.turn == null);
    request.end = empty.end;
    try std.testing.expectEqual(@as(usize, 0), (try storage.activityPage(request)).count);
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSessionAsk(&storage, "label-config");
            try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
            var request: protocol.ActivityPage = .{};
            try request.session.set(session.slice());
            request.direction = .backward;
            const healthy = try storage.activityPage(request);
            try std.testing.expectEqual(@as(u64, 2), healthy.call_activity.total);
            try std.testing.expectEqualStrings("Run first command", healthy.call_activity.entries[0].presentation.description.?.slice());
            if (route == .settled_activity or route == .conversation) {
                var stop = try completeSessionStop("label-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                try std.testing.expectEqual(@as(usize, 3), (try storage.publicConversationPage(.{ .session = request.session })).count);
            }
            var sql: [256]u8 = undefined;
            try exec(storage.database, try std.fmt.bufPrintSentinel(&sql, "UPDATE model_tool_call SET description={s} WHERE call_ordinal=0", .{description.sql}, 0));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
            const result: anyerror!void = switch (route) {
                .current, .full => if (testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, if (route == .full) .full else .current)) |bytes| blk: {
                    std.testing.allocator.free(bytes);
                    break :blk {};
                } else |err| err,
                .live_activity, .settled_activity => if (storage.activityPage(request)) |_| {} else |err| err,
                .conversation => if (storage.publicConversationPage(.{ .session = request.session })) |_| {} else |err| err,
            };
            try std.testing.expectError(description.failure, result);
            try std.testing.expect(storage.isFenced());
            try std.testing.expectError(error.StoreFenced, storage.activityPage(request));
            try std.testing.expectEqual(@as(usize, 0), busyStatements(storage.database));
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_get_autocommit(storage.database));
        }
    }
}

test "tool label observation trusts admission but exact inspection authenticates payload" {
    for ([_]enum { arguments, execution, proposal, full }{ .arguments, .execution, .proposal, .full }) |route| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "label-config");
        try submitTestMessage(&storage, &tmp, "label-input", "label-input", session.slice(), "propose");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try settleTwoActionsForTesting(&storage, &tmp, binding, "label-calls");
        var request: protocol.ActivityPage = .{};
        try request.session.set(session.slice());
        const before = try storage.activityPage(request);
        const action = try queryU64(storage.database, "SELECT min(action_id) FROM action_operation");
        // Damage only undisplayed private bytes, not the accepted references or
        // their metadata. Lightweight observations no longer read those bytes.
        try exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT content_id FROM model_output_item WHERE item_kind=3)");
        const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
        defer std.testing.allocator.free(report);
        try std.testing.expect(std.mem.indexOf(u8, report, "Run first command") != null);
        const after = try storage.activityPage(request);
        try std.testing.expectEqual(before.call_activity.total, after.call_activity.total);
        for (before.call_activity.entries[0..before.call_activity.count], after.call_activity.entries[0..after.call_activity.count]) |original, observed| {
            try std.testing.expectEqualStrings(original.presentation.description.?.slice(), observed.presentation.description.?.slice());
            try std.testing.expectEqual(original.presentation.code, observed.presentation.code);
        }
        try std.testing.expect(!storage.isFenced());
        const result: anyerror!void = switch (route) {
            .arguments => if (storage.actionArguments(session.slice(), action)) |_| {} else |err| err,
            .execution => blk: {
                const admitted = (try storage.admitNextActionAttempt(300_000, .{})).?;
                break :blk if (storage.readBashExecutionInput(admitted.permit.binding)) |_| {} else |err| err;
            },
            .proposal => blk: {
                const position = try queryU64(storage.database, "SELECT min(session_position) FROM model_output_item WHERE item_kind=3");
                if (storage.openProposalField(.{ .session = request.session, .position = position, .field = .arguments })) |value| {
                    var reader = value;
                    reader.close();
                    break :blk {};
                } else |err| break :blk err;
            },
            .full => if (testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full)) |bytes| blk: {
                std.testing.allocator.free(bytes);
                break :blk {};
            } else |err| err,
        };
        try std.testing.expectError(error.CorruptStore, result);
        try std.testing.expect(storage.isFenced());
    }
}

test "completed tool labels trust admission while model replay authenticates payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "replay-config");
    try submitTestMessage(&storage, &tmp, "replay-input", "replay-input", session.slice(), "propose");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, binding, "replay-calls");
    var stop = try completeSessionStop("replay-stop", session.slice());
    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
    var request: protocol.ConversationPage = .{};
    try request.session.set(session.slice());
    const before = try storage.publicConversationPage(request);
    try exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT content_id FROM model_output_item WHERE item_kind=3)");
    const after = try storage.publicConversationPage(request);
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
    var view = try storage.openHistoricalView(next);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, view.nextEntry(0));
    try std.testing.expect(storage.isFenced());
}

test "live tool activity survives completed Turns and split result pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    const page = try storage.activityPage(request);
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
    const split = try storage.activityPage(request);
    try std.testing.expect(split.more);
    try std.testing.expectEqual(@as(u64, 10), split.call_activity.total);
    try std.testing.expectEqual(@as(u64, 10), split.call_activity.entries[0].ordinal);
    const split_last = split.items[split.count - 1];
    request.position = split_last.position;
    request.ordinal = split_last.ordinal;
    const finished = try storage.activityPage(request);
    try std.testing.expect(!finished.more);
    try std.testing.expectEqual(@as(u64, 0), finished.call_activity.total);
    request.position = 0;
    request.ordinal = null;
    request.direction = .backward;
    try std.testing.expectEqual(@as(u64, 0), (try storage.activityPage(request)).call_activity.total);

    // Fixed history boundaries cannot suppress newer live calls.
    try submitTestMessage(&storage, &tmp, "live-new", "new", session.slice(), "propose again");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleTwoActionsForTesting(&storage, &tmp, next, "live-new-calls");
    request.direction = .forward;
    request.position = finished.end;
    const frozen = try storage.activityPage(request);
    try std.testing.expectEqual(@as(usize, 0), frozen.count);
    try std.testing.expectEqual(@as(u64, 2), frozen.call_activity.total);
    try std.testing.expectEqual(next.operation_id, frozen.call_activity.entries[0].operation);
}

test "compaction overflow admits a new Operation without losing applied input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "compact-config");
    try submitTestMessage(&storage, &tmp, "compact-input", "input", session.slice(), "keep all input");
    const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const detail = "{\"reason\":\"ContextOverflow\",\"stage\":\"response\",\"byte_offset\":\"0\",\"output_index\":null}";
    var failure: ModelFailure = .{ .rejected = .{ .code = "context_overflow", .diagnostic = detail, .request_id = .{} } };
    try failure.rejected.request_id.set("compact-overflow-request");
    try storage.settleModelAttemptFailure(original, failure, .context_overflow, .{});
    const next = (try storage.admitNextModelAttempt(.{})) orelse return error.MissingCompaction;
    try std.testing.expect(next.permit.binding.operation_id != original.operation_id);
    try std.testing.expectEqual(original.turn_id, next.permit.binding.turn_id);
    try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(next.permit.binding));
    var view = try storage.openHistoricalView(next.permit.binding);
    defer view.close();
    try std.testing.expectEqual(ModelOperationKind.compaction, (try view.settings()).operation);
    try std.testing.expect((try view.contextAnchor()) == null);
    const input = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
    try std.testing.expect((try view.nextEntry(input.position)) == null);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).pending_messages);
    const bytes = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 64 * 1024, .full);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const resolution = report.value.object.get("full").?.object.get("model_operations").?.array.items[0].object.get("resolution").?.object;
    try std.testing.expectEqualStrings("context_overflow", resolution.get("code").?.string);
    try std.testing.expectEqualStrings(detail, resolution.get("content").?.object.get("text").?.string);
    try std.testing.expectEqual(original.operation_id, try queryU64(storage.database, "SELECT operation_id FROM model_operation WHERE request_id='compact-overflow-request' AND resolution_code='context_overflow' AND last_failure_code='context_overflow'"));
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
            .reasoning, .function_call => "",
            .compaction => ",\"encrypted_content\":\"opaque\"",
            .message => ",\"content\":[]",
        };
        var item_buffer: [256]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&item_buffer, "{{\"type\":\"{s}\",\"id\":\"{s}\"{s}}}", .{ @tagName(kind), id, fields });
        if (kind == .function_call) calls += 1;
        try source.writeStreamingAll(std.testing.io, bytes);
        try metadata.append(.{ .tag = .item, .kind = kind, .ordinal = ordinal, .start = offset, .length = bytes.len, .content_digest = protocol.contentDigest(bytes), .id_digest = protocol.contentDigest(id) });
        offset += bytes.len;
    }
    try source.sync(std.testing.io);
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
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPage(request)).count);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).action_count);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(session.slice())).pending_messages);
    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    // Accepted compaction message items remain private, without a required
    // assistant Conversation entry, across every public inventory on reopen.
    try std.testing.expectEqual(@as(usize, 1), (try storage.publicConversationPage(request)).count);
    const activity = try storage.activityPage(.{ .session = request.session });
    for (activity.items[0..activity.count]) |item| try std.testing.expect(item.value != .assistant);
    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full);
    defer std.testing.allocator.free(report);
    var parsed_report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
    defer parsed_report.deinit();
    for (parsed_report.value.object.get("full").?.object.get("conversation").?.array.items) |entry|
        try std.testing.expect(!std.mem.eql(u8, "assistant", entry.object.get("kind").?.string));
    const compaction_message = try queryU64(storage.database, "SELECT session_position FROM model_output_item WHERE item_kind=2");
    try std.testing.expectError(error.ContentNotFound, storage.openPublicConversationContent(.{ .session = request.session, .position = compaction_message }));
    try std.testing.expect(!storage.isFenced());
    const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(compact.turn_id, successor.turn_id);
    try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
    {
        var view = try storage.openHistoricalView(successor);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        const anchor = (try view.contextAnchor()).?;
        for ([_][]const u8{ "original", "{\"type\":\"reasoning\",\"id\":\"reasoning-0\"}", "{\"type\":\"compaction\",\"id\":\"compaction-1\",\"encrypted_content\":\"opaque\"}", "{\"type\":\"message\",\"id\":\"message-2\",\"content\":[]}", "later" }, 0..) |expected, index| {
            const entry = (try cursor.next(&view)).?;
            if (index == 2) try std.testing.expectEqual(anchor, entry.position);
            var reader = try view.openContent(entry.content.?);
            defer reader.close();
            var bytes: [256]u8 = undefined;
            const count = try reader.read(0, &bytes);
            try std.testing.expectEqualStrings(expected, bytes[0..count]);
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
        var view = try storage.openHistoricalView(exhausted);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        const anchor = (try view.contextAnchor()).?;
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
    for ([_][]const u8{ "gpt-6-luna", "model-a", "gpt-6-luna-alias" }) |model| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var configure = try completeConfiguration("config", "", workspace, model);
        const created_session_0_reply = storage.configure(&configure, true, .{});
        try std.testing.expect(created_session_0_reply == .accepted);
        const created_session_0 = created_session_0_reply.accepted.session;
        const expected: ?u64 = if (std.mem.eql(u8, model, "gpt-6-luna")) 244800 else null;
        const initial = try storage.inspectSession(created_session_0.slice());
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
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
        const selected = try storage.inspectSession(created_session_0.slice());
        try std.testing.expectEqual(@as(?u64, 10), selected.compaction_trigger_override);
        try std.testing.expectEqual(@as(?u64, 8), selected.output_reservation_override);
        try storage.close();
        storage = try testingStore(&tmp, std.testing.io);
        const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
        try std.testing.expectEqual(first.operation_id, retry.operation_id);
        {
            var view = try storage.openHistoricalView(retry);
            defer view.close();
            const frozen = try view.settings();
            try std.testing.expectEqual(expected, frozen.compaction_trigger);
            try std.testing.expectEqual(@as(u64, 0), frozen.output_reservation);
        }
        try patch.key.set("inherit");
        patch.configuration.compaction_trigger.state = .explicit_null;
        patch.configuration.output_reservation.state = .explicit_null;
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
        const reset = try storage.inspectSession(created_session_0.slice());
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
        // Overflow recovery remains enabled without a default trigger, but
        // unchanged context cannot authorize another compaction.
        try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
        try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        try expectActivityOutcome(&storage, created_session_0.slice(), successor, "ResourceExceeded");
    }
}

test "compaction exact threshold zero reservation and integer usage fallback" {
    for ([_][]const u8{ "{\"total_tokens\":999}", "{\"total_tokens\":1000}", "{\"total_tokens\":1000.5}", "{\"total_tokens\":1000e0}", "{\"total_tokens\":-1000}", "{\"total_tokens\":0}", "{\"total_tokens\":18446744073709551616}", "{\"total_tokens\":1000000}", "{\"total_tokens\":9223372036854775807}", "{\"input_tokens\":9223372036854775807,\"output_tokens\":9223372036854775807}" }, 0..) |usage, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        var patch: protocol.ConfigureCommand = .{};
        try patch.key.set("heuristics");
        try patch.session.set(session.slice());
        patch.configuration.compaction_trigger.state = .value;
        try patch.configuration.compaction_trigger.value.set("1000");
        // An unknown model has no guessed automatic capacity, even with
        // accepted usage far above the known model's default threshold.
        if (index == 7) patch.configuration.compaction_trigger.state = .omitted;
        patch.configuration.output_reservation.state = .value;
        try patch.configuration.output_reservation.value.set("0");
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
        const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "");
        try settleCallsForTestingWithFaults(&storage, &tmp, first, "usage-output", &.{}, .{}, usage);
        if (index >= 8) {
            // Split counts can sum above SQLite's signed range. Saturation
            // must preserve the high-pressure decision rather than wrap/null.
            try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), try queryU64(storage.database, "SELECT usage_tokens FROM model_operation WHERE output_item_count IS NOT NULL"));
        }
        const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(if (index == 1 or index >= 8) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
    }
}

test "compaction pressure uses the latest accepted output even without usage" {
    for ([_]struct { usage: ?[]const u8, usable: bool }{
        .{ .usage = null, .usable = false },
        .{ .usage = "{\"total_tokens\":1.5}", .usable = false },
        .{ .usage = "{\"total_tokens\":1}", .usable = true },
        .{ .usage = "{\"input_tokens\":1}", .usable = false },
        .{ .usage = "{\"output_tokens\":1}", .usable = false },
        .{ .usage = "{\"input_tokens\":1,\"output_tokens\":null}", .usable = false },
        .{ .usage = "{\"input_tokens\":null,\"output_tokens\":1}", .usable = false },
        .{ .usage = "{\"input_tokens\":1,\"output_tokens\":1.5}", .usable = false },
        .{ .usage = "{\"input_tokens\":1,\"output_tokens\":-1}", .usable = false },
        .{ .usage = "{\"input_tokens\":1,\"output_tokens\":9223372036854775808}", .usable = false },
        .{ .usage = "{\"input_tokens\":1,\"output_tokens\":0}", .usable = true },
        .{ .usage = "{\"input_tokens\":0,\"output_tokens\":1}", .usable = true },
        .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999}", .usable = true },
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
        .{ .usage = "{\"total_tokens\":0,\"input_tokens\":99999,\"input_tokens\":null,\"output_tokens\":0}", .usable = true },
        .{ .usage = "{\"input_tokens\":0,\"output_tokens\":null,\"output_tokens\":99999,\"total_tokens\":0}", .usable = true },
        .{ .usage = "{\"input_tokens\":0,\"details\":{\"input_tokens\":99999,\"output_tokens\":99999},\"output_tokens\":0}", .usable = true },
    }) |case| {
        for ([_]enum { host_input, provider_output, small }{ .host_input, .provider_output, .small }) |context| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
            const original: [4000]u8 = @splat('x');
            try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), if (context == .host_input) &original else "small input");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "item", .name = "unknown", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTestingWithFaults(&storage, &tmp, first, "older-output", &calls, .{}, "{\"total_tokens\":1}");
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
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "config");
    var patch: protocol.ConfigureCommand = .{};
    try patch.key.set("heuristics");
    try patch.session.set(session.slice());
    patch.configuration.compaction_trigger.state = .value;
    try patch.configuration.compaction_trigger.value.set("1");
    patch.configuration.output_reservation.state = .value;
    try patch.configuration.output_reservation.value.set("1");
    try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "one", "one", session.slice(), "original");
    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "provider_failure" }, .ordinary, .{});
    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "pending");
    const compact = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view = try storage.openHistoricalView(compact);
    defer view.close();
    const frozen = try view.settings();
    try std.testing.expectEqual(ModelOperationKind.compaction, frozen.operation);
    try std.testing.expectEqual(@as(u64, 1), frozen.compaction_trigger);
    try std.testing.expectEqual(@as(u64, 1), frozen.output_reservation);
    try std.testing.expect((try view.contextAnchor()) == null);
    const input = (try view.nextEntry(0)).?;
    try std.testing.expectEqual(HistoricalEntryKind.user, input.kind);
    try std.testing.expect((try view.nextEntry(input.position)) == null);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(session.slice())).pending_messages);
    try patch.key.set("updated-heuristics");
    try patch.configuration.compaction_trigger.value.set("999");
    try patch.configuration.output_reservation.value.set("8");
    patch.configuration.instructions = try testingBytesContent(&tmp, "instruction", "later instruction");
    defer patch.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), (try view.settings()).compaction_trigger);
    try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "arrival");
    try settleCompactionForTesting(&storage, &tmp, compact, &.{.compaction});
    const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var later = try storage.openHistoricalView(successor);
    defer later.close();
    const settings = try later.settings();
    try std.testing.expectEqual(ModelOperationKind.assistant_response, settings.operation);
    try std.testing.expectEqual(@as(u64, 999), settings.compaction_trigger);
    try std.testing.expectEqual(@as(u64, 8), settings.output_reservation);
    var cursor: TestingHistoryCursor = .{};
    const anchor = (try later.contextAnchor()).?;
    for ([_]HistoricalEntryKind{ .user, .provider_output, .user, .user, .instruction }) |kind| {
        const entry = (try cursor.next(&later)).?;
        try std.testing.expectEqual(kind, entry.kind);
        if (kind == .provider_output) try std.testing.expectEqual(anchor, entry.position);
    }
    try std.testing.expect((try cursor.next(&later)) == null);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).pending_messages);
    const replay = storage.configure(&patch, true, .{});
    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
    var omitted: protocol.ConfigureCommand = .{};
    try omitted.key.set("omitted-heuristics");
    try omitted.session.set(session.slice());
    try std.testing.expect(storage.configure(&omitted, true, .{}) == .accepted);
    const observed = try storage.inspectSession(session.slice());
    try std.testing.expectEqual(@as(u64, 999), observed.compaction_trigger);
    try std.testing.expectEqual(@as(u64, 8), observed.output_reservation);
    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "\"compaction_trigger\":\"999\",\"output_reservation\":\"8\"") != null);
    for ([_][]const u8{ "0", "", "-1", "9223372036854775808", "+1", "1.5", "1_000", " 1", "١" }, 0..) |invalid, index| {
        var invalid_patch: protocol.ConfigureCommand = .{};
        var key: [32]u8 = undefined;
        try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-heuristic-{d}", .{index}));
        try invalid_patch.session.set(session.slice());
        invalid_patch.configuration.compaction_trigger.state = .value;
        try invalid_patch.configuration.compaction_trigger.value.set(invalid);
        const rejected = storage.configure(&invalid_patch, true, .{});
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(ConfigurationRejection.invalid_compaction_trigger, rejected.rejected.code);
        try std.testing.expectEqual(observed.revision, (try storage.inspectSession(session.slice())).revision);
        if (!std.mem.eql(u8, invalid, "0")) {
            try invalid_patch.key.set(try std.fmt.bufPrint(&key, "invalid-reserve-{d}", .{index}));
            invalid_patch.configuration.compaction_trigger.state = .omitted;
            invalid_patch.configuration.output_reservation.state = .value;
            try invalid_patch.configuration.output_reservation.value.set(invalid);
            const reserve_rejected = storage.configure(&invalid_patch, true, .{});
            try std.testing.expect(reserve_rejected == .rejected);
            try std.testing.expectEqual(ConfigurationRejection.invalid_output_reservation, reserve_rejected.rejected.code);
            try std.testing.expectEqual(observed.revision, (try storage.inspectSession(session.slice())).revision);
        }
    }
}

test "compaction failed and unresolved candidates preserve the accepted base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
        var view = try storage.openHistoricalView(candidate);
        defer view.close();
        var cursor: TestingHistoryCursor = .{};
        const anchor = (try view.contextAnchor()).?;
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
    storage = try testingStore(&tmp, std.testing.io);
    try submitTestMessage(&storage, &tmp, "three", "three", session.slice(), "new turn");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view = try storage.openHistoricalView(next);
    defer view.close();
    var cursor: TestingHistoryCursor = .{};
    const anchor = (try view.contextAnchor()).?;
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
        var storage = try testingStore(&tmp, std.testing.io);
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
            .anchor => try exec(storage.database, "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4"),
            .tail => try exec(storage.database, "DELETE FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=2"),
            .payload => try exec(storage.database, "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (SELECT content_id FROM model_output_item WHERE operation_id=(SELECT max(operation_id) FROM model_output_item) AND item_kind=4)"),
        }
        var view = try storage.openHistoricalView(next);
        defer view.close();
        if (corruption != .payload) {
            try std.testing.expectError(error.CorruptStore, view.contextAnchor());
        } else {
            const anchor = (try view.contextAnchor()).?;
            const selected = (try view.nextEntry(anchor - 1)).?;
            try std.testing.expectEqual(anchor, selected.position);
            var reader = try view.openContent(selected.content.?);
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
                var storage = try testingStore(&tmp, std.testing.io);
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
                    const tie = try prepare(storage.database, "UPDATE model_operation SET admission_position=" ++
                        "(SELECT admission_position FROM model_operation WHERE operation_id=?1) WHERE operation_id=?2");
                    defer _ = c.sqlite3_finalize(tie);
                    try bindU64(tie, 1, previous);
                    try bindU64(tie, 2, output.operation_id);
                    try expectDone(tie);
                }
                // Message entries now reference their exact raw items. Bypass
                // that FK only while injecting the intended missing-item fault.
                try exec(storage.database, "PRAGMA foreign_keys=OFF");
                const mutation = try prepare(storage.database, sql);
                defer _ = c.sqlite3_finalize(mutation);
                try bindU64(mutation, 1, corrupt_id);
                try expectDone(mutation);
                try exec(storage.database, "PRAGMA foreign_keys=ON");
                var view = try storage.openHistoricalView(next);
                defer view.close();
                if (context_read) {
                    try std.testing.expectError(error.CorruptStore, view.contextAnchor());
                } else {
                    try std.testing.expectError(error.CorruptStore, view.nextEntry(0));
                }
                try std.testing.expect(storage.isFenced());
                try std.testing.expectError(error.StoreFenced, view.settings());
            }
        }
    }
}

test "compaction repeated overflow consumes fixed pending prefix without a proactive loop" {
    for ([_]bool{ false, true }) |with_base| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
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
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
        try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "fixed pending prefix");
        const proactive = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(proactive));
        try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(session.slice())).pending_messages);
        try storage.settleModelAttemptFailure(proactive, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
        try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession(session.slice())).pending_messages);
        const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(successor));
        try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).pending_messages);
        try storage.settleModelAttemptFailure(successor, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
        const recovery = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(recovery));
        try storage.settleModelAttemptFailure(recovery, .{ .uncorrelated = "overflow" }, .context_overflow, .{});
        try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
        try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).pending_messages);
        const observation = try storage.observeCommand("pending");
        try std.testing.expectEqualStrings("ResourceExceeded", observation.message.?.queue.?.state.failed.code.slice());
        try std.testing.expect(!storage.isFenced());
    }
}

test "compaction does not repeat a soft trigger after a failed assistant with unchanged source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
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
    try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
    try submitTestMessage(&storage, &tmp, "two", "two", session.slice(), "new pending input");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession(session.slice())).pending_messages);
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
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const session = try configureTestSession(&storage, "config");
        var patch: protocol.ConfigureCommand = .{};
        try patch.key.set("heuristics");
        try patch.session.set(session.slice());
        patch.configuration.compaction_trigger.state = .value;
        try patch.configuration.compaction_trigger.value.set("1000");
        try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
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
            var storage = try testingStore(&tmp, std.testing.io);
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
            try exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL");
            const insert = try prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,allowance_used,uncertain,resolution_code) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,1,0,'failed' FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, population);
            try bindU64(insert, 2, current.operation_id);
            try expectDone(insert);

            var view = try storage.openHistoricalView(current);
            defer view.close();
            var measured: @This() = .{};
            c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
            defer c.sqlite3_progress_handler(storage.database, 0, null, null);
            while (!try view.validateOutputsStep()) {}
            try std.testing.expectEqual(with_base, (try view.contextAnchor()) != null);
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
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "config");
            try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "retain");
            const current = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            // Keep the actual current Operation newer than all injected history.
            try exec(storage.database, "UPDATE model_operation SET admission_position=100000 WHERE resolution_code IS NULL; UPDATE session SET next_position=100001");
            const insert = try prepare(storage.database, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL " ++
                "SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose," ++
                "output_reservation,attempt_ordinal,allowance_used,uncertain,resolution_code) " ++
                "SELECT 100+value,current.turn_id,current.session_ref,current.settings_revision,current.input_cutoff,100+value,value%2," ++
                "0,1,1,0,'failed' FROM sequence CROSS JOIN model_operation current WHERE current.operation_id=?2");
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, population);
            try bindU64(insert, 2, current.operation_id);
            try expectDone(insert);
            try storage.settleModelAttemptFailure(current, .{ .uncorrelated = if (overflow) "overflow" else "provider_http_422" }, if (overflow) .context_overflow else .ordinary, .{});
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "pending input");

            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (overflow) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (overflow) 1 else 0), (try storage.inspectSession(session.slice())).pending_messages);
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
            var storage = try testingStore(&tmp, std.testing.io);
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
                    .low => "{\"total_tokens\":1}",
                    .high => "{\"total_tokens\":1000}",
                    .missing => null,
                    .unchanged => unreachable,
                });
            }
            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("policy");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            };
            try std.testing.expectEqual(if (suffix == .high) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (suffix == .high) 1 else 0), (try storage.inspectSession(session.slice())).pending_messages);
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
            var storage = try testingStore(&tmp, std.testing.io);
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
                try std.testing.expect(storage.configure(&tools, true, .{}) == .accepted);
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
                    try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
                }
                const message_key = try std.fmt.bufPrint(&key, "message-{d}", .{index});
                try submitTestMessage(&storage, &tmp, "input", message_key, session.slice(), "old input");
                const binding = (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureInput).permit.binding;
                if (kind == .instruction and index != population) {
                    // Isolate revision history from accepted-output population.
                    try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
                } else {
                    try settleCallsForTestingWithFaults(&storage, &tmp, binding, "output", &.{call}, .{}, if (index == population) (if (compact) (if (kind == .instruction) "{\"total_tokens\":99900}" else "{\"total_tokens\":99999}") else "{\"total_tokens\":1}") else null);
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
            try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
            if (kind == .instruction) {
                var clear: protocol.ConfigureCommand = .{};
                try clear.key.set("clear");
                try clear.session.set(session.slice());
                clear.configuration.instructions = try testingBytesContent(&tmp, "clear-instruction", "");
                defer clear.removeTemporaryContent(std.testing.io) catch unreachable;
                try std.testing.expect(storage.configure(&clear, true, .{}) == .accepted);
            }
            try submitTestMessage(&storage, &tmp, "pending", "pending", session.slice(), "");
            var measured: @This() = .{};
            const admitted = blk: {
                c.sqlite3_progress_handler(storage.database, 1, progress, &measured);
                defer c.sqlite3_progress_handler(storage.database, 0, null, null);
                break :blk (try storage.admitNextModelAttempt(.{}) orelse return error.MissingPressureAdmission).permit.binding;
            };
            try std.testing.expectEqual(if (compact) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(admitted));
            try std.testing.expectEqual(@as(u64, if (compact) 1 else 0), (try storage.inspectSession(session.slice())).pending_messages);
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
            var storage = try testingStore(&tmp, std.testing.io);
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
            try std.testing.expectEqual(SessionStopCompletion.completed, stopped.accepted.completion);
            try storage.close();
            storage = try testingStore(&tmp, std.testing.io);

            var patch: protocol.ConfigureCommand = .{};
            try patch.key.set("pressure");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set(if (pressure) "1" else "1000000");
            try std.testing.expect(storage.configure(&patch, true, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "new", "new", session.slice(), "new work");
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expect(next.turn_id != original.turn_id);
            try std.testing.expectEqual(if (pressure) ModelOperationKind.compaction else ModelOperationKind.assistant_response, try storage.modelOperationKind(next));
            try std.testing.expectEqual(@as(u64, if (pressure) 1 else 0), (try storage.inspectSession(session.slice())).pending_messages);
        }
    }
}

test "compaction purpose admission fences a missing latest Turn Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const session = try configureTestSession(&storage, "config");
    try submitTestMessage(&storage, &tmp, "input", "input", session.slice(), "original input");
    const original = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelAttemptFailure(original, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
    try exec(storage.database, "UPDATE turn SET operation_id=99999");
    try submitTestMessage(&storage, &tmp, "later", "later", session.slice(), "new input");
    try std.testing.expectError(error.CorruptStore, storage.admitNextModelAttempt(.{}));
    try std.testing.expect(storage.isFenced());
}
