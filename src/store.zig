const std = @import("std");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 5;
pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;
const runnable_probe_sql =
    "SELECT 1 FROM message_admission m INDEXED BY message_admission_pending " ++
    "WHERE m.turn_id IS NULL AND NOT EXISTS(" ++
    " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
    ") LIMIT 1";

pub const Faults = struct {
    content_read: bool = false,
    content_import: bool = false,
    before_commit: bool = false,
    attempt_before_commit: bool = false,
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

pub const AdmissionKind = enum { configure, message };

const StoredAnswer = struct {
    accepted: bool,
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
};

pub const CommandObservation = struct {
    status: enum { absent, accepted, rejected },
    kind: AdmissionKind = .configure,
    target: protocol.Bounded(protocol.max_session_bytes) = .{},
    code: protocol.Bounded(96) = .{},
    revision: u64 = 0,
    created: bool = false,
    message: ?MessageObservation = null,
};

pub const ContentReference = struct {
    length: u64,
    digest: [32]u8,
};

pub const MessageObservation = struct {
    admission_id: ?u64,
    status: enum { queued, processing, failed },
    content: ContentReference,
    turn_id: ?u64 = null,
    operation_id: ?u64 = null,
    attempt_ordinal: ?u64 = null,
    failure: protocol.Bounded(96) = .{},
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

    pub fn suppress(self: *DispatchPermit) void {
        self.available = false;
    }
};

pub const AttemptAdmission = struct {
    permit: DispatchPermit,
    selected_messages: u64,
};

pub const HistoricalSettings = struct {
    model: protocol.Bounded(protocol.max_model_bytes),
    instructions: ContentReference,
    output_schema: ?ContentReference,
    tools_mask: u8,
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

    pub fn nextInstruction(self: *HistoricalView, after_revision: u64) !?HistoricalInstruction {
        std.debug.assert(self.active);
        return self.store.readHistoricalInstruction(self.binding, after_revision);
    }

    pub fn openContent(self: *HistoricalView, reference: ContentReference) !ContentReader {
        std.debug.assert(self.active);
        return self.store.openContent(reference);
    }

    pub fn close(self: *HistoricalView) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

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
};

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
            rollback(self.database);
            self.fenced.store(true, .release);
            return .infrastructure_failure;
        };
    }

    fn configureLocked(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) !ConfigureReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        errdefer rollback(self.database);

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
        const created = current == null;
        if (created and (configuration.workspace.state != .value or configuration.model.state != .value)) {
            return try self.saveConfigurationRejection(command, &digest, .incomplete_initial_configuration, faults);
        }

        var next = current orelse CurrentConfiguration{};
        if (configuration.workspace.state == .value) {
            var canonical_workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
            validateWorkspace(self.io, configuration.workspace.value.slice(), &canonical_workspace) catch {
                return try self.saveConfigurationRejection(command, &digest, .invalid_workspace, faults);
            };
            if (!created and !next.workspace.eql(canonical_workspace.slice())) {
                return try self.saveConfigurationRejection(command, &digest, .workspace_is_immutable, faults);
            }
            next.workspace = canonical_workspace;
        }
        if (configuration.model.state == .value) next.model = configuration.model.value;
        if (configuration.tools.state == .value) {
            next.tools_mask = 0;
            for (configuration.tools.values[0..configuration.tools.count]) |tool| {
                next.tools_mask |= switch (tool) {
                    .bash => 1,
                    .edit => 2,
                };
            }
        }
        if (configuration.permission_mode.state == .value) {
            next.permission_mode = if (configuration.permission_mode.value.eql("ask")) 0 else 1;
        }
        if (!created and next.revision == std.math.maxInt(i64)) {
            return try self.saveConfigurationRejection(command, &digest, .revision_exhausted, faults);
        }
        const command_instructions_id = if (configuration.instructions.state == .value)
            try self.importContent(&configuration.instructions, faults)
        else
            null;
        if (command_instructions_id) |content_id| {
            next.instructions_id = content_id;
        } else if (created) {
            next.instructions_id = try self.importEmptyContent();
        }
        const command_output_schema_id = if (configuration.output_schema.state == .value)
            try self.importContent(&configuration.output_schema, faults)
        else
            null;
        switch (configuration.output_schema.state) {
            .omitted => {},
            .explicit_null => next.output_schema_id = null,
            .value => next.output_schema_id = command_output_schema_id,
        }
        next.revision = if (created) 1 else next.revision + 1;

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
        var answer = StoredAnswer{ .accepted = false };
        try answer.code.set(@tagName(code));
        try self.insertCommand(
            command.key.slice(),
            .configure,
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
            rollback(self.database);
            self.fenced.store(true, .release);
            return .infrastructure_failure;
        };
    }

    fn submitMessageLocked(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) !MessageReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        errdefer rollback(self.database);
        const digest = command.semanticDigest();
        const supplied_content = ContentReference{
            .length = command.text.length,
            .digest = command.text.digest,
        };
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .message or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (existing.accepted) {
                const content_id = existing.primary_content_id orelse return error.CorruptStore;
                const metadata = try self.readContentMetadata(content_id);
                const admission_id = try self.readMessageAdmission(
                    command.key.slice(),
                    command.session.slice(),
                    content_id,
                );
                return .{ .accepted = .{
                    .replayed = true,
                    .admission_id = admission_id,
                    .content = .{ .length = metadata.length, .digest = metadata.digest },
                } };
            }
            const code = std.meta.stringToEnum(MessageRejection, existing.code.slice()) orelse
                return error.CorruptStore;
            return .{ .rejected = .{ .replayed = true, .code = code, .content = supplied_content } };
        }
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
                null,
                null,
                answer,
            );
            if (faults.before_commit) return error.InjectedCommitFailure;
            try exec(self.database, "COMMIT");
            return .{ .rejected = .{ .replayed = false, .code = rejection, .content = supplied_content } };
        }
        const text_id = try self.importContent(&command.text, faults);
        const metadata = try self.readContentMetadata(text_id);
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
            .content = .{ .length = metadata.length, .digest = metadata.digest },
        } };
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
        if (command.kind == .message and command.accepted) {
            const content_id = command.primary_content_id orelse
                return self.fenceReadFailure(error.CorruptStore);
            const metadata = self.readContentMetadata(content_id) catch |err|
                return self.fenceReadFailure(err);
            observation.message = self.readMessageObservation(
                key,
                command.target.slice(),
                content_id,
                .{ .length = metadata.length, .digest = metadata.digest },
            ) catch |err| return self.fenceReadFailure(err);
        }
        return observation;
    }

    fn readMessageObservation(
        self: *Store,
        command_key: []const u8,
        session_ref: []const u8,
        content_id: i64,
        content: ContentReference,
    ) !MessageObservation {
        const statement = try prepare(
            self.database,
            "SELECT m.admission_id,m.turn_id,t.operation_id,t.outcome_code,o.attempt_ordinal " ++
                "FROM message_admission m " ++
                "LEFT JOIN turn t ON t.turn_id=m.turn_id " ++
                "LEFT JOIN model_operation o ON o.operation_id=t.operation_id " ++
                "WHERE m.command_key=?1 AND m.session_ref=?2 AND m.content_id=?3",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, command_key);
        try bindText(statement, 2, session_ref);
        try bindI64(statement, 3, content_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.CorruptStore;
        const admission_id = c.sqlite3_column_int64(statement, 0);
        if (admission_id <= 0) return error.CorruptStore;
        var result = MessageObservation{
            .admission_id = @intCast(admission_id),
            .status = .queued,
            .content = content,
        };
        const turn_id = try readNullablePositiveI64(statement, 1);
        if (turn_id) |actual_turn| {
            result.turn_id = @intCast(actual_turn);
            const operation_id = try readNullablePositiveI64(statement, 2) orelse
                return error.CorruptStore;
            result.operation_id = @intCast(operation_id);
            const attempt = c.sqlite3_column_int64(statement, 4);
            if (attempt <= 0) return error.CorruptStore;
            result.attempt_ordinal = @intCast(attempt);
            if (c.sqlite3_column_type(statement, 3) == c.SQLITE_NULL) {
                result.status = .processing;
            } else {
                try readText(statement, 3, &result.failure);
                if (result.failure.len == 0) return error.CorruptStore;
                result.status = .failed;
            }
        }
        return result;
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
            rollback(self.database);
            if (err != error.InjectedAttemptCommitFailure) self.fenced.store(true, .release);
            return err;
        };
    }

    fn admitNextModelAttemptLocked(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!try self.hasRunnableWorkLocked()) return null;
        try exec(self.database, "BEGIN IMMEDIATE");
        errdefer rollback(self.database);

        const select = try prepare(
            self.database,
            "SELECT m.session_ref,min(m.admission_id),max(m.admission_id),count(*),s.revision " ++
                "FROM message_admission m JOIN session s ON s.session_ref=m.session_ref " ++
                "WHERE m.turn_id IS NULL AND NOT EXISTS(" ++
                " SELECT 1 FROM turn active WHERE active.session_ref=m.session_ref AND active.outcome_code IS NULL" ++
                ") GROUP BY m.session_ref ORDER BY min(m.admission_id) LIMIT 1",
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
        if (first_admission <= 0 or cutoff < first_admission or selected <= 0 or revision <= 0) {
            return error.CorruptStore;
        }

        const turn_id = try nextIdentity(self.database, "turn", "turn_id");
        const operation_id = try nextIdentity(self.database, "model_operation", "operation_id");
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code) " ++
                    "VALUES(?1,?2,?3,?4,?5,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, turn_id);
            try bindText(insert, 2, session_ref.slice());
            try bindI64(insert, 3, first_admission);
            try bindI64(insert, 4, cutoff);
            try bindU64(insert, 5, operation_id);
            try expectDone(insert);
        }
        {
            const bind = try prepare(
                self.database,
                "UPDATE message_admission SET turn_id=?1 WHERE session_ref=?2 AND turn_id IS NULL AND admission_id<=?3",
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
                "INSERT INTO conversation_entry(session_ref,entry_ordinal,turn_id,source_admission_id,content_id) " ++
                    "SELECT ?1,coalesce((SELECT max(entry_ordinal) FROM conversation_entry WHERE session_ref=?1),0) + " ++
                    "row_number() OVER (ORDER BY admission_id),?2,admission_id,content_id " ++
                    "FROM message_admission WHERE turn_id=?2 ORDER BY admission_id",
            );
            defer _ = c.sqlite3_finalize(project);
            try bindText(project, 1, session_ref.slice());
            try bindU64(project, 2, turn_id);
            try expectDone(project);
            if (c.sqlite3_changes(self.database) != selected) return error.ProjectionFailed;
        }
        {
            const insert = try prepare(
                self.database,
                "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff," ++
                    "attempt_ordinal,allowance_used,uncertain,resolution_code) VALUES(?1,?2,?3,?4,?5,1,1,1,NULL)",
            );
            defer _ = c.sqlite3_finalize(insert);
            try bindU64(insert, 1, operation_id);
            try bindU64(insert, 2, turn_id);
            try bindText(insert, 3, session_ref.slice());
            try bindI64(insert, 4, revision);
            try bindI64(insert, 5, cutoff);
            try expectDone(insert);
        }
        if (faults.attempt_before_commit) return error.InjectedAttemptCommitFailure;
        try exec(self.database, "COMMIT");
        const binding = AttemptBinding{
            .turn_id = turn_id,
            .operation_id = operation_id,
            .attempt_ordinal = 1,
        };
        return .{
            .permit = .{ .binding = binding },
            .selected_messages = @intCast(selected),
        };
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
            "SELECT turn_id,attempt_ordinal,resolution_code FROM model_operation WHERE operation_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, binding.operation_id);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or
            c.sqlite3_column_int64(statement, 0) != binding.turn_id or
            c.sqlite3_column_int64(statement, 1) != binding.attempt_ordinal or
            c.sqlite3_column_type(statement, 2) != c.SQLITE_NULL)
        {
            return error.StaleAttemptBinding;
        }
    }

    fn readHistoricalSettings(self: *Store, binding: AttemptBinding) !HistoricalSettings {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.readHistoricalSettingsLocked(binding) catch |err| switch (err) {
            error.StaleAttemptBinding => err,
            else => self.fenceReadFailure(err),
        };
    }

    fn readHistoricalSettingsLocked(self: *Store, binding: AttemptBinding) !HistoricalSettings {
        try self.validateCurrentAttempt(binding);
        const statement = try prepare(
            self.database,
            "SELECT r.model,r.instructions_content_id,r.output_schema_content_id,r.tools_mask " ++
                "FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref " ++
                "AND r.revision=o.settings_revision WHERE o.operation_id=?1",
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
            .instructions = .{ .length = instructions.length, .digest = instructions.digest },
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
            error.StaleAttemptBinding => err,
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
            error.StaleAttemptBinding => err,
            else => self.fenceReadFailure(err),
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
            error.StaleAttemptBinding => return err,
            else => return self.fenceReadFailure(err),
        };
        try handoff(context);
    }

    pub fn settleModelFailure(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        faults: Faults,
    ) !void {
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.settleModelFailureLocked(binding, code, faults) catch |err| {
            rollback(self.database);
            self.fenced.store(true, .release);
            return err;
        };
    }

    fn settleModelFailureLocked(
        self: *Store,
        binding: AttemptBinding,
        code: []const u8,
        faults: Faults,
    ) !void {
        try exec(self.database, "BEGIN IMMEDIATE");
        errdefer rollback(self.database);
        try self.validateCurrentAttempt(binding);
        {
            const statement = try prepare(
                self.database,
                "UPDATE model_operation SET uncertain=0,resolution_code=?2 " ++
                    "WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_ordinal=?3",
            );
            defer _ = c.sqlite3_finalize(statement);
            try bindU64(statement, 1, binding.operation_id);
            try bindText(statement, 2, code);
            try bindU64(statement, 3, binding.attempt_ordinal);
            try expectDone(statement);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        {
            const statement = try prepare(
                self.database,
                "UPDATE turn SET outcome_code=?2 WHERE turn_id=?1 AND operation_id=?3 AND outcome_code IS NULL",
            );
            defer _ = c.sqlite3_finalize(statement);
            try bindU64(statement, 1, binding.turn_id);
            try bindText(statement, 2, code);
            try bindU64(statement, 3, binding.operation_id);
            try expectDone(statement);
            if (c.sqlite3_changes(self.database) != 1) return error.StaleAttemptBinding;
        }
        if (faults.before_commit) return error.InjectedCommitFailure;
        try exec(self.database, "COMMIT");
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentReader {
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

    const ExistingCommand = struct {
        kind: AdmissionKind,
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
        const kind: AdmissionKind = switch (kind_value) {
            1 => .configure,
            2 => .message,
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
        const statement = try prepare(self.database, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND turn_id IS NULL");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.MessageAdmissionReadFailed;
        const count = c.sqlite3_column_int64(statement, 0);
        if (count < 0) return error.CorruptStore;
        return @intCast(count);
    }

    fn readSession(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
        const statement = try prepare(self.database, "SELECT workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision FROM session WHERE session_ref=?1");
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
        return current;
    }

    fn insertSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "INSERT INTO session(session_ref,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id,revision) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)");
        defer _ = c.sqlite3_finalize(statement);
        try bindCurrent(statement, session_ref, current);
        try expectDone(statement);
    }

    fn updateSession(self: *Store, session_ref: []const u8, current: *const CurrentConfiguration) !void {
        const statement = try prepare(self.database, "UPDATE session SET workspace=?2,model=?3,instructions_content_id=?4,tools_mask=?5,permission_mode=?6,output_schema_content_id=?7,revision=?8 WHERE session_ref=?1");
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
        kind: AdmissionKind,
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
            if (try source.length(self.io) != content.length) return error.ContentChanged;
        } else if (content.length != 0 or
            !std.mem.eql(u8, &protocol.contentDigest(""), &content.digest))
        {
            return error.MissingContentCustody;
        }
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2");
        defer _ = c.sqlite3_finalize(find);
        try bindBlob(find, 1, &content.digest);
        try bindU64(find, 2, content.length);
        const find_result = c.sqlite3_step(find);
        if (find_result == c.SQLITE_ROW) {
            const content_id = c.sqlite3_column_int64(find, 0);
            if (content_id <= 0) return error.CorruptStore;
            if (content.file) |source| {
                try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
            }
            return content_id;
        }
        if (find_result != c.SQLITE_DONE) return error.ContentReadFailed;

        const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload) VALUES(?1,?2,zeroblob(?2))");
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, &content.digest);
        try bindU64(insert, 2, content.length);
        try expectDone(insert);
        const content_id = c.sqlite3_last_insert_rowid(self.database);
        if (content_id <= 0) return error.ContentWriteFailed;

        if (content.length == 0) {
            if (content.file) |source| {
                try verifyExternalContent(self.io, source, content.length, &content.digest, null, faults);
            }
            return content_id;
        }
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        const file = content.file orelse return error.MissingContentCustody;
        // Verify the exact bytes copied while the row is still uncommitted.
        // The caller rolls back the whole transaction if verification fails.
        try verifyExternalContent(self.io, file, content.length, &content.digest, blob, faults);
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
        const statement = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2");
        defer _ = c.sqlite3_finalize(statement);
        try bindBlob(statement, 1, &reference.digest);
        try bindU64(statement, 2, reference.length);
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
    destination: ?*c.sqlite3_blob,
    faults: Faults,
) !void {
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    var hash = protocol.contentHasher();
    while (offset < expected_length) {
        const wanted: usize = @intCast(@min(expected_length - offset, buffer.len));
        const count = try file.readPositionalAll(io, buffer[0..wanted], offset);
        if (count != wanted) return error.ContentReadFailed;
        if (faults.content_read) return error.InjectedContentReadFailure;
        hash.update(buffer[0..count]);
        if (destination) |blob| {
            if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
            if (c.sqlite3_blob_write(blob, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
            if (faults.content_import) return error.InjectedContentImportFailure;
        }
        offset += count;
    }
    if (try file.length(io) != expected_length) return error.ContentChanged;
    if (!std.mem.eql(u8, &hash.finalResult(), expected_digest)) return error.ContentChanged;
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
        \\ UNIQUE(digest,byte_length)
        \\) STRICT;
        \\CREATE TABLE session(
        \\ session_ref TEXT PRIMARY KEY CHECK(length(CAST(session_ref AS BLOB)) BETWEEN 1 AND 128),
        \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
        \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND 3),
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ revision INTEGER NOT NULL CHECK(revision>0)
        \\) STRICT;
        \\CREATE TABLE core_command(
        \\ command_key TEXT PRIMARY KEY CHECK(length(CAST(command_key AS BLOB))<=128),
        \\ kind INTEGER NOT NULL CHECK(kind IN (1,2)),
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
        \\ operation_id INTEGER NOT NULL UNIQUE,
        \\ outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96)
        \\) STRICT;
        \\CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
        \\CREATE TABLE model_operation(
        \\ operation_id INTEGER PRIMARY KEY CHECK(operation_id>0),
        \\ turn_id INTEGER NOT NULL UNIQUE REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ session_ref TEXT NOT NULL,
        \\ settings_revision INTEGER NOT NULL CHECK(settings_revision>0),
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ allowance_used INTEGER NOT NULL CHECK(allowance_used BETWEEN 1 AND 4),
        \\ uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
        \\ FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK((resolution_code IS NULL AND uncertain=1) OR (resolution_code IS NOT NULL AND uncertain=0))
        \\) STRICT;
        \\CREATE TABLE conversation_entry(
        \\ session_ref TEXT NOT NULL,
        \\ entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
        \\ source_admission_id INTEGER NOT NULL UNIQUE REFERENCES message_admission(admission_id),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,entry_ordinal)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
        \\CREATE INDEX message_admission_pending ON message_admission(admission_id,session_ref) WHERE turn_id IS NULL;
        \\CREATE INDEX model_operation_runnable ON model_operation(resolution_code,operation_id);
    );
    try exec(database, "PRAGMA application_id=1280591409");
    try exec(database, "PRAGMA user_version=5");
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
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','model_operation','conversation_entry')) OR " ++
                "(type='index' AND ((sql IS NULL AND tbl_name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','turn','model_operation','conversation_entry')) OR " ++
                "(sql IS NOT NULL AND name NOT IN ('message_admission_session_order','message_admission_pending','turn_one_active_per_session','model_operation_runnable')))) OR " ++
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

fn bindCurrent(statement: *c.sqlite3_stmt, session_ref: []const u8, current: *const CurrentConfiguration) !void {
    try bindText(statement, 1, session_ref);
    try bindText(statement, 2, current.workspace.slice());
    try bindText(statement, 3, current.model.slice());
    try bindNullableI64(statement, 4, current.instructions_id);
    try bindI64(statement, 5, current.tools_mask);
    try bindI64(statement, 6, current.permission_mode);
    try bindNullableI64(statement, 7, current.output_schema_id);
    try bindU64(statement, 8, current.revision);
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

fn testingContent(tmp: *std.testing.TmpDir, name: []const u8, fill: u8, length: usize) !protocol.ContentField {
    const file = try tmp.dir.createFile(std.testing.io, name, .{ .read = true });
    errdefer file.close(std.testing.io);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    @memset(&buffer, fill);
    var remaining = length;
    var hash = protocol.contentHasher();
    while (remaining != 0) {
        const count = @min(remaining, buffer.len);
        try file.writeStreamingAll(std.testing.io, buffer[0..count]);
        hash.update(buffer[0..count]);
        remaining -= count;
    }
    try file.sync(std.testing.io);
    return .{
        .state = .value,
        .file = file,
        .length = length,
        .digest = hash.finalResult(),
    };
}

fn queryU64(database: *c.sqlite3, sql: [:0]const u8) !u64 {
    const statement = try prepare(database, sql);
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.QueryFailed;
    const value = c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
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
    try std.testing.expectEqual(first_reply.accepted.admission_id, observed.message.?.admission_id.?);
    try std.testing.expect(observed.message.?.status == .queued);

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
    try std.testing.expectEqual(first_reply.accepted.admission_id, restarted.message.?.admission_id.?);
    try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSession("direct/messages")).pending_messages);
}

test "message rejections replay before current Session checks without retained input" {
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
    try std.testing.expect(observed.message == null);
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

test "external content identity is verified before canonical commit" {
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

test "content verification failure rolls back new imports and deduplicated inputs" {
    const Case = enum { digest, short, long, empty_digest, read_failure };
    inline for (.{ false, true }) |deduplicated| {
        inline for (std.meta.tags(Case)) |case| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage = try testingStore(&tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const length: usize = if (case == .empty_digest) 0 else protocol.content_window_bytes * 2 + 17;

            var initial = try completeConfiguration("initial", "direct/import", workspace, "model-a");
            initial.configuration.instructions = try testingContent(&tmp, "original", 'a', length);
            defer initial.removeTemporaryContent(std.testing.io) catch unreachable;
            if (deduplicated) try std.testing.expect(storage.configure(&initial, .{}) == .accepted);
            const content_count = try queryU64(storage.database, "SELECT count(*) FROM content");
            const command_count = try queryU64(storage.database, "SELECT count(*) FROM core_command");
            const revision_count = try queryU64(storage.database, "SELECT count(*) FROM session_revision");

            var command = try completeConfiguration("invalid", "direct/import", workspace, "model-b");
            command.configuration.instructions = try testingContent(&tmp, "invalid", 'b', length);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            const content = &command.configuration.instructions;
            switch (case) {
                .digest => {
                    // A dedup hit must check supplied bytes, not trust the claimed digest.
                    content.digest = initial.configuration.instructions.digest;
                },
                .short => content.length += 1,
                .long => content.length -= 1,
                .empty_digest => content.digest[0] ^= 1,
                .read_failure => {
                    if (deduplicated) content.digest = initial.configuration.instructions.digest;
                },
            }
            try std.testing.expect(storage.configure(&command, .{ .content_read = case == .read_failure }) == .infrastructure_failure);
            try std.testing.expectError(error.StoreFenced, storage.observeCommand("invalid"));
            try std.testing.expectEqual(content_count, try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(command_count, try queryU64(storage.database, "SELECT count(*) FROM core_command"));
            try std.testing.expectEqual(revision_count, try queryU64(storage.database, "SELECT count(*) FROM session_revision"));
            try std.testing.expectEqual(@as(u64, if (deduplicated) 1 else 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        }
    }
}

test "content import reads once and rolls back sources that change during reading" {
    const Probe = struct {
        const Change = enum { none, truncate, grow };
        var change: Change = .none;
        var bytes_read: usize = 0;

        fn read(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const count = try std.testing.io.vtable.fileReadPositional(userdata, file, data, offset);
            bytes_read += count;
            if (offset == 0) switch (change) {
                .none => {},
                .truncate => file.setLength(std.testing.io, count) catch return error.Unexpected,
                .grow => file.setLength(std.testing.io, protocol.content_window_bytes * 2 + 18) catch return error.Unexpected,
            };
            return count;
        }
    };
    for (std.meta.tags(Probe.Change)) |change| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var vtable = std.testing.io.vtable.*;
        vtable.fileReadPositional = Probe.read;
        storage.io.vtable = &vtable;
        Probe.change = change;
        Probe.bytes_read = 0;

        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
        var command = try completeConfiguration("read-probe", "direct/import", workspace, "model-a");
        const length = protocol.content_window_bytes * 2 + 17;
        command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        if (change == .none) {
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
            try std.testing.expectEqual(length, Probe.bytes_read);
            Probe.bytes_read = 0;
            try command.key.set("deduplicated");
            try std.testing.expect(storage.configure(&command, .{}) == .accepted);
            try std.testing.expectEqual(length, Probe.bytes_read);
        } else {
            try std.testing.expect(storage.configure(&command, .{}) == .infrastructure_failure);
            try std.testing.expectError(error.StoreFenced, storage.observeCommand("read-probe"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM content"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM core_command"));
            try std.testing.expectEqual(@as(u64, 0), try queryU64(storage.database, "SELECT count(*) FROM session"));
        }
    }
}

test "multiwindow content import and deduplication preserve all bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("first", "direct/import", workspace, "model-a");
    const length = protocol.content_window_bytes * 2 + 17;
    command.configuration.instructions = try testingContent(&tmp, "source", 'q', length);
    defer command.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    try command.key.set("second");
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    const observation = try storage.inspectSession("direct/import");
    try std.testing.expectEqual(@as(u64, 2), observation.revision);
    var reader = try storage.openContent(observation.instructions);
    defer reader.close();
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < length) {
        const count = try reader.read(offset, buffer[0..@min(buffer.len, length - offset)]);
        try std.testing.expect(count != 0);
        for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 'q'), byte);
        offset += count;
    }
    try std.testing.expectEqual(length, offset);
}

test "definite rejections retain decisions without retaining payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage = try testingStore(&tmp, std.testing.io);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var initial = try completeConfiguration("initial", "direct/exhausted", workspace, "model-a");
    try std.testing.expect(storage.configure(&initial, .{}) == .accepted);
    try exec(storage.database, "UPDATE session SET revision=9223372036854775807 WHERE session_ref='direct/exhausted'");

    var unknown_message: protocol.MessageCommand = .{};
    try unknown_message.key.set("unknown-message");
    try unknown_message.session.set("direct/unknown");
    unknown_message.text = try testingContent(&tmp, "unknown-message", 'm', 64 * 1024);
    defer unknown_message.removeTemporaryContent(std.testing.io) catch unreachable;
    const unknown_reply = storage.submitMessage(&unknown_message, .{});
    try std.testing.expect(unknown_reply == .rejected);
    try std.testing.expectEqual(MessageRejection.unknown_session, unknown_reply.rejected.code);

    var incomplete: protocol.ConfigureCommand = .{};
    try incomplete.key.set("incomplete");
    try incomplete.session.set("direct/incomplete");
    incomplete.configuration.instructions = try testingContent(&tmp, "incomplete", 'i', 64 * 1024);
    defer incomplete.removeTemporaryContent(std.testing.io) catch unreachable;
    const incomplete_reply = storage.configure(&incomplete, .{});
    try std.testing.expect(incomplete_reply == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.incomplete_initial_configuration, incomplete_reply.rejected.code);

    var exhausted: protocol.ConfigureCommand = .{};
    try exhausted.key.set("exhausted");
    try exhausted.session.set("direct/exhausted");
    exhausted.configuration.instructions = try testingContent(&tmp, "exhausted", 'e', 64 * 1024);
    defer exhausted.removeTemporaryContent(std.testing.io) catch unreachable;
    const exhausted_reply = storage.configure(&exhausted, .{});
    try std.testing.expect(exhausted_reply == .rejected);
    try std.testing.expectEqual(ConfigurationRejection.revision_exhausted, exhausted_reply.rejected.code);

    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(
        storage.database,
        "SELECT count(*) FROM core_command WHERE accepted=0 AND (primary_content_id IS NOT NULL OR secondary_content_id IS NOT NULL)",
    ));

    try storage.close();
    storage = try testingStore(&tmp, std.testing.io);
    try std.testing.expect(storage.submitMessage(&unknown_message, .{}).rejected.replayed);
    try std.testing.expect(storage.configure(&incomplete, .{}).rejected.replayed);
    try std.testing.expect(storage.configure(&exhausted, .{}).rejected.replayed);

    var changed = unknown_message;
    changed.text.digest[0] ^= 1;
    try std.testing.expect(storage.submitMessage(&changed, .{}) == .conflict);
    var retargeted = incomplete;
    try retargeted.session.set("direct/other");
    try std.testing.expect(storage.configure(&retargeted, .{}) == .conflict);
    var changed_kind: protocol.MessageCommand = .{};
    try changed_kind.key.set("incomplete");
    try changed_kind.session.set("direct/incomplete");
    changed_kind.text = unknown_message.text;
    try std.testing.expect(storage.submitMessage(&changed_kind, .{}) == .conflict);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(storage.database, "SELECT count(*) FROM content"));
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
    try std.testing.expect((try storage.observeCommand("dispatch-1")).message.?.status == .queued);

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expectEqual(@as(u64, 2), admitted.selected_messages);
    const binding = try admitted.permit.consume();
    try std.testing.expectError(error.DispatchPermitConsumed, admitted.permit.consume());
    try std.testing.expect((try storage.observeCommand("dispatch-1")).message.?.status == .processing);
    try std.testing.expectEqual(
        binding.operation_id,
        (try storage.observeCommand("dispatch-2")).message.?.operation_id.?,
    );

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
    try std.testing.expect(storage.configure(&update, .{}) == .accepted);

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

    try storage.settleModelFailure(binding, "provider_http_422", .{});
    const failed = (try storage.observeCommand("dispatch-1")).message.?;
    try std.testing.expect(failed.status == .failed);
    try std.testing.expectEqualStrings("provider_http_422", failed.failure.slice());
    try std.testing.expect((try storage.observeCommand("dispatch-3")).message.?.status == .queued);
    try std.testing.expectEqual(@as(u64, 1), (try storage.inspectSession("direct/dispatch")).pending_messages);

    const later = (try storage.admitNextModelAttempt(.{})).?;
    var later_view = try storage.openHistoricalView(later.permit.binding);
    defer later_view.close();
    try std.testing.expectEqualStrings("model-b", (try later_view.settings()).model.slice());
}

test "saved model failure is atomic and retains consumed uncertainty on save fault" {
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
            storage.settleModelFailure(binding, "request_preparation_failed", .{ .before_commit = true }),
        );
        try storage.close();
    }
    {
        var storage = try testingStore(&tmp, std.testing.io);
        defer storage.close() catch unreachable;
        const observation = (try storage.observeCommand("failure-message")).message.?;
        try std.testing.expect(observation.status == .processing);
        try std.testing.expectEqual(@as(u64, 1), observation.attempt_ordinal.?);
        try std.testing.expect((try storage.admitNextModelAttempt(.{})) == null);
    }
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
    try std.testing.expectError(error.StoreFenced, storage.settleModelFailure(binding, "request_preparation_failed", .{}));
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
