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
const reads_domain = @import("reads.zig");
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

/// `message` takes up waiting Messages, starting a Turn or joining an
/// open one; `open_turn_message` only joins an open Turn, as a Host that
/// holds new Turns does (D193).
pub const ModelAdmissionKind = enum { message, open_turn_message, tool_continuation };
/// Whether the Turn's `current` Operation proposed tool calls and each is
/// rejected or its action resolved. Each table it reads is tied to
/// `current`'s Session (`rsql.tiedRefs`), for a write that reads it. The
/// term `item.item_ordinal>=0`, always true, keeps SQLite on
/// model_output_item's primary key: without it the session_ref tie draws
/// the planner to model_output_call_history, a scan of the Session's calls.
/// `@index` cannot say this: it names only an index the schema declares,
/// and the primary key of this WITHOUT ROWID table is the table itself,
/// named only by SQLite's internal `sqlite_autoindex_model_output_item_1`.
const complete_tool_results_sql =
    store_schema.resolutionIs("current.resolution_code", .tool_proposals) ++ " AND EXISTS(" ++
    " SELECT 1 FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3" ++
    ") AND (SELECT count(*) FROM model_tool_call tool_call WHERE tool_call.operation_id=current.operation_id AND tool_call.session_ref=current.session_ref)=(" ++
    " SELECT count(*) FROM model_output_item item WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3" ++
    ") AND NOT EXISTS(" ++
    " SELECT 1 FROM model_output_item item LEFT JOIN model_tool_call tool_call " ++
    " ON tool_call.operation_id=item.operation_id AND tool_call.session_ref=item.session_ref AND tool_call.item_ordinal=item.item_ordinal " ++
    " LEFT JOIN action_operation action ON action.parent_operation_id=tool_call.operation_id " ++
    " AND action.session_ref=tool_call.session_ref AND action.call_ordinal=tool_call.call_ordinal" ++
    " WHERE item.operation_id=current.operation_id AND item.item_ordinal>=0 AND item.session_ref=current.session_ref AND item.item_kind=3 AND (" ++
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
/// The Session's open Turn takes waiting input at its next model call.
const open_turn_takes_input_sql =
    "EXISTS(" ++
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    " AND " ++ continues_with_input_sql ++
    ")";
const runnable_eligibility_sql =
    queued_input_sql ++ " AND (NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") OR " ++ open_turn_takes_input_sql ++ ")";
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

/// The Session whose oldest waiting Message is oldest, among those whose
/// input `eligibility` admits, with the Messages it takes.
fn RunnableSelection(comptime eligibility: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH candidate AS (" ++
            "SELECT m.session_ref FROM message_admission m @index(message_admission_pending) WHERE " ++
            "@served((SELECT provider FROM session WHERE session_ref=m.session_ref))" ++ " AND " ++ eligibility ++
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
}
const runnable_selection = RunnableSelection(runnable_eligibility_sql);
/// While new Turns are held: only Sessions whose open Turn takes the input.
const open_turn_selection = RunnableSelection(queued_input_sql ++ " AND " ++ open_turn_takes_input_sql);
/// `runnable_selection` as SQLite runs it.
pub const runnable_selection_sql = runnable_selection.sql;

// Excluding only queued input matches runnable eligibility because the indexed
// Turn is its Session's only active one (turn_one_active_per_session), the two
// continuation predicates share complete_tool_results_sql and turn_policy keeps
// continues_without_input inside continues_with_input. It also trusts the stored
// column, which `disagreeing_continuation` fences.
pub const tool_continuation_selection = rsql.Read(.{
    .sql = "SELECT " ++ rsql.session_head_columns ++ ",active.first_admission_id AS first_admission,active.input_cutoff AS cutoff,0 AS selected,active.turn_id " ++
        "FROM turn active @index(turn_tool_continuation) JOIN session s ON s.session_ref=active.session_ref " ++
        "WHERE active.outcome_code IS NULL AND active.continuation_operation_id=active.operation_id AND " ++ "@served(s.provider)" ++
        " AND NOT EXISTS(SELECT 1 FROM message_admission m " ++
        "WHERE m.session_ref=active.session_ref AND " ++ queued_input_sql ++
        ") ORDER BY active.operation_id LIMIT 1",
    .Args = struct {},
    .Row = Selection,
    .cardinality = .optional,
});

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
        "AND o.retry_due_at_ms<=?1 AND o.operation_id>?2 AND " ++ "@served(s.provider)" ++
        " ORDER BY o.operation_id LIMIT {d}",
    .{retry_admission_page_rows},
);
pub const DispatchPermit = attempt.DispatchPermit;

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
};

/// The latest Turn as `previousTurn` weighs it: its current Operation's
/// purpose and resolution, whether it is active, and the first Message it
/// took. Main's text, but that it reads whether the Turn is active, not
/// its outcome code, which it weighed only for that.
const latest_turn = rsql.Read(.{
    .sql = "SELECT current.purpose,current.resolution_code,current.operation_id,latest.outcome_code IS NULL AS active,latest.first_admission_id " ++
        "FROM turn latest @index(turn_session_latest) LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "WHERE latest.session_ref=?1 ORDER BY latest.turn_id DESC LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        purpose: u1,
        resolution_code: ?protocol.Bounded(protocol.max_code_bytes),
        operation_id: rsql.Positive,
        active: bool,
        first_admission_id: rsql.Positive,
    },
    .cardinality = .optional,
});

/// The first Message admission would select for the Session's next Turn,
/// or 0 when none is runnable: a later Message has a new admission.
const first_runnable = rsql.Read(.{
    .sql = "SELECT coalesce(min(m.admission_id),0) AS first FROM message_admission m WHERE m.session_ref=?1 AND " ++ runnable_eligibility_sql,
    .Args = struct { session: []const u8 },
    .Row = struct { first: u64 },
    .cardinality = .one,
});

/// The names main gave `CompactionRead`'s failed steps: each is
/// `CorruptStore`, where main's own check of whether the context changed
/// let `StatementFailed` through, which `admission_context` now reads.
pub const compaction_failures = .{
    .{ latest_turn, error.CorruptStore },
    .{ first_runnable, error.CorruptStore },
    .{ admission_context, error.CorruptStore },
};

/// The facts the next model call's purpose rests on, read only as far as
/// `turn_policy` needs them, in stages a caller's rounds share, for the
/// Current report's `context_estimate`: the latest Turn; only where
/// `asksNextInput`, the first runnable Message, which admission would
/// select; and only when `turn_policy.forcedPurpose` leaves the purpose
/// open, `admission_context`, the facts admission weighs in that case.
pub const CompactionRead = struct {
    session: []const u8,
    /// The Session's next position, provider and model.
    boundary: u64,
    provider: protocol.Provider,
    model: []const u8,
    facts: turn_policy.CompactionFacts,
    stage: enum { latest, first, context, done } = .latest,
    latest: latest_turn.Result = undefined,
    first: first_runnable.Result = undefined,
    context: admission_context.Result = undefined,

    pub fn init(session: []const u8, boundary: u64, provider: protocol.Provider, model: []const u8, policy: model_capability.CompactionPolicy) CompactionRead {
        return .{ .session = session, .boundary = boundary, .provider = provider, .model = model, .facts = .{
            .trigger = policy.compaction_trigger,
            .context_changed = false,
            .usage_tokens = null,
            .uncovered_bytes = 0,
            .output_reservation = policy.output_reservation,
        } };
    }

    /// Queues this stage's read; false once the facts are read.
    pub fn queue(read: *CompactionRead, a: anytype) bool {
        switch (read.stage) {
            .latest => a.read(latest_turn, .{ .session = read.session }, &read.latest),
            .first => a.read(first_runnable, .{ .session = read.session }, &read.first),
            .context => a.read(admission_context, .{ .session = read.session, .boundary = read.boundary, .provider = read.provider, .model = read.model }, &read.context),
            .done => return false,
        }
        return true;
    }

    /// After the round that ran this stage's read: takes it and picks the
    /// next stage.
    pub fn advance(read: *CompactionRead) !void {
        read.stage = switch (read.stage) {
            .latest => stage: {
                const latest = read.latest orelse break :stage .done;
                if (asksNextInput(latest.purpose == 1, latest.active)) break :stage .first;
                break :stage read.weigh(null);
            },
            .first => read.weigh(read.first.first),
            .context => stage: {
                try takeContext(&read.facts, &read.context);
                break :stage .done;
            },
            .done => .done,
        };
    }

    /// The latest Turn's `previousTurn`, given the next Turn's first
    /// Message where it asks; then whether the context is still to read.
    fn weigh(read: *CompactionRead, next_first: ?u64) @TypeOf(read.stage) {
        const latest = read.latest.?;
        const resolution: []const u8 = if (latest.resolution_code) |*code| code.slice() else "";
        read.facts.previous = previousTurn(latest.purpose == 1, resolution, latest.active, latest.first_admission_id.get(), next_first);
        return if (turn_policy.forcedPurpose(read.facts.previous, read.facts.trigger) == null) .context else .done;
    }
};

/// Whether `turn_policy` asks the latest Turn which input comes next:
/// only an ended compaction's Turn.
fn asksNextInput(compaction: bool, active: bool) bool {
    return compaction and !active;
}

/// The latest Turn as `turn_policy` weighs it, for admission and the
/// Current report alike: its call's purpose and resolution, whether it is
/// active, and, where `asksNextInput`, whether `next_first`, the first
/// Message the next Turn takes, is the one it started from.
fn previousTurn(compaction: bool, resolution: []const u8, active: bool, latest_first: u64, next_first: ?u64) turn_policy.Previous {
    return .{
        .purpose = if (compaction) .compaction else .assistant_response,
        .context_overflow = turn_policy.Resolution.parse(resolution) == .context_overflow,
        .turn_active = active,
        .same_input_prefix = asksNextInput(compaction, active) and next_first.? == latest_first,
    };
}

/// `admission_context`'s row into `compaction`: whether the context
/// changed, and only when it did, the usage's pressure and the bytes it
/// does not cover.
fn takeContext(compaction: *turn_policy.CompactionFacts, context: *const admission_context.Row) !void {
    compaction.context_changed = context.changed;
    if (!context.changed) return;
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
        "FROM model_operation b @index(model_operation_compaction_bases) JOIN model_output_item anchor ON anchor.operation_id=b.operation_id " ++
        "WHERE b.session_ref=?1 AND b.purpose=1 AND " ++ store_schema.resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=" ++ frontier ++ " AND anchor.item_kind=4),0))) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o @index(model_operation_context_history) " ++
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
/// the newest one has a changed suffix before it. Its text is main's.
pub const context_changed = rsql.Read(.{
    .sql = "WITH " ++ compaction_base_sql ++ " SELECT " ++ changed_since_base_sql ++ " AS changed",
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct { changed: bool },
    .cardinality = .one,
});

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

/// The applied instruction frontier of the Session the marker or text in
/// `session` names: assistant admission projects every instruction update
/// in its revision prefix, so Conversation's unique source_revision index
/// is the applied frontier, equal or cleared text included.
fn appliedFrontierSql(comptime session: []const u8) []const u8 {
    return "coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),1)";
}

/// The Conversation's last entry ordinal for the Session `session` names.
fn lastOrdinalSql(comptime session: []const u8) []const u8 {
    return "coalesce((SELECT max(e.entry_ordinal) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),0)";
}

/// The instruction updates after the applied frontier, up to `revision`.
fn pendingInstructionsSql(comptime session: []const u8, comptime revision: []const u8) []const u8 {
    return "r.session_ref=" ++ session ++ " AND r.revision>" ++ appliedFrontierSql(session) ++ " AND r.revision<=" ++ revision ++ " AND r.instructions_updated=1";
}

/// What admission decides from, inside its transaction: the Session's head
/// and settings, its latest Turn as `previousTurn` reads it, and how many
/// instruction updates `project_instructions` would project.
const admission_facts = rsql.Read(.{
    .sql = "SELECT " ++ rsql.session_head_columns ++ ",s.revision,s.provider,s.model,s.compaction_trigger,s.output_reservation,s.reasoning_effort," ++
        "latest.turn_id AS latest_turn,latest.outcome_code IS NULL AS latest_active,latest.first_admission_id AS latest_first," ++
        "current.operation_id AS latest_operation,current.purpose AS latest_compaction,current.resolution_code AS latest_resolution," ++
        "(SELECT count(*) FROM session_revision r WHERE " ++ pendingInstructionsSql("?1", "s.revision") ++ ") AS instructions " ++
        "FROM session s LEFT JOIN turn latest ON latest.turn_id=(SELECT t.turn_id FROM turn t @index(turn_session_latest) " ++
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
        instructions: u64,
    },
    .cardinality = .one,
});

/// The facts automatic compaction weighs, in one statement before the
/// position ?2: whether the context changed since the newest compaction
/// base (`context_changed`), and, only when it did, the newest usage
/// after that base (`latestUsageSql`) and the bytes it does not cover
/// (`uncoveredBytesSql`). Otherwise the usage is NULL and the bytes 0.
/// Admission and the Current report (`CompactionRead`) read it only when
/// `turn_policy.forcedPurpose` leaves the purpose open. `since`
/// and `latest_usage` are each named once, so SQLite need not materialize them.
/// `base` is `context_changed`'s and named twice: a one-row `base` named
/// once measured 5 steps cheaper here and 11 dearer in `context_changed`.
/// The newest usage at or after the base is the newest
/// usage, when that one is at or after the base, and none otherwise; so
/// `latest_usage` reads the newest, and the join holds it to the base. `provider`
/// and `model` are the Session's settings, as `admission_facts` read them.
const admission_context = rsql.Read(.{
    .sql = "WITH " ++ compaction_base_sql ++ "," ++
        "since AS (SELECT " ++ changed_since_base_sql ++ " AS changed,coalesce((SELECT admission_position FROM base),0) AS frontier)," ++
        "latest_usage AS (" ++ latestUsageSql("0", "?3", "?4") ++ ")," ++
        "measured AS (SELECT since.changed,since.frontier,latest_usage.uncached,latest_usage.cache_read,latest_usage.cache_write,latest_usage.output," ++
        "latest_usage.usage_position,latest_usage.result_admission," ++
        "CASE WHEN latest_usage.uncached IS NULL THEN 0 ELSE latest_usage.usage_position END AS covered," ++
        "CASE WHEN latest_usage.uncached IS NULL THEN since.frontier ELSE latest_usage.result_admission END AS results " ++
        "FROM since LEFT JOIN latest_usage ON since.changed AND latest_usage.result_admission>=since.frontier) " ++
        "SELECT measured.changed,measured.uncached,measured.cache_read,measured.cache_write,measured.output,measured.usage_position,measured.result_admission," ++
        "CASE WHEN measured.changed THEN " ++ uncoveredBytesSql("measured.covered", "measured.frontier", "measured.results") ++ " ELSE 0 END AS uncovered_bytes " ++
        "FROM measured",
    .Args = struct { session: []const u8, boundary: u64, provider: protocol.Provider, model: []const u8 },
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
/// order, after its last entry ordinal and from the position
/// `position_base`: the selection's count.
const project_messages = rsql.Write(.{
    .sql = entry_columns ++ "SELECT session_ref," ++ lastOrdinalSql("@session(?1)") ++ "+row_number() OVER (ORDER BY admission_id)," ++
        "?3+row_number() OVER (ORDER BY admission_id)-1,1,?2,admission_id,NULL,NULL,content_id,@now " ++
        "FROM message_admission WHERE session_ref=@session(?1) AND turn_id=?2 AND admission_id>=?4 ORDER BY admission_id",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, position_base: u64, first_admission: u64 },
    .expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } },
});

/// Projects the instruction updates after the applied frontier up to
/// `revision`, in revision order, after the last entry ordinal and from
/// the position `position_base`: `admission_facts`' instruction count.
const project_instructions = rsql.Write(.{
    .sql = entry_columns ++ "SELECT r.session_ref," ++ lastOrdinalSql("@session(?1)") ++ "+row_number() OVER (ORDER BY r.revision)," ++
        "?3+row_number() OVER (ORDER BY r.revision)-1,2,?2,NULL,r.revision,NULL,r.instructions_content_id,@now " ++
        "FROM session_revision r WHERE " ++ pendingInstructionsSql("@session(?1)", "?4") ++ " ORDER BY r.revision",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, position_base: u64, revision: u64 },
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

/// Admits the next model Attempt of `kind`. The read Access `reader`
/// selects, outside any transaction; with nothing selected it runs main's
/// idle checks, the disagreeing continuations with whether any Operation
/// is blocked, and only then the blocked calls' outcomes, and answers
/// null. The write Access `writer` reads
/// `admission_facts` after its BEGIN; when `turn_policy.forcedPurpose`
/// leaves the purpose open, it reads `admission_context` in a round of its
/// own. Then it writes the Turn, binds and projects the Messages and
/// instructions, inserts the Operation, claims their positions and
/// commits: three rounds on a forced path, four otherwise. The held Store
/// mutex excludes every other writer, so what the selection read still
/// holds; a moved head is `SelectionChanged`.
pub fn admitNextModelAttempt(reader: anytype, writer: anytype, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
    var found: runnable_selection.Result = undefined;
    switch (kind) {
        .message => reader.read(runnable_selection, .{}, &found),
        .open_turn_message => reader.read(open_turn_selection, .{}, &found),
        .tool_continuation => reader.read(tool_continuation_selection, .{}, &found),
    }
    try store_access.runAs(reader, error.RunnableSelectionFailed);
    const selection = found orelse {
        var disagreeing: disagreeing_continuation.Result = undefined;
        var blocked: reads_domain.First(blocked_operation.Row) = .{};
        reader.read(disagreeing_continuation, .{}, &disagreeing);
        reader.readEach(blocked_operation, .{}, 1, &blocked);
        try store_access.runNamed(reader, .{.{ blocked_operation, error.CallReadFailed }}, error.TurnReadFailed);
        if (disagreeing != null) return error.CorruptStore;
        if (blocked.row != null) try validateBlockedToolCalls(reader);
        return null;
    };
    if (selection.cutoff.get() < selection.first_admission.get()) return error.CorruptStore;
    const session_ref: []const u8 = &selection.session.ref;
    const first_admission = selection.first_admission.get();

    var facts: admission_facts.Result = undefined;
    writer.read(admission_facts, .{ .session = session_ref }, &facts);
    try store_access.runAs(writer, error.SessionReadFailed);
    if (facts.session.next_position != selection.session.next_position) return error.SelectionChanged;

    const policy = model_capability.compactionPolicy(facts.model.slice(), if (facts.compaction_trigger) |trigger| trigger.get() else null, facts.output_reservation);
    var compaction: turn_policy.CompactionFacts = .{
        .trigger = policy.compaction_trigger,
        .context_changed = false,
        .usage_tokens = null,
        .uncovered_bytes = 0,
        .output_reservation = policy.output_reservation,
    };
    if (facts.latest_turn != null) {
        if (facts.latest_operation == null) return error.CorruptStore;
        const latest_first = facts.latest_first orelse return error.CorruptStore;
        const resolution: []const u8 = if (facts.latest_resolution) |*code| code.slice() else "";
        compaction.previous = previousTurn(facts.latest_compaction orelse return error.CorruptStore, resolution, facts.latest_active, latest_first.get(), first_admission);
    }
    if (turn_policy.forcedPurpose(compaction.previous, compaction.trigger) == null) {
        var context: admission_context.Result = undefined;
        writer.read(admission_context, .{
            .session = session_ref,
            .boundary = selection.session.next_position.get(),
            .provider = facts.provider,
            .model = facts.model.slice(),
        }, &context);
        try store_access.runAs(writer, error.CorruptStore);
        try takeContext(&compaction, &context);
    }
    const purpose = turn_policy.nextPurpose(compaction);
    const selected: u64 = if (purpose == .compaction) 0 else selection.selected;
    const instructions: u64 = if (purpose == .compaction) 0 else facts.instructions;

    const turn_id = if (selection.turn_id) |existing| existing.get() else try writer.identity(.turn_id);
    const operation_id = try writer.identity(.operation_id);
    const cutoff = selection.cutoff.get();
    if (selection.turn_id == null) {
        writer.write(insert_turn, .{ .turn_id = turn_id, .session = facts.session, .first_admission = first_admission, .cutoff = cutoff, .operation_id = operation_id });
    } else {
        writer.write(continue_turn, .{ .turn_id = turn_id, .cutoff = cutoff, .operation_id = operation_id, .session = facts.session });
    }
    const positions = try writer.positions(facts.session);
    if (selected != 0) {
        writer.writeCount(bind_messages, .{ .turn_id = turn_id, .session = facts.session, .cutoff = cutoff }, selected);
        writer.writeCount(project_messages, .{
            .session = facts.session,
            .turn_id = turn_id,
            .position_base = try positions.take(selected),
            .first_admission = first_admission,
        }, selected);
    }
    if (instructions != 0) {
        writer.writeCount(project_instructions, .{
            .session = facts.session,
            .turn_id = turn_id,
            .position_base = try positions.take(instructions),
            .revision = facts.revision.get(),
        }, instructions);
    }
    writer.write(insert_operation, .{
        .operation_id = operation_id,
        .turn_id = turn_id,
        .session = facts.session,
        .revision = facts.revision.get(),
        .cutoff = cutoff,
        .position = try positions.take(1),
        .compaction = purpose == .compaction,
        .compaction_trigger = policy.compaction_trigger,
        .output_reservation = policy.output_reservation,
        .reasoning_effort = configuration_domain.effectiveReasoningEffort(&facts),
    });
    // The writes are queued, not run, as in every converted entry point.
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    try writer.commit();
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
        try store_access.runAs(candidate, error.RetrySelectionFailed);
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

/// Every active Turn's current Operation that proposed tool calls, the
/// Operations that can be blocking successor discovery: main's scope.
const blocked_operations_sql = "FROM turn active JOIN model_operation operation ON operation.operation_id=active.operation_id " ++
    "WHERE active.outcome_code IS NULL AND " ++ store_schema.resolutionIs("operation.resolution_code", .tool_proposals);

/// Whether any Operation is blocked: one row stepped, so an idle Store
/// with none pays only this seek, where main's scope read cost as much.
const blocked_operation = rsql.Read(.{
    .sql = "SELECT operation.operation_id " ++ blocked_operations_sql,
    .Args = struct {},
    .Row = struct { operation_id: rsql.Positive },
    .cardinality = .each,
});

/// The tool outcome rule (`reads.ToolOutcome`) over those Operations.
const blocked_tool_calls = reads_domain.ToolOutcome("", "SELECT DISTINCT operation.operation_id," ++
    reads_domain.expectedCallsSql("operation.operation_id") ++ " " ++ blocked_operations_sql, struct {}, false);

/// Before declaring the Store idle, distinguish valid permission waits
/// from malformed canonical classification: the tool outcome rule over
/// `blocked_tool_calls`, in a round of its own, once `blocked_operation`
/// found one. A failed step is `CallReadFailed`, main's name for each of
/// its statements.
fn validateBlockedToolCalls(reader: anytype) !void {
    var check: reads_domain.ToolOutcomeCheck = .{};
    reader.readEach(blocked_tool_calls, .{}, std.math.maxInt(u64), &check);
    try store_access.runAs(reader, error.CallReadFailed);
    try check.finish();
}
