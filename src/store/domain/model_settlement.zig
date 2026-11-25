const std = @import("std");
const model_attempt = @import("model_attempt.zig");
const tool_proposal = @import("../../tool_proposal.zig");
const FieldCertificate = @import("../../activity_read.zig").FieldCertificate;
const content_string = @import("../../content_string.zig");
const idempotency_key = @import("../../idempotency_key.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const tool_defs = @import("../../call_classification.zig");
const tool_record = @import("../../tool_record.zig");
const tool_presentation = @import("../../tool_presentation.zig");
const mcp_arguments = @import("../../mcp/arguments.zig");
const mcp_document = @import("../../mcp/document.zig");
const tool_set = @import("tool_set.zig");
const output_format = @import("../../output_format.zig");
const retry_policy = @import("../../retry_policy.zig");
const turn_policy = @import("../../turn_policy.zig");
const codecs = @import("../../codecs.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const rsql = @import("../rsql.zig");
const store_schema = @import("../schema.zig");
const action_domain = @import("action.zig");
const command_domain = @import("command.zig");
const operation_effort = @import("operation_effort.zig");
const configuration_domain = @import("configuration.zig");
const content_domain = @import("content.zig");
const historical_domain = @import("historical.zig");
const history_floor_domain = @import("history_floor.zig");
const model_admission_domain = @import("model_admission.zig");
const store_access = @import("../access.zig");
const transition = @import("../transition.zig");
const forward_domain = @import("forward.zig");
const turn_domain = @import("turn.zig");
const failure_class = @import("../../failure_class.zig");
const pages = @import("../../os/pages.zig");
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

pub const ModelTimings = @import("../../model_timing.zig").Values;

pub const ModelFailureClass = union(enum) {
    ordinary,
    effort_change_refused,
    context_overflow,
    retryable: retry_policy.Input,
    refreshed,
};

pub const ModelFailure = union(enum) {
    uncorrelated: []const u8,
    correlated: Correlated,
    rejected: Rejected,

    pub const Correlated = struct {
        code: []const u8,
        request_id: Bounded(256),
        report: []const u8,
    };

    pub const Rejected = struct {
        code: []const u8,
        diagnostic: []const u8,
        request_id: Bounded(256),
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
    response_id: Bounded(256),
    model_evidence: Bounded(775),
    request_id: Bounded(256),
};

pub fn checkAttempt(self: *Store, binding: AttemptBinding) !ModelOperationKind {
    return self.queue().run(checkAttemptHeld, .{ self, binding });
}

fn checkAttemptHeld(self: *Store, binding: AttemptBinding) !ModelOperationKind {
    const entry = try store_core.enter(self, .none);
    defer entry.release();
    return entry.finish(Ordinary.attempt_binding, readAttemptKind(&entry, binding));
}

pub noinline fn readAttemptKind(entry: *const store_core.Entry, binding: AttemptBinding) !ModelOperationKind {
    var a: store_access.Access(.read, error{}) = .open(entry);
    defer a.deinit();
    return attemptKind(&a, binding);
}

const standing_columns = "o.turn_id,o.attempt_ordinal,o.resolution_code IS NOT NULL AS resolved,o.interrupted_by_command_key IS NOT NULL AS interrupted";

pub const attempt_standing = rsql.Read(.{
    .sql = "SELECT " ++ standing_columns ++ ",o.purpose AS compaction FROM model_operation o WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { turn_id: i64, attempt_ordinal: i64, resolved: bool, interrupted: bool, compaction: bool },
    .cardinality = .optional,
});

pub fn attemptKind(a: anytype, binding: AttemptBinding) !ModelOperationKind {
    var found: attempt_standing.Result = undefined;
    queueAttemptKind(a, binding, &found);
    try runOperationRead(a);
    return attemptKindOf(found, binding);
}

pub fn queueAttemptKind(a: anytype, binding: AttemptBinding, found: *attempt_standing.Result) void {
    a.read(attempt_standing, .{ .operation_id = binding.operation_id }, found);
}

pub fn attemptKindOf(found: attempt_standing.Result, binding: AttemptBinding) error{ StaleAttemptBinding, SupersededByControl }!ModelOperationKind {
    const row = found orelse return error.StaleAttemptBinding;
    try attemptStanding(row, binding);
    return if (row.compaction) .compaction else .assistant_response;
}

fn namesAttempt(turn_id: i64, attempt_ordinal: i64, binding: AttemptBinding) bool {
    return turn_id == binding.turn_id and attempt_ordinal == binding.attempt_ordinal;
}

fn attemptStanding(facts: anytype, binding: AttemptBinding) error{ StaleAttemptBinding, SupersededByControl }!void {
    if (!namesAttempt(facts.turn_id, facts.attempt_ordinal, binding)) return error.StaleAttemptBinding;
    if (!facts.resolved) return;
    if (facts.interrupted) return error.SupersededByControl;
    return error.StaleAttemptBinding;
}

const attempt_facts = rsql.Read(.{
    .sql = "SELECT " ++ standing_columns ++ ",o.purpose AS compaction,o.admission_position," ++
        "coalesce(o.retry_due_at_ms,0)<>0 AS retry_waiting,o.auth_refresh_claimed AS refresh_claimed," ++
        rsql.session_head_columns ++ "," ++
        "CASE WHEN ?2 THEN EXISTS(SELECT 1 FROM turn t WHERE t.turn_id=o.turn_id AND t.outcome_code IS NULL " ++
        "AND t.operation_id=o.operation_id) ELSE 0 END AS turn_open," ++
        "CASE WHEN ?3 THEN " ++ turn_domain.unowedChildrenSql("o.session_ref") ++ " ELSE 0 END AS unowed_children " ++
        "FROM model_operation o LEFT JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64, closes: bool, context_full: bool = false },
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
        unowed_children: u64,
    },
    .cardinality = .optional,
});

fn currentAttempt(facts: *const attempt_facts.Result, binding: AttemptBinding) error{ StaleAttemptBinding, SupersededByControl }!*const attempt_facts.Row {
    const row = &(facts.* orelse return error.StaleAttemptBinding);
    try attemptStanding(row, binding);
    return row;
}

const attempt_session = rsql.Read(.{
    .sql = "SELECT " ++ standing_columns ++ "," ++ rsql.session_head_columns ++ " " ++
        "FROM model_operation o LEFT JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { turn_id: i64, attempt_ordinal: i64, resolved: bool, interrupted: bool, session: rsql.SessionHead },
    .cardinality = .optional,
});

pub const AttemptSession = struct {
    found: attempt_session.Result = undefined,

    pub fn queue(read: *AttemptSession, r: anytype, binding: AttemptBinding) void {
        r.read(attempt_session, .{ .operation_id = binding.operation_id }, &read.found);
    }

    pub fn session(read: *const AttemptSession, binding: AttemptBinding) !rsql.SessionHead {
        const row = read.found orelse return error.StaleAttemptBinding;
        try attemptStanding(row, binding);
        return row.session;
    }
};

const superseding_control = rsql.Read(.{
    .sql = "SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation WHERE operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { turn_id: i64, attempt_ordinal: i64, interrupted_by_command_key: ?Bounded(idempotency_key.max_bytes) },
    .cardinality = .optional,
});

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
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.AuthRefreshUnclaimed } },
});

fn runOperationRead(a: anytype) !void {
    try store_access.runAs(a, error.OperationReadFailed);
}

pub const ClaimAuthRefresh = struct {
    pub const rounds = transition.rounds(.{ .facts = .{ .always, error.OperationReadFailed } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct { binding: AttemptBinding };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.attempt_binding;
    pub const Guards = store_core.Ordinary.attempt_binding || Declined;
    pub const Declined = error{AuthRefreshUnclaimed};

    input: Input,
    facts: attempt_facts.Result = undefined,

    pub fn step(t: *ClaimAuthRefresh, r: *transition.Round(ClaimAuthRefresh), ran: ?rounds.At) !transition.Next(ClaimAuthRefresh) {
        const binding = t.input.binding;
        if (ran == null) {
            r.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = false }, &t.facts);
            return .{ .round = .facts };
        }
        const row = try currentAttempt(&t.facts, binding);
        if (row.retry_waiting or row.refresh_claimed or binding.attempt_ordinal >= retry_policy.maximum_attempts) return .{ .done = false };
        r.write(claim_auth_refresh, .{ .operation_id = binding.operation_id, .attempt_ordinal = binding.attempt_ordinal, .session = row.session });
        return .commit;
    }

    pub fn committed(_: *const ClaimAuthRefresh) Result {
        return true;
    }

    pub fn declined(_: *const ClaimAuthRefresh, _: Declined) Result {
        return false;
    }
};

const resolve_failure = model_attempt.Write(.{
    .end = .resolution,
    .set = "retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,request_id=?4," ++
        "last_failure_code=coalesce(?5,last_failure_code)",
    .where = "operation_id=?1 AND session_ref=@session(?7) AND resolution_code IS NULL AND attempt_ordinal=?6",
    .Args = struct { operation_id: u64, resolution: []const u8, content_id: ?u64, request_id: ?[]const u8, last_failure_code: ?[]const u8, attempt_ordinal: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

const schedule_retry = model_attempt.Write(.{
    .end = .retry,
    .set = "retry_due_at_ms=?2,last_failure_code=?3",
    .where = "operation_id=?1 AND session_ref=@session(?5) AND resolution_code IS NULL AND attempt_ordinal=?4",
    .Args = struct { operation_id: u64, due_at_ms: u64, code: []const u8, attempt_ordinal: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

const refused_effort_source = rsql.Read(.{
    .sql = "SELECT o.effort_source_revision AS revision FROM model_operation o WHERE o.operation_id=?1 AND " ++ operation_effort.refusalEligibleSql("o"),
    .Args = struct { operation: u64 },
    .Row = struct { revision: rsql.Positive },
    .cardinality = .optional,
});

const insert_effort_refusal = rsql.Write(.{
    .sql = "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at,provider_text,refused_operation_id) VALUES(@session(?1),?2,0,?3,'reasoning_effort_refused',@now,?4,?5)",
    .Args = struct { session: rsql.SessionHead, position: u64, revision: u64, provider_text: []const u8, operation: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

const invalidate_effort_prefix = rsql.Write(.{
    .sql = "UPDATE session SET prefix_seal=NULL WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.StaleAttemptBinding } },
});

fn queueEffortRefusal(a: anytype, session: rsql.SessionHead, revision: u64, operation: u64, report: []const u8) !void {
    const position = try (try a.positions(session)).take(1);
    a.write(insert_effort_refusal, .{ .session = session, .position = position, .revision = revision, .provider_text = report, .operation = operation });
    a.write(invalidate_effort_prefix, .{ .session = session });
}

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

    fn lookup(content: *FailureContent, a: anytype) void {
        if (content.diagnostic != null and content.report != null) {
            content_domain.lookupPair(a, &content.diagnostic.?, &content.report.?, &content.pair);
        } else if (content.diagnostic) |*value| {
            content_domain.lookup(a, value);
        } else if (content.report) |*value| content_domain.lookup(a, value);
    }

    fn found(content: *FailureContent) void {
        if (content.diagnostic != null and content.report != null) content_domain.foundPair(&content.pair, &content.diagnostic.?, &content.report.?);
    }

    fn importDiagnostic(content: *FailureContent, a: anytype, failure: *const ModelFailure) !?u64 {
        const value = if (content.diagnostic) |*value| value else return null;
        return try content_domain.importBytes(a, value, failure.diagnostic().?);
    }

    fn importReport(content: *FailureContent, a: anytype, failure: *const ModelFailure) !?u64 {
        const value = if (content.report) |*value| value else return null;
        return try content_domain.importBytes(a, value, failure.report());
    }
};

pub const SettleFailure = struct {
    pub const rounds = transition.rounds(.{
        .refusal = .{ .branch, error.OperationReadFailed },
        .facts = .{ .always, error.OperationReadFailed },
        .floor = .{ .branch, error.CorruptStore },
        .floor_page = .{ .paged, error.CorruptStore },
        .context = .{.branch},
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .refusal;
    pub const Input = struct { entry: *const store_core.Entry, floor: *history_floor_domain.FloorSearch, prepared: ?*const history_floor_domain.Prepared = null, io: std.Io, binding: AttemptBinding, failure: *const ModelFailure, disposition: *const ModelFailureClass };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.attempt_binding || error{FloorPreparationRequired};
    pub const Guards = store_core.Ordinary.attempt_binding;
    pub const Declined = error{};

    input: Input,
    exhausted_refusal: ?u64 = null,
    retry_random: u64 = 0,
    facts: attempt_facts.Result = undefined,
    content: FailureContent = .{ .diagnostic = null, .report = null },
    reads: union { source: refused_effort_source.Result, floor: *history_floor_domain.FloorSearch, context: context_changed.Result } = undefined,

    fn disposition(t: *const SettleFailure) ModelFailureClass {
        if (t.input.disposition.* != .effort_change_refused) return t.input.disposition.*;
        if (t.exhausted_refusal != null) return .{ .retryable = .{ .waits_ms = retry_policy.default_waits_ms } };
        return .ordinary;
    }

    pub fn step(t: *SettleFailure, r: *transition.Round(SettleFailure), ran: ?rounds.At) !transition.Next(SettleFailure) {
        const binding = t.input.binding;
        const failure = t.input.failure;
        const at = ran orelse {
            if (t.input.disposition.* != .effort_change_refused) return t.queueFacts(r);
            t.reads = .{ .source = undefined };
            r.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = false }, &t.facts);
            r.read(refused_effort_source, .{ .operation = binding.operation_id }, &t.reads.source);
            return .{ .round = .refusal };
        };
        switch (at) {
            .refusal => {
                const row = try currentAttempt(&t.facts, binding);
                const revision = (t.reads.source orelse return t.queueFacts(r)).revision.get();
                if (binding.attempt_ordinal >= retry_policy.maximum_attempts) {
                    t.exhausted_refusal = revision;
                    return t.queueFacts(r);
                }
                try queueEffortRefusal(r, row.session, revision, binding.operation_id, failure.report());
                schedule_retry.queue(r, .{
                    .operation_id = binding.operation_id,
                    .due_at_ms = @intCast(@max(1, try store_core.readUnixMilliseconds(t.input.io))),
                    .code = failure.code(),
                    .attempt_ordinal = binding.attempt_ordinal,
                    .session = row.session,
                });
                if (r.faults().before_commit) return error.InjectedCommitFailure;
                return .commit;
            },
            .facts => {
                t.content.found();
                const row = try currentAttempt(&t.facts, binding);
                if (t.disposition() != .context_overflow) return t.settle(r, false);
                if (row.compaction) {
                    t.input.floor.* = .{ .operation = binding.operation_id, .entry = t.input.entry, .prepared = t.input.prepared };
                    t.reads = .{ .floor = t.input.floor };
                    t.reads.floor.start(r);
                    return .{ .round = .floor };
                }
                t.reads = .{ .context = undefined };
                r.read(context_changed, .{ .session = &row.session.ref, .boundary = row.admission_position.get() }, &t.reads.context);
                return .{ .round = .context };
            },
            .floor, .floor_page => {
                if (try t.reads.floor.next(r)) return .{ .round = .floor_page };
                return t.settle(r, t.reads.floor.room() != null);
            },
            .context => return t.settle(r, turn_policy.recoversOverflow(.assistant_response, try model_admission_domain.contextChanged(&t.reads.context), codecs.compacts(t.reads.context.codec))),
        }
    }

    fn queueFacts(t: *SettleFailure, r: *transition.Round(SettleFailure)) transition.Next(SettleFailure) {
        const binding = t.input.binding;
        const settles_as = t.disposition();
        if (settles_as == .retryable) t.input.io.random(std.mem.asBytes(&t.retry_random));
        const resolves = switch (settles_as) {
            .ordinary, .context_overflow => true,
            .refreshed => false,
            .effort_change_refused => unreachable,
            .retryable => binding.attempt_ordinal == retry_policy.maximum_attempts,
        };
        if (resolves) t.content = .of(t.input.failure);
        const context_full = settles_as == .context_overflow or failure_class.of(t.input.failure.code()) == .overflow;
        r.read(attempt_facts, .{ .operation_id = binding.operation_id, .closes = resolves, .context_full = resolves and context_full }, &t.facts);
        t.content.lookup(r);
        return .{ .round = .facts };
    }

    fn settle(t: *SettleFailure, r: *transition.Round(SettleFailure), compact: bool) !transition.Next(SettleFailure) {
        const binding = t.input.binding;
        const failure = t.input.failure;
        const faults = r.faults();
        const code = failure.code();
        const row = try currentAttempt(&t.facts, binding);
        const session = row.session;
        switch (t.disposition()) {
            .effort_change_refused => unreachable,
            .ordinary, .context_overflow => {
                const overflow = t.disposition() == .context_overflow;
                if (t.content.diagnostic != null and faults.content_import) return error.InjectedContentImportFailure;
                const diagnostic_id = try t.content.importDiagnostic(r, failure);
                resolve_failure.queue(r, .{
                    .operation_id = binding.operation_id,
                    .resolution = if (overflow) @tagName(turn_policy.Resolution.context_overflow) else code,
                    .content_id = diagnostic_id,
                    .request_id = optionalText(failure.requestId()),
                    .last_failure_code = if (overflow) code else null,

                    .attempt_ordinal = binding.attempt_ordinal,
                    .session = session,
                });
                if (compact) {
                    turn_domain.queueContinuation(r, binding.turn_id, session);
                } else {
                    if (!row.turn_open) return error.StaleAttemptBinding;
                    if (t.content.report != null and faults.content_import) return error.InjectedContentImportFailure;
                    const report = try t.content.importReport(r, failure);
                    const outcome: TurnOutcome = if (overflow) .{ .resource_exceeded = optionalId(report) } else .{ .failed = .{
                        .code = code,
                        .report = optionalId(report),
                    } };
                    const positions = try r.positions(session);
                    try turn_domain.queueCloseOr(r, positions, binding.turn_id, outcome, error.StaleAttemptBinding);
                    if (outcome.ending(false) == .context_full) turn_domain.queueOwedStops(r, &row.session.ref, positions.head.next_position.get() + positions.taken - 1, row.unowed_children);
                }
            },
            .refreshed => {
                if (!row.refresh_claimed or binding.attempt_ordinal >= retry_policy.maximum_attempts) return error.StaleAttemptBinding;
                schedule_retry.queue(r, .{
                    .operation_id = binding.operation_id,
                    .due_at_ms = @intCast(@max(1, try store_core.readUnixMilliseconds(t.input.io))),
                    .code = code,
                    .attempt_ordinal = binding.attempt_ordinal,
                    .session = session,
                });
            },
            .retryable => |policy| switch (try retry_policy.decide(binding.attempt_ordinal, policy, try store_core.readUnixMilliseconds(t.input.io), t.retry_random)) {
                .schedule_at_ms => |due_at_ms| schedule_retry.queue(r, .{
                    .operation_id = binding.operation_id,
                    .due_at_ms = std.math.cast(u64, due_at_ms) orelse return error.IntegerOutOfRange,
                    .code = code,
                    .attempt_ordinal = binding.attempt_ordinal,
                    .session = session,
                }),
                .exhausted => {
                    if (t.content.diagnostic != null and faults.content_import) return error.InjectedContentImportFailure;
                    const diagnostic_id = try t.content.importDiagnostic(r, failure);
                    resolve_failure.queue(r, .{
                        .operation_id = binding.operation_id,
                        .resolution = "retry_exhausted",
                        .content_id = diagnostic_id,
                        .request_id = optionalText(failure.requestId()),
                        .last_failure_code = code,
                        .attempt_ordinal = binding.attempt_ordinal,
                        .session = session,
                    });
                    if (!row.turn_open) return error.StaleAttemptBinding;
                    if (t.content.report != null and faults.content_import) return error.InjectedContentImportFailure;
                    const report = try t.content.importReport(r, failure);
                    try turn_domain.queueCloseOr(r, try r.positions(session), binding.turn_id, .{ .retry_exhausted = optionalId(report) }, error.StaleAttemptBinding);
                },
            },
        }
        if (t.exhausted_refusal) |revision| try queueEffortRefusal(r, session, revision, binding.operation_id, failure.report());
        if (faults.before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(_: *const SettleFailure) Result {}
};

fn optionalText(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

fn optionalId(id: ?u64) ?i64 {
    return if (id) |value| @intCast(value) else null;
}

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

const resolve_exhausted = model_attempt.Write(.{
    .end = .resolution,
    .set = "retry_due_at_ms=NULL,resolution_code='retry_exhausted'",
    .where = "operation_id=?1 AND session_ref=@session(?2) AND " ++ retry_exhausted_sql,
    .Args = struct { operation_id: u64, session: rsql.SessionHead },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.SelectionChanged } },
});

const ExhaustedChoice = struct {
    active: ActiveOperationFilter,
    chosen: ?exhausted_attempts.Row = null,

    pub fn visit(choice: *ExhaustedChoice, row: *const exhausted_attempts.Row) bool {
        if (choice.active.contains(row.operation_id.get())) return true;
        choice.chosen = row.*;
        return false;
    }
};

pub const RecoverExhausted = struct {
    pub const rounds = transition.rounds(.{ .scan = .{ .always, error.RetryRecoveryFailed } });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = null;
    pub const Input = struct { active: ActiveOperationFilter };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{SelectionChanged};
    pub const Declined = error{};

    input: Input,
    choice: ExhaustedChoice = undefined,

    pub fn step(t: *RecoverExhausted, r: *transition.Round(RecoverExhausted), ran: ?rounds.At) !transition.Next(RecoverExhausted) {
        if (ran == null) {
            t.choice = .{ .active = t.input.active };
            r.readEach(exhausted_attempts, .{}, try std.math.add(u64, t.input.active.maximum_exclusions, 1), &t.choice);
            return .{ .round = .scan };
        }
        const chosen = t.choice.chosen orelse return .{ .done = false };
        if (!chosen.turn_open) return error.SelectionChanged;
        resolve_exhausted.queue(r, .{ .operation_id = chosen.operation_id.get(), .session = chosen.session });
        try turn_domain.queueCloseOr(r, try r.positions(chosen.session), chosen.turn_id.get(), .{ .retry_exhausted = null }, error.SelectionChanged);
        return .commit;
    }

    pub fn committed(_: *const RecoverExhausted) Result {
        return true;
    }
};

const builtin_names_sql = blk: {
    var names: []const u8 = "";
    for (std.enums.values(tool_record.Tool), 0..) |tool, index| {
        names = names ++ (if (index == 0) "" else ",") ++ "'" ++ @tagName(tool) ++ "'";
    }
    break :blk names;
};

const success_facts = rsql.Read(.{
    .sql = "SELECT r.revision AS frozen_revision,coalesce(" ++ tool_set.namesSql("o.tool_set_id") ++ ",'') AS tool_names,coalesce(" ++ tool_set.appNamesSql("o.tool_set_id") ++ ",'') AS app_names," ++
        "EXISTS(SELECT 1 FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id " ++
        "WHERE member.tool_set_id=o.tool_set_id AND tool.name NOT IN (" ++ builtin_names_sql ++ ") AND tool.owner NOT IN ('mcp','app')) AS invalid_owner," ++
        "s.permission_mode,s.revision," ++
        "coalesce((SELECT max(e.entry_ordinal) FROM conversation_entry e WHERE e.session_ref=o.session_ref),0) AS entry_base " ++
        "FROM model_operation o LEFT JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision " ++
        "JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1",
    .Args = struct { operation_id: u64 },
    .Row = struct { frozen_revision: ?rsql.Positive = null, tool_names: *Bounded(tool_set.max_offered_names_bytes), app_names: *Bounded(tool_set.max_app_names_bytes), invalid_owner: bool = false, permission_mode: bool = false, revision: rsql.Positive = undefined, entry_base: u64 = 0 },
    .cardinality = .optional,
});

const pending_messages = rsql.Read(.{
    .sql = "SELECT count(*) AS pending FROM model_operation o JOIN message_admission m ON m.session_ref=o.session_ref " ++
        "WHERE o.operation_id=?1 AND m.turn_id IS NULL AND m.admission_id>coalesce((" ++
        "SELECT stop.admission_cutoff FROM session_stop stop WHERE stop.session_ref=o.session_ref ORDER BY stop.admission_cutoff DESC LIMIT 1),0)",
    .Args = struct { operation_id: u64 },
    .Row = struct { pending: u64 },
    .cardinality = .one,
});

fn parameters(comptime first: usize, comptime count: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var text: []const u8 = "";
        for (first..first + count) |number| text = text ++ (if (number == first) "" else ",") ++ std.fmt.comptimePrint("?{d}", .{number});
        return text;
    }
}

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

fn digestArgs(comptime S: type, comptime width: usize, digests: *[width][32]u8, count: usize) *const S.Args {
    comptime std.debug.assert(@sizeOf(S.Args) == width * 32 and @offsetOf(S.Args, "d1") == 0);
    std.debug.assert(count != 0 and count <= width);
    for (digests[count..]) |*slot| slot.* = digests[0];
    return @ptrCast(digests);
}

fn ContentBatch(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT content_id,digest,byte_length,private FROM content WHERE digest IN (" ++ parameters(1, width) ++ ")",
        .Args = DigestArgs(&.{}, width),
        .Row = LookupRow,
        .cardinality = .each,
    });
}

const LookupRow = struct { content_id: rsql.Positive, digest: [32]u8, byte_length: u64, private: bool };

fn DuplicateItems(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT item_id_digest AS digest FROM model_output_item WHERE operation_id=?1 AND item_id_digest IN (" ++ parameters(2, width) ++ ")",
        .Args = DigestArgs(&.{"operation_id"}, width),
        .Row = DuplicateRow,
        .cardinality = .each,
    });
}

fn DuplicateCalls(comptime width: usize) type {
    return rsql.Read(.{
        .sql = "SELECT c.digest FROM model_tool_call t JOIN content c ON c.content_id=t.call_id_content_id " ++
            "WHERE t.operation_id=?1 AND c.private=0 AND c.digest IN (" ++ parameters(2, width) ++ ")",
        .Args = DigestArgs(&.{"operation_id"}, width),
        .Row = DuplicateRow,
        .cardinality = .each,
    });
}

const content_batch = ContentBatch(narrow_width);
const content_batch_wide = ContentBatch(lookup_width);
const duplicate_items = DuplicateItems(narrow_width);
const duplicate_items_wide = DuplicateItems(batch_items);
const duplicate_calls = DuplicateCalls(narrow_width);
const duplicate_calls_wide = DuplicateCalls(batch_items);

comptime {
    std.debug.assert(duplicate_items.Args == duplicate_calls.Args and duplicate_items_wide.Args == duplicate_calls_wide.Args);
}

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
        description: ?tool_record.Description,
        call_failed: bool,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

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
        rejection_code: ?tool_proposal.Rejection,
        rejection_content_id: ?u64,
        acceptance_position: ?u64,
        action_kind: ?u64,
        description: ?tool_record.Description,
        field_metadata: FieldCertificate.Bytes,
        session: rsql.SessionHead,
    },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_action = rsql.Write(.{
    .sql = "INSERT INTO action_operation(action_id,parent_operation_id,call_ordinal,session_ref,tool_kind,permission_revision,authorized,bash_timeout_override_ms,resolution_code,decided_at,approval_position) " ++
        "VALUES(?1,?2,?3,@session(?4),1,?5,?6,?7,NULL,CASE WHEN ?6=1 THEN @now END,?8)",
    .Args = struct { action_id: u64, operation_id: u64, call_ordinal: u64, session: rsql.SessionHead, revision: u64, authorized: bool, timeout_ms: ?u64, approval_position: ?u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const resolve_success = model_attempt.Write(.{
    .end = .resolution,
    .set = "retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,model_evidence=?5,request_id=?6,output_item_count=?7," ++
        "usage_uncached_tokens=?8,usage_cache_read_tokens=?9,usage_cache_write_tokens=?10,usage_output_tokens=?11",
    .where = "operation_id=?1 AND session_ref=@session(?13) AND resolution_code IS NULL AND attempt_ordinal=?12",
    .Args = struct {
        operation_id: u64,
        resolution: []const u8,
        content_id: ?u64,
        response_id: ?[]const u8,
        model_evidence: rsql.Bytes,
        request_id: ?[]const u8,
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

const batch_items = 64;
const narrow_width = 16;
const lookup_width = batch_items;
const batch_identities = 4 * lookup_width + 1;
const wide_lookup_above = 3 * narrow_width;
fn lookupCount(n: usize) usize {
    var left = n;
    var count: usize = 0;
    while (left != 0) : (count += 1) left -= @min(if (left > wide_lookup_above) lookup_width else narrow_width, left);
    return count;
}
const max_lookups = blk: {
    @setEvalBranchQuota(100_000);
    var most: usize = 0;
    for (1..batch_identities + 1) |n| most = @max(most, lookupCount(n));
    break :blk most;
};

const Identity = struct {
    length: u64,
    row: packed struct(u64) { content_id: u63, private: bool },
};

const LookupVisitor = struct {
    batch: *Batch,
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

const historical_names = rsql.Read(.{
    .sql = "SELECT DISTINCT tool.name FROM model_operation o JOIN tool_set_member member ON " ++
        "(member.tool_set_id IN (SELECT earlier.tool_set_id FROM model_operation earlier WHERE earlier.session_ref=o.session_ref AND earlier.admission_position<o.admission_position) " ++
        "OR member.tool_set_id IN (SELECT " ++ tool_set.offeredSetSql("r") ++ " FROM session_revision r WHERE r.session_ref=o.session_ref AND r.revision<o.settings_revision)) " ++
        "JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE o.operation_id=?1 AND tool.name IN (" ++ parameters(2, batch_items) ++ ")",
    .Args = NameArgs(),
    .Row = struct { name: Bounded(tool_record.max_name_bytes) },
    .cardinality = .each,
});

fn NameArgs() type {
    var names: [batch_items + 1][:0]const u8 = undefined;
    var types: [batch_items + 1]type = undefined;
    names[0] = "operation_id";
    types[0] = u64;
    for (0..batch_items) |index| {
        names[index + 1] = std.fmt.comptimePrint("n{d}", .{index});
        types[index + 1] = Bounded(tool_record.max_name_bytes);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

const HistoryVisitor = struct {
    batch: *Batch,
    pub fn visit(visitor: *HistoryVisitor, row: *const historical_names.Row) bool {
        const batch = visitor.batch;
        const digest = content_string.digest(row.name.slice());
        for (batch.identities[0..batch.identity_count], batch.identity_digests[0..batch.identity_count], 0..) |*identity, *candidate, index| {
            if (identity.row.private or identity.length != row.name.len or !std.mem.eql(u8, candidate, &digest)) continue;
            batch.withdrawn[index] = true;
        }
        return true;
    }
};

pub const Batch = struct {
    offered_names: Bounded(tool_set.max_offered_names_bytes),
    offered_app_names: Bounded(tool_set.max_app_names_bytes),
    withdrawn: [batch_identities]bool,
    history_visitor: HistoryVisitor,
    history_needed: bool,
    kind: enum { items, calls },
    start: u64,
    end: u64,
    stopped: ?anyerror,
    last: bool,
    identity_digests: [batch_identities][32]u8,
    identities: [batch_identities]Identity,
    identity_count: u16,
    ids: DuplicateIds,
    digest_count: u8,
    lookups: [max_lookups]LookupVisitor,
    lookup_count: u8,
    duplicates: DuplicateVisitor,

    noinline fn queueHistory(batch: *Batch, a: anytype, operation_id: u64, output: *const ValidatedOutput, io: std.Io) !void {
        @setEvalBranchQuota(20_000);
        const Name = Bounded(tool_record.max_name_bytes);
        comptime {
            std.debug.assert(@sizeOf(historical_names.Args) == @sizeOf(u64) + batch_items * @sizeOf(Name));
            for (0..batch_items) |index| {
                std.debug.assert(@offsetOf(historical_names.Args, std.fmt.comptimePrint("n{d}", .{index})) == @offsetOf(historical_names.Args, "n0") + index * @sizeOf(Name));
            }
        }
        const mapped = try pages.Mapped(historical_names.Args).map();
        defer mapped.unmap();
        const args = mapped.value;
        args.operation_id = operation_id;
        const names: *[batch_items]Name = @ptrCast(&args.n0);
        var reader = try OutputMetadataReader.init(io, output.metadata);
        reader.offset = batch.start;
        var index: usize = 0;
        while (index < batch.digest_count) {
            const record = try reader.next() orelse return error.CorruptOutputMetadata;
            switch (record.tag) {
                .name => if (record.decoded_length <= tool_record.max_name_bytes) {
                    var buffer: [tool_record.max_name_bytes]u8 = undefined;
                    try names[index].set(try excerpt(io, output.source, record, &buffer));
                },
                .arguments => index += 1,
                else => {},
            }
        }
        batch.history_visitor = .{ .batch = batch };
        a.readEachFrom(historical_names, args, batch_items, &batch.history_visitor);
    }

    fn reset(batch: *Batch, kind: @FieldType(Batch, "kind"), start: u64) void {
        batch.kind = kind;
        batch.withdrawn = @splat(false);
        batch.history_needed = false;
        batch.start = start;
        batch.end = start;
        batch.stopped = null;
        batch.last = false;
        batch.identity_count = 0;
        batch.digest_count = 0;
        batch.lookup_count = 0;
        batch.duplicates = .{ .batch = batch };
    }

    fn stop(batch: *Batch, failure: ?anyerror, at: u64) void {
        batch.stopped = failure;
        batch.end = if (failure == null) std.math.maxInt(u64) else at;
        batch.last = true;
    }

    fn offeredAppText(batch: *const Batch) []const u8 {
        return batch.offered_app_names.slice();
    }

    /// Points the success read's app names at this Batch's buffer, which the read fills and the settlement's tools borrow.
    fn pointOfferedApps(batch: *Batch, success: *success_facts.Row) void {
        success.app_names = &batch.offered_app_names;
    }

    fn find(batch: *Batch, value: *const content_domain.Import) ?*Identity {
        for (batch.identities[0..batch.identity_count], batch.identity_digests[0..batch.identity_count]) |*identity, *digest| {
            if (identity.length == value.length and identity.row.private == value.private and std.mem.eql(u8, digest, &value.digest)) return identity;
        }
        return null;
    }

    fn cutFirst(batch: *Batch, boundary: ?PartBoundary, cut: *?u64) void {
        if (batch.digest_count != 0) return;
        const at = boundary orelse return;
        batch.identity_count = at.identities;
        cut.* = at.offset;
    }

    fn add(batch: *Batch, value: content_domain.Import) bool {
        if (batch.find(&value) != null) return true;
        if (batch.identity_count == batch_identities) return false;
        batch.identity_digests[batch.identity_count] = value.digest;
        batch.identities[batch.identity_count] = .{ .length = value.length, .row = .{ .content_id = 0, .private = value.private } };
        batch.identity_count += 1;
        return true;
    }

    noinline fn queueContentReads(batch: *Batch, a: anytype) void {
        var first: u16 = 0;
        while (first < batch.identity_count) {
            const left = batch.identity_count - first;
            const count = @min(@as(u16, if (left > wide_lookup_above) lookup_width else narrow_width), left);
            const chunk = batch.identity_digests[first..][0..count];
            var distinct: u8 = 0;
            for (chunk, 0..) |*digest, index| {
                const seen = for (chunk[0..index]) |*earlier| {
                    if (std.mem.eql(u8, earlier, digest)) break true;
                } else false;
                if (!seen) distinct += 1;
            }
            const visitor = &batch.lookups[batch.lookup_count];
            visitor.* = .{ .batch = batch, .limit = 2 * distinct };
            batch.lookup_count += 1;
            const limit = 2 * @as(u64, distinct) + 1;
            if (count <= narrow_width) {
                if (first + narrow_width <= batch_identities) {
                    a.readEachFrom(content_batch, digestArgs(content_batch, narrow_width, batch.identity_digests[first..][0..narrow_width], count), limit, visitor);
                } else {
                    var padded: [narrow_width][32]u8 = undefined;
                    @memcpy(padded[0..count], chunk);
                    a.readEachFrom(content_batch, digestArgs(content_batch, narrow_width, &padded, count), limit, visitor);
                }
            } else {
                a.readEachFrom(content_batch_wide, digestArgs(content_batch_wide, lookup_width, batch.identity_digests[first..][0..lookup_width], count), limit, visitor);
            }
            first += count;
        }
    }

    fn queueReads(batch: *Batch, a: anytype, operation_id: u64, output: *const ValidatedOutput, io: std.Io) !void {
        @setEvalBranchQuota(20_000);
        batch.queueContentReads(a);
        if (batch.digest_count == 0) return;
        if (batch.kind == .calls and batch.history_needed) try batch.queueHistory(a, operation_id, output, io);
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

    fn checkReads(batch: *const Batch) error{CorruptStore}!void {
        for (batch.lookups[0..batch.lookup_count]) |visitor| if (visitor.overflow) return error.CorruptStore;
        if (batch.duplicates.overflow) return error.CorruptStore;
    }

    fn duplicate(batch: *const Batch, index: u8) bool {
        if (batch.duplicates.lowest) |lowest| if (lowest == index) return true;
        for (batch.ids.digests[0..index]) |*earlier| if (std.mem.eql(u8, earlier, &batch.ids.digests[index])) return true;
        return false;
    }
};

fn recordImport(record: *const OutputMetadataRecord) ?content_domain.Import {
    const length: u64, const private = switch (record.tag) {
        .part => switch (record.part_kind) {
            .summary_text, .reasoning_text => .{ record.decoded_length, true },
            .opaque_block, .output_text, .refusal => return null,
        },
        .extras => .{ record.decoded_length, true },
        .text => .{ record.decoded_length, false },
        .name, .call_id, .arguments => .{ record.decoded_length, false },
        .item, .action, .pattern, .member, .usage => return null,
    };
    return .{ .digest = record.content_digest, .length = length, .private = private };
}

noinline fn collectItems(batch: *Batch, output: *const ValidatedOutput, io: std.Io, start: u64, resuming: bool, cut: *?u64) void {
    batch.reset(.items, start);
    cut.* = null;
    var reader = OutputMetadataReader.init(io, output.metadata) catch |err| return batch.stop(err, start);
    reader.offset = start;
    var unit_start = start;
    var unit_identities = batch.identity_count;
    var unfit = false;
    var boundary: ?PartBoundary = null;
    while (true) {
        const record_start = reader.offset;
        const record = (reader.next() catch |err| return batch.stop(err, record_start)) orelse {
            batch.end = reader.offset;
            batch.last = true;
            return;
        };
        if (record.tag == .item or record.tag == .usage) {
            if (record.tag == .item and !unfit and output.answer_length == 0 and output.answer_item_ordinal == record.ordinal and
                !batch.add(content_domain.empty_content))
            {
                unfit = true;
                batch.cutFirst(boundary, cut);
            }
            if (unfit and batch.digest_count != 0) {
                batch.identity_count = unit_identities;
                batch.end = unit_start;
                return;
            }
            if (record.tag == .item and !resuming) {
                batch.ids.digests[batch.digest_count] = record.id_digest;
                batch.digest_count += 1;
            }
            unit_start = reader.offset;
            unit_identities = batch.identity_count;
            if (unfit or resuming or batch.digest_count == batch_items) {
                batch.end = reader.offset;
                return;
            }
            continue;
        }
        if (record.tag == .name or record.tag == .call_id or record.tag == .arguments) continue;
        const value = recordImport(&record) orelse continue;
        if (unfit) continue;
        if (!batch.add(value)) {
            unfit = true;
            batch.cutFirst(boundary, cut);
            continue;
        }
        if (record.tag == .extras and record.scope == .part) boundary = .{ .offset = reader.offset, .identities = batch.identity_count };
    }
}

const PartBoundary = struct { offset: u64, identities: u16 };

noinline fn collectCalls(batch: *Batch, output: *const ValidatedOutput, io: std.Io, start: u64, offered: *const tool_record.Offered) void {
    @setEvalBranchQuota(20_000);
    comptime std.debug.assert(batch_identities >= 4 * batch_items + 1);
    batch.reset(.calls, start);
    var reader = OutputMetadataReader.init(io, output.metadata) catch |err| return batch.stop(err, start);
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
                const name_record = name orelse return batch.stop(null, record_start);
                const call_id_record = call_id orelse return batch.stop(null, record_start);
                for ([_]*const OutputMetadataRecord{ &name_record, &call_id_record, &record }) |field| {
                    const fits = batch.add(recordImport(field).?);
                    std.debug.assert(fits);
                }
                if (inspectOutputCall(io, output.source, name_record, record, offered)) |facts| {
                    const provisional = facts.tool == null and !facts.removed;
                    if (provisional) {
                        batch.history_needed = true;
                        const fits = batch.add(.ofBytes(tool_defs.removed_tool_result, false));
                        std.debug.assert(fits);
                    }
                    if (tool_defs.classifyCall(&facts)) |code| {
                        var buffer: [192]u8 = undefined;
                        if (rejectionText(io, output, code, &facts, name_record, &buffer)) |text| {
                            const fits = batch.add(.ofBytes(text, false));
                            std.debug.assert(fits);
                        } else |_| {}
                    } else if (facts.tool != null and facts.tool.?.owner == .app) {
                        // The unserved app result importCall records: one shared identity, like a rejection's text.
                        const fits = batch.add(.ofBytes(tool_record.Runner.app.unservedText(), false));
                        std.debug.assert(fits);
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

fn rejectionText(io: std.Io, output: *const ValidatedOutput, code: tool_proposal.Rejection, facts: *const tool_defs.CallFacts, name: OutputMetadataRecord, buffer: *[192]u8) ![]const u8 {
    var rejected_name: output_format.NameReader = .{ .io = io, .file = output.source, .position = name.start, .end = try name.end() };
    return tool_defs.rejectionResult(code, facts, &rejected_name, name.decoded_length, name.content_digest, buffer);
}

fn validateCandidate(io: std.Io, output: *const ValidatedOutput, purpose: ModelOperationKind) !void {
    var candidate_metadata = try OutputMetadataReader.init(io, output.metadata);
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

pub const SettleSuccess = struct {
    const named = .{
        .{ attempt_facts, error.OperationReadFailed },
        .{ success_facts, error.OperationReadFailed },
        .{ pending_messages, error.SessionStopReadFailed },
        .{ content_batch, error.OutputReadFailed },
        .{ content_batch_wide, error.OutputReadFailed },
        .{ duplicate_items, error.OutputReadFailed },
        .{ duplicate_items_wide, error.OutputReadFailed },
        .{ duplicate_calls, error.OutputReadFailed },
        .{ duplicate_calls_wide, error.OutputReadFailed },
        .{ historical_names, error.OutputReadFailed },
    };
    pub const rounds = transition.rounds(.{
        .facts = .{ .always, error.StatementFailed, named },
        .batch = .{ .paged, error.StatementFailed, named },
    });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const pass: transition.Pass = .wide;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct {
        io: std.Io,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
        batch: *Batch,
    };
    pub const Result = void;
    pub const Ordinary = store_core.Ordinary.model_success;
    pub const Guards = store_core.Ordinary.model_success;
    pub const Declined = error{};

    input: Input,
    facts: attempt_facts.Result = undefined,
    success: success_facts.Row = undefined,
    success_found: store_access.Found = .missing,
    pending: pending_messages.Result = undefined,
    oversized: Oversized = .{},
    settlement: Settlement = undefined,

    pub fn step(t: *SettleSuccess, r: *transition.Round(SettleSuccess), ran: ?rounds.At) !transition.Next(SettleSuccess) {
        switch (ran orelse return t.queueFacts(r)) {
            .facts => try t.settleFacts(r),
            .batch => try t.input.batch.checkReads(),
        }
        if (try t.settlement.advance(r, t.input.batch, &t.oversized)) return .{ .round = .batch };
        return t.finish(r);
    }

    pub fn committed(_: *const SettleSuccess) Result {}

    noinline fn queueFacts(t: *SettleSuccess, r: *transition.Round(SettleSuccess)) !transition.Next(SettleSuccess) {
        const batch = t.input.batch;
        const operation_id = t.input.binding.operation_id;
        t.success = .{ .tool_names = &batch.offered_names, .app_names = undefined };
        batch.pointOfferedApps(&t.success);
        r.read(attempt_facts, .{ .operation_id = operation_id, .closes = true }, &t.facts);
        r.readInto(success_facts, .{ .operation_id = operation_id }, &t.success, &t.success_found);
        r.read(pending_messages, .{ .operation_id = operation_id }, &t.pending);
        if (t.input.faults.settlement_trace) |trace| if (r.transactionOpen()) trace.mark(.transaction_active);
        collectItems(batch, t.input.output, t.input.io, 0, false, &t.oversized.cut);
        try batch.queueReads(r, operation_id, t.input.output, t.input.io);
        return .{ .round = .facts };
    }

    noinline fn settleFacts(t: *SettleSuccess, r: *transition.Round(SettleSuccess)) !void {
        const io = t.input.io;
        const output = t.input.output;
        const binding = t.input.binding;
        const row = try currentAttempt(&t.facts, binding);
        if (!t.success_found.get()) return error.CorruptStore;
        if (t.success.frozen_revision == null) return error.StaleAttemptBinding;
        if (t.success.invalid_owner) return error.CorruptStore;
        const purpose: ModelOperationKind = if (row.compaction) .compaction else .assistant_response;
        try validateCandidate(io, output, purpose);
        try t.input.batch.checkReads();

        const batch = t.input.batch;
        const positions = try r.positions(row.session);
        const first_item_position = try positions.take(output.item_count);
        const call_items = try OutputMetadataReader.init(io, output.metadata);
        t.settlement = .{
            .io = io,
            .binding = binding,
            .output = output,
            .faults = t.input.faults,
            .session = row.session,
            .positions = positions,
            .first_item_position = first_item_position,
            .purpose = purpose,
            .tools = .{ .names = batch.offered_names.slice(), .apps = batch.offeredAppText(), .historical_digests = &batch.identity_digests, .withdrawn = &batch.withdrawn },
            .settling = t.success,
            .call_items = call_items,
        };
        t.settlement.call_item = try t.settlement.call_items.nextItem();
    }

    noinline fn finish(t: *SettleSuccess, r: *transition.Round(SettleSuccess)) !transition.Next(SettleSuccess) {
        const s = &t.settlement;
        const row = &t.facts.?;
        const binding = s.binding;
        const output = s.output;
        const output_fact = turn_policy.outputFact(s.purpose, output.call_count);
        const usage = s.usage;
        resolve_success.queue(r, .{
            .operation_id = binding.operation_id,
            .resolution = @tagName(turn_policy.Resolution.of(output_fact)),
            .content_id = s.answer_id,
            .response_id = optionalText(output.response_id.slice()),
            .model_evidence = .{ .bytes = output.model_evidence.slice() },
            .request_id = optionalText(output.request_id.slice()),
            .item_count = output.item_count,
            .uncached = if (usage) |counts| counts.uncached else null,
            .cache_read = if (usage) |counts| counts.cache_read else null,
            .cache_write = if (usage) |counts| counts.cache_write else null,
            .output = if (usage) |counts| counts.output else null,
            .attempt_ordinal = binding.attempt_ordinal,
            .session = row.session,
        });
        if (turn_policy.completesTurn(output_fact, t.pending.pending)) {
            if (!row.turn_open) return error.StaleAttemptBinding;
            const answer = s.answer_id orelse return error.CorruptOutputMetadata;
            try turn_domain.queueCloseOr(r, s.positions, binding.turn_id, .{ .completed = @intCast(answer) }, error.StaleAttemptBinding);
        } else turn_domain.queueContinuation(r, binding.turn_id, row.session);
        if (s.faults.output_commit) return error.InjectedOutputCommitFailure;
        return .commit;
    }
};

const Oversized = struct {
    cut: ?u64 = null,
    paused: ?Paused = null,

    const Paused = struct {
        item_at: u64,
        region_start: u64,
        progress: ItemProgress,
    };
};

const ItemProgress = struct {
    offset: u64,
    part_count: u64 = 0,
    text_length: u64 = 0,
};

const ContentRow = struct { id: u64, fresh: bool };

const Settlement = struct {
    io: std.Io,
    binding: AttemptBinding,
    output: *const ValidatedOutput,
    faults: Faults,
    session: rsql.SessionHead,
    positions: *store_access.Positions,
    first_item_position: u64,
    purpose: ModelOperationKind,
    tools: tool_record.Offered,
    settling: success_facts.Row,
    imported_items: u64 = 0,
    imported_calls: u64 = 0,
    entries: u64 = 0,
    answer_id: ?u64 = null,
    usage_seen: bool = false,
    usage: ?output_format.Usage = null,
    call_items: OutputMetadataReader,
    call_item: ?OutputMetadataRecord = null,

    fn advance(s: *Settlement, a: anytype, batch: *Batch, oversized: *Oversized) !bool {
        while (true) {
            switch (batch.kind) {
                .items => {
                    try s.writeItems(a, batch, oversized);
                    if (oversized.paused) |paused| {
                        collectItems(batch, s.output, s.io, paused.progress.offset, true, &oversized.cut);
                    } else if (batch.last) {
                        try s.itemsDone();
                        oversized.cut = null;
                        collectCalls(batch, s.output, s.io, 0, &s.tools);
                    } else collectItems(batch, s.output, s.io, batch.end, false, &oversized.cut);
                },
                .calls => {
                    try s.writeCalls(a, batch);
                    if (batch.last) break;
                    collectCalls(batch, s.output, s.io, batch.end, &s.tools);
                },
            }
            if (batch.identity_count != 0 or batch.digest_count != 0) {
                try batch.queueReads(a, s.binding.operation_id, s.output, s.io);
                return true;
            }
        }
        if (s.imported_calls != s.output.call_count) return error.CorruptOutputMetadata;
        return false;
    }

    fn itemsDone(s: *Settlement) !void {
        if (s.imported_items != s.output.item_count) return error.CorruptOutputMetadata;
        if (s.purpose == .assistant_response and s.output.answer_length != 0 and s.answer_id == null) return error.CorruptOutputMetadata;
    }

    fn content(a: anytype, batch: *Batch, imported: content_domain.Import) !ContentRow {
        const identity = batch.find(&imported) orelse return error.OutputSourceChanged;
        if (identity.row.content_id != 0) return .{ .id = identity.row.content_id, .fresh = false };
        const id = try content_domain.insertRow(a, &imported);
        identity.row.content_id = @intCast(id);
        return .{ .id = id, .fresh = true };
    }

    fn sinkFor(a: anytype, row: ContentRow, length: u64) !?store_access.ContentSink {
        if (!row.fresh or length == 0) return null;
        return try a.contentSink(row.id, length);
    }

    noinline fn writeItems(s: *Settlement, a: anytype, batch: *Batch, oversized: *Oversized) !void {
        if (oversized.paused != null) return s.resumeItem(a, batch, oversized);
        var reader = try OutputMetadataReader.init(s.io, s.output.metadata);
        reader.offset = batch.start;
        var region_start = batch.start;
        var index: u8 = 0;
        while (reader.offset < batch.end) {
            const record_start = reader.offset;
            const record = try reader.next() orelse break;
            if (record.tag == .usage) {
                if (s.usage_seen) return error.CorruptOutputMetadata;
                s.usage_seen = true;
                s.usage = record.usage;
                continue;
            }
            if (record.tag != .item) continue;
            defer region_start = reader.offset;
            if (record.ordinal != s.imported_items) return error.CorruptOutputMetadata;
            if (index == batch.digest_count) return error.CorruptOutputMetadata;
            if (batch.duplicate(index)) return error.InvalidProviderEnvelope;
            var description: tool_record.Description = .{};
            var progress: ItemProgress = .{ .offset = region_start };
            const neutral = try s.importItem(a, batch, record, region_start, reader.offset, &progress, oversized.cut, &description) orelse {
                oversized.paused = .{ .item_at = record_start, .region_start = region_start, .progress = progress };
                return;
            };
            try s.recordItem(a, batch, record, batch.ids.digests[index], neutral, &description);
            index += 1;
        }
        if (batch.stopped) |err| return err;
    }

    fn resumeItem(s: *Settlement, a: anytype, batch: *Batch, oversized: *Oversized) !void {
        if (batch.stopped) |err| return err;
        const paused = &oversized.paused.?;
        var reader = try OutputMetadataReader.init(s.io, s.output.metadata);
        reader.offset = paused.item_at;
        const record = try reader.next() orelse return error.CorruptOutputMetadata;
        var description: tool_record.Description = .{};
        const neutral = try s.importItem(a, batch, record, paused.region_start, reader.offset, &paused.progress, oversized.cut, &description) orelse return;
        oversized.paused = null;
        try s.recordItem(a, batch, record, record.id_digest, neutral, &description);
    }

    fn recordItem(s: *Settlement, a: anytype, batch: *Batch, record: OutputMetadataRecord, id_digest: [32]u8, neutral: ImportedNeutral, description: *const tool_record.Description) !void {
        a.write(insert_item, .{
            .operation_id = s.binding.operation_id,
            .item_ordinal = record.ordinal,
            .session = s.session,
            .position = s.first_item_position + s.imported_items,
            .kind = @backingInt(record.kind),
            .attempt_ordinal = s.binding.attempt_ordinal,
            .id_digest = id_digest,
            .omits_reasoning_text = record.omit_reasoning_text,
            .phase = @backingInt(record.phase),
            .extras_content_id = neutral.bag,
            .part_count = neutral.part_count,
            .message_content_id = neutral.text,
            .description = if (neutral.described and description.len != 0) description.* else null,
            .call_failed = neutral.call_failed,
        });
        s.imported_items += 1;
        if (s.purpose != .assistant_response or record.kind != .message) return;
        const text = neutral.text.?;
        if (s.output.answer_item_ordinal == record.ordinal) {
            const empty = &content_domain.empty_content;
            const answer: ContentRow = if (s.output.answer_length == 0) try content(a, batch, empty.*) else .{ .id = text, .fresh = false };
            const length, const digest = if (s.output.answer_length == 0) .{ empty.length, &empty.digest } else .{ neutral.text_length, &neutral.text_digest };
            if (length != s.output.answer_length or !std.mem.eql(u8, digest, &s.output.answer_digest)) return error.OutputSourceChanged;
            s.answer_id = answer.id;
        }
        s.entries += 1;
        a.write(insert_entry, .{
            .session = s.session,
            .ordinal = s.settling.entry_base + s.entries,
            .position = s.first_item_position + record.ordinal,
            .turn_id = s.binding.turn_id,
            .operation_id = s.binding.operation_id,
            .item_ordinal = record.ordinal,
            .content_id = text,
        });
    }

    fn importItem(s: *Settlement, a: anytype, batch: *Batch, item: OutputMetadataRecord, metadata_start: u64, metadata_end: u64, progress: *ItemProgress, cut: ?u64, description: *tool_record.Description) !?ImportedNeutral {
        var metadata = try OutputMetadataReader.init(s.io, s.output.metadata);
        metadata.offset = progress.offset;
        metadata.length = metadata_end;
        var item_bag: ?u64 = null;
        var text: ?u64 = null;
        var text_record: ?OutputMetadataRecord = null;
        var text_length = progress.text_length;
        var part_count = progress.part_count;
        var part: ?struct { record: OutputMetadataRecord, start: u64, text: ?u64 } = null;
        var action: ?OutputMetadataRecord = null;
        var pattern: ?OutputMetadataRecord = null;
        while (true) {
            if (cut) |at| if (metadata.offset == at) {
                std.debug.assert(part == null and item_bag == null and text == null and action == null);
                progress.* = .{ .offset = at, .part_count = part_count, .text_length = text_length };
                return null;
            };
            const record = try metadata.next() orelse break;
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
                            try s.importDecoded(a, batch, record),
                    };
                    part = .{ .record = record, .start = metadata.offset, .text = own_text };
                },
                .extras => switch (record.scope) {
                    .part => {
                        const pending = part orelse return error.CorruptOutputMetadata;
                        const bag = try s.importBag(a, batch, record, pending.start, metadata.offset);
                        a.write(insert_part, .{
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
                        item_bag = try s.importBag(a, batch, record, metadata_start, metadata.offset);
                    },
                },
                .text => {
                    if (item_bag == null or text != null or record.decoded_length != text_length) return error.CorruptOutputMetadata;
                    text = try s.importMessageText(a, batch, record, metadata_start, metadata.offset);
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

    fn importMessageText(s: *Settlement, a: anytype, batch: *Batch, text: OutputMetadataRecord, start: u64, end: u64) !u64 {
        const row = try content(a, batch, recordImport(&text).?);
        const sink = try sinkFor(a, row, text.decoded_length) orelse return row.id;
        defer sink.close();
        try streamMessageText(s.io, s.output, text, start, end, sink, s.faults);
        return row.id;
    }

    fn importBag(s: *Settlement, a: anytype, batch: *Batch, trailer: OutputMetadataRecord, start: u64, end: u64) !u64 {
        const row = try content(a, batch, recordImport(&trailer).?);
        const sink = try sinkFor(a, row, trailer.decoded_length);
        defer if (sink) |value| value.close();
        try streamBag(s.io, s.output, trailer, start, end, sink, s.faults);
        return row.id;
    }

    fn importDecoded(s: *Settlement, a: anytype, batch: *Batch, part: OutputMetadataRecord) !u64 {
        const row = try content(a, batch, recordImport(&part).?);
        const sink = try sinkFor(a, row, part.decoded_length) orelse return row.id;
        defer sink.close();
        try streamDecoded(s.io, s.output, part, sink, s.faults);
        return row.id;
    }

    noinline fn writeCalls(s: *Settlement, a: anytype, batch: *Batch) !void {
        var reader = try OutputMetadataReader.init(s.io, s.output.metadata);
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
                    try s.importCall(a, batch, index, .{ name, call_id, record });
                    name_record = null;
                    call_id_record = null;
                    index += 1;
                    s.imported_calls += 1;
                },
                else => {},
            }
        }
        if (batch.stopped) |err| return err;
        if (batch.last and (name_record != null or call_id_record != null)) return error.CorruptOutputMetadata;
    }

    fn importCall(s: *Settlement, a: anytype, batch: *Batch, index: u8, fields: [3]OutputMetadataRecord) !void {
        const name, const call_id, const record = fields;
        const name_content_id = try s.importDecoded(a, batch, name);
        const call_id_content_id = try s.importDecoded(a, batch, call_id);
        const arguments_content_id = try s.importDecoded(a, batch, record);
        if (batch.duplicate(index)) return error.InvalidProviderEnvelope;
        const call_facts = try inspectOutputCall(s.io, s.output.source, name, record, &s.tools);
        const rejection_code = tool_defs.classifyCall(&call_facts);
        const app_call = if (call_facts.tool) |tool| rejection_code == null and tool.owner == .app else false;
        const rejection_content_id: ?u64 = if (rejection_code) |code| id: {
            var buffer: [192]u8 = undefined;
            const text = try rejectionText(s.io, s.output, code, &call_facts, name, &buffer);
            if (s.faults.output_import) return error.InjectedContentImportFailure;
            const value: content_domain.Import = .ofBytes(text, false);
            const row = try content(a, batch, value);
            if (try sinkFor(a, row, value.length)) |sink| {
                defer sink.close();
                try sink.write(text, 0);
            }
            break :id row.id;
        } else null;
        const unserved_content_id: ?u64 = if (app_call) try s.unservedContent(a, batch) else null;
        try s.recordCall(a, &fields, .{ name_content_id, call_id_content_id, arguments_content_id }, &call_facts, rejection_code, rejection_content_id, unserved_content_id);
    }

    /// The result of an app call no app serves yet: imported once per Batch, the same way a rejection's text is.
    noinline fn unservedContent(s: *Settlement, a: anytype, batch: *Batch) !u64 {
        const text = tool_record.Runner.app.unservedText();
        if (s.faults.output_import) return error.InjectedContentImportFailure;
        const value: content_domain.Import = .ofBytes(text, false);
        const row = try content(a, batch, value);
        if (try sinkFor(a, row, value.length)) |sink| {
            defer sink.close();
            try sink.write(text, 0);
        }
        return row.id;
    }

    noinline fn recordCall(s: *Settlement, a: anytype, fields: *const [3]OutputMetadataRecord, content_ids: [3]u64, call_facts: *const tool_defs.CallFacts, rejection_code: ?tool_proposal.Rejection, rejection_content_id: ?u64, unserved_content_id: ?u64) !void {
        const record = fields[2];
        const name_content_id, const call_id_content_id, const arguments_content_id = content_ids;
        var field_metadata: FieldCertificate.Bytes = undefined;
        for (fields.*, 0..) |field, at| FieldCertificate.write(&field_metadata, at, .{ .length = field.decoded_length, .digest = field.content_digest });
        const description = try callDescription(call_facts, s.io, s.output.source, record);

        a.write(insert_call, .{
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
            .description = description,
            .field_metadata = field_metadata,
            .session = s.session,
        });
        if (rejection_code != null) return;
        // An app call resolves at once, so it needs no approval.
        const authorized = call_facts.tool.?.runner() == .core or s.settling.permission_mode or unserved_content_id != null;
        const action_id = try a.identity(.action_id);
        a.write(insert_action, .{
            .action_id = action_id,
            .operation_id = s.binding.operation_id,
            .call_ordinal = s.imported_calls,
            .session = s.session,
            .revision = s.settling.revision.get(),
            .authorized = authorized,
            .timeout_ms = if (call_facts.bashArguments()) |arguments| arguments.timeout_ms else null,
            .approval_position = if (authorized) null else s.first_item_position + record.ordinal,
        });
        if (unserved_content_id) |content_id| {
            try action_domain.queueResolution(a, .{ .action_id = action_id, .parent_operation_id = s.binding.operation_id, .turn_id = s.binding.turn_id }, s.session, .failed, content_id);
            return;
        }
        if (!authorized) try forward_domain.queue(a, &s.session.ref, &s.session.ref, .approval, action_id);
    }
};

const ImportedNeutral = struct { bag: u64, part_count: u64, text: ?u64, text_length: u64, text_digest: [32]u8, described: bool, call_failed: bool };

noinline fn describeWebSearch(io: std.Io, source: std.Io.File, call: OutputMetadataRecord, pattern: ?OutputMetadataRecord) !tool_record.Description {
    var target: [tool_defs.WebSearchCall.excerpt_bytes]u8 = undefined;
    var found: [tool_defs.WebSearchCall.excerpt_bytes]u8 = undefined;
    return tool_defs.describe(.{ .web_search = .{
        .action = @fromBackingInt(@backingInt(call.action)),
        .target = try excerpt(io, source, call, &target),
        .pattern = if (pattern) |field| try excerpt(io, source, field, &found) else "",
    } });
}

fn excerpt(io: std.Io, source: std.Io.File, record: OutputMetadataRecord, buffer: []u8) ![]const u8 {
    var reader: output_format.NameReader = .{ .io = io, .file = source, .position = record.start, .end = try record.end() };
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) buffer[length] = try reader.next() orelse break;
    return buffer[0..length];
}

fn writeChecked(sink: ?store_access.ContentSink, hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8, written: *u64, length: u64) !void {
    if (bytes.len > length - written.*) return error.OutputSourceChanged;
    hash.update(bytes);
    if (sink) |value| try value.write(bytes, written.*);
    written.* += bytes.len;
}

noinline fn streamBag(io: std.Io, output: *const ValidatedOutput, trailer: OutputMetadataRecord, start: u64, end: u64, sink: ?store_access.ContentSink, faults: Faults) !void {
    var members = try OutputMetadataReader.init(io, output.metadata);
    members.offset = start;
    members.length = end;
    var copy: content_domain.HashedWindow(import_window_bytes) = .{ .hash = content_string.hasher() };
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

noinline fn streamMessageText(io: std.Io, output: *const ValidatedOutput, text: OutputMetadataRecord, start: u64, end: u64, sink: store_access.ContentSink, faults: Faults) !void {
    var parts = try OutputMetadataReader.init(io, output.metadata);
    parts.offset = start;
    parts.length = end;
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = content_string.hasher() };
    var written: u64 = 0;
    while (try parts.next()) |part| {
        if (part.tag != .part or (part.part_kind != .output_text and part.part_kind != .refusal)) continue;
        try writeDecoded(io, output, sink, &decoded, part, &written, text.decoded_length);
        if (faults.output_import) return error.InjectedOutputImportFailure;
    }
    if (written != text.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &text.content_digest)) return error.OutputSourceChanged;
}

noinline fn streamDecoded(io: std.Io, output: *const ValidatedOutput, part: OutputMetadataRecord, sink: store_access.ContentSink, faults: Faults) !void {
    var decoded: content_domain.HashedWindow(import_window_bytes) = .{ .hash = content_string.hasher() };
    var written: u64 = 0;
    try writeDecoded(io, output, sink, &decoded, part, &written, part.decoded_length);
    if (faults.output_import) return error.InjectedOutputImportFailure;
    if (written != part.decoded_length or !std.mem.eql(u8, &decoded.hash.finalResult(), &part.content_digest)) return error.OutputSourceChanged;
}

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

noinline fn callDescription(facts: *const tool_defs.CallFacts, io: std.Io, file: std.Io.File, arguments: OutputMetadataRecord) !?tool_record.Description {
    if (facts.tool) |*tool| if (tool.runner() == .mcp) {
        var fallback: tool_record.Description = .{ .len = 0 };
        try fallback.set(tool.name);
        if (facts.invalid_mcp_arguments) return fallback;
        var source: output_format.JsonStringSource = .{
            .encoded = .{ .io = io, .file = file, .position = arguments.start, .end = try arguments.end() },
        };
        const range = try mcp_arguments.descriptionRange(&source) orelse return fallback;
        source = .{ .encoded = .{ .io = io, .file = file, .position = arguments.start, .end = try arguments.end() } };
        for (0..@intCast(range.start)) |_| _ = try source.take();
        var encoded: [6 * tool_presentation.max_description_bytes]u8 = undefined;
        if (range.length > encoded.len) return error.CorruptOutputMetadata;
        const contents = encoded[0..@intCast(range.length)];
        for (contents) |*byte| byte.* = try source.take();
        var description: tool_record.Description = .{ .len = 0 };
        var decoded = std.Io.Writer.fixed(&description.bytes);
        try mcp_document.writeDecoded(&decoded, contents);
        description.len = decoded.end;
        return if (tool_presentation.ToolPresentation.validDescription(description.slice())) description else fallback;
    };
    return facts.description();
}

noinline fn inspectOutputCall(io: std.Io, source: std.Io.File, name: OutputMetadataRecord, arguments: OutputMetadataRecord, offered: *const tool_record.Offered) !tool_defs.CallFacts {
    var call_name: output_format.NameReader = .{ .io = io, .file = source, .position = name.start, .end = try name.end() };
    var encoded: output_format.JsonStringSource = .{
        .encoded = .{ .io = io, .file = source, .position = arguments.start, .end = try arguments.end() },
    };
    return tool_defs.inspectCall(&call_name, name.decoded_length, &encoded, offered);
}

pub fn validateJsonBytes(bytes: []const u8) !bool {
    var scanner = std.json.Scanner.initCompleteInput(std.heap.c_allocator, bytes);
    defer scanner.deinit();
    try scanner.ensureTotalStackCapacity(@import("../../json_limits.zig").max_depth);
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => return false,
            else => return err,
        };
        if (scanner.stackHeight() > @import("../../json_limits.zig").max_depth) return false;
        if (token == .end_of_document) return true;
    }
}

pub noinline fn validateJsonFile(io: std.Io, file: std.Io.File) !bool {
    var read_buffer: [@import("../../conversation_read.zig").content_window_bytes]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var json_reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer json_reader.deinit();
    try json_reader.ensureTotalStackCapacity(@import("../../json_limits.zig").max_depth);
    while (true) {
        const token = json_reader.next() catch |err| switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => return false,
            else => return err,
        };
        if (json_reader.stackHeight() > @import("../../json_limits.zig").max_depth) return false;
        if (token == .end_of_document) return true;
    }
}
