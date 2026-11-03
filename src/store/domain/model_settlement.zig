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

/// Every model Operation resolution ends its Attempt or retry wait at once.
/// `settleModelSuccessLocked` is its last caller, and it goes when that
/// settlement converts.
const operation_resolved_at_sql = "resolved_at=unixepoch(),attempt_at=NULL,retry_scheduled_at=NULL";
/// `operation_resolved_at_sql` for typed statements, dated by the Access.
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
/// Operation; otherwise `turn_open` is false and unread.
const attempt_facts = rsql.Read(.{
    .sql = "SELECT o.turn_id,o.attempt_ordinal,o.resolution_code IS NOT NULL AS resolved," ++
        "o.interrupted_by_command_key IS NOT NULL AS interrupted,o.purpose AS compaction,o.admission_position," ++
        "coalesce(o.retry_due_at_ms,0)<>0 AS retry_waiting,o.auth_refresh_claimed AS refresh_claimed," ++
        rsql.session_head_columns ++ "," ++
        "CASE WHEN ?2 THEN EXISTS(SELECT 1 FROM turn t WHERE t.turn_id=o.turn_id AND t.outcome_code IS NULL " ++
        "AND t.operation_id=o.operation_id) ELSE 0 END AS turn_open " ++
        "FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
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
    a.run() catch |err| return if (err == error.StatementFailed) error.OperationReadFailed else err;
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
    /// Whether `importDiagnostic` queued a new row.
    diagnostic_inserted: bool = false,

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
        content.diagnostic_inserted = value.found == null;
        return try content_domain.importBytes(a, value, failure.diagnostic().?);
    }

    /// The report's row. One equal to the diagnostic is the diagnostic's
    /// (`content.importSlot`). A round queues `insert_content` once, so
    /// when the diagnostic's row is new and the report's is a different
    /// new row, the queued round runs first: one more round trip, only
    /// then.
    fn importReport(content: *FailureContent, a: anytype, failure: *const ModelFailure) !?u64 {
        const value = if (content.report) |*value| value else return null;
        if (value.found == null and content.diagnostic_inserted and
            a.insertedContent(&value.digest, value.length, value.private) == null) try a.run();
        return try content_domain.importBytes(a, value, failure.report());
    }
};

/// Round 1 reads the Attempt and, for a failure that resolves it, looks
/// up the failure's diagnostic and report. A context overflow reads in
/// round 2 whether compaction can recover it, which needs the Attempt's
/// position. The write round resolves the Attempt or schedules its retry,
/// and closes its Turn or records its continuation, then commits; a new
/// diagnostic and a new report add one round between (`importReport`).
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
    candidate.run() catch |err| return if (err == error.StatementFailed) error.RetryRecoveryFailed else err;
    const chosen = choice.chosen orelse return false;
    if (!chosen.turn_open) return error.SelectionChanged;
    a.write(resolve_exhausted, .{ .operation_id = chosen.operation_id.get(), .session = chosen.session });
    try turn_domain.queueCloseOr(a, try a.positions(chosen.session), chosen.turn_id.get(), .{ .retry_exhausted = null }, error.SelectionChanged);
    try a.commit();
    return true;
}

pub fn settleModelSuccessLocked(
    self: *Store,
    binding: AttemptBinding,
    output: *const ValidatedOutput,
    faults: Faults,
) !void {
    try store_core.begin(self);
    if (faults.settlement_trace) |trace| {
        std.debug.assert(c.sqlite3_txn_state(self.database, "main") == c.SQLITE_TXN_WRITE);
        trace.mark(.transaction_active);
    }
    _ = try validateCurrentAttempt(self, binding);
    const operation = try store_core.cached(
        self,
        "SELECT o.session_ref,r.tools_mask FROM model_operation o JOIN session_revision r " ++
            "ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
            "WHERE o.operation_id=?1 AND o.turn_id=?2",
    );
    defer sqlite.resetCached(operation);
    try sqlite.bindU64(operation, 1, binding.operation_id);
    try sqlite.bindU64(operation, 2, binding.turn_id);
    switch (c.sqlite3_step(operation)) {
        c.SQLITE_ROW => {},
        c.SQLITE_DONE => return error.StaleAttemptBinding,
        else => return error.OperationReadFailed,
    }
    var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
    try sqlite.readText(operation, 0, &session_ref);
    const frozen_tools = try configuration_domain.toolSet(c.sqlite3_column_int(operation, 1));
    const current = try configuration_domain.readSessionFacts(self, session_ref.slice(), null) orelse return error.CorruptStore;
    const purpose = try readModelOperationKind(self, binding.operation_id);
    // Validate the explicit candidate before imports, projections or effects.
    var candidate_metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
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

    const first_item_position = try turn_domain.claimSessionPositions(self, session_ref.slice(), output.item_count);
    var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    var imported_items: u64 = 0;
    var answer_id: ?i64 = null;
    var usage_id: ?i64 = null;
    var usage: ?output_format.Usage = null;
    // Each item's records precede its item record.
    var item_records_start: u64 = 0;
    while (try metadata.next()) |record| {
        if (record.tag == .usage) {
            if (usage_id != null) return error.CorruptOutputMetadata;
            usage_id = try importSourceRange(
                self,
                output.source,
                output.source_length,
                record.start,
                record.length,
                &record.content_digest,
                true,
                faults,
            );
            usage = record.usage;
            continue;
        }
        if (record.tag != .item) continue;
        defer item_records_start = metadata.offset;
        if (record.ordinal != imported_items) return error.CorruptOutputMetadata;
        const duplicate_identity = try store_core.cached(
            self,
            "SELECT 1 FROM model_output_item WHERE operation_id=?1 AND item_id_digest=?2 LIMIT 1",
        );
        defer sqlite.resetCached(duplicate_identity);
        try sqlite.bindU64(duplicate_identity, 1, binding.operation_id);
        try sqlite.bindBlob(duplicate_identity, 2, &record.id_digest);
        switch (c.sqlite3_step(duplicate_identity)) {
            c.SQLITE_DONE => {},
            c.SQLITE_ROW => return error.InvalidProviderEnvelope,
            else => return error.OutputReadFailed,
        }
        // The item in Rui's own form: its parts and provider bags.
        const neutral = try importNeutralItem(self, binding, output, record, item_records_start, metadata.offset, faults);
        const insert = try store_core.cached(
            self,
            "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,message_content_id,description,call_failed) " ++
                "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
        );
        defer sqlite.resetCached(insert);
        try sqlite.bindU64(insert, 1, binding.operation_id);
        try sqlite.bindU64(insert, 2, record.ordinal);
        try sqlite.bindText(insert, 3, session_ref.slice());
        try sqlite.bindU64(insert, 4, first_item_position + imported_items);
        try sqlite.bindI64(insert, 5, @backingInt(record.kind));
        try sqlite.bindU64(insert, 6, binding.attempt_ordinal);
        try sqlite.bindBlob(insert, 7, &record.id_digest);
        try sqlite.bindI64(insert, 8, @intFromBool(record.omit_reasoning_text));
        try sqlite.bindI64(insert, 9, @backingInt(record.phase));
        try sqlite.bindI64(insert, 10, neutral.bag);
        try sqlite.bindU64(insert, 11, neutral.part_count);
        try sqlite.bindNullableI64(insert, 12, neutral.text);
        try sqlite.bindOptionalText(insert, 13, if (neutral.description) |*description| description.slice() else "");
        try sqlite.bindI64(insert, 14, @intFromBool(neutral.call_failed));
        try sqlite.expectDone(insert);
        imported_items += 1;
        // Items own stream positions. Each visible message is a
        // Conversation entry at its own item's position, so text remains
        // before/among calls, not after the complete call group. Only
        // the selected message is the result.
        if (purpose != .assistant_response or record.kind != .message) continue;
        const content_id = neutral.text.?;
        if (output.answer_item_ordinal == record.ordinal) {
            // The selected result can be empty while the exact message
            // text (including whitespace) remains in Conversation.
            answer_id = if (output.answer_length == 0) try content_domain.importEmptyContent(self) else content_id;
            const content = try content_domain.readContentMetadata(self, answer_id.?);
            if (content.length != output.answer_length or !std.mem.eql(u8, &content.digest, &output.answer_digest)) return error.OutputSourceChanged;
        }
        const entry = try store_core.cached(self, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_operation_id,source_item_ordinal,content_id,recorded_at) " ++
            "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+1,session_position,3,?3,?4,?6,?5,unixepoch() " ++
            "FROM model_output_item WHERE operation_id=?4 AND item_ordinal=?6");
        defer sqlite.resetCached(entry);
        try sqlite.bindText(entry, 1, session_ref.slice());
        try sqlite.bindU64(entry, 3, binding.turn_id);
        try sqlite.bindU64(entry, 4, binding.operation_id);
        try sqlite.bindI64(entry, 5, content_id);
        try sqlite.bindU64(entry, 6, record.ordinal);
        try sqlite.expectDone(entry);
        if (c.sqlite3_changes(self.database) != 1) return error.CorruptOutputMetadata;
    }
    if (imported_items != output.item_count) return error.CorruptOutputMetadata;
    if (purpose == .assistant_response and output.answer_length != 0 and answer_id == null) return error.CorruptOutputMetadata;

    var imported_calls: u64 = 0;
    var name_record: ?OutputMetadataRecord = null;
    var call_id_record: ?OutputMetadataRecord = null;
    metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    var call_items = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    var call_item = try call_items.nextItem();
    while (try metadata.next()) |record| switch (record.tag) {
        .name => name_record = record,
        .call_id => call_id_record = record,
        .arguments => {
            const name = name_record orelse return error.CorruptOutputMetadata;
            const call_id = call_id_record orelse return error.CorruptOutputMetadata;
            if (name.ordinal != record.ordinal or call_id.ordinal != record.ordinal or record.kind != .function_call)
                return error.CorruptOutputMetadata;
            while (call_item != null and call_item.?.ordinal < record.ordinal) call_item = try call_items.nextItem();
            const owner = call_item orelse return error.CorruptOutputMetadata;
            if (owner.ordinal != record.ordinal or owner.kind != .function_call) return error.CorruptOutputMetadata;
            try importOutputCall(self, binding, output, session_ref.slice(), current, frozen_tools, imported_calls, .{ name, call_id, record }, faults);
            name_record = null;
            call_id_record = null;
            imported_calls += 1;
        },
        else => {},
    };
    if (name_record != null or call_id_record != null or
        imported_calls != output.call_count) return error.CorruptOutputMetadata;

    const pending = try command_domain.countPendingMessages(self, session_ref.slice());
    const output_fact = turn_policy.outputFact(purpose, output.call_count);
    const resolution_code = @tagName(turn_policy.Resolution.of(output_fact));
    {
        const update = try store_core.cached(
            self,
            "UPDATE model_operation SET retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,model_evidence=?5,request_id=?8,usage_content_id=?9,output_item_count=?11," ++
                "usage_uncached_tokens=?12,usage_cache_read_tokens=?13,usage_cache_write_tokens=?14,usage_output_tokens=?15," ++ operation_resolved_at_sql ++ " " ++
                "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?10",
        );
        defer sqlite.resetCached(update);
        try sqlite.bindU64(update, 1, binding.operation_id);
        try sqlite.bindText(update, 2, resolution_code);
        try sqlite.bindNullableI64(update, 3, answer_id);
        try sqlite.bindOptionalText(update, 4, output.response_id.slice());
        try sqlite.bindBlob(update, 5, output.model_evidence.slice());
        try sqlite.bindOptionalText(update, 8, output.request_id.slice());
        try sqlite.bindNullableI64(update, 9, usage_id);
        try sqlite.bindU64(update, 10, binding.attempt_ordinal);
        try sqlite.bindU64(update, 11, output.item_count);
        // The provider parser admits only counts that fit an SQLite integer.
        try sqlite.bindNullableU64(update, 12, if (usage) |counts| counts.uncached else null);
        try sqlite.bindNullableU64(update, 13, if (usage) |counts| counts.cache_read else null);
        try sqlite.bindNullableU64(update, 14, if (usage) |counts| counts.cache_write else null);
        try sqlite.bindNullableU64(update, 15, if (usage) |counts| counts.output else null);
        try sqlite.expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
    }
    if (turn_policy.completesTurn(output_fact, pending)) {
        if (!try turn_domain.closeTurn(self, binding.turn_id, binding.operation_id, .{ .completed = answer_id.? })) return error.StaleAttemptBinding;
    } else try turn_domain.recordContinuation(self, binding.turn_id, session_ref.slice());
    if (faults.output_commit) return error.InjectedOutputCommitFailure;
    try store_core.commit(self);
}

/// Imports one accepted call: its fields, its classification and, when
/// it is runnable, its Action. noinline: the call's classification
/// buffers live in this frame only, not in the settlement frame under
/// which every item's import runs.
noinline fn importOutputCall(self: *Store, binding: AttemptBinding, output: *const ValidatedOutput, session_ref_slice: []const u8, current: SessionFacts, frozen_tools: tool_catalog.ToolSet, imported_calls: u64, fields: [3]OutputMetadataRecord, faults: Faults) !void {
    const name, const call_id, const record = fields;
    const name_content_id = try importDecodedString(self, output, name, false, faults);
    const call_id_content_id = try importDecodedString(self, output, call_id, false, faults);
    const arguments_content_id = try importDecodedString(self, output, record, false, faults);

    const duplicate_call = try store_core.cached(
        self,
        "SELECT 1 FROM model_tool_call WHERE operation_id=?1 AND call_id_content_id=?2 LIMIT 1",
    );
    defer sqlite.resetCached(duplicate_call);
    try sqlite.bindU64(duplicate_call, 1, binding.operation_id);
    try sqlite.bindI64(duplicate_call, 2, call_id_content_id);
    switch (c.sqlite3_step(duplicate_call)) {
        c.SQLITE_DONE => {},
        c.SQLITE_ROW => return error.InvalidProviderEnvelope,
        else => return error.OutputReadFailed,
    }

    const call_facts = try inspectOutputCall(self.io, output.source, name, record);
    const bash_arguments = call_facts.bash_arguments;
    const rejection_code = tool_catalog.classifyCall(call_facts.name, bash_arguments != null, frozen_tools);
    var rejection_buffer: [192]u8 = undefined;
    const rejection_text = if (rejection_code) |code| text: {
        var rejected_name: output_format.NameReader = .{ .io = self.io, .file = output.source, .position = name.start, .end = try name.end() };
        break :text try tool_catalog.rejectionResult(code, &rejected_name, name.decoded_length, name.content_digest, &rejection_buffer);
    } else null;
    const rejection_content_id = if (rejection_text) |text|
        try content_domain.importBytesContent(self, text, false, faults.output_import)
    else
        null;
    const acceptance_position = if (rejection_code != null)
        try turn_domain.claimSessionPosition(self, session_ref_slice)
    else
        null;
    const insert_call = try store_core.cached(
        self,
        "INSERT INTO model_tool_call(operation_id,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id," ++
            "rejection_code,rejection_content_id,acceptance_position,action_kind,description,field_metadata,session_ref) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
    );
    defer sqlite.resetCached(insert_call);
    try sqlite.bindU64(insert_call, 1, binding.operation_id);
    try sqlite.bindU64(insert_call, 2, imported_calls);
    try sqlite.bindU64(insert_call, 3, record.ordinal);
    try sqlite.bindI64(insert_call, 4, name_content_id);
    try sqlite.bindI64(insert_call, 5, call_id_content_id);
    try sqlite.bindI64(insert_call, 6, arguments_content_id);
    try sqlite.bindOptionalText(insert_call, 7, if (rejection_code) |code| @tagName(code) else "");
    try sqlite.bindNullableI64(insert_call, 8, rejection_content_id);
    try sqlite.bindNullableU64(insert_call, 9, acceptance_position);
    if (rejection_code == null) try sqlite.bindI64(insert_call, 10, 1) else try sqlite.bindNullableI64(insert_call, 10, null);
    // A call the catalog did not accept has no description.
    const description: ?tool_catalog.Description = if (bash_arguments) |*args| tool_catalog.describe(.{ .bash = args }) else null;
    try sqlite.bindOptionalText(insert_call, 11, if (description) |*line| line.slice() else "");
    // The call's certificate: (little-endian length, SHA-256) for its
    // name, call_id and arguments, in ProposalField order.
    var field_metadata: [120]u8 = undefined;
    for (fields, 0..) |field, index| {
        std.mem.writeInt(u64, field_metadata[index * 40 ..][0..8], field.decoded_length, .little);
        @memcpy(field_metadata[index * 40 + 8 ..][0..32], &field.content_digest);
    }
    try sqlite.bindBlob(insert_call, 12, &field_metadata);
    try sqlite.bindText(insert_call, 13, session_ref_slice);
    try sqlite.expectDone(insert_call);

    if (rejection_code == null) {
        const action_id = try store_core.takeIdentity(self, .action_id);
        const insert_action = try store_core.cached(
            self,
            "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,bash_timeout_override_ms,resolution_code,decided_at) " ++
                "VALUES(?1,?2,?3,?4,1,?5,?6,?7,NULL,CASE WHEN ?6=1 THEN unixepoch() END)",
        );
        defer sqlite.resetCached(insert_action);
        try sqlite.bindU64(insert_action, 1, action_id);
        try sqlite.bindU64(insert_action, 2, binding.operation_id);
        try sqlite.bindU64(insert_action, 3, imported_calls);
        try sqlite.bindText(insert_action, 4, session_ref_slice);
        try sqlite.bindU64(insert_action, 5, current.revision);
        try sqlite.bindI64(insert_action, 6, @as(i64, if (current.permission_mode == 0) 0 else 1));
        try sqlite.bindNullableU64(insert_action, 7, bash_arguments.?.timeout_ms);
        try sqlite.expectDone(insert_action);
    }
}

/// Copies the usage record's bytes. noinline with a small window, so
/// the settlement frame that every item import runs under stays small.
noinline fn importSourceRange(
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
    const slot = try content_domain.contentSlot(self, digest, length, private);
    var blob: ?*c.sqlite3_blob = null;
    if (!slot.existing and length != 0) {
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
    }
    defer if (blob) |value| {
        _ = c.sqlite3_blob_close(value);
    };
    var copy: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var offset: u64 = 0;
    while (offset < length) {
        const wanted: usize = @intCast(@min(length - offset, copy.window.len));
        const count = try file.readPositionalAll(self.io, copy.window[0..wanted], start + offset);
        if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
        copy.hash.update(copy.window[0..count]);
        if (blob) |value| {
            if (c.sqlite3_blob_write(value, copy.window[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
        }
        if (faults.output_import) return error.InjectedOutputImportFailure;
        offset += count;
    }
    if (!std.mem.eql(u8, &copy.hash.finalResult(), digest)) return error.OutputSourceChanged;
    return slot.id;
}

/// Saves one accepted item in Rui's own form from its metadata records
/// in `[metadata_start, metadata_end)`: its parts, its provider bags and,
/// for a message, its text (every text part's decoded text back to back,
/// one row its parts are lengths of).
/// noinline: its windows live in this frame only.
noinline fn importNeutralItem(self: *Store, binding: AttemptBinding, output: *const ValidatedOutput, item: OutputMetadataRecord, metadata_start: u64, metadata_end: u64, faults: Faults) !ImportedNeutral {
    var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    metadata.offset = metadata_start;
    metadata.length = metadata_end;
    var item_bag: ?i64 = null;
    var text: ?i64 = null;
    var text_length: u64 = 0;
    var part_count: u64 = 0;
    // The open part: its record's offset and its own text row. Every
    // part closes with its bag, so one INSERT writes the whole row.
    var part: ?struct { record: OutputMetadataRecord, start: u64, text: ?i64 } = null;
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
                        try importDecodedString(self, output, record, true, faults),
                };
                part = .{ .record = record, .start = metadata.offset, .text = own_text };
            },
            .extras => switch (record.scope) {
                .part => {
                    const pending = part orelse return error.CorruptOutputMetadata;
                    const bag = try importBag(self, output, record, pending.start, metadata.offset, faults);
                    const insert = try store_core.cached(
                        self,
                        "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
                    );
                    defer sqlite.resetCached(insert);
                    try sqlite.bindU64(insert, 1, binding.operation_id);
                    try sqlite.bindU64(insert, 2, item.ordinal);
                    try sqlite.bindU64(insert, 3, part_count);
                    try sqlite.bindI64(insert, 4, @backingInt(pending.record.part_array));
                    try sqlite.bindI64(insert, 5, @backingInt(pending.record.part_kind));
                    try sqlite.bindNullableU64(insert, 6, switch (pending.record.part_kind) {
                        .output_text, .refusal => pending.record.decoded_length,
                        .opaque_block, .summary_text, .reasoning_text => null,
                    });
                    try sqlite.bindNullableI64(insert, 7, pending.text);
                    try sqlite.bindI64(insert, 8, bag);
                    try sqlite.expectDone(insert);
                    part_count += 1;
                    part = null;
                },
                .item => {
                    if (part != null or item_bag != null) return error.CorruptOutputMetadata;
                    item_bag = try importBag(self, output, record, metadata_start, metadata.offset, faults);
                },
            },
            .text => {
                if (item_bag == null or text != null or record.decoded_length != text_length) return error.CorruptOutputMetadata;
                text = try importMessageText(self, output, record, metadata_start, metadata.offset, faults);
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
    var description: ?tool_catalog.Description = null;
    if (action) |call| {
        var target: [tool_catalog.WebSearchCall.excerpt_bytes]u8 = undefined;
        var found: [tool_catalog.WebSearchCall.excerpt_bytes]u8 = undefined;
        description = tool_catalog.describe(.{ .web_search = .{
            .action = @fromBackingInt(@backingInt(call.action)),
            .target = try excerpt(self.io, output.source, call, &target),
            .pattern = if (pattern) |field| try excerpt(self.io, output.source, field, &found) else "",
        } });
    }
    return .{
        .bag = item_bag orelse return error.CorruptOutputMetadata,
        .part_count = part_count,
        .text = text,
        .description = description,
        .call_failed = if (action) |call| call.call_failed else false,
    };
}

/// The first decoded bytes of a certified string `record`, as many as
/// `buffer` holds.
fn excerpt(io: std.Io, source: std.Io.File, record: OutputMetadataRecord, buffer: []u8) ![]const u8 {
    var reader: output_format.NameReader = .{ .io = io, .file = source, .position = record.start, .end = try record.end() };
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) buffer[length] = try reader.next() orelse break;
    return buffer[0..length];
}

/// An item in Rui's own form; a hosted call's description and outcome.
const ImportedNeutral = struct { bag: i64, part_count: u64, text: ?i64, description: ?tool_catalog.Description, call_failed: bool };

/// Decodes a message's text parts among the records in `[start, end)`
/// into one public row, checked against the message's `text` record.
/// A row with the same bytes is shared.
fn importMessageText(self: *Store, output: *const ValidatedOutput, text: OutputMetadataRecord, start: u64, end: u64, faults: Faults) !i64 {
    const slot = try content_domain.contentSlot(self, &text.content_digest, text.decoded_length, false);
    if (slot.existing or text.decoded_length == 0) return slot.id;
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    defer _ = c.sqlite3_blob_close(blob);
    var parts = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    parts.offset = start;
    parts.length = end;
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    while (try parts.next()) |part| {
        if (part.tag != .part or (part.part_kind != .output_text and part.part_kind != .refusal)) continue;
        try writeDecoded(self, output, blob, &decoded, part, &written, text.decoded_length);
        if (faults.output_import) return error.InjectedOutputImportFailure;
    }
    if (written != text.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &text.content_digest)) return error.OutputSourceChanged;
    return slot.id;
}

/// Copies one bag, the `member` records of `trailer`'s scope in
/// `[start, end)` joined by commas, into a private content row.
fn importBag(self: *Store, output: *const ValidatedOutput, trailer: OutputMetadataRecord, start: u64, end: u64, faults: Faults) !i64 {
    const slot = try content_domain.contentSlot(self, &trailer.content_digest, trailer.decoded_length, true);
    var blob: ?*c.sqlite3_blob = null;
    if (!slot.existing and trailer.decoded_length != 0) {
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    }
    defer if (blob) |value| {
        _ = c.sqlite3_blob_close(value);
    };
    var members = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
    members.offset = start;
    members.length = end;
    var copy: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    var first = true;
    while (try members.next()) |member| {
        if (member.tag != .member or member.scope != trailer.scope) continue;
        if (!first) try content_domain.writeCheckedBytes(self, blob, &copy.hash, ",", &written, trailer.decoded_length);
        first = false;
        const member_end = try member.end();
        if (member_end > output.source_length) return error.CorruptOutputMetadata;
        var offset = member.start;
        while (offset < member_end) {
            const wanted: usize = @intCast(@min(member_end - offset, copy.window.len));
            const count = try output.source.readPositionalAll(self.io, copy.window[0..wanted], offset);
            if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
            try content_domain.writeCheckedBytes(self, blob, &copy.hash, copy.window[0..count], &written, trailer.decoded_length);
            if (faults.output_import) return error.InjectedOutputImportFailure;
            offset += count;
        }
    }
    if (written != trailer.decoded_length or !std.mem.eql(u8, &copy.hash.finalResult(), &trailer.content_digest)) return error.OutputSourceChanged;
    return slot.id;
}

/// Decodes one saved string (a part's text or a call field) into its own
/// content row. A row with the same bytes is shared.
fn importDecodedString(self: *Store, output: *const ValidatedOutput, part: OutputMetadataRecord, private: bool, faults: Faults) !i64 {
    const slot = try content_domain.contentSlot(self, &part.content_digest, part.decoded_length, private);
    if (slot.existing or part.decoded_length == 0) return slot.id;
    var blob: ?*c.sqlite3_blob = null;
    if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) return error.ContentWriteFailed;
    defer _ = c.sqlite3_blob_close(blob);
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = protocol.contentHasher() };
    var written: u64 = 0;
    try writeDecoded(self, output, blob, &decoded, part, &written, part.decoded_length);
    if (faults.output_import) return error.InjectedOutputImportFailure;
    if (written != part.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &part.content_digest)) return error.OutputSourceChanged;
    return slot.id;
}

/// Decodes `part`'s encoded string from the source into `blob` at
/// `written`, within `length`, hashing what it writes.
fn writeDecoded(self: *Store, output: *const ValidatedOutput, blob: ?*c.sqlite3_blob, decoded: *content_domain.HashedWindow(import_window_bytes), part: OutputMetadataRecord, written: *u64, length: u64) !void {
    if (try part.end() > output.source_length) return error.CorruptOutputMetadata;
    var count: usize = 0;
    var text: output_format.EncodedStringWindow(import_window_bytes) = .{ .io = self.io, .file = output.source, .position = part.start, .end = try part.end() };
    while (try text.next()) |byte| {
        decoded.window[count] = byte;
        count += 1;
        if (count == decoded.window.len) {
            try content_domain.writeCheckedBytes(self, blob, &decoded.hash, &decoded.window, written, length);
            count = 0;
        }
    }
    try content_domain.writeCheckedBytes(self, blob, &decoded.hash, decoded.window[0..count], written, length);
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
