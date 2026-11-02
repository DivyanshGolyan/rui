//! Model Attempt admission: selecting the next runnable Session, compaction
//! facts, context estimates and retries.

const std = @import("std");
const attempt = @import("../../attempt.zig");
const protocol = @import("../../protocol.zig");
const model_capability = @import("../../model_capability.zig");
const product_defaults = @import("../../product_defaults.zig");
const output_format = @import("../../output_format.zig");
const retry_policy = @import("../../retry_policy.zig");
const turn_policy = @import("../../turn_policy.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("action.zig");
const configuration_domain = @import("configuration.zig");
const historical_domain = @import("historical.zig");
const model_settlement_domain = @import("model_settlement.zig");
const report_domain = @import("report.zig");
const store_schema = @import("../schema.zig");
const sqlite = @import("../sqlite.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptBinding = store_core.AttemptBinding;
const Faults = store_core.Faults;
const ModelOperationKind = historical_domain.ModelOperationKind;
const SessionFacts = configuration_domain.SessionFacts;
const accepted_resolutions = store_schema.accepted_resolutions;

pub const ModelAdmissionKind = enum { message, tool_continuation };
const complete_tool_results_sql =
    store_schema.resolutionIs("current.resolution_code", .tool_proposals) ++ " AND EXISTS(" ++
    " SELECT 1 FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_kind=3" ++
    ") AND (SELECT count(*) FROM model_tool_call tool_call WHERE tool_call.operation_id=current.operation_id)=(" ++
    " SELECT count(*) FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_kind=3" ++
    ") AND NOT EXISTS(" ++
    " SELECT 1 FROM model_output_item item LEFT JOIN model_tool_call tool_call " ++
    " ON tool_call.operation_id=item.operation_id AND tool_call.item_ordinal=item.item_ordinal " ++
    " LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id " ++
    " AND action.call_ordinal=tool_call.call_ordinal WHERE item.operation_id=current.operation_id AND item.item_kind=3 AND (" ++
    " tool_call.operation_id IS NULL OR (tool_call.rejection_code IS NULL AND (action.action_id IS NULL OR action.resolution_code IS NULL))" ++
    ")" ++
    ")";
/// Whether the Turn's `current` Operation lets it continue once input arrives.
const continues_with_input_sql =
    "(" ++ store_schema.oneOf("current.resolution_code", &turn_policy.continues_with_input) ++ " OR (" ++ complete_tool_results_sql ++ "))";
/// Whether the Turn's `current` Operation lets it continue without input.
/// `continuation_operation_id` stores this fact so selection can walk an index.
pub const continues_without_input_sql =
    "(" ++ store_schema.oneOf("current.resolution_code", &turn_policy.continues_without_input) ++ " OR (" ++ complete_tool_results_sql ++ "))";
/// A Message `m` no Turn has taken and no Session stop excludes.
const queued_input_sql =
    "m.turn_id IS NULL AND NOT EXISTS(" ++
    " SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
    " AND m.admission_id<=stopped.admission_cutoff" ++
    ")";
const runnable_eligibility_sql =
    queued_input_sql ++ " AND (NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") OR EXISTS(" ++
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    " AND " ++ continues_with_input_sql ++
    "))";
pub const runnable_selection_sql =
    "WITH candidate AS (" ++
    "SELECT m.session_ref FROM message_admission m INDEXED BY message_admission_pending WHERE " ++
    configuration_domain.servedProviderSql("(SELECT provider FROM session WHERE session_ref=m.session_ref)") ++ " AND " ++ runnable_eligibility_sql ++
    " ORDER BY m.admission_id LIMIT 1) " ++
    "SELECT m.session_ref,min(m.admission_id),max(m.admission_id),count(*),s.revision,s.next_position," ++
    "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    "AND " ++ continues_with_input_sql ++ ") " ++
    "FROM candidate chosen JOIN message_admission m INDEXED BY message_admission_session_order " ++
    "ON m.session_ref=chosen.session_ref JOIN session s ON s.session_ref=m.session_ref " ++
    "WHERE " ++ runnable_eligibility_sql ++
    " GROUP BY m.session_ref";
// Excluding only queued input matches runnable eligibility because the indexed
// Turn is its Session's only active one (turn_one_active_per_session), the two
// continuation predicates share complete_tool_results_sql and turn_policy keeps
// continues_without_input inside continues_with_input. It also trusts the stored
// column, which validateRecordedContinuations fences.
pub const tool_continuation_selection_sql =
    "SELECT active.session_ref,active.first_admission_id,active.input_cutoff,0,s.revision,s.next_position,active.turn_id " ++
    "FROM turn active INDEXED BY turn_tool_continuation JOIN session s ON s.session_ref=active.session_ref " ++
    "WHERE active.outcome_code IS NULL AND active.continuation_operation_id=active.operation_id AND " ++ configuration_domain.servedProviderSql("s.provider") ++
    " AND NOT EXISTS(SELECT 1 FROM message_admission m " ++
    "WHERE m.session_ref=active.session_ref AND " ++ queued_input_sql ++
    ") ORDER BY active.operation_id LIMIT 1";
/// Matches the partial retry indexes' text, which the schema fixes.
pub const retry_allowance_open_sql = std.fmt.comptimePrint("attempt_ordinal<{d}", .{retry_policy.maximum_attempts});
/// An unresolved last Attempt with no retry due: its outcome is uncertain.
pub const retry_exhausted_sql = std.fmt.comptimePrint("resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal={d}", .{retry_policy.maximum_attempts});
/// Due retries one admission read keeps after sorting by operation_id. The
/// due-time index cannot supply that order, so the literal LIMIT keeps the
/// sort to these rows; a bound one would make the cached plan re-prepare on
/// every bind. A default Host's active Operations and its oldest due retry
/// fit in one read, and a larger Host pages on operation_id.
pub const retry_admission_page_rows = product_defaults.active_capacity + 1;
pub const retry_admission_select_sql = std.fmt.comptimePrint(
    "SELECT turn_id,operation_id,attempt_ordinal,retry_due_at_ms FROM model_operation " ++
        "INDEXED BY model_operation_retry_due WHERE resolution_code IS NULL AND " ++ retry_allowance_open_sql ++ " " ++
        "AND retry_due_at_ms<=?1 AND operation_id>?2 AND " ++ configuration_domain.servedProviderSql("(SELECT provider FROM session WHERE session_ref=model_operation.session_ref)") ++
        " ORDER BY operation_id LIMIT {d}",
    .{retry_admission_page_rows},
);
pub const DispatchPermit = attempt.DispatchPermit;

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
};

fn nextModelOperationKind(self: *Store, session_ref: []const u8, first_admission: i64, current: *const SessionFacts, policy: model_capability.CompactionPolicy) !ModelOperationKind {
    return turn_policy.nextPurpose(try compactionFacts(self, session_ref, first_admission, current.next_position, current.provider, current.model.slice(), policy));
}

/// The facts the next model call's purpose rests on, read only as far as
/// `turn_policy` needs them. Admission and the Current report's
/// `context_estimate` both read them here. `first_admission` starts the
/// next Turn; null reads the Session's first runnable Message, which
/// admission would select.
pub fn compactionFacts(self: *Store, session_ref: []const u8, first_admission: ?i64, next_position: u64, provider: protocol.Provider, model: []const u8, policy: model_capability.CompactionPolicy) !turn_policy.CompactionFacts {
    var facts: turn_policy.CompactionFacts = .{
        .trigger = policy.compaction_trigger,
        .context_changed = false,
        .usage_tokens = null,
        .uncovered_bytes = 0,
        .output_reservation = policy.output_reservation,
    };
    const last = try store_core.cached(self, "SELECT current.purpose,current.resolution_code,current.operation_id,latest.outcome_code,latest.first_admission_id FROM turn latest INDEXED BY turn_session_latest " ++
        "LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "WHERE latest.session_ref=?1 ORDER BY latest.turn_id DESC LIMIT 1");
    defer sqlite.resetCached(last);
    try sqlite.bindText(last, 1, session_ref);
    const result = c.sqlite3_step(last);
    if (result == c.SQLITE_DONE) return facts;
    if (result != c.SQLITE_ROW) return error.CorruptStore;
    _ = try sqlite.readNullablePositiveI64(last, 2) orelse return error.CorruptStore;
    var resolution: protocol.Bounded(protocol.max_code_bytes) = .{};
    try sqlite.readText(last, 1, &resolution);
    const purpose: turn_policy.Purpose = switch (c.sqlite3_column_int(last, 0)) {
        0 => .assistant_response,
        1 => .compaction,
        else => return error.CorruptStore,
    };
    const active = c.sqlite3_column_type(last, 3) == c.SQLITE_NULL;
    const latest_first = try sqlite.readNullablePositiveI64(last, 4) orelse return error.CorruptStore;
    facts.previous = .{
        .purpose = purpose,
        .context_overflow = turn_policy.Resolution.parse(resolution.slice()) == .context_overflow,
        .turn_active = active,
        // Only an ended compaction's Turn asks which input comes next.
        .same_input_prefix = purpose == .compaction and !active and
            (first_admission orelse try firstRunnableAdmission(self, session_ref)) == latest_first,
    };
    if (turn_policy.forcedPurpose(facts.previous, facts.trigger) != null) return facts;
    facts.context_changed = try contextChangedSinceBase(self, session_ref, next_position);
    if (!facts.context_changed) return facts;
    const estimate = try contextEstimate(self, session_ref, next_position, provider, model);
    facts.usage_tokens = estimate.usage_tokens;
    facts.uncovered_bytes = estimate.uncovered_bytes;
    return facts;
}

/// The first Message admission would select for this Session's next
/// Turn, or 0 when none is runnable: a later Message has a new admission.
fn firstRunnableAdmission(self: *Store, session_ref: []const u8) !i64 {
    const statement = try store_core.cached(self, "SELECT coalesce(min(m.admission_id),0) FROM message_admission m WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    return c.sqlite3_column_int64(statement, 0);
}

const ContextEstimate = struct { usage_tokens: ?u64, uncovered_bytes: u64 };

/// What the next model call would start from, before the Session position
/// `next_position`: the newest accepted usage on this model since the
/// last compaction, and the bytes it does not cover. Automatic compaction
/// and the Current report read this one estimate.
fn contextEstimate(self: *Store, session_ref: []const u8, next_position: u64, provider: protocol.Provider, model: []const u8) !ContextEstimate {
    var usage_tokens: ?u64 = null;
    const base = try store_core.cached(self, "SELECT coalesce((SELECT admission_position FROM model_operation INDEXED BY model_operation_compaction_bases " ++
        "WHERE session_ref=?1 AND purpose=1 AND " ++ store_schema.resolutionIs("resolution_code", .compacted) ++ " AND admission_position<?2 ORDER BY admission_position DESC LIMIT 1),0)");
    defer sqlite.resetCached(base);
    try sqlite.bindText(base, 1, session_ref);
    try sqlite.bindU64(base, 2, next_position);
    if (c.sqlite3_step(base) != c.SQLITE_ROW) return error.CorruptStore;
    const frontier = try sqlite.readNullableTokens(base, 0, true) orelse return error.CorruptStore;
    // Without a usage anchor, all retained host input still contributes.
    // Covered provider/tool material is excluded separately by the base.
    var usage_position: u64 = 0;
    var result_admission = frontier;
    const usage = try store_core.cached(self, "SELECT o.usage_uncached_tokens,o.usage_cache_read_tokens,o.usage_cache_write_tokens,o.usage_output_tokens,coalesce((SELECT max(i.session_position) FROM model_output_item i WHERE i.operation_id=o.operation_id),o.admission_position),o.admission_position " ++
        "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=?1 AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " " ++
        "AND o.admission_position>=?2 AND r.provider=?3 AND r.model=?4 ORDER BY o.admission_position DESC LIMIT 1");
    defer sqlite.resetCached(usage);
    try sqlite.bindText(usage, 1, session_ref);
    try sqlite.bindU64(usage, 2, frontier);
    try sqlite.bindText(usage, 3, @tagName(provider));
    try sqlite.bindText(usage, 4, model);
    switch (c.sqlite3_step(usage)) {
        c.SQLITE_ROW => {
            if (try sqlite.readNullableTokens(usage, 0, true)) |uncached| {
                const counts: output_format.Usage = .{
                    .uncached = uncached,
                    .cache_read = try sqlite.readNullableTokens(usage, 1, true) orelse return error.CorruptStore,
                    .cache_write = try sqlite.readNullableTokens(usage, 2, true) orelse return error.CorruptStore,
                    .output = try sqlite.readNullableTokens(usage, 3, true) orelse return error.CorruptStore,
                };
                usage_tokens = counts.pressure();
                usage_position = @intCast(try sqlite.readNullablePositiveI64(usage, 4) orelse return error.CorruptStore);
                // Include this producer: its results follow usage.
                result_admission = @intCast(try sqlite.readNullablePositiveI64(usage, 5) orelse return error.CorruptStore);
            }
        },
        c.SQLITE_DONE => {},
        else => return error.CorruptStore,
    }
    const estimate = try store_core.cached(self, "SELECT " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=?1 AND e.entry_kind IN (1,2) AND e.session_position>?2) + " ++
        // An output item's bytes are its bag, its parts' text and bags,
        // and a call's three fields. A message part's text is a length
        // of its message text.
        "(SELECT coalesce(sum(coalesce((SELECT bag.byte_length FROM content bag WHERE bag.content_id=i.extras_content_id),0) + " ++
        "(SELECT coalesce(sum(coalesce(p.text_length,text.byte_length,0)+coalesce(bag.byte_length,0)),0) FROM model_output_part p " ++
        "LEFT JOIN content text ON text.content_id=p.text_content_id LEFT JOIN content bag ON bag.content_id=p.extras_content_id " ++
        "WHERE p.operation_id=i.operation_id AND p.item_ordinal=i.item_ordinal) + " ++
        "coalesce((SELECT name.byte_length+call_id.byte_length+arguments.byte_length FROM model_tool_call tool_call " ++
        "JOIN content name ON name.content_id=tool_call.name_content_id JOIN content call_id ON call_id.content_id=tool_call.call_id_content_id " ++
        "JOIN content arguments ON arguments.content_id=tool_call.arguments_content_id " ++
        "WHERE tool_call.operation_id=i.operation_id AND tool_call.item_ordinal=i.item_ordinal),0)),0) FROM model_output_item i " ++
        "WHERE i.session_ref=?1 AND i.session_position>=max(?2+1,coalesce((SELECT max(anchor.session_position) " ++
        "FROM model_operation b INDEXED BY model_operation_compaction_bases JOIN model_output_item anchor ON anchor.operation_id=b.operation_id " ++
        "WHERE b.session_ref=?1 AND b.purpose=1 AND " ++ store_schema.resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=?3 AND anchor.item_kind=4),0))) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o INDEXED BY model_operation_context_history " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=o.operation_id " ++
        "JOIN content c ON c.content_id=tool_call.rejection_content_id WHERE o.session_ref=?1 AND o.admission_position>=?4 " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " AND tool_call.acceptance_position>max(?2,?3)) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id " ++
        "WHERE a.session_ref=?1 AND a.acceptance_position>max(?2,?3)) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN content c ON c.content_id=m.content_id " ++
        "WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=?1 AND r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
        "AND r.instructions_updated=1) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=?1 AND r.revision=1 AND ?2=0)");
    defer sqlite.resetCached(estimate);
    try sqlite.bindText(estimate, 1, session_ref);
    try sqlite.bindU64(estimate, 2, usage_position);
    try sqlite.bindU64(estimate, 3, frontier);
    try sqlite.bindU64(estimate, 4, result_admission);
    if (c.sqlite3_step(estimate) != c.SQLITE_ROW) return error.CorruptStore;
    const bytes = c.sqlite3_column_int64(estimate, 0);
    if (bytes < 0) return error.CorruptStore;
    return .{ .usage_tokens = usage_tokens, .uncovered_bytes = @intCast(bytes) };
}

pub fn overflowCanCompact(self: *Store, binding: AttemptBinding) !bool {
    const purpose = try model_settlement_domain.readModelOperationKind(self, binding.operation_id);
    const statement = try store_core.cached(self, "SELECT session_ref,admission_position FROM model_operation WHERE operation_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.operation_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 0, &session_ref);
    const boundary = try sqlite.readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
    return turn_policy.recoversOverflow(purpose, try contextChangedSinceBase(self, session_ref.slice(), @intCast(boundary)));
}

fn contextChangedSinceBase(self: *Store, session_ref: []const u8, boundary: u64) !bool {
    // Any changed suffix of the newest base also belongs to every older
    // base. Older bases cannot change the answer.
    const statement = try store_core.cached(self, "WITH base AS (SELECT admission_position FROM model_operation INDEXED BY model_operation_compaction_bases " ++
        "WHERE session_ref=?1 AND purpose=1 AND " ++ store_schema.resolutionIs("resolution_code", .compacted) ++ " AND admission_position<?2 " ++
        "ORDER BY admission_position DESC LIMIT 1) " ++
        "SELECT NOT EXISTS(SELECT 1 FROM base " ++
        "WHERE NOT EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=?1 " ++
        "AND e.entry_kind IN (1,2) AND e.session_position>base.admission_position AND e.session_position<?2) " ++
        "AND NOT EXISTS(SELECT 1 FROM model_output_item item INDEXED BY model_output_history " ++
        "CROSS JOIN model_operation suffix ON suffix.operation_id=item.operation_id " ++
        "WHERE item.session_ref=?1 AND suffix.session_ref=?1 AND suffix.purpose=0 " ++
        "AND item.session_position>base.admission_position AND item.session_position<?2))");
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    try sqlite.bindU64(statement, 2, boundary);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    return c.sqlite3_column_int(statement, 0) == 1;
}

pub fn admitNextModelAttemptLocked(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
    const select = switch (kind) {
        .message => try store_core.cached(self, runnable_selection_sql),
        .tool_continuation => try store_core.cached(self, tool_continuation_selection_sql),
    };
    defer sqlite.resetCached(select);
    switch (c.sqlite3_step(select)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => {
            try validateRecordedContinuations(self);
            try validateBlockedToolCalls(self);
            return null;
        },
        else => return error.RunnableSelectionFailed,
    }
    var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(select, 0, &session_ref);
    try store_core.touch(self, session_ref.slice());
    const first_admission = c.sqlite3_column_int64(select, 1);
    const cutoff = c.sqlite3_column_int64(select, 2);
    var selected = c.sqlite3_column_int64(select, 3);
    const revision = c.sqlite3_column_int64(select, 4);
    const initial_position = c.sqlite3_column_int64(select, 5);
    const existing_turn = try sqlite.readNullablePositiveI64(select, 6);
    if (first_admission <= 0 or cutoff < first_admission or selected < 0 or revision <= 0 or initial_position <= 0) {
        return error.CorruptStore;
    }
    // The Store's one exclusive connection is held under its mutex, so the
    // row read above is still the selection inside the write transaction.
    std.debug.assert(c.sqlite3_get_autocommit(self.database) != 0);
    try store_core.begin(self);
    const current = try configuration_domain.readSessionFacts(self, session_ref.slice(), null) orelse return error.CorruptStore;
    const policy = model_capability.compactionPolicy(current.model.slice(), current.compaction_trigger, current.output_reservation);
    const purpose = try nextModelOperationKind(self, session_ref.slice(), first_admission, &current, policy);
    if (purpose == .compaction) selected = 0;

    const turn_id = if (existing_turn) |value| @as(u64, @intCast(value)) else try store_core.takeIdentity(self, .turn_id);
    const operation_id = try store_core.takeIdentity(self, .operation_id);
    if (existing_turn == null) {
        const insert = try store_core.cached(
            self,
            "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id) " ++
                "VALUES(?1,?2,?3,?4,?5,NULL,NULL)",
        );
        defer sqlite.resetCached(insert);
        try sqlite.bindU64(insert, 1, turn_id);
        try sqlite.bindText(insert, 2, session_ref.slice());
        try sqlite.bindI64(insert, 3, first_admission);
        try sqlite.bindI64(insert, 4, cutoff);
        try sqlite.bindU64(insert, 5, operation_id);
        try sqlite.expectDone(insert);
    } else {
        const update = try store_core.cached(
            self,
            "UPDATE turn SET input_cutoff=?2,operation_id=?3 WHERE turn_id=?1 AND outcome_code IS NULL",
        );
        defer sqlite.resetCached(update);
        try sqlite.bindU64(update, 1, turn_id);
        try sqlite.bindI64(update, 2, cutoff);
        try sqlite.bindU64(update, 3, operation_id);
        try sqlite.expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
    }
    if (selected != 0) {
        const bind = try store_core.cached(
            self,
            "UPDATE message_admission SET turn_id=?1 WHERE session_ref=?2 AND turn_id IS NULL AND admission_id<=?3 " ++
                "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=message_admission.session_ref " ++
                "AND message_admission.admission_id<=stopped.admission_cutoff)",
        );
        defer sqlite.resetCached(bind);
        try sqlite.bindU64(bind, 1, turn_id);
        try sqlite.bindText(bind, 2, session_ref.slice());
        try sqlite.bindI64(bind, 3, cutoff);
        try sqlite.expectDone(bind);
        if (c.sqlite3_changes(self.database) != selected) return error.SelectionChanged;
    }
    if (selected != 0) {
        const project = try store_core.cached(
            self,
            "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id,recorded_at) " ++
                "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                "row_number() OVER (ORDER BY admission_id),?3 + row_number() OVER (ORDER BY admission_id) - 1,1,?2,admission_id,NULL,NULL,content_id,unixepoch() " ++
                "FROM message_admission WHERE turn_id=?2 AND admission_id>=?4 ORDER BY admission_id",
        );
        defer sqlite.resetCached(project);
        try sqlite.bindText(project, 1, session_ref.slice());
        try sqlite.bindU64(project, 2, turn_id);
        try sqlite.bindI64(project, 3, initial_position);
        try sqlite.bindI64(project, 4, first_admission);
        try sqlite.expectDone(project);
        if (c.sqlite3_changes(self.database) != selected) return error.ProjectionFailed;
    }
    var next_position: u64 = try std.math.add(u64, @intCast(initial_position), @intCast(selected));
    // Assistant admission atomically projects every instruction update in
    // its revision prefix. Conversation's unique source_revision index is
    // therefore the canonical applied frontier, including equal/clear text.
    const instruction_count = blk: {
        if (purpose == .compaction) break :blk @as(i64, 0);
        const count = try store_core.cached(
            self,
            "SELECT count(*) FROM session_revision r WHERE r.session_ref=?1 AND " ++
                "r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
                "AND r.revision<=?2 AND r.instructions_updated=1",
        );
        defer sqlite.resetCached(count);
        try sqlite.bindText(count, 1, session_ref.slice());
        try sqlite.bindI64(count, 2, revision);
        if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.InstructionSelectionFailed;
        const value = c.sqlite3_column_int64(count, 0);
        if (value < 0) return error.CorruptStore;
        break :blk value;
    };
    if (instruction_count != 0) {
        const project = try store_core.cached(
            self,
            "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id,recorded_at) " ++
                "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                "row_number() OVER (ORDER BY revision),?3 + row_number() OVER (ORDER BY revision) - 1,2,?2,NULL,revision,NULL,instructions_content_id,unixepoch() " ++
                "FROM session_revision r WHERE r.session_ref=?1 AND " ++
                "r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
                "AND r.revision<=?4 AND r.instructions_updated=1 ORDER BY revision",
        );
        defer sqlite.resetCached(project);
        try sqlite.bindText(project, 1, session_ref.slice());
        try sqlite.bindU64(project, 2, turn_id);
        try sqlite.bindU64(project, 3, next_position);
        try sqlite.bindI64(project, 4, revision);
        try sqlite.expectDone(project);
        if (c.sqlite3_changes(self.database) != instruction_count) return error.InstructionSelectionFailed;
        next_position = try std.math.add(u64, next_position, @intCast(instruction_count));
    }
    // Claim the positions the projections above took from the selection's
    // read of the counter.
    const claimed_count = try std.math.add(u64, next_position - @as(u64, @intCast(initial_position)), 1);
    if (try turn_domain.claimSessionPositions(self, session_ref.slice(), claimed_count) != initial_position) return error.SelectionChanged;
    {
        const insert = try store_core.cached(
            self,
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                "admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,attempt_ordinal,retry_due_at_ms,attempt_at) " ++
                "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,0,unixepoch())",
        );
        defer sqlite.resetCached(insert);
        try sqlite.bindU64(insert, 1, operation_id);
        try sqlite.bindU64(insert, 2, turn_id);
        try sqlite.bindText(insert, 3, session_ref.slice());
        try sqlite.bindI64(insert, 4, revision);
        try sqlite.bindI64(insert, 5, cutoff);
        try sqlite.bindU64(insert, 6, next_position);
        try sqlite.bindI64(insert, 7, @as(i64, if (purpose == .compaction) 1 else 0));
        try sqlite.bindNullableU64(insert, 8, policy.compaction_trigger);
        try sqlite.bindU64(insert, 9, policy.output_reservation);
        try sqlite.bindNullableEffort(insert, 10, configuration_domain.effectiveReasoningEffort(&current));
        try sqlite.expectDone(insert);
    }
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try store_core.commit(self);
    const binding = AttemptBinding{
        .turn_id = turn_id,
        .operation_id = operation_id,
        .attempt_ordinal = 1,
    };
    return .{ .permit = .{ .binding = binding } };
}

pub fn tryAdmitNextModelRetryLocked(
    self: *Store,
    active: ActiveOperationFilter,
    faults: Faults,
) !?AttemptAdmission {
    const snapshot_ms = try store_core.readUnixMilliseconds(self.io);
    const selection_limit = try std.math.add(usize, active.maximum_exclusions, 1);
    const select = try store_core.cached(self, retry_admission_select_sql);
    defer sqlite.resetCached(select);
    try sqlite.bindI64(select, 1, snapshot_ms);
    try sqlite.bindI64(select, 2, 0);
    var selected: ?AttemptBinding = null;
    var scanned: usize = 0;
    var page_rows: usize = 0;
    var after_operation_id: i64 = 0;
    while (scanned < selection_limit) {
        const result = c.sqlite3_step(select);
        if (result == c.SQLITE_DONE) {
            if (page_rows < retry_admission_page_rows) break;
            if (c.sqlite3_reset(select) != c.SQLITE_OK) return error.RetrySelectionFailed;
            try sqlite.bindI64(select, 2, after_operation_id);
            page_rows = 0;
            continue;
        }
        if (result != c.SQLITE_ROW) return error.RetrySelectionFailed;
        const turn_id = c.sqlite3_column_int64(select, 0);
        const operation_id = c.sqlite3_column_int64(select, 1);
        const attempt_ordinal = c.sqlite3_column_int64(select, 2);
        const due_at_ms = c.sqlite3_column_int64(select, 3);
        if (turn_id <= 0 or operation_id <= 0 or attempt_ordinal <= 0 or
            attempt_ordinal >= retry_policy.maximum_attempts or
            due_at_ms < 0 or due_at_ms > snapshot_ms)
        {
            return error.CorruptStore;
        }
        scanned += 1;
        page_rows += 1;
        after_operation_id = operation_id;
        if (active.contains(@intCast(operation_id))) continue;
        selected = .{
            .turn_id = @intCast(turn_id),
            .operation_id = @intCast(operation_id),
            .attempt_ordinal = @intCast(attempt_ordinal),
        };
        break;
    }
    // Ends the read before any transaction this transition opens.
    if (c.sqlite3_reset(select) != c.SQLITE_OK) return error.RetrySelectionFailed;

    // Eligibility exists only inside this Store transition. No selected
    // candidate or time snapshot survives rollback, capacity loss or exit.
    // The held Store mutex excludes every other writer, so the candidate
    // read outside the transaction is still current inside it.
    const current = selected orelse return null;
    try store_core.begin(self);
    if (current.attempt_ordinal >= retry_policy.maximum_attempts) return error.CorruptStore;
    const replacement_ordinal = current.attempt_ordinal + 1;
    const update = try store_core.cached(
        self,
        "UPDATE model_operation SET attempt_ordinal=?2,retry_due_at_ms=0,attempt_at=unixepoch(),retry_scheduled_at=NULL " ++
            "WHERE operation_id=?1 AND turn_id=?3 AND resolution_code IS NULL " ++
            "AND attempt_ordinal=?4 AND " ++ retry_allowance_open_sql ++ " AND retry_due_at_ms<=?5 RETURNING session_ref",
    );
    defer sqlite.resetCached(update);
    try sqlite.bindU64(update, 1, current.operation_id);
    try sqlite.bindU64(update, 2, replacement_ordinal);
    try sqlite.bindU64(update, 3, current.turn_id);
    try sqlite.bindU64(update, 4, current.attempt_ordinal);
    try sqlite.bindI64(update, 5, snapshot_ms);
    if (try store_core.stepTouching(self, update) != 1) {
        try store_core.rollback(self);
        return null;
    }
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try store_core.commit(self);
    return .{ .permit = .{ .binding = .{
        .turn_id = current.turn_id,
        .operation_id = current.operation_id,
        .attempt_ordinal = replacement_ordinal,
    } } };
}

/// Before declaring the Store idle, distinguish valid permission waits
/// from malformed canonical classification. Only each active Turn's
/// current Operation can be blocking successor discovery.
fn validateBlockedToolCalls(self: *Store) !void {
    const statement = try store_core.cached(
        self,
        "SELECT operation.operation_id FROM turn active JOIN model_operation operation " ++
            "ON operation.operation_id=active.operation_id WHERE active.outcome_code IS NULL " ++
            "AND " ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals) ++ " ORDER BY operation.operation_id",
    );
    defer sqlite.resetCached(statement);
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const operation_id = c.sqlite3_column_int64(statement, 0);
            if (operation_id <= 0) return error.CorruptStore;
            _ = try report_domain.readToolOutcomeFacts(self, @intCast(operation_id), false);
        },
        c.SQLITE_DONE => return,
        else => return error.CallReadFailed,
    };
}

/// Rejects an active Turn whose stored continuation disagrees with its Operation, since selection would skip it or take it too early.
fn validateRecordedContinuations(self: *Store) !void {
    const disagreeing = try store_core.cached(
        self,
        "SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
            "WHERE active.outcome_code IS NULL AND (active.continuation_operation_id IS active.operation_id)!=" ++
            "(CASE WHEN " ++ continues_without_input_sql ++ " THEN 1 ELSE 0 END) LIMIT 1",
    );
    defer sqlite.resetCached(disagreeing);
    switch (c.sqlite3_step(disagreeing)) {
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => return error.CorruptStore,
        else => return error.TurnReadFailed,
    }
}
