const std = @import("std");
const binding = @import("binding.zig");
const conversation = @import("conversation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("fcntl.h");
    @cInclude("sys/file.h");
    @cInclude("unistd.h");
});

pub const schema_version: u32 = 19;
pub const application_id: u32 = 0x4f4e5047;
pub const max_path_bytes: usize = 1024;
pub const max_text_bytes: usize = 1024 * 1024;
pub const max_conversation_window: usize = 256;

const schema =
    \\CREATE TABLE content (
    \\    content_id INTEGER PRIMARY KEY CHECK (content_id > 0),
    \\    byte_length INTEGER NOT NULL CHECK (byte_length BETWEEN 1 AND 1048576),
    \\    digest BLOB NOT NULL CHECK (length(digest) = 32),
    \\    payload BLOB NOT NULL CHECK (length(payload) = byte_length)
    \\) STRICT;
    \\CREATE TABLE session (
    \\    session_id INTEGER PRIMARY KEY CHECK (session_id > 0),
    \\    workspace_path TEXT NOT NULL CHECK (length(workspace_path) BETWEEN 1 AND 1024),
    \\    access_scope_digest BLOB NOT NULL CHECK (length(access_scope_digest) = 32)
    \\) STRICT;
    \\CREATE TABLE turn (
    \\    turn_id INTEGER PRIMARY KEY CHECK (turn_id > 0),
    \\    session_id INTEGER NOT NULL,
    \\    turn_ordinal INTEGER NOT NULL CHECK (turn_ordinal > 0),
    \\    admission_digest BLOB NOT NULL CHECK (length(admission_digest) = 32),
    \\    initial_entry_id INTEGER NOT NULL CHECK (initial_entry_id > 0),
    \\    outcome_kind INTEGER CHECK (outcome_kind IS NULL OR outcome_kind BETWEEN 1 AND 3),
    \\    outcome_content_id INTEGER,
    \\    failure_code INTEGER,
    \\    UNIQUE (session_id, turn_ordinal),
    \\    UNIQUE (session_id, turn_id),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (outcome_content_id) REFERENCES content (content_id),
    \\    FOREIGN KEY (turn_id, initial_entry_id) REFERENCES conversation_entry (turn_id, entry_id)
    \\        DEFERRABLE INITIALLY DEFERRED,
    \\    CHECK ((outcome_kind IS NULL AND outcome_content_id IS NULL AND failure_code IS NULL) OR
    \\           (outcome_kind = 1 AND outcome_content_id IS NOT NULL AND failure_code IS NULL) OR
    \\           (outcome_kind = 2 AND outcome_content_id IS NOT NULL AND failure_code IS NOT NULL) OR
    \\           (outcome_kind = 3 AND outcome_content_id IS NULL AND failure_code IS NULL))
    \\) STRICT;
    \\CREATE UNIQUE INDEX one_nonterminal_turn_per_session
    \\ON turn (session_id) WHERE outcome_kind IS NULL;
    \\CREATE TABLE operation (
    \\    operation_id INTEGER PRIMARY KEY CHECK (operation_id > 0),
    \\    session_id INTEGER NOT NULL,
    \\    turn_id INTEGER NOT NULL,
    \\    operation_ordinal INTEGER NOT NULL CHECK (operation_ordinal > 0),
    \\    kind INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 3),
    \\    descriptor_content_id INTEGER NOT NULL,
    \\    descriptor_digest BLOB NOT NULL CHECK (length(descriptor_digest) = 32),
    \\    caused_by_entry_id INTEGER,
    \\    caused_by_entry_kind INTEGER GENERATED ALWAYS AS (
    \\        CASE WHEN caused_by_entry_id IS NULL THEN NULL ELSE 3 END
    \\    ) STORED,
    \\    UNIQUE (turn_id, operation_ordinal),
    \\    UNIQUE (turn_id, operation_id),
    \\    UNIQUE (session_id, turn_id, operation_id),
    \\    UNIQUE (operation_id, descriptor_content_id),
    \\    UNIQUE (caused_by_entry_id),
    \\    FOREIGN KEY (session_id, turn_id) REFERENCES turn (session_id, turn_id),
    \\    FOREIGN KEY (descriptor_content_id) REFERENCES content (content_id),
    \\    FOREIGN KEY (turn_id, caused_by_entry_id) REFERENCES conversation_entry (turn_id, entry_id),
    \\    FOREIGN KEY (
    \\        session_id, turn_id, caused_by_entry_id, caused_by_entry_kind
    \\    ) REFERENCES conversation_entry (
    \\        session_id, turn_id, entry_id, kind
    \\    ),
    \\    CHECK ((kind = 1 AND caused_by_entry_id IS NULL) OR
    \\           (kind IN (2, 3) AND caused_by_entry_id IS NOT NULL))
    \\) STRICT;
    \\CREATE TABLE conversation_entry (
    \\    session_id INTEGER NOT NULL,
    \\    revision INTEGER NOT NULL CHECK (revision > 0),
    \\    entry_id INTEGER NOT NULL CHECK (entry_id > 0),
    \\    turn_id INTEGER NOT NULL,
    \\    kind INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 4),
    \\    content_id INTEGER NOT NULL,
    \\    source_operation_id INTEGER,
    \\    call_ordinal INTEGER,
    \\    PRIMARY KEY (session_id, revision),
    \\    UNIQUE (entry_id),
    \\    UNIQUE (session_id, entry_id),
    \\    UNIQUE (turn_id, entry_id),
    \\    UNIQUE (session_id, turn_id, entry_id, kind),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (session_id, turn_id) REFERENCES turn (session_id, turn_id),
    \\    FOREIGN KEY (content_id) REFERENCES content (content_id),
    \\    FOREIGN KEY (turn_id, source_operation_id) REFERENCES operation (turn_id, operation_id),
    \\    CHECK ((kind = 1 AND source_operation_id IS NULL AND call_ordinal IS NULL) OR
    \\           (kind = 2 AND source_operation_id IS NOT NULL AND call_ordinal IS NULL) OR
    \\           (kind IN (3, 4) AND source_operation_id IS NOT NULL AND call_ordinal >= 0))
    \\) STRICT, WITHOUT ROWID;
    \\CREATE UNIQUE INDEX one_tool_result_per_action
    \\ON conversation_entry (source_operation_id) WHERE kind = 4;
    \\CREATE UNIQUE INDEX one_call_ordinal_per_model
    \\ON conversation_entry (source_operation_id, call_ordinal) WHERE kind = 3;
    \\CREATE TABLE attempt (
    \\    attempt_id INTEGER PRIMARY KEY CHECK (attempt_id > 0),
    \\    operation_id INTEGER NOT NULL,
    \\    attempt_ordinal INTEGER NOT NULL CHECK (attempt_ordinal > 0),
    \\    dispatch_content_id INTEGER NOT NULL,
    \\    dispatch_digest BLOB NOT NULL CHECK (length(dispatch_digest) = 32),
    \\    parameters_content_id INTEGER NOT NULL,
    \\    context_cutoff_revision INTEGER NOT NULL CHECK (context_cutoff_revision >= 0),
    \\    workspace_digest BLOB NOT NULL CHECK (length(workspace_digest) = 32),
    \\    external_idempotency_key TEXT,
    \\    possible_duplicate INTEGER NOT NULL CHECK (possible_duplicate IN (0, 1)),
    \\    UNIQUE (operation_id, attempt_ordinal),
    \\    UNIQUE (operation_id, attempt_id),
    \\    FOREIGN KEY (operation_id) REFERENCES operation (operation_id),
    \\    FOREIGN KEY (operation_id, dispatch_content_id)
    \\        REFERENCES operation (operation_id, descriptor_content_id),
    \\    FOREIGN KEY (dispatch_content_id) REFERENCES content (content_id),
    \\    FOREIGN KEY (parameters_content_id) REFERENCES content (content_id),
    \\    CHECK (external_idempotency_key IS NULL OR length(external_idempotency_key) BETWEEN 1 AND 256)
    \\) STRICT;
    \\CREATE TABLE attempt_completion (
    \\    completion_id INTEGER PRIMARY KEY CHECK (completion_id > 0),
    \\    operation_id INTEGER NOT NULL,
    \\    attempt_id INTEGER NOT NULL,
    \\    completion_ordinal INTEGER NOT NULL CHECK (completion_ordinal > 0),
    \\    evidence_kind INTEGER NOT NULL CHECK (evidence_kind BETWEEN 1 AND 3),
    \\    evidence_content_id INTEGER NOT NULL,
    \\    evidence_digest BLOB NOT NULL CHECK (length(evidence_digest) = 32),
    \\    UNIQUE (attempt_id, completion_ordinal),
    \\    UNIQUE (attempt_id, completion_id),
    \\    UNIQUE (operation_id, completion_id),
    \\    FOREIGN KEY (operation_id, attempt_id) REFERENCES attempt (operation_id, attempt_id),
    \\    FOREIGN KEY (evidence_content_id) REFERENCES content (content_id)
    \\) STRICT;
    \\CREATE TABLE operation_resolution (
    \\    operation_id INTEGER PRIMARY KEY,
    \\    resolution_kind INTEGER NOT NULL CHECK (resolution_kind BETWEEN 1 AND 7),
    \\    completion_id INTEGER,
    \\    result_content_id INTEGER NOT NULL,
    \\    result_digest BLOB NOT NULL CHECK (length(result_digest) = 32),
    \\    FOREIGN KEY (operation_id) REFERENCES operation (operation_id),
    \\    FOREIGN KEY (operation_id, completion_id)
    \\        REFERENCES attempt_completion (operation_id, completion_id),
    \\    FOREIGN KEY (result_content_id) REFERENCES content (content_id)
    \\) STRICT;
;

pub const Digest = binding.Sha256;

pub const SemanticDomain = enum {
    access_scope,
    turn,
    operation,
    dispatch,
    workspace,
    completion,
    resolution,

    fn name(self: SemanticDomain) []const u8 {
        return switch (self) {
            .access_scope => "access-scope",
            .turn => "turn",
            .operation => "operation",
            .dispatch => "dispatch",
            .workspace => "workspace",
            .completion => "completion",
            .resolution => "resolution",
        };
    }
};

pub const TurnOutcome = enum(u8) {
    completed = 1,
    failed = 2,
    cancelled = 3,
};

pub const TurnCondition = enum {
    runnable,
    in_flight,
    completed,
    failed,
    cancelled,
};

pub const AdmissionResult = enum { admitted, replay };

pub const AdmitTurn = struct {
    session_id: u64,
    turn_id: u64,
    turn_ordinal: u32,
    entry_id: u64,
    content_id: u64,
    expected_conversation_revision: u64,
    workspace_path: []const u8,
    access_scope_digest: Digest,
    admission_digest: Digest,
    user_text: []const u8,
};

pub const DecisionSnapshot = struct {
    session_id: u64,
    turn_id: u64,
    conversation_revision: u64,
    outcome: ?TurnOutcome,
    unresolved_external_attempts: u16,
};

pub fn classify(snapshot: DecisionSnapshot) TurnCondition {
    if (snapshot.outcome) |outcome| return switch (outcome) {
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
    };
    if (snapshot.unresolved_external_attempts != 0) return .in_flight;
    return .runnable;
}

pub const ConversationKind = enum(u8) {
    user_text = 1,
    assistant_text = 2,
    tool_call = 3,
    tool_result = 4,
};

pub const ConversationEntry = struct {
    revision: u64,
    entry_id: u64,
    turn_id: u64,
    kind: ConversationKind,
    content_id: u64,
    source_operation_id: ?u64,
    call_ordinal: ?u16,
};

pub const OperationKind = enum(u8) {
    model = 1,
    bash = 2,
    apply_patch = 3,
};

pub const EvidenceKind = enum(u8) {
    success = 1,
    failure = 2,
    uncertain = 3,
};

pub const ResolutionKind = enum(u8) {
    success = 1,
    failure = 2,
    denied = 3,
    indeterminate = 4,
    cancelled = 5,
    model_tool_calls = 6,
    final_answer = 7,
};

pub const AdmitOperation = struct {
    turn_id: u64,
    operation_id: u64,
    operation_ordinal: u32,
    kind: OperationKind,
    descriptor_content_id: u64,
    descriptor: []const u8,
    descriptor_digest: Digest,
};

pub const AdmitAttempt = struct {
    operation_id: u64,
    attempt_id: u64,
    attempt_ordinal: u32,
    dispatch_content_id: u64,
    dispatch_request: []const u8,
    dispatch_digest: Digest,
    parameters_content_id: u64,
    parameters: []const u8,
    context_cutoff_revision: u64,
    workspace_digest: Digest,
    external_idempotency_key: ?[]const u8,
    possible_duplicate: bool = false,
};

pub const CompleteAndResolve = struct {
    operation_id: u64,
    attempt_id: u64,
    completion_id: u64,
    completion_ordinal: u32,
    evidence_kind: EvidenceKind,
    completion_content_id: u64,
    completion_content: []const u8,
    completion_digest: Digest,
    resolution_kind: ResolutionKind,
    result_content_id: u64,
    result_content: []const u8,
    resolution_digest: Digest,
};

pub const RecordCompletion = struct {
    operation_id: u64,
    attempt_id: u64,
    completion_id: u64,
    completion_ordinal: u32,
    evidence_kind: EvidenceKind,
    content_id: u64,
    content: []const u8,
    completion_digest: Digest,
};

pub const CompletionRecord = struct {
    operation_id: u64,
    attempt_id: u64,
    completion_id: u64,
    completion_ordinal: u32,
    evidence_kind: EvidenceKind,
    content_id: u64,
    digest: Digest,
};

pub const ResolveWithoutCompletion = struct {
    operation_id: u64,
    resolution_kind: ResolutionKind,
    content_id: u64,
    content: []const u8,
    resolution_digest: Digest,
};

pub const SettleTurn = struct {
    turn_id: u64,
    outcome: TurnOutcome,
    failure_content_id: ?u64 = null,
    failure_message: ?[]const u8 = null,
    failure_code: ?u16 = null,
};

pub const ToolCallCandidate = struct {
    entry_id: u64,
    content_id: u64,
    content: []const u8,
    action_operation_id: u64,
    action_operation_ordinal: u32,
    action_kind: OperationKind,
    descriptor_content_id: u64,
    descriptor: []const u8,
    descriptor_digest: Digest,
};

pub const AdmitModelToolCalls = struct {
    turn_id: u64,
    model_operation_id: u64,
    attempt_id: u64,
    completion_id: u64,
    completion_content_id: u64,
    captured_output: []const u8,
    completion_digest: Digest,
    expected_conversation_revision: u64,
    calls: []const ToolCallCandidate,
};

pub const ToolResultCandidate = struct {
    action_operation_id: u64,
    entry_id: u64,
};

pub const AppendToolResults = struct {
    turn_id: u64,
    parent_model_operation_id: u64,
    expected_conversation_revision: u64,
    results: []const ToolResultCandidate,
};

pub const CompleteTurn = struct {
    turn_id: u64,
    model_operation_id: u64,
    attempt_id: u64,
    completion_id: u64,
    completion_content_id: u64,
    final_entry_id: u64,
    final_content_id: u64,
    captured_output: []const u8,
    final_answer: []const u8,
    completion_digest: Digest,
    expected_conversation_revision: u64,
};

pub const FailTurnFromCompletion = struct {
    turn_id: u64,
    completion: CompleteAndResolve,
    failure_code: u16,
};

pub const FailTurnWithoutCompletion = struct {
    turn_id: u64,
    operation_id: u64,
    result_content_id: u64,
    message: []const u8,
    failure_code: u16,
};

pub const OperationView = struct {
    operation_id: u64,
    operation_ordinal: u32,
    kind: OperationKind,
    caused_by_operation_id: ?u64,
    call_ordinal: ?u16,
};

pub const PendingToolResult = struct {
    parent_model_operation_id: u64,
    action_operation_id: u64,
    call_ordinal: u16,
};

pub const OperationRecord = struct {
    session_id: u64,
    turn_id: u64,
    operation_id: u64,
    operation_ordinal: u32,
    kind: OperationKind,
    descriptor_content_id: u64,
    descriptor_digest: Digest,
    caused_by_operation_id: ?u64,
    caused_by_entry_id: ?u64,
    call_ordinal: ?u16,
};

pub const SessionRecord = struct {
    session_id: u64,
    conversation_revision: u64,
    active_turn_id: ?u64,
    latest_turn_id: ?u64,
};

pub const TurnRecord = struct {
    session_id: u64,
    turn_id: u64,
    turn_ordinal: u32,
    outcome: ?TurnOutcome,
    outcome_content_id: ?u64,
    failure_code: ?u16,
};

pub const CrashPoint = enum {
    after_turn_row,
    before_turn_commit,
    after_turn_commit,
    before_operation_commit,
    after_operation_commit,
    before_attempt_commit,
    after_attempt_commit,
    after_completion_row,
    after_completion_commit,
    before_resolution_commit,
    after_resolution_commit,
    after_final_entry,
    after_failure_resolution,
    before_turn_settlement_commit,
    after_turn_settlement_commit,
    before_turn_outcome_commit,
    after_turn_outcome_commit,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reach_fn: *const fn (*anyopaque, CrashPoint) anyerror!void,

    fn reach(self: FaultHook, point: CrashPoint) !void {
        try self.reach_fn(self.context, point);
    }
};

pub fn semanticDigest(domain: SemanticDomain, bytes: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("onepage-relational-v1\x00");
    hasher.update(domain.name());
    hasher.update("\x00");
    hasher.update(bytes);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub const Store = struct {
    database: *c.sqlite3,
    lock_fd: c_int,
    open_: bool = true,
    fault_hook: ?FaultHook = null,

    pub fn setFaultHook(self: *Store, hook: ?FaultHook) void {
        self.fault_hook = hook;
    }

    pub fn open(path: []const u8) !Store {
        if (path.len == 0 or path.len > max_path_bytes) return error.InvalidHostStorePath;
        const lock_fd = try acquireHostLock(path);
        errdefer releaseHostLock(lock_fd);
        var terminated: [max_path_bytes:0]u8 = undefined;
        @memcpy(terminated[0..path.len], path);
        terminated[path.len] = 0;
        var maybe_database: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE |
            c.SQLITE_OPEN_NOMUTEX | c.SQLITE_OPEN_PRIVATECACHE;
        const result = c.sqlite3_open_v2(&terminated, &maybe_database, flags, null);
        if (result != c.SQLITE_OK) {
            if (maybe_database) |database| _ = c.sqlite3_close_v2(database);
            return mapSqliteError(result);
        }
        const database = maybe_database orelse return error.HostStoreOpenFailed;
        errdefer std.debug.assert(c.sqlite3_close_v2(database) == c.SQLITE_OK);
        var store: Store = .{ .database = database, .lock_fd = lock_fd };
        try store.execute("PRAGMA foreign_keys=ON");
        try store.execute("PRAGMA journal_mode=WAL");
        try store.execute("PRAGMA synchronous=FULL");
        try store.execute("PRAGMA busy_timeout=0");
        const app_id = try store.pragmaU64("PRAGMA application_id");
        const version = try store.pragmaU64("PRAGMA user_version");
        const empty = app_id == 0 and version == 0 and try store.schemaIsEmpty();
        if (empty) {
            try store.execute("BEGIN IMMEDIATE");
            errdefer store.rollback();
            try store.execute(schema);
            try store.execute("PRAGMA application_id=1330532423");
            try store.execute("PRAGMA user_version=19");
            try store.execute("COMMIT");
        } else if (app_id != application_id or version != schema_version) {
            return error.UnsupportedHostStoreVersion;
        }
        if (try store.pragmaU64("PRAGMA foreign_keys") != 1) return error.ForeignKeysDisabled;
        if (try store.pragmaU64("PRAGMA synchronous") != 2) return error.InvalidSynchronousMode;
        return store;
    }

    pub fn close(self: *Store) void {
        if (!self.open_) return;
        std.debug.assert(c.sqlite3_close_v2(self.database) == c.SQLITE_OK);
        releaseHostLock(self.lock_fd);
        self.open_ = false;
    }

    pub fn admitTurn(self: *Store, command: AdmitTurn) !AdmissionResult {
        try validateAdmitTurn(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();

        if (try self.turnExists(command.turn_id)) {
            if (!try self.turnReplayMatches(command)) return error.TurnConflict;
            try self.execute("COMMIT");
            return .replay;
        }

        const session_exists = try self.sessionExists(command.session_id);
        if (!session_exists) {
            if (command.expected_conversation_revision != 0 or command.turn_ordinal != 1) {
                return error.SessionNotFound;
            }
            const insert_session = try self.prepare(
                "INSERT INTO session (session_id, workspace_path, access_scope_digest) VALUES (?1, ?2, ?3)",
            );
            defer finalize(insert_session);
            try bindU64(insert_session, 1, command.session_id);
            try bindText(insert_session, 2, command.workspace_path);
            try bindBlob(insert_session, 3, &command.access_scope_digest);
            try done(insert_session);
            try self.expectOneChange();
        } else {
            try self.validateSessionBinding(command);
        }

        const current_revision = try self.conversationRevision(command.session_id);
        if (current_revision != command.expected_conversation_revision) return error.StaleConversation;
        if (try self.hasActiveTurn(command.session_id)) return error.SessionBusy;
        if (try self.nextTurnOrdinal(command.session_id) != command.turn_ordinal) {
            return error.InvalidTurnOrdinal;
        }

        try self.insertContent(command.content_id, command.user_text);
        const insert_turn = try self.prepare(
            "INSERT INTO turn (turn_id, session_id, turn_ordinal, admission_digest, initial_entry_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        defer finalize(insert_turn);
        try bindU64(insert_turn, 1, command.turn_id);
        try bindU64(insert_turn, 2, command.session_id);
        try bindU64(insert_turn, 3, command.turn_ordinal);
        try bindBlob(insert_turn, 4, &command.admission_digest);
        try bindU64(insert_turn, 5, command.entry_id);
        try done(insert_turn);
        try self.expectOneChange();
        try self.reach(.after_turn_row);

        const insert_entry = try self.prepare(
            "INSERT INTO conversation_entry (session_id, revision, entry_id, turn_id, kind, content_id) VALUES (?1, ?2, ?3, ?4, 1, ?5)",
        );
        defer finalize(insert_entry);
        try bindU64(insert_entry, 1, command.session_id);
        try bindU64(insert_entry, 2, current_revision + 1);
        try bindU64(insert_entry, 3, command.entry_id);
        try bindU64(insert_entry, 4, command.turn_id);
        try bindU64(insert_entry, 5, command.content_id);
        try done(insert_entry);
        try self.expectOneChange();
        try self.reach(.before_turn_commit);
        try self.execute("COMMIT");
        try self.reach(.after_turn_commit);
        return .admitted;
    }

    pub fn admitOperation(self: *Store, command: AdmitOperation) !AdmissionResult {
        try validateOperation(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.existingOperation(command.operation_id)) |existing| {
            if (existing.turn_id != command.turn_id or
                existing.ordinal != command.operation_ordinal or
                existing.kind != command.kind or
                existing.descriptor_content_id != command.descriptor_content_id or
                !std.mem.eql(u8, &existing.digest, &command.descriptor_digest))
            {
                return error.OperationConflict;
            }
            try self.execute("COMMIT");
            return .replay;
        }
        try self.requireActiveTurn(command.turn_id);
        if (try self.nextOperationOrdinal(command.turn_id) != command.operation_ordinal) {
            return error.InvalidOperationOrdinal;
        }
        try self.insertContent(command.descriptor_content_id, command.descriptor);
        try self.insertOperation(.{
            .turn_id = command.turn_id,
            .operation_id = command.operation_id,
            .ordinal = command.operation_ordinal,
            .kind = command.kind,
            .descriptor_content_id = command.descriptor_content_id,
            .descriptor_digest = command.descriptor_digest,
        });
        try self.reach(.before_operation_commit);
        try self.execute("COMMIT");
        try self.reach(.after_operation_commit);
        return .admitted;
    }

    pub fn admitAttempt(
        self: *Store,
        command: AdmitAttempt,
    ) !AdmissionResult {
        try validateAttempt(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.attemptExists(command.attempt_id)) {
            if (!try self.attemptReplayMatches(command)) return error.AttemptConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        const operation = try self.requireUnresolvedOperation(command.operation_id);
        if (command.dispatch_content_id != operation.descriptor_content_id) {
            return error.AttemptDispatchConflict;
        }
        if (try self.nextAttemptOrdinal(command.operation_id) != command.attempt_ordinal) {
            return error.InvalidAttemptOrdinal;
        }
        const revision = try self.conversationRevision(operation.session_id);
        if (command.context_cutoff_revision > revision) return error.FutureContextCutoff;
        try self.ensureContent(command.dispatch_content_id, command.dispatch_request);
        try self.insertContent(command.parameters_content_id, command.parameters);
        const statement = try self.prepare(
            \\INSERT INTO attempt (
            \\    attempt_id, operation_id, attempt_ordinal, dispatch_content_id,
            \\    dispatch_digest, parameters_content_id, context_cutoff_revision,
            \\    workspace_digest, external_idempotency_key, possible_duplicate
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.attempt_id);
        try bindU64(statement, 2, command.operation_id);
        try bindU64(statement, 3, command.attempt_ordinal);
        try bindU64(statement, 4, command.dispatch_content_id);
        try bindBlob(statement, 5, &command.dispatch_digest);
        try bindU64(statement, 6, command.parameters_content_id);
        try bindU64AllowZero(statement, 7, command.context_cutoff_revision);
        try bindBlob(statement, 8, &command.workspace_digest);
        if (command.external_idempotency_key) |key|
            try bindText(statement, 9, key)
        else
            try bindNull(statement, 9);
        try bindU64AllowZero(statement, 10, @intFromBool(command.possible_duplicate));
        try done(statement);
        try self.expectOneChange();
        try self.reach(.before_attempt_commit);
        try self.execute("COMMIT");
        try self.reach(.after_attempt_commit);
        return .admitted;
    }

    pub fn completeAndResolve(self: *Store, command: CompleteAndResolve) !AdmissionResult {
        try validateCompletion(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.resolutionExists(command.operation_id)) {
            if (!try self.resolutionReplayMatches(
                command.operation_id,
                command.resolution_kind,
                command.completion_id,
                command.result_content_id,
                command.resolution_digest,
            ) or !try self.completionReplayMatches(command)) return error.ResolutionConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        try self.requireAttemptForOperation(command.attempt_id, command.operation_id);
        try self.ensureContent(command.completion_content_id, command.completion_content);
        try self.insertContent(command.result_content_id, command.result_content);
        _ = try self.ensureCompletion(.{
            .completion_id = command.completion_id,
            .operation_id = command.operation_id,
            .attempt_id = command.attempt_id,
            .ordinal = command.completion_ordinal,
            .kind = command.evidence_kind,
            .content_id = command.completion_content_id,
            .digest = command.completion_digest,
        });
        try self.reach(.after_completion_row);
        try self.insertResolution(
            command.operation_id,
            command.resolution_kind,
            command.completion_id,
            command.result_content_id,
            command.resolution_digest,
        );
        try self.reach(.before_resolution_commit);
        try self.execute("COMMIT");
        try self.reach(.after_resolution_commit);
        return .admitted;
    }

    pub fn recordCompletion(self: *Store, command: RecordCompletion) !AdmissionResult {
        try validateRecordedCompletion(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.existingCompletion(command.completion_id)) |existing| {
            if (existing.operation_id != command.operation_id or
                existing.attempt_id != command.attempt_id or
                existing.ordinal != command.completion_ordinal or
                existing.kind != command.evidence_kind or
                existing.content_id != command.content_id or
                !std.mem.eql(u8, &existing.digest, &command.completion_digest))
            {
                return error.CompletionConflict;
            }
            try self.execute("COMMIT");
            return .replay;
        }
        try self.requireAttemptForOperation(command.attempt_id, command.operation_id);
        if (!try self.resolutionExists(command.operation_id) and
            try self.nextCompletionOrdinal(command.attempt_id) != 1)
        {
            return error.MultipleApplicableCompletions;
        }
        if (try self.nextCompletionOrdinal(command.attempt_id) != command.completion_ordinal) {
            return error.InvalidCompletionOrdinal;
        }
        try self.insertContent(command.content_id, command.content);
        try self.insertCompletion(.{
            .completion_id = command.completion_id,
            .operation_id = command.operation_id,
            .attempt_id = command.attempt_id,
            .ordinal = command.completion_ordinal,
            .kind = command.evidence_kind,
            .content_id = command.content_id,
            .digest = command.completion_digest,
        });
        try self.execute("COMMIT");
        try self.reach(.after_completion_commit);
        return .admitted;
    }

    pub fn resolveWithoutCompletion(
        self: *Store,
        command: ResolveWithoutCompletion,
    ) !AdmissionResult {
        if (command.operation_id == 0 or command.content_id == 0 or
            command.content.len == 0 or command.content.len > max_text_bytes or
            !std.mem.eql(u8, &command.resolution_digest, &semanticDigest(.resolution, command.content)) or
            (command.resolution_kind != .denied and command.resolution_kind != .cancelled and
                command.resolution_kind != .indeterminate and command.resolution_kind != .failure))
        {
            return error.InvalidResolution;
        }
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.resolutionExists(command.operation_id)) {
            if (!try self.resolutionReplayMatches(
                command.operation_id,
                command.resolution_kind,
                null,
                command.content_id,
                command.resolution_digest,
            )) return error.ResolutionConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        _ = try self.requireUnresolvedOperation(command.operation_id);
        try self.insertContent(command.content_id, command.content);
        try self.insertResolution(
            command.operation_id,
            command.resolution_kind,
            null,
            command.content_id,
            command.resolution_digest,
        );
        try self.execute("COMMIT");
        return .admitted;
    }

    pub fn settleTurn(self: *Store, command: SettleTurn) !AdmissionResult {
        try validateSettlement(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.turnOutcome(command.turn_id)) |existing| {
            if (existing != command.outcome or !try self.turnSettlementReplayMatches(command)) {
                return error.TurnOutcomeConflict;
            }
            try self.execute("COMMIT");
            return .replay;
        }
        if (try self.unresolvedOperationCount(command.turn_id) != 0) {
            return error.UnresolvedOperations;
        }
        const statement = switch (command.outcome) {
            .cancelled => try self.prepare(
                "UPDATE turn SET outcome_kind = 3 WHERE turn_id = ?1 AND outcome_kind IS NULL",
            ),
            .failed => blk: {
                try self.insertContent(command.failure_content_id.?, command.failure_message.?);
                const failed = try self.prepare(
                    "UPDATE turn SET outcome_kind = 2, outcome_content_id = ?2, failure_code = ?3 WHERE turn_id = ?1 AND outcome_kind IS NULL",
                );
                try bindU64(failed, 2, command.failure_content_id.?);
                try bindU64(failed, 3, command.failure_code.?);
                break :blk failed;
            },
            .completed => unreachable,
        };
        defer finalize(statement);
        try bindU64(statement, 1, command.turn_id);
        try done(statement);
        try self.expectOneChange();
        try self.reach(.before_turn_settlement_commit);
        try self.execute("COMMIT");
        try self.reach(.after_turn_settlement_commit);
        return .admitted;
    }

    pub fn failTurnFromCompletion(
        self: *Store,
        command: FailTurnFromCompletion,
    ) !AdmissionResult {
        try validateCompletion(command.completion);
        if (command.turn_id == 0 or command.failure_code == 0 or
            command.completion.resolution_kind != .failure)
        {
            return error.InvalidTurnFailure;
        }
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.turnOutcome(command.turn_id)) |outcome| {
            if (outcome != .failed or
                !try self.completionReplayMatches(command.completion) or
                !try self.resolutionReplayMatches(
                    command.completion.operation_id,
                    .failure,
                    command.completion.completion_id,
                    command.completion.result_content_id,
                    command.completion.resolution_digest,
                ) or
                !try self.failedOutcomeMatches(
                    command.turn_id,
                    command.completion.result_content_id,
                    command.completion.result_content,
                    command.failure_code,
                )) return error.TurnOutcomeConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        const operation = try self.requireUnresolvedOperation(command.completion.operation_id);
        if (operation.turn_id != command.turn_id) return error.InvalidModelOperation;
        try self.requireAttemptForOperation(
            command.completion.attempt_id,
            command.completion.operation_id,
        );
        try self.ensureContent(
            command.completion.completion_content_id,
            command.completion.completion_content,
        );
        try self.insertContent(
            command.completion.result_content_id,
            command.completion.result_content,
        );
        _ = try self.ensureCompletion(.{
            .completion_id = command.completion.completion_id,
            .operation_id = command.completion.operation_id,
            .attempt_id = command.completion.attempt_id,
            .ordinal = command.completion.completion_ordinal,
            .kind = command.completion.evidence_kind,
            .content_id = command.completion.completion_content_id,
            .digest = command.completion.completion_digest,
        });
        try self.insertResolution(
            command.completion.operation_id,
            .failure,
            command.completion.completion_id,
            command.completion.result_content_id,
            command.completion.resolution_digest,
        );
        try self.reach(.after_failure_resolution);
        try self.setFailedOutcome(
            command.turn_id,
            command.completion.result_content_id,
            command.failure_code,
        );
        try self.reach(.before_turn_settlement_commit);
        try self.execute("COMMIT");
        try self.reach(.after_turn_settlement_commit);
        return .admitted;
    }

    pub fn failTurnWithoutCompletion(
        self: *Store,
        command: FailTurnWithoutCompletion,
    ) !AdmissionResult {
        if (command.turn_id == 0 or command.operation_id == 0 or
            command.result_content_id == 0 or command.failure_code == 0 or
            command.message.len == 0 or command.message.len > max_text_bytes or
            !std.unicode.utf8ValidateSlice(command.message))
        {
            return error.InvalidTurnFailure;
        }
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.turnOutcome(command.turn_id)) |outcome| {
            if (outcome != .failed or
                !try self.resolutionReplayMatches(
                    command.operation_id,
                    .indeterminate,
                    null,
                    command.result_content_id,
                    semanticDigest(.resolution, command.message),
                ) or
                !try self.failedOutcomeMatches(
                    command.turn_id,
                    command.result_content_id,
                    command.message,
                    command.failure_code,
                )) return error.TurnOutcomeConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        const operation = try self.requireUnresolvedOperation(command.operation_id);
        if (operation.turn_id != command.turn_id or operation.kind != .model) {
            return error.InvalidModelOperation;
        }
        try self.insertContent(command.result_content_id, command.message);
        try self.insertResolution(
            command.operation_id,
            .indeterminate,
            null,
            command.result_content_id,
            semanticDigest(.resolution, command.message),
        );
        try self.reach(.after_failure_resolution);
        try self.setFailedOutcome(
            command.turn_id,
            command.result_content_id,
            command.failure_code,
        );
        try self.reach(.before_turn_settlement_commit);
        try self.execute("COMMIT");
        try self.reach(.after_turn_settlement_commit);
        return .admitted;
    }

    pub fn admitModelToolCalls(self: *Store, command: AdmitModelToolCalls) !AdmissionResult {
        try validateModelToolCalls(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const resolution_digest = semanticDigest(.resolution, command.captured_output);
        if (try self.resolutionExists(command.model_operation_id)) {
            if (!try self.resolutionReplayMatches(
                command.model_operation_id,
                .model_tool_calls,
                command.completion_id,
                command.completion_content_id,
                resolution_digest,
            ) or !try self.modelToolCallsReplayMatch(command)) return error.ResolutionConflict;
            try self.execute("COMMIT");
            return .replay;
        }
        const operation = try self.requireUnresolvedOperation(command.model_operation_id);
        if (operation.turn_id != command.turn_id or operation.kind != .model) {
            return error.InvalidModelOperation;
        }
        if (try self.unresolvedOperationCount(command.turn_id) != 1) {
            return error.UnresolvedOperations;
        }
        try self.requireAttemptForOperation(command.attempt_id, command.model_operation_id);
        if (try self.conversationRevision(operation.session_id) != command.expected_conversation_revision) {
            return error.StaleConversation;
        }
        try self.ensureContent(command.completion_content_id, command.captured_output);
        _ = try self.ensureCompletion(.{
            .completion_id = command.completion_id,
            .operation_id = command.model_operation_id,
            .attempt_id = command.attempt_id,
            .ordinal = 1,
            .kind = .success,
            .content_id = command.completion_content_id,
            .digest = command.completion_digest,
        });
        try self.insertResolution(
            command.model_operation_id,
            .model_tool_calls,
            command.completion_id,
            command.completion_content_id,
            resolution_digest,
        );
        var revision = command.expected_conversation_revision;
        for (command.calls, 0..) |call, call_index| {
            try self.insertContent(call.content_id, call.content);
            revision += 1;
            try self.insertConversationEntry(.{
                .session_id = operation.session_id,
                .revision = revision,
                .entry_id = call.entry_id,
                .turn_id = command.turn_id,
                .kind = .tool_call,
                .content_id = call.content_id,
                .source_operation_id = command.model_operation_id,
                .call_ordinal = @intCast(call_index),
            });
            try self.insertContent(call.descriptor_content_id, call.descriptor);
            try self.insertOperation(.{
                .turn_id = command.turn_id,
                .operation_id = call.action_operation_id,
                .ordinal = call.action_operation_ordinal,
                .kind = call.action_kind,
                .descriptor_content_id = call.descriptor_content_id,
                .descriptor_digest = call.descriptor_digest,
                .caused_by_entry_id = call.entry_id,
            });
        }
        try self.execute("COMMIT");
        return .admitted;
    }

    pub fn appendToolResults(self: *Store, command: AppendToolResults) !AdmissionResult {
        if (command.turn_id == 0 or command.parent_model_operation_id == 0 or
            command.results.len == 0 or command.results.len > 8)
        {
            return error.InvalidToolResults;
        }
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const session_id = try self.sessionForTurn(command.turn_id);
        if (try self.conversationRevision(session_id) != command.expected_conversation_revision) {
            const replayed = try self.toolResultsMatch(command);
            if (!replayed) return error.StaleConversation;
            try self.execute("COMMIT");
            return .replay;
        }
        if (try self.childOperationCount(command.parent_model_operation_id) != command.results.len) {
            return error.IncompleteToolResults;
        }
        var revision = command.expected_conversation_revision;
        for (command.results, 0..) |result, call_index| {
            const resolved = try self.resolvedChild(
                command.turn_id,
                command.parent_model_operation_id,
                result.action_operation_id,
                call_index,
            );
            revision += 1;
            try self.insertConversationEntry(.{
                .session_id = session_id,
                .revision = revision,
                .entry_id = result.entry_id,
                .turn_id = command.turn_id,
                .kind = .tool_result,
                .content_id = resolved.content_id,
                .source_operation_id = result.action_operation_id,
                .call_ordinal = @intCast(call_index),
            });
        }
        try self.execute("COMMIT");
        return .admitted;
    }

    pub fn completeTurn(self: *Store, command: CompleteTurn) !AdmissionResult {
        try validateCompleteTurn(command);
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollback();
        if (try self.turnOutcome(command.turn_id)) |outcome| {
            if (outcome != .completed or !try self.completeTurnReplayMatches(command)) {
                return error.TurnOutcomeConflict;
            }
            try self.execute("COMMIT");
            return .replay;
        }
        const operation = try self.requireUnresolvedOperation(command.model_operation_id);
        if (operation.turn_id != command.turn_id or operation.kind != .model) {
            return error.InvalidModelOperation;
        }
        if (try self.unresolvedOperationCount(command.turn_id) != 1) {
            return error.UnresolvedOperations;
        }
        try self.requireAttemptForOperation(command.attempt_id, command.model_operation_id);
        if (try self.conversationRevision(operation.session_id) != command.expected_conversation_revision) {
            return error.StaleConversation;
        }
        try self.ensureContent(command.completion_content_id, command.captured_output);
        try self.insertContent(command.final_content_id, command.final_answer);
        _ = try self.ensureCompletion(.{
            .completion_id = command.completion_id,
            .operation_id = command.model_operation_id,
            .attempt_id = command.attempt_id,
            .ordinal = 1,
            .kind = .success,
            .content_id = command.completion_content_id,
            .digest = command.completion_digest,
        });
        const resolution_digest = semanticDigest(.resolution, command.final_answer);
        try self.insertResolution(
            command.model_operation_id,
            .final_answer,
            command.completion_id,
            command.final_content_id,
            resolution_digest,
        );
        try self.insertConversationEntry(.{
            .session_id = operation.session_id,
            .revision = command.expected_conversation_revision + 1,
            .entry_id = command.final_entry_id,
            .turn_id = command.turn_id,
            .kind = .assistant_text,
            .content_id = command.final_content_id,
            .source_operation_id = command.model_operation_id,
        });
        try self.reach(.after_final_entry);
        const settle = try self.prepare(
            "UPDATE turn SET outcome_kind = 1, outcome_content_id = ?2 WHERE turn_id = ?1 AND outcome_kind IS NULL",
        );
        defer finalize(settle);
        try bindU64(settle, 1, command.turn_id);
        try bindU64(settle, 2, command.final_content_id);
        try done(settle);
        try self.expectOneChange();
        try self.reach(.before_turn_outcome_commit);
        try self.execute("COMMIT");
        try self.reach(.after_turn_outcome_commit);
        return .admitted;
    }

    pub fn readUnresolvedOperations(
        self: *Store,
        turn_id: u64,
        out: []OperationView,
    ) !usize {
        if (turn_id == 0 or out.len == 0 or out.len > 256) return error.InvalidOperationWindow;
        const statement = try self.prepare(
            \\SELECT o.operation_id, o.operation_ordinal, o.kind,
            \\       o.caused_by_operation_id, o.call_ordinal
            \\FROM operation o
            \\LEFT JOIN operation_resolution r ON r.operation_id = o.operation_id
            \\WHERE o.turn_id = ?1 AND r.operation_id IS NULL
            \\ORDER BY o.operation_ordinal LIMIT ?2
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        try bindU64(statement, 2, out.len);
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return count;
            if (result != c.SQLITE_ROW) return mapSqliteError(result);
            const kind_value = c.sqlite3_column_int64(statement, 2);
            if (kind_value < 1 or kind_value > 3) return error.CorruptHostStore;
            out[count] = .{
                .operation_id = try positiveColumn(statement, 0),
                .operation_ordinal = std.math.cast(u32, try positiveColumn(statement, 1)) orelse
                    return error.CorruptHostStore,
                .kind = @enumFromInt(kind_value),
                .caused_by_operation_id = try optionalPositiveColumn(statement, 3),
                .call_ordinal = if (try optionalNonnegativeColumn(statement, 4)) |value|
                    std.math.cast(u16, value) orelse return error.CorruptHostStore
                else
                    null,
            };
        }
        return count;
    }

    /// Derive the ordered Conversation consequence of resolved child Actions.
    /// No queue or consumption marker is stored: absence of the immutable Tool
    /// Result entry is the complete recovery fact.
    pub fn readPendingToolResults(
        self: *Store,
        turn_id: u64,
        out: []PendingToolResult,
    ) !usize {
        if (turn_id == 0 or out.len == 0 or out.len > 8) return error.InvalidToolResultWindow;
        const statement = try self.prepare(
            \\SELECT child.caused_by_operation_id, child.operation_id, child.call_ordinal
            \\FROM operation child
            \\JOIN operation_resolution resolution ON resolution.operation_id = child.operation_id
            \\LEFT JOIN conversation_entry result
            \\  ON result.kind = 4 AND result.source_operation_id = child.operation_id
            \\WHERE child.turn_id = ?1 AND child.kind IN (2, 3) AND result.entry_id IS NULL
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM operation sibling
            \\      LEFT JOIN operation_resolution sibling_resolution
            \\        ON sibling_resolution.operation_id = sibling.operation_id
            \\      WHERE sibling.caused_by_operation_id = child.caused_by_operation_id
            \\        AND sibling_resolution.operation_id IS NULL
            \\  )
            \\ORDER BY child.caused_by_operation_id, child.call_ordinal
            \\LIMIT ?2
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        try bindU64(statement, 2, out.len + 1);
        var count: usize = 0;
        while (true) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return count;
            if (result != c.SQLITE_ROW) return mapSqliteError(result);
            if (count == out.len) return error.ToolResultWindowExceeded;
            const pending: PendingToolResult = .{
                .parent_model_operation_id = try positiveColumn(statement, 0),
                .action_operation_id = try positiveColumn(statement, 1),
                .call_ordinal = std.math.cast(u16, try nonnegativeColumn(statement, 2)) orelse
                    return error.CorruptHostStore,
            };
            if (count != 0 and pending.parent_model_operation_id != out[0].parent_model_operation_id) {
                return error.MultiplePendingToolResultBatches;
            }
            if (pending.call_ordinal != count) return error.CorruptHostStore;
            out[count] = pending;
            count += 1;
        }
    }

    pub fn loadDecisionSnapshot(self: *Store, turn_id: u64) !DecisionSnapshot {
        if (turn_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT t.session_id, t.outcome_kind,
            \\       (SELECT COALESCE(MAX(e.revision), 0) FROM conversation_entry e WHERE e.session_id = t.session_id),
            \\       (SELECT count(*) FROM attempt a
            \\        JOIN operation o ON o.operation_id = a.operation_id
            \\        LEFT JOIN operation_resolution r ON r.operation_id = o.operation_id
            \\        LEFT JOIN attempt_completion completion ON completion.operation_id = o.operation_id
            \\        WHERE o.turn_id = t.turn_id AND r.operation_id IS NULL
            \\          AND completion.completion_id IS NULL)
            \\FROM turn t WHERE t.turn_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.TurnNotFound;
        const outcome_raw = c.sqlite3_column_int64(statement, 1);
        const attempts = c.sqlite3_column_int64(statement, 3);
        if (attempts < 0 or attempts > std.math.maxInt(u16)) return error.CorruptHostStore;
        const snapshot: DecisionSnapshot = .{
            .session_id = try positiveColumn(statement, 0),
            .turn_id = turn_id,
            .conversation_revision = try nonnegativeColumn(statement, 2),
            .outcome = if (c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL)
                null
            else if (outcome_raw >= @intFromEnum(TurnOutcome.completed) and
                outcome_raw <= @intFromEnum(TurnOutcome.cancelled))
                @enumFromInt(outcome_raw)
            else
                return error.CorruptHostStore,
            .unresolved_external_attempts = @intCast(attempts),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return snapshot;
    }

    pub fn readUnresolvedCompletion(
        self: *Store,
        operation_id: u64,
    ) !?CompletionRecord {
        if (operation_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT completion.operation_id, completion.attempt_id,
            \\       completion.completion_id, completion.completion_ordinal,
            \\       completion.evidence_kind, completion.evidence_content_id,
            \\       completion.evidence_digest
            \\FROM attempt_completion completion
            \\LEFT JOIN operation_resolution resolution
            \\  ON resolution.operation_id = completion.operation_id
            \\WHERE completion.operation_id = ?1 AND resolution.operation_id IS NULL
            \\ORDER BY completion.attempt_id, completion.completion_ordinal LIMIT 2
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        const first = c.sqlite3_step(statement);
        if (first == c.SQLITE_DONE) return null;
        if (first != c.SQLITE_ROW) return mapSqliteError(first);
        const kind = std.enums.fromInt(EvidenceKind, c.sqlite3_column_int64(statement, 4)) orelse
            return error.CorruptHostStore;
        const value: CompletionRecord = .{
            .operation_id = try positiveColumn(statement, 0),
            .attempt_id = try positiveColumn(statement, 1),
            .completion_id = try positiveColumn(statement, 2),
            .completion_ordinal = std.math.cast(u32, try positiveColumn(statement, 3)) orelse
                return error.CorruptHostStore,
            .evidence_kind = kind,
            .content_id = try positiveColumn(statement, 5),
            .digest = try digestColumn(statement, 6),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.MultipleApplicableCompletions;
        return value;
    }

    pub fn readConversation(
        self: *Store,
        session_id: u64,
        after_revision: u64,
        out: []ConversationEntry,
    ) !usize {
        if (session_id == 0 or out.len == 0 or out.len > max_conversation_window) {
            return error.InvalidConversationWindow;
        }
        const statement = try self.prepare(
            \\SELECT revision, entry_id, turn_id, kind, content_id, source_operation_id, call_ordinal
            \\FROM conversation_entry WHERE session_id = ?1 AND revision > ?2
            \\ORDER BY revision LIMIT ?3
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        try bindU64AllowZero(statement, 2, after_revision);
        try bindU64(statement, 3, out.len);
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            const result = c.sqlite3_step(statement);
            if (result == c.SQLITE_DONE) return count;
            if (result != c.SQLITE_ROW) return mapSqliteError(result);
            const kind_raw = c.sqlite3_column_int64(statement, 3);
            if (kind_raw < @intFromEnum(ConversationKind.user_text) or
                kind_raw > @intFromEnum(ConversationKind.tool_result))
            {
                return error.CorruptHostStore;
            }
            out[count] = .{
                .revision = try positiveColumn(statement, 0),
                .entry_id = try positiveColumn(statement, 1),
                .turn_id = try positiveColumn(statement, 2),
                .kind = @enumFromInt(kind_raw),
                .content_id = try positiveColumn(statement, 4),
                .source_operation_id = try optionalPositiveColumn(statement, 5),
                .call_ordinal = if (try optionalNonnegativeColumn(statement, 6)) |value|
                    std.math.cast(u16, value) orelse return error.CorruptHostStore
                else
                    null,
            };
        }
        return count;
    }

    pub fn sessionConversationRevision(self: *Store, session_id: u64) !u64 {
        if (session_id == 0) return error.InvalidIdentity;
        return self.conversationRevision(session_id);
    }

    pub fn readSession(self: *Store, session_id: u64) !SessionRecord {
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT s.session_id,
            \\       COALESCE((SELECT MAX(revision) FROM conversation_entry WHERE session_id = s.session_id), 0),
            \\       (SELECT turn_id FROM turn WHERE session_id = s.session_id AND outcome_kind IS NULL),
            \\       (SELECT turn_id FROM turn WHERE session_id = s.session_id ORDER BY turn_ordinal DESC LIMIT 1)
            \\FROM session s WHERE s.session_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SessionNotFound;
        const result: SessionRecord = .{
            .session_id = try positiveColumn(statement, 0),
            .conversation_revision = try nonnegativeColumn(statement, 1),
            .active_turn_id = try optionalPositiveColumn(statement, 2),
            .latest_turn_id = try optionalPositiveColumn(statement, 3),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return result;
    }

    pub fn readTurn(self: *Store, turn_id: u64) !TurnRecord {
        if (turn_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT session_id, turn_id, turn_ordinal, outcome_kind, outcome_content_id, failure_code
            \\FROM turn WHERE turn_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.TurnNotFound;
        const outcome: ?TurnOutcome = if (c.sqlite3_column_type(statement, 3) == c.SQLITE_NULL)
            null
        else blk: {
            const value = c.sqlite3_column_int64(statement, 3);
            if (value < 1 or value > 3) return error.CorruptHostStore;
            break :blk @enumFromInt(value);
        };
        const result: TurnRecord = .{
            .session_id = try positiveColumn(statement, 0),
            .turn_id = try positiveColumn(statement, 1),
            .turn_ordinal = std.math.cast(u32, try positiveColumn(statement, 2)) orelse
                return error.CorruptHostStore,
            .outcome = outcome,
            .outcome_content_id = try optionalPositiveColumn(statement, 4),
            .failure_code = if (try optionalPositiveColumn(statement, 5)) |value|
                std.math.cast(u16, value) orelse return error.CorruptHostStore
            else
                null,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return result;
    }

    pub fn readSessionWorkspace(self: *Store, session_id: u64, out: []u8) ![]const u8 {
        if (session_id == 0 or out.len == 0 or out.len > max_path_bytes) {
            return error.InvalidWorkspaceBuffer;
        }
        const statement = try self.prepare("SELECT workspace_path FROM session WHERE session_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SessionNotFound;
        const length = c.sqlite3_column_bytes(statement, 0);
        if (length <= 0 or length > out.len) return error.WorkspaceBufferTooSmall;
        const pointer = c.sqlite3_column_text(statement, 0) orelse return error.CorruptHostStore;
        @memcpy(out[0..@intCast(length)], pointer[0..@intCast(length)]);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return out[0..@intCast(length)];
    }

    pub fn nextTurnOrdinalForSession(self: *Store, session_id: u64) !u32 {
        if (!try self.sessionExists(session_id)) return error.SessionNotFound;
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(turn_ordinal), 0) + 1 FROM turn WHERE session_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = std.math.cast(u32, try positiveColumn(statement, 0)) orelse
            return error.TurnCapacityExceeded;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    pub fn nextOperationOrdinalForTurn(self: *Store, turn_id: u64) !u32 {
        if (turn_id == 0) return error.InvalidIdentity;
        return std.math.cast(u32, try self.nextOperationOrdinal(turn_id)) orelse
            error.OperationOrdinalExhausted;
    }

    pub fn nextAttemptOrdinalForOperation(self: *Store, operation_id: u64) !u32 {
        if (operation_id == 0) return error.InvalidIdentity;
        return std.math.cast(u32, try self.nextAttemptOrdinal(operation_id)) orelse
            error.AttemptOrdinalExhausted;
    }

    pub fn readOperation(self: *Store, operation_id: u64) !OperationRecord {
        const statement = try self.prepare(
            \\SELECT session_id, turn_id, operation_ordinal, kind,
            \\       descriptor_content_id, descriptor_digest,
            \\       caused_by_operation_id, caused_by_entry_id, call_ordinal
            \\FROM operation WHERE operation_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.OperationNotFound;
        const kind_raw = c.sqlite3_column_int64(statement, 3);
        if (kind_raw < 1 or kind_raw > 3) return error.CorruptHostStore;
        const value: OperationRecord = .{
            .session_id = try positiveColumn(statement, 0),
            .turn_id = try positiveColumn(statement, 1),
            .operation_id = operation_id,
            .operation_ordinal = std.math.cast(u32, try positiveColumn(statement, 2)) orelse
                return error.CorruptHostStore,
            .kind = @enumFromInt(kind_raw),
            .descriptor_content_id = try positiveColumn(statement, 4),
            .descriptor_digest = try digestColumn(statement, 5),
            .caused_by_operation_id = try optionalPositiveColumn(statement, 6),
            .caused_by_entry_id = try optionalPositiveColumn(statement, 7),
            .call_ordinal = if (try optionalNonnegativeColumn(statement, 8)) |raw|
                std.math.cast(u16, raw) orelse return error.CorruptHostStore
            else
                null,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    pub fn contentLength(self: *Store, content_id: u64) !usize {
        const statement = try self.prepare(
            "SELECT byte_length FROM content WHERE content_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ContentNotFound;
        const length = std.math.cast(usize, try positiveColumn(statement, 0)) orelse
            return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return length;
    }

    pub fn readContent(self: *Store, content_id: u64, out: []u8) ![]const u8 {
        const statement = try self.prepare(
            "SELECT byte_length, payload, digest FROM content WHERE content_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ContentNotFound;
        const length = std.math.cast(usize, try positiveColumn(statement, 0)) orelse
            return error.CorruptHostStore;
        if (length > out.len or c.sqlite3_column_bytes(statement, 1) != length) {
            return error.ContentBufferTooSmall;
        }
        const pointer = c.sqlite3_column_blob(statement, 1) orelse return error.CorruptHostStore;
        const bytes: [*]const u8 = @ptrCast(pointer);
        @memcpy(out[0..length], bytes[0..length]);
        const expected = try digestColumn(statement, 2);
        if (!std.mem.eql(u8, &expected, &binding.hash(binding.Blob, out[0..length]).bytes)) {
            return error.ContentDigestMismatch;
        }
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return out[0..length];
    }

    fn validateSessionBinding(self: *Store, command: AdmitTurn) !void {
        const statement = try self.prepare(
            "SELECT workspace_path, access_scope_digest FROM session WHERE session_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.SessionNotFound;
        if (!columnTextEquals(statement, 0, command.workspace_path) or
            !columnBlobEquals(statement, 1, &command.access_scope_digest))
        {
            return error.SessionBindingConflict;
        }
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    fn turnExists(self: *Store, turn_id: u64) !bool {
        const statement = try self.prepare("SELECT 1 FROM turn WHERE turn_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn turnReplayMatches(self: *Store, command: AdmitTurn) !bool {
        const statement = try self.prepare(
            \\SELECT t.session_id, t.turn_ordinal, t.admission_digest, t.initial_entry_id,
            \\       e.content_id, e.revision, s.workspace_path, s.access_scope_digest, content.payload
            \\FROM turn t
            \\JOIN session s ON s.session_id = t.session_id
            \\JOIN conversation_entry e ON e.turn_id = t.turn_id AND e.entry_id = t.initial_entry_id
            \\JOIN content ON content.content_id = e.content_id
            \\WHERE t.turn_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = try positiveColumn(statement, 0) == command.session_id and
            try positiveColumn(statement, 1) == command.turn_ordinal and
            columnBlobEquals(statement, 2, &command.admission_digest) and
            try positiveColumn(statement, 3) == command.entry_id and
            try positiveColumn(statement, 4) == command.content_id and
            try positiveColumn(statement, 5) == command.expected_conversation_revision + 1 and
            columnTextEquals(statement, 6, command.workspace_path) and
            columnBlobEquals(statement, 7, &command.access_scope_digest) and
            columnBlobEquals(statement, 8, command.user_text);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    fn sessionExists(self: *Store, session_id: u64) !bool {
        const statement = try self.prepare("SELECT 1 FROM session WHERE session_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn hasActiveTurn(self: *Store, session_id: u64) !bool {
        const statement = try self.prepare(
            "SELECT 1 FROM turn WHERE session_id = ?1 AND outcome_kind IS NULL LIMIT 1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn conversationRevision(self: *Store, session_id: u64) !u64 {
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(revision), 0) FROM conversation_entry WHERE session_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try nonnegativeColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn nextTurnOrdinal(self: *Store, session_id: u64) !u64 {
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(turn_ordinal), 0) + 1 FROM turn WHERE session_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, session_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try positiveColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    const ExistingOperation = struct {
        turn_id: u64,
        ordinal: u32,
        kind: OperationKind,
        descriptor_content_id: u64,
        digest: Digest,
    };

    fn existingOperation(self: *Store, operation_id: u64) !?ExistingOperation {
        const statement = try self.prepare(
            "SELECT turn_id, operation_ordinal, kind, descriptor_content_id, descriptor_digest FROM operation WHERE operation_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const kind_raw = c.sqlite3_column_int64(statement, 2);
        if (kind_raw < 1 or kind_raw > 3) return error.CorruptHostStore;
        const existing: ExistingOperation = .{
            .turn_id = try positiveColumn(statement, 0),
            .ordinal = std.math.cast(u32, try positiveColumn(statement, 1)) orelse
                return error.CorruptHostStore,
            .kind = @enumFromInt(kind_raw),
            .descriptor_content_id = try positiveColumn(statement, 3),
            .digest = try digestColumn(statement, 4),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return existing;
    }

    fn requireActiveTurn(self: *Store, turn_id: u64) !void {
        const statement = try self.prepare(
            "SELECT 1 FROM turn WHERE turn_id = ?1 AND outcome_kind IS NULL",
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.TurnNotActive;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    fn nextOperationOrdinal(self: *Store, turn_id: u64) !u64 {
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(operation_ordinal), 0) + 1 FROM operation WHERE turn_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try positiveColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn unresolvedOperationCount(self: *Store, turn_id: u64) !u64 {
        const statement = try self.prepare(
            \\SELECT count(*) FROM operation o
            \\LEFT JOIN operation_resolution r ON r.operation_id = o.operation_id
            \\WHERE o.turn_id = ?1 AND r.operation_id IS NULL
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try nonnegativeColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    const InsertOperation = struct {
        turn_id: u64,
        operation_id: u64,
        ordinal: u32,
        kind: OperationKind,
        descriptor_content_id: u64,
        descriptor_digest: Digest,
        caused_by_operation_id: ?u64 = null,
        caused_by_entry_id: ?u64 = null,
        call_ordinal: ?u16 = null,
    };

    fn insertOperation(self: *Store, value: InsertOperation) !void {
        const session_id = try self.sessionForTurn(value.turn_id);
        const statement = try self.prepare(
            \\INSERT INTO operation (
            \\    operation_id, session_id, turn_id, operation_ordinal, kind,
            \\    descriptor_content_id, descriptor_digest,
            \\    caused_by_operation_id, caused_by_entry_id, call_ordinal
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, value.operation_id);
        try bindU64(statement, 2, session_id);
        try bindU64(statement, 3, value.turn_id);
        try bindU64(statement, 4, value.ordinal);
        try bindU64(statement, 5, @intFromEnum(value.kind));
        try bindU64(statement, 6, value.descriptor_content_id);
        try bindBlob(statement, 7, &value.descriptor_digest);
        try bindOptionalU64(statement, 8, value.caused_by_operation_id);
        try bindOptionalU64(statement, 9, value.caused_by_entry_id);
        try bindOptionalU64AllowZero(statement, 10, value.call_ordinal);
        try done(statement);
        try self.expectOneChange();
    }

    fn attemptExists(self: *Store, attempt_id: u64) !bool {
        const statement = try self.prepare("SELECT 1 FROM attempt WHERE attempt_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, attempt_id);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn attemptReplayMatches(self: *Store, command: AdmitAttempt) !bool {
        const statement = try self.prepare(
            \\SELECT a.operation_id, a.attempt_ordinal, a.dispatch_content_id,
            \\       a.dispatch_digest, a.parameters_content_id, parameters.payload,
            \\       a.context_cutoff_revision, a.workspace_digest,
            \\       a.external_idempotency_key, a.possible_duplicate
            \\FROM attempt a
            \\JOIN content parameters ON parameters.content_id = a.parameters_content_id
            \\WHERE a.attempt_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.attempt_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = try positiveColumn(statement, 0) == command.operation_id and
            try positiveColumn(statement, 1) == command.attempt_ordinal and
            try positiveColumn(statement, 2) == command.dispatch_content_id and
            columnBlobEquals(statement, 3, &command.dispatch_digest) and
            try positiveColumn(statement, 4) == command.parameters_content_id and
            columnBlobEquals(statement, 5, command.parameters) and
            try nonnegativeColumn(statement, 6) == command.context_cutoff_revision and
            columnBlobEquals(statement, 7, &command.workspace_digest) and
            optionalColumnTextEquals(statement, 8, command.external_idempotency_key) and
            c.sqlite3_column_int64(statement, 9) == @intFromBool(command.possible_duplicate);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    const OperationAuthority = struct {
        turn_id: u64,
        session_id: u64,
        kind: OperationKind,
        descriptor_content_id: u64,
    };

    fn requireUnresolvedOperation(self: *Store, operation_id: u64) !OperationAuthority {
        const statement = try self.prepare(
            \\SELECT o.turn_id, t.session_id, o.kind, o.descriptor_content_id
            \\FROM operation o
            \\JOIN turn t ON t.turn_id = o.turn_id
            \\LEFT JOIN operation_resolution r ON r.operation_id = o.operation_id
            \\WHERE o.operation_id = ?1 AND r.operation_id IS NULL AND t.outcome_kind IS NULL
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.OperationNotRunnable;
        const kind_raw = c.sqlite3_column_int64(statement, 2);
        if (kind_raw < 1 or kind_raw > 3) return error.CorruptHostStore;
        const value: OperationAuthority = .{
            .turn_id = try positiveColumn(statement, 0),
            .session_id = try positiveColumn(statement, 1),
            .kind = @enumFromInt(kind_raw),
            .descriptor_content_id = try positiveColumn(statement, 3),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn nextAttemptOrdinal(self: *Store, operation_id: u64) !u64 {
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(attempt_ordinal), 0) + 1 FROM attempt WHERE operation_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try positiveColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn resolutionExists(self: *Store, operation_id: u64) !bool {
        const statement = try self.prepare(
            "SELECT 1 FROM operation_resolution WHERE operation_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn resolutionReplayMatches(
        self: *Store,
        operation_id: u64,
        kind: ResolutionKind,
        completion_id: ?u64,
        result_content_id: u64,
        digest: Digest,
    ) !bool {
        const statement = try self.prepare(
            "SELECT resolution_kind, completion_id, result_content_id, result_digest FROM operation_resolution WHERE operation_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = c.sqlite3_column_int64(statement, 0) == @intFromEnum(kind) and
            try optionalPositiveColumn(statement, 1) == completion_id and
            try positiveColumn(statement, 2) == result_content_id and
            columnBlobEquals(statement, 3, &digest);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    fn completionReplayMatches(self: *Store, command: CompleteAndResolve) !bool {
        const existing = (try self.existingCompletion(command.completion_id)) orelse return false;
        return existing.operation_id == command.operation_id and
            existing.attempt_id == command.attempt_id and
            existing.ordinal == command.completion_ordinal and
            existing.kind == command.evidence_kind and
            existing.content_id == command.completion_content_id and
            std.mem.eql(u8, &existing.digest, &command.completion_digest);
    }

    fn requireAttemptForOperation(self: *Store, attempt_id: u64, operation_id: u64) !void {
        const statement = try self.prepare(
            "SELECT 1 FROM attempt WHERE attempt_id = ?1 AND operation_id = ?2",
        );
        defer finalize(statement);
        try bindU64(statement, 1, attempt_id);
        try bindU64(statement, 2, operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.AttemptNotFound;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    fn nextCompletionOrdinal(self: *Store, attempt_id: u64) !u64 {
        const statement = try self.prepare(
            "SELECT COALESCE(MAX(completion_ordinal), 0) + 1 FROM attempt_completion WHERE attempt_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, attempt_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try positiveColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    const ExistingCompletion = struct {
        operation_id: u64,
        attempt_id: u64,
        ordinal: u32,
        kind: EvidenceKind,
        content_id: u64,
        digest: Digest,
    };

    fn existingCompletion(self: *Store, completion_id: u64) !?ExistingCompletion {
        const statement = try self.prepare(
            "SELECT operation_id, attempt_id, completion_ordinal, evidence_kind, evidence_content_id, evidence_digest FROM attempt_completion WHERE completion_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, completion_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const value: ExistingCompletion = .{
            .operation_id = try positiveColumn(statement, 0),
            .attempt_id = try positiveColumn(statement, 1),
            .ordinal = std.math.cast(u32, try positiveColumn(statement, 2)) orelse
                return error.CorruptHostStore,
            .kind = std.enums.fromInt(EvidenceKind, c.sqlite3_column_int64(statement, 3)) orelse
                return error.CorruptHostStore,
            .content_id = try positiveColumn(statement, 4),
            .digest = try digestColumn(statement, 5),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    const InsertCompletion = struct {
        completion_id: u64,
        operation_id: u64,
        attempt_id: u64,
        ordinal: u32,
        kind: EvidenceKind,
        content_id: u64,
        digest: Digest,
    };

    fn insertCompletion(self: *Store, value: InsertCompletion) !void {
        const statement = try self.prepare(
            \\INSERT INTO attempt_completion (
            \\    completion_id, operation_id, attempt_id, completion_ordinal, evidence_kind,
            \\    evidence_content_id, evidence_digest
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, value.completion_id);
        try bindU64(statement, 2, value.operation_id);
        try bindU64(statement, 3, value.attempt_id);
        try bindU64(statement, 4, value.ordinal);
        try bindU64(statement, 5, @intFromEnum(value.kind));
        try bindU64(statement, 6, value.content_id);
        try bindBlob(statement, 7, &value.digest);
        try done(statement);
        try self.expectOneChange();
    }

    fn ensureCompletion(self: *Store, value: InsertCompletion) !AdmissionResult {
        if (try self.existingCompletion(value.completion_id)) |existing| {
            if (existing.operation_id != value.operation_id or
                existing.attempt_id != value.attempt_id or
                existing.ordinal != value.ordinal or existing.kind != value.kind or
                existing.content_id != value.content_id or
                !std.mem.eql(u8, &existing.digest, &value.digest))
            {
                return error.CompletionConflict;
            }
            return .replay;
        }
        try self.requireAttemptForOperation(value.attempt_id, value.operation_id);
        if (try self.nextCompletionOrdinal(value.attempt_id) != value.ordinal) {
            return error.InvalidCompletionOrdinal;
        }
        try self.insertCompletion(value);
        return .admitted;
    }

    fn insertResolution(
        self: *Store,
        operation_id: u64,
        kind: ResolutionKind,
        completion_id: ?u64,
        content_id: u64,
        digest: Digest,
    ) !void {
        const statement = try self.prepare(
            \\INSERT INTO operation_resolution (
            \\    operation_id, resolution_kind, completion_id, result_content_id, result_digest
            \\) VALUES (?1, ?2, ?3, ?4, ?5)
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        try bindU64(statement, 2, @intFromEnum(kind));
        try bindOptionalU64(statement, 3, completion_id);
        try bindU64(statement, 4, content_id);
        try bindBlob(statement, 5, &digest);
        try done(statement);
        try self.expectOneChange();
    }

    fn setFailedOutcome(
        self: *Store,
        turn_id: u64,
        content_id: u64,
        failure_code: u16,
    ) !void {
        const statement = try self.prepare(
            "UPDATE turn SET outcome_kind = 2, outcome_content_id = ?2, failure_code = ?3 WHERE turn_id = ?1 AND outcome_kind IS NULL",
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        try bindU64(statement, 2, content_id);
        try bindU64(statement, 3, failure_code);
        try done(statement);
        try self.expectOneChange();
    }

    const InsertConversationEntry = struct {
        session_id: u64,
        revision: u64,
        entry_id: u64,
        turn_id: u64,
        kind: ConversationKind,
        content_id: u64,
        source_operation_id: ?u64 = null,
        call_ordinal: ?u16 = null,
    };

    fn insertConversationEntry(self: *Store, value: InsertConversationEntry) !void {
        const statement = try self.prepare(
            \\INSERT INTO conversation_entry (
            \\    session_id, revision, entry_id, turn_id, kind, content_id,
            \\    source_operation_id, call_ordinal
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, value.session_id);
        try bindU64(statement, 2, value.revision);
        try bindU64(statement, 3, value.entry_id);
        try bindU64(statement, 4, value.turn_id);
        try bindU64(statement, 5, @intFromEnum(value.kind));
        try bindU64(statement, 6, value.content_id);
        try bindOptionalU64(statement, 7, value.source_operation_id);
        try bindOptionalU64AllowZero(statement, 8, value.call_ordinal);
        try done(statement);
        try self.expectOneChange();
    }

    fn sessionForTurn(self: *Store, turn_id: u64) !u64 {
        const statement = try self.prepare("SELECT session_id FROM turn WHERE turn_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.TurnNotFound;
        const session_id = try positiveColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return session_id;
    }

    fn childOperationCount(self: *Store, parent_operation_id: u64) !usize {
        const statement = try self.prepare(
            "SELECT count(*) FROM operation WHERE caused_by_operation_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, parent_operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const count = try nonnegativeColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return std.math.cast(usize, count) orelse error.CorruptHostStore;
    }

    const ResolvedChild = struct { content_id: u64 };

    fn resolvedChild(
        self: *Store,
        turn_id: u64,
        parent_operation_id: u64,
        operation_id: u64,
        call_ordinal: usize,
    ) !ResolvedChild {
        const statement = try self.prepare(
            \\SELECT r.result_content_id
            \\FROM operation o
            \\JOIN operation_resolution r ON r.operation_id = o.operation_id
            \\WHERE o.operation_id = ?1 AND o.turn_id = ?2
            \\  AND o.caused_by_operation_id = ?3 AND o.call_ordinal = ?4
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, operation_id);
        try bindU64(statement, 2, turn_id);
        try bindU64(statement, 3, parent_operation_id);
        try bindU64AllowZero(statement, 4, call_ordinal);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.UnresolvedToolCall;
        const value: ResolvedChild = .{ .content_id = try positiveColumn(statement, 0) };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn toolResultsMatch(self: *Store, command: AppendToolResults) !bool {
        if (try self.childOperationCount(command.parent_model_operation_id) != command.results.len) {
            return false;
        }
        for (command.results, 0..) |candidate, call_index| {
            const statement = try self.prepare(
                \\SELECT entry_id, revision FROM conversation_entry
                \\WHERE turn_id = ?1 AND kind = 4 AND source_operation_id = ?2 AND call_ordinal = ?3
                ,
            );
            defer finalize(statement);
            try bindU64(statement, 1, command.turn_id);
            try bindU64(statement, 2, candidate.action_operation_id);
            try bindU64AllowZero(statement, 3, call_index);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
            if (try positiveColumn(statement, 0) != candidate.entry_id) return false;
            if (try positiveColumn(statement, 1) !=
                command.expected_conversation_revision + call_index + 1) return false;
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        }
        return true;
    }

    fn modelToolCallsReplayMatch(self: *Store, command: AdmitModelToolCalls) !bool {
        const completion = (try self.existingCompletion(command.completion_id)) orelse return false;
        if (completion.operation_id != command.model_operation_id or
            completion.attempt_id != command.attempt_id or completion.ordinal != 1 or
            completion.kind != .success or completion.content_id != command.completion_content_id or
            !std.mem.eql(u8, &completion.digest, &command.completion_digest)) return false;
        for (command.calls, 0..) |call, call_index| {
            const statement = try self.prepare(
                \\SELECT entry.entry_id, entry.content_id, entry.revision, call_content.payload,
                \\       child.operation_ordinal, child.kind, child.descriptor_content_id,
                \\       child.descriptor_digest, descriptor.payload
                \\FROM operation child
                \\JOIN conversation_entry entry
                \\  ON entry.turn_id = child.turn_id AND entry.entry_id = child.caused_by_entry_id
                \\JOIN content call_content ON call_content.content_id = entry.content_id
                \\JOIN content descriptor ON descriptor.content_id = child.descriptor_content_id
                \\WHERE child.operation_id = ?1 AND child.turn_id = ?2
                \\  AND child.caused_by_operation_id = ?3 AND child.call_ordinal = ?4
                ,
            );
            defer finalize(statement);
            try bindU64(statement, 1, call.action_operation_id);
            try bindU64(statement, 2, command.turn_id);
            try bindU64(statement, 3, command.model_operation_id);
            try bindU64AllowZero(statement, 4, call_index);
            if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
            const matches = try positiveColumn(statement, 0) == call.entry_id and
                try positiveColumn(statement, 1) == call.content_id and
                try positiveColumn(statement, 2) == command.expected_conversation_revision + call_index + 1 and
                columnBlobEquals(statement, 3, call.content) and
                try positiveColumn(statement, 4) == call.action_operation_ordinal and
                c.sqlite3_column_int64(statement, 5) == @intFromEnum(call.action_kind) and
                try positiveColumn(statement, 6) == call.descriptor_content_id and
                columnBlobEquals(statement, 7, &call.descriptor_digest) and
                columnBlobEquals(statement, 8, call.descriptor);
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
            if (!matches) return false;
        }
        return try self.childOperationCount(command.model_operation_id) == command.calls.len;
    }

    fn completeTurnReplayMatches(self: *Store, command: CompleteTurn) !bool {
        const completion = (try self.existingCompletion(command.completion_id)) orelse return false;
        if (completion.operation_id != command.model_operation_id or
            completion.attempt_id != command.attempt_id or completion.ordinal != 1 or
            completion.kind != .success or completion.content_id != command.completion_content_id or
            !std.mem.eql(u8, &completion.digest, &command.completion_digest)) return false;
        if (!try self.resolutionReplayMatches(
            command.model_operation_id,
            .final_answer,
            command.completion_id,
            command.final_content_id,
            semanticDigest(.resolution, command.final_answer),
        )) return false;
        const statement = try self.prepare(
            \\SELECT t.outcome_content_id, entry.content_id, entry.source_operation_id,
            \\       entry.revision, final.payload
            \\FROM turn t
            \\JOIN conversation_entry entry ON entry.entry_id = ?2 AND entry.turn_id = t.turn_id
            \\JOIN content final ON final.content_id = entry.content_id
            \\WHERE t.turn_id = ?1 AND t.outcome_kind = 1 AND entry.kind = 2
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.turn_id);
        try bindU64(statement, 2, command.final_entry_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = try positiveColumn(statement, 0) == command.final_content_id and
            try positiveColumn(statement, 1) == command.final_content_id and
            try positiveColumn(statement, 2) == command.model_operation_id and
            try positiveColumn(statement, 3) == command.expected_conversation_revision + 1 and
            columnBlobEquals(statement, 4, command.final_answer);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    fn turnSettlementReplayMatches(self: *Store, command: SettleTurn) !bool {
        const statement = try self.prepare(
            \\SELECT t.outcome_kind, t.outcome_content_id, t.failure_code, content.payload
            \\FROM turn t LEFT JOIN content ON content.content_id = t.outcome_content_id
            \\WHERE t.turn_id = ?1
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, command.turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = switch (command.outcome) {
            .cancelled => c.sqlite3_column_int64(statement, 0) == @intFromEnum(TurnOutcome.cancelled) and
                c.sqlite3_column_type(statement, 1) == c.SQLITE_NULL and
                c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL,
            .failed => c.sqlite3_column_int64(statement, 0) == @intFromEnum(TurnOutcome.failed) and
                try positiveColumn(statement, 1) == command.failure_content_id.? and
                try positiveColumn(statement, 2) == command.failure_code.? and
                columnBlobEquals(statement, 3, command.failure_message.?),
            .completed => false,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    fn failedOutcomeMatches(
        self: *Store,
        turn_id: u64,
        content_id: u64,
        message: []const u8,
        failure_code: u16,
    ) !bool {
        const statement = try self.prepare(
            \\SELECT t.outcome_content_id, t.failure_code, content.payload
            \\FROM turn t JOIN content ON content.content_id = t.outcome_content_id
            \\WHERE t.turn_id = ?1 AND t.outcome_kind = 2
            ,
        );
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const matches = try positiveColumn(statement, 0) == content_id and
            try positiveColumn(statement, 1) == failure_code and
            columnBlobEquals(statement, 2, message);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return matches;
    }

    fn turnOutcome(self: *Store, turn_id: u64) !?TurnOutcome {
        const statement = try self.prepare("SELECT outcome_kind FROM turn WHERE turn_id = ?1");
        defer finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.TurnNotFound;
        if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) {
            if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
            return null;
        }
        const raw = c.sqlite3_column_int64(statement, 0);
        if (raw < 1 or raw > 3) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @enumFromInt(raw);
    }

    fn insertContent(self: *Store, content_id: u64, bytes: []const u8) !void {
        if (content_id == 0 or bytes.len == 0 or bytes.len > max_text_bytes) {
            return error.InvalidContent;
        }
        const digest = binding.hash(binding.Blob, bytes);
        const statement = try self.prepare(
            "INSERT INTO content (content_id, byte_length, digest, payload) VALUES (?1, ?2, ?3, ?4)",
        );
        defer finalize(statement);
        try bindU64(statement, 1, content_id);
        try bindU64(statement, 2, bytes.len);
        try bindBlob(statement, 3, &digest.bytes);
        try bindBlob(statement, 4, bytes);
        try done(statement);
        try self.expectOneChange();
    }

    fn ensureContent(self: *Store, content_id: u64, bytes: []const u8) !void {
        const statement = try self.prepare(
            "SELECT byte_length, digest FROM content WHERE content_id = ?1",
        );
        defer finalize(statement);
        try bindU64(statement, 1, content_id);
        switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => return self.insertContent(content_id, bytes),
            c.SQLITE_ROW => {
                const length = try positiveColumn(statement, 0);
                const digest = try digestColumn(statement, 1);
                const expected = binding.hash(binding.Blob, bytes);
                if (length != bytes.len or !std.mem.eql(u8, &digest, &expected.bytes)) {
                    return error.ContentConflict;
                }
                if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
            },
            else => |result| return mapSqliteError(result),
        }
    }

    fn schemaIsEmpty(self: *Store) !bool {
        const statement = try self.prepare(
            "SELECT 1 FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1",
        );
        defer finalize(statement);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => true,
            c.SQLITE_ROW => false,
            else => |result| mapSqliteError(result),
        };
    }

    fn pragmaU64(self: *Store, sql: [:0]const u8) !u64 {
        const statement = try self.prepare(sql);
        defer finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = try nonnegativeColumn(statement, 0);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return value;
    }

    fn prepare(self: *Store, sql: [:0]const u8) !*c.sqlite3_stmt {
        var maybe_statement: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.database, sql.ptr, -1, &maybe_statement, null);
        if (result != c.SQLITE_OK) return mapSqliteError(result);
        return maybe_statement orelse error.HostStorePrepareFailed;
    }

    fn execute(self: *Store, sql: [:0]const u8) !void {
        const result = c.sqlite3_exec(self.database, sql.ptr, null, null, null);
        if (result != c.SQLITE_OK) return mapSqliteError(result);
    }

    fn expectOneChange(self: *Store) !void {
        if (c.sqlite3_changes(self.database) != 1) return error.UnexpectedAffectedRows;
    }

    fn rollback(self: *Store) void {
        _ = c.sqlite3_exec(self.database, "ROLLBACK", null, null, null);
    }

    fn reach(self: *Store, point: CrashPoint) !void {
        if (self.fault_hook) |hook| try hook.reach(point);
    }
};

fn validateAdmitTurn(command: AdmitTurn) !void {
    if (command.session_id == 0 or command.turn_id == 0 or command.entry_id == 0 or
        command.content_id == 0 or command.turn_ordinal == 0 or
        command.workspace_path.len == 0 or command.workspace_path.len > max_path_bytes or
        !std.unicode.utf8ValidateSlice(command.workspace_path) or
        command.user_text.len == 0 or command.user_text.len > max_text_bytes or
        !std.unicode.utf8ValidateSlice(command.user_text))
    {
        return error.InvalidTurnAdmission;
    }
}

fn validateOperation(command: AdmitOperation) !void {
    if (command.turn_id == 0 or command.operation_id == 0 or command.operation_ordinal == 0 or
        command.kind != .model or command.descriptor_content_id == 0 or command.descriptor.len == 0 or
        command.descriptor.len > max_text_bytes or
        !std.mem.eql(u8, &command.descriptor_digest, &semanticDigest(.operation, command.descriptor)))
    {
        return error.InvalidOperationAdmission;
    }
}

fn validateAttempt(command: AdmitAttempt) !void {
    if (command.operation_id == 0 or command.attempt_id == 0 or command.attempt_ordinal == 0 or
        command.dispatch_content_id == 0 or command.parameters_content_id == 0 or
        command.dispatch_content_id == command.parameters_content_id or
        command.dispatch_request.len == 0 or command.dispatch_request.len > max_text_bytes or
        command.parameters.len == 0 or command.parameters.len > max_text_bytes or
        !std.mem.eql(u8, &command.dispatch_digest, &semanticDigest(.dispatch, command.dispatch_request)))
    {
        return error.InvalidAttemptAdmission;
    }
    if (command.external_idempotency_key) |key| {
        if (key.len == 0 or key.len > 256 or !std.unicode.utf8ValidateSlice(key)) {
            return error.InvalidAttemptAdmission;
        }
    }
}

fn validateCompletion(command: CompleteAndResolve) !void {
    if (command.operation_id == 0 or command.attempt_id == 0 or command.completion_id == 0 or
        command.completion_ordinal == 0 or command.completion_content_id == 0 or
        command.result_content_id == 0 or command.completion_content_id == command.result_content_id or
        command.completion_content.len == 0 or command.completion_content.len > max_text_bytes or
        command.result_content.len == 0 or command.result_content.len > max_text_bytes or
        !std.mem.eql(u8, &command.completion_digest, &semanticDigest(.completion, command.completion_content)) or
        !std.mem.eql(u8, &command.resolution_digest, &semanticDigest(.resolution, command.result_content)))
    {
        return error.InvalidCompletionAdmission;
    }
}

fn validateRecordedCompletion(command: RecordCompletion) !void {
    if (command.operation_id == 0 or command.attempt_id == 0 or command.completion_id == 0 or
        command.completion_ordinal == 0 or command.content_id == 0 or
        command.content.len == 0 or command.content.len > max_text_bytes or
        !std.mem.eql(u8, &command.completion_digest, &semanticDigest(.completion, command.content)))
    {
        return error.InvalidCompletionAdmission;
    }
}

/// The synchronous V1 CLI is the Host for one invocation. This kernel lock is
/// held for the Store lifetime, so another process cannot infer lost volatile
/// custody while the owning Host is still alive.
fn acquireHostLock(database_path: []const u8) !c_int {
    var path: [max_path_bytes + ".lock".len:0]u8 = undefined;
    if (database_path.len + ".lock".len > path.len) return error.InvalidHostStorePath;
    @memcpy(path[0..database_path.len], database_path);
    @memcpy(path[database_path.len..][0..".lock".len], ".lock");
    path[database_path.len + ".lock".len] = 0;
    const descriptor = c.open(&path, c.O_RDWR | c.O_CREAT, @as(c_uint, 0o600));
    if (descriptor < 0) return error.HostStoreLockOpenFailed;
    errdefer _ = c.close(descriptor);
    if (c.flock(descriptor, c.LOCK_EX | c.LOCK_NB) != 0) return error.HostStoreBusy;
    return descriptor;
}

fn releaseHostLock(descriptor: c_int) void {
    _ = c.flock(descriptor, c.LOCK_UN);
    _ = c.close(descriptor);
}

fn validateSettlement(command: SettleTurn) !void {
    if (command.turn_id == 0 or command.outcome == .completed) return error.InvalidTurnSettlement;
    switch (command.outcome) {
        .cancelled => if (command.failure_content_id != null or command.failure_message != null or
            command.failure_code != null) return error.InvalidTurnSettlement,
        .failed => {
            const message = command.failure_message orelse return error.InvalidTurnSettlement;
            if (command.failure_content_id == null or command.failure_code == null or
                command.failure_code.? == 0 or message.len == 0 or message.len > max_text_bytes or
                !std.unicode.utf8ValidateSlice(message)) return error.InvalidTurnSettlement;
        },
        .completed => unreachable,
    }
}

fn validateModelToolCalls(command: AdmitModelToolCalls) !void {
    if (command.turn_id == 0 or command.model_operation_id == 0 or command.attempt_id == 0 or
        command.completion_id == 0 or command.completion_content_id == 0 or
        command.calls.len == 0 or command.calls.len > 8 or
        command.captured_output.len == 0 or command.captured_output.len > max_text_bytes or
        !std.mem.eql(u8, &command.completion_digest, &semanticDigest(.completion, command.captured_output)))
    {
        return error.InvalidModelOutput;
    }
    for (command.calls, 0..) |call, index| {
        if (call.entry_id == 0 or call.content_id == 0 or call.action_operation_id == 0 or
            call.action_operation_ordinal == 0 or call.action_kind == .model or
            call.descriptor_content_id == 0 or call.content.len == 0 or
            call.content.len > max_text_bytes or call.descriptor.len == 0 or
            call.descriptor.len > max_text_bytes or
            !std.mem.eql(u8, &call.descriptor_digest, &semanticDigest(.operation, call.descriptor)))
        {
            return error.InvalidModelOutput;
        }
        const admitted_call = conversation.decodeToolCall(call.content) catch
            return error.InvalidModelOutput;
        const expected_key = switch (call.action_kind) {
            .bash => model_contract.bash_key,
            .apply_patch => model_contract.apply_patch_key,
            .model => unreachable,
        };
        if (!std.mem.eql(u8, admitted_call.key, expected_key)) {
            return error.InvalidActionProvenance;
        }
        for (command.calls[0..index]) |earlier| {
            const current_ids = [_]u64{ call.entry_id, call.content_id, call.action_operation_id, call.descriptor_content_id };
            const earlier_ids = [_]u64{ earlier.entry_id, earlier.content_id, earlier.action_operation_id, earlier.descriptor_content_id };
            for (current_ids) |current_id| for (earlier_ids) |earlier_id| {
                if (current_id == earlier_id) return error.InvalidModelOutput;
            };
        }
    }
    try validateCapturedModelToolCalls(command.captured_output, command.calls);
}

fn validateCapturedModelToolCalls(
    captured_output: []const u8,
    calls: []const ToolCallCandidate,
) !void {
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = model_protocol.decode(&scratch, captured_output) catch
        return error.InvalidModelOutput;
    if (parsed.disposition != .tool_calls or parsed.tool_call_count != calls.len) {
        return error.InvalidModelOutput;
    }
    for (calls, 0..) |call, index| {
        const expected = conversation.decodeToolCall(call.content) catch
            return error.InvalidModelOutput;
        const span = parsed.tool_calls[index];
        const key = captured_output[span.key_offset..][0..span.key_length];
        const arguments = captured_output[span.arguments_offset..][0..span.arguments_length];
        if (!std.mem.eql(u8, key, expected.key) or
            !std.mem.eql(u8, arguments, expected.arguments)) return error.InvalidModelOutput;
    }
}

fn validateCompleteTurn(command: CompleteTurn) !void {
    if (command.turn_id == 0 or command.model_operation_id == 0 or command.attempt_id == 0 or
        command.completion_id == 0 or command.completion_content_id == 0 or
        command.final_entry_id == 0 or command.final_content_id == 0 or
        command.completion_content_id == command.final_content_id or
        command.captured_output.len == 0 or command.captured_output.len > max_text_bytes or
        command.final_answer.len == 0 or command.final_answer.len > max_text_bytes or
        !std.unicode.utf8ValidateSlice(command.final_answer) or
        !std.mem.eql(u8, &command.completion_digest, &semanticDigest(.completion, command.captured_output)))
    {
        return error.InvalidTurnCompletion;
    }
}

fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    const wide: u64 = @intCast(value);
    if (wide == 0 or wide > std.math.maxInt(i64)) return error.InvalidIdentity;
    const result = c.sqlite3_bind_int64(statement, index, @intCast(wide));
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindU64AllowZero(statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.InvalidIdentity;
    const result = c.sqlite3_bind_int64(statement, index, @intCast(value));
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindOptionalU64(statement: *c.sqlite3_stmt, index: c_int, value: ?u64) !void {
    if (value) |present| return bindU64(statement, index, present);
    return bindNull(statement, index);
}

fn bindOptionalU64AllowZero(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (value) |present| return bindU64AllowZero(statement, index, @intCast(present));
    return bindNull(statement, index);
}

fn bindNull(statement: *c.sqlite3_stmt, index: c_int) !void {
    const result = c.sqlite3_bind_null(statement, index);
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const result = c.sqlite3_bind_blob64(statement, index, bytes.ptr, bytes.len, null);
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const result = c.sqlite3_bind_text64(statement, index, bytes.ptr, bytes.len, null, c.SQLITE_UTF8);
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn done(statement: *c.sqlite3_stmt) !void {
    const result = c.sqlite3_step(statement);
    if (result != c.SQLITE_DONE) return mapSqliteError(result);
}

fn finalize(statement: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(statement);
}

fn positiveColumn(statement: *c.sqlite3_stmt, index: c_int) !u64 {
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.CorruptHostStore;
    return @intCast(value);
}

fn nonnegativeColumn(statement: *c.sqlite3_stmt, index: c_int) !u64 {
    const value = c.sqlite3_column_int64(statement, index);
    if (value < 0) return error.CorruptHostStore;
    return @intCast(value);
}

fn optionalPositiveColumn(statement: *c.sqlite3_stmt, index: c_int) !?u64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    return try positiveColumn(statement, index);
}

fn optionalNonnegativeColumn(statement: *c.sqlite3_stmt, index: c_int) !?u64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    return try nonnegativeColumn(statement, index);
}

fn digestColumn(statement: *c.sqlite3_stmt, index: c_int) !Digest {
    if (c.sqlite3_column_bytes(statement, index) != 32) return error.CorruptHostStore;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptHostStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..32].*;
}

fn columnTextEquals(statement: *c.sqlite3_stmt, index: c_int, expected: []const u8) bool {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0 or length != expected.len) return false;
    const pointer = c.sqlite3_column_text(statement, index) orelse return false;
    return std.mem.eql(u8, pointer[0..@intCast(length)], expected);
}

fn optionalColumnTextEquals(
    statement: *c.sqlite3_stmt,
    index: c_int,
    expected: ?[]const u8,
) bool {
    if (expected) |bytes| return columnTextEquals(statement, index, bytes);
    return c.sqlite3_column_type(statement, index) == c.SQLITE_NULL;
}

fn columnBlobEquals(statement: *c.sqlite3_stmt, index: c_int, expected: []const u8) bool {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0 or length != expected.len) return false;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return false;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return std.mem.eql(u8, bytes[0..@intCast(length)], expected);
}

fn mapSqliteError(result: c_int) anyerror {
    return switch (result & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.HostStoreBusy,
        c.SQLITE_FULL => error.HostStoreFull,
        c.SQLITE_IOERR => error.HostStoreIo,
        c.SQLITE_CORRUPT => error.CorruptHostStore,
        c.SQLITE_NOTADB => error.NotAHostStore,
        c.SQLITE_NOMEM => error.HostStoreNoMemory,
        c.SQLITE_CONSTRAINT => error.HostStoreConstraint,
        else => error.HostStoreFailure,
    };
}
