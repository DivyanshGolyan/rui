const std = @import("std");
const binding = @import("binding.zig");
const completion_inbox = @import("completion_inbox.zig");
const patch_tool = @import("patch_tool.zig");
const persisted_format = @import("persisted_format.zig");
const session_transition = @import("session_transition.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema_version: u32 = persisted_format.epoch;
pub const application_id: u32 = 0x4f4e5047; // "ONPG"
pub const max_path_bytes: usize = 1024;
pub const max_transition_payload: usize = session_transition.max_payload_size;
pub const max_workspace_path_bytes: usize = 1024;
pub const max_model_bytes: usize = 128;
pub const max_content_bytes: usize = 1024 * 1024;
pub const content_window_bytes: usize = 4096;
/// The largest first-import closure shipped by V1 is one apply-patch admission:
/// patch bytes, its canonical Patch Intent, and the Tool Call content. Existing
/// content references do not consume this bound.
pub const max_first_content_imports: usize = 3;
// SQLITE_LIMIT_LENGTH covers the encoded row, not only its largest BLOB. The
// content schema has bounded identity, digest, and record-header overhead.
const sqlite_row_overhead_bytes: usize = 4096;
const sqlite_max_length_bytes = max_content_bytes + sqlite_row_overhead_bytes;

const install_schema_version = std.fmt.comptimePrint(
    "PRAGMA user_version={d}",
    .{schema_version},
);

comptime {
    std.debug.assert(max_transition_payload == 1012);
}

const session_schema =
    \\CREATE TABLE session (
    \\    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 8),
    \\    agent_id BLOB NOT NULL CHECK (length(agent_id) = 8),
    \\    task_id BLOB NOT NULL CHECK (length(task_id) = 8),
    \\    workspace_path TEXT NOT NULL CHECK (length(workspace_path) BETWEEN 1 AND 1024),
    \\    model TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128),
    \\    ownership_epoch INTEGER NOT NULL DEFAULT 1 CHECK (ownership_epoch > 0),
    \\    head_sequence INTEGER NOT NULL DEFAULT 0 CHECK (head_sequence >= 0),
    \\    UNIQUE (agent_id),
    \\    UNIQUE (task_id)
    \\) STRICT
;
const content_schema =
    \\CREATE TABLE content (
    \\    content_id INTEGER PRIMARY KEY,
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    content_ref BLOB NOT NULL CHECK (length(content_ref) = 8),
    \\    byte_length INTEGER NOT NULL CHECK (byte_length BETWEEN 1 AND 1048576),
    \\    digest BLOB NOT NULL CHECK (length(digest) = 32),
    \\    payload BLOB NOT NULL CHECK (length(payload) = byte_length),
    \\    UNIQUE (session_id, content_ref),
    \\    FOREIGN KEY (session_id) REFERENCES session (session_id)
    \\) STRICT
;
const transition_schema =
    \\CREATE TABLE session_transition (
    \\    session_id BLOB NOT NULL CHECK (length(session_id) = 8),
    \\    sequence INTEGER NOT NULL CHECK (sequence > 0),
    \\    payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 1012),
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
    \\    FOREIGN KEY (session_id, content_ref)
    \\        REFERENCES content (session_id, content_ref),
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
    \\    FOREIGN KEY (session_id, result_reference)
    \\        REFERENCES content (session_id, content_ref),
    \\    FOREIGN KEY (session_id, consumed_by_sequence)
    \\        REFERENCES session_transition (session_id, sequence)
    \\) STRICT
;
const completion_index_schema =
    \\CREATE INDEX completion_inbox_by_session
    \\ON completion_inbox (session_id, consumed_by_sequence, inbox_id)
;

const read_session_sql: [:0]const u8 =
    \\SELECT agent_id, task_id, ownership_epoch, workspace_path, model
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
const read_content_sql: [:0]const u8 =
    \\SELECT content_id, byte_length, digest
    \\FROM content WHERE session_id = ?1 AND content_ref = ?2
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

pub const CompletionMatch = union(enum) { pending, consumed: u64 };

/// The exact admitted Attempt and the first terminal Result transaction for
/// its Operation. This is reconstructed from the authoritative bounded ledger
/// rather than retained as an unbounded resident history.
pub const CompletedAttempt = struct {
    operation: session_transition.OperationRecord,
    attempt: session_transition.AttemptRecord,
    terminal_result_sequence: u64,
};

pub const CompletedAttemptScan = struct {
    next_sequence: u64 = 1,
    operation: ?session_transition.OperationRecord = null,
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

pub const ContentMetadata = struct {
    length: u64,
    digest: binding.Blob,
};

pub const ContentSource = union(enum) {
    bytes: []const u8,
    file: struct {
        handle: *const std.Io.File,
        offset: u64,
    },
};

/// One already-bounded transient value to import inside the transaction that
/// first references it. File sources are borrowed, position-independent, and
/// remain owned by the caller until the transaction returns.
pub const ContentImport = struct {
    reference: u64,
    length: u64,
    digest: binding.Blob,
    source: ContentSource,
};

pub const CompletionResult = union(enum) {
    existing,
    first_import: ContentImport,
};

pub const CompletionPublication = union(enum) {
    pending: struct {
        envelope: completion_inbox.Envelope,
        result: CompletionResult,
    },
    audited: struct {
        envelope: completion_inbox.Envelope,
        result: CompletionResult,
        consumed_by_sequence: u64,
    },

    fn envelope(self: CompletionPublication) completion_inbox.Envelope {
        return switch (self) {
            .pending => |value| value.envelope,
            .audited => |value| value.envelope,
        };
    }

    fn result(self: CompletionPublication) CompletionResult {
        return switch (self) {
            .pending => |value| value.result,
            .audited => |value| value.result,
        };
    }

    fn auditSequence(self: CompletionPublication) ?u64 {
        return switch (self) {
            .pending => null,
            .audited => |value| value.consumed_by_sequence,
        };
    }
};

/// A closed prepared relationship between content imported by one semantic
/// transaction and the facts that first reference it.
pub const TransactionContentImport = union(enum) {
    transaction_fact: ContentImport,
    patch_intent: struct {
        intent: ContentImport,
        patch: ContentImport,
    },
};

pub const PreparedCommit = struct {
    transaction: session_transition.Transaction,
    content: []const TransactionContentImport = &.{},
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

/// SQLite-maintained storage work and pager counters. Production fixes the
/// journal mode during database initialization; this reports only values with
/// a current measurement consumer.
pub const SqlitePagerAccounting = struct {
    page_size_bytes: u64,
    page_count: u64,
    freelist_pages: u64,
    cache_pages_written: u64,
    cache_spill_events: u64,
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

    pub fn validate(self: SessionIdentity) !void {
        const values = [_]u64{
            self.session_id,
            self.agent_id,
            self.task_id,
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
        const task = "fixture task";
        return self.createSessionWithContent(.{
            .identities = identity,
            .workspace_path = ".",
            .model = "fixture:test",
        }, initialTransaction(identity), .{
            .reference = identity.task_id,
            .length = task.len,
            .digest = binding.hash(binding.Blob, task),
            .source = .{ .bytes = task },
        });
    }

    pub fn createSessionWithMetadata(
        self: *StorageOwner,
        descriptor: SessionDescriptor,
        transaction: session_transition.Transaction,
    ) !void {
        const task = "fixture task";
        return self.createSessionWithContent(descriptor, transaction, .{
            .reference = descriptor.identities.task_id,
            .length = task.len,
            .digest = binding.hash(binding.Blob, task),
            .source = .{ .bytes = task },
        });
    }

    pub fn createSessionWithContent(
        self: *StorageOwner,
        descriptor: SessionDescriptor,
        transaction: session_transition.Transaction,
        task_content: ContentImport,
    ) !void {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        try descriptor.identities.validate();
        if (descriptor.workspace_path.len == 0 or
            descriptor.workspace_path.len > max_workspace_path_bytes or
            descriptor.model.len == 0 or descriptor.model.len > max_model_bytes or
            !std.unicode.utf8ValidateSlice(descriptor.model))
        {
            return error.InvalidSessionMetadata;
        }
        if (transaction.sequence != 1) return error.InvalidTransitionSequence;
        try validateTransactionIdentity(descriptor.identities, transaction);
        if (task_content.reference != descriptor.identities.task_id) {
            return error.InvalidContentReference;
        }
        var payload_buffer: [session_transition.max_payload_size]u8 = undefined;
        const payload = try session_transition.encode(&payload_buffer, transaction);

        try self.execute("BEGIN IMMEDIATE");
        errdefer self.rollbackOrPoison();
        const statement = try self.prepare(
            \\INSERT INTO session (
            \\    session_id, agent_id, task_id, workspace_path, model, head_sequence
            \\) VALUES (?1, ?2, ?3, ?4, ?5, 1)
        );
        defer finalize(statement);
        var encoded_identities: [3][8]u8 = undefined;
        try bindIdentity(statement, 1, descriptor.identities.session_id, &encoded_identities[0]);
        try bindIdentity(statement, 2, descriptor.identities.agent_id, &encoded_identities[1]);
        try bindIdentity(statement, 3, descriptor.identities.task_id, &encoded_identities[2]);
        try bindText(statement, 4, descriptor.workspace_path);
        try bindText(statement, 5, descriptor.model);
        try expectDone(c.sqlite3_step(statement));
        try self.insertContent(descriptor.identities.session_id, task_content);
        try self.insertTransaction(descriptor.identities.session_id, transaction, payload);
        try self.ensureAdmissionCapacity();
        try self.reach(.before_commit);
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

    pub fn sqlitePagerAccounting(
        self: *StorageOwner,
        reset_counters: bool,
    ) !SqlitePagerAccounting {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const writes = try self.databaseStatus(c.SQLITE_DBSTATUS_CACHE_WRITE, reset_counters);
        const spills = try self.databaseStatus(c.SQLITE_DBSTATUS_CACHE_SPILL, reset_counters);
        return .{
            .page_size_bytes = try self.pragmaU64("PRAGMA page_size"),
            .page_count = try self.pragmaU64("PRAGMA page_count"),
            .freelist_pages = try self.pragmaU64("PRAGMA freelist_count"),
            .cache_pages_written = writes.current,
            .cache_spill_events = spills.current,
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
        const ownership_epoch = c.sqlite3_column_int64(statement, 2);
        const workspace_length = c.sqlite3_column_bytes(statement, 3);
        const model_length = c.sqlite3_column_bytes(statement, 4);
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
            },
            .ownership_epoch = @intCast(ownership_epoch),
            .workspace_path = undefined,
            .workspace_path_length = @intCast(workspace_length),
            .model = undefined,
            .model_length = @intCast(model_length),
        };
        try stored.identities.validate();
        const workspace_pointer = c.sqlite3_column_text(statement, 3) orelse {
            return error.CorruptHostStore;
        };
        const model_pointer = c.sqlite3_column_text(statement, 4) orelse {
            return error.CorruptHostStore;
        };
        @memcpy(
            stored.workspace_path[0..stored.workspace_path_length],
            workspace_pointer[0..stored.workspace_path_length],
        );
        @memcpy(stored.model[0..stored.model_length], model_pointer[0..stored.model_length]);
        if (!std.unicode.utf8ValidateSlice(stored.modelName())) return error.CorruptHostStore;
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
        publication: CompletionPublication,
    ) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const envelope = publication.envelope();
        const consumed_by_sequence = publication.auditSequence();
        const result = publication.result();
        if (consumed_by_sequence) |sequence| {
            if (sequence == 0) return error.InvalidSequence;
        }
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
            try self.reach(.before_commit);
            try self.execute("COMMIT");
            return @intCast(sequence);
        }
        if (existing_result != c.SQLITE_DONE) return mapSqliteError(existing_result);

        const count = try self.prepare(pending_completion_count_sql);
        defer finalize(count);
        try bindIdentity(count, 1, envelope.session_id, &identities[0]);
        try bindIdentity(count, 2, envelope.agent_id, &identities[2]);
        const count_result = c.sqlite3_step(count);
        if (count_result == c.SQLITE_DONE) return error.InvalidCompletionIdentity;
        if (count_result != c.SQLITE_ROW) return mapSqliteError(count_result);
        const pending_count = c.sqlite3_column_int64(count, 0);
        if (pending_count < 0) return error.CorruptHostStore;
        if (consumed_by_sequence == null and pending_count >= completion_inbox.max_records) {
            return error.CompletionCapacityExceeded;
        }
        if (c.sqlite3_step(count) != c.SQLITE_DONE) return error.CorruptHostStore;

        switch (result) {
            .first_import => |value| {
                if (value.reference != envelope.result_ref) return error.CompletionContentMismatch;
                try self.insertContent(envelope.session_id, value);
            },
            .existing => try self.requireContent(envelope.session_id, envelope.result_ref),
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
        try self.reach(.before_commit);
        try self.execute("COMMIT");
        return @intCast(inbox_id);
    }

    /// Matches one complete evidence envelope against the immutable Inbox row
    /// selected by its semantic identity. The caller receives no row fields to
    /// reinterpret or use as a second source of authority.
    pub fn matchCompletion(
        self: *StorageOwner,
        envelope: completion_inbox.Envelope,
    ) !?CompletionMatch {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        try completion_inbox.validate(envelope);

        const statement = try self.prepare(find_completion_sql);
        defer finalize(statement);
        var identities: [4][8]u8 = undefined;
        try bindIdentity(statement, 1, envelope.session_id, &identities[0]);
        try bindIdentity(statement, 2, envelope.agent_id, &identities[1]);
        try bindU64(statement, 3, envelope.agent_generation);
        try bindIdentity(statement, 4, envelope.operation_id, &identities[2]);
        try bindU64(statement, 5, envelope.operation_generation);
        try bindIdentity(statement, 6, envelope.attempt_id, &identities[3]);
        try bindU64(statement, 7, @intFromEnum(envelope.kind));
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const inbox_id = c.sqlite3_column_int64(statement, 0);
        if (inbox_id <= 0) return error.CorruptHostStore;
        const result_ref = try readIdentityColumn(statement, 1);
        const result_digest = try readBindingColumn(binding.Result, statement, 2);
        const completion_digest = try readBindingColumn(binding.Completion, statement, 3);
        const ownership_epoch = try readIdentityColumn(statement, 4);
        if (ownership_epoch != envelope.ownership_epoch or result_ref != envelope.result_ref or
            !binding.eql(binding.Result, result_digest, envelope.result_digest) or
            !binding.eql(binding.Completion, completion_digest, envelope.completion_digest))
        {
            return error.ConflictingCompletionEvidence;
        }
        const disposition: CompletionMatch = switch (c.sqlite3_column_type(statement, 5)) {
            c.SQLITE_NULL => .pending,
            c.SQLITE_INTEGER => consumed: {
                const sequence = c.sqlite3_column_int64(statement, 5);
                if (sequence <= 0) return error.CorruptHostStore;
                break :consumed .{ .consumed = @intCast(sequence) };
            },
            else => return error.CorruptHostStore,
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return disposition;
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
        return self.commitPrepared(token, .{ .transaction = transaction });
    }

    pub fn commitPrepared(
        self: *StorageOwner,
        token: OwnerToken,
        prepared: PreparedCommit,
    ) !u64 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const transaction = prepared.transaction;
        const contents = prepared.content;
        if (token.session_id == 0 or token.epoch == 0) return error.StaleOwner;
        if (contents.len > session_transition.max_facts) return error.ExcessiveContentImports;
        if (transaction.sequence == 0 or transaction.sequence > session_transition.max_transitions) {
            return error.SessionSequenceExhausted;
        }
        try self.validateTransactionContentImports(transaction, contents);
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
        for (contents) |content| switch (content) {
            .transaction_fact => |value| try self.insertContent(token.session_id, value),
            .patch_intent => |value| {
                try self.insertContent(token.session_id, value.intent);
                try self.insertContent(token.session_id, value.patch);
            },
        };
        try self.requireTransactionContent(token.session_id, transaction);
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
            .operation_admitted,
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

    pub fn contentMetadata(
        self: *StorageOwner,
        session_id: u64,
        reference: u64,
    ) !ContentMetadata {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const stored = try self.findContent(session_id, reference);
        return .{ .length = stored.length, .digest = stored.digest };
    }

    pub fn readContentWindow(
        self: *StorageOwner,
        session_id: u64,
        reference: u64,
        offset: u64,
        out: []u8,
    ) ![]const u8 {
        self.request_lock.lockUncancelable(self.io);
        defer self.request_lock.unlock(self.io);
        try self.ensureOpen();
        const stored = try self.findContent(session_id, reference);
        if (offset > stored.length) return error.InvalidContentOffset;
        const wanted: usize = @intCast(@min(stored.length - offset, out.len));
        if (wanted == 0) return out[0..0];
        var blob: ?*c.sqlite3_blob = null;
        try expectOk(c.sqlite3_blob_open(
            self.database,
            "main",
            "content",
            "payload",
            stored.row_id,
            0,
            &blob,
        ));
        const opened = blob orelse return error.CorruptHostStore;
        defer closeBlob(opened);
        if (offset > std.math.maxInt(c_int) or wanted > std.math.maxInt(c_int)) {
            return error.InvalidContentOffset;
        }
        try expectOk(c.sqlite3_blob_read(
            opened,
            out.ptr,
            @intCast(wanted),
            @intCast(offset),
        ));
        return out[0..wanted];
    }

    const StoredContent = struct {
        row_id: c.sqlite3_int64,
        length: u64,
        digest: binding.Blob,
    };

    fn findContent(
        self: *StorageOwner,
        session_id: u64,
        reference: u64,
    ) !StoredContent {
        if (session_id == 0 or reference == 0) return error.InvalidContentReference;
        const statement = try self.prepare(read_content_sql);
        defer finalize(statement);
        var ids: [2][8]u8 = undefined;
        try bindIdentity(statement, 1, session_id, &ids[0]);
        try bindIdentity(statement, 2, reference, &ids[1]);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return error.ContentNotFound;
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const row_id = c.sqlite3_column_int64(statement, 0);
        const length_value = c.sqlite3_column_int64(statement, 1);
        if (row_id <= 0 or length_value <= 0 or length_value > max_content_bytes) {
            return error.CorruptHostStore;
        }
        const stored: StoredContent = .{
            .row_id = row_id,
            .length = @intCast(length_value),
            .digest = try readBindingColumn(binding.Blob, statement, 2),
        };
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptHostStore;
        return stored;
    }

    fn requireContent(self: *StorageOwner, session_id: u64, reference: u64) !void {
        if (reference == 0) return;
        _ = self.findContent(session_id, reference) catch |err| switch (err) {
            error.ContentNotFound => return error.MissingContentReference,
            else => return err,
        };
    }

    fn requireTransactionContent(
        self: *StorageOwner,
        session_id: u64,
        transaction: session_transition.Transaction,
    ) !void {
        for (transaction.factSlice()) |fact| {
            const references = fact.contentReferences();
            for (references.slice()) |reference| {
                try self.requireContent(session_id, reference.reference);
            }
        }
    }

    fn validateTransactionContentImports(
        self: *StorageOwner,
        transaction: session_transition.Transaction,
        contents: []const TransactionContentImport,
    ) !void {
        var imported_references: [max_first_content_imports]u64 = undefined;
        var imported_count: usize = 0;
        for (contents) |entry| switch (entry) {
            .transaction_fact => |content| {
                try appendImportReference(&imported_references, &imported_count, content.reference);
                if (!transaction.referencesContent(content.reference)) {
                    return error.UnreferencedContentImport;
                }
            },
            .patch_intent => |pair| {
                try appendImportReference(&imported_references, &imported_count, pair.intent.reference);
                try appendImportReference(&imported_references, &imported_count, pair.patch.reference);
                if (pair.intent.reference == pair.patch.reference or
                    !transaction.referencesPatchIntent(pair.intent.reference) or
                    transaction.referencesContent(pair.patch.reference))
                {
                    return error.InvalidPatchContentReference;
                }
                const patch_reference = try self.decodePatchIntentReference(pair.intent);
                if (patch_reference != pair.patch.reference) {
                    return error.InvalidPatchContentReference;
                }
            },
        };
    }

    fn decodePatchIntentReference(self: *StorageOwner, content: ContentImport) !u64 {
        if (content.length < patch_tool.intent_header_size or
            content.length > patch_tool.max_intent_size)
        {
            return error.InvalidPatchIntent;
        }
        var buffer: [patch_tool.max_intent_size]u8 = undefined;
        const length: usize = @intCast(content.length);
        const bytes = switch (content.source) {
            .bytes => |value| blk: {
                if (value.len != length) return error.InvalidContentLength;
                break :blk value;
            },
            .file => |source| blk: {
                const actual = try source.handle.readPositionalAll(
                    self.io,
                    buffer[0..length],
                    source.offset,
                );
                if (actual != length) return error.TruncatedContent;
                break :blk buffer[0..length];
            },
        };
        const intent = patch_tool.decodeIntent(bytes) catch return error.InvalidPatchIntent;
        return intent.patch_ref;
    }

    fn appendImportReference(
        references: *[max_first_content_imports]u64,
        count: *usize,
        reference: u64,
    ) !void {
        if (reference == 0) return error.InvalidContentReference;
        for (references[0..count.*]) |prior| {
            if (prior == reference) return error.DuplicateContentImport;
        }
        if (count.* == references.len) return error.ExcessiveContentImports;
        references[count.*] = reference;
        count.* += 1;
    }

    fn insertContent(
        self: *StorageOwner,
        session_id: u64,
        content: ContentImport,
    ) !void {
        if (session_id == 0 or content.reference == 0) return error.InvalidContentReference;
        if (content.length == 0 or content.length > max_content_bytes or
            content.length > std.math.maxInt(c_int))
        {
            return error.InvalidContentLength;
        }
        switch (content.source) {
            .bytes => |bytes| if (bytes.len != content.length) return error.InvalidContentLength,
            .file => {},
        }
        if (self.findContent(session_id, content.reference)) |stored| {
            if (stored.length != content.length or
                !binding.eql(binding.Blob, stored.digest, content.digest))
            {
                return error.ConflictingContentReference;
            }
            return error.ContentAlreadyExists;
        } else |err| switch (err) {
            error.ContentNotFound => {},
            else => return err,
        }

        const insert = try self.prepare(
            \\INSERT INTO content (
            \\    session_id, content_ref, byte_length, digest, payload
            \\) VALUES (?1, ?2, ?3, ?4, zeroblob(?5))
            \\RETURNING content_id
        );
        defer finalize(insert);
        var ids: [2][8]u8 = undefined;
        try bindIdentity(insert, 1, session_id, &ids[0]);
        try bindIdentity(insert, 2, content.reference, &ids[1]);
        try bindU64(insert, 3, content.length);
        try bindBlob(insert, 4, &content.digest.bytes);
        try bindU64(insert, 5, content.length);
        const result = c.sqlite3_step(insert);
        if (result != c.SQLITE_ROW) return mapSqliteError(result);
        const row_id = c.sqlite3_column_int64(insert, 0);
        if (row_id <= 0) return error.CorruptHostStore;
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.CorruptHostStore;

        var blob: ?*c.sqlite3_blob = null;
        try expectOk(c.sqlite3_blob_open(
            self.database,
            "main",
            "content",
            "payload",
            row_id,
            1,
            &blob,
        ));
        const opened = blob orelse return error.CorruptHostStore;
        defer closeBlob(opened);

        var hasher = binding.Hasher(binding.Blob).init();
        var offset: u64 = 0;
        var window: [content_window_bytes]u8 = undefined;
        while (offset < content.length) {
            const wanted: usize = @intCast(@min(content.length - offset, window.len));
            const bytes = switch (content.source) {
                .bytes => |source| source[@intCast(offset)..][0..wanted],
                .file => |file| blk: {
                    const read = try file.handle.readPositionalAll(
                        self.io,
                        window[0..wanted],
                        file.offset + offset,
                    );
                    if (read != wanted) return error.TruncatedContentImport;
                    break :blk window[0..wanted];
                },
            };
            try expectOk(c.sqlite3_blob_write(
                opened,
                bytes.ptr,
                @intCast(bytes.len),
                @intCast(offset),
            ));
            hasher.update(bytes);
            offset += bytes.len;
        }
        if (!binding.eql(binding.Blob, hasher.final(), content.digest)) {
            return error.ContentDigestMismatch;
        }
    }

    fn harden(self: *StorageOwner, config: Config) !void {
        try expectOk(c.sqlite3_extended_result_codes(self.database, 1));
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DQS_DDL, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_DQS_DML, 0);
        try dbConfig(self.database, c.SQLITE_DBCONFIG_ENABLE_FKEY, 1);

        _ = c.sqlite3_limit(self.database, c.SQLITE_LIMIT_LENGTH, sqlite_max_length_bytes);
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
        inline for (.{ session_schema, content_schema, transition_schema, conversation_schema, completion_schema }) |sql| {
            self.execute(sql) catch |err| return err;
        }
        self.execute(completion_index_schema) catch |err| return err;
        self.execute("PRAGMA application_id=1330532423") catch |err| return err;
        self.execute(install_schema_version) catch |err| return err;
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
        try self.expectSchemaSql("table", "content", content_schema);
        try self.expectSchemaSql("table", "session_transition", transition_schema);
        try self.expectSchemaSql("table", "conversation_entry", conversation_schema);
        try self.expectSchemaSql("table", "completion_inbox", completion_schema);
        try self.expectSchemaSql("index", "completion_inbox_by_session", completion_index_schema);
        try self.expectSchemaCount(
            "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
            6,
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
        .task_admitted, .operation_admitted, .attempt_admitted => return true,
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

fn closeBlob(blob: *c.sqlite3_blob) void {
    // Blob I/O errors are returned by read/write. Close only releases the
    // short-lived handle before the owning transaction completes.
    _ = c.sqlite3_blob_close(blob);
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
        .operation_admitted => |operation| {
            if (operation.operation.operation_id != operation_id or
                operation.operation.generation != operation_generation)
            {
                continue;
            }
            if (scan.terminal_before_attempt) return error.InvalidHistoricalCompletionOrdering;
            if (scan.operation) |existing| {
                if (!std.meta.eql(existing, operation)) return error.ConflictingLedgerFacts;
            } else scan.operation = operation;
        },
        .attempt_admitted => |attempt| {
            if (attempt.operation.operation_id != operation_id or
                attempt.operation.generation != operation_generation or
                attempt.attempt_id != attempt_id)
            {
                continue;
            }
            if (scan.terminal_before_attempt) return error.InvalidHistoricalCompletionOrdering;
            const operation = scan.operation orelse return error.InvalidHistoricalCompletionOrdering;
            if (!std.meta.eql(operation.operation, attempt.operation) or
                operation.descriptor_ref != attempt.descriptor_ref or
                !binding.descriptorEql(operation.descriptor_digest, attempt.descriptor_digest))
            {
                return error.InvalidHistoricalCompletionRelationship;
            }
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
                const operation = scan.operation orelse {
                    scan.terminal_before_attempt = true;
                    continue;
                };
                if (!std.meta.eql(attempt.operation, result.operation)) {
                    return error.InvalidHistoricalCompletionRelationship;
                }
                scan.completed = .{
                    .operation = operation,
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

fn testContent(reference: u64) ContentImport {
    const bytes = "host-store-test-content";
    return .{
        .reference = reference,
        .length = bytes.len,
        .digest = binding.hash(binding.Blob, bytes),
        .source = .{ .bytes = bytes },
    };
}

fn directContent(content: ContentImport) TransactionContentImport {
    return .{ .transaction_fact = content };
}

fn pendingPublication(
    envelope: completion_inbox.Envelope,
    result: CompletionResult,
) CompletionPublication {
    return .{ .pending = .{ .envelope = envelope, .result = result } };
}

fn auditedPublication(
    envelope: completion_inbox.Envelope,
    result: CompletionResult,
    sequence: u64,
) CompletionPublication {
    return .{ .audited = .{
        .envelope = envelope,
        .result = result,
        .consumed_by_sequence = sequence,
    } };
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
        std.fmt.comptimePrint(
            "CREATE TABLE session (session_id BLOB); PRAGMA application_id=1330532423; PRAGMA user_version={d}",
            .{schema_version},
        ),
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
    try owner.expectSchemaSql("table", "content", content_schema);
    try owner.expectSchemaSql("table", "session_transition", transition_schema);
    try owner.expectSchemaSql("table", "conversation_entry", conversation_schema);
    try owner.expectSchemaSql("table", "completion_inbox", completion_schema);
    try owner.expectSchemaSql("index", "completion_inbox_by_session", completion_index_schema);
}

test "Host Store round trips Conversation kinds and rejects hostile kinds" {
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

    const identity: SessionIdentity = .{
        .session_id = 81,
        .agent_id = 82,
        .task_id = 83,
    };
    try owner.createSession(identity);
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = 85,
    });
    _ = try owner.commitPrepared(
        .{ .session_id = identity.session_id, .epoch = 1 },
        .{ .transaction = transaction, .content = &.{directContent(testContent(85))} },
    );

    const stored = try owner.readConversationEntry(identity.session_id, 2);
    try std.testing.expectEqual(@intFromEnum(session_transition.ConversationKind.assistant_text), stored.kind);
    try std.testing.expectEqual(@as(u64, 1), stored.parent_id);
    try std.testing.expectEqual(@as(u64, 85), stored.content_ref);

    try owner.execute("PRAGMA ignore_check_constraints=ON");
    try owner.execute("UPDATE conversation_entry SET kind=5");
    try std.testing.expectError(
        error.CorruptHostStore,
        owner.readConversationEntry(identity.session_id, 2),
    );
}

test "pre-release Host Store rejects the preceding schema epoch" {
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
        std.fmt.comptimePrint(
            "CREATE TABLE legacy_schema (value INTEGER); PRAGMA application_id=1330532423; PRAGMA user_version={d}",
            .{schema_version - 1},
        ),
        null,
        null,
        null,
    ));
    try expectOk(c.sqlite3_close_v2(database));

    try std.testing.expectError(
        error.UnsupportedHostStoreVersion,
        StorageOwner.open(std.testing.io, path, .{}),
    );
}

test "model identity is valid UTF-8 before write and after hostile persistence" {
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
    const identity: SessionIdentity = .{ .session_id = 11, .agent_id = 12, .task_id = 13 };
    try std.testing.expectError(
        error.InvalidSessionMetadata,
        owner.createSessionWithMetadata(.{
            .identities = identity,
            .workspace_path = ".",
            .model = "fixture:\xff",
        }, initialTransaction(identity)),
    );
    try owner.createSessionWithMetadata(.{
        .identities = identity,
        .workspace_path = ".",
        .model = "fixture:valid",
    }, initialTransaction(identity));
    try owner.execute("UPDATE session SET model=CAST(X'FF' AS TEXT)");
    try std.testing.expectError(error.CorruptHostStore, owner.readSession(identity.session_id));
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
        });
    }
    const completion = completion_inbox.bind(.{
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
    });
    _ = try owner.publishCompletion(pendingPublication(
        completion,
        .{ .first_import = testContent(103) },
    ));
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
    const inbox_id = try owner.publishCompletion(auditedPublication(
        envelope,
        .{ .first_import = testContent(103) },
        1,
    ));
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
    const pending_id = try owner.publishCompletion(pendingPublication(
        pending,
        .{ .first_import = testContent(106) },
    ));
    try std.testing.expectEqual(pending_id, try owner.completionHead(8));
    try std.testing.expectEqual(pending_id, try owner.publishCompletion(auditedPublication(
        pending,
        .existing,
        1,
    )));
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
        owner.publishCompletion(auditedPublication(cross_epoch, .existing, 1)),
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
        owner.publishCompletion(auditedPublication(conflicting, .existing, 1)),
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
        try owner.insertContent(8, testContent(index + 10_000));
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

    try std.testing.expectError(error.CompletionCapacityExceeded, owner.publishCompletion(pendingPublication(completion_inbox.bind(.{
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
    }), .existing)));
}

test "content and its first durable reference share one SQLite commit" {
    const FailBeforeCommit = struct {
        armed: bool = false,

        fn reached(context: *anyopaque, boundary: FaultBoundary) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.armed and boundary == .before_commit) return error.InjectedCrash;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fault: FailBeforeCommit = .{};
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var owner = try StorageOwner.open(std.testing.io, path, .{
        .fault = .{ .context = &fault, .reached = FailBeforeCommit.reached },
    });
    defer owner.close();

    fault.armed = true;
    const identity: SessionIdentity = .{
        .session_id = 301,
        .agent_id = 302,
        .task_id = 303,
    };
    try std.testing.expectError(error.InjectedCrash, owner.createSession(identity));
    try std.testing.expectError(error.SessionNotFound, owner.readSession(identity.session_id));
    try std.testing.expectError(
        error.ContentNotFound,
        owner.contentMetadata(identity.session_id, identity.task_id),
    );

    fault.armed = false;
    try owner.createSession(identity);
    var semantic: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    semantic.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = 305,
    });
    fault.armed = true;
    try std.testing.expectError(
        error.InjectedCrash,
        owner.commitPrepared(
            .{ .session_id = identity.session_id, .epoch = 1 },
            .{ .transaction = semantic, .content = &.{directContent(testContent(305))} },
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(identity.session_id));
    try std.testing.expectError(
        error.ContentNotFound,
        owner.contentMetadata(identity.session_id, 305),
    );
    try std.testing.expectError(
        error.ConversationEntryNotFound,
        owner.readConversationEntry(identity.session_id, 2),
    );

    const completion = completion_inbox.bind(.{
        .kind = .model,
        .session_id = identity.session_id,
        .ownership_epoch = 1,
        .agent_id = identity.agent_id,
        .agent_generation = 1,
        .operation_id = 306,
        .operation_generation = 1,
        .attempt_id = 307,
        .result_ref = 308,
        .result_digest = binding.hash(binding.Result, "completion-content"),
    });
    try std.testing.expectError(
        error.InjectedCrash,
        owner.publishCompletion(pendingPublication(
            completion,
            .{ .first_import = testContent(308) },
        )),
    );
    try std.testing.expectEqual(@as(u64, 0), try owner.completionHead(identity.session_id));
    try std.testing.expectError(
        error.ContentNotFound,
        owner.contentMetadata(identity.session_id, 308),
    );
}

test "content survives reopen through fixed windows and remains Session scoped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var bytes: [content_window_bytes * 2 + 17]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const content: ContentImport = .{
        .reference = 405,
        .length = bytes.len,
        .digest = binding.hash(binding.Blob, &bytes),
        .source = .{ .bytes = &bytes },
    };

    {
        var owner = try StorageOwner.open(std.testing.io, path, .{});
        defer owner.close();
        try owner.createSession(.{
            .session_id = 401,
            .agent_id = 402,
            .task_id = 403,
        });
        var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
        transaction.facts[0] = session_transition.conversationAdvanced(.{
            .agent = .{ .agent_id = 402, .agent_generation = 1, .ownership_epoch = 1 },
            .entry_id = 2,
            .parent_id = 1,
            .kind = .assistant_text,
            .content_ref = content.reference,
        });
        _ = try owner.commitPrepared(
            .{ .session_id = 401, .epoch = 1 },
            .{ .transaction = transaction, .content = &.{directContent(content)} },
        );
    }

    {
        var owner = try StorageOwner.open(std.testing.io, path, .{});
        defer owner.close();
        const metadata = try owner.contentMetadata(401, content.reference);
        try std.testing.expectEqual(@as(u64, bytes.len), metadata.length);
        try std.testing.expectEqual(content.digest, metadata.digest);
        var window: [content_window_bytes]u8 = undefined;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const read = try owner.readContentWindow(401, content.reference, offset, &window);
            try std.testing.expectEqualSlices(u8, bytes[offset .. offset + read.len], read);
            offset += read.len;
        }

        try owner.createSession(.{
            .session_id = 411,
            .agent_id = 412,
            .task_id = 413,
        });
        var cross_session: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
        cross_session.facts[0] = session_transition.conversationAdvanced(.{
            .agent = .{ .agent_id = 412, .agent_generation = 1, .ownership_epoch = 1 },
            .entry_id = 2,
            .parent_id = 1,
            .kind = .assistant_text,
            .content_ref = content.reference,
        });
        try std.testing.expectError(
            error.MissingContentReference,
            owner.commit(.{ .session_id = 411, .epoch = 1 }, cross_session),
        );
        try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(411));
    }
}

test "content import rejects wrong length digest and conflicting identity before commit" {
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
    const identity: SessionIdentity = .{ .session_id = 501, .agent_id = 502, .task_id = 503 };
    try owner.createSession(identity);
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = 505,
    });
    const bytes = "validated content";
    try std.testing.expectError(
        error.InvalidContentLength,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{directContent(.{
                .reference = 505,
                .length = bytes.len - 1,
                .digest = binding.hash(binding.Blob, bytes),
                .source = .{ .bytes = bytes },
            })},
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(identity.session_id));

    try std.testing.expectError(
        error.ContentDigestMismatch,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{directContent(.{
                .reference = 505,
                .length = bytes.len,
                .digest = binding.hash(binding.Blob, "different content"),
                .source = .{ .bytes = bytes },
            })},
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(identity.session_id));
    try std.testing.expectError(error.ContentNotFound, owner.contentMetadata(identity.session_id, 505));

    transaction.facts[0].conversation_advanced.content_ref = identity.task_id;
    try std.testing.expectError(
        error.ConflictingContentReference,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{directContent(.{
                .reference = identity.task_id,
                .length = bytes.len,
                .digest = binding.hash(binding.Blob, bytes),
                .source = .{ .bytes = bytes },
            })},
        }),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(identity.session_id));
}

test "content maximum is representable and remains exact" {
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
    const identity: SessionIdentity = .{ .session_id = 601, .agent_id = 602, .task_id = 603 };
    try owner.createSession(identity);

    const bytes = try std.testing.allocator.alloc(u8, max_content_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = 605,
    });
    _ = try owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
        .transaction = transaction,
        .content = &.{directContent(.{
            .reference = 605,
            .length = max_content_bytes,
            .digest = binding.hash(binding.Blob, bytes[0..max_content_bytes]),
            .source = .{ .bytes = bytes[0..max_content_bytes] },
        })},
    });
    try std.testing.expectEqual(
        @as(u64, max_content_bytes),
        (try owner.contentMetadata(identity.session_id, 605)).length,
    );

    transaction.sequence = 3;
    transaction.facts[0].conversation_advanced = .{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 3,
        .parent_id = 2,
        .kind = .assistant_text,
        .content_ref = 606,
    };
    try std.testing.expectError(
        error.InvalidContentLength,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{directContent(.{
                .reference = 606,
                .length = max_content_bytes + 1,
                .digest = binding.hash(binding.Blob, bytes),
                .source = .{ .bytes = bytes },
            })},
        }),
    );
}

test "semantic commit rejects content without a first reference" {
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
    const identity: SessionIdentity = .{ .session_id = 611, .agent_id = 612, .task_id = 613 };
    try owner.createSession(identity);
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = identity.task_id,
    });
    try std.testing.expectError(
        error.UnreferencedContentImport,
        owner.commitPrepared(
            .{ .session_id = identity.session_id, .epoch = 1 },
            .{ .transaction = transaction, .content = &.{directContent(testContent(615))} },
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), try owner.sessionHead(identity.session_id));
    try std.testing.expectError(error.ContentNotFound, owner.contentMetadata(identity.session_id, 615));
}

test "three first imports succeed while existing references do not consume the cap" {
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
    const identity: SessionIdentity = .{ .session_id = 611, .agent_id = 612, .task_id = 613 };
    try owner.createSession(identity);
    const agent: session_transition.AgentContext = .{
        .agent_id = identity.agent_id,
        .agent_generation = 1,
        .ownership_epoch = 1,
    };

    var existing_references: [max_first_content_imports + 2]u64 = undefined;
    for (&existing_references, 0..) |*reference, index| {
        reference.* = 700 + index;
        var transaction: session_transition.Transaction = .{
            .sequence = 2 + index,
            .fact_count = 1,
        };
        transaction.facts[0] = session_transition.outcome(agent, index + 1, reference.*);
        _ = try owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{directContent(testContent(reference.*))},
        });
    }

    var existing: session_transition.Transaction = .{ .sequence = 7, .fact_count = 3 };
    for (0..2) |index| existing.facts[index] = session_transition.approvalRequired(.{
        .operation = .{
            .agent = agent,
            .operation_id = 800 + index,
            .generation = 1,
        },
        .binding_ref = existing_references[index * 2],
        .descriptor_ref = existing_references[index * 2 + 1],
    });
    existing.facts[2] = session_transition.outcome(agent, 10, existing_references[4]);
    _ = try owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
        .transaction = existing,
    });

    var exact: session_transition.Transaction = .{ .sequence = 8, .fact_count = 2 };
    exact.facts[0] = session_transition.approvalRequired(.{
        .operation = .{ .agent = agent, .operation_id = 900, .generation = 1 },
        .binding_ref = 900,
        .descriptor_ref = 901,
    });
    exact.facts[1] = session_transition.outcome(agent, 11, 902);
    var exact_imports: [max_first_content_imports]TransactionContentImport = undefined;
    for (&exact_imports, 0..) |*content, index| {
        content.* = directContent(testContent(900 + index));
    }
    _ = try owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
        .transaction = exact,
        .content = &exact_imports,
    });

    var excessive: session_transition.Transaction = .{ .sequence = 9, .fact_count = 2 };
    for (0..2) |index| excessive.facts[index] = session_transition.approvalRequired(.{
        .operation = .{ .agent = agent, .operation_id = 910 + index, .generation = 1 },
        .binding_ref = 910 + index * 2,
        .descriptor_ref = 911 + index * 2,
    });
    var imports: [max_first_content_imports + 1]TransactionContentImport = undefined;
    for (&imports, 0..) |*content, index| content.* = directContent(testContent(910 + index));
    try std.testing.expectError(
        error.ExcessiveContentImports,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = excessive,
            .content = &imports,
        }),
    );
}

test "patch content requires its first-referenced Intent in the same commit" {
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
    const identity: SessionIdentity = .{ .session_id = 621, .agent_id = 622, .task_id = 623 };
    try owner.createSession(identity);
    const operation: session_transition.OperationContext = .{
        .agent = .{ .agent_id = identity.agent_id, .agent_generation = 1, .ownership_epoch = 1 },
        .operation_id = 624,
        .generation = 1,
    };
    var target_path: patch_tool.TargetPath = .{ .length = 8, .bytes = @splat(0) };
    @memcpy(target_path.bytes[0..8], "file.txt");
    var intent: patch_tool.Intent = .{
        .patch_ref = 626,
        .workspace_path = "/tmp/workspace",
        .target_path = target_path,
        .patch_digest = binding.hash(binding.PatchDescriptor, "patch"),
        .intent_digest = undefined,
        .preimage_digest = binding.hash(binding.Preimage, "before"),
        .postimage_digest = binding.hash(binding.Postimage, "after"),
        .preimage_inode = 1,
        .file_mode = 0o100644,
    };
    intent.intent_digest = patch_tool.intentDigest(intent);
    var intent_buffer: [patch_tool.max_intent_size]u8 = undefined;
    const intent_bytes = try patch_tool.encodeIntent(&intent_buffer, intent);
    const intent_content: ContentImport = .{
        .reference = 625,
        .length = intent_bytes.len,
        .digest = binding.hash(binding.Blob, intent_bytes),
        .source = .{ .bytes = intent_bytes },
    };
    const descriptor: binding.Descriptor = .{ .apply_patch = intent.intent_digest };
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.operationAdmitted(
        operation,
        .{ .operation_id = 624, .generation = 1 },
        625,
        descriptor,
    );
    const patch: TransactionContentImport = .{ .patch_intent = .{
        .intent = intent_content,
        .patch = testContent(626),
    } };
    try std.testing.expectError(
        error.InvalidPatchIntent,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{.{ .patch_intent = .{
                .intent = testContent(625),
                .patch = testContent(626),
            } }},
        }),
    );

    var mismatched_intent = intent;
    mismatched_intent.patch_ref = 627;
    mismatched_intent.intent_digest = patch_tool.intentDigest(mismatched_intent);
    var mismatched_buffer: [patch_tool.max_intent_size]u8 = undefined;
    const mismatched_bytes = try patch_tool.encodeIntent(&mismatched_buffer, mismatched_intent);
    try std.testing.expectError(
        error.InvalidPatchContentReference,
        owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
            .transaction = transaction,
            .content = &.{.{ .patch_intent = .{
                .intent = .{
                    .reference = 625,
                    .length = mismatched_bytes.len,
                    .digest = binding.hash(binding.Blob, mismatched_bytes),
                    .source = .{ .bytes = mismatched_bytes },
                },
                .patch = testContent(626),
            } }},
        }),
    );
    _ = try owner.commitPrepared(.{ .session_id = identity.session_id, .epoch = 1 }, .{
        .transaction = transaction,
        .content = &.{patch},
    });
    _ = try owner.contentMetadata(identity.session_id, 625);
    _ = try owner.contentMetadata(identity.session_id, 626);
}
