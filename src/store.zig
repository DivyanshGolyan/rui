const std = @import("std");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 9;
pub const maximum_model_attempts: u64 = 4;
pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;
const runnable_probe_sql =
    "SELECT 1 FROM message_admission m INDEXED BY message_admission_pending " ++
    "WHERE m.turn_id IS NULL AND NOT EXISTS(" ++
    " SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
    " AND m.admission_id<=stopped.admission_cutoff" ++
    ") AND (NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") OR EXISTS(" ++
    " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
    " AND current.resolution_code IN ('continued','interrupted')" ++
    ")) LIMIT 1";
const continuation_risk_sql =
    "SELECT 1 FROM model_output_item WHERE session_ref=?1 UNION ALL " ++
    "SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
    "WHERE active.session_ref=?1 AND active.outcome_code IS NULL AND current.resolution_code IS NULL LIMIT 1";

pub const Faults = struct {
    content_read: bool = false,
    content_import: bool = false,
    before_commit: bool = false,
    attempt_before_commit: bool = false,
    output_read: bool = false,
    output_import: bool = false,
    output_commit: bool = false,
    rollback_failure: bool = false,
    control_trace: ?ControlTrace = null,
};

pub const ControlTracePhase = enum { lock_acquired, store_complete };

pub const ControlTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, ControlTracePhase) void,

    fn mark(self: ControlTrace, phase: ControlTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const AcceptedConfiguration = struct {
    replayed: bool,
    revision: u64 = 0,
    created: bool = false,
};

pub const ConfigurationRejection = enum {
    invalid_session_reference,
    unsupported_permission_mode,
    invalid_model,
    invalid_output_schema,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    continuation_model_incompatible,
    revision_exhausted,
};

pub const RejectedConfiguration = struct {
    replayed: bool,
    code: ConfigurationRejection,
};

pub const ConfigureReply = union(enum) {
    accepted: AcceptedConfiguration,
    rejected: RejectedConfiguration,
    conflict,
    infrastructure_failure,
};

pub const MessageRejection = enum {
    invalid_session_reference,
    unknown_session,
};

pub const AcceptedMessage = struct {
    replayed: bool,
    admission_id: u64,
    content: ContentReference,
};

pub const RejectedMessage = struct {
    replayed: bool,
    code: MessageRejection,
    content: ContentReference,
};

pub const MessageReply = union(enum) {
    accepted: AcceptedMessage,
    rejected: RejectedMessage,
    conflict,
    infrastructure_failure,
};

pub const CommandKind = enum { configure, message, session_stop, model_interruption };

const StoredAnswer = struct {
    accepted: bool,
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
};

pub const CommandObservation = struct {
    status: enum { absent, accepted, rejected },
    kind: CommandKind = .configure,
    target: protocol.Bounded(protocol.max_session_bytes) = .{},
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
    message: ?MessageObservation = null,
    session_stop: ?SessionStopObservation = null,
    model_interruption: ?ModelInterruptionTarget = null,
};

pub const SessionStopSelection = struct {
    selected_turn_id: ?u64 = null,
    admission_cutoff: u64,
};

pub const SessionStopObservation = struct {
    selection: SessionStopSelection,
    completion: enum { pending, completed },
};

pub const ModelInterruptionTarget = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    turn_id: u64,
    operation_id: u64,
};

pub const SessionStopRejection = enum { invalid_session_reference, unknown_session };

pub const SessionStopReply = union(enum) {
    accepted: struct {
        replayed: bool,
        selection: SessionStopSelection,
        interrupted_operation_id: ?u64 = null,
    },
    rejected: struct { replayed: bool, code: SessionStopRejection },
    conflict,
    infrastructure_failure,
};

pub const ModelInterruptionRejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_operation,
    target_mismatch,
    operation_resolved,
};

pub const ModelInterruptionReply = union(enum) {
    accepted: struct { replayed: bool },
    rejected: struct { replayed: bool, code: ModelInterruptionRejection },
    conflict,
    infrastructure_failure,
};

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
    private: bool = false,
};

pub const MessageObservation = struct {
    content: ContentReference,
    queue: ?AcceptedMessageQueue = null,
};

pub const AcceptedMessageQueue = struct {
    admission_id: u64,
    state: State,

    pub const State = union(enum) {
        queued,
        excluded: struct { code: protocol.Bounded(96) },
        processing: AttemptBinding,
        completed: struct {
            binding: AttemptBinding,
            answer: ContentReference,
        },
        cancelled: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(96),
        },
        failed: struct {
            binding: AttemptBinding,
            code: protocol.Bounded(96),
        },
    };
};

pub const AttemptBinding = struct {
    turn_id: u64,
    operation_id: u64,
    attempt_ordinal: u64,
};

pub const DispatchPermit = struct {
    binding: AttemptBinding,
    available: bool = true,

    pub fn consume(self: *DispatchPermit) !AttemptBinding {
        if (!self.available) return error.DispatchPermitConsumed;
        self.available = false;
        return self.binding;
    }
};

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
};

pub const RetryPolicyInput = struct {
    waits_ms: [3]u64,
    retry_after_ms: ?u64 = null,
};

pub const ModelFailureDisposition = union(enum) {
    terminal,
    retryable: RetryPolicyInput,
};

const ModelRetryDecision = union(enum) {
    schedule_after_ms: u64,
    exhausted,
};

pub const ActiveOperationFilter = struct {
    context: *const anyopaque,
    containsFn: *const fn (*const anyopaque, u64) bool,
    maximum_exclusions: usize,

    pub fn contains(self: ActiveOperationFilter, operation_id: u64) bool {
        return self.containsFn(self.context, operation_id);
    }

    pub fn empty() ActiveOperationFilter {
        return .{
            .context = &empty_active_context,
            .containsFn = containsNoActiveOperation,
            .maximum_exclusions = 0,
        };
    }
};

const empty_active_context: u8 = 0;

fn containsNoActiveOperation(_: *const anyopaque, _: u64) bool {
    return false;
}

pub const HistoricalSettings = struct {
    model: protocol.Bounded(protocol.max_model_bytes),
    baseline_instructions: ContentReference,
    output_schema: ?ContentReference,
    tools_mask: u8,
};

pub const HistoricalEntryKind = enum { user, instruction, provider_output };

pub const HistoricalEntry = struct {
    position: u64,
    kind: HistoricalEntryKind,
    content: ContentReference,
};

pub const HistoricalInput = struct {
    admission_id: u64,
    content: ContentReference,
};

pub const HistoricalInstruction = struct {
    revision: u64,
    content: ContentReference,
};

pub const HistoricalView = struct {
    store: *Store,
    binding: AttemptBinding,
    active: bool = true,

    pub fn settings(self: *HistoricalView) !HistoricalSettings {
        std.debug.assert(self.active);
        return self.store.readHistoricalSettings(self.binding);
    }

    pub fn nextInput(self: *HistoricalView, after_admission: u64) !?HistoricalInput {
        std.debug.assert(self.active);
        return self.store.readHistoricalInput(self.binding, after_admission);
    }

    pub fn nextEntry(self: *HistoricalView, after_position: u64) !?HistoricalEntry {
        std.debug.assert(self.active);
        return self.store.readHistoricalEntry(self.binding, after_position);
    }

    pub fn nextInstruction(self: *HistoricalView, after_revision: u64) !?HistoricalInstruction {
        std.debug.assert(self.active);
        return self.store.readHistoricalInstruction(self.binding, after_revision);
    }

    pub fn openContent(self: *HistoricalView, reference: ContentReference) !ContentReader {
        std.debug.assert(self.active);
        return self.store.openHistoricalContent(reference);
    }

    pub fn close(self: *HistoricalView) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

pub const OutputItemKind = enum(u8) { reasoning = 1, message = 2 };
pub const OutputRecordTag = enum(u8) { item = 1, text = 2, usage = 3 };

pub const OutputMetadataRecord = struct {
    tag: OutputRecordTag,
    kind: OutputItemKind = .reasoning,
    ordinal: u64 = 0,
    start: u64,
    length: u64,
    decoded_length: u64 = 0,
    id_digest: [32]u8 = [_]u8{0} ** 32,
    content_digest: [32]u8 = [_]u8{0} ** 32,
};

const output_metadata_record_bytes = 104;

pub const OutputMetadataWriter = struct {
    io: std.Io,
    file: std.Io.File,
    used: *std.atomic.Value(u64),
    limit: u64,
    charged: u64 = 0,
    records: u64 = 0,
    decoded_length: u64 = 0,
    fail_writes: bool = false,
    sealed: bool = false,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        name: []const u8,
        used: *std.atomic.Value(u64),
        limit: u64,
        fail_unlink: bool,
        retained: *?RetainedOutputMetadata,
    ) !OutputMetadataWriter {
        retained.* = null;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        if (fail_unlink) {
            retained.* = retainedOutputMetadata(io, file, scratch_path, name, used);
            return error.InjectedMetadataUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = retainedOutputMetadata(io, file, scratch_path, name, used);
            return err;
        };
        return .{ .io = io, .file = file, .used = used, .limit = limit };
    }

    pub fn append(self: *OutputMetadataWriter, record: OutputMetadataRecord) !void {
        std.debug.assert(!self.sealed);
        if (self.fail_writes) return error.InjectedMetadataFailure;
        if (!reserveAtomic(self.used, self.limit, output_metadata_record_bytes)) {
            return error.MetadataScratchExhausted;
        }
        // A failed write ends validation; retain the complete fixed-record
        // reservation until deinit so a partial OS write is never uncharged.
        self.charged += output_metadata_record_bytes;
        var bytes: [output_metadata_record_bytes]u8 = [_]u8{0} ** output_metadata_record_bytes;
        bytes[0] = @intFromEnum(record.tag);
        bytes[1] = @intFromEnum(record.kind);
        std.mem.writeInt(u64, bytes[8..16], record.ordinal, .little);
        std.mem.writeInt(u64, bytes[16..24], record.start, .little);
        std.mem.writeInt(u64, bytes[24..32], record.length, .little);
        std.mem.writeInt(u64, bytes[32..40], record.decoded_length, .little);
        @memcpy(bytes[40..72], &record.id_digest);
        @memcpy(bytes[72..104], &record.content_digest);
        try self.file.writeStreamingAll(self.io, &bytes);
        self.records += 1;
        if (record.tag == .text) {
            self.decoded_length = try std.math.add(u64, self.decoded_length, record.decoded_length);
        }
    }

    pub fn sealForRead(self: *OutputMetadataWriter) !void {
        if (self.sealed) return;
        try self.file.sync(self.io);
        if (try self.file.length(self.io) != self.charged) return error.MetadataSealFailed;
        self.sealed = true;
    }

    pub fn deinit(self: *OutputMetadataWriter) void {
        self.file.close(self.io);
        releaseAtomic(self.used, self.charged);
        self.* = undefined;
    }
};

pub const RetainedOutputMetadata = struct {
    io: std.Io,
    file: std.Io.File,
    scratch_path: protocol.Bounded(protocol.max_store_bytes + 64),
    name: protocol.Bounded(96),
    used: *std.atomic.Value(u64),
    charged: u64 = 0,

    pub fn cleanup(self: *RetainedOutputMetadata) !void {
        var scratch = try std.Io.Dir.cwd().openDir(self.io, self.scratch_path.slice(), .{});
        defer scratch.close(self.io);
        try scratch.deleteFile(self.io, self.name.slice());
        self.file.close(self.io);
        releaseAtomic(self.used, self.charged);
        self.* = undefined;
    }
};

fn retainedOutputMetadata(
    io: std.Io,
    file: std.Io.File,
    scratch_path: []const u8,
    name: []const u8,
    used: *std.atomic.Value(u64),
) RetainedOutputMetadata {
    var retained = RetainedOutputMetadata{
        .io = io,
        .file = file,
        .scratch_path = .{},
        .name = .{},
        .used = used,
    };
    retained.scratch_path.set(scratch_path) catch unreachable;
    retained.name.set(name) catch unreachable;
    return retained;
}

pub const OutputMetadataReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    length: u64,

    pub fn init(io: std.Io, file: std.Io.File, _: u64) !OutputMetadataReader {
        const length = try file.length(io);
        return .{ .io = io, .file = file, .length = length };
    }

    pub fn next(self: *OutputMetadataReader) !?OutputMetadataRecord {
        if (self.offset == self.length) return null;
        if (self.length - self.offset < output_metadata_record_bytes) return error.CorruptOutputMetadata;
        var bytes: [output_metadata_record_bytes]u8 = undefined;
        const count = try self.file.readPositionalAll(self.io, &bytes, self.offset);
        if (count != bytes.len) return error.CorruptOutputMetadata;
        self.offset += bytes.len;
        return .{
            .tag = switch (bytes[0]) {
                1 => .item,
                2 => .text,
                3 => .usage,
                else => return error.CorruptOutputMetadata,
            },
            .kind = switch (bytes[1]) {
                1 => .reasoning,
                2 => .message,
                else => return error.CorruptOutputMetadata,
            },
            .ordinal = std.mem.readInt(u64, bytes[8..16], .little),
            .start = std.mem.readInt(u64, bytes[16..24], .little),
            .length = std.mem.readInt(u64, bytes[24..32], .little),
            .decoded_length = std.mem.readInt(u64, bytes[32..40], .little),
            .id_digest = bytes[40..72].*,
            .content_digest = bytes[72..104].*,
        };
    }

    pub fn nextItem(self: *OutputMetadataReader) !?OutputMetadataRecord {
        while (try self.next()) |record| if (record.tag == .item) return record;
        return null;
    }
};

pub const ValidatedOutput = struct {
    source: std.Io.File,
    source_length: u64,
    metadata: std.Io.File,
    item_count: u64,
    answer_length: u64,
    answer_digest: [32]u8,
    response_id: protocol.Bounded(256),
    body_model: protocol.Bounded(protocol.max_model_bytes),
    openai_model: protocol.Bounded(protocol.max_model_bytes),
    x_openai_model: protocol.Bounded(protocol.max_model_bytes),
    request_id: protocol.Bounded(256),
};

fn reserveAtomic(used: *std.atomic.Value(u64), limit: u64, amount: u64) bool {
    if (amount > limit) return false;
    var current = used.load(.acquire);
    while (true) {
        const next = std.math.add(u64, current, amount) catch return false;
        if (next > limit) return false;
        current = used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
    }
}

fn releaseAtomic(used: *std.atomic.Value(u64), amount: u64) void {
    const prior = used.fetchSub(amount, .acq_rel);
    std.debug.assert(prior >= amount);
}

pub const SessionObservation = struct {
    found: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    revision: u64 = 0,
    tools_mask: u8 = 0,
    permission_mode: protocol.Bounded(16) = .{},
    instructions: ContentReference = .{ .length = 0, .digest = [_]u8{0} ** 32 },
    output_schema: ?ContentReference = null,
    pending_messages: u64 = 0,
};

pub const ContentReader = struct {
    store: *Store,
    reference: ContentReference,
    active: bool = true,

    pub fn read(self: *ContentReader, start: u64, destination: []u8) !usize {
        std.debug.assert(self.active);
        return self.store.readContentRange(self.reference, start, destination);
    }

    pub fn close(self: *ContentReader) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

const CurrentConfiguration = struct {
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    instructions_id: ?i64 = null,
    tools_mask: u8 = 3,
    permission_mode: u8 = 0,
    output_schema_id: ?i64 = null,
    revision: u64 = 0,
    next_position: u64 = 1,
};

const ConfigurationContentAction = enum(u2) {
    preserve,
    import_requested,
    default_empty,
    clear,
};

const ConfigurationUpdatePlan = union(enum) {
    rejected: ConfigurationRejection,
    update: struct {
        instructions: ConfigurationContentAction,
        output_schema: ConfigurationContentAction,
    },
};

fn configurationBeforeWorkspace(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
    continuation_risk: bool,
) ?ConfigurationRejection {
    if (current == null and
        (requested.workspace.state != .value or requested.model.state != .value))
    {
        return .incomplete_initial_configuration;
    }
    if (current) |existing| {
        if (requested.model.state == .value and
            !existing.model.eql(requested.model.value.slice()) and
            continuation_risk)
        {
            return .continuation_model_incompatible;
        }
    }
    return null;
}

fn planConfigurationUpdate(
    current: ?*const CurrentConfiguration,
    requested: *const protocol.Configuration,
    canonical_workspace: ?*const protocol.Bounded(protocol.max_workspace_bytes),
    next: *CurrentConfiguration,
) ConfigurationUpdatePlan {
    const created = current == null;
    if (requested.workspace.state == .value) {
        const workspace = canonical_workspace orelse unreachable;
        if (current) |existing| {
            if (!existing.workspace.eql(workspace.slice())) {
                return .{ .rejected = .workspace_is_immutable };
            }
        }
    } else {
        std.debug.assert(canonical_workspace == null);
    }
    if (current) |existing| {
        if (existing.revision == std.math.maxInt(i64)) {
            return .{ .rejected = .revision_exhausted };
        }
    }

    if (canonical_workspace) |workspace| next.workspace = workspace.*;
    if (requested.model.state == .value) next.model = requested.model.value;
    if (requested.tools.state == .value) {
        next.tools_mask = 0;
        for (requested.tools.values[0..requested.tools.count]) |tool| {
            next.tools_mask |= switch (tool) {
                .bash => 1,
                .edit => 2,
            };
        }
    }
    if (requested.permission_mode.state == .value) {
        next.permission_mode = if (requested.permission_mode.value.eql("ask")) 0 else 1;
    }
    next.revision = if (created) 1 else current.?.revision + 1;

    return .{ .update = .{
        .instructions = switch (requested.instructions.state) {
            .value => .import_requested,
            .omitted, .explicit_null => if (created) .default_empty else .preserve,
        },
        .output_schema = switch (requested.output_schema.state) {
            .value => .import_requested,
            .explicit_null => .clear,
            .omitted => if (created) .clear else .preserve,
        },
    } };
}

pub const Store = struct {
    io: std.Io,
    database: *c.sqlite3,
    selector: protocol.Bounded(protocol.max_store_bytes),
    mutex: std.Io.Mutex = .init,
    fenced: std.atomic.Value(bool) = .init(false),

    pub fn open(io: std.Io, database_path: []const u8, selector: []const u8) !Store {
        if (c.sqlite3_hard_heap_limit64(@intCast(sqlite_heap_bytes)) < 0) {
            return error.SqliteHeapLimitConfigurationFailed;
        }
        errdefer _ = c.sqlite3_hard_heap_limit64(0);

        const existing = blk: {
            const stat = std.Io.Dir.cwd().statFile(io, database_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            if (stat.kind != .file) return error.InvalidStoreDatabase;
            break :blk stat.size != 0;
        };

        var path_buffer: [protocol.max_store_bytes + 65:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{database_path});
        var database: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(
            path,
            &database,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (open_result != c.SQLITE_OK) {
            if (database) |db| _ = c.sqlite3_close(db);
            return error.StoreOpenFailed;
        }
        errdefer _ = c.sqlite3_close(database.?);

        try setLimit(database.?, c.SQLITE_LIMIT_LENGTH, @intCast(protocol.max_sqlite_content_bytes + 4096));
        try setLimit(database.?, c.SQLITE_LIMIT_SQL_LENGTH, 16 * 1024);
        try setLimit(database.?, c.SQLITE_LIMIT_COLUMN, 32);
        try setLimit(database.?, c.SQLITE_LIMIT_EXPR_DEPTH, protocol.max_json_depth);
        try setLimit(database.?, c.SQLITE_LIMIT_COMPOUND_SELECT, 4);
        try setLimit(database.?, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
        try setLimit(database.?, c.SQLITE_LIMIT_VARIABLE_NUMBER, 16);
        try setLimit(database.?, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
        try setLimit(database.?, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 4096);
        try setLimit(database.?, c.SQLITE_LIMIT_ATTACHED, 0);
        try setLimit(database.?, c.SQLITE_LIMIT_WORKER_THREADS, 0);
        try dbConfig(database.?, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
        try dbConfig(database.?, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
        if (existing) {
            try validateExisting(database.?, selector);
        }
        try exec(database.?, "PRAGMA busy_timeout=0");
        try exec(database.?, "PRAGMA foreign_keys=ON");
        try exec(database.?, "PRAGMA mmap_size=0");
        try exec(database.?, "PRAGMA temp_store=FILE");
        try exec(database.?, "PRAGMA cache_size=-4096");
        try exec(database.?, "PRAGMA synchronous=EXTRA");
        if (@import("builtin").os.tag == .macos) try exec(database.?, "PRAGMA fullfsync=ON");
        if (!existing) try bootstrap(database.?, selector);
        try exec(database.?, "PRAGMA journal_mode=DELETE");

        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        return .{ .io = io, .database = database.?, .selector = stored_selector };
    }

    pub fn close(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        const close_result = c.sqlite3_close(self.database);
        self.mutex.unlock(self.io);
        if (close_result != c.SQLITE_OK) return error.StoreCloseFailed;
        _ = c.sqlite3_hard_heap_limit64(0);
        self.* = undefined;
    }

    pub fn validateRetryWaits(self: *Store, waits_ms: [3]u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms = try readUnixMilliseconds(self.database);
        for (waits_ms) |wait_ms| {
            if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
            _ = std.math.add(i64, now_ms, @intCast(wait_ms)) catch
                return error.InvalidRetryWait;
        }
    }

    pub fn configure(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) ConfigureReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        return self.configureLocked(command, faults) catch {
            self.finishTransactionFailure(faults);
            return .infrastructure_failure;
        };
    }

    fn configureLocked(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) !ConfigureReply {
        try exec(self.database, "BEGIN IMMEDIATE");

        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .configure or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest))
            {
                return .conflict;
            }
            if (existing.accepted) return .{ .accepted = .{
                .replayed = true,
                .revision = existing.revision,
                .created = existing.created,
            } };
            return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(ConfigurationRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
        }

        if (command.session.len == 0) {
            return try self.saveConfigurationRejection(command, &digest, .invalid_session_reference, faults);
        }
        const configuration = &command.configuration;
        if (configuration.permission_mode.state == .value and
            !configuration.permission_mode.value.eql("ask") and
            !configuration.permission_mode.value.eql("bypass"))
        {
            return try self.saveConfigurationRejection(command, &digest, .unsupported_permission_mode, faults);
        }
        if (configuration.model.state == .value and configuration.model.value.len == 0) {
            return try self.saveConfigurationRejection(command, &digest, .invalid_model, faults);
        }
        if (configuration.output_schema.state == .value and
            !try validateJsonFile(self.io, configuration.output_schema.file orelse return error.MissingContentCustody))
        {
            return try self.saveConfigurationRejection(command, &digest, .invalid_output_schema, faults);
        }

        const current = try self.readSession(command.session.slice());
        const current_configuration: ?*const CurrentConfiguration = if (current) |*value| value else null;
        const continuation_risk = if (current_configuration) |existing|
            if (configuration.model.state == .value and
                !existing.model.eql(configuration.model.value.slice()))
                try self.sessionHasContinuationRisk(command.session.slice())
            else
                false
        else
            false;
        if (configurationBeforeWorkspace(current_configuration, configuration, continuation_risk)) |rejection| {
            return try self.saveConfigurationRejection(command, &digest, rejection, faults);
        }

        var canonical_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        const canonical_workspace_ref: ?*const protocol.Bounded(protocol.max_workspace_bytes) =
            if (configuration.workspace.state == .value) canonical: {
                validateWorkspace(
                    self.io,
                    configuration.workspace.value.slice(),
                    &canonical_workspace,
                ) catch {
                    return try self.saveConfigurationRejection(command, &digest, .invalid_workspace, faults);
                };
                break :canonical &canonical_workspace;
            } else null;

        const created = current_configuration == null;
        var next = if (current_configuration) |existing| existing.* else CurrentConfiguration{};
        const content_actions = switch (planConfigurationUpdate(
            current_configuration,
            configuration,
            canonical_workspace_ref,
            &next,
        )) {
            .rejected => |rejection| return try self.saveConfigurationRejection(
                command,
                &digest,
                rejection,
                faults,
            ),
            .update => |actions| actions,
        };

        var command_instructions_id: ?i64 = null;
        switch (content_actions.instructions) {
            .preserve => {},
            .import_requested => {
                command_instructions_id = try self.importContent(&configuration.instructions, faults);
                next.instructions_id = command_instructions_id;
            },
            .default_empty => next.instructions_id = try self.importEmptyContent(),
            .clear => next.instructions_id = null,
        }
        var command_output_schema_id: ?i64 = null;
        switch (content_actions.output_schema) {
            .preserve => {},
            .import_requested => {
                command_output_schema_id = try self.importContent(&configuration.output_schema, faults);
                next.output_schema_id = command_output_schema_id;
            },
            .default_empty => next.output_schema_id = try self.importEmptyContent(),
            .clear => next.output_schema_id = null,
        }

        if (created) {
            try self.insertSession(command.session.slice(), &next);
        } else {
            try self.updateSession(command.session.slice(), &next);
        }
        try self.insertRevision(
            command.session.slice(),
            command.key.slice(),
            &next,
            created or configuration.instructions.state == .value,
        );
        const answer = StoredAnswer{
            .accepted = true,
            .revision = next.revision,
            .created = created,
        };
        try self.insertCommand(
            command.key.slice(),
            .configure,
            command.session.slice(),
            &digest,
            command_instructions_id,
            command_output_schema_id,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{ .replayed = false, .revision = next.revision, .created = created } };
    }

    fn saveConfigurationRejection(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        digest: *const [32]u8,
        code: ConfigurationRejection,
        faults: Faults,
    ) !ConfigureReply {
        const instructions_id = if (command.configuration.instructions.state == .value)
            try self.importContent(&command.configuration.instructions, faults)
        else
            null;
        const output_schema_id = if (command.configuration.output_schema.state == .value)
            try self.importContent(&command.configuration.output_schema, faults)
        else
            null;
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try self.insertCommand(
            command.key.slice(),
            .configure,
            command.session.slice(),
            digest,
            instructions_id,
            output_schema_id,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    fn sessionHasContinuationRisk(self: *Store, session_ref: []const u8) !bool {
        const statement = try prepare(self.database, continuation_risk_sql);
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.ContinuationReadFailed,
        };
    }

    pub fn submitMessage(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) MessageReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        return self.submitMessageLocked(command, faults) catch {
            self.finishTransactionFailure(faults);
            return .infrastructure_failure;
        };
    }

    fn submitMessageLocked(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) !MessageReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .message or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            const content_id = existing.primary_content_id orelse return error.CorruptStore;
            const metadata = try self.readContentMetadata(content_id);
            const content = ContentReference{ .length = metadata.length, .digest = metadata.digest };
            if (existing.accepted) {
                const admission_id = try self.readMessageAdmission(
                    command.key.slice(),
                    command.session.slice(),
                    content_id,
                );
                return .{ .accepted = .{
                    .replayed = true,
                    .admission_id = admission_id,
                    .content = content,
                } };
            }
            const code = std.meta.stringToEnum(MessageRejection, existing.code.slice()) orelse
                return error.CorruptStore;
            return .{ .rejected = .{ .replayed = true, .code = code, .content = content } };
        }
        const text_id = try self.importContent(&command.text, faults);
        const metadata = try self.readContentMetadata(text_id);
        const content = ContentReference{ .length = metadata.length, .digest = metadata.digest };
        const code: ?MessageRejection = if (command.session.len == 0)
            .invalid_session_reference
        else if (try self.readSession(command.session.slice()) == null)
            .unknown_session
        else
            null;
        if (code) |rejection| {
            var answer = StoredAnswer{ .accepted = false };
            try answer.code.set(@tagName(rejection));
            try self.insertCommand(
                command.key.slice(),
                .message,
                command.session.slice(),
                &digest,
                text_id,
                null,
                answer,
            );
            if (faults.before_commit) return error.InjectedCommitFailure;
            try exec(self.database, "COMMIT");
            return .{ .rejected = .{ .replayed = false, .code = rejection, .content = content } };
        }
        try self.insertCommand(
            command.key.slice(),
            .message,
            command.session.slice(),
            &digest,
            text_id,
            null,
            .{ .accepted = true },
        );
        const admission_id = try self.insertMessageAdmission(
            command.session.slice(),
            command.key.slice(),
            text_id,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{
            .replayed = false,
            .admission_id = admission_id,
            .content = content,
        } };
    }

    pub fn stopSession(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.control_trace) |trace| trace.mark(.lock_acquired);
        const result: SessionStopReply = result: {
            if (self.fenced.load(.acquire)) break :result .infrastructure_failure;
            break :result self.stopSessionLocked(command, faults) catch {
                self.finishTransactionFailure(faults);
                break :result .infrastructure_failure;
            };
        };
        if (faults.control_trace) |trace| trace.mark(.store_complete);
        return result;
    }

    fn stopSessionLocked(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) !SessionStopReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .session_stop or
                !existing.target.eql(command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (!existing.accepted) return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(SessionStopRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
            const selection = try self.readSessionStopSelection(command.key.slice());
            return .{ .accepted = .{
                .replayed = true,
                .selection = selection,
                .interrupted_operation_id = try self.readInterruptedOperation(command.key.slice()),
            } };
        }

        if (command.session.len == 0) {
            return self.saveSessionStopRejection(command, &digest, .invalid_session_reference, faults);
        }
        if (try self.readSession(command.session.slice()) == null) {
            return self.saveSessionStopRejection(command, &digest, .unknown_session, faults);
        }

        const cutoff_statement = try prepare(
            self.database,
            "SELECT coalesce(max(admission_id),0) FROM message_admission WHERE session_ref=?1",
        );
        defer _ = c.sqlite3_finalize(cutoff_statement);
        try bindText(cutoff_statement, 1, command.session.slice());
        if (c.sqlite3_step(cutoff_statement) != c.SQLITE_ROW) return error.StopSelectionFailed;
        const cutoff_value = c.sqlite3_column_int64(cutoff_statement, 0);
        if (cutoff_value < 0) return error.CorruptStore;

        const active_statement = try prepare(
            self.database,
            "SELECT t.turn_id,t.operation_id,o.resolution_code FROM turn t " ++
                "JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE t.session_ref=?1 AND t.outcome_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(active_statement);
        try bindText(active_statement, 1, command.session.slice());
        const active_result = c.sqlite3_step(active_statement);
        var selected_turn_id: ?u64 = null;
        var current_operation_id: ?u64 = null;
        var operation_unresolved = false;
        if (active_result == c.SQLITE_ROW) {
            const turn_value = c.sqlite3_column_int64(active_statement, 0);
            const operation_value = c.sqlite3_column_int64(active_statement, 1);
            if (turn_value <= 0 or operation_value <= 0) return error.CorruptStore;
            selected_turn_id = @intCast(turn_value);
            current_operation_id = @intCast(operation_value);
            operation_unresolved = c.sqlite3_column_type(active_statement, 2) == c.SQLITE_NULL;
        } else if (active_result != c.SQLITE_DONE) return error.StopSelectionFailed;

        try self.insertCommand(
            command.key.slice(),
            .session_stop,
            command.session.slice(),
            &digest,
            null,
            null,
            .{ .accepted = true },
        );
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,admission_cutoff) VALUES(?1,?2,?3,?4)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, command.key.slice());
            try bindText(insert, 2, command.session.slice());
            try bindNullableU64(insert, 3, selected_turn_id);
            try bindI64(insert, 4, cutoff_value);
            try expectDone(insert);
        }
        var interrupted_operation_id: ?u64 = null;
        if (selected_turn_id) |turn_id| {
            if (operation_unresolved) {
                const update_operation = try prepare(
                    self.database,
                    "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='interrupted'," ++
                        "interrupted_by_command_key=?2 WHERE operation_id=?1 AND resolution_code IS NULL",
                );
                defer _ = c.sqlite3_finalize(update_operation);
                try bindU64(update_operation, 1, current_operation_id.?);
                try bindText(update_operation, 2, command.key.slice());
                try expectDone(update_operation);
                if (c.sqlite3_changes(self.database) != 1) return error.StopSelectionChanged;
                interrupted_operation_id = current_operation_id;
            }
            const update_turn = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='cancelled' WHERE turn_id=?1 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update_turn);
            try bindU64(update_turn, 1, turn_id);
            try expectDone(update_turn);
            if (c.sqlite3_changes(self.database) != 1) return error.StopSelectionChanged;
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{
            .replayed = false,
            .selection = .{
                .selected_turn_id = selected_turn_id,
                .admission_cutoff = @intCast(cutoff_value),
            },
            .interrupted_operation_id = interrupted_operation_id,
        } };
    }

    fn saveSessionStopRejection(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        digest: *const [32]u8,
        code: SessionStopRejection,
        faults: Faults,
    ) !SessionStopReply {
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try self.insertCommand(
            command.key.slice(),
            .session_stop,
            command.session.slice(),
            digest,
            null,
            null,
            answer,
        );
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    pub fn interruptModel(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (faults.control_trace) |trace| trace.mark(.lock_acquired);
        const result: ModelInterruptionReply = result: {
            if (self.fenced.load(.acquire)) break :result .infrastructure_failure;
            break :result self.interruptModelLocked(command, faults) catch {
                self.finishTransactionFailure(faults);
                break :result .infrastructure_failure;
            };
        };
        if (faults.control_trace) |trace| trace.mark(.store_complete);
        return result;
    }

    fn interruptModelLocked(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) !ModelInterruptionReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .model_interruption or
                !existing.target.eql(command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            const saved_target = try self.readModelInterruptionTarget(command.key.slice());
            if (!saved_target.session.eql(command.session.slice()) or
                saved_target.turn_id != command.turn_id or
                saved_target.operation_id != command.operation_id) return error.CorruptStore;
            if (existing.accepted) return .{ .accepted = .{ .replayed = true } };
            return .{ .rejected = .{
                .replayed = true,
                .code = std.meta.stringToEnum(ModelInterruptionRejection, existing.code.slice()) orelse
                    return error.CorruptStore,
            } };
        }

        var rejection: ?ModelInterruptionRejection = null;
        if (command.session.len == 0) {
            rejection = .invalid_session_reference;
        } else if (command.turn_id == 0 or command.operation_id == 0 or
            command.turn_id > std.math.maxInt(i64) or command.operation_id > std.math.maxInt(i64))
        {
            rejection = .invalid_target;
        } else if (try self.readSession(command.session.slice()) == null) {
            rejection = .unknown_session;
        }

        if (rejection == null) {
            const operation = try prepare(
                self.database,
                "SELECT turn_id,session_ref,resolution_code FROM model_operation WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(operation);
            try bindU64(operation, 1, command.operation_id);
            const result = c.sqlite3_step(operation);
            if (result == c.SQLITE_DONE) {
                rejection = .unknown_operation;
            } else if (result != c.SQLITE_ROW) {
                return error.InterruptionTargetReadFailed;
            } else {
                const turn_value = c.sqlite3_column_int64(operation, 0);
                var session: protocol.Bounded(protocol.max_session_bytes) = .{};
                try readText(operation, 1, &session);
                if (turn_value <= 0 or @as(u64, @intCast(turn_value)) != command.turn_id or
                    !session.eql(command.session.slice()))
                {
                    rejection = .target_mismatch;
                } else if (c.sqlite3_column_type(operation, 2) != c.SQLITE_NULL) {
                    rejection = .operation_resolved;
                }
            }
        }

        if (rejection) |code| {
            return self.saveModelInterruptionAnswer(command, &digest, false, @tagName(code), faults);
        }

        const current_turn = try prepare(
            self.database,
            "SELECT 1 FROM turn WHERE turn_id=?1 AND session_ref=?2 AND operation_id=?3 AND outcome_code IS NULL",
        );
        defer _ = c.sqlite3_finalize(current_turn);
        try bindU64(current_turn, 1, command.turn_id);
        try bindText(current_turn, 2, command.session.slice());
        try bindU64(current_turn, 3, command.operation_id);
        const current_result = c.sqlite3_step(current_turn);
        if (current_result == c.SQLITE_DONE) {
            return self.saveModelInterruptionAnswer(
                command,
                &digest,
                false,
                @tagName(ModelInterruptionRejection.target_mismatch),
                faults,
            );
        }
        if (current_result != c.SQLITE_ROW) return error.InterruptionTargetReadFailed;

        try self.insertModelInterruptionCommand(command, &digest, .{ .accepted = true });
        {
            const update = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='interrupted'," ++
                    "interrupted_by_command_key=?2 WHERE operation_id=?1 AND resolution_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, command.operation_id);
            try bindText(update, 2, command.key.slice());
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.InterruptionTargetChanged;
        }
        if (!try self.hasApplicablePendingMessage(command.session.slice())) {
            const settle_turn = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='cancelled' WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(settle_turn);
            try bindU64(settle_turn, 1, command.turn_id);
            try bindU64(settle_turn, 2, command.operation_id);
            try expectDone(settle_turn);
            if (c.sqlite3_changes(self.database) != 1) return error.InterruptionTargetChanged;
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .accepted = .{ .replayed = false } };
    }

    fn saveModelInterruptionAnswer(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        digest: *const [32]u8,
        accepted: bool,
        code: []const u8,
        faults: Faults,
    ) !ModelInterruptionReply {
        var answer = StoredAnswer{ .accepted = accepted };
        try answer.code.set(code);
        try self.insertModelInterruptionCommand(command, digest, answer);
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
        if (accepted) return .{ .accepted = .{ .replayed = false } };
        return .{ .rejected = .{
            .replayed = false,
            .code = std.meta.stringToEnum(ModelInterruptionRejection, code) orelse unreachable,
        } };
    }

    fn insertModelInterruptionCommand(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        digest: *const [32]u8,
        answer: StoredAnswer,
    ) !void {
        try self.insertCommand(
            command.key.slice(),
            .model_interruption,
            command.session.slice(),
            digest,
            null,
            null,
            answer,
        );
        var turn_buffer: [20]u8 = undefined;
        const turn = try std.fmt.bufPrint(&turn_buffer, "{d}", .{command.turn_id});
        var operation_buffer: [20]u8 = undefined;
        const operation = try std.fmt.bufPrint(&operation_buffer, "{d}", .{command.operation_id});
        const insert = try prepare(
            self.database,
            "INSERT INTO model_interruption_command(command_key,session_ref,turn_id,operation_id) VALUES(?1,?2,?3,?4)",
        );
        defer _ = c.sqlite3_finalize(insert);
        try bindText(insert, 1, command.key.slice());
        try bindText(insert, 2, command.session.slice());
        try bindText(insert, 3, turn);
        try bindText(insert, 4, operation);
        try expectDone(insert);
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const existing = self.readExistingCommand(key) catch |err| return self.fenceReadFailure(err);
        const command = existing orelse return .{ .status = .absent };
        var observation = CommandObservation{
            .status = if (command.accepted) .accepted else .rejected,
            .kind = command.kind,
            .revision = command.revision,
            .created = command.created,
        };
        observation.target = command.target;
        observation.code = command.code;
        if (command.kind == .message) {
            const content_id = command.primary_content_id orelse
                return self.fenceReadFailure(error.CorruptStore);
            const metadata = self.readContentMetadata(content_id) catch |err|
                return self.fenceReadFailure(err);
            observation.message = .{
                .content = .{ .length = metadata.length, .digest = metadata.digest },
                .queue = self.readMessageQueue(
                    key,
                    command.target.slice(),
                    content_id,
                    command.accepted,
                ) catch |err| return self.fenceReadFailure(err),
            };
        } else if (command.kind == .session_stop and command.accepted) {
            const selection = self.readSessionStopSelection(key) catch |err|
                return self.fenceReadFailure(err);
            observation.session_stop = .{
                .selection = selection,
                .completion = if (selection.selected_turn_id) |turn_id|
                    if (self.turnIsComplete(turn_id) catch |err| return self.fenceReadFailure(err))
                        .completed
                    else
                        .pending
                else
                    .completed,
            };
        } else if (command.kind == .model_interruption) {
            observation.model_interruption = self.readModelInterruptionTarget(key) catch |err|
                return self.fenceReadFailure(err);
        }
        return observation;
    }

    fn readMessageQueue(
        self: *Store,
        command_key: []const u8,
        session_ref: []const u8,
        content_id: i64,
        accepted: bool,
    ) !?AcceptedMessageQueue {
        const statement = try prepare(
            self.database,
            "SELECT m.session_ref,m.content_id,m.admission_id,m.turn_id,t.operation_id,t.outcome_code,o.attempt_ordinal,t.outcome_content_id," ++
                "EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff) " ++
                "FROM message_admission m " ++
                "LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
                "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE m.command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return if (accepted) error.CorruptStore else null;
        if (step != c.SQLITE_ROW) return error.CorruptStore;
        if (!accepted) return error.CorruptStore;
        var actual_session: protocol.Bounded(protocol.max_session_bytes) = .{};
        readText(statement, 0, &actual_session) catch return error.CorruptStore;
        if (!actual_session.eql(session_ref)) return error.CorruptStore;
        const actual_content_id = c.sqlite3_column_int64(statement, 1);
        if (actual_content_id <= 0 or actual_content_id != content_id) return error.CorruptStore;
        const admission_id = c.sqlite3_column_int64(statement, 2);
        if (admission_id <= 0) return error.CorruptStore;
        const turn_id = try readNullablePositiveI64(statement, 3);
        if (turn_id == null) {
            if (c.sqlite3_column_int(statement, 8) != 0) {
                var code: protocol.Bounded(96) = .{};
                try code.set("session_stopped");
                return .{ .admission_id = @intCast(admission_id), .state = .{ .excluded = .{ .code = code } } };
            }
            return .{ .admission_id = @intCast(admission_id), .state = .queued };
        }
        const binding = AttemptBinding{
            .turn_id = @intCast(turn_id.?),
            .operation_id = @intCast(try readNullablePositiveI64(statement, 4) orelse
                return error.CorruptStore),
            .attempt_ordinal = @intCast(try readNullablePositiveI64(statement, 6) orelse
                return error.CorruptStore),
        };
        if (c.sqlite3_column_type(statement, 5) == c.SQLITE_NULL) {
            if (c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL) return error.CorruptStore;
            return .{ .admission_id = @intCast(admission_id), .state = .{ .processing = binding } };
        }
        var outcome: protocol.Bounded(96) = .{};
        try readText(statement, 5, &outcome);
        if (outcome.eql("completed")) {
            const answer_id = try readNullablePositiveI64(statement, 7) orelse return error.CorruptStore;
            const answer = try self.readContentMetadata(answer_id);
            return .{
                .admission_id = @intCast(admission_id),
                .state = .{ .completed = .{
                    .binding = binding,
                    .answer = .{ .length = answer.length, .digest = answer.digest },
                } },
            };
        }
        if (outcome.eql("cancelled")) {
            if (c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL) return error.CorruptStore;
            return .{
                .admission_id = @intCast(admission_id),
                .state = .{ .cancelled = .{ .binding = binding, .code = outcome } },
            };
        }
        if (outcome.len == 0 or c.sqlite3_column_type(statement, 7) != c.SQLITE_NULL)
            return error.CorruptStore;
        return .{
            .admission_id = @intCast(admission_id),
            .state = .{ .failed = .{ .binding = binding, .code = outcome } },
        };
    }

    pub fn commandResult(self: *Store, key: []const u8) !ContentReference {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = try prepare(
            self.database,
            "SELECT t.outcome_code,t.outcome_content_id,EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff) FROM core_command command " ++
                "JOIN message_admission m ON m.command_key=command.command_key " ++
                "LEFT JOIN turn t ON t.turn_id=m.turn_id WHERE command.command_key=?1 AND command.kind=2 AND command.accepted=1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ResultNotFound;
        if (c.sqlite3_column_int(statement, 2) != 0 and c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) {
            return error.ResultFailed;
        }
        if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return error.ResultNotReady;
        var outcome: protocol.Bounded(96) = .{};
        try readText(statement, 0, &outcome);
        if (!outcome.eql("completed")) return error.ResultFailed;
        const content_id = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        const metadata = try self.readContentMetadata(content_id);
        return .{ .length = metadata.length, .digest = metadata.digest };
    }

    pub fn inspectSession(self: *Store, session_ref: []const u8) !SessionObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const maybe_current = self.readSession(session_ref) catch |err| return self.fenceReadFailure(err);
        const current = maybe_current orelse return .{};
        var observation = SessionObservation{
            .found = true,
            .revision = current.revision,
            .tools_mask = current.tools_mask,
        };
        try observation.session.set(session_ref);
        observation.workspace = current.workspace;
        observation.model = current.model;
        try observation.permission_mode.set(if (current.permission_mode == 0) "ask" else "bypass");
        if (current.instructions_id) |content_id| {
            const metadata = self.readContentMetadata(content_id) catch |err| return self.fenceReadFailure(err);
            observation.instructions = .{ .length = metadata.length, .digest = metadata.digest };
        }
        if (current.output_schema_id) |content_id| {
            const metadata = self.readContentMetadata(content_id) catch |err| return self.fenceReadFailure(err);
            observation.output_schema = .{ .length = metadata.length, .digest = metadata.digest };
        }
        observation.pending_messages = self.countPendingMessages(session_ref) catch |err|
            return self.fenceReadFailure(err);
        return observation;
    }

    pub fn admitNextModelAttempt(self: *Store, faults: Faults) !?AttemptAdmission {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.admitNextModelAttemptLocked(faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.InjectedAttemptCommitFailure,
            );
        };
    }

    fn admitNextModelAttemptLocked(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!try self.hasRunnableWorkLocked()) return null;
        try exec(self.database, "BEGIN IMMEDIATE");

        const select = try prepare(
            self.database,
            "SELECT m.session_ref,min(m.admission_id),max(m.admission_id),count(*),s.revision,s.next_position," ++
                "(SELECT active.turn_id FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
                "WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
                "AND current.resolution_code IN ('continued','interrupted')) " ++
                "FROM message_admission m JOIN session s ON s.session_ref=m.session_ref " ++
                "WHERE m.turn_id IS NULL AND NOT EXISTS(" ++
                " SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                " AND m.admission_id<=stopped.admission_cutoff" ++
                ") AND (NOT EXISTS(" ++
                " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
                ") OR EXISTS(" ++
                " SELECT 1 FROM turn active JOIN model_operation current ON current.operation_id=active.operation_id " ++
                " WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL " ++
                " AND current.resolution_code IN ('continued','interrupted')" ++
                ")) GROUP BY m.session_ref ORDER BY min(m.admission_id) LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(select);
        const step_result = c.sqlite3_step(select);
        if (step_result == c.SQLITE_DONE) {
            try exec(self.database, "ROLLBACK");
            return null;
        }
        if (step_result != c.SQLITE_ROW) return error.RunnableSelectionFailed;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(select, 0, &session_ref);
        const first_admission = c.sqlite3_column_int64(select, 1);
        const cutoff = c.sqlite3_column_int64(select, 2);
        const selected = c.sqlite3_column_int64(select, 3);
        const revision = c.sqlite3_column_int64(select, 4);
        const initial_position = c.sqlite3_column_int64(select, 5);
        const existing_turn = try readNullablePositiveI64(select, 6);
        if (first_admission <= 0 or cutoff < first_admission or selected <= 0 or revision <= 0 or initial_position <= 0) {
            return error.CorruptStore;
        }

        const turn_id = if (existing_turn) |value| @as(u64, @intCast(value)) else try nextIdentity(self.database, "turn", "turn_id");
        const operation_id = try nextIdentity(self.database, "model_operation", "operation_id");
        if (existing_turn == null) {
            const insert = try prepare(
                self.database,
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id) " ++
                    "VALUES(?1,?2,?3,?4,?5,NULL,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, turn_id);
            try bindText(insert, 2, session_ref.slice());
            try bindI64(insert, 3, first_admission);
            try bindI64(insert, 4, cutoff);
            try bindU64(insert, 5, operation_id);
            try expectDone(insert);
        } else {
            const update = try prepare(
                self.database,
                "UPDATE turn SET input_cutoff=?2,operation_id=?3 WHERE turn_id=?1 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, turn_id);
            try bindI64(update, 2, cutoff);
            try bindU64(update, 3, operation_id);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        {
            const bind = try prepare(
                self.database,
                "UPDATE message_admission SET turn_id=?1 WHERE session_ref=?2 AND turn_id IS NULL AND admission_id<=?3 " ++
                    "AND NOT EXISTS(SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=message_admission.session_ref " ++
                    "AND message_admission.admission_id<=stopped.admission_cutoff)",
            );
            defer _ = c.sqlite3_finalize(bind);
            try bindU64(bind, 1, turn_id);
            try bindText(bind, 2, session_ref.slice());
            try bindI64(bind, 3, cutoff);
            try expectDone(bind);
            if (c.sqlite3_changes(self.database) != selected) return error.SelectionChanged;
        }
        {
            const project = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                    "row_number() OVER (ORDER BY admission_id),?3 + row_number() OVER (ORDER BY admission_id) - 1,1,?2,admission_id,NULL,NULL,content_id " ++
                    "FROM message_admission WHERE turn_id=?2 AND admission_id>=?4 ORDER BY admission_id",
            );
            defer _ = c.sqlite3_finalize(project);
            try bindText(project, 1, session_ref.slice());
            try bindU64(project, 2, turn_id);
            try bindI64(project, 3, initial_position);
            try bindI64(project, 4, first_admission);
            try expectDone(project);
            if (c.sqlite3_changes(self.database) != selected) return error.ProjectionFailed;
        }
        var next_position: u64 = try std.math.add(u64, @intCast(initial_position), @intCast(selected));
        const instruction_count = blk: {
            const count = try prepare(
                self.database,
                "SELECT count(*) FROM session_revision r WHERE r.session_ref=?1 AND r.revision>1 AND " ++
                    "r.revision<=?2 AND r.instructions_updated=1 AND NOT EXISTS(" ++
                    "SELECT 1 FROM conversation_entry e WHERE e.session_ref=r.session_ref AND e.source_revision=r.revision)",
            );
            defer _ = c.sqlite3_finalize(count);
            try bindText(count, 1, session_ref.slice());
            try bindI64(count, 2, revision);
            if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.InstructionSelectionFailed;
            const value = c.sqlite3_column_int64(count, 0);
            if (value < 0) return error.CorruptStore;
            break :blk value;
        };
        if (instruction_count != 0) {
            const project = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                    "row_number() OVER (ORDER BY revision),?3 + row_number() OVER (ORDER BY revision) - 1,2,?2,NULL,revision,NULL,instructions_content_id " ++
                    "FROM session_revision r WHERE r.session_ref=?1 AND r.revision>1 AND r.revision<=?4 AND r.instructions_updated=1 AND NOT EXISTS(" ++
                    "SELECT 1 FROM conversation_entry e WHERE e.session_ref=r.session_ref AND e.source_revision=r.revision) ORDER BY revision",
            );
            defer _ = c.sqlite3_finalize(project);
            try bindText(project, 1, session_ref.slice());
            try bindU64(project, 2, turn_id);
            try bindU64(project, 3, next_position);
            try bindI64(project, 4, revision);
            try expectDone(project);
            if (c.sqlite3_changes(self.database) != instruction_count) return error.InstructionSelectionFailed;
            next_position = try std.math.add(u64, next_position, @intCast(instruction_count));
        }
        {
            const update = try prepare(self.database, "UPDATE session SET next_position=?2 WHERE session_ref=?1 AND next_position=?3");
            defer _ = c.sqlite3_finalize(update);
            try bindText(update, 1, session_ref.slice());
            try bindU64(update, 2, next_position);
            try bindI64(update, 3, initial_position);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                    "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,body_model,openai_model,x_openai_model,request_id,usage_content_id) " ++
                    "VALUES(?1,?2,?3,?4,?5,?6,1,1,1,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, operation_id);
            try bindU64(insert, 2, turn_id);
            try bindText(insert, 3, session_ref.slice());
            try bindI64(insert, 4, revision);
            try bindI64(insert, 5, cutoff);
            try bindU64(insert, 6, next_position);
            try expectDone(insert);
        }
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        const binding = AttemptBinding{
            .turn_id = turn_id,
            .operation_id = operation_id,
            .attempt_ordinal = 1,
        };
        return .{ .permit = .{ .binding = binding } };
    }

    pub fn tryAdmitNextModelRetry(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.tryAdmitNextModelRetryLocked(active, faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.InjectedAttemptCommitFailure,
            );
        };
    }

    fn tryAdmitNextModelRetryLocked(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        try exec(self.database, "BEGIN IMMEDIATE");
        const snapshot_ms = try readUnixMilliseconds(self.database);
        const selection_limit = try std.math.add(
            usize,
            active.maximum_exclusions,
            1,
        );
        if (selection_limit > std.math.maxInt(i64)) return error.RetrySelectionLimitExceeded;
        const select = try prepare(
            self.database,
            "SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms FROM model_operation " ++
                "INDEXED BY model_operation_retry_age WHERE resolution_code IS NULL AND allowance_used<4 " ++
                "AND retry_due_at_ms<=?1 ORDER BY operation_id LIMIT ?2",
        );
        var select_open = true;
        defer {
            if (select_open) _ = c.sqlite3_finalize(select);
        }
        try bindI64(select, 1, snapshot_ms);
        try bindI64(select, 2, @as(i64, @intCast(selection_limit)));
        var selected: ?AttemptBinding = null;
        while (true) {
            const result = c.sqlite3_step(select);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.RetrySelectionFailed;
            const turn_id = c.sqlite3_column_int64(select, 0);
            const operation_id = c.sqlite3_column_int64(select, 1);
            const attempt_ordinal = c.sqlite3_column_int64(select, 2);
            const allowance_used = c.sqlite3_column_int64(select, 3);
            const due_at_ms = c.sqlite3_column_int64(select, 4);
            if (turn_id <= 0 or operation_id <= 0 or attempt_ordinal <= 0 or
                allowance_used != attempt_ordinal or allowance_used >= maximum_model_attempts or
                due_at_ms < 0 or due_at_ms > snapshot_ms)
            {
                return error.CorruptStore;
            }
            if (active.contains(@intCast(operation_id))) continue;
            selected = .{
                .turn_id = @intCast(turn_id),
                .operation_id = @intCast(operation_id),
                .attempt_ordinal = @intCast(attempt_ordinal),
            };
            break;
        }
        if (c.sqlite3_finalize(select) != c.SQLITE_OK) return error.RetrySelectionFailed;
        select_open = false;

        // Eligibility exists only inside this Store transition. No selected
        // candidate or time snapshot survives rollback, capacity loss or exit.
        const current = selected orelse {
            try exec(self.database, "ROLLBACK");
            return null;
        };
        if (current.attempt_ordinal >= maximum_model_attempts) return error.CorruptStore;
        const replacement_ordinal = current.attempt_ordinal + 1;
        const update = try prepare(
            self.database,
            "UPDATE model_operation SET attempt_ordinal=?2,allowance_used=?2,uncertain=1,retry_due_at_ms=0 " ++
                "WHERE operation_id=?1 AND turn_id=?3 AND resolution_code IS NULL " ++
                "AND attempt_ordinal=?4 AND allowance_used=?4 AND allowance_used<4 AND retry_due_at_ms<=?5",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindU64(update, 1, current.operation_id);
        try bindU64(update, 2, replacement_ordinal);
        try bindU64(update, 3, current.turn_id);
        try bindU64(update, 4, current.attempt_ordinal);
        try bindI64(update, 5, snapshot_ms);
        try expectDone(update);
        if (c.sqlite3_changes(self.database) != 1) {
            try exec(self.database, "ROLLBACK");
            return null;
        }
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        return .{ .permit = .{ .binding = .{
            .turn_id = current.turn_id,
            .operation_id = current.operation_id,
            .attempt_ordinal = replacement_ordinal,
        } } };
    }

    fn hasRunnableWorkLocked(self: *Store) !bool {
        const statement = try prepare(self.database, runnable_probe_sql);
        defer _ = c.sqlite3_finalize(statement);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.RunnableSelectionFailed,
        };
    }

    pub fn openHistoricalView(self: *Store, binding: AttemptBinding) !HistoricalView {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        try self.validateCurrentAttempt(binding);
        return .{ .store = self, .binding = binding };
    }

    fn validateCurrentAttempt(self: *Store, binding: AttemptBinding) !void {
        const statement = try prepare(
            self.database,
            "SELECT turn_id,attempt_ordinal,resolution_code,interrupted_by_command_key " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return error.StaleAttemptBinding;
        if (c.sqlite3_column_type(statement, 2) == c.SQLITE_NULL) return;
        if (c.sqlite3_column_type(statement, 3) != c.SQLITE_NULL) return error.SupersededByControl;
        return error.StaleAttemptBinding;
    }

    fn readHistoricalSettings(self: *Store, binding: AttemptBinding) !HistoricalSettings {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalSettingsLocked(binding) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalSettingsLocked(self: *Store, binding: AttemptBinding) !HistoricalSettings {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(
            self.database,
            "SELECT r.model,baseline.instructions_content_id,r.output_schema_content_id,r.tools_mask " ++
                "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref " ++
                "AND r.revision=o.settings_revision JOIN session_revision baseline ON " ++
                "baseline.session_ref=o.session_ref AND baseline.revision=1 WHERE o.operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var model: protocol.Bounded(protocol.max_model_bytes) = .{};
        try readText(statement, 0, &model);
        const instructions_id = try readNullablePositiveI64(statement, 1) orelse return error.CorruptStore;
        const output_schema_id = try readNullablePositiveI64(statement, 2);
        const tools = c.sqlite3_column_int(statement, 3);
        if (tools < 0 or tools > 3) return error.CorruptStore;
        const instructions = try self.readContentMetadata(instructions_id);
        const output_schema = if (output_schema_id) |content_id| blk: {
            const metadata = try self.readContentMetadata(content_id);
            break :blk ContentReference{ .length = metadata.length, .digest = metadata.digest };
        } else null;
        return .{
            .model = model,
            .baseline_instructions = .{ .length = instructions.length, .digest = instructions.digest },
            .output_schema = output_schema,
            .tools_mask = @intCast(tools),
        };
    }

    fn readHistoricalInstruction(
        self: *Store,
        binding: AttemptBinding,
        after_revision: u64,
    ) !?HistoricalInstruction {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalInstructionLocked(binding, after_revision) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalInstructionLocked(
        self: *Store,
        binding: AttemptBinding,
        after_revision: u64,
    ) !?HistoricalInstruction {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(
            self.database,
            "SELECT r.revision,r.instructions_content_id FROM model_operation o " ++
                "JOIN session_revision r ON r.session_ref=o.session_ref " ++
                "WHERE o.operation_id=?1 AND r.revision>?2 AND r.revision<=o.settings_revision " ++
                "AND r.instructions_updated=1 ORDER BY r.revision LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        try bindU64(statement, 2, after_revision);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.HistoricalInstructionReadFailed;
        const revision = c.sqlite3_column_int64(statement, 0);
        const content_id = c.sqlite3_column_int64(statement, 1);
        if (revision <= 0 or content_id <= 0) return error.CorruptStore;
        const metadata = try self.readContentMetadata(content_id);
        return .{
            .revision = @intCast(revision),
            .content = .{ .length = metadata.length, .digest = metadata.digest },
        };
    }

    fn readHistoricalInput(
        self: *Store,
        binding: AttemptBinding,
        after_admission: u64,
    ) !?HistoricalInput {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalInputLocked(binding, after_admission) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalEntry(self: *Store, binding: AttemptBinding, after_position: u64) !?HistoricalEntry {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalEntryLocked(binding, after_position) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalEntryLocked(self: *Store, binding: AttemptBinding, after_position: u64) !?HistoricalEntry {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(
            self.database,
            "SELECT position,kind,content_id FROM (" ++
                "SELECT e.session_position AS position,e.entry_kind AS kind,e.content_id AS content_id " ++
                "FROM model_operation current JOIN conversation_entry e ON e.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND e.session_position>?2 AND e.session_position<current.admission_position " ++
                "AND e.entry_kind IN (1,2) UNION ALL " ++
                "SELECT item.session_position AS position,3 AS kind,item.content_id AS content_id " ++
                "FROM model_operation current JOIN model_output_item item ON item.session_ref=current.session_ref " ++
                "WHERE current.operation_id=?1 AND item.session_position>?2 AND item.session_position<current.admission_position" ++
                ") ORDER BY position LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        try bindU64(statement, 2, after_position);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.HistoricalEntryReadFailed;
        const position = c.sqlite3_column_int64(statement, 0);
        const kind_value = c.sqlite3_column_int(statement, 1);
        const content_id = c.sqlite3_column_int64(statement, 2);
        if (position <= 0 or content_id <= 0) return error.CorruptStore;
        const kind: HistoricalEntryKind = switch (kind_value) {
            1 => .user,
            2 => .instruction,
            3 => .provider_output,
            else => return error.CorruptStore,
        };
        const metadata = try self.readContentMetadata(content_id);
        return .{
            .position = @intCast(position),
            .kind = kind,
            .content = .{
                .length = metadata.length,
                .digest = metadata.digest,
                .private = kind == .provider_output,
            },
        };
    }

    fn readHistoricalInputLocked(
        self: *Store,
        binding: AttemptBinding,
        after_admission: u64,
    ) !?HistoricalInput {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(
            self.database,
            "SELECT m.admission_id,m.content_id FROM model_operation o " ++
                "JOIN message_admission m ON m.turn_id=o.turn_id " ++
                "WHERE o.operation_id=?1 AND m.admission_id>?2 AND m.admission_id<=o.input_cutoff " ++
                "ORDER BY m.admission_id LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        try bindU64(statement, 2, after_admission);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.HistoricalInputReadFailed;
        const admission_id = c.sqlite3_column_int64(statement, 0);
        const content_id = c.sqlite3_column_int64(statement, 1);
        if (admission_id <= 0 or content_id <= 0) return error.CorruptStore;
        const metadata = try self.readContentMetadata(content_id);
        return .{
            .admission_id = @intCast(admission_id),
            .content = .{ .length = metadata.length, .digest = metadata.digest },
        };
    }

    pub fn isFenced(self: *const Store) bool {
        return self.fenced.load(.acquire);
    }

    pub fn operationSupersededByControl(self: *Store, binding: AttemptBinding) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const statement = prepare(
            self.database,
            "SELECT turn_id,attempt_ordinal,interrupted_by_command_key FROM model_operation WHERE operation_id=?1",
        ) catch |err| return self.fenceReadFailure(err);
        defer _ = c.sqlite3_finalize(statement);
        bindU64(statement, 1, binding.operation_id) catch |err| return self.fenceReadFailure(err);
        const step = c.sqlite3_step(statement);
        if (step == c.SQLITE_DONE) return false;
        if (step != c.SQLITE_ROW) return self.fenceReadFailure(error.OperationReadFailed);
        if (c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal)
            return false;
        return c.sqlite3_column_type(statement, 2) != c.SQLITE_NULL;
    }

    pub fn withDispatchHandoff(
        self: *Store,
        binding: AttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.validateCurrentAttempt(binding) catch |err| switch (err) {
            error.StaleAttemptBinding, error.SupersededByControl => return err,
            else => return self.fenceReadFailure(err),
        };
        try handoff(context);
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        disposition: ModelFailureDisposition,
        faults: Faults,
    ) !void {
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.settleModelAttemptFailureLocked(binding, code, disposition, faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.StaleAttemptBinding or err == error.SupersededByControl,
            );
        };
    }

    fn settleModelAttemptFailureLocked(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        disposition: ModelFailureDisposition,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        try self.validateCurrentAttempt(binding);
        switch (disposition) {
            .terminal => {
                const update = try prepare(
                    self.database,
                    "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2 " ++
                        "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                );
                defer _ = c.sqlite3_finalize(update);
                try bindU64(update, 1, binding.operation_id);
                try bindText(update, 2, code);
                try bindU64(update, 3, binding.attempt_ordinal);
                try expectDone(update);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;

                const settle_turn = try prepare(
                    self.database,
                    "UPDATE turn SET outcome_code=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
                );
                defer _ = c.sqlite3_finalize(settle_turn);
                try bindU64(settle_turn, 1, binding.turn_id);
                try bindText(settle_turn, 2, code);
                try bindU64(settle_turn, 3, binding.operation_id);
                try expectDone(settle_turn);
                if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
            },
            .retryable => |policy| switch (try decideModelRetry(binding.attempt_ordinal, policy)) {
                .schedule_after_ms => |delay_ms| {
                    const now_ms = try readUnixMilliseconds(self.database);
                    const due_at_ms = try std.math.add(i64, now_ms, @intCast(delay_ms));
                    const update = try prepare(
                        self.database,
                        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=?2,last_failure_code=?3 " ++
                            "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?4",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, binding.operation_id);
                    try bindI64(update, 2, due_at_ms);
                    try bindText(update, 3, code);
                    try bindU64(update, 4, binding.attempt_ordinal);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                },
                .exhausted => {
                    const update = try prepare(
                        self.database,
                        "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,last_failure_code=?2,resolution_code='retry_exhausted' " ++
                            "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
                    );
                    defer _ = c.sqlite3_finalize(update);
                    try bindU64(update, 1, binding.operation_id);
                    try bindText(update, 2, code);
                    try bindU64(update, 3, binding.attempt_ordinal);
                    try expectDone(update);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;

                    const settle_turn = try prepare(
                        self.database,
                        "UPDATE turn SET outcome_code='retry_exhausted' " ++
                            "WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
                    );
                    defer _ = c.sqlite3_finalize(settle_turn);
                    try bindU64(settle_turn, 1, binding.turn_id);
                    try bindU64(settle_turn, 2, binding.operation_id);
                    try expectDone(settle_turn);
                    if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
                },
            },
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
    }

    pub fn recoverOneExhaustedModelAttempt(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        return self.recoverOneExhaustedModelAttemptLocked(active) catch |err| {
            return self.finishTransactionError(err, .{}, false);
        };
    }

    fn recoverOneExhaustedModelAttemptLocked(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        const scan_limit = try std.math.add(
            usize,
            active.maximum_exclusions,
            1,
        );
        if (scan_limit > std.math.maxInt(i64)) return error.RetrySelectionLimitExceeded;
        const select = try prepare(
            self.database,
            "SELECT turn_id,operation_id FROM model_operation INDEXED BY model_operation_retry_exhausted " ++
                "WHERE resolution_code IS NULL AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0 " ++
                "ORDER BY operation_id LIMIT ?1",
        );
        var select_open = true;
        defer {
            if (select_open) _ = c.sqlite3_finalize(select);
        }
        try bindI64(select, 1, @as(i64, @intCast(scan_limit)));
        var selected: ?AttemptBinding = null;
        while (true) {
            const result = c.sqlite3_step(select);
            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) return error.RetryRecoveryFailed;
            const turn_id = c.sqlite3_column_int64(select, 0);
            const operation_id = c.sqlite3_column_int64(select, 1);
            if (turn_id <= 0 or operation_id <= 0) return error.CorruptStore;
            if (active.contains(@intCast(operation_id))) continue;
            selected = .{
                .turn_id = @intCast(turn_id),
                .operation_id = @intCast(operation_id),
                .attempt_ordinal = maximum_model_attempts,
            };
            break;
        }
        if (c.sqlite3_finalize(select) != c.SQLITE_OK) return error.RetryRecoveryFailed;
        select_open = false;
        const binding = selected orelse return false;

        try exec(self.database, "BEGIN IMMEDIATE");
        {
            const update_operation = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code='retry_exhausted' " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND uncertain=1 AND allowance_used=?2",
            );
            defer _ = c.sqlite3_finalize(update_operation);
            try bindI64(update_operation, 1, binding.operation_id);
            try bindU64(update_operation, 2, maximum_model_attempts);
            try expectDone(update_operation);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        {
            const update_turn = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='retry_exhausted' " ++
                    "WHERE turn_id=?1 AND operation_id=?2 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update_turn);
            try bindI64(update_turn, 1, binding.turn_id);
            try bindI64(update_turn, 2, binding.operation_id);
            try expectDone(update_turn);
            if (c.sqlite3_changes(self.database) != 1) return error.SelectionChanged;
        }
        try exec(self.database, "COMMIT");
        return true;
    }

    pub fn settleModelSuccess(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.settleModelSuccessLocked(binding, output, faults) catch |err| {
            return self.finishTransactionError(
                err,
                faults,
                err == error.StaleAttemptBinding or err == error.SupersededByControl,
            );
        };
    }

    fn settleModelSuccessLocked(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        try self.validateCurrentAttempt(binding);
        const operation = try prepare(
            self.database,
            "SELECT session_ref FROM model_operation WHERE operation_id=?1 AND turn_id=?2",
        );
        defer _ = c.sqlite3_finalize(operation);
        try bindU64(operation, 1, binding.operation_id);
        try bindU64(operation, 2, binding.turn_id);
        if (c.sqlite3_step(operation) != c.SQLITE_ROW) return error.StaleAttemptBinding;
        var session_ref: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(operation, 0, &session_ref);
        var current = try self.readSession(session_ref.slice()) orelse return error.CorruptStore;

        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        var imported_items: u64 = 0;
        var usage_id: ?i64 = null;
        while (try metadata.next()) |record| {
            if (record.tag == .text) continue;
            if (record.tag == .usage) {
                if (usage_id != null) return error.CorruptOutputMetadata;
                usage_id = try self.importSourceRange(
                    output.source,
                    output.source_length,
                    record.start,
                    record.length,
                    &record.content_digest,
                    true,
                    faults,
                );
                continue;
            }
            if (record.ordinal != imported_items) return error.CorruptOutputMetadata;
            const content_id = try self.importSourceRange(
                output.source,
                output.source_length,
                record.start,
                record.length,
                &record.content_digest,
                true,
                faults,
            );
            const insert = try prepare(
                self.database,
                "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,content_id,attempt_ordinal) " ++
                    "VALUES(?1,?2,?3,?4,?5,?6,?7)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, binding.operation_id);
            try bindU64(insert, 2, record.ordinal);
            try bindText(insert, 3, session_ref.slice());
            try bindU64(insert, 4, current.next_position);
            try bindI64(insert, 5, @intFromEnum(record.kind));
            try bindI64(insert, 6, content_id);
            try bindU64(insert, 7, binding.attempt_ordinal);
            try expectDone(insert);
            current.next_position = try std.math.add(u64, current.next_position, 1);
            imported_items += 1;
        }
        if (imported_items != output.item_count) return error.CorruptOutputMetadata;

        const answer_id = try self.importDecodedAnswer(output, faults);
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,content_id) " ++
                    "VALUES(?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0)+1,?2,3,?3,NULL,NULL,?4,?5)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindText(insert, 1, session_ref.slice());
            try bindU64(insert, 2, current.next_position);
            try bindU64(insert, 3, binding.turn_id);
            try bindU64(insert, 4, binding.operation_id);
            try bindI64(insert, 5, answer_id);
            try expectDone(insert);
            current.next_position = try std.math.add(u64, current.next_position, 1);
        }
        const pending = try self.countPendingMessages(session_ref.slice());
        const resolution_code = if (pending == 0) "completed" else "continued";
        {
            const update = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,retry_due_at_ms=NULL,resolution_code=?2,resolution_content_id=?3,response_id=?4,body_model=?5,openai_model=?6,x_openai_model=?7,request_id=?8,usage_content_id=?9 " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?10",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, binding.operation_id);
            try bindText(update, 2, resolution_code);
            try bindI64(update, 3, answer_id);
            try bindOptionalText(update, 4, output.response_id.slice());
            try bindOptionalText(update, 5, output.body_model.slice());
            try bindOptionalText(update, 6, output.openai_model.slice());
            try bindOptionalText(update, 7, output.x_openai_model.slice());
            try bindOptionalText(update, 8, output.request_id.slice());
            try bindNullableI64(update, 9, usage_id);
            try bindU64(update, 10, binding.attempt_ordinal);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        if (pending == 0) {
            const update = try prepare(
                self.database,
                "UPDATE turn SET outcome_code='completed',outcome_content_id=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(update);
            try bindU64(update, 1, binding.turn_id);
            try bindI64(update, 2, answer_id);
            try bindU64(update, 3, binding.operation_id);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        {
            const update = try prepare(self.database, "UPDATE session SET next_position=?2 WHERE session_ref=?1");
            defer _ = c.sqlite3_finalize(update);
            try bindText(update, 1, session_ref.slice());
            try bindU64(update, 2, current.next_position);
            try expectDone(update);
            if (c.sqlite3_changes(self.database) != 1) return error.SessionUpdateFailed;
        }
        if (faults.output_commit) return error.InjectedOutputCommitFailure;
        try exec(self.database, "COMMIT");
    }

    const ContentSlot = struct { id: i64, existing: bool };

    fn contentSlot(self: *Store, digest: *const [32]u8, length: u64, private: bool) !ContentSlot {
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, digest);
        try bindU64(find, 2, length);
        try bindI64(find, 3, @as(i64, if (private) 1 else 0));
        const result = c.sqlite3_step(find);
        if (result == c.SQLITE_ROW) {
            const id = c.sqlite3_column_int64(find, 0);
            if (id <= 0) return error.CorruptStore;
            return .{ .id = id, .existing = true };
        }
        if (result != c.SQLITE_DONE) return error.ContentReadFailed;
        const insert = try prepare(
            self.database,
            "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,zeroblob(?2),?3)",
        );
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, digest);
        try bindU64(insert, 2, length);
        try bindI64(insert, 3, @as(i64, if (private) 1 else 0));
        try expectDone(insert);
        const id = c.sqlite3_last_insert_rowid(self.database);
        if (id <= 0) return error.ContentWriteFailed;
        return .{ .id = id, .existing = false };
    }

    fn importSourceRange(
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
        const slot = try self.contentSlot(digest, length, private);
        var blob: ?*c.sqlite3_blob = null;
        if (!slot.existing and length != 0) {
            if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
        }
        defer if (blob) |value| {
            _ = c.sqlite3_blob_close(value);
        };
        var hash = protocol.contentHasher();
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < length) {
            const wanted: usize = @intCast(@min(length - offset, buffer.len));
            const count = try file.readPositionalAll(self.io, buffer[0..wanted], start + offset);
            if (count != wanted or faults.output_read) return error.OutputSourceReadFailed;
            hash.update(buffer[0..count]);
            if (blob) |value| {
                if (c.sqlite3_blob_write(value, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                    return error.ContentWriteFailed;
                }
            }
            if (faults.output_import) return error.InjectedOutputImportFailure;
            offset += count;
        }
        if (!std.mem.eql(u8, &hash.finalResult(), digest)) return error.OutputSourceChanged;
        return slot.id;
    }

    fn importDecodedAnswer(self: *Store, output: *const ValidatedOutput, faults: Faults) !i64 {
        const slot = try self.contentSlot(&output.answer_digest, output.answer_length, false);
        var blob: ?*c.sqlite3_blob = null;
        if (!slot.existing and output.answer_length != 0) {
            if (c.sqlite3_blob_open(self.database, "main", "content", "payload", slot.id, 1, &blob) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
        }
        defer if (blob) |value| {
            _ = c.sqlite3_blob_close(value);
        };
        var hash = protocol.contentHasher();
        var destination_offset: u64 = 0;
        var metadata = try OutputMetadataReader.init(self.io, output.metadata, output.item_count);
        while (try metadata.next()) |record| {
            if (record.tag != .text) continue;
            try decodeTextRange(
                self.io,
                output.source,
                output.source_length,
                record,
                blob,
                &destination_offset,
                &hash,
                faults,
            );
        }
        if (destination_offset != output.answer_length or
            !std.mem.eql(u8, &hash.finalResult(), &output.answer_digest)) return error.OutputSourceChanged;
        return slot.id;
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentReader {
        if (reference.private) return error.PrivateContent;
        return self.openHistoricalContent(reference);
    }

    fn openHistoricalContent(self: *Store, reference: ContentReference) !ContentReader {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        _ = self.resolveContentReference(reference) catch |err| return self.fenceReadFailure(err);
        return .{ .store = self, .reference = reference };
    }

    fn readContentRange(
        self: *Store,
        reference: ContentReference,
        start: u64,
        destination: []u8,
    ) !usize {
        if (destination.len > protocol.content_window_bytes) return error.WindowTooLarge;
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        const content_id = self.resolveContentReference(reference) catch |err| return self.fenceReadFailure(err);
        if (start > reference.length) return error.RangeOutOfBounds;
        const wanted: u64 = @min(destination.len, reference.length - start);
        if (wanted == 0) return 0;
        if (start > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob) != c.SQLITE_OK) {
            return self.fenceReadFailure(error.ContentReadFailed);
        }
        defer _ = c.sqlite3_blob_close(blob);
        if (c.sqlite3_blob_read(blob, destination.ptr, @intCast(wanted), @intCast(start)) != c.SQLITE_OK) {
            return self.fenceReadFailure(error.ContentReadFailed);
        }
        return @intCast(wanted);
    }

    fn fenceReadFailure(self: *Store, err: anyerror) anyerror {
        self.fenced.store(true, .release);
        return err;
    }

    fn finishTransactionError(
        self: *Store,
        err: anyerror,
        faults: Faults,
        preserve_expected: bool,
    ) anyerror {
        self.rollbackAfterError(faults) catch |rollback_err| {
            self.fenced.store(true, .release);
            return rollback_err;
        };
        if (!preserve_expected) self.fenced.store(true, .release);
        return err;
    }

    fn finishTransactionFailure(self: *Store, faults: Faults) void {
        self.rollbackAfterError(faults) catch {};
        self.fenced.store(true, .release);
    }

    fn rollbackAfterError(self: *Store, faults: Faults) !void {
        if (c.sqlite3_get_autocommit(self.database) != 0) return;
        if (faults.rollback_failure) return error.CanonicalRollbackFailed;
        if (c.sqlite3_exec(self.database, "ROLLBACK", null, null, null) != c.SQLITE_OK or
            c.sqlite3_get_autocommit(self.database) == 0)
        {
            return error.CanonicalRollbackFailed;
        }
    }

    const ExistingCommand = struct {
        kind: CommandKind,
        target: protocol.Bounded(protocol.max_session_bytes),
        digest: [32]u8,
        accepted: bool,
        code: protocol.Bounded(96),
        revision: u64,
        created: bool,
        primary_content_id: ?i64,
    };

    fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
        const statement = try prepare(self.database, "SELECT kind,target,input_digest,accepted,code,revision,created,primary_content_id FROM core_command WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return null;
        if (step_result != c.SQLITE_ROW) return error.CommandReadFailed;
        const kind_value = c.sqlite3_column_int(statement, 0);
        const kind: CommandKind = switch (kind_value) {
            1 => .configure,
            2 => .message,
            3 => .session_stop,
            4 => .model_interruption,
            else => return error.CorruptStore,
        };
        var target: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 1, &target);
        const digest = try readDigest(statement, 2);
        const accepted_value = c.sqlite3_column_int(statement, 3);
        if (accepted_value != 0 and accepted_value != 1) return error.CorruptStore;
        var code: protocol.Bounded(96) = .{};
        try readText(statement, 4, &code);
        const revision_value = c.sqlite3_column_int64(statement, 5);
        if (revision_value < 0) return error.CorruptStore;
        const created_value = c.sqlite3_column_int(statement, 6);
        if (created_value != 0 and created_value != 1) return error.CorruptStore;
        const primary_content_id = readNullablePositiveI64(statement, 7) catch return error.CorruptStore;
        return .{
            .kind = kind,
            .target = target,
            .digest = digest,
            .accepted = accepted_value == 1,
            .code = code,
            .revision = @intCast(revision_value),
            .created = created_value == 1,
            .primary_content_id = primary_content_id,
        };
    }

    fn readMessageAdmission(
        self: *Store,
        command_key: []const u8,
        session_ref: []const u8,
        content_id: i64,
    ) !u64 {
        const statement = try prepare(self.database, "SELECT admission_id,session_ref,content_id FROM message_admission WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const admission_id = c.sqlite3_column_int64(statement, 0);
        var stored_session: protocol.Bounded(protocol.max_session_bytes) = .{};
        try readText(statement, 1, &stored_session);
        if (admission_id <= 0 or
            !stored_session.eql(session_ref) or
            c.sqlite3_column_int64(statement, 2) != content_id)
        {
            return error.CorruptStore;
        }
        return @intCast(admission_id);
    }

    fn countPendingMessages(self: *Store, session_ref: []const u8) !u64 {
        const statement = try prepare(
            self.database,
            "SELECT count(*) FROM message_admission m WHERE session_ref=?1 AND turn_id IS NULL AND NOT EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff)",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.MessageAdmissionReadFailed;
        const count = c.sqlite3_column_int64(statement, 0);
        if (count < 0) return error.CorruptStore;
        return @intCast(count);
    }

    fn hasApplicablePendingMessage(self: *Store, session_ref: []const u8) !bool {
        const statement = try prepare(
            self.database,
            "SELECT 1 FROM message_admission m WHERE m.session_ref=?1 AND m.turn_id IS NULL AND NOT EXISTS(" ++
                "SELECT 1 FROM session_stop stopped WHERE stopped.session_ref=m.session_ref " ++
                "AND m.admission_id<=stopped.admission_cutoff) LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.MessageAdmissionReadFailed,
        };
    }

    fn readSessionStopSelection(self: *Store, command_key: []const u8) !SessionStopSelection {
        const statement = try prepare(
            self.database,
            "SELECT selected_turn_id,admission_cutoff FROM session_stop WHERE command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const cutoff = c.sqlite3_column_int64(statement, 1);
        if (cutoff < 0) return error.CorruptStore;
        return .{
            .selected_turn_id = if (try readNullablePositiveI64(statement, 0)) |value| @intCast(value) else null,
            .admission_cutoff = @intCast(cutoff),
        };
    }

    fn readInterruptedOperation(self: *Store, command_key: []const u8) !?u64 {
        const statement = try prepare(
            self.database,
            "SELECT operation_id FROM model_operation WHERE interrupted_by_command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        const result = c.sqlite3_step(statement);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.CorruptStore;
        const operation_id = c.sqlite3_column_int64(statement, 0);
        if (operation_id <= 0 or c.sqlite3_step(statement) != c.SQLITE_DONE) return error.CorruptStore;
        return @intCast(operation_id);
    }

    fn readModelInterruptionTarget(self: *Store, command_key: []const u8) !ModelInterruptionTarget {
        const statement = try prepare(
            self.database,
            "SELECT session_ref,turn_id,operation_id FROM model_interruption_command WHERE command_key=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        var target = ModelInterruptionTarget{
            .session = .{},
            .turn_id = 0,
            .operation_id = 0,
        };
        try readText(statement, 0, &target.session);
        var turn_text: protocol.Bounded(20) = .{};
        try readText(statement, 1, &turn_text);
        var operation_text: protocol.Bounded(20) = .{};
        try readText(statement, 2, &operation_text);
        target.turn_id = std.fmt.parseInt(u64, turn_text.slice(), 10) catch return error.CorruptStore;
        target.operation_id = std.fmt.parseInt(u64, operation_text.slice(), 10) catch return error.CorruptStore;
        return target;
    }

    fn turnIsComplete(self: *Store, turn_id: u64) !bool {
        const statement = try prepare(self.database, "SELECT outcome_code FROM turn WHERE turn_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, turn_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        return c.sqlite3_column_type(statement, 0) != c.SQLITE_NULL;
    }

    fn readSession(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
        const statement = try prepare(self.database, "SELECT workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position FROM session WHERE session_ref=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        const step_result = c.sqlite3_step(statement);
        if (step_result == c.SQLITE_DONE) return null;
        if (step_result != c.SQLITE_ROW) return error.SessionReadFailed;
        var current: CurrentConfiguration = .{};
        try readText(statement, 0, &current.workspace);
        try readText(statement, 1, &current.model);
        current.instructions_id = (readNullablePositiveI64(statement, 2) catch return error.CorruptStore) orelse
            return error.CorruptStore;
        const tools = c.sqlite3_column_int(statement, 3);
        if (tools < 0 or tools > 3) return error.CorruptStore;
        current.tools_mask = @intCast(tools);
        const permission = c.sqlite3_column_int(statement, 4);
        if (permission < 0 or permission > 1) return error.CorruptStore;
        current.permission_mode = @intCast(permission);
        current.output_schema_id = readNullablePositiveI64(statement, 5) catch return error.CorruptStore;
        const revision = c.sqlite3_column_int64(statement, 6);
        if (revision <= 0) return error.CorruptStore;
        current.revision = @intCast(revision);
        const next_position = c.sqlite3_column_int64(statement, 7);
        if (next_position <= 0) return error.CorruptStore;
        current.next_position = @intCast(next_position);
        return current;
    }

    fn insertSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision,next_position) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
    }

    fn updateSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "UPDATE session SET workspace=?2,model=?3,instructions_content_id=?4,tools_mask=?5,permission_mode=?6,output_schema_content_id=?7,revision=?8,next_position=?9 WHERE session_ref=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.SessionUpdateFailed;
    }

    fn insertRevision(
        self: *Store,
        session_ref: []const u8,
        command_key: []const u8,
        current: *const CurrentConfiguration,
        instructions_updated: bool,
    ) !void {
        const statement = try prepare(self.database, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,instructions_updated,tools_mask,permission_mode,output_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, current.revision);
        try bindText(statement, 3, command_key);
        try bindText(statement, 4, current.workspace.slice());
        try bindText(statement, 5, current.model.slice());
        try bindNullableI64(statement, 6, current.instructions_id);
        try bindI64(statement, 7, @as(i64, if (instructions_updated) 1 else 0));
        try bindI64(statement, 8, current.tools_mask);
        try bindI64(statement, 9, current.permission_mode);
        try bindNullableI64(statement, 10, current.output_schema_id);
        try expectDone(statement);
    }

    fn insertCommand(
        self: *Store,
        key: []const u8,
        kind: CommandKind,
        target: []const u8,
        digest: *const [32]u8,
        primary_content_id: ?i64,
        secondary_content_id: ?i64,
        answer: StoredAnswer,
    ) !void {
        const statement = try prepare(self.database, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        const kind_value: i64 = switch (kind) {
            .configure => 1,
            .message => 2,
            .session_stop => 3,
            .model_interruption => 4,
        };
        try bindI64(statement, 2, kind_value);
        try bindText(statement, 3, target);
        try bindBlob(statement, 4, digest);
        try bindNullableI64(statement, 5, primary_content_id);
        try bindNullableI64(statement, 6, secondary_content_id);
        const accepted_value: i64 = if (answer.accepted) 1 else 0;
        try bindI64(statement, 7, accepted_value);
        try bindText(statement, 8, answer.code.slice());
        try bindU64(statement, 9, answer.revision);
        const created_value: i64 = if (answer.created) 1 else 0;
        try bindI64(statement, 10, created_value);
        try expectDone(statement);
    }

    fn insertMessageAdmission(
        self: *Store,
        session_ref: []const u8,
        command_key: []const u8,
        content_id: i64,
    ) !u64 {
        const latest = try prepare(self.database, "SELECT admission_id FROM message_admission ORDER BY admission_id DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(latest);
        const latest_result = c.sqlite3_step(latest);
        const admission_id: u64 = if (latest_result == c.SQLITE_DONE)
            1
        else if (latest_result == c.SQLITE_ROW) blk: {
            const prior = c.sqlite3_column_int64(latest, 0);
            if (prior <= 0 or prior == std.math.maxInt(i64)) {
                return error.MessageAdmissionIdentityExhausted;
            }
            break :blk @intCast(prior + 1);
        } else return error.MessageAdmissionReadFailed;
        const statement = try prepare(self.database, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id) VALUES(?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, admission_id);
        try bindText(statement, 2, session_ref);
        try bindText(statement, 3, command_key);
        try bindI64(statement, 4, content_id);
        try expectDone(statement);
        return admission_id;
    }

    fn importEmptyContent(self: *Store) !i64 {
        var empty: protocol.ContentField = .{ .state = .value };
        empty.digest = protocol.contentDigest("");
        return self.importContent(&empty, .{});
    }

    fn importContent(self: *Store, content: *const protocol.ContentField, faults: Faults) !i64 {
        std.debug.assert(content.state == .value);
        if (content.file) |source| {
            try verifyExternalContent(self.io, source, content.length, &content.digest, faults);
        } else if (content.length != 0 or
            !std.mem.eql(u8, &protocol.contentDigest(""), &content.digest))
        {
            return error.MissingContentCustody;
        }
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=0");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &content.digest);
        try bindU64(find, 2, content.length);
        const find_result = c.sqlite3_step(find);
        if (find_result == c.SQLITE_ROW) {
            const content_id = c.sqlite3_column_int64(find, 0);
            if (content_id <= 0) return error.CorruptStore;
            return content_id;
        }
        if (find_result != c.SQLITE_DONE) return error.ContentReadFailed;

        const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload,private) VALUES(?1,?2,zeroblob(?2),0)");
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, &content.digest);
        try bindU64(insert, 2, content.length);
        try expectDone(insert);
        const content_id = c.sqlite3_last_insert_rowid(self.database);
        if (content_id <= 0) return error.ContentWriteFailed;

        if (content.length == 0) {
            return content_id;
        }
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        const file = content.file orelse return error.MissingContentCustody;
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < content.length) {
            const wanted: usize = @intCast(@min(content.length - offset, buffer.len));
            const count = try file.readPositionalAll(self.io, buffer[0..wanted], offset);
            if (count != wanted) return error.ContentReadFailed;
            if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
            if (c.sqlite3_blob_write(blob, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
            if (faults.content_import) return error.InjectedContentImportFailure;
            offset += count;
        }
        return content_id;
    }

    const ContentMetadata = struct { length: u64, digest: [32]u8 };

    fn readContentMetadata(self: *Store, content_id: i64) !ContentMetadata {
        const statement = try prepare(self.database, "SELECT byte_length,digest FROM content WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const length = c.sqlite3_column_int64(statement, 0);
        if (length < 0) return error.CorruptStore;
        return .{ .length = @intCast(length), .digest = try readDigest(statement, 1) };
    }

    fn resolveContentReference(self: *Store, reference: ContentReference) !i64 {
        const statement = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2 AND private=?3");
        defer _ = c.sqlite3_finalize(statement);
        try bindBlob(statement, 1, &reference.digest);
        try bindU64(statement, 2, reference.length);
        try bindI64(statement, 3, @as(i64, if (reference.private) 1 else 0));
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const content_id = c.sqlite3_column_int64(statement, 0);
        if (content_id <= 0) return error.CorruptStore;
        return content_id;
    }
};

fn validateWorkspace(io: std.Io, supplied: []const u8, destination: anytype) !void {
    if (!std.fs.path.isAbsolute(supplied)) return error.WorkspaceMustBeAbsolute;
    if (std.mem.indexOfScalar(u8, supplied, 0) != null) return error.InvalidWorkspace;
    var directory = try std.Io.Dir.cwd().openDir(io, supplied, .{});
    defer directory.close(io);
    var canonical: [protocol.max_workspace_bytes]u8 = undefined;
    const length = try directory.realPath(io, &canonical);
    try destination.set(canonical[0..length]);
}

fn verifyExternalContent(
    io: std.Io,
    file: std.Io.File,
    expected_length: u64,
    expected_digest: *const [32]u8,
    faults: Faults,
) !void {
    if (try file.length(io) != expected_length) return error.ContentChanged;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    var hash = protocol.contentHasher();
    while (offset < expected_length) {
        const wanted: usize = @intCast(@min(expected_length - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count != wanted) return error.ContentReadFailed;
        if (faults.content_read) return error.InjectedContentReadFailure;
        hash.update(buffer[0..count]);
        offset += count;
    }
    if (!std.mem.eql(u8, &hash.finalResult(), expected_digest)) return error.ContentChanged;
}

const OutputByteSource = struct {
    io: std.Io,
    file: std.Io.File,
    position: u64,
    end: u64,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [protocol.content_window_bytes]u8 = undefined,

    fn take(self: *OutputByteSource) !u8 {
        if (self.position == self.end) return error.IncompleteJsonString;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.end - self.position, self.buffer.len));
            const count = try self.file.readPositionalAll(self.io, self.buffer[0..wanted], self.position);
            if (count != wanted) return error.OutputSourceReadFailed;
            self.buffer_length = count;
        }
        const byte = self.buffer[@intCast(self.position - self.buffer_start)];
        self.position += 1;
        return byte;
    }
};

const DecodedSink = struct {
    blob: ?*c.sqlite3_blob,
    offset: *u64,
    hash: *std.crypto.hash.sha2.Sha256,
    buffer: [protocol.content_window_bytes]u8 = undefined,
    used: usize = 0,
    fail_import: bool,

    fn emit(self: *DecodedSink, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            const count = @min(remaining.len, self.buffer.len - self.used);
            @memcpy(self.buffer[self.used .. self.used + count], remaining[0..count]);
            self.used += count;
            remaining = remaining[count..];
            if (self.used == self.buffer.len) try self.flush();
        }
    }

    fn flush(self: *DecodedSink) !void {
        if (self.used == 0) return;
        self.hash.update(self.buffer[0..self.used]);
        if (self.blob) |blob| {
            if (self.offset.* > std.math.maxInt(c_int) or
                c.sqlite3_blob_write(blob, self.buffer[0..self.used].ptr, @intCast(self.used), @intCast(self.offset.*)) != c.SQLITE_OK)
            {
                return error.ContentWriteFailed;
            }
        }
        if (self.fail_import) return error.InjectedOutputImportFailure;
        self.offset.* = try std.math.add(u64, self.offset.*, self.used);
        self.used = 0;
    }
};

fn decodeTextRange(
    io: std.Io,
    file: std.Io.File,
    source_length: u64,
    record: OutputMetadataRecord,
    blob: ?*c.sqlite3_blob,
    destination_offset: *u64,
    hash: *std.crypto.hash.sha2.Sha256,
    faults: Faults,
) !void {
    const end = try std.math.add(u64, record.start, record.length);
    if (end > source_length) return error.CorruptOutputMetadata;
    var source = OutputByteSource{ .io = io, .file = file, .position = record.start, .end = end };
    var sink = DecodedSink{
        .blob = blob,
        .offset = destination_offset,
        .hash = hash,
        .fail_import = faults.output_import,
    };
    const initial_offset = destination_offset.*;
    while (source.position < source.end) {
        const byte = try source.take();
        if (faults.output_read) return error.OutputSourceReadFailed;
        if (byte != '\\') {
            try sink.emit(&.{byte});
            continue;
        }
        const escape = try source.take();
        switch (escape) {
            '"', '\\', '/' => try sink.emit(&.{escape}),
            'b' => try sink.emit(&.{8}),
            'f' => try sink.emit(&.{12}),
            'n' => try sink.emit("\n"),
            'r' => try sink.emit("\r"),
            't' => try sink.emit("\t"),
            'u' => {
                var scalar = try readOutputHex(&source);
                if (scalar >= 0xd800 and scalar <= 0xdbff) {
                    if (try source.take() != '\\' or try source.take() != 'u') return error.InvalidJsonSurrogate;
                    const low = try readOutputHex(&source);
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidJsonSurrogate;
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
                } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidJsonSurrogate;
                var encoded: [4]u8 = undefined;
                const count = try std.unicode.utf8Encode(scalar, &encoded);
                try sink.emit(encoded[0..count]);
            },
            else => return error.InvalidJsonEscape,
        }
    }
    try sink.flush();
    if (destination_offset.* - initial_offset != record.decoded_length) return error.CorruptOutputMetadata;
}

fn readOutputHex(source: *OutputByteSource) !u21 {
    var value: u21 = 0;
    for (0..4) |_| {
        const byte = try source.take();
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidJsonEscape,
        };
        value = value * 16 + digit;
    }
    return value;
}

fn validateJsonFile(io: std.Io, file: std.Io.File) !bool {
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

fn bootstrap(database: *c.sqlite3, selector: []const u8) !void {
    try exec(database, "BEGIN EXCLUSIVE");
    errdefer rollback(database);
    try exec(database,
        \\CREATE TABLE store_meta(
        \\ key TEXT PRIMARY KEY,
        \\ value TEXT NOT NULL
        \\) STRICT;
        \\CREATE TABLE content(
        \\ content_id INTEGER PRIMARY KEY,
        \\ digest BLOB NOT NULL CHECK(length(digest)=32),
        \\ byte_length INTEGER NOT NULL CHECK(byte_length>=0 AND byte_length<=1073737728),
        \\ payload BLOB NOT NULL CHECK(length(payload)=byte_length),
        \\ private INTEGER NOT NULL CHECK(private IN (0,1)),
        \\ UNIQUE(digest,byte_length,private)
        \\) STRICT;
        \\CREATE TABLE session(
        \\ session_ref TEXT PRIMARY KEY CHECK(length(CAST(session_ref AS BLOB)) BETWEEN 1 AND 128),
        \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
        \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND 3),
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ next_position INTEGER NOT NULL CHECK(next_position>0)
        \\) STRICT;
        \\CREATE TABLE core_command(
        \\ command_key TEXT PRIMARY KEY CHECK(length(CAST(command_key AS BLOB))<=128),
        \\ kind INTEGER NOT NULL CHECK(kind IN (1,2,3,4)),
        \\ target TEXT NOT NULL CHECK(length(CAST(target AS BLOB))<=128),
        \\ input_digest BLOB NOT NULL CHECK(length(input_digest)=32),
        \\ primary_content_id INTEGER REFERENCES content(content_id),
        \\ secondary_content_id INTEGER REFERENCES content(content_id),
        \\ accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
        \\ code TEXT NOT NULL CHECK(length(CAST(code AS BLOB))<=96),
        \\ revision INTEGER NOT NULL CHECK(revision>=0),
        \\ created INTEGER NOT NULL CHECK(created IN (0,1))
        \\) STRICT;
        \\CREATE TABLE session_revision(
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ workspace TEXT NOT NULL,
        \\ model TEXT NOT NULL,
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
        \\ tools_mask INTEGER NOT NULL,
        \\ permission_mode INTEGER NOT NULL,
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,revision)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE message_admission(
        \\ admission_id INTEGER PRIMARY KEY CHECK(admission_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ turn_id INTEGER REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED
        \\) STRICT;
        \\CREATE TABLE turn(
        \\ turn_id INTEGER PRIMARY KEY CHECK(turn_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ first_admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id) DEFERRABLE INITIALLY DEFERRED,
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>=first_admission_id),
        \\ operation_id INTEGER NOT NULL,
        \\ outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96),
        \\ outcome_content_id INTEGER REFERENCES content(content_id)
        \\) STRICT;
        \\CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
        \\CREATE TABLE session_stop(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ selected_turn_id INTEGER REFERENCES turn(turn_id),
        \\ admission_cutoff INTEGER NOT NULL CHECK(admission_cutoff>=0)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_interruption_command(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL CHECK(length(CAST(session_ref AS BLOB))<=128),
        \\ turn_id TEXT NOT NULL CHECK(length(turn_id) BETWEEN 1 AND 20),
        \\ operation_id TEXT NOT NULL CHECK(length(operation_id) BETWEEN 1 AND 20)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_operation(
        \\ operation_id INTEGER PRIMARY KEY CHECK(operation_id>0),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ session_ref TEXT NOT NULL,
        \\ settings_revision INTEGER NOT NULL CHECK(settings_revision>0),
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),
        \\ admission_position INTEGER NOT NULL CHECK(admission_position>0),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ allowance_used INTEGER NOT NULL CHECK(allowance_used BETWEEN 1 AND 4),
        \\ uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
        \\ retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
        \\ last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),
        \\ body_model TEXT CHECK(body_model IS NULL OR length(CAST(body_model AS BLOB))<=256),
        \\ openai_model TEXT CHECK(openai_model IS NULL OR length(CAST(openai_model AS BLOB))<=256),
        \\ x_openai_model TEXT CHECK(x_openai_model IS NULL OR length(CAST(x_openai_model AS BLOB))<=256),
        \\ request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),
        \\ usage_content_id INTEGER REFERENCES content(content_id),
        \\ interrupted_by_command_key TEXT REFERENCES core_command(command_key),
        \\ FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK((resolution_code IS NULL AND ((uncertain=1 AND retry_due_at_ms=0) OR (uncertain=0 AND retry_due_at_ms>0))) OR
        \\       (resolution_code IS NOT NULL AND uncertain=0 AND retry_due_at_ms IS NULL)),
        \\ CHECK((resolution_code='interrupted' AND interrupted_by_command_key IS NOT NULL) OR
        \\       (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL))
        \\) STRICT;
        \\CREATE TABLE conversation_entry(
        \\ session_ref TEXT NOT NULL,
        \\ entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ entry_kind INTEGER NOT NULL CHECK(entry_kind IN (1,2,3)),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
        \\ source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),
        \\ source_revision INTEGER,
        \\ source_operation_id INTEGER REFERENCES model_operation(operation_id),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,entry_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_output_item(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ session_ref TEXT NOT NULL,
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ item_kind INTEGER NOT NULL CHECK(item_kind IN (1,2)),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ PRIMARY KEY(operation_id,item_ordinal),
        \\ UNIQUE(session_ref,session_position)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
        \\CREATE INDEX message_admission_pending ON message_admission(admission_id,session_ref) WHERE turn_id IS NULL;
        \\CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff);
        \\CREATE INDEX model_operation_retry_age ON model_operation(operation_id) WHERE resolution_code IS NULL AND allowance_used<4;
        \\CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0;
        \\CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
        \\CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
    );
    try exec(database, "PRAGMA application_id=1280591409");
    try exec(database, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version}));
    const statement = try prepare(database, "INSERT INTO store_meta(key,value) VALUES('wire_version','1'),('store_selector',?1)");
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, selector);
    try expectDone(statement);
    try exec(database, "COMMIT");
}

fn validateExisting(database: *c.sqlite3, selector: []const u8) !void {
    if (try pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    if (try pragmaInt(database, "PRAGMA user_version") != schema_version) return error.WrongStoreVersion;
    {
        const statement = try prepare(
            database,
            "SELECT count(*) FROM sqlite_schema WHERE " ++
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item')) OR " ++
                "(type='index' AND ((sql IS NULL AND tbl_name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item')) OR " ++
                "(sql IS NOT NULL AND name NOT IN ('message_admission_session_order','message_admission_pending','session_stop_exclusion','turn_one_active_per_session','model_operation_retry_age','model_operation_retry_exhausted','conversation_entry_history','model_output_history')))) OR " ++
                "type NOT IN ('table','index')",
        );
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_int64(statement, 0) != 0) {
            return error.WrongStoreSchema;
        }
    }
    {
        const statement = try prepare(database, "SELECT value FROM store_meta WHERE key='wire_version'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreVersion;
        var version: protocol.Bounded(16) = .{};
        try readText(statement, 0, &version);
        if (!version.eql(protocol.wire_version)) return error.WrongStoreVersion;
    }
    {
        const statement = try prepare(database, "SELECT value FROM store_meta WHERE key='store_selector'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try readText(statement, 0, &stored_selector);
        if (!stored_selector.eql(selector)) return error.WrongStoreIdentity;
    }
}

fn pragmaInt(database: *c.sqlite3, sql: [:0]const u8) !u32 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.PragmaReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0 or value > std.math.maxInt(u32)) return error.CorruptStore;
    return @intCast(value);
}

fn readUnixMilliseconds(database: *c.sqlite3) !i64 {
    const statement = try prepare(
        database,
        "SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER)",
    );
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ClockReadFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value <= 0) return error.ClockReadFailed;
    return value;
}

fn decideModelRetry(attempt_ordinal: u64, policy: RetryPolicyInput) !ModelRetryDecision {
    if (attempt_ordinal == 0 or attempt_ordinal > maximum_model_attempts) {
        return error.InvalidAttemptOrdinal;
    }
    for (policy.waits_ms) |wait_ms| {
        if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (policy.retry_after_ms) |retry_after_ms| {
        if (retry_after_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (attempt_ordinal == maximum_model_attempts) return .exhausted;
    const index: usize = @intCast(attempt_ordinal - 1);
    return .{ .schedule_after_ms = @max(
        policy.waits_ms[index],
        policy.retry_after_ms orelse 0,
    ) };
}

fn bindCurrent(statement: *c.sqlite3_stmt, session_ref: []const u8, current: *const CurrentConfiguration) !void {
    try bindText(statement, 1, session_ref);
    try bindText(statement, 2, current.workspace.slice());
    try bindText(statement, 3, current.model.slice());
    try bindNullableI64(statement, 4, current.instructions_id);
    try bindI64(statement, 5, current.tools_mask);
    try bindI64(statement, 6, current.permission_mode);
    try bindNullableI64(statement, 7, current.output_schema_id);
    try bindU64(statement, 8, current.revision);
    try bindU64(statement, 9, current.next_position);
}

fn nextIdentity(database: *c.sqlite3, comptime table: []const u8, comptime column: []const u8) !u64 {
    const statement = try prepare(
        database,
        "SELECT " ++ column ++ " FROM " ++ table ++ " ORDER BY " ++ column ++ " DESC LIMIT 1",
    );
    defer _ = c.sqlite3_finalize(statement);
    const result = c.sqlite3_step(statement);
    if (result == c.SQLITE_DONE) return 1;
    if (result != c.SQLITE_ROW) return error.IdentityReadFailed;
    const prior = c.sqlite3_column_int64(statement, 0);
    if (prior <= 0 or prior == std.math.maxInt(i64)) return error.IdentityExhausted;
    return @intCast(prior + 1);
}

fn prepare(database: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v3(database, sql, -1, c.SQLITE_PREPARE_PERSISTENT, &statement, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    return statement orelse error.StatementPrepareFailed;
}

fn exec(database: *c.sqlite3, sql: [:0]const u8) !void {
    if (c.sqlite3_exec(database, sql, null, null, null) != c.SQLITE_OK) return error.SqliteExecFailed;
}

fn rollback(database: *c.sqlite3) void {
    _ = c.sqlite3_exec(database, "ROLLBACK", null, null, null);
}

fn dbConfig(database: *c.sqlite3, operation: c_int, value: c_int) !void {
    var prior: c_int = 0;
    if (c.sqlite3_db_config(database, operation, value, &prior) != c.SQLITE_OK) {
        return error.SqliteConfigurationFailed;
    }
}

fn setLimit(database: *c.sqlite3, category: c_int, value: c_int) !void {
    _ = c.sqlite3_limit(database, category, value);
    if (c.sqlite3_limit(database, category, -1) != value) return error.SqliteLimitConfigurationFailed;
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text64(statement, index, value.ptr, value.len, null, c.SQLITE_UTF8) != c.SQLITE_OK) {
        return error.BindFailed;
    }
}

fn bindOptionalText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (value.len == 0) {
        if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
    } else try bindText(statement, index, value);
}

fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_blob64(statement, index, value.ptr, value.len, null) != c.SQLITE_OK) return error.BindFailed;
}

fn bindI64(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return error.BindFailed;
}

fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.IntegerOutOfRange;
    try bindI64(statement, index, value);
}

fn bindNullableI64(statement: *c.sqlite3_stmt, index: c_int, value: ?i64) !void {
    const result = if (value) |actual|
        c.sqlite3_bind_int64(statement, index, actual)
    else
        c.sqlite3_bind_null(statement, index);
    if (result != c.SQLITE_OK) return error.BindFailed;
}

fn bindNullableU64(statement: *c.sqlite3_stmt, index: c_int, value: ?u64) !void {
    if (value) |present| return bindU64(statement, index, present);
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.BindFailed;
}

fn expectDone(statement: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.StatementFailed;
}

fn readText(statement: *c.sqlite3_stmt, index: c_int, destination: anytype) !void {
    const length = c.sqlite3_column_bytes(statement, index);
    if (length < 0) return error.CorruptStore;
    if (length == 0) return destination.set("");
    const pointer = c.sqlite3_column_text(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    try destination.set(bytes[0..@intCast(length)]);
}

fn readDigest(statement: *c.sqlite3_stmt, index: c_int) ![32]u8 {
    if (c.sqlite3_column_bytes(statement, index) != 32) return error.CorruptStore;
    const pointer = c.sqlite3_column_blob(statement, index) orelse return error.CorruptStore;
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..32].*;
}

fn readNullablePositiveI64(statement: *c.sqlite3_stmt, index: c_int) !?i64 {
    if (c.sqlite3_column_type(statement, index) == c.SQLITE_NULL) return null;
    const value = c.sqlite3_column_int64(statement, index);
    if (value <= 0) return error.InvalidIdentity;
    return value;
}

fn testingStore(tmp: *std.testing.TmpDir, io: std.Io) !Store {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return Store.open(io, database, root) catch |err| {
        std.debug.print("testing Store open failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn completeConfiguration(key: []const u8, session_ref: []const u8, workspace: []const u8, model: []const u8) !protocol.ConfigureCommand {
    var command: protocol.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.model.state = .value;
    try command.configuration.model.value.set(model);
    return command;
}

fn completeMessage(
    key: []const u8,
    session_ref: []const u8,
    file: std.Io.File,
    text: []const u8,
) !protocol.MessageCommand {
    var command: protocol.MessageCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.text = .{
        .state = .value,
        .file = file,
        .length = text.len,
        .digest = protocol.contentDigest(text),
    };
    return command;
}

fn canonicalCwd(io: std.Io, buffer: []u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer directory.close(io);
    const length = try directory.realPath(io, buffer);
    return buffer[0..length];
}

fn admitRetryForTesting(storage: *Store) !?AttemptAdmission {
    return storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{});
}

fn completeSessionStop(key: []const u8, session_ref: []const u8) !protocol.SessionStopCommand {
    var command: protocol.SessionStopCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    return command;
}

fn completeModelInterruption(
    key: []const u8,
    session_ref: []const u8,
    binding: AttemptBinding,
) !protocol.ModelInterruptionCommand {
    var command: protocol.ModelInterruptionCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.turn_id = binding.turn_id;
    command.operation_id = binding.operation_id;
    return command;
}

fn configureTestSession(
    storage: *Store,
    key: []const u8,
    session_ref: []const u8,
) !void {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, session_ref, workspace, "model-a");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
}

fn submitTestMessage(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    file_name: []const u8,
    key: []const u8,
    session_ref: []const u8,
    text: []const u8,
) !void {
    const file = try tmp.dir.createFile(std.testing.io, file_name, .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var command = try completeMessage(key, session_ref, file, text);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&command, .{}) == .accepted);
}

test "Session stop freezes its selection and excludes only the admitted prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-stop", "direct/stop");
    try submitTestMessage(&storage, &tmp, "stop-a", "message-a", "direct/stop", "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;

    var stop = try completeSessionStop("stop", "direct/stop");
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expect(!accepted.accepted.replayed);
    try std.testing.expectEqual(binding.turn_id, accepted.accepted.selection.selected_turn_id.?);
    try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
    try std.testing.expectEqual(binding.operation_id, accepted.accepted.interrupted_operation_id.?);
    try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding));

    const cancelled = (try storage.observeCommand("message-a")).message.?.queue.?;
    const cancellation = switch (cancelled.state) {
        .cancelled => |value| value,
        else => return error.ExpectedCancelledObservation,
    };
    try std.testing.expectEqual(binding.turn_id, cancellation.binding.turn_id);
    try std.testing.expectEqualStrings("cancelled", cancellation.code.slice());

    var after_stop = try completeModelInterruption("interrupt-after-stop", "direct/stop", binding);
    const rejected_interrupt = storage.interruptModel(&after_stop, .{});
    try std.testing.expect(rejected_interrupt == .rejected);
    try std.testing.expectEqual(
        ModelInterruptionRejection.operation_resolved,
        rejected_interrupt.rejected.code,
    );

    try submitTestMessage(&storage, &tmp, "stop-b", "message-b", "direct/stop", "later");
    const replay = storage.stopSession(&stop, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), replay.accepted.selection.admission_cutoff);
    try std.testing.expect((try storage.observeCommand("message-b")).message.?.queue.?.state == .queued);
    const later = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expect(later.permit.binding.turn_id != binding.turn_id);
}

test "idle Session stop excludes queued work but not later admissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-idle-stop", "direct/idle-stop");
    try submitTestMessage(&storage, &tmp, "idle-stop-a", "idle-message-a", "direct/idle-stop", "before");
    var stop = try completeSessionStop("idle-stop", "direct/idle-stop");
    const accepted = storage.stopSession(&stop, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectEqual(@as(?u64, null), accepted.accepted.selection.selected_turn_id);
    try std.testing.expectEqual(@as(u64, 1), accepted.accepted.selection.admission_cutoff);
    const excluded = (try storage.observeCommand("idle-message-a")).message.?.queue.?;
    try std.testing.expect(excluded.state == .excluded);
    try std.testing.expectEqualStrings("session_stopped", excluded.state.excluded.code.slice());
    try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);

    try submitTestMessage(&storage, &tmp, "idle-stop-b", "idle-message-b", "direct/idle-stop", "after");
    const later = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 1), later.permit.binding.turn_id);
}

test "exact model interruption continues only with applicable pending input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-interrupt", "direct/interrupt");
    try submitTestMessage(&storage, &tmp, "interrupt-a", "interrupt-message-a", "direct/interrupt", "first");
    const first = (try storage.admitNextModelAttempt(.{})).?;
    const binding = first.permit.binding;
    try submitTestMessage(&storage, &tmp, "interrupt-b", "interrupt-message-b", "direct/interrupt", "second");

    var interrupt = try completeModelInterruption("interrupt", "direct/interrupt", binding);
    const accepted = storage.interruptModel(&interrupt, .{});
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectError(error.SupersededByControl, storage.openHistoricalView(binding));
    const successor = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(binding.turn_id, successor.permit.binding.turn_id);
    try std.testing.expect(successor.permit.binding.operation_id != binding.operation_id);

    const observation = try storage.observeCommand("interrupt");
    try std.testing.expectEqual(binding.turn_id, observation.model_interruption.?.turn_id);
    try std.testing.expectEqual(binding.operation_id, observation.model_interruption.?.operation_id);
}

test "exact model interruption rejects stale targets and replays before applicability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-rejected-interrupt", "direct/rejected-interrupt");
    var early: protocol.ModelInterruptionCommand = .{ .turn_id = 1, .operation_id = 1 };
    try early.key.set("early-interrupt");
    try early.session.set("direct/rejected-interrupt");
    const rejected = storage.interruptModel(&early, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, rejected.rejected.code);

    try submitTestMessage(&storage, &tmp, "rejected-interrupt-a", "rejected-interrupt-message", "direct/rejected-interrupt", "first");
    const admitted = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 1), admitted.permit.binding.operation_id);
    const replay = storage.interruptModel(&early, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(ModelInterruptionRejection.unknown_operation, replay.rejected.code);

    early.operation_id = 2;
    try std.testing.expect(storage.interruptModel(&early, .{}) == .conflict);

    var exact = try completeModelInterruption("exact-interrupt", "direct/rejected-interrupt", admitted.permit.binding);
    try std.testing.expect(storage.interruptModel(&exact, .{}) == .accepted);
    try std.testing.expect(
        (try storage.observeCommand("rejected-interrupt-message")).message.?.queue.?.state == .cancelled,
    );
    try std.testing.expectError(
        error.SupersededByControl,
        storage.settleModelAttemptFailure(admitted.permit.binding, "late_failure", .terminal, .{}),
    );

    var after = try completeModelInterruption("after-interrupt", "direct/rejected-interrupt", admitted.permit.binding);
    const resolved = storage.interruptModel(&after, .{});
    try std.testing.expect(resolved == .rejected);
    try std.testing.expectEqual(ModelInterruptionRejection.operation_resolved, resolved.rejected.code);
}

test "model interruption removes a scheduled retry from admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try configureTestSession(&storage, "configure-retry-interrupt", "direct/retry-interrupt");
    try submitTestMessage(&storage, &tmp, "retry-interrupt-a", "retry-interrupt-message", "direct/retry-interrupt", "first");
    const admitted = (try storage.admitNextModelAttempt(.{})).?;
    try storage.settleModelAttemptFailure(admitted.permit.binding, "temporary", .{ .retryable = .{
        .waits_ms = .{ 1, 1, 1 },
    } }, .{});

    var interrupt = try completeModelInterruption(
        "retry-interrupt",
        "direct/retry-interrupt",
        admitted.permit.binding,
    );
    try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
}

test "failed control commit saves no answer after reopening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    try configureTestSession(&storage, "configure-control-rollback", "direct/control-rollback");
    var stop = try completeSessionStop("rollback-stop", "direct/control-rollback");
    try std.testing.expect(storage.stopSession(&stop, .{ .before_commit = true }) == .infrastructure_failure);
    try std.testing.expect(storage.isFenced());
    try storage.close();

    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var database_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    const database = try std.fmt.bufPrint(
        &database_buffer,
        "{s}/store.sqlite3",
        .{root_buffer[0..root_length]},
    );
    storage = try Store.open(std.testing.io, database, root_buffer[0..root_length]);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("rollback-stop")).status == .absent);
}

test "configuration pre-Workspace decisions preserve completeness and continuation precedence" {
    const Case = struct {
        name: []const u8,
        has_current: bool,
        workspace_requested: bool,
        model_requested: ?[]const u8,
        continuation_risk: bool,
        expected: ?ConfigurationRejection,
    };
    const cases = [_]Case{
        .{
            .name = "new sparse request",
            .has_current = false,
            .workspace_requested = false,
            .model_requested = null,
            .continuation_risk = false,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new request missing model",
            .has_current = false,
            .workspace_requested = true,
            .model_requested = null,
            .continuation_risk = false,
            .expected = .incomplete_initial_configuration,
        },
        .{
            .name = "new complete request",
            .has_current = false,
            .workspace_requested = true,
            .model_requested = "model-a",
            .continuation_risk = true,
            .expected = null,
        },
        .{
            .name = "risky incompatible model before Workspace",
            .has_current = true,
            .workspace_requested = true,
            .model_requested = "model-b",
            .continuation_risk = true,
            .expected = .continuation_model_incompatible,
        },
        .{
            .name = "same model with continuation",
            .has_current = true,
            .workspace_requested = false,
            .model_requested = "model-a",
            .continuation_risk = true,
            .expected = null,
        },
        .{
            .name = "compatible sparse update",
            .has_current = true,
            .workspace_requested = false,
            .model_requested = "model-b",
            .continuation_risk = false,
            .expected = null,
        },
    };

    var existing: CurrentConfiguration = .{};
    try existing.workspace.set("/canonical/workspace");
    try existing.model.set("model-a");
    existing.instructions_id = 11;
    existing.revision = 1;
    for (cases) |case| {
        var requested: protocol.Configuration = .{};
        if (case.workspace_requested) {
            requested.workspace.state = .value;
            try requested.workspace.value.set("relative-or-different-workspace");
        }
        if (case.model_requested) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        const current: ?*const CurrentConfiguration = if (case.has_current) &existing else null;
        std.testing.expectEqual(
            case.expected,
            configurationBeforeWorkspace(current, &requested, case.continuation_risk),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "configuration planning preserves sparse defaults and rejection precedence" {
    const WorkspaceRequest = enum { omitted, same, different };
    const InstructionsRequest = enum { omitted, value };
    const SchemaRequest = enum { omitted, value, clear };
    const Actions = struct {
        instructions: ConfigurationContentAction,
        output_schema: ConfigurationContentAction,
    };
    const Case = struct {
        name: []const u8,
        created: bool,
        workspace: WorkspaceRequest,
        model: ?[]const u8 = null,
        empty_tools: bool = false,
        permission: ?[]const u8 = null,
        instructions: InstructionsRequest = .omitted,
        schema: SchemaRequest = .omitted,
        current_revision: u64 = 7,
        expected_rejection: ?ConfigurationRejection = null,
        expected_actions: ?Actions = null,
        expected_model: []const u8 = "model-a",
        expected_tools: u8 = 3,
        expected_permission: u8 = 0,
        expected_revision: u64 = 8,
    };
    const cases = [_]Case{
        .{
            .name = "new defaults",
            .created = true,
            .workspace = .same,
            .model = "model-a",
            .expected_actions = .{ .instructions = .default_empty, .output_schema = .clear },
            .expected_revision = 1,
        },
        .{
            .name = "sparse update preserves omitted content",
            .created = false,
            .workspace = .omitted,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .preserve },
        },
        .{
            .name = "explicit update requests imports and clear",
            .created = false,
            .workspace = .same,
            .model = "model-b",
            .empty_tools = true,
            .permission = "bypass",
            .instructions = .value,
            .schema = .clear,
            .expected_actions = .{ .instructions = .import_requested, .output_schema = .clear },
            .expected_model = "model-b",
            .expected_tools = 0,
            .expected_permission = 1,
        },
        .{
            .name = "requested schema imports",
            .created = false,
            .workspace = .omitted,
            .schema = .value,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .import_requested },
        },
        .{
            .name = "Workspace immutability precedes revision exhaustion",
            .created = false,
            .workspace = .different,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .workspace_is_immutable,
            .expected_revision = std.math.maxInt(i64),
        },
        .{
            .name = "revision exhaustion follows equal Workspace",
            .created = false,
            .workspace = .same,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .revision_exhausted,
            .expected_revision = std.math.maxInt(i64),
        },
    };

    try std.testing.expect(@sizeOf(ConfigurationUpdatePlan) <= 4);
    for (cases) |case| {
        var existing: CurrentConfiguration = .{};
        try existing.workspace.set("/canonical/workspace");
        try existing.model.set("model-a");
        existing.instructions_id = 11;
        existing.output_schema_id = 12;
        existing.revision = case.current_revision;

        var requested: protocol.Configuration = .{};
        if (case.workspace != .omitted) requested.workspace.state = .value;
        if (case.model) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        if (case.empty_tools) {
            requested.tools.state = .value;
            requested.tools.count = 0;
        }
        if (case.permission) |permission| {
            requested.permission_mode.state = .value;
            try requested.permission_mode.value.set(permission);
        }
        if (case.instructions == .value) requested.instructions.state = .value;
        requested.output_schema.state = switch (case.schema) {
            .omitted => .omitted,
            .value => .value,
            .clear => .explicit_null,
        };

        var canonical_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
        try canonical_workspace.set(switch (case.workspace) {
            .omitted, .same => "/canonical/workspace",
            .different => "/different/workspace",
        });
        const canonical_workspace_ref: ?*const protocol.Bounded(protocol.max_workspace_bytes) =
            if (case.workspace == .omitted) null else &canonical_workspace;
        const current: ?*const CurrentConfiguration = if (case.created) null else &existing;
        var next = if (current) |value| value.* else CurrentConfiguration{};
        const plan = planConfigurationUpdate(current, &requested, canonical_workspace_ref, &next);

        if (case.expected_rejection) |expected| {
            std.testing.expect(plan == .rejected) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected, plan.rejected);
        } else {
            const expected = case.expected_actions.?;
            std.testing.expect(plan == .update) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected.instructions, plan.update.instructions);
            try std.testing.expectEqual(expected.output_schema, plan.update.output_schema);
        }
        try std.testing.expectEqualStrings(case.expected_model, next.model.slice());
        try std.testing.expectEqual(case.expected_tools, next.tools_mask);
        try std.testing.expectEqual(case.expected_permission, next.permission_mode);
        try std.testing.expectEqual(case.expected_revision, next.revision);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 11), next.instructions_id);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 12), next.output_schema_id);
    }
}

test "configuration rejection content imports roll back and replay committed answer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const instructions = "rejected instructions";
    const instructions_file = try tmp.dir.createFile(std.testing.io, "rejected-instructions", .{ .read = true });
    try instructions_file.writeStreamingAll(std.testing.io, instructions);
    try instructions_file.sync(std.testing.io);
    const schema = "{\"type\":\"object\"}";
    const schema_file = try tmp.dir.createFile(std.testing.io, "rejected-schema", .{ .read = true });
    try schema_file.writeStreamingAll(std.testing.io, schema);
    try schema_file.sync(std.testing.io);
    var command: protocol.ConfigureCommand = .{};
    try command.key.set("rejected-content");
    command.configuration.instructions = .{
        .state = .value,
        .file = instructions_file,
        .length = instructions.len,
        .digest = protocol.contentDigest(instructions),
    };
    command.configuration.output_schema = .{
        .state = .value,
        .file = schema_file,
        .length = schema.len,
        .digest = protocol.contentDigest(schema),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&command, .{ .content_import = true }) == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("rejected-content")).status == .absent);
        const rolled_back_content = try prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(rolled_back_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(rolled_back_content));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(rolled_back_content, 0));

        const rejected = storage.configure(&command, .{});
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
        const committed_content = try prepare(
            storage.database,
            "SELECT COUNT(*) FROM core_command command " ++
                "JOIN content instructions ON instructions.content_id=command.primary_content_id " ++
                "JOIN content schema ON schema.content_id=command.secondary_content_id " ++
                "WHERE command.command_key='rejected-content'",
        );
        defer _ = c.sqlite3_finalize(committed_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(committed_content));
        try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(committed_content, 0));

        const replay = storage.configure(&command, .{});
        try std.testing.expect(replay == .rejected);
        try std.testing.expect(replay.rejected.replayed);
        try std.testing.expectEqual(ConfigurationRejection.invalid_session_reference, replay.rejected.code);
        const retained_content = try prepare(storage.database, "SELECT COUNT(*) FROM content");
        defer _ = c.sqlite3_finalize(retained_content);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(retained_content));
        try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(retained_content, 0));
    }
}

test "configuration answers replay without reverting newer settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var first = try completeConfiguration("first", "direct/test", workspace, "model-a");
    const first_reply = storage.configure(&first, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(first_reply.accepted.created);

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("update");
    try update.session.set("direct/test");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const update_reply = storage.configure(&update, .{});
    try std.testing.expect(update_reply == .accepted);
    try std.testing.expectEqual(@as(u64, 2), update_reply.accepted.revision);

    const replay = storage.configure(&first, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
    const observation = try storage.inspectSession("direct/test");
    try std.testing.expectEqualStrings("model-b", observation.model.slice());
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    try std.testing.expectEqual(@as(u8, 3), observation.tools_mask);
    try std.testing.expectEqualStrings("ask", observation.permission_mode.slice());
    try std.testing.expectEqual(@as(u64, 0), observation.instructions.length);
    var empty_digest: [32]u8 = undefined;
    empty_digest = protocol.contentDigest("");
    try std.testing.expectEqualSlices(u8, &empty_digest, &observation.instructions.digest);
    try std.testing.expect(observation.output_schema == null);

    var reader = try storage.openContent(observation.instructions);
    defer reader.close();
    var content_window: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try reader.read(0, &content_window));
    try std.testing.expectError(error.RangeOutOfBounds, reader.read(1, &content_window));
    var private_reference = observation.instructions;
    private_reference.private = true;
    try std.testing.expectError(error.PrivateContent, storage.openContent(private_reference));
    try std.testing.expect((try storage.observeCommand("first")).status == .accepted);

    first.configuration.model.value.len = 0;
    try first.configuration.model.value.set("model-c");
    try std.testing.expect(storage.configure(&first, .{}) == .conflict);
}

test "core preserves empty keys and Session references containing NUL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    const session_ref = "exact\x00reference";
    var command = try completeConfiguration("", session_ref, workspace, "model-a");
    const reply = storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    const observation = try storage.inspectSession(session_ref);
    try std.testing.expect(observation.found);
    try std.testing.expectEqualSlices(u8, session_ref, observation.session.slice());
    try std.testing.expect((try storage.observeCommand("")).status == .accepted);
}

test "saved incomplete initialization stays rejected after Session creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    try incomplete.session.set("direct/rejection");
    const rejected = storage.configure(&incomplete, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var complete = try completeConfiguration(
        "complete",
        "direct/rejection",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&complete, .{}) == .accepted);
    const replay = storage.configure(&incomplete, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
}

test "failed commit saves neither answer nor partial Session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(
        "commit-fault",
        "direct/fault",
        workspace,
        "model-a",
    );
    {
        var storage = try testingStore(&tmp, std.testing.io);
        const reply = storage.configure(&command, .{ .before_commit = true });
        try std.testing.expect(reply == .infrastructure_failure);
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        try std.testing.expect((try storage.observeCommand("commit-fault")).status == .absent);
        try std.testing.expect(!(try storage.inspectSession("direct/fault")).found);
        try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    }
}

test "message admissions remain queued in order and retain bounded canonical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/messages", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_text = "first message\n" ++ ("abcdef" ** 700) ++ "🙂";
    const first_file = try tmp.dir.createFile(std.testing.io, "first-message", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, first_text);
    try first_file.sync(std.testing.io);
    var first = try completeMessage("message-1", "direct/messages", first_file, first_text);
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    const first_reply = storage.submitMessage(&first, .{});
    try std.testing.expect(first_reply == .accepted);
    try std.testing.expect(!first_reply.accepted.replayed);
    try std.testing.expectEqual(@as(u64, 1), first_reply.accepted.admission_id);

    const second_text = "second";
    const second_file = try tmp.dir.createFile(std.testing.io, "second-message", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, second_text);
    try second_file.sync(std.testing.io);
    var second = try completeMessage("message-2", "direct/messages", second_file, second_text);
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    const second_reply = storage.submitMessage(&second, .{});
    try std.testing.expect(second_reply == .accepted);
    try std.testing.expect(first_reply.accepted.admission_id < second_reply.accepted.admission_id);

    const replay = storage.submitMessage(&first, .{});
    try std.testing.expect(replay == .accepted);
    try std.testing.expect(replay.accepted.replayed);
    try std.testing.expectEqual(first_reply.accepted.admission_id, replay.accepted.admission_id);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(first_text), &replay.accepted.content.digest);

    const session = try storage.inspectSession("direct/messages");
    try std.testing.expectEqual(@as(u64, 2), session.pending_messages);
    const observed = try storage.observeCommand("message-1");
    try std.testing.expect(observed.status == .accepted);
    try std.testing.expect(observed.kind == .message);
    try std.testing.expect(observed.message != null);
    const accepted_observation = observed.message.?.queue.?;
    try std.testing.expectEqual(first_reply.accepted.admission_id, accepted_observation.admission_id);
    try std.testing.expect(accepted_observation.state == .queued);

    var reader = try storage.openContent(observed.message.?.content);
    var actual: [first_text.len]u8 = undefined;
    var offset: usize = 0;
    while (offset < actual.len) {
        const count = try reader.read(offset, actual[offset..@min(actual.len, offset + 31)]);
        try std.testing.expect(count != 0);
        offset += count;
    }
    reader.close();
    try std.testing.expectEqualSlices(u8, first_text, &actual);

    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    const restarted = try storage.observeCommand("message-1");
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.message.?.queue.?.admission_id);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSession("direct/messages")).pending_messages);
}

test "message rejections retain input and replay before current Session checks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const text = "rejected input";
    const file = try tmp.dir.createFile(std.testing.io, "rejected-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("rejected-message", "direct/later", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    const rejected = storage.submitMessage(&message, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, rejected.rejected.code);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure-later", "direct/later", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const replay = storage.submitMessage(&message, .{});
    try std.testing.expect(replay == .rejected);
    try std.testing.expect(replay.rejected.replayed);
    try std.testing.expectEqual(MessageRejection.unknown_session, replay.rejected.code);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &replay.rejected.content.digest);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/later")).pending_messages);

    const observed = try storage.observeCommand("rejected-message");
    try std.testing.expect(observed.status == .rejected);
    try std.testing.expect(observed.message != null);
    try std.testing.expect(observed.message.?.queue == null);

    var other_configuration = try completeConfiguration(
        "other-rejected-configure",
        "direct/other-rejected",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&other_configuration, .{}) == .accepted);
    const other_file = try tmp.dir.createFile(std.testing.io, "other-rejected-message", .{ .read = true });
    try other_file.writeStreamingAll(std.testing.io, "different input");
    try other_file.sync(std.testing.io);
    var other_message = try completeMessage(
        "other-rejected-message",
        "direct/other-rejected",
        other_file,
        "different input",
    );
    defer other_message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&other_message, .{}) == .accepted);
    try exec(
        storage.database,
        "UPDATE message_admission SET command_key='rejected-message' " ++
            "WHERE command_key='other-rejected-message'",
    );
    try std.testing.expectError(error.CorruptStore, storage.observeCommand("rejected-message"));
    try std.testing.expect(storage.isFenced());
}

test "message observation validates accepted admission references independently" {
    const corruptions = [_]enum { session, content }{ .session, .content };
    for (corruptions) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;

        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var primary_configuration = try completeConfiguration(
            "reference-primary-configure",
            "direct/reference-primary",
            workspace,
            "model-a",
        );
        try std.testing.expect(storage.configure(&primary_configuration, .{}) == .accepted);
        var other_configuration = try completeConfiguration(
            "reference-other-configure",
            "direct/reference-other",
            workspace,
            "model-a",
        );
        try std.testing.expect(storage.configure(&other_configuration, .{}) == .accepted);

        const primary_file = try tmp.dir.createFile(std.testing.io, "reference-primary-message", .{ .read = true });
        try primary_file.writeStreamingAll(std.testing.io, "primary input");
        try primary_file.sync(std.testing.io);
        var primary_message = try completeMessage(
            "reference-primary-message",
            "direct/reference-primary",
            primary_file,
            "primary input",
        );
        defer primary_message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&primary_message, .{}) == .accepted);

        const other_file = try tmp.dir.createFile(std.testing.io, "reference-other-message", .{ .read = true });
        try other_file.writeStreamingAll(std.testing.io, "other input");
        try other_file.sync(std.testing.io);
        var other_message = try completeMessage(
            "reference-other-message",
            "direct/reference-other",
            other_file,
            "other input",
        );
        defer other_message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&other_message, .{}) == .accepted);

        switch (corruption) {
            .session => try exec(
                storage.database,
                "UPDATE message_admission SET session_ref='direct/reference-other' " ++
                    "WHERE command_key='reference-primary-message'",
            ),
            .content => try exec(
                storage.database,
                "UPDATE message_admission SET content_id=(" ++
                    "SELECT content_id FROM message_admission WHERE command_key='reference-other-message') " ++
                    "WHERE command_key='reference-primary-message'",
            ),
        }
        try std.testing.expectError(
            error.CorruptStore,
            storage.observeCommand("reference-primary-message"),
        );
        try std.testing.expect(storage.isFenced());
    }
}

test "message observation rejects an answer attached to processing durable facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "corrupt-observation-configure",
        "direct/corrupt-observation",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "corrupt-observation-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "input");
    try file.sync(std.testing.io);
    var message = try completeMessage(
        "corrupt-observation-message",
        "direct/corrupt-observation",
        file,
        "input",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try exec(
        storage.database,
        "UPDATE turn SET outcome_content_id=(" ++
            "SELECT content_id FROM message_admission WHERE command_key='corrupt-observation-message')",
    );

    try std.testing.expectError(
        error.CorruptStore,
        storage.observeCommand("corrupt-observation-message"),
    );
    try std.testing.expect(storage.isFenced());
}

test "message conflicts and failed commits cannot create another admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/conflict", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const text = "one admission";
    const file = try tmp.dir.createFile(std.testing.io, "message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message", "direct/conflict", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .before_commit = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect((try storage.observeCommand("message")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/conflict")).pending_messages);
    const accepted = storage.submitMessage(&message, .{});
    try std.testing.expect(accepted == .accepted);

    var retargeted = message;
    retargeted.text.file = null;
    try retargeted.session.set("direct/other");
    try std.testing.expect(storage.submitMessage(&retargeted, .{}) == .conflict);
    var changed = message;
    changed.text.file = null;
    changed.text.length += 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var changed_kind = try completeConfiguration("message", "direct/conflict", workspace, "model-a");
    try std.testing.expect(storage.configure(&changed_kind, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession("direct/conflict")).pending_messages);
    try storage.close();
}

test "failed message import rolls back content command and admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/import", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const text = "larger than an empty import";
    const file = try tmp.dir.createFile(std.testing.io, "import-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message = try completeMessage("message-import", "direct/import", file, text);
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{ .content_import = true }) == .infrastructure_failure);
    try storage.close();

    storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expect((try storage.observeCommand("message-import")).status == .absent);
    try std.testing.expectEqual(@as(u64, 0), (try storage.inspectSession("direct/import")).pending_messages);
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
}

test "rollback failure fences mutation until fresh reopen restores committed facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "rollback-configure",
        "direct/rollback",
        workspace,
        "model-a",
    );
    const message_file = try tmp.dir.createFile(std.testing.io, "rollback-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "committed prefix");
    try message_file.sync(std.testing.io);
    var message = try completeMessage(
        "rollback-message",
        "direct/rollback",
        message_file,
        "committed prefix",
    );
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;

    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
        try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.admitNextModelAttempt(.{
                .attempt_before_commit = true,
                .rollback_failure = true,
            }),
        );
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_get_autocommit(storage.database));
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(error.StoreFenced, storage.admitNextModelAttempt(.{}));
        var later = try completeConfiguration("rollback-later", "direct/later", workspace, "model-a");
        try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
        try storage.close();
    }

    var binding: AttemptBinding = undefined;
    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect((try storage.observeCommand("rollback-configure")).status == .accepted);
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .queued,
        );
        {
            const partial = try prepare(
                storage.database,
                "SELECT (SELECT count(*) FROM turn),(SELECT count(*) FROM model_operation)," ++
                    "(SELECT count(*) FROM conversation_entry)",
            );
            defer _ = c.sqlite3_finalize(partial);
            try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(partial));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 0));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 1));
            try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(partial, 2));
        }

        var admission = (try storage.admitNextModelAttempt(.{})).?;
        binding = try admission.permit.consume();
        var stale = binding;
        stale.attempt_ordinal += 1;
        try std.testing.expectError(
            error.CanonicalRollbackFailed,
            storage.settleModelAttemptFailure(
                stale,
                "must-not-settle",
                .terminal,
                .{ .rollback_failure = true },
            ),
        );
        try std.testing.expect(storage.isFenced());
        try std.testing.expectError(
            error.StoreFenced,
            storage.settleModelAttemptFailure(binding, "must-not-settle", .terminal, .{}),
        );
        try storage.close();
    }

    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("rollback-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(binding.operation_id, observed_binding.operation_id);
        try storage.settleModelAttemptFailure(binding, "provider_http_422", .terminal, .{});
        try std.testing.expect(
            (try storage.observeCommand("rollback-message")).message.?.queue.?.state == .failed,
        );
    }
}

test "production Store applies finite durable SQLite settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA busy_timeout"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA mmap_size"));
    try std.testing.expectEqual(@as(u32, 1), try pragmaInt(storage.database, "PRAGMA temp_store"));
    try std.testing.expectEqual(@as(u32, 3), try pragmaInt(storage.database, "PRAGMA synchronous"));
    try std.testing.expectEqual(@as(u32, 4096), try pragmaInt(storage.database, "PRAGMA page_size"));
    try std.testing.expectEqual(@as(u32, 0), try pragmaInt(storage.database, "PRAGMA trusted_schema"));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_threadsafe());
    try std.testing.expectEqual(@as(i64, sqlite_heap_bytes), c.sqlite3_hard_heap_limit64(-1));
    try std.testing.expectEqual(@as(c_int, 16 * 1024), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_SQL_LENGTH, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_ATTACHED, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_limit(storage.database, c.SQLITE_LIMIT_WORKER_THREADS, -1));
}

test "fresh Store uses current schema and rejects the prior version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});

    var storage = try Store.open(std.testing.io, database, root);
    try std.testing.expectEqual(schema_version, try pragmaInt(storage.database, "PRAGMA user_version"));
    {
        const removed_index = try prepare(
            storage.database,
            "SELECT count(*) FROM sqlite_schema WHERE type='index' AND name='model_operation_runnable'",
        );
        defer _ = c.sqlite3_finalize(removed_index);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(removed_index));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(removed_index, 0));
    }
    try exec(storage.database, "PRAGMA user_version=7");
    try storage.close();

    try std.testing.expectError(
        error.WrongStoreVersion,
        Store.open(std.testing.io, database, root),
    );
}

test "existing Store rejects a different canonical identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage = try Store.open(std.testing.io, database, root);
    try storage.close();
    try std.testing.expectError(
        error.WrongStoreIdentity,
        Store.open(std.testing.io, database, "/different/canonical/store"),
    );
}

test "canonical observation failure fences later admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("create", "direct/corrupt", workspace, "model-a");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(storage.database, "UPDATE session SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/corrupt'");
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    try std.testing.expectError(error.CorruptStore, storage.inspectSession("direct/corrupt"));

    var later = try completeConfiguration("later", "direct/later", workspace, "model-a");
    try std.testing.expect(storage.configure(&later, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("later"));
}

test "external content import follows sealed descriptor custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const captured = "captured instructions";
    const replacement = "pathname replacement";
    const file = try tmp.dir.createFile(std.testing.io, "ingress", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, captured);
    try file.sync(std.testing.io);
    try tmp.dir.deleteFile(std.testing.io, "ingress");
    var replacement_file = try tmp.dir.createFile(std.testing.io, "ingress", .{});
    try replacement_file.writeStreamingAll(std.testing.io, replacement);
    replacement_file.close(std.testing.io);

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("sealed", "direct/sealed", workspace, "model-a");
    command.configuration.instructions = .{
        .state = .value,
        .file = file,
        .length = captured.len,
        .digest = protocol.contentDigest(captured),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);

    const observation = try storage.inspectSession("direct/sealed");
    var reader = try storage.openContent(observation.instructions);
    defer reader.close();
    var bytes: [captured.len]u8 = undefined;
    try std.testing.expectEqual(captured.len, try reader.read(0, &bytes));
    try std.testing.expectEqualStrings(captured, &bytes);
}

test "external content identity is verified before canonical import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const captured = "captured instructions";
    const file = try tmp.dir.createFile(std.testing.io, "changed", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, captured);
    try file.sync(std.testing.io);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("changed", "direct/changed", workspace, "model-a");
    command.configuration.instructions = .{
        .state = .value,
        .file = file,
        .length = captured.len,
        .digest = protocol.contentDigest("different bytes"),
    };
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;

    try std.testing.expect(storage.configure(&command, .{}) == .infrastructure_failure);
    try std.testing.expectError(error.StoreFenced, storage.observeCommand("changed"));
}

test "one committed selection freezes its settings and input prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/dispatch", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_file = try tmp.dir.createFile(std.testing.io, "dispatch-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage("dispatch-1", "direct/dispatch", first_file, "first");
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);

    const second_file = try tmp.dir.createFile(std.testing.io, "dispatch-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage("dispatch-2", "direct/dispatch", second_file, "second");
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&second, .{}) == .accepted);

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.admitNextModelAttempt(.{ .attempt_before_commit = true }),
    );
    try std.testing.expect(
        (try storage.observeCommand("dispatch-1")).message.?.queue.?.state == .queued,
    );

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    const first_observation = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const second_observation = (try storage.observeCommand("dispatch-2")).message.?.queue.?;
    const first_binding = switch (first_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    const second_binding = switch (second_observation.state) {
        .processing => |value| value,
        else => return error.ExpectedProcessingObservation,
    };
    try std.testing.expectEqual(binding.turn_id, first_binding.turn_id);
    try std.testing.expectEqual(binding.turn_id, second_binding.turn_id);
    try std.testing.expectEqual(binding.operation_id, first_binding.operation_id);
    try std.testing.expectEqual(binding.operation_id, second_binding.operation_id);

    const third_file = try tmp.dir.createFile(std.testing.io, "dispatch-third", .{ .read = true });
    try third_file.writeStreamingAll(std.testing.io, "later");
    try third_file.sync(std.testing.io);
    var third = try completeMessage("dispatch-3", "direct/dispatch", third_file, "later");
    defer third.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&third, .{}) == .accepted);
    var update: protocol.ConfigureCommand = .{};
    try update.key.set("configure-later");
    try update.session.set("direct/dispatch");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const active_update = storage.configure(&update, .{});
    try std.testing.expect(active_update == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.continuation_model_incompatible,
        active_update.rejected.code,
    );

    var view = try storage.openHistoricalView(binding);
    defer view.close();
    const settings = try view.settings();
    try std.testing.expectEqualStrings("model-a", settings.model.slice());
    const first_input = (try view.nextInput(0)).?;
    const second_input = (try view.nextInput(first_input.admission_id)).?;
    try std.testing.expect((try view.nextInput(second_input.admission_id)) == null);
    var first_reader = try view.openContent(first_input.content);
    defer first_reader.close();
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(actual.len, try first_reader.read(0, &actual));
    try std.testing.expectEqualStrings("first", &actual);

    try storage.settleModelAttemptFailure(binding, "provider_http_422", .terminal, .{});
    const failed = (try storage.observeCommand("dispatch-1")).message.?.queue.?;
    const failure = switch (failed.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("provider_http_422", failure.code.slice());
    try std.testing.expect(
        (try storage.observeCommand("dispatch-3")).message.?.queue.?.state == .queued,
    );
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession("direct/dispatch")).pending_messages);

    try update.key.set("configure-after-failure");
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view = try storage.openHistoricalView(later.permit.binding);
    defer later_view.close();
    try std.testing.expectEqualStrings("model-b", (try later_view.settings()).model.slice());
}

test "continued accepted output keeps model continuation incompatible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration(
        "continued-config",
        "direct/continued-output",
        workspace,
        "model-a",
    );
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const first_file = try tmp.dir.createFile(std.testing.io, "continued-first", .{ .read = true });
    try first_file.writeStreamingAll(std.testing.io, "first");
    try first_file.sync(std.testing.io);
    var first = try completeMessage(
        "continued-first",
        "direct/continued-output",
        first_file,
        "first",
    );
    defer first.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&first, .{}) == .accepted);
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    const second_file = try tmp.dir.createFile(std.testing.io, "continued-second", .{ .read = true });
    try second_file.writeStreamingAll(std.testing.io, "second");
    try second_file.sync(std.testing.io);
    var second = try completeMessage(
        "continued-second",
        "direct/continued-output",
        second_file,
        "second",
    );
    defer second.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&second, .{}) == .accepted);

    const source_bytes = "\"answer\"";
    const source = try tmp.dir.createFile(std.testing.io, "continued-output", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained_metadata: ?RetainedOutputMetadata = null;
    var metadata = try OutputMetadataWriter.init(
        std.testing.io,
        root_buffer[0..root_length],
        "continued-metadata",
        &metadata_used,
        1_024,
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    try std.testing.expect(retained_metadata == null);
    try metadata.append(.{
        .tag = .item,
        .kind = .message,
        .start = 0,
        .length = source_bytes.len,
        .content_digest = protocol.contentDigest(source_bytes),
    });
    try metadata.append(.{
        .tag = .text,
        .start = 1,
        .length = "answer".len,
        .decoded_length = "answer".len,
    });
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .answer_length = "answer".len,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .body_model = .{},
        .openai_model = .{},
        .x_openai_model = .{},
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
    {
        const resolution = try prepare(
            storage.database,
            "SELECT resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(resolution);
        try bindU64(resolution, 1, binding.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(resolution));
        var code: protocol.Bounded(96) = .{};
        try readText(resolution, 0, &code);
        try std.testing.expectEqualStrings("continued", code.slice());
    }

    var update: protocol.ConfigureCommand = .{};
    try update.key.set("continued-model-change");
    try update.session.set("direct/continued-output");
    update.configuration.model.state = .value;
    try update.configuration.model.value.set("model-b");
    const rejected = storage.configure(&update, .{});
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(
        ConfigurationRejection.continuation_model_incompatible,
        rejected.rejected.code,
    );

    const completion_binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try storage.settleModelSuccess(completion_binding, &output, .{});
    const completed = (try storage.observeCommand("continued-first")).message.?.queue.?;
    const completion = switch (completed.state) {
        .completed => |value| value,
        else => return error.ExpectedCompletedObservation,
    };
    try std.testing.expectEqual(completion_binding, completion.binding);
    try std.testing.expectEqual(@as(u64, "answer".len), completion.answer.length);
    try std.testing.expectEqualSlices(
        u8,
        &protocol.contentDigest("answer"),
        &completion.answer.digest,
    );
}

test "failed model settlement recovers uncertainty with a fresh consumed Attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("configure", "direct/failure", workspace, "model-a");

    {
        var storage = try testingStore(&tmp, std.testing.io);
        try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
        const message_file = try tmp.dir.createFile(std.testing.io, "failure-message", .{ .read = true });
        try message_file.writeStreamingAll(std.testing.io, "fail");
        try message_file.sync(std.testing.io);
        var message = try completeMessage("failure-message", "direct/failure", message_file, "fail");
        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectError(
            error.InjectedCommitFailure,
            storage.settleModelAttemptFailure(
                binding,
                "request_preparation_failed",
                .terminal,
                .{ .before_commit = true },
            ),
        );
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const observed_binding = switch (observation.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 1), observed_binding.attempt_ordinal);
        var replacement = (try admitRetryForTesting(&storage)).?;
        const replacement_binding = try replacement.permit.consume();
        try std.testing.expectEqual(@as(u64, 2), replacement_binding.attempt_ordinal);
        try std.testing.expectEqual(
            replacement_binding.operation_id,
            observed_binding.operation_id,
        );
        const recovered = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const recovered_binding = switch (recovered.state) {
            .processing => |value| value,
            else => return error.ExpectedProcessingObservation,
        };
        try std.testing.expectEqual(@as(u64, 2), recovered_binding.attempt_ordinal);

        {
            const force_exhausted = try prepare(
                storage.database,
                "UPDATE model_operation SET attempt_ordinal=4,allowance_used=4 WHERE operation_id=?1",
            );
            defer _ = c.sqlite3_finalize(force_exhausted);
            try bindU64(force_exhausted, 1, replacement_binding.operation_id);
            try expectDone(force_exhausted);
            try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(storage.database));
        }

        const Active = struct {
            fn contains(context: *const anyopaque, operation_id: u64) bool {
                const expected: *const u64 = @ptrCast(@alignCast(context));
                return operation_id == expected.*;
            }
        };
        const active_operation = replacement_binding.operation_id;
        try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(.{
            .context = &active_operation,
            .containsFn = Active.contains,
            .maximum_exclusions = 1,
        }));
        try std.testing.expect(
            try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()),
        );
        const exhausted = (try storage.observeCommand("failure-message")).message.?.queue.?;
        const failure = switch (exhausted.state) {
            .failed => |value| value,
            else => return error.ExpectedFailedObservation,
        };
        try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
    }
}

test "temporary model failures conserve allowance and exhaust after four Attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("retry-config", "direct/retry", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const message_file = try tmp.dir.createFile(std.testing.io, "retry-message", .{ .read = true });
    try message_file.writeStreamingAll(std.testing.io, "retry me");
    try message_file.sync(std.testing.io);
    var message = try completeMessage("retry-message", "direct/retry", message_file, "retry me");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);

    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const retry_policy = RetryPolicyInput{
        .waits_ms = .{ 20, 1, 1 },
        .retry_after_ms = 50,
    };
    try storage.settleModelAttemptFailure(
        first,
        "provider_temporary_http_429",
        .{ .retryable = retry_policy },
        .{},
    );
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    {
        const statement = try prepare(
            storage.database,
            "SELECT uncertain,retry_due_at_ms-CAST(unixepoch('subsec')*1000 AS INTEGER),last_failure_code,resolution_code " ++
                "FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, first.operation_id);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 0));
        try std.testing.expect(c.sqlite3_column_int64(statement, 1) > 0);
        var failure: protocol.Bounded(96) = .{};
        try readText(statement, 2, &failure);
        try std.testing.expectEqualStrings("provider_temporary_http_429", failure.slice());
        try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    }

    try std.testing.io.sleep(.fromMilliseconds(60), .awake);
    const second = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, second.operation_id);
    try std.testing.expectEqual(@as(u64, 2), second.attempt_ordinal);
    try std.testing.expectError(
        error.StaleAttemptBinding,
        storage.settleModelAttemptFailure(first, "late_old_failure", .terminal, .{}),
    );
    try std.testing.expect(!storage.isFenced());

    try storage.settleModelAttemptFailure(
        second,
        "provider_transport_failure",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const third = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 3), third.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        third,
        "provider_temporary_http_503",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    const fourth = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(@as(u64, 4), fourth.attempt_ordinal);
    try storage.settleModelAttemptFailure(
        fourth,
        "provider_transport_failure",
        .{ .retryable = .{ .waits_ms = retry_policy.waits_ms } },
        .{},
    );

    const observation = (try storage.observeCommand("retry-message")).message.?.queue.?;
    const failure = switch (observation.state) {
        .failed => |value| value,
        else => return error.ExpectedFailedObservation,
    };
    try std.testing.expectEqualStrings("retry_exhausted", failure.code.slice());
    try std.testing.expect((try admitRetryForTesting(&storage)) == null);
    const statement = try prepare(
        storage.database,
        "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code,resolution_code " ++
            "FROM model_operation WHERE operation_id=?1",
    );
    defer _ = c.sqlite3_finalize(statement);
    try bindU64(statement, 1, first.operation_id);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 0));
    try std.testing.expectEqual(@as(i64, 4), c.sqlite3_column_int64(statement, 1));
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_column_int(statement, 2));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(statement, 3));
    var last_failure: protocol.Bounded(96) = .{};
    try readText(statement, 4, &last_failure);
    try std.testing.expectEqualStrings("provider_transport_failure", last_failure.slice());
    var resolution: protocol.Bounded(96) = .{};
    try readText(statement, 5, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
}

test "model retry decision applies configured waits Retry-After and exhaustion" {
    const defaults = RetryPolicyInput{ .waits_ms = .{ 2_000, 4_000, 8_000 } };
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_after_ms = 2_000 },
        try decideModelRetry(1, defaults),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_after_ms = 4_000 },
        try decideModelRetry(2, defaults),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_after_ms = 8_000 },
        try decideModelRetry(3, defaults),
    );
    try std.testing.expectEqual(
        ModelRetryDecision.exhausted,
        try decideModelRetry(4, defaults),
    );

    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_after_ms = 6_000 },
        try decideModelRetry(2, .{
            .waits_ms = defaults.waits_ms,
            .retry_after_ms = 6_000,
        }),
    );
    try std.testing.expectEqual(
        ModelRetryDecision{ .schedule_after_ms = 8_000 },
        try decideModelRetry(3, .{
            .waits_ms = defaults.waits_ms,
            .retry_after_ms = 6_000,
        }),
    );

    try std.testing.expectError(error.InvalidAttemptOrdinal, decideModelRetry(0, defaults));
    try std.testing.expectError(error.InvalidAttemptOrdinal, decideModelRetry(5, defaults));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = .{ 0, 4_000, 8_000 },
    }));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = .{ @as(u64, @intCast(std.math.maxInt(i64))) + 1, 4_000, 8_000 },
    }));
    try std.testing.expectError(error.InvalidRetryWait, decideModelRetry(1, .{
        .waits_ms = defaults.waits_ms,
        .retry_after_ms = @as(u64, @intCast(std.math.maxInt(i64))) + 1,
    }));
}

test "canonical historical read failure fences dispatch without a fabricated outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var configuration = try completeConfiguration("historical-config", "direct/historical-corrupt", workspace, "model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "historical-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "message");
    try file.sync(std.testing.io);
    var message = try completeMessage("historical-message", "direct/historical-corrupt", file, "message");
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    var attempt = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try attempt.permit.consume();

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(storage.database, "UPDATE session_revision SET instructions_content_id=9223372036854775807 WHERE session_ref='direct/historical-corrupt'");
    try exec(storage.database, "PRAGMA foreign_keys=ON");
    var view = try storage.openHistoricalView(binding);
    defer view.close();
    try std.testing.expectError(error.CorruptStore, view.settings());
    try std.testing.expect(storage.isFenced());
    try std.testing.expectError(
        error.StoreFenced,
        storage.settleModelAttemptFailure(binding, "request_preparation_failed", .terminal, .{}),
    );
}

test "idle runnable probe uses the pending-only admission index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try prepare(storage.database, "EXPLAIN QUERY PLAN " ++ runnable_probe_sql);
    defer _ = c.sqlite3_finalize(statement);
    var uses_pending_index = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const detail = pointer[0..@intCast(length)];
            uses_pending_index = uses_pending_index or
                std.mem.indexOf(u8, detail, "message_admission_pending") != null;
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_pending_index);
}

test "continuation risk follows output and active Turn indexes without Operation scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const statement = try prepare(storage.database, "EXPLAIN QUERY PLAN " ++ continuation_risk_sql);
    defer _ = c.sqlite3_finalize(statement);
    try bindText(statement, 1, "direct/query-plan");
    var uses_output_index = false;
    var uses_active_turn_index = false;
    var uses_current_operation_identity = false;
    var scans_model_operations = false;
    while (true) switch (c.sqlite3_step(statement)) {
        c.SQLITE_ROW => {
            const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
            const length = c.sqlite3_column_bytes(statement, 3);
            if (length < 0) return error.InvalidQueryPlan;
            const detail = pointer[0..@intCast(length)];
            uses_output_index = uses_output_index or
                std.mem.indexOf(u8, detail, "model_output_history") != null;
            uses_active_turn_index = uses_active_turn_index or
                std.mem.indexOf(u8, detail, "turn_one_active_per_session") != null;
            uses_current_operation_identity = uses_current_operation_identity or
                (std.mem.indexOf(u8, detail, "current") != null and
                    std.mem.indexOf(u8, detail, "INTEGER PRIMARY KEY") != null);
            const scans_relation = std.mem.startsWith(u8, detail, "SCAN ") or
                std.mem.indexOf(u8, detail, " SCAN ") != null;
            scans_model_operations = scans_model_operations or
                (scans_relation and
                    (std.mem.indexOf(u8, detail, "current") != null or
                        std.mem.indexOf(u8, detail, "model_operation") != null));
        },
        c.SQLITE_DONE => break,
        else => return error.InvalidQueryPlan,
    };
    try std.testing.expect(uses_output_index);
    try std.testing.expect(uses_active_turn_index);
    try std.testing.expect(uses_current_operation_identity);
    try std.testing.expect(!scans_model_operations);
}

test "retry admission and exhausted recovery use age indexes without temporary sorting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    const queries = [_]struct { sql: [:0]const u8, index: []const u8 }{
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id,attempt_ordinal,allowance_used,retry_due_at_ms " ++
                "FROM model_operation INDEXED BY model_operation_retry_age " ++
                "WHERE resolution_code IS NULL AND allowance_used<4 AND retry_due_at_ms<=99 " ++
                "ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_age",
        },
        .{
            .sql = "EXPLAIN QUERY PLAN SELECT turn_id,operation_id FROM model_operation " ++
                "INDEXED BY model_operation_retry_exhausted WHERE resolution_code IS NULL " ++
                "AND uncertain=1 AND allowance_used=4 AND retry_due_at_ms=0 " ++
                "ORDER BY operation_id LIMIT 64",
            .index = "model_operation_retry_exhausted",
        },
    };
    for (queries) |query| {
        const statement = try prepare(storage.database, query.sql);
        defer _ = c.sqlite3_finalize(statement);
        var uses_index = false;
        while (true) switch (c.sqlite3_step(statement)) {
            c.SQLITE_ROW => {
                const pointer = c.sqlite3_column_text(statement, 3) orelse return error.InvalidQueryPlan;
                const length = c.sqlite3_column_bytes(statement, 3);
                if (length < 0) return error.InvalidQueryPlan;
                const detail = pointer[0..@intCast(length)];
                uses_index = uses_index or std.mem.indexOf(u8, detail, query.index) != null;
                try std.testing.expect(std.mem.indexOf(u8, detail, "TEMP B-TREE") == null);
            },
            c.SQLITE_DONE => break,
            else => return error.InvalidQueryPlan,
        };
        try std.testing.expect(uses_index);
    }
}

test "retry transitions preserve age and settle one exhausted outcome per call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    try exec(storage.database, "PRAGMA foreign_keys=OFF");
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<5097) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
            "SELECT value,value,printf('retry-%d',value),1,1,1,1,1,0," ++
            "CASE WHEN value<=4096 THEN 9223372036854775807 ELSE 1 END FROM sequence",
    );

    const Active = struct {
        const Context = struct {
            operation_ids: *const [1000]u64,
            comparisons: *usize,
        };

        fn contains(context: *const anyopaque, operation_id: u64) bool {
            const active: *const Context = @ptrCast(@alignCast(context));
            for (active.operation_ids) |active_id| {
                active.comparisons.* += 1;
                if (operation_id == active_id) return true;
            }
            return false;
        }
    };
    var active_operations: [1000]u64 = undefined;
    for (&active_operations, 0..) |*operation_id, index| {
        operation_id.* = 4097 + @as(u64, @intCast(index));
    }
    var comparisons: usize = 0;
    const active_context = Active.Context{
        .operation_ids = &active_operations,
        .comparisons = &comparisons,
    };
    const active_filter = ActiveOperationFilter{
        .context = &active_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_operations.len,
    };

    // The simple age index deliberately scans the durable future prefix. This
    // records that real work rather than asserting a synthetic constant bound.
    {
        const statement = try prepare(
            storage.database,
            "SELECT operation_id FROM model_operation INDEXED BY model_operation_retry_age " ++
                "WHERE resolution_code IS NULL AND allowance_used<4 AND retry_due_at_ms<=?1 " ++
                "ORDER BY operation_id LIMIT 1001",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, try readUnixMilliseconds(storage.database));
        var rows: usize = 0;
        while (c.sqlite3_step(statement) == c.SQLITE_ROW) rows += 1;
        try std.testing.expectEqual(@as(usize, 1001), rows);
        const vm_steps = c.sqlite3_stmt_status(statement, c.SQLITE_STMTSTATUS_VM_STEP, 0);
        try std.testing.expect(vm_steps > 4096);
    }

    try std.testing.expectError(
        error.InjectedAttemptCommitFailure,
        storage.tryAdmitNextModelRetry(active_filter, .{ .attempt_before_commit = true }),
    );
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(usize, 501500), comparisons);
    comparisons = 0;
    const admitted = (try storage.tryAdmitNextModelRetry(active_filter, .{})).?;
    try std.testing.expectEqual(@as(u64, 5097), admitted.permit.binding.operation_id);
    try std.testing.expectEqual(@as(u64, 2), admitted.permit.binding.attempt_ordinal);
    try std.testing.expectEqual(@as(usize, 501500), comparisons);

    try exec(storage.database, "DELETE FROM model_operation");
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(6000) UNION ALL SELECT value+1 FROM sequence WHERE value<7001) " ++
            "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id) " ++
            "SELECT value,printf('exhausted-%d',value),1,1,value FROM sequence",
    );
    try exec(
        storage.database,
        "WITH RECURSIVE sequence(value) AS (VALUES(6000) UNION ALL SELECT value+1 FROM sequence WHERE value<7001) " ++
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) " ++
            "SELECT value,value,printf('exhausted-%d',value),1,1,1,4,4,1,0 FROM sequence",
    );
    try exec(storage.database, "PRAGMA foreign_keys=ON");

    var active_exhausted: [1000]u64 = undefined;
    for (&active_exhausted, 0..) |*operation_id, index| operation_id.* = 6000 + @as(u64, @intCast(index));
    var exhausted_comparisons: usize = 0;
    const exhausted_context = Active.Context{
        .operation_ids = &active_exhausted,
        .comparisons = &exhausted_comparisons,
    };
    try std.testing.expect(try storage.recoverOneExhaustedModelAttempt(.{
        .context = &exhausted_context,
        .containsFn = Active.contains,
        .maximum_exclusions = active_exhausted.len,
    }));
    try std.testing.expectEqual(@as(usize, 501500), exhausted_comparisons);
    const outcomes = try prepare(
        storage.database,
        "SELECT operation_id,resolution_code FROM model_operation WHERE operation_id IN (7000,7001) ORDER BY operation_id",
    );
    defer _ = c.sqlite3_finalize(outcomes);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 7000), c.sqlite3_column_int64(outcomes, 0));
    var resolution: protocol.Bounded(96) = .{};
    try readText(outcomes, 1, &resolution);
    try std.testing.expectEqualStrings("retry_exhausted", resolution.slice());
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(outcomes));
    try std.testing.expectEqual(@as(i64, 7001), c.sqlite3_column_int64(outcomes, 0));
    try std.testing.expectEqual(c.SQLITE_NULL, c.sqlite3_column_type(outcomes, 1));
}
