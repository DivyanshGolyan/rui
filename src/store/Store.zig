//! The Store type and its public entry points, then what the domain files share
//! and nothing outside src/store/ reaches: locking and fencing, statement execution,
//! identities and traces. The facade re-exports only the Store type and its value types.

const std = @import("std");
const attempt = @import("../attempt.zig");
const platform = @import("../platform.zig");
const protocol = @import("../protocol.zig");
const retry_policy = @import("../retry_policy.zig");
const change_ring = @import("../change_ring.zig");
const action_domain = @import("domain/action.zig");
const command_domain = @import("domain/command.zig");
const configuration_domain = @import("domain/configuration.zig");
const content_domain = @import("domain/content.zig");
const historical_domain = @import("domain/historical.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const reads_domain = @import("domain/reads.zig");
const report_domain = @import("domain/report.zig");
const rsql = @import("rsql.zig");
const Access = @import("access.zig").Access;
const ReadAccess = reads_domain.ReadAccess;
const store_schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const ActionAttemptAdmission = action_domain.ActionAttemptAdmission;
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionResolutionCode = action_domain.ActionResolutionCode;
const ActionSettlement = action_domain.ActionSettlement;
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const AttemptAdmission = model_admission_domain.AttemptAdmission;
const BashExecutionInput = action_domain.BashExecutionInput;
const CommandObservation = command_domain.CommandObservation;
const ConfigureReply = configuration_domain.ConfigureReply;
const ContentBlob = @import("access.zig").ContentBlob;
const Found = @import("access.zig").Found;
const ContentLocation = content_domain.ContentLocation;
const ContentReference = content_domain.ContentReference;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const HistoricalView = historical_domain.HistoricalView;
const MessageReply = command_domain.MessageReply;
const ModelAdmissionKind = model_admission_domain.ModelAdmissionKind;
const ModelFailure = model_settlement_domain.ModelFailure;
const ModelFailureClass = model_settlement_domain.ModelFailureClass;
const ModelInterruptionReply = command_domain.ModelInterruptionReply;
const ModelOperationKind = historical_domain.ModelOperationKind;
const PermissionDecisionReply = command_domain.PermissionDecisionReply;
const PrefixSeal = historical_domain.PrefixSeal;
const PublicConversationPage = reads_domain.PublicConversationPage;
const SessionListOptions = report_domain.SessionListOptions;
const SessionObservation = reads_domain.SessionObservation;
const SessionReport = report_domain.SessionReport;
const SessionReportCapture = report_domain.SessionReportCapture;
const SessionReportOptions = report_domain.SessionReportOptions;
const SessionStopReply = command_domain.SessionStopReply;
const StatementCache = sqlite.StatementCache;
const SupersedingControl = action_domain.SupersedingControl;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;
const sqlite_heap_bytes = sqlite.sqlite_heap_bytes;

pub const Store = struct {
    io: std.Io,
    database: *c.sqlite3,
    selector: protocol.Bounded(protocol.max_store_bytes),
    mutex: std.Io.Mutex = .init,
    fenced: std.atomic.Value(bool) = .init(false),
    /// Advances before `release` of any entry point that changed rows, so
    /// after every successful COMMIT. An unchanged value proves no canonical
    /// fact changed since it was read; a rolled-back change also advances it.
    commit_generation: std.atomic.Value(u64) = .init(0),
    /// The Sessions the current entry point changed. Every writer touches
    /// each Session whose rows it changes, and `release` records them under
    /// the generation the commit advances to.
    touched: change_ring.Touched = .{},
    /// Which Sessions changed at recent generations: Session listing's
    /// `since` hint, guarded by the mutex. Owned: `openWithOptions` maps it
    /// and `close` unmaps it.
    changes: *change_ring.Ring,
    /// This opening's identity: a `since` token from any other opening
    /// names generations this one never counted.
    instance: [16]u8 = undefined,
    statements: StatementCache = .{},
    /// The Host hands out every id and sequence value, and each
    /// transaction's second; see `HostValues`.
    ids: HostValues,
    /// The labels of the providers whose Sessions get model Attempts, each
    /// between commas, fixed at open.
    served: protocol.Routes = protocol.routesAll(.unserved),
    // Entry.release closes the read transaction before unlocking, including
    // errors and yielded historical scans. Logical readers cannot pin the WAL.
    read_blob: ContentBlob = .{},
    /// Which use holds the out-of-line scratch in this entry point.
    scratch_use: ScratchUse = .none,
    // Source-level proof only: no counters/storage in the production Store.
    testing_content_work: if (@import("builtin").is_test) struct { read: std.atomic.Value(u64) = .init(0), closes: std.atomic.Value(u64) = .init(0), blob: std.atomic.Value(u64) = .init(0) } else void = if (@import("builtin").is_test) .{} else {},

    /// Whether nothing changed since `since` on this opening: atomics only,
    /// no lock. Never while fenced, so a read reports the failure.
    pub fn notModified(self: *const Store, since: change_ring.Token) bool {
        return !self.isFenced() and std.mem.eql(u8, &since.instance, &self.instance) and
            since.generation == self.commit_generation.load(.acquire);
    }

    pub fn open(self: *Store, io: std.Io, database_path: []const u8, selector: []const u8) !void {
        return self.openWithOptions(io, database_path, selector, .{});
    }

    pub fn inspectSessionForTesting(self: *Store, session_ref: []const u8) !SessionObservation {
        var observation: SessionObservation = undefined;
        try self.inspectSession(session_ref, &observation);
        return observation;
    }

    /// Test fixture for a historical producing binding unavailable through
    /// today's immutable Session configuration admission. Requires a newer
    /// current revision, leaving that revision and its frozen inputs intact.
    pub fn prefixSealForTesting(self: *Store, binding: AttemptBinding) !?PrefixSeal {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        var access = historical_domain.ReadAccess.within(self);
        return historical_domain.prefixSealOf(&access, binding);
    }

    pub fn setPrefixSealForTesting(self: *Store, binding: AttemptBinding, seal: *const PrefixSeal) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        const statement = try cached(self, "UPDATE session SET prefix_seal=?2 WHERE session_ref=(SELECT session_ref FROM model_operation WHERE operation_id=?1)");
        defer sqlite.resetCached(statement);
        try sqlite.bindU64(statement, 1, binding.operation_id);
        const bytes = seal.encode();
        try sqlite.bindBlob(statement, 2, &bytes);
        try sqlite.expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingRevision;
    }

    pub fn setHistoricalModelForTesting(self: *Store, binding: AttemptBinding, model: []const u8) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        var bounded: protocol.Bounded(protocol.max_model_bytes) = .{};
        try bounded.set(model);
        if (bounded.len == 0) return error.InvalidModel;
        const statement = try cached(self, "UPDATE session_revision SET model=?2 " ++
            "WHERE (session_ref,revision)=(SELECT o.session_ref,o.settings_revision FROM model_operation o " ++
            "JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1 AND o.settings_revision<s.revision)");
        defer sqlite.resetCached(statement);
        try sqlite.bindU64(statement, 1, binding.operation_id);
        try sqlite.bindText(statement, 2, model);
        try sqlite.expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingRevision;
    }

    /// Flips the first byte of the provider bag of the `binding` Operation's
    /// first output item, keeping its recorded length and digest, as on-disk
    /// damage would.
    pub fn damageOutputBagForTesting(self: *Store, binding: AttemptBinding) !void {
        if (!@import("builtin").is_test) @compileError("test-only Store fixture");
        const statement = try cached(self, "UPDATE content SET payload=CAST(CASE WHEN substr(CAST(payload AS TEXT),1,1)='X' THEN 'Y' ELSE 'X' END || substr(CAST(payload AS TEXT),2) AS BLOB) " ++
            "WHERE content_id=(SELECT extras_content_id FROM model_output_item WHERE operation_id=?1 AND item_ordinal=0)");
        defer sqlite.resetCached(statement);
        try sqlite.bindU64(statement, 1, binding.operation_id);
        try sqlite.expectDone(statement);
        if (c.sqlite3_changes(self.database) != 1) return error.InvalidTestingOutput;
    }

    /// Opens in place: the Host holds exactly one Store, never a copy. It
    /// runs once per process; noinline keeps its path buffers off the
    /// caller's frame, which lives as long as the Host.
    pub noinline fn openWithOptions(
        self: *Store,
        io: std.Io,
        database_path: []const u8,
        selector: []const u8,
        options: OpenOptions,
    ) !void {
        errdefer self.* = undefined;
        if (options.cache_kib == 0 or options.cache_kib > 4096) return error.InvalidSqliteCacheSize;
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

        var path_buffer: [platform.max_database_path_bytes + 1:0]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{database_path}, 0);
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
        // The handle may still be null on later failure paths; never unwrap
        // it while unwinding an open failure.
        errdefer {
            if (database) |db| _ = c.sqlite3_close(db);
        }

        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LENGTH, @intCast(protocol.max_sqlite_content_bytes + 4096));
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_SQL_LENGTH, 16 * 1024);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COLUMN, 32);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_EXPR_DEPTH, protocol.max_json_depth);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_COMPOUND_SELECT, 4);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_FUNCTION_ARG, 16);
        // 65: a settlement's wide duplicate read binds its Operation and 64 digests as
        // ?1..?65 (`model_settlement.batch_items`); a created Session's INSERT binds 17.
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_VARIABLE_NUMBER, rsql.max_parameters);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_TRIGGER_DEPTH, 0);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 4096);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_ATTACHED, 0);
        try sqlite.setLimit(database.?, c.SQLITE_LIMIT_WORKER_THREADS, 0);
        try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
        try sqlite.dbConfig(database.?, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
        // Before the first read: the Host keeps the file lock until close, and
        // WAL then keeps its index in heap memory, so no -shm file exists.
        try sqlite.exec(database.?, "PRAGMA locking_mode=EXCLUSIVE");
        if (existing) {
            if (options.found_schema_version) |found| found.* = try sqlite.pragmaInt(database.?, "PRAGMA user_version");
            try store_schema.validateExisting(database.?, selector);
        }
        try sqlite.exec(database.?, "PRAGMA busy_timeout=0");
        try sqlite.exec(database.?, "PRAGMA foreign_keys=ON");
        try sqlite.exec(database.?, "PRAGMA mmap_size=0");
        try sqlite.exec(database.?, "PRAGMA temp_store=FILE");
        var cache_size_buffer: [64:0]u8 = undefined;
        const cache_size = try std.fmt.bufPrintSentinel(&cache_size_buffer, "PRAGMA cache_size=-{d}", .{options.cache_kib}, 0);
        try sqlite.exec(database.?, cache_size);
        try sqlite.exec(database.?, if (options.cache_spill) "PRAGMA cache_spill=ON" else "PRAGMA cache_spill=OFF");
        try sqlite.exec(database.?, "PRAGMA synchronous=FULL");
        if (@import("../os/os.zig").full_fsync) try sqlite.exec(database.?, "PRAGMA fullfsync=ON");
        // Validation precedes this, so an incompatible Store keeps its journal mode.
        const journal_mode = sqlite.diagnosticTextPragma(database.?, "PRAGMA journal_mode=WAL") orelse return error.StoreJournalModeFailed;
        if (!std.mem.eql(u8, journal_mode.slice(), "wal")) return error.StoreJournalModeFailed;
        // Checkpoints truncate a grown WAL back to the auto-checkpoint size.
        try sqlite.exec(database.?, "PRAGMA journal_size_limit=4194304");
        if (!existing) try store_schema.bootstrap(database.?, selector);
        // A new Host never inherits a lost Action's sender authority.
        try sqlite.exec(database.?, "UPDATE action_operation SET sender_handle=NULL WHERE sender_handle IS NOT NULL");

        if (@import("builtin").is_test) try sqlite.createTouchOracleForTesting(database.?);

        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try stored_selector.set(selector);
        const changes = try createRing();
        errdefer destroyRing(changes);
        self.* = .{ .io = io, .database = database.?, .selector = stored_selector, .changes = changes, .ids = .{ .next = undefined } };
        self.served = options.served;
        // The Store is in final storage, so the function may keep its address.
        if (c.sqlite3_create_function_v2(self.database, "rui_served", 1, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC, &self.served, sqlite.servedFunction, null, null, null) != c.SQLITE_OK)
            return error.StoreOpenFailed;
        // Tells this opening's `since` tokens from another's. It grants
        // nothing, so the process CSPRNG serves, and Session IDs keep sole
        // use of secure draws.
        io.random(&self.instance);
        errdefer self.statements.deinit();
        // Error paths then roll back without preparing or allocating.
        _ = try cached(self, "ROLLBACK");
        try loadIdentities(self, .full);
    }

    pub fn sqliteDiagnostic(self: *Store) SqliteDiagnostic {
        lockAdmin(self);
        defer self.mutex.unlock(self.io);

        var result: SqliteDiagnostic = .{};
        var current: c.sqlite3_int64 = 0;
        var highwater: c.sqlite3_int64 = 0;
        if (c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &current, &highwater, 0) == c.SQLITE_OK and
            current >= 0 and highwater >= 0)
        {
            result.process_memory_current_bytes = @intCast(current);
            result.process_memory_highwater_bytes = @intCast(highwater);
        }

        var cache_used: c_int = 0;
        var unused_highwater: c_int = 0;
        if (c.sqlite3_db_status(
            self.database,
            c.SQLITE_DBSTATUS_CACHE_USED,
            &cache_used,
            &unused_highwater,
            0,
        ) == c.SQLITE_OK and cache_used >= 0) {
            result.cache_used_bytes = @intCast(cache_used);
        }
        var spills: c_int = 0;
        if (c.sqlite3_db_status(
            self.database,
            c.SQLITE_DBSTATUS_CACHE_SPILL,
            &spills,
            &unused_highwater,
            0,
        ) == c.SQLITE_OK and spills >= 0) {
            result.cache_spills = @intCast(spills);
        }

        const hard_heap_limit = c.sqlite3_hard_heap_limit64(-1);
        if (hard_heap_limit >= 0) result.hard_heap_limit_bytes = @intCast(hard_heap_limit);
        result.page_size_bytes = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA page_size");
        result.cache_size_setting = sqlite.diagnosticSignedPragma(self.database, "PRAGMA cache_size");
        result.cache_spill_threshold = sqlite.diagnosticSignedPragma(self.database, "PRAGMA cache_spill");
        result.mmap_size_bytes = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA mmap_size");
        result.synchronous = sqlite.diagnosticSignedPragma(self.database, "PRAGMA synchronous");
        result.temp_store = sqlite.diagnosticSignedPragma(self.database, "PRAGMA temp_store");
        result.busy_timeout_ms = sqlite.diagnosticUnsignedPragma(self.database, "PRAGMA busy_timeout");
        result.journal_mode = sqlite.diagnosticTextPragma(self.database, "PRAGMA journal_mode");
        return result;
    }

    pub fn close(self: *Store) !void {
        lockAdmin(self);
        self.statements.deinit();
        const close_result = c.sqlite3_close(self.database);
        self.mutex.unlock(self.io);
        // Freed even when SQLite keeps the handle: nothing retries a close.
        destroyRing(self.changes);
        if (close_result != c.SQLITE_OK) return error.StoreCloseFailed;
        _ = c.sqlite3_hard_heap_limit64(0);
        self.* = undefined;
    }

    /// Model settlement's batch table, in the Store's scratch beside its
    /// change ring (`OutOfLine`), so no frame on the engine thread holds
    /// it. Only `settleModelSuccess` uses it.
    pub fn settlementBatch(self: *Store) *model_settlement_domain.Batch {
        return @ptrCast(self.scratch(.settlement));
    }

    /// What a configure reads, over 4.6 KB, in the Store's scratch beside
    /// its change ring (`OutOfLine`), so no Host stack frame holds it. A
    /// configure or a creating Message uses it.
    pub fn configurationReads(self: *Store) *configuration_domain.ConfigurationReads {
        return @ptrCast(self.scratch(.configuration));
    }

    /// The Full report's revision content owners, in the Store's scratch
    /// beside its change ring (`OutOfLine`), so no Host stack frame holds
    /// its 16 KiB. Only `report.renderRevisions` uses it.
    pub fn reportOwners(self: *Store) *report_domain.ContentOwners {
        return @ptrCast(self.scratch(.report));
    }

    /// The scratch for `use`. Safe builds check that the caller holds the
    /// mutex, and that no other use took the scratch in this entry point:
    /// the two share its bytes. `Entry.release` frees it.
    fn scratch(self: *Store, use: ScratchUse) *align(scratch_align) [scratch_bytes]u8 {
        std.debug.assert(self.mutex.state.load(.monotonic) != .unlocked);
        std.debug.assert(self.scratch_use == .none or self.scratch_use == use);
        self.scratch_use = use;
        const owned: *OutOfLine = @fieldParentPtr("ring", self.changes);
        return &owned.scratch;
    }

    pub fn validateRetryWaits(self: *Store, waits_ms: retry_policy.Waits) !void {
        lockAdmin(self);
        defer self.mutex.unlock(self.io);
        try retry_policy.validateWaits(waits_ms, try readUnixMilliseconds(self.io));
    }

    /// A configuration that requires a model is rejected when the Host does
    /// not serve its Session's provider.
    pub fn configure(
        self: *Store,
        command: *const protocol.ConfigureCommand,
        faults: Faults,
    ) ConfigureReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, configuration_domain.configure(&access, self.io, self.served, command, faults))) catch .infrastructure_failure;
    }

    /// A fresh Message admission, as `MessageCommitted` receives it.
    pub const MessageAdmission = struct {
        /// The admitted Session, borrowed for the call.
        session: []const u8,
        /// Store-wide, increasing with each admission.
        admission_id: u64,
        /// The sender was another Session's Action, not a person.
        from_peer: bool,
    };

    /// Called once a fresh Message admission commits, before the Store lock
    /// is released, so whatever reads the Store next also sees its effect.
    /// A replayed or rejected Message calls nothing. It cannot fail.
    pub const MessageCommitted = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque, admission: MessageAdmission) void,
    };

    /// A Message's `require_model` condition checks that the Host serves its
    /// Session's provider before creating anything.
    pub fn submitMessageWithModel(
        self: *Store,
        command: *const protocol.MessageCommand,
        committed: ?MessageCommitted,
        faults: Faults,
    ) MessageReply {
        const entry = enter(self, .none) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{SessionUpdateFailed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.submitMessage(&access, self.io, self.served, self.selector.slice(), command, committed, faults))) catch .infrastructure_failure;
    }

    pub fn stopSession(
        self: *Store,
        command: *const protocol.SessionStopCommand,
        faults: Faults,
    ) SessionStopReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ InterruptionTargetChanged, StopSelectionChanged }) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.stopSession(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn interruptModel(
        self: *Store,
        command: *const protocol.ModelInterruptionCommand,
        faults: Faults,
    ) ModelInterruptionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{InterruptionTargetChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.interruptModel(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn decidePermission(
        self: *Store,
        command: *const protocol.PermissionDecisionCommand,
        faults: Faults,
    ) PermissionDecisionReply {
        const entry = enter(self, .fromControl(faults.control_trace)) catch return .infrastructure_failure;
        defer entry.release();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, command_domain.decidePermission(&access, command, faults))) catch .infrastructure_failure;
    }

    pub fn observeCommand(self: *Store, key: []const u8) !CommandObservation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, command_domain.observeCommand(&access, key));
    }

    pub fn commandResult(self: *Store, key: []const u8) !ContentReference {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.result, command_domain.commandResult(&access, key));
    }

    pub fn inspectSession(self: *Store, session_ref: []const u8, out: *SessionObservation) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, reads_domain.inspectSession(&access, session_ref, out));
    }

    // Reverse chronological, with call order breaking ties at a completed
    // group's final acceptance position. No transaction survives this call.
    // The fixed end is the last committed position at the first read, not a
    // count of visible rows; a private-only append cannot become public later.
    pub fn publicConversationPage(self: *Store, request: *const protocol.ConversationPage, out: *PublicConversationPage) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.publicConversationPage(&access, request, out));
    }

    // Resolve the public identity again, rather than accepting a global digest:
    // another Session's content or private provider material is not authority.
    pub fn openPublicConversationContent(self: *Store, request: *const protocol.ConversationContent) !ContentLocation {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.public_content, reads_domain.openPublicConversationContent(&access, request));
    }

    pub fn activityPage(self: *Store, request: *const protocol.ActivityPage, out: *protocol.ActivityFacts) !void {
        try request.validate();
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.page, reads_domain.activityPage(&access, request, out));
    }

    pub fn openActivityContent(self: *Store, request: *const protocol.ReadActivityContent) !ContentLocation {
        if (request.position == 0 or request.position > std.math.maxInt(i64) or request.ordinal > std.math.maxInt(i64)) return error.ContentNotFound;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.content, reads_domain.openActivityContent(&access, request));
    }

    /// Authenticates the Session/Operation/Attempt before reading optional
    /// diagnostics. Diagnostic faults never fence canonical state.
    pub fn captureFailedResponse(self: *Store, request: *const protocol.InspectSession, store_dir: std.Io.Dir, options: SessionListOptions) !SessionReport {
        const selection = request.failed_response.?;
        const binding = binding: {
            const entry = try enter(self, .none);
            defer entry.release();
            var access: ReadAccess = .open(&entry);
            defer access.deinit();
            break :binding try entry.finish(Ordinary.content, report_domain.failedResponseBinding(&access, request.session.slice(), selection));
        };
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        try @import("../failed_responses.zig").exportRecord(self.io, store_dir, binding, selection.part, &capture);
        return capture.seal();
    }

    pub fn captureSessionReport(
        self: *Store,
        session_ref: []const u8,
        options: SessionReportOptions,
    ) !SessionReport {
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        {
            const entry = try enter(self, .none);
            defer entry.release();
            var access: ReadAccess = .open(&entry);
            defer access.deinit();
            try entry.finishCapture(&capture, report_domain.renderSessionReport(&access, session_ref, options.profile, options.execution, &capture));
        }
        return capture.seal();
    }

    /// Returns an owned, unlinked page; no SQLite cursor or mutex survives capture.
    /// The caller releases its scratch charge by deinitializing the report.
    pub fn captureSessionList(self: *Store, request: *const protocol.ListSessions, options: SessionListOptions) !SessionReport {
        try request.validate();
        var capture: SessionReportCapture = .{ .io = self.io, .writer = null, .budget = options.scratch_budget };
        try capture.create(options.scratch_path, options.request_number, options.fail_unlink);
        errdefer capture.deinit();
        {
            const entry = try enter(self, .none);
            defer entry.release();
            var access: ReadAccess = .open(&entry);
            defer access.deinit();
            try entry.finishCapture(&capture, report_domain.renderSessionList(&access, request, &capture));
        }
        return capture.seal();
    }

    pub fn actionArguments(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .arguments);
    }

    pub fn actionCallId(self: *Store, session_ref: []const u8, action_id: u64) !ContentReference {
        return self.actionContent(session_ref, action_id, .call_id);
    }

    fn actionContent(self: *Store, session_ref: []const u8, action_id: u64, field: protocol.ProposalField) !ContentReference {
        const entry = try enter(self, .none);
        defer entry.release();
        if (action_id == 0 or action_id > std.math.maxInt(i64)) return error.ActionNotFound;
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action, action_domain.actionContent(&access, session_ref, action_id, field));
    }

    pub fn admitNextModelAttempt(self: *Store, faults: Faults) !?AttemptAdmission {
        if (!@import("builtin").is_test) @compileError("Production admission must select an explicit work kind");
        return try self.admitModelAttempt(.message, faults) orelse
            self.admitModelAttempt(.tool_continuation, faults);
    }

    /// Never inlined: its two Accesses and admission's rows (about 4 KiB)
    /// stay off the frame of a caller that goes on to dispatch the Attempt.
    pub noinline fn admitModelAttempt(self: *Store, kind: ModelAdmissionKind, faults: Faults) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var reader: ReadAccess = .open(&entry);
        defer reader.deinit();
        var writer: Access(.write, error{ SelectionChanged, ProjectionFailed, InstructionSelectionFailed }) = .open(&entry);
        defer writer.deinit();
        return entry.finishTransaction(Ordinary.none, faults, writer.end(faults, model_admission_domain.admitNextModelAttempt(&reader, &writer, kind, faults)));
    }

    pub fn admitNextActionAttempt(
        self: *Store,
        bash_timeout_ms: u64,
        faults: Faults,
    ) !?ActionAttemptAdmission {
        if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, action_domain.admitNextActionAttempt(&candidate, &access, self.io, bash_timeout_ms, faults)));
    }

    /// `out` is valid only when this returns without error.
    pub fn readBashExecutionInput(self: *Store, binding: ActionAttemptBinding, out: *BashExecutionInput) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.action_attempt, action_domain.readBashExecutionInput(&access, binding, out));
    }

    pub fn revokeActionSender(self: *Store, binding: ActionAttemptBinding) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.single, error{}) = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.revokeActionSender(&access, binding));
    }

    pub fn actionSupersededByStop(self: *Store, binding: ActionAttemptBinding) !?SupersedingControl {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, action_domain.actionSupersededByStop(&access, binding));
    }

    pub fn withActionDispatchHandoff(
        self: *Store,
        binding: ActionAttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        try entry.finish(Ordinary.action_dispatch, action_domain.validateActionDispatch(&access, binding));
        // Launch failures are effect outcomes, not canonical faults; the
        // caller settles or fences them. The handoff still runs under the lock.
        try handoff(context);
    }

    pub fn settleActionAttempt(
        self: *Store,
        binding: ActionAttemptBinding,
        code: ActionResolutionCode,
        result: []const u8,
        faults: Faults,
    ) !ActionSettlement {
        if (result.len == 0) return error.InvalidActionResult;
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.action_attempt) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.action_attempt, faults, access.end(faults, action_domain.settleActionAttempt(&access, binding, code, result, faults)));
    }

    pub fn recoverOneUncertainAction(self: *Store, active: ActiveOperationFilter) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{ActionSelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, action_domain.recoverOneUncertainAction(&candidate, &access, active)));
    }

    pub fn tryAdmitNextModelRetry(
        self: *Store,
        active: ActiveOperationFilter,
        faults: Faults,
    ) !?AttemptAdmission {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{RetryNoLongerDue}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, faults, access.end(faults, model_admission_domain.tryAdmitNextModelRetry(&candidate, &access, self.io, active, faults)));
    }

    /// Opens the view in `out`, where it stays until it closes: a view
    /// borrows its own buffers, so it never moves.
    pub fn openHistoricalView(self: *Store, binding: AttemptBinding, out: *HistoricalView) !void {
        try model_settlement_domain.checkAttempt(self, binding);
        out.* = .{ .store = self, .binding = binding };
    }

    pub fn modelOperationKind(self: *Store, binding: AttemptBinding) !ModelOperationKind {
        const entry = try enter(self, .none);
        defer entry.release();
        _ = try entry.finish(Ordinary.attempt_binding, model_settlement_domain.validateCurrentAttempt(self, binding));
        return entry.finish(Ordinary.none, model_settlement_domain.readModelOperationKind(self, binding.operation_id));
    }

    pub fn isFenced(self: *const Store) bool {
        return self.fenced.load(.acquire);
    }

    /// Read before the canonical reads it may let a caller skip.
    pub fn commitGeneration(self: *const Store) u64 {
        return self.commit_generation.load(.acquire);
    }

    pub fn operationSupersededByControl(self: *Store, binding: AttemptBinding) !?SupersedingControl {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: ReadAccess = .open(&entry);
        defer access.deinit();
        return entry.finish(Ordinary.none, model_settlement_domain.operationSupersededByControl(&access, binding));
    }

    pub fn withDispatchHandoff(
        self: *Store,
        binding: AttemptBinding,
        context: anytype,
        comptime handoff: anytype,
    ) !void {
        const entry = try enter(self, .none);
        defer entry.release();
        _ = try entry.finish(Ordinary.attempt_binding, model_settlement_domain.validateCurrentAttempt(self, binding));
        // As for Actions, dispatch failures belong to the caller.
        try handoff(context);
    }

    /// Durably claims this Operation's one forced credential refresh before
    /// any refresh exchange. The Attempt stays uncertain, so a crash before
    /// settlement falls back to ordinary uncertain recovery while the claim
    /// prevents a second refresh. Returns false when the Operation already
    /// claimed, or when no replacement allowance would remain.
    pub fn claimModelAuthRefresh(self: *Store, binding: AttemptBinding) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.attempt_binding || error{AuthRefreshUnclaimed}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.attempt_binding, .{}, access.end(.{}, model_settlement_domain.claimModelAuthRefresh(&access, binding)));
    }

    pub fn settleModelAttemptFailure(
        self: *Store,
        binding: AttemptBinding,
        failure: ModelFailure,
        disposition: ModelFailureClass,
        faults: Faults,
    ) !void {
        const code = failure.code();
        if (code.len == 0 or code.len > 96 or !std.unicode.utf8ValidateSlice(code)) {
            return error.InvalidFailureCode;
        }
        if (failure.diagnostic()) |detail| {
            std.debug.assert(detail.len <= 512 and std.unicode.utf8ValidateSlice(detail));
        }
        const report = failure.report();
        std.debug.assert(report.len <= protocol.max_report_bytes and std.unicode.utf8ValidateSlice(report));
        const entry = try enter(self, .none);
        defer entry.release();
        var access: Access(.write, Ordinary.attempt_binding) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.attempt_binding, faults, access.end(faults, model_settlement_domain.settleModelAttemptFailure(&access, self.io, binding, failure, disposition, faults)));
    }

    pub fn recoverOneExhaustedModelAttempt(
        self: *Store,
        active: ActiveOperationFilter,
    ) !bool {
        const entry = try enter(self, .none);
        defer entry.release();
        var candidate: ReadAccess = .open(&entry);
        defer candidate.deinit();
        var access: Access(.write, error{SelectionChanged}) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.none, .{}, access.end(.{}, model_settlement_domain.recoverOneExhaustedModelAttempt(&candidate, &access, active)));
    }

    pub fn settleModelSuccess(
        self: *Store,
        binding: AttemptBinding,
        output: *const ValidatedOutput,
        faults: Faults,
    ) !void {
        const entry = try enter(self, .fromSettlement(faults.settlement_trace));
        defer entry.release();
        var access: Access(.write, Ordinary.model_success) = .open(&entry);
        defer access.deinit();
        return entry.finishTransaction(Ordinary.model_success, faults, access.end(faults, model_settlement_domain.settleModelSuccess(&access, self.io, binding, output, faults)));
    }

    pub fn openContent(self: *Store, reference: ContentReference) !ContentLocation {
        return content_domain.openContentIdentity(self, reference, false);
    }
};

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
    settlement_trace: ?SettlementTrace = null,
};

pub const ControlTracePhase = enum { lock_requested, lock_acquired, durable_acceptance, store_complete };

pub const ControlTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, ControlTracePhase) void,

    pub fn mark(self: ControlTrace, phase: ControlTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const SettlementTracePhase = enum {
    lock_requested,
    lock_acquired,
    transaction_active,
    settlement_complete,
};

pub const SettlementTrace = struct {
    context: *anyopaque,
    mark_fn: *const fn (*anyopaque, SettlementTracePhase) void,

    pub fn mark(self: SettlementTrace, phase: SettlementTracePhase) void {
        self.mark_fn(self.context, phase);
    }
};

pub const AttemptBinding = attempt.AttemptBinding;

pub const OpenOptions = struct {
    /// The providers whose Sessions get model Attempts.
    served: protocol.Routes = protocol.routesAll(.endpoint),
    cache_spill: bool = true,
    cache_kib: u32 = 1024,
    found_schema_version: ?*u32 = null,
};

pub const SqliteDiagnostic = struct {
    process_memory_current_bytes: ?u64 = null,
    process_memory_highwater_bytes: ?u64 = null,
    cache_used_bytes: ?u64 = null,
    cache_spills: ?u64 = null,
    hard_heap_limit_bytes: ?u64 = null,
    page_size_bytes: ?u64 = null,
    cache_size_setting: ?i64 = null,
    cache_spill_threshold: ?i64 = null,
    mmap_size_bytes: ?u64 = null,
    synchronous: ?i64 = null,
    temp_store: ?i64 = null,
    busy_timeout_ms: ?u64 = null,
    journal_mode: ?protocol.Bounded(16) = null,
};

// The frame that holds a Store keeps every byte of it resident, so a fixed
// buffer belongs in memory of its own, like the change ring's. The production
// Store is 744 bytes; test builds add 24 bytes of counters and sit exactly at
// 768, so a new field must come out of existing padding, or out of the Store.
comptime {
    if (@sizeOf(Store) > 768) @compileError(std.fmt.comptimePrint("Store is {d} bytes; keep large state out of line", .{@sizeOf(Store)}));
}

/// The Store's state too large for the frame that holds it.
const OutOfLine = struct {
    ring: change_ring.Ring,
    scratch: Scratch align(scratch_align),
};

const ScratchUse = enum(u8) { none, configuration, settlement, report };

/// One entry point's large state: a configure's reads, a settlement's
/// batch or a Full report's content owners (within the batch's 14480
/// bytes), which no entry point holds at once (`Store.scratch` checks
/// that in safe builds). Bytes, not a union, so it is no bigger than the larger
/// use and needs no tag of its own: `Store.scratch_use` is its tag.
const Scratch = [scratch_bytes]u8;
const scratch_bytes = @max(@sizeOf(configuration_domain.ConfigurationReads), @sizeOf(model_settlement_domain.Batch), @sizeOf(report_domain.ContentOwners));
const scratch_align = @max(@alignOf(configuration_domain.ConfigurationReads), @alignOf(model_settlement_domain.Batch), @alignOf(report_domain.ContentOwners));

/// The resident bytes the owner accepted for a settlement batch of 64
/// items, beyond the configure reads' 4888.
const accepted_settlement_growth = 10240;

comptime {
    // The settlement batch is the larger use: 14480 bytes, 9592 beyond the
    // configure reads. Exact, so a change to either size is a decision.
    if (@sizeOf(configuration_domain.ConfigurationReads) != 4888 or scratch_bytes != 14480)
        @compileError(std.fmt.comptimePrint("the Store's scratch is {d} bytes and the configure reads {d}; restate them here", .{ scratch_bytes, @sizeOf(configuration_domain.ConfigurationReads) }));
    if (scratch_bytes - 4888 > accepted_settlement_growth) @compileError("the settlement batch outgrew what the owner accepted");
}

/// The change ring, and the scratch beside it, in pages of their own,
/// which the kernel faults in only as they are written: an idle Host keeps
/// none of the ring's 88 KiB resident. A configure, a creating Message or
/// a success settlement writes the scratch's pages once, and they stay
/// resident for the Store's life: at most 14480 bytes, a settlement
/// batch's size, of which a configure writes 4888.
/// Not `Allocator.create`, whose ReleaseSafe 0xAA fill would write every
/// page now.
fn createRing() error{OutOfMemory}!*change_ring.Ring {
    const bytes = std.heap.page_allocator.rawAlloc(@sizeOf(OutOfLine), .of(OutOfLine), @returnAddress()) orelse return error.OutOfMemory;
    const ring: *change_ring.Ring = &@as(*OutOfLine, @ptrCast(@alignCast(bytes))).ring;
    // Every scalar takes Ring's own default; the columns stay unwritten, since
    // only entries below `len` are read.
    const info = @typeInfo(change_ring.Ring).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (@typeInfo(Field) == .array) continue;
        @field(ring, name) = attrs.defaultValue(Field) orelse @compileError("Ring." ++ name ++ " needs a default");
    }
    return ring;
}

fn destroyRing(ring: *change_ring.Ring) void {
    const owned: *OutOfLine = @fieldParentPtr("ring", ring);
    std.heap.page_allocator.rawFree(@as([*]u8, @ptrCast(owned))[0..@sizeOf(OutOfLine)], .of(OutOfLine), @returnAddress());
}

/// Expected outcomes of locked entry points. A canonical read or save
/// fault fences the Host (ARCHITECTURE.md, "Commit boundaries and crash
/// recovery"), so every other error from an entry point has fenced the
/// Store before the caller sees it.
pub const Ordinary = struct {
    pub const none = error{};
    const page = error{ SessionNotFound, InvalidCursor };
    const content = error{ContentNotFound};
    const public_content = error{ ContentNotFound, RangeOutOfBounds };
    pub const action = error{ActionNotFound};
    const result = error{ ResultNotFound, ResultNotReady, ResultFailed };
    pub const attempt_binding = error{ StaleAttemptBinding, SupersededByControl };
    pub const historical_entry = error{HistoricalPending};
    const model_success = attempt_binding || error{InvalidProviderEnvelope};
    const action_attempt = error{StaleActionAttemptBinding};
    const action_dispatch = action_attempt || error{SupersededByControl};

    /// Rejects a declared ordinary name the body cannot return, so a
    /// stale or misspelled name fails to compile instead of fencing.
    fn produced(comptime Set: type, comptime Result: type) void {
        const returned = @typeInfo(@typeInfo(Result).error_union.error_set).error_set.error_names orelse return;
        outer: inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            inline for (returned) |candidate| {
                if (comptime std.mem.eql(u8, name, candidate)) continue :outer;
            }
            @compileError("ordinary error " ++ name ++ " is not returned by " ++ @typeName(Result));
        }
    }

    fn contains(comptime Set: type, err: anyerror) bool {
        inline for (@typeInfo(Set).error_set.error_names.?) |name| {
            if (err == @field(anyerror, name)) return true;
        }
        return false;
    }
};

const EntryTrace = union(enum) {
    none,
    control: ControlTrace,
    settlement: SettlementTrace,

    fn fromControl(trace: ?ControlTrace) EntryTrace {
        return if (trace) |value| .{ .control = value } else .none;
    }

    fn fromSettlement(trace: ?SettlementTrace) EntryTrace {
        return if (trace) |value| .{ .settlement = value } else .none;
    }

    fn mark(self: EntryTrace, phase: enum { requested, acquired, complete }) void {
        switch (self) {
            .none => {},
            .control => |trace| trace.mark(switch (phase) {
                .requested => .lock_requested,
                .acquired => .lock_acquired,
                .complete => .store_complete,
            }),
            .settlement => |trace| trace.mark(switch (phase) {
                .requested => .lock_requested,
                .acquired => .lock_acquired,
                .complete => .settlement_complete,
            }),
        }
    }
};

/// Exclusive canonical access for one entry point, from `enter` through
/// `release`. Errors leave through `finish` or `finishTransaction`, which
/// return the entry point's declared ordinary errors and fence the rest.
/// Only `lockAdmin` otherwise takes the mutex, for open/close diagnostics.
pub const Entry = struct {
    const max_result_bytes = 1024;

    store: *Store,
    trace: EntryTrace,
    changes: i64,

    pub fn finish(self: Entry, comptime Expected: type, result: anytype) @TypeOf(result) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

    /// Rolls back any open transaction first; a failed rollback fences
    /// and replaces the original error, including an ordinary one.
    pub fn finishTransaction(self: Entry, comptime Expected: type, faults: Faults, result: anytype) Transaction(@TypeOf(result)) {
        comptime Ordinary.produced(Expected, @TypeOf(result));
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            rollbackAfterError(self.store, faults) catch |rollback_err| return fence(self.store, rollback_err);
            if (Ordinary.contains(Expected, err)) return err;
            return fence(self.store, err);
        };
    }

    /// Report capture marks its own scratch failures ordinary.
    fn finishCapture(self: Entry, capture: *const SessionReportCapture, result: anytype) @TypeOf(result) {
        comptime assertSmallResult(@TypeOf(result));
        return result catch |err| {
            if (capture.ordinary_failure) return err;
            return fence(self.store, err);
        };
    }

    pub fn release(self: Entry) void {
        const store = self.store;
        store.read_blob.close();
        store.scratch_use = .none;
        if (@import("builtin").is_test) store.statements.assertIdle();
        // Counts autocommit and explicit-transaction writes alike. A
        // rolled-back change touched everything: never a missed change.
        if (c.sqlite3_total_changes64(store.database) != self.changes) {
            if (@import("builtin").is_test) if (untouchedForTesting(store)) |id|
                std.debug.panic("rows of Session {s} changed, but the entry point that changed them did not touch it", .{&id});
            const generation = store.commit_generation.fetchAdd(1, .release) + 1;
            store.changes.record(generation, &store.touched);
        }
        self.trace.mark(.complete);
        store.mutex.unlock(store.io);
    }

    /// Rejects an entry point result over `max_result_bytes`. A Host
    /// thread keeps its deepest stack pages for life, and a result
    /// returned by value takes a slot in each frame it passes through;
    /// a big result is filled through the caller's `out: *T` instead.
    fn assertSmallResult(comptime Result: type) void {
        const Payload = @typeInfo(Result).error_union.payload;
        const Value = switch (@typeInfo(Payload)) {
            .optional => |optional| optional.child,
            else => Payload,
        };
        if (@sizeOf(Value) > max_result_bytes) @compileError(std.fmt.comptimePrint(
            "{s} is {d} bytes, over the {d}-byte result bound; fill it through out: *T",
            .{ @typeName(Value), @sizeOf(Value), max_result_bytes },
        ));
    }

    fn Transaction(comptime Result: type) type {
        const info = @typeInfo(Result).error_union;
        return (info.error_set || error{CanonicalRollbackFailed})!info.payload;
    }
};

pub fn enter(self: *Store, trace: EntryTrace) error{StoreFenced}!Entry {
    if (self.isFenced()) return error.StoreFenced;
    trace.mark(.requested);
    self.mutex.lockUncancelable(self.io);
    self.touched = .{};
    // Rows a test changed outside any entry point belong to none.
    if (@import("builtin").is_test) clearTouchOracleForTesting(self);
    const entry: Entry = .{ .store = self, .trace = trace, .changes = c.sqlite3_total_changes64(self.database) };
    trace.mark(.acquired);
    if (self.isFenced()) {
        entry.release();
        return error.StoreFenced;
    }
    return entry;
}

/// Administrative access without canonical classification.
fn lockAdmin(self: *Store) void {
    self.mutex.lockUncancelable(self.io);
}

/// Records that this entry point changes `session_ref`'s rows, with its
/// Workspace's key, read here inside the entry point: a failed read
/// fails it, and fences, like any other. The Session's row must exist.
pub fn touch(self: *Store, session_ref: []const u8) !void {
    if (!self.touched.needsEntry(session_ref)) return;
    const workspace = try readSessionWorkspaceKey(self, session_ref) orelse return error.CorruptStore;
    self.touched.add(.{ .session = session_ref[0..change_ring.id_bytes].*, .workspace = workspace });
}

/// Opens an entry point's write transaction. Every entry point begins
/// here; only opening the Store, in `schema.bootstrap`, issues a BEGIN of
/// its own, before any entry point can run.
pub fn begin(self: *Store) !void {
    std.debug.assert(self.ids.taken.count() == 0 and self.ids.second == 0);
    try execute(self, "BEGIN IMMEDIATE");
}

/// Commits the open transaction; the identities it took stay taken.
pub fn commit(self: *Store) !void {
    try execute(self, "COMMIT");
    self.ids.taken = .empty;
    self.ids.second = 0;
}

/// Rolls back the open transaction. A Session it created no longer
/// exists, so the entry point has touched everything.
pub fn rollback(self: *Store) !void {
    self.touched.everything = true;
    self.ids.second = 0;
    try execute(self, "ROLLBACK");
    try loadIdentities(self, self.ids.taken);
}

/// The open transaction's second, bound to every `@now` in it: read from
/// the clock at its first use, and held until commit or rollback, so a
/// nested Access dates its rows with its caller's second. Outside a
/// transaction (a read Access), each use reads the clock.
pub fn transactionSecond(self: *Store) error{ClockReadFailed}!i64 {
    if (self.ids.second != 0) return self.ids.second;
    const second = std.math.cast(u32, @divFloor(try readUnixMilliseconds(self.io), 1000)) orelse return error.ClockReadFailed;
    if (second == 0) return error.ClockReadFailed;
    if (c.sqlite3_get_autocommit(self.database) == 0) self.ids.second = second;
    return second;
}

/// A Workspace's identity in the Store: SHA-256 of its canonical text.
/// Reads compare it, then the text, so a collision never merges two.
pub fn workspaceDigest(workspace: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workspace, &digest, .{});
    return digest;
}

const session_workspace_key_sql = "SELECT workspace_key FROM session WHERE session_ref=?1";

/// The key of `session_ref`'s Workspace, or null when no such Session
/// exists.
fn readSessionWorkspaceKey(self: *Store, session_ref: []const u8) !?u64 {
    const statement = try cached(self, session_workspace_key_sql);
    defer sqlite.resetCached(statement);
    try sqlite.bindText(statement, 1, session_ref);
    return switch (c.sqlite3_step(statement)) {
        c.SQLITE_DONE => null,
        c.SQLITE_ROW => @intCast(try sqlite.readNullablePositiveI64(statement, 0) orelse return error.CorruptStore),
        else => error.SessionReadFailed,
    };
}

/// Test builds: a Session whose rows this entry point changed but did
/// not touch. The oracle is a temporary trigger on each table that
/// carries a Session, so a writer that skips `touch` fails whichever
/// test drives it.
pub fn untouchedForTesting(self: *Store) ?change_ring.Id {
    if (!@import("builtin").is_test) @compileError("test-only check");
    if (self.touched.everything) return null;
    // Cached, so a test that counts prepared or uncached statements sees
    // none. A test that makes SQLite fail gets no verdict.
    const statement = cached(self, "SELECT DISTINCT session_ref FROM temp.touched_oracle WHERE session_ref IS NOT NULL") catch return null;
    defer sqlite.resetCached(statement);
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) {
        const changed = c.sqlite3_column_text(statement, 0)[0..@intCast(c.sqlite3_column_bytes(statement, 0))];
        if (self.touched.contains(changed)) continue;
        var id: change_ring.Id = @splat('?');
        const length = @min(id.len, changed.len);
        @memcpy(id[0..length], changed[0..length]);
        return id;
    }
    return null;
}

fn clearTouchOracleForTesting(self: *Store) void {
    if (!@import("builtin").is_test) @compileError("test-only oracle");
    const statement = cached(self, "DELETE FROM temp.touched_oracle") catch return;
    defer sqlite.resetCached(statement);
    _ = c.sqlite3_step(statement);
}

/// The only fence setter. Returns `err` so callers can propagate it.
pub fn fence(self: *Store, err: anytype) @TypeOf(err) {
    self.fenced.store(true, .release);
    return err;
}

/// The saved Session, as `configuration.readSaved` reads it, in a read
/// Access of its own, then checked by `configuration.checkSaved`.
pub fn readSessionForTesting(self: *Store, session_ref: []const u8) !?CurrentConfiguration {
    var a = ReadAccess.within(self);
    defer a.deinit();
    var current: CurrentConfiguration = .{};
    var found: Found = undefined;
    configuration_domain.readSaved(&a, session_ref, &current, &found);
    try a.run();
    if (!found.get()) return null;
    try configuration_domain.checkSaved(&current);
    return current;
}

pub fn activityPageForTesting(self: *Store, request: protocol.ActivityPage) !protocol.ActivityFacts {
    var page: protocol.ActivityFacts = undefined;
    try self.activityPage(&request, &page);
    return page;
}

pub fn publicConversationPageForTesting(self: *Store, request: protocol.ConversationPage) !PublicConversationPage {
    var page: PublicConversationPage = undefined;
    try self.publicConversationPage(&request, &page);
    return page;
}

/// Prepares `sql` once for the Store's lifetime; the caller resets it
/// with `resetCached` before releasing the Store mutex. Comptime only
/// pins the SQL to static storage, so one body serves every statement.
pub inline fn cached(self: *Store, comptime sql: [:0]const u8) !*c.sqlite3_stmt {
    comptime rsql.checkStatement(sql);
    return cachedStatic(self, sql);
}

/// A typed statement's prepared form, cached like `cached`'s. Its text was
/// checked when the statement type was made.
pub fn cachedTyped(self: *Store, comptime S: type) !*c.sqlite3_stmt {
    return cachedStatic(self, S.sql);
}

/// Reached only through `cached` and `cachedTyped`: a reused buffer would
/// alias its key.
fn cachedStatic(self: *Store, sql: [:0]const u8) !*c.sqlite3_stmt {
    if (self.statements.find(sql.ptr)) |statement| {
        std.debug.assert(c.sqlite3_stmt_busy(statement) == 0);
        return statement;
    }
    var prepared: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v3(self.database, sql, -1, c.SQLITE_PREPARE_PERSISTENT, &prepared, null) != c.SQLITE_OK) {
        return error.StatementPrepareFailed;
    }
    const statement = prepared orelse return error.StatementPrepareFailed;
    self.statements.insert(sql.ptr, statement) catch |err| {
        _ = c.sqlite3_finalize(statement);
        return err;
    };
    return statement;
}

/// Runs a cached statement that returns no rows.
pub inline fn execute(self: *Store, comptime sql: [:0]const u8) !void {
    comptime rsql.checkStatement(sql);
    return executeStatic(self, sql);
}

fn executeStatic(self: *Store, sql: [:0]const u8) !void {
    const statement = try cachedStatic(self, sql);
    defer sqlite.resetCached(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.SqliteExecFailed;
}

/// A column whose values the Host hands out: a row's id, or its place in
/// a Store-wide order.
pub const Identity = enum { turn_id, operation_id, action_id, content_id, created_seq, command_seq, admission_id };

/// What the Host hands to transactions. The next value of each `Identity`
/// is the Store's maximum plus one, read at open and again for each column
/// a rolled-back transaction took from. Correct because one Host owns the
/// Store; the primary or unique key still refuses a duplicate, and a
/// refused write fences.
const HostValues = struct {
    next: std.EnumArray(Identity, u64),
    /// The columns that handed out a value since `begin`.
    taken: std.EnumSet(Identity) = .empty,
    /// The open transaction's Unix second for `@now`, or 0 before its first
    /// use. A u32 holds seconds until 2106 and fits the padding after
    /// `taken`, so the Store does not grow.
    second: u32 = 0,
};

/// The next value of `column`, inside the open transaction. The one place
/// an identity is allocated, so a per-Host range can replace the counter.
pub fn takeIdentity(self: *Store, comptime column: Identity) error{ IdentityExhausted, IdentityOutsideTransaction }!u64 {
    // Rollback is what gives an id back; outside a transaction nothing would.
    if (c.sqlite3_get_autocommit(self.database) != 0) return error.IdentityOutsideTransaction;
    const value = self.ids.next.get(column);
    if (value > std.math.maxInt(i64)) return error.IdentityExhausted;
    self.ids.next.set(column, value + 1);
    self.ids.taken.insert(column);
    return value;
}

/// Re-reads every id after a test wrote rows past the Host, as reopening
/// would.
pub fn reloadIdentitiesForTesting(self: *Store) !void {
    try loadIdentities(self, .full);
}

/// Reads `columns`' next values from the committed rows: at open, and after
/// a rollback, which gives back every value its transaction took. Re-reading
/// max() rather than restoring a snapshot taken at BEGIN stays correct when
/// a COMMIT's outcome is unknown, because only committed rows count: a
/// value whose row committed is never handed out twice, and one whose row
/// did not is handed out again.
fn loadIdentities(self: *Store, columns: std.EnumSet(Identity)) !void {
    inline for (comptime std.enums.values(Identity)) |column| if (columns.contains(column)) {
        const table = switch (column) {
            .turn_id => "turn",
            .operation_id => "model_operation",
            .action_id => "action_operation",
            .content_id => "content",
            .created_seq => "session",
            .command_seq => "core_command",
            .admission_id => "message_admission",
        };
        const statement = try cached(self, "SELECT coalesce(max(" ++ @tagName(column) ++ "),0) FROM " ++ table);
        defer sqlite.resetCached(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.IdentityReadFailed;
        self.ids.next.set(column, try sqlite.readCount(statement, 0) + 1);
    };
    self.ids.taken = .empty;
}

pub fn rollbackAfterError(self: *Store, faults: Faults) !void {
    // SQLite may already have rolled back what the entry point touched.
    self.touched.everything = true;
    if (c.sqlite3_get_autocommit(self.database) == 0) {
        if (faults.rollback_failure) return error.CanonicalRollbackFailed;
        execute(self, "ROLLBACK") catch return error.CanonicalRollbackFailed;
        if (c.sqlite3_get_autocommit(self.database) == 0) return error.CanonicalRollbackFailed;
    }
    self.ids.second = 0;
    loadIdentities(self, self.ids.taken) catch return error.CanonicalRollbackFailed;
}

pub fn readUnixMilliseconds(io: std.Io) !i64 {
    const value = std.Io.Clock.real.now(io).toMilliseconds();
    if (value <= 0) return error.ClockReadFailed;
    return value;
}
