const std = @import("std");
const completion_inbox = @import("completion_inbox.zig");
const session_transition = @import("session_transition.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema_version: u32 = 1;
pub const application_id: u32 = 0x4f4e5047; // "ONPG"
pub const max_path_bytes: usize = 1024;
pub const max_transition_payload: usize = 4096;
pub const max_workspace_path_bytes: usize = 1024;
pub const max_model_bytes: usize = 128;

const identity_schema =
    \\CREATE TABLE host_store_identity (
    \\    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    \\    application_id TEXT NOT NULL CHECK (application_id = 'onepage.host-store'),
    \\    schema_version INTEGER NOT NULL CHECK (schema_version > 0)
    \\) STRICT
;
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
    \\    payload_version INTEGER NOT NULL CHECK (payload_version > 0),
    \\    kind INTEGER NOT NULL CHECK (kind > 0),
    \\    payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 65536),
    \\    digest BLOB NOT NULL CHECK (length(digest) = 32),
    \\    PRIMARY KEY (session_id, sequence),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id)
    \\) STRICT, WITHOUT ROWID
;
const checkpoint_schema =
    \\CREATE TABLE state_checkpoint (
    \\    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 8),
    \\    sequence INTEGER NOT NULL CHECK (sequence >= 0),
    \\    payload_version INTEGER NOT NULL CHECK (payload_version > 0),
    \\    payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 65536),
    \\    digest BLOB NOT NULL CHECK (length(digest) = 32),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id)
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

pub const TransitionKind = session_transition.Kind;

pub const PreparedTransition = struct {
    session_id: u64,
    expected_sequence: u64,
    payload_version: u16,
    kind: TransitionKind,
    payload: []const u8,
    digest: [32]u8,
};

pub const PreparedRecord = struct {
    payload_version: u16,
    kind: TransitionKind,
    payload: []const u8,
    digest: [32]u8,
};

pub const PreparedBatch = struct {
    session_id: u64,
    expected_sequence: u64,
    records: []const PreparedRecord,
};

pub const StoredTransition = struct {
    session_id: u64,
    sequence: u64,
    payload_version: u16,
    kind: TransitionKind,
    payload: [max_transition_payload]u8,
    payload_length: u16,
    digest: [32]u8,

    pub fn payloadSlice(self: *const StoredTransition) []const u8 {
        return self.payload[0..self.payload_length];
    }
};

pub const PreparedCheckpoint = struct {
    session_id: u64,
    sequence: u64,
    payload_version: u16,
    payload: []const u8,
    digest: [32]u8,
};

pub const StoredCheckpoint = struct {
    sequence: u64,
    payload_version: u16,
    payload_length: u32,
    digest: [32]u8,
};

pub const StoredCompletion = struct {
    envelope: completion_inbox.Envelope,
    consumed_by_sequence: ?u64,
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
    page_cache_highwater_bytes: u64,
    lookaside_current_slots: u64,
    lookaside_highwater_slots: u64,
    statements_current_bytes: u64,
    statements_highwater_bytes: u64,
};

pub const BackupProgress = struct {
    copied_pages: u32,
    remaining_pages: u32,
    total_pages: u32,
    complete: bool,
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
    backup_destination: ?*c.sqlite3 = null,
    backup_handle: ?*c.sqlite3_backup = null,
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
        const existing_store = try fileHasContent(io, path);

        if (config.sqlite_heap_limit_bytes > std.math.maxInt(i64)) {
            return error.InvalidSqliteHeapLimit;
        }
        _ = c.sqlite3_hard_heap_limit64(@intCast(config.sqlite_heap_limit_bytes));

        var maybe_database: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE |
            c.SQLITE_OPEN_NOMUTEX | c.SQLITE_OPEN_PRIVATECACHE;
        const open_result = c.sqlite3_open_v2(&terminated_path, &maybe_database, flags, null);
        if (open_result != c.SQLITE_OK) {
            if (maybe_database) |database| _ = c.sqlite3_close_v2(database);
            return mapSqliteError(open_result);
        }
        const database = maybe_database orelse return error.HostStoreOpenFailed;
        errdefer _ = c.sqlite3_close_v2(database);

        var owner: StorageOwner = .{
            .io = io,
            .lock_file = lock_file,
            .database = database,
            .fault = config.fault,
            .admission_reserve_pages = config.admission_reserve_pages,
            .sqlite_heap_limit_bytes = config.sqlite_heap_limit_bytes,
        };
        if (existing_store) try owner.verifySchemaIdentity();
        try owner.harden(config);
        if (!existing_store) try owner.installSchema();
        try owner.verifySchemaIdentity();
        try owner.validateSchemaShape();
        return owner;
    }

    pub fn close(self: *StorageOwner) void {
        if (!self.open_) return;
        self.finishBackup();
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
        try self.ensureAdmissionCapacity();
        const statement = try self.prepare(
            \\INSERT INTO session (
            \\    session_id, agent_id, task_id, branch_id, workspace_path, model, active_leaf_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded_identities: [5][8]u8 = undefined;
        try bindIdentity(statement, 1, descriptor.identities.session_id, &encoded_identities[0]);
        try bindIdentity(statement, 2, descriptor.identities.agent_id, &encoded_identities[1]);
        try bindIdentity(statement, 3, descriptor.identities.task_id, &encoded_identities[2]);
        try bindIdentity(statement, 4, descriptor.identities.branch_id, &encoded_identities[3]);
        try bindText(statement, 5, descriptor.workspace_path);
        try bindText(statement, 6, descriptor.model);
        try bindIdentity(statement, 7, 1, &encoded_identities[4]);
        try expectDone(c.sqlite3_step(statement));
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
            .page_cache_highwater_bytes = cache.highwater,
            .lookaside_current_slots = lookaside.current,
            .lookaside_highwater_slots = lookaside.highwater,
            .statements_current_bytes = statements.current,
            .statements_highwater_bytes = statements.highwater,
        };
    }

    pub fn beginBackup(self: *StorageOwner, destination_path: []const u8) !void {
        try self.ensureOpen();
        if (self.backup_handle != null) return error.BackupAlreadyActive;
        if (destination_path.len == 0 or destination_path.len > max_path_bytes) {
            return error.InvalidBackupPath;
        }
        if (try fileHasContent(self.io, destination_path)) return error.BackupDestinationExists;
        var terminated_path: [max_path_bytes:0]u8 = undefined;
        @memcpy(terminated_path[0..destination_path.len], destination_path);
        terminated_path[destination_path.len] = 0;
        var destination: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(
            &terminated_path,
            &destination,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX |
                c.SQLITE_OPEN_PRIVATECACHE,
            null,
        );
        if (open_result != c.SQLITE_OK) {
            if (destination) |database| _ = c.sqlite3_close_v2(database);
            return mapSqliteError(open_result);
        }
        const destination_database = destination orelse return error.BackupOpenFailed;
        errdefer _ = c.sqlite3_close_v2(destination_database);
        const backup = c.sqlite3_backup_init(
            destination_database,
            "main",
            self.database,
            "main",
        ) orelse return mapSqliteError(c.sqlite3_errcode(destination_database));
        self.backup_destination = destination_database;
        self.backup_handle = backup;
    }

    pub fn driveBackup(self: *StorageOwner, page_quantum: u8) !BackupProgress {
        try self.ensureOpen();
        if (page_quantum == 0 or page_quantum > 64) return error.InvalidBackupQuantum;
        const backup = self.backup_handle orelse return error.BackupNotActive;
        const result = c.sqlite3_backup_step(backup, page_quantum);
        const remaining = c.sqlite3_backup_remaining(backup);
        const total = c.sqlite3_backup_pagecount(backup);
        if (remaining < 0 or total < 0 or remaining > total) {
            self.finishBackup();
            return error.CorruptBackupProgress;
        }
        const progress: BackupProgress = .{
            .copied_pages = @intCast(total - remaining),
            .remaining_pages = @intCast(remaining),
            .total_pages = @intCast(total),
            .complete = result == c.SQLITE_DONE,
        };
        if (result == c.SQLITE_DONE) {
            try self.completeBackup();
            return progress;
        }
        if (result != c.SQLITE_OK) {
            self.finishBackup();
            return mapSqliteError(result);
        }
        return progress;
    }

    pub fn readSession(self: *StorageOwner, session_id: u64) !StoredSession {
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT agent_id, task_id, branch_id, ownership_epoch, active_leaf_id,
            \\       entry_count, workspace_path, model
            \\FROM session WHERE session_id = ?1
        );
        defer _ = c.sqlite3_finalize(statement);
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
        const statement = try self.prepare(
            "SELECT head_sequence FROM session WHERE session_id = ?1",
        );
        defer _ = c.sqlite3_finalize(statement);
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

    pub fn rebuildConversationProjection(
        self: *StorageOwner,
        session_id: u64,
        active_leaf_id: u64,
        entry_count: u64,
    ) !void {
        try self.ensureOpen();
        if (session_id == 0 or active_leaf_id == 0 or active_leaf_id != entry_count) {
            return error.InvalidConversationProjection;
        }
        const statement = try self.prepare(
            "UPDATE session SET active_leaf_id = ?2, entry_count = ?3 WHERE session_id = ?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded: [2][8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded[0]);
        try bindIdentity(statement, 2, active_leaf_id, &encoded[1]);
        try bindU64(statement, 3, entry_count);
        try expectDone(c.sqlite3_step(statement));
        if (c.sqlite3_changes(self.database) != 1) return error.SessionNotFound;
    }

    pub fn claimSession(self: *StorageOwner, session_id: u64) !u64 {
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\UPDATE session SET ownership_epoch = ownership_epoch + 1
            \\WHERE session_id = ?1 AND ownership_epoch < 9223372036854775807
            \\RETURNING ownership_epoch
        );
        defer _ = c.sqlite3_finalize(statement);
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
        const statement = try self.prepare(
            "SELECT ownership_epoch FROM session WHERE session_id = ?1",
        );
        defer _ = c.sqlite3_finalize(statement);
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
        const statement = try self.prepare(
            "SELECT inbox_head FROM session WHERE session_id = ?1",
        );
        defer _ = c.sqlite3_finalize(statement);
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
        const existing = try self.prepare(
            \\SELECT c.inbox_sequence, c.result_reference, c.result_digest
            \\FROM completion_inbox AS c
            \\JOIN session AS s ON s.session_id = c.session_id
            \\WHERE c.session_id = ?1 AND c.ownership_epoch = ?2
            \\  AND s.agent_id = ?3 AND c.agent_generation = ?4
            \\  AND c.operation_id = ?5 AND c.operation_generation = ?6
            \\  AND c.attempt_id = ?7 AND c.evidence_kind = ?8
        );
        defer _ = c.sqlite3_finalize(existing);
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

        const advance = try self.prepare(
            "UPDATE session SET inbox_head = ?2 WHERE session_id = ?1 AND inbox_head = ?3",
        );
        defer _ = c.sqlite3_finalize(advance);
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
        defer _ = c.sqlite3_finalize(insert);
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
        const statement = try self.prepare(
            \\SELECT c.evidence_kind, c.ownership_epoch, s.agent_id, c.agent_generation,
            \\       c.operation_id, c.operation_generation, c.attempt_id,
            \\       c.result_reference, c.result_digest, c.consumed_by_sequence
            \\FROM completion_inbox AS c
            \\JOIN session AS s ON s.session_id = c.session_id
            \\WHERE c.session_id = ?1 AND c.inbox_sequence = ?2
        );
        defer _ = c.sqlite3_finalize(statement);
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

    pub fn putCheckpoint(
        self: *StorageOwner,
        checkpoint_record: PreparedCheckpoint,
    ) !void {
        try self.ensureOpen();
        if (checkpoint_record.session_id == 0) return error.InvalidIdentity;
        if (checkpoint_record.sequence > std.math.maxInt(i64)) return error.InvalidSequence;
        if (checkpoint_record.payload_version == 0 or checkpoint_record.payload.len == 0 or
            checkpoint_record.payload.len > 65_536)
        {
            return error.InvalidCheckpointPayload;
        }
        var actual_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(
            checkpoint_record.payload,
            &actual_digest,
            .{},
        );
        if (!std.mem.eql(u8, &actual_digest, &checkpoint_record.digest)) {
            return error.CheckpointDigestMismatch;
        }
        if (checkpoint_record.sequence > try self.sessionHead(checkpoint_record.session_id)) {
            return error.CheckpointAheadOfLedger;
        }
        const statement = try self.prepare(
            \\INSERT INTO state_checkpoint (
            \\    session_id, sequence, payload_version, payload, digest
            \\) VALUES (?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT (session_id) DO UPDATE SET
            \\    sequence = excluded.sequence,
            \\    payload_version = excluded.payload_version,
            \\    payload = excluded.payload,
            \\    digest = excluded.digest
            \\WHERE excluded.sequence >= state_checkpoint.sequence
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, checkpoint_record.session_id, &encoded_session_id);
        try bindU64(statement, 2, checkpoint_record.sequence);
        try bindU64(statement, 3, checkpoint_record.payload_version);
        try bindBlob(statement, 4, checkpoint_record.payload);
        try bindBlob(statement, 5, &checkpoint_record.digest);
        try expectDone(c.sqlite3_step(statement));
    }

    pub fn readCheckpoint(
        self: *StorageOwner,
        session_id: u64,
        out: []u8,
    ) !StoredCheckpoint {
        try self.ensureOpen();
        if (session_id == 0) return error.InvalidIdentity;
        const statement = try self.prepare(
            \\SELECT sequence, payload_version, payload, digest
            \\FROM state_checkpoint WHERE session_id = ?1
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.CheckpointNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const sequence = c.sqlite3_column_int64(statement, 0);
        const payload_version = c.sqlite3_column_int64(statement, 1);
        const payload_length = c.sqlite3_column_bytes(statement, 2);
        const digest_length = c.sqlite3_column_bytes(statement, 3);
        if (sequence < 0 or payload_version <= 0 or payload_version > std.math.maxInt(u16) or
            payload_length <= 0 or payload_length > out.len or digest_length != 32)
        {
            return error.CorruptCheckpoint;
        }
        const payload_pointer = c.sqlite3_column_blob(statement, 2) orelse {
            return error.CorruptCheckpoint;
        };
        const digest_pointer = c.sqlite3_column_blob(statement, 3) orelse {
            return error.CorruptCheckpoint;
        };
        const payload_bytes: [*]const u8 = @ptrCast(payload_pointer);
        @memcpy(out[0..@intCast(payload_length)], payload_bytes[0..@intCast(payload_length)]);
        var digest: [32]u8 = undefined;
        const digest_bytes: [*]const u8 = @ptrCast(digest_pointer);
        @memcpy(&digest, digest_bytes[0..32]);
        var actual_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out[0..@intCast(payload_length)], &actual_digest, .{});
        if (!std.mem.eql(u8, &actual_digest, &digest)) return error.CheckpointDigestMismatch;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return .{
            .sequence = @intCast(sequence),
            .payload_version = @intCast(payload_version),
            .payload_length = @intCast(payload_length),
            .digest = digest,
        };
    }

    pub fn appendTransition(
        self: *StorageOwner,
        transition: PreparedTransition,
    ) !u64 {
        return self.appendBatch(.{
            .session_id = transition.session_id,
            .expected_sequence = transition.expected_sequence,
            .records = &.{.{
                .payload_version = transition.payload_version,
                .kind = transition.kind,
                .payload = transition.payload,
                .digest = transition.digest,
            }},
        });
    }

    pub fn appendBatch(self: *StorageOwner, batch: PreparedBatch) !u64 {
        try self.ensureOpen();
        if (batch.session_id == 0) return error.InvalidIdentity;
        if (batch.records.len == 0 or batch.records.len > 8) return error.InvalidTransitionCount;
        if (batch.expected_sequence > session_transition.max_transitions - batch.records.len) {
            return error.SessionSequenceExhausted;
        }
        for (batch.records, 0..) |record, index| {
            if (record.payload_version == 0 or record.payload.len == 0 or
                record.payload.len > max_transition_payload)
            {
                return error.InvalidTransitionPayload;
            }
            if (record.payload_version != session_transition.payload_version) {
                return error.UnsupportedTransitionPayloadVersion;
            }
            const decoded = try session_transition.decode(record.payload);
            if (decoded.fact.kind != record.kind) return error.TransitionKindProjectionMismatch;
            if (decoded.sequence != batch.expected_sequence + index + 1) {
                return error.TransitionSequenceProjectionMismatch;
            }
            if (decoded.core != null and index + 1 != batch.records.len) {
                return error.InvalidCoreTransitionOrder;
            }
            const actual_digest = try session_transition.digest(record.payload);
            if (!std.mem.eql(u8, &actual_digest, &record.digest)) {
                return error.PayloadDigestMismatch;
            }
        }

        for (batch.records) |record| {
            const kind = (try session_transition.decode(record.payload)).fact.kind;
            if (kind == .task_admitted or kind == .operation_submitted or
                kind == .attempt_admitted)
            {
                try self.ensureAdmissionCapacity();
                break;
            }
        }

        const current_head = try self.sessionHead(batch.session_id);
        if (current_head != batch.expected_sequence) return error.SessionSequenceConflict;
        const final_sequence = batch.expected_sequence + batch.records.len;

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();

        const advance = try self.prepare(
            "UPDATE session SET head_sequence = ?2 WHERE session_id = ?1 AND head_sequence = ?3",
        );
        defer _ = c.sqlite3_finalize(advance);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(advance, 1, batch.session_id, &encoded_session_id);
        try bindU64(advance, 2, final_sequence);
        try bindU64(advance, 3, batch.expected_sequence);
        try expectDone(c.sqlite3_step(advance));
        if (c.sqlite3_changes(self.database) != 1) return error.SessionSequenceConflict;
        try self.reach(.after_transition_head_advance);

        for (batch.records, 0..) |record, index| {
            const insert = try self.prepare(
                \\INSERT INTO session_transition (
                \\    session_id, sequence, payload_version, kind, payload, digest
                \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindIdentity(insert, 1, batch.session_id, &encoded_session_id);
            try bindU64(insert, 2, batch.expected_sequence + index + 1);
            try bindU64(insert, 3, record.payload_version);
            try bindU64(insert, 4, @intFromEnum(record.kind));
            try bindBlob(insert, 5, record.payload);
            try bindBlob(insert, 6, &record.digest);
            try expectDone(c.sqlite3_step(insert));
            try self.reach(.after_transition_insert);
            const decoded = try session_transition.decode(record.payload);
            if (decoded.fact.kind == .result and decoded.fact.attempt_id != 0) {
                try self.associateCompletion(
                    batch.session_id,
                    batch.expected_sequence + index + 1,
                    decoded.fact,
                );
            }
            if (decoded.fact.kind == .conversation_advanced) {
                try self.advanceConversation(batch.session_id, decoded.fact.subject);
            }
        }

        try self.reach(.before_commit);
        try self.execute("COMMIT");
        return final_sequence;
    }

    fn associateCompletion(
        self: *StorageOwner,
        session_id: u64,
        sequence: u64,
        fact: session_transition.Fact,
    ) !void {
        std.debug.assert(fact.kind == .result and fact.attempt_id != 0);
        var identities: [7][8]u8 = undefined;
        const statement = try self.prepare(
            \\UPDATE completion_inbox SET consumed_by_sequence = ?2
            \\WHERE session_id = ?1 AND consumed_by_sequence IS NULL
            \\  AND ownership_epoch = ?3 AND agent_generation = ?4
            \\  AND operation_id = ?5 AND operation_generation = ?6
            \\  AND attempt_id = ?7 AND evidence_kind = ?8
            \\  AND result_reference = ?9 AND result_digest = ?10
            \\  AND session_id IN (SELECT session_id FROM session WHERE agent_id = ?11)
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindIdentity(statement, 1, session_id, &identities[0]);
        try bindU64(statement, 2, sequence);
        try bindIdentity(statement, 3, fact.ownership_epoch, &identities[1]);
        try bindU64(statement, 4, fact.agent_generation);
        try bindIdentity(statement, 5, fact.operation_id, &identities[2]);
        try bindU64(statement, 6, fact.generation);
        try bindIdentity(statement, 7, fact.attempt_id, &identities[3]);
        try bindU64(statement, 8, fact.evidence_kind);
        try bindIdentity(statement, 9, fact.reference, &identities[4]);
        try bindIdentity(statement, 10, fact.digest, &identities[5]);
        try bindIdentity(statement, 11, fact.agent_id, &identities[6]);
        try expectDone(c.sqlite3_step(statement));
        switch (c.sqlite3_changes(self.database)) {
            0 => return error.CompletionEvidenceMissing,
            1 => {},
            else => return error.AmbiguousCompletionEvidence,
        }
    }

    fn advanceConversation(
        self: *StorageOwner,
        session_id: u64,
        entry_id: u64,
    ) !void {
        const session = try self.readSession(session_id);
        if (entry_id <= session.entry_count) {
            if (entry_id != session.active_leaf_id) return error.ConversationProjectionConflict;
            return;
        }
        if (entry_id != session.entry_count + 1) return error.ConversationProjectionGap;
        const statement = try self.prepare(
            \\UPDATE session SET active_leaf_id = ?2, entry_count = ?3
            \\WHERE session_id = ?1 AND entry_count = ?4
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded_values: [2][8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_values[0]);
        try bindIdentity(statement, 2, entry_id, &encoded_values[1]);
        try bindU64(statement, 3, entry_id);
        try bindU64(statement, 4, session.entry_count);
        try expectDone(c.sqlite3_step(statement));
        if (c.sqlite3_changes(self.database) != 1) return error.ConversationProjectionConflict;
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

        const statement = try self.prepare(
            \\SELECT payload_version, kind, payload, digest
            \\FROM session_transition
            \\WHERE session_id = ?1 AND sequence = ?2
        );
        defer _ = c.sqlite3_finalize(statement);
        var encoded_session_id: [8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &encoded_session_id);
        try bindU64(statement, 2, sequence);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.TransitionNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);

        const payload_version = c.sqlite3_column_int64(statement, 0);
        const kind_value = c.sqlite3_column_int64(statement, 1);
        const payload_length = c.sqlite3_column_bytes(statement, 2);
        const digest_length = c.sqlite3_column_bytes(statement, 3);
        if (payload_version <= 0 or payload_version > std.math.maxInt(u16) or
            kind_value <= 0 or kind_value > std.math.maxInt(u16) or
            payload_length <= 0 or payload_length > max_transition_payload or
            digest_length != 32)
        {
            return error.CorruptHostStore;
        }
        const kind = std.enums.fromInt(
            TransitionKind,
            @as(u16, @intCast(kind_value)),
        ) orelse return error.UnsupportedTransitionKind;
        const payload_pointer = c.sqlite3_column_blob(statement, 2) orelse {
            return error.CorruptHostStore;
        };
        const digest_pointer = c.sqlite3_column_blob(statement, 3) orelse {
            return error.CorruptHostStore;
        };
        out.* = .{
            .session_id = session_id,
            .sequence = sequence,
            .payload_version = @intCast(payload_version),
            .kind = kind,
            .payload = undefined,
            .payload_length = @intCast(payload_length),
            .digest = undefined,
        };
        const payload_bytes: [*]const u8 = @ptrCast(payload_pointer);
        @memcpy(out.payload[0..out.payload_length], payload_bytes[0..out.payload_length]);
        const digest_bytes: [*]const u8 = @ptrCast(digest_pointer);
        @memcpy(&out.digest, digest_bytes[0..32]);

        const decoded = try session_transition.decode(out.payloadSlice());
        if (decoded.sequence != sequence) return error.TransitionSequenceProjectionMismatch;
        if (decoded.fact.kind != out.kind) return error.TransitionKindProjectionMismatch;
        if (out.payload_version != session_transition.payload_version) {
            return error.TransitionVersionProjectionMismatch;
        }
        const actual_digest = try session_transition.digest(out.payloadSlice());
        if (!std.mem.eql(u8, &actual_digest, &out.digest)) return error.PayloadDigestMismatch;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    fn harden(self: *StorageOwner, config: Config) !void {
        _ = c.sqlite3_extended_result_codes(self.database, 1);
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
        self.execute("PRAGMA application_id=1330532423") catch |err| return err;
        inline for (.{ identity_schema, session_schema, transition_schema, checkpoint_schema, completion_schema }) |sql| {
            self.execute(sql) catch |err| return err;
        }
        self.execute(
            \\INSERT INTO host_store_identity (singleton, application_id, schema_version)
            \\VALUES (1, 'onepage.host-store', 1)
        ) catch |err| return err;
        self.execute(completion_index_schema) catch |err| return err;
        self.execute("COMMIT") catch |err| {
            self.rollbackOrPoison();
            return err;
        };
    }

    fn verifySchemaIdentity(self: *StorageOwner) !void {
        if (try self.pragmaU64("PRAGMA application_id") != application_id) {
            return error.InvalidHostStoreIdentity;
        }
        const statement = self.prepare(
            "SELECT application_id, schema_version FROM host_store_identity WHERE singleton = 1",
        ) catch |err| switch (err) {
            error.HostStoreFailure => return error.InvalidHostStoreIdentity,
            else => return err,
        };
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.InvalidHostStoreIdentity;
        const application_pointer = c.sqlite3_column_text(statement, 0) orelse {
            return error.InvalidHostStoreIdentity;
        };
        const application_bytes: [*]const u8 = @ptrCast(application_pointer);
        const application_length = c.sqlite3_column_bytes(statement, 0);
        if (application_length != "onepage.host-store".len or
            !std.mem.eql(u8, application_bytes[0..@intCast(application_length)], "onepage.host-store"))
        {
            return error.InvalidHostStoreIdentity;
        }
        const found_version = c.sqlite3_column_int64(statement, 1);
        if (found_version != schema_version) return error.UnsupportedHostStoreVersion;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
    }

    fn validateSchemaShape(self: *StorageOwner) !void {
        const expected_objects = .{
            .{ "index", "completion_inbox_unconsumed", completion_index_schema },
            .{ "table", "completion_inbox", completion_schema },
            .{ "table", "host_store_identity", identity_schema },
            .{ "table", "session", session_schema },
            .{ "table", "session_transition", transition_schema },
            .{ "table", "state_checkpoint", checkpoint_schema },
        };
        const objects = try self.prepare(
            \\SELECT type, name, sql FROM sqlite_schema
            \\WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
            \\ORDER BY type, name
        );
        defer _ = c.sqlite3_finalize(objects);
        inline for (expected_objects) |expected| {
            if (c.sqlite3_step(objects) != c.SQLITE_ROW) return error.InvalidHostStoreSchema;
            inline for (0..3) |column| {
                const value = c.sqlite3_column_text(objects, column) orelse
                    return error.InvalidHostStoreSchema;
                const length = c.sqlite3_column_bytes(objects, column);
                if (length != expected[column].len or
                    !std.mem.eql(u8, value[0..@intCast(length)], expected[column]))
                {
                    return error.InvalidHostStoreSchema;
                }
            }
        }
        if (c.sqlite3_step(objects) != c.SQLITE_DONE) return error.InvalidHostStoreSchema;

        const queries = [_][:0]const u8{
            "SELECT session_id, agent_id, task_id, branch_id, workspace_path, model, ownership_epoch, active_leaf_id, entry_count, head_sequence, inbox_head FROM session LIMIT 0",
            "SELECT session_id, sequence, payload_version, kind, payload, digest FROM session_transition LIMIT 0",
            "SELECT session_id, sequence, payload_version, payload, digest FROM state_checkpoint LIMIT 0",
            "SELECT session_id, inbox_sequence, ownership_epoch, agent_generation, operation_id, operation_generation, attempt_id, evidence_kind, result_reference, result_digest, consumed_by_sequence FROM completion_inbox LIMIT 0",
        };
        for (queries) |query| {
            const statement = self.prepare(query) catch |err| switch (err) {
                error.HostStoreFailure => return error.InvalidHostStoreSchema,
                else => return err,
            };
            defer _ = c.sqlite3_finalize(statement);
        }
        const expected_tables = [_]struct { name: []const u8, without_rowid: bool }{
            .{ .name = "completion_inbox", .without_rowid = true },
            .{ .name = "host_store_identity", .without_rowid = false },
            .{ .name = "session", .without_rowid = false },
            .{ .name = "session_transition", .without_rowid = true },
            .{ .name = "state_checkpoint", .without_rowid = false },
        };
        const tables = try self.prepare(
            \\SELECT name, wr, strict FROM pragma_table_list
            \\WHERE schema = 'main' AND name NOT LIKE 'sqlite_%'
            \\ORDER BY name
        );
        defer _ = c.sqlite3_finalize(tables);
        for (expected_tables) |expected| {
            if (c.sqlite3_step(tables) != c.SQLITE_ROW) return error.InvalidHostStoreSchema;
            const name_pointer = c.sqlite3_column_text(tables, 0) orelse {
                return error.InvalidHostStoreSchema;
            };
            const name_length = c.sqlite3_column_bytes(tables, 0);
            if (name_length != expected.name.len or
                !std.mem.eql(u8, name_pointer[0..@intCast(name_length)], expected.name) or
                c.sqlite3_column_int(tables, 1) != @intFromBool(expected.without_rowid) or
                c.sqlite3_column_int(tables, 2) != 1)
            {
                return error.InvalidHostStoreSchema;
            }
        }
        if (c.sqlite3_step(tables) != c.SQLITE_DONE) return error.InvalidHostStoreSchema;
        if (try self.scalarSql(
            "SELECT count(*) FROM pragma_index_list('completion_inbox') WHERE name='completion_inbox_unconsumed'",
        ) != 1 or
            try self.scalarSql("SELECT count(*) FROM pragma_foreign_key_list('session_transition')") != 1 or
            try self.scalarSql("SELECT count(*) FROM pragma_foreign_key_list('state_checkpoint')") != 1 or
            try self.scalarSql("SELECT count(*) FROM pragma_foreign_key_list('completion_inbox')") != 3)
        {
            return error.InvalidHostStoreSchema;
        }
    }

    fn scalarSql(self: *StorageOwner, sql: [:0]const u8) !u64 {
        const statement = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.InvalidHostStoreSchema;
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0 or c.sqlite3_step(statement) != c.SQLITE_DONE) {
            return error.InvalidHostStoreSchema;
        }
        return @intCast(value);
    }

    fn ensureAdmissionCapacity(self: *StorageOwner) !void {
        const page_count = try self.pragmaU64("PRAGMA page_count");
        const maximum_page_count = try self.pragmaU64("PRAGMA max_page_count");
        if (page_count > maximum_page_count or
            maximum_page_count - page_count < self.admission_reserve_pages)
        {
            return error.HostStoreCapacityReserved;
        }
    }

    fn pragmaU64(self: *StorageOwner, sql: [:0]const u8) !u64 {
        const statement = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
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

    fn completeBackup(self: *StorageOwner) !void {
        const backup = self.backup_handle orelse return error.BackupNotActive;
        const destination = self.backup_destination orelse return error.BackupNotActive;
        self.backup_handle = null;
        self.backup_destination = null;
        const finish_result = c.sqlite3_backup_finish(backup);
        const close_result = c.sqlite3_close_v2(destination);
        if (finish_result != c.SQLITE_OK) return mapSqliteError(finish_result);
        if (close_result != c.SQLITE_OK) return mapSqliteError(close_result);
    }

    fn finishBackup(self: *StorageOwner) void {
        if (self.backup_handle) |backup| _ = c.sqlite3_backup_finish(backup);
        if (self.backup_destination) |destination| _ = c.sqlite3_close_v2(destination);
        self.backup_handle = null;
        self.backup_destination = null;
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

fn fileHasContent(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    return (try file.length(io)) != 0;
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

fn nonnegative(value: anytype) !u64 {
    if (value < 0) return error.CorruptSqliteAccounting;
    return @intCast(value);
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
