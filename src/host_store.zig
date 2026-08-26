const std = @import("std");
const completion_inbox = @import("completion_inbox.zig");
const session_transition = @import("session_transition.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema_version: u32 = 1;
pub const application_id: u32 = 0x4f4e5047; // "ONPG"
pub const max_path_bytes: usize = 1024;
pub const max_transition_payload: usize = session_transition.max_payload_size;
pub const max_workspace_path_bytes: usize = 1024;
pub const max_model_bytes: usize = 128;

const session_schema =
    \\CREATE TABLE session (
    \\    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 8),
    \\    agent_id BLOB NOT NULL CHECK (length(agent_id) = 8),
    \\    task_id BLOB NOT NULL CHECK (length(task_id) = 8),
    \\    branch_id BLOB NOT NULL CHECK (length(branch_id) = 8),
    \\    workspace_path TEXT NOT NULL CHECK (length(workspace_path) BETWEEN 1 AND 1024),
    \\    model TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128),
    \\    ownership_epoch INTEGER NOT NULL DEFAULT 1 CHECK (ownership_epoch > 0),
    \\    active_leaf_id BLOB NOT NULL CHECK (length(active_leaf_id) = 8),
    \\    entry_count INTEGER NOT NULL DEFAULT 1 CHECK (entry_count > 0),
    \\    head_sequence INTEGER NOT NULL DEFAULT 0 CHECK (head_sequence >= 0),
    \\    inbox_head INTEGER NOT NULL DEFAULT 0 CHECK (inbox_head >= 0),
    \\    UNIQUE (agent_id),
    \\    UNIQUE (task_id),
    \\    UNIQUE (branch_id)
    \\) STRICT
;
const transition_schema =
    \\CREATE TABLE session_transition (
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    sequence INTEGER NOT NULL CHECK (sequence > 0),
    \\    payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 740),
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
    \\    committed_by_sequence INTEGER,
    \\    PRIMARY KEY (session_id, entry_id),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (session_id, committed_by_sequence)
    \\        REFERENCES session_transition (session_id, sequence)
    \\) STRICT
;
const completion_schema =
    \\CREATE TABLE completion_inbox (
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    inbox_sequence INTEGER NOT NULL CHECK (inbox_sequence > 0),
    \\    ownership_epoch BLOB NOT NULL CHECK (length(ownership_epoch) = 8),
    \\    agent_generation INTEGER NOT NULL CHECK (agent_generation > 0),
    \\    operation_id BLOB NOT NULL CHECK (length(operation_id) = 8),
    \\    operation_generation INTEGER NOT NULL CHECK (operation_generation > 0),
    \\    attempt_id BLOB NOT NULL CHECK (length(attempt_id) = 8),
    \\    evidence_kind INTEGER NOT NULL CHECK (evidence_kind > 0),
    \\    result_reference BLOB NOT NULL CHECK (length(result_reference) = 8),
    \\    result_digest BLOB NOT NULL CHECK (length(result_digest) = 8),
    \\    consumed_by_sequence INTEGER,
    \\    PRIMARY KEY (
    \\        session_id, ownership_epoch, agent_generation, operation_id,
    \\        operation_generation, attempt_id, evidence_kind
    \\    ),
    \\    UNIQUE (session_id, inbox_sequence),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id),
    \\    FOREIGN KEY (session_id, consumed_by_sequence)
    \\        REFERENCES session_transition (session_id, sequence)
    \\) STRICT, WITHOUT ROWID
;
const completion_index_schema =
    \\CREATE INDEX completion_inbox_unconsumed
    \\ON completion_inbox (session_id, consumed_by_sequence, inbox_sequence)
;

const read_session_sql: [:0]const u8 =
    \\SELECT agent_id, task_id, branch_id, ownership_epoch, active_leaf_id,
    \\       entry_count, workspace_path, model
    \\FROM session WHERE session_id = ?1
;
const session_head_sql: [:0]const u8 =
    "SELECT head_sequence FROM session WHERE session_id = ?1";
const claim_ownership_sql: [:0]const u8 =
    \\UPDATE session SET ownership_epoch = ownership_epoch + 1
    \\WHERE session_id = ?1 AND ownership_epoch < 9223372036854775807
    \\RETURNING ownership_epoch
;
const current_ownership_sql: [:0]const u8 =
    "SELECT ownership_epoch FROM session WHERE session_id = ?1";
const completion_head_sql: [:0]const u8 =
    "SELECT inbox_head FROM session WHERE session_id = ?1";
const find_completion_sql: [:0]const u8 =
    \\SELECT c.inbox_sequence, c.result_reference, c.result_digest
    \\FROM completion_inbox AS c
    \\JOIN session AS s ON s.session_id = c.session_id
    \\WHERE c.session_id = ?1 AND c.ownership_epoch = ?2
    \\  AND s.agent_id = ?3 AND c.agent_generation = ?4
    \\  AND c.operation_id = ?5 AND c.operation_generation = ?6
    \\  AND c.attempt_id = ?7 AND c.evidence_kind = ?8
;
const advance_inbox_head_sql: [:0]const u8 =
    "UPDATE session SET inbox_head = ?2 WHERE session_id = ?1 AND inbox_head = ?3";
const read_completion_sql: [:0]const u8 =
    \\SELECT c.evidence_kind, c.ownership_epoch, s.agent_id, c.agent_generation,
    \\       c.operation_id, c.operation_generation, c.attempt_id,
    \\       c.result_reference, c.result_digest, c.consumed_by_sequence
    \\FROM completion_inbox AS c
    \\JOIN session AS s ON s.session_id = c.session_id
    \\WHERE c.session_id = ?1 AND c.inbox_sequence = ?2
;
const advance_session_head_sql: [:0]const u8 =
    \\UPDATE session SET head_sequence = ?2
    \\WHERE session_id = ?1 AND ownership_epoch = ?3 AND head_sequence = ?4
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
const advance_conversation_sql: [:0]const u8 =
    \\UPDATE session SET active_leaf_id = ?2, entry_count = ?3
    \\WHERE session_id = ?1 AND entry_count + 1 = ?3
;
const read_transition_sql: [:0]const u8 =
    \\SELECT payload, record_digest
    \\FROM session_transition
    \\WHERE session_id = ?1 AND sequence = ?2
;
const read_conversation_sql: [:0]const u8 =
    \\SELECT parent_id, kind, content_ref, committed_by_sequence
    \\FROM conversation_entry WHERE session_id = ?1 AND entry_id = ?2
;

pub const CapacityClass = enum { closure, admission };

pub const ConversationInsert = struct {
    entry_id: u64,
    parent_id: u64,
    kind: u8,
    content_ref: u64,
};

pub const CompletionAssociation = struct {
    ownership_epoch: u64,
    agent_id: u64,
    agent_generation: u32,
    operation_id: u64,
    operation_generation: u32,
    attempt_id: u64,
    evidence_kind: u8,
    result_reference: u64,
    result_digest: u64,
};

pub const CommitRequest = struct {
    token: OwnerToken,
    expected_sequence: u64,
    payload: []const u8,
    conversations: []const ConversationInsert = &.{},
    completions: []const CompletionAssociation = &.{},
    capacity_class: CapacityClass = .closure,
};

pub const StoredTransition = struct {
    session_id: u64,
    sequence: u64,
    payload: [max_transition_payload]u8,
    payload_length: u16,
    record_digest: [32]u8,

    pub fn payloadSlice(self: *const StoredTransition) []const u8 {
        return self.payload[0..self.payload_length];
    }
};

pub const StoredCompletion = struct {
    envelope: completion_inbox.Envelope,
    consumed_by_sequence: ?u64,
};

pub const StoredConversationEntry = struct {
    entry_id: u64,
    parent_id: u64,
    kind: u8,
    content_ref: u64,
    committed_by_sequence: ?u64,
};

pub const Config = struct {
    page_cache_kib: u16 = 64,
    maximum_page_count: u32 = 262_144,
    admission_reserve_pages: u16 = 16,
    sqlite_heap_limit_bytes: u64 = 8 * 1024 * 1024,
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
    after_completion_head_advance,
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

    fn validate(self: SessionIdentity) !void {
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
    active_leaf_id: u64,
    entry_count: u64,
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
    lock_file: std.Io.File,
    database: *c.sqlite3,
    fault: ?FaultHook,
    admission_reserve_pages: u16,
    sqlite_heap_limit_bytes: u64,
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
        if (config.sqlite_heap_limit_bytes > std.math.maxInt(i64)) {
            return error.InvalidSqliteHeapLimit;
        }
        _ = c.sqlite3_hard_heap_limit64(@intCast(config.sqlite_heap_limit_bytes));

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
            .sqlite_heap_limit_bytes = config.sqlite_heap_limit_bytes,
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
        });
    }

    pub fn createSessionWithMetadata(
        self: *StorageOwner,
        descriptor: SessionDescriptor,
    ) !void {
        try self.ensureOpen();
        try descriptor.identities.validate();
        if (descriptor.workspace_path.len == 0 or
            descriptor.workspace_path.len > max_workspace_path_bytes or
            descriptor.model.len == 0 or descriptor.model.len > max_model_bytes)
        {
            return error.InvalidSessionMetadata;
        }
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();
        const statement = try self.prepare(
            \\INSERT INTO session (
            \\    session_id, agent_id, task_id, branch_id, workspace_path, model, active_leaf_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        );
        defer finalize(statement);
        var encoded_identities: [5][8]u8 = undefined;
        try bindIdentity(statement, 1, descriptor.identities.session_id, &encoded_identities[0]);
        try bindIdentity(statement, 2, descriptor.identities.agent_id, &encoded_identities[1]);
        try bindIdentity(statement, 3, descriptor.identities.task_id, &encoded_identities[2]);
        try bindIdentity(statement, 4, descriptor.identities.branch_id, &encoded_identities[3]);
        try bindText(statement, 5, descriptor.workspace_path);
        try bindText(statement, 6, descriptor.model);
        try bindIdentity(statement, 7, 1, &encoded_identities[4]);
        try expectDone(c.sqlite3_step(statement));

        const root = try self.prepare(
            \\INSERT INTO conversation_entry (
            \\    session_id, entry_id, parent_id, kind, content_ref, committed_by_sequence
            \\) VALUES (?1, ?2, NULL, 1, ?3, NULL)
        );
        defer finalize(root);
        try bindIdentity(root, 1, descriptor.identities.session_id, &encoded_identities[0]);
        try bindIdentity(root, 2, 1, &encoded_identities[4]);
        try bindIdentity(root, 3, descriptor.identities.task_id, &encoded_identities[2]);
        try expectDone(c.sqlite3_step(root));
        try self.ensureAdmissionCapacity();
        try self.execute("COMMIT");
    }

    pub fn memoryAccounting(self: *StorageOwner, reset_highwater: bool) !MemoryAccounting {
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
            .allowance_bytes = self.sqlite_heap_limit_bytes,
            .heap_current_bytes = try nonnegative(heap_current),
            .heap_highwater_bytes = try nonnegative(heap_highwater),
            .page_cache_current_bytes = cache.current,
            .lookaside_current_slots = lookaside.current,
            .lookaside_highwater_slots = lookaside.highwater,
            .statements_current_bytes = statements.current,
        };
    }

    pub fn readSession(self: *StorageOwner, session_id: u64) !StoredSession {
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
        const entry_count = c.sqlite3_column_int64(statement, 5);
        const workspace_length = c.sqlite3_column_bytes(statement, 6);
        const model_length = c.sqlite3_column_bytes(statement, 7);
        if (ownership_epoch <= 0 or entry_count <= 0 or
            workspace_length <= 0 or workspace_length > max_workspace_path_bytes or
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
            .active_leaf_id = try readIdentityColumn(statement, 4),
            .entry_count = @intCast(entry_count),
            .workspace_path = undefined,
            .workspace_path_length = @intCast(workspace_length),
            .model = undefined,
            .model_length = @intCast(model_length),
        };
        try stored.identities.validate();
        const workspace_pointer = c.sqlite3_column_text(statement, 6) orelse {
            return error.CorruptHostStore;
        };
        const model_pointer = c.sqlite3_column_text(statement, 7) orelse {
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
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(session_head_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return error.SessionNotFound;
        if (step_result != c.SQLITE_ROW) return mapSqliteError(step_result);
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0) return error.CorruptHostStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return @intCast(value);
    }

    pub fn claimSession(self: *StorageOwner, session_id: u64) !u64 {
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

    pub fn authorizeSession(self: *StorageOwner, token: OwnerToken) !void {
        try self.ensureOpen();
        if (token.session_id == 0 or token.epoch == 0 or token.epoch > std.math.maxInt(i64)) {
            return error.StaleOwner;
        }
        const statement = try self.prepare(current_ownership_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, token.session_id, &encoded_session_id);
        const result = c.sqlite3_step(statement);
        if (result != c.SQLITE_ROW) return error.StaleOwner;
        const epoch = c.sqlite3_column_int64(statement, 0);
        if (epoch <= 0 or @as(u64, @intCast(epoch)) != token.epoch) return error.StaleOwner;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    pub fn completionHead(self: *StorageOwner, session_id: u64) !u64 {
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(completion_head_sql);
        defer finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return error.SessionNotFound;
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
        try self.ensureOpen();
        try completion_inbox.validate(envelope);

        var identities: [7][8]u8 = undefined;
        const existing = try self.prepare(find_completion_sql);
        defer finalize(existing);
        try bindIdentity(existing, 1, envelope.session_id, &identities[0]);
        try bindIdentity(existing, 2, envelope.ownership_epoch, &identities[1]);
        try bindIdentity(existing, 3, envelope.agent_id, &identities[2]);
        try bindU64(existing, 4, envelope.agent_generation);
        try bindIdentity(existing, 5, envelope.operation_id, &identities[3]);
        try bindU64(existing, 6, envelope.operation_generation);
        try bindIdentity(existing, 7, envelope.attempt_id, &identities[4]);
        try bindU64(existing, 8, @intFromEnum(envelope.kind));
        const existing_result = c.sqlite3_step(existing);
        if (existing_result == c.SQLITE_ROW) {
            const sequence = c.sqlite3_column_int64(existing, 0);
            const result_ref = try readIdentityColumn(existing, 1);
            const result_digest = try readIdentityColumn(existing, 2);
            if (sequence <= 0) return error.CorruptHostStore;
            if (result_ref != envelope.result_ref or result_digest != envelope.result_digest) {
                return error.ConflictingCompletionEvidence;
            }
            if (c.sqlite3_step(existing) != c.SQLITE_DONE) return error.CorruptHostStore;
            return @intCast(sequence);
        }
        if (existing_result != c.SQLITE_DONE) return mapSqliteError(existing_result);

        const current_head = try self.completionHead(envelope.session_id);
        if (current_head >= completion_inbox.max_records) return error.CompletionSequenceExhausted;
        const sequence = current_head + 1;
        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();

        const advance = try self.prepare(advance_inbox_head_sql);
        defer finalize(advance);
        try bindIdentity(advance, 1, envelope.session_id, &identities[0]);
        try bindU64(advance, 2, sequence);
        try bindU64(advance, 3, current_head);
        try expectDone(c.sqlite3_step(advance));
        if (c.sqlite3_changes(self.database) != 1) return error.CompletionSequenceConflict;
        try self.reach(.after_completion_head_advance);

        const insert = try self.prepare(
            \\INSERT INTO completion_inbox (
            \\    session_id, inbox_sequence, ownership_epoch, agent_generation,
            \\    operation_id, operation_generation, attempt_id, evidence_kind,
            \\    result_reference, result_digest
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        );
        defer finalize(insert);
        try bindIdentity(insert, 1, envelope.session_id, &identities[0]);
        try bindU64(insert, 2, sequence);
        try bindIdentity(insert, 3, envelope.ownership_epoch, &identities[1]);
        try bindU64(insert, 4, envelope.agent_generation);
        try bindIdentity(insert, 5, envelope.operation_id, &identities[3]);
        try bindU64(insert, 6, envelope.operation_generation);
        try bindIdentity(insert, 7, envelope.attempt_id, &identities[4]);
        try bindU64(insert, 8, @intFromEnum(envelope.kind));
        try bindIdentity(insert, 9, envelope.result_ref, &identities[5]);
        try bindIdentity(insert, 10, envelope.result_digest, &identities[6]);
        try expectDone(c.sqlite3_step(insert));
        try self.reach(.before_commit);
        try self.execute("COMMIT");
        return sequence;
    }

    pub fn readCompletion(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
    ) !StoredCompletion {
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
            .result_digest = try readIdentityColumn(statement, 8),
        };
        try completion_inbox.validate(envelope);
        const consumed_by_sequence: ?u64 = switch (c.sqlite3_column_type(statement, 9)) {
            c.SQLITE_NULL => null,
            c.SQLITE_INTEGER => consumed: {
                const consumed = c.sqlite3_column_int64(statement, 9);
                if (consumed <= 0) return error.CorruptHostStore;
                break :consumed @intCast(consumed);
            },
            else => return error.CorruptHostStore,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return .{ .envelope = envelope, .consumed_by_sequence = consumed_by_sequence };
    }

    pub fn commit(self: *StorageOwner, request: CommitRequest) !u64 {
        try self.ensureOpen();
        if (request.token.session_id == 0 or request.token.epoch == 0) return error.StaleOwner;
        if (request.payload.len == 0 or request.payload.len > max_transition_payload) {
            return error.InvalidTransitionPayload;
        }
        if (request.expected_sequence >= session_transition.max_transitions) {
            return error.SessionSequenceExhausted;
        }
        if (request.conversations.len > session_transition.max_facts or
            request.completions.len > session_transition.max_facts)
        {
            return error.InvalidTransitionCount;
        }
        const sequence = request.expected_sequence + 1;
        var digest: [32]u8 = undefined;
        recordDigest(request.token.session_id, sequence, request.payload, &digest);

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();
        const advance = try self.prepare(advance_session_head_sql);
        defer finalize(advance);
        var identities: [10][8]u8 = undefined;
        try bindIdentity(advance, 1, request.token.session_id, &identities[0]);
        try bindU64(advance, 2, sequence);
        try bindU64(advance, 3, request.token.epoch);
        try bindU64(advance, 4, request.expected_sequence);
        try expectDone(c.sqlite3_step(advance));
        if (c.sqlite3_changes(self.database) != 1) return error.StaleOwnerOrSequenceConflict;
        try self.reach(.after_transition_head_advance);

        const insert = try self.prepare(
            \\INSERT INTO session_transition (session_id, sequence, payload, record_digest)
            \\VALUES (?1, ?2, ?3, ?4)
        );
        defer finalize(insert);
        try bindIdentity(insert, 1, request.token.session_id, &identities[0]);
        try bindU64(insert, 2, sequence);
        try bindBlob(insert, 3, request.payload);
        try bindBlob(insert, 4, &digest);
        try expectDone(c.sqlite3_step(insert));
        try self.reach(.after_transition_insert);

        for (request.conversations) |entry| try self.commitConversation(
            request.token.session_id,
            sequence,
            entry,
        );
        for (request.completions) |association| try self.associateCompletion(
            request.token.session_id,
            sequence,
            association,
        );
        if (request.capacity_class == .admission) try self.ensureAdmissionCapacity();
        try self.reach(.before_commit);
        try self.execute("COMMIT");
        return sequence;
    }

    fn associateCompletion(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        association: CompletionAssociation,
    ) !void {
        var ids: [7][8]u8 = undefined;
        const statement = try self.prepare(associate_completion_sql);
        defer finalize(statement);
        try bindIdentity(statement, 1, session_id, &ids[0]);
        try bindU64(statement, 2, sequence);
        try bindIdentity(statement, 3, association.ownership_epoch, &ids[1]);
        try bindU64(statement, 4, association.agent_generation);
        try bindIdentity(statement, 5, association.operation_id, &ids[2]);
        try bindU64(statement, 6, association.operation_generation);
        try bindIdentity(statement, 7, association.attempt_id, &ids[3]);
        try bindU64(statement, 8, association.evidence_kind);
        try bindIdentity(statement, 9, association.result_reference, &ids[4]);
        try bindIdentity(statement, 10, association.result_digest, &ids[5]);
        try bindIdentity(statement, 11, association.agent_id, &ids[6]);
        try expectDone(c.sqlite3_step(statement));
        if (c.sqlite3_changes(self.database) != 1) return error.CompletionEvidenceMissing;
    }

    fn commitConversation(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        entry: ConversationInsert,
    ) !void {
        if (entry.entry_id == 0 or entry.content_ref == 0 or entry.kind < 1 or entry.kind > 4) {
            return error.InvalidConversationEntry;
        }
        var ids: [4][8]u8 = undefined;
        const insert = try self.prepare(
            \\INSERT INTO conversation_entry (
            \\    session_id, entry_id, parent_id, kind, content_ref, committed_by_sequence
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(session_id, entry_id) DO UPDATE SET
            \\    committed_by_sequence = excluded.committed_by_sequence
            \\WHERE conversation_entry.parent_id IS excluded.parent_id
            \\  AND conversation_entry.kind = excluded.kind
            \\  AND conversation_entry.content_ref = excluded.content_ref
            \\  AND conversation_entry.committed_by_sequence IS NULL
        );
        defer finalize(insert);
        try bindIdentity(insert, 1, session_id, &ids[0]);
        try bindIdentity(insert, 2, entry.entry_id, &ids[1]);
        if (entry.parent_id == 0) try expectOk(c.sqlite3_bind_null(insert, 3)) else try bindIdentity(insert, 3, entry.parent_id, &ids[2]);
        try bindU64(insert, 4, entry.kind);
        try bindIdentity(insert, 5, entry.content_ref, &ids[3]);
        try bindU64(insert, 6, sequence);
        try expectDone(c.sqlite3_step(insert));
        if (c.sqlite3_changes(self.database) != 1) return error.ConversationProjectionConflict;

        const advance = try self.prepare(advance_conversation_sql);
        defer finalize(advance);
        try bindIdentity(advance, 1, session_id, &ids[0]);
        try bindIdentity(advance, 2, entry.entry_id, &ids[1]);
        try bindU64(advance, 3, entry.entry_id);
        try expectDone(c.sqlite3_step(advance));
        if (entry.entry_id != 1 and c.sqlite3_changes(self.database) != 1) {
            return error.ConversationProjectionConflict;
        }
    }

    pub fn readTransition(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        out: *StoredTransition,
    ) !void {
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

        const payload_length = c.sqlite3_column_bytes(statement, 0);
        const digest_length = c.sqlite3_column_bytes(statement, 1);
        if (payload_length <= 0 or payload_length > max_transition_payload or digest_length != 32) {
            return error.CorruptHostStore;
        }
        const payload_pointer = c.sqlite3_column_blob(statement, 0) orelse {
            return error.CorruptHostStore;
        };
        const digest_pointer = c.sqlite3_column_blob(statement, 1) orelse {
            return error.CorruptHostStore;
        };
        out.* = .{
            .session_id = session_id,
            .sequence = sequence,
            .payload = undefined,
            .payload_length = @intCast(payload_length),
            .record_digest = undefined,
        };
        const payload_bytes: [*]const u8 = @ptrCast(payload_pointer);
        @memcpy(out.payload[0..out.payload_length], payload_bytes[0..out.payload_length]);
        const digest_bytes: [*]const u8 = @ptrCast(digest_pointer);
        @memcpy(&out.record_digest, digest_bytes[0..32]);
        var actual_digest: [32]u8 = undefined;
        recordDigest(session_id, sequence, out.payloadSlice(), &actual_digest);
        if (!std.mem.eql(u8, &actual_digest, &out.record_digest)) return error.PayloadDigestMismatch;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    pub fn readConversationEntry(
        self: *StorageOwner,
        session_id: u64,
        entry_id: u64,
    ) !StoredConversationEntry {
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
        const committed: ?u64 = if (c.sqlite3_column_type(statement, 3) == c.SQLITE_NULL)
            null
        else blk: {
            const value = c.sqlite3_column_int64(statement, 3);
            if (value <= 0) return error.CorruptHostStore;
            break :blk @intCast(value);
        };
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
        self.execute("PRAGMA user_version=1") catch |err| return err;
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
        try self.validateSchemaMetadata();
        const queries = [_][:0]const u8{
            "SELECT session_id, agent_id, task_id, branch_id, workspace_path, model, ownership_epoch, active_leaf_id, entry_count, head_sequence, inbox_head FROM session LIMIT 0",
            "SELECT session_id, sequence, payload, record_digest FROM session_transition LIMIT 0",
            "SELECT session_id, entry_id, parent_id, kind, content_ref, committed_by_sequence FROM conversation_entry LIMIT 0",
            "SELECT session_id, inbox_sequence, ownership_epoch, agent_generation, operation_id, operation_generation, attempt_id, evidence_kind, result_reference, result_digest, consumed_by_sequence FROM completion_inbox LIMIT 0",
        };
        for (queries) |query| {
            const statement = self.prepare(query) catch |err| switch (err) {
                error.HostStoreFailure => return error.InvalidHostStoreSchema,
                else => return err,
            };
            defer finalize(statement);
        }
        const lifecycle_statements = [_][:0]const u8{
            read_session_sql,
            session_head_sql,
            claim_ownership_sql,
            current_ownership_sql,
            completion_head_sql,
            find_completion_sql,
            advance_inbox_head_sql,
            read_completion_sql,
            advance_session_head_sql,
            associate_completion_sql,
            advance_conversation_sql,
            read_transition_sql,
            read_conversation_sql,
        };
        for (lifecycle_statements) |sql| {
            const statement = self.prepare(sql) catch |err| switch (err) {
                error.HostStoreFailure => return error.InvalidHostStoreSchema,
                else => return err,
            };
            defer finalize(statement);
        }
    }

    fn validateSchemaMetadata(self: *StorageOwner) !void {
        const tables = [_]struct { name: []const u8, without_rowid: u8 }{
            .{ .name = "session", .without_rowid = 0 },
            .{ .name = "session_transition", .without_rowid = 1 },
            .{ .name = "conversation_entry", .without_rowid = 0 },
            .{ .name = "completion_inbox", .without_rowid = 1 },
        };
        const metadata = try self.prepare(
            "SELECT type, wr, strict FROM pragma_table_list WHERE schema = 'main' AND name = ?1",
        );
        defer finalize(metadata);
        for (tables) |table| {
            try expectOk(c.sqlite3_reset(metadata));
            try expectOk(c.sqlite3_clear_bindings(metadata));
            try bindText(metadata, 1, table.name);
            if (c.sqlite3_step(metadata) != c.SQLITE_ROW or
                !columnTextEquals(metadata, 0, "table") or
                c.sqlite3_column_int(metadata, 1) != table.without_rowid or
                c.sqlite3_column_int(metadata, 2) != 1 or
                c.sqlite3_step(metadata) != c.SQLITE_DONE)
            {
                return error.InvalidHostStoreSchema;
            }
        }
        try self.expectSchemaSql("table", "session", session_schema);
        try self.expectSchemaSql("table", "session_transition", transition_schema);
        try self.expectSchemaSql("table", "conversation_entry", conversation_schema);
        try self.expectSchemaSql("table", "completion_inbox", completion_schema);
        try self.expectSchemaSql("index", "completion_inbox_unconsumed", completion_index_schema);
        try self.expectSchemaCount(
            "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
            5,
        );
        try self.expectSchemaCount(
            "SELECT count(*) FROM sqlite_schema WHERE type = 'index' AND name = 'completion_inbox_unconsumed' AND tbl_name = 'completion_inbox'",
            1,
        );
        try self.expectSchemaCount("SELECT count(*) FROM pragma_foreign_key_list('session_transition')", 1);
        try self.expectSchemaCount("SELECT count(*) FROM pragma_foreign_key_list('conversation_entry')", 3);
        try self.expectSchemaCount("SELECT count(*) FROM pragma_foreign_key_list('completion_inbox')", 3);
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
    if (config.sqlite_heap_limit_bytes < 1024 * 1024 or
        config.sqlite_heap_limit_bytes > std.math.maxInt(i64))
    {
        return error.InvalidSqliteHeapLimit;
    }
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

fn recordDigest(session_id: u64, sequence: u64, payload: []const u8, out: *[32]u8) void {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update("onepage-ledger-v1\x00");
    var identity: [16]u8 = undefined;
    std.mem.writeInt(u64, identity[0..8], session_id, .little);
    std.mem.writeInt(u64, identity[8..16], sequence, .little);
    hasher.update(&identity);
    hasher.update(payload);
    hasher.final(out);
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
        "CREATE TABLE session (session_id BLOB); PRAGMA application_id=1330532423; PRAGMA user_version=1",
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
    try owner.expectSchemaSql("index", "completion_inbox_unconsumed", completion_index_schema);
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

test "populated lifecycle statements use indexes without scans or temporary materialization" {
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
    _ = try owner.publishCompletion(.{
        .kind = .model,
        .session_id = 8,
        .ownership_epoch = 1,
        .agent_id = 9,
        .agent_generation = 1,
        .operation_id = 101,
        .operation_generation = 1,
        .attempt_id = 102,
        .result_ref = 103,
        .result_digest = 104,
    });
    _ = try owner.commit(.{
        .token = .{ .session_id = 8, .epoch = 1 },
        .expected_sequence = 0,
        .payload = "populated-plan",
        .conversations = &.{.{
            .entry_id = 2,
            .parent_id = 1,
            .kind = 2,
            .content_ref = 105,
        }},
    });
    try owner.execute("ANALYZE");

    const plans = [_][:0]const u8{
        "EXPLAIN QUERY PLAN " ++ read_session_sql,
        "EXPLAIN QUERY PLAN " ++ session_head_sql,
        "EXPLAIN QUERY PLAN " ++ claim_ownership_sql,
        "EXPLAIN QUERY PLAN " ++ current_ownership_sql,
        "EXPLAIN QUERY PLAN " ++ completion_head_sql,
        "EXPLAIN QUERY PLAN " ++ find_completion_sql,
        "EXPLAIN QUERY PLAN " ++ advance_inbox_head_sql,
        "EXPLAIN QUERY PLAN " ++ read_completion_sql,
        "EXPLAIN QUERY PLAN " ++ advance_session_head_sql,
        "EXPLAIN QUERY PLAN " ++ associate_completion_sql,
        "EXPLAIN QUERY PLAN " ++ advance_conversation_sql,
        "EXPLAIN QUERY PLAN " ++ read_transition_sql,
        "EXPLAIN QUERY PLAN " ++ read_conversation_sql,
    };
    for (plans) |sql| try expectIndexedPlan(&owner, sql);
}

fn expectIndexedPlan(owner: *StorageOwner, sql: [:0]const u8) !void {
    const statement = try owner.prepare(sql);
    defer finalize(statement);
    var saw_search = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length <= 0) return error.InvalidQueryPlan;
            const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
            const detail = pointer[0..@intCast(length)];
            if (std.mem.startsWith(u8, detail, "SCAN ") or
                std.mem.indexOf(u8, detail, "USE TEMP B-TREE") != null)
            {
                return error.UnboundedQueryPlan;
            }
            if (std.mem.startsWith(u8, detail, "SEARCH ")) saw_search = true;
        },
        c.SQLITE_DONE => break,
        else => |result| return mapSqliteError(result),
    };
    if (!saw_search) return error.UnindexedQueryPlan;
}
