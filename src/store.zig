const std = @import("std");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 1;
pub const sqlite_heap_bytes: u64 = 16 * 1024 * 1024;

pub const Faults = struct {
    content_read: bool = false,
    before_commit: bool = false,
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
    model_processing_unavailable_in_issue_170,
};

pub const MessageReply = union(enum) {
    rejected: struct {
        replayed: bool,
        code: MessageRejection,
    },
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
};

pub const SessionObservation = struct {
    found: bool = false,
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    revision: u64 = 0,
    tools_mask: u8 = 0,
    permission_mode: protocol.Bounded(16) = .{},
    instructions_length: u64 = 0,
    instructions_digest: [32]u8 = [_]u8{0} ** 32,
    output_schema_present: bool = false,
    output_schema_length: u64 = 0,
    output_schema_digest: [32]u8 = [_]u8{0} ** 32,
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
            !try validateJsonFile(self.io, configuration.output_schema.path.slice()))
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
        if (!created and next.revision == std.math.maxInt(i64)) {
            return try self.saveConfigurationRejection(command, &digest, .revision_exhausted, faults);
        }
        next.revision = if (created) 1 else next.revision + 1;

        if (created) {
            try self.insertSession(command.session.slice(), &next);
        } else {
            try self.updateSession(command.session.slice(), &next);
        }
        try self.insertRevision(command.session.slice(), command.key.slice(), &next);
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

    pub fn rejectMessage(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) MessageReply {
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fenced.load(.acquire)) return .infrastructure_failure;
        return self.rejectMessageLocked(command, faults) catch {
            rollback(self.database);
            self.fenced.store(true, .release);
            return .infrastructure_failure;
        };
    }

    fn rejectMessageLocked(
        self: *Store,
        command: *const protocol.MessageCommand,
        faults: Faults,
    ) !MessageReply {
        try exec(self.database, "BEGIN IMMEDIATE");
        errdefer rollback(self.database);
        const digest = command.semanticDigest();
        if (try self.readExistingCommand(command.key.slice())) |existing| {
            try exec(self.database, "ROLLBACK");
            if (existing.kind != .message or
                !std.mem.eql(u8, existing.target.slice(), command.session.slice()) or
                !std.mem.eql(u8, &existing.digest, &digest)) return .conflict;
            if (existing.accepted) return error.CorruptStore;
            const code = std.meta.stringToEnum(MessageRejection, existing.code.slice()) orelse return error.CorruptStore;
            return .{ .rejected = .{ .replayed = true, .code = code } };
        }
        var answer = StoredAnswer{ .accepted = false };
        const code: MessageRejection = if (command.session.len == 0)
            .invalid_session_reference
        else if (try self.readSession(command.session.slice()) == null)
            .unknown_session
        else
            .model_processing_unavailable_in_issue_170;
        const text_id = try self.importContent(&command.text, faults);
        try answer.code.set(@tagName(code));
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
        return .{ .rejected = .{ .replayed = false, .code = code } };
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const existing = try self.readExistingCommand(key) orelse return .{ .status = .absent };
        var observation = CommandObservation{
            .status = if (existing.accepted) .accepted else .rejected,
            .kind = existing.kind,
            .revision = existing.revision,
            .created = existing.created,
        };
        observation.target = existing.target;
        observation.code = existing.code;
        return observation;
    }

    pub fn inspectSession(self: *Store, session_ref: []const u8) !SessionObservation {
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = try self.readSession(session_ref) orelse return .{};
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
            const metadata = try self.readContentMetadata(content_id);
            observation.instructions_length = metadata.length;
            observation.instructions_digest = metadata.digest;
        }
        if (current.output_schema_id) |content_id| {
            const metadata = try self.readContentMetadata(content_id);
            observation.output_schema_present = true;
            observation.output_schema_length = metadata.length;
            observation.output_schema_digest = metadata.digest;
        }
        return observation;
    }

    pub fn readContentRange(
        self: *Store,
        content_id: i64,
        start: u64,
        destination: []u8,
    ) !usize {
        if (destination.len > protocol.content_window_bytes) return error.WindowTooLarge;
        if (self.fenced.load(.acquire)) return error.StoreFenced;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const metadata = try self.readContentMetadata(content_id);
        if (start > metadata.length) return error.RangeOutOfBounds;
        const wanted: u64 = @min(destination.len, metadata.length - start);
        if (wanted == 0) return 0;
        if (start > std.math.maxInt(c_int)) return error.RangeOutOfBounds;
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 0, &blob) != c.SQLITE_OK) {
            return error.ContentReadFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        if (c.sqlite3_blob_read(blob, destination.ptr, @intCast(wanted), @intCast(start)) != c.SQLITE_OK) {
            return error.ContentReadFailed;
        }
        return @intCast(wanted);
    }

    const ExistingCommand = struct {
        kind: AdmissionKind,
        target: protocol.Bounded(protocol.max_session_bytes),
        digest: [32]u8,
        accepted: bool,
        code: protocol.Bounded(96),
        revision: u64,
        created: bool,
    };

    fn readExistingCommand(self: *Store, key: []const u8) !?ExistingCommand {
        const statement = try prepare(self.database, "SELECT kind,target,input_digest,accepted,code,revision,created FROM core_command WHERE command_key=?1");
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
        return .{
            .kind = kind,
            .target = target,
            .digest = digest,
            .accepted = accepted_value == 1,
            .code = code,
            .revision = @intCast(revision_value),
            .created = created_value == 1,
        };
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
    ) !void {
        const statement = try prepare(self.database, "INSERT INTO session_revision(session_ref,revision,command_key,workspace,model,instructions_content_id,tools_mask,permission_mode,output_schema_content_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, session_ref);
        try bindU64(statement, 2, current.revision);
        try bindText(statement, 3, command_key);
        try bindText(statement, 4, current.workspace.slice());
        try bindText(statement, 5, current.model.slice());
        try bindNullableI64(statement, 6, current.instructions_id);
        try bindI64(statement, 7, current.tools_mask);
        try bindI64(statement, 8, current.permission_mode);
        try bindNullableI64(statement, 9, current.output_schema_id);
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

    fn importEmptyContent(self: *Store) !i64 {
        var empty: protocol.ContentField = .{ .state = .value };
        empty.digest = protocol.contentDigest("");
        return self.importContent(&empty, .{});
    }

    fn importContent(self: *Store, content: *const protocol.ContentField, faults: Faults) !i64 {
        std.debug.assert(content.state == .value);
        const find = try prepare(self.database, "SELECT content_id FROM content WHERE digest=?1 AND byte_length=?2");
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

        const insert = try prepare(self.database, "INSERT INTO content(digest,byte_length,payload) VALUES(?1,?2,zeroblob(?2))");
        defer _ = c.sqlite3_finalize(insert);
        try bindBlob(insert, 1, &content.digest);
        try bindU64(insert, 2, content.length);
        try expectDone(insert);
        const content_id = c.sqlite3_last_insert_rowid(self.database);
        if (content_id <= 0) return error.ContentWriteFailed;

        if (content.length == 0) {
            if (faults.content_read) return error.InjectedContentReadFailure;
            if (!std.mem.eql(u8, &protocol.contentDigest(""), &content.digest)) return error.ContentChanged;
            return content_id;
        }
        var blob: ?*c.sqlite3_blob = null;
        if (c.sqlite3_blob_open(self.database, "main", "content", "payload", content_id, 1, &blob) != c.SQLITE_OK) {
            return error.ContentWriteFailed;
        }
        defer _ = c.sqlite3_blob_close(blob);
        var file = try std.Io.Dir.openFileAbsolute(self.io, content.path.slice(), .{});
        defer file.close(self.io);
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        var hash = protocol.contentHasher();
        while (offset < content.length) {
            const wanted: usize = @intCast(@min(content.length - offset, buffer.len));
            const count = try file.readStreaming(self.io, &.{buffer[0..wanted]});
            if (count != wanted) return error.ContentReadFailed;
            if (faults.content_read) return error.InjectedContentReadFailure;
            hash.update(buffer[0..count]);
            if (offset > std.math.maxInt(c_int)) return error.ContentTooLarge;
            if (c.sqlite3_blob_write(blob, buffer[0..count].ptr, @intCast(count), @intCast(offset)) != c.SQLITE_OK) {
                return error.ContentWriteFailed;
            }
            offset += count;
        }
        var trailing: [1]u8 = undefined;
        const trailing_count = file.readStreaming(self.io, &.{&trailing}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (trailing_count != 0) return error.ContentChanged;
        if (!std.mem.eql(u8, &hash.finalResult(), &content.digest)) return error.ContentChanged;
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

fn validateJsonFile(io: std.Io, path: []const u8) !bool {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var read_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
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
        \\ tools_mask INTEGER NOT NULL,
        \\ permission_mode INTEGER NOT NULL,
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ PRIMARY KEY(session_ref,revision)
        \\) STRICT, WITHOUT ROWID;
    );
    try exec(database, "PRAGMA application_id=1280591409");
    try exec(database, "PRAGMA user_version=1");
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
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision')) OR " ++
                "(type='index' AND (sql IS NOT NULL OR tbl_name NOT IN ('store_meta','content','session','core_command','session_revision'))) OR " ++
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

fn canonicalCwd(io: std.Io, buffer: []u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer directory.close(io);
    const length = try directory.realPath(io, buffer);
    return buffer[0..length];
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
    try std.testing.expectEqual(@as(u64, 0), observation.instructions_length);
    var empty_digest: [32]u8 = undefined;
    empty_digest = protocol.contentDigest("");
    try std.testing.expectEqualSlices(u8, &empty_digest, &observation.instructions_digest);
    try std.testing.expect(!observation.output_schema_present);

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
