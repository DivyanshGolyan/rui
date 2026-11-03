//! Model Attempt settlement: importing a validated output, saving failures and
//! reports, and fencing Attempts superseded by a control.

const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_catalog = @import("../../tools.zig");
const output_format = @import("../../output_format.zig");
const retry_policy = @import("../../retry_policy.zig");
const turn_policy = @import("../../turn_policy.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const rsql = @import("../rsql.zig");
const store_schema = @import("../schema.zig");
const action_domain = @import("action.zig");
const command_domain = @import("command.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const historical_domain = @import("historical.zig");
const model_admission_domain = @import("model_admission.zig");
const sqlite = @import("../sqlite.zig");
const store_access = @import("../access.zig");
const turn_domain = @import("turn.zig");
const c = sqlite.c;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptBinding = store_core.AttemptBinding;
const Faults = store_core.Faults;
const ModelOperationKind = historical_domain.ModelOperationKind;
const Ordinary = store_core.Ordinary;
const SessionFacts = configuration_domain.SessionFacts;
const SupersedingControl = action_domain.SupersedingControl;
const TurnOutcome = turn_domain.TurnOutcome;
const import_window_bytes = content_domain.import_window_bytes;
const retry_allowance_open_sql = model_admission_domain.retry_allowance_open_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;
const context_changed = model_admission_domain.context_changed;

/// Every model Operation resolution ends its Attempt or retry wait at
/// once, dated by the Access.
pub const operation_resolved_now_sql = "resolved_at=@now,attempt_at=NULL,retry_scheduled_at=NULL";

pub const ModelFailureClass = union(enum) {
    ordinary,
    context_overflow,
    retryable: retry_policy.Input,
    /// A model 401 whose one forced credential refresh completed under this
    /// Operation's claim: the replacement is due now, within the allowance.
    refreshed,
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
        /// The provider's own words, `code: message`; empty when it sent
        /// none. A terminal failure keeps it as its outcome's report.
        report: []const u8,
    };

    pub const Rejected = struct {
        code: []const u8,
        // Borrowed for settlement only; never Turn output or model continuation.
        diagnostic: []const u8,
        request_id: protocol.Bounded(256),
        report: []const u8,
    };

    pub fn code(self: *const ModelFailure) []const u8 {
        return switch (self.*) {
            .uncorrelated => |value| value,
            .correlated => |value| value.code,
            .rejected => |value| value.code,
        };
    }

    pub fn diagnostic(self: *const ModelFailure) ?[]const u8 {
        return switch (self.*) {
            .rejected => |value| value.diagnostic,
            .uncorrelated, .correlated => null,
        };
    }

    pub fn report(self: *const ModelFailure) []const u8 {
        return switch (self.*) {
            .uncorrelated => "",
            .correlated => |value| value.report,
            .rejected => |value| value.report,
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
const OutputRecordTag = output_format.OutputRecordTag;
const OutputMetadataRecord = output_format.OutputMetadataRecord;
const OutputMetadataReader = output_format.OutputMetadataReader;

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

pub fn checkAttempt(self: *Store, binding: AttemptBinding) !void {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    _ = try entry.finish(Ordinary.attempt_binding, validateCurrentAttempt(self, binding));
}

pub fn readModelOperationKind(self: *Store, operation_id: u64) !ModelOperationKind {
    const statement = try store_core.cached(self, "SELECT purpose FROM model_operation WHERE operation_id=?1");
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, operation_id);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
    return switch (c.sqlite3_column_int(statement, 0)) {
        0 => .assistant_response,
        1 => .compaction,
        else => error.CorruptStore,
    };
}

/// Checks that `binding` names its Operation's current Attempt, touching
/// and returning the Operation's Session.
pub fn validateCurrentAttempt(self: *Store, binding: AttemptBinding) !change_ring.Id {
    const statement = try store_core.cached(
        self,
        "SELECT turn_id,attempt_ordinal,resolution_code,interrupted_by_command_key,session_ref " ++
            "FROM model_operation WHERE operation_id=?1",
    );
    defer sqlite.resetCached(statement);
    try sqlite.bindU64(statement, 1, binding.operation_id);
    const step = c.sqlite3_step(statement);
    if (step == c.SQLITE_DONE) return error.StaleAttemptBinding;
    if (step != c.SQLITE_ROW) return error.OperationReadFailed;
    // Every write that settles this Attempt changes its Session.
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(statement, 4, &session);
    try store_core.touch(self, session.slice());
    if (session.len != change_ring.id_bytes) return error.CorruptStore;
    try attemptStanding(.{
        .turn_id = c.sqlite3_column_int64(statement, 0),
        .attempt_ordinal = c.sqlite3_column_int64(statement, 1),
        .resolved = c.sqlite3_column_type(statement, 2) != c.SQLITE_NULL,
        .interrupted = c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL,
    }, binding);
    return session.slice()[0..change_ring.id_bytes].*;
}

/// The stored facts that decide whether a binding is still current.
const AttemptFacts = struct { turn_id: i64, attempt_ordinal: i64, resolved: bool, interrupted: bool };

/// Whether `binding` names the Attempt whose Turn and ordinal these are.
fn namesAttempt(turn_id: i64, attempt_ordinal: i64, binding: AttemptBinding) bool {
    return turn_id == binding.turn_id and attempt_ordinal == binding.attempt_ordinal;
}

/// The one rule for a binding: current while it names its Operation's
/// unresolved Attempt; otherwise `SupersededByControl` when a control
/// interrupted that Attempt, else `StaleAttemptBinding`.
fn attemptStanding(facts: AttemptFacts, binding: AttemptBinding) error{ StaleAttemptBinding, SupersededByControl }!void {
    if (!namesAttempt(facts.turn_id, facts.attempt_ordinal, binding)) return error.StaleAttemptBinding;
    if (!facts.resolved) return;
    if (facts.interrupted) return error.SupersededByControl;
    return error.StaleAttemptBinding;
}

/// The Operation `operation_id`'s Attempt as settling it reads it: its
/// binding, whether it is resolved or interrupted, its purpose and claim,
/// its Session, and, when `closes`, whether its Turn is open on this
/// Operation; otherwise `turn_open` is false and unread. A missing Session
/// row fails to decode, `CorruptStore`, as main's session facts read was.
const attempt_facts = rsql.Read(.{
    .sql = "SELECT o.turn_id,o.attempt_ordinal,o.resolution_code IS NOT NULL AS resolved," ++
        "o.interrupted_by_command_key IS NOT NULL AS interrupted,o.purpose AS compaction,o.admission_position," ++
        "coalesce(o.retry_due_at_ms,0)<>0 AS retry_waiting,o.auth_refresh_claimed AS refresh_claimed," ++
        rsql.session_head_columns ++ "," ++
        "CASE WHEN ?2 THEN EXISTS(SELECT 1 FROM turn t WHERE t.turn_id=o.turn_id AND t.outcome_code IS NULL " ++
        "AND t.operation_id=o.operation_id) ELSE 0 END AS turn_open " ++
        "FROM model_operation o LEFT JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64, closes: bool },
    .Row = struct {
        turn_id: i64,
        attempt_ordinal: i64,
        resolved: bool,
        interrupted: bool,
        compaction: bool,
        admission_position: rsql.Positive,
        retry_waiting: bool,
        refresh_claimed: bool,
        session: rsql.SessionHead,
        turn_open: bool,
    },
    .cardinality = .optional,
});

/// After an `attempt_facts` round: its row while `attemptStanding` finds
/// `binding` current; a missing Operation is `StaleAttemptBinding`.
fn currentAttempt(facts: *const attempt_facts.Result, binding: AttemptBinding) error{ StaleAttemptBinding, SupersededByControl }!*const attempt_facts.Row {
    const row = &(facts.* orelse return error.StaleAttemptBinding);
    try attemptStanding(.{ .turn_id = row.turn_id, .attempt_ordinal = row.attempt_ordinal, .resolved = row.resolved, .interrupted = row.interrupted }, binding);
    return row;
}

const superseding_control = rsql.Read(.{
    .sql = "SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation WHERE operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { turn_id: i64, attempt_ordinal: i64, interrupted_by_command_key: ?protocol.Bounded(protocol.max_key_bytes) },
    .cardinality = .optional,
});

/// The control that interrupted the Attempt `binding` names, or null.
pub fn operationSupersededByControl(a: anytype, binding: AttemptBinding) !?SupersedingControl {
    var found: superseding_control.Result = undefined;
    a.read(superseding_control, .{ .operation_id = binding.operation_id }, &found);
    try runOperationRead(a);
    const row = found orelse return null;
    if (!namesAttempt(row.turn_id, row.attempt_ordinal, binding)) return null;
    return .{ .command_key = row.interrupted_by_command_key orelse return null };
}

const claim_auth_refresh = rsql.Write(.{
    .sql = "UPDATE model_operation SET auth_refresh_claimed=1 WHERE operation_id=?1 AND session_ref=@session(?3) " ++
        "AND resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=?2 AND auth_refresh_claimed=0 AND " ++ retry_allowance_open_sql,
    .Args = struct { operation_id: u64, attempt_ordinal: u64, session: rsql.SessionHead },
    // Main answered false when it changed no row; `claimModelAuthRefresh`
    // still does.
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.AuthRefreshUnclaimed } },
});

/// The error a failed step of an Operation read reports, as on main.
fn runOperationRead(a: anytype) !void {
    try store_access.runAs(a, error.OperationReadFailed);
}

/// Round 1 reads the Attempt; the claim is written only when the round
/// found it running, unclaimed and within the allowance. Otherwise, or
/// when the claim's UPDATE changes no row, the Access is abandoned and
/// the answer is false, as on main.
pub fn claimModelAuthRefresh(a: anytype, binding: AttemptBinding) !bool {
    var facts: attempt_facts.Result = undefined;
    a.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = false }, &facts);
    try runOperationRead(a);
    const row = try currentAttempt(&facts, binding);
    if (row.retry_waiting or row.refresh_claimed or binding.attempt_ordinal >= retry_policy.maximum_attempts) {
        try a.abandon(.{});
        return false;
    }
    a.write(claim_auth_refresh, .{ .operation_id = binding.operation_id, .attempt_ordinal = binding.attempt_ordinal, .session = row.session });
    a.commit() catch |err| {
        if (err != error.AuthRefreshUnclaimed) return err;
        try a.abandon(.{});
        return false;
    };
    return true;
}

/// Resolves an unresolved Attempt with a failure: `ordinary`, a context
/// overflow and an exhausted retry. `last_failure_code` null keeps the
/// saved one.
const resolve_failure = rsql.Write(.{
    .sql = "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,request_id=?4," ++
        "last_failure_code=coalesce(?5,last_failure_code)," ++ operation_resolved_now_sql ++ " " ++
        "WHERE operation_id=?1 AND session_ref=@session(?7) AND resolution_code IS NULL AND attempt_ordinal=?6",
    .Args = struct { operation_id: u64, resolution: []const u8, content_id: ?u64, request_id: ?[]const u8, last_failure_code: ?[]const u8, attempt_ordinal: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

/// Ends a failed Attempt with a retry due at `due_at_ms`.
const schedule_retry = rsql.Write(.{
    .sql = "UPDATE model_operation SET retry_due_at_ms=?2,last_failure_code=?3,retry_scheduled_at=@now,attempt_at=NULL " ++
        "WHERE operation_id=?1 AND session_ref=@session(?5) AND resolution_code IS NULL AND attempt_ordinal=?4",
    .Args = struct { operation_id: u64, due_at_ms: u64, code: []const u8, attempt_ordinal: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

/// The content a failure settles with: its diagnostic and its report.
const FailureContent = struct {
    diagnostic: ?content_domain.Import,
    report: ?content_domain.Import,
    pair: content_domain.Pair = undefined,

    fn of(failure: *const ModelFailure) FailureContent {
        const report = failure.report();
        return .{
            .diagnostic = if (failure.diagnostic()) |detail| .ofBytes(detail, false) else null,
            .report = if (report.len == 0) null else .ofBytes(report, false),
        };
    }

    /// Queues the lookups of both values: one statement for one or two.
    fn lookup(content: *FailureContent, a: anytype) void {
        if (content.diagnostic != null and content.report != null) {
            content_domain.lookupPair(a, &content.diagnostic.?, &content.report.?, &content.pair);
        } else if (content.diagnostic) |*value| {
            content_domain.lookup(a, value);
        } else if (content.report) |*value| content_domain.lookup(a, value);
    }

    /// After the lookup round.
    fn found(content: *FailureContent) void {
        if (content.diagnostic != null and content.report != null) content_domain.foundPair(&content.pair, &content.diagnostic.?, &content.report.?);
    }

    fn importDiagnostic(content: *FailureContent, a: anytype, failure: *const ModelFailure) !?u64 {
        const value = if (content.diagnostic) |*value| value else return null;
        return try content_domain.importBytes(a, value, failure.diagnostic().?);
    }

    /// The report's row. One equal to the diagnostic is the diagnostic's
    /// (`content.importSlot`).
    fn importReport(content: *FailureContent, a: anytype, failure: *const ModelFailure) !?u64 {
        const value = if (content.report) |*value| value else return null;
        return try content_domain.importBytes(a, value, failure.report());
    }
};

/// Round 1 reads the Attempt and, for a failure that resolves it, looks
/// up the failure's diagnostic and report. A context overflow reads in
/// round 2 whether compaction can recover it, which needs the Attempt's
/// position. The write round resolves the Attempt or schedules its retry,
/// and closes its Turn or records its continuation, then commits.
pub fn settleModelAttemptFailure(
    a: anytype,
    io: std.Io,
    binding: AttemptBinding,
    failure: ModelFailure,
    disposition: ModelFailureClass,
    faults: Faults,
) !void {
    const code = failure.code();
    var retry_random: u64 = 0;
    if (disposition == .retryable) io.random(std.mem.asBytes(&retry_random));
    // Only a resolving failure saves content: an ordinary one, an overflow,
    // or a retry that exhausts the allowance.
    const resolves = switch (disposition) {
        .ordinary, .context_overflow => true,
        .refreshed => false,
        .retryable => binding.attempt_ordinal == retry_policy.maximum_attempts,
    };
    var facts: attempt_facts.Result = undefined;
    var content: FailureContent = if (resolves) .of(&failure) else .{ .diagnostic = null, .report = null };
    a.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = resolves }, &facts);
    content.lookup(a);
    try runOperationRead(a);
    content.found();
    const row = try currentAttempt(&facts, binding);
    const session = row.session;
    switch (disposition) {
        .ordinary, .context_overflow => {
            const compact = disposition == .context_overflow and compact: {
                var changed: context_changed.Result = undefined;
                a.read(context_changed, .{ .session = &session.ref, .boundary = row.admission_position.get() }, &changed);
                try a.run();
                const purpose: ModelOperationKind = if (row.compaction) .compaction else .assistant_response;
                break :compact turn_policy.recoversOverflow(purpose, changed.changed);
            };
            if (content.diagnostic != null and faults.content_import) return error.InjectedContentImportFailure;
            const diagnostic_id = try content.importDiagnostic(a, &failure);
            a.write(resolve_failure, .{
                .operation_id = binding.operation_id,
                .resolution = if (disposition == .context_overflow) @tagName(turn_policy.Resolution.context_overflow) else code,
                .content_id = diagnostic_id,
                .request_id = optionalText(failure.requestId()),
                .last_failure_code = if (disposition == .context_overflow) code else null,
                .attempt_ordinal = binding.attempt_ordinal,
                .session = session,
            });
            if (compact) {
                turn_domain.queueContinuation(a, binding.turn_id, session);
            } else {
                if (!row.turn_open) return error.StaleAttemptBinding;
                if (content.report != null and faults.content_import) return error.InjectedContentImportFailure;
                const report = try content.importReport(a, &failure);
                const outcome: TurnOutcome = if (disposition == .context_overflow) .{ .resource_exceeded = optionalId(report) } else .{ .failed = .{
                    .code = code,
                    .report = optionalId(report),
                } };
                try turn_domain.queueCloseOr(a, try a.positions(session), binding.turn_id, outcome, error.StaleAttemptBinding);
            }
        },
        .refreshed => {
            if (!row.refresh_claimed or binding.attempt_ordinal >= retry_policy.maximum_attempts) return error.StaleAttemptBinding;
            a.write(schedule_retry, .{
                .operation_id = binding.operation_id,
                .due_at_ms = @intCast(@max(1, try store_core.readUnixMilliseconds(io))),
                .code = code,
                .attempt_ordinal = binding.attempt_ordinal,
                .session = session,
            });
        },
        .retryable => |policy| switch (try retry_policy.decide(binding.attempt_ordinal, policy, try store_core.readUnixMilliseconds(io), retry_random)) {
            .schedule_at_ms => |due_at_ms| a.write(schedule_retry, .{
                .operation_id = binding.operation_id,
                .due_at_ms = std.math.cast(u64, due_at_ms) orelse return error.IntegerOutOfRange,
                .code = code,
                .attempt_ordinal = binding.attempt_ordinal,
                .session = session,
            }),
            .exhausted => {
                if (content.diagnostic != null and faults.content_import) return error.InjectedContentImportFailure;
                const diagnostic_id = try content.importDiagnostic(a, &failure);
                a.write(resolve_failure, .{
                    .operation_id = binding.operation_id,
                    .resolution = "retry_exhausted",
                    .content_id = diagnostic_id,
                    // The settling Attempt's correlation, like a terminal failure.
                    .request_id = optionalText(failure.requestId()),
                    .last_failure_code = code,
                    .attempt_ordinal = binding.attempt_ordinal,
                    .session = session,
                });
                if (!row.turn_open) return error.StaleAttemptBinding;
                if (content.report != null and faults.content_import) return error.InjectedContentImportFailure;
                const report = try content.importReport(a, &failure);
                try turn_domain.queueCloseOr(a, try a.positions(session), binding.turn_id, .{ .retry_exhausted = optionalId(report) }, error.StaleAttemptBinding);
            },
        },
    }
    if (faults.before_commit) return error.InjectedCommitFailure;
    try a.commit();
}

/// Text that binds NULL when empty, as `sqlite.bindOptionalText` did.
fn optionalText(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

fn optionalId(id: ?u64) ?i64 {
    return if (id) |value| @intCast(value) else null;
}

/// Unresolved last Attempts with no retry due, in id order, with their
/// Session and whether their Turn is open on them.
const exhausted_attempts = rsql.Read(.{
    .sql = "SELECT o.turn_id,o.operation_id," ++ rsql.session_head_columns ++ "," ++
        "EXISTS(SELECT 1 FROM turn t WHERE t.turn_id=o.turn_id AND t.outcome_code IS NULL " ++
        "AND t.operation_id=o.operation_id) AS turn_open " ++
        "FROM model_operation o @index(model_operation_retry_exhausted) JOIN session s ON s.session_ref=o.session_ref " ++
        "WHERE o." ++ retry_exhausted_sql ++ " ORDER BY o.operation_id",
    .Args = struct {},
    .Row = struct { turn_id: rsql.Positive, operation_id: rsql.Positive, session: rsql.SessionHead, turn_open: bool },
    .cardinality = .each,
});

const resolve_exhausted = rsql.Write(.{
    .sql = "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code='retry_exhausted'," ++ operation_resolved_now_sql ++ " " ++
        "WHERE operation_id=?1 AND session_ref=@session(?2) AND " ++ retry_exhausted_sql,
    .Args = struct { operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SelectionChanged } },
});

/// Picks the first scanned Attempt no execution slot holds.
const ExhaustedChoice = struct {
    active: ActiveOperationFilter,
    chosen: ?exhausted_attempts.Row = null,

    pub fn visit(choice: *ExhaustedChoice, row: *const exhausted_attempts.Row) bool {
        if (choice.active.contains(row.operation_id.get())) return true;
        choice.chosen = row.*;
        return false;
    }
};

/// Resolves one exhausted Attempt no slot holds and closes its Turn. The
/// read Access `candidate` scans outside any transaction, so a pass that
/// finds none runs only the scan; the scan stops at the first Attempt
/// `active` does not hold, after at most one more than it can exclude.
/// The held Store mutex excludes every other writer, so the write Access
/// `a` writes from what the scan read, in one round.
pub fn recoverOneExhaustedModelAttempt(candidate: anytype, a: anytype, active: ActiveOperationFilter) !bool {
    var choice: ExhaustedChoice = .{ .active = active };
    candidate.readEach(exhausted_attempts, .{}, try std.math.add(u64, active.maximum_exclusions, 1), &choice);
    try store_access.runAs(candidate, error.RetryRecoveryFailed);
    const chosen = choice.chosen orelse return false;
    if (!chosen.turn_open) return error.SelectionChanged;
    a.write(resolve_exhausted, .{ .operation_id = chosen.operation_id.get(), .session = chosen.session });
    try turn_domain.queueCloseOr(a, try a.positions(chosen.session), chosen.turn_id.get(), .{ .retry_exhausted = null }, error.SelectionChanged);
    try a.commit();
    return true;
}

/// What settling a success reads beside its Attempt: the Operation's
/// frozen tools, null when its revision row is missing (main's
/// `StaleAttemptBinding`), the Session's permission mode and revision,
/// and the last Conversation ordinal.
const success_facts = rsql.Read(.{
    .sql = "SELECT r.tools_mask,s.permission_mode,s.revision," ++
        "coalesce((SELECT max(e.entry_ordinal) FROM conversation_entry e WHERE e.session_ref=o.session_ref),0) AS entry_base " ++
        "FROM model_operation o LEFT JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { tools_mask: ?u8, permission_mode: bool, revision: rsql.Positive, entry_base: u64 },
    .cardinality = .optional,
});

/// The Messages of the Operation's Session that no Turn took and no stop
/// excludes, as main's pending count (`command.pending_messages`): one
/// statement of its own, so a failed step reports main's
/// `SessionStopReadFailed`.
const pending_messages = rsql.Read(.{
    .sql = "SELECT count(*) AS pending FROM model_operation o JOIN message_admission m ON m.session_ref=o.session_ref " ++
        "WHERE o.operation_id=?1 AND m.turn_id IS NULL AND m.admission_id>coalesce((" ++
        "SELECT stop.admission_cutoff FROM session_stop stop WHERE stop.session_ref=o.session_ref ORDER BY stop.admission_cutoff DESC LIMIT 1),0)",
    .Args = struct { operation_id: u64 },
    .Row = struct { pending: u64 },
    .cardinality = .one,
});

/// Ends a settlement round, mapping a failed step to the name main gave
/// that read: the Attempt and the facts read beside it
/// `OperationReadFailed` (main's operation read joined the revision), the
/// pending Messages `SessionStopReadFailed`, and the output's content and
/// duplicate reads `OutputReadFailed`. A write's failed step stays
/// `StatementFailed`.
fn runSettlement(a: anytype) !void {
    a.run() catch |err| {
        if (err != error.StatementFailed) return err;
        if (a.failedOn(attempt_facts) or a.failedOn(success_facts)) return error.OperationReadFailed;
        if (a.failedOn(pending_messages)) return error.SessionStopReadFailed;
        if (a.failedOn(content_batch) or a.failedOn(content_batch_wide) or a.failedOn(content_domain.lookup_content) or
            a.failedOn(duplicate_items) or a.failedOn(duplicate_items_wide) or
            a.failedOn(duplicate_calls) or a.failedOn(duplicate_calls_wide)) return error.OutputReadFailed;
        return err;
    };
}

/// "?k,?k+1,...": `count` parameters from `first`.
fn parameters(comptime first: usize, comptime count: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var text: []const u8 = "";
        for (first..first + count) |number| text = text ++ (if (number == first) "" else ",") ++ std.fmt.comptimePrint("?{d}", .{number});
        return text;
    }
}

/// Args of the `u64` fields `lead`, then `width` digests `d1..`, bound
/// by value in the order an IN list binds them. Extern, so the digests sit
/// back to back after the lead and a batch binds its own storage in place:
/// `Batch.identity_digests` for a lookup, `Batch.ids` for a duplicate read.
fn DigestArgs(comptime lead: []const [:0]const u8, comptime width: usize) type {
    @setEvalBranchQuota(20_000);
    const count = lead.len + width;
    var names: [count][:0]const u8 = undefined;
    var types: [count]type = undefined;
    for (lead, 0..) |name, index| {
        names[index] = name;
        types[index] = u64;
    }
    for (0..width) |index| {
        names[lead.len + index] = std.fmt.comptimePrint("d{d}", .{index + 1});
        types[lead.len + index] = [32]u8;
    }
    return @Struct(.@"extern", null, &names, &types, &@splat(.{}));
}

/// `width` digests from `digests[0]`, as `S`'s Args: the first `count`
/// are the read's, and the slots after them take the first again, since a
/// repeated digest adds no row to an IN list. The slots past `count` are
/// ones the batch does not use, so writing them loses nothing.
fn digestArgs(comptime S: type, comptime width: usize, digests: *[width][32]u8, count: usize) *const S.Args {
    comptime std.debug.assert(@sizeOf(S.Args) == width * 32 and @offsetOf(S.Args, "d1") == 0);
    std.debug.assert(count != 0 and count <= width);
    for (digests[count..]) |*slot| slot.* = digests[0];
    return @ptrCast(digests);
}

/// Every content row with one of `width` digests. A digest names one
/// length (import verifies it), so each has at most a public and a private
/// row: `n` distinct digests return at most `2n` rows.
fn ContentBatch(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT content_id,digest,byte_length,private FROM content WHERE digest IN (" ++ parameters(1, width) ++ ")",
        .Args = DigestArgs(&.{}, width),
        .Row = LookupRow,
        .cardinality = .each,
    });
}

const LookupRow = struct { content_id: rsql.Positive, digest: [32]u8, byte_length: u64, private: bool };

/// The item ids among `width` that the Operation already saved: one row
/// each at most, as `(operation_id, item_id_digest)` is unique. Read with
/// `readEach`, so `DuplicateVisitor` keeps the lowest batch index any row
/// names, which `.optional` could not.
fn DuplicateItems(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT item_id_digest AS digest FROM model_output_item WHERE operation_id=?1 AND item_id_digest IN (" ++ parameters(2, width) ++ ")",
        .Args = DigestArgs(&.{"operation_id"}, width),
        .Row = DuplicateRow,
        .cardinality = .each,
    });
}

/// The call ids among `width` that the Operation already saved: one row
/// each at most, as `(operation_id, call_id_content_id)` is unique and a
/// call id is public content.
fn DuplicateCalls(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT c.digest FROM model_tool_call t JOIN content c ON c.content_id=t.call_id_content_id " ++
            "WHERE t.operation_id=?1 AND c.private=0 AND c.digest IN (" ++ parameters(2, width) ++ ")",
        .Args = DigestArgs(&.{"operation_id"}, width),
        .Row = DuplicateRow,
        .cardinality = .each,
    });
}

/// Each digest read in two widths: a batch binds the narrow one when its
/// digests fit it, so a reply of at most `narrow_width` items or calls
/// runs main's statements, and the wide one past that.
const content_batch = ContentBatch(narrow_width);
const content_batch_wide = ContentBatch(lookup_width);
const duplicate_items = DuplicateItems(narrow_width);
const duplicate_items_wide = DuplicateItems(batch_items);
const duplicate_calls = DuplicateCalls(narrow_width);
const duplicate_calls_wide = DuplicateCalls(batch_items);

comptime {
    // `queueReads` binds `duplicate_items`' Args to a calls read too.
    std.debug.assert(duplicate_items.Args == duplicate_calls.Args and duplicate_items_wide.Args == duplicate_calls_wide.Args);
}

/// The Operation and a batch's item or call id digests, laid out as the
/// wide duplicate read's Args, whose narrow Args are a prefix of it.
const DuplicateIds = extern struct {
    operation_id: u64,
    digests: [batch_items][32]u8,

    comptime {
        for (.{ duplicate_items.Args, duplicate_items_wide.Args }, .{ narrow_width, batch_items }) |Args, width| {
            std.debug.assert(@offsetOf(Args, "operation_id") == @offsetOf(DuplicateIds, "operation_id"));
            std.debug.assert(@offsetOf(Args, "d1") == @offsetOf(DuplicateIds, "digests"));
            std.debug.assert(@sizeOf(Args) == @offsetOf(DuplicateIds, "digests") + width * 32);
        }
    }

    /// The ids as `S`'s Args, padded past `count` as `digestArgs` pads.
    fn args(ids: *DuplicateIds, comptime S: type, comptime width: usize, count: usize) *const S.Args {
        std.debug.assert(count != 0 and count <= width);
        for (ids.digests[count..width]) |*slot| slot.* = ids.digests[0];
        return @ptrCast(ids);
    }
};

const DuplicateRow = struct { digest: [32]u8 };

const insert_part = rsql.Write(.{
    .sql = "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
    .Args = struct { operation_id: u64, item_ordinal: u64, part_ordinal: u64, part_array: u64, part_kind: u64, text_length: ?u64, text_content_id: ?u64, extras_content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_item = rsql.Write(.{
    .sql = "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest," ++
        "replay_omits_reasoning_text,phase,extras_content_id,part_count,message_content_id,description,call_failed) " ++
        "VALUES(?1,?2,@session(?3),?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
    .Args = struct {
        operation_id: u64,
        item_ordinal: u64,
        session: rsql.SessionHead,
        position: u64,
        kind: u64,
        attempt_ordinal: u64,
        id_digest: [32]u8,
        omits_reasoning_text: bool,
        phase: u64,
        extras_content_id: u64,
        part_count: u64,
        message_content_id: ?u64,
        description: ?tool_catalog.Description,
        call_failed: bool,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// A visible message's Conversation entry, at its item's position.
const insert_entry = rsql.Write(.{
    .sql = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id,recorded_at) " ++
        "VALUES(@session(?1),?2,?3,3,?4,?5,?6,?7,@now)",
    .Args = struct { session: rsql.SessionHead, ordinal: u64, position: u64, turn_id: u64, operation_id: u64, item_ordinal: u64, content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_call = rsql.Write(.{
    .sql = "INSERT INTO model_tool_call(operation_id,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id," ++
        "rejection_code,rejection_content_id,acceptance_position,action_kind,description,field_metadata,session_ref) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,@session(?13))",
    .Args = struct {
        operation_id: u64,
        call_ordinal: u64,
        item_ordinal: u64,
        name_content_id: u64,
        call_id_content_id: u64,
        arguments_content_id: u64,
        rejection_code: ?protocol.ProposalRejection,
        rejection_content_id: ?u64,
        acceptance_position: ?u64,
        action_kind: ?u64,
        description: ?tool_catalog.Description,
        field_metadata: [120]u8,
        session: rsql.SessionHead,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// An accepted call's Action, decided now when the revision bypasses asks.
const insert_action = rsql.Write(.{
    .sql = "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,bash_timeout_override_ms,resolution_code,decided_at) " ++
        "VALUES(?1,?2,?3,@session(?4),1,?5,?6,?7,NULL,CASE WHEN ?6=1 THEN @now END)",
    .Args = struct { action_id: u64, operation_id: u64, call_ordinal: u64, session: rsql.SessionHead, revision: u64, authorized: bool, timeout_ms: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

/// Resolves the settling Attempt with its output.
const resolve_success = rsql.Write(.{
    .sql = "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,model_evidence=?5,request_id=?6,usage_content_id=?7,output_item_count=?8," ++
        "usage_uncached_tokens=?9,usage_cache_read_tokens=?10,usage_cache_write_tokens=?11,usage_output_tokens=?12," ++ operation_resolved_now_sql ++ " " ++
        "WHERE operation_id=?1 AND session_ref=@session(?14) AND resolution_code IS NULL AND attempt_ordinal=?13",
    .Args = struct {
        operation_id: u64,
        resolution: []const u8,
        content_id: ?u64,
        response_id: ?[]const u8,
        model_evidence: rsql.Bytes,
        request_id: ?[]const u8,
        usage_content_id: ?u64,
        item_count: u64,
        uncached: ?u64,
        cache_read: ?u64,
        cache_write: ?u64,
        output: ?u64,
        attempt_ordinal: u64,
        session: rsql.SessionHead,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

/// The most items or calls one batch holds: the wide duplicate read binds
/// one digest each beside the Operation, the Store's 65 variables
/// (`SQLITE_LIMIT_VARIABLE_NUMBER`).
const batch_items = 64;
/// The digests a narrow digest read binds, as main's sixteen.
const narrow_width = 16;
/// The digests one wide `content_batch` statement binds.
const lookup_width = batch_items;
/// The most distinct content identities one batch looks up, in four wide
/// `content_batch` statements: a call imports at most four (its name,
/// call_id, arguments and rejection text), so 64 calls always fit.
const batch_identities = 4 * lookup_width;
/// The identities left above which a lookup takes a wide statement: three
/// narrow statements step less than one wide statement padded to 64
/// values, four more (measured: 33 identities took 316 steps in three
/// narrow statements and 342 in one wide).
const wide_lookup_above = 3 * narrow_width;
/// The `content_batch` statements `n` identities take.
fn lookupCount(n: usize) usize {
    var left = n;
    var count: usize = 0;
    while (left != 0) : (count += 1) left -= @min(if (left > wide_lookup_above) lookup_width else narrow_width, left);
    return count;
}
/// The most `content_batch` statements one batch queues.
const max_lookups = blk: {
    @setEvalBranchQuota(100_000);
    var most: usize = 0;
    for (1..batch_identities + 1) |n| most = @max(most, lookupCount(n));
    break :blk most;
};

/// A content identity a batch imports, beside its digest in
/// `Batch.identity_digests`, and its row: 0 until the lookup round found
/// one or the batch inserted one.
const Identity = struct {
    length: u64,
    row: packed struct(u64) { content_id: u63, private: bool },
};

/// Matches one `content_batch` statement's rows to its batch's identities.
const LookupVisitor = struct {
    batch: *Batch,
    /// `2n` for `n` distinct digests; one more row is `CorruptStore`.
    limit: u8,
    rows: u8 = 0,
    overflow: bool = false,

    pub fn visit(visitor: *LookupVisitor, row: *const LookupRow) bool {
        if (visitor.rows == visitor.limit) {
            visitor.overflow = true;
            return false;
        }
        visitor.rows += 1;
        if (visitor.batch.find(&.{ .digest = row.digest, .length = row.byte_length, .private = row.private })) |identity| identity.row.content_id = @intCast(row.content_id.get());
        return true;
    }
};

/// Finds the lowest index of a batch digest the Operation already saved.
const DuplicateVisitor = struct {
    batch: *Batch,
    rows: u8 = 0,
    overflow: bool = false,
    lowest: ?u8 = null,

    pub fn visit(visitor: *DuplicateVisitor, row: *const DuplicateRow) bool {
        if (visitor.rows == batch_items) {
            visitor.overflow = true;
            return false;
        }
        visitor.rows += 1;
        for (visitor.batch.ids.digests[0..visitor.batch.digest_count], 0..) |*candidate, index| {
            if (!std.mem.eql(u8, candidate, &row.digest)) continue;
            if (visitor.lowest == null or index < visitor.lowest.?) visitor.lowest = @intCast(index);
            break;
        }
        return true;
    }
};

/// One stretch of the output's metadata, imported in two rounds: the round
/// that looks up its content and duplicates, then the round that writes it.
/// Every row a batch writes binds its values by value, so the next batch is
/// collected into the same table as soon as this one's rows are queued.
pub const Batch = struct {
    kind: enum { items, calls },
    /// The metadata records it covers: `[start, end)`.
    start: u64,
    end: u64,
    /// What stopped the collecting walk at `end`, which the write walk
    /// returns when it gets there, as main's walk would.
    stopped: ?anyerror,
    /// Whether no records follow `end` for a later batch of this kind.
    last: bool,
    /// Each identity's digest, back to back, so a lookup binds a run of
    /// them in place.
    identity_digests: [batch_identities][32]u8,
    identities: [batch_identities]Identity,
    identity_count: u16,
    /// Each item's id digest, or each call's call_id digest, in order.
    ids: DuplicateIds,
    digest_count: u8,
    lookups: [max_lookups]LookupVisitor,
    lookup_count: u8,
    duplicates: DuplicateVisitor,

    fn reset(batch: *Batch, kind: @FieldType(Batch, "kind"), start: u64) void {
        batch.kind = kind;
        batch.start = start;
        batch.end = start;
        batch.stopped = null;
        batch.last = false;
        batch.identity_count = 0;
        batch.digest_count = 0;
        batch.lookup_count = 0;
        batch.duplicates = .{ .batch = batch };
    }

    /// Ends the batch at `at`, where the collecting walk failed with
    /// `failure`. With no failure, the write walk walks on and fails at
    /// the same record, as main's walk does.
    fn stop(batch: *Batch, failure: ?anyerror, at: u64) void {
        batch.stopped = failure;
        batch.end = if (failure == null) std.math.maxInt(u64) else at;
        batch.last = true;
    }

    fn find(batch: *Batch, value: *const content_domain.Import) ?*Identity {
        for (batch.identities[0..batch.identity_count], batch.identity_digests[0..batch.identity_count]) |*identity, *digest| {
            if (identity.length == value.length and identity.row.private == value.private and std.mem.eql(u8, digest, &value.digest)) return identity;
        }
        return null;
    }

    /// Adds an identity unless the batch has it; false when it is full.
    fn add(batch: *Batch, value: content_domain.Import) bool {
        if (batch.find(&value) != null) return true;
        if (batch.identity_count == batch_identities) return false;
        batch.identity_digests[batch.identity_count] = value.digest;
        batch.identities[batch.identity_count] = .{ .length = value.length, .row = .{ .content_id = 0, .private = value.private } };
        batch.identity_count += 1;
        return true;
    }

    /// Queues the lookups of every identity and the duplicate read, each
    /// in its narrow width when its digests fit it. The identities go in
    /// wide statements while more than `wide_lookup_above` are left, and in
    /// narrow ones after (`lookupCount`).
    fn queueReads(batch: *Batch, a: anytype, operation_id: u64) void {
        var first: u16 = 0;
        while (first < batch.identity_count) {
            const left = batch.identity_count - first;
            const count = @min(@as(u16, if (left > wide_lookup_above) lookup_width else narrow_width), left);
            const chunk = batch.identity_digests[first..][0..count];
            var distinct: u8 = 0;
            for (chunk, 0..) |*digest, index| {
                // A public and a private identity of one value share a digest.
                const seen = for (chunk[0..index]) |*earlier| {
                    if (std.mem.eql(u8, earlier, digest)) break true;
                } else false;
                if (!seen) distinct += 1;
            }
            const visitor = &batch.lookups[batch.lookup_count];
            visitor.* = .{ .batch = batch, .limit = 2 * distinct };
            batch.lookup_count += 1;
            const limit = 2 * @as(u64, distinct) + 1;
            // Only the last run is short, so its padding lands in unused
            // slots: wide runs start at multiples of 64 and narrow ones at
            // multiples of 16, below `batch_identities`.
            if (count <= narrow_width) {
                a.readEachFrom(content_batch, digestArgs(content_batch, narrow_width, batch.identity_digests[first..][0..narrow_width], count), limit, visitor);
            } else {
                a.readEachFrom(content_batch_wide, digestArgs(content_batch_wide, lookup_width, batch.identity_digests[first..][0..lookup_width], count), limit, visitor);
            }
            first += count;
        }
        if (batch.digest_count == 0) return;
        batch.ids.operation_id = operation_id;
        if (batch.digest_count <= narrow_width) {
            const args = batch.ids.args(duplicate_items, narrow_width, batch.digest_count);
            switch (batch.kind) {
                .items => a.readEachFrom(duplicate_items, args, batch_items + 1, &batch.duplicates),
                .calls => a.readEachFrom(duplicate_calls, args, batch_items + 1, &batch.duplicates),
            }
        } else {
            const args = batch.ids.args(duplicate_items_wide, batch_items, batch.digest_count);
            switch (batch.kind) {
                .items => a.readEachFrom(duplicate_items_wide, args, batch_items + 1, &batch.duplicates),
                .calls => a.readEachFrom(duplicate_calls_wide, args, batch_items + 1, &batch.duplicates),
            }
        }
    }

    /// After the reads' round: more rows than identities allow is a
    /// corrupt Store.
    fn checkReads(batch: *const Batch) error{CorruptStore}!void {
        for (batch.lookups[0..batch.lookup_count]) |visitor| if (visitor.overflow) return error.CorruptStore;
        if (batch.duplicates.overflow) return error.CorruptStore;
    }

    /// Whether the digest at `index` repeats an earlier one in the batch,
    /// or the Store already holds it.
    fn duplicate(batch: *const Batch, index: u8) bool {
        if (batch.duplicates.lowest) |lowest| if (lowest == index) return true;
        for (batch.ids.digests[0..index]) |*earlier| if (std.mem.eql(u8, earlier, &batch.ids.digests[index])) return true;
        return false;
    }
};

/// The identity a metadata record imports, if any, as main imports it:
/// a decoded part text, a bag, a message text, the usage record, and a
/// call's name, call_id and arguments.
fn recordImport(record: *const OutputMetadataRecord) ?content_domain.Import {
    const length: u64, const private = switch (record.tag) {
        .part => switch (record.part_kind) {
            .summary_text, .reasoning_text => .{ record.decoded_length, true },
            .opaque_block, .output_text, .refusal => return null,
        },
        .extras => .{ record.decoded_length, true },
        .text => .{ record.decoded_length, false },
        .usage => .{ record.length, true },
        .name, .call_id, .arguments => .{ record.decoded_length, false },
        .item, .action, .pattern, .member => return null,
    };
    return .{ .digest = record.content_digest, .length = length, .private = private };
}

/// Collects the next items from `start`: whole items, at most
/// `batch_items`, while their identities fit, the usage record's and an
/// empty answer's included. A first item whose identities do not all fit
/// is taken alone; the rest are looked up when written
/// (`Settlement.content`). Never fails: a metadata read failure stops the
/// batch there, for the write walk to return.
fn collectItems(batch: *Batch, output: *const ValidatedOutput, io: std.Io, start: u64) void {
    batch.reset(.items, start);
    var reader = OutputMetadataReader.init(io, output.metadata, output.item_count) catch |err| return batch.stop(err, start);
    reader.offset = start;
    var unit_start = start;
    var unit_identities = batch.identity_count;
    var unfit = false;
    while (true) {
        const record_start = reader.offset;
        const record = (reader.next() catch |err| return batch.stop(err, record_start)) orelse {
            batch.end = reader.offset;
            batch.last = true;
            return;
        };
        if (record.tag == .item or record.tag == .usage) {
            if (record.tag == .usage and !unfit and !batch.add(recordImport(&record).?)) unfit = true;
            if (record.tag == .item and !unfit and output.answer_length == 0 and output.answer_item_ordinal == record.ordinal and
                !batch.add(content_domain.empty_content)) unfit = true;
            if (unfit and batch.digest_count != 0) {
                batch.identity_count = unit_identities;
                batch.end = unit_start;
                return;
            }
            if (record.tag == .item) {
                batch.ids.digests[batch.digest_count] = record.id_digest;
                batch.digest_count += 1;
            }
            unit_start = reader.offset;
            unit_identities = batch.identity_count;
            // A unit taken unfit is a first item too big for a batch.
            if (unfit or batch.digest_count == batch_items) {
                batch.end = reader.offset;
                return;
            }
            continue;
        }
        if (record.tag == .name or record.tag == .call_id or record.tag == .arguments) continue;
        const value = recordImport(&record) orelse continue;
        if (!unfit and !batch.add(value)) unfit = true;
    }
}

/// Collects the next calls from `start`, as `collectItems` does items:
/// each call's name, call_id and arguments, and, when the catalog rejects
/// it, its rejection text. A call imports at most four identities, so
/// `batch_items` calls always fit `batch_identities`.
fn collectCalls(batch: *Batch, output: *const ValidatedOutput, io: std.Io, start: u64, frozen_tools: tool_catalog.ToolSet) void {
    comptime std.debug.assert(batch_identities >= 4 * batch_items);
    batch.reset(.calls, start);
    var reader = OutputMetadataReader.init(io, output.metadata, output.item_count) catch |err| return batch.stop(err, start);
    reader.offset = start;
    var name: ?OutputMetadataRecord = null;
    var call_id: ?OutputMetadataRecord = null;
    while (true) {
        const record_start = reader.offset;
        const record = (reader.next() catch |err| return batch.stop(err, record_start)) orelse {
            batch.end = reader.offset;
            batch.last = true;
            return;
        };
        switch (record.tag) {
            .name => name = record,
            .call_id => call_id = record,
            .arguments => {
                // The write walk reports a malformed call where main does.
                const name_record = name orelse return batch.stop(null, record_start);
                const call_id_record = call_id orelse return batch.stop(null, record_start);
                for ([_]*const OutputMetadataRecord{ &name_record, &call_id_record, &record }) |field| {
                    const fits = batch.add(recordImport(field).?);
                    std.debug.assert(fits);
                }
                // The write walk inspects the call again and returns a
                // failure here, or of its rejection text, where main does;
                // collecting only needs the text's identity.
                if (inspectOutputCall(io, output.source, name_record, record)) |facts| {
                    if (tool_catalog.classifyCall(facts.name, facts.bash_arguments != null, frozen_tools)) |code| {
                        var buffer: [192]u8 = undefined;
                        if (rejectionText(io, output, code, name_record, &buffer)) |text| {
                            const fits = batch.add(.ofBytes(text, false));
                            std.debug.assert(fits);
                        } else |_| {}
                    }
                } else |_| {}
                batch.ids.digests[batch.digest_count] = call_id_record.content_digest;
                batch.digest_count += 1;
                name = null;
                call_id = null;
                if (batch.digest_count == batch_items) {
                    batch.end = reader.offset;
                    return;
                }
            },
            else => {},
        }
    }
}

/// A rejected call's result text, from its name in the source.
fn rejectionText(io: std.Io, output: *const ValidatedOutput, code: protocol.ProposalRejection, name: OutputMetadataRecord, buffer: *[192]u8) ![]const u8 {
    var rejected_name: output_format.NameReader = .{ .io = io, .file = output.source, .position = name.start, .end = try name.end() };
    return tool_catalog.rejectionResult(code, &rejected_name, name.decoded_length, name.content_digest, buffer);
}

/// Main's checks on the candidate output, before any import: compaction
/// items and calls must fit the Operation's purpose.
fn validateCandidate(io: std.Io, output: *const ValidatedOutput, purpose: ModelOperationKind) !void {
    var candidate_metadata = try OutputMetadataReader.init(io, output.metadata, output.item_count);
    var compaction_count: u64 = 0;
    while (try candidate_metadata.next()) |record| {
        if (record.tag == .item and record.kind == .compaction) {
            if (record.length == 0) return error.InvalidProviderEnvelope;
            compaction_count += 1;
        }
        if (purpose == .compaction and (record.kind == .function_call or record.kind == .web_search_call)) return error.InvalidProviderEnvelope;
    }
    if (purpose == .compaction) {
        if (compaction_count != 1 or output.call_count != 0) return error.InvalidProviderEnvelope;
    } else if (compaction_count != 0) return error.InvalidProviderEnvelope;
}

/// Round 1 opens the transaction and reads the Attempt, the settling
/// facts, and the first batch's content and duplicate item ids. Then Zig
/// checks the binding and the candidate output against the Operation's
/// purpose, as main does before any import. Each later round writes one
/// batch, its new content streamed into its rows in process, and reads
/// the next batch's (`importBatches`). The last round resolves the
/// Operation, closes its Turn or records its continuation, and commits.
/// An item batch closes at 64 items or before the item whose identities
/// would pass 256, a call batch at 64 calls, which always fit, so the
/// rounds are the item batches plus the call batches plus one: a reply of
/// at most 64 items whose identities fit settles in 2 rounds, and in 3
/// when it proposes calls. An identity a batch did not collect (a first
/// item with more than 256) adds a lookup round, and a second when it
/// inserts.
pub fn settleModelSuccess(a: anytype, io: std.Io, binding: AttemptBinding, output: *const ValidatedOutput, faults: Faults) !void {
    const batch = a.store.settlementBatch();
    var facts: attempt_facts.Result = undefined;
    var success: success_facts.Result = undefined;
    var pending: pending_messages.Result = undefined;
    a.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = true }, &facts);
    a.read(success_facts, .{ .operation_id = binding.operation_id }, &success);
    a.read(pending_messages, .{ .operation_id = binding.operation_id }, &pending);
    // BEGIN IMMEDIATE ran when the first read was queued.
    if (a.failure == null) if (faults.settlement_trace) |trace| {
        std.debug.assert(c.sqlite3_txn_state(a.store.database, "main") == c.SQLITE_TXN_WRITE);
        trace.mark(.transaction_active);
    };
    collectItems(batch, output, io, 0);
    batch.queueReads(a, binding.operation_id);
    try runSettlement(a);
    const row = try currentAttempt(&facts, binding);
    // The Operation was found, so only its revision row can be missing.
    const settling = success orelse return error.CorruptStore;
    const tools_mask = settling.tools_mask orelse return error.StaleAttemptBinding;
    const purpose: ModelOperationKind = if (row.compaction) .compaction else .assistant_response;
    // Main checked the candidate before any output read.
    try validateCandidate(io, output, purpose);
    try batch.checkReads();

    const positions = try a.positions(row.session);
    var settlement: Settlement(@TypeOf(a)) = .{
        .a = a,
        .io = io,
        .binding = binding,
        .output = output,
        .faults = faults,
        .session = row.session,
        .positions = positions,
        .first_item_position = try positions.take(output.item_count),
        .purpose = purpose,
        .tools = try configuration_domain.toolSet(tools_mask),
        .settling = settling,
        .call_items = try OutputMetadataReader.init(io, output.metadata, output.item_count),
    };
    settlement.call_item = try settlement.call_items.nextItem();
    try settlement.importBatches(batch);

    const output_fact = turn_policy.outputFact(purpose, output.call_count);
    const usage = settlement.usage;
    a.write(resolve_success, .{
        .operation_id = binding.operation_id,
        .resolution = @tagName(turn_policy.Resolution.of(output_fact)),
        .content_id = settlement.answer_id,
        .response_id = optionalText(output.response_id.slice()),
        .model_evidence = .{ .bytes = output.model_evidence.slice() },
        .request_id = optionalText(output.request_id.slice()),
        .usage_content_id = settlement.usage_id,
        .item_count = output.item_count,
        // The provider parser admits only counts that fit an SQLite integer.
        .uncached = if (usage) |counts| counts.uncached else null,
        .cache_read = if (usage) |counts| counts.cache_read else null,
        .cache_write = if (usage) |counts| counts.cache_write else null,
        .output = if (usage) |counts| counts.output else null,
        .attempt_ordinal = binding.attempt_ordinal,
        .session = row.session,
    });
    if (turn_policy.completesTurn(output_fact, pending.pending)) {
        if (!row.turn_open) return error.StaleAttemptBinding;
        const answer = settlement.answer_id orelse return error.CorruptOutputMetadata;
        try turn_domain.queueCloseOr(a, positions, binding.turn_id, .{ .completed = @intCast(answer) }, error.StaleAttemptBinding);
    } else turn_domain.queueContinuation(a, binding.turn_id, row.session);
    if (faults.output_commit) return error.InjectedOutputCommitFailure;
    try a.commit();
}

/// A content row a settlement value imports: found, or inserted by this
/// settlement, when `fresh` says its bytes are still to stream.
const ContentRow = struct { id: u64, fresh: bool };

/// One success settlement's state across its batches.
fn Settlement(comptime A: type) type {
    return struct {
        const Self = @This();

        a: A,
        io: std.Io,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
        session: rsql.SessionHead,
        positions: *store_access.Positions,
        first_item_position: u64,
        purpose: ModelOperationKind,
        tools: tool_catalog.ToolSet,
        settling: success_facts.Row,
        imported_items: u64 = 0,
        imported_calls: u64 = 0,
        entries: u64 = 0,
        answer_id: ?u64 = null,
        usage_id: ?u64 = null,
        usage: ?output_format.Usage = null,
        /// The function_call items, walked beside the calls' records.
        call_items: OutputMetadataReader,
        call_item: ?OutputMetadataRecord = null,

        /// Writes each batch and reads the next in one round, the items
        /// first, then the calls, as main's second pass imports them. The
        /// written batch's rows bind their values by value, so the next
        /// batch is collected into the same table before they step.
        fn importBatches(s: *Self, batch: *Batch) !void {
            while (true) {
                switch (batch.kind) {
                    .items => {
                        try s.writeItems(batch);
                        if (batch.last) {
                            try s.itemsDone();
                            collectCalls(batch, s.output, s.io, 0, s.tools);
                        } else collectItems(batch, s.output, s.io, batch.end);
                    },
                    .calls => {
                        try s.writeCalls(batch);
                        if (batch.last) break;
                        collectCalls(batch, s.output, s.io, batch.end, s.tools);
                    },
                }
                // A batch with nothing to read has nothing to write.
                if (batch.identity_count != 0 or batch.digest_count != 0) {
                    batch.queueReads(s.a, s.binding.operation_id);
                    try runSettlement(s.a);
                    try batch.checkReads();
                }
            }
            if (s.imported_calls != s.output.call_count) return error.CorruptOutputMetadata;
        }

        fn itemsDone(s: *Self) !void {
            if (s.imported_items != s.output.item_count) return error.CorruptOutputMetadata;
            if (s.purpose == .assistant_response and s.output.answer_length != 0 and s.answer_id == null) return error.CorruptOutputMetadata;
        }

        /// The row of an identity: the batch's, inserting it at its first
        /// use when the lookup found none. An identity the batch did not
        /// collect (a first item too big for one) costs its own lookup
        /// round, and a second when it inserts.
        fn content(s: *Self, batch: *Batch, imported: content_domain.Import) !ContentRow {
            if (batch.find(&imported)) |identity| {
                if (identity.row.content_id != 0) return .{ .id = identity.row.content_id, .fresh = false };
                const id = try content_domain.insertRow(s.a, &imported);
                identity.row.content_id = @intCast(id);
                return .{ .id = id, .fresh = true };
            }
            var value = imported;
            content_domain.lookup(s.a, &value);
            try runSettlement(s.a);
            if (value.found) |found| return .{ .id = found.content_id.get(), .fresh = false };
            const id = try content_domain.insertRow(s.a, &value);
            try s.a.run();
            return .{ .id = id, .fresh = true };
        }

        /// A sink for a fresh row with bytes, else null.
        fn sinkFor(s: *Self, row: ContentRow, length: u64) !?store_access.ContentSink {
            if (!row.fresh or length == 0) return null;
            return try s.a.contentSink(row.id);
        }

        /// Walks the batch's records in main's order: each item's ordinal,
        /// its duplicate check, its parts and bags, its row, and a visible
        /// message's entry; the usage record where it lies.
        fn writeItems(s: *Self, batch: *Batch) !void {
            var reader = try OutputMetadataReader.init(s.io, s.output.metadata, s.output.item_count);
            reader.offset = batch.start;
            var region_start = batch.start;
            var index: u8 = 0;
            while (reader.offset < batch.end) {
                const record = try reader.next() orelse break;
                if (record.tag == .usage) {
                    if (s.usage_id != null) return error.CorruptOutputMetadata;
                    s.usage_id = try s.importUsage(batch, record);
                    s.usage = record.usage;
                    continue;
                }
                if (record.tag != .item) continue;
                defer region_start = reader.offset;
                if (record.ordinal != s.imported_items) return error.CorruptOutputMetadata;
                if (index == batch.digest_count) return error.CorruptOutputMetadata;
                if (batch.duplicate(index)) return error.InvalidProviderEnvelope;
                var description: tool_catalog.Description = .{};
                const neutral = try s.importItem(batch, record, region_start, reader.offset, &description);
                s.a.write(insert_item, .{
                    .operation_id = s.binding.operation_id,
                    .item_ordinal = record.ordinal,
                    .session = s.session,
                    .position = s.first_item_position + s.imported_items,
                    .kind = @backingInt(record.kind),
                    .attempt_ordinal = s.binding.attempt_ordinal,
                    .id_digest = batch.ids.digests[index],
                    .omits_reasoning_text = record.omit_reasoning_text,
                    .phase = @backingInt(record.phase),
                    .extras_content_id = neutral.bag,
                    .part_count = neutral.part_count,
                    .message_content_id = neutral.text,
                    .description = if (neutral.described and description.len != 0) description else null,
                    .call_failed = neutral.call_failed,
                });
                index += 1;
                s.imported_items += 1;
                // Items own stream positions. Each visible message is a
                // Conversation entry at its own item's position, so text
                // remains before/among calls, not after the complete call
                // group. Only the selected message is the result.
                if (s.purpose != .assistant_response or record.kind != .message) continue;
                const text = neutral.text.?;
                if (s.output.answer_item_ordinal == record.ordinal) {
                    // The selected result can be empty while the exact message
                    // text (including whitespace) remains in Conversation.
                    const empty = &content_domain.empty_content;
                    const answer: ContentRow = if (s.output.answer_length == 0) try s.content(batch, empty.*) else .{ .id = text, .fresh = false };
                    const length, const digest = if (s.output.answer_length == 0) .{ empty.length, &empty.digest } else .{ neutral.text_length, &neutral.text_digest };
                    if (length != s.output.answer_length or !std.mem.eql(u8, digest, &s.output.answer_digest)) return error.OutputSourceChanged;
                    s.answer_id = answer.id;
                }
                s.entries += 1;
                s.a.write(insert_entry, .{
                    .session = s.session,
                    .ordinal = s.settling.entry_base + s.entries,
                    .position = s.first_item_position + record.ordinal,
                    .turn_id = s.binding.turn_id,
                    .operation_id = s.binding.operation_id,
                    .item_ordinal = record.ordinal,
                    .content_id = text,
                });
            }
            if (batch.stopped) |err| return err;
        }

        /// Copies the usage record's bytes into a private row.
        fn importUsage(s: *Self, batch: *Batch, record: OutputMetadataRecord) !u64 {
            const end = try std.math.add(u64, record.start, record.length);
            if (end > s.output.source_length) return error.CorruptOutputMetadata;
            const row = try s.content(batch, recordImport(&record).?);
            const sink = try s.sinkFor(row, record.length);
            defer if (sink) |value| value.close();
            try streamSourceRange(s.io, s.output.source, record.start, record.length, &record.content_digest, sink, s.faults);
            return row.id;
        }

        /// Saves one accepted item in Rui's own form from its metadata
        /// records in `[metadata_start, metadata_end)`: its parts, its
        /// provider bags and, for a message, its text (every text part's
        /// decoded text back to back, one row its parts are lengths of).
        /// A hosted call's description goes to `description`.
        fn importItem(s: *Self, batch: *Batch, item: OutputMetadataRecord, metadata_start: u64, metadata_end: u64, description: *tool_catalog.Description) !ImportedNeutral {
            var metadata = try OutputMetadataReader.init(s.io, s.output.metadata, s.output.item_count);
            metadata.offset = metadata_start;
            metadata.length = metadata_end;
            var item_bag: ?u64 = null;
            var text: ?u64 = null;
            var text_record: ?OutputMetadataRecord = null;
            var text_length: u64 = 0;
            var part_count: u64 = 0;
            // The open part: its record's offset and its own text row. Every
            // part closes with its bag, so one INSERT writes the whole row.
            var part: ?struct { record: OutputMetadataRecord, start: u64, text: ?u64 } = null;
            // A hosted call's action record, and its pattern record if any.
            var action: ?OutputMetadataRecord = null;
            var pattern: ?OutputMetadataRecord = null;
            while (try metadata.next()) |record| {
                if (record.tag == .item) break;
                if (record.ordinal != item.ordinal or record.kind != item.kind) return error.CorruptOutputMetadata;
                switch (record.tag) {
                    .part => {
                        if (part != null or item_bag != null) return error.CorruptOutputMetadata;
                        const own_text = switch (record.part_kind) {
                            .opaque_block => null,
                            .output_text, .refusal => own: {
                                if (item.kind != .message) return error.CorruptOutputMetadata;
                                text_length = try std.math.add(u64, text_length, record.decoded_length);
                                break :own null;
                            },
                            .summary_text, .reasoning_text => if (item.kind != .reasoning)
                                return error.CorruptOutputMetadata
                            else
                                try s.importDecoded(batch, record),
                        };
                        part = .{ .record = record, .start = metadata.offset, .text = own_text };
                    },
                    .extras => switch (record.scope) {
                        .part => {
                            const pending = part orelse return error.CorruptOutputMetadata;
                            const bag = try s.importBag(batch, record, pending.start, metadata.offset);
                            s.a.write(insert_part, .{
                                .operation_id = s.binding.operation_id,
                                .item_ordinal = item.ordinal,
                                .part_ordinal = part_count,
                                .part_array = @backingInt(pending.record.part_array),
                                .part_kind = @backingInt(pending.record.part_kind),
                                .text_length = switch (pending.record.part_kind) {
                                    .output_text, .refusal => pending.record.decoded_length,
                                    .opaque_block, .summary_text, .reasoning_text => null,
                                },
                                .text_content_id = pending.text,
                                .extras_content_id = bag,
                            });
                            part_count += 1;
                            part = null;
                        },
                        .item => {
                            if (part != null or item_bag != null) return error.CorruptOutputMetadata;
                            item_bag = try s.importBag(batch, record, metadata_start, metadata.offset);
                        },
                    },
                    .text => {
                        if (item_bag == null or text != null or record.decoded_length != text_length) return error.CorruptOutputMetadata;
                        text = try s.importMessageText(batch, record, metadata_start, metadata.offset);
                        text_record = record;
                    },
                    .action => {
                        if (item.kind != .web_search_call or action != null) return error.CorruptOutputMetadata;
                        action = record;
                    },
                    .pattern => {
                        if (action == null or pattern != null) return error.CorruptOutputMetadata;
                        pattern = record;
                    },
                    .member, .name, .call_id, .arguments => {},
                    .usage => return error.CorruptOutputMetadata,
                    .item => unreachable,
                }
            }
            if (part != null or (text != null) != (item.kind == .message) or
                (action != null) != (item.kind == .web_search_call)) return error.CorruptOutputMetadata;
            if (action) |call| description.* = try describeWebSearch(s.io, s.output.source, call, pattern);
            return .{
                .bag = item_bag orelse return error.CorruptOutputMetadata,
                .part_count = part_count,
                .text = text,
                .text_length = if (text_record) |record| record.decoded_length else 0,
                .text_digest = if (text_record) |record| record.content_digest else @splat(0),
                .described = action != null,
                .call_failed = if (action) |call| call.call_failed else false,
            };
        }

        /// Decodes a message's text parts among the records in
        /// `[start, end)` into one public row, checked against the
        /// message's `text` record. A row with the same bytes is shared.
        fn importMessageText(s: *Self, batch: *Batch, text: OutputMetadataRecord, start: u64, end: u64) !u64 {
            const row = try s.content(batch, recordImport(&text).?);
            const sink = try s.sinkFor(row, text.decoded_length) orelse return row.id;
            defer sink.close();
            try streamMessageText(s.io, s.output, text, start, end, sink, s.faults);
            return row.id;
        }

        /// Copies one bag, the `member` records of `trailer`'s scope in
        /// `[start, end)` joined by commas, into a private row, verifying
        /// a found one.
        fn importBag(s: *Self, batch: *Batch, trailer: OutputMetadataRecord, start: u64, end: u64) !u64 {
            const row = try s.content(batch, recordImport(&trailer).?);
            const sink = try s.sinkFor(row, trailer.decoded_length);
            defer if (sink) |value| value.close();
            try streamBag(s.io, s.output, trailer, start, end, sink, s.faults);
            return row.id;
        }

        /// Decodes one saved string (a part's text or a call field) into
        /// its own row. A row with the same bytes is shared.
        fn importDecoded(s: *Self, batch: *Batch, part: OutputMetadataRecord) !u64 {
            const row = try s.content(batch, recordImport(&part).?);
            const sink = try s.sinkFor(row, part.decoded_length) orelse return row.id;
            defer sink.close();
            try streamDecoded(s.io, s.output, part, sink, s.faults);
            return row.id;
        }

        /// Walks the batch's records for calls in main's order: each
        /// call's fields, its duplicate check, its classification, its
        /// row and, when runnable, its Action.
        fn writeCalls(s: *Self, batch: *Batch) !void {
            var reader = try OutputMetadataReader.init(s.io, s.output.metadata, s.output.item_count);
            reader.offset = batch.start;
            var name_record: ?OutputMetadataRecord = null;
            var call_id_record: ?OutputMetadataRecord = null;
            var index: u8 = 0;
            while (reader.offset < batch.end) {
                const record = try reader.next() orelse break;
                switch (record.tag) {
                    .name => name_record = record,
                    .call_id => call_id_record = record,
                    .arguments => {
                        const name = name_record orelse return error.CorruptOutputMetadata;
                        const call_id = call_id_record orelse return error.CorruptOutputMetadata;
                        if (name.ordinal != record.ordinal or call_id.ordinal != record.ordinal or record.kind != .function_call)
                            return error.CorruptOutputMetadata;
                        while (s.call_item != null and s.call_item.?.ordinal < record.ordinal) s.call_item = try s.call_items.nextItem();
                        const owner = s.call_item orelse return error.CorruptOutputMetadata;
                        if (owner.ordinal != record.ordinal or owner.kind != .function_call) return error.CorruptOutputMetadata;
                        if (index == batch.digest_count) return error.CorruptOutputMetadata;
                        try s.importCall(batch, index, .{ name, call_id, record });
                        name_record = null;
                        call_id_record = null;
                        index += 1;
                        s.imported_calls += 1;
                    },
                    else => {},
                }
            }
            if (batch.stopped) |err| return err;
            // A batch ends before a call's first field, so fields left open
            // at the last batch's end belong to no call.
            if (batch.last and (name_record != null or call_id_record != null)) return error.CorruptOutputMetadata;
        }

        /// Imports one accepted call: its fields, its classification and,
        /// when it is runnable, its Action.
        fn importCall(s: *Self, batch: *Batch, index: u8, fields: [3]OutputMetadataRecord) !void {
            const name, const call_id, const record = fields;
            const name_content_id = try s.importDecoded(batch, name);
            const call_id_content_id = try s.importDecoded(batch, call_id);
            const arguments_content_id = try s.importDecoded(batch, record);
            if (batch.duplicate(index)) return error.InvalidProviderEnvelope;
            const call_facts = try inspectOutputCall(s.io, s.output.source, name, record);
            const rejection_code = tool_catalog.classifyCall(call_facts.name, call_facts.bash_arguments != null, s.tools);
            const rejection_content_id: ?u64 = if (rejection_code) |code| id: {
                var buffer: [192]u8 = undefined;
                const text = try rejectionText(s.io, s.output, code, name, &buffer);
                if (s.faults.output_import) return error.InjectedContentImportFailure;
                const value: content_domain.Import = .ofBytes(text, false);
                const row = try s.content(batch, value);
                if (try s.sinkFor(row, value.length)) |sink| {
                    defer sink.close();
                    try sink.write(text, 0);
                }
                break :id row.id;
            } else null;
            // The call's certificate: (little-endian length, SHA-256) for its
            // name, call_id and arguments, in ProposalField order.
            var field_metadata: [120]u8 = undefined;
            for (fields, 0..) |field, at| {
                std.mem.writeInt(u64, field_metadata[at * 40 ..][0..8], field.decoded_length, .little);
                @memcpy(field_metadata[at * 40 + 8 ..][0..32], &field.content_digest);
            }
            // A call the catalog did not accept has no description.
            const description: ?tool_catalog.Description = if (call_facts.bash_arguments) |*arguments| tool_catalog.describe(.{ .bash = arguments }) else null;
            s.a.write(insert_call, .{
                .operation_id = s.binding.operation_id,
                .call_ordinal = s.imported_calls,
                .item_ordinal = record.ordinal,
                .name_content_id = name_content_id,
                .call_id_content_id = call_id_content_id,
                .arguments_content_id = arguments_content_id,
                .rejection_code = rejection_code,
                .rejection_content_id = rejection_content_id,
                .acceptance_position = if (rejection_code != null) try s.positions.take(1) else null,
                .action_kind = if (rejection_code == null) 1 else null,
                .description = if (description) |text| if (text.len != 0) text else null else null,
                .field_metadata = field_metadata,
                .session = s.session,
            });
            if (rejection_code != null) return;
            s.a.write(insert_action, .{
                .action_id = try s.a.identity(.action_id),
                .operation_id = s.binding.operation_id,
                .call_ordinal = s.imported_calls,
                .session = s.session,
                .revision = s.settling.revision.get(),
                .authorized = s.settling.permission_mode,
                .timeout_ms = call_facts.bash_arguments.?.timeout_ms,
            });
        }
    };
}

/// An item in Rui's own form; a message's text identity; whether a hosted
/// call's description was written, and its outcome.
const ImportedNeutral = struct { bag: u64, part_count: u64, text: ?u64, text_length: u64, text_digest: [32]u8, described: bool, call_failed: bool };

/// A hosted call's description from its action and pattern records.
/// noinline: its excerpt windows live in this frame only.
noinline fn describeWebSearch(io: std.Io, source: std.Io.File, call: OutputMetadataRecord, pattern: ?OutputMetadataRecord) !tool_catalog.Description {
    var target: [tool_catalog.WebSearchCall.excerpt_bytes]u8 = undefined;
    var found: [tool_catalog.WebSearchCall.excerpt_bytes]u8 = undefined;
    return tool_catalog.describe(.{ .web_search = .{
        .action = @fromBackingInt(@backingInt(call.action)),
        .target = try excerpt(io, source, call, &target),
        .pattern = if (pattern) |field| try excerpt(io, source, field, &found) else "",
    } });
}

/// The first decoded bytes of a certified string `record`, as many as
/// `buffer` holds.
fn excerpt(io: std.Io, source: std.Io.File, record: OutputMetadataRecord, buffer: []u8) ![]const u8 {
    var reader: output_format.NameReader = .{ .io = io, .file = source, .position = record.start, .end = try record.end() };
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) buffer[length] = try reader.next() orelse break;
    return buffer[0..length];
}

/// Hashes `bytes` at `written` within `length`, writing them to `sink`
/// when there is one.
fn writeChecked(sink: ?store_access.ContentSink, hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8, written: *u64, length: u64) !void {
    if (bytes.len > length - written.*) return error.OutputSourceChanged;
    hash.update(bytes);
    if (sink) |value| try value.write(bytes, written.*);
    written.* += bytes.len;
}

/// Streams the source's `[start, start + length)` into `sink`, if any,
/// checking its digest. noinline with a small window, so the settlement
/// frame stays small.
noinline fn streamSourceRange(io: std.Io, file: std.Io.File, start: u64, length: u64, digest: *const [32]u8, sink: ?store_access.ContentSink, faults: Faults) !void {
    var copy: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var offset: u64 = 0;
    while (offset < length) {
        const wanted: usize = @intCast(@min(length - offset, copy.window.len));
        const count = try file.readPositionalAll(io, copy.window[0..wanted], start + offset);
        if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
        copy.hash.update(copy.window[0..count]);
        if (sink) |value| try value.write(copy.window[0..count], offset);
        if (faults.output_import) return error.InjectedOutputImportFailure;
        offset += count;
    }
    if (!std.mem.eql(u8, &copy.hash.finalResult(), digest)) return error.OutputSourceChanged;
}

/// Streams a bag's members in `[start, end)` into `sink`, if any,
/// checking its length and digest.
noinline fn streamBag(io: std.Io, output: *const ValidatedOutput, trailer: OutputMetadataRecord, start: u64, end: u64, sink: ?store_access.ContentSink, faults: Faults) !void {
    var members = try OutputMetadataReader.init(io, output.metadata, output.item_count);
    members.offset = start;
    members.length = end;
    var copy: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    var first = true;
    while (try members.next()) |member| {
        if (member.tag != .member or member.scope != trailer.scope) continue;
        if (!first) try writeChecked(sink, &copy.hash, ",", &written, trailer.decoded_length);
        first = false;
        const member_end = try member.end();
        if (member_end > output.source_length) return error.CorruptOutputMetadata;
        var offset = member.start;
        while (offset < member_end) {
            const wanted: usize = @intCast(@min(member_end - offset, copy.window.len));
            const count = try output.source.readPositionalAll(io, copy.window[0..wanted], offset);
            if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
            try writeChecked(sink, &copy.hash, copy.window[0..count], &written, trailer.decoded_length);
            if (faults.output_import) return error.InjectedOutputImportFailure;
            offset += count;
        }
    }
    if (written != trailer.decoded_length or !std.mem.eql(u8, &copy.hash.finalResult(), &trailer.content_digest)) return error.OutputSourceChanged;
}

/// Decodes a message's text parts among `[start, end)` into `sink`.
noinline fn streamMessageText(io: std.Io, output: *const ValidatedOutput, text: OutputMetadataRecord, start: u64, end: u64, sink: store_access.ContentSink, faults: Faults) !void {
    var parts = try OutputMetadataReader.init(io, output.metadata, output.item_count);
    parts.offset = start;
    parts.length = end;
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    while (try parts.next()) |part| {
        if (part.tag != .part or (part.part_kind != .output_text and part.part_kind != .refusal)) continue;
        try writeDecoded(io, output, sink, &decoded, part, &written, text.decoded_length);
        if (faults.output_import) return error.InjectedOutputImportFailure;
    }
    if (written != text.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &text.content_digest)) return error.OutputSourceChanged;
}

/// Decodes one saved string into `sink`.
noinline fn streamDecoded(io: std.Io, output: *const ValidatedOutput, part: OutputMetadataRecord, sink: store_access.ContentSink, faults: Faults) !void {
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    try writeDecoded(io, output, sink, &decoded, part, &written, part.decoded_length);
    if (faults.output_import) return error.InjectedOutputImportFailure;
    if (written != part.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &part.content_digest)) return error.OutputSourceChanged;
}

/// Decodes `part`'s encoded string from the source into `sink` at
/// `written`, within `length`, hashing what it writes.
fn writeDecoded(io: std.Io, output: *const ValidatedOutput, sink: store_access.ContentSink, decoded: *content_domain.HashedWindow(import_window_bytes), part: OutputMetadataRecord, written: *u64, length: u64) !void {
    if (try part.end() > output.source_length) return error.CorruptOutputMetadata;
    var count: usize = 0;
    var text: output_format.EncodedStringWindow(import_window_bytes) = .{ .io = io, .file = output.source, .position = part.start, .end = try part.end() };
    while (try text.next()) |byte| {
        decoded.window[count] = byte;
        count += 1;
        if (count == decoded.window.len) {
            try writeChecked(sink, &decoded.hash, &decoded.window, written, length);
            count = 0;
        }
    }
    try writeChecked(sink, &decoded.hash, decoded.window[0..count], written, length);
}

/// One function call's catalog facts: its name and, for bash, its
/// arguments. noinline: the arguments' content window lives in this frame
/// only, not in the settlement frame that walks the output's metadata.
noinline fn inspectOutputCall(io: std.Io, source: std.Io.File, name: OutputMetadataRecord, arguments: OutputMetadataRecord) !tool_catalog.CallFacts {
    var call_name: output_format.NameReader = .{ .io = io, .file = source, .position = name.start, .end = try name.end() };
    var encoded: output_format.JsonStringSource = .{
        .encoded = .{ .io = io, .file = source, .position = arguments.start, .end = try arguments.end() },
    };
    return tool_catalog.inspectCall(&call_name, name.decoded_length, &encoded);
}

/// noinline: its read buffer serves the rare schema check, not every
/// configure frame.
pub noinline fn validateJsonFile(io: std.Io, file: std.Io.File) !bool {
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
