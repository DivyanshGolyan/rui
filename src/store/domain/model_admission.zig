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
const rsql = @import("../rsql.zig");
const store_access = @import("../access.zig");
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
/// The Session a model admission takes up, as its selection reads it:
/// its head, the Messages it binds (`first_admission` to `cutoff`, and
/// how many), and the Turn it continues, if any.
const Selection = struct {
    session: rsql.SessionHead,
    first_admission: rsql.Positive,
    cutoff: rsql.Positive,
    selected: u64,
    turn_id: ?rsql.Positive,
};

const runnable_selection = rsql.Read(.{
    .sql = "WITH candidate AS (" ++
        "SELECT m.session_ref FROM message_admission m @index(message_admission_pending) WHERE " ++
        configuration_domain.servedProviderSql("(SELECT provider FROM session WHERE session_ref=m.session_ref)") ++ " AND " ++ runnable_eligibility_sql ++
        " ORDER BY m.admission_id LIMIT 1) " ++
        "SELECT " ++ rsql.session_head_columns ++ ",min(m.admission_id) AS first_admission,max(m.admission_id) AS cutoff,count(*) AS selected," ++
        "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
        "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
        "AND " ++ continues_with_input_sql ++ ") AS turn_id " ++
        "FROM candidate chosen JOIN message_admission m @index(message_admission_session_order) " ++
        "ON m.session_ref=chosen.session_ref JOIN session s ON s.session_ref=m.session_ref " ++
        "WHERE " ++ runnable_eligibility_sql ++
        " GROUP BY m.session_ref",
    .Args = struct {},
    .Row = Selection,
    .cardinality = .optional,
});
/// `runnable_selection` as SQLite runs it.
pub const runnable_selection_sql = runnable_selection.sql;

// Excluding only queued input matches runnable eligibility because the indexed
// Turn is its Session's only active one (turn_one_active_per_session), the two
// continuation predicates share complete_tool_results_sql and turn_policy keeps
// continues_without_input inside continues_with_input. It also trusts the stored
// column, which `disagreeing_continuation` fences.
const tool_continuation_selection = rsql.Read(.{
    .sql = "SELECT " ++ rsql.session_head_columns ++ ",active.first_admission_id AS first_admission,active.input_cutoff AS cutoff,0 AS selected,active.turn_id " ++
        "FROM turn active @index(turn_tool_continuation) JOIN session s ON s.session_ref=active.session_ref " ++
        "WHERE active.outcome_code IS NULL AND active.continuation_operation_id=active.operation_id AND " ++ configuration_domain.servedProviderSql("s.provider") ++
        " AND NOT EXISTS(SELECT 1 FROM message_admission m " ++
        "WHERE m.session_ref=active.session_ref AND " ++ queued_input_sql ++
        ") ORDER BY active.operation_id LIMIT 1",
    .Args = struct {},
    .Row = Selection,
    .cardinality = .optional,
});
/// `tool_continuation_selection` as SQLite runs it.
pub const tool_continuation_selection_sql = tool_continuation_selection.sql;

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
const retry_admission_select_text = std.fmt.comptimePrint(
    "SELECT o.turn_id,o.operation_id,o.attempt_ordinal,o.retry_due_at_ms," ++ rsql.session_head_columns ++ " " ++
        "FROM model_operation o @index(model_operation_retry_due) JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o.resolution_code IS NULL AND o." ++ retry_allowance_open_sql ++ " " ++
        "AND o.retry_due_at_ms<=?1 AND o.operation_id>?2 AND " ++ configuration_domain.servedProviderSql("s.provider") ++
        " ORDER BY o.operation_id LIMIT {d}",
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

/// The newest accepted usage on the Session's model at or after the
/// compaction base `frontier`, and where it ends: its last output item, or
/// its own admission. `provider` and `model` name the Session's settings.
fn latestUsageSql(comptime frontier: []const u8, comptime provider: []const u8, comptime model: []const u8) []const u8 {
    return "SELECT o.usage_uncached_tokens AS uncached,o.usage_cache_read_tokens AS cache_read,o.usage_cache_write_tokens AS cache_write," ++
        "o.usage_output_tokens AS output,coalesce((SELECT max(i.session_position) FROM model_output_item i WHERE i.operation_id=o.operation_id),o.admission_position) AS usage_position," ++
        "o.admission_position AS result_admission " ++
        "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=?1 AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " " ++
        "AND o.admission_position>=" ++ frontier ++ " AND r.provider=" ++ provider ++ " AND r.model=" ++ model ++ " ORDER BY o.admission_position DESC LIMIT 1";
}

/// The bytes the usage at `usage_position` does not cover, from the
/// compaction base `frontier`, counting provider results from the
/// Operation admitted at `result_admission`. The Session is ?1.
fn uncoveredBytesSql(comptime usage_position: []const u8, comptime frontier: []const u8, comptime result_admission: []const u8) []const u8 {
    const later = "max(" ++ usage_position ++ "," ++ frontier ++ ")";
    return "(SELECT coalesce(sum(c.byte_length),0) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=?1 AND e.entry_kind IN (1,2) AND e.session_position>" ++ usage_position ++ ") + " ++
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
        "WHERE i.session_ref=?1 AND i.session_position>=max(" ++ usage_position ++ "+1,coalesce((SELECT max(anchor.session_position) " ++
        "FROM model_operation b INDEXED_BASES JOIN model_output_item anchor ON anchor.operation_id=b.operation_id " ++
        "WHERE b.session_ref=?1 AND b.purpose=1 AND " ++ store_schema.resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=" ++ frontier ++ " AND anchor.item_kind=4),0))) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o INDEXED_HISTORY " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=o.operation_id " ++
        "JOIN content c ON c.content_id=tool_call.rejection_content_id WHERE o.session_ref=?1 AND o.admission_position>=" ++ result_admission ++ " " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " AND tool_call.acceptance_position>" ++ later ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id " ++
        "WHERE a.session_ref=?1 AND a.acceptance_position>" ++ later ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN content c ON c.content_id=m.content_id " ++
        "WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=?1 AND r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=?1),1) " ++
        "AND r.instructions_updated=1) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=?1 AND r.revision=1 AND " ++ usage_position ++ "=0)";
}

/// `uncoveredBytesSql` with its index choices in `spelling`: SQLite's
/// `INDEXED BY` for the legacy text, `@index` for a typed statement.
fn uncoveredBytes(comptime spelling: enum { legacy, typed }, comptime usage_position: []const u8, comptime frontier: []const u8, comptime result_admission: []const u8) []const u8 {
    const text = uncoveredBytesSql(usage_position, frontier, result_admission);
    const bases, const history = switch (spelling) {
        .legacy => .{ "INDEXED BY model_operation_compaction_bases", "INDEXED BY model_operation_context_history" },
        .typed => .{ "@index(model_operation_compaction_bases)", "@index(model_operation_context_history)" },
    };
    return comptime replaced(replaced(text, "INDEXED_BASES", bases), "INDEXED_HISTORY", history);
}

fn replaced(comptime text: []const u8, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100 * text.len);
        const at = std.mem.indexOf(u8, text, from).?;
        return text[0..at] ++ to ++ text[at + from.len ..];
    }
}

/// What the next model call would start from, before the Session position
/// `next_position`: the newest accepted usage on this model since the
/// last compaction, and the bytes it does not cover. The Current report
/// reads this estimate; admission reads the same rules in
/// `admission_context`.
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
    const usage = try store_core.cached(self, comptime std.fmt.comptimePrint("{s}", .{latestUsageSql("?2", "?3", "?4")}));
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
    const estimate = try store_core.cached(self, comptime std.fmt.comptimePrint("SELECT {s}", .{uncoveredBytes(.legacy, "?2", "?3", "?4")}));
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

/// The Session ?1's newest compaction base before the position ?2, as the
/// CTE `base`: zero rows or one.
const compaction_base_sql = "base AS (SELECT admission_position FROM model_operation @index(model_operation_compaction_bases) " ++
    "WHERE session_ref=?1 AND purpose=1 AND " ++ store_schema.resolutionIs("resolution_code", .compacted) ++ " AND admission_position<?2 " ++
    "ORDER BY admission_position DESC LIMIT 1)";

/// Over `compaction_base_sql`: true when there is no base, or the base has
/// a changed suffix before ?2. Any changed suffix of the newest base also
/// belongs to every older base, so older bases cannot change the answer.
const changed_since_base_sql = "NOT EXISTS(SELECT 1 FROM base " ++
    "WHERE NOT EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=?1 " ++
    "AND e.entry_kind IN (1,2) AND e.session_position>base.admission_position AND e.session_position<?2) " ++
    "AND NOT EXISTS(SELECT 1 FROM model_output_item item @index(model_output_history) " ++
    "CROSS JOIN model_operation suffix ON suffix.operation_id=item.operation_id " ++
    "WHERE item.session_ref=?1 AND suffix.session_ref=?1 AND suffix.purpose=0 " ++
    "AND item.session_position>base.admission_position AND item.session_position<?2))";

/// True when the Session has no compaction base before `boundary`, or
/// the newest one has a changed suffix before it.
pub const context_changed = rsql.Read(.{
    .sql = "WITH " ++ compaction_base_sql ++ " SELECT " ++ changed_since_base_sql ++ " AS changed",
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct { changed: bool },
    .cardinality = .one,
});

fn contextChangedSinceBase(self: *Store, session_ref: []const u8, boundary: u64) !bool {
    var a = store_access.Access(.read, error{}).within(self);
    defer a.deinit();
    var changed: context_changed.Result = undefined;
    a.read(context_changed, .{ .session = session_ref, .boundary = boundary }, &changed);
    try a.run();
    return changed.changed;
}

/// Disagreeing stored continuations: an active Turn whose
/// `continuation_operation_id` says otherwise than its Operation, which
/// selection would skip or take too early.
const disagreeing_continuation = rsql.Read(.{
    .sql = "SELECT 1 AS disagrees FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
        "WHERE active.outcome_code IS NULL AND @same(active.continuation_operation_id,active.operation_id)<>" ++
        "(CASE WHEN " ++ continues_without_input_sql ++ " THEN 1 ELSE 0 END) LIMIT 1",
    .Args = struct {},
    .Row = struct { disagrees: u64 },
    .cardinality = .optional,
});

/// What admission decides from, inside its transaction: the Session's head
/// and settings, its latest Turn as `compactionFacts` reads it, the
/// Conversation's last entry ordinal, and the instruction updates after
/// the applied frontier, up to the Session's revision. Assistant
/// admission projects every instruction update in its revision prefix, so
/// Conversation's unique source_revision index is the applied frontier,
/// equal or cleared text included.
const admission_facts = rsql.Read(.{
    .sql = "WITH applied AS (SELECT coalesce(max(e.source_revision),1) AS frontier FROM conversation_entry e WHERE e.session_ref=?1) " ++
        "SELECT " ++ rsql.session_head_columns ++ ",s.revision,s.provider,s.model,s.compaction_trigger,s.output_reservation,s.reasoning_effort," ++
        "latest.turn_id AS latest_turn,latest.outcome_code IS NULL AS latest_active,latest.first_admission_id AS latest_first," ++
        "current.operation_id AS latest_operation,current.purpose AS latest_compaction,current.resolution_code AS latest_resolution," ++
        "(SELECT coalesce(max(e.entry_ordinal),0) FROM conversation_entry e WHERE e.session_ref=?1) AS ordinal_base,applied.frontier," ++
        "(SELECT count(*) FROM session_revision r WHERE r.session_ref=?1 AND r.revision>applied.frontier " ++
        "AND r.revision<=s.revision AND r.instructions_updated=1) AS instructions " ++
        "FROM session s CROSS JOIN applied LEFT JOIN turn latest ON latest.turn_id=(SELECT t.turn_id FROM turn t @index(turn_session_latest) " ++
        "WHERE t.session_ref=?1 ORDER BY t.turn_id DESC LIMIT 1) " ++
        "LEFT JOIN model_operation current ON current.operation_id=latest.operation_id WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        revision: rsql.Positive,
        provider: protocol.Provider,
        model: protocol.Bounded(protocol.max_model_bytes),
        compaction_trigger: ?rsql.Positive,
        output_reservation: ?u64,
        reasoning_effort: ?protocol.ReasoningEffort,
        latest_turn: ?rsql.Positive,
        latest_active: bool,
        latest_first: ?rsql.Positive,
        latest_operation: ?rsql.Positive,
        latest_compaction: ?bool,
        latest_resolution: ?protocol.Bounded(protocol.max_code_bytes),
        ordinal_base: u64,
        frontier: rsql.Positive,
        instructions: u64,
    },
    .cardinality = .one,
});

/// The facts automatic compaction weighs, in one statement before the
/// position ?2: whether the context changed since the newest compaction
/// base (`context_changed`), and, only when it did, the newest usage
/// after that base and the bytes it does not cover (`contextEstimate`'s
/// rules). Otherwise the usage is NULL and the bytes 0, unread. A Session
/// with no Turn reads none of them and reports `changed` false: its first
/// call's purpose is forced (`turn_policy.forcedPurpose`), so admission
/// never weighs them.
const admission_context = rsql.Read(.{
    .sql = "WITH " ++ compaction_base_sql ++ "," ++
        "since AS (SELECT CASE WHEN EXISTS(SELECT 1 FROM turn t WHERE t.session_ref=?1) THEN " ++ changed_since_base_sql ++
        " ELSE 0 END AS changed,coalesce((SELECT admission_position FROM base),0) AS frontier)," ++
        "usage AS (" ++ latestUsageSql(
        "(SELECT frontier FROM since)",
        "(SELECT provider FROM session WHERE session_ref=?1)",
        "(SELECT model FROM session WHERE session_ref=?1)",
    ) ++ ")," ++
        "measured AS (SELECT since.changed,since.frontier,usage.uncached,usage.cache_read,usage.cache_write,usage.output," ++
        "usage.usage_position,usage.result_admission," ++
        "CASE WHEN usage.uncached IS NULL THEN 0 ELSE usage.usage_position END AS covered," ++
        "CASE WHEN usage.uncached IS NULL THEN since.frontier ELSE usage.result_admission END AS results " ++
        "FROM since LEFT JOIN usage ON since.changed) " ++
        "SELECT measured.changed,measured.uncached,measured.cache_read,measured.cache_write,measured.output,measured.usage_position,measured.result_admission," ++
        "CASE WHEN measured.changed THEN " ++ uncoveredBytes(.typed, "measured.covered", "measured.frontier", "measured.results") ++ " ELSE 0 END AS uncovered_bytes " ++
        "FROM measured",
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct {
        changed: bool,
        uncached: ?u64,
        cache_read: ?u64,
        cache_write: ?u64,
        output: ?u64,
        usage_position: ?rsql.Positive,
        result_admission: ?rsql.Positive,
        uncovered_bytes: u64,
    },
    .cardinality = .one,
});

const insert_turn = rsql.Write(.{
    .sql = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id) " ++
        "VALUES(?1,@session(?2),?3,?4,?5,NULL,NULL)",
    .Args = struct { turn_id: u64, session: rsql.SessionHead, first_admission: u64, cutoff: u64, operation_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const continue_turn = rsql.Write(.{
    .sql = "UPDATE turn SET input_cutoff=?2,operation_id=?3 WHERE turn_id=?1 AND session_ref=@session(?4) AND outcome_code IS NULL",
    .Args = struct { turn_id: u64, cutoff: u64, operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SelectionChanged } },
});

/// Binds the selected Messages to the Turn: the selection's count.
const bind_messages = rsql.Write(.{
    .sql = "UPDATE message_admission SET turn_id=?1 WHERE session_ref=@session(?2) AND turn_id IS NULL AND admission_id<=?3 " ++
        "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=message_admission.session_ref " ++
        "AND message_admission.admission_id<=stopped.admission_cutoff)",
    .Args = struct { turn_id: u64, session: rsql.SessionHead, cutoff: u64 },
    .expect = .{ .counted = .{ .otherwise = error.SelectionChanged } },
});

const entry_columns = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id," ++
    "source_revision,source_operation_id,content_id,recorded_at) ";

/// Projects the Turn's bound Messages into the Conversation, in admission
/// order, after the entry ordinal `ordinal_base` and from the position
/// `position_base`: the selection's count.
const project_messages = rsql.Write(.{
    .sql = entry_columns ++ "SELECT session_ref,?3+row_number() OVER (ORDER BY admission_id),?4+row_number() OVER (ORDER BY admission_id)-1,1,?2," ++
        "admission_id,NULL,NULL,content_id,@now FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?5 ORDER BY admission_id",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, ordinal_base: u64, position_base: u64, first_admission: u64 },
    .expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } },
});

/// Projects the instruction updates after `frontier` up to `revision`, in
/// revision order: `admission_facts`' instruction count.
const project_instructions = rsql.Write(.{
    .sql = entry_columns ++ "SELECT session_ref,?3+row_number() OVER (ORDER BY revision),?4+row_number() OVER (ORDER BY revision)-1,2,?2," ++
        "NULL,revision,NULL,instructions_content_id,@now FROM session_revision WHERE session_ref=@session(?1) AND revision>?5 AND revision<=?6 " ++
        "AND instructions_updated=1 ORDER BY revision",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, ordinal_base: u64, position_base: u64, frontier: u64, revision: u64 },
    .expect = .{ .counted = .{ .otherwise = error.InstructionSelectionFailed } },
});

const insert_operation = rsql.Write(.{
    .sql = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
        "admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,attempt_ordinal,retry_due_at_ms,attempt_at) " ++
        "VALUES(?1,?2,@session(?3),?4,?5,?6,?7,?8,?9,?10,1,0,@now)",
    .Args = struct {
        operation_id: u64,
        turn_id: u64,
        session: rsql.SessionHead,
        revision: u64,
        cutoff: u64,
        position: u64,
        compaction: bool,
        compaction_trigger: ?u64,
        output_reservation: u64,
        reasoning_effort: ?protocol.ReasoningEffort,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// The purpose of the next model call, from `admission_facts` and
/// `admission_context` (`compactionFacts`' rules, which read them one
/// statement at a time for the Current report).
fn admissionPurpose(facts: *const admission_facts.Row, context: *const admission_context.Row, first_admission: u64, policy: model_capability.CompactionPolicy) !turn_policy.Purpose {
    var compaction: turn_policy.CompactionFacts = .{
        .trigger = policy.compaction_trigger,
        .context_changed = false,
        .usage_tokens = null,
        .uncovered_bytes = 0,
        .output_reservation = policy.output_reservation,
    };
    if (facts.latest_turn != null) {
        if (facts.latest_operation == null) return error.CorruptStore;
        const purpose: turn_policy.Purpose = if (facts.latest_compaction orelse return error.CorruptStore) .compaction else .assistant_response;
        const active = facts.latest_active;
        const latest_first = facts.latest_first orelse return error.CorruptStore;
        compaction.previous = .{
            .purpose = purpose,
            .context_overflow = if (facts.latest_resolution) |*code| turn_policy.Resolution.parse(code.slice()) == .context_overflow else false,
            .turn_active = active,
            // Only an ended compaction's Turn asks which input comes next.
            .same_input_prefix = purpose == .compaction and !active and first_admission == latest_first.get(),
        };
    }
    if (turn_policy.forcedPurpose(compaction.previous, compaction.trigger) == null) {
        compaction.context_changed = context.changed;
        if (context.changed) {
            if (context.uncached) |uncached| {
                const counts: output_format.Usage = .{
                    .uncached = uncached,
                    .cache_read = context.cache_read orelse return error.CorruptStore,
                    .cache_write = context.cache_write orelse return error.CorruptStore,
                    .output = context.output orelse return error.CorruptStore,
                };
                if (context.usage_position == null or context.result_admission == null) return error.CorruptStore;
                compaction.usage_tokens = counts.pressure();
            }
            compaction.uncovered_bytes = context.uncovered_bytes;
        }
    }
    return turn_policy.nextPurpose(compaction);
}

/// Admits the next model Attempt of `kind`, in three rounds. The read
/// Access `candidate` selects, outside any transaction; with nothing
/// selected it runs main's idle checks and answers null. The write Access
/// `a` reads `admission_facts` and `admission_context` after its BEGIN,
/// decides the purpose in Zig, then writes the Turn, binds and projects
/// the Messages and instructions, inserts the Operation, claims their
/// positions and commits. The held Store mutex excludes every other
/// writer, so what round 1 read still holds; a moved head is
/// `SelectionChanged`.
pub fn admitNextModelAttempt(candidate: anytype, a: anytype, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
    var found: runnable_selection.Result = undefined;
    switch (kind) {
        .message => candidate.read(runnable_selection, .{}, &found),
        .tool_continuation => candidate.read(tool_continuation_selection, .{}, &found),
    }
    candidate.run() catch |err| return if (err == error.StatementFailed) error.RunnableSelectionFailed else err;
    const selection = found orelse {
        var disagreeing: disagreeing_continuation.Result = undefined;
        candidate.read(disagreeing_continuation, .{}, &disagreeing);
        candidate.run() catch |err| return if (err == error.StatementFailed) error.TurnReadFailed else err;
        if (disagreeing != null) return error.CorruptStore;
        try validateBlockedToolCalls(candidate.store);
        return null;
    };
    if (selection.cutoff.get() < selection.first_admission.get()) return error.CorruptStore;
    const session_ref: []const u8 = &selection.session.ref;

    var facts: admission_facts.Result = undefined;
    var context: admission_context.Result = undefined;
    a.read(admission_facts, .{ .session = session_ref }, &facts);
    a.read(admission_context, .{ .session = session_ref, .boundary = selection.session.next_position.get() }, &context);
    try a.run();
    if (facts.session.next_position != selection.session.next_position) return error.SelectionChanged;

    const policy = model_capability.compactionPolicy(facts.model.slice(), if (facts.compaction_trigger) |trigger| trigger.get() else null, facts.output_reservation);
    const purpose = try admissionPurpose(&facts, &context, selection.first_admission.get(), policy);
    const selected: u64 = if (purpose == .compaction) 0 else selection.selected;
    const instructions: u64 = if (purpose == .compaction) 0 else facts.instructions;

    const turn_id = if (selection.turn_id) |existing| existing.get() else try a.identity(.turn_id);
    const operation_id = try a.identity(.operation_id);
    const first_admission = selection.first_admission.get();
    const cutoff = selection.cutoff.get();
    if (selection.turn_id == null) {
        a.write(insert_turn, .{ .turn_id = turn_id, .session = facts.session, .first_admission = first_admission, .cutoff = cutoff, .operation_id = operation_id });
    } else {
        a.write(continue_turn, .{ .turn_id = turn_id, .cutoff = cutoff, .operation_id = operation_id, .session = facts.session });
    }
    const positions = try a.positions(facts.session);
    if (selected != 0) {
        a.writeCount(bind_messages, .{ .turn_id = turn_id, .session = facts.session, .cutoff = cutoff }, selected);
        a.writeCount(project_messages, .{
            .session = facts.session,
            .turn_id = turn_id,
            .ordinal_base = facts.ordinal_base,
            .position_base = try positions.take(selected),
            .first_admission = first_admission,
        }, selected);
    }
    if (instructions != 0) {
        a.writeCount(project_instructions, .{
            .session = facts.session,
            .turn_id = turn_id,
            .ordinal_base = facts.ordinal_base + selected,
            .position_base = try positions.take(instructions),
            .frontier = facts.frontier.get(),
            .revision = facts.revision.get(),
        }, instructions);
    }
    a.write(insert_operation, .{
        .operation_id = operation_id,
        .turn_id = turn_id,
        .session = facts.session,
        .revision = facts.revision.get(),
        .cutoff = cutoff,
        .position = try positions.take(1),
        .compaction = purpose == .compaction,
        .compaction_trigger = policy.compaction_trigger,
        .output_reservation = policy.output_reservation,
        .reasoning_effort = facts.reasoning_effort orelse model_capability.defaultReasoningEffort(facts.model.slice()),
    });
    // The writes are queued, not run, as in every converted entry point.
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try a.commit();
    return .{ .permit = .{ .binding = .{ .turn_id = turn_id, .operation_id = operation_id, .attempt_ordinal = 1 } } };
}

/// Due retries in id order after `after`, with their Session: one page.
const due_retries = rsql.Read(.{
    .sql = retry_admission_select_text,
    .Args = struct { now_ms: u64, after: u64 },
    .Row = struct { turn_id: rsql.Positive, operation_id: rsql.Positive, attempt_ordinal: rsql.Positive, retry_due_at_ms: u64, session: rsql.SessionHead },
    .cardinality = .each,
});

/// `due_retries` as SQLite runs it.
pub const retry_admission_select_sql = due_retries.sql;

const retry_attempt = rsql.Write(.{
    .sql = "UPDATE model_operation SET attempt_ordinal=?2,retry_due_at_ms=0,attempt_at=@now,retry_scheduled_at=NULL " ++
        "WHERE operation_id=?1 AND session_ref=@session(?6) AND turn_id=?3 AND resolution_code IS NULL " ++
        "AND attempt_ordinal=?4 AND " ++ retry_allowance_open_sql ++ " AND retry_due_at_ms<=?5",
    .Args = struct { operation_id: u64, replacement: u64, turn_id: u64, attempt_ordinal: u64, now_ms: u64, session: rsql.SessionHead },
    // Main answered null when it changed no row; `tryAdmitNextModelRetry`
    // still does.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.RetryNoLongerDue } },
});

/// Scans one page of `due_retries` for the first retry no execution slot
/// holds, counting what it stepped.
const RetryChoice = struct {
    active: ActiveOperationFilter,
    now_ms: u64,
    scanned: u64 = 0,
    page_rows: u64 = 0,
    after: u64 = 0,
    chosen: ?due_retries.Row = null,
    corrupt: bool = false,

    pub fn visit(choice: *RetryChoice, row: *const due_retries.Row) bool {
        if (row.attempt_ordinal.get() >= retry_policy.maximum_attempts or row.retry_due_at_ms > choice.now_ms) {
            choice.corrupt = true;
            return false;
        }
        choice.scanned += 1;
        choice.page_rows += 1;
        choice.after = row.operation_id.get();
        if (choice.active.contains(row.operation_id.get())) return true;
        choice.chosen = row.*;
        return false;
    }
};

/// The read Access `candidate` pages through due retries in id order,
/// outside any transaction, until it finds one `active` does not hold,
/// after at most one more than it can exclude; each page is a round. The
/// held Store mutex excludes every other writer, so the write Access `a`
/// starts the replacement Attempt from what the scan read, in one round.
pub fn tryAdmitNextModelRetry(candidate: anytype, a: anytype, io: std.Io, active: ActiveOperationFilter, faults: Faults) !?AttemptAdmission {
    const now_ms = std.math.cast(u64, try store_core.readUnixMilliseconds(io)) orelse return error.IntegerOutOfRange;
    const limit = try std.math.add(u64, active.maximum_exclusions, 1);
    var choice: RetryChoice = .{ .active = active, .now_ms = now_ms };
    while (choice.chosen == null and choice.scanned < limit) {
        choice.page_rows = 0;
        candidate.readEach(due_retries, .{ .now_ms = now_ms, .after = choice.after }, limit - choice.scanned, &choice);
        candidate.run() catch |err| return if (err == error.StatementFailed) error.RetrySelectionFailed else err;
        if (choice.corrupt) return error.CorruptStore;
        if (choice.page_rows < retry_admission_page_rows) break;
    }
    const chosen = choice.chosen orelse return null;
    const replacement = chosen.attempt_ordinal.get() + 1;
    a.write(retry_attempt, .{
        .operation_id = chosen.operation_id.get(),
        .replacement = replacement,
        .turn_id = chosen.turn_id.get(),
        .attempt_ordinal = chosen.attempt_ordinal.get(),
        .now_ms = now_ms,
        .session = chosen.session,
    });
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    a.commit() catch |err| {
        if (err != error.RetryNoLongerDue) return err;
        try a.abandon(faults);
        return null;
    };
    return .{ .permit = .{ .binding = .{
        .turn_id = chosen.turn_id.get(),
        .operation_id = chosen.operation_id.get(),
        .attempt_ordinal = replacement,
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
