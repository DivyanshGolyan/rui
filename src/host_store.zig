const std = @import("std");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const session_transition = @import("session_transition.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema_version: u32 = 4;
pub const application_id: u32 = 0x4f4e5047; // "ONPG"
pub const max_path_bytes: usize = 1024;
pub const max_transition_payload: usize = session_transition.max_payload_size;
pub const max_workspace_path_bytes: usize = 1024;
pub const max_model_bytes: usize = 128;

comptime {
    std.debug.assert(max_transition_payload == 996);
}

const session_schema =
    \\CREATE TABLE session (
    \\    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 8),
    \\    agent_id BLOB NOT NULL CHECK (length(agent_id) = 8),
    \\    task_id BLOB NOT NULL CHECK (length(task_id) = 8),
    \\    branch_id BLOB NOT NULL CHECK (length(branch_id) = 8),
    \\    workspace_path TEXT NOT NULL CHECK (length(workspace_path) BETWEEN 1 AND 1024),
    \\    model TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128),
    \\    ownership_epoch INTEGER NOT NULL DEFAULT 1 CHECK (ownership_epoch > 0),
    \\    head_sequence INTEGER NOT NULL DEFAULT 0 CHECK (head_sequence >= 0),
    \\    UNIQUE (agent_id),
    \\    UNIQUE (task_id),
    \\    UNIQUE (branch_id)
    \\) STRICT
;
const transition_schema =
    \\CREATE TABLE session_transition (
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    sequence INTEGER NOT NULL CHECK (sequence > 0),
    \\    payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 996),
    \\    record_digest BLOB NOT NULL CHECK (length(record_digest) = 32),
    \\    PRIMARY KEY (session_id, sequence),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id)
    \\) STRICT, WITHOUT ROWID
;
const conversation_schema =
    \\CREATE TABLE conversation_entry (
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    entry_id BLOB NOT NULL CHECK (length(entry_id) = 8),
    \\    parent_id BLOB CHECK (parent_id IS NULL OR length(parent_id) = 8),
    \\    kind INTEGER NOT NULL CHECK (kind BETWEEN 1 AND 4),
    \\    content_ref BLOB NOT NULL CHECK (length(content_ref) = 8),
    \\    committed_by_sequence INTEGER NOT NULL,
    \\    PRIMARY KEY (session_id, entry_id),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (session_id, committed_by_sequence)
    \\        REFERENCES session_transition (session_id, sequence)
    \\) STRICT
;
const completion_schema =
    \\CREATE TABLE completion_inbox (
    \\    inbox_id INTEGER PRIMARY KEY,
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    ownership_epoch BLOB NOT NULL CHECK (length(ownership_epoch) = 8),
    \\    agent_generation INTEGER NOT NULL CHECK (agent_generation > 0),
    \\    operation_id BLOB NOT NULL CHECK (length(operation_id) = 8),
    \\    operation_generation INTEGER NOT NULL CHECK (operation_generation > 0),
    \\    attempt_id BLOB NOT NULL CHECK (length(attempt_id) = 8),
    \\    evidence_kind INTEGER NOT NULL CHECK (evidence_kind > 0),
    \\    result_reference BLOB NOT NULL CHECK (length(result_reference) = 8),
    \\    result_digest BLOB NOT NULL CHECK (length(result_digest) = 32),
    \\    completion_digest BLOB NOT NULL CHECK (length(completion_digest) = 32),
    \\    consumed_by_sequence INTEGER,
    \\    UNIQUE (
    \\        session_id, agent_generation, operation_id,
    \\        operation_generation, attempt_id, evidence_kind
    \\    ),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (session_id, consumed_by_sequence)
    \\        REFERENCES session_transition (session_id, sequence)
    \\) STRICT
;
const completion_index_schema =
    \\CREATE INDEX completion_inbox_by_session
    \\ON completion_inbox (session_id, consumed_by_sequence, inbox_id)
;

const read_session_sql: [:0]const u8 =
    \\SELECT agent_id, task_id, branch_id, ownership_epoch, workspace_path, model
    \\FROM session WHERE session_id = ?1
;
const session_head_sql: [:0]const u8 =
    "SELECT head_sequence FROM session WHERE session_id = ?1";
const claim_ownership_sql: [:0]const u8 =
    \\UPDATE session SET ownership_epoch = ownership_epoch + 1
    \\WHERE session_id = ?1 AND ownership_epoch < 9223372036854775807
    \\RETURNING ownership_epoch
;
const completion_head_sql: [:0]const u8 =
    "SELECT inbox_id FROM completion_inbox WHERE session_id = ?1 AND consumed_by_sequence IS NULL ORDER BY inbox_id DESC LIMIT 1";
const pending_completion_count_sql: [:0]const u8 =
    \\SELECT count(p.inbox_id)
    \\FROM session AS s
    \\LEFT JOIN (
    \\    SELECT inbox_id, session_id FROM completion_inbox
    \\    WHERE session_id = ?1 AND consumed_by_sequence IS NULL
    \\    LIMIT 4096
    \\) AS p ON p.session_id = s.session_id
    \\WHERE s.session_id = ?1 AND s.agent_id = ?2
    \\GROUP BY s.session_id
;
const find_completion_sql: [:0]const u8 =
    \\SELECT c.inbox_id, c.result_reference, c.result_digest, c.completion_digest,
    \\       c.ownership_epoch, c.consumed_by_sequence
    \\FROM completion_inbox AS c
    \\JOIN session AS s ON s.session_id = c.session_id
    \\WHERE c.session_id = ?1 AND s.agent_id = ?2 AND c.agent_generation = ?3
    \\  AND c.operation_id = ?4 AND c.operation_generation = ?5
    \\  AND c.attempt_id = ?6 AND c.evidence_kind = ?7
;
const read_completion_sql: [:0]const u8 =
    \\SELECT c.evidence_kind, c.ownership_epoch, s.agent_id, c.agent_generation,
    \\       c.operation_id, c.operation_generation, c.attempt_id,
    \\       c.result_reference, c.result_digest, c.completion_digest, c.consumed_by_sequence
    \\FROM completion_inbox AS c
    \\JOIN session AS s ON s.session_id = c.session_id
    \\WHERE c.session_id = ?1 AND c.inbox_id = ?2
;
const read_completion_after_sql: [:0]const u8 =
    \\SELECT c.inbox_id, c.evidence_kind, c.ownership_epoch, s.agent_id,
    \\       c.agent_generation, c.operation_id, c.operation_generation,
    \\       c.attempt_id, c.result_reference, c.result_digest,
    \\       c.completion_digest, c.consumed_by_sequence
    \\FROM completion_inbox AS c
    \\JOIN session AS s ON s.session_id = c.session_id
    \\WHERE c.session_id = ?1 AND c.consumed_by_sequence IS NULL
    \\  AND c.inbox_id > ?2 AND c.inbox_id <= ?3
    \\ORDER BY c.inbox_id
    \\LIMIT 1
;
const advance_session_head_sql: [:0]const u8 =
    \\UPDATE session SET head_sequence = ?2
    \\WHERE session_id = ?1 AND ownership_epoch = ?3 AND head_sequence = ?4 AND agent_id = ?5
;
const associate_completion_sql: [:0]const u8 =
    \\UPDATE completion_inbox SET consumed_by_sequence = ?2
    \\WHERE session_id = ?1 AND consumed_by_sequence IS NULL
    \\  AND ownership_epoch = ?3 AND agent_generation = ?4
    \\  AND operation_id = ?5 AND operation_generation = ?6
    \\  AND attempt_id = ?7 AND evidence_kind = ?8
    \\  AND result_reference = ?9 AND result_digest = ?10
    \\  AND session_id IN (SELECT session_id FROM session WHERE agent_id = ?11)
;
const read_transition_sql: [:0]const u8 =
    \\SELECT sequence, payload, record_digest
    \\FROM session_transition
    \\WHERE session_id = ?1 AND sequence = ?2
;
const scan_completed_attempt_sql: [:0]const u8 =
    \\SELECT sequence, payload, record_digest
    \\FROM session_transition
    \\WHERE session_id = ?1 AND sequence >= ?2 AND sequence <= ?3
    \\ORDER BY sequence
;
const read_conversation_sql: [:0]const u8 =
    \\SELECT parent_id, kind, content_ref, committed_by_sequence
    \\FROM conversation_entry WHERE session_id = ?1 AND entry_id = ?2
;

pub const StoredTransition = struct {
    session_id: u64,
    sequence: u64,
    transaction: session_transition.Transaction,
};

pub const StoredCompletion = struct {
    inbox_id: u64,
    envelope: completion_inbox.Envelope,
    consumed_by_sequence: ?u64,
};

/// The exact admitted Attempt and the first terminal Result transaction for
/// its Operation. This is reconstructed from the authoritative bounded ledger
/// rather than retained as an unbounded resident history.
pub const CompletedAttempt = struct {
    attempt: session_transition.AttemptRecord,
    terminal_result_sequence: u64,
};

pub const CompletedAttemptScan = struct {
    next_sequence: u64 = 1,
    attempt: ?session_transition.AttemptRecord = null,
    terminal_before_attempt: bool = false,
    completed: ?CompletedAttempt = null,
    exhausted: bool = false,

    pub fn result(self: CompletedAttemptScan) ?CompletedAttempt {
        return self.completed;
    }

    pub fn done(self: CompletedAttemptScan) bool {
        return self.completed != null or self.exhausted;
    }
};

pub const StoredConversationEntry = struct {
    entry_id: u64,
    parent_id: u64,
    kind: u8,
    content_ref: u64,
    committed_by_sequence: u64,
};

pub const Config = struct {
    page_cache_kib: u16 = 64,
    maximum_page_count: u32 = 262_144,
    admission_reserve_pages: u16 = 16,
    fault: ?FaultHook = null,
};

pub const MemoryAccounting = struct {
    allowance_bytes: u64,
    heap_current_bytes: u64,
    heap_highwater_bytes: u64,
    page_cache_current_bytes: u64,
    lookaside_current_slots: u64,
    lookaside_highwater_slots: u64,
    statements_current_bytes: u64,
};

pub const FaultBoundary = enum {
    before_transition_read,
    after_transition_head_advance,
    after_transition_insert,
    before_commit,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, FaultBoundary) anyerror!void,
};

pub const SessionIdentity = struct {
    session_id: u64,
    agent_id: u64,
    task_id: u64,
    branch_id: u64,

    pub fn validate(self: SessionIdentity) !void {
        const values = [_]u64{
            self.session_id,
            self.agent_id,
            self.task_id,
            self.branch_id,
        };
        for (values, 0..) |value, index| {
            if (value == 0) return error.InvalidIdentity;
            for (values[index + 1 ..]) |other| {
                if (value == other) return error.InvalidIdentity;
            }
        }
    }
};

pub const SessionDescriptor = struct {
    identities: SessionIdentity,
    workspace_path: []const u8,
    model: []const u8,
};

pub const StoredSession = struct {
    identities: SessionIdentity,
    ownership_epoch: u64,
    workspace_path: [max_workspace_path_bytes]u8,
    workspace_path_length: u16,
    model: [max_model_bytes]u8,
    model_length: u8,

    pub fn workspacePath(self: *const StoredSession) []const u8 {
        return self.workspace_path[0..self.workspace_path_length];
    }

    pub fn modelName(self: *const StoredSession) []const u8 {
        return self.model[0..self.model_length];
    }
};

pub const OwnerToken = struct {
    session_id: u64,
    epoch: u64,
};

pub const StorageOwner = struct {
    io: std.Io,
    request_lock: std.Io.Mutex = .init,
    lock_file: std.Io.File,
    database: *c.sqlite3,
    fault: ?FaultHook,
    admission_reserve_pages: u16,
    open_: bool = true,
    failed_: bool = false,

    pub fn open(io: std.Io, path: []const u8, config: Config) !StorageOwner {
        try validateConfig(path, config);

        var lock_path_buffer: [max_path_bytes + 5]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_path_buffer, "{s}.lock", .{path});
        var lock_file = try openHostLock(io, lock_path);
        errdefer {
            lock_file.unlock(io);
            lock_file.close(io);
        }

        var terminated_path: [max_path_bytes:0]u8 = undefined;
        @memcpy(terminated_path[0..path.len], path);
        terminated_path[path.len] = 0;
        var maybe_database: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE |
            c.SQLITE_OPEN_NOMUTEX | c.SQLITE_OPEN_PRIVATECACHE;
        const open_result = c.sqlite3_open_v2(&terminated_path, &maybe_database, flags, null);
        if (open_result != c.SQLITE_OK) {
            if (maybe_database) |database| closeDatabase(database);
            return mapSqliteError(open_result);
        }
        const database = maybe_database orelse return error.HostStoreOpenFailed;
        errdefer closeDatabase(database);

        var owner: StorageOwner = .{
            .io = io,
            .lock_file = lock_file,
            .database = database,
            .fault = config.fault,
            .admission_reserve_pages = config.admission_reserve_pages,
        };
        const stored_application_id = try owner.pragmaU64("PRAGMA application_id");
        const stored_schema_version = try owner.pragmaU64("PRAGMA user_version");
        const install = stored_application_id == 0 and stored_schema_version == 0 and
            try owner.schemaIsEmpty();
        if (!install) {
            if (stored_application_id != application_id) return error.InvalidHostStoreIdentity;
            if (stored_schema_version != schema_version) return error.UnsupportedHostStoreVersion;
        }
        try owner.harden(config);
        if (install) try owner.installSchema();
        try owner.verifySchemaIdentity();
        try owner.validateSchemaShape();
        return owner;
    }

    pub fn close(self: *StorageOwner) void {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        if (!self.open_) return;
        const close_result = c.sqlite3_close_v2(self.database);
        std.debug.assert(close_result == c.SQLITE_OK);
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.open_ = false;
    }

    pub fn createSession(self: *StorageOwner, identity: SessionIdentity) !void {
        return self.createSessionWithMetadata(.{
            .identities = identity,
            .workspace_path = ".",
            .model = "fixture:test",
        }, initialTransaction(identity));
    }

    pub fn createSessionWithMetadata(
        self: *StorageOwner,
        descriptor: SessionDescriptor,
        transaction: session_transition.Transaction,
    ) !void {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        try descriptor.identities.validate();
        if (descriptor.workspace_path.len == 0 or
            descriptor.workspace_path.len > max_workspace_path_bytes or
            descriptor.model.len == 0 or descriptor.model.len > max_model_bytes)
        {
            return error.InvalidSessionMetadata;
        }
        if (transaction.sequence != 1) return error.InvalidTransitionSequence;
        try validateTransactionIdentity(descriptor.identities, transaction);
        var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
        const payload = try session_transition.encode(&payload_buffer, transaction);

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();
        const statement = try self.prepare(
            \\INSERT INTO session (
            \\    session_id, agent_id, task_id, branch_id, workspace_path, model, head_sequence
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1)
        );
        defer finalize(statement);
        var encoded_identities: [4][8]u8 = undefined;
        try bindIdentity(statement, 1, descriptor.identities.session_id, &encoded_identities[0]);
        try bindIdentity(statement, 2, descriptor.identities.agent_id, &encoded_identities[1]);
        try bindIdentity(statement, 3, descriptor.identities.task_id, &encoded_identities[2]);
        try bindIdentity(statement, 4, descriptor.identities.branch_id, &encoded_identities[3]);
        try bindText(statement, 5, descriptor.workspace_path);
        try bindText(statement, 6, descriptor.model);
        try expectDone(c.sqlite3_step(statement));
        try self.insertTransaction(descriptor.identities.session_id, transaction, payload);
        try self.ensureAdmissionCapacity();
        try self.execute("COMMIT");
    }

    pub fn memoryAccounting(self: *StorageOwner, reset_highwater: bool) !MemoryAccounting {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        var heap_current: c.sqlite3_int64 = 0;
        var heap_highwater: c.sqlite3_int64 = 0;
        try expectOk(c.sqlite3_status64(
            c.SQLITE_STATUS_MEMORY_USED,
            &heap_current,
            &heap_highwater,
            @intFromBool(reset_highwater),
        ));
        const cache = try self.databaseStatus(c.SQLITE_DBSTATUS_CACHE_USED, reset_highwater);
        const lookaside = try self.databaseStatus(c.SQLITE_DBSTATUS_LOOKASIDE_USED, reset_highwater);
        const statements = try self.databaseStatus(c.SQLITE_DBSTATUS_STMT_USED, reset_highwater);
        return .{
            .allowance_bytes = try processHeapLimit(),
            .heap_current_bytes = try nonnegative(heap_current),
            .heap_highwater_bytes = try nonnegative(heap_highwater),
            .page_cache_current_bytes = cache.current,
            .lookaside_current_slots = lookaside.current,
            .lookaside_highwater_slots = lookaside.highwater,
            .statements_current_bytes = statements.current,
        };
    }

    pub fn readSession(self: *StorageOwner, session_id: u64) !StoredSession {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(read_session_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.SessionNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const ownership_epoch = c.sqlite3_column_int64(statement, 3);
        const workspace_length = c.sqlite3_column_bytes(statement, 4);
        const model_length = c.sqlite3_column_bytes(statement, 5);
        if (ownership_epoch <= 0 or workspace_length <= 0 or workspace_length > max_workspace_path_bytes or
            model_length <= 0 or model_length > max_model_bytes)
        {
            return error.CorruptHostStore;
        }
        var stored: StoredSession = .{
            .identities = .{
                .session_id = session_id,
                .agent_id = try readIdentityColumn(statement, 0),
                .task_id = try readIdentityColumn(statement, 1),
                .branch_id = try readIdentityColumn(statement, 2),
            },
            .ownership_epoch = @intCast(ownership_epoch),
            .workspace_path = undefined,
            .workspace_path_length = @intCast(workspace_length),
            .model = undefined,
            .model_length = @intCast(model_length),
        };
        try stored.identities.validate();
        const workspace_pointer = c.sqlite3_column_text(statement, 4) orelse {
            return error.CorruptHostStore;
        };
        const model_pointer = c.sqlite3_column_text(statement, 5) orelse {
            return error.CorruptHostStore;
        };
        @memcpy(
            stored.workspace_path[0..stored.workspace_path_length],
            workspace_pointer[0..stored.workspace_path_length],
        );
        @memcpy(stored.model[0..stored.model_length], model_pointer[0..stored.model_length]);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return stored;
    }

    pub fn sessionHead(self: *StorageOwner, session_id: u64) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(session_head_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return 0;
        if (step_result != c.SQLITE_ROW) return mapSqliteError(step_result);
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @intCast(value);
    }

    pub fn claimSession(self: *StorageOwner, session_id: u64) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(claim_ownership_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.SessionNotFoundOrEpochExhausted;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const epoch = c.sqlite3_column_int64(statement, 0);
        if (epoch <= 1) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @intCast(epoch);
    }

    pub fn completionHead(self: *StorageOwner, session_id: u64) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(completion_head_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return 0;
        if (step_result != c.SQLITE_ROW) return mapSqliteError(step_result);
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @intCast(value);
    }

    pub fn publishCompletion(
        self: *StorageOwner,
        envelope: completion_inbox.Envelope,
    ) !u64 {
        return self.publishCompletionState(envelope, null);
    }

    pub fn publishAuditedCompletion(
        self: *StorageOwner,
        envelope: completion_inbox.Envelope,
        consumed_by_sequence: u64,
    ) !u64 {
        if (consumed_by_sequence == 0) return error.InvalidSequence;
        return self.publishCompletionState(envelope, consumed_by_sequence);
    }

    fn publishCompletionState(
        self: *StorageOwner,
        envelope: completion_inbox.Envelope,
        consumed_by_sequence: ?u64,
    ) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        try completion_inbox.validate(envelope);

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();

        var identities: [6][8]u8 = undefined;
        const existing = try self.prepare(find_completion_sql);
        defer finalize(existing);
        try bindIdentity(existing, 1, envelope.session_id, &identities[0]);
        try bindIdentity(existing, 2, envelope.agent_id, &identities[2]);
        try bindU64(existing, 3, envelope.agent_generation);
        try bindIdentity(existing, 4, envelope.operation_id, &identities[3]);
        try bindU64(existing, 5, envelope.operation_generation);
        try bindIdentity(existing, 6, envelope.attempt_id, &identities[4]);
        try bindU64(existing, 7, @intFromEnum(envelope.kind));
        const existing_result = c.sqlite3_step(existing);
        if (existing_result == c.SQLITE_ROW) {
            const sequence = c.sqlite3_column_int64(existing, 0);
            const result_ref = try readIdentityColumn(existing, 1);
            const result_digest = try readBindingColumn(binding.Result, existing, 2);
            const completion_digest = try readBindingColumn(binding.Completion, existing, 3);
            const ownership_epoch = try readIdentityColumn(existing, 4);
            if (sequence <= 0) return error.CorruptHostStore;
            if (ownership_epoch != envelope.ownership_epoch or result_ref != envelope.result_ref or
                !binding.eql(binding.Result, result_digest, envelope.result_digest) or
                !binding.eql(binding.Completion, completion_digest, envelope.completion_digest))
            {
                return error.ConflictingCompletionEvidence;
            }
            if (consumed_by_sequence) |sequence_value| {
                if (c.sqlite3_column_type(existing, 5) == c.SQLITE_NULL) {
                    const audit = try self.prepare(
                        "UPDATE completion_inbox SET consumed_by_sequence = ?2 WHERE inbox_id = ?1 AND consumed_by_sequence IS NULL",
                    );
                    defer finalize(audit);
                    try bindU64(audit, 1, @intCast(sequence));
                    try bindU64(audit, 2, sequence_value);
                    if (c.sqlite3_step(audit) != c.SQLITE_DONE) return error.CorruptHostStore;
                }
            }
            if (c.sqlite3_step(existing) != c.SQLITE_DONE) return error.CorruptHostStore;
            try self.execute("COMMIT");
            return @intCast(sequence);
        }
        if (existing_result != c.SQLITE_DONE) return mapSqliteError(existing_result);

        if (consumed_by_sequence == null) {
            const count = try self.prepare(pending_completion_count_sql);
            defer finalize(count);
            try bindIdentity(count, 1, envelope.session_id, &identities[0]);
            try bindIdentity(count, 2, envelope.agent_id, &identities[2]);
            const count_result = c.sqlite3_step(count);
            if (count_result == c.SQLITE_DONE) return error.InvalidCompletionIdentity;
            if (count_result != c.SQLITE_ROW) return mapSqliteError(count_result);
            const pending_count = c.sqlite3_column_int64(count, 0);
            if (pending_count < 0) return error.CorruptHostStore;
            if (pending_count >= completion_inbox.max_records) {
                return error.CompletionCapacityExceeded;
            }
            if (c.sqlite3_step(count) != c.SQLITE_DONE) return error.CorruptHostStore;
        }

        const insert = try self.prepare(
            \\INSERT INTO completion_inbox (
            \\    session_id, ownership_epoch, agent_generation,
            \\    operation_id, operation_generation, attempt_id, evidence_kind,
            \\    result_reference, result_digest, completion_digest, consumed_by_sequence
            \\) SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?12
            \\  FROM session WHERE session_id = ?1 AND agent_id = ?11
            \\RETURNING inbox_id
        );
        defer finalize(insert);
        try bindIdentity(insert, 1, envelope.session_id, &identities[0]);
        try bindIdentity(insert, 2, envelope.ownership_epoch, &identities[1]);
        try bindU64(insert, 3, envelope.agent_generation);
        try bindIdentity(insert, 4, envelope.operation_id, &identities[3]);
        try bindU64(insert, 5, envelope.operation_generation);
        try bindIdentity(insert, 6, envelope.attempt_id, &identities[4]);
        try bindU64(insert, 7, @intFromEnum(envelope.kind));
        try bindIdentity(insert, 8, envelope.result_ref, &identities[5]);
        try bindBlob(insert, 9, &envelope.result_digest.bytes);
        try bindBlob(insert, 10, &envelope.completion_digest.bytes);
        try bindIdentity(insert, 11, envelope.agent_id, &identities[2]);
        if (consumed_by_sequence) |sequence_value| {
            try bindU64(insert, 12, sequence_value);
        } else try expectOk(c.sqlite3_bind_null(insert, 12));
        const insert_result = c.sqlite3_step(insert);
        if (insert_result == c.SQLITE_DONE) return error.InvalidCompletionIdentity;
        if (insert_result != c.SQLITE_ROW) return mapSqliteError(insert_result);
        const inbox_id = c.sqlite3_column_int64(insert, 0);
        if (inbox_id <= 0) return error.CorruptHostStore;
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.CorruptHostStore;
        try self.execute("COMMIT");
        return @intCast(inbox_id);
    }

    pub fn readCompletion(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
    ) !StoredCompletion {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        if (sequence == 0 or sequence > std.math.maxInt(i64)) return error.InvalidSequence;
        const statement = try self.prepare(read_completion_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        try bindU64(statement, 2, sequence);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.CompletionNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const kind_value = c.sqlite3_column_int64(statement, 0);
        if (kind_value <= 0 or kind_value > std.math.maxInt(u8)) return error.CorruptHostStore;
        const envelope: completion_inbox.Envelope = .{
            .kind = std.enums.fromInt(
                completion_inbox.EvidenceKind,
                @as(u8, @intCast(kind_value)),
            ) orelse return error.UnsupportedCompletionKind,
            .session_id = session_id,
            .ownership_epoch = try readIdentityColumn(statement, 1),
            .agent_id = try readIdentityColumn(statement, 2),
            .agent_generation = try readPositiveU32Column(statement, 3),
            .operation_id = try readIdentityColumn(statement, 4),
            .operation_generation = try readPositiveU32Column(statement, 5),
            .attempt_id = try readIdentityColumn(statement, 6),
            .result_ref = try readIdentityColumn(statement, 7),
            .result_digest = try readBindingColumn(binding.Result, statement, 8),
            .completion_digest = try readBindingColumn(binding.Completion, statement, 9),
        };
        try completion_inbox.validate(envelope);
        const consumed_by_sequence: ?u64 = switch (c.sqlite3_column_type(statement, 10)) {
            c.SQLITE_NULL => null,
            c.SQLITE_INTEGER => consumed: {
                const consumed = c.sqlite3_column_int64(statement, 10);
                if (consumed <= 0) return error.CorruptHostStore;
                break :consumed @intCast(consumed);
            },
            else => return error.CorruptHostStore,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return .{ .inbox_id = sequence, .envelope = envelope, .consumed_by_sequence = consumed_by_sequence };
    }

    pub fn readCompletionAfter(
        self: *StorageOwner,
        session_id: u64,
        after_id: u64,
        through_id: u64,
    ) !?StoredCompletion {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0 or after_id > through_id or through_id > std.math.maxInt(i64)) {
            return error.InvalidSequence;
        }
        const statement = try self.prepare(read_completion_after_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        try bindU64(statement, 2, after_id);
        try bindU64(statement, 3, through_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const inbox_id_value = c.sqlite3_column_int64(statement, 0);
        const kind_value = c.sqlite3_column_int64(statement, 1);
        if (inbox_id_value <= 0 or kind_value <= 0 or kind_value > std.math.maxInt(u8)) {
            return error.CorruptHostStore;
        }
        const stored: StoredCompletion = .{
            .inbox_id = @intCast(inbox_id_value),
            .envelope = .{
                .kind = std.enums.fromInt(
                    completion_inbox.EvidenceKind,
                    @as(u8, @intCast(kind_value)),
                ) orelse return error.UnsupportedCompletionKind,
                .session_id = session_id,
                .ownership_epoch = try readIdentityColumn(statement, 2),
                .agent_id = try readIdentityColumn(statement, 3),
                .agent_generation = try readPositiveU32Column(statement, 4),
                .operation_id = try readIdentityColumn(statement, 5),
                .operation_generation = try readPositiveU32Column(statement, 6),
                .attempt_id = try readIdentityColumn(statement, 7),
                .result_ref = try readIdentityColumn(statement, 8),
                .result_digest = try readBindingColumn(binding.Result, statement, 9),
                .completion_digest = try readBindingColumn(binding.Completion, statement, 10),
            },
            .consumed_by_sequence = switch (c.sqlite3_column_type(statement, 11)) {
                c.SQLITE_NULL => null,
                c.SQLITE_INTEGER => consumed: {
                    const value = c.sqlite3_column_int64(statement, 11);
                    if (value <= 0) return error.CorruptHostStore;
                    break :consumed @intCast(value);
                },
                else => return error.CorruptHostStore,
            },
        };
        try completion_inbox.validate(stored.envelope);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return stored;
    }

    pub fn commit(
        self: *StorageOwner,
        token: OwnerToken,
        transaction: session_transition.Transaction,
    ) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (token.session_id == 0 or token.epoch == 0) return error.StaleOwner;
        if (transaction.sequence == 0 or transaction.sequence > session_transition.max_transitions) {
            return error.SessionSequenceExhausted;
        }
        var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
        const payload = try session_transition.encode(&payload_buffer, transaction);
        const agent_id = try validateCommitIdentity(token, transaction);
        const expected_sequence = transaction.sequence - 1;

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();
        const advance = try self.prepare(advance_session_head_sql);
        defer finalize(advance);
        var identities: [2][8]u8 = undefined;
        try bindIdentity(advance, 1, token.session_id, &identities[0]);
        try bindU64(advance, 2, transaction.sequence);
        try bindU64(advance, 3, token.epoch);
        try bindU64(advance, 4, expected_sequence);
        try bindIdentity(advance, 5, agent_id, &identities[1]);
        try expectDone(c.sqlite3_step(advance));
        if (c.sqlite3_changes(self.database) != 1) return error.StaleOwnerOrSequenceConflict;
        try self.reach(.after_transition_head_advance);
        try self.insertTransaction(token.session_id, transaction, payload);
        if (isAdmission(transaction)) try self.ensureAdmissionCapacity();
        try self.reach(.before_commit);
        try self.execute("COMMIT");
        return transaction.sequence;
    }

    fn insertTransaction(
        self: *StorageOwner,
        session_id: u64,
        transaction: session_transition.Transaction,
        payload: []const u8,
    ) !void {
        const digest = recordDigest(session_id, transaction.sequence, payload);
        const insert = try self.prepare(
            \\INSERT INTO session_transition (session_id, sequence, payload, record_digest)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer finalize(insert);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(insert, 1, session_id, &encoded_session_id);
        try bindU64(insert, 2, transaction.sequence);
        try bindBlob(insert, 3, payload);
        try bindBlob(insert, 4, &digest.bytes);
        try expectDone(c.sqlite3_step(insert));
        try self.reach(.after_transition_insert);

        for (transaction.factSlice()) |fact| switch (fact) {
            .conversation_advanced => |advanced| try self.commitConversation(
                session_id,
                transaction.sequence,
                advanced.entry_id,
                advanced.parent_id,
                advanced.kind,
                advanced.content_ref,
            ),
            .result => |result| switch (result.evidence) {
                .immediate => {},
                .durable => |evidence| try self.associateCompletion(
                    session_id,
                    transaction.sequence,
                    result,
                    evidence,
                ),
            },
            .task_admitted,
            .operation_submitted,
            .operation_accepted,
            .attempt_admitted,
            .authorization,
            .outcome,
            .cancellation,
            .shutdown,
            .result_applied,
            .approval_required,
            => {},
        };
    }

    fn associateCompletion(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        result: session_transition.ResultRecord,
        evidence: session_transition.DurableResultEvidence,
    ) !void {
        const operation = result.operation;
        const attempt_id: u64 = switch (evidence) {
            inline else => |value| value,
        };
        const evidence_kind = std.meta.activeTag(evidence);
        var ids: [6][8]u8 = undefined;
        const statement = try self.prepare(associate_completion_sql);
        defer finalize(statement);
        try bindIdentity(statement, 1, session_id, &ids[0]);
        try bindU64(statement, 2, sequence);
        try bindIdentity(statement, 3, operation.agent.ownership_epoch, &ids[1]);
        try bindU64(statement, 4, operation.agent.agent_generation);
        try bindIdentity(statement, 5, operation.operation_id, &ids[2]);
        try bindU64(statement, 6, operation.generation);
        try bindIdentity(statement, 7, attempt_id, &ids[3]);
        try bindU64(statement, 8, @intFromEnum(evidence_kind));
        try bindIdentity(statement, 9, result.result_ref, &ids[4]);
        try bindBlob(statement, 10, &result.result_digest.bytes);
        try bindIdentity(statement, 11, operation.agent.agent_id, &ids[5]);
        try expectDone(c.sqlite3_step(statement));
        if (c.sqlite3_changes(self.database) != 1) return error.CompletionEvidenceMissing;
    }

    fn commitConversation(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        entry_id: u64,
        parent_id: u64,
        kind: session_transition.ConversationKind,
        content_ref: u64,
    ) !void {
        var ids: [4][8]u8 = undefined;
        const insert = try self.prepare(
            \\INSERT INTO conversation_entry (
            \\    session_id, entry_id, parent_id, kind, content_ref, committed_by_sequence
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        );
        defer finalize(insert);
        try bindIdentity(insert, 1, session_id, &ids[0]);
        try bindIdentity(insert, 2, entry_id, &ids[1]);
        if (parent_id == 0) try expectOk(c.sqlite3_bind_null(insert, 3)) else try bindIdentity(insert, 3, parent_id, &ids[2]);
        try bindU64(insert, 4, @intFromEnum(kind));
        try bindIdentity(insert, 5, content_ref, &ids[3]);
        try bindU64(insert, 6, sequence);
        try expectDone(c.sqlite3_step(insert));
    }

    pub fn readTransition(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        out: *StoredTransition,
    ) !void {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (self.fault) |hook| try hook.reached(hook.context, .before_transition_read);
        if (session_id == 0) return error.InvalidIdentity;
        if (sequence == 0 or sequence > std.math.maxInt(i64)) return error.InvalidSequence;

        const statement = try self.prepare(read_transition_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        try bindU64(statement, 2, sequence);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.TransitionNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        try decodeVerifiedTransitionRow(statement, session_id, sequence, out);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    pub fn scanCompletedAttemptWindow(
        self: *StorageOwner,
        session_id: u64,
        operation_id: u64,
        operation_generation: u32,
        attempt_id: u64,
        ledger_head: u64,
        row_budget: u8,
        scan: *CompletedAttemptScan,
    ) !u8 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        if (session_id == 0 or operation_id == 0 or operation_generation == 0 or attempt_id == 0) {
            return error.InvalidIdentity;
        }
        if (ledger_head == 0 or ledger_head > session_transition.max_transitions or row_budget == 0) {
            return error.InvalidHistoricalScanRange;
        }
        if (scan.next_sequence == 0 or scan.next_sequence > ledger_head + 1) {
            return error.InvalidHistoricalScanCursor;
        }
        if (scan.done()) return 0;
        const last_sequence = @min(
            ledger_head,
            scan.next_sequence + @as(u64, row_budget) - 1,
        );

        const statement = try self.prepare(scan_completed_attempt_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        try bindU64(statement, 2, scan.next_sequence);
        try bindU64(statement, 3, last_sequence);

        var processed: u8 = 0;
        while (processed < row_budget and scan.next_sequence <= last_sequence) {
            const step = c.sqlite3_step(statement);
            if (step == c.SQLITE_DONE) return error.TransitionNotFound;
            if (step != c.SQLITE_ROW) return mapSqliteError(step);
            var stored: StoredTransition = undefined;
            try decodeVerifiedTransitionRow(statement, session_id, scan.next_sequence, &stored);
            scan.next_sequence += 1;
            processed += 1;
            try applyCompletedAttemptFacts(
                scan,
                stored.transaction,
                operation_id,
                operation_generation,
                attempt_id,
            );
            if (scan.completed != null) break;
        }
        if (scan.completed == null and scan.next_sequence > ledger_head) scan.exhausted = true;
        return processed;
    }

    pub fn readConversationEntry(
        self: *StorageOwner,
        session_id: u64,
        entry_id: u64,
    ) !StoredConversationEntry {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const statement = try self.prepare(read_conversation_sql);
        defer finalize(statement);
        var ids: [2][8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &ids[0]);
        try bindIdentity(statement, 2, entry_id, &ids[1]);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.ConversationEntryNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const parent_id: u64 = if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL)
            0
        else
            try readIdentityColumn(statement, 0);
        const kind = c.sqlite3_column_int64(statement, 1);
        if (kind < 1 or kind > 4) return error.CorruptHostStore;
        if (c.sqlite3_column_type(statement, 3) != c.SQLITE_INTEGER) return error.CorruptHostStore;
        const committed_value = c.sqlite3_column_int64(statement, 3);
        if (committed_value <= 0) return error.CorruptHostStore;
        const committed: u64 = @intCast(committed_value);
        const stored: StoredConversationEntry = .{
            .entry_id = entry_id,
            .parent_id = parent_id,
            .kind = @intCast(kind),
            .content_ref = try readIdentityColumn(statement, 2),
            .committed_by_sequence = committed,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return stored;
    }

    fn harden(self: *StorageOwner, config: Config) !void {
        try expectOk(c.sqlite3_extended_result_codes(self.database, 1));
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DQS_DDL, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DQS_DML, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_ENABLE_FKEY, 1);

        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_LENGTH, 1_048_576);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_SQL_LENGTH, 65_536);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_COLUMN, 64);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_COMPOUND_SELECT, 8);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_VDBE_OP, 100_000);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_ATTACHED, 0);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 256);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_VARIABLE_NUMBER, 64);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_WORKER_THREADS, 0);

        try self.execute("PRAGMA page_size=4096");
        try self.execute("PRAGMA journal_mode=DELETE");
        try self.execute("PRAGMA synchronous=EXTRA");
        try self.execute("PRAGMA foreign_keys=ON");
        try self.execute("PRAGMA busy_timeout=0");
        try self.execute("PRAGMA mmap_size=0");
        try self.execute("PRAGMA temp_store=FILE");
        try self.execute("PRAGMA trusted_schema=OFF");
        try self.execute("PRAGMA cell_size_check=ON");
        if (try self.pragmaU64("PRAGMA page_size") != 4096) {
            return error.UnsupportedHostStorePageSize;
        }

        var pragma_buffer: [64]u8 = undefined;
        const cache_pragma = try std.fmt.bufPrintZ(
            &pragma_buffer,
            "PRAGMA cache_size=-{d}",
            .{config.page_cache_kib},
        );
        try self.execute(cache_pragma);
        const pages_pragma = try std.fmt.bufPrintZ(
            &pragma_buffer,
            "PRAGMA max_page_count={d}",
            .{config.maximum_page_count},
        );
        try self.execute(pages_pragma);
    }

    fn installSchema(self: *StorageOwner) !void {
        self.execute("BEGIN IMMEDIATE") catch |err| return err;
        errdefer self.rollbackOrPoison();
        inline for (.{ session_schema, transition_schema, conversation_schema, completion_schema }) |sql| {
            self.execute(sql) catch |err| return err;
        }
        self.execute(completion_index_schema) catch |err| return err;
        self.execute("PRAGMA application_id=1330532423") catch |err| return err;
        self.execute("PRAGMA user_version=4") catch |err| return err;
        self.execute("COMMIT") catch |err| {
            self.rollbackOrPoison();
            return err;
        };
    }

    fn verifySchemaIdentity(self: *StorageOwner) !void {
        if (try self.pragmaU64("PRAGMA application_id") != application_id) {
            return error.InvalidHostStoreIdentity;
        }
        if (try self.pragmaU64("PRAGMA user_version") != schema_version) {
            return error.UnsupportedHostStoreVersion;
        }
    }

    fn schemaIsEmpty(self: *StorageOwner) !bool {
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

    fn validateSchemaShape(self: *StorageOwner) !void {
        try self.expectSchemaSql("table", "session", session_schema);
        try self.expectSchemaSql("table", "session_transition", transition_schema);
        try self.expectSchemaSql("table", "conversation_entry", conversation_schema);
        try self.expectSchemaSql("table", "completion_inbox", completion_schema);
        try self.expectSchemaSql("index", "completion_inbox_by_session", completion_index_schema);
        try self.expectSchemaCount(
            "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
            5,
        );
    }

    fn expectSchemaSql(
        self: *StorageOwner,
        object_type: []const u8,
        name: []const u8,
        expected: []const u8,
    ) !void {
        const statement = try self.prepare(
            "SELECT sql FROM sqlite_schema WHERE type = ?1 AND name = ?2",
        );
        defer finalize(statement);
        try bindText(statement, 1, object_type);
        try bindText(statement, 2, name);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            !columnTextEquals(statement, 0, expected) or
            c.sqlite3_step(statement) != c.SQLITE_DONE)
        {
            return error.InvalidHostStoreSchema;
        }
    }

    fn expectSchemaCount(self: *StorageOwner, sql: [:0]const u8, expected: u8) !void {
        const statement = try self.prepare(sql);
        defer finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            c.sqlite3_column_int64(statement, 0) != expected or
            c.sqlite3_step(statement) != c.SQLITE_DONE)
        {
            return error.InvalidHostStoreSchema;
        }
    }

    fn ensureAdmissionCapacity(self: *StorageOwner) !void {
        const page_count = try self.pragmaU64("PRAGMA page_count");
        const freelist_count = try self.pragmaU64("PRAGMA freelist_count");
        const maximum_page_count = try self.pragmaU64("PRAGMA max_page_count");
        if (page_count > maximum_page_count or freelist_count > page_count or
            freelist_count + maximum_page_count - page_count < self.admission_reserve_pages)
        {
            return error.HostStoreCapacityReserved;
        }
    }

    fn pragmaU64(self: *StorageOwner, sql: [:0]const u8) !u64 {
        const statement = try self.prepare(sql);
        defer finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptHostStore;
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @intCast(value);
    }

    const DatabaseStatus = struct { current: u64, highwater: u64 };

    fn databaseStatus(
        self: *StorageOwner,
        operation: c_int,
        reset_highwater: bool,
    ) !DatabaseStatus {
        var current: c_int = 0;
        var highwater: c_int = 0;
        try expectOk(c.sqlite3_db_status(
            self.database,
            operation,
            &current,
            &highwater,
            @intFromBool(reset_highwater),
        ));
        return .{
            .current = try nonnegative(current),
            .highwater = try nonnegative(highwater),
        };
    }

    fn prepare(self: *StorageOwner, sql: [:0]const u8) !*c.sqlite3_stmt {
        var maybe_statement: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(self.database, sql.ptr, -1, &maybe_statement, null);
        if (result != c.SQLITE_OK) return mapSqliteError(result);
        return maybe_statement orelse error.HostStorePrepareFailed;
    }

    fn execute(self: *StorageOwner, sql: [:0]const u8) !void {
        const result = c.sqlite3_exec(self.database, sql.ptr, null, null, null);
        if (result != c.SQLITE_OK) return mapSqliteError(result);
    }

    fn ensureOpen(self: *const StorageOwner) !void {
        if (!self.open_) return error.HostStoreClosed;
        if (self.failed_) return error.HostStoreUnavailable;
    }

    fn reach(self: *StorageOwner, boundary: FaultBoundary) !void {
        if (self.fault) |hook| try hook.reached(hook.context, boundary);
    }

    fn rollbackOrPoison(self: *StorageOwner) void {
        self.execute("ROLLBACK") catch {
            // SQLite may already have rolled back FULL, IOERR, or NOMEM automatically.
        };
        if (c.sqlite3_get_autocommit(self.database) == 0) self.failed_ = true;
    }
};

fn initialTransaction(identity: SessionIdentity) session_transition.Transaction {
    const agent: session_transition.AgentContext = .{
        .agent_id = identity.agent_id,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };
    var transaction: session_transition.Transaction = .{ .sequence = 1, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = agent,
        .entry_id = 1,
        .parent_id = 0,
        .kind = .user_text,
        .content_ref = identity.task_id,
    });
    return transaction;
}

fn validateTransactionIdentity(
    identity: SessionIdentity,
    transaction: session_transition.Transaction,
) !void {
    for (transaction.factSlice()) |fact| {
        const agent = fact.agent();
        if (agent.agent_id != identity.agent_id or agent.ownership_epoch != 1) {
            return error.InvalidTransitionIdentity;
        }
    }
    if (transaction.fact_count != 1 or
        std.meta.activeTag(transaction.facts[0]) != .conversation_advanced)
    {
        return error.InvalidInitialTransition;
    }
    const root = transaction.facts[0].conversation_advanced;
    if (root.entry_id != 1 or root.parent_id != 0 or root.kind != .user_text or
        root.content_ref != identity.task_id)
    {
        return error.InvalidInitialTransition;
    }
}

fn validateCommitIdentity(
    token: OwnerToken,
    transaction: session_transition.Transaction,
) !u64 {
    const first = transaction.facts[0].agent();
    if (first.agent_generation != 1) return error.InvalidTransitionIdentity;
    for (transaction.factSlice()) |fact| {
        const agent = fact.agent();
        if (agent.agent_id != first.agent_id or agent.agent_generation != first.agent_generation) {
            return error.InvalidTransitionIdentity;
        }
        const may_use_earlier_epoch = switch (fact) {
            .result => |result| result.evidence == .durable,
            else => false,
        };
        if (agent.ownership_epoch > token.epoch or
            (!may_use_earlier_epoch and agent.ownership_epoch != token.epoch))
        {
            return error.StaleOwner;
        }
    }
    return first.agent_id;
}

fn isAdmission(transaction: session_transition.Transaction) bool {
    for (transaction.factSlice()) |fact| switch (fact) {
        .task_admitted, .operation_submitted, .attempt_admitted => return true,
        .operation_accepted,
        .authorization,
        .result,
        .conversation_advanced,
        .outcome,
        .cancellation,
        .shutdown,
        .result_applied,
        .approval_required,
        => {},
    };
    return false;
}

fn validateConfig(path: []const u8, config: Config) !void {
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidHostStorePath;
    if (config.page_cache_kib != 32 and config.page_cache_kib != 64 and
        config.page_cache_kib != 128)
    {
        return error.UnsupportedPageCacheProfile;
    }
    if (config.maximum_page_count < 16) return error.InvalidMaximumPageCount;
    if (config.admission_reserve_pages == 0 or
        config.admission_reserve_pages >= config.maximum_page_count)
    {
        return error.InvalidAdmissionReserve;
    }
}

pub fn configureProcessHeapLimit(limit_bytes: u64) !void {
    if (limit_bytes < 1024 * 1024 or limit_bytes > std.math.maxInt(i64)) {
        return error.InvalidSqliteHeapLimit;
    }
    if (c.sqlite3_hard_heap_limit64(@intCast(limit_bytes)) < 0) {
        return error.SqliteHeapLimitConfigurationFailed;
    }
}

pub fn disableProcessHeapLimit() void {
    _ = c.sqlite3_hard_heap_limit64(0);
}

fn processHeapLimit() !u64 {
    const value = c.sqlite3_hard_heap_limit64(-1);
    if (value < 0) return error.SqliteHeapLimitQueryFailed;
    return @intCast(value);
}

fn openHostLock(io: std.Io, path: []const u8) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    for (0..8) |_| {
        return cwd.openFile(io, path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |open_error| switch (open_error) {
            error.FileNotFound => cwd.createFile(io, path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |create_error| switch (create_error) {
                error.PathAlreadyExists => continue,
                error.WouldBlock => return error.HostStoreBusy,
                else => return create_error,
            },
            error.WouldBlock => return error.HostStoreBusy,
            else => return open_error,
        };
    }
    return error.HostStoreLockRace;
}

fn dbConfig(database: *c.sqlite3, operation: c_int, value: c_int) !void {
    var previous: c_int = 0;
    const result = c.sqlite3_db_config(database, operation, value, &previous);
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.InvalidIdentity;
    const result = c.sqlite3_bind_int64(statement, index, @intCast(value));
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindIdentity(
    statement: *c.sqlite3_stmt,
    index: c_int,
    value: u64,
    encoded: *[8]u8,
) !void {
    if (value == 0) return error.InvalidIdentity;
    std.mem.writeInt(u64, encoded, value, .little);
    const result = c.sqlite3_bind_blob64(
        statement,
        index,
        encoded,
        encoded.len,
        null,
    );
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const result = c.sqlite3_bind_blob64(
        statement,
        index,
        bytes.ptr,
        bytes.len,
        null,
    );
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const result = c.sqlite3_bind_text64(
        statement,
        index,
        bytes.ptr,
        bytes.len,
        null,
        c.SQLITE_UTF8,
    );
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn readIdentityColumn(statement: *c.sqlite3_stmt, index: c_int) !u64 {
    if (c.sqlite3_column_bytes(statement, index) != 8) return error.CorruptHostStore;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptHostStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    const value = std.mem.readInt(u64, bytes[0..8], .little);
    if (value == 0) return error.CorruptHostStore;
    return value;
}

fn readBindingColumn(comptime T: type, statement: *c.sqlite3_stmt, index: c_int) !T {
    if (c.sqlite3_column_bytes(statement, index) != @sizeOf(binding.Sha256)) {
        return error.CorruptHostStore;
    }
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptHostStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return .{ .bytes = bytes[0..@sizeOf(binding.Sha256)].* };
}

fn columnTextEquals(statement: *c.sqlite3_stmt, index: c_int, expected: []const u8) bool {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0 or length != expected.len) return false;
    const pointer = c.sqlite3_column_text(statement, index) orelse return false;
    return std.mem.eql(u8, pointer[0..@intCast(length)], expected);
}

fn readPositiveU32Column(statement: *c.sqlite3_stmt, index: c_int) !u32 {
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0 or value > std.math.maxInt(u32)) return error.CorruptHostStore;
    return @intCast(value);
}

fn expectDone(result: c_int) !void {
    if (result != c.SQLITE_DONE) return mapSqliteError(result);
}

fn expectOk(result: c_int) !void {
    if (result != c.SQLITE_OK) return mapSqliteError(result);
}

fn finalize(statement: *c.sqlite3_stmt) void {
    // sqlite3_finalize repeats the statement's last evaluation error. Every
    // evaluation result is handled at its step call, so finalization has no
    // independent failure to publish during deferred cleanup.
    _ = c.sqlite3_finalize(statement);
}

fn closeDatabase(database: *c.sqlite3) void {
    // Opening owns no outstanding statements at this cleanup boundary, so a
    // close failure is an internal lifetime defect rather than a recoverable result.
    std.debug.assert(c.sqlite3_close_v2(database) == c.SQLITE_OK);
}

fn nonnegative(value: anytype) !u64 {
    if (value < 0) return error.CorruptSqliteAccounting;
    return @intCast(value);
}

fn decodeVerifiedTransitionRow(
    statement: *c.sqlite3_stmt,
    session_id: u64,
    expected_sequence: u64,
    out: *StoredTransition,
) !void {
    const sequence = try nonnegative(c.sqlite3_column_int64(statement, 0));
    if (sequence != expected_sequence or sequence > session_transition.max_transitions) {
        return error.CorruptHostStore;
    }
    const payload_length = c.sqlite3_column_bytes(statement, 1);
    const digest_length = c.sqlite3_column_bytes(statement, 2);
    if (payload_length <= 0 or payload_length > max_transition_payload or digest_length != 32) {
        return error.CorruptHostStore;
    }
    const payload_pointer = c.sqlite3_column_blob(statement, 1) orelse
        return error.CorruptHostStore;
    const digest_pointer = c.sqlite3_column_blob(statement, 2) orelse
        return error.CorruptHostStore;
    const length: usize = @intCast(payload_length);
    var payload: [max_transition_payload]u8 = undefined;
    const payload_bytes: [*]const u8 = @ptrCast(payload_pointer);
    @memcpy(payload[0..length], payload_bytes[0..length]);
    const digest_bytes: [*]const u8 = @ptrCast(digest_pointer);
    var stored_digest: binding.LedgerRecord = undefined;
    @memcpy(&stored_digest.bytes, digest_bytes[0..32]);
    if (!binding.eql(
        binding.LedgerRecord,
        recordDigest(session_id, sequence, payload[0..length]),
        stored_digest,
    )) return error.PayloadDigestMismatch;
    out.* = .{
        .session_id = session_id,
        .sequence = sequence,
        .transaction = try session_transition.decode(
            sequence,
            payload[0..length],
        ),
    };
}

fn applyCompletedAttemptFacts(
    scan: *CompletedAttemptScan,
    transaction: session_transition.Transaction,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
) !void {
    for (transaction.factSlice()) |fact| switch (fact) {
        .attempt_admitted => |attempt| {
            if (attempt.operation.operation_id != operation_id or
                attempt.operation.generation != operation_generation or
                attempt.attempt_id != attempt_id)
            {
                continue;
            }
            if (scan.terminal_before_attempt) return error.InvalidHistoricalCompletionOrdering;
            if (scan.attempt) |existing| {
                if (!std.meta.eql(existing, attempt)) return error.ConflictingLedgerFacts;
            } else scan.attempt = attempt;
        },
        .result => |result| {
            if (result.operation.operation_id != operation_id or
                result.operation.generation != operation_generation or
                scan.completed != null or scan.terminal_before_attempt)
            {
                continue;
            }
            if (scan.attempt) |attempt| {
                if (!std.meta.eql(attempt.operation, result.operation)) {
                    return error.InvalidHistoricalCompletionRelationship;
                }
                scan.completed = .{
                    .attempt = attempt,
                    .terminal_result_sequence = transaction.sequence,
                };
            } else scan.terminal_before_attempt = true;
        },
        else => {},
    };
}

fn recordDigest(session_id: u64, sequence: u64, payload: []const u8) binding.LedgerRecord {
    var hasher = binding.Hasher(binding.LedgerRecord).init();
    var identity: [16]u8 = undefined;
    std.mem.writeInt(u64, identity[0..8], session_id, .little);
    std.mem.writeInt(u64, identity[8..16], sequence, .little);
    hasher.update(&identity);
    hasher.update(payload);
    return hasher.final();
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

test "SQLite primary failure classes map to explicit Host Store outcomes" {
    try std.testing.expectEqual(error.HostStoreBusy, mapSqliteError(c.SQLITE_BUSY));
    try std.testing.expectEqual(error.HostStoreFull, mapSqliteError(c.SQLITE_FULL));
    try std.testing.expectEqual(error.HostStoreIo, mapSqliteError(c.SQLITE_IOERR_WRITE));
    try std.testing.expectEqual(error.CorruptHostStore, mapSqliteError(c.SQLITE_CORRUPT));
    try std.testing.expectEqual(error.NotAHostStore, mapSqliteError(c.SQLITE_NOTADB));
    try std.testing.expectEqual(error.HostStoreNoMemory, mapSqliteError(c.SQLITE_NOMEM));
}

test "an empty SQLite database left before schema publication can be initialized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var terminated_path: [max_path_bytes:0]u8 = undefined;
    @memcpy(terminated_path[0..path.len], path);
    terminated_path[path.len] = 0;

    var maybe_database: ?*c.sqlite3 = null;
    try expectOk(c.sqlite3_open_v2(
        &terminated_path,
        &maybe_database,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ));
    const database = maybe_database orelse return error.HostStoreOpenFailed;
    try expectOk(c.sqlite3_exec(database, "VACUUM", null, null, null));
    try expectOk(c.sqlite3_close_v2(database));

    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try std.testing.expectEqual(@as(u64, application_id), try owner.pragmaU64("PRAGMA application_id"));
    try std.testing.expectEqual(@as(u64, schema_version), try owner.pragmaU64("PRAGMA user_version"));
}

test "an unowned non-empty SQLite schema is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var terminated_path: [max_path_bytes:0]u8 = undefined;
    @memcpy(terminated_path[0..path.len], path);
    terminated_path[path.len] = 0;

    var maybe_database: ?*c.sqlite3 = null;
    try expectOk(c.sqlite3_open_v2(
        &terminated_path,
        &maybe_database,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ));
    const database = maybe_database orelse return error.HostStoreOpenFailed;
    try expectOk(c.sqlite3_exec(database, "CREATE TABLE foreign_data (value INTEGER)", null, null, null));
    try expectOk(c.sqlite3_close_v2(database));

    try std.testing.expectError(
        error.InvalidHostStoreIdentity,
        StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "matching identity cannot hide an incomplete or unhardened schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var terminated_path: [max_path_bytes:0]u8 = undefined;
    @memcpy(terminated_path[0..path.len], path);
    terminated_path[path.len] = 0;

    var maybe_database: ?*c.sqlite3 = null;
    try expectOk(c.sqlite3_open_v2(
        &terminated_path,
        &maybe_database,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ));
    const database = maybe_database orelse return error.HostStoreOpenFailed;
    try expectOk(c.sqlite3_exec(
        database,
        "CREATE TABLE session (session_id BLOB); PRAGMA application_id=1330532423; PRAGMA user_version=4",
        null,
        null,
        null,
    ));
    try expectOk(c.sqlite3_close_v2(database));

    try std.testing.expectError(
        error.InvalidHostStoreSchema,
        StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "installed schema retains the exact V1 keys constraints and completion index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();

    try owner.expectSchemaSql("table", "session", session_schema);
    try owner.expectSchemaSql("table", "session_transition", transition_schema);
    try owner.expectSchemaSql("table", "conversation_entry", conversation_schema);
    try owner.expectSchemaSql("table", "completion_inbox", completion_schema);
    try owner.expectSchemaSql("index", "completion_inbox_by_session", completion_index_schema);
}

test "admission rolls back before consuming the closure reserve" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    const reserve: u16 = 8;
    var owner = try StorageOwner.open(std.testing.io, path, .{
        .maximum_page_count = 32,
        .admission_reserve_pages = reserve,
    });
    defer owner.close();

    var rejected = false;
    for (1..10_001) |index| {
        const id: u64 = @intCast(index * 4);
        owner.createSession(.{
            .session_id = id,
            .agent_id = id + 1,
            .task_id = id + 2,
            .branch_id = id + 3,
        }) catch |err| switch (err) {
            error.HostStoreCapacityReserved => {
                rejected = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(rejected);
    const page_count = try owner.pragmaU64("PRAGMA page_count");
    const freelist_count = try owner.pragmaU64("PRAGMA freelist_count");
    const maximum_page_count = try owner.pragmaU64("PRAGMA max_page_count");
    try std.testing.expect(freelist_count + maximum_page_count - page_count >= reserve);
}

test "Completion recovery range is bounded by its Session index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();

    for (1..129) |index| {
        const base: u64 = @intCast(index * 8);
        try owner.createSession(.{
            .session_id = base,
            .agent_id = base + 1,
            .task_id = base + 2,
            .branch_id = base + 3,
        });
    }
    _ = try owner.publishCompletion(completion_inbox.bind(.{
        .kind = .model,
        .session_id = 8,
        .ownership_epoch = 1,
        .agent_id = 9,
        .agent_generation = 1,
        .operation_id = 101,
        .operation_generation = 1,
        .attempt_id = 102,
        .result_ref = 103,
        .result_digest = binding.hash(binding.Result, "result-104"),
    }));
    try owner.execute("ANALYZE");
    const statement = try owner.prepare(read_completion_after_sql);
    defer finalize(statement);
    var encoded_session_id: [8]u8 = undefined;
    try bindIdentity(statement, 1, 8, &encoded_session_id);
    try bindU64(statement, 2, 0);
    try bindU64(statement, 3, std.math.maxInt(i64));
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CompletionNotFound;
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_FULLSCAN_STEP,
        0,
    ));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_SORT,
        0,
    ));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_AUTOINDEX,
        0,
    ));
}

test "historical Completion range is bounded by the Session Ledger key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 8,
        .agent_id = 9,
        .task_id = 10,
        .branch_id = 11,
    });

    const populate = try owner.prepare(
        \\WITH RECURSIVE ledger_sequence(value) AS (
        \\    SELECT 2
        \\    UNION ALL
        \\    SELECT value + 1 FROM ledger_sequence WHERE value < 32768
        \\)
        \\INSERT INTO session_transition (session_id, sequence, payload, record_digest)
        \\SELECT ?1, value, zeroblob(1), zeroblob(32) FROM ledger_sequence
    );
    defer finalize(populate);
    var populated_session_id: [8]u8 = undefined;
    try bindIdentity(populate, 1, 8, &populated_session_id);
    try expectDone(c.sqlite3_step(populate));
    try owner.execute("ANALYZE");

    const statement = try owner.prepare(scan_completed_attempt_sql);
    defer finalize(statement);
    var encoded_session_id: [8]u8 = undefined;
    try bindIdentity(statement, 1, 8, &encoded_session_id);
    try bindU64(statement, 2, 1);
    try bindU64(statement, 3, session_transition.max_transitions);
    var row_count: u32 = 0;
    while (true) {
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) break;
        if (step != c.SQLITE_ROW) return mapSqliteError(step);
        row_count += 1;
    }
    try std.testing.expectEqual(session_transition.max_transitions, row_count);
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_FULLSCAN_STEP,
        0,
    ));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_SORT,
        0,
    ));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_stmt_status(
        statement,
        c.SQLITE_STMTSTATUS_AUTOINDEX,
        0,
    ));
}

test "late Completion evidence is inserted already consumed for audit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 8,
        .agent_id = 9,
        .task_id = 10,
        .branch_id = 11,
    });
    const envelope = completion_inbox.bind(.{
        .kind = .model,
        .session_id = 8,
        .ownership_epoch = 1,
        .agent_id = 9,
        .agent_generation = 1,
        .operation_id = 101,
        .operation_generation = 1,
        .attempt_id = 102,
        .result_ref = 103,
        .result_digest = binding.hash(binding.Result, "late-result"),
    });
    const inbox_id = try owner.publishAuditedCompletion(envelope, 1);
    const stored = try owner.readCompletion(8, inbox_id);
    try std.testing.expectEqual(@as(?u64, 1), stored.consumed_by_sequence);
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(8));

    var pending = envelope;
    pending.attempt_id = 105;
    pending.result_ref = 106;
    pending.result_digest = binding.hash(binding.Result, "pending-then-audited");
    pending = completion_inbox.bind(.{
        .kind = pending.kind,
        .session_id = pending.session_id,
        .ownership_epoch = pending.ownership_epoch,
        .agent_id = pending.agent_id,
        .agent_generation = pending.agent_generation,
        .operation_id = pending.operation_id,
        .operation_generation = pending.operation_generation,
        .attempt_id = pending.attempt_id,
        .result_ref = pending.result_ref,
        .result_digest = pending.result_digest,
    });
    const pending_id = try owner.publishCompletion(pending);
    try std.testing.expectEqual(pending_id, try owner.completionHead(8));
    try std.testing.expectEqual(pending_id, try owner.publishAuditedCompletion(pending, 1));
    try std.testing.expectEqual(@as(?u64, 1), (try owner.readCompletion(8, pending_id)).consumed_by_sequence);
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(8));

    var cross_epoch = envelope;
    cross_epoch.ownership_epoch = 2;
    cross_epoch.result_ref = 107;
    cross_epoch.result_digest = binding.hash(binding.Result, "cross-epoch-conflict");
    cross_epoch = completion_inbox.bind(.{
        .kind = cross_epoch.kind,
        .session_id = cross_epoch.session_id,
        .ownership_epoch = cross_epoch.ownership_epoch,
        .agent_id = cross_epoch.agent_id,
        .agent_generation = cross_epoch.agent_generation,
        .operation_id = cross_epoch.operation_id,
        .operation_generation = cross_epoch.operation_generation,
        .attempt_id = cross_epoch.attempt_id,
        .result_ref = cross_epoch.result_ref,
        .result_digest = cross_epoch.result_digest,
    });
    try std.testing.expectError(
        error.ConflictingCompletionEvidence,
        owner.publishAuditedCompletion(cross_epoch, 1),
    );

    var conflicting = envelope;
    conflicting.result_ref = 104;
    conflicting.result_digest = binding.hash(binding.Result, "conflicting-late-result");
    conflicting = completion_inbox.bind(.{
        .kind = conflicting.kind,
        .session_id = conflicting.session_id,
        .ownership_epoch = conflicting.ownership_epoch,
        .agent_id = conflicting.agent_id,
        .agent_generation = conflicting.agent_generation,
        .operation_id = conflicting.operation_id,
        .operation_generation = conflicting.operation_generation,
        .attempt_id = conflicting.attempt_id,
        .result_ref = conflicting.result_ref,
        .result_digest = conflicting.result_digest,
    });
    try std.testing.expectError(
        error.ConflictingCompletionEvidence,
        owner.publishAuditedCompletion(conflicting, 1),
    );
}

test "Completion publication enforces the pending per-Session bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{});
    defer owner.close();
    try owner.createSession(.{
        .session_id = 8,
        .agent_id = 9,
        .task_id = 10,
        .branch_id = 11,
    });

    try owner.execute("BEGIN IMMEDIATE");
    errdefer owner.rollbackOrPoison();
    const insert = try owner.prepare(
        \\INSERT INTO completion_inbox (
        \\    session_id, ownership_epoch, agent_generation,
        \\    operation_id, operation_generation, attempt_id, evidence_kind,
        \\    result_reference, result_digest, completion_digest
        \\) VALUES (?1, ?2, 1, ?3, 1, ?4, 1, ?5, ?6, ?7)
    );
    defer finalize(insert);
    var ids: [5][8]u8 = undefined;
    const result_digest = binding.hash(binding.Result, "capacity-result");
    const completion_digest = binding.hash(binding.Completion, "capacity-completion");
    for (0..completion_inbox.max_records) |index| {
        try bindIdentity(insert, 1, 8, &ids[0]);
        try bindIdentity(insert, 2, 1, &ids[1]);
        try bindIdentity(insert, 3, 100, &ids[2]);
        try bindIdentity(insert, 4, index + 1, &ids[3]);
        try bindIdentity(insert, 5, index + 10_000, &ids[4]);
        try bindBlob(insert, 6, &result_digest.bytes);
        try bindBlob(insert, 7, &completion_digest.bytes);
        try expectDone(c.sqlite3_step(insert));
        try expectOk(c.sqlite3_reset(insert));
        try expectOk(c.sqlite3_clear_bindings(insert));
    }
    try owner.execute("COMMIT");

    try std.testing.expectError(error.CompletionCapacityExceeded, owner.publishCompletion(completion_inbox.bind(.{
        .kind = .model,
        .session_id = 8,
        .ownership_epoch = 1,
        .agent_id = 9,
        .agent_generation = 1,
        .operation_id = 100,
        .operation_generation = 1,
        .attempt_id = completion_inbox.max_records + 1,
        .result_ref = 20_000,
        .result_digest = binding.hash(binding.Result, "result-200"),
    })));
}
