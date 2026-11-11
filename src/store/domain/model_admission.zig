//! Model Attempt admission: selecting the next runnable Session, compaction
//! facts, context estimates and retries.

const std = @import("std");
const replay_recipe = @import("../../replay_recipe.zig");
const attempt = @import("../../attempt.zig");
const outcome_code = @import("../../outcome_code.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const provider_name = @import("../../provider_name.zig");
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
const history_floor_domain = @import("history_floor.zig");
const model_settlement_domain = @import("model_settlement.zig");
const reads_domain = @import("reads.zig");
const tool_offer = @import("tool_offer.zig");
const store_schema = @import("../schema.zig");
const turn_domain = @import("turn.zig");
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
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id AND current.session_ref=active.session_ref " ++
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
    /// The skills the selected Messages bound, each projected after its Message.
    skills: u64,
    turn_id: ?rsql.Positive,
};

/// The candidate Session is shared by selection and its batched facts read.
fn runnableCandidateSql(comptime eligibility: []const u8) []const u8 {
    return "SELECT m.session_ref FROM message_admission m @index(message_admission_pending) WHERE " ++
        "@served((SELECT provider FROM session WHERE session_ref=m.session_ref))" ++ " AND " ++ eligibility ++
        " ORDER BY m.admission_id LIMIT 1";
}

/// The Session whose oldest waiting Message is oldest, among those whose
/// input `eligibility` admits, with the Messages it takes.
fn RunnableSelection(comptime eligibility: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH candidate AS (" ++ runnableCandidateSql(eligibility) ++ ") " ++
            "SELECT " ++ rsql.session_head_columns ++ ",min(m.admission_id) AS first_admission,max(m.admission_id) AS cutoff,count(*) AS selected," ++
            "coalesce(sum((SELECT count(*) FROM message_skill k WHERE k.admission_id=m.admission_id)),0) AS skills," ++
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
    .sql = "SELECT " ++ rsql.session_head_columns ++ ",active.first_admission_id AS first_admission,active.input_cutoff AS cutoff,0 AS selected,0 AS skills,active.turn_id " ++
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
    /// The admission's commit read the request's settings into the
    /// caller's `historical_domain.Start`, whose view is open.
    request_started: bool = false,
};

/// The latest Turn as `previousTurn` weighs it: its current Operation's
/// purpose and resolution, whether it is active, and the first Message it
/// took. Main's text, but that it reads whether the Turn is active, not
/// its outcome code, which it weighed only for that.
const latest_turn = rsql.Read(.{
    .sql = "SELECT current.purpose,current.resolution_code,current.operation_id,latest.outcome_code IS NULL AS active,latest.first_admission_id,r.model " ++
        "FROM turn latest @index(turn_session_latest) LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "LEFT JOIN session_revision r ON r.session_ref=current.session_ref AND r.revision=current.settings_revision " ++
        "WHERE latest.session_ref=?1 ORDER BY latest.turn_id DESC LIMIT 1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        purpose: u1,
        resolution_code: ?Bounded(outcome_code.max_bytes),
        operation_id: rsql.Positive,
        active: bool,
        first_admission_id: rsql.Positive,
        model: Bounded(model_capability.max_model_bytes),
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
    .{ context_bytes, error.CorruptStore },
};

/// The facts the next model call's purpose rests on, read only as far as
/// `turn_policy` needs them, in stages a caller's rounds share, for the
/// Current report's `context_estimate`. Recipe identities ride the latest
/// Turn's round; only where `asksNextInput`, read the first runnable Message.
/// Only when purpose remains open does the next round count uncovered bytes.
pub const CompactionRead = struct {
    session: []const u8,
    /// The Session's next position, provider and model.
    boundary: u64,
    provider: provider_name.Provider,
    model: []const u8,
    facts: turn_policy.CompactionFacts,
    stage: enum { latest, first, bytes, done } = .latest,
    latest: latest_turn.Result = undefined,
    first: first_runnable.Result = undefined,
    context: admission_context.Result = undefined,
    bytes_args: context_bytes.Args = undefined,
    bytes: context_bytes.Result = undefined,

    pub fn init(session: []const u8, boundary: u64, provider: provider_name.Provider, model: []const u8, policy: model_capability.CompactionPolicy) CompactionRead {
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
            .latest => {
                a.read(latest_turn, .{ .session = read.session }, &read.latest);
                a.read(admission_context, .{ .session = read.session, .boundary = read.boundary, .provider = read.provider, .model = read.model }, &read.context);
            },
            .first => a.read(first_runnable, .{ .session = read.session }, &read.first),
            .bytes => a.read(context_bytes, read.bytes_args, &read.bytes),
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
                break :stage try read.weigh(null);
            },
            .first => try read.weigh(read.first.first),
            .bytes => stage: {
                read.facts.uncovered_bytes = read.bytes.uncovered_bytes;
                break :stage .done;
            },
            .done => .done,
        };
    }

    /// The latest Turn's `previousTurn`, given the next Turn's first
    /// Message where it asks; then whether the context is still to read.
    fn weigh(read: *CompactionRead, next_first: ?u64) !@TypeOf(read.stage) {
        const latest = read.latest.?;
        const resolution: []const u8 = if (latest.resolution_code) |*code| code.slice() else "";
        read.facts.previous = previousTurn(latest.purpose == 1, resolution, latest.active, latest.first_admission_id.get(), next_first, output_format.OutputItemKind.compaction.replayableTo(latest.model.slice(), read.model, .selected_base));
        if (turn_policy.forcedPurpose(read.facts.previous, read.facts.trigger) != null) return .done;
        const context = if (read.context) |*row| row else return error.CorruptStore;
        read.bytes_args = try takeContext(&read.facts, context, read.model, read.session) orelse return .done;
        return .bytes;
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
fn previousTurn(compaction: bool, resolution: []const u8, active: bool, latest_first: u64, next_first: ?u64, same_model: bool) turn_policy.Previous {
    return .{
        .purpose = if (compaction and same_model) .compaction else .assistant_response,
        .context_overflow = same_model and turn_policy.Resolution.parse(resolution) == .context_overflow,
        .turn_active = active,
        .same_input_prefix = same_model and asksNextInput(compaction, active) and next_first.? == latest_first,
    };
}

/// The next request inherits only its compatible base's floor.
fn currentRecipe(context: anytype, model: []const u8) error{CorruptStore}!replay_recipe.Recipe {
    return replay_recipe.Recipe.select(model, if (context.base_position) |position| .{
        .position = position.get(),
        .floor = if (context.base_floor) |floor| floor.get() else 0,
        .model = (context.base_model orelse return error.CorruptStore).slice(),
    } else null, 0);
}

/// All pressure consumers decide coverage here, using the replay owner's rule.
/// A compaction's usage measured its input recipe, not the new base it produced.
fn takeContext(compaction: *turn_policy.CompactionFacts, context: anytype, model: []const u8, session: []const u8) !?context_bytes.Args {
    const recipe = try currentRecipe(context, model);
    compaction.context_changed = recipe.frontier == 0 or context.changed;
    if (!compaction.context_changed) return null;
    var coverage: context_bytes.Args = .{ .session = session, .covered = 0, .frontier = recipe.frontier, .results = recipe.frontier };
    if (context.uncached) |uncached| {
        const measured = replay_recipe.Recipe.select(model, if (context.usage_base_position) |position| .{
            .position = position.get(),
            .floor = if (context.usage_base_floor) |floor| floor.get() else 0,
            .model = (context.usage_base_model orelse return error.CorruptStore).slice(),
        } else null, if (context.usage_floor) |floor| floor.get() else 0);
        const counts: output_format.Usage = .{
            .uncached = uncached,
            .cache_read = context.cache_read orelse return error.CorruptStore,
            .cache_write = context.cache_write orelse return error.CorruptStore,
            .output = context.output orelse return error.CorruptStore,
        };
        const position = context.usage_position orelse return error.CorruptStore;
        const admission = context.result_admission orelse return error.CorruptStore;
        if (recipe.measuredBy(measured)) {
            compaction.usage_tokens = counts.pressure();
            coverage.covered = position.get();
            coverage.results = admission.get();
        }
    }
    return coverage;
}

/// The latest accepted output on this binding, even when its usage is absent.
/// Its admission freezes the recipe it measured; its last item ends coverage.
fn latestUsageSql(comptime session: []const u8, comptime provider: []const u8, comptime model: []const u8) []const u8 {
    return "SELECT o.history_floor AS usage_floor,o.usage_uncached_tokens AS uncached,o.usage_cache_read_tokens AS cache_read,o.usage_cache_write_tokens AS cache_write," ++
        "o.usage_output_tokens AS output,coalesce((SELECT max(i.session_position) FROM model_output_item i WHERE i.operation_id=o.operation_id),o.admission_position) AS usage_position," ++
        "o.admission_position AS result_admission " ++
        "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=" ++ session ++ " AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " " ++
        "AND r.provider=" ++ provider ++ " AND r.model=" ++ model ++ " ORDER BY o.admission_position DESC LIMIT 1";
}

/// The bytes the usage at `usage_position` does not cover, from the
/// compaction base `frontier`, counting provider results from the
/// Operation admitted at `result_admission`, in the Session `session`.
fn uncoveredBytesSql(comptime session: []const u8, comptime usage_position: []const u8, comptime frontier: []const u8, comptime result_admission: []const u8) []const u8 {
    const later = "max(" ++ usage_position ++ "," ++ frontier ++ ")";
    return "(SELECT coalesce(sum(c.byte_length),0) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=" ++ session ++ " AND e.entry_kind IN (1,2,4) AND e.session_position>" ++ usage_position ++ ") + " ++
        "(SELECT coalesce(sum(" ++ history_floor_domain.item_bytes_sql ++ "),0) FROM model_output_item i " ++
        "WHERE i.session_ref=" ++ session ++ " AND i.session_position>=max(" ++ usage_position ++ "+1,coalesce((SELECT max(anchor.session_position) " ++
        "FROM model_operation b @index(model_operation_compaction_bases) JOIN model_output_item anchor ON anchor.operation_id=b.operation_id AND anchor.session_ref=b.session_ref " ++
        "WHERE b.session_ref=" ++ session ++ " AND b.purpose=1 AND " ++ store_schema.resolutionIs("b.resolution_code", .compacted) ++ " AND b.admission_position=" ++ frontier ++ " AND anchor.item_kind=4),0))) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM model_operation o @index(model_operation_context_history) " ++
        "CROSS JOIN model_tool_call tool_call ON tool_call.operation_id=o.operation_id AND tool_call.session_ref=o.session_ref " ++
        "JOIN content c ON c.content_id=tool_call.rejection_content_id WHERE o.session_ref=" ++ session ++ " AND o.admission_position>=" ++ result_admission ++ " " ++
        "AND " ++ store_schema.oneOf("o.resolution_code", &accepted_resolutions) ++ " AND tool_call.acceptance_position>" ++ later ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id " ++
        "WHERE a.session_ref=" ++ session ++ " AND a.acceptance_position>" ++ later ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN content c ON c.content_id=m.content_id " ++
        "WHERE m.session_ref=" ++ session ++ " AND " ++ runnable_eligibility_sql ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM message_admission m JOIN message_skill k ON k.admission_id=m.admission_id " ++
        "JOIN content c ON c.content_id=k.content_id WHERE m.session_ref=" ++ session ++ " AND " ++ runnable_eligibility_sql ++ ") + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=" ++ session ++ " AND r.revision>coalesce((SELECT max(e.source_revision) FROM conversation_entry e WHERE e.session_ref=" ++ session ++ "),1) " ++
        "AND r.instructions_updated=1) + " ++
        "(SELECT coalesce(sum(c.byte_length),0) FROM session_revision r JOIN content c ON c.content_id=r.instructions_content_id " ++
        "WHERE r.session_ref=" ++ session ++ " AND r.revision=1 AND " ++ usage_position ++ "=0)";
}

/// The raw newest base, before model compatibility is decided by Recipe.select.
fn baseCteSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "base AS (SELECT candidate.operation_id,candidate.admission_position,candidate.history_floor,candidate.session_ref,candidate.settings_revision FROM context_session context JOIN model_operation candidate ON candidate.operation_id=" ++
        historical_domain.newestBaseSql(session, boundary) ++ ")";
}

/// Whether the raw base has a changed suffix. A discarded base instead means
/// all visible history, hence a changed context, as `currentRecipe` decides.
fn changedSinceBaseSql(comptime session: []const u8, comptime boundary: []const u8) []const u8 {
    return "NOT EXISTS(SELECT 1 FROM base " ++
        "WHERE NOT EXISTS(SELECT 1 FROM conversation_entry e WHERE e.session_ref=" ++ session ++ " " ++
        "AND e.entry_kind IN (1,2,4) AND e.session_position>base.admission_position AND e.session_position<" ++ boundary ++ ") " ++
        "AND NOT EXISTS(SELECT 1 FROM model_output_item item @index(model_output_history) " ++
        "CROSS JOIN model_operation suffix ON suffix.operation_id=item.operation_id " ++
        "WHERE item.session_ref=" ++ session ++ " AND suffix.session_ref=" ++ session ++ " AND suffix.purpose=0 " ++
        "AND item.session_position>base.admission_position AND item.session_position<" ++ boundary ++ "))";
}

const base_columns_sql = "base.admission_position AS base_position," ++
    "base.history_floor AS base_floor,base_revision.model AS base_model";
const base_revision_join_sql = " LEFT JOIN session_revision base_revision ON base_revision.session_ref=base.session_ref AND base_revision.revision=base.settings_revision ";

/// Overflow recovery uses the same selected recipe as request preparation and pressure.
pub const context_changed = rsql.Read(.{
    .sql = "WITH context_session AS (SELECT ?1 AS session_ref,?2 AS boundary)," ++ baseCteSql("context.session_ref", "context.boundary") ++ ",since AS (SELECT " ++ changedSinceBaseSql("context.session_ref", "context.boundary") ++ " AS changed FROM context_session context) SELECT since.changed," ++ base_columns_sql ++
        ",(SELECT r.model FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "WHERE o.session_ref=?1 AND o.admission_position=?2) AS model FROM since LEFT JOIN base ON 1" ++ base_revision_join_sql,
    .Args = struct { session: []const u8, boundary: u64 },
    .Row = struct {
        changed: bool,
        base_position: ?rsql.Positive,
        base_floor: ?rsql.Positive,
        base_model: ?Bounded(model_capability.max_model_bytes),
        model: Bounded(model_capability.max_model_bytes),
    },
    .cardinality = .one,
});

pub fn contextChanged(context: *const context_changed.Row) error{CorruptStore}!bool {
    return (try currentRecipe(context, context.model.slice())).frontier == 0 or context.changed;
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

/// The settings, previous Turn and instruction count of the Session `session`
/// names, read with its selection under the same Entry lock: the columns
/// after the Session head, then the joins on `session s`.
fn factsColumnsSql(comptime session: []const u8) []const u8 {
    return "s.revision,s.provider,s.model,s.compaction_trigger,s.output_reservation,s.reasoning_effort," ++
        configuration_domain.previousReasoningEffortSql("s") ++ " AS previous_reasoning_effort," ++
        "s.tool_set_id,s.loaded_tool_set_id," ++ tool_offer.stale_sql ++ " AS offer_stale," ++
        "latest.turn_id AS latest_turn,latest.outcome_code IS NULL AS latest_active,latest.first_admission_id AS latest_first," ++
        "current.operation_id AS latest_operation,current.purpose AS latest_compaction,current.resolution_code AS latest_resolution,latest_revision.model AS latest_model," ++
        "(SELECT count(*) FROM session_revision r WHERE " ++ pendingInstructionsSql(session, "s.revision") ++ ") AS instructions";
}

fn factsJoinsSql(comptime session: []const u8) []const u8 {
    return " LEFT JOIN turn latest ON latest.turn_id=(SELECT t.turn_id FROM turn t @index(turn_session_latest) " ++
        "WHERE t.session_ref=" ++ session ++ " ORDER BY t.turn_id DESC LIMIT 1) " ++
        "LEFT JOIN model_operation current ON current.operation_id=latest.operation_id " ++
        "LEFT JOIN session_revision latest_revision ON latest_revision.session_ref=current.session_ref AND latest_revision.revision=current.settings_revision";
}

/// Read identities and counters, not an estimate against a SQL-selected recipe.
/// Zig selects both the next request's recipe and the one the usage measured;
/// only then does the byte read count the suffix (or restored full history).
fn contextCtesSql(comptime scope: []const u8) []const u8 {
    const session = "context.session_ref";
    const boundary = "context.boundary";
    return "context_session AS (" ++ scope ++ ")," ++ baseCteSql(session, boundary) ++ ",since AS (SELECT " ++ changedSinceBaseSql(session, boundary) ++ " AS changed FROM context_session context),latest_usage AS (" ++ latestUsageSql("(SELECT session_ref FROM context_session)", "(SELECT provider FROM context_session)", "(SELECT model FROM context_session)") ++ ")," ++
        "measured AS (SELECT since.changed," ++ base_columns_sql ++
        ",saved.uncached,saved.cache_read,saved.cache_write,saved.output,saved.usage_position,saved.result_admission,saved.usage_floor," ++
        "usage_base.admission_position AS usage_base_position," ++
        "usage_base.history_floor AS usage_base_floor,usage_revision.model AS usage_base_model " ++
        "FROM context_session context CROSS JOIN since LEFT JOIN base ON 1" ++ base_revision_join_sql ++
        "LEFT JOIN latest_usage saved ON 1 LEFT JOIN model_operation usage_base ON usage_base.operation_id=" ++
        historical_domain.newestBaseSql(session, "saved.result_admission") ++
        " LEFT JOIN session_revision usage_revision ON usage_revision.session_ref=usage_base.session_ref AND usage_revision.revision=usage_base.settings_revision)";
}

const context_columns_sql = "measured.changed,measured.base_position,measured.base_floor,measured.base_model," ++
    "measured.uncached,measured.cache_read,measured.cache_write,measured.output,measured.usage_position,measured.result_admission," ++
    "measured.usage_floor,measured.usage_base_position,measured.usage_base_floor,measured.usage_base_model";

const ContextRow = struct {
    model: ?Bounded(model_capability.max_model_bytes),
    changed: bool,
    base_position: ?rsql.Positive,
    base_floor: ?rsql.Positive,
    base_model: ?Bounded(model_capability.max_model_bytes),
    uncached: ?u64,
    cache_read: ?u64,
    cache_write: ?u64,
    output: ?u64,
    usage_position: ?rsql.Positive,
    result_admission: ?rsql.Positive,
    usage_floor: ?rsql.Positive,
    usage_base_position: ?rsql.Positive,
    usage_base_floor: ?rsql.Positive,
    usage_base_model: ?Bounded(model_capability.max_model_bytes),
};

const admission_context = rsql.Read(.{
    .sql = "WITH " ++ contextCtesSql("SELECT ?1 AS session_ref,?2 AS boundary,?3 AS provider,?4 AS model WHERE EXISTS(SELECT 1 FROM turn latest @index(turn_session_latest) WHERE latest.session_ref=?1)") ++ " SELECT ?4 AS model," ++ context_columns_sql ++ " FROM measured",
    .Args = struct { session: []const u8, boundary: u64, provider: provider_name.Provider, model: []const u8 },
    .Row = ContextRow,
    .cardinality = .optional,
});

/// What admission reads of the Session it selected: the head, the facts and
/// the recipe identities.
const SelectedRow = struct {
    session: rsql.SessionHead,
    revision: rsql.Positive,
    provider: provider_name.Provider,
    model: Bounded(model_capability.max_model_bytes),
    compaction_trigger: ?rsql.Positive,
    output_reservation: ?u64,
    reasoning_effort: ?model_capability.ReasoningEffort,
    previous_reasoning_effort: ?model_capability.ReasoningEffort,
    tool_set_id: rsql.Positive,
    loaded_tool_set_id: ?rsql.Positive,
    offer_stale: bool,
    latest_turn: ?rsql.Positive,
    latest_active: bool,
    latest_first: ?rsql.Positive,
    latest_operation: ?rsql.Positive,
    latest_compaction: ?bool,
    latest_resolution: ?Bounded(outcome_code.max_bytes),
    latest_model: ?Bounded(model_capability.max_model_bytes),
    instructions: u64,
    changed: bool,
    base_position: ?rsql.Positive,
    base_floor: ?rsql.Positive,
    base_model: ?Bounded(model_capability.max_model_bytes),
    uncached: ?u64,
    cache_read: ?u64,
    cache_write: ?u64,
    output: ?u64,
    usage_position: ?rsql.Positive,
    result_admission: ?rsql.Positive,
    usage_floor: ?rsql.Positive,
    usage_base_position: ?rsql.Positive,
    usage_base_floor: ?rsql.Positive,
    usage_base_model: ?Bounded(model_capability.max_model_bytes),
};

/// The selected Session's admission facts and recipe identities, in the same
/// batch as candidate selection: one statement, so admission's write round
/// reads neither. The candidate query comes from the selection owner, not a
/// copied predicate.
fn SelectedContext(comptime candidate_sql: []const u8) type {
    return rsql.Read(.{
        .sql = "WITH admission_selection AS (" ++ candidate_sql ++ ")," ++
            contextCtesSql("SELECT s.session_ref,s.next_position AS boundary,s.provider,s.model FROM session s JOIN admission_selection chosen ON chosen.session_ref=s.session_ref") ++
            " SELECT " ++ rsql.session_head_columns ++ "," ++ factsColumnsSql("context.session_ref") ++ "," ++ context_columns_sql ++
            " FROM context_session context CROSS JOIN measured JOIN session s ON s.session_ref=context.session_ref" ++ factsJoinsSql("context.session_ref"),
        .Args = struct {},
        .Row = SelectedRow,
        .cardinality = .optional,
    });
}
const selected_context = SelectedContext(runnableCandidateSql(runnable_eligibility_sql));
/// The message admission's facts and context read as SQLite runs it.
pub const selected_context_sql = selected_context.sql;
const open_turn_context = SelectedContext(runnableCandidateSql(queued_input_sql ++ " AND " ++ open_turn_takes_input_sql));
const tool_continuation_context = SelectedContext(tool_continuation_selection.made_from.sql);

const context_bytes = rsql.Read(.{
    .sql = "SELECT " ++ uncoveredBytesSql("?1", "?2", "?3", "?4") ++ " AS uncovered_bytes",
    .Args = struct { session: []const u8, covered: u64, frontier: u64, results: u64 },
    .Row = struct { uncovered_bytes: u64 },
    .cardinality = .one,
});

/// What an admission knows of its context's uncovered bytes, which it
/// does not read: nothing yet, so its first write weighs them
/// (`within_pressure`), or that this write just found them over the limit.
pub const Pressure = enum { weighed, over };

/// Admission's guard that the selected recipe's uncovered bytes are under
/// `limit` (`turn_policy.compactingBytes`): it matches the Session's row
/// only then and changes nothing in it.
const within_pressure = rsql.Write(.{
    .sql = "UPDATE session SET next_position=next_position WHERE session_ref=@session(?1) AND " ++
        uncoveredBytesSql("session.session_ref", "?2", "?3", "?4") ++ "<?5",
    .Args = struct { session: rsql.SessionHead, covered: u64, frontier: u64, results: u64, limit: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CompactionDue } },
});

/// `within_pressure` as SQLite runs it.
pub const within_pressure_sql = within_pressure.sql;

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

/// The selected Messages `m` that come before `ahead` in admission order:
/// a later one's entry sits after theirs and after each of their skills'.
fn selectedBeforeSql(comptime ahead: []const u8) []const u8 {
    return "prior.session_ref=" ++ ahead ++ ".session_ref AND prior.turn_id=?2 AND prior.admission_id>=?4 AND prior.admission_id<" ++ ahead ++ ".admission_id";
}

/// Projects the Turn's bound Messages into the Conversation, in admission
/// order, after its last entry ordinal and from the position
/// `position_base`, each leaving room after it for the skills its text
/// bound: the selection's count.
const project_messages = rsql.Write(.{
    .sql = entry_columns ++ "SELECT m.session_ref," ++ lastOrdinalSql("@session(?1)") ++ "+row_number() OVER (ORDER BY m.admission_id)+" ++ prior_skills_sql ++ "," ++
        "?3+row_number() OVER (ORDER BY m.admission_id)-1+" ++ prior_skills_sql ++ ",1,?2,m.admission_id,NULL,NULL,m.content_id,@now " ++
        "FROM message_admission m WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?4 ORDER BY m.admission_id",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, position_base: u64, first_admission: u64 },
    .expect = .{ .counted = .{ .otherwise = error.ProjectionFailed } },
});
const prior_skills_sql = "(SELECT count(*) FROM message_admission prior JOIN message_skill k ON k.admission_id=prior.admission_id WHERE " ++ selectedBeforeSql("m") ++ ")";

/// Projects each skill the Turn's bound Messages bound right after its
/// Message's entry, in the text's order: the selection's skill count.
const project_skills = rsql.Write(.{
    .sql = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_skill_admission_id,source_skill_position,content_id,recorded_at) " ++
        "SELECT owner.session_ref,owner.entry_ordinal+k.position,owner.session_position+k.position,4,?2,k.admission_id,k.position,k.content_id,@now " ++
        "FROM message_admission m JOIN conversation_entry owner ON owner.session_ref=m.session_ref AND owner.source_admission_id=m.admission_id JOIN message_skill k ON k.admission_id=m.admission_id " ++
        "WHERE m.session_ref=@session(?1) AND m.turn_id=?2 AND m.admission_id>=?3 ORDER BY m.admission_id,k.position",
    .Args = struct { session: rsql.SessionHead, turn_id: u64, first_admission: u64 },
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
        "admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,history_floor,history_level,history_dropped,attempt_ordinal,retry_due_at_ms,attempt_at,tool_set_id) " ++
        "VALUES(?1,?2,@session(?3),?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,1,0,@now,?14)",
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
        reasoning_effort: ?model_capability.ReasoningEffort,
        history_floor: ?u64,
        history_level: ?u8,
        history_dropped: ?u64,
        tool_set_id: u64,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// What an admission of `kind` selects: the owner `admitNextModelAttempt`
/// and the dispatch loop's work read (`dispatchWork`) queue it here.
fn queueSelection(reader: anytype, kind: ModelAdmissionKind, found: *runnable_selection.Result) void {
    switch (kind) {
        .message => reader.read(runnable_selection, .{}, found),
        .open_turn_message => reader.read(open_turn_selection, .{}, found),
        .tool_continuation => reader.read(tool_continuation_selection, .{}, found),
    }
}

fn queueSelectedContext(reader: anytype, kind: ModelAdmissionKind, row: *SelectedRow, found: *store_access.Found) void {
    switch (kind) {
        .message => reader.readInto(selected_context, .{}, row, found),
        .open_turn_message => reader.readInto(open_turn_context, .{}, row, found),
        .tool_continuation => reader.readInto(tool_continuation_context, .{}, row, found),
    }
}

/// What a model admission that selected nothing checks before the Store
/// counts as idle: no continuation disagrees with its calls, and every
/// blocked Operation's calls have their outcomes. `queue` rides the
/// caller's round; `settle` runs after it and costs one more round only
/// when an Operation is blocked.
const IdleChecks = struct {
    disagreeing: disagreeing_continuation.Result = undefined,
    blocked: reads_domain.First(blocked_operation.Row) = .{},

    fn queue(checks: *IdleChecks, reader: anytype) void {
        reader.read(disagreeing_continuation, .{}, &checks.disagreeing);
        reader.readEach(blocked_operation, .{}, 1, &checks.blocked);
    }

    fn settle(checks: *const IdleChecks, reader: anytype) !void {
        if (!try checks.settled()) try validateBlockedToolCalls(reader);
    }

    /// Whether the checks end here; false when a blocked Operation's
    /// calls are still to be read, in rounds of their own.
    fn settled(checks: *const IdleChecks) error{CorruptStore}!bool {
        if (checks.disagreeing != null) return error.CorruptStore;
        return checks.blocked.row == null;
    }
};

/// Admits the next model Attempt of `kind`. The read Access `reader`
/// selects, outside any transaction but inside the Store hold; with nothing
/// selected it runs main's idle checks, the disagreeing continuations with
/// whether any Operation is blocked, and only then the blocked calls'
/// outcomes, and answers null. The selected Session's admission facts and
/// recipe identities share selection's read batch, so Zig chooses coverage
/// before the write Access opens. Only the selected recipe's uncovered
/// bytes, where the purpose rests on them, are read inside the transaction.
/// Then it writes the Turn, binds and projects input, inserts the Operation
/// and commits. The Entry mutex excludes every other writer; a moved head is
/// `SelectionChanged`.
pub fn admitNextModelAttempt(reader: anytype, writer: anytype, kind: ModelAdmissionKind, pressure: Pressure, faults: Faults, start: ?historical_domain.Start) !?AttemptAdmission {
    var found: runnable_selection.Result = undefined;
    var facts_row: SelectedRow = undefined;
    var facts_found: store_access.Found = undefined;
    queueSelection(reader, kind, &found);
    queueSelectedContext(reader, kind, &facts_row, &facts_found);
    try store_access.runNamed(reader, .{
        .{ selected_context, error.SessionReadFailed },
        .{ open_turn_context, error.SessionReadFailed },
        .{ tool_continuation_context, error.SessionReadFailed },
    }, error.RunnableSelectionFailed);
    const selection = found orelse {
        var idle: IdleChecks = .{};
        idle.queue(reader);
        try store_access.runNamed(reader, .{.{ blocked_operation, error.CallReadFailed }}, error.TurnReadFailed);
        try idle.settle(reader);
        return null;
    };
    if (selection.cutoff.get() < selection.first_admission.get()) return error.CorruptStore;
    const session_ref: []const u8 = &selection.session.ref;
    const first_admission = selection.first_admission.get();
    if (!facts_found.get()) return error.CorruptStore;
    const facts = &facts_row;
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
        compaction.previous = previousTurn(facts.latest_compaction orelse return error.CorruptStore, resolution, facts.latest_active, latest_first.get(), first_admission, output_format.OutputItemKind.compaction.replayableTo((facts.latest_model orelse return error.CorruptStore).slice(), facts.model.slice(), .selected_base));
    }
    // The uncovered bytes are never read here. Where only their count
    // decides the purpose, the admission writes as an assistant response
    // and its first write checks the count against the policy's limit
    // (`within_pressure`); that guard's failure is `CompactionDue`, and the
    // caller admits again knowing the count is `.over` it.
    var purpose = turn_policy.nextPurpose(compaction);
    var weighed: ?within_pressure.Args = null;
    if (try takeContext(&compaction, facts, facts.model.slice(), session_ref)) |coverage| {
        purpose = turn_policy.nextPurpose(compaction);
        if (purpose != .compaction) if (turn_policy.compactingBytes(compaction)) |limit| switch (pressure) {
            .over => purpose = .compaction,
            .weighed => weighed = .{
                .session = facts.session,
                .covered = coverage.covered,
                .frontier = coverage.frontier,
                .results = coverage.results,
                .limit = @min(limit, std.math.maxInt(i64)),
            },
        };
    }
    // A compaction after one that overflowed makes room: settlement let
    // the Turn go on only because a deeper floor exists (D217).
    var dropped: u64 = 0;
    const room: ?history_floor_domain.Choice = if (compaction.previous) |previous| room: {
        if (purpose != .compaction or previous.purpose != .compaction or !previous.context_overflow or !previous.turn_active) break :room null;
        const latest = (facts.latest_operation orelse return error.CorruptStore).get();
        const deeper = try history_floor_domain.deeperFloor(writer, latest) orelse return error.CorruptStore;
        dropped = try history_floor_domain.droppedEntries(writer, latest, deeper);
        break :room deeper.choice;
    } else null;
    // A compaction that makes no room keeps its base's floor (D217).
    const floor: ?u64 = if (room) |choice| choice.floor else if (purpose == .compaction)
        try history_floor_domain.inheritedFloor(writer, session_ref, selection.session.next_position.get(), facts.model.slice())
    else
        null;
    const selected: u64 = if (purpose == .compaction) 0 else selection.selected;
    const instructions: u64 = if (purpose == .compaction) 0 else facts.instructions;

    const offer = try tool_offer.freeze(writer, facts.tool_set_id.get(), if (facts.loaded_tool_set_id) |id| id.get() else null, facts.offer_stale);
    if (weighed) |args| writer.write(within_pressure, args);
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
        const inputs = selected + selection.skills;
        writer.writeCount(bind_messages, .{ .turn_id = turn_id, .session = facts.session, .cutoff = cutoff }, selected);
        writer.writeCount(project_messages, .{
            .session = facts.session,
            .turn_id = turn_id,
            .position_base = try positions.take(inputs),
            .first_admission = first_admission,
        }, selected);
        if (selection.skills != 0) writer.writeCount(project_skills, .{ .session = facts.session, .turn_id = turn_id, .first_admission = first_admission }, selection.skills);
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
        .reasoning_effort = configuration_domain.effectiveReasoningEffort(facts),
        .history_floor = floor,
        .history_level = if (room) |choice| choice.level else null,
        .history_dropped = if (room != null) dropped else null,
        .tool_set_id = offer,
    });
    // The writes are queued, not run, as in every converted entry point.
    if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
    const binding: AttemptBinding = .{ .turn_id = turn_id, .operation_id = operation_id, .attempt_ordinal = 1 };
    // The request's settings round reads only what this commit saves, so
    // it follows COMMIT in the same message where that message has room.
    var request: historical_domain.SettingsRead = undefined;
    // Only a network engine's commit carries reads after it.
    const opened = if (start) |into| writer.store.engine.batches() and into.open(writer.store, binding) else false;
    if (opened) {
        request = .init(start.?.view, start.?.settings);
        store_core.followCommit(writer.store, request.follow());
    }
    defer if (opened) store_core.followCommit(writer.store, null);
    writer.commit() catch |err| {
        if (opened) start.?.view.close();
        return err;
    };
    const started = opened and start.?.view.settled != null;
    if (opened and !started) start.?.view.close();
    return .{ .permit = .{ .binding = binding }, .request_started = started };
}

/// Which of the dispatch loop's commit-driven scans would find work now.
/// A hint: each admission still selects for itself, so a stale one costs
/// an empty scan or a pass's delay, never a wrong write.
pub const DispatchWork = struct {
    /// An owed stop, an owed ending, a feed hop or a core tool call.
    core: bool,
    mcp: bool,
    bash: bool,
    /// Waiting input a Turn can take: any Session's, or while new Turns
    /// are held (`paused`) only an open Turn's.
    message: bool,
    tool_continuation: bool,
    /// An open Turn's Attempt is unresolved with a retry state: running,
    /// waiting for its retry or out of retries. The retry scans find
    /// nothing without one; they also skip what execution slots hold.
    retry: bool,

    /// Before the first read, and what a loop with no Store assumes.
    pub const unknown: DispatchWork = .{ .core = true, .mcp = true, .bash = true, .message = true, .tool_continuation = true, .retry = true };
};

/// The reads `DispatchWork` takes, as one round's statements: the
/// selections the slot-free, Bash, message and tool-continuation scans
/// each open with, queued by those scans' own owners, and the
/// `IdleChecks` a model admission that selects nothing would run.
pub const DispatchSurvey = struct {
    actions: action_domain.WorkProbe = .{},
    message: runnable_selection.Result = undefined,
    continuation: runnable_selection.Result = undefined,
    idle: IdleChecks = .{},
    retry: retrying_attempt.Result = undefined,

    /// The statement whose failed step names the read's failure.
    pub const named = .{.{ blocked_operation, error.CallReadFailed }};

    pub fn queue(survey: *DispatchSurvey, reader: anytype, paused: bool) void {
        survey.actions.queue(reader);
        queueSelection(reader, if (paused) .open_turn_message else .message, &survey.message);
        queueSelection(reader, .tool_continuation, &survey.continuation);
        survey.idle.queue(reader);
        reader.read(retrying_attempt, .{}, &survey.retry);
    }

    /// Whether the idle checks, which run when either selection found
    /// nothing, still have a blocked Operation's calls to read.
    fn unsettled(survey: *const DispatchSurvey) error{CorruptStore}!bool {
        if (survey.message != null and survey.continuation != null) return false;
        return !try survey.idle.settled();
    }

    /// The round's answer once its statements stepped; null when the
    /// idle checks need rounds of their own (`dispatchWork` takes them).
    pub fn work(survey: *const DispatchSurvey) error{CorruptStore}!?DispatchWork {
        if (try survey.unsettled()) return null;
        return survey.found();
    }

    fn found(survey: *const DispatchSurvey) DispatchWork {
        return .{
            .core = survey.actions.core(),
            .mcp = survey.actions.mcp(),
            .bash = survey.actions.bash(),
            .message = survey.message != null,
            .tool_continuation = survey.continuation != null,
            .retry = survey.retry != null,
        };
    }
};

/// Reads `DispatchWork`: `DispatchSurvey`'s round, then the blocked
/// calls' outcomes when the idle checks ask for them.
pub fn dispatchWork(reader: anytype, paused: bool) !DispatchWork {
    var survey: DispatchSurvey = .{};
    survey.queue(reader, paused);
    try store_access.runNamed(reader, DispatchSurvey.named, error.TurnReadFailed);
    if (try survey.unsettled()) try validateBlockedToolCalls(reader);
    return survey.found();
}

/// Whether any Attempt the retry scans read exists: each sets
/// `retry_due_at_ms` while unresolved, and every resolution clears it.
const retrying_attempt = rsql.Read(.{
    .sql = "SELECT 1 AS retrying FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
        "WHERE active.outcome_code IS NULL AND current.resolution_code IS NULL AND current.retry_due_at_ms IS NOT NULL LIMIT 1",
    .Args = struct {},
    .Row = struct { retrying: u64 },
    .cardinality = .optional,
});

/// Due retries in id order after `after`, with their Session: one page.
const due_retries = rsql.Read(.{
    .sql = retry_admission_select_text,
    .Args = struct { now_ms: u64, after: u64 },
    .Row = struct { turn_id: rsql.Positive, operation_id: rsql.Positive, attempt_ordinal: rsql.Positive, retry_due_at_ms: u64, session: rsql.SessionHead },
    .cardinality = .each,
});

/// The earliest scheduled retry not yet due, which no commit makes due:
/// only time does.
const next_scheduled_retry = rsql.Read(.{
    .sql = "SELECT o.retry_due_at_ms FROM model_operation o @index(model_operation_retry_due) JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o.resolution_code IS NULL AND o." ++ retry_allowance_open_sql ++ " " ++
        "AND o.retry_due_at_ms>?1 AND " ++ "@served(s.provider)" ++
        " ORDER BY o.retry_due_at_ms LIMIT 1",
    .Args = struct { now_ms: u64 },
    .Row = struct { retry_due_at_ms: u64 },
    .cardinality = .optional,
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
/// Store runs no other entry point meanwhile, so the write Access `a`
/// starts the replacement Attempt from what the scan read, in one round.
/// The first page's round also reads `scheduled`, when given: the Unix
/// millisecond the earliest scheduled retry not yet due falls due.
pub fn tryAdmitNextModelRetry(candidate: anytype, a: anytype, io: std.Io, active: ActiveOperationFilter, faults: Faults, scheduled: ?*?u64) !?AttemptAdmission {
    const now_ms = std.math.cast(u64, try store_core.readUnixMilliseconds(io)) orelse return error.IntegerOutOfRange;
    const limit = try std.math.add(u64, active.maximum_exclusions, 1);
    var choice: RetryChoice = .{ .active = active, .now_ms = now_ms };
    var next_scheduled: next_scheduled_retry.Result = null;
    var first_page = true;
    while (choice.chosen == null and choice.scanned < limit) {
        choice.page_rows = 0;
        candidate.readEach(due_retries, .{ .now_ms = now_ms, .after = choice.after }, limit - choice.scanned, &choice);
        if (first_page and scheduled != null) candidate.read(next_scheduled_retry, .{ .now_ms = now_ms }, &next_scheduled);
        try store_access.runAs(candidate, error.RetrySelectionFailed);
        if (first_page) if (scheduled) |out| {
            out.* = if (next_scheduled) |row| row.retry_due_at_ms else null;
        };
        first_page = false;
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
